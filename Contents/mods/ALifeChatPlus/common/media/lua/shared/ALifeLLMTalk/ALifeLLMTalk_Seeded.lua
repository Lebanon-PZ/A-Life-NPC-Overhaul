-- A-Life Talk 0.5.2.1: PRE-SEEDED NPC BASES. Random suitable houses across the map become bases that already exist
-- when you get there, and people already in the world (A-Life's offline squads, unloaded groups / loners) are made
-- to live in them, so off screen they stay around their home and render there when you come close.
--  * seeding: a few at world start / first load, then gradually (one site per pass, a pass every 30 s; after the
--    first set, at most one new base per game day). Sites are found with A-Life's road graph (towns / junctions, a
--    stable shuffled order) and the meta grid (getRoomsIntersecting -> BuildingDef), so unloaded cells work.
--    Scored by size / rooms (residential, defensible); never the player's base, a safehouse, an outpost, a taken /
--    cooling-down house, near you, or near another base (A-Life's Havens.excluded + 0.5.2's rules + spacing).
--  * residents: an existing A-Life offline squad (no outpost / expedition / revenge / plan, not owned by an
--    activity, nobody in your party / a settler / already dead among them), else an unloaded natural group or
--    loner, else (optional) a new squad drawn the way A-Life founds them (rosters, census, world pressure, caps).
--  * the base: an A-Life haven (same record as 0.5.2 bases) + our record (name, stage camp / fortified, food,
--    morale, faction, history). Afterwards it lives exactly like a 0.5.2 base (life, talk, visits, raids, offline
--    events, abandon, overrun with final deaths, falls when everyone is dead) and shows in Places once known.
--  * keeping them home (runtime wraps, method-checked, A-Life files untouched):
--      OfflineDirector.plannedTask / GroupPlan.offlineTask -> a homed squad away from home walks back (A-Life's
--        own "return" task over the road graph) and at home stays put (rest / fortify) at the house; short day
--        trips allowed; approachEligible -> never sent to drift toward you
--      RenderProtocol.memoryFor -> rendered members get havenId / supply depot and home = the house
--      Havens.crewAlive -> a base whose people are an unrendered squad isn't "crew gone"
--  * materialize on approach (cell loaded, you 25-120 tiles away): boards on existing windows (camp: a couple;
--    fortified: the ground floor + side doors, never the main door) through A-Life's OutpostBuilder, and a few
--    supplies in an existing container at the depot. No new furniture. Once per stage.
--  * deaths: a resident's final death takes them off the roster and clears their home at once; when nobody living
--    is left the base falls: A-Life's haven is released, the house is free again after 4 in-game days, no respawn,
--    no replacements; the record stays in Places as "fallen".
-- Settings: seededBases (on / off), seededBasesCount, seededSpawn. npcBases off = all of this off too.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Seeded") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Bases"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Seeded"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Seeded") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) if M.log then M.log("seeded: " .. tostring(msg)) end end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function unit(s) -- 0..1, well mixed (nearby strings give unrelated rolls)
    local h = hash(s)
    h = (h * 48271) % 2147483647
    h = (h * 48271) % 2147483647
    return (math.floor(h / 7) % 10000) / 10000
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function H() return PA().Havens end
local function hours()
    local hv = H()
    if fn(hv, "hours") then local ok, v = pcall(hv.hours); if ok and tonumber(v) then return tonumber(v) end end
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return h
end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function inside(b, x, y, pad)
    pad = pad or 0
    return type(b) == "table" and x ~= nil and x >= b.x1 - pad and x <= b.x2 + pad and y >= b.y1 - pad and y <= b.y2 + pad
end
-- pre-1.0 MP (P5): seeded bases are world places. On a server "you" = the online player nearest the spot in question
-- (nearPos), else the camp's player (M.homePlayer); far / in reach checks are against every player. SP: unchanged.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function thePlayer() if mpServer() and M.homePlayer then return M.homePlayer() end; return ALifeSide.you() end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function hourOfDay()
    local h = nil
    pcall(function() h = getGameTime():getHour() end)
    if h == nil then h = math.floor(hours()) % 24 end
    return h
end
local function Graph() local g = PA().RoadGraph; return (type(g) == "table" and type(g.nodes) == "table") and g or nil end
local function Ledger() local l = PA().SquadLedger; return fn(l, "peek") and l or nil end

setting("seededBases", true)    -- pre-seeded bases on / off (existing ones keep living; npcBases off = everything off)
setting("seededBasesCount", 3)  -- how many pre-seeded bases to keep (0-8; the npcBasesMax / A-Life cap still applies)
setting("seededSpawn", true)    -- when nobody suitable is around, ask A-Life to draw a new squad for the house (caps respected)
-- (settings rows: ALifeLLMTalk_UIBond)

M.sbCfg = {
    seedMs = 30000, matMs = 5000, firstMs = 15000, regapH = 24, minPlayerTiles = 250, spacing = 350, box = 60,
    roomsMax = 160, buildingsMax = 40, minStatic = 10, pullTiles = 3000, playerClearTiles = 200, crewMin = 1, crewMax = 6,
    homeTiles = 40, tripTiles = 400, tripChance = 0.25, matTiles = 120, matSafeTiles = 25, boardCamp = 2, boardFort = 10,
    stashDraws = { camp = 6, fortified = 10 }, originsMax = 400,
}
M.sbStats = { ticks = 0, seedPasses = 0, queries = 0, rooms = 0, sites = 0, refused = 0, seeded = 0, homedSquads = 0, homedGroups = 0,
    spawned = 0, spawnRefused = 0, tasks = 0, returns = 0, snaps = 0, approachBlocked = 0, renderTagged = 0, crewAliveSaves = 0,
    materialized = 0, boarded = 0, stashed = 0, deaths = 0, released = 0, ms = 0, maxMs = 0 }
M.sbStash = { { "Base.TinnedBeans", 3 }, { "Base.CannedCorn", 3 }, { "Base.TinnedSoup", 3 }, { "Base.CannedChili", 2 },
    { "Base.Crisps", 2 }, { "Base.Plank", 2 }, { "Base.Nails", 1 }, { "Base.Bandage", 1 } }

