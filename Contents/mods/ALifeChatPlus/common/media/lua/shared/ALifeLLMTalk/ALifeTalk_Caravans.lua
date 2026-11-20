-- A-Life NPC Overhaul 0.6.6: CARAVANS. Real people, real goods.
--
-- With the Jeem Extension's trader visits on, the traders who come to your base are no longer made up. A real NPC
-- group nearby (one of the bases this mod runs) sends real members of its own, carrying a real share of its stash:
--   * who comes: dormant members of that group (never its leader, never everyone; at least one stays home). If no group
--     within reach can spare people and goods, nobody comes. The world being empty means no traders.
--   * what they sell: things out of that group's stash, taken out when they leave home. What you buy is gone from them.
--   * what you pay: goes back into their stash (Jeem's visits used to delete it). Unsold goods go home too.
--   * leaving: Jeem's visit walks them off as before, but instead of being taken off the map they walk home.
--   * what they buy follows what the group is: farmers sell food, crafters tools, traders a bit of everything.
-- Jeem still does the walking, the trade window, prices by your standing, fleeing when attacked. A group whose people
-- you hurt stops coming (Jeem's ban), and a dead caravan member is a real death in that group.
-- Off screen, groups that trade also run goods between each other (CARAVANS BETWEEN GROUPS, below): surplus for what
-- they lack, on paper, and a warband nearby may rob the run.
-- Performance: one pick per visit Jeem would start (a list walk over active bases); the off-screen runs once a day
-- per trading group.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Caravans") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Caravans"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Caravans") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("caravans: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "trade") end end
local function copy(v, depth)
    if type(v) ~= "table" or (depth or 0) > 6 then return v end
    local o = {}; for k, x in pairs(v) do o[k] = copy(x, (depth or 0) + 1) end; return o
end
local function JM() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end

if M.settings.caravans == nil then M.settings.caravans = true end
M.cvCfg = {
    rangeTiles = 1500,       -- how far a group will send people to trade with you
    party = 3,               -- at most this many come
    keepHome = 1,            -- at least this many stay home
    share = 0.5,             -- of each kind of thing they can spare, this much goes with them
    foodKeepDays = 5,        -- food they keep for themselves (days a head) before selling any
    rows = 12, perRow = 6,   -- at most this many kinds of goods, this many of each
    minGoods = 4,            -- fewer than this to sell: they don't come
    paidCap = 200,
}
-- 0.6.6: TRAVEL TIME. Everything that goes between places takes the real time to get there: the road distance on
-- A-Life's road graph (its cached shortest routes; straight line x1.3 when there's no graph) at walking pace, or at
-- driving pace for a group with a vehicle (vehicles arrive with 0.6.9; until then they walk).
M.travelCfg = { walkTilesPerH = 150, driveTilesPerH = 900, offRoad = 1.3, cacheMax = 200 }
M.travelCache, M.travelCacheN = {}, 0
function M.roadTiles(ax, ay, bx, by)
    local key = math.floor(ax / 50) .. ":" .. math.floor(ay / 50) .. ">" .. math.floor(bx / 50) .. ":" .. math.floor(by / 50)
    local c = M.travelCache[key]
    if c then return c end
    local straight = math.sqrt(d2(ax, ay, bx, by))
    local tiles = straight * M.travelCfg.offRoad
    local G = PA().RoadGraph
    if fn(G, "nearest") and fn(G, "treeFrom") then
        pcall(function()
            local from, d1 = G.nearest(ax, ay)
            local to, d3 = G.nearest(bx, by)
            if from and to then
                local tree = G.treeFrom(from)
                local d = tree and tree.distances and tree.distances[to]
                if tonumber(d) and d < math.huge then
                    local road = (tonumber(d1) or 0) * M.travelCfg.offRoad + d + (tonumber(d3) or 0) * M.travelCfg.offRoad
                    if road >= straight then tiles = road end
                end
            end
        end)
    end
    if M.travelCacheN >= M.travelCfg.cacheMax then M.travelCache, M.travelCacheN = {}, 0 end
    M.travelCache[key], M.travelCacheN = tiles, M.travelCacheN + 1
    return tiles
end
-- hours to get from (ax, ay) to (bx, by); b = the group travelling (drives if it has a working vehicle: b.vehicle)
function M.travelH(ax, ay, bx, by, b)
    local tiles = M.roadTiles(ax, ay, bx, by)
    local drive = type(b) == "table" and b.vehicle ~= nil and b.vehicle ~= false
    local speed = drive and (tonumber(M.settings.driveTilesPerH) or M.travelCfg.driveTilesPerH) or (tonumber(M.settings.walkTilesPerH) or M.travelCfg.walkTilesPerH)
    speed = math.max(10, speed)
    return tiles / speed, tiles, drive and "drive" or "walk"
end
M.cvStats = { trips = 0, waited = 0, gaveUp = 0, picked = 0, noSource = 0, came = 0, home = 0, sold = 0, paid = 0, returned = 0, runs = 0, robbed = 0 }
M.cvKind = { food = "food", water = "food", meds = "medical", ammo = "ammo", tools = "other", materials = "other", other = "other" }
M.cvArchetype = { farmers = "food", crafters = "tools", traders = "general", warband = "gunsmith", slavers = "gunsmith" }

