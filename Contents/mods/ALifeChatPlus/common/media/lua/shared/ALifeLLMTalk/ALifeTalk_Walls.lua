-- A-Life NPC Overhaul pre-1.0: ORGANIC WALLS. NPC bases fortify the way real people would (docs/PLAN-BUILD.md).
--  * once a base is loaded they look at the real ground: a flood-fill from the yard (walls, fences, gates and windows
--    are barriers; rooms and water are solid). Already closed in: nothing to build. Closed in but for a few openings
--    (a fenced compound with one way in): they wall the openings. Open ground: Build's palisade box round the house.
--  * a gate only if the yard has no way out already (a gate in the fence, a building in the fence line): one wicket
--    in the opening nearest the road
--  * late game: more rings, further out, as the days go by (wallLayers, wallLayerDays)
--  * far, never-loaded bases: the wood and doors they can count on are guessed from the map (forest zones, buildings
--    near them) until the first real look; walls and the gate are settled out of sight on load
-- Rides on ALifeTalk_Build (wraps bdRing, bdPlaceWall, bdSettle, bdDay, bdScanStep). Real materials only.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Walls") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Build"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.bdRing) ~= "function" then return end
ALifeWalls = ALifeWalls or {}
local W = ALifeWalls
local TAG = "[ALifeWalls]"
W.VERSION = ALifeSide.MOD_VERSION
W.DEFAULTS = { orgWalls = true, orgScanTiles = 45, orgMaxGap = 8, orgMaxGapTotal = 48, wallLayers = 2, wallLayerDays = 30,
    wallLayerGap = 3, wallMaxRing = 140, orgGuess = true, orgTreesPer100 = 3 }
-- engine budgets (not gameplay): squares read per tick, hours between looks, ticks to wait before settling anyway
W.cfg = { readPerTick = 600, rescanH = 24, retryH = 1, giveUpTicks = 120, pruneMax = 80, guessMinStep = 8,
    gateN = "fixtures_doors_fences_01_13", gateW = "fixtures_doors_fences_01_12",
    forest = { Forest = true, DeepForest = true, PHForest = true, BirchForest = true, PRForest = true, OrganicForest = true } }
W.stats = { looks = 0, closed = 0, gaps = 0, open = 0, partial = 0, pieces = 0, skipped = 0, refunded = 0, gates = 0, layers = 0, guesses = 0 }
-- new setting keys go in fileKeys at load (CLAUDE.md rule 2)
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(W.DEFAULTS) do
            if M.settings[k] == nil then M.settings[k] = v end
            if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end
local function setting(k)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[k] end
    if v == nil then v = W.DEFAULTS[k] end
    return v
end
local function num(k) return tonumber(setting(k)) or W.DEFAULTS[k] end
local function log(msg) if M.log then M.log("walls: " .. tostring(msg)) else print(TAG .. " " .. tostring(msg)) end end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
function W.on() return setting("orgWalls") ~= false and fn(M, "bdOn") and M.bdOn() end

----------------------------------------------------------------------------------------------------------------
-- reading a square: bits (Kahlua has no bit ops: powers of two, tested with has())
----------------------------------------------------------------------------------------------------------------
local B_N, B_W, B_SOLID, B_UNL, B_DN, B_DW, B_ROOM = 1, 2, 4, 8, 16, 32, 64
W.BITS = { N = B_N, W = B_W, SOLID = B_SOLID, UNL = B_UNL, DN = B_DN, DW = B_DW, ROOM = B_ROOM }
local function has(code, bit) return math.floor((tonumber(code) or 0) / bit) % 2 == 1 end
W.has = has
-- tile flags (newtiledefinitions): what closes the north / west edge of a square
local EDGE_N = { "WallN", "WallNW", "TallHoppableN", "HoppableN", "collideN", "DoorWallN", "WindowN", "windowN", "doorN" }
local EDGE_W = { "WallW", "WallNW", "TallHoppableW", "HoppableW", "collideW", "DoorWallW", "WindowW", "windowW", "doorW" }
-- A-Life OutpostBuilder.flag: the IsoFlagType enum first, then the property by name
local function flagOn(props, name)
    if props == nil then return false end
    local ok, v = pcall(function() local f = IsoFlagType ~= nil and IsoFlagType[name] or nil; return f ~= nil and props:has(f) == true end)
    if ok and v == true then return true end
    ok, v = pcall(function() return props:has(name) == true end)
    return ok and v == true
