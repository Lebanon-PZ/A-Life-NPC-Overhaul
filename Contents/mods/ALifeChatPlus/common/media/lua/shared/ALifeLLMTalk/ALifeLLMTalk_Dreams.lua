-- A-Life Talk 0.5.1: DREAMS & NIGHTMARES, PTSD FLARE-UPS
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Dreams") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Dreams"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Dreams") end end -- 0.5.1.6 perf label
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Dreams", function()
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
setting("dreams", true)
M.dreamCfg = { chance = 30, nightmareBase = 10, flareGapMs = 1200000, traumaDecayH = 0.02, tick = 20000 }
M.dreamDone = {} -- uid -> day number

-- trauma 0..1 per NPC: bad fights (own HP low), deaths they saw, bites, turned friends
function M.traumaOf(uid)
    local t = bucket("trauma")[tostring(uid)]
    if type(t) ~= "table" then return 0, nil end
    local v = (tonumber(t.v) or 0) - math.max(0, hours() - (tonumber(t.h) or 0)) * M.dreamCfg.traumaDecayH
    if v <= 0 then bucket("trauma")[tostring(uid)] = nil; return 0, nil end
    return clamp(v, 0, 1), t.why
end
function M.addTrauma(uid, amount, why)
    if M.settings.dreams == false then return end
    local v = M.traumaOf(uid)
    local p = M.partsOf and M.partsOf(uid) or nil
    local k = p and p.core and p.core.key or ""
    local scale = (k == "haunted" or k == "coward" or k == "hollow" or k == "broken") and 1.5 or ((k == "stoic" or k == "hardass" or k == "cold") and 0.5 or 1)
    bucket("trauma")[tostring(uid)] = { v = clamp(v + amount * scale, 0, 1), h = hours(), why = why }
end

M.dreamLines = {
    nightmare = { "I was back there... they were eating him and I just watched.", "Dreamt the dead were knocking. All night. Knock, knock.",
        "I keep seeing {who}'s face. Every time I close my eyes.", "Woke up screaming. Sorry if I scared anyone." },
    good = { "Dreamt about the beach. Sun, cold beer. No dead.", "I was home. Mom was cooking. Felt so real.", "Had a dream it was all over. Helicopters, soldiers, the works." },
    odd = { "Dreamt my teeth fell out. Then I was a dog.", "I dreamed the radio talked back to me. Said my name.", "Weird one. I was swimming in cereal." },
}
function M.dreamFor(uid, l)
    local trauma, why = M.traumaOf(uid)
    local grief = 0
    local who = nil
    if M.griefOf then
        for _, e in pairs(M.griefOf(uid)) do
            if type(e) == "table" and M.griefIntensity then local ok, i = pcall(M.griefIntensity, e); if ok and tonumber(i) and i > grief then grief, who = i, e.n end end
        end
    end
    local nm = M.dreamCfg.nightmareBase + trauma * 60 + grief * 40
    local r = hash(uid .. "#dream#" .. math.floor(hours() / 24)) % 100
    local kind = r < nm and "nightmare" or (r < nm + 25 and "odd" or "good")
    local line = pick(M.dreamLines[kind], uid .. math.floor(hours()))
    if who then line = string.gsub(line, "{who}", who) else line = string.gsub(line, "{who}'s", "his") end
    return kind, line, why, who
end

function M.onWoke(uid, l, player)
    if M.settings.dreams == false then return end
    local day = math.floor(hours() / 24)
    if M.dreamDone[uid] == day then return end
    M.dreamDone[uid] = day
    if (hash(uid .. "#dreamroll#" .. day) % 100) >= M.dreamCfg.chance + M.traumaOf(uid) * 40 then return end
    local kind, line, why, who = M.dreamFor(uid, l)
    if kind == "nightmare" then
        if M.feel then M.feel(uid, "fear", 0.3, "a nightmare"); M.feel(uid, "anxiety", 0.3, "a nightmare") end
        local P = patch()
        if P and fn(P, "gesture") then pcall(P.gesture, uid, "spooked") end
    elseif kind == "good" and M.feel then M.feel(uid, "hope", 0.2, "a good dream") end
    if M.keyMem then pcall(M.keyMem, uid, "dream", "Had a " .. kind .. ": " .. line) end
    if M.logInteraction then pcall(M.logInteraction, uid, "Woke up from a " .. kind, nil, nil, "event") end
    speak(l, player, "dream", "You just woke up from a " .. kind .. (who and (" about " .. who) or "") .. (why and (" (still shaken by " .. why .. ")") or "")
        .. ". Describe it in one short line", line, { keyMs = 3600000 })
    log("dream: " .. uid .. " " .. kind)
