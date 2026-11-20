-- A-Life Talk 0.5.1.7: GRUDGES AND REVENGE, by personality (people book entry e.grudge)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Grudge") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Grudge"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Grudge") end end
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
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
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
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
M.spokeAt = M.spokeAt or {}
-- one line: the AI (react mode) with a canned fallback
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    if l == nil or l.record == nil then return false end
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid) .. (opts.sub and (":" .. opts.sub) or "")
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 8000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 16,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say and l.shell then M.say(l.shell, player, fallback, { record = l.record }) end
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
    if x == nil then return {}, player end
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    local uid = tostring(l.record.uid)
    if M.isPaused and M.isPaused(uid) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Grudge", function()
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
local function lensOf(uid) local ok, l = pcall(function() return M.lens and M.lens(uid) or {} end); return ok and type(l) == "table" and l or {} end
local function keyOf(uid) local ok, k = pcall(function() local p = M.partsOf and M.partsOf(uid) or nil; return p and p.core and p.core.key or "" end); return ok and tostring(k or "") or "" end
local function modsOf(uid) local ok, m = pcall(function() return M.personaMods and M.personaMods(uid) or {} end); return ok and type(m) == "table" and m or {} end
local function opinionOf(uid, player)
    local r = rec(uid)
    local pa = PA()
    if r and player and fn(pa.NpcOpinion, "valueOf") then
        local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
        if ok and tonumber(v) then return tonumber(v) end
    end
    local e = bucket("book")[tostring(uid)]
    if type(e) == "table" and tonumber(e.value) then return tonumber(e.value) end
    return nil
end
local function opAdj(uid, player, d, why)
    local r = rec(uid)
    if r == nil or player == nil or d == 0 then return false end
    local pa = PA()
    local f = M.origAdjust or (pa.NpcOpinion and pa.NpcOpinion.adjust)
    if type(f) ~= "function" then return false end
    return pcall(f, r, player, d, why)
end
local function listenerOf(uid)
    local pa = PA()
    local r = rec(uid)
    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil
    if r == nil or sh == nil then return nil end
    return { record = r, shell = sh }
end
local function distTo(l, player)
    local x, y = pos(l and l.shell); local px, py = pos(player)
    if x == nil or px == nil then return 1e9 end
    return math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
end

----------------------------------------------------------------------------------------------------------------
-- grudges and revenge, by personality. Kill / rob / betray someone's friend, family, partner or faction mate:
-- the survivors hold a grudge sized by how close they were and who they are. Hotheads / the vengeful / the loyal
-- confront, track or ambush you (A-Life revenge squads through the nemesis layer); cowards avoid you and spread the
-- word; the forgiving let it go. Grudges fade, or get settled by talk, payback or an apology.
-- Lives in the people book entry (e.grudge), so it keeps going while they are far away.
----------------------------------------------------------------------------------------------------------------
setting("grudges", true)
M.grudgeCfg = { minW = 0.2, maxSurvivors = 30, revengeAt = 50, confrontAt = 25, avoidAt = 15, confrontCdH = 6, avoidCdH = 3,
    decayDay = 3, tickMs = 12000, nearTiles = 14 }
M.grudgeStyleMul = { revenge = 1.2, confront = 1.0, avoid = 0.9, forgive = 0.6 }
M.grudgeDecayMul = { revenge = 0.4, confront = 1.0, avoid = 1.3, forgive = 3.5 }

function M.grudgeOf(uid)
    local e = bucket("book")[tostring(uid)]
    local g = type(e) == "table" and e.grudge or nil
    if type(g) == "table" and not g.settled and (tonumber(g.v) or 0) > 0 then return g end
    return nil
end
function M.grudgeLevel(uid)
    if M.settings.grudges == false then return 0 end
    local g = M.grudgeOf(uid)
    return g and math.floor(tonumber(g.v) or 0) or 0
