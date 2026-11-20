-- A-Life Talk 0.5.1.7: CHANGING OVER MONTHS - harden / crack / go feral by personality; care pulls them back (people book e.change)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Change") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Change"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Change") end end
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Change", function()
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
-- changing over months: trauma and experience pile up; depending on who they are, people harden, crack or go
-- feral. Slow (a couple of percent a day at most), visible in the Personality page (the trait ring shifts, a line
-- under QUIRKS), and care / company pulls them back. One pass per in-game day over the people book (no per-tick work).
----------------------------------------------------------------------------------------------------------------
setting("changeOverTime", true)
M.changeCfg = { maxStep = 0.02, careStep = 0.03, minPressure = 8, trDecay = 0.985, exDecay = 0.99, careDecay = 0.9, careNeed = 4 }
M.changeLabels = {
    hardened = { "a little harder", "hardened", "hard as nails" },
    cracking = { "frayed", "cracking", "falling apart" },
    feral = { "wild-eyed", "going feral", "feral" },
    raging = { "on edge", "seething", "consumed by rage" }, -- 0.5.2.7: a loss turned to anger (Loss.lua)
}
M.changeLines = {
    hardened = { "Getting harder out here", "Hardened by months out here", "Nothing gets to them any more" },
    cracking = { "Starting to fray", "Cracking under it all", "Falling apart" },
    feral = { "Something wild in the eyes", "Going feral", "More animal than person now" },
    raging = { "Angry at everything since", "Seething, looking for someone to blame", "Nothing left but rage" },
}
-- how each state bends the trait ring (multiplier per unit of degree)
M.changeShift = {
    hardened = { brave = 0.9, calm = 0.6, mean = 0.4, kind = -0.5, fearful = -0.6, cheerful = -0.5, romantic = -0.4 },
    cracking = { fearful = 1.0, gloomy = 1.0, paranoid = 0.5, brave = -0.5, calm = -0.6, cheerful = -0.6 },
    feral = { unhinged = 1.2, mean = 0.8, volatile = 0.8, kind = -0.7, disciplined = -0.6, calm = -0.6 },
    raging = { volatile = 1.1, mean = 0.6, brave = 0.4, kind = -0.6, calm = -0.8, cheerful = -0.6, romantic = -0.3 },
}
local function cs(uid, create)
    local e = M.pb(uid, create)
    if e == nil then return nil end
    if type(e.change) ~= "table" then
        if not create then return nil end
        e.change = { tr = 0, ex = 0, care = 0, deg = 0, state = "steady", day = math.floor(hours() / 24), stage = 0 }
    end
    return e.change
end
M.changeOf = function(uid) return cs(uid, false) end
-- inputs: trauma (bad things), experience (danger survived), care (gifts, talks, company, healing)
function M.changeNote(uid, kind, amount, info)
    if M.settings.changeOverTime == false then return end
    local c = cs(uid, true)
    if c == nil then return end
    amount = tonumber(amount) or 1
    if kind == "trauma" then c.tr = math.min(200, c.tr + amount)
    elseif kind == "witness" then c.tr = math.min(200, c.tr + amount * 2); c.ex = math.min(200, c.ex + amount)
    elseif kind == "danger" then c.ex = math.min(200, c.ex + amount); c.tr = math.min(200, c.tr + amount * 0.3)
    elseif kind == "care" then c.care = math.min(40, c.care + amount)
    elseif kind == "loss" and M.lossNote then M.lossNote(uid, c, amount, info) end -- 0.5.2.7 [pt255u] (Loss.lua)
end
function M.changeOnLog(uid, what, before, after, kind)
    if M.settings.changeOverTime == false then return end
    what = tostring(what or "")
    if kind == "bond" and string.sub(what, 1, 9) == "Survived " then M.changeNote(uid, "danger", 3)
    elseif kind == "wound" and string.sub(what, 1, 5) == "Hurt:" then M.changeNote(uid, "trauma", 2)
    elseif kind == "wound" and string.sub(what, 1, 12) == "You gave the" then M.changeNote(uid, "care", 3)
    elseif (kind == "gift" or string.sub(what, 1, 9) == "You gave ") and M.lossComfort then pcall(M.lossComfort, uid, 2.5, "gift")
    elseif kind == "talk" and before and after and after >= before then
        M.changeNote(uid, "care", 0.5)
        if M.lossComfort then pcall(M.lossComfort, uid, 1.5, "talk") end -- 0.5.2.7: comforting a grieving person counts more
    elseif kind == "opinion" and string.find(what, "patched", 1, true) then M.changeNote(uid, "care", 2)
    elseif kind == "event" and string.sub(what, 1, 6) == "Heard " then M.changeNote(uid, "trauma", 3) end
