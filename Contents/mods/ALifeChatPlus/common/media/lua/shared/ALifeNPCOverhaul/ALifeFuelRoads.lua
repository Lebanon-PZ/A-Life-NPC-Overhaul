-- A-Life NPC Overhaul 0.7.5: FUEL AND THE ROAD, FROM A-LIFE 1.5's REAL CARS (hook in, never replace).
-- A-Life 1.5's NPC cars burn fuel by distance, run dry, search for gas, give up and walk. We read that, nothing made:
--   * FUEL ECONOMY: what gas is worth follows the real world. It gets dearer as the days go by, and dearer still while
--     A-Life's own drivers are out of fuel (the share of its cars that are dry, searching or abandoned). Everything
--     that prices through "every item has its own worth" sees it: caravans, haggling, Airport flights, raids.
--   * PEOPLE OFF THE ROAD: a driver or passenger of an A-Life car who is near you remembers the real trip (where they
--     set out from, where they were going, whether the tank ran dry or the car was left behind), so they can tell you
--     where they were headed and the AI doesn't make it up.
--   * ROADMAP, NAMED PLACES: where an A-Life car really ran dry and was left, people start calling the spot by it
--     ("Last Gallon, on the road to Rosewood"). Where we describe a place, that name comes first.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "fuelRoads" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeFuelRoads") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeFuelRoads = ALifeFuelRoads or {}
local L = ALifeFuelRoads
local TAG = "[ALifeFuelRoads]"
L.VERSION = "0.7.5"
L.cfg = {
    dayRamp = 0.01, dayCap = 0.6,          -- +1% worth a day, at most +60% from time alone
    dryWeight = 1.5, minCars = 3,          -- +150% at "every car is dry"; needs at least 3 cars to judge
    cap = 3.0,                             -- fuel is never more than 3x its base worth
    recalcH = 1,                           -- recompute at most once an in-game hour
    hearTiles = 40,                        -- people this close get their trip remembered
    nameTiles = 60,                        -- a named place counts within this many tiles
    namedMax = 40,
}
L.DRY = { fuel_out = true, find_fuel = true }
L.NAMES = { "Last Gallon", "Dry Tank Bend", "Empty Tank Stop", "Fumes Turn", "Gas Can Corner", "Sputter Hill", "Walkaway Bend",
    "Long Walk Junction" }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { recalcs = 0, remembered = 0, named = 0 }
L.factor, L.factorAt, L.lastShare = 1, -1e9, 0
L.seenStates = L.seenStates or {}

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end

function L.enabled()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.fuelRoads == false)
end

function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end

local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__FuelRoads"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__FuelRoads"] = orig
    L.hooked[hookName] = true
    return true
end

-- A-Life's car squads (offline and live), read only
function L.carSquads()
    local CO = PA() and PA().CarOffline
    if not fn(CO, "vehicleSquads") then return {} end
    local ok, list = pcall(CO.vehicleSquads)
    return ok and type(list) == "table" and list or {}
end
function L.isDry(q)
    local j = type(q) == "table" and q.cars2 or nil
    if type(j) ~= "table" then return false end
    return L.DRY[j.state] == true or (j.state == "exit" and j.why == "no_fuel")
end

----------------------------------------------------------------------------------------------------------------
-- 1. fuel economy
----------------------------------------------------------------------------------------------------------------
function L.recalc()
    local h = hours()
    if h - L.factorAt < L.cfg.recalcH then return L.factor end
    L.factorAt = h
    local days = h / 24
    local timeF = 1 + math.min(L.cfg.dayCap, days * L.cfg.dayRamp)
    local cars, dry = 0, 0
    for _, q in ipairs(L.carSquads()) do
        if type(q.cars2) == "table" then
            cars = cars + 1
            if L.isDry(q) then dry = dry + 1 end
        end
    end
    local share = cars >= L.cfg.minCars and (dry / cars) or 0
    L.lastShare, L.lastCars, L.lastDry = share, cars, dry
    L.factor = math.min(L.cfg.cap, timeF * (1 + L.cfg.dryWeight * share))
    L.metrics.recalcs = L.metrics.recalcs + 1
    return L.factor
end