end
-- style from the personality (lens 0..1 values + persona mods)
function M.grudgeStyle(uid)
    local l, m, k = lensOf(uid), modsOf(uid), keyOf(uid)
    local forgive = tonumber(m.forgive) or 0.5
    local s = {
        revenge = (l.mean or 0) + (l.loyal or 0) * 0.8 + (l.proud or 0) * 0.5 + (l.unhinged or 0) * 0.6 + (1 - forgive) * 0.8,
        confront = (l.volatile or 0) * 1.2 + (l.brave or 0) * 0.6 + (l.proud or 0) * 0.3,
        avoid = (l.fearful or 0) * 1.6 + (l.paranoid or 0) * 0.4,
        forgive = (l.kind or 0) + (l.devout or 0) * 0.8 + (l.calm or 0) * 0.8 + forgive * 0.9,
    }
    if k == "hothead" then s.confront = s.confront + 0.6 end
    if k == "coward" or k == "timid" then s.avoid = s.avoid + 0.8 end
    if k == "gentle" or k == "saint" then s.forgive = s.forgive + 0.6 end
    local best, bv = "confront", -1
    for _, name in ipairs({ "revenge", "confront", "avoid", "forgive" }) do if s[name] > bv then best, bv = name, s[name] end end
    return best, s
end
M.grudgeWords = { revenge = "out for revenge", confront = "wants it out with you", avoid = "keeps away from you", forgive = "trying to let it go" }
function M.grudgeWord(g)
    local v = tonumber(g and g.v) or 0
    if v < 20 then return "a bit sore" elseif v < 45 then return "resentful" elseif v < 70 then return "bitter" end
    return g.style == "avoid" and "afraid of you" or "out for blood"
end

function M.grudgeAdd(uid, amount, why, victim, kind)
    if M.settings.grudges == false or amount == nil or amount <= 0 then return nil end
    uid = tostring(uid)
    if M.isFinalDead and M.isFinalDead(uid) then return nil end
    local r = rec(uid)
    if r ~= nil and r.lifecycle == "dead" then return nil end
    local e = M.pb(uid, true)
    if e == nil then return nil end
    local g = type(e.grudge) == "table" and e.grudge or nil
    if g == nil or g.settled then g = { v = 0, h = hours() }; e.grudge = g end
    g.style = g.style or M.grudgeStyle(uid)
    local sev = M.bondSeverity and M.bondSeverity(uid) or 1 -- a betrayal from a close friend cuts deeper
    local add = amount * (M.grudgeStyleMul[g.style] or 1) * sev
    g.v = clamp((tonumber(g.v) or 0) + add, 0, 100)
    g.why, g.victim, g.kind, g.lastH, g.dayH = string.sub(tostring(why or "what you did"), 1, 80), victim, kind, hours(), g.dayH or hours()
    if M.histAdd then M.histAdd(uid, "grudge", "Holds a grudge: " .. g.why) end
    log("[Grudge] " .. nameOf(r) .. " +" .. math.floor(add) .. " -> " .. math.floor(g.v) .. " (" .. g.style .. ": " .. g.why .. ")")
    M.grudgeAct(uid, g)
    return g
end
-- the far-away part: revenge goes into the nemesis layer (A-Life revenge squads); avoiders spread the word
function M.grudgeAct(uid, g)
    if g.style == "revenge" or (g.style == "confront" and g.v >= 80) then
        if g.v >= M.grudgeCfg.revengeAt and M.addGrudge and (tonumber(g.sentV) or 0) < g.v - 10 then
            g.sentV = g.v
            M._grudgeFeed = true
            pcall(M.addGrudge, uid, g.v, g.why, ALifeSide.you())
            M._grudgeFeed = nil
        end
    elseif g.style == "avoid" and not g.spread and g.v >= M.grudgeCfg.avoidAt then
        g.spread = true
        if M.addDeed then
            local r = rec(uid)
            pcall(M.addDeed, "grudge", nameOf(r) .. " is telling people " .. (string.gsub(g.why, "^You ", "the newcomer ", 1)), -4, { uid }, nil, nil)
        end
    end
end
function M.grudgeSettle(uid, how)
    local e = bucket("book")[tostring(uid)]
    local g = type(e) == "table" and e.grudge or nil
    if type(g) ~= "table" or g.settled then return false end
    g.settled, g.settledH, g.v = how or "time", hours(), 0
    local txt = ({ apology = "Accepted your apology - grudge settled", payback = "Got even - grudge settled", talk = "Talked it out - grudge settled",
        time = "Let the grudge go" })[how] or "Let the grudge go"
    if M.histAdd then M.histAdd(uid, "grudge", txt) end
    if how ~= "payback" then
        local n = bucket("nemesis")[tostring(uid)]
        if type(n) == "table" then n.g = math.max(0, (tonumber(n.g) or 0) * 0.5) end
    end
    log("[Grudge] " .. tostring(uid) .. " settled (" .. tostring(how) .. ")")
    return true