end
-- which way this personality bends under pressure (base personality: the unchanged chart)
function M.changeTarget(uid, c)
    local l = {}
    M._changeRaw = true
    l = lensOf(uid)
    M._changeRaw = nil
    local k = keyOf(uid)
    local s = {
        hardened = (l.brave or 0) + (l.disciplined or 0) + (l.proud or 0) * 0.5 + (l.calm or 0) * 0.4 + (l.mean or 0) * 0.3,
        cracking = (l.fearful or 0) + (l.gloomy or 0) + (l.kind or 0) * 0.5 + (l.romantic or 0) * 0.4 + (l.cheerful or 0) * 0.3,
        feral = (l.unhinged or 0) * 1.5 + (l.mean or 0) + (l.volatile or 0) * 0.5,
    }
    if k == "stoic" or k == "cold" or k == "brave" or k == "hardass" then s.hardened = s.hardened + 0.4 end
    if k == "coward" or k == "broken" or k == "haunted" or k == "depressive" then s.cracking = s.cracking + 0.4 end
    if k == "cruel" or k == "unhinged" or k == "arsonist" then s.feral = s.feral + 0.4 end
    -- going feral needs real damage and nobody there for them
    if c.tr < 30 or c.care >= M.changeCfg.careNeed then s.feral = s.feral * 0.3 end
    local best, bv = "hardened", -1
    for _, name in ipairs({ "hardened", "cracking", "feral" }) do if s[name] > bv then best, bv = name, s[name] end end
    local pressure = c.tr + c.ex * 0.35
    local want = 0
    if pressure >= M.changeCfg.minPressure then want = clamp((pressure - c.care * 1.5) / 80, 0, 1) end
    -- 0.5.2.7 [pt255u]: a fresh loss decides the direction (who they are + how they grieve) and how far it goes
    if M.lossTarget and type(c.loss) == "table" and M.settings.partnerLossTrauma ~= false then
        local lb, lw = M.lossTarget(uid, c)
        if lb then best = lb; want = math.max(want * 0.5, lw) end
    end
    return best, want, pressure
end
local function stageOf(deg) if deg >= 0.7 then return 3 elseif deg >= 0.4 then return 2 elseif deg >= 0.15 then return 1 end return 0 end
-- one in-game day for one person
function M.changeDay(uid, c, days)
    days = math.max(1, math.min(30, days or 1))
    for _ = 1, days do
        local target, want = M.changeTarget(uid, c)
        local step = M.changeCfg.maxStep
        if M.lossStep then step = M.lossStep(uid, c, step) end -- 0.5.2.7: a fresh loss moves faster
        if c.state ~= "steady" and c.state ~= target and c.deg > 0 then
            c.deg = math.max(0, c.deg - step) -- turning around: unwind first
            if c.deg <= 0 then c.state = "steady" end
        elseif c.deg < want then
            if c.state == "steady" then c.state = target end
            c.deg = math.min(want, c.deg + step)
        elseif c.deg > want then
            c.deg = math.max(want, c.deg - step * 0.5)
        end
        -- care pulls them back (on top)
        if c.care >= M.changeCfg.careNeed and c.deg > 0 then c.deg = math.max(0, c.deg - math.min(M.changeCfg.careStep, c.care / 400)) end
        if c.deg <= 0 then c.deg, c.state = 0, "steady" end
        if M.lossDay then pcall(M.lossDay, uid, c) end -- 0.5.2.7: the grief fades (faster with people around / care)
        c.tr, c.ex, c.care = c.tr * M.changeCfg.trDecay, c.ex * M.changeCfg.exDecay, c.care * M.changeCfg.careDecay
    end
    local st = stageOf(c.deg)
    if st ~= (c.stage or 0) then
        local up = st > (c.stage or 0)
        if c.state ~= "steady" and st > 0 then
            M.histAdd(uid, "change", (up and "" or "Coming back a little: ") .. M.changeLines[c.state][st])
        elseif not up then
            M.histAdd(uid, "change", "Coming back to themselves")
        end
        c.stage = st
        c.sinceDay = math.floor(hours() / 24)
    end
end
function M.changeDaily()
    if M.settings.changeOverTime == false then return end
    local day = math.floor(hours() / 24)
    for uid, e in pairs(bucket("book")) do
        local c = type(e) == "table" and not e.dead and e.change or nil
        if type(c) == "table" then
            local last = tonumber(c.day) or day
            if day > last then c.day = day; M.changeDay(uid, c, day - last) end
        end
    end
end
function M.changeWord(uid)
    local c = cs(uid, false)
    if c == nil or c.state == "steady" or stageOf(c.deg or 0) == 0 then return nil end
    return M.changeLabels[c.state][stageOf(c.deg)], M.changeLines[c.state][stageOf(c.deg)], c
end

