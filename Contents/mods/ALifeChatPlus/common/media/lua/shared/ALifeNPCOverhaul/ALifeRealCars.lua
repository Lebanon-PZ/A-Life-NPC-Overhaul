-- A-Life NPC Overhaul 0.8.4: NPCS TAKE REAL CARS.
-- 0.8.0 switched A-Life's cars off entirely (ALifeAirspace), because A-Life made cars out of nothing. That also
-- switched off A-Life's own "car life": NPC groups noticing a real parked car, getting in (open door, their key,
-- forcing or smashing a window), starting it (keys in it, their key, hotwiring), topping up the tank (a pump,
-- or siphoning another car) and driving it somewhere. All real cars.
-- This puts car life back and keeps every made-up car out:
--   * Car life on (setting realCars): A-Life's CarLife reads its options with the car gate open.
--   * Offline trips on for real cars: a car someone drove out of sight still travels (CarOffline), and is rebuilt
--     where it really ends up: the same car moved, never a second one.
--   * Never a new car: CarOffline's createCar refuses every record marked newCar (A-Life's seeded traffic, faction
--     rides, start cars). Its other spawn paths (arrivals, camp/outpost cars, drive-bys) stay shut by ALifeAirspace.
--   * No made-up keys: a car taken through car life leaves only if it's hotwired, the keys are in it, or one of them
--     carries its key (A-Life would otherwise make a key on the spot).
--   * Siphoning needs a hose and a can on one of them; a pump further than a few tiles needs a can.
--   * Your cars are left alone: cars you drove in the last realCarsPlayerHours, cars inside your base, our caravans'
--     own cars and the car someone is coming to pick you up in.
-- Every hook wraps A-Life's own function or uses its adapter slots, returns its result, and switches itself off if
-- it errors. Server/SP only (A-Life's car life runs on the authority).

require "ALifeNPCOverhaul/AA_Side"
ALifeRealCars = ALifeRealCars or {}
local R = ALifeRealCars
local TAG = "[ALifeRealCars]"
R.VERSION = ALifeSide.MOD_VERSION

-- settings (they live with the rest of the mod's settings; these are only the defaults; A-Life's own values)
R.DEFAULTS = {
    realCars = true,            -- NPC groups take real parked cars (A-Life's car life)
    realCarsReach = 45,         -- tiles: how close a parked car must be for a group to notice it
    realCarsChance = 20,        -- % per look (a group looks every 20 s while travelling) that they go for it
    realCarsTrips = 6,          -- most groups on a car trip at once
    realCarsPlayerHours = 72,   -- game hours after you were in a car that nobody takes it
    realCarsKeys = true,        -- no made-up keys: hotwired, keys in it, or they carry its key
    realCarsSiphonKit = true,   -- siphoning another car needs a hose and a can on one of them
    realCarsPumpReach = 4,      -- tiles: a pump further than this needs a can carried to it
    realCarsBaseMargin = 10,    -- tiles around your base where nobody takes a car
}
R.FILE_KEYS = { "realCars", "realCarsReach", "realCarsChance", "realCarsTrips", "realCarsPlayerHours", "realCarsKeys",
    "realCarsSiphonKit", "realCarsPumpReach", "realCarsBaseMargin" }

R.off, R.hooked = R.off or {}, R.hooked or {}
R.metrics = R.metrics or { newRefused = 0, moved = 0, keyRefused = 0, siphonNoKit = 0, pumpNoCan = 0, baseKept = 0, oursKept = 0 }
R.inDepart = false

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function A() return ALifeAirspace end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end

function R.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = R.DEFAULTS[key] end
    return v
end
function R.on() return R.setting("realCars") ~= false end
function R.carsOff() local a = A(); return fn(a, "carsOff") and a.carsOff() == true end
function R.isOwn() local a = A(); return fn(a, "isOwn") and a.isOwn() == true end
-- our rules apply while A-Life's own cars are off (with them on, A-Life decides everything as it always did)
function R.active() return R.carsOff() and R.on() and not R.isOwn() end
-- run f with ALifeAirspace's car gate open for this one call
local function open(f, ...)
    local a = A()
    if fn(a, "asOwn") then return a.asOwn(f, ...) end
    return f(...)
end

function R.guard(name, f, ...)
    if R.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        R.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end

local function wrap(tbl, name, hookName, make)
    if R.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__RealCars"] = orig
    R.hooked[hookName] = true
    return true
end
-- fill one of A-Life's adapter slots (S.use(name) asks adapters first, then its defaults)
local function adapt(S, name, hookName, make)
    if R.hooked[hookName] then return true end
    if type(S) ~= "table" or type(S.adapters) ~= "table" or type(S.defaults) ~= "table" then return false end
    if S.adapters[name] ~= nil then log("adapter '" .. name .. "' already taken by another mod: left alone"); R.hooked[hookName] = true; return true end
    if not fn(S.defaults, name) then return false end
    S.adapters[name] = make(S.defaults)
    R.hooked[hookName] = true
    return true
end

----------------------------------------------------------------------------------------------------------------
-- car life options: on with A-Life's cars off, our numbers
----------------------------------------------------------------------------------------------------------------
function R.tune(CL, S)
    if type(CL) == "table" and type(CL.settings) == "table" then
        CL.settings.noticeReach = math.max(5, num(R.setting("realCarsReach"), 45))
        CL.settings.noticeChance = math.max(0, math.min(100, num(R.setting("realCarsChance"), 20))) / 100
    end
    if type(S) == "table" and type(S.settings) == "table" then
        S.settings.tripCap = math.max(0, math.floor(num(R.setting("realCarsTrips"), 6)))
        S.settings.playerCarHours = math.max(0, num(R.setting("realCarsPlayerHours"), 72))
    end
end
function R.options(CL, S)
    if not R.carsOff() then return CL.opts() end -- A-Life's cars on: its own sandbox decides
    local o = open(CL.opts)
    if type(o) ~= "table" then o = {} end
    o.life = R.on()
    R.tune(CL, S)
    return o
end

----------------------------------------------------------------------------------------------------------------
-- your cars, your base, our cars
----------------------------------------------------------------------------------------------------------------
local function pickupKey(x, y) return math.floor(x / 4) .. "," .. math.floor(y / 4) end -- ALifePickup's keyAt
function R.ours(car)
    local mine = false
    pcall(function()
        if car:hasModData() and car:getModData().ALCPPaperCar ~= nil then mine = true end -- a caravan's own car
    end)
    if mine then return true end
    local P = ALifePickup
    local p = type(P) == "table" and P.pending or nil
    if type(p) == "table" and p.carKey ~= nil then
        pcall(function() if pickupKey(car:getX(), car:getY()) == p.carKey then mine = true end end) -- someone is coming for you in it
    end
    return mine
end
-- inside (or within realCarsBaseMargin of) any player's marked base / safehouse / claimed base
function R.inPlayerBase(x, y, players)
    local M = ALifeLLMTalk
    if not fn(M, "playerBase") or type(players) ~= "table" then return false end
    local margin = num(R.setting("realCarsBaseMargin"), 10)
    for _, player in ipairs(players) do
        local ok, b, kind = pcall(M.playerBase, player)
        if ok and type(b) == "table" and kind ~= "building" and tonumber(b.x1) and tonumber(b.y1) and tonumber(b.x2) and tonumber(b.y2) then
            if x >= b.x1 - margin and x <= b.x2 + margin and y >= b.y1 - margin and y <= b.y2 + margin then return true end
        end
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- what they carry: a hose and a can (the same test as our "siphon that car" command)
----------------------------------------------------------------------------------------------------------------
function R.crewKit(S, trip)
    local hose, can = nil, nil
    local K = ALifeCommands
    if not fn(K, "siphonKit") or not fn(S, "members") then return nil, nil end
    local ok, rows = pcall(S.members, trip)
    if not ok or type(rows) ~= "table" then return nil, nil end
    for _, row in ipairs(rows) do
        if row.shell ~= nil and not row.dead then
            local h, c = K.siphonKit(row.shell)
            hose, can = hose or h, can or c
        end
    end
    return hose, can
end
function R.filterFuel(S, src, trip)
    if type(src) ~= "table" or not R.active() then return src end
    local hose, can = R.crewKit(S, trip)
    if src.donor ~= nil and R.setting("realCarsSiphonKit") ~= false and not (hose ~= nil and can ~= nil) then
        src.donor = nil
        R.metrics.siphonNoKit = R.metrics.siphonNoKit + 1
    end
    if type(src.pump) == "table" and num(src.pump.distance, 0) > num(R.setting("realCarsPumpReach"), 4) and can == nil then
        src.pump = nil
        R.metrics.pumpNoCan = R.metrics.pumpNoCan + 1
    end
    src.canPct = 0 -- A-Life has no real can here (no default); a number from elsewhere would be fuel from nowhere
    return src
end

----------------------------------------------------------------------------------------------------------------
-- hooks
----------------------------------------------------------------------------------------------------------------
function R.hookCarLife(pa)
    local CL, S = pa.CarLife, pa.CarLifeServer
    if type(CL) ~= "table" or type(S) ~= "table" then return end
    adapt(S, "options", "options", function(D)
        return function(...)
            local ok, o = R.guard("options", R.options, CL, S)
            if ok and type(o) == "table" then return o end
            return D.options(...)
        end
    end)
    adapt(S, "inBase", "inBase", function(D)
        return function(x, y, ...)
            if D.inBase(x, y, ...) == true then return true end
            if not R.active() then return false end
            local ok, players = pcall(S.use, "players")
            local okB, yes = R.guard("inBase", R.inPlayerBase, x, y, ok and players or nil)
            if okB and yes then R.metrics.baseKept = R.metrics.baseKept + 1; return true end
            return false
        end
    end)
    adapt(S, "carInfo", "carInfo", function(D)
        return function(car, trip, ...)
            local info = D.carInfo(car, trip, ...)
            if trip == nil and type(info) == "table" and R.active() then
                local ok, mine = R.guard("ours", R.ours, car)
                if ok and mine then info.playerCar = true; R.metrics.oursKept = R.metrics.oursKept + 1 end
            end
            return info
        end
    end)
    adapt(S, "fuelSources", "fuelSources", function(D)
        return function(car, trip, info, ...)
            local src = D.fuelSources(car, trip, info, ...)
            local ok, out = R.guard("fuelSources", R.filterFuel, S, src, trip)
            if ok then return out end
            return src
        end
    end)
    adapt(S, "depart", "depart", function(D)
        return function(...)
            R.inDepart = true
            local r = { pcall(D.depart, ...) }
            R.inDepart = false
            if not r[1] then error(r[2], 0) end
            return r[2], r[3]
        end
    end)
end

function R.hookOffline(pa)
    local CO = pa.CarOffline
    if type(CO) ~= "table" then return end
    wrap(CO, "enabled", "offlineEnabled", function(orig)
        return function(...)
            if R.active() then return open(orig, ...) end
            return orig(...)
        end
    end)
    if type(CO.world) == "table" then
        wrap(CO.world, "createCar", "createCar", function(orig)
            return function(rec, ...)
                if R.carsOff() and not R.isOwn() then
                    if type(rec) ~= "table" or rec.newCar == true then
                        R.metrics.newRefused = R.metrics.newRefused + 1
                        if R.metrics.newRefused <= 5 then
                            log("refused a car from nothing (" .. tostring(type(rec) == "table" and rec.script or "?") .. ")")
                        end
                        return nil, "new_car_refused"
                    end
                    if not R.on() then return orig(rec, ...) end -- A-Life's gate says no, as in 0.8.0
                    R.metrics.moved = R.metrics.moved + 1
                    return open(orig, rec, ...)
                end
                return orig(rec, ...)
            end
        end)
    end
end

function R.hookKeys(pa)
    local K = pa.VehicleArrivalKeys
    if type(K) ~= "table" then return end
    wrap(K, "grant", "keys", function(orig)
        return function(car, npc, actor, ...)
            if R.inDepart and R.active() and R.setting("realCarsKeys") ~= false then
                local have, hot, ign = false, false, false
                pcall(function() have = npc:getInventory():haveThisKeyId(car:getKeyId()) ~= nil end)
                if not have then
                    pcall(function() hot = car:isHotwired() == true; ign = car:isKeysInIgnition() == true end)
                    if hot or ign then return true end -- runs without a key in their pocket
                    R.metrics.keyRefused = R.metrics.keyRefused + 1
                    return false, "no_key"
                end
            end
            return orig(car, npc, actor, ...)
        end
    end)
end

R.HOOKS = { "options", "inBase", "carInfo", "fuelSources", "depart", "offlineEnabled", "createCar", "keys" }
function R.install()
    local pa = PA()
    if pa == nil then return 0, R.HOOKS end
    if ALifeSide.client() then R.client = true; return 0, {} end -- car life runs on the server
    -- the server files that hold car life and its keys load after shared/: ask for them by name
    pcall(require, "ProjectALife/Driving/ALifeCarLifeServer")
    pcall(require, "ProjectALife/Driving/ALifeCarLifeActions")
    pcall(require, "ProjectALife/Driving/ALifeCarOfflineServer")
    pcall(require, "ProjectALife/Driving/ALifeVehicleArrivalKeys")
    R.hookCarLife(pa)
    R.hookOffline(pa)
    R.hookKeys(pa)
    local n, missing = 0, {}
    for _, h in ipairs(R.HOOKS) do if R.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end
R.tries = 0
function R.tryInstall()
    R.tries = R.tries + 1
    local ok, n, missing = pcall(R.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if R.client then log("ready v" .. R.VERSION .. ": client, nothing to hook (car life runs on the server)"); return true end
    if #missing == 0 or R.tries >= 20 then
        log("ready v" .. R.VERSION .. ": " .. n .. "/" .. #R.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or "")
            .. " (NPCs take real cars: " .. ((R.carsOff() and R.on()) and "on" or (R.carsOff() and "off" or "A-Life decides")) .. ")")
        return true
    end
    return false
end
function R.report()
    local t = R.metrics
    return "cars moved " .. t.moved .. ", cars from nothing refused " .. t.newRefused .. ", made-up keys refused " .. t.keyRefused
        .. ", siphon without hose+can " .. t.siphonNoKit .. ", far pump without can " .. t.pumpNoCan
        .. ", left alone: in your base " .. t.baseKept .. ", ours " .. t.oursKept
end

if type(Events) == "table" then
    local function start()
        if R.started then return end -- OnGameStart and OnServerStarted can both fire
        R.started = true
        if R.tryInstall() then return end
        if Events.OnTick == nil then return end
        local last = 0
        local function retry()
            local now = 0
            pcall(function() now = getTimestampMs() end)
            if now - last < 500 then return end
            last = now
            if R.tryInstall() then Events.OnTick.Remove(retry) end
        end
        Events.OnTick.Add(retry)
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(start) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(start) end
    if Events.EveryDays ~= nil then Events.EveryDays.Add(function() log(R.report()) end) end
end
print(TAG .. " loaded v" .. R.VERSION)
