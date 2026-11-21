-- A-Life Talk 0.5.1.2: ATTENTION: talk to someone and they stop, turn to you and listen (typing / push-to-talk too); danger cancels it
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Attention") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Attention"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Attention") end end -- 0.5.1.6 perf label
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur == nil then -- pre-1.0 MP: first player with people near
        for _, p in ipairs(ALifeSide.online()) do
            local x, y, z = pos(p)
            local list = M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}
            if #list > 0 then return list, p end
        end
        return {}, nil
    end
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Attention", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = true, nil
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- pre-1.0 MP: once per online player
            M.eachPlayer(function() local ok2, e2 = pcall(f, now); if not ok2 then ok, e = ok2, e2 end end)
        else ok, e = pcall(f, now) end
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("attention", true)
setting("listenWindowSec", 10)
setting("listenDebug", true) -- [ALifeTalk][Listen] lines in console.txt (hold start / reassert / skip / end)
-- leaveTiles 11 < A-Life's Talk listenRadius (12): A-Life drops a talk hold beyond that, so we let go first
M.attnCfg = { talkTiles = 12, typeTiles = 9, threatTiles = 10, hostileTiles = 10, leaveTiles = 11, tickMs = 150, scanMs = 500,
    reassertMs = 1000, holdSlackMs = 2500, minHoldMs = 3000, losGraceMs = 2500, stuckMs = 1200, volatileTypeCapMs = 6000 }
M.attnCool = {} -- uid -> ms: volatile people who already lost patience don't re-listen to the same typing
M.attn = {} -- uid -> { untilMs, held, why, startMs, via, lastAssert, losLostAt, movingSince, factor }
-- 0.5.1.2: diagnostics. Skips are rate-limited per NPC + reason so the log stays readable.
M.listenLogAt = {}
function M.listenLog(msg, key, gapMs)
    if M.settings.listenDebug == false then return end
    if key ~= nil then
        local now = nowMs()
        if now - (M.listenLogAt[key] or -1e12) < (gapMs or 10000) then return end
        M.listenLogAt[key] = now
    end
    ALifeHealth.note("[ALifeTalk][Listen]", msg)
end
local function who(l) return tostring(l and l.record and nameOf(l.record) or "?") .. " (" .. tostring(l and l.record and l.record.uid) .. ")" end
local function windowMs() return math.max(2, tonumber(M.settings.listenWindowSec) or 10) * 1000 end
-- volatile / hot-headed people barely pause: their window shrinks (0.25 .. 1)
function M.attnFactor(uid)
    local lens = M.lens and M.lens(uid) or {}
    local f = 1 - (lens.volatile or 0) * 0.8 - (lens.mean or 0) * 0.3
    local core = M.partsOf and M.partsOf(uid) or nil
    local k = core and core.core and core.core.key or ""
    if k == "hothead" or k == "sadist" or k == "cruel" or k == "bully" or k == "ruthless" then f = f * 0.4 end
    return clamp(f, 0.25, 1)
end
local function textFocused(box)
    local f = false
    pcall(function() if box ~= nil and box.isFocused ~= nil then f = box:isFocused() == true end end)
    return f
end
-- typing in chat or the A-Life talk box, or holding push-to-talk
function M.playerComposing()
    local busy = false
    pcall(function()
        if type(ISChat) ~= "table" then return end
        if ISChat.focused == true then busy = true; return end
        local inst = ISChat.instance
        if inst ~= nil and (inst.focused == true or textFocused(inst.textEntry)) then busy = true end
    end)
    if busy then return true, "chat" end
    pcall(function()
        local box = PA().TalkInput and PA().TalkInput.box
        busy = box ~= nil and box.isVisible ~= nil and box:isVisible() == true
    end)
    if busy then return true, "talkbox" end
    if type(M.voiceState) == "table" and M.voiceState.down == true then return true, "ptt" end
    return false
