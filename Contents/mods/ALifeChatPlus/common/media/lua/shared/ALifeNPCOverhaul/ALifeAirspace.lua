-- A-Life NPC Overhaul 0.8.0: ONLY THE GUARD FLIES, AND A-LIFE'S OWN CARS STAY PARKED (hook in, never replace).
--   * ONLY THE GUARD FLIES: A-Life 1.5 launches helicopters on its own all day (news, police, military, brigands,
--     routine flybys, up to four a day plus raid backup). Now a helicopter only takes off when the Louisville National
--     Guard is the one using it: your supply flights, the Guard's own raids and its own support calls, and only while
--     it still has something that flies. Every other helicopter start is refused at the source, quietly (no log spam).
--     A-Life's scripted story flights (the day-365 ending, the Fiesta at the tower) are A-Life's, and left alone.
--   * A-LIFE'S CARS STAY PARKED: A-Life creates no cars of its own any more (traffic, drive-bys, pull-ups, travelers,
--     ambushes, pursuit and reinforcement cars, camp and outpost cars, cars rebuilt from its offline trips, NPCs
--     taking over cars on their own). Raids and visitors that would have come by car walk in. Only this mod puts an
--     NPC behind a wheel: your drive orders, your party riding with you or in a second car, pickups, caravans in their
--     own car. Those still steer with A-Life's driving engine underneath, which stays on.
-- How: wraps on A-Life's own switches (Options.carsEnabled / carTrafficOff / carTrafficCount / applyMasters,
-- VehicleArrivals.enabled / prepare / tickBody, DebugService.aircraftRefusal, HeliNatural.fire, HeliRole.fire,
-- HeliArrival.launch, HeliDirector.start). Each wrap calls the original whenever it isn't refusing.
-- Our own car and the Guard's flights pass with L.asOwn(...), which opens the gates for that one call.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Settings: "guardOnlySky" and "alifeCarsOff" (both on by default; switching one off gives A-Life back its own).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeAirspace") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeAirspace = ALifeAirspace or {}
local L = ALifeAirspace
local TAG = "[ALifeAirspace]"
L.VERSION = "0.8.0"
L.REFUSE_HELI = "only the Louisville National Guard flies (NPC Overhaul)"
L.REFUSE_CAR = "A-Life's own cars are off (NPC Overhaul drives)"
-- A-Life's car encounter switches (Settings.current); carDriveHere stays: that's a drive the player orders
L.CAR_SWITCHES = { "carDriveBy", "carBlockade", "carPursuit", "carPullUp", "carReinforcements", "carDriveOff" }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.own = L.own or 0
L.saved = L.saved or nil
L.metrics = L.metrics or { heliRefused = 0, naturalHeld = 0, roleHeld = 0, ambientHeld = 0, searchHeld = 0, guardFlights = 0,
    carsRefused = 0, arrivalsWalked = 0, ownCars = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function M() return ALifeLLMTalk end

local function setting(key)
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings[key] == false)
end
function L.skyOn() return setting("guardOnlySky") end
function L.carsOff() return setting("alifeCarsOff") end

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
    if tbl[name .. "__Airspace"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__Airspace"] = orig
    L.hooked[hookName] = true
    return true
end

-- run f with our gates open (our own car, the Guard's flight); errors pass through unchanged
function L.asOwn(f, ...)
    L.own = L.own + 1
    local r = { pcall(f, ...) }
    L.own = L.own - 1
    if L.own < 0 then L.own = 0 end
    if not r[1] then error(r[2], 0) end
    return r[2], r[3], r[4]
end
function L.isOwn() return L.own > 0 end

----------------------------------------------------------------------------------------------------------------
-- who may fly: the Guard, while it has helicopters
----------------------------------------------------------------------------------------------------------------
function L.guardFid()
    local S = ALifeSkyPower
    if not fn(S, "guardActive") or not fn(S, "fleet") then return nil end
    local ok, on, s = pcall(S.guardActive)
    if not ok or not on or type(s) ~= "table" then return nil end
    local okF, n = pcall(S.fleet)
    if not okF or (tonumber(n) or 0) <= 0 then return nil end
    return s.factionId
end
function L.isGuard(fid)
    if fid == nil then return false end
    local g = L.guardFid()
    return g ~= nil and tostring(g) == tostring(fid)
end
function L.heliKind(args)
    local H = PA() and PA().HeliArrival
    if not fn(H, "kindFor") then return nil end
    local ok, k = pcall(H.kindFor, args)
    return ok and k or nil
end

----------------------------------------------------------------------------------------------------------------
-- helicopters
----------------------------------------------------------------------------------------------------------------
-- every helicopter body (and every by-car arrival that still asks for one) passes DebugService.aircraftRefusal
function L.hookRefusal(S)
    return wrap(S, "aircraftRefusal", "aircraftRefusal", function(orig)
        return function(args, ...)
            local refuse = nil
            if type(args) == "table" then
                local ok, why = L.guard("aircraftRefusal", function()
                    if L.heliKind(args) ~= nil then
                        if L.skyOn() and not L.isGuard(args.factionId) then L.metrics.heliRefused = L.metrics.heliRefused + 1; return L.REFUSE_HELI end
                        if L.skyOn() then L.metrics.guardFlights = L.metrics.guardFlights + 1 end
                    elseif L.carsOff() and not L.isOwn() then
                        -- a by-car arrival that couldn't walk instead (drive-by, pull-up, traveler, ambush)
                        L.metrics.carsRefused = L.metrics.carsRefused + 1
                        return L.REFUSE_CAR
                    end
                    return nil
                end)
                if ok then refuse = why end
            end
            if refuse ~= nil then return refuse end
            return orig(args, ...)
        end
    end)
end
-- the Guard's helicopter is a vehicle arrival: let A-Life's arrival code run for it even with A-Life's cars off
function L.hookArrivalPrepare(A)
    return wrap(A, "prepare", "arrivalPrepare", function(orig)
        return function(player, args, ...)
            if type(args) == "table" and (L.skyOn() or L.carsOff()) and L.heliKind(args) ~= nil and L.isGuard(args.factionId) then
                return L.asOwn(orig, player, args, ...)
            end
            return orig(player, args, ...)
        end
    end)
end
-- A-Life's own flights: natural (news, police, military, brigands) and routine flybys
function L.hookNatural(N)
    return wrap(N, "fire", "naturalFire", function(orig)
        return function(why, day, player, force, ...)
            if force ~= true and L.skyOn() and not L.isOwn() then
                L.metrics.naturalHeld = L.metrics.naturalHeld + 1
                if fn(N, "note") then return false, N.note("guard_only") end
                return false, "guard_only"
            end
            return orig(why, day, player, force, ...)
        end
    end)
end
function L.hookRole(R)
    return wrap(R, "fire", "roleFire", function(orig)
        return function(why, ...)
            if L.skyOn() and not L.isOwn() then
                L.metrics.roleHeld = L.metrics.roleHeld + 1
                if fn(R, "note") then return false, R.note("guard_only") end
                return false, "guard_only"
            end
            return orig(why, ...)
        end
    end)
end
-- backstop: any other ambient launch
function L.hookLaunch(H)
    return wrap(H, "launch", "heliLaunch", function(orig)
        return function(player, kind, variant, ambient, factionId, ...)
            if ambient == true and L.skyOn() and not L.isOwn() then
                L.metrics.ambientHeld = L.metrics.ambientHeld + 1
                return false, "guard_only"
            end
            return orig(player, kind, variant, ambient, factionId, ...)
        end
    end)
end
-- searchlight helicopters (support calls at night): only the Guard's
function L.hookSearch(D)
    return wrap(D, "start", "searchStart", function(orig)
        return function(spec, ...)
            if type(spec) == "table" and L.skyOn() and not L.isOwn() then
                local id = tostring(spec.id or "")
                if string.sub(id, 1, 6) ~= "debug-" and not L.isGuard(spec.factionId) then
                    L.metrics.searchHeld = L.metrics.searchHeld + 1
                    return nil, "guard_only"
                end
            end
            return orig(spec, ...)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- cars
----------------------------------------------------------------------------------------------------------------
function L.hookOptions(O)
    wrap(O, "carsEnabled", "carsEnabled", function(orig)
        return function(...)
            if L.carsOff() and not L.isOwn() then return false end
            return orig(...)
        end
    end)
    wrap(O, "carTrafficOff", "carTrafficOff", function(orig)
        return function(...)
            if L.carsOff() and not L.isOwn() then return true end
            return orig(...)
        end
    end)
    wrap(O, "carTrafficCount", "carTrafficCount", function(orig)
        return function(value, ...)
            if L.carsOff() and not L.isOwn() then return 0 end
            return orig(value, ...)
        end
    end)
    return wrap(O, "applyMasters", "applyMasters", function(orig)
        return function(current, ...)
            local r = orig(current, ...)
            if L.carsOff() and type(current) == "table" then L.zeroSwitches(current) end
            return r
        end
    end)
end
function L.zeroSwitches(current)
    for _, k in ipairs(L.CAR_SWITCHES) do current[k] = false end
    current.carScriptedDrive = 0
    current.carEncounterPercent = 0
end
-- Settings.current was read before we were here: switch it now, and give it back if the setting goes off
function L.applyLive()
    local S = PA() and PA().Settings
    local cur = type(S) == "table" and S.current or nil
    if type(cur) ~= "table" then return end
    if L.carsOff() then
        if L.saved == nil then
            L.saved = { carScriptedDrive = cur.carScriptedDrive, carEncounterPercent = cur.carEncounterPercent }
            for _, k in ipairs(L.CAR_SWITCHES) do L.saved[k] = cur[k] end
        end
        L.zeroSwitches(cur)
    elseif L.saved ~= nil then
        for k, v in pairs(L.saved) do cur[k] = v end
        L.saved = nil
        log("A-Life's own cars are back on (setting off)")
    end
end
function L.hookArrivals(A)
    wrap(A, "enabled", "arrivalsEnabled", function(orig)
        return function(...)
            if L.carsOff() and not L.isOwn() then L.metrics.arrivalsWalked = L.metrics.arrivalsWalked + 1; return false end
            return orig(...)
        end
    end)
    -- its tick cancels every plan while cars are off; the Guard's helicopter plans must survive it (car plans no
    -- longer get made, so opening the gate here changes nothing else)
    return wrap(A, "tickBody", "arrivalsTick", function(orig)
        return function(...)
            if L.carsOff() then return L.asOwn(orig, ...) end
            return orig(...)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "aircraftRefusal", "arrivalPrepare", "naturalFire", "roleFire", "heliLaunch", "searchStart",
    "carsEnabled", "carTrafficOff", "carTrafficCount", "applyMasters", "arrivalsEnabled", "arrivalsTick" }
function L.install()
    local m, pa = M(), PA()
    if type(m) == "table" and type(m.settings) == "table" then
        if m.settings.guardOnlySky == nil then m.settings.guardOnlySky = true end
        if m.settings.alifeCarsOff == nil then m.settings.alifeCarsOff = true end
    end
    if pa == nil then return 0, L.HOOKS end
    if type(pa.DebugService) == "table" then L.hookRefusal(pa.DebugService) end
    if type(pa.VehicleArrivals) == "table" then L.hookArrivalPrepare(pa.VehicleArrivals); L.hookArrivals(pa.VehicleArrivals) end
    if type(pa.HeliNatural) == "table" then L.hookNatural(pa.HeliNatural) end
    if type(pa.HeliRole) == "table" then L.hookRole(pa.HeliRole) end
    if type(pa.HeliArrival) == "table" then L.hookLaunch(pa.HeliArrival) end
    if type(pa.HeliDirector) == "table" then L.hookSearch(pa.HeliDirector) end
    if type(pa.Options) == "table" then L.hookOptions(pa.Options) end
    L.guard("applyLive", L.applyLive)
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
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or "")
            .. " (sky: " .. (L.skyOn() and "Guard only" or "A-Life") .. ", A-Life cars: " .. (L.carsOff() and "off" or "on") .. ")")
        return true
    end
    return false
end
function L.report()
    local t = L.metrics
    return "helis refused " .. t.heliRefused .. ", natural held " .. t.naturalHeld .. ", flybys held " .. t.roleHeld
        .. ", Guard flights " .. t.guardFlights .. ", car arrivals refused " .. t.carsRefused
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = nowMs()
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    -- the setting can be switched in game: follow it (cheap; no work when nothing changed)
    if Events.EveryTenMinutes ~= nil then
        Events.EveryTenMinutes.Add(function() L.guard("applyLive", L.applyLive) end)
    end
    if Events.EveryDays ~= nil then
        Events.EveryDays.Add(function() log(L.report()) end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
