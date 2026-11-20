-- A-Life Talk 0.4.0: AI-written Knox County Radio bulletins from real events.
--
-- Our events (deaths, bites, fires, hordes, wrecks, nemesis sightings) are collected as short reports (ModData bucket
-- "news"). Every few game hours, while nobody is talking, the bridge writes a 2-4 sentence bulletin from them
-- (background model). It airs on A-Life's own Knox County Radio channel (default 99.6 MHz): Radio.OnEveryHour is
-- wrapped - when a bulletin is ready and the channel is free, ours airs that hour instead of a canned segment;
-- otherwise A-Life's original runs unchanged. If the AI is offline, a plain template bulletin is used.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_News") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "News"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("News") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end

M.newsSettings = { everyHours = 3, minEvents = 2, staleHours = 48, keep = 30, maxInBulletin = 6 }

local function bucket()
    local data = M.store()
    data.news = type(data.news) == "table" and data.news or {}
    local n = data.news
    n.events = type(n.events) == "table" and n.events or {}
    return n
end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end

function M.townAt(x, y)
    local pa = PA()
    if x == nil then return nil end
    if pa and fn(pa.KnoxRadio, "townOf") then
        local ok, t = pcall(pa.KnoxRadio.townOf, x, y)
        if ok and t then return t end
    end
    if pa and fn(pa.Speech, "nearestTown") then
        local ok, t = pcall(pa.Speech.nearestTown, x, y)
        if ok and t then return t end
    end
    return nil
end