end
local function anyFlag(props, list) for _, f in ipairs(list) do if flagOn(props, f) then return true end end; return false end
function W.readSquare(x, y)
    local sq = nil
    pcall(function() sq = getCell():getGridSquare(x, y, 0) end)
    if sq == nil then return B_UNL end
    local room, water = false, false
    pcall(function() room = sq:getRoom() ~= nil end) -- unverified 42.21 (vanilla Lua uses it everywhere); pcall'd
    pcall(function() local p = sq:getProperties(); water = p ~= nil and IsoFlagType ~= nil and p:has(IsoFlagType.water) == true end)
    local n, w, dn, dw = false, false, false, false
    local function scan(props)
        if props == nil then return end
        if not n and anyFlag(props, EDGE_N) then n = true end
        if not w and anyFlag(props, EDGE_W) then w = true end
        if not dn and flagOn(props, "doorN") then dn = true end
        if not dw and flagOn(props, "doorW") then dw = true end
    end
    pcall(function() scan(sq:getProperties()) end)
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            pcall(function() scan(o:getSprite():getProperties()) end)
        end
    end)
    local code = 0
    if n then code = code + B_N end
    if w then code = code + B_W end
    if room or water then code = code + B_SOLID end
    if dn then code = code + B_DN end
    if dw then code = code + B_DW end
    if room then code = code + B_ROOM end
    return code
end

----------------------------------------------------------------------------------------------------------------
-- the ground as a grid g = { rx1, ry1, rx2, ry2, wd, map } (map[idx] = bits); pure from here (harness-testable)
----------------------------------------------------------------------------------------------------------------
local function idx(g, x, y)
    if x < g.rx1 or x > g.rx2 or y < g.ry1 or y > g.ry2 then return nil end
    return (y - g.ry1) * g.wd + (x - g.rx1) + 1
end
local function code(g, x, y) local i = idx(g, x, y); if i == nil then return B_SOLID end; return g.map[i] or B_UNL end
local function passable(c) return not has(c, B_SOLID) and not has(c, B_UNL) end
W.code = code
local function edgeKey(dir, x, y) return dir .. ":" .. x .. ":" .. y end
local function closedSet(list)
    local s = {}
    for _, c in ipairs(list) do
        for v = c.a, c.b do
            if c.dir == "N" then s[edgeKey("N", v, c.at)] = true else s[edgeKey("W", c.at, v)] = true end
        end
    end
    return s