end

-- PTSD flare-up: trauma + a trigger (gunfire, zombies close, a scream) -> shaking, dread, clipped speech
M.flareAt = {}
function M.ptsdFlare(uid, l, player, trigger)
    local now = nowMs()
    if now - (M.flareAt[uid] or -1e12) < M.dreamCfg.flareGapMs then return false end
    local t = M.traumaOf(uid)
    if t < 0.3 then return false end
    M.flareAt[uid] = now
    if M.feel then M.feel(uid, "dread", 0.3 + t * 0.4, "a flashback") end
    local P = patch()
    if P and fn(P, "gesture") then pcall(P.gesture, uid, "shiver") end
    local lines = { "No, no, no - not again...", "I can't... I can't breathe...", "Get down! Get - sorry. Sorry.", "It's happening again..." }
    speak(l, player, "dream", "A flashback hits you (" .. tostring(trigger) .. "); you're back in the worst fight of your life", pick(lines, uid .. now), { keyMs = 600000, urgent = true })
    log("ptsd flare: " .. uid .. " (" .. tostring(trigger) .. ")")
    return true
end

-- sources of trauma
if type(Events) == "table" and type(Events.ProjectALife_NpcHit) == "table" and type(Events.ProjectALife_NpcHit.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcHit, "ALifeLLMTalk_Dreams", function(body, attacker, damage)
        pcall(function()
            local uid = M.uidOf and M.uidOf(body)
            if uid == nil then return end
            local hp = 100
            pcall(function() hp = PA().Health.hpPercent(body) end)
            if tonumber(hp) and hp < 45 then M.addTrauma(uid, 0.25, "nearly dying in a fight") end
        end)
    end)
end
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Dreams", function(body, uid, killer)
        pcall(function()
            local x, y, z = pos(body)
            for _, l in ipairs(M.nearbyNpcs and x and M.nearbyNpcs(x, y, z, 15, uid) or {}) do
                local w = M.closeness and select(1, M.closeness(tostring(l.record.uid), tostring(uid))) or 0
                M.addTrauma(tostring(l.record.uid), 0.1 + w * 0.4, "watching " .. firstOf(rec(uid)) .. " die")
            end
        end)
    end)
end
-- wake-ups: an activity "sleep" that ended, or morning (6-9) for NPCs around you once a day
M.wasAsleep = {}
function M.dreamTick(now)
    if M.settings.dreams == false then return end
    local near, player = nearPlayer(30)
    if player == nil then return end
    local hour = 12
    pcall(function() hour = getGameTime():getHour() end)
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        local a = M.activities and M.activities[uid]
        local asleep = a ~= nil and a.kind == "sleep"
        if M.wasAsleep[uid] and not asleep and idleOk(l, now) then M.onWoke(uid, l, player) end
        M.wasAsleep[uid] = asleep or nil
        if hour >= 6 and hour <= 9 and idleOk(l, now) and (hash(uid .. "#morning#" .. math.floor(hours() / 24)) % 6 == 0) then M.onWoke(uid, l, player) end
        -- flare triggers: zombies close or a gunshot in the last 10 s
        local P = patch()
        local x, y = pos(l.shell)
        local zs = (P and fn(P, "zombiesNear") and x) and P.zombiesNear(x, y, 6) or 0
        local shot = M.lastGunshotAt and now - M.lastGunshotAt < 10000
        if (zs >= 3 or shot) and M.traumaOf(uid) >= 0.3 then M.ptsdFlare(uid, l, player, shot and "gunfire" or "the dead up close") end
    end
end
if type(M.addSound) == "function" and not M._dreamSoundWrapped then
    M._dreamSoundWrapped = true
    local orig = M.addSound
    M.addSound = function(kind, ...)
        if kind == "gunshot" or kind == "explosion" then M.lastGunshotAt = nowMs() end
        return orig(kind, ...)
    end
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local t, why = M.traumaOf(tostring(listener.record.uid))
    if t >= 0.3 then req.ptsd = { level = math.floor(t * 100), why = why, flare = now - (M.flareAt[tostring(listener.record.uid)] or -1e12) < 60000 } end
end)
regMode("dream")
everyMs(M.dreamCfg.tick, M.dreamTick)
return M
