-- A-Life NPC Overhaul 0.6.11: VEHICLES.
--
-- A group drives when it really has a vehicle and the fuel for the trip; otherwise it walks.
--   * what they own: when you're near one of their bases, the real vehicles parked there (on the grounds or just
--     outside) are looked at: a working engine and a gas tank. The best one is theirs. Nothing is made.
--   * fuel is real: a trip burns fuel for the road distance there and back; gas cans in their stash top the tank up
--     (and are used up). Next time you're near, the real car's tank is set to what they have left.
--   * if the car is gone when you come back (you took it, it burned, the dead wrecked it), they've lost it.
--   * caravans, help from allies and hunters drive (0.6.6 travel time at driving pace); nomads leave theirs behind
--     (they're starving and out of fuel by then).
-- The car itself can't be moved while nobody's near it (the game doesn't let mods move a vehicle that isn't loaded),
-- so a group that drives to you parks out of sight and walks in.
-- Performance: the vehicle look is once an in-game hour per base, only while you're near it (a walk over the loaded
-- vehicles list); everything else is a few numbers.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Vehicles") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCellCars"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Vehicles"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Vehicles") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("vehicles: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "vehicle") end end

if M.settings.npcVehicles == nil then M.settings.npcVehicles = true end
M.vhCfg = { tilesPerLitre = 500, reserve = 2, pad = 25, canLitres = 8, refillBelow = 12, lookEveryH = 1 }
M.vhStats = { seen = 0, lost = 0, synced = 0, drives = 0, litres = 0, cans = 0 }

local function stashOf(haven, create) return fn(M, "nbStashList") and M.nbStashList(haven, create) or nil end

-- the real vehicles parked at a base (only while it's loaded); returns the best one's facts or nil
local function partOf(v, id) local p = nil; pcall(function() p = v:getPartById(id) end); return p end
local function factsOf(v)
    local f = nil
    pcall(function()
        local tank, engine = partOf(v, "GasTank"), partOf(v, "Engine")
        if tank == nil or engine == nil or (tonumber(engine:getCondition()) or 0) <= 0 then return end
        f = { fuel = tonumber(tank:getContainerContentAmount()) or 0, cap = tonumber(tank:getContainerCapacity()) or 0,
            script = tostring(v:getScriptName() or "vehicle"), id = v.getSqlId and v:getSqlId() or nil, x = v:getX(), y = v:getY() }
    end)
    return f
end
function M.vhScan(b)
    local list = {}
    local bb = type(b.bounds) == "table" and b.bounds or { x1 = b.x - 10, y1 = b.y - 10, x2 = b.x + 10, y2 = b.y + 10 }
    local pad = M.vhCfg.pad
    local x1, y1, x2, y2 = tonumber(bb.x1), tonumber(bb.y1), tonumber(bb.x2), tonumber(bb.y2)
    if x1 == nil or y1 == nil or x2 == nil or y2 == nil then return list end
    for _, v in ipairs(ALifeCellCars.list()) do -- 0.9.5: 42.21 cell vehicles = HashSet (no get(i))
        pcall(function()
            local x, y = v:getX(), v:getY()
            if x >= x1 - pad and x <= x2 + pad and y >= y1 - pad and y <= y2 + pad then list[#list + 1] = v end
        end)
    end
    return list
end
-- look at what's parked there (you're near): keep theirs in step with the real one
function M.vhLook(b, h)
    if M.settings.npcVehicles == false or type(b) ~= "table" or b.status ~= "active" then return end
    if h - (tonumber(b.vhLookH) or -1e9) < M.vhCfg.lookEveryH then return end
    b.vhLookH = h
    local vs = M.vhScan(b)
    local mine, best = nil, nil
    for _, v in ipairs(vs) do
        local f = factsOf(v)
        if f then
            if type(b.vehicle) == "table" and b.vehicle.id ~= nil and f.id == b.vehicle.id then mine = { v = v, f = f } end
            if best == nil or f.fuel > best.f.fuel then best = { v = v, f = f } end
        end
    end
    if type(b.vehicle) == "table" and b.vehicle.id ~= nil then
        if mine == nil then
            b.vehicle = nil
            M.vhStats.lost = M.vhStats.lost + 1
            event(b, "Their vehicle is gone", "vehicle")
        else
            -- the real tank shows what they've used (fuel that went down on the road, or was topped up from cans)
            local tank = partOf(mine.v, "GasTank")
            if tank and math.abs((tonumber(b.vehicle.fuel) or 0) - mine.f.fuel) > 0.05 then
                if (tonumber(b.vehicle.fuel) or 0) < mine.f.fuel or (b.vehicle.toppedUp or 0) > 0 then
                    pcall(function() tank:setContainerContentAmount(math.max(0, math.min(mine.f.cap, b.vehicle.fuel))) end)
                    pcall(function() mine.v:transmitPartModData(tank) end)
                    M.vhStats.synced = M.vhStats.synced + 1
                else
                    b.vehicle.fuel = mine.f.fuel -- someone filled it (you?): theirs now
                end
                b.vehicle.toppedUp = 0
            end
        end
        return
    end
    if best then
        b.vehicle = { id = best.f.id, script = best.f.script, fuel = best.f.fuel, cap = best.f.cap, seenH = h }
        M.vhStats.seen = M.vhStats.seen + 1
        event(b, "They have a vehicle (" .. best.f.script .. ")", "vehicle")
        log(tostring(b.name) .. " has " .. best.f.script .. " with " .. math.floor(best.f.fuel) .. " L")
    end
end
-- gas cans in their stash go into the tank (used up)
function M.vhRefill(b, want)
    local v = type(b) == "table" and b.vehicle or nil
    want = math.max(tonumber(want) or 0, M.vhCfg.refillBelow)
    if type(v) ~= "table" or (tonumber(v.fuel) or 0) >= want then return 0 end
    local list = stashOf(M.nbHavenOf(b))
    if list == nil then return 0 end
    local n = 0
    for i = #list, 1, -1 do
        if (tonumber(v.fuel) or 0) >= (tonumber(v.cap) or 0) - M.vhCfg.canLitres or (tonumber(v.fuel) or 0) >= want then break end
        local t = type(list[i]) == "table" and list[i].type or list[i]
        if fn(M, "nbKindOf") and M.nbKindOf(t) == "fuel" then
            table.remove(list, i)
            v.fuel = math.min(tonumber(v.cap) or 50, (tonumber(v.fuel) or 0) + M.vhCfg.canLitres)
            v.toppedUp = (v.toppedUp or 0) + 1
            n = n + 1
        end
    end
    M.vhStats.cans = M.vhStats.cans + n
    return n
end
-- can they drive this far (there and back) right now?
-- (no side effects: asking how long a trip takes never uses fuel or cans)
function M.vhCanDrive(b, tiles)
    if M.settings.npcVehicles == false or type(b) ~= "table" or type(b.vehicle) ~= "table" then return false end
    local fuel = tonumber(b.vehicle.fuel) or 0
    local need = tiles * 2 / M.vhCfg.tilesPerLitre + M.vhCfg.reserve
    if fuel >= need then return true end
    local cans = 0
    for _, it in ipairs(stashOf(M.nbHavenOf(b)) or {}) do
        local t = type(it) == "table" and it.type or it
        if fn(M, "nbKindOf") and M.nbKindOf(t) == "fuel" then cans = cans + 1 end
    end
    return math.min(tonumber(b.vehicle.cap) or 50, fuel + cans * M.vhCfg.canLitres) >= need
end
-- the trip happens: top up from cans if needed, then burn
function M.vhBurn(b, tiles)
    if type(b) ~= "table" or type(b.vehicle) ~= "table" then return 0 end
    local l = tiles * 2 / M.vhCfg.tilesPerLitre
    if (tonumber(b.vehicle.fuel) or 0) < l + M.vhCfg.reserve then M.vhRefill(b, l + M.vhCfg.reserve) end
    b.vehicle.fuel = math.max(0, (tonumber(b.vehicle.fuel) or 0) - l)
    M.vhStats.drives = M.vhStats.drives + 1
    M.vhStats.litres = M.vhStats.litres + l
    return l
end
function M.vhPerf()
    local s = M.vhStats
    return "vehicles: seen " .. s.seen .. ", lost " .. s.lost .. ", drives " .. s.drives .. " (" .. math.floor(s.litres) .. " L), cans used " .. s.cans .. ", tanks synced " .. s.synced
end

----------------------------------------------------------------------------------------------------------------
-- hooks (wrap, never replace; marked)
----------------------------------------------------------------------------------------------------------------
M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeVehicles] " .. where .. " failed, NPC vehicles off for this session: " .. tostring(a)) end
    return ok and a or nil
end
function M.vhInstall()
    if M._alcpHooks.vehicles or type(M.nbStep) ~= "function" or not fn(M, "travelH") then return false end
    M._alcpHooks.vehicles = true
    -- travel: drive when they can (b.vehicle is set only while they can make the trip; burned when they go)
    local travelH = M.travelH
    M.travelH = function(ax, ay, bx, by, b, ...)
        if broken or type(b) ~= "table" or type(b.vehicle) ~= "table" then return travelH(ax, ay, bx, by, b, ...) end
        local tiles = M.roadTiles(ax, ay, bx, by)
        if guard("drive?", M.vhCanDrive, b, tiles) then return travelH(ax, ay, bx, by, b, ...) end
        local keep = b.vehicle
        b.vehicle = nil -- walking pace this time
        local th, t2, mode = travelH(ax, ay, bx, by, b, ...)
        b.vehicle = keep
        return th, t2, mode
    end
    -- trips that went by car burn the fuel
    local function burnAfter(name)
        if not fn(M, name) then return end
        local f = M[name]
        M[name] = function(...)
            local args = { ... }
            local r1, r2, r3 = f(...)
            pcall(function()
                local trip = nil
                if name == "cvSetOut" and r1 == "on_the_way" then trip = M.cvTripFor(args[1].id, args[3])
                    if trip == nil then for _, t in pairs(select(1, M.cvTrips())) do if t.leftH == args[2] and t.baseId == args[1].id then trip = t end end end
                elseif name == "rcSend" then trip = r1 end
                if type(trip) == "table" and trip.mode == "drive" then
                    local b = M.nbOf(trip.home)
                    if b then M.vhBurn(b, tonumber(trip.tiles) or 0); event(b, "Drove " .. math.floor(tonumber(trip.tiles) or 0) .. " tiles", "vehicle") end
                end
            end)
            return r1, r2, r3
        end
    end
    burnAfter("cvSetOut")
    -- help / hunt trips: note how they went (and burn)
    if fn(M, "rcSend") then
        local send = M.rcSend
        M.rcSend = function(kind, b, n, player, h, ...)
            local px, py = nil, nil
            pcall(function() px, py = player:getX(), player:getY() end)
            local mode, tiles = nil, nil
            if px then local okT, _, t2, m = pcall(M.travelH, b.x, b.y, px, py, b); if okT then tiles, mode = t2, m end end
            local trip = send(kind, b, n, player, h, ...)
            if type(trip) == "table" then
                trip.mode, trip.tiles = mode, tiles and math.floor(tiles) or nil
                if mode == "drive" then M.vhBurn(b, tiles or 0); event(b, "Drove out to you (" .. math.floor(tiles or 0) .. " tiles)", "vehicle") end
            end
            return trip
        end
    end
    -- nomads leave theirs behind
    if fn(M, "nmMove") then
        local move = M.nmMove
        M.nmMove = function(b, c, h, ...)
            local hadCar = type(b) == "table" and type(b.vehicle) == "table"
            local b2 = move(b, c, h, ...)
            if hadCar and type(b2) == "table" then b2.vehicle = nil; event(b2, "They left their vehicle behind, out of fuel", "vehicle") end
            return b2
        end
    end
    -- look at what's parked while you're near (the base is loaded)
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        if not far and type(b) == "table" and b.status == "active" and not broken then guard("look", M.vhLook, b, h) end
        return r
    end
    print("[ALifeVehicles] loaded v0.6.11 (groups drive their real vehicles when they have the fuel)")
    return true
end
if not M.vhInstall() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.vhInstall() end) end
