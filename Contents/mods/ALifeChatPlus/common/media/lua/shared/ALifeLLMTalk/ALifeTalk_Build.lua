-- A-Life Chat Plus 0.3.2: NPC BASES BUILD WITH REAL MATERIALS.
-- People living in a Chat Plus base (seeded bases, the airport, settled groups) fortify it from what they gather:
--  * chop trees near the base (real tree removed) -> logs in the base's stockpile container
--  * saw logs -> planks at the stockpile
--  * evenings: take doors off other buildings (real door removed) -> hinges + a doorknob
--  * board the ground-floor windows (planks + nails), raise a log palisade around the house (logs), hang a gate
--    in it (planks + hinges + doorknob)
-- Tools are real: an axe to chop, a saw for planks, a screwdriver for doors, in someone's hands or in the stockpile.
-- Missing tools / nails go on the base's want list (they mention it when you talk to them; you can bring some).
-- Seen work: a rendered NPC walks to the tree / door / window, plays A-Life's chop / saw / board-up animation, and the
-- world changes when they finish. Unseen work: progress per game day on a ledger; when you come within range the
-- ledger is settled for real (stumps where trees were, doors gone, walls up, items in the stockpile) - never in
-- front of you (25 tiles).
-- Hooks: a behaviour module in A-Life's own module registry (after combat, fear and player orders; before chores).
-- World edits use A-Life's own builder calls (placeThumpable / placeMapTile / barricadeWindow) and the same tree
-- removal A-Life uses when it clears outpost ground. A-Life files are untouched.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Build") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
-- pre-1.0 MP (P4): bases are shared world places (one co-op world), so this file ticks per BASE, not per player. A
-- base counts as seen when ANY online player is within loadedTiles (the nearest one stands in for "you"); unseen work
-- is settled only far from EVERY player; doors / furniture are never taken near any player; a person in anyone's
-- party doesn't work. The A-Life module + talk extras only register where the world runs. SP: unchanged.
require "ALifeLLMTalk/ALifeLLMTalk_Seeded"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) if M.log then M.log("build: " .. tostring(msg)) else print("[ALifeNPCOverhaul] build: " .. tostring(msg)) end end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hourOfDay() local h = nil; pcall(function() h = getGameTime():getHour() end); return tonumber(h) or (math.floor(hours()) % 24) end
local function nowMs() return (type(getTimestampMs) == "function" and getTimestampMs()) or (M.nowMs and M.nowMs()) or 0 end
local function thePlayer() return ALifeSide.you() end
local function pos(o) if o == nil then return nil end; local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
local function H() return PA().Havens end
local function OB() return PA().OutpostBuilder end
-- PZ's Kahlua has no next(): emptiness by pairs
local function tableHasAny(t) if type(t) ~= "table" then return false end; for _ in pairs(t) do return true end; return false end
local function isA(o, cls) local ok, v = pcall(function() return instanceof(o, cls) end); return ok and v == true end
-- pre-1.0 MP (P4): on an MP server there is no single "you": every online player counts
local function mpOn() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
-- is any online living player closer than tiles to (x, y)? (strictly closer, like the old single-player checks)
local function playerNear(x, y, tiles)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return false end
    local lim = (tonumber(tiles) or 0) ^ 2
    for _, p in ipairs(ALifeSide.online()) do
        local dead = false
        pcall(function() dead = p:isDead() == true end)
        local px, py = pos(p)
        if not dead and px ~= nil and d2(x, y, px, py) < lim then return true end
    end
    return false
end
M.bdPlayerNear = playerNear

if M.settings and M.settings.npcBuild == nil then M.settings.npcBuild = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, k in ipairs(M.fileKeys) do if k == "npcBuild" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "npcBuild" end
end