function M.changeInstall()
    if M._w517 == nil then M._w517 = {} end
    local W = M._w517
    if not W.addTrauma and type(M.addTrauma) == "function" then
        W.addTrauma = true
        local orig = M.addTrauma
        M.addTrauma = function(uid, amount, why)
            if uid ~= nil then pcall(M.changeNote, uid, "trauma", (tonumber(amount) or 0.2) * 12) end
            return orig(uid, amount, why)
        end
    end
    -- the trait ring shifts (and with it the lens every system reads)
    if not W.traitChart and type(M.traitChart) == "function" then
        W.traitChart = true
        local orig = M.traitChart
        M.traitChart = function(uid, limit)
            if M.settings.changeOverTime == false or M._changeRaw then return orig(uid, limit) end
            local e = bucket("book")[tostring(uid)]
            local c = type(e) == "table" and e.change or nil
            if type(c) ~= "table" or c.state == "steady" or (tonumber(c.deg) or 0) < 0.05 then return orig(uid, limit) end
            limit = limit or 5
            local out = orig(uid, limit + 3)
            local sh = M.changeShift[c.state] or {}
            local total = 0
            for _, x in ipairs(out) do
                local m = sh[x.key]
                if m then
                    x.w = math.max(0.01, (x.w or x.pct or 1) * (1 + m * c.deg))
                    x.tip = tostring(x.tip or "") .. " (" .. (m > 0 and "grown" or "faded") .. ": " .. tostring(M.changeLabels[c.state][math.max(1, stageOf(c.deg))]) .. ")"
                    x.changed = m > 0 and 1 or -1
                end
            end
            table.sort(out, function(a, b) if a.w == b.w then return a.key < b.key end return a.w > b.w end)
            while #out > limit do table.remove(out) end
            for _, x in ipairs(out) do total = total + x.w end
            if total <= 0 then return out end
            local sum = 0
            for _, x in ipairs(out) do x.pct = math.floor(x.w / total * 100); sum = sum + x.pct end
            local i = 1
            while sum < 100 and #out > 0 do out[i].pct = out[i].pct + 1; sum = sum + 1; i = i % #out + 1 end
            return out
        end
    end
    -- behaviour: hardened shrug off fear, cracking people scare easily, feral ones lash out and don't forgive
    if not W.personaMods and type(M.personaMods) == "function" then
        W.personaMods = true
        local orig = M.personaMods
        M.personaMods = function(uid)
            local m = orig(uid)
            if M.settings.changeOverTime == false or type(m) ~= "table" then return m end
            local e = bucket("book")[tostring(uid)]
            local c = type(e) == "table" and e.change or nil
            local lossOn = type(c) == "table" and type(c.loss) == "table" and (tonumber(c.loss.alone) or 0) > 0
            if type(c) ~= "table" or ((c.state == "steady" or (tonumber(c.deg) or 0) < 0.05) and not lossOn) then return m end
            local o = {}
            for k, v in pairs(m) do o[k] = v end
            local d = c.deg
            local function adj(k, f) if tonumber(o[k]) then o[k] = clamp(o[k] * f, 0, 2) end end
            if c.state == "hardened" then adj("fear", 1 - 0.5 * d); adj("forgive", 1 - 0.3 * d); adj("pos", 1 - 0.2 * d)
            elseif c.state == "cracking" then adj("fear", 1 + 0.6 * d); adj("neg", 1 + 0.2 * d)
            elseif c.state == "feral" then adj("neg", 1 + 0.5 * d); adj("forgive", 1 - 0.6 * d); adj("fear", 1 - 0.4 * d); adj("pos", 1 - 0.3 * d)
            elseif c.state == "raging" then adj("neg", 1 + 0.6 * d); adj("forgive", 1 - 0.7 * d); adj("fear", 1 - 0.3 * d) end
            if type(c.loss) == "table" and (tonumber(c.loss.alone) or 0) > 0 then adj("fear", 1 + 0.4 * c.loss.alone) end -- afraid of losing anyone else
            return o
        end
    end
    -- the Personality page: a line under QUIRKS
    if not W.personalityData and type(M.personalityData) == "function" then
        W.personalityData = true
        local orig = M.personalityData
        M.personalityData = function(uid, player)
            local d = orig(uid, player)
            if M.settings.changeOverTime == false or type(d) ~= "table" then return d end
            local _, line, c = M.changeWord(uid)
            if line then
                d.quirks = type(d.quirks) == "table" and d.quirks or {}
                table.insert(d.quirks, 1, line)
                while #d.quirks > 2 do table.remove(d.quirks) end
                d.change = { state = c.state, deg = c.deg, line = line }
            end
            return d
        end
    end
end

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.changeOverTime == false then return end
    local word, line, c = M.changeWord(listener.record.uid)
    if word then req.change = { state = c.state, word = word, line = line } end
    if M.lossPrompt then pcall(M.lossPrompt, req, listener.record.uid) end -- 0.5.2.7: the grieving undertone
end)

everyMs(60000, function(now)
    if M.settings.enabled == false then return end
    if M.f517Install then pcall(M.f517Install) end
    local day = math.floor(hours() / 24)
    if day ~= M.changeDayNo then M.changeDayNo = day; M.changeDaily() end
end)
-- deaths nearby mark everyone who saw it (cheap: only loaded people near the body)
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Change", function(body, uid, killer)
        if M.settings.changeOverTime == false then return end
        pcall(function()
            local bx, by = pos(body)
            if bx == nil then return end
            local near = nearPlayer(40)
            for _, l in ipairs(near) do
                local u = tostring(l.record.uid)
                local x, y = pos(l.shell)
                if u ~= tostring(uid) and x and (x - bx) ^ 2 + (y - by) ^ 2 <= 400 and bucket("book")[u] ~= nil then M.changeNote(u, "witness", 2) end
            end
        end)
    end)
end
