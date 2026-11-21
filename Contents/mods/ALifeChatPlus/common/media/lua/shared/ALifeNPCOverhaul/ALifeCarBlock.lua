-- A-Life NPC Overhaul 0.8.11: CAR BLOCK. A hostile crew in a car stops in the road and fights from behind it.
-- Built on A-Life's car life (real cars only: ALifeRealCars keeps every made-up car out):
--   Chase: a car-life crew that's hostile to you, with you behind them in a moving car for carBlockChaseMs: one roll
--          per trip. Yes -> they stop and bail out (A-Life's "bail" exit: brake, everyone out fast, weapons out, cover
--          on the side of the car away from you).
--   Camp:  you drive at a hostile group's home (in a moving car, closing in): their nearest usable car gets an A-Life
--          car-life trip to a point on the road toward you (they run to it, get in - doors, keys, hotwiring, fuel all
--          A-Life's own - and drive). Close to the point, or to you, they do the same bail.
-- How: a "block" exit rule added to A-Life's CarLife.exitRules; CarLifeServer.feeds wrapped to say when; a "block"
-- destination kind (only we hand it out) so A-Life's own CarLifeServer.begin starts the trip; threatSide adapter for
-- the cover side. 0.8.11.1 swing (single player): before the stop, the live driving session (A-Life owner.sessions,
-- the one CarLife depart made) gets one last waypoint ahead and off to the side, as A-Life's own Blockade.dismount
-- rewrites s.route; the driver turns across the road, then the block exit brakes. MP: the session lives on the
-- driving client, so the car stops in its lane there. Unverified in game (needs a probe).
-- Any group with a car. Server / SP (where car life runs). Every number is a setting.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeFightBrain"

ALifeCarBlock = ALifeCarBlock or {}
local K = ALifeCarBlock
local B = ALifeFightBrain
local TAG = "[ALifeCarBlock]"
K.VERSION = ALifeSide.MOD_VERSION
K.metrics = K.metrics or { chaseSeen = 0, chaseBlocks = 0, campSeen = 0, campTrips = 0, campRefused = 0, bailed = 0 }
K.metrics.fleeTrips = K.metrics.fleeTrips or 0
K.metrics.fleeRefused = K.metrics.fleeRefused or 0
K.lastGap = K.lastGap or {}     -- "player|group" -> { d, atMs }
K.campAt = K.campAt or {}       -- groupId -> ms of their last camp block

K.DEFAULTS = {
    carBlock = true,             -- hostile crews stop their car in the road and fight from behind it
    carBlockChase = true,        -- ... when you chase them in a car
    carBlockCamp = true,         -- ... when you drive at their home: they drive out to block you
    carBlockChance = 50,         -- % per chase / per approach
    carBlockChaseMs = 6000,      -- you behind them this long (ms) before they decide
    carBlockKmh = 20,            -- your car must be doing at least this (km/h)
    carBlockCampReach = 250,     -- you this close to their home (tiles), closing in, in a car (0.8.11.1: 150 -> 250, earlier)
    carBlockCampAhead = 40,      -- the block point: this far from them toward you (tiles, at most half way)
    carBlockStopTiles = 20,      -- camp trips stop this close to the block point (tiles)
    carBlockMeetTiles = 30,      -- ... or this close to you (tiles)
    carBlockCampGapMs = 600000,  -- one camp block per group this often (ms)
    -- 0.8.11.1 car flee (brain setting carFlee): a group that breaks takes a car-life trip away from you
    carFleeTiles = 150,          -- ... this far away from you (tiles)
    carBlockSwing = true,        -- single player: they swing the car across the road before they stop
    carBlockSwingMs = 1500,      -- ... time they get to turn before the stop (ms)
    carBlockSwingTiles = 5,      -- ... how far off to the side they steer (tiles)
}
K.FILE_KEYS = {}
for k in pairs(K.DEFAULTS) do K.FILE_KEYS[#K.FILE_KEYS + 1] = k end
table.sort(K.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end

function K.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
function K.n(key) return num(K.setting(key), num(K.DEFAULTS[key], 0)) end
function K.on() return K.setting("carBlock") ~= false end

-- your car and its speed (km/h), or nil
function K.playerCar(player)
    local car = call(player, "getVehicle")
    if car == nil then return nil, 0 end
    return car, math.abs(num(call(car, "getCurrentSpeedKmHour"), 0))
end

-- car forward on the ground (A-Life: getForwardVector(Vector3f.new()), x / z)
function K.forward(car)
    local fx, fy = nil, nil
    pcall(function()
        local v = car:getForwardVector(Vector3f.new())
        fx, fy = v:x(), v:z()
    end)
    if fx == nil then return nil end
    local l = math.sqrt(fx * fx + fy * fy)
    if l < 0.0001 then return nil end
    return fx / l, fy / l
end

-- ---------------------------------------------------------------------------------------------------- chase
-- (called from the wrapped CarLifeServer.feeds; target = A-Life's own hostile-player pick for this trip)
function K.chase(trip, car, st, target, now)
    if trip.block ~= nil or trip.blockRolled or K.setting("carBlockChase") == false then return false end
    local player = type(target) == "table" and target.player or nil
    local pcar, kmh = K.playerCar(player)
    local behind = false
    if pcar ~= nil and kmh >= K.n("carBlockKmh") then
        local fx, fy = K.forward(car)
        local cx, cy = num(call(car, "getX"), nil), num(call(car, "getY"), nil)
        if fx ~= nil and cx ~= nil then behind = (target.x - cx) * fx + (target.y - cy) * fy < 0 end
    end
    if not behind then trip.chaseSinceMs = nil; return false end
    if trip.chaseSinceMs == nil then trip.chaseSinceMs = now; K.metrics.chaseSeen = K.metrics.chaseSeen + 1 end
    if now - trip.chaseSinceMs < K.n("carBlockChaseMs") then return false end
    trip.blockRolled = true
    if roll(100) >= K.n("carBlockChance") then return false end
    trip.block = { kind = "chase", player = player }
    K.metrics.chaseBlocks = K.metrics.chaseBlocks + 1
    log("car " .. tostring(trip.carId) .. " (group " .. tostring(trip.groupId) .. "): you're chasing them, they stop to fight")
    return true
end

-- camp trip: close to the block point or to you -> bail
function K.arrived(trip, st, target)
    if trip.block == nil or trip.block.kind ~= "camp" then return false end
    if num(st.destTiles, 1e9) <= K.n("carBlockStopTiles") then return true end
    return type(target) == "table" and num(target.dist, 1e9) <= K.n("carBlockMeetTiles")
end

-- 0.8.11.1 swing: A-Life's live driving session (single player: same Lua state). Blockade.dismount pattern: one
-- waypoint, navigation reset. A plain waypoint (not "dismount": the stop and the bail stay car life's).
function K.session(car)
    if not ALifeSide.sp() then return nil end
    local S = PA().CarLifeServer
    local owner = fn(S, "use") and S.use("owner") or nil
    local id = call(car, "getId")
    if type(owner) ~= "table" or type(owner.sessions) ~= "table" or id == nil then return nil end
    return owner.sessions[id]
end
function K.swing(trip, car, now)
    if K.setting("carBlockSwing") == false then return false end
    local s = K.session(car)
    if type(s) ~= "table" or s.bail ~= nil or s.braking or s.exitAt then return false end
    local fx, fy = K.forward(car)
    local cx, cy = num(call(car, "getX"), nil), num(call(car, "getY"), nil)
    if fx == nil or cx == nil then return false end
    -- turn away from your side (A-Life left = (fy, -fx)); nose ends up away from you, the body across the road
    local sign = (K.threatSide(trip, car) == "left") and -1 or 1
    local side, ahead = K.n("carBlockSwingTiles"), 3
    local x, y = cx + fx * ahead + fy * sign * side, cy + fy * ahead - fx * sign * side
    s.route, s.waypoint = { { x = x, y = y } }, 1
    local n = s.navigation
    if type(n) == "table" then
        n.path, n.search, n.reverse = nil, nil, nil
        n.offPath, n.retryAt, n.scanAt = true, 0, 0
        n.obstacle, n.clearDistance = nil, math.huge
    end
    s.reversing, s.plannedReverse = nil, nil
    K.metrics.swings = (K.metrics.swings or 0) + 1
    log("car " .. tostring(trip.carId) .. ": swings across the road")
    return true
end

function K.feeds(trip, car, st, rows, target, now)
    if not K.on() or type(st) ~= "table" or car == nil then return end
    -- swinging: the stop comes when the turn time is up
    if type(trip.block) == "table" and trip.block.swingUntilMs ~= nil then
        if now >= trip.block.swingUntilMs then st.blockNow = true end
        return
    end
    if K.chase(trip, car, st, target, now) or K.arrived(trip, st, target) then
        if type(target) == "table" and target.player ~= nil then trip.block.player = target.player end
        local ok, swung = pcall(K.swing, trip, car, now)
        if ok and swung then trip.block.swingUntilMs = now + K.n("carBlockSwingMs"); return end
        st.blockNow = true
    end
end

-- the cover side: away from you (left / right of the car; A-Life S.sidePoint's left = (fy, -fx))
function K.threatSide(trip, car)
    if type(trip) ~= "table" or trip.block == nil then return nil end
    local p = trip.block.player
    local px, py = num(call(p, "getX"), nil), num(call(p, "getY"), nil)
    local cx, cy = num(call(car, "getX"), nil), num(call(car, "getY"), nil)
    local fx, fy = K.forward(car)
    if px == nil or cx == nil or fx == nil then return nil end
    local lateral = (px - cx) * fy + (py - cy) * (-fx)
    if lateral >= 0 then return "left" end
    return "right"
end

-- ---------------------------------------------------------------------------------------------------- camp
local function recordOf(uid)
    local pa = PA()
    local reg = pa and pa.ActorRegistry or nil
    if not fn(reg, "read") then return nil end
    local ok, r = pcall(reg.read, tostring(uid))
    if ok then return r end
    return nil
end
function K.hostile(actor, player)
    local pa = PA()
    local rel = pa and pa.Relations or nil
    if not fn(rel, "hostileToPlayer") or actor == nil then return false end
    local ok, h = pcall(rel.hostileToPlayer, actor, player)
    return ok and h == true
end
-- a car-life group row at home: its leader within homeReach of their home / leash (as the fight brain's home turf)
function K.atHome(row)
    if type(row) ~= "table" or row.x == nil or type(row.members) ~= "table" or row.members[1] == nil then return nil end
    local rec = recordOf(row.members[1].uid)
    local mem = type(rec) == "table" and rec.memory or nil
    if type(mem) ~= "table" then return nil end
    local reach2 = B.n("homeReach") ^ 2
    for _, k in ipairs({ "home", "leash" }) do
        local p = mem[k]
        if type(p) == "table" and tonumber(p.x) and tonumber(p.y) and (row.x - p.x) ^ 2 + (row.y - p.y) ^ 2 <= reach2 then return rec end
    end
    if mem.outpostId ~= nil then return rec end
    return nil
end

-- the group's nearest usable car (within A-Life's noticeReach): car, info, gap / nil, why
function K.usableCar(S, row)
    local CL = PA().CarLife
    local carRow, gap = S.nearestCar(row)
    if carRow == nil or gap > num(CL.settings.noticeReach, 45) then return nil, "no_car" end
    local car = S.use("car", carRow.id)
    if car == nil then return nil, "no_car" end
    local info = S.use("carInfo", car, nil)
    if info.occupied or info.playerCar or info.upright == false or info.wrecked or info.tag ~= nil then return nil, "car_not_usable" end
    if S.use("inBase", info.x, info.y) == true then return nil, "car_in_base" end
    return car, info, gap
end

-- A-Life's own car-life trip to one point (a one-off site of our kind: the only one offered for this call)
function K.beginTo(S, row, car, info, kind, x, y, now)
    local CL = PA().CarLife
    local site = { kind = kind, x = x, y = y }
    site.tiles = math.sqrt((site.x - info.x) ^ 2 + (site.y - info.y) ^ 2)
    if CL.destKinds[kind] == nil then CL.destKinds[kind] = { weight = 1, minTiles = 0, maxTiles = 1200, mode = "ride" } end
    local opts = {}
    for k, v in pairs(S.options(now) or {}) do opts[k] = v end
    opts.ditch = false
    local prev = S.adapters.sites
    S.adapters.sites = function() return { site } end
    local ok, trip, why = pcall(S.begin, row, car, info, now, opts)
    S.adapters.sites = prev
    if not ok then return nil, tostring(trip) end
    if trip == nil then return nil, why or "refused" end
    return trip
end

-- start A-Life's own car-life trip to the block point (a "block" site)
function K.startCamp(S, row, player, now)
    local car, info = K.usableCar(S, row)
    if car == nil then return nil, info end
    local px, py = num(call(player, "getX"), nil), num(call(player, "getY"), nil)
    if px == nil then return nil, "no_player" end
    local d = math.sqrt((px - row.x) ^ 2 + (py - row.y) ^ 2)
    local t = math.min(0.5, K.n("carBlockCampAhead") / math.max(1, d))
    local trip, why = K.beginTo(S, row, car, info, "block", row.x + (px - row.x) * t, row.y + (py - row.y) * t, now)
    if trip == nil then return nil, why end
    trip.block = { kind = "camp", player = player }
    trip.blockRolled = true
    return trip
end

-- ---------------------------------------------------------------------------------------------------- car flee
-- 0.8.11.1: the 0.8.10c car flee hooked A-Life's CarLeaveServer, which only drives arrival / reinforcement / mission
-- cars (and ALifeAirspace shuts those), so it never fired. Now a broken group (fight brain "break", not faking) with a
-- usable car near takes an A-Life car-life trip AWAY from you: they run to it, get in (doors, keys, hotwire, fuel all
-- A-Life's own; its threat-near abort still holds) and drive. One look per fight. Brain setting carFlee.
function K.flee(gid, st, f, contact, now)
    if st.carFled or st.advisory or st.mood ~= "break" or st.fake ~= nil or st.phase ~= nil then return nil end
    if B.setting("carFlee") == false then return nil end
    local pa = PA()
    local S = pa and pa.CarLifeServer or nil
    if type(S) ~= "table" or type(S.groupRows) ~= "table" or type(S.byGroup) ~= "table" or not fn(S, "begin") then return nil end
    local row = nil
    for _, r in ipairs(S.groupRows) do if tostring(r.id) == tostring(gid) then row = r; break end end
    if row == nil or row.x == nil or row.excluded then return nil end
    st.carFled = true
    if S.byGroup[row.id] ~= nil then return nil, "already_driving" end
    local car, info = K.usableCar(S, row)
    if car == nil then K.metrics.fleeRefused = K.metrics.fleeRefused + 1; return nil, info end
    local tx, ty = num(call(contact.target, "getX"), nil), num(call(contact.target, "getY"), nil)
    if tx == nil and type(st.lastSeen) == "table" then tx, ty = st.lastSeen.x, st.lastSeen.y end
    if tx == nil then return nil, "no_threat" end
    local dx, dy = row.x - tx, row.y - ty
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.5 then dx, dy = info.x - tx, info.y - ty; l = math.sqrt(dx * dx + dy * dy) end
    if l < 0.5 then dx, dy, l = 1, 0, 1 end
    local reach = K.n("carFleeTiles")
    local trip, why = K.beginTo(S, row, car, info, "flee", row.x + dx / l * reach, row.y + dy / l * reach, now)
    if trip == nil then
        K.metrics.fleeRefused = K.metrics.fleeRefused + 1
        log("group " .. tostring(gid) .. ": no car run (" .. tostring(why) .. ")")
        return nil, why
    end
    trip.urgent = true
    trip.blockRolled = true -- a run, not a block: no chase block on this trip
    K.metrics.fleeTrips = K.metrics.fleeTrips + 1
    log("group " .. tostring(gid) .. ": broken, they run for car " .. tostring(trip.carId) .. " and drive off")
    return trip
end

function K.campTick(now)
    if not K.on() or K.setting("carBlockCamp") == false then return end
    local pa = PA()
    local S = pa and pa.CarLifeServer or nil
    if type(S) ~= "table" or type(S.groupRows) ~= "table" or not fn(S, "begin") then return end
    local reach = K.n("carBlockCampReach")
    for _, player in ipairs(B.players()) do
        local pcar, kmh = K.playerCar(player)
        local px, py = num(call(player, "getX"), nil), num(call(player, "getY"), nil)
        local pkey = tostring(call(player, "getUsername") or "p0")
        if pcar ~= nil and kmh >= K.n("carBlockKmh") and px ~= nil then
            -- 0.8.11.1: crews already next to their car go first (on the road sooner); one block per player per check
            local cands = {}
            for _, row in ipairs(S.groupRows) do
                if row.x ~= nil and S.byGroup[row.id] == nil and now >= num(K.campAt[row.id], -1e12) + K.n("carBlockCampGapMs") then
                    local d = math.sqrt((px - row.x) ^ 2 + (py - row.y) ^ 2)
                    local key = pkey .. "|" .. tostring(row.id)
                    local last = K.lastGap[key]
                    K.lastGap[key] = { d = d, atMs = now }
                    local closing = last ~= nil and now - last.atMs <= 5000 and last.d - d >= 3
                    if d <= reach and closing then
                        local rec = K.atHome(row)
                        if rec ~= nil and K.hostile(rec, player) then
                            local _, gap = S.nearestCar(row)
                            cands[#cands + 1] = { row = row, gap = num(gap, 1e9) }
                        end
                    end
                end
            end
            table.sort(cands, function(a, b) return a.gap < b.gap end)
            for _, c in ipairs(cands) do
                local row = c.row
                K.campAt[row.id] = now
                K.metrics.campSeen = K.metrics.campSeen + 1
                if roll(100) < K.n("carBlockChance") then
                    local trip, why = K.startCamp(S, row, player, now)
                    if trip ~= nil then
                        K.metrics.campTrips = K.metrics.campTrips + 1
                        log("group " .. tostring(row.id) .. ": you're driving at their home, they take car " .. tostring(trip.carId) .. " to block you")
                        break
                    end
                    K.metrics.campRefused = K.metrics.campRefused + 1
                    log("group " .. tostring(row.id) .. ": no block (" .. tostring(why) .. ")")
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------- install
K.RULE = { id = "block", mode = "bail", chance = 1, fixed = true, test = function(f) return f.blockNow == true end }
function K.hook()
    if K.hooked then return true end
    local pa = PA()
    local CL, S = pa and pa.CarLife or nil, pa and pa.CarLifeServer or nil
    if type(CL) ~= "table" or type(CL.exitRules) ~= "table" or not fn(S, "feeds") or type(S.adapters) ~= "table" then return false end
    local have = false
    for _, r in ipairs(CL.exitRules) do if r.id == "block" then have = true end end
    if not have then
        local at = #CL.exitRules + 1
        for i, r in ipairs(CL.exitRules) do if r.id == "player_stop" then at = i; break end end
        table.insert(CL.exitRules, at, K.RULE)
    end
    if S.feeds_ALifeCarBlock == nil then
        local orig = S.feeds
        S.feeds = function(trip, car, st, rows, target, now, ...)
            local a, b = orig(trip, car, st, rows, target, now, ...)
            local ok, e = pcall(K.feeds, trip, car, st, rows, target, now)
            if not ok and not K.failLogged then K.failLogged = true; log("feeds failed (once): " .. tostring(e)) end
            return a, b
        end
        S.feeds_ALifeCarBlock = orig
        local prevSide = S.adapters.threatSide
        S.adapters.threatSide = function(trip, car, ...)
            local ok, side = pcall(K.threatSide, trip, car)
            if ok and side ~= nil then
                K.metrics.bailed = K.metrics.bailed + 1
                return side
            end
            if type(prevSide) == "function" then return prevSide(trip, car, ...) end
            if type(S.defaults.threatSide) == "function" then return S.defaults.threatSide(trip, car, ...) end
            return nil
        end
    end
    K.hooked = true
    log("hooked A-Life car life (exit rule block, feeds, cover side)")
    return true
end
-- car flee rides on the brain's think (server / SP)
function K.hookBrain()
    if K.brainHooked or not fn(B, "thinkGroup") then return K.brainHooked == true end
    local orig = B.thinkGroup
    B.thinkGroup = function(groupId, contact, now, ...)
        local st, f = orig(groupId, contact, now, ...)
        if K.hooked and type(st) == "table" and type(contact) == "table" and st.mood == "break" and not st.carFled then
            local ok, e = pcall(K.flee, groupId, st, f, contact, now)
            if not ok and not K.fleeFailLogged then K.fleeFailLogged = true; log("car run failed (once): " .. tostring(e)) end
        end
        return st, f
    end
    K.brainHooked = true
    return true
end
K.hookBrain()
K.tries = K.tries or 0
function K.tryHook()
    if K.hooked or K.gaveUp then return end
    K.tries = K.tries + 1
    if K.hook() then return end
    if K.tries >= 600 then
        K.gaveUp = true
        if ALifeSide.world() then log("A-Life car life not found: car block off") end
    end
end
K.tryHook()
if type(Events) == "table" and Events.OnTick ~= nil then
    Events.OnTick.Add(function()
        if not K.hooked then if not K.gaveUp then K.tryHook() end return end
        if not B.authoritative() then return end
        local now = B.nowMs()
        if now < num(K.nextCampMs, 0) then return end
        K.nextCampMs = now + 2000
        local ok, e = pcall(K.campTick, now)
        if not ok and not K.campFailLogged then K.campFailLogged = true; log("camp check failed (once): " .. tostring(e)) end
    end)
end
print(TAG .. " ready v" .. K.VERSION .. ": hostile crews stop in the road and fight from behind the car (chase, camp), broken groups drive off, hook " .. (K.hooked and "on" or "waiting"))

return K