end
-- flood-fill from the seeds; stops at the first square on the region's rim (escaped) or an unloaded one
function W.bfs(g, seeds, closed)
    closed = closed or {}
    local inR, q, qh = {}, {}, 1
    for _, s in ipairs(seeds) do
        local i = idx(g, s.x, s.y)
        if i and not inR[i] and passable(g.map[i] or B_UNL) then inR[i] = true; q[#q + 1] = s.x; q[#q + 1] = s.y end
    end
    while qh <= #q do
        local x, y = q[qh], q[qh + 1]
        qh = qh + 2
        if x <= g.rx1 or x >= g.rx2 or y <= g.ry1 or y >= g.ry2 then return { inR = inR, escaped = true } end
        local c = code(g, x, y)
        -- up / down / left / right: the edge between, then the square
        local moves = {
            { x, y - 1, has(c, B_N) or closed[edgeKey("N", x, y)] },
            { x, y + 1, has(code(g, x, y + 1), B_N) or closed[edgeKey("N", x, y + 1)] },
            { x - 1, y, has(c, B_W) or closed[edgeKey("W", x, y)] },
            { x + 1, y, has(code(g, x + 1, y), B_W) or closed[edgeKey("W", x + 1, y)] },
        }
        for _, mv in ipairs(moves) do
            if not mv[3] then
                local nx, ny = mv[1], mv[2]
                local i = idx(g, nx, ny)
                if i and not inR[i] then
                    local nc = g.map[i] or B_UNL
                    if has(nc, B_UNL) then return { inR = inR, unl = true } end
                    if not has(nc, B_SOLID) then inR[i] = true; q[#q + 1] = nx; q[#q + 1] = ny end
                end
            end
        end
    end
    return { inR = inR, escaped = false }
end
-- something ends a run at the vertex (vx, vy) (top-left corner of square vx, vy): an edge or a solid square
local function anchored(g, vx, vy)
    if has(code(g, vx - 1, vy), B_N) or has(code(g, vx, vy), B_N) then return true end
    if has(code(g, vx, vy), B_W) or has(code(g, vx, vy - 1), B_W) then return true end
    for _, s in ipairs({ { vx - 1, vy - 1 }, { vx, vy - 1 }, { vx - 1, vy }, { vx, vy } }) do
        local c = code(g, s[1], s[2])
        if has(c, B_SOLID) and not has(c, B_UNL) and idx(g, s[1], s[2]) then return true end
    end
    return false
end
-- straight openings no wider than maxGap with something at both ends: the places a wall could close
function W.candidates(g, maxGap)
    local out = {}
    local function openN(x, y) return not has(code(g, x, y), B_N) and passable(code(g, x, y)) and passable(code(g, x, y - 1)) end
    local function openW(x, y) return not has(code(g, x, y), B_W) and passable(code(g, x, y)) and passable(code(g, x - 1, y)) end
    for y = g.ry1 + 1, g.ry2 do
        local x = g.rx1 + 1
        while x <= g.rx2 - 1 do
            if openN(x, y) then
                local xa = x
                while x <= g.rx2 - 1 and openN(x, y) do x = x + 1 end
                local xb = x - 1
                if xb - xa + 1 <= maxGap and anchored(g, xa, y) and anchored(g, xb + 1, y) then out[#out + 1] = { dir = "N", a = xa, b = xb, at = y } end
            else x = x + 1 end
        end
    end
    for x = g.rx1 + 1, g.rx2 do
        local y = g.ry1 + 1
        while y <= g.ry2 - 1 do
            if openW(x, y) then
                local ya = y
                while y <= g.ry2 - 1 and openW(x, y) do y = y + 1 end
                local yb = y - 1
                if yb - ya + 1 <= maxGap and anchored(g, x, ya) and anchored(g, x, yb + 1) then out[#out + 1] = { dir = "W", a = ya, b = yb, at = x } end
            else y = y + 1 end
        end
    end
    return out
end
-- does the opening separate the region from the outside (one side in, one out)?
local function crosses(g, c, inR)
    for v = c.a, c.b do
        local i1, i2
        if c.dir == "N" then i1, i2 = idx(g, v, c.at), idx(g, v, c.at - 1) else i1, i2 = idx(g, c.at, v), idx(g, c.at - 1, v) end
        if (i1 and inR[i1] or false) ~= (i2 and inR[i2] or false) then return true end
    end
    return false
end
local function mid(c) if c.dir == "N" then return (c.a + c.b) / 2, c.at end; return c.at, (c.a + c.b) / 2 end
local function tiles(list) local n = 0; for _, c in ipairs(list) do n = n + (c.b - c.a + 1) end; return n end
-- a way out already: a door / gate in the region's rim, or a building that touches the yard and the outside
function W.hasExit(g, inR)
    local roomSeeds = {}
    for i in pairs(inR) do
        local x, y = g.rx1 + (i - 1) % g.wd, g.ry1 + math.floor((i - 1) / g.wd)
        local c = code(g, x, y)
        local nbrs = {
            { x, y - 1, has(c, B_DN) }, { x, y + 1, has(code(g, x, y + 1), B_DN) },
            { x - 1, y, has(c, B_DW) }, { x + 1, y, has(code(g, x + 1, y), B_DW) },
        }
        for _, nb in ipairs(nbrs) do
            local j = idx(g, nb[1], nb[2])
            if j and not inR[j] then
                local nc = code(g, nb[1], nb[2])
                if nb[3] and passable(nc) then return true end
                if has(nc, B_ROOM) then roomSeeds[#roomSeeds + 1] = { nb[1], nb[2] } end
            end
        end
    end
    -- through a building: rooms touching the yard that also touch open ground outside it
    local seen, q, qh = {}, {}, 1
    for _, s in ipairs(roomSeeds) do local j = idx(g, s[1], s[2]); if not seen[j] then seen[j] = true; q[#q + 1] = s end end
    while qh <= #q do
        local x, y = q[qh][1], q[qh][2]
        qh = qh + 1
        for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
            local nx, ny = x + d[1], y + d[2]
            local j = idx(g, nx, ny)
            if j and not seen[j] then
                local nc = code(g, nx, ny)
                if has(nc, B_ROOM) then seen[j] = true; q[#q + 1] = { nx, ny }
                elseif passable(nc) and not inR[j] then return true end
            end
        end
    end
    return false
end

-- one step of the look (one flood-fill); s = analysis state; returns a result table when done
function W.analyseStep(s)
    local g = s.g
    s.steps = (s.steps or 0) + 1
    if s.phase == nil then
        local r0 = W.bfs(g, s.seeds, {})
        if r0.unl then return { mode = "partial" } end
        if not r0.escaped then return { mode = "closed", inR = r0.inR, gaps = {} } end
        s.cands = W.candidates(g, s.maxGap)
        s.closed = {}
        for _, c in ipairs(s.cands) do s.closed[#s.closed + 1] = c end
        s.phase = "all"
        return nil
    elseif s.phase == "all" then
        local r = W.bfs(g, s.seeds, closedSet(s.closed))
        if r.unl then return { mode = "partial" } end
        if r.escaped then return { mode = "open" } end
        s.inR, s.tested, s.phase = r.inR, {}, "prune"
        return nil
    elseif s.phase == "prune" then
        -- the innermost untried opening on the rim: if the yard stays closed without it, it was an inner cut
        local best, bd = nil, 1e18
        for k, c in ipairs(s.closed) do
            if not s.tested[c] and crosses(g, c, s.inR) then
                local mx, my = mid(c)
                local dd = d2(mx, my, s.cx, s.cy)
                if dd < bd then best, bd = k, dd end
            end
        end
        if best == nil or s.steps > W.cfg.pruneMax then
            local gaps = {}
            for _, c in ipairs(s.closed) do if crosses(g, c, s.inR) then gaps[#gaps + 1] = c end end
            if tiles(gaps) > s.maxTotal then return { mode = "open", why = "too many openings" } end
            return { mode = "gaps", inR = s.inR, gaps = gaps }
        end
        local c = s.closed[best]
        s.tested[c] = true
        local trial = {}
        for k, x in ipairs(s.closed) do if k ~= best then trial[#trial + 1] = x end end
        local r = W.bfs(g, s.seeds, closedSet(trial))
        if not r.escaped and not r.unl then s.closed, s.inR = trial, r.inR end
        return nil
    end
    return { mode = "partial" }
end

-- result -> wall pieces (+ a gate when the yard has no way out); pieces walk the opening nearest the road first
function W.pieces(g, res, roadSide, baseId)
    local fam = { n = "walls_logs_1", w = "walls_logs_0" }
    local arch = type(ProjectALife) == "table" and ProjectALife.OutpostArchitect or nil
    if type(arch) == "table" and type(arch.family) == "table" and type(arch.family.palisade) == "table" then fam = arch.family.palisade end
    local gaps = {}
    for _, c in ipairs(res.gaps or {}) do gaps[#gaps + 1] = c end
    local roadY = (roadSide == "N") and g.ry1 or g.ry2
    table.sort(gaps, function(a, b)
        local _, ay = mid(a)
        local _, by = mid(b)
        local da, db = math.abs(ay - roadY), math.abs(by - roadY)
        if da ~= db then return da < db end
        if a.dir ~= b.dir then return a.dir < b.dir end
        if a.at ~= b.at then return a.at < b.at end
        return a.a < b.a
    end)
    local gate = nil
    if #gaps > 0 and not W.hasExit(g, res.inR) then
        -- the gate: the north-facing opening nearest the road (gates read best across a road), else the nearest
        local pick = nil
        for _, c in ipairs(gaps) do if c.dir == "N" then pick = c; break end end
        pick = pick or gaps[1]
        local v = math.floor((pick.a + pick.b) / 2)
        if pick.dir == "N" then gate = { x = v, y = pick.at, z = 0, sprite = W.cfg.gateN, north = true, key = edgeKey("gN", v, pick.at) }
        else gate = { x = pick.at, y = v, z = 0, sprite = W.cfg.gateW, north = false, key = edgeKey("gW", pick.at, v) } end
    end
    local function inside(dir, x, y)
        local i = idx(g, x, y)
        if i and res.inR[i] then return { x = x, y = y } end
        if dir == "N" then return { x = x, y = y - 1 } end
        return { x = x - 1, y = y }
    end
    local walls = {}
    for _, c in ipairs(gaps) do
        for v = c.a, c.b do
            local x, y = v, c.at
            if c.dir == "W" then x, y = c.at, v end
            local isGate = gate ~= nil and gate.x == x and gate.y == y and (gate.north == (c.dir == "N"))
            if not isGate then
                walls[#walls + 1] = { x = x, y = y, z = 0, sprite = (c.dir == "N") and fam.n or fam.w, north = c.dir == "N",
                    key = "ow:" .. edgeKey(c.dir, x, y), inside = inside(c.dir, x, y), base = baseId }
            end
        end
    end
    if gate then gate.inside = inside(gate.north and "N" or "W", gate.x, gate.y) end
    -- what they hold: the region's extents (later rings go round it)
    local bb = nil
    for i in pairs(res.inR or {}) do
        local x, y = g.rx1 + (i - 1) % g.wd, g.ry1 + math.floor((i - 1) / g.wd)
        if bb == nil then bb = { x1 = x, y1 = y, x2 = x, y2 = y }
        else
            if x < bb.x1 then bb.x1 = x end
            if x > bb.x2 then bb.x2 = x end
            if y < bb.y1 then bb.y1 = y end
            if y > bb.y2 then bb.y2 = y end
        end
    end
    return walls, gate, bb
end

----------------------------------------------------------------------------------------------------------------
-- the look at a loaded base: read the ground a slice per tick, then one flood-fill per tick
----------------------------------------------------------------------------------------------------------------
W.scans = {}
W.rings = {}
local function boundsOf(b)
    if type(b.bounds) == "table" and tonumber(b.bounds.x1) then return b.bounds end
    if tonumber(b.x) then local x, y = math.floor(b.x), math.floor(b.y); return { x1 = x - 3, y1 = y - 3, x2 = x + 3, y2 = y + 3 } end
    return nil
end
function W.newScan(b)
    local bb = boundsOf(b)
    if bb == nil then return nil end
    local T = math.max(10, math.floor(num("orgScanTiles")))
    local g = { rx1 = bb.x1 - T, ry1 = bb.y1 - T, rx2 = bb.x2 + T, ry2 = bb.y2 + T, map = {} }
    g.wd = g.rx2 - g.rx1 + 1
    g.ht = g.ry2 - g.ry1 + 1
    return { g = g, bb = bb, i = 0, total = g.wd * g.ht, ticks = 0, cx = (bb.x1 + bb.x2) / 2, cy = (bb.y1 + bb.y2) / 2,
        maxGap = math.max(1, math.floor(num("orgMaxGap"))), maxTotal = math.max(1, math.floor(num("orgMaxGapTotal"))) }
end
-- the yard next to the house: open squares in the base bounds and one ring round them
local function seedsOf(s)
    local out = {}
    for x = s.bb.x1 - 1, s.bb.x2 + 1 do
        for y = s.bb.y1 - 1, s.bb.y2 + 1 do
            if passable(code(s.g, x, y)) then out[#out + 1] = { x = x, y = y } end
        end
    end
    return out
end
function W.scanTick(b, s, read)
    read = read or W.readSquare
    s.ticks = s.ticks + 1
    local g = s.g
    if s.i < s.total then
        local n = 0
        while s.i < s.total and n < W.cfg.readPerTick do
            local x, y = g.rx1 + s.i % g.wd, g.ry1 + math.floor(s.i / g.wd)
            s.i = s.i + 1
            g.map[s.i] = read(x, y)
            n = n + 1
        end
        if s.i < s.total then return nil end
        s.seeds = seedsOf(s)
        if #s.seeds == 0 then return { mode = "open", why = "no yard" } end
        return nil
    end
    return W.analyseStep(s)
end

-- keep the plan; owed pieces of the old plan that the new one doesn't use go back on the ledger as logs
local function pieceCost(p) return (p.corner and 1) or (tonumber(M.bdCfg and M.bdCfg.logsPerWall) or 4) end
function W.refundOwed(b, keep)
    local r = M.bdRec(b)
    local old = M._owRingRaw and M._owRingRaw(b) or nil
    local n = 0
    for _, p in ipairs(type(old) == "table" and old.walls or {}) do
        if r.walls[p.key] == "owed" and not (keep and keep[p.key]) then
            r.walls[p.key] = nil
            r.owe.walls = math.max(0, (tonumber(r.owe.walls) or 0) - 1)
            r.pend.log = (tonumber(r.pend.log) or 0) + pieceCost(p)
            n = n + 1
        end
    end
    if n > 0 then W.stats.refunded = W.stats.refunded + n end
    return n
end
local function boxStarted(b)
    local r = M.bdRec(b)
    local raw = W.origRing and W.origRing(b) or nil
    for _, p in ipairs(type(raw) == "table" and raw.walls or {}) do if r.walls[p.key] == true then return true end end
    return false
end
function W.apply(b, s, res, h)
    local r = M.bdRec(b)
    W.stats.looks = W.stats.looks + 1
    if res.mode == "partial" then
        W.stats.partial = W.stats.partial + 1
        if r.ow == nil and s.ticks >= W.cfg.giveUpTicks then r.ow = { mode = "unknown", h = h } end
        if type(r.ow) == "table" then r.ow.retryH = h end
        return
    end
    local mode = res.mode
    local walls, gate, bb = {}, nil, nil
    local layer = math.max(1, tonumber(r.layer) or 1)
    local cur = type(r.ow) == "table" and r.ow.mode or nil
    if mode == "gaps" or mode == "closed" then
        walls, gate, bb = W.pieces(s.g, res, b.roadSide, b.id)
        if layer == 1 and cur ~= "gaps" and cur ~= "closed" and boxStarted(b) then
            mode = "box" -- a palisade box with real pieces up stays a box (no switching halfway)
        end
    end
    if layer == 1 and (cur == "gaps" or mode == "gaps" or mode == "closed") then
        -- the layer-1 plan changes: owed pieces it no longer has go back on the ledger as logs
        local keep = {}
        if mode == "gaps" then for _, p in ipairs(walls) do keep[p.key] = true end end
        W.refundOwed(b, keep)
    end
    if layer >= 2 and type(r.ow) == "table" and type(r.ow.bbox) == "table" then bb = r.ow.bbox end -- outer rings keep their line
    r.ow = { mode = mode, h = h, walls = (mode == "gaps") and walls or {}, gate = (mode == "gaps") and gate or nil, bbox = bb,
        tiles = #walls, why = res.why }
    W.stats[mode] = (W.stats[mode] or 0) + 1
    W.rings[b.id] = nil
    if type(M.bdRings) == "table" then M.bdRings[b.id] = nil end
    log(tostring(b.name or b.id) .. ": " .. mode .. (mode == "gaps" and (" - " .. #walls .. " wall pieces" .. (gate and " and a gate" or "")) or "")
        .. (res.why and (" (" .. res.why .. ")") or ""))
end
function W.step(b, h)
    if not W.on() or type(b) ~= "table" or b.id == nil then return end
    local r = M.bdRec(b)
    local ow = type(r.ow) == "table" and r.ow or nil
    local s = W.scans[b.id]
    if s == nil then
        if ow and ow.mode ~= "unknown" and h - (tonumber(ow.h) or -1e9) < W.cfg.rescanH and ow.retryH == nil then return end
        if ow and ow.retryH and h - ow.retryH < W.cfg.retryH then return end
        s = W.newScan(b)
        if s == nil then return end
        W.scans[b.id] = s
    end
    local ok, res = pcall(W.scanTick, b, s)
    if not ok then log("look failed at " .. tostring(b.name or b.id) .. ": " .. tostring(res)); W.scans[b.id] = nil; r.ow = r.ow or { mode = "unknown", h = h }; return end
    if res ~= nil then
        W.scans[b.id] = nil
        W.apply(b, s, res, h)
    end
end
-- settle only after the first look (so a fenced compound gets its openings walled, not a box)
function W.waiting(b)
    local r = M.bdRec(b)
    if r.ow ~= nil then return false end
    local s = W.scans[b.id]
    if s == nil then return boundsOf(b) ~= nil end
    if s.ticks >= W.cfg.giveUpTicks then r.ow = { mode = "unknown", h = hours() }; return false end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- never-seen bases: what they can count on, from the map (forest zones, buildings near them)
----------------------------------------------------------------------------------------------------------------
function W.zoneTypes(x, y)
    local list = {}
    pcall(function()
        local zones = getWorld():getMetaGrid():getZonesAt(math.floor(x), math.floor(y), 0)
        for i = 0, zones:size() - 1 do local z = zones:get(i); if z ~= nil then list[#list + 1] = tostring(z:getType()) end end
    end)
    return list
end
function W.buildingKey(x, y)
    local key = nil
    pcall(function()
        local def = getWorld():getMetaGrid():getBuildingAt(math.floor(x), math.floor(y))
        if def ~= nil then key = def:getX() .. ":" .. def:getY() end
    end)
    return key
end
function W.guess(b, R)
    local bb = boundsOf(b)
    local step = math.max(W.cfg.guessMinStep, math.floor(R / 6))
    local cx, cy = math.floor(b.x), math.floor(b.y)
    local forestN, fDist, bld, bDist, nB = 0, 0, {}, 0, 0
    local own = bb and W.buildingKey((bb.x1 + bb.x2) / 2, (bb.y1 + bb.y2) / 2) or nil
    for x = cx - R, cx + R, step do
        for y = cy - R, cy + R, step do
            local dd = d2(x, y, cx, cy)
            if dd <= R * R and not (bb and x >= bb.x1 - 4 and x <= bb.x2 + 4 and y >= bb.y1 - 4 and y <= bb.y2 + 4) then
                for _, t in ipairs(W.zoneTypes(x, y)) do
                    if W.cfg.forest[t] then forestN = forestN + 1; fDist = fDist + math.sqrt(dd); break end
                end
                local k = W.buildingKey(x, y)
                if k and k ~= own and not bld[k] then bld[k] = true; nB = nB + 1; bDist = bDist + math.sqrt(dd) end
            end
        end
    end
    local trees = math.floor(forestN * step * step / 100 * num("orgTreesPer100"))
    return { trees = trees, treeDist = forestN > 0 and fDist / forestN or 0, doors = nB, doorDist = nB > 0 and bDist / nB or 0 }
end
function W.guessKnown(b)
    if setting("orgGuess") == false or not fn(M, "bdRange") then return end
    local r = M.bdRec(b)
    if r.known ~= nil and not (type(r.known) == "table" and r.known.guess) then return end -- a real scan beats a guess
    local R, i = M.bdRange(b)
    if type(r.known) == "table" and r.known.R == R then return end
    local g = W.guess(b, R)
    r.known = { trees = math.max(0, g.trees - (tonumber(r.owe.trees) or 0)), doors = math.max(0, g.doors - (tonumber(r.owe.doors) or 0)),
        wood = 0, treeDist = g.treeDist, doorDist = g.doorDist, woodDist = 0, R = R, guess = true }
    W.stats.guesses = W.stats.guesses + 1
    local cfg = M.bdCfg or {}
    if r.known.trees < (tonumber(cfg.widenBelow) or 4) and type(cfg.ranges) == "table" and i < #cfg.ranges then r.range = i + 1 end
end

----------------------------------------------------------------------------------------------------------------
-- rings: layer 1 = the look's plan (gaps / closed) or Build's box; later layers = a box further out
----------------------------------------------------------------------------------------------------------------
function W.ring(b)
    local r = M.bdRec(b)
    local layer = math.max(1, tonumber(r.layer) or 1)
    local ow = type(r.ow) == "table" and r.ow or nil
    if M.bdCfg then M.bdCfg.ringMaxSegments = math.max(20, math.floor(num("wallMaxRing"))) end
    local ring
    if layer == 1 and ow and (ow.mode == "gaps" or ow.mode == "closed") then
        ring = W.rings[b.id]
        if ring == nil then
            local bb = ow.bbox or boundsOf(b) or { x1 = 0, y1 = 0, x2 = 0, y2 = 0 }
            ring = { walls = type(ow.walls) == "table" and ow.walls or {}, gate = (type(ow.gate) == "table") and { ow.gate } or {},
                x1 = bb.x1, y1 = bb.y1, x2 = bb.x2, y2 = bb.y2, organic = true }
            W.rings[b.id] = ring
        end
    elseif layer >= 2 then
        local bb = (ow and type(ow.bbox) == "table" and ow.bbox) or boundsOf(b)
        if bb == nil then return false end
        local pad = math.floor(num("wallLayerGap")) * (layer - 1)
        ring = W.origRing({ id = tostring(b.id) .. "#L" .. layer, bounds = { x1 = bb.x1 - pad, y1 = bb.y1 - pad, x2 = bb.x2 + pad, y2 = bb.y2 + pad },
            roadSide = b.roadSide })
    else
        ring = W.origRing(b)
    end
    if type(ring) == "table" then for _, p in ipairs(ring.walls) do p.base = b.id end end
    return ring
end
-- the next layer, once this one is finished and enough days have gone by since they settled
function W.maybeLayer(b, h)
    if not W.on() then return false end
    local r = M.bdRec(b)
    local layer = math.max(1, tonumber(r.layer) or 1)
    if layer >= math.floor(num("wallLayers")) then return false end
    if r.ow == nil then return false end -- not before the first look
    local founded = tonumber(b.founded) or tonumber(b.foundedHours)
    if founded == nil then return false end
    if (h - founded) / 24 < num("wallLayerDays") * layer then return false end
    local ring = M.bdRing(b)
    if type(ring) ~= "table" then return false end
    for _, p in ipairs(ring.walls) do if r.walls[p.key] ~= true then return false end end
    if #ring.gate > 0 and not r.gate then return false end
    r.gateDone = type(r.gateDone) == "table" and r.gateDone or {}
    r.gateDone[layer] = r.gate and true or false
    r.layer, r.gate = layer + 1, nil
    W.stats.layers = W.stats.layers + 1
    log(tostring(b.name or b.id) .. " start wall ring " .. (layer + 1))
    return true
end

----------------------------------------------------------------------------------------------------------------
-- placing: a piece whose edge is already closed (wall, fence, building, water, a car) is done for free
----------------------------------------------------------------------------------------------------------------
function W.edgeTaken(p)
    local sq = nil
    pcall(function() sq = getCell():getGridSquare(p.x, p.y, p.z or 0) end)
    if sq == nil then return false end
    local car = false
    pcall(function() car = sq:getVehicleContainer() ~= nil end)
    if car then return true end
    local c = W.readSquare(p.x, p.y)
    if has(c, B_SOLID) then return true end
    if p.north then
        if has(c, B_N) or has(W.readSquare(p.x, p.y - 1), B_SOLID) then return true end
    else
        if has(c, B_W) or has(W.readSquare(p.x - 1, p.y), B_SOLID) then return true end
    end
    return false
end
function W.refundPiece(p)
    local b = p.base ~= nil and fn(M, "nbOf") and M.nbOf(p.base) or nil
    if b == nil then return end
    M.bdAdd(b, "log", pieceCost(p), nil)
    W.stats.skipped = W.stats.skipped + 1
end
-- the gate out of sight, once they have what it takes (planks, hinges, a knob)
function W.settleGate(b, px, py)
    local r = M.bdRec(b)
    if r.gate then return false end
    local ring = M.bdRing(b)
    if type(ring) ~= "table" or #ring.gate == 0 or M.bdNextWall(b) ~= nil then return false end
    local cfg = M.bdCfg
    local safe = tonumber(cfg.playerSafeTiles) or 25
    for _, p in ipairs(ring.gate) do
        if px ~= nil and d2(p.x, p.y, px, py) <= safe * safe then return false end
        if fn(M, "bdPlayerNear") and M.bdPlayerNear(p.x, p.y, safe + 0.001) then return false end
    end
    local c = M.bdContainer(b)
    local need = { plank = cfg.gatePlanks, hinge = cfg.gateHinges, knob = cfg.gateKnobs }
    for k, n in pairs(need) do if M.bdHave(b, k, c) < n then return false end end
    if not M.bdPlaceGate(ring) then return false end
    for k, n in pairs(need) do M.bdSpend(b, k, n, c) end
    r.gate = true
    W.stats.gates = W.stats.gates + 1
    log(tostring(b.name or b.id) .. " hung their gate")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- hooks into Build
----------------------------------------------------------------------------------------------------------------
function W.install()
    if M._owInstalled then return true end
    if not (fn(M, "bdRing") and fn(M, "bdPlaceWall") and fn(M, "bdSettle") and fn(M, "bdDay") and fn(M, "bdScanStep")) then return false end
    M._owInstalled = true
    W.origRing = M.bdRing
    M._owRingRaw = function(b) return M.bdRing(b) end
    M.bdRing = function(b)
        if not W.on() or type(b) ~= "table" then return W.origRing(b) end
        local ok, ring = pcall(W.ring, b)
        if not ok then log("ring failed (logged): " .. tostring(ring)); return W.origRing(b) end
        return ring
    end
    local place = M.bdPlaceWall
    M.bdPlaceWall = function(p)
        if W.on() and type(p) == "table" and not p.corner then
            local ok, taken = pcall(W.edgeTaken, p)
            if ok and taken then pcall(W.refundPiece, p); return true end
        end
        local placed = place(p)
        if placed and type(p) == "table" and p.inside then W.stats.pieces = W.stats.pieces + 1 end
        return placed
    end
    local settle = M.bdSettle
    M.bdSettle = function(b, px, py)
        if W.on() and type(b) == "table" and W.waiting(b) then return false end
        local res = settle(b, px, py)
        if W.on() and type(b) == "table" then pcall(W.settleGate, b, px, py) end
        return res
    end
    local day = M.bdDay
    M.bdDay = function(b, dayIndex)
        if W.on() and type(b) == "table" then
            pcall(W.guessKnown, b)
            pcall(W.maybeLayer, b, hours())
        end
        return day(b, dayIndex)
    end
    local scan = M.bdScanStep
    M.bdScanStep = function(b, h)
        local res = scan(b, h)
        if W.on() and type(b) == "table" then
            pcall(W.step, b, h)
            pcall(W.maybeLayer, b, h)
        end
        return res
    end
    return true
end

function W.perf()
    local s = W.stats
    return "looks " .. s.looks .. " (closed " .. s.closed .. ", gaps " .. s.gaps .. ", open " .. s.open .. ", partial " .. s.partial
        .. "), pieces " .. s.pieces .. ", skipped " .. s.skipped .. ", refunded " .. s.refunded .. ", gates " .. s.gates
        .. ", layers " .. s.layers .. ", guesses " .. s.guesses
end
-- console: what a base's walls look like now
function W.describe(b)
    if type(b) ~= "table" then return "no base" end
    local r = M.bdRec(b)
    local ow = type(r.ow) == "table" and r.ow or {}
    local ring = M.bdRing(b)
    local left = 0
    for _, p in ipairs(type(ring) == "table" and ring.walls or {}) do if r.walls[p.key] ~= true then left = left + 1 end end
    return tostring(b.name or b.id) .. ": " .. tostring(ow.mode or "not looked yet") .. ", ring " .. tostring(r.layer or 1)
        .. ", pieces left " .. left .. ", gate " .. tostring(r.gate and "up" or (type(ring) == "table" and #ring.gate > 0 and "wanted" or "none"))
end

function W.rows()
    if type(M.settingRows) ~= "table" then return end
    local have = {}
    for _, r in ipairs(M.settingRows) do have[r[1]] = true end
    for _, r in ipairs({
        { "orgWalls", "Organic walls: NPC bases close the openings in fences they already have, add a gate, and build more rings late game" },
        { "orgScanTiles", "Organic walls: how far round the base they look for a fence line", { 30, 45, 70 } },
        { "orgMaxGap", "Organic walls: widest opening they will wall over (tiles)", { 4, 8, 12 } },
        { "orgMaxGapTotal", "Organic walls: most wall they'll put in openings before building their own ring (tiles)", { 24, 48, 96 } },
        { "wallLayers", "Organic walls: most wall rings a base builds", { 1, 2, 3 } },
        { "wallLayerDays", "Organic walls: days settled before each extra ring", { 14, 30, 60 } },
        { "wallLayerGap", "Organic walls: tiles between rings", { 2, 3, 5 } },
        { "wallMaxRing", "Organic walls: longest palisade ring they'll build round a place (tiles)", { 100, 140, 220 } },
        { "orgGuess", "Organic walls: bases you never went near count the trees and doors the map says are there" },
        { "orgTreesPer100", "Organic walls: trees counted per 100 tiles of forest (never-seen bases)", { 2, 3, 6 } },
    }) do
        if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
        if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
    end
end

pcall(W.install)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(W.install)
        pcall(W.rows)
        print(TAG .. " ready v" .. W.VERSION .. ": organic walls (" .. (W.on() and "on" or "off") .. ", hooks " .. (M._owInstalled and "in" or "missing") .. ")")
    end)
end
return W
