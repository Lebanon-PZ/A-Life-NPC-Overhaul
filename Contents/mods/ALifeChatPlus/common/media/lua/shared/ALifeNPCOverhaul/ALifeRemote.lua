-- A-Life NPC Overhaul pre-1.0 (MP port P3, docs/PLAN-MP.md): WINDOW BUTTONS AND LISTS, FROM WHEREVER THE LOGIC RUNS.
-- The talk windows (client) call ALifeLLMTalk functions directly (M.partyCommand(uid, "hold", player), M.partyData(p)).
-- In single player that is the world. On an MP client the world is on the server, so:
--   R.expose(name, nArgs, playerAt) : on an MP client M[name](...) is sent to the server ("mcall"); the server runs
--     M[name] with the client's first nArgs arguments (plain strings / numbers / booleans only) and THE SENDER as the
--     player (put in at argument playerAt; whatever the client passed there is ignored), with ALifeSide.you() = sender.
--     The client gets nothing back at once (the call answers nil); the window refreshes its view.
--   R.view(name, build, fallback) : build(player) on the server -> a flat table, sent back ("mview"); the client keeps
--     the last one (R.cache[name]) and asks again at most every R.VIEW_MS. R.get(name) returns the cached copy.
-- Single player / MP server: nothing changes (no wrap, direct calls). Only names exposed here cross the network.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"
ALifeRemote = ALifeRemote or {}
local R = ALifeRemote
R.VERSION = ALifeSide.MOD_VERSION
R.VIEW_MS = 1000
R.calls = R.calls or {}
R.views = R.views or {}
R.cache = R.cache or {}
R.askedAt = R.askedAt or {}
R.listeners = R.listeners or {}
R.metrics = R.metrics or { sent = 0, ran = 0, refused = 0, views = 0, got = 0 }
local function M() return ALifeLLMTalk end
local function nowMs() if type(getTimestampMs) == "function" then return getTimestampMs() end return os.time() * 1000 end
local function scalar(v) local t = type(v); return t == "string" or t == "number" or t == "boolean" end

function R.expose(name, nArgs, playerAt)
    R.calls[name] = { n = tonumber(nArgs) or 0, at = tonumber(playerAt) or ((tonumber(nArgs) or 0) + 1) }
end
function R.view(name, build, fallback)
    R.views[name] = { build = build, fallback = fallback }
end
-- client: a window wants to know when a view arrives (refresh)
function R.onView(name, f) R.listeners[name] = f end

-- ------------------------------------------------------------------------------- client side
local function forwarder(name, spec)
    return function(...)
        local args = { ... }
        local out = {}
        for i = 1, spec.n do
            local idx = i < spec.at and i or i + 1 -- the player's slot is skipped (the server puts the sender there)
            local v = args[idx]
            if scalar(v) then out["a" .. i] = v end
        end
        out.fn = name
        R.metrics.sent = R.metrics.sent + 1
        ALifeCmd.send(ALifeSide.localPlayer(), "mcall", out)
        return nil
    end
end
-- swap the exposed functions for forwarders; MP client only. Called at game start (every file has loaded by then).
R.wrapped = R.wrapped or {}
function R.install()
    if not ALifeSide.mpClient() then return 0 end
    local m = M()
    if type(m) ~= "table" then return 0 end
    local n = 0
    for name, spec in pairs(R.calls) do
        if type(m[name]) == "function" and R.wrapped[name] ~= m[name] then
            local f = forwarder(name, spec)
            m[name] = f
            R.wrapped[name] = f
            n = n + 1
        end
    end
    return n
end
-- the cached view (asks the server again when older than VIEW_MS). SP / server: built here, now.
function R.get(name, player)
    local v = R.views[name]
    if v == nil then return nil end
    if not ALifeSide.mpClient() then
        local ok, data = pcall(v.build, ALifeSide.you(player))
        return ok and data or nil
    end
    local now = nowMs()
    if now - (R.askedAt[name] or -1e12) >= R.VIEW_MS then
        R.askedAt[name] = now
        ALifeCmd.send(ALifeSide.localPlayer(), "mviewAsk", { name = name })
    end
    local c = R.cache[name]
    if c == nil and v.fallback ~= nil then return v.fallback end
    return c
