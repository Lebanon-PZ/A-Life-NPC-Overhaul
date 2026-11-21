-- A-Life NPC Overhaul 0.6.5: NOMADS. When the land runs dry, people move.
--
-- A group that is starving and has stripped everything around its house doesn't just scatter any more: it packs up
-- what it really has (its stash, its people, its squads) and walks the roads toward a part of the map that still has
-- unlooted buildings, and settles there. Same people, same name, same beliefs, grudges and friendships; the old house
-- is left behind (empty: they took the stash). Nothing is made: the stash moves, the people move.
--   * only off-screen: you're never next to the house they leave or the one they move into
--   * on the road for a day or a few (about 250 tiles a day): no foraging, they eat from what they carry
--   * a group with unlooted buildings still around it doesn't move: it scatters like before (starving, but the
--     problem isn't the land)
--   * the Airport never moves; setting "nomads" turns it all off
-- OUTPOSTS (below): big groups send a few people to hold police stations, army posts, clinics, gas stations...
-- Performance: the search for a new place runs once, when a group would otherwise give up, and at most once an
-- in-game hour across the whole world (a few hundred building look-ups, no square scans).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Nomads") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Nomads"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Nomads") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("nomads: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "road") end end

if M.settings.nomads == nil then M.settings.nomads = true end
M.nmCfg = {
    tilesPerDay = 250,                 -- fallback pace (no travel-time module): tiles a day
    hoursOnTheMove = 10,               -- 0.6.6: a household on the road walks about 10 hours a day (road distance, walking pace)
    dists = { 350, 700 },              -- how far they look for a new place
    angles = 8,
    strippedRadii = { 20, 45, 80 },    -- "nothing left around here": fewer than strippedMin unlooted buildings in these rings
    strippedMin = 2,
    destRadii = { 0, 20, 40, 60 }, destAngles = 6, destMin = 3, -- a place worth going: at least destMin unlooted buildings
    playerFar = 300,                   -- never pick a place near you
    baseFar = 200,                     -- or on top of another group
    searchEveryH = 1,                  -- world-wide: one search an hour at most
    retryH = 6,
}
M.nmStats = { searches = 0, left = 0, arrived = 0, scattered = 0, notStripped = 0, noPlace = 0, lookups = 0 }
M.nmEndWord = "they packed up and moved on"
if type(M.nbEndWords) == "table" then M.nbEndWords.moved = M.nmEndWord end

local function playerXY()
    local x, y = nil, nil
    pcall(function()
        local n = getNumActivePlayers()
        for i = 0, n - 1 do
            local p = getSpecificPlayer(i)
            if p then x, y = p:getX(), p:getY(); return end
        end
    end)
    return x, y
end
local function playerNear(x, y, r)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then return ALifeSide.nearest(x, y, r) ~= nil end -- MP: any online player
    local px, py = playerXY()
    return px ~= nil and d2(px, py, x, y) <= r * r
end
local function D() return type(ALifeDerelict) == "table" and fn(ALifeDerelict, "findNear") and ALifeDerelict or nil end
local function unlooted(x, y, n, radii, angles)
    local der = D()
    if der == nil then return 0 end
    M.nmStats.lookups = M.nmStats.lookups + 1
    local ok, list = pcall(der.findNear, x, y, n, radii, angles)
    return ok and type(list) == "table" and #list or 0
end
local function baseNear(x, y, r, except)
    local st = M.nbStore and M.nbStore() or nil
    for id, o in pairs(st and st.byId or {}) do
        if type(o) == "table" and o.status == "active" and id ~= except and tonumber(o.x) and d2(o.x, o.y, x, y) <= r * r then return true end
        if type(o) == "table" and type(o.road) == "table" and o.road.dest and d2(o.road.dest.x, o.road.dest.y, x, y) <= r * r then return true end
    end
    return false
end

function M.nmStripped(b)
    local cfg = M.nmCfg
    return unlooted(b.x, b.y, cfg.strippedMin, cfg.strippedRadii, cfg.angles) < cfg.strippedMin