function L.hookWorth(W)
    return wrap(W, "of", "worth", function(orig)
        return function(fullType, ...)
            local v, kind = orig(fullType, ...)
            if kind == "fuel" and L.enabled() and tonumber(v) then
                local ok, f = L.guard("worth", L.recalc)
                if ok and tonumber(f) then return v * f, kind end
            end
            return v, kind
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 2. people off the road remember their trip
----------------------------------------------------------------------------------------------------------------
local function nodeName(id)
    local G = PA() and PA().RoadGraph
    local n = G and type(G.nodes) == "table" and G.nodes[id] or nil
    return type(n) == "table" and n.name or nil
end
local function squadOf(record)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or nil
    if m == nil then return nil end
    local id = m.squadId or (type(m.carCrew) == "table" and m.carCrew.squad) or nil
    local ledger = PA() and PA().SquadLedger
    if id == nil or not fn(ledger, "peek") then return nil end
    local ok, q = pcall(ledger.peek, id)
    return ok and type(q) == "table" and q or nil
end
function L.tripText(q)
    local j = type(q.cars2) == "table" and q.cars2 or {}
    local from = type(q.cs) == "table" and nodeName(q.cs.from) or nil
    local to = (type(j.dest) == "table" and j.dest.name) or (type(q.cs) == "table" and nodeName(q.cs.to)) or nil
    if to == nil then return nil end
    local text = "Was in a car " .. (from and ("from " .. from .. " ") or "") .. "headed for " .. to
    if j.state == "fuel_out" or j.state == "find_fuel" then text = text .. "; the tank ran dry and we're looking for gas"
    elseif j.state == "exit" and j.why == "no_fuel" then text = text .. "; we left the car when the gas ran out"
    elseif j.state == "exit" then text = text .. "; we left the car" end
    return text, (j.state or "drive")
end

function L.rememberNear(player)
    local M, pa = ALifeLLMTalk, PA()
    local wd = pa and pa.Watchdog
    if not fn(M, "keyMem") or wd == nil or type(wd.bindings) ~= "table" or player == nil then return 0 end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    if px == nil then return 0 end
    local n = 0
    local r2 = L.cfg.hearTiles * L.cfg.hearTiles
    for uid, bind in pairs(wd.bindings) do
        if type(bind) == "table" and bind.shell ~= nil then
            local x, y = nil, nil
            pcall(function() x, y = bind.shell:getX(), bind.shell:getY() end)
            if x ~= nil and (x - px) ^ 2 + (y - py) ^ 2 <= r2 and fn(pa.ActorRegistry, "read") then
                local okR, r = pcall(pa.ActorRegistry.read, tostring(uid))
                local q = okR and squadOf(r) or nil
                if q ~= nil then
                    local text, state = L.tripText(q)
                    local key = tostring(uid) .. ":" .. tostring(state)
                    if text ~= nil and not L.seenStates[key] then
                        L.seenStates[key] = true
                        pcall(M.keyMem, tostring(uid), "road_trip", text)
                        n = n + 1
                    end
                end
            end
        end
    end
    L.metrics.remembered = L.metrics.remembered + n
    return n
end

----------------------------------------------------------------------------------------------------------------
-- 3. roadmap: places named after what happened there
----------------------------------------------------------------------------------------------------------------
function L.named()
    local M = ALifeLLMTalk
    if not fn(M, "bucket") then return nil end
    local ok, b = pcall(M.bucket, "namedPlaces")
    if not ok or type(b) ~= "table" then return nil end
    b.list = type(b.list) == "table" and b.list or {}
    b.cars = type(b.cars) == "table" and b.cars or {}
    return b
end
function L.nameAt(x, y)
    local b = L.named()
    if b == nil or x == nil then return nil end
    local best, bd = nil, L.cfg.nameTiles * L.cfg.nameTiles
    for _, p in ipairs(b.list) do
        local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
        if d <= bd then best, bd = p, d end
    end
    return best
end
function L.namePlace(x, y, why, seed, toward, names)
    local b = L.named()
    if b == nil or x == nil or L.nameAt(x, y) ~= nil then return nil end
    names = type(names) == "table" and #names > 0 and names or L.NAMES
    local name = names[(hash(seed) % #names) + 1]
    for _, p in ipairs(b.list) do if p.name == name then name = name .. " " .. (#b.list + 1) end end
    local full = name .. (toward and (", on the road to " .. toward) or "")
    b.list[#b.list + 1] = { x = math.floor(x), y = math.floor(y), name = full, why = why, h = hours() }
    while #b.list > L.cfg.namedMax do table.remove(b.list, 1) end
    L.metrics.named = L.metrics.named + 1
    log("a place got a name: " .. full .. " (" .. why .. ")")
    return full
end
-- once an hour: A-Life cars newly left behind for lack of fuel name their spot
function L.nameStep()
    local b = L.named()
    if b == nil then return 0 end
    local n = 0
    for _, q in ipairs(L.carSquads()) do
        local j = type(q.cars2) == "table" and q.cars2 or nil
        if j ~= nil and j.state == "exit" and j.why == "no_fuel" and not b.cars[q.id] then
            b.cars[q.id] = true
            local to = type(j.dest) == "table" and j.dest.name or nil
            if L.namePlace(q.x, q.y, "a car ran out of gas and was left there", q.id, to) then n = n + 1 end
        end
    end
    return n
end

function L.hookPlaceName(M)
    return wrap(M, "placeName", "placeName", function(orig)
        return function(x, y, z, ...)
            local base = orig(x, y, z, ...)
            if not L.enabled() then return base end
            local ok, p = L.guard("placeName", L.nameAt, tonumber(x), tonumber(y))
            if ok and type(p) == "table" then
                if base ~= nil and base ~= "" then return "at " .. p.name .. " (" .. tostring(base) .. ")" end
                return "at " .. p.name
            end
            return base
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- install + clock
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "worth", "placeName" }
function L.install()
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" and M.settings.fuelRoads == nil then M.settings.fuelRoads = true end
    if type(ALifeWorth) == "table" then L.hookWorth(ALifeWorth) end
    if type(M) == "table" then L.hookPlaceName(M) end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end
L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or ""))
        return true
    end
    return false
end
function L.tenMinutes()
    if not L.enabled() then return end
    local p = nil
    p = ALifeSide.campPlayer()
    if p ~= nil then L.guard("remember", L.rememberNear, p) end
end
function L.hourly()
    if not L.enabled() then return end
    L.guard("names", L.nameStep)
    local ok, f = L.guard("worth", L.recalc)
    if ok and L.lastCars and L.lastCars > 0 and math.floor(hours()) % 24 == 0 then
        log("fuel x" .. (math.floor(L.factor * 100 + 0.5) / 100) .. " (" .. tostring(L.lastDry) .. " of " .. tostring(L.lastCars) .. " A-Life cars dry)")
    end
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = 0
                pcall(function() now = getTimestampMs() end)
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryTenMinutes ~= nil then Events.EveryTenMinutes.Add(L.tenMinutes) end
    if Events.EveryHours ~= nil then Events.EveryHours.Add(L.hourly) end
end
print(TAG .. " loaded v" .. L.VERSION)