end
if type(ALifeCmd) == "table" and type(ALifeCmd.onClient) == "function" then
    ALifeCmd.onClient("mview", function(a)
        if type(a) ~= "table" or type(a.name) ~= "string" or R.views[a.name] == nil then return end
        R.cache[a.name] = type(a.data) == "table" and a.data or {}
        R.metrics.got = R.metrics.got + 1
        local f = R.listeners[a.name]
        if type(f) == "function" then pcall(f, R.cache[a.name]) end
    end)
end

-- ------------------------------------------------------------------------------- server side
function R.run(player, a)
    if type(a) ~= "table" or type(a.fn) ~= "string" then R.metrics.refused = R.metrics.refused + 1; return false end
    local spec = R.calls[a.fn]
    local m = M()
    local f = spec and type(m) == "table" and m[a.fn] or nil
    if spec == nil or type(f) ~= "function" or player == nil then R.metrics.refused = R.metrics.refused + 1; return false end
    local args, j = {}, 1
    for i = 1, spec.n + 1 do
        if i == spec.at then args[i] = player
        else
            local v = a["a" .. j]
            args[i] = scalar(v) and v or nil
            j = j + 1
        end
    end
    R.metrics.ran = R.metrics.ran + 1
    local ok, e = ALifeSide.with(player, f, unpack(args, 1, spec.n + 1))
    if not ok then print("[ALifeRemote] " .. a.fn .. " failed: " .. tostring(e)) end
    return ok
end
function R.sendView(player, name)
    local v = R.views[name]
    if v == nil or player == nil then return false end
    local ok, data = ALifeSide.with(player, v.build, player)
    if not ok then print("[ALifeRemote] view " .. tostring(name) .. " failed: " .. tostring(data)); data = nil end
    R.metrics.views = R.metrics.views + 1
    return ALifeCmd.reply(player, "mview", { name = name, data = type(data) == "table" and data or {} })
end
if type(ALifeCmd) == "table" and type(ALifeCmd.onServer) == "function" then
    -- handlers never error out (ALifeCmd turns a failing handler off for the session)
    ALifeCmd.onServer("mcall", function(player, a) pcall(R.run, player, a) end)
    ALifeCmd.onServer("mviewAsk", function(player, a) if type(a) == "table" and type(a.name) == "string" then pcall(R.sendView, player, a.name) end end)