function M.newsNote(kind, text, x, y)
    if M.settings.radioNews == false or type(text) ~= "string" or text == "" then return end
    local n = bucket()
    local town = M.townAt(x, y)
    local line = text .. (town and (" near " .. town) or "")
    for i = #n.events, math.max(1, #n.events - 6), -1 do
        if n.events[i].x == line then return end
    end
    n.events[#n.events + 1] = { k = kind, x = line, h = hours() }
    while #n.events > M.newsSettings.keep do table.remove(n.events, 1) end
end

-- reports from our event pipeline: wrap M.submit for memory events (deaths, bites, fires, hordes, wrecks)
function M.newsFromEvent(ev)
    if type(ev) ~= "table" then return end
    local kind = tostring(ev.kind or "event")
    if kind == "death" then
        local who = ev.killerUid == "player" and (#(ev.witnesses or {}) > 0 and "a stranger" or "someone unknown")
            or (ev.killer == "zombies or something unseen" and "the dead" or "another survivor")
        M.newsNote("death", tostring(ev.victim or "a survivor") .. " was killed by " .. who, ev.x, ev.y)
    elseif type(ev.what) == "string" then
        local what = ev.what
        what = string.gsub(what, "the player", "a stranger")
        M.newsNote(kind, what, ev.x, ev.y)
    end
end
if type(M.submit) == "function" and not M._newsWrapped then
    local orig = M.submit
    M.submit = function(job)
        if type(job) == "table" and job.mode == "event" and type(job.event) == "table" then pcall(M.newsFromEvent, job.event) end
        return orig(job)
    end
    M._newsWrapped = true
end

----------------------------------------------------------------------------------------------------------------
-- writing the bulletin
----------------------------------------------------------------------------------------------------------------
function M.newsPick()
    local n = bucket()
    local h = hours()
    local out = {}
    for i = #n.events, 1, -1 do
        local e = n.events[i]
        if not e.aired and h - (tonumber(e.h) or 0) <= M.newsSettings.staleHours then table.insert(out, 1, e) end
        if #out >= M.newsSettings.maxInBulletin then break end
    end
    return out
end

function M.templateBulletin(events)
    local parts = { "Knox County Radio, survivor bulletin." }
    for i, e in ipairs(events) do
        if i > 3 then break end
        parts[#parts + 1] = "Word is " .. e.x .. "."
    end
    parts[#parts + 1] = "Stay off the main roads after dark, and keep your water boiled."
    return table.concat(parts, " ")
end

function M.newsRequest(job, now)
    local pa = PA()
    local clock = fn(pa.Speech, "clock") and pa.Speech.clock() or {}
    local list = {}
    local kinds = {}
    for _, e in ipairs(job.events or {}) do list[#list + 1] = e.x; kinds[#kinds + 1] = tostring(e.k or "") end
    M.counter = (M.counter or 0) + 1
    return { id = tostring(M.nowMs()) .. "-n" .. tostring(M.counter), mode = "bulletin", worldId = M.worldId(),
        world = { day = clock.daysSurvived, hour = clock.hour }, bulletin = { events = list, kinds = kinds, station = "Knox County Radio" } }
end

function M.newsReady(job, text)
    local n = bucket()
    if type(text) ~= "string" or text == "" then text = M.templateBulletin(job.events or {}) end
    n.ready = { text = text, h = hours() }
    for _, e in ipairs(job.events or {}) do e.aired = true end
    log("radio bulletin ready: " .. string.sub(text, 1, 120))
end

M.eventModes.bulletin = {
    request = M.newsRequest,
    finish = function(p, r) M.newsReady(p, r and r.text or "") end,
    fallback = function(p) M.newsReady(p, nil) end,
}

function M.newsTick()
    if M.settings.radioNews == false or not M.worldHere() then return end -- MP: the server keeps the news and airs it
    pcall(M.installNewsRadio)
    local n = bucket()
    local h = hours()
    if n.ready ~= nil then return end -- one waiting already
    if h - (tonumber(n.lastH) or -1e9) < M.newsSettings.everyHours then return end
    local events = M.newsPick()
    if #events < M.newsSettings.minEvents and not (#events >= 1 and h - (tonumber(n.lastH) or -1e9) >= 12) then return end
    n.lastH = h
    if M.pending ~= nil or #M.queue > 0 or not M.bridgeAlive(M.nowMs()) then
        M.newsReady({ events = events }, nil) -- AI busy/offline: template bulletin
        return
    end
    M.submit({ mode = "bulletin", events = events, startMs = M.nowMs(), depth = 0 })
end

----------------------------------------------------------------------------------------------------------------
-- airing on A-Life's Knox County Radio
----------------------------------------------------------------------------------------------------------------
function M.splitSentences(text)
    local out = {}
    for s in string.gmatch(tostring(text) .. " ", "(.-[%.%!%?])%s+") do
        s = string.gsub(s, "^%s+", "")
        if s ~= "" then out[#out + 1] = s end
    end
    if #out == 0 then out[1] = tostring(text) end
    return out
end

function M.airBulletin(channel, time)
    local n = bucket()
    local ready = n.ready
    if ready == nil or channel == nil or RadioBroadCast == nil or RadioLine == nil then return false end
    if channel:getAiringBroadcast() ~= nil then return false end
    local pa = PA()
    local radio = pa and pa.KnoxRadio
    if fn(radio, "enabled") and radio.enabled() ~= true then return false end -- station switched off in A-Life sandbox
    local slot = time:getNightsSurvived() * 24 + time:getHour()
    local state = radio and fn(radio, "state") and radio.state(time) or nil
    if state and state.lastSlot == slot then return false end
    local b = RadioBroadCast.new((radio and radio.channelUUID or "ALT") .. "-news-" .. tostring(slot), -1, -1)
    for _, s in ipairs(M.splitSentences(ready.text)) do
        b:AddRadioLine(RadioLine.new("Knox County Radio: " .. s, 0.95, 0.85, 0.6))
    end
    channel:setAiringBroadcast(b)
    if state then state.lastSlot = slot end
    n.ready = nil
    n.aired = (tonumber(n.aired) or 0) + 1
    log("radio bulletin on air (" .. tostring(#M.splitSentences(ready.text)) .. " lines)")
    return true
end

function M.installNewsRadio()
    local pa = PA()
    local radio = pa and pa.KnoxRadio
    if not fn(radio, "OnEveryHour") or radio.OnEveryHour == M.wrappedRadioHour then return end
    local orig = radio.OnEveryHour
    M.wrappedRadioHour = function(channel, time, ...)
        if M.settings.radioNews ~= false then
            local ok, aired = pcall(M.airBulletin, channel, time)
            if ok and aired then return end
        end
        return orig(channel, time, ...)
    end
    radio.OnEveryHour = M.wrappedRadioHour
    log("wrapped KnoxRadio.OnEveryHour (AI news bulletins)")
end

return M
