-- A-Life NPC Overhaul 0.6.16: HEALTH. Two things testers (and you) need:
--   1. FEATURE-OFF: when one of our systems hits an error and switches itself off for the session (they all do that
--      instead of crashing), you see it: a one-time on-screen note per feature, and it's written down: when, which,
--      why. Caught from our own console lines ("... off for this session"), so every system is covered, old and new.
--   2. COST: every one of our event handlers and background tick handlers is timed: calls and milliseconds per 5
--      seconds (average over the session and the last window) and the slowest single call.
-- Written to Zomboid/Lua/ALifeChatPlus_health.txt once a minute (and on every feature-off). A tester sends that one
-- file. A short summary goes to the console every 5 minutes.
-- Performance: two clock reads per handler call; the file is written once a minute.
ALifeHealth = ALifeHealth or {}
local HL = ALifeHealth
HL.windowMs, HL.fileEveryMs, HL.consoleEveryMs = 5000, 60000, 300000
HL.stats = HL.stats or {}       -- label -> { calls, ms, max, wCalls, wMs, windows, lastCalls, lastMs }
HL.offs = HL.offs or {}         -- list of { at (game hours), real, feature, why }
HL.offSeen = HL.offSeen or {}
HL.wrapped = HL.wrapped or setmetatable({}, { __mode = "k" })
HL.started = HL.started or nil
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function on() local M = ALifeLLMTalk; return not (type(M) == "table" and type(M.settings) == "table" and M.settings.healthLog == false) end