end
-- own zombie count (used when the patch is missing); A-Life's people are IsoZombies too, so they are skipped
local function zombiesNearOwn(x, y, tiles)
    local n = 0
    pcall(function()
        local cell = getCell()
        local zs = cell ~= nil and cell.getZombieList ~= nil and cell:getZombieList() or nil
        if zs == nil or zs.size == nil then return end
        local S = PA().Speech
        for i = 0, math.min(zs:size(), 400) - 1 do
            local zb = zs:get(i)
            if zb ~= nil and zb.getX ~= nil and not (zb.isDead ~= nil and zb:isDead()) then
                if math.abs(zb:getX() - x) <= tiles and math.abs(zb:getY() - y) <= tiles then
                    local v = S and fn(S, "variable") and S.variable(zb, "ALifeUID") or nil
                    if v == nil or tostring(v) == "" then n = n + 1 end
                end
            end
        end
    end)
    return n
end
-- danger near the NPC: zombies, hostiles, a fight, fleeing. Returns the reason (string) or false
function M.attnDanger(l, player)
    local P = patch()
    local x, y, z = pos(l.shell)
    if x == nil then return "no body" end
    local zn
    if P and fn(P, "zombiesNear") then zn = tonumber((P.zombiesNear(x, y, M.attnCfg.threatTiles))) or 0 else zn = zombiesNearOwn(x, y, M.attnCfg.threatTiles) end
    if zn > 0 then return "zombies (" .. zn .. " within " .. M.attnCfg.threatTiles .. " tiles)" end
    if M.inCombat and M.inCombat(l.shell, l.record) then return "in combat" end
    local r = l.record
    if r.intent == "flee" or r.activity == "fleeing" or r.intent == "panic" or r.intent == "retreat" or r.intent == "gun_flee" then return "fleeing" end
    local pa = PA()
    if fn(pa.Talk, "stance") and M.nearbyNpcs then
        for _, o in ipairs(M.nearbyNpcs(x, y, z or 0, M.attnCfg.hostileTiles, r.uid)) do
            local ok, st = pcall(pa.Talk.stance, o.record, player)
            if ok and st == "hostile" then return "hostile " .. tostring(nameOf(o.record)) .. " near" end
        end
    end
    return false
end
-- hostile, terrified or rude-by-nature NPCs may not give you the time of day
function M.attnIgnores(l, player, seed)
    local pa = PA()
    local st = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or "neutral"
    if st == "hostile" then return true, "hostile" end
    local uid = tostring(l.record.uid)
    local e = M.emoBehavior and M.emoBehavior(uid) or {}
    if (e.fear or 0) >= 0.7 then return true, "terrified" end
    local v = 0
    pcall(function() v = tonumber((pa.NpcOpinion.valueOf(l.record, player))) or 0 end)
    local _, style = nil, nil
    if M.personaKind then _, style = M.personaKind(uid) end
    local rude = style == "insult" or style == "mock" or style == "refuse"
    if (rude or v <= -40) and (hash(uid .. "#attn#" .. tostring(seed)) % 100) < (v <= -40 and 70 or 40) then return true, "rude" end
    return false
end
local function face(l, player)
    local ok = false
    pcall(function() local S = PA().Speech; if S and type(S.face) == "function" then S.face(l.shell, player); ok = true end end)
    if not ok then pcall(function() if l.shell.faceThisObject ~= nil then l.shell:faceThisObject(player) end end) end
end
local function playerKey(player)
    local k = nil
    pcall(function() local S = PA().Speech; if fn(S, "playerKey") then k = S.playerKey(player) end end)
    return k
end
-- how long A-Life's own talk hold still runs for this player (ms; 0 = none / someone else's)
function M.attnHoldLeft(uid, player, now)
    local r = rec(uid)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or nil
    if m == nil or m.talkHoldPlayerKey == nil then return 0 end
    local key = playerKey(player)
    if key ~= nil and m.talkHoldPlayerKey ~= key then return 0 end
    return math.max(0, (tonumber(m.talkHoldUntilMs) or 0) - (now or nowMs()))
