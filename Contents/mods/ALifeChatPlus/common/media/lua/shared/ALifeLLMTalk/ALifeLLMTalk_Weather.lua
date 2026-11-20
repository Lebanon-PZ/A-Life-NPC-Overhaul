-- A-Life Talk 0.5.1: WEATHER & SEASON TALK (ClimateManager; every call guarded inside M.climate in Activity.lua)
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Weather") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Weather"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Weather") end end -- 0.5.1.6 perf label
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
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur == nil then -- MP: the first online player with people near
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Weather", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("weatherTalk", true)
M.wxCfg = { tick = 60000, gapMs = 900000 }
M.wxState = { prev = nil, coldDays = 0, lastTalk = -1e12, lastDay = nil }
M.wxLines = {
    snow = { "Snow. Great. Now they leave tracks and so do we.", "First snow... it's beautiful, almost." },
    deepcold = { "I can't feel my fingers.", "This cold's gonna kill more of us than the dead.", "Keep the fire going, whatever it takes." },
    rain = { "Rain's good - covers the noise.", "Soaked to the bone again.", "At least we can fill the barrels." },
    fog = { "Can't see ten feet in this fog.", "Fog like this... they could be anywhere.", "I hate the fog. Hate it." },
    storm = { "Storm's coming. Board up, grab what you can.", "Get everything inside - storm's rolling in!", "Gonna be a bad one tonight." },
    thaw = { "It's warming up! Feel that?", "Thaw's here. We made it through the winter.", "Snow's melting. Never thought I'd see spring again." },
    heat = { "It's an oven out here.", "The smell gets worse in the heat." },
}
function M.weatherEvent(c, st)
    local ev = nil
    if c.storm and not (st.prev and st.prev.storm) then ev = "storm"
    elseif c.snow > 0.2 and not (st.prev and st.prev.snow > 0.2) then ev = "snow"
    elseif c.temp < -5 and not (st.prev and st.prev.temp < -5) then ev = "deepcold"
    elseif c.fog > 0.5 and not (st.prev and st.prev.fog > 0.5) then ev = "fog"
    elseif c.rain > 0.4 and not (st.prev and st.prev.rain > 0.4) then ev = "rain"
    elseif c.temp > 30 and not (st.prev and st.prev.temp > 30) then ev = "heat"
    elseif c.temp > 4 and st.coldDays >= 2 then ev = "thaw"; st.coldDays = 0 end
    return ev
end
function M.weatherTick(now)
    if M.settings.weatherTalk == false or not M.worldHere() then return end
    local c = M.climate and M.climate() or nil
    if c == nil then return end
    local st = M.wxState
    local day = math.floor(hours() / 24)
    if st.lastDay ~= day then
        st.lastDay = day
        if c.temp < 0 then st.coldDays = st.coldDays + 1 elseif c.temp > 4 and st.coldDays < 2 then st.coldDays = 0 end
    end
    local ev = M.weatherEvent(c, st)
    st.prev = c
    if ev == nil or now - st.lastTalk < (ev == "storm" and 120000 or M.wxCfg.gapMs) then return ev end
    local near, player = nearPlayer(25)
    local speaker = nil
    for _, l in ipairs(near) do if idleOk(l, now) then speaker = l; break end end
    if speaker == nil then return ev end
    st.lastTalk = now
    local uid = tostring(speaker.record.uid)
    local fb = pick(M.wxLines[ev], uid .. day)
    speak(speaker, player, "weather", "The weather just turned: " .. ev .. " (" .. math.floor(c.temp) .. " C" .. (c.season and (", " .. c.season) or "") .. "). React to it", fb, { keyMs = 600000 })
    if ev == "thaw" and M.feel then for _, l in ipairs(near) do M.feel(tostring(l.record.uid), "hope", 0.25, "the thaw") end end
    if ev == "deepcold" and M.feel then for _, l in ipairs(near) do M.feel(tostring(l.record.uid), "despair", 0.1, "the deep cold") end end
    -- storms: prepare (barricade if sheltering, else hoard / scavenge) through the activity layer
    if ev == "storm" and M.startActivity then
        for i, l in ipairs(near) do
            if i > 4 then break end
            local m = type(l.record.memory) == "table" and l.record.memory or {}
            if idleOk(l, now) then pcall(M.startActivity, l, m.shelterBuildingId ~= nil and "barricade" or "scavenge", now) end
        end
    end
    log("weather talk: " .. ev)
    return ev
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local c = M.wxState.prev
    if c then req.weather2 = { temp = math.floor(c.temp), rain = c.rain > 0.3, snow = c.snow > 0.2, fog = c.fog > 0.4, storm = c.storm, season = c.season } end
end)
regMode("weather")
everyMs(M.wxCfg.tick, M.weatherTick)
return M