function M.sbOn() return M.nbOn() and M.settings.seededBases ~= false end
function M.sbStore()
    local st = M.nbStore()
    st.seed = type(st.seed) == "table" and st.seed or {}
    local s = st.seed
    s.cursor = tonumber(s.cursor) or 0
    s.made = tonumber(s.made) or 0
    if s.salt == nil then s.salt = tostring(hash(tostring(nowMs()) .. "#" .. tostring(hours()))) end
    return s
end
function M.sbCount() return clamp(math.floor(tonumber(M.settings.seededBasesCount) or 3), 0, 8) end
function M.sbSeededActive()
    local n = 0
    for _, b in ipairs(M.nbActive()) do if b.seeded then n = n + 1 end end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- squads homed to a base (ledger fields: nbHavenId, nbOldHome)
----------------------------------------------------------------------------------------------------------------
local function seedOf(q, i, member)
    return (type(member) == "table" and type(member.identitySeed) == "string" and member.identitySeed) or (tostring(q.id) .. ":member:" .. tostring(i))
end
M.sbSeedOf = seedOf
-- what we know of a squad member: patch's remembered uid / name for that appearance seed (people you met)
local function known(seed)
    local P = patch()
    local d = P and (P.data or (fn(P, "store") and P.store())) or nil
    local s = type(d) == "table" and type(d.seeds) == "table" and d.seeds[seed] or nil
    return type(s) == "table" and s or nil
end
function M.sbActiveBase(id)
    local b = id and M.nbOf(id) or nil
    if b and b.status == "active" then return b end
    return nil