end
-- NPCs something else is steering right now (their own hold / an order / territory) - we only face them
local function steeredBy(uid, l)
    local P = patch()
    if M.paused and M.paused[uid] then return "pause-listen" end
    if P and fn(P, "orderedBy") and P.orderedBy(uid) ~= nil then return "order " .. tostring(P.orderedBy(uid)) end
    if M.terr and M.terr[uid] then return "territory" end
    -- A-Life is walking them to / from a car seat: a hold here cancels its path ("directive_changed" error + retry)
    local DO = rawget(_G, "ALifeDriveOrders")
    if DO and DO.passengerPhase then
        local okP, ph = pcall(DO.passengerPhase, uid)
        if okP and (ph == "approach" or ph == "exit_pending" or ph == "outside" or ph == "walkaway") then return "car " .. tostring(ph) end
    end
    return nil
end
-- write / refresh A-Life's own talk hold (memory.talkHoldUntilMs: DecisionLoop.talkStop + ModuleTalkPresence keep them
-- standing and facing you every brain tick). Through the patch when present (companions wait, our activities stop).
local function applyHold(l, player, ms, now)
    local uid = tostring(l.record.uid)
    local P = patch()
    local pa = PA()
    ms = math.max(M.attnCfg.minHoldMs, math.floor(ms))
    local via = nil
    if P and fn(P, "holdFriendly") then
        if pcall(P.holdFriendly, uid, player, ms) then via = "patch" end
    end
    if M.attnHoldLeft(uid, player, now) <= 0 and fn(pa.Talk, "hold") then
        if pcall(pa.Talk.hold, l.record, l.shell, player, now, ms) then via = "alife" end
    end
    if M.attnHoldLeft(uid, player, now) > 0 then return true, via end
    -- A-Life refused (busy) or is missing: a plain body stop so at least this moment they stand still
    pcall(function() if l.shell.setMoving ~= nil then l.shell:setMoving(false) end end)
    return false, (via and (via .. " (A-Life refused: busy)")) or "no Talk.hold"
end
local function stopBody(l)
    pcall(function()
        if l.shell.getPathFindBehavior2 ~= nil then
            local pf = l.shell:getPathFindBehavior2()
            if pf ~= nil and pf.cancel ~= nil then pf:cancel() end
        end
        if l.shell.setMoving ~= nil then l.shell:setMoving(false) end
    end)
end
-- start / refresh attention on one NPC
function M.attend(l, player, why)
    if l == nil or player == nil then return false end
    if M.settings.attention == false then M.listenLog("skip: setting 'attention' is off", "off", 60000); return false, "off" end
    local uid = tostring(l.record.uid)
    local now = nowMs()
    local danger = M.attnDanger(l, player)
    if danger then
        M.listenLog("skip " .. who(l) .. ": danger - " .. tostring(danger), uid .. "|danger")
        if M.attn[uid] then M.release(uid, player, "danger: " .. tostring(danger)) end
        return false, "danger"
    end
    local a = M.attn[uid]
    local fresh = a == nil
    if not fresh then
        local st = "neutral"
        pcall(function() local pa = PA(); if fn(pa.Talk, "stance") then st = pa.Talk.stance(l.record, player) end end)
        if st == "hostile" then
            M.listenLog("skip " .. who(l) .. ": ignores you (hostile)", uid .. "|ign")
            M.release(uid, player, "turned hostile")
            return false, "hostile"
        end
    elseif why ~= "talking" and (M.attnCool[uid] or -1e12) > now then
        return false, "cooldown" -- a short fuse already ran out while you kept typing
    end
    if fresh then
        local ign, reason = M.attnIgnores(l, player, math.floor(now / 30000))
        if ign then
            M.attnIgnored = { uid = uid, why = reason }
            M.listenLog("skip " .. who(l) .. ": ignores you (" .. tostring(reason) .. ")", uid .. "|ign")
            return false, reason
        end
        a = { startMs = now, held = false, factor = M.attnFactor(uid), lastAssert = -1e12 }
        M.attn[uid] = a
    end
    local cap = (a.factor < 0.5 and why ~= "talking" and why ~= "answering") and (a.startMs + M.attnCfg.volatileTypeCapMs) or 1e15
    a.untilMs = math.max(a.untilMs or 0, math.min(now + windowMs() * a.factor, cap))
    a.why = why
    local other = steeredBy(uid, l)
    if other then
        a.held = false
        if fresh then M.listenLog("listen " .. who(l) .. " (" .. tostring(why) .. "): face only, " .. other .. " keeps them") end
    elseif fresh or M.attnHoldLeft(uid, player, now) < math.min(a.untilMs - now, M.attnCfg.holdSlackMs) then
        a.lastAssert = now
        local ok, via = applyHold(l, player, a.untilMs - now + M.attnCfg.holdSlackMs, now)
        a.held = a.held or ok
        a.via = via
        if fresh then
            M.listenLog("hold start " .. who(l) .. " (" .. tostring(why) .. ") window " .. math.floor(a.untilMs - now) .. " ms via " .. tostring(via)
                .. (ok and "" or " - NOT held") .. (a.factor < 1 and (" (volatile x" .. ALifeFmtDec(a.factor, 2) .. ")") or ""))
        end
    end
    face(l, player)
    return true