local function stashOf(haven, create) return fn(M, "nbStashList") and M.nbStashList(haven, create) or nil end
local function typeOf(it) return type(it) == "table" and it.type or it end
local function kindOf(t) return fn(M, "nbKindOf") and M.nbKindOf(t) or "other" end
local function homeOf(id)
    local st = M.nbStore and M.nbStore() or nil
    local b, n = st and st.byId[id] or nil, 0
    while type(b) == "table" and b.status ~= "active" and b.movedTo and n < 5 do n = n + 1; b = st.byId[b.movedTo] end
    return type(b) == "table" and b.status == "active" and b or nil
end

local function boxCenter(V, base)
    if type(base) == "table" and base.own then return tonumber(base.x), tonumber(base.y) end -- 0.6.18: our own visits (no Jeem)
    local box = fn(V, "box") and V.box(base.id) or nil
    if type(box) ~= "table" then return nil end
    return (box.x1 + box.x2) / 2, (box.y1 + box.y2) / 2
end
-- who could come: dormant, real, not the leader
local function travellers(b, n)
    local scan = M.nbScan()
    local out = {}
    local shellFor = PA().Talk and PA().Talk.shellFor
    for _, r in ipairs(scan.crews[b.id] or {}) do
        if r.lifecycle == "dormant" and not r.virtual and tostring(r.uid) ~= tostring(b.leader) then
            local m = type(r.memory) == "table" and r.memory or {}
            local onScreen = false
            if type(shellFor) == "function" then pcall(function() onScreen = shellFor(tostring(r.uid)) ~= nil end) end
            if not onScreen and m.squadId == nil and m.jimmyTrader == nil and m.alcpCaravan == nil and m.alcpTrip == nil then out[#out + 1] = r end
        end
    end
    table.sort(out, function(x, y) return hash(tostring(x.uid) .. "cv") < hash(tostring(y.uid) .. "cv") end)
    while #out > n do table.remove(out) end
    return out
end
-- what they can spare: { [type] = n } (their food for foodKeepDays a head stays home)
function M.cvSpare(b, haven)
    local list = stashOf(haven)
    local spare, total = {}, 0
    if list == nil then return spare, 0 end
    local foodKeep = math.floor((tonumber(b.crewN) or 1) * M.cvCfg.foodKeepDays / ((M.nbCfg and M.nbCfg.foodPerItem) or 0.25))
    local food = 0
    local byType = {}
    for _, it in ipairs(list) do local t = typeOf(it); if t then byType[t] = (byType[t] or 0) + 1 end end
    for t, n in pairs(byType) do
        local k = kindOf(t)
        local give = math.floor(n * M.cvCfg.share)
        if k == "food" or k == "water" then
            local can = math.max(0, n - math.max(0, foodKeep - food))
            food = food + n
            give = math.min(give, can)
        end
        give = math.min(give, M.cvCfg.perRow)
        if give > 0 then spare[t] = give; total = total + give end
    end
    return spare, total
end
-- the group that comes to the Jeem base at (x, y), or nil
function M.cvPick(x, y, h, only)
    local best, bs = nil, -1e9
    local cfg = M.cvCfg
    for _, b in ipairs(M.nbActive and M.nbActive() or {}) do
        if (only == nil or only == b.id) and (only ~= nil or not fn(M, "tpKnows") or M.tpKnows(b, x, y, h)) and not b.airport and not b.road and not b.outpostOf and tonumber(b.x)
                and d2(b.x, b.y, x, y) <= (tonumber(M.settings.caravanTiles) or cfg.rangeTiles) ^ 2 then
            local creed = type(b.dir) == "table" and b.dir.creed or nil
            local friendly = (tonumber(b.rep) or 50) >= 40 and b.trade ~= "warband" and b.trade ~= "slavers"
                and (creed ~= "closed" and creed ~= "raiders" or b.trade == "traders")
            if friendly and (tonumber(b.crewN) or 0) > cfg.keepHome and (tonumber(b.cvAwayUntil) or -1e9) < h then
                local haven = M.nbHavenOf(b)
                local spare, total = M.cvSpare(b, haven)
                if total >= cfg.minGoods then
                    local s = total + (b.trade == "traders" and 50 or 0) + (tonumber(b.rep) or 50) / 5 - math.sqrt(d2(b.x, b.y, x, y)) / 100
                    if s > bs then
                        local who = travellers(b, math.min(cfg.party, (tonumber(b.crewN) or 0) - cfg.keepHome))
                        if #who >= 1 then best, bs = { b = b, haven = haven, spare = spare, who = who }, s end
                    end
                end
            end
        end
    end
    return best
end
-- take the goods out of their stash: Jeem's stock rows { fullType, kind, value, count, carrier }
function M.cvLoad(src, archetype, carriers)
    local G = JM() and JM().TraderGoods
    local list = stashOf(src.haven)
    local rows, byType = {}, {}
    if list == nil then return rows end
    local order = {}
    for t, n in pairs(src.spare) do order[#order + 1] = { t = t, n = n } end
    table.sort(order, function(a, c) if a.n ~= c.n then return a.n > c.n end return a.t < c.t end)
    for i = 1, math.min(#order, M.cvCfg.rows) do byType[order[i].t] = order[i].n end
    local taken = {}
    for i = #list, 1, -1 do
        local t = typeOf(list[i])
        if t and (byType[t] or 0) > 0 then
            byType[t] = byType[t] - 1
            taken[t] = (taken[t] or 0) + 1
            table.remove(list, i)
        end
    end
    local n = 0
    for t, c in pairs(taken) do
        n = n + 1
        local kind = M.cvKind[kindOf(t)] or "other"
        local value = 1
        if type(ALifeWorth) == "table" and M.settings.itemWorth ~= false then value = math.max(0.1, (ALifeWorth.of(t))) -- 0.6.14
        elseif G and fn(G, "resaleValue") then local ok, v = pcall(G.resaleValue, t, kind, archetype); if ok and tonumber(v) then value = tonumber(v) end end
        rows[#rows + 1] = { fullType = t, kind = kind, value = value, count = c, carrier = ((n - 1) % math.max(1, carriers)) + 1 }
    end
    table.sort(rows, function(a, c) return a.fullType < c.fullType end)
    pcall(M.nbFoodSync, src.b, src.haven)
    return rows
end
local function trips()
    local st = M.nbStore()
    st.cvTrips = type(st.cvTrips) == "table" and st.cvTrips or {}
    st.cvBack = type(st.cvBack) == "table" and st.cvBack or {}
    return st.cvTrips, st.cvBack
end
M.cvTrips = trips
-- goods going home: they land in the stash when the walk back is done
local function sendBack(homeId, items, fromX, fromY, h, why, repD, repWhy)
    local b = homeOf(homeId)
    if b == nil or (#items == 0 and repD == nil) then return 0 end
    local _, back = trips()
    local th = M.travelH(fromX, fromY, b.x, b.y, b)
    -- 0.6.19: held chokepoints on the way home: a toll, or a robbery
    if fn(M, "chkPass") and #items > 0 then
        local okP, left, what = pcall(M.chkPass, b, items, fromX, fromY, b.x, b.y, math.floor(h / 24))
        if okP and type(left) == "table" then items = left; if what then why = (why and (why .. "; ") or "") .. what end end
    end
    back[#back + 1] = { home = homeId, items = items, at = h + th, why = why, rep = repD, repWhy = repWhy }
    return #items
end
M.cvSendBack = function(...) return sendBack(...) end
local function land(entry)
    local b = homeOf(entry.home)
    if b == nil then return 0 end
    local haven = M.nbHavenOf(b)
    local list = stashOf(haven, true) or {}
    for _, t in ipairs(entry.items) do list[#list + 1] = { type = t } end
    pcall(M.nbFoodSync, b, haven)
    if tonumber(entry.rep) and fn(M, "nbRep") then pcall(M.nbRep, b, entry.rep, entry.repWhy) end -- 0.6.7: the news they carried home
    M.cvStats.returned = M.cvStats.returned + #entry.items
    if entry.why then event(b, entry.why, "trade") end
    return #entry.items
end
-- goods (rows still in stock + what was paid) go home (they get there when the walk back is done)
function M.cvUnload(visit)
    local a = type(visit) == "table" and visit.alcp or nil
    if type(a) ~= "table" or a.unloaded then return 0 end
    a.unloaded = true
    local items = {}
    for _, row in ipairs(type(visit.stock) == "table" and visit.stock or {}) do
        for _ = 1, math.max(0, math.floor(tonumber(row.count) or 0)) do items[#items + 1] = row.fullType end
        row.count = 0
    end
    for _, t in ipairs(type(a.paid) == "table" and a.paid or {}) do items[#items + 1] = t end
    -- 0.6.7: you hurt them. Anyone who got away carries the news home; if nobody did, nobody ever knows, but the
    -- caravans stop coming (they never came back)
    local repD, repWhy = nil, nil
    if a.wronged then
        local alive = 0
        for _, m in ipairs(type(visit.members) == "table" and visit.members or {}) do if not m.dead then alive = alive + 1 end end
        if alive > 0 then
            repD = a.wronged == "member_killed" and -40 or -20
            repWhy = a.wronged == "member_killed" and "You killed one of their traders" or "You attacked their traders"
        else
            local b = homeOf(a.home)
            if b then b.cvAwayUntil = hours() + 24 * 7; event(b, "Their traders never came back", "trade") end
            items = {}
        end
    end
    return sendBack(a.home, items, tonumber(a.x) or 0, tonumber(a.y) or 0, hours(),
        a.wronged and "Their traders came back hurt and angry" or ("Their traders came home: sold " .. tostring(visit.sold or 0) .. ", brought back " .. #(a.paid or {}) .. " in trade"),
        repD, repWhy)
end

-- a group sets out for the Jeem base: picks its people, packs the goods (out of the stash now), walks the road
-- 0.6.8: trips are keyed "jeemBase>group" (several groups can be on their way to one base: market days)
function M.cvTripFor(baseId, groupId)
    local t = trips()
    for _, trip in pairs(t) do
        if (trip.baseId or "") == baseId and (groupId == nil or trip.home == groupId) then return trip end
    end
    return nil
end
function M.cvSetOut(base, h, only, tag)
    local V = JM() and JM().Traders and JM().Traders.visits
    local x, y = boxCenter(V, base)
    if x == nil then return "no_areas" end
    local src = M.cvPick(x, y, h, only or M.cvOnly)
    if src == nil then M.cvStats.noSource = M.cvStats.noSource + 1; return "no_caravan" end
    local arch = M.cvArchetype[src.b.trade] or "general"
    local rows = M.cvLoad(src, arch, #src.who)
    local th, tiles, mode = M.travelH(src.b.x, src.b.y, x, y, src.b)
    local uids = {}
    for _, r in ipairs(src.who) do uids[#uids + 1] = tostring(r.uid) end
    local tripsT = trips()
    local trip = { own = base.own == true or nil, baseId = base.id, home = src.b.id, uids = uids, rows = rows, archetype = arch, leftH = h, at = h + th, tiles = math.floor(tiles), mode = mode, x = x, y = y }
    if type(tag) == "table" then for k, v in pairs(tag) do trip[k] = v end end
    tripsT[base.id .. ">" .. src.b.id] = trip
    -- 0.6.17: they leave home now and are on the road until they get there (meet them on the way)
    if fn(M, "lvSend") then
        for _, uid in ipairs(uids) do pcall(M.lvSend, uid, { tx = x, ty = y, untilH = trip.at, tag = "caravan_out" }) end
    end
    src.b.cvAwayUntil = h + th * 2 + 30
    M.cvStats.trips = M.cvStats.trips + 1
    event(src.b, "Sent " .. #uids .. " people with goods to trade at a base " .. math.floor(tiles) .. " tiles away (" .. mode .. ")", "trade")
    log(tostring(src.b.name) .. " set out for " .. tostring(base.id) .. ": " .. #uids .. " people, " .. #rows .. " kinds of goods, "
        .. math.floor(tiles) .. " tiles, " .. (ALifeFmtDec and ALifeFmtDec(th, 1) or tostring(math.floor(th))) .. " h")
    return "on_the_way"
end
-- at the gate: the same people (still alive, still at home in the registry: dormant)
function M.cvTripSource(trip)
    local b = homeOf(trip.home)
    if b == nil then return nil end
    local reg = PA().ActorRegistry
    local who = {}
    for _, uid in ipairs(trip.uids or {}) do
        local r = reg.read(uid)
        if r and r.lifecycle == "dormant" then who[#who + 1] = r end
    end
    if #who == 0 then return nil end
    return { b = b, haven = M.nbHavenOf(b), spare = {}, who = who }
end
local WAIT = { night = true, nobody_home = true, busy = true, cooldown = true, day_cap = true, crowded = true, alife_trader = true,
    too_early = true, raided = true, visiting = true, no_spot = true }
M.cvCfg.waitH = 48
-- every ten minutes: trips that got there try to arrive; goods walking home land
function M.cvTick()
    if broken then return end
    local J = JM()
    local V = J and J.Traders and J.Traders.visits
    local h = hours()
    local tripsT, back = trips()
    for i = #back, 1, -1 do if h >= (tonumber(back[i].at) or 0) then land(back[i]); table.remove(back, i) end end
    local jeem = type(V) == "table" and fn(V, "start")
    local keys = {}
    for tripKey in pairs(tripsT) do keys[#keys + 1] = tripKey end
    for _, tripKey in ipairs(keys) do
        local trip = tripsT[tripKey]
        local baseId = trip.baseId or tripKey
        if (jeem or trip.own) and h >= (tonumber(trip.at) or 0) and h >= (tonumber(trip.nextH) or 0) then
            local base = (not trip.own) and J and J.BaseAreas and fn(J.BaseAreas, "base") and J.BaseAreas.base(baseId) or nil
            local visit, why = nil, base and nil or "base_gone"
            if trip.own then -- 0.6.18: our own visit (no Jeem): they come to your trading post / base and trade face to face
                if fn(M, "ovArrive") then
                    local ok, v, w = pcall(M.ovArrive, trip, h)
                    if ok then visit, why = v, w else why = "error"; print("[ALifeCaravans] own visit failed: " .. tostring(v)) end
                else why = "base_gone" end
            elseif base then
                M.cvArriving = trip
                local ok, v, w = pcall(V.start, base, h, fn(V, "players") and V.players() or {}, {})
                M.cvArriving = nil
                if ok then visit, why = v, w else why = "error"; fail("arrive", v) end
            end
            if visit then
                tripsT[tripKey] = nil
                M.cvLastVisit = visit
            elseif WAIT[why] and h - trip.at < M.cvCfg.waitH then
                trip.nextH = h + 1
                M.cvStats.waited = M.cvStats.waited + 1
            else
                -- they gave up and walk home with the goods
                tripsT[tripKey] = nil
                M.cvStats.gaveUp = M.cvStats.gaveUp + 1
                local items = {}
                for _, row in ipairs(trip.rows or {}) do for _ = 1, math.max(0, tonumber(row.count) or 0) do items[#items + 1] = row.fullType end end
                sendBack(trip.home, items, trip.x or 0, trip.y or 0, h, "Their traders came back without trading (" .. tostring(why) .. ")")
                -- 0.6.17: and they walk home themselves
                local hb = homeOf(trip.home)
                local hv = hb and M.nbHavenOf(hb) or nil
                local dp = hv and type(hv.depot) == "table" and hv.depot or (hb and { x = hb.x, y = hb.y, z = 0 }) or nil
                if dp and fn(M, "lvSend") then
                    local th = 6
                    pcall(function() th = M.travelH(trip.x or dp.x, trip.y or dp.y, dp.x, dp.y, hb) end)
                    for _, uid in ipairs(trip.uids or {}) do
                        pcall(M.lvSend, uid, { tx = dp.x, ty = dp.y, untilH = h + (tonumber(th) or 6), final = { x = dp.x + (hash(uid) % 3) - 1, y = dp.y + (hash(uid .. "y") % 3) - 1, z = dp.z or 0 }, tag = "caravan_home" })
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the Jeem wraps
----------------------------------------------------------------------------------------------------------------
local function stamp(V, T, memory, visit, member)
    memory.jimmyTrader = V.infoFor(visit, member)
    memory.groupId = "jimmy_trader:" .. visit.id
    memory.jimmyPersistent = true
    memory.moduleOverrides = type(memory.moduleOverrides) == "table" and memory.moduleOverrides or {}
    if fn(T, "switches") then for key, value in pairs(T.switches()) do memory.moduleOverrides[key] = value end end
end
-- a real member goes home: off the visit, back to where they live
function M.cvSendHome(record)
    local reg = PA().ActorRegistry
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory.alcpCaravan or nil
    if type(m) ~= "table" or not fn(reg, "update") then return false end
    local b = homeOf(m.home)
    local haven = b and M.nbHavenOf(b) or nil
    local depot = haven and type(haven.depot) == "table" and haven.depot or (type(m.oldPos) == "table" and m.oldPos) or nil
    local wp = type(record.worldPosition) == "table" and record.worldPosition or nil
    local fx, fy = wp and tonumber(wp.x), wp and tonumber(wp.y)
    local placed = nil
    local ok, res = pcall(reg.update, record.uid, record.revision, function(r)
        r.memory = type(r.memory) == "table" and r.memory or {}
        local keep = r.memory.alcpCaravan or {}
        r.memory.jimmyTrader, r.memory.jimmyPersistent = nil, nil
        r.memory.groupId = keep.oldGroup
        r.memory.moduleOverrides = keep.oldOverrides
        r.memory.alcpCaravan = nil
        if b then r.memory.havenId = b.id end
        if depot then r.worldPosition = { x = depot.x + (hash(r.uid) % 3) - 1, y = depot.y + (hash(r.uid .. "y") % 3) - 1, z = depot.z or 0 }; placed = r.worldPosition end
    end)
    if ok and res ~= false then
        M.cvStats.home = M.cvStats.home + 1
        -- 0.6.17: home is the end of the road, not a teleport: on the road back until the walk (or drive) is done
        if placed and fx and fn(M, "lvSend") then
            local th = 6
            pcall(function() th = M.travelH(fx, fy, placed.x, placed.y, b) end)
            pcall(M.lvSend, record.uid, { fx = fx, fy = fy, tx = placed.x, ty = placed.y, untilH = hours() + (tonumber(th) or 6), final = placed, tag = "caravan_home" })
        end
        return true
    end
    return false
end

M._alcpHooks = M._alcpHooks or {}
local broken = false
local function fail(where, err)
    if broken then return end
    broken = true
    print("[ALifeCaravans] " .. where .. " failed, caravans use Jeem's own traders for this session: " .. tostring(err))
end
function M.cvInstall()
    local J = JM()
    local T = J and J.Traders
    local V = T and T.visits
    if M._alcpHooks.caravans then return true end
    if type(V) ~= "table" or not fn(V, "start") or not fn(V, "create") or not fn(V, "depart") or not fn(V, "close") then return false end
    M._alcpHooks.caravans = true
    local start, create, depart, close = V.start, V.create, V.depart, V.close

    V.start = function(base, h, players, opts, ...)
        if broken or M.settings.caravans == false or type(base) ~= "table" then return start(base, h, players, opts, ...) end
        local arriving = M.cvArriving
        local tripsT = trips()
        if arriving == nil then
            -- Jeem wants a visit now: a group sets out instead; they get here when the road is walked
            if M.cvTripFor(base.id) then return nil, "on_the_way" end
            local ok, res = pcall(M.cvSetOut, base, h)
            if not ok then fail("set out", res); return start(base, h, players, opts, ...) end
            return nil, res or "no_caravan"
        end
        local ok, src = pcall(M.cvTripSource, arriving)
        if not ok then fail("arrive", src); return nil, "error" end
        if src == nil then return nil, "trip_gone" end
        M.cvStats.picked = M.cvStats.picked + 1
        local o = copy(opts or {})
        o.walkUp, o.party = true, #src.who
        o.archetype = o.archetype or M.cvArchetype[src.b.trade] or "general"
        M.cvPending = { src = src, used = 0, archetype = o.archetype, rows = arriving.rows }
        local okS, visit, why, more = pcall(start, base, h, players, o, ...)
        local pend = M.cvPending
        M.cvPending = nil
        if not okS then fail("start", visit); return nil, "error" end
        if visit and type(visit.alcp) == "table" then
            local x, y = boxCenter(V, base)
            visit.alcp.x, visit.alcp.y = x, y
            visit.alcp.market = arriving.market
            src.b.knowsYou = src.b.knowsYou or h -- 0.6.8: they've been to your place now
            for _, f in ipairs(M.cvArriveHooks or {}) do pcall(f, visit, src.b, h) end
            M.cvStats.came = M.cvStats.came + 1
            log(tostring(src.b.name) .. ": " .. tostring(pend.used) .. " arrived at " .. tostring(base.id) .. " with " .. #(visit.stock or {}) .. " kinds of goods")
        end
        return visit, why, more
    end

    V.create = function(visit, member, ...)
        if broken then return create(visit, member, ...) end
        if type(member) == "table" and member.real then return nil end -- a real person lost on the way is never made again
        local pend = M.cvPending
        if type(visit) ~= "table" or pend == nil then return create(visit, member, ...) end
        local ok, res = pcall(function()
            local src = pend.src
            if visit.alcp == nil then
                visit.alcp = { home = src.b.id, homeName = src.b.name, paid = {} }
                visit.faction = tostring(src.b.name)
                visit.stock = pend.rows or M.cvLoad(src, pend.archetype, #src.who)
            end
            pend.used = pend.used + 1
            local r = src.who[pend.used]
            if r == nil then return nil end
            local reg = PA().ActorRegistry
            member.uid, member.real = tostring(r.uid), true
            local fresh = reg.read(member.uid)
            if fresh == nil or fresh.lifecycle ~= "dormant" then return nil end
            local okU, done = pcall(reg.update, fresh.uid, fresh.revision, function(e)
                e.memory = type(e.memory) == "table" and e.memory or {}
                e.memory.alcpCaravan = { home = src.b.id, oldGroup = e.memory.groupId, oldOverrides = copy(e.memory.moduleOverrides),
                    oldPos = copy(e.worldPosition) }
                stamp(V, T, e.memory, visit, member)
                e.worldPosition = { x = member.arriveAt.x + 0.5, y = member.arriveAt.y + 0.5, z = 0 }
            end)
            if not okU or done == false or done == nil then return nil end
            if fn(M, "lvCancel") then M.lvCancel(member.uid) end -- 0.6.17: off the road, at the gate
            return reg.read(member.uid)
        end)
        if not ok then fail("create", res); return nil end
        return res
    end

    V.depart = function(visit, member, record, players, h, force, ...)
        local m = type(record) == "table" and type(record.memory) == "table" and record.memory.alcpCaravan or nil
        if broken or m == nil then return depart(visit, member, record, players, h, force, ...) end
        local ok, res = pcall(function()
            local reg = PA().ActorRegistry
            if record.lifecycle == "active" then
                if not force then
                    local x, y = V.livePosition(record)
                    if x == nil then return false end
                    local late = h - (tonumber(type(visit) == "table" and visit.leftHours) or h) >= V.C.leaveTimeoutHours
                    local clear = late and V.C.lateClear or V.C.clearOfPlayers
                    for _, p in ipairs(players or {}) do if d2(p.x, p.y, x, y) < clear * clear then
                        -- 0.6.17: you're there: they pick up and walk off down the road (gone once out of sight)
                        if fn(M, "lvSend") and not (fn(M, "lvIsAway") and M.lvIsAway(record.uid)) then
                            local mm = record.memory.alcpCaravan
                            local hb = mm and homeOf(mm.home)
                            if hb then pcall(M.lvSend, record.uid, { tx = hb.x, ty = hb.y, untilH = h + 48, tag = "caravan" }) end
                        end
                        return false
                    end end
                end
                local spawn = PA().SpawnService
                if not fn(spawn, "dehydrate") or not pcall(spawn.dehydrate, record.uid, "alcp_caravan") then return false end
                record = reg.read(record.uid)
                if record == nil then if type(member) == "table" then member.gone = true end; return true end
            end
            if record.lifecycle ~= "dormant" then return false end
            if M.cvSendHome(record) then if type(member) == "table" then member.gone = true end; return true end
            return false
        end)
        if not ok then fail("depart", res); return false end
        return res
    end

    if fn(V, "flee") then
        local flee = V.flee
        V.flee = function(visit, h, players, key, why, theirs, ...)
            if type(visit) == "table" and type(visit.alcp) == "table" and key ~= nil
                    and (why == "member_killed" or why == "attacked" or why == "held_up" or why == "provoked") then
                if visit.alcp.wronged ~= "member_killed" then visit.alcp.wronged = why end
            end
            return flee(visit, h, players, key, why, theirs, ...)
        end
    end
    V.close = function(visit, h, reason, ...)
        if not broken and type(visit) == "table" and visit.alcp then
            local ok, err = pcall(M.cvUnload, visit)
            if not ok then fail("close", err) end
        end
        return close(visit, h, reason, ...)
    end

    -- 0.6.14: what your things are worth to traders: the real worth of each item (not one price per kind), and for
    -- our caravans also what their group is short of
    local GW = J.GiftWorth
    if fn(GW, "tradeValue") and fn(GW, "kind") and type(ALifeWorth) == "table" then
        local tradeValue = GW.tradeValue
        GW.tradeValue = function(item, wants, ...)
            if broken or M.settings.itemWorth == false then return tradeValue(item, wants, ...) end
            local ok, v = pcall(function()
                local jk = GW.kind(item)
                local w = ALifeWorth.item(item)
                return w * (type(wants) == "table" and tonumber(wants[jk]) or 1)
            end)
            if ok and tonumber(v) then return v end
            return tradeValue(item, wants, ...)
        end
    end
    M.cvJeemKind = { food = "food", medical = "meds", ammo = "ammo", gun = "weapon", melee = "weapon", vice = "other", other = "other" }
    local function needWants(visit, wants)
        if type(wants) ~= "table" or type(visit) ~= "table" or type(visit.alcp) ~= "table" or type(ALifeWorth) ~= "table" then return wants end
        local b = homeOf(visit.alcp.home)
        if b == nil then return wants end
        local out = {}
        for k, v in pairs(wants) do out[k] = (tonumber(v) or 0) * ALifeWorth.need(b, M.cvJeemKind[k] or "other") end
        return out
    end
    local TTq = J.TraderTrade
    if fn(TTq, "addToQuote") then
        local addToQuote = TTq.addToQuote
        TTq.addToQuote = function(q, player, record, visit, ...)
            local r = addToQuote(q, player, record, visit, ...)
            if not broken and M.settings.itemWorth ~= false then pcall(function() q.wants = needWants(visit, q.wants) end) end
            return r
        end
    end
    -- what you pay them goes into their stash (Jeem packs it away into nothing)
    local TT, Hg = J.TraderTrade, J.HandGifts
    if fn(TT, "execute") and fn(Hg, "takeFrom") then
        local execute = TT.execute
        TT.execute = function(player, record, visit, giveIds, takeIds, ...)
            if broken or type(visit) ~= "table" or type(visit.alcp) ~= "table" then return execute(player, record, visit, giveIds, takeIds, ...) end
            local takeFrom = Hg.takeFrom
            local Goods = J.TraderGoods
            local wantsFn = Goods and Goods.wants
            if type(wantsFn) == "function" and M.settings.itemWorth ~= false then
                Goods.wants = function(arch, ...) return needWants(visit, wantsFn(arch, ...)) end -- 0.6.14: what their group is short of
            end
            Hg.takeFrom = function(p, item, ...)
                pcall(function()
                    local t = item:getFullType()
                    local paid = visit.alcp.paid
                    if t and #paid < M.cvCfg.paidCap then paid[#paid + 1] = t; M.cvStats.paid = M.cvStats.paid + 1 end
                end)
                return takeFrom(p, item, ...)
            end
            local ok, a, b2, c = pcall(execute, player, record, visit, giveIds, takeIds, ...)
            Hg.takeFrom = takeFrom
            if Goods and wantsFn then Goods.wants = wantsFn end
            if not ok then error(a) end
            return a, b2, c
        end
    end
    print("[ALifeCaravans] loaded v0.6.6 (Jeem's traders are real people from real groups, carrying real goods)")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- CARAVANS BETWEEN GROUPS (off screen, on paper). Once a day a trading group (or one with a big surplus) sends goods
-- to a friendly group nearby that lacks them, for what that group has spare. Things move, nothing is made. A warband
-- within reach of the road may rob the run: the goods go to them.
----------------------------------------------------------------------------------------------------------------
M.cvRunCfg = { tiles = 1000, robTiles = 400, robChance = 0.25, swap = 6 }
local function stashKinds(haven)
    local by = {}
    for _, it in ipairs(stashOf(haven) or {}) do local k = kindOf(typeOf(it)); by[k] = (by[k] or 0) + 1 end
    return by
end
-- 0.6.14: moves things of a kind until their worth reaches cap (worth moved, count)
local function moveWorth(fromHaven, toHaven, kind, cap)
    local fl, tl = stashOf(fromHaven), stashOf(toHaven, true)
    if fl == nil or tl == nil or type(ALifeWorth) ~= "table" then return 0, 0 end
    local got, n = 0, 0
    for i = #fl, 1, -1 do
        if got >= cap then break end
        local t = typeOf(fl[i])
        if kindOf(t) == kind then
            local v = ALifeWorth.of(t)
            if got + v <= cap * 1.25 then tl[#tl + 1] = table.remove(fl, i); got = got + v; n = n + 1 end
        end
    end
    return got, n
end
M.cvRunCfg.worth = 20
local function moveKind(fromHaven, toHaven, kind, n)
    local fl, tl = stashOf(fromHaven), stashOf(toHaven, true)
    if fl == nil or tl == nil then return 0 end
    local moved = 0
    for i = #fl, 1, -1 do
        if moved >= n then break end
        if kindOf(typeOf(fl[i])) == kind then tl[#tl + 1] = table.remove(fl, i); moved = moved + 1 end
    end
    return moved
end
function M.cvRun(b, h)
    if M.settings.caravans == false or type(b) ~= "table" or b.status ~= "active" or b.road or b.airport then return end
    local day = math.floor(h / 24)
    if b.cvRunDay == day then return end
    b.cvRunDay = day
    if b.trade ~= "traders" and ALifeRoll01(b.id .. "#run#" .. day) >= 1 / 7 then return end -- traders every day, others weekly-ish
    local mine = M.nbHavenOf(b)
    local have = stashKinds(mine)
    local best, bs, give, want = nil, -1e9, nil, nil
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and not o.airport and not o.road and tonumber(o.x) and d2(o.x, o.y, b.x, b.y) <= M.cvRunCfg.tiles ^ 2 then
            local tie = fn(M, "dirTie") and M.dirTie(b, o) or 0
            if (tonumber(tie) or 0) >= 0 and o.trade ~= "warband" and o.trade ~= "slavers" then
                local theirs = stashKinds(M.nbHavenOf(o))
                for _, k in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do
                    for _, w in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do
                        if k ~= w and (have[k] or 0) >= 12 and (have[w] or 0) < 3 and (theirs[w] or 0) >= 12 and (theirs[k] or 0) < 3 then
                            local s = (have[k] or 0) + (theirs[w] or 0) - math.sqrt(d2(o.x, o.y, b.x, b.y)) / 50
                            if s > bs then best, bs, give, want = o, s, k, w end
                        end
                    end
                end
            end
        end
    end
    if best == nil then return end
    local theirsHaven = M.nbHavenOf(best)
    local n = M.cvRunCfg.swap
    -- 0.6.19: outposts holding a chokepoint on the way take a toll, or everything
    if fn(M, "chkRunHazard") then
        local okH, robbed = pcall(M.chkRunHazard, b, best, give, n, day, moveKind)
        if okH and robbed then pcall(M.nbFoodSync, b, mine); return end
    end
    -- the road: a warband near the halfway point may rob the run
    local mx, my = (b.x + best.x) / 2, (b.y + best.y) / 2
    for _, w in ipairs(M.nbActive()) do
        if (w.trade == "warband" or w.trade == "slavers") and w.id ~= b.id and w.id ~= best.id and d2(w.x, w.y, mx, my) <= M.cvRunCfg.robTiles ^ 2
                and ALifeRoll01(b.id .. w.id .. day) < M.cvRunCfg.robChance then
            local got = moveKind(mine, M.nbHavenOf(w), give, n)
            M.cvStats.robbed = M.cvStats.robbed + 1
            event(b, "Their trade run to " .. tostring(best.name) .. " was robbed on the road by " .. tostring(w.name), "trade")
            event(w, "Robbed a trade run from " .. tostring(b.name) .. " (" .. got .. " " .. give .. ")", "trade")
            if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, w, -15) end
            pcall(M.nbFoodSync, b, mine); pcall(M.nbFoodSync, w, M.nbHavenOf(w))
            return
        end
    end
    local out, back
    if type(ALifeWorth) == "table" and M.settings.itemWorth ~= false then
        -- fair by worth to each side: they send what they can spare and get back as much as it's worth to them
        local sent
        sent, out = moveWorth(mine, theirsHaven, give, M.cvRunCfg.worth)
        local fair = sent * ALifeWorth.need(best, give) / math.max(0.5, ALifeWorth.need(b, want))
        local _, n2 = moveWorth(theirsHaven, mine, want, fair)
        back = n2
    else
        out = moveKind(mine, theirsHaven, give, n)
        back = moveKind(theirsHaven, mine, want, n)
    end
    pcall(M.nbFoodSync, b, mine); pcall(M.nbFoodSync, best, theirsHaven)
    if out + back > 0 then
        M.cvStats.runs = M.cvStats.runs + 1
        event(b, "Traded " .. out .. " " .. give .. " to " .. tostring(best.name) .. " for " .. back .. " " .. want, "trade")
        event(best, "Traded with " .. tostring(b.name) .. ": " .. out .. " " .. give .. " for " .. back .. " " .. want, "trade")
        if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, best, 3) end
        -- 0.6.8: word gets around: groups that trade tell each other about your place
        if b.knowsYou and not best.knowsYou then best.knowsYou = h; event(best, "Heard about your place from " .. tostring(b.name), "heard") end
        if best.knowsYou and not b.knowsYou then b.knowsYou = h; event(b, "Heard about your place from " .. tostring(best.name), "heard") end
    end
end
function M.cvPerf()
    local s = M.cvStats
    return "caravans: came " .. s.came .. " (nobody to send " .. s.noSource .. "), went home " .. s.home .. ", paid in " .. s.paid
        .. ", goods home " .. s.returned .. ", runs between groups " .. s.runs .. ", robbed " .. s.robbed
end

-- the off-screen runs ride the base simulation (once a day per base, cheap)
function M.cvInstallRuns()
    if M._alcpHooks.caravanRuns or type(M.nbStep) ~= "function" then return false end
    M._alcpHooks.caravanRuns = true
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        if not broken and type(b) == "table" and b.status == "active" and far then
            local ok, err = pcall(M.cvRun, b, h)
            if not ok then fail("run", err) end
        end
        return r
    end
    return true
end
M.cvInstallRuns()
local tries = 0
local function tryInstall()
    tries = tries + 1
    if M.cvInstall() or tries > 30 then
        if Events and Events.EveryOneMinute then ALifeHealth.remove(Events.EveryOneMinute, tryInstall) end
    end
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() M.cvInstallRuns(); M.cvInstall() end) end
    if Events.EveryOneMinute then ALifeHealth.add(Events.EveryOneMinute, "ALifeTalk_Caravans", tryInstall) end
    if Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_Caravans", function() local ok, err = pcall(M.cvTick); if not ok then fail("tick", err) end end) end
end