end
-- virtual crew: one entry per member of an offline squad homed here (rendered squads have registry records)
function M.sbCrewOf(b)
    local led = Ledger()
    if led == nil or type(b.squads) ~= "table" then return {} end
    local out, keep = {}, {}
    for _, sid in ipairs(b.squads) do
        local q = led.peek(sid)
        if q ~= nil and q.state ~= "wiped" and q.nbHavenId == b.id and type(q.members) == "table" and #q.members > 0 then
            keep[#keep + 1] = sid
            if q.state == "offline" then
                for i, member in ipairs(q.members) do
                    local seed = seedOf(q, i, member)
                    local k = known(seed)
                    local name = (k and k.name) or member.name
                    local first = (k and k.first) or (type(name) == "string" and string.match(name, "^(%S+)")) or nil
                    out[#out + 1] = { uid = (k and k.uid) or ("seed:" .. seed), virtual = true, known = k ~= nil or nil, seed = seed, index = i,
                        squadId = q.id, lifecycle = "dormant", factionId = q.factionId, revision = 0, name = name, first = first,
                        worldPosition = { x = tonumber(q.x) or b.x, y = tonumber(q.y) or b.y, z = 0 },
                        memory = { havenId = b.id, squadId = q.id, identitySeed = seed, personFirst = first, personName = name } }
                end
            end
        end
    end
    b.squads = keep
    return out
end
-- members of live homed squads that are rendered right now (their registry records carry havenId too)
function M.sbLiveSquadMembers(b, renderedOnly)
    local led = Ledger()
    if led == nil or type(b.squads) ~= "table" then return 0 end
    local n = 0
    for _, sid in ipairs(b.squads) do
        local q = led.peek(sid)
        if q ~= nil and q.state ~= "wiped" and q.state ~= "offline" and q.nbHavenId == b.id and renderedOnly then
            -- rendered members are counted from the registry; only count ones without a record (staging)
            if type(q.renderedUids) ~= "table" or #q.renderedUids == 0 then n = n + #(q.members or {}) end
        end
    end
    return n
end
-- a homed squad that is live but not offline right now (staging / rendered): its people are on their way in or out
function M.sbInTransit(b)
    local led = Ledger()
    if led == nil or type(b.squads) ~= "table" then return false end
    for _, sid in ipairs(b.squads) do
        local q = led.peek(sid)
        if q ~= nil and q.state ~= "wiped" and q.state ~= "offline" and q.nbHavenId == b.id and type(q.members) == "table" and #q.members > 0 then return true end
    end
    return false
end
-- is the member with this seed still alive in that squad? true / false (dead) / nil (can't tell now: in transit)
function M.sbSeedAlive(sid, seed, b)
    local led = Ledger()
    if led == nil then return nil end
    local q = led.peek(sid)
    if q == nil or q.state == "wiped" then return false end
    if q.nbHavenId ~= b.id then return "left" end
    for i, member in ipairs(q.members or {}) do if seedOf(q, i, member) == seed then return true end end
    if q.state ~= "offline" then return nil end
    return false
end
function M.sbHasLive(id)
    local b = M.sbActiveBase(id)
    local led = Ledger()
    if b == nil or led == nil or type(b.squads) ~= "table" then return false end
    for _, sid in ipairs(b.squads) do
        local q = led.peek(sid)
        if q ~= nil and q.state ~= "wiped" and q.nbHavenId == id and type(q.members) == "table" and #q.members > 0 then return true end
    end
    return false
end
-- final death of an unseen (offline) squad member: removed from A-Life's squad (same as OfflineCombat.shed),
-- a remembered person is marked finally dead (scen73 rules); the last one -> squad "wiped" (A-Life sweeps it)
function M.sbKillVirtual(r, why)
    local led = Ledger()
    if led == nil or type(r) ~= "table" or r.squadId == nil then return false end
    local q = led.peek(r.squadId)
    if q == nil or q.state ~= "offline" or type(q.members) ~= "table" then return false end
    local player = mpServer() and ALifeSide.nearest(tonumber(q.x) or 0, tonumber(q.y) or 0) or thePlayer()
    local px, py = pos(player)
    if px ~= nil and d2(px, py, tonumber(q.x) or 0, tonumber(q.y) or 0) <= M.nbCfg.farTiles ^ 2 then return false end -- never in reach
    local h = hours()
    local done = false
    pcall(led.update, q.id, q.revision, function(s)
        local at = nil
        for i, member in ipairs(s.members) do
            member.identitySeed = seedOf(s, i, member) -- pin identities before indices shift
            if member.identitySeed == r.seed then at = i end
        end
        if at == nil then return end
        table.remove(s.members, at)
        if #s.members == 0 then s.state = "wiped"; s.wipedHours = h end
        done = true
    end)
    if not done then return false end
    if r.known and M.markFinalDead then pcall(M.markFinalDead, tostring(r.uid), why, nil) end
    M.sbStats.deaths = M.sbStats.deaths + 1
    if M.nbStats then M.nbStats.deaths = M.nbStats.deaths + 1 end
    return true
end
-- unseen people far from the base while you're away: an idle squad stuck far away is put back at the house
function M.sbBringHome(r, b, depot, h)
    local led = Ledger()
    if led == nil or r.squadId == nil then return false end
    local q = led.peek(r.squadId)
    if q == nil or q.state ~= "offline" then return false end
    if type(q.route) == "table" and #q.route > 0 then return false end -- walking (home or on a trip)
    local task = type(q.task) == "table" and q.task or {}
    if h - (tonumber(task.assignedHours) or h) < 12 then return false end
    local ok = led.update(q.id, q.revision, function(s)
        s.x, s.y = depot.x + (hash(s.id) % 3) - 1, depot.y + (hash(s.id .. "y") % 3) - 1
    end, true)
    if ok then M.sbStats.snaps = M.sbStats.snaps + 1 end
    return ok == true
end
function M.sbRelease(b)
    local led = Ledger()
    if led == nil or type(b.squads) ~= "table" then return 0 end
    local n = 0
    for _, sid in ipairs(b.squads) do
        local q = led.peek(sid)
        if q ~= nil and q.nbHavenId == b.id then
            pcall(led.update, q.id, q.revision, function(s)
                s.nbHavenId = nil
                if s.nbOldHome ~= nil then s.homeNodeId = s.nbOldHome end
                s.nbOldHome = nil
            end)
            n = n + 1
        end
    end
    M.sbStats.released = M.sbStats.released + n
    return n
end
function M.sbHomeSquad(q, b, depot, h)
    local led = Ledger()
    local g = Graph()
    if led == nil then return false end
    local node = nil
    if g and fn(g, "nearest") then local ok, id = pcall(g.nearest, depot.x, depot.y); if ok then node = id end end
    local ok = led.update(q.id, q.revision, function(s)
        s.nbHavenId = b.id
        if s.nbOldHome == nil then s.nbOldHome = s.homeNodeId end
        if node ~= nil then s.homeNodeId, s.nodeId, s.legFrom = node, node, node end
        s.x, s.y = depot.x + (hash(s.id) % 3) - 1, depot.y + (hash(s.id .. "y") % 3) - 1
        s.route, s.legHours, s.nightCamp = {}, nil, nil
        s.task = { kind = "fortify", label = "holding " .. tostring(b.name), dest = node, assignedHours = h, untilHours = h + 2, stationary = true }
        s.decisionDueHours = h + 2
    end, true)
    if ok then
        b.squads = type(b.squads) == "table" and b.squads or {}
        local have = false
        for _, sid in ipairs(b.squads) do if sid == q.id then have = true end end
        if not have then b.squads[#b.squads + 1] = q.id end
    end
    return ok == true
end

----------------------------------------------------------------------------------------------------------------
-- keeping them home: the decision A-Life's offline director asks for (GroupPlan.offlineTask / plannedTask)
----------------------------------------------------------------------------------------------------------------
function M.sbTask(q, hrs, here, hour)
    if type(q) ~= "table" or q.nbHavenId == nil or not M.nbOn() then return nil end
    local b = M.sbActiveBase(q.nbHavenId)
    if b == nil then q.nbHavenId = nil; return nil end
    local hv = H()
    local haven = fn(hv, "of") and hv.of(b.id) or nil
    local depot = haven and type(haven.depot) == "table" and haven.depot or { x = b.x, y = b.y }
    local g = Graph()
    hour = tonumber(hour) or hourOfDay()
    local dist = math.sqrt(d2(tonumber(q.x) or 0, tonumber(q.y) or 0, depot.x, depot.y))
    local day = hour >= 7 and hour < 18
    local trip = day and unit(tostring(q.id) .. "#trip#" .. math.floor((tonumber(hrs) or 0) / 6)) < M.sbCfg.tripChance
    M.sbStats.tasks = M.sbStats.tasks + 1
    if dist > M.sbCfg.homeTiles then
        if trip and dist < M.sbCfg.tripTiles then return nil end -- out on a day trip (A-Life picks the chore)
        local home = q.homeNodeId
        if g and home ~= nil and g.nodes[home] ~= nil and here ~= nil and here ~= home and fn(g, "route") then
            local ok, route = pcall(g.route, here, home)
            if ok and type(route) == "table" and #route >= 2 then
                M.sbStats.returns = M.sbStats.returns + 1
                return { kind = "return", label = "heading home to " .. tostring(b.name), dest = home }, route
            end
        end
        -- at the home node (or no road): the last stretch to the door
        q.x, q.y = depot.x + (hash(tostring(q.id)) % 3) - 1, depot.y + (hash(tostring(q.id) .. "y") % 3) - 1
        M.sbStats.snaps = M.sbStats.snaps + 1
    elseif trip then
        return nil
    elseif dist > 2 then
        -- home: at the door, not out by the road node (where they show up when you come)
        q.x, q.y = depot.x + (hash(tostring(q.id)) % 3) - 1, depot.y + (hash(tostring(q.id) .. "y") % 3) - 1
    end
    local kind = (hour >= 21 or hour < 7) and "rest" or "fortify"
    return { kind = kind, label = (kind == "rest" and "resting at " or "holding ") .. tostring(b.name), dest = here }, { here }
end

----------------------------------------------------------------------------------------------------------------
-- runtime wraps (method-exists checks; re-applied if A-Life replaces a table; never double-wrapped)
----------------------------------------------------------------------------------------------------------------
M._sbW = M._sbW or {}
local function wrapField(t, name, tag, maker)
    if type(t) ~= "table" or type(t[name]) ~= "function" then return false end
    if t[name] == M._sbW[tag] then return true end
    local w = maker(t[name])
    t[name] = w
    M._sbW[tag] = w
    return true
end
function M.sbInstall()
    local pa = PA()
    local out = {}
    out.planned = wrapField(pa.OfflineDirector, "plannedTask", "planned", function(orig) return function(squad, hrs, here, allowed, hour)
        local ok, task, route = pcall(M.sbTask, squad, hrs, here, hour)
        if ok and task ~= nil then return task, route end
        return orig(squad, hrs, here, allowed, hour)
    end end)
    out.groupPlan = wrapField(pa.GroupPlan, "offlineTask", "groupPlan", function(orig) return function(squad, hrs, here, allowed, hour)
        local ok, task, route = pcall(M.sbTask, squad, hrs, here, hour)
        if ok and task ~= nil then return task, route end
        return orig(squad, hrs, here, allowed, hour)
    end end)
    out.approach = wrapField(pa.OfflineDirector, "approachEligible", "approach", function(orig) return function(q, hrs)
        if type(q) == "table" and q.nbHavenId ~= nil and M.nbOn() and M.sbActiveBase(q.nbHavenId) then
            M.sbStats.approachBlocked = M.sbStats.approachBlocked + 1
            return false
        end
        return orig(q, hrs)
    end end)
    out.memory = wrapField(pa.RenderProtocol, "memoryFor", "memory", function(orig) return function(squad, index, x, y, health, head)
        local mem = orig(squad, index, x, y, health, head)
        if type(mem) == "table" and type(squad) == "table" and squad.nbHavenId ~= nil and M.nbOn() then
            local b = M.sbActiveBase(squad.nbHavenId)
            local hv = H()
            local haven = b and fn(hv, "of") and hv.of(b.id) or nil
            if b then
                local dp = haven and type(haven.depot) == "table" and haven.depot or { x = b.x, y = b.y, z = 0 }
                mem.havenId = b.id
                mem.supplyDepot = { x = dp.x, y = dp.y, z = dp.z or 0 }
                mem.home = { x = dp.x, y = dp.y, z = dp.z or 0 }
                mem.nbSeeded = true
                M.sbStats.renderTagged = M.sbStats.renderTagged + 1
            end
        end
        return mem
    end end)
    out.crewAlive = wrapField(pa.Havens, "crewAlive", "crewAlive", function(orig) return function(id)
        if orig(id) then return true end
        local ok, live = pcall(M.sbHasLive, id)
        if ok and live then M.sbStats.crewAliveSaves = M.sbStats.crewAliveSaves + 1; return true end
        return false
    end end)
    -- our own: a base that ends lets its squads go (they travel again; the dead stay dead)
    out.ended = wrapField(M, "nbEnded", "ended", function(orig) return function(b, reason)
        local was = type(b) == "table" and b.status == "active"
        orig(b, reason)
        if was and type(b) == "table" and b.status ~= "active" then pcall(M.sbRelease, b) end
    end end)
    M.sbWraps = out
    return out
end

----------------------------------------------------------------------------------------------------------------
-- finding sites without loaded cells: road-graph nodes (stable shuffled order) -> meta-grid buildings around them
----------------------------------------------------------------------------------------------------------------
function M.sbOrigins()
    local g = Graph()
    local s = M.sbStore()
    local list = {}
    if g then
        local n = 0
        for id, node in pairs(g.nodes) do
            if type(node) == "table" and tonumber(node.x) and tonumber(node.y) then
                n = n + 1
                if n > 4000 then break end
                list[#list + 1] = { id = id, x = node.x, y = node.y, k = hash(tostring(id) .. "#" .. s.salt), town = node.kind == "town" }
            end
        end
    end
    if #list == 0 then
        -- no road graph yet: a ring of points well away from the player
        local px, py = pos(thePlayer())
        if px == nil then return list end
        local base = { x = math.floor(px / 100) * 100, y = math.floor(py / 100) * 100 }
        for _, r in ipairs({ 350, 600, 900 }) do
            for a = 0, 11 do
                local ang = a * math.pi / 6 + r
                list[#list + 1] = { id = "ring:" .. r .. ":" .. a, x = math.floor(base.x + math.cos(ang) * r), y = math.floor(base.y + math.sin(ang) * r),
                    k = hash("ring" .. r .. a .. s.salt) }
            end
        end
    end
    table.sort(list, function(a, b) if a.k ~= b.k then return a.k < b.k end return tostring(a.id) < tostring(b.id) end)
    while #list > M.sbCfg.originsMax do table.remove(list) end
    return list
end
function M.sbBuildingsNear(x, y, r)
    if M.sbRoomsHook then return M.sbRoomsHook(x, y, r) end
    local defs = {}
    pcall(function()
        local rooms = ArrayList.new()
        getWorld():getMetaGrid():getRoomsIntersecting(math.floor(x) - r, math.floor(y) - r, r * 2, r * 2, rooms)
        local total = rooms:size()
        M.sbStats.rooms = M.sbStats.rooms + total
        local stride = math.max(1, math.ceil(total / M.sbCfg.roomsMax))
        for i = 0, total - 1, stride do
            local room = rooms:get(i)
            local def = room ~= nil and room:getBuilding() or nil
            if def ~= nil then defs[#defs + 1] = def end
        end
    end)
    return defs
end
local function defBounds(def)
    local b = nil
    pcall(function()
        local x1, y1, x2, y2 = tonumber(def:getX()), tonumber(def:getY()), tonumber(def:getX2()), tonumber(def:getY2())
        if x1 and y1 and x2 and y2 then b = { x1 = math.floor(x1), y1 = math.floor(y1), x2 = math.floor(x2) - 1, y2 = math.floor(y2) - 1 } end
    end)
    return b
end
function M.sbSiteOk(c, h, px, py)
    if px ~= nil and d2(c.center.x, c.center.y, px, py) < M.sbCfg.minPlayerTiles ^ 2 then return "player_near" end
    for _, o in ipairs(M.nbActive()) do
        if d2(o.x, o.y, c.center.x, c.center.y) < M.sbCfg.spacing ^ 2 then return "spacing" end
    end
    local hv = H()
    if fn(hv, "activeList") then
        local ok, list = pcall(hv.activeList)
        for _, hvn in ipairs(ok and list or {}) do
            if tonumber(hvn.x) and d2(hvn.x, hvn.y, c.center.x, c.center.y) < M.sbCfg.spacing ^ 2 then return "spacing" end
        end
    end
    return M.nbExcluded(c, h)
end
function M.sbChooseSite(origin, h)
    local px, py = pos(mpServer() and ALifeSide.nearest(origin.x, origin.y) or thePlayer())
    M.sbStats.queries = M.sbStats.queries + 1
    local seen, best, bestS, refused = {}, nil, -1e9, {}
    local defs = M.sbBuildingsNear(origin.x, origin.y, M.sbCfg.box)
    local looked = 0
    for _, def in ipairs(defs) do
        local b = defBounds(def)
        if b then
            local key = b.x1 .. ":" .. b.y1
            if not seen[key] then
                seen[key] = true
                looked = looked + 1
                if looked > M.sbCfg.buildingsMax then break end
                local c = { key = key, def = def, bounds = b, center = { x = (b.x1 + b.x2) / 2, y = (b.y1 + b.y2) / 2 } }
                local why = M.sbSiteOk(c, h, px, py)
                if why then refused[why] = (refused[why] or 0) + 1
                else
                    local st = M.nbStatic(c)
                    local s = st.static
                    local rc = st.rooms or {}
                    if (rc.bedroom or 0) > 0 and (rc.kitchen or 0) > 0 then s = s + 10 end -- residential
                    if st.area >= 50 and st.area <= 250 then s = s + 5 end              -- defensible size
                    s = s + (hash(key .. M.sbStore().salt) % 7)                           -- a little variety
                    if s >= M.sbCfg.minStatic and (s > bestS or (s == bestS and key < best.key)) then
                        best, bestS = c, s
                        c.score, c.why, c.rooms = s, st.why, st.roomNames
                    end
                end
            end
        end
    end
    return best, refused
end

----------------------------------------------------------------------------------------------------------------
-- residents: an offline squad, else unloaded natural people, else (optional) a new squad drawn A-Life's way
----------------------------------------------------------------------------------------------------------------
local BUSY = { revenge = true, reinforce = true, withdraw = true, drift = true, assassin = true }
function M.sbSquadOk(q, px, py)
    if type(q) ~= "table" or q.state ~= "offline" then return false, "state" end
    if type(q.members) ~= "table" or #q.members < 1 then return false, "empty" end
    if q.nbHavenId ~= nil and M.sbActiveBase(q.nbHavenId) then return false, "homed" end
    if q.homeOutpostId ~= nil or q.expedition ~= nil or q.expeditionReservedFor ~= nil or q.revenge ~= nil or q.plan ~= nil
            or q.stagePending ~= nil or q.releasePending ~= nil then return false, "busy" end
    if type(q.task) == "table" and BUSY[tostring(q.task.kind)] then return false, "busy" end
    local off = PA().OfflineDirector
    if fn(off, "activityOwned") then local ok, v = pcall(off.activityOwned, q); if ok and v then return false, "activity" end end
    local cat = PA().Catalog
    if q.factionId and fn(cat, "faction") then
        local ok, f = pcall(cat.faction, q.factionId)
        if ok and type(f) == "table" and type(f.spawn) == "table" and f.spawn.havens == false then return false, "faction" end
    end
    if px ~= nil and d2(tonumber(q.x) or 0, tonumber(q.y) or 0, px, py) < M.sbCfg.playerClearTiles ^ 2 then return false, "player_near" end
    -- nobody in your party, a settler, or dead among them (people you met: patch's remembered uid)
    for i, member in ipairs(q.members) do
        local k = known(seedOf(q, i, member))
        if k and k.uid then
            local uid = tostring(k.uid)
            if M.settlerOf and M.settlerOf(uid) ~= nil then return false, "settler" end
            if mpServer() and M.bdInParty and M.bdInParty(uid) then return false, "party" end -- MP: anyone's party
            if M.partyIsMember and select(2, pcall(M.partyIsMember, uid, thePlayer())) == true then return false, "party" end
            if M.isFinalDead and select(2, pcall(M.isFinalDead, uid)) == true then return false, "dead" end
        end
    end
    return true
end
function M.sbFindSquad(site, px, py)
    local led = Ledger()
    if led == nil or not fn(led, "eachLive") then return nil end
    local best, bd = nil, M.sbCfg.pullTiles ^ 2
    pcall(led.eachLive, function(q)
        if M.sbSquadOk(q, px, py) then
            local d = d2(tonumber(q.x) or 0, tonumber(q.y) or 0, site.center.x, site.center.y)
            if d < bd and #q.members <= M.sbCfg.crewMax then best, bd = q, d end
        end
    end)
    return best
end
function M.sbFindGroup(site, px, py)
    local scan = M.nbScan(true)
    local best, bd = nil, M.sbCfg.pullTiles ^ 2
    for _, gid in ipairs(scan.order) do
        local g = scan.groups[gid]
        if g and #g.members >= M.sbCfg.crewMin and #g.members <= M.sbCfg.crewMax then
            local ok, d = true, nil
            for _, r in ipairs(g.members) do
                local m = type(r.memory) == "table" and r.memory or {}
                local wp = r.worldPosition
                if not M.nbEligible(r) or r.lifecycle ~= "dormant" or m.squadId ~= nil or type(wp) ~= "table" or not tonumber(wp.x)
 then ok = false; break end
                local sh = nil
                pcall(function() sh = PA().Talk.shellFor(tostring(r.uid)) end)
                if sh ~= nil then ok = false; break end
                if px ~= nil and d2(wp.x, wp.y, px, py) < M.sbCfg.playerClearTiles ^ 2 then ok = false; break end
                d = d or d2(wp.x, wp.y, site.center.x, site.center.y)
            end
            if ok and d and d < bd then best, bd = g, d end
        end
    end
    return best
end
-- a new squad, drawn the way A-Life founds them (rosters, faction rules, census seats, world pressure, caps)
function M.sbSpawn(site, h)
    local pa = PA()
    local led, off, cat, rules = Ledger(), pa.OfflineDirector, pa.Catalog, pa.FactionSpawnRules
    if led == nil or not fn(led, "create") or not fn(led, "count") or type(off) ~= "table" or not fn(off, "drawMembers") or not fn(cat, "faction") then
        return nil, "no_api"
    end
    local cap = math.min(tonumber(led.settings and led.settings.maximum) or 24, tonumber(off.settings and off.settings.squadCap) or 8)
    if led.count() >= cap then return nil, "squad_cap" end
    local pressure = pa.WorldPressure
    if fn(pressure, "available") then
        local ok, v = pcall(pressure.available, site.center.x, site.center.y, 0, h)
        if ok and v == false then return nil, "pressure" end
    end
    local rosters = nil -- same source as A-Life's own offline director
    if type(off.adapters) == "table" and type(off.adapters.rosters) == "function" then pcall(function() rosters = off.adapters.rosters() end) end
    if type(rosters) ~= "table" then rosters = (pa.Director and type(pa.Director.rosters) == "table") and pa.Director.rosters or {} end
    local ids = {}
    for fid, roster in pairs(rosters) do
        if type(roster) == "table" and #roster > 0 then
            local ok, f = pcall(cat.faction, fid)
            if ok and type(f) == "table" and type(f.spawn) == "table" and f.spawn.havens ~= false then
                local avail = true
                if fn(rules, "available") then local ok2, v = pcall(rules.available, f, h / 24, hourOfDay()); avail = ok2 and v ~= false end
                local hostile = false
                if fn(rules, "hostile") then local ok3, v = pcall(rules.hostile, f); hostile = ok3 and v == true end
                if avail and not hostile then ids[#ids + 1] = fid end
            end
        end
    end
    if #ids == 0 then return nil, "no_rosters" end
    table.sort(ids)
    local fid = ids[(hash(site.key .. "#f") % #ids) + 1]
    local size = 2 + hash(site.key .. "#n") % 3
    if fn(off, "censusSeats") then local ok, seats = pcall(off.censusSeats, size, fid, h); if ok and tonumber(seats) then size = math.min(size, seats) end end
    if size < 1 then return nil, "census" end
    local okD, members = pcall(off.drawMembers, rosters[fid], size)
    if not okD or type(members) ~= "table" or #members == 0 then return nil, "draw" end
    local ticket = nil
    if fn(pressure, "reserve") then
        local ok, t = pcall(pressure.reserve, { id = "talkseed:" .. site.key .. ":" .. tostring(h), x = site.center.x, y = site.center.y, z = 0, hours = h })
        if not ok or t == nil then return nil, "pressure" end
        ticket = t
    end
    local g = Graph()
    local node = nil
    if g and fn(g, "nearest") then local ok, id = pcall(g.nearest, site.center.x, site.center.y); if ok then node = id end end
    local label = fid
    pcall(function() local f = cat.faction(fid); if type(f.general) == "table" and type(f.general.name) == "string" then label = f.general.name end end)
    local okC, squad = pcall(led.create, { name = tostring(label) .. " " .. (fn(led, "nextSuffix") and led.nextSuffix() or "S"), factionId = fid,
        x = site.center.x, y = site.center.y, nodeId = node, homeNodeId = node, members = members, foundedHours = h, decisionDueHours = h + 2 })
    if not okC or type(squad) ~= "table" then
        if ticket and fn(pressure, "release") then pcall(pressure.release, ticket, h) end
        return nil, "create"
    end
    if ticket and fn(pressure, "commit") then pcall(pressure.commit, ticket, h, squad.id) end
    M.sbStats.spawned = M.sbStats.spawned + 1
    return led.peek(squad.id) or squad
end

----------------------------------------------------------------------------------------------------------------
-- making a seeded base
----------------------------------------------------------------------------------------------------------------
function M.sbMake(site, h, origin)
    local hv = H()
    if not fn(hv, "store") then return nil, "no_havens" end
    local px, py = pos(thePlayer())
    if mpServer() and type(origin) == "table" and origin.x ~= nil then px, py = pos(ALifeSide.nearest(origin.x, origin.y)) end
    local squad = M.sbFindSquad(site, px, py)
    local group = squad == nil and M.sbFindGroup(site, px, py) or nil
    local how = squad and "squad" or (group and "group" or nil)
    if how == nil and M.settings.seededSpawn ~= false then
        local why
        squad, why = M.sbSpawn(site, h)
        if squad then how = "spawned" else M.sbStats.spawnRefused = M.sbStats.spawnRefused + 1; M.sbLastRefusal = why end
    end
    if how == nil then return nil, "nobody" end
    -- A-Life's haven (same record as a 0.5.2 base), our record on top
    local store = hv.store()
    local depot = nil
    if fn(hv, "depotIn") then local ok, d = pcall(hv.depotIn, site.bounds, 0); if ok and type(d) == "table" then depot = d end end
    local guess = depot == nil
    if guess then depot = { x = math.floor(site.center.x) + 0.5, y = math.floor(site.center.y) + 0.5, z = 0 } end
    store.seq = (tonumber(store.seq) or 0) + 1
    local id = "haven:" .. store.seq
    local key = fn(hv, "keyOf") and hv.keyOf(site.bounds) or site.key
    local haven = { id = id, kind = "house", state = "active", x = site.center.x, y = site.center.y, z = 0, buildingKey = key, bounds = site.bounds,
        depot = depot, foundedHours = h, lastHomeHours = h, stock = { items = 0 }, groupId = squad and squad.id or (group and group.id) or nil,
        foundedBy = "ALifeTalkSeed" }
    store.byId[id] = haven
    store.byBuilding = type(store.byBuilding) == "table" and store.byBuilding or {}
    store.byBuilding[key] = id
    if type(hv.metrics) == "table" then hv.metrics.founded = (hv.metrics.founded or 0) + 1 end
    if fn(hv, "dirty") then pcall(hv.dirty) end
    local fortified = unit(key .. "#stage" .. M.sbStore().salt) < 0.4
    local crew, faction = {}, nil
    local b = { id = id, by = "seed", squads = {} }
    if how == "group" then
        local reg = PA().ActorRegistry
        for _, r in ipairs(group.members) do
            pcall(reg.update, r.uid, r.revision, function(entry)
                entry.memory = type(entry.memory) == "table" and entry.memory or {}
                entry.memory.havenId = id
                entry.memory.supplyDepot = { x = depot.x, y = depot.y, z = depot.z or 0 }
                entry.worldPosition = { x = depot.x + (hash(r.uid) % 3) - 1, y = depot.y + (hash(r.uid .. "y") % 3) - 1, z = 0 }
            end)
            crew[#crew + 1] = (fn(reg, "read") and reg.read(r.uid)) or r
        end
        faction = group.members[1] and group.members[1].factionId or nil
        M.sbStats.homedGroups = M.sbStats.homedGroups + 1
    end
    -- 0.6.0: what they really carry, nothing more (was 5-10 days of food from nowhere)
    local food = M.nbCarriedFood and M.nbCarriedFood(how == "group" and crew or (squad and squad.members) or {}) or 0
    local morale = 55 + hash(key .. "#mor") % 21
    local extra = { seeded = true, seedHow = how, seedNode = origin and origin.id or nil, stage = fortified and "fortified" or "camp",
        work = fortified and M.nbCfg.fortWork or M.nbCfg.campWork, food = food, morale = morale, depotGuess = guess or nil,
        whyText = "they have held it for a while", houseWhy = site.why }
    -- the record first (so the squad can point at it), then the squad homes there
    local tmp = { id = id, status = "active", name = "?", x = site.center.x, y = site.center.y, bounds = site.bounds, squads = {} }
    M.nbStore().byId[id] = tmp
    if squad then
        if not M.sbHomeSquad(squad, tmp, depot, h) then
            M.nbStore().byId[id] = nil
            store.byId[id], store.byBuilding[key] = nil, nil
            return nil, "home_failed"
        end
        if how == "squad" then M.sbStats.homedSquads = M.sbStats.homedSquads + 1 end
        crew = M.sbCrewOf(tmp)
        faction = squad.factionId
        extra.squads = tmp.squads
    end
    extra.faction = faction
    b = M.nbAdopt(haven, "seed", crew, extra)
    b.squads = tmp.squads
    if M.keyMem then for _, r in ipairs(crew) do if not r.virtual then pcall(M.keyMem, tostring(r.uid), "home", "Lives at " .. b.name) end end end
    local s = M.sbStore()
    s.made, s.lastH = s.made + 1, h
    if M.sbSeededActive() >= M.sbCount() then s.initDone = true end
    M.sbStats.seeded = M.sbStats.seeded + 1
    M.nbScanCache = nil
    log("seeded " .. b.name .. " (" .. id .. ", " .. b.stage .. ") at " .. math.floor(site.center.x) .. "," .. math.floor(site.center.y)
        .. " for " .. how .. " (" .. #crew .. " people), score " .. tostring(site.score))
    return b
end
function M.sbSeedTick(h)
    if not M.sbOn() or not M.nbHavensOn() then return 0 end
    local want = M.sbCount()
    if want <= 0 or M.sbSeededActive() >= want then return 0 end
    if #M.nbActive() >= M.nbCap() then M.sbStats.refused = M.sbStats.refused + 1; return 0 end
    local s = M.sbStore()
    -- the first set comes at world start / first load; after that one at a time, a day apart (more allowed, or one fell)
    if s.initDone and h - (tonumber(s.lastH) or -1e9) < M.sbCfg.regapH then return 0 end
    M.sbStats.seedPasses = M.sbStats.seedPasses + 1
    local origins = M.sbOrigins()
    if #origins == 0 then return 0 end
    s.cursor = (s.cursor % #origins) + 1
    local o = origins[s.cursor]
    local px, py = pos(mpServer() and ALifeSide.nearest(o.x, o.y) or thePlayer())
    if px ~= nil and d2(o.x, o.y, px, py) < M.sbCfg.minPlayerTiles ^ 2 then return 0 end
    local site, refused = M.sbChooseSite(o, h)
    M.sbLast = { origin = o.id, refused = refused, site = site and site.key or nil, h = h }
    if site == nil then return 0 end
    M.sbStats.sites = M.sbStats.sites + 1
    local b, why = M.sbMake(site, h, o)
    M.sbLast.made, M.sbLast.why = b and b.id or nil, why
    return b and 1 or 0
end

----------------------------------------------------------------------------------------------------------------
-- materialize on approach: boards on existing openings + a few supplies in an existing container (once per stage)
----------------------------------------------------------------------------------------------------------------
function M.sbMaterialize(b, h, px, py)
    local hv = H()
    local haven = fn(hv, "of") and hv.of(b.id) or nil
    if haven == nil or type(b.bounds) ~= "table" then return false end
    local cx, cy = math.floor((b.bounds.x1 + b.bounds.x2) / 2), math.floor((b.bounds.y1 + b.bounds.y2) / 2)
    local sq = fn(hv, "squareAt") and hv.squareAt(cx, cy, 0) or nil
    if sq == nil then return false end -- not loaded yet
    b.mat = type(b.mat) == "table" and b.mat or {}
    local m = b.mat
    -- the real depot, now that the house is loaded
    if b.depotGuess and fn(hv, "depotIn") then
        local ok, d = pcall(hv.depotIn, b.bounds, 0)
        if ok and type(d) == "table" then
            haven.depot = d
            b.depotGuess = nil
            local reg = PA().ActorRegistry
            for _, r in ipairs(M.nbScan(true).crews[b.id] or {}) do
                pcall(reg.update, r.uid, r.revision, function(e) if type(e.memory) == "table" then e.memory.supplyDepot = { x = d.x, y = d.y, z = d.z or 0 } end end)
            end
        end
    end
    local close = px ~= nil and inside(b.bounds, px, py, M.sbCfg.matSafeTiles)
    if close then return false end -- never changes things in front of you: done before you get this close
    local ob = PA().OutpostBuilder
    local want = b.stage == "fortified" and M.sbCfg.boardFort or (b.stage == "camp" and M.sbCfg.boardCamp or 0)
    if m.stage ~= b.stage then
        local boarded = 0
        if want > 0 and fn(ob, "probeBuilding") and fn(ob, "barricadeWindow") then
            pcall(function()
                local bld = sq:getBuilding()
                local probe = bld and ob.probeBuilding(bld) or nil
                if probe == nil or probe.complete == false then boarded = -1; return end
                local planks = b.stage == "fortified" and 3 or 2
                local main = fn(ob, "mainEntrance") and ob.mainEntrance(probe.doors(), probe.roadSide) or nil
                for _, w in ipairs(probe.windows()) do
                    if boarded >= want then break end
                    if (tonumber(w.z) or 0) == 0 and w.barricaded ~= true then
                        local ok, done = pcall(ob.barricadeWindow, w.objectX or w.x, w.objectY or w.y, 0, planks, nil, w.north)
                        if ok and done then boarded = boarded + 1 end
                    end
                end
                if b.stage == "fortified" and fn(ob, "barricadeDoor") then
                    for _, d in ipairs(probe.doors()) do
                        if boarded >= want then break end
                        if d ~= main and (tonumber(d.z) or 0) == 0 and d.barricaded ~= true then
                            local ok, done = pcall(ob.barricadeDoor, d.objectX or d.x, d.objectY or d.y, 0, planks, d.north)
                            if ok and done then boarded = boarded + 1 end
                        end
                    end
                end
            end)
        end
        if boarded >= 0 then
            m.stage, m.boarded, m.h = b.stage, (m.boarded or 0) + boarded, h
            M.sbStats.boarded = M.sbStats.boarded + boarded
        end
    end
    if not m.stash then
        local container = fn(hv, "containerAt") and hv.containerAt(haven.depot) or nil
        if container ~= nil then
            local draws = M.sbCfg.stashDraws[b.stage] or 4
            local added = 0
            for i = 1, draws do
                local row = M.sbStash[(hash(b.id .. "#stash" .. i) % #M.sbStash) + 1]
                for _ = 1, 1 + hash(b.id .. "#q" .. i) % row[2] do
                    if pcall(function() container:AddItem(row[1]) end) then added = added + 1 end
                end
            end
            m.stash, m.stashN = h, added
            M.sbStats.stashed = M.sbStats.stashed + added
        else
            m.noContainer = true
            m.stash = h -- no furniture is ever placed; nothing to fill
        end
    end
    if m.done == nil and m.stage == b.stage and m.stash then
        m.done = h
        M.sbStats.materialized = M.sbStats.materialized + 1
        log("materialized " .. tostring(b.name) .. ": boards " .. tostring(m.boarded) .. ", stash " .. tostring(m.stashN or 0))
    end
    return true
end
function M.sbMatTick(h)
    local player = thePlayer()
    local px, py = pos(player)
    if px == nil then return 0 end
    local n = 0
    for _, b in ipairs(M.nbActive()) do
        if mpServer() then px, py = pos(ALifeSide.nearest(b.x, b.y)); px = px or -1e9; py = py or -1e9 end -- MP: the player nearest this base
        if b.seeded and d2(b.x, b.y, px, py) <= M.sbCfg.matTiles ^ 2 then
            local m = type(b.mat) == "table" and b.mat or {}
            if m.stage ~= b.stage or not m.stash or b.depotGuess then
                if M.sbMaterialize(b, h, px, py) then n = n + 1 end
                break -- one base per pass
            end
        end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- tick (called from M.nbTick, already 1 s gated): materialize check 5 s, seeding pass 30 s; perf counted
----------------------------------------------------------------------------------------------------------------
M.sbLastT = { mat = -1e12, seed = -1e12, first = nil }
function M.sbTick(now)
    if not M.nbOn() then return end
    local L = M.sbLastT
    if L.first == nil then L.first = now end
    local doMat = now - L.mat >= M.sbCfg.matMs
    local doSeed = now - L.seed >= M.sbCfg.seedMs and now - L.first >= M.sbCfg.firstMs
    if not doMat and not doSeed then return end
    local t0 = (getTimestampMs and getTimestampMs()) or nowMs()
    M.sbStats.ticks = M.sbStats.ticks + 1
    pcall(M.sbInstall)
    local h = hours()
    if doMat then L.mat = now; local ok, e = pcall(M.sbMatTick, h); if not ok then log("materialize error: " .. tostring(e)) end end
    if doSeed then L.seed = now; local ok, e = pcall(M.sbSeedTick, h); if not ok then log("seed error: " .. tostring(e)) end end
    local dt = ((getTimestampMs and getTimestampMs()) or nowMs()) - t0
    M.sbStats.ms = M.sbStats.ms + dt
    if dt > M.sbStats.maxMs then M.sbStats.maxMs = dt end
end
function M.sbPerf()
    local s = M.sbStats
    return string.format("seeded %d active (%d made), passes %d, queries %d, rooms %d, homed squads %d groups %d, spawned %d, tasks %d (returns %d, snaps %d), "
        .. "approach blocked %d, render tagged %d, crew saves %d, materialized %d (boards %d, stash %d), deaths %d, released %d, avg %.3f ms, max %.1f ms",
        M.sbSeededActive(), M.sbStore().made, s.seedPasses, s.queries, s.rooms, s.homedSquads, s.homedGroups, s.spawned, s.tasks, s.returns, s.snaps,
        s.approachBlocked, s.renderTagged, s.crewAliveSaves, s.materialized, s.boarded, s.stashed, s.deaths, s.released,
        s.ticks > 0 and s.ms / s.ticks or 0, s.maxMs)
end
pcall(M.sbInstall)
return M