end
function M.release(uid, player, why)
    local a = M.attn[uid]
    M.attn[uid] = nil
    if a and a.held then
        local P = patch()
        local pa = PA()
        if P and fn(P, "resumeFriendly") then pcall(P.resumeFriendly, uid, player)
        elseif fn(pa.Talk, "releaseHold") then pcall(pa.Talk.releaseHold, tostring(uid), playerKey(player)) end
    end
    M.attnLastEnd = { uid = uid, why = why }
    if a then M.listenLog("hold end " .. tostring(nameOf(rec(uid))) .. " (" .. tostring(uid) .. "): " .. tostring(why)
        .. " after " .. math.floor(nowMs() - (a.startMs or nowMs())) .. " ms") end
end
-- who you're about to talk to: the NPC you face most, else the nearest
function M.attnTarget(player)
    local x, y, z = pos(player)
    if x == nil or not M.nearbyNpcs then return nil end
    local fx, fy = nil, nil
    pcall(function() local v = player:getForwardDirection(); fx, fy = v:getX(), v:getY() end)
    local best, bestS = nil, -1e9
    for _, l in ipairs(M.nearbyNpcs(x, y, z or 0, M.attnCfg.typeTiles)) do
        local lx, ly = pos(l.shell)
        if lx then
            local dx, dy = lx - x, ly - y
            local d = math.sqrt(dx * dx + dy * dy) + 0.01
            local s = -d
            if fx then s = s + ((dx * fx + dy * fy) / d) * 4 end
            if s > bestS then best, bestS = l, s end
        end
    end
    return best
end
local function waitingOn(uid)
    if M.pending and tostring(M.pending.uid) == uid then return true end
    for _, q in ipairs(M.queue or {}) do if tostring(q.uid) == uid and (q.mode == "reply" or q.mode == "radio") then return true end end
    return false