end
-- ------------------------------------------------------------------------------- remote reads (P6: the windows)
-- R.readable(name, nArgs, playerAt): a READ-ONLY function the windows call (a person's mood, history, last seen...).
-- On an MP client M[name](...) answers from a cache of the server's answer for those arguments; a missing or older
-- than R.READ_MS answer is asked for in the background ("mread", the sender is the player, plain values only) and the
-- window shows it on its next refresh (nil until then). The server runs only listed names and sends back up to four
-- results ("mreadR"; ALifeCmd: 3 levels, strings 300). SP / server: nothing changes.
R.READ_MS = 3000
R.reads = R.reads or {}
R.readCache = R.readCache or {}
R.readN = R.readN or 0
-- empty = true: answer {} (not nil) until the server's answer arrives (for functions that return a list / table)
function R.readable(name, nArgs, playerAt, empty)
    R.reads[name] = { n = tonumber(nArgs) or 0, at = tonumber(playerAt) or ((tonumber(nArgs) or 0) + 1), empty = empty == true }
end
local function readKey(name, out)
    local t = { name }
    for i = 1, 6 do t[#t + 1] = tostring(out["a" .. i]) end
    return table.concat(t, "|")
end
local function reader(name, spec)
    return function(...)
        local args = { ... }
        local out = {}
        for i = 1, spec.n do
            local idx = i < spec.at and i or i + 1
            local v = args[idx]
            if scalar(v) then out["a" .. i] = v end
        end
        local key = readKey(name, out)
        local c = R.readCache[key]
        local now = nowMs()
        if c == nil then
            if R.readN > 600 then R.readCache, R.readN = {}, 0 end -- keep it small: start over
            c = { at = -1e12, asked = -1e12 }
            R.readCache[key] = c
            R.readN = R.readN + 1
        end
        if now - c.at >= R.READ_MS and now - c.asked >= R.READ_MS then
            c.asked = now
            out.fn, out.key = name, key
            R.metrics.reads = (R.metrics.reads or 0) + 1
            ALifeCmd.send(ALifeSide.localPlayer(), "mread", out)
        end
        if c.vals ~= nil then
            if spec.empty and c.vals.v1 == nil then return {} end
            return c.vals.v1, c.vals.v2, c.vals.v3, c.vals.v4
        end
        if spec.empty then return {} end
        return nil
    end
end
function R.installReads()
    if not ALifeSide.mpClient() then return 0 end
    local m = M()
    if type(m) ~= "table" then return 0 end
    local n = 0
    for name, spec in pairs(R.reads) do
        if type(m[name]) == "function" and R.wrapped[name] ~= m[name] then
            local f = reader(name, spec)
            m[name] = f
            R.wrapped[name] = f
            n = n + 1
        end
    end
    return n
end
function R.read(player, a)
    if type(a) ~= "table" or type(a.fn) ~= "string" or type(a.key) ~= "string" then return false end
    local spec = R.reads[a.fn]
    local m = M()
    local f = spec and type(m) == "table" and m[a.fn] or nil
    if spec == nil or type(f) ~= "function" or player == nil then R.metrics.refused = R.metrics.refused + 1; return false end
    local args, j = {}, 1
    for i = 1, spec.n + 1 do
        if i == spec.at then args[i] = player
        else
            local v = a["a" .. j]
            args[i] = scalar(v) and v or nil
            j = j + 1
        end
    end
    local ok, packed = ALifeSide.with(player, function() local r1, r2, r3, r4 = f(unpack(args, 1, spec.n + 1)); return { v1 = r1, v2 = r2, v3 = r3, v4 = r4 } end)
    if not ok then print("[ALifeRemote] read " .. a.fn .. " failed: " .. tostring(packed)); packed = {} end
    packed.key = string.sub(a.key, 1, 280)
    return ALifeCmd.reply(player, "mreadR", packed)
end
if type(ALifeCmd) == "table" and type(ALifeCmd.onServer) == "function" then
    ALifeCmd.onServer("mread", function(player, a) pcall(R.read, player, a) end)
end
if type(ALifeCmd) == "table" and type(ALifeCmd.onClient) == "function" then
    ALifeCmd.onClient("mreadR", function(a)
        if type(a) ~= "table" or type(a.key) ~= "string" then return end
        local c = R.readCache[a.key]
        if c == nil then c = { asked = -1e12 }; R.readCache[a.key] = c; R.readN = R.readN + 1 end
        c.at, c.vals = nowMs(), { v1 = a.v1, v2 = a.v2, v3 = a.v3, v4 = a.v4 }
    end)
end
-- ------------------------------------------------------------------------------- global ModData mirrors
-- The server's ModData.transmit(key) reaches a client ONLY as Events.OnReceiveGlobalModData(key, table) (42.21 jar:
-- GlobalModDataPacket.parse fires the event and stores nothing; table = false when the server has none). So the
-- client stores it here. Mirrored: our own "ALifeChatPlus_*" tables (Chronicle, Democracy, Ghost, Legacy, Member;
-- they transmit on change) + any key a module names with R.mirror(key). At game start an MP client asks for each
-- (ModData.request) so a player who joins late has them too.
R.MIRROR_PREFIX = "ALifeChatPlus_"
R.mirrors = R.mirrors or { ALifeChatPlus_Chronicle = true, ALifeChatPlus_Democracy = true, ALifeChatPlus_Ghost = true,
    ALifeChatPlus_Legacy = true, ALifeChatPlus_Member = true }
R.mirrorListeners = R.mirrorListeners or {}
function R.mirror(key, onChange) R.mirrors[key] = true; if onChange then R.mirrorListeners[key] = onChange end end
function R.isMirror(key)
    return type(key) == "string" and (R.mirrors[key] == true or string.sub(key, 1, #R.MIRROR_PREFIX) == R.MIRROR_PREFIX)
end
function R.onMirror(key, data)
    if not ALifeSide.mpClient() or not R.isMirror(key) or type(data) ~= "table" then return false end
    if type(ModData) ~= "table" or type(ModData.add) ~= "function" then return false end
    local ok = pcall(ModData.add, key, data)
    if ok then
        R.metrics.mirrored = (R.metrics.mirrored or 0) + 1
        local f = R.mirrorListeners[key]
        if type(f) == "function" then pcall(f, data) end
    end
    return ok
end
function R.askMirrors()
    if not ALifeSide.mpClient() or type(ModData) ~= "table" or type(ModData.request) ~= "function" then return 0 end
    local n = 0
    for key in pairs(R.mirrors) do if pcall(ModData.request, key) then n = n + 1 end end
    return n
end
-- ------------------------------------------------------------------------------- shared world tables (P4)
-- R.share(key, build, everyMs): the server sends clients a READ-ONLY copy of a world table (the camp, work zones...)
-- for windows, menus and map overlays. build() makes the table on the server; a deep copy (data only, depth 8) goes
-- out as global ModData key (ModData.add + ModData.transmit, then removed again on the server so the save never holds
-- a second copy; transmit writes its packets inside the call, 42.21 jar GlobalModData.transmit). Sent when R.touch(key)
-- marked it changed (at most once a second) and at least every everyMs (default 10 s), only with players online.
-- R.shared(key): MP client = the last copy (nil until the first arrives); SP / server = build() itself, live.
-- Writes never go through here: a client changes the world only with exposed calls (R.expose) on the server.
R.shares = R.shares or {}
function R.share(key, build, everyMs)
    R.shares[key] = { build = build, every = tonumber(everyMs) or 10000, at = -1e12, dirty = true }
    R.mirror(key)
end
function R.touch(key) local s = R.shares[key]; if s then s.dirty = true end end
local function copyOf(v, depth)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    if t ~= "table" or depth > 8 then return nil end
    local out = {}
    for k, x in pairs(v) do
        local tk = type(k)
        if tk == "string" or tk == "number" then
            local c = copyOf(x, depth + 1)
            if c ~= nil then out[k] = c end
        end
    end
    return out
end
R.copyOf = function(v) return copyOf(v, 1) end
function R.pushShares(now, force)
    if not ALifeSide.mpServer() or type(ModData) ~= "table" or type(ModData.transmit) ~= "function" then return 0 end
    if #ALifeSide.online() == 0 then return 0 end
    now = now or nowMs()
    local n = 0
    for key, s in pairs(R.shares) do
        if force or (s.dirty and now - s.at >= 1000) or now - s.at >= s.every then
            s.at, s.dirty = now, false
            local ok, data = pcall(s.build)
            if ok and type(data) == "table" then
                local copy = copyOf(data, 1) or {}
                if pcall(ModData.add, key, copy) then
                    pcall(ModData.transmit, key)
                    if type(ModData.remove) == "function" then pcall(ModData.remove, key) end
                    n = n + 1
                    R.metrics.shared = (R.metrics.shared or 0) + 1
                end
            elseif not ok then print("[ALifeRemote] share " .. tostring(key) .. " failed: " .. tostring(data)) end
        end
    end
    return n
end
function R.shared(key)
    local s = R.shares[key]
    if not ALifeSide.mpClient() then
        if s == nil then return nil end
        local ok, data = pcall(s.build)
        return ok and data or nil
    end
    if type(ModData) ~= "table" or type(ModData.get) ~= "function" then return nil end
    local ok, data = pcall(ModData.get, key)
    return ok and type(data) == "table" and data or nil
end
if type(Events) == "table" and Events.OnTick and type(Events.OnTick.Add) == "function" then
    local n = 0
    Events.OnTick.Add(function()
        n = n + 1
        if n % 30 ~= 0 or not ALifeSide.mpServer() then return end
        pcall(R.pushShares)
    end)
end
if type(Events) == "table" and Events.OnReceiveGlobalModData and type(Events.OnReceiveGlobalModData.Add) == "function" then
    Events.OnReceiveGlobalModData.Add(function(key, data) pcall(R.onMirror, key, data) end)
end
if type(Events) == "table" and Events.OnGameStart and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function() pcall(R.install); pcall(R.installReads); pcall(R.askMirrors) end)
end
print("[ALifeRemote] ready " .. R.VERSION .. ": window buttons + lists cross to the server in MP (mcall / mview)")
return R