end
function M.grudgeEase(uid, d, how)
    local g = M.grudgeOf(uid)
    if g == nil then return end
    g.v = math.max(0, g.v - d)
    if g.v < 5 then M.grudgeSettle(uid, how) end
end

-- trigger 1: you killed someone. Survivors: same group, same faction or a pair row (active AND far-away records)
local function sameGroup(a, b)
    local ma, mb = type(a.memory) == "table" and a.memory or {}, type(b.memory) == "table" and b.memory or {}
    return ma.groupId ~= nil and ma.groupId == mb.groupId
end
function M.grudgeOnDeath(body, uid, killer)
    if M.settings.grudges == false then return end
    local pa = PA()
    local victim = rec(uid)
    if victim == nil or not fn(pa.ActorRegistry, "each") then return end
    local player = ALifeSide.you()
    local kid = nil
    if M.killerOf then local _; _, kid = M.killerOf(killer, player, body) end
    if kid ~= "player" then return end
    if M.isInfectedVictim and M.isInfectedVictim(victim, body) then return end -- a mercy kill is not murder
    local vname = nameOf(victim)
    local count = 0
    pa.ActorRegistry.each(function(r)
        if count >= M.grudgeCfg.maxSurvivors then return true end
        if r.uid ~= victim.uid and r.lifecycle ~= "dead" then
            local grp = sameGroup(r, victim)
            local pairRow = M.pairKey and bucket("pairs")[M.pairKey(r.uid, victim.uid)] ~= nil
            local fac = r.factionId ~= nil and r.factionId == victim.factionId
            if grp or pairRow or fac then
                local w, t = 0, "stranger"
                if M.closeness then w, t = M.closeness(r.uid, victim.uid) end
                if grp then w = math.max(w, 0.35) end
                if fac then w = math.max(w, 0.2) end
                if w >= M.grudgeCfg.minW then
                    count = count + 1
                    local rel = (t ~= "stranger" and t ~= "acquaintance") and t or (grp and "groupmate" or "faction mate")
                    M.grudgeAdd(r.uid, 20 + 70 * w, "You killed " .. vname .. " (their " .. rel .. ")", vname, "kill")
                end
            end
        end
        return false
    end)
end
-- trigger 2: robbery / betrayal / hitting one of theirs (A-Life opinion events) - the victim and their close ties
M.grudgeAmounts = { ["You robbed them"] = 30, ["You broke a deal"] = 40, ["You hit one of theirs"] = 15 }
function M.grudgeFromBetrayal(uid, why)
    if M.settings.grudges == false then return end
    local amt = M.grudgeAmounts[why]
    if amt == nil then return end -- killings come through the death event
    local r = rec(uid)
    M.grudgeAdd(uid, amt, why, nil, "betray")
    if r == nil or not M.tiesOf then return end
    local ok, ties = pcall(M.tiesOf, uid, nil, 6, false)
    if not ok or type(ties) ~= "table" then return end
    local vname = nameOf(r)
    for _, t in ipairs(ties) do
        local w = M.closeness and M.closeness(t.uid, uid) or 0
        if t.uid and not t.dead and w >= 0.4 then M.grudgeAdd(t.uid, amt * w * 0.6, string.gsub(why, "them", vname), vname, "betray") end
    end
end
-- personality also shapes the old nemesis grudges: cowards and the forgiving don't swear revenge as easily
function M.grudgeInstall()
    if M._w517 == nil then M._w517 = {} end
    if not M._w517.addGrudge and type(M.addGrudge) == "function" then
        M._w517.addGrudge = true
        local orig = M.addGrudge
        M.addGrudge = function(uid, amount, why, player)
            if M.settings.grudges ~= false and not M._grudgeFeed and tonumber(amount) then
                local st = M.grudgeStyle(uid)
                if st == "avoid" then amount = amount * 0.5 elseif st == "forgive" then amount = amount * 0.4 end
            end
            return orig(uid, amount, why, player)
        end
    end
end

-- settling: payback (they hit you), talk (good conversations), time (daily decay)
function M.grudgeOnHit(wielder, target, weapon, damage)
    if M.settings.grudges == false then return end
    local player = ALifeSide.you()
    if player == nil or target ~= player or wielder == nil or wielder == player then return end
    local pa = PA()
    local uid = nil
    pcall(function() uid = pa.Speech.variable(wielder, "ALifeUID") end)
    if uid == nil or tostring(uid) == "" then return end
    local g = M.grudgeOf(uid)
    if g == nil then return end
    g.paid = (tonumber(g.paid) or 0) + 1
    g.v = math.max(0, g.v - (g.style == "revenge" and 12 or 20))
    if g.v < 10 then M.grudgeSettle(uid, "payback") end
