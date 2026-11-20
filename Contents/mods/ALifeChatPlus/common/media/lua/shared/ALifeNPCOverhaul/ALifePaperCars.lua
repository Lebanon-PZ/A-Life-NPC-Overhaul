-- A-Life NPC Overhaul 0.7.6: CARAVANS COME IN THEIR OWN CAR (the same car, moved on paper).
-- The game can't move a car whose ground isn't loaded, so a group's car travels on paper, the way A-Life 1.5 moves
-- its own cars: the real car is saved (model, every part's condition, fuel, battery, paint, rust) and rebuilt from
-- that record where it really is. Nothing is made: there is only ever one of their car.
--   * They set out by car (a caravan that drives, as before: real fuel burned). Their car leaves their lot: the next
--     time their base is loaded and you're not looking (30+ tiles off), the real car is saved and taken off the lot.
--     Anything left in its trunk or glovebox goes into their stash (they unloaded it before leaving).
--   * They arrive: their car is rebuilt parked near your trading post / base, on the side they came from, and they
--     walk over from it to trade.
--   * They leave: once nobody's near it (40+ tiles), the car is saved again (fuel, any damage) and goes home on paper,
--     arriving after the real drive time. When their base is loaded and you're not looking, it's parked back on
--     their lot.
--   * Their car, their property: drive off in it and you've stolen it. It's yours, it's gone from them, and they
--     hear about it.
-- If a car can't be rebuilt (no room, ground not loaded, A-Life's car tools missing), they walk in like before.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "paperCars" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifePaperCars") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifePaperCars = ALifePaperCars or {}
local L = ALifePaperCars
local TAG = "[ALifePaperCars]"
L.VERSION = "0.7.6"
L.cfg = { hideTiles = 30, leaveTiles = 40, parkBack = 12, parkSide = 6, clearTiles = 4, stealTiles = 25, theftRep = -15, roadSnap = 20 }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { leftLot = 0, parkedAtPost = 0, wentHome = 0, backOnLot = 0, stolen = 0, refused = 0, unloaded = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end

function L.enabled()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and (M.settings.paperCars == false or M.settings.npcVehicles == false))
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
    if tbl[name .. "__PaperCars"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__PaperCars"] = orig
    L.hooked[hookName] = true
    return true
end

-- A-Life's car tools (CarOffline world adapter, server side)
local function W()
    local CO = PA() and PA().CarOffline
    local w = CO and CO.world
    if fn(w, "snapshot") and fn(w, "createCar") and fn(w, "removeCar") and fn(w, "untag") then return w end
    return nil
end
function L.toolsReady() return W() ~= nil end

local function players()
    local out = {}
    pcall(function()
        local n = getNumActivePlayers and getNumActivePlayers() or 1
        for i = 0, n - 1 do local p = getSpecificPlayer(i); if p ~= nil and not p:isDead() then out[#out + 1] = p end end
    end)
    return out
end
function L.nearestPlayerTiles(x, y)
    local best = math.huge
    for _, p in ipairs(players()) do
        local px, py = nil, nil
        pcall(function() px, py = p:getX(), p:getY() end)
        if px ~= nil then local d = math.sqrt(d2(px, py, x, y)); if d < best then best = d end end
    end
    return best
end
local function sqlId(car) local id = nil; pcall(function() id = car:getSqlId() end); return tonumber(id) end
local function carXY(car) local x, y = nil, nil; pcall(function() x, y = car:getX(), car:getY() end); return x, y end
local function occupied(car)
    local busy = false
    pcall(function()
        for seat = 0, car:getMaxPassengers() - 1 do if car:getCharacter(seat) ~= nil then busy = true end end
    end)
    return busy
end
local function playerDriving(car)
    local yes = false
    pcall(function()
        for seat = 0, car:getMaxPassengers() - 1 do
            local c = car:getCharacter(seat)
            if c ~= nil and instanceof(c, "IsoPlayer") then yes = true end
        end
    end)
    return yes
end
-- 0.7.11.1: the cell's vehicle list has no size()/get() from Lua on 42.21 (threw every ten minutes); walk it with its
-- iterator like ALifePickup/ALifeDriveOrders do, size()/get() only as a fallback
local function cellCars()
    local out = {}
    local vs = nil
    pcall(function() vs = getCell():getVehicles() end)
    if vs == nil then return out end
    local ok = pcall(function() local it = vs:iterator(); while it:hasNext() do out[#out + 1] = it:next() end end)
    if not ok then out = {}; pcall(function() for i = 0, vs:size() - 1 do out[#out + 1] = vs:get(i) end end) end
    return out
end
local function paperOf(b) return type(b) == "table" and type(b.vehicle) == "table" and type(b.vehicle.paper) == "table" and b.vehicle.paper or nil end
local function M() return ALifeLLMTalk end
local function event(b, text) local m = M(); if fn(m, "nbEvent") then pcall(m.nbEvent, b, text, "vehicle") end end

-- what's in the car's trunk / glovebox / seats -> their stash (by type, like every stash), car left empty
function L.emptyIntoStash(car, b)
    local m = M()
    local list = (fn(m, "nbHavenOf") and fn(m, "nbStashList")) and m.nbStashList(m.nbHavenOf(b), true) or nil
    local n = 0
    pcall(function()
        for i = 0, car:getPartCount() - 1 do
            local part = car:getPartByIndex(i)
            local c = part and part:getItemContainer() or nil
            if c ~= nil then
                local items = c:getItems()
                for k = items:size() - 1, 0, -1 do
                    local it = items:get(k)
                    if list ~= nil then list[#list + 1] = { type = it:getFullType() } end
                    c:DoRemoveItem(it)
                    n = n + 1
                end
            end
        end
    end)
    return n
end

-- save + take off the map (only when nobody's inside); returns the record
-- fuel: our books already burned the round trip when they set out (as before); the real tank is what's in it.
-- leaving the lot: the record arrives with half the trip burned; driving home: the other half comes off the tank.
function L.takeOff(car, b, why, mode)
    local w = W()
    if w == nil or car == nil or occupied(car) then return nil end
    local ok, rec = pcall(w.snapshot, car)
    if not ok or type(rec) ~= "table" then return nil end
    local moved = L.emptyIntoStash(car, b)
    if not w.removeCar(car) then return nil end
    local cap = b.vehicle and tonumber(b.vehicle.cap) or nil
    local p = paperOf(b)
    if cap and cap > 0 and rec.fuel and p then
        local tank = rec.fuel * cap
        if mode == "lot" then
            p.tripL = math.max(0, tank - (tonumber(p.fuelAfter) or tank))
            rec.fuel = math.max(0, tank - p.tripL / 2) / cap
        elseif mode == "home" then
            rec.fuel = math.max(0, tank - (tonumber(p.tripL) or 0) / 2) / cap
            b.vehicle.fuel = rec.fuel * cap
        end
    end
    log(tostring(b.name) .. ": car saved and taken off the map (" .. tostring(why) .. ")" .. (moved > 0 and (", " .. moved .. " things into their stash") or ""))
    return rec
end

-- rebuild their car at (x, y); returns the car
function L.rebuild(b, rec, x, y, heading, gen)
    local w = W()
    if w == nil or x == nil then return nil, "no_tools" end
    for _, other in ipairs(cellCars()) do
        local ox, oy = carXY(other)
        if ox ~= nil and d2(ox, oy, x, y) <= L.cfg.clearTiles * L.cfg.clearTiles then return nil, "no_room" end
    end
    -- 0.8.0: A-Life's own cars are off (ALifeAirspace); this one is ours, so the car gate lets it through
    local car, why
    local A = ALifeAirspace
    if type(A) == "table" and type(A.asOwn) == "function" then
        car, why = A.asOwn(w.createCar, rec, x, y, heading or 0, "alcp_paper", 0)
    else
        car, why = w.createCar(rec, x, y, heading or 0, "alcp_paper", 0)
    end
    if car == nil then return nil, why end
    pcall(w.untag, car)                 -- not one of A-Life's offline squads: its reconciler leaves it alone
    pcall(function() car:getModData().ALCPPaperCar = { base = b.id, gen = gen } end)
    return car
end

-- a minimal record when the real car hasn't been seen since they left (their own facts: model, fuel)
local function recordFor(b)
    local p, v = paperOf(b), b.vehicle
    if p and type(p.rec) == "table" then return p.rec end
    local cap = tonumber(v.cap) or 0
    return { script = v.script, fuel = cap > 0 and math.max(0, math.min(1, (tonumber(v.fuel) or 0) / cap)) or nil }
end

----------------------------------------------------------------------------------------------------------------
-- departure: a caravan that drives takes the car
----------------------------------------------------------------------------------------------------------------
function L.onSetOut(base, h, only, r1)
    if r1 ~= "on_the_way" then return end
    local m = M()
    local trip = fn(m, "cvTripFor") and m.cvTripFor(base.id, only) or nil
    if type(trip) ~= "table" or trip.mode ~= "drive" then return end
    local b = fn(m, "nbOf") and m.nbOf(trip.home) or nil
    if type(b) ~= "table" or type(b.vehicle) ~= "table" or paperOf(b) then return end
    b.vehicle.paper = { state = "out", gen = math.floor(h * 10), leftH = h, home = b.vehicle.lot, baseId = base.id,
        fuelAfter = tonumber(b.vehicle.fuel) }
    log(tostring(b.name) .. " set out by car (" .. tostring(b.vehicle.script) .. ")")
end

function L.hookSetOut(m)
    return wrap(m, "cvSetOut", "cvSetOut", function(orig)
        return function(base, h, only, tag, ...)
            local r1, r2, r3 = orig(base, h, only, tag, ...)
            if L.enabled() and type(base) == "table" then L.guard("cvSetOut", L.onSetOut, base, h, only, r1) end
            return r1, r2, r3
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- their lot (runs where the old "look at what's parked" ran: you're near their base)
----------------------------------------------------------------------------------------------------------------
function L.lotLook(b, h)
    local p = paperOf(b)
    local mine = nil
    for _, car in ipairs((fn(M(), "vhScan") and M().vhScan(b)) or {}) do
        if b.vehicle.id ~= nil and sqlId(car) == b.vehicle.id then mine = car end
    end
    if p.state ~= "home" then
        -- the car is out: if the real one is still on the lot, it leaves now (out of your sight)
        if mine ~= nil then
            local x, y = carXY(mine)
            if L.nearestPlayerTiles(x, y) >= L.cfg.hideTiles then
                local rec = L.takeOff(mine, b, "left with their caravan", "lot")
                if rec then
                    p.rec, p.home = rec, { x = math.floor(x), y = math.floor(y) }
                    L.metrics.leftLot = L.metrics.leftLot + 1
                end
            end
        end
        return
    end
    -- home again: the original never left the lot (the base wasn't loaded the whole time): nothing to park
    if mine ~= nil then
        b.vehicle.paper = nil
        return
    end
    local spot = p.home or { x = math.floor(b.x) + 4, y = math.floor(b.y) + 4 }
    if L.nearestPlayerTiles(spot.x, spot.y) < L.cfg.hideTiles then return end -- not in front of you
    local car, why = L.rebuild(b, recordFor(b), spot.x + 0.5, spot.y + 0.5, 0, p.gen)
    if car == nil then return end
    pcall(function() car:getModData().ALCPPaperCar = nil end)
    local id = sqlId(car)
    b.vehicle.id = (id ~= nil and id > 0) and id or nil
    if b.vehicle.id == nil then b.vehicle = nil end -- the next look adopts it again from what's parked
    if type(b.vehicle) == "table" then b.vehicle.paper = nil end
    L.metrics.backOnLot = L.metrics.backOnLot + 1
    event(b, "Their car is back on the lot")
    log(tostring(b.name) .. ": car back on their lot")
end

function L.hookLook(m)
    return wrap(m, "vhLook", "vhLook", function(orig)
        return function(b, h, ...)
            local p = L.enabled() and paperOf(b) or nil
            if p ~= nil then
                local hh = tonumber(h) or hours()
                if hh - (tonumber(p.lookH) or -1e9) >= 0.1 then p.lookH = hh; L.guard("vhLook", L.lotLook, b, hh) end
                if paperOf(b) == nil and type(b.vehicle) == "table" then return orig(b, h, ...) end
                return nil -- while their car is on paper, "it's gone from the lot" isn't true
            end
            local r = orig(b, h, ...)
            -- remember where it's parked (where it goes back to)
            if L.enabled() and type(b) == "table" and type(b.vehicle) == "table" and b.vehicle.id ~= nil then
                pcall(function()
                    for _, car in ipairs(M().vhScan(b)) do
                        if sqlId(car) == b.vehicle.id then
                            local x, y = carXY(car)
                            b.vehicle.lot = { x = math.floor(x), y = math.floor(y) }
                        end
                    end
                end)
            end
            return r
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- arrival and leaving
----------------------------------------------------------------------------------------------------------------
function L.parkSpot(visit, b)
    local x, y = tonumber(visit.x), tonumber(visit.y)
    if x == nil then return nil end
    local dx, dy = (tonumber(b.x) or x) - x, (tonumber(b.y) or y) - y
    local len = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local px, py = x + dx / len * L.cfg.parkBack - dy / len * L.cfg.parkSide, y + dy / len * L.cfg.parkBack + dx / len * L.cfg.parkSide
    local G = PA() and PA().RoadGraph
    if fn(G, "snapToRoad") then
        local ok, s = pcall(G.snapToRoad, px, py, L.cfg.roadSnap)
        if ok and type(s) == "table" and tonumber(s.x) then px, py = s.x, s.y end
    end
    local heading = 0
    if type(math.atan2) == "function" then heading = math.atan2(-dy, -dx) end -- facing your place
    return px, py, heading
end

function L.onArrive(visit, b, h)
    local p = paperOf(b)
    if p == nil or p.state ~= "out" then return end
    p.state = "at_post"
    local x, y, heading = L.parkSpot(visit, b)
    local car, why = nil, "no_spot"
    if x ~= nil then car, why = L.rebuild(b, recordFor(b), x, y, heading, p.gen) end
    if car == nil then
        L.metrics.refused = L.metrics.refused + 1
        log(tostring(b.name) .. ": couldn't park their car near you (" .. tostring(why) .. "), they walked in")
        return
    end
    p.post = { x = math.floor(x), y = math.floor(y) }
    L.metrics.parkedAtPost = L.metrics.parkedAtPost + 1
    log(tostring(b.name) .. ": came in their own car (" .. tostring(b.vehicle.script) .. ")")
end

function L.onLeave(v, h)
    local m = M()
    local b = fn(m, "nbOf") and m.nbOf(v.home) or nil
    local p = paperOf(b)
    if p == nil or p.state ~= "at_post" then return end
    p.state = "returning"
    local th = 6
    if fn(m, "travelH") and v.x and b.x then pcall(function() th = m.travelH(v.x, v.y, b.x, b.y, b) end) end
    p.backH = h + (tonumber(th) or 6)
end

function L.hookOvLeave(m)
    return wrap(m, "ovLeave", "ovLeave", function(orig)
        return function(v, h, why, ...)
            local r = orig(v, h, why, ...)
            if L.enabled() and type(v) == "table" then L.guard("ovLeave", L.onLeave, v, h) end
            return r
        end
    end)
end
function L.hookCvUnload(m) -- Jeem visits
    return wrap(m, "cvUnload", "cvUnload", function(orig)
        return function(visit, ...)
            local r = orig(visit, ...)
            local a = type(visit) == "table" and visit.alcp or nil
            if L.enabled() and type(a) == "table" then
                L.guard("cvUnload", L.onLeave, { home = a.home, x = visit.x or a.x, y = visit.y or a.y }, hours())
            end
            return r
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- every ten minutes: their car where it is now (parked at your place, going home, stolen)
----------------------------------------------------------------------------------------------------------------
function L.carsStep()
    local m = M()
    local h = hours()
    for _, car in ipairs(cellCars()) do
        local tag = nil
        pcall(function() tag = car:getModData().ALCPPaperCar end)
        if type(tag) == "table" then
            local b = fn(m, "nbOf") and m.nbOf(tag.base) or nil
            local p = paperOf(b)
            local x, y = carXY(car)
            local current = p ~= nil and p.gen == tag.gen
            local moved = current and p.post and x and d2(x, y, p.post.x, p.post.y) > L.cfg.stealTiles * L.cfg.stealTiles
            if current and (playerDriving(car) or moved) then
                do
                    pcall(function() car:getModData().ALCPPaperCar = nil end)
                    b.vehicle = nil
                    if fn(m, "nbRep") then pcall(m.nbRep, b, L.cfg.theftRep, "You took their car") end
                    event(b, "Their car was taken while they traded")
                    L.metrics.stolen = L.metrics.stolen + 1
                    log(tostring(b and b.name) .. ": their car was stolen")
                end
            elseif current and p.state == "at_post" then
                -- parked at your place while they trade: it stays
            elseif x ~= nil and L.nearestPlayerTiles(x, y) >= L.cfg.leaveTiles and not occupied(car) then
                -- gone home (or a leftover copy): saved and off the map once nobody's near
                if current and (p.state == "returning" or p.state == "home") then
                    local rec = L.takeOff(car, b, "drove home", "home")
                    if rec then p.rec = rec; L.metrics.wentHome = L.metrics.wentHome + 1 end
                elseif type(b) == "table" and type(b.vehicle) == "table" then
                    if L.takeOff(car, b, "leftover copy", "copy") then L.metrics.unloaded = L.metrics.unloaded + 1 end
                else
                    pcall(function() car:getModData().ALCPPaperCar = nil end) -- their group is gone: just a car now
                end
            end
        end
    end
    -- the drive home on paper
    local st = fn(m, "nbStore") and m.nbStore() or nil
    for _, b in pairs(st and st.byId or {}) do
        local p = paperOf(b)
        if p and p.state == "returning" and h >= (tonumber(p.backH) or 0) then p.state = "home" end
    end
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "cvSetOut", "vhLook", "arrive", "ovLeave", "cvUnload", "tools" }
function L.install()
    local m = M()
    if type(m) ~= "table" then return 0, L.HOOKS end
    if type(m.settings) == "table" and m.settings.paperCars == nil then m.settings.paperCars = true end
    L.hookSetOut(m); L.hookLook(m); L.hookOvLeave(m); L.hookCvUnload(m)
    if not L.hooked.arrive then
        m.cvArriveHooks = m.cvArriveHooks or {}
        table.insert(m.cvArriveHooks, function(visit, b, h)
            if L.enabled() and type(visit) == "table" and type(b) == "table" then L.guard("arrive", L.onArrive, visit, b, h) end
        end)
        L.hooked.arrive = true
    end
    L.hooked.tools = L.toolsReady() or nil
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
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or ""))
        return true
    end
    return false
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
    if Events.EveryTenMinutes ~= nil then
        Events.EveryTenMinutes.Add(function() if L.enabled() and L.toolsReady() then L.guard("carsStep", L.carsStep) end end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