end
-- where to go: the direction with the most unlooted buildings, far from you and from other groups
function M.nmFindDest(b, n, h)
    local cfg = M.nmCfg
    M.nmStats.searches = M.nmStats.searches + 1
    local best, bs = nil, -1e9
    for _, dist in ipairs(cfg.dists) do
        for a = 0, cfg.angles - 1 do
            local ang = (a + (hash(b.id) % 100) / 100) * 2 * math.pi / cfg.angles
            local x, y = math.floor(b.x + math.cos(ang) * dist), math.floor(b.y + math.sin(ang) * dist)
            if not playerNear(x, y, cfg.playerFar) and not baseNear(x, y, cfg.baseFar, b.id) then
                local cnt = unlooted(x, y, 5, cfg.destRadii, cfg.destAngles)
                if cnt >= cfg.destMin then
                    local s = cnt * 10 - dist / 100 + (hash(b.id .. ":" .. a .. ":" .. dist) % 100) / 100
                    if s > bs then best, bs = { x = x, y = y, cnt = cnt }, s end
                end
            end
        end
    end
    if best == nil or not fn(M, "nbChooseHouse") then return nil end
    local ok, c = pcall(M.nbChooseHouse, { x = best.x, y = best.y }, n, h)
    if not ok or type(c) ~= "table" then return nil end
    return { x = best.x, y = best.y, key = c.key, why = c.why,
        bounds = { x1 = c.bounds.x1, y1 = c.bounds.y1, x2 = c.bounds.x2, y2 = c.bounds.y2 },
        center = { x = c.center.x, y = c.center.y } }
end

-- the moment a group would give up: if the land is the problem, they leave instead. true = they're on the road.
function M.nmTryLeave(b, h)
    if M.settings.nomads == false or type(b) ~= "table" or b.status ~= "active" or b.airport or b.road then return false end
    if (tonumber(b.crewN) or 0) < 1 then return false end
    if playerNear(b.x, b.y, (M.nbCfg and M.nbCfg.farTiles) or 150) then return false end
    if (tonumber(b.nmTriedH) or -1e9) > h - M.nmCfg.retryH then return false end
    if (tonumber(M.nmSearchH) or -1e9) > h - M.nmCfg.searchEveryH then return false end
    b.nmTriedH = h
    if not M.nmStripped(b) then M.nmStats.notStripped = M.nmStats.notStripped + 1; return false end
    M.nmSearchH = h
    local dest = M.nmFindDest(b, math.max(1, tonumber(b.crewN) or 1), h)
    if dest == nil then M.nmStats.noPlace = M.nmStats.noPlace + 1; return false end
    local dist = math.sqrt(d2(b.x, b.y, dest.center.x, dest.center.y))
    -- 0.6.6: the real road distance at walking pace, about 10 hours on the move a day (a whole household, loaded)
    local travelH = dist / M.nmCfg.tilesPerDay * 24
    if fn(M, "travelH") then local okT, th, tiles = pcall(M.travelH, b.x, b.y, dest.center.x, dest.center.y, b); if okT and tonumber(th) then travelH = th * 24 / M.nmCfg.hoursOnTheMove; dist = tiles end end
    b.road = { dest = dest, leftH = h, at = h + travelH, dist = math.floor(dist) }
    -- 0.6.17: the whole household is on the road (not sitting in the old house until they arrive)
    if fn(M, "lvSend") then
        pcall(function()
            for _, r in ipairs(M.nbScan(true).crews[b.id] or {}) do
                if r.lifecycle ~= "dead" and not r.virtual then M.lvSend(r.uid, { tx = dest.center.x, ty = dest.center.y, untilH = b.road.at, tag = "nomads" }) end
            end
        end)
    end
    b.starveH = 0
    M.nmStats.left = M.nmStats.left + 1
    event(b, "Nothing left to find around here. They packed what they had and took to the road", "road")
    log((b.name or b.id) .. " left for (" .. math.floor(dest.center.x) .. "," .. math.floor(dest.center.y) .. "), " .. b.road.dist .. " tiles")
    return true
end

