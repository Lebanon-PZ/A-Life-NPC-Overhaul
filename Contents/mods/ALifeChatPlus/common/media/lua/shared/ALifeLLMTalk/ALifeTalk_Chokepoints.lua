-- A-Life NPC Overhaul 0.6.19: CHOKEPOINTS. Places on the road worth holding, worked out from A-Life's road graph:
--   * river crossings: road legs A-Life marked as crossing water (bridges)
--   * the only road in: a road that, if held, cuts a town (or a whole corner of the map) off from the rest
--   * crossroads: a town whose loss would split the road network (several roads meet there)
-- Big groups now send outposts to hold these as well as police stations, army sites and the like (0.6.5): a house by
-- the bridge, the last building on the only road into town. An outpost on a chokepoint holds up the traders who pass
-- through it: a toll from friends, a robbery from warbands and slavers.
-- Works on any map A-Life has built its road graph for (the vanilla map ships one; A-Life builds one for modded maps
-- as you play). Hand-placed chokepoints can be added: ALifeChokepoints = { { x = .., y = .., label = "..", score = .. } }.
-- Performance: the graph is analysed once (a few hundred towns and roads; a few ms) and again only if it changes.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Chokepoints") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
M.chkCfg = M.chkCfg or { score = { both = 14, bridge = 13, cut = 12, water = 10, cross = 8, extra = 11 }, entryT = 0.12, near = { 0, 15, 30, 50 }, probeAngles = 8,
    candidates = 6, minDist = 100, maxDist = 600, playerFar = 300, baseFar = 100, maxArea = 2500, tollShare = 0.1, robChance = 0.35, onRoute = 60 }
M.chkStats = M.chkStats or { builds = 0, points = 0, outposts = 0, tolls = 0, robbed = 0 }
if M.settings and M.settings.chokepoints == nil then M.settings.chokepoints = true end

local function log(msg) if M.log then M.log("chokepoints: " .. tostring(msg)) end end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function G() local g = PA().RoadGraph; return type(g) == "table" and type(g.nodes) == "table" and type(g.adjacency) == "table" and g or nil end
local function nameOf(g, id)
    local node = g.nodes[id]
    local n = nil
    if fn(g, "displayName") then pcall(function() n = g.displayName(id, node) end) end
    return tostring(n or (node and node.name) or id)
end
local function at(g, a, b, t)
    if fn(g, "interpolate") then local ok, p = pcall(g.interpolate, a, b, t); if ok and type(p) == "table" and tonumber(p.x) then return p.x, p.y end end
    local na, nb = g.nodes[a], g.nodes[b]
    return na.x + (nb.x - na.x) * t, na.y + (nb.y - na.y) * t
end