-- pre-1.0: NOTE. The one path for step-by-step console notes (a trade, an order, a prisoner taken, why a car refused).
-- Setting logDetail (default on: testers' console.txt keeps them); off = console shows only ready lines and errors,
-- which stay plain print() everywhere.
function HL.note(tag, msg)
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" and M.settings.logDetail == false then return end
    print(tostring(tag) .. " " .. tostring(msg))
end

local function stat(label)
    local s = HL.stats[label]
    if s == nil then s = { calls = 0, ms = 0, max = 0, wCalls = 0, wMs = 0, windows = 0, lastCalls = 0, lastMs = 0 }; HL.stats[label] = s end
    return s
end
-- time a function under a label (same arguments and results; errors pass through untouched)
function HL.wrap(label, fn)
    if type(fn) ~= "function" then return fn end
    local w = HL.wrapped[fn]
    if w then return w end
    local s = stat(label)
    w = function(...)
        local t0 = now()
        local a, b, c, d = fn(...)
        local dt = now() - t0
        s.calls, s.ms, s.wCalls, s.wMs = s.calls + 1, s.ms + dt, s.wCalls + 1, s.wMs + dt
        if dt > s.max then s.max = dt end
        return a, b, c, d
    end
    HL.wrapped[fn] = w
    return w
end
-- Events.X.Add / Remove, timed
function HL.add(ev, label, fn)
    if type(ev) ~= "table" or type(ev.Add) ~= "function" then return end
    return ev.Add(HL.wrap(label, fn))
end
function HL.remove(ev, fn)
    if type(ev) ~= "table" or type(ev.Remove) ~= "function" then return end
    local w = HL.wrapped[fn]
    if w then ev.Remove(w) end
    return ev.Remove(fn)
end
-- background tick handlers (AA_Tick), timed
function HL.tickAdd(label, fn)
    if type(ALifeTick) ~= "table" then return end
    return ALifeTick.add(HL.wrap(label .. ":tick", fn))
end
function HL.tickRemove(fn)
    if type(ALifeTick) ~= "table" then return end
    local w = HL.wrapped[fn]
    if w then ALifeTick.remove(w) end
    return ALifeTick.remove(fn)
end

----------------------------------------------------------------------------------------------------------------
-- feature-off
----------------------------------------------------------------------------------------------------------------
local OFF = { "this session" }
local function looksOff(msg)
    for _, k in ipairs(OFF) do if string.find(msg, k, 1, true) then return true end end
    return false
end
local function featureOf(msg)
    local tag = string.match(msg, "^%[([%w_]+)%]") or "NPC Overhaul"
    local rest = string.gsub(msg, "^%[[^%]]*%]%s*", "")
    rest = string.gsub(rest, "^%[[^%]]*%]%s*", "")
    local what = string.match(rest, "^(.-)%s+failed") or string.match(rest, "^(.-)%s+error") or string.match(rest, "^(.-)[,:%(]") or rest
    what = string.sub(what, 1, 48)
    if what == "" then return tag end
    return tag .. ": " .. what
end
local function toast(text)
    pcall(function()
        local M = ALifeLLMTalk
        if type(M) == "table" and type(M.momToast) == "function" then M.momToast(text); return end
        local p = getSpecificPlayer(0)
        if p and HaloTextHelper and HaloTextHelper.addText then HaloTextHelper.addText(p, text, HaloTextHelper.getColorRed and HaloTextHelper.getColorRed() or nil) end
    end)
end
function HL.off(feature, why)
    feature = tostring(feature)
    HL.offs[#HL.offs + 1] = { at = hours(), real = now(), feature = feature, why = tostring(why or "") }
    while #HL.offs > 50 do table.remove(HL.offs, 1) end
    if not HL.offSeen[feature] and on() then
        HL.offSeen[feature] = true
        toast("NPC Overhaul: " .. feature .. " turned itself off after an error. Please send your console.txt and Zomboid/Lua/ALifeChatPlus_health.txt.")
    end
    HL.dirty = true
end
-- our console lines: a feature switching itself off is noticed here, so every system is covered
if not HL.printHooked and type(print) == "function" then
    HL.printHooked = true
    local rawPrint = print
    print = function(...)
        local first = ...
        pcall(function()
            if type(first) == "string" and (string.find(first, "ALife", 1, true) or string.find(first, "[ALCP", 1, true)) and looksOff(first) then
                HL.off(featureOf(first), first)
            end
        end)
        return rawPrint(...)
    end
end

----------------------------------------------------------------------------------------------------------------
-- windows, the file, the console summary
----------------------------------------------------------------------------------------------------------------
HL.started = HL.started or now()
local lastWindow, lastFile, lastConsole = HL.started, HL.started, HL.started
local function roll(t)
    for _, s in pairs(HL.stats) do
        s.lastCalls, s.lastMs = s.wCalls, s.wMs
        s.wCalls, s.wMs = 0, 0
        s.windows = s.windows + 1
    end
end
function HL.rows()
    local rows = {}
    for label, s in pairs(HL.stats) do
        if s.calls > 0 then
            local w = math.max(1, s.windows)
            rows[#rows + 1] = { label = label, calls5 = s.calls / w, ms5 = s.ms / w, lastCalls = s.lastCalls, lastMs = s.lastMs, max = s.max, total = s.ms }
        end
    end
    table.sort(rows, function(a, b) return a.ms5 > b.ms5 end)
    return rows
end
local function f1(x) return tostring(math.floor((tonumber(x) or 0) * 10 + 0.5) / 10) end
function HL.summary(n)
    -- "Main:<part>" rows are pieces of a timed handler: kept out of the total (no double count), listed by worst spike
    local all, rows, subs, parts, total = HL.rows(), {}, {}, {}, 0
    for _, r in ipairs(all) do
        if string.find(r.label, ":", 1, true) then subs[#subs + 1] = r else rows[#rows + 1] = r; total = total + r.ms5 end
    end
    for i = 1, math.min(n or 5, #rows) do
        local r = rows[i]
        parts[#parts + 1] = r.label .. " " .. f1(r.ms5) .. " ms/" .. f1(r.calls5) .. " calls (max " .. math.floor(r.max) .. ")"
    end
    table.sort(subs, function(a, b) return a.max > b.max end)
    local spikes = {}
    for i = 1, math.min(3, #subs) do spikes[#spikes + 1] = subs[i].label .. " max " .. math.floor(subs[i].max) end
    return "NPC Overhaul cost per 5 s: " .. f1(total) .. " ms total; most: " .. table.concat(parts, ", ")
        .. (#spikes > 0 and (" | spikes: " .. table.concat(spikes, ", ")) or "")
        .. (#HL.offs > 0 and (" | features off: " .. #HL.offs) or "")
end
function HL.writeFile()
    if not on() then return false end
    local w = nil
    pcall(function() w = getFileWriter("ALifeChatPlus_health.txt", true, false) end)
    if w == nil then return false end
    pcall(function()
        local ver = "?"
        pcall(function() ver = tostring(getModInfoByID("ALifeChatPlus"):getModVersion()) end)
        w:write("A-Life NPC Overhaul health report (mod " .. ver .. ")\r\n")
        w:write("game hours " .. f1(hours()) .. ", session " .. math.floor((now() - (HL.started or now())) / 1000) .. " s\r\n\r\n")
        w:write("FEATURES THAT TURNED THEMSELVES OFF\r\n")
        if #HL.offs == 0 then w:write("  none\r\n") end
        for _, o in ipairs(HL.offs) do
            w:write("  game hour " .. f1(o.at) .. ": " .. o.feature .. " - " .. o.why .. "\r\n")
        end
        w:write("\r\nCOST (per 5 seconds: average over the session / last 5 s; slowest single call)\r\n")
        w:write("  ms/5s    calls/5s   last ms  last calls  max ms   handler\r\n")
        for _, r in ipairs(HL.rows()) do
            w:write(string.format("  %-8s %-10s %-8s %-11s %-8s %s\r\n", f1(r.ms5), f1(r.calls5), f1(r.lastMs), tostring(r.lastCalls), tostring(math.floor(r.max)), r.label))
        end
        w:write("\r\n" .. HL.summary(8) .. "\r\n")
    end)
    pcall(function() w:close() end)
    return true
end
function HL.tick()
    local t = now()
    if t - lastWindow >= HL.windowMs then lastWindow = t; roll(t) end
    if t - lastFile >= HL.fileEveryMs or (HL.dirty and t - lastFile >= 5000) then lastFile = t; HL.dirty = false; HL.writeFile() end
    if t - lastConsole >= HL.consoleEveryMs then lastConsole = t; print("[ALifeHealth] " .. HL.summary(5)) end
end
if not HL.tickHooked and Events and Events.OnTick then
    HL.tickHooked = true
    Events.OnTick.Add(function() pcall(HL.tick) end)
end
return HL