-- on the road: no foraging, no fortifying; they eat from what they carry. Arrive when it's time.
function M.nmRoadStep(b, haven, crew, dt, h)
    local n = math.max(1, #(crew or {}))
    local need = n * dt / 24
    local eaten = fn(M, "nbFoodTake") and (M.nbFoodTake(b, need, haven) or 0) or 0
    local short = need - eaten
    b.morale = math.max(0, math.min(100, (tonumber(b.morale) or 50) - (short > need * 0.5 and 4 or 1) * dt / 24))
    if h >= (tonumber(b.road.at) or 0) then return M.nmArrive(b, h) end
end

local function stashOf(haven, create) return fn(M, "nbStashList") and M.nbStashList(haven, create) or nil end

function M.nmMove(b, c, h)
    local hv = PA().Havens
    local old = fn(M, "nbHavenOf") and M.nbHavenOf(b) or nil
    local scan = M.nbScan(true)
    local members = {}
    for _, r in ipairs(scan.crews[b.id] or {}) do if r.lifecycle ~= "dead" and not r.virtual then members[#members + 1] = r end end
    local squads = {}
    for _, sid in ipairs(type(b.squads) == "table" and b.squads or {}) do squads[#squads + 1] = sid end
    -- what they carry: taken out of the old stash before the old house is given up
    local carry = {}
    local ls = old and stashOf(old) or nil
    if ls then for i = 1, #ls do carry[#carry + 1] = ls[i] end; for i = #ls, 1, -1 do ls[i] = nil end end
    local rations = tonumber(b.rations) or 0
    b.rations = 0
    local oldId, oldName = b.id, b.name
    M.nbAbandon(b, "moved")
    local ok, haven2, b2 = pcall(M.nbCreate, "nomad:" .. tostring(oldId), members, c, h, "came from " .. tostring(oldName))
    if not ok or type(b2) ~= "table" then
        log("could not settle " .. tostring(oldName) .. ": " .. tostring(haven2) .. " (they scattered)")
        M.nmStats.scattered = M.nmStats.scattered + 1
        return nil
    end
    if fn(M, "lvCancel") then for _, r in ipairs(members) do M.lvCancel(r.uid) end end -- 0.6.17: off the road, moved in
    local ns = stashOf(haven2, true)
    if ns then for i = 1, #carry do ns[#ns + 1] = carry[i] end
    elseif #carry > 0 then log("nowhere to put " .. #carry .. " carried items at " .. tostring(haven2.id) .. " (kept as food where possible)")
        local fi = 0; for _, it in ipairs(carry) do if fn(M, "nbIsFood") and M.nbIsFood(type(it) == "table" and it.type or it) then fi = fi + 1 end end
        rations = rations + fi * ((M.nbCfg and M.nbCfg.foodPerItem) or 0.25) end
    b2.rations = rations
    -- the same group: name, beliefs, standing, history
    local events = {}
    for _, e in ipairs(type(b.events) == "table" and b.events or {}) do if e.k ~= "ended" then events[#events + 1] = e end end
    for _, k in ipairs({ "dir", "trade", "rep", "known", "faction", "absorbed", "visits", "by", "pins" }) do if b[k] ~= nil then b2[k] = b[k] end end
    b2.name = oldName
    b2.maxCrewN = math.max(tonumber(b.maxCrewN) or 0, tonumber(b2.maxCrewN) or 0)
    b2.morale = math.min(100, (tonumber(b.morale) or 40) + 10)
    b2.events = events
    b2.movedFrom, b2.moves = oldId, (tonumber(b.moves) or 0) + 1
    b.movedTo = b2.id
    if type(b.roster) == "table" then
        b2.roster = type(b2.roster) == "table" and b2.roster or {}
        for k, e in pairs(b.roster) do if b2.roster[k] == nil and type(e) == "table" and e.sq then b2.roster[k] = e end end
    end
    -- everyone who knew them by their old house knows them by the new one
    local st = M.nbStore()
    for _, o in pairs(st.byId) do
        if type(o) == "table" and type(o.dir) == "table" then
            if type(o.dir.ties) == "table" and o.dir.ties[oldId] ~= nil then o.dir.ties[b2.id] = o.dir.ties[oldId]; o.dir.ties[oldId] = nil end
            local g = o.dir.goals
            for _, w in pairs(type(g) == "table" and g or {}) do if type(w) == "table" and w.target == oldId then w.target = b2.id end end
        end
    end
    -- their A-Life squads come along
    local depot = type(haven2.depot) == "table" and { x = haven2.depot.x, y = haven2.depot.y, z = haven2.depot.z } or { x = c.center.x, y = c.center.y, z = 0 }
    local led = PA().SquadLedger
    if fn(M, "sbHomeSquad") and type(led) == "table" and fn(led, "peek") then
        for _, sid in ipairs(squads) do
            local q = led.peek(sid)
            if q and q.state ~= "wiped" then pcall(M.sbHomeSquad, q, b2, depot, h) end
        end
    end
    if fn(M, "nbFoodSync") then pcall(M.nbFoodSync, b2, haven2) end
    event(b2, "They came here from their old place after the land there ran dry (" .. tostring(b.road and b.road.dist or "?") .. " tiles on foot)", "road")
    M.nbScanCache = nil
    M.nmStats.arrived = M.nmStats.arrived + 1
    log(tostring(oldName) .. " settled at " .. tostring(b2.id) .. " with " .. #members .. " people, " .. #carry .. " items")
    return b2
end

function M.nmArrive(b, h)
    local road = b.road
    local c = road and road.dest
    if type(c) ~= "table" then b.road = nil; return end
    -- you're there, or someone took it: look again around the same spot, or wait a few hours
    local bad = playerNear(c.center.x, c.center.y, (M.nbCfg and M.nbCfg.farTiles) or 150) and "player"
        or (fn(M, "nbExcluded") and select(2, pcall(M.nbExcluded, c, h))) or nil
    if bad == false then bad = nil end
    if bad then
        if bad == "player" then road.at = h + 6; return end
        local ok, c2 = pcall(M.nbChooseHouse, { x = c.x, y = c.y }, math.max(1, tonumber(b.crewN) or 1), h)
        if not ok or type(c2) ~= "table" then
            b.road = nil
            M.nmStats.scattered = M.nmStats.scattered + 1
            return M.nbAbandon(b, "starved")
        end
        c = { x = c.x, y = c.y, key = c2.key, why = c2.why, bounds = c2.bounds, center = c2.center }
    end
    b.road = road
    return M.nmMove(b, c, h)
end

function M.nmWords(b)
    if type(b) ~= "table" then return nil end
    if b.road then return "on the road, looking for a new place after the land ran dry" end
    if b.outpostOf and b.opWhat then return "holding the " .. tostring(b.opWhat) .. " as an outpost for the rest of your people" end
    if b.movedFrom then return "moved here after the land around their old place ran dry" end
    return nil
end
function M.nmPerf()
    local s = M.nmStats
    return "nomads: searches " .. s.searches .. ", left " .. s.left .. ", arrived " .. s.arrived .. ", scattered " .. s.scattered
        .. ", stayed (land not stripped) " .. s.notStripped .. ", no place " .. s.noPlace .. ", look-ups " .. s.lookups
end


----------------------------------------------------------------------------------------------------------------
-- OUTPOSTS. A big group holds the places that matter.
-- A group of 6+ that's fed and steady sends 2-3 of its own people to hold a small base at a place worth holding:
-- a police station, an army site, a fire station, a clinic, a gas station, a hardware store, a warehouse. They take a
-- real share of the stash. The main base sends food when the outpost runs short (from its own surplus). An outpost
-- about to starve is called home (its people and stash go back). If the main base falls, the outpost goes on alone.
----------------------------------------------------------------------------------------------------------------
if M.settings.outposts == nil then M.settings.outposts = true end
M.opCfg = { minCrew = 6, keepHome = 4, perDayChance = 0.15, everyH = 168, dists = { 150, 300, 500 }, angles = 8,
    probeRadii = { 0, 12, 25, 40 }, probeAngles = 8, maxArea = 2500, playerFar = 300, baseFar = 100,
    foodEach = 2, supplyLow = 2, supplyHigh = 4, supplyDays = 3 }
M.opPOI = { -- room-name piece -> what the place is, how much it's worth holding
    { "police", "police station", 10 }, { "army", "army post", 10 }, { "military", "army post", 10 }, { "armory", "armory", 10 },
    { "gunstore", "gun store", 9 }, { "fire", "fire station", 7 }, { "medical", "clinic", 7 }, { "clinic", "clinic", 7 },
    { "hospital", "hospital", 7 }, { "pharmac", "pharmacy", 7 }, { "gasstore", "gas station", 6 }, { "gas", "gas station", 5 },
    { "tool", "hardware store", 5 }, { "hardware", "hardware store", 5 }, { "warehouse", "warehouse", 5 }, { "grocer", "grocery", 4 },
    { "mechanic", "garage", 4 }, { "farm", "farm", 3 },
}
M.opStats = { searches = 0, founded = 0, recalled = 0, alone = 0, supplies = 0, lookups = 0 }
if type(M.nbEndWords) == "table" then M.nbEndWords.recalled = "its people were called home" end

local function poiOf(def)
    local rooms = fn(M, "nbDefRooms") and M.nbDefRooms(def) or {}
    local best, bs = nil, 0
    for _, r in ipairs(rooms) do
        for _, p in ipairs(M.opPOI) do
            if p[3] > bs and string.find(r, p[1], 1, true) then best, bs = p[2], p[3] end
        end
    end
    return best, bs
end
local function outpostsOf(b)
    local n, st = 0, M.nbStore()
    for _, o in pairs(st.byId) do if type(o) == "table" and o.status == "active" and o.outpostOf == b.id then n = n + 1 end end
    return n
end
function M.opFindSpot(b, h)
    local cfg = M.opCfg
    M.opStats.searches = M.opStats.searches + 1
    local best, bs, seen = nil, 0, {}
    for _, dist in ipairs(cfg.dists) do
        for a = 0, cfg.angles - 1 do
            local ang = (a + (hash(b.id .. "op") % 100) / 100) * 2 * math.pi / cfg.angles
            local x, y = b.x + math.cos(ang) * dist, b.y + math.sin(ang) * dist
            if not playerNear(x, y, cfg.playerFar) then
                for _, r in ipairs(cfg.probeRadii) do
                    for k = 0, (r == 0 and 0 or cfg.probeAngles - 1) do
                        local aa = k * 2 * math.pi / cfg.probeAngles
                        local def = nil
                        M.opStats.lookups = M.opStats.lookups + 1
                        pcall(function() def = getWorld():getMetaGrid():getBuildingAt(math.floor(x + math.cos(aa) * r), math.floor(y + math.sin(aa) * r)) end)
                        if def then
                            local bb = nil
                            pcall(function() bb = { x1 = def:getX(), y1 = def:getY(), x2 = def:getX2(), y2 = def:getY2() } end)
                            local key = bb and (bb.x1 .. ":" .. bb.y1)
                            if key and not seen[key] then
                                seen[key] = true
                                local area = (bb.x2 - bb.x1 + 1) * (bb.y2 - bb.y1 + 1)
                                local what, worth = poiOf(def)
                                local s = worth - dist / 250
                                if what and area <= cfg.maxArea and s > bs then
                                    local c = { key = key, bounds = bb, center = { x = (bb.x1 + bb.x2) / 2, y = (bb.y1 + bb.y2) / 2 }, why = { what } }
                                    local ex = fn(M, "nbExcluded") and select(2, pcall(M.nbExcluded, c, h)) or nil
                                    if not ex and not baseNear(c.center.x, c.center.y, cfg.baseFar, nil) then best, bs = { c = c, what = what, score = s }, s end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end
local function pickCrew(b, n)
    local scan = M.nbScan(true)
    local list = {}
    for _, r in ipairs(scan.crews[b.id] or {}) do
        if r.lifecycle ~= "dead" and not r.virtual and tostring(r.uid) ~= tostring(b.leader) then list[#list + 1] = r end
    end
    table.sort(list, function(x, y) return hash(tostring(x.uid) .. "op") < hash(tostring(y.uid) .. "op") end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end
function M.opFound(b, h)
    local cfg = M.opCfg
    local crewN = tonumber(b.crewN) or 0
    local spot = M.opFindSpot(b, h)
    if spot == nil then return nil end
    local go = pickCrew(b, crewN >= 8 and 3 or 2)
    if #go < 2 or crewN - #go < cfg.keepHome then return nil end
    local ok, haven2, o = pcall(M.nbCreate, "outpost:" .. tostring(b.id), go, spot.c, h, "sent by " .. tostring(b.name) .. " to hold the " .. spot.what)
    if not ok or type(o) ~= "table" then log("outpost failed for " .. tostring(b.name) .. ": " .. tostring(haven2)); return nil end
    o.outpostOf, o.opWhat = b.id, spot.what
    o.name = tostring(b.name) .. " (" .. spot.what .. ")"
    o.faction, o.trade, o.rep, o.known = b.faction, b.trade, b.rep, nil
    local d = type(b.dir) == "table" and b.dir or {}
    o.dir = { creed = d.creed, rule = d.rule, ties = { [b.id] = 90 }, goals = {} }
    b.dir = d; d.ties = type(d.ties) == "table" and d.ties or {}; d.ties[o.id] = 90
    -- a real share of the stash goes with them: food (a couple of days each), a box of ammo if there's any
    local from, to = M.nbHavenOf(b), haven2
    local fs, ts = from and stashOf(from), stashOf(to, true)
    local food, ammo, wantFood = 0, 0, #go * cfg.foodEach * 4
    if fs and ts then
        for i = #fs, 1, -1 do
            local t = type(fs[i]) == "table" and fs[i].type or fs[i]
            local k = fn(M, "nbKindOf") and M.nbKindOf(t) or nil
            if (k == "food" and food < wantFood) or (k == "ammo" and ammo < 1) then
                ts[#ts + 1] = table.remove(fs, i)
                if k == "food" then food = food + 1 else ammo = ammo + 1 end
            end
        end
    end
    pcall(M.nbFoodSync, b, from); pcall(M.nbFoodSync, o, to)
    b.opLastH = h
    o.events = {}
    event(o, #go .. " of " .. tostring(b.name) .. " came to hold the " .. spot.what, "outpost")
    event(b, "Sent " .. #go .. " people to hold the " .. spot.what, "outpost")
    M.opStats.founded = M.opStats.founded + 1
    M.nbScanCache = nil
    log(tostring(b.name) .. " sent " .. #go .. " to the " .. spot.what .. " (" .. tostring(o.id) .. "), " .. food .. " food, " .. ammo .. " ammo")
    return o
end
local function parentOf(o)
    local st, seen, id = M.nbStore(), 0, o.outpostOf
    local p = id and st.byId[id] or nil
    while type(p) == "table" and p.status ~= "active" and p.movedTo and seen < 5 do seen = seen + 1; id = p.movedTo; p = st.byId[id] end
    if type(p) == "table" and p.status == "active" then
        if id ~= o.outpostOf then o.outpostOf = id; if type(o.dir) == "table" and type(o.dir.ties) == "table" then o.dir.ties[id] = 90 end end
        return p
    end
    return nil
end
-- once a day per base (cheap): found an outpost, keep one supplied, or let it go on alone
function M.opDaily(b, h, far)
    if M.settings.outposts == false or type(b) ~= "table" or b.status ~= "active" then return end
    local day = math.floor(h / 24)
    if b.opDay == day then return end
    b.opDay = day
    if b.outpostOf then
        local p = parentOf(b)
        if p == nil then
            b.outpostOf = nil
            M.opStats.alone = M.opStats.alone + 1
            event(b, "No word from their people. They hold the " .. tostring(b.opWhat or "place") .. " on their own now", "outpost")
            return
        end
        local per = (tonumber(b.food) or 0) / math.max(1, tonumber(b.crewN) or 1)
        local pper = (tonumber(p.food) or 0) / math.max(1, tonumber(p.crewN) or 1)
        if per < M.opCfg.supplyLow and pper > M.opCfg.supplyHigh and p.road == nil then
            local want = math.max(0, (tonumber(b.crewN) or 1) * M.opCfg.supplyDays - (tonumber(b.food) or 0))
            local spare = ((tonumber(p.food) or 0) - (tonumber(p.crewN) or 1) * M.opCfg.supplyHigh)
            local amt = math.min(want, math.max(0, spare))
            if amt > 0.25 then
                local got = M.nbFoodTake(p, amt, M.nbHavenOf(p)) or 0
                local added = M.nbFoodAdd(b, got) or 0
                if added > 0 then M.opStats.supplies = M.opStats.supplies + 1; event(b, "Supplies came from " .. tostring(p.name), "outpost") end
            end
        end
        return
    end
    local cfg = M.opCfg
    if b.airport or b.road or not far or (tonumber(b.crewN) or 0) < cfg.minCrew or (tonumber(b.morale) or 0) < 50 then return end
    if (tonumber(b.food) or 0) / math.max(1, tonumber(b.crewN) or 1) < 3 then return end
    if h - (tonumber(b.opLastH) or -1e9) < cfg.everyH then return end
    if outpostsOf(b) >= math.min(2, 1 + math.floor(((tonumber(b.crewN) or 0) - cfg.minCrew) / 3)) then return end
    if ALifeRoll01(b.id .. "#op#" .. day) >= cfg.perDayChance then return end
    if (tonumber(M.nmSearchH) or -1e9) > h - M.nmCfg.searchEveryH then return end
    M.nmSearchH = h
    b.opLastH = h -- tried: wait a week either way
    return M.opFound(b, h)
end
-- an outpost about to starve: called home (people and stash go back) instead of scattering
function M.opRecall(o)
    local p = parentOf(o)
    if p == nil or not fn(M, "nbAbsorb") then return false end
    local ok, res = pcall(M.nbAbsorb, p, o, hours())
    if not ok or not res then return false end
    o.endReason = "recalled"
    if type(o.events) == "table" and o.events[#o.events] and o.events[#o.events].k == "ended" then o.events[#o.events].t = "Left behind: " .. M.nbEndWords.recalled end
    event(p, "Called their people home from the " .. tostring(o.opWhat or "outpost"), "outpost")
    M.opStats.recalled = M.opStats.recalled + 1
    return true
end
function M.opPerf()
    local s = M.opStats
    return "outposts: searches " .. s.searches .. ", founded " .. s.founded .. ", supplied " .. s.supplies .. ", recalled " .. s.recalled
        .. ", on their own " .. s.alone .. ", look-ups " .. s.lookups
end

----------------------------------------------------------------------------------------------------------------
-- hooks: wrap, never replace (marked so a reload never double-wraps)
----------------------------------------------------------------------------------------------------------------
M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeNomads] " .. where .. " failed, nomads off for this session: " .. tostring(a)) end
    return ok and a or nil
end
function M.nmInstall()
    if M._alcpHooks.nomads or type(M.nbStep) ~= "function" or type(M.nbAbandon) ~= "function" then return false end
    M._alcpHooks.nomads = true
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        if type(b) == "table" and type(b.road) == "table" and not broken then
            guard("road", M.nmRoadStep, b, haven, crew, dt, h)
            return
        end
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        if type(b) == "table" and b.status == "active" and not broken then guard("outposts", M.opDaily, b, h, far) end
        return r
    end
    local abandon = M.nbAbandon
    M.nbAbandon = function(b, reason, ...)
        if reason == "starved" and type(b) == "table" and not b.road and not broken then
            if b.outpostOf and guard("recall", M.opRecall, b) == true then return end
            if not b.outpostOf and guard("leave", M.nmTryLeave, b, hours()) == true then return end
        end
        return abandon(b, reason, ...)
    end
    print("[ALifeNomads] loaded v" .. ALifeSide.MOD_VERSION .. " (starving groups on stripped land move on; big groups hold outposts)")
    return true
end
if not M.nmInstall() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.nmInstall() end) end