M.bdCfg = {
    radius = 30,                 -- trees within this many tiles of the base
    doorRadius = 70, doorMinFromBase = 6,
    workFrom = 7, workTo = 19,   -- daylight jobs
    salvageFrom = 17, salvageTo = 21, -- door salvage hours ("in other hours")
    chopMs = 20000, sawMs = 12000, doorMs = 15000, wallMs = 12000, boardMs = 9000, gateMs = 15000,
    walkTimeoutMs = 60000, banMs = 600000,
    logsPerTree = 2, planksPerLog = 3, logsPerWall = 4, planksPerWindow = 2, nailsPerPlank = 2,
    gatePlanks = 4, gateHinges = 2, gateKnobs = 1, hingesPerDoor = 2, knobsPerDoor = 1,
    ringPad = 3, ringMaxSegments = 140,
    maxChop = 3, maxSaw = 1, maxDoor = 1, maxBuild = 2,
    scanSquares = 500,           -- tree / door scan budget per pass
    planMs = 5000, tickMs = 1000,
    playerSafeTiles = 25,        -- never change the world this close to you when settling unseen work
    loadedTiles = 90,            -- base counts as "loaded" (seen) when you are this close
    -- unseen progress per game day
    dayLogsPerWorker = 4, dayMaxWorkers = 4, dayPlanks = 6, dayWalls = 4, dayDoors = 1, toolFindChance = 0.12,
    pendCap = 200,
    -- supply runs: how far they look, step by step, as the near ground runs dry
    ranges = { 30, 100, 200, 300 }, widenBelow = 4,
    carryLogs = 2, carryPlanks = 6,   -- what one person carries back in one trip
    runTiles = 40,                    -- further than this is a supply run (they carry it home)
    -- unseen trips per worker per day by distance: near = several, far = one
    tripsNear = 3, tripsAt100 = 2, tripsFar = 1,
    -- wooden furniture / fences: sprite prefix, planks, nails (taken with a hammer or saw; never containers)
    woodSprites = {
        { "furniture_tables_high_01", 2, 2 }, { "furniture_tables_low_01", 2, 2 },
        { "furniture_seating_indoor_01", 1, 1 }, { "furniture_seating_indoor_02", 1, 1 },
        { "furniture_shelving_01", 2, 2 }, { "fencing_01", 1, 1 },
    },
    woodMs = 12000, maxWood = 2,
}
M.bdItems = { log = "Base.Log", plank = "Base.Plank", nails = "Base.Nails", hinge = "Base.Hinge", knob = "Base.Doorknob" }
M.bdTools = {
    axe = { "Base.Axe", "Base.WoodAxe", "Base.HandAxe", "Base.AxeStone" },
    saw = { "Base.Saw", "Base.GardenSaw", "Base.SmallSaw", "Base.CrudeSaw" },
    screwdriver = { "Base.Screwdriver", "Base.Multitool" },
    hammer = { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer" },
}
M.bdWantWords = { axe = "an axe", saw = "a saw", screwdriver = "a screwdriver", hammer = "a hammer", wood = "wood (nothing left to cut nearby)", nails = "nails", log = "logs",
    plank = "planks", hinge = "hinges", knob = "a doorknob" }
M.bdStats = { evals = 0, claimed = 0, chopped = 0, sawn = 0, doors = 0, walls = 0, windows = 0, gates = 0,
    walks = 0, bans = 0, settled = 0, days = 0, toolsFound = 0, missingItems = 0, ms = 0, maxMs = 0 }

function M.bdOn() return M.settings.npcBuild ~= false and M.nbOn() end

----------------------------------------------------------------------------------------------------------------
-- items: verified once against the game's scripts (a missing item is skipped with one log line, never spawned blind)
----------------------------------------------------------------------------------------------------------------
M.bdKnown = {}
function M.bdItemOk(full)
    local v = M.bdKnown[full]
    if v ~= nil then return v end
    local ok, found = pcall(function() return getScriptManager():FindItem(full) end)
    v = ok and found ~= nil
    M.bdKnown[full] = v
    if not v then M.bdStats.missingItems = M.bdStats.missingItems + 1; log("item " .. full .. " not in this game - skipped") end
    return v
end

----------------------------------------------------------------------------------------------------------------
-- per-base record (saved with the base): ledger for unseen work, what's built, the want list
----------------------------------------------------------------------------------------------------------------
function M.bdRec(b)
    b.bd = type(b.bd) == "table" and b.bd or {}
    local r = b.bd
    r.pend = type(r.pend) == "table" and r.pend or {}     -- items made unseen, not yet in the stockpile
    r.owe = type(r.owe) == "table" and r.owe or {}        -- unseen world changes to settle: trees, doors, walls
    r.walls = type(r.walls) == "table" and r.walls or {}  -- ring piece key -> true (built)
    r.tools = type(r.tools) == "table" and r.tools or {}  -- last known: axe / saw / screwdriver
    r.want = type(r.want) == "table" and r.want or {}
    r.dayH = tonumber(r.dayH) or hours()
    for _, k in ipairs({ "trees", "doors", "walls", "windows", "wood" }) do r.owe[k] = tonumber(r.owe[k]) or 0 end
    return r
end

----------------------------------------------------------------------------------------------------------------
-- the stockpile: A-Life's depot container for the base (real items), plus the unseen ledger
----------------------------------------------------------------------------------------------------------------
function M.bdDepot(b)
    local hv = H()
    local haven = fn(hv, "of") and hv.of(b.id) or nil
    local d = haven and type(haven.depot) == "table" and haven.depot or nil
    return d or { x = b.x, y = b.y, z = 0 }
end
function M.bdContainer(b)
    local hv = H()
    if not fn(hv, "containerAt") then return nil end
    local ok, c = pcall(hv.containerAt, M.bdDepot(b))
    return ok and c or nil
end
local function count(c, full)
    if c == nil then return 0 end
    local n = 0
    pcall(function() n = tonumber(c:getCountTypeRecurse(full)) or 0 end)
    return n
end
local function take(c, full, want)
    local taken = 0
    while c ~= nil and taken < want do
        local item = nil
        pcall(function() item = c:getFirstTypeRecurse(full) end)
        if item == nil then break end
        local ok = pcall(function() item:getContainer():DoRemoveItem(item) end)
        if not ok then break end
        taken = taken + 1
    end
    return taken
end
local function give(c, full, n)
    if c == nil or n <= 0 or not M.bdItemOk(full) then return 0 end
    local added = 0
    for _ = 1, n do if pcall(function() c:AddItem(full) end) then added = added + 1 end end
    return added
end
-- how many of a material the base has: stockpile (if loaded) + ledger
function M.bdHave(b, key, c)
    local r = M.bdRec(b)
    return count(c, M.bdItems[key]) + (tonumber(r.pend[key]) or 0)
end
-- spend from the ledger first, then the stockpile; true when all of it was there
function M.bdSpend(b, key, n, c)
    if M.bdHave(b, key, c) < n then return false end
    local r = M.bdRec(b)
    local fromLedger = math.min(n, tonumber(r.pend[key]) or 0)
    r.pend[key] = (tonumber(r.pend[key]) or 0) - fromLedger
    local rest = n - fromLedger
    if rest > 0 and take(c, M.bdItems[key], rest) < rest then return false end
    return true
end
function M.bdAdd(b, key, n, c)
    if c ~= nil then
        local added = give(c, M.bdItems[key], n)
        if added == n then return end
        n = n - added
    end
    local r = M.bdRec(b)
    r.pend[key] = math.min(M.bdCfg.pendCap, (tonumber(r.pend[key]) or 0) + n)
end
-- put the unseen ledger into the real stockpile
function M.bdFlush(b, c)
    if c == nil then return 0 end
    local r = M.bdRec(b)
    local moved = 0
    for key, n in pairs(r.pend) do
        n = tonumber(n) or 0
        if n > 0 and M.bdItems[key] then
            local added = give(c, M.bdItems[key], n)
            r.pend[key] = n - added
            moved = moved + added
        end
    end
    return moved
end

----------------------------------------------------------------------------------------------------------------
-- tools: in the worker's hands / inventory, or in the stockpile
----------------------------------------------------------------------------------------------------------------
local function hasAny(inv, list)
    if inv == nil then return false end
    for _, full in ipairs(list) do if count(inv, full) > 0 then return true end end
    return false
end
function M.bdHasTool(kind, shell, c)
    local list = M.bdTools[kind]
    if list == nil then return false end
    local inv = nil
    if shell ~= nil then pcall(function() inv = shell:getInventory() end) end
    return hasAny(inv, list) or hasAny(c, list)
end

----------------------------------------------------------------------------------------------------------------
-- the palisade ring: A-Life's own architect lays it out (walls_logs family + a fence gate on the road side)
----------------------------------------------------------------------------------------------------------------
M.bdRings = {}
function M.bdRing(b)
    local cached = M.bdRings[b.id]
    if cached ~= nil then return cached end
    local arch = PA().OutpostArchitect
    local bb = type(b.bounds) == "table" and b.bounds or nil
    if bb == nil or not fn(arch, "newPlan") or not fn(arch, "box") or type(arch.family) ~= "table" or arch.family.palisade == nil then
        M.bdRings[b.id] = false
        return false
    end
    local pad = M.bdCfg.ringPad
    local x1, y1, x2, y2 = bb.x1 - pad, bb.y1 - pad, bb.x2 + pad, bb.y2 + pad
    local per = 2 * ((x2 - x1 + 1) + (y2 - y1 + 1))
    if per > M.bdCfg.ringMaxSegments then M.bdRings[b.id] = false; return false end
    local side = (b.roadSide == "N") and "N" or "S"
    local gx = math.floor((x1 + x2) / 2) - 1
    local plan = arch.newPlan(hash(b.id))
    local ok = pcall(arch.box, plan, x1, y1, x2, y2, 0, arch.family.palisade, { { side = side, at = gx, kind = "gate" } })
    if not ok then M.bdRings[b.id] = false; return false end
    local fam = arch.family.palisade
    local gateSprites = {}
    if type(arch.piece) == "table" and type(arch.piece.gateN) == "table" then for _, s in ipairs(arch.piece.gateN) do gateSprites[s] = true end end
    local ring = { walls = {}, gate = {}, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    for _, op in ipairs(plan.ops or {}) do
        if op.op == "tile" and op.sprite then
            local piece = { x = op.x, y = op.y, z = op.z or 0, sprite = op.sprite, key = op.x .. ":" .. op.y .. ":" .. op.sprite }
            if gateSprites[op.sprite] then ring.gate[#ring.gate + 1] = piece
            else
                piece.north = op.sprite == fam.n
                piece.corner = op.sprite == fam.nw or op.sprite == fam.se
                ring.walls[#ring.walls + 1] = piece
            end
        end
    end
    -- build order: walk the ring from the gate outward so the open side closes last
    table.sort(ring.walls, function(a, c)
        local da, dc = d2(a.x, a.y, gx, (side == "N") and y1 or y2), d2(c.x, c.y, gx, (side == "N") and y1 or y2)
        if da ~= dc then return da > dc end
        return a.key < c.key
    end)
    M.bdRings[b.id] = ring
    return ring
end
function M.bdNextWall(b)
    local ring = M.bdRing(b)
    if not ring then return nil end
    local r = M.bdRec(b)
    for _, p in ipairs(ring.walls) do if not r.walls[p.key] then return p end end
    return nil
end
function M.bdWallsDone(b)
    local ring = M.bdRing(b)
    return ring ~= false and M.bdNextWall(b) == nil
end
function M.bdPlaceWall(p)
    local ob = OB()
    if p.corner then
        return fn(ob, "placeMapTile") and ob.placeMapTile(p.x, p.y, p.z, p.sprite) ~= nil
    end
    return fn(ob, "placeThumpable") and ob.placeThumpable(p.x, p.y, p.z, p.sprite, p.north) ~= nil
end
function M.bdPlaceGate(ring)
    local ob = OB()
    if not fn(ob, "placeMapTile") then return false end
    local all = true
    for _, p in ipairs(ring.gate) do if ob.placeMapTile(p.x, p.y, p.z, p.sprite) == nil then all = false end end
    return all
end

----------------------------------------------------------------------------------------------------------------
-- the base's windows (A-Life's building probe): ground floor, not yet barricaded
----------------------------------------------------------------------------------------------------------------
M.bdWin = {}
function M.bdWindows(b, h)
    local c = M.bdWin[b.id]
    if c and h - c.h < 0.5 then return c.list end
    local list = {}
    local ob, hv = OB(), H()
    if fn(ob, "probeBuilding") and type(b.bounds) == "table" then
        pcall(function()
            local cx, cy = math.floor((b.bounds.x1 + b.bounds.x2) / 2), math.floor((b.bounds.y1 + b.bounds.y2) / 2)
            local sq = fn(hv, "squareAt") and hv.squareAt(cx, cy, 0) or getCell():getGridSquare(cx, cy, 0)
            local bld = sq and sq:getBuilding() or nil
            local probe = bld and ob.probeBuilding(bld) or nil
            if probe == nil or probe.complete == false then return end
            for _, w in ipairs(probe.windows()) do
                if (tonumber(w.z) or 0) == 0 and w.barricaded ~= true then list[#list + 1] = w end
            end
        end)
    end
    M.bdWin[b.id] = { h = h, list = list }
    return list
end

----------------------------------------------------------------------------------------------------------------
-- finding trees and doors around a loaded base (budgeted scans, cached)
----------------------------------------------------------------------------------------------------------------
M.bdScan = {}
local function scanState(b)
    local s = M.bdScan[b.id]
    if s == nil then s = { trees = {}, doors = {}, wood = {}, i = 0, done = false, h = -1e9, R = 0 }; M.bdScan[b.id] = s end
    return s
end
local function sqAt(x, y)
    local sq = nil
    pcall(function() sq = getCell():getGridSquare(x, y, 0) end)
    return sq
end
local function inBounds(bb, x, y, pad)
    pad = pad or 0
    return type(bb) == "table" and x >= bb.x1 - pad and x <= bb.x2 + pad and y >= bb.y1 - pad and y <= bb.y2 + pad
end
-- wooden furniture / fences worth stripping for planks + nails (by sprite name; containers are never taken)
local function woodKind(o)
    local name = nil
    pcall(function() name = o:getSprite():getName() end)
    if type(name) ~= "string" then return nil end
    for _, row in ipairs(M.bdCfg.woodSprites) do
        if string.sub(name, 1, #row[1]) == row[1] then
            local hasBox = false
            pcall(function() hasBox = o:getContainer() ~= nil end)
            if hasBox then return nil end
            return row
        end
    end
    return nil
end
local function inAnyBase(x, y, pad)
    for _, o in ipairs(M.nbActive()) do if inBounds(o.bounds, x, y, pad) then return true end end
    return false
end
-- how far out they look now: 30, then 100, 200, 300 tiles as the near ground runs dry
function M.bdRange(b)
    local r = M.bdRec(b)
    local i = math.max(1, math.min(#M.bdCfg.ranges, tonumber(r.range) or 1))
    r.range = i
    return M.bdCfg.ranges[i], i
end
-- one budgeted pass over the square out to the current range, in 10x10 blocks; a block whose corner isn't
-- loaded is skipped whole (unloaded ground costs nothing). Trees, doors and wooden furniture / fences.
function M.bdScanStep(b, h)
    local s = scanState(b)
    local range = M.bdRange(b)
    local R = math.max(range, M.bdCfg.doorRadius) -- doors are looked for out to doorRadius from the start
    if s.done and h - s.h < 6 and s.R == R and s.range == range then return s end
    if s.done or s.R ~= R or s.range ~= range then s.trees, s.doors, s.wood, s.i, s.done, s.R, s.range = {}, {}, {}, 0, false, R, range end
    local r2 = range * range
    local B = 10
    local blocks = math.ceil((2 * R + 1) / B)
    local cx, cy = math.floor(b.x), math.floor(b.y)
    local budget = M.bdCfg.scanSquares
    local total = blocks * blocks
    local pad = M.bdCfg.ringPad + 1
    while budget > 0 and s.i < total do
        local i = s.i
        s.i = i + 1
        local bx, by = cx - R + (i % blocks) * B, cy - R + math.floor(i / blocks) * B
        if sqAt(bx, by) == nil and sqAt(bx + B - 1, by + B - 1) == nil then
            budget = budget - 1
        else
            budget = budget - B * B
            for x = bx, bx + B - 1 do
                for y = by, by + B - 1 do
                    local dd = d2(x, y, cx, cy)
                    local sq = dd <= R * R and sqAt(x, y) or nil
                    if sq ~= nil then
                        pcall(function()
                            local objs = sq:getObjects()
                            for k = 0, objs:size() - 1 do
                                local o = objs:get(k)
                                if isA(o, "IsoTree") then
                                    if dd <= r2 and not inBounds(b.bounds, x, y, pad) then s.trees[#s.trees + 1] = { x = x, y = y, key = x .. ":" .. y, dist = math.sqrt(dd) } end
                                elseif isA(o, "IsoDoor") then
                                    if not inBounds(b.bounds, x, y, M.bdCfg.doorMinFromBase) then
                                        s.doors[#s.doors + 1] = { x = x, y = y, north = o:getNorth() == true, key = x .. ":" .. y .. ":" .. tostring(o:getNorth()), dist = math.sqrt(dd) }
                                    end
                                else
                                    local row = dd <= r2 and woodKind(o) or nil
                                    if row and not inAnyBase(x, y, 2) then
                                        local nm = nil
                                        pcall(function() nm = o:getSprite():getName() end)
                                        s.wood[#s.wood + 1] = { x = x, y = y, sprite = nm, planks = row[2], nails = row[3],
                                            key = x .. ":" .. y .. ":" .. tostring(nm), dist = math.sqrt(dd) }
                                    end
                                end
                            end
                        end)
                    end
                end
            end
        end
    end
    if s.i >= total then
        s.done, s.h = true, h
        local function near(p, q) return p.dist < q.dist end
        table.sort(s.trees, near); table.sort(s.doors, near); table.sort(s.wood, near)
        M.bdAfterScan(b, s)
    end
    return s
end
-- what the scan found decides what unseen work can count on, and whether to look further out
function M.bdFree(list)
    local n = 0
    for _, t in ipairs(list) do if not t.gone and not t.owed then n = n + 1 end end
    return n
end
function M.bdAfterScan(b, s)
    local r = M.bdRec(b)
    local function avg(list)
        local sum, n = 0, 0
        for _, t in ipairs(list) do if not t.gone and not t.owed then sum, n = sum + t.dist, n + 1 end end
        return n > 0 and sum / n or 0
    end
    -- owed (unseen) work is pinned to real things the scan found, nearest first
    local function pin(list, n)
        for _, t in ipairs(list) do
            if n <= 0 then break end
            if not t.gone then t.owed = true; n = n - 1 end
        end
    end
    pin(s.trees, r.owe.trees); pin(s.doors, r.owe.doors); pin(s.wood, tonumber(r.owe.wood) or 0)
    r.known = { trees = M.bdFree(s.trees), doors = M.bdFree(s.doors), wood = M.bdFree(s.wood),
        treeDist = avg(s.trees), doorDist = avg(s.doors), woodDist = avg(s.wood), R = s.range }
    local _, idx = M.bdRange(b)
    if r.known.trees + r.known.wood < M.bdCfg.widenBelow and idx < #M.bdCfg.ranges then
        r.range = idx + 1
        log(tostring(b.name) .. ": wood is getting thin - they'll look out to " .. M.bdCfg.ranges[idx + 1] .. " tiles")
    end
end
-- a door that isn't anyone's home: not a player base / safehouse, not near you
function M.bdDoorOk(d, px, py)
    if px ~= nil and d2(d.x, d.y, px, py) < 20 ^ 2 then return false end
    if mpOn() and playerNear(d.x, d.y, 20) then return false end -- MP: not near any player
    local sq = sqAt(d.x, d.y)
    if sq == nil then return false end
    if SafeHouse ~= nil and fn(SafeHouse, "getSafeHouse") then
        local ok, sh = pcall(SafeHouse.getSafeHouse, sq)
        if ok and sh ~= nil then return false end
    end
    local heat = PA().BaseHeat
    if fn(heat, "anchorOverlaps") then
        local ok, hit = pcall(heat.anchorOverlaps, d.x - 4, d.y - 4, d.x + 4, d.y + 4)
        if ok and hit then return false end
    end
    for _, o in ipairs(M.nbActive()) do if inBounds(o.bounds, d.x, d.y, 2) then return false end end
    return true
end
local function objOn(x, y, cls, north)
    local sq = sqAt(x, y)
    if sq == nil then return nil, nil end
    local found = nil
    pcall(function()
        local objs = sq:getObjects()
        for k = 0, objs:size() - 1 do
            local o = objs:get(k)
            if isA(o, cls) and (north == nil or o:getNorth() == north) then found = o; break end
        end
    end)
    return found, sq
end
local function removeObj(x, y, cls, north)
    local o, sq = objOn(x, y, cls, north)
    if o == nil then return false end
    return pcall(function() sq:transmitRemoveItemFromSquare(o) end)
end

----------------------------------------------------------------------------------------------------------------
-- deciding what's needed (cached per base, a few seconds)
----------------------------------------------------------------------------------------------------------------
M.bdPlans = {}
-- next project and what it's short of: { kind = "board"|"wall"|"gate", target, need = { key = n } }
function M.bdProject(b, h, c)
    local cfg = M.bdCfg
    local r = M.bdRec(b)
    local wins = M.bdWindows(b, h)
    -- windows first (they matter most), unless there are no nails at all: then the palisade first
    local nailsFor = cfg.planksPerWindow * cfg.nailsPerPlank
    if #wins > 0 and M.bdHave(b, "nails", c) >= nailsFor then
        return { kind = "board", target = wins[1], need = { plank = cfg.planksPerWindow, nails = nailsFor } }
    end
    local wall = M.bdNextWall(b)
    if wall then return { kind = "wall", target = wall, need = { log = wall.corner and 1 or cfg.logsPerWall } } end
    local ring = M.bdRing(b)
    if ring and not r.gate and #ring.gate > 0 then
        return { kind = "gate", target = ring.gate[1], need = { plank = cfg.gatePlanks, hinge = cfg.gateHinges, knob = cfg.gateKnobs } }
    end
    if #wins > 0 then return { kind = "board", target = wins[1], need = { plank = cfg.planksPerWindow, nails = nailsFor } } end
    return nil
end
function M.bdShort(b, need, c)
    local short = {}
    for key, n in pairs(need or {}) do
        local have = M.bdHave(b, key, c)
        if have < n then short[key] = n - have end
    end
    return short
end
-- the want list the NPCs talk about (tools and nails they can't make)
function M.bdUpdateWants(b, shortList, toolMissing)
    local r = M.bdRec(b)
    local w = {}
    for _, k in ipairs({ "axe", "saw", "screwdriver", "hammer" }) do if toolMissing[k] then w[#w + 1] = k end end
    if shortList.nails then w[#w + 1] = "nails" end
    if shortList.wood then w[#w + 1] = "wood" end
    r.want = w
end

----------------------------------------------------------------------------------------------------------------
-- jobs for rendered people (runtime only; claims keep two people off the same tree / door / window)
----------------------------------------------------------------------------------------------------------------
M.bdJobs = {}     -- uid -> job
M.bdClaims = {}   -- target key -> uid
M.bdBans = {}     -- target key -> until ms (couldn't reach it)
local function busyCount(baseId, kind)
    local n = 0
    for _, j in pairs(M.bdJobs) do if j.base == baseId and j.kind == kind then n = n + 1 end end
    return n
end
local function claim(key, uid)
    local owner = M.bdClaims[key]
    if owner ~= nil and owner ~= uid then return false end
    if (M.bdBans[key] or 0) > nowMs() then return false end
    M.bdClaims[key] = uid
    return true
end
local function release(uid)
    local j = M.bdJobs[uid]
    if j and j.key and M.bdClaims[j.key] == uid then M.bdClaims[j.key] = nil end
    M.bdJobs[uid] = nil
end
M.bdRelease = release

-- pick a job for this person: build when the materials are there, else gather what's short
local function nearestFree(list, uid, ok)
    for _, t in ipairs(list) do
        if not t.gone and not t.owed and (ok == nil or ok(t)) and claim(t.kind .. ":" .. t.key, uid) then return t end
    end
    return nil
end
local function gatherJob(kind, b, t, uid, cfg, anim, ms)
    local spot = { x = t.x + 0.5 + ((hash(uid) % 2 == 0) and 1 or -1), y = t.y + 0.5, z = 0 }
    if kind ~= "chop" then spot = { x = t.x + 0.5, y = t.y + 0.5, z = 0 } end
    return { kind = kind, base = b.id, key = t.kind .. ":" .. t.key, target = t, spot = spot, ms = ms, anim = anim,
        run = (t.dist or 0) > cfg.runTiles or nil }
end
function M.bdPick(b, uid, shell, h, hour, c)
    local cfg = M.bdCfg
    if type(cfg) ~= "table" or b == nil or b.id == nil then return nil end
    local okP, proj = pcall(M.bdProject, b, h, c)
    if not okP then log("bdProject error: " .. tostring(proj)); proj = nil end
    local need = (type(proj) == "table" and type(proj.need) == "table") and proj.need or {}
    local short = M.bdShort(b, need, c)
    if type(short) ~= "table" then short = {} end
    local toolMissing = {}
    local day = hour >= (cfg.workFrom or 8) and hour < (cfg.workTo or 18)
    local evening = hour >= (cfg.salvageFrom or 18) and hour < (cfg.salvageTo or 22)
    local ring = M.bdRing(b)
    local okS, s = pcall(scanState, b)
    if not okS or type(s) ~= "table" then s = { trees = {}, doors = {}, wood = {} } end
    s.trees = type(s.trees) == "table" and s.trees or {}
    s.doors = type(s.doors) == "table" and s.doors or {}
    s.wood = type(s.wood) == "table" and s.wood or {}
    for _, t in ipairs(s.trees) do t.kind = "tree" end
    for _, t in ipairs(s.doors) do t.kind = "door" end
    for _, t in ipairs(s.wood) do t.kind = "wood" end
    local function shortEmpty()
        for _ in pairs(short) do return false end
        return true
    end
    -- 1) build
    if proj and shortEmpty() and day and busyCount(b.id, "build") < (cfg.maxBuild or 1) then
        local t = proj.target
        if type(t) ~= "table" then return nil end
        local key = tostring(proj.kind) .. ":" .. tostring(t.key or ((t.objectX or t.x) .. ":" .. (t.objectY or t.y)))
        if claim(key, uid) then
            local spot = { x = (t.x or t.objectX) + 0.5, y = (t.y or t.objectY) + 0.5, z = 0 }
            if proj.kind == "wall" or proj.kind == "gate" then
                -- stand inside the ring, next to the piece
                local ring2 = ring or {}
                local inX = (t.x <= (ring2.x1 or t.x)) and 1 or ((t.x > (ring2.x2 or t.x)) and -1 or 0)
                local inY = (t.y <= (ring2.y1 or t.y)) and 1 or ((t.y > (ring2.y2 or t.y)) and -1 or 0)
                spot = { x = t.x + 0.5 + inX, y = t.y + 0.5 + inY, z = 0 }
            end
            return { kind = "build", what = proj.kind, base = b.id, key = key, target = t, need = need, spot = spot,
                ms = (proj.kind == "board" and cfg.boardMs) or (proj.kind == "gate" and cfg.gateMs) or cfg.wallMs,
                anim = (proj.kind == "board") and "board_up" or "build_crate" }
        end
    end
    -- 2) saw planks
    if short.plank and M.bdHave(b, "log", c) > 0 and day then
        if not M.bdHasTool("saw", shell, c) then toolMissing.saw = true
        elseif busyCount(b.id, "saw") < cfg.maxSaw and claim("saw:" .. b.id, uid) then
            local d = M.bdDepot(b)
            return { kind = "saw", base = b.id, key = "saw:" .. b.id, spot = { x = d.x, y = d.y, z = 0 }, ms = cfg.sawMs, anim = "saw_planks" }
        end
    end
    -- 3) strip wooden furniture / fences in empty places: planks + nails (a hammer or a saw)
    if (short.plank or short.nails) and day and busyCount(b.id, "wood") < cfg.maxWood then
        if not (M.bdHasTool("hammer", shell, c) or M.bdHasTool("saw", shell, c)) then toolMissing.hammer = true
        else
            local px, py = pos(thePlayer())
            local t = nearestFree(s.wood, uid, function(w) return M.bdDoorOk(w, px, py) end)
            if t then return gatherJob("wood", b, t, uid, cfg, "search_mid", cfg.woodMs) end
        end
    end
    -- 4) chop
    if (short.log or (short.plank and M.bdHave(b, "log", c) == 0)) and day then
        if not M.bdHasTool("axe", shell, c) then toolMissing.axe = true
        elseif busyCount(b.id, "chop") < cfg.maxChop then
            local t = nearestFree(s.trees, uid)
            if t then return gatherJob("chop", b, t, uid, cfg, "chop_wood", cfg.chopMs) end
        end
    end
    -- 5) doors for hinges / knob, evenings
    if (short.hinge or short.knob) and evening then
        if not M.bdHasTool("screwdriver", shell, c) then toolMissing.screwdriver = true
        elseif busyCount(b.id, "door") < cfg.maxDoor then
            local px, py = pos(thePlayer())
            local t = nearestFree(s.doors, uid, function(d) return M.bdDoorOk(d, px, py) end)
            if t then return gatherJob("door", b, t, uid, cfg, "search_low", cfg.doorMs) end
        end
    end
    -- out of wood within the furthest range they'll go: say so
    local _, idx = M.bdRange(b)
    if (short.log or short.plank) and s.done and idx >= #cfg.ranges and M.bdFree(s.trees) == 0 and M.bdFree(s.wood) == 0 then
        short.wood = true
    end
    M.bdUpdateWants(b, short, toolMissing)
    return nil
end

-- what one person carries home from a job (into their own inventory first, then hauled to the stockpile)
local function carry(shell, key, n)
    local full = M.bdItems[key]
    if shell == nil or n <= 0 or not M.bdItemOk(full) then return 0 end
    local inv = nil
    pcall(function() inv = shell:getInventory() end)
    return give(inv, full, n)
end
-- the job's result in the world
function M.bdFinish(j, b, shell, c)
    local cfg = M.bdCfg
    local r = M.bdRec(b)
    local got = {}
    local function load(key, n)
        local k = carry(shell, key, n)
        if k < n then M.bdAdd(b, key, n - k, c) end -- no hands to carry with (shouldn't happen): straight to the stockpile
        if k > 0 then got[key] = (got[key] or 0) + k end
    end
    if j.kind == "chop" then
        if not removeObj(j.target.x, j.target.y, "IsoTree") then j.target.gone = true; return false end
        j.target.gone = true
        load("log", cfg.logsPerTree)
        M.bdStats.chopped = M.bdStats.chopped + 1
    elseif j.kind == "wood" then
        local o, sq = nil, sqAt(j.target.x, j.target.y)
        pcall(function()
            local objs = sq:getObjects()
            for k = 0, objs:size() - 1 do
                local x = objs:get(k)
                local nm = nil
                pcall(function() nm = x:getSprite():getName() end)
                if nm == j.target.sprite then o = x; break end
            end
        end)
        if o == nil or not pcall(function() sq:transmitRemoveItemFromSquare(o) end) then j.target.gone = true; return false end
        j.target.gone = true
        load("plank", j.target.planks or 1)
        load("nails", j.target.nails or 1)
        M.bdStats.wood = (M.bdStats.wood or 0) + 1
    elseif j.kind == "door" then
        if not removeObj(j.target.x, j.target.y, "IsoDoor", j.target.north) then j.target.gone = true; return false end
        j.target.gone = true
        load("hinge", cfg.hingesPerDoor)
        load("knob", cfg.knobsPerDoor)
        M.bdStats.doors = M.bdStats.doors + 1
    elseif j.kind == "haul" then
        local inv = nil
        pcall(function() inv = shell:getInventory() end)
        for key, n in pairs(j.carry or {}) do
            local moved = take(inv, M.bdItems[key], n)
            M.bdAdd(b, key, moved, c)
        end
        M.bdStats.hauls = (M.bdStats.hauls or 0) + 1
        return true
    elseif j.kind == "saw" then
        if not M.bdSpend(b, "log", 1, c) then return false end
        M.bdAdd(b, "plank", cfg.planksPerLog, c)
        M.bdStats.sawn = M.bdStats.sawn + 1
        return true
    elseif j.kind == "build" then
        if tableHasAny(M.bdShort(b, j.need, c)) then return false end
        local t = j.target
        local placed = false
        if j.what == "wall" then placed = M.bdPlaceWall(t)
        elseif j.what == "gate" then placed = M.bdPlaceGate(M.bdRing(b) or { gate = {} })
        elseif j.what == "board" then
            local ob = OB()
            if fn(ob, "barricadeWindow") then
                local ok, done = pcall(ob.barricadeWindow, t.objectX or t.x, t.objectY or t.y, 0, cfg.planksPerWindow, nil, t.north)
                placed = ok and done == true
            end
        end
        if not placed then return false end
        for key, n in pairs(j.need) do M.bdSpend(b, key, n, c) end
        if j.what == "wall" then r.walls[t.key] = true; M.bdStats.walls = M.bdStats.walls + 1
        elseif j.what == "gate" then r.gate = true; M.bdStats.gates = M.bdStats.gates + 1
        else M.bdWin[b.id] = nil; M.bdStats.windows = M.bdStats.windows + 1 end
        return true
    else
        return false
    end
    -- gathered: carry it home
    if tableHasAny(got) then
        local d = M.bdDepot(b)
        return true, { kind = "haul", base = b.id, key = "haul:" .. tostring(j.key), carry = got,
            spot = { x = d.x, y = d.y, z = 0 }, ms = 1500, anim = "search_low", run = j.run }
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- A-Life behaviour module: runs for rendered people whose memory says they live in one of our bases
----------------------------------------------------------------------------------------------------------------
function M.bdBaseOf(actor)
    local m = type(actor) == "table" and type(actor.memory) == "table" and actor.memory or nil
    local id = m and m.havenId or nil
    local b = id and M.nbOf(id) or nil
    if b == nil or b.status ~= "active" then return nil end
    return b
end
-- in a party (SP: yours, as before; MP server: anyone's - rows and patch companions count for every party, walking
-- with any online player counts too)
function M.bdInParty(uid)
    if type(M.partyIsMember) ~= "function" then return false end
    if not mpOn() then local ok, yes = pcall(M.partyIsMember, uid, thePlayer()); return ok and yes == true end
    for _, p in ipairs(ALifeSide.online()) do
        local ok, yes = pcall(M.partyIsMember, uid, p)
        if ok and yes == true then return true end
    end
    local ok, yes = pcall(M.partyIsMember, uid, nil)
    return ok and yes == true
end
function M.bdEvaluate(actor, shell, context)
    if not M.bdOn() or shell == nil or type(context) ~= "table" then return nil end
    if context.threat ~= nil then
        if actor and M.bdJobs[actor.uid] then release(actor.uid) end
        return nil
    end
    local b = M.bdBaseOf(actor)
    if b == nil then return nil end
    local uid = tostring(actor.uid)
    if type(M.alHolds) == "function" and M.alHolds(uid) then release(uid); return nil end -- camp alarm
    if M.bdInParty(uid) then release(uid); return nil end
    M.bdStats.evals = M.bdStats.evals + 1
    local now = tonumber(context.now) or nowMs()
    local h, hour = hours(), hourOfDay()
    local c = M.bdContainer(b)
    local j = M.bdJobs[uid]
    if j == nil then
        if (M.bdNextTry and (M.bdNextTry[uid] or 0) > now) then return nil end
        j = M.bdPick(b, uid, shell, h, hour, c)
        if j == nil then
            M.bdNextTry = M.bdNextTry or {}
            M.bdNextTry[uid] = now + 15000
            return nil
        end
        j.started = now
        M.bdJobs[uid] = j
    end
    -- walk there
    local sx, sy = pos(shell)
    if sx == nil then release(uid); return nil end
    if d2(sx, sy, j.spot.x, j.spot.y) > 1.6 ^ 2 then
        j.workFrom = nil
        local allow = M.bdCfg.walkTimeoutMs + 1500 * (tonumber(j.target and j.target.dist) or 0) + (j.kind == "haul" and 120000 or 0)
        if now - j.started > allow then
            M.bdBans[j.key] = now + M.bdCfg.banMs
            M.bdStats.bans = M.bdStats.bans + 1
            release(uid)
            return nil
        end
        if type(context.startMovement) ~= "function" then release(uid); return nil end
        M.bdStats.walks = M.bdStats.walks + 1
        return context.startMovement(actor, shell, j.spot, "chatplus_" .. j.kind, { pace = "walk", timeoutMs = 15000, tolerance = 1.2 })
    end
    -- work
    j.workFrom = j.workFrom or now
    local anim = PA().Animations
    if fn(anim, "apply") then pcall(anim.apply, shell, j.anim) end
    if type(context.setActivity) == "function" then pcall(context.setActivity, actor, "idle", "chatplus_" .. j.kind) end
    if now - j.workFrom >= j.ms then
        local ok, done, nextJob = pcall(M.bdFinish, j, b, shell, c)
        if not ok then log("finish error: " .. tostring(done)) end
        if fn(anim, "clear") then pcall(anim.clear, shell) end
        release(uid)
        if ok and type(nextJob) == "table" then nextJob.started = now; M.bdJobs[uid] = nextJob end
        M.bdStats.claimed = M.bdStats.claimed + 1
        return { kind = "idle", intent = "chatplus_" .. j.kind, cooldownUntilMs = now + 1500 }
    end
    return { kind = "idle", intent = "chatplus_" .. j.kind, cooldownUntilMs = now + 1000 }
end
function M.bdRegister()
    if M._bdRegistered then return true end
    local reg = PA().ModuleRegistry
    if not fn(reg, "register") then return false end
    local ok, done, why = pcall(reg.register, {
        id = "chatplus_build", label = "NPC Overhaul: base building",
        summary = "People in an NPC Overhaul base chop trees, saw planks, salvage doors and fortify the base with real materials.",
        kind = "orders", priority = 93, defaultEnabled = true,
        evaluate = function(actor, shell, context)
            local t0 = nowMs()
            local ok2, res = pcall(M.bdEvaluate, actor, shell, context)
            local dt = nowMs() - t0
            M.bdStats.ms = M.bdStats.ms + dt
            if dt > M.bdStats.maxMs then M.bdStats.maxMs = dt end
            if not ok2 then
                if not M._bdErr then M._bdErr = true; log("module error (logged once): " .. tostring(res)) end
                return nil
            end
            return res
        end,
    })
    if ok and (done == true or (done == false and tostring(why):find("duplicate", 1, true))) then
        -- A-Life only runs a module for an NPC whose behaviour profile lists it: add ours to every profile
        local prof = PA().BehaviorProfiles
        local n = 0
        if type(prof) == "table" and type(prof.definitions) == "table" then
            for _, d in ipairs(prof.definitions) do
                if type(d) == "table" and type(d.overlays) == "table" then d.overlays.chatplus_build = true; n = n + 1 end
            end
        end
        if n == 0 then log("A-Life behaviour profiles not found - the build module may never run") end
        M._bdRegistered = true
        log("registered with A-Life's behaviour modules (priority 93)")
        return true
    end
    log("could not register with A-Life: " .. tostring(why or done))
    return false
end

----------------------------------------------------------------------------------------------------------------
-- unseen days: progress on the ledger; settled for real when you come close (never within 25 tiles)
----------------------------------------------------------------------------------------------------------------
function M.bdCrew(b)
    local n = tonumber(b.crewN) or 0
    if M.sbCrewOf and b.seeded then local ok, crew = pcall(M.sbCrewOf, b); if ok and type(crew) == "table" and #crew > 0 then n = #crew end end
    return n
end
local function roll(seed) return (hash(seed) % 10000) / 10000 end
function M.bdDay(b, dayIndex)
    local cfg = M.bdCfg
    local r = M.bdRec(b)
    local crew = math.min(cfg.dayMaxWorkers, M.bdCrew(b))
    if crew <= 0 then return end
    -- tools they don't have might turn up while scavenging
    for _, k in ipairs({ "axe", "saw", "screwdriver", "hammer" }) do
        if r.tools[k] == false and roll(b.id .. "#" .. k .. "#" .. dayIndex) < cfg.toolFindChance then
            r.tools[k] = true
            M.bdStats.toolsFound = M.bdStats.toolsFound + 1
            log(tostring(b.name) .. " found " .. M.bdWantWords[k])
        end
    end
    -- only what a scan really saw standing can be used (nothing from nowhere); never seen = nothing unseen
    local k = type(r.known) == "table" and r.known or nil
    if k == nil then return end
    local proj = M.bdProject(b, hours(), nil)
    local need = proj and proj.need or {}
    -- build first with what's on the ledger (walls only unseen; windows / gate need the house loaded)
    local walls = 0
    while walls < cfg.dayWalls do
        local p = M.bdNextWall(b)
        if p == nil then break end
        local logs = p.corner and 1 or cfg.logsPerWall
        if (tonumber(r.pend.log) or 0) < logs then break end
        r.pend.log = r.pend.log - logs
        r.walls[p.key] = "owed"
        r.owe.walls = r.owe.walls + 1
        walls = walls + 1
    end
    -- trips per worker: near ground is quick, far runs are one trip a day
    local function trips(dist)
        dist = tonumber(dist) or 0
        if dist <= cfg.runTiles then return cfg.tripsNear elseif dist <= 100 then return cfg.tripsAt100 end
        return cfg.tripsFar
    end
    -- logs: trees that are really there, carried home a couple at a time
    local wantWood = (need.log or need.plank) and true or false
    if wantWood and r.tools.axe ~= false and k.trees > 0 then
        local trees = math.min(k.trees, crew * trips(k.treeDist))
        trees = math.min(trees, math.floor((cfg.pendCap - (tonumber(r.pend.log) or 0)) / cfg.logsPerTree))
        if trees > 0 then
            r.pend.log = (tonumber(r.pend.log) or 0) + trees * cfg.logsPerTree
            r.owe.trees = r.owe.trees + trees
            k.trees = k.trees - trees
        end
    end
    -- planks + nails from wooden furniture / fences that are really there
    if (need.plank or need.nails) and (r.tools.hammer ~= false or r.tools.saw ~= false) and k.wood > 0 then
        local n = math.min(k.wood, crew * trips(k.woodDist))
        if n > 0 then
            r.pend.plank = (tonumber(r.pend.plank) or 0) + n
            r.pend.nails = (tonumber(r.pend.nails) or 0) + n
            r.owe.wood = (tonumber(r.owe.wood) or 0) + n
            k.wood = k.wood - n
        end
    end
    -- planks from logs
    if need.plank and r.tools.saw ~= false and (tonumber(r.pend.log) or 0) > 0 then
        local logs = math.min(math.ceil(cfg.dayPlanks / cfg.planksPerLog), tonumber(r.pend.log) or 0)
        r.pend.log = r.pend.log - logs
        r.pend.plank = (tonumber(r.pend.plank) or 0) + logs * cfg.planksPerLog
    end
    -- hinges / knob from doors that are really there
    if (need.hinge or need.knob) and r.tools.screwdriver ~= false and k.doors > 0 then
        local n = math.min(k.doors, cfg.dayDoors)
        r.pend.hinge = (tonumber(r.pend.hinge) or 0) + cfg.hingesPerDoor * n
        r.pend.knob = (tonumber(r.pend.knob) or 0) + cfg.knobsPerDoor * n
        r.owe.doors = r.owe.doors + n
        k.doors = k.doors - n
    end
    M.bdStats.days = M.bdStats.days + 1
end
-- settle what happened while you were away: the very trees / doors / furniture counted are removed, walls go up,
-- items go in the stockpile. Something counted that is gone now (you took it) is taken back off the ledger.
function M.bdSettle(b, px, py)
    local r = M.bdRec(b)
    local c = M.bdContainer(b)
    local s = scanState(b)
    if not s.done then return false end
    local changed = 0
    local safe = M.bdCfg.playerSafeTiles ^ 2
    local function farFromYou(x, y)
        if mpOn() and playerNear(x, y, M.bdCfg.playerSafeTiles + 0.001) then return false end -- MP: far from EVERY player
        return px == nil or d2(x, y, px, py) > safe
    end
    local function settle(list, oweKey, remove, undo)
        for _, t in ipairs(list) do
            if (tonumber(r.owe[oweKey]) or 0) <= 0 then break end
            if t.owed and not t.gone and farFromYou(t.x, t.y) then
                if remove(t) then t.gone = true; changed = changed + 1 else t.gone = true; undo() end
                t.owed = nil
                r.owe[oweKey] = r.owe[oweKey] - 1
            end
        end
    end
    local cfg = M.bdCfg
    local function unpend(key, n) r.pend[key] = math.max(0, (tonumber(r.pend[key]) or 0) - n) end
    settle(s.trees, "trees", function(t) return removeObj(t.x, t.y, "IsoTree") end, function() unpend("log", cfg.logsPerTree) end)
    settle(s.doors, "doors", function(d) return M.bdDoorOk(d, px, py) and removeObj(d.x, d.y, "IsoDoor", d.north) end,
        function() unpend("hinge", cfg.hingesPerDoor); unpend("knob", cfg.knobsPerDoor) end)
    settle(s.wood, "wood", function(w)
        local done = false
        local sq = sqAt(w.x, w.y)
        pcall(function()
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local nm = nil
                pcall(function() nm = o:getSprite():getName() end)
                if nm == w.sprite then sq:transmitRemoveItemFromSquare(o); done = true; break end
            end
        end)
        return done
    end, function() unpend("plank", 1); unpend("nails", 1) end)
    if c ~= nil then changed = changed + M.bdFlush(b, c) end
    local ring = M.bdRing(b)
    if ring and r.owe.walls > 0 then
        for _, p in ipairs(ring.walls) do
            if r.walls[p.key] == "owed" and farFromYou(p.x, p.y) then
                if M.bdPlaceWall(p) then r.walls[p.key] = true; r.owe.walls = math.max(0, r.owe.walls - 1); changed = changed + 1 end
            end
        end
    end
    if changed > 0 then
        M.bdStats.settled = M.bdStats.settled + 1
        log("settled " .. tostring(b.name) .. ": " .. changed .. " changes from unseen work")
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- tick (rides on the seeded-base tick, already 1 s gated): days for every base, scans + settling near you
----------------------------------------------------------------------------------------------------------------
M.bdLastT = { tick = -1e12 }
function M.bdTick(now)
    if not M.bdOn() then return end
    if now - M.bdLastT.tick < M.bdCfg.tickMs then return end
    M.bdLastT.tick = now
    if not M._bdRegistered then pcall(M.bdRegister) end
    local h = hours()
    local px, py = pos(thePlayer())
    for _, b in ipairs(M.nbActive()) do
        local r = M.bdRec(b)
        if mpOn() then px, py = pos(ALifeSide.nearest(b.x, b.y)) end -- MP: the online player nearest this base is "you"
        local near = px ~= nil and d2(b.x, b.y, px, py) <= M.bdCfg.loadedTiles ^ 2
        if near then
            M.bdScanStep(b, h)
            -- tools: what the stockpile holds now (people's hands are checked per job)
            local c = M.bdContainer(b)
            if c ~= nil then
                for k, list in pairs(M.bdTools) do if hasAny(c, list) then r.tools[k] = true end end
            end
            pcall(M.bdSettle, b, px, py)
            r.dayH = h -- seen days are real work, not ledger
        else
            local steps = 0
            while h - r.dayH >= 24 and steps < 30 do
                r.dayH = r.dayH + 24
                M.bdDay(b, math.floor(r.dayH / 24))
                steps = steps + 1
            end
            if steps >= 30 then r.dayH = h end
        end
    end
end
-- tools never seen at a base start as "unknown"; once a base was seen without one it's "false" until found
function M.bdNoteMissingTools(b, toolMissing)
    local r = M.bdRec(b)
    for k in pairs(toolMissing) do if r.tools[k] ~= true then r.tools[k] = false end end
end
do -- keep the missing-tool notes from bdPick
    local orig = M.bdUpdateWants
    M.bdUpdateWants = function(b, shortList, toolMissing)
        orig(b, shortList, toolMissing)
        M.bdNoteMissingTools(b, toolMissing)
    end
end

----------------------------------------------------------------------------------------------------------------
-- the want list in conversation: they may mention what the base is short of
----------------------------------------------------------------------------------------------------------------
function M.bdExtra(req, player, listener)
    if not M.bdOn() or type(listener) ~= "table" then return end
    local b = M.bdBaseOf(listener.record)
    if b == nil then return end
    local r = M.bdRec(b)
    if #r.want == 0 then return end
    local words = {}
    for _, k in ipairs(r.want) do words[#words + 1] = M.bdWantWords[k] or k end
    req.psyche = type(req.psyche) == "table" and req.psyche or {}
    local need = "Your group is fortifying its place and is short of " .. table.concat(words, ", ") .. "; you might ask for it or trade for it if it fits."
    req.psyche.mood = req.psyche.mood and (tostring(req.psyche.mood) .. ". " .. need) or need
end

function M.bdPerf()
    local s = M.bdStats
    return "chopped " .. s.chopped .. ", sawn " .. s.sawn .. ", doors " .. s.doors .. ", walls " .. s.walls .. ", windows " .. s.windows
        .. ", gates " .. s.gates .. ", walks " .. s.walks .. ", bans " .. s.bans .. ", settled " .. s.settled .. ", unseen days " .. s.days
        .. ", tools found " .. s.toolsFound .. ", module ms " .. math.floor(s.ms) .. " (max " .. math.floor(s.maxMs) .. ")"
end

function M.bdInstall()
    if not (M._bdTickW and M.sbTick == M._bdTickW) then
        local orig = M.sbTick
        if type(orig) == "function" then
            M._bdTickW = function(now)
                orig(now)
                local ok, e = pcall(M.bdTick, now)
                if not ok and not M._bdTickErr then M._bdTickErr = true; log("tick error (logged once): " .. tostring(e)) end
            end
            M.sbTick = M._bdTickW
        end
    end
    -- seeded bases no longer get free boards on approach: windows are boarded with planks they made
    if M.bdOn() and type(M.sbCfg) == "table" then M.sbCfg.boardCamp, M.sbCfg.boardFort = 0, 0 end
end
pcall(M.bdInstall)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(M.bdInstall)
        local ok = pcall(M.bdRegister)
        if not M._bdExtraOn and type(M.requestExtras) == "table" then
            table.insert(M.requestExtras, function(req, player, listener, now) pcall(M.bdExtra, req, player, listener) end)
            M._bdExtraOn = true
        end
        print("[ALifeNPCOverhaul] build loaded v" .. ALifeSide.MOD_VERSION .. " (" .. (M.bdOn() and "on" or "off") .. ", A-Life module " .. (M._bdRegistered and "registered" or "not yet") .. ")")
    end)
end
return M