-- bridges (cut edges) and cut vertices of the road graph, iteratively (no deep recursion); sub = size of the part
-- that hangs off each cut edge (on the child side)
function M.chkAnalyse(nodes, adj)
    local disc, low, parent, sub, order = {}, {}, {}, {}, 0
    local cutEdges, cutNodes = {}, {}
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    local total = #ids
    for _, root in ipairs(ids) do
        if disc[root] == nil then
            order = order + 1
            disc[root], low[root], sub[root] = order, order, 1
            local rootKids = 0
            local stack = { { id = root, nbrs = nil, i = 0 } }
            while #stack > 0 do
                local top = stack[#stack]
                if top.nbrs == nil then
                    top.nbrs = {}
                    for nb in pairs(adj[top.id] or {}) do top.nbrs[#top.nbrs + 1] = nb end
                    table.sort(top.nbrs)
                end
                top.i = top.i + 1
                local nb = top.nbrs[top.i]
                if nb ~= nil then
                    if disc[nb] == nil then
                        parent[nb] = top.id
                        order = order + 1
                        disc[nb], low[nb], sub[nb] = order, order, 1
                        if top.id == root then rootKids = rootKids + 1 end
                        stack[#stack + 1] = { id = nb, nbrs = nil, i = 0 }
                    elseif nb ~= parent[top.id] then
                        if disc[nb] < low[top.id] then low[top.id] = disc[nb] end
                    end
                else
                    stack[#stack] = nil
                    local p = parent[top.id]
                    if p ~= nil then
                        sub[p] = sub[p] + sub[top.id]
                        if low[top.id] < low[p] then low[p] = low[top.id] end
                        if low[top.id] > disc[p] then cutEdges[#cutEdges + 1] = { a = p, b = top.id, side = sub[top.id] } end
                        if p ~= root and low[top.id] >= disc[p] then cutNodes[p] = true end
                    end
                end
            end
            if rootKids > 1 then cutNodes[root] = true end
        end
    end
    return cutEdges, cutNodes, total
end

-- 0.6.19: real bridges from the map's own zone data (vanilla ships it): roads (Nav zones) that cross a river (the
-- river traced through its WaterFlow markers). Modded maps mostly have no such data yet: generated after 1.0.
M.chkCfg.river = M.chkCfg.river or { link = 150, cluster = 60, minHits = 2, cell = 100 }
local function clipSeg(ax, ay, bx, by, r)
    local x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
    local dx, dy = bx - ax, by - ay
    local t0, t1 = 0, 1
    local function clip(p, q)
        if p == 0 then return q >= 0 end
        local t = q / p
        if p < 0 then if t > t1 then return false elseif t > t0 then t0 = t end
        else if t < t0 then return false elseif t < t1 then t1 = t end end
        return true
    end
    if clip(-dx, ax - x0) and clip(dx, x1 - ax) and clip(-dy, ay - y0) and clip(dy, y1 - ay) then
        local t = (t0 + t1) / 2
        return ax + dx * t, ay + dy * t
    end
    return nil
end
function M.chkBridges(Z)
    if type(Z) ~= "table" or not fn(Z, "list") then return {} end
    local cfg = M.chkCfg.river
    local water, roads = Z.list("water"), Z.list("roads")
    if #water == 0 or #roads == 0 then return {} end
    local pts, grid = {}, {}
    local R = cfg.link
    for i, w in ipairs(water) do
        local p = { x = w.x + w.w / 2, y = w.y + w.h / 2 }
        pts[i] = p
        local k = math.floor(p.x / R) .. ":" .. math.floor(p.y / R)
        grid[k] = grid[k] or {}
        grid[k][#grid[k] + 1] = i
    end
    local rg, rc = {}, cfg.cell
    for i, r in ipairs(roads) do
        for gx = math.floor(r.x / rc), math.floor((r.x + r.w) / rc) do
            for gy = math.floor(r.y / rc), math.floor((r.y + r.h) / rc) do
                local k = gx .. ":" .. gy
                rg[k] = rg[k] or {}
                rg[k][#rg[k] + 1] = i
            end
        end
    end
    local hits = {}
    for i, p in ipairs(pts) do
        local cx, cy = math.floor(p.x / R), math.floor(p.y / R)
        for dx = -1, 1 do for dy = -1, 1 do
            for _, j in ipairs(grid[(cx + dx) .. ":" .. (cy + dy)] or {}) do
                local q = pts[j]
                local dd = (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2
                if j > i and dd > 0 and dd <= R * R then
                    local seen = {}
                    for gx = math.floor(math.min(p.x, q.x) / rc), math.floor(math.max(p.x, q.x) / rc) do
                        for gy = math.floor(math.min(p.y, q.y) / rc), math.floor(math.max(p.y, q.y) / rc) do
                            for _, ri in ipairs(rg[gx .. ":" .. gy] or {}) do
                                if not seen[ri] then
                                    seen[ri] = true
                                    local x, y = clipSeg(p.x, p.y, q.x, q.y, roads[ri])
                                    if x then hits[#hits + 1] = { x = x, y = y } end
                                end
                            end
                        end
                    end
                end
            end
        end end
    end
    local cl = {}
    for _, h in ipairs(hits) do
        local f = nil
        for _, c in ipairs(cl) do if d2(c.x, c.y, h.x, h.y) < cfg.cluster ^ 2 then f = c; break end end
        if f then f.sx, f.sy, f.n = f.sx + h.x, f.sy + h.y, f.n + 1; f.x, f.y = f.sx / f.n, f.sy / f.n
        else cl[#cl + 1] = { x = h.x, y = h.y, sx = h.x, sy = h.y, n = 1 } end
    end
    local out = {}
    for _, c in ipairs(cl) do if c.n >= cfg.minHits then out[#out + 1] = { x = math.floor(c.x), y = math.floor(c.y), n = c.n } end end
    return out
end

-- every chokepoint: { x, y, kind, score, label }
function M.chkPoints()
    if M.settings.chokepoints == false then return {} end
    local g = G()
    local epoch = g and (tonumber(g.epoch) or 0) or -1
    local c = M._chk
    if c and c.epoch == epoch and c.g == g then return c.list end
    local list = {}
    if g then
        local ok, err = pcall(function()
            local S = M.chkCfg.score
            local cutEdges, cutNodes, total = M.chkAnalyse(g.nodes, g.adjacency)
            local isCut = {}
            for _, e in ipairs(cutEdges) do isCut[e.a .. ">" .. e.b], isCut[e.b .. ">" .. e.a] = e, e end
            local done = {}
            for _, e in ipairs(g.edges or {}) do
                local ce = isCut[e.a .. ">" .. e.b]
                if ce or e.bridge then
                    local key = e.a < e.b and (e.a .. ">" .. e.b) or (e.b .. ">" .. e.a)
                    if not done[key] then
                        done[key] = true
                        if ce then
                            -- the road into the smaller side, near its end
                            local small, big = ce.b, ce.a
                            if ce.side > total - ce.side then small, big = ce.a, ce.b end
                            local x, y = at(g, small, big, M.chkCfg.entryT)
                            list[#list + 1] = { x = x, y = y, kind = e.bridge and "both" or "cut", score = e.bridge and S.both or S.cut,
                                label = (e.bridge and "river crossing into " or "only road into ") .. nameOf(g, small), a = e.a, b = e.b }
                        else
                            local x, y = at(g, e.a, e.b, 0.5)
                            list[#list + 1] = { x = x, y = y, kind = "water", score = S.water,
                                label = "river crossing between " .. nameOf(g, e.a) .. " and " .. nameOf(g, e.b), a = e.a, b = e.b }
                        end
                    end
                end
            end
            for id in pairs(cutNodes) do
                local deg = 0
                for _ in pairs(g.adjacency[id] or {}) do deg = deg + 1 end
                local n = g.nodes[id]
                if deg >= 3 and n then list[#list + 1] = { x = n.x, y = n.y, kind = "cross", score = S.cross, label = "crossroads at " .. nameOf(g, id), node = id } end
            end
        end)
        if not ok then log("could not read the road graph: " .. tostring(err)) end
    end
    -- real bridges from the zone data (once a session: it doesn't change)
    if M._chkBridges == nil then
        local okB, br = pcall(M.chkBridges, PA().MapZones)
        M._chkBridges = okB and br or {}
        if not okB then log("could not read the map zones: " .. tostring(br)) end
    end
    for _, p in ipairs(M._chkBridges) do
        local near = nil
        if g and fn(g, "nearest") then pcall(function() local id = g.nearest(p.x, p.y, "town"); if id then near = nameOf(g, id) end end) end
        list[#list + 1] = { x = p.x, y = p.y, kind = "bridge", score = M.chkCfg.score.bridge, label = "bridge" .. (near and (" near " .. near) or "") }
    end
    for _, p in ipairs(type(ALifeChokepoints) == "table" and ALifeChokepoints or {}) do
        if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
            list[#list + 1] = { x = tonumber(p.x), y = tonumber(p.y), kind = "extra", score = tonumber(p.score) or M.chkCfg.score.extra, label = tostring(p.label or "the road") }
        end
    end
    table.sort(list, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.label < b.label end)
    M._chk = { epoch = epoch, g = g, list = list }
    M.chkStats.builds, M.chkStats.points = M.chkStats.builds + 1, #list
    if #list > 0 then log(#list .. " chokepoints on the road graph") end
    return list
end

----------------------------------------------------------------------------------------------------------------
-- outposts: hold a chokepoint (a building right by it)
----------------------------------------------------------------------------------------------------------------
local function playerNear(x, y, r)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then return ALifeSide.nearest(x, y, r) ~= nil end -- MP: any online player
    local px, py = nil, nil
    pcall(function() local p = ALifeSide.you(); px, py = p:getX(), p:getY() end)
    return px ~= nil and d2(px, py, x, y) <= r * r
end
local function baseNear(x, y, r)
    local st = M.nbStore and M.nbStore() or nil
    for _, o in pairs(st and st.byId or {}) do
        if type(o) == "table" and o.status == "active" and tonumber(o.x) and d2(o.x, o.y, x, y) <= r * r then return true end
    end
    return false
end
local function held(p)
    local st = M.nbStore and M.nbStore() or nil
    for _, o in pairs(st and st.byId or {}) do
        if type(o) == "table" and o.status == "active" and type(o.choke) == "table" and d2(o.choke.x, o.choke.y, p.x, p.y) < 40 * 40 then return o end
    end
    return nil
end
M.chkHeldBy = held
-- a building to hold right by the chokepoint
function M.chkBuildingNear(p, h)
    local cfg = M.chkCfg
    local best, bd = nil, 1e18
    for _, r in ipairs(cfg.near) do
        for k = 0, (r == 0 and 0 or cfg.probeAngles - 1) do
            local a = k * 2 * math.pi / cfg.probeAngles
            local def = nil
            pcall(function() def = getWorld():getMetaGrid():getBuildingAt(math.floor(p.x + math.cos(a) * r), math.floor(p.y + math.sin(a) * r)) end)
            if def then
                local bb = nil
                pcall(function() bb = { x1 = def:getX(), y1 = def:getY(), x2 = def:getX2(), y2 = def:getY2() } end)
                if bb then
                    local area = (bb.x2 - bb.x1 + 1) * (bb.y2 - bb.y1 + 1)
                    local cx, cy = (bb.x1 + bb.x2) / 2, (bb.y1 + bb.y2) / 2
                    local dd = d2(cx, cy, p.x, p.y)
                    if area <= cfg.maxArea and dd < bd then
                        local c = { key = bb.x1 .. ":" .. bb.y1, bounds = bb, center = { x = cx, y = cy }, why = { p.label } }
                        local ex = fn(M, "nbExcluded") and select(2, pcall(M.nbExcluded, c, h)) or nil
                        if not ex then best, bd = c, dd end
                    end
                end
            end
        end
        if best then return best end -- the closest ring with a building wins
    end
    return best
end
-- the best chokepoint spot for group b (or nil): { c, what, score, choke }
function M.chkSpotFor(b, h)
    if M.settings.chokepoints == false or type(b) ~= "table" or not tonumber(b.x) then return nil end
    local cfg = M.chkCfg
    local cands = {}
    for _, p in ipairs(M.chkPoints()) do
        local dd = d2(p.x, p.y, b.x, b.y)
        if dd >= cfg.minDist ^ 2 and dd <= cfg.maxDist ^ 2 and not held(p) and not playerNear(p.x, p.y, cfg.playerFar) and not baseNear(p.x, p.y, cfg.baseFar) then
            cands[#cands + 1] = { p = p, s = p.score - math.sqrt(dd) / 250 }
        end
    end
    table.sort(cands, function(a, c) return a.s > c.s end)
    for i = 1, math.min(#cands, cfg.candidates) do
        local c = M.chkBuildingNear(cands[i].p, h)
        if c then return { c = c, what = cands[i].p.label, score = cands[i].s, choke = cands[i].p } end
    end
    return nil
end

-- outposts consider chokepoints too: the better of the best place to hold and the best chokepoint
function M.chkInstall()
    if M._alcpHooks and M._alcpHooks.chokepoints then return true end
    if not fn(M, "opFindSpot") or not fn(M, "opFound") then return false end
    M._alcpHooks = M._alcpHooks or {}
    M._alcpHooks.chokepoints = true
    M.cvArriveHooks = M.cvArriveHooks or {}
    table.insert(M.cvArriveHooks, function(visit, b, h) local ok, err = pcall(M.chkTell, b, h, "traders"); if not ok then log("tell failed: " .. tostring(err)) end end)
    local find = M.opFindSpot
    M.opFindSpot = function(b, h, ...)
        local poi = find(b, h, ...)
        local ok, ch = pcall(M.chkSpotFor, b, h)
        if not ok then print("[ALifeChokepoints] spot search failed, chokepoints off for this session: " .. tostring(ch)); M.settings.chokepoints = false; return poi end
        if ch == nil then return poi end
        -- a POI's worth (police 10 ... farm 3) against the chokepoint's: both minus distance
        local poiScore = poi and (tonumber(poi.score) or 7) or -1e9
        if ch.score > poiScore then M.chkPending = ch.choke; return ch end
        return poi
    end
    local found = M.opFound
    M.opFound = function(b, h, ...)
        local before = {}
        local st = M.nbStore()
        for id in pairs(st.byId or {}) do before[id] = true end
        local res = found(b, h, ...)
        local p = M.chkPending
        M.chkPending = nil
        if p then
            for id, o in pairs(st.byId or {}) do
                if not before[id] and type(o) == "table" and o.outpostOf == b.id then
                    o.choke = { x = p.x, y = p.y, label = p.label, kind = p.kind, a = p.a, b = p.b }
                    M.chkStats.outposts = M.chkStats.outposts + 1
                    log(tostring(b.name) .. " holds the " .. p.label)
                end
            end
        end
        return res
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- traders passing a held chokepoint: a toll (friends of the holders) or a robbery (warbands, slavers)
----------------------------------------------------------------------------------------------------------------
-- outposts on the road from (ax, ay) to (bx, by): the leg passes within onRoute tiles of the chokepoint
function M.chkOnRoute(ax, ay, bx, by, except)
    local out = {}
    local st = M.nbStore and M.nbStore() or nil
    local cfg = M.chkCfg
    local vx, vy = bx - ax, by - ay
    local L2 = vx * vx + vy * vy
    for _, o in pairs(st and st.byId or {}) do
        if type(o) == "table" and o.status == "active" and type(o.choke) == "table" and o.id ~= except and o.outpostOf ~= except then
            local px, py = o.choke.x, o.choke.y
            local t = L2 > 0 and math.max(0, math.min(1, ((px - ax) * vx + (py - ay) * vy) / L2)) or 0
            local qx, qy = ax + vx * t, ay + vy * t
            if t > 0.02 and t < 0.98 and d2(px, py, qx, qy) <= cfg.onRoute ^ 2 then out[#out + 1] = o end
        end
    end
    return out
end
local function parentOf(o)
    local st = M.nbStore()
    return st.byId and st.byId[o.outpostOf] or nil
end
local function hostile(o)
    local p = parentOf(o) or o
    return p.trade == "warband" or p.trade == "slavers"
end
-- goods (list of types) carried by group `who` past held chokepoints: returns the goods left, and what happened
function M.chkPass(who, goods, ax, ay, bx, by, day)
    if M.settings.chokepoints == false or type(goods) ~= "table" or #goods == 0 then return goods, nil end
    local left = goods
    local what = nil
    for _, o in ipairs(M.chkOnRoute(ax, ay, bx, by, who and who.id)) do
        local holder = parentOf(o) or o
        local tie = (fn(M, "dirTie") and M.dirTie(holder, who)) or 0
        local roll = ALifeRoll01 and ALifeRoll01(tostring(o.id) .. ">" .. tostring(who and who.id) .. "#" .. tostring(day)) or 0.5
        if hostile(o) and tie < 25 and roll < M.chkCfg.robChance then
            -- robbed: the holders take it all to their stash
            local ls = fn(M, "nbStashList") and M.nbStashList(fn(M, "nbHavenOf") and M.nbHavenOf(o) or nil, true) or nil
            if ls then for _, t in ipairs(left) do ls[#ls + 1] = { type = t } end end
            M.chkStats.robbed = M.chkStats.robbed + 1
            what = "robbed at the " .. tostring(o.choke.label) .. " by " .. tostring(holder.name)
            if fn(M, "nbEvent") then pcall(M.nbEvent, o, "Took everything a passing group of traders carried at the " .. tostring(o.choke.label), "raid") end
            if fn(M, "dirTieAdd") and who then pcall(M.dirTieAdd, holder, who, -20) end
            return {}, what
        end
        -- a toll: a share of the goods (the best of them) to the holders
        local n = math.max(1, math.floor(#left * M.chkCfg.tollShare + 0.5))
        local keep, toll = {}, {}
        local sorted = {}
        for i, t in ipairs(left) do sorted[i] = { t = t, w = type(ALifeWorth) == "table" and ALifeWorth.of(t) or 1 } end
        table.sort(sorted, function(a, b) return a.w > b.w end)
        for i, e in ipairs(sorted) do if i <= n then toll[#toll + 1] = e.t else keep[#keep + 1] = e.t end end
        local ls = fn(M, "nbStashList") and M.nbStashList(fn(M, "nbHavenOf") and M.nbHavenOf(o) or nil, true) or nil
        if ls then for _, t in ipairs(toll) do ls[#ls + 1] = { type = t } end end
        M.chkStats.tolls = M.chkStats.tolls + 1
        left = keep
        what = (what and (what .. "; ") or "") .. "paid a toll at the " .. tostring(o.choke.label)
    end
    return left, what
end

-- a trade run between two groups (stash to stash) passing held chokepoints; true = robbed (run over)
function M.chkRunHazard(b, best, give, n, day, moveKind)
    if M.settings.chokepoints == false then return false end
    for _, o in ipairs(M.chkOnRoute(b.x, b.y, best.x, best.y, b.id)) do
        if o.outpostOf ~= best.id and o.id ~= best.id then
            local holder = parentOf(o) or o
            local tie = (fn(M, "dirTie") and M.dirTie(holder, b)) or 0
            local roll = ALifeRoll01 and ALifeRoll01(tostring(o.id) .. ">" .. tostring(b.id) .. "#" .. tostring(day)) or 0.5
            local mine, theirs = M.nbHavenOf(b), M.nbHavenOf(o)
            if hostile(o) and tie < 25 and roll < M.chkCfg.robChance then
                local got = moveKind(mine, theirs, give, n)
                M.chkStats.robbed = M.chkStats.robbed + 1
                if fn(M, "nbEvent") then
                    pcall(M.nbEvent, b, "Their trade run to " .. tostring(best.name) .. " was robbed at the " .. tostring(o.choke.label) .. " by " .. tostring(holder.name), "trade")
                    pcall(M.nbEvent, o, "Robbed a trade run from " .. tostring(b.name) .. " at the " .. tostring(o.choke.label) .. " (" .. tostring(got) .. " " .. tostring(give) .. ")", "trade")
                end
                if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, holder, -15) end
                return true
            end
            local toll = moveKind(mine, theirs, give, math.max(1, math.floor(n * M.chkCfg.tollShare + 0.5)))
            if (tonumber(toll) or 0) > 0 then
                M.chkStats.tolls = M.chkStats.tolls + 1
                if fn(M, "nbEvent") then pcall(M.nbEvent, b, "Paid a toll of " .. tostring(toll) .. " " .. tostring(give) .. " at the " .. tostring(o.choke.label), "trade") end
            end
        end
    end
    return false
end

-- debug: every chokepoint on your map (for checking them against the real map)
function M.chkMarkMap()
    local list = M.chkPoints()
    M.jnQueue = M.jnQueue or {}
    for _, p in ipairs(list) do M.jnQueue[#M.jnQueue + 1] = { text = "[choke] " .. p.label, x = math.floor(p.x), y = math.floor(p.y) } end
    if fn(M, "jnFlush") then pcall(M.jnFlush) end
    return #list
end

----------------------------------------------------------------------------------------------------------------
-- 0.6.21 word on the road: people who travel (traders at your place, groups on the radio) tell you who holds the
-- roads near them and what happened to them on the way. It goes in your journal (what you were told, not live).
----------------------------------------------------------------------------------------------------------------
M.chkCfg.tellTiles = M.chkCfg.tellTiles or 900
M.chkCfg.tellMax = M.chkCfg.tellMax or 2
M.chkCfg.troubleDays = M.chkCfg.troubleDays or 7
function M.chkTell(b, h, via)
    if M.settings.chokepoints == false or type(b) ~= "table" or not tonumber(b.x) or not fn(M, "jnLearn") then return 0 end
    local st = M.nbStore()
    local told = 0
    -- who holds which road near them (nearest first)
    local list = {}
    for _, o in pairs(st.byId or {}) do
        if type(o) == "table" and o.status == "active" and type(o.choke) == "table" and o.outpostOf ~= b.id and o.id ~= b.id then
            local dd = d2(o.choke.x, o.choke.y, b.x, b.y)
            if dd <= M.chkCfg.tellTiles ^ 2 then list[#list + 1] = { o = o, d = dd } end
        end
    end
    table.sort(list, function(a, c) return a.d < c.d end)
    for i = 1, math.min(#list, M.chkCfg.tellMax) do
        local o = list[i].o
        local holder = parentOf(o) or o
        local fresh = type(o.intel) == "table" and o.intel.choke == o.choke.label and h - (tonumber(o.intel.at) or -1e9) < 24
        if not fresh then
        local feel = hostile(o) and "they rob people there" or "they take a toll"
        local text = tostring(b.name) .. " say " .. tostring(holder.name) .. " hold the " .. tostring(o.choke.label) .. " (" .. feel .. ")"
        local fields = { status = "holding the " .. tostring(o.choke.label) }
        if fn(M, "jnSnapshot") then local okS, snap = pcall(M.jnSnapshot, o); if okS and type(snap) == "table" then snap.status = fields.status; fields = snap end end
        pcall(M.jnLearn, o, "rumor", fields, text, b.name)
        o.intel = type(o.intel) == "table" and o.intel or {}
        o.intel.choke = o.choke.label -- roughly where: the place they named
        if o.intel.x == nil then o.intel.x, o.intel.y = o.choke.x, o.choke.y end
        told = told + 1
        end
    end
    -- what happened to them on the road lately
    local since = h - M.chkCfg.troubleDays * 24
    for i = #(b.events or {}), 1, -1 do
        local e = b.events[i]
        if type(e) == "table" and (tonumber(e.h) or 0) < since then break end
        if type(e) == "table" and type(e.t) == "string" and (string.find(e.t, "robbed at the", 1, true) or string.find(e.t, "toll", 1, true)) then
            if b.chkToldH == e.h then break end
            b.chkToldH = e.h
            pcall(M.jnLearn, b, via == "radio" and "radio" or "rumor", {}, tostring(b.name) .. ": " .. e.t, b.name)
            told = told + 1
            break
        end
    end
    return told
end

local function tryInstall() local ok, res = pcall(M.chkInstall); return ok and res end
if Events and Events.OnGameStart then Events.OnGameStart.Add(function() tryInstall() end) end
tryInstall()
print("[ALifeChokepoints] loaded v" .. ALifeSide.MOD_VERSION .. " (river crossings, only roads in and crossroads from the road graph)")