end
function M.attnTick(now)
    if M.settings.attention == false or not M.worldHere() then return end
    local player = ALifeSide.you()
    if player == nil then return end
    local composing, how = M.playerComposing()
    if composing and now - (M.attnScanAt or 0) >= M.attnCfg.scanMs then
        M.attnScanAt = now
        local l = M.attnTarget(player)
        if l then M.attend(l, player, "typing (" .. tostring(how) .. ")")
        else M.listenLog("you are typing (" .. tostring(how) .. ") but nobody is within " .. M.attnCfg.typeTiles .. " tiles", "nobody", 15000) end
    end
    -- the NPC we wait an AI answer from listens too (even if the words hook missed them)
    if M.pending and M.pending.uid and M.attn[tostring(M.pending.uid)] == nil and now - (M.attnPendAt or 0) >= 1000 then
        M.attnPendAt = now
        local pa = PA()
        local uid = tostring(M.pending.uid)
        local r, sh = rec(uid), fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
        if r and sh then
            local px0, py0 = pos(player)
            local sx, sy = pos(sh)
            if px0 and sx and (sx - px0) ^ 2 + (sy - py0) ^ 2 <= M.attnCfg.leaveTiles ^ 2 then M.attend({ record = r, shell = sh }, player, "answering") end
        end
    end
    local pa = PA()
    local px, py = pos(player)
    for uid, a in pairs(M.attn) do
        local r = rec(uid)
        local sh = r and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
        if r == nil or sh == nil then M.attn[uid] = nil; M.listenLog("hold end " .. tostring(uid) .. ": unloaded")
        else
            local l = { record = r, shell = sh }
            local x, y = pos(sh)
            local waiting = waitingOn(uid)
            if waiting then a.untilMs = math.max(a.untilMs, now + windowMs() * a.factor) end
            if composing then
                local cap = a.factor < 0.5 and (a.startMs + M.attnCfg.volatileTypeCapMs) or 1e15
                a.untilMs = math.max(a.untilMs, math.min(now + windowMs() * a.factor, cap))
            end
            local danger = M.attnDanger(l, player)
            if danger then M.release(uid, player, "danger - " .. tostring(danger))
            elseif x == nil or px == nil or (x - px) ^ 2 + (y - py) ^ 2 > M.attnCfg.leaveTiles ^ 2 then M.release(uid, player, "walked away")
            elseif now >= a.untilMs then
                if a.factor < 0.5 then M.attnCool[uid] = now + 30000 end
                M.release(uid, player, a.factor < 0.5 and "window over (volatile, short fuse)" or "window over")
            else
                -- out of sight for a while: A-Life won't keep a hold it can't see either
                local los = true
                if fn(pa.Talk, "lineOfSight") then local okL, v = pcall(pa.Talk.lineOfSight, player, sh, r); los = not okL or v == true end
                if not los then a.losLostAt = a.losLostAt or now else a.losLostAt = nil end
                if a.losLostAt and now - a.losLostAt >= M.attnCfg.losGraceMs then M.release(uid, player, "out of sight")
                else
                    local other = steeredBy(uid, l)
                    if other == nil and now - (a.lastAssert or -1e12) >= M.attnCfg.reassertMs then
                        local left = M.attnHoldLeft(uid, player, now)
                        local want = a.untilMs - now
                        if left < math.min(want, M.attnCfg.holdSlackMs) or left < want - 4000 then
                            a.lastAssert = now
                            local ok, via = applyHold(l, player, want + M.attnCfg.holdSlackMs, now)
                            a.held = a.held or ok
                            M.listenLog("reassert " .. who(l) .. ": A-Life hold had " .. math.floor(left) .. " ms left, now " .. math.floor(want + M.attnCfg.holdSlackMs)
                                .. " ms via " .. tostring(via) .. (ok and "" or " - NOT held"), uid .. "|re", 4000)
                        else a.lastAssert = now end
                    end
                    -- still walking although held (some A-Life mover ignored the stop): stop the body itself
                    local moving = false
                    pcall(function() moving = sh.isMoving ~= nil and sh:isMoving() == true end)
                    if moving and other == nil then
                        a.movingSince = a.movingSince or now
                        if now - a.movingSince >= M.attnCfg.stuckMs then
                            stopBody(l)
                            a.movingSince = now
                            M.listenLog("still walking while held: " .. who(l) .. " - stopped the body", uid .. "|walk", 4000)
                        end
                    else a.movingSince = nil end
                    face(l, player)
                end
            end
        end
    end
end
function M.attnOnWords(player, text, loud, hearers)
    if M.settings.attention == false or hearers == nil then return end
    if #hearers == 0 then M.listenLog("you spoke but nobody heard you (no NPC in range)", "nohear", 15000) end
    for i, l in ipairs(hearers) do
        if i > 1 then break end -- the one you talk to
        M.attend(l, player, "talking")
    end
end
table.insert(M.playerWordHooks, 1, M.attnOnWords)
everyMs(M.attnCfg.tickMs, M.attnTick)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local pa, P = PA(), patch()
        M.listenLog("ready: attention=" .. tostring(M.settings.attention ~= false) .. " window=" .. tostring(M.settings.listenWindowSec) .. "s"
            .. " A-Life Talk.hold=" .. tostring(fn(pa.Talk, "hold")) .. " patch holdFriendly=" .. tostring(P ~= nil and fn(P, "holdFriendly"))
            .. " TalkPresence=" .. tostring(type(pa.ModuleTalkPresence) == "table"))
    end)
end
return M