end
function M.grudgeOnLog(uid, what, before, after, kind)
    if M.settings.grudges == false then return end
    if kind == "talk" and before and after and after > before then M.grudgeEase(uid, 1.5, "talk")
    elseif kind == "nemesis" and string.sub(tostring(what), 1, 21) == "Came back for revenge" then M.grudgeEase(uid, 15, "payback")
    elseif kind == "nemesis" and string.sub(tostring(what), 1, 18) == "Let the grudge go" then M.grudgeSettle(uid, "time") end
end
function M.grudgeDaily()
    local h = hours()
    for uid, e in pairs(bucket("book")) do
        local g = type(e) == "table" and e.grudge or nil
        if type(g) == "table" and not g.settled and (tonumber(g.v) or 0) > 0 then
            local days = math.floor((h - (tonumber(g.dayH) or h)) / 24)
            if days >= 1 then
                g.dayH = (tonumber(g.dayH) or h) + days * 24
                g.v = math.max(0, g.v - days * M.grudgeCfg.decayDay * (M.grudgeDecayMul[g.style] or 1))
                if g.v < 5 then M.grudgeSettle(uid, g.style == "forgive" and "time" or "time") end
            end
        end
    end
end

-- near you: confront (hotheads / the vengeful) or keep away (cowards). One line per cooldown; nothing while busy.
function M.grudgeTick(now)
    if M.settings.enabled == false or M.settings.grudges == false then return end
    if M.f517Install then pcall(M.f517Install) end
    local h = hours()
    if math.floor(h) ~= M.grudgeHour then M.grudgeHour = math.floor(h); M.grudgeDaily() end
    local near, player = nearPlayer(M.grudgeCfg.nearTiles)
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        local g = M.grudgeOf(uid)
        if g and idleOk(l, now) and bucket("party")[uid] == nil then
            local d = distTo(l, player)
            if (g.style == "confront" or g.style == "revenge") and g.v >= M.grudgeCfg.confrontAt and d <= 12 and h >= (tonumber(g.confH) or -1e9) then
                g.confH = h + M.grudgeCfg.confrontCdH
                M.histAdd(uid, "grudge", "Confronted you about it")
                speak(l, player, "grudge", "You see the newcomer - the one who did this: " .. g.why .. ". You haven't forgotten. Confront them, "
                    .. (g.style == "revenge" and "cold and threatening" or "angry") .. ".",
                    g.style == "revenge" and "I know what you did. I haven't forgotten." or "You've got some nerve showing your face here.", { keyMs = 0, sub = uid })
                return
            elseif g.style == "avoid" and g.v >= M.grudgeCfg.avoidAt and d <= 8 and h >= (tonumber(g.avH) or -1e9) then
                g.avH = h + M.grudgeCfg.avoidCdH
                -- they really keep away: A-Life's own flee order (TalkOrders.runAway: walks off, marks them wary of you)
                local pa = PA()
                if fn(pa.TalkOrders, "runAway") then g.fled = (tonumber(g.fled) or 0) + 1; pcall(pa.TalkOrders.runAway, l.record, l.shell, player, now, false) end
                speak(l, player, "grudge", "The newcomer who did this (" .. g.why .. ") is coming close. You're scared of them and want them gone. Keep it short.",
                    "Stay away from me. Please.", { keyMs = 0, sub = uid })
                return
            end
        end
    end
end

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.grudges == false then return end
    local g = M.grudgeOf(listener.record.uid)
    if g then req.grudge = { v = math.floor(g.v), why = g.why, style = g.style, word = M.grudgeWord(g) } end
end)

regMode("grudge")
everyMs(M.grudgeCfg.tickMs, M.grudgeTick)
if type(Events) == "table" then
    if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Grudge", function(body, uid, killer) pcall(M.grudgeOnDeath, body, uid, killer) end)
    end
    if type(Events.OnWeaponHitCharacter) == "table" and type(Events.OnWeaponHitCharacter.Add) == "function" then
        ALifeHealth.add(Events.OnWeaponHitCharacter, "ALifeLLMTalk_Grudge", function(a, b, c, d) pcall(M.grudgeOnHit, a, b, c, d) end)
    end
end
