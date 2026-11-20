-- A-Life NPC Overhaul 0.6.17: PEOPLE ACTUALLY LEAVE.
-- Whenever someone goes somewhere (a caravan heading home, radio help going back, a searcher sent out, a group
-- setting out to trade, a household moving on), they really go:
--   1. WALK OFF: if you're there, they walk away down the road (or the way they're headed). They vanish only once
--      you can't see them any more (out of sight, or far enough away). Never in front of you.
--   2. ON THE ROAD: while they travel they are somewhere along the way, moved on as time passes (snapped to a road).
--      Not at home, not at the place they're going. Go there and you can meet them on the road; they carry on.
--   3. GET THERE: when the travel time is up they are where they went (or back home, for a round trip).
-- Performance: one pass a second over the people currently leaving (usually 0-6); the road spot is recomputed once
-- a game hour per person.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Leaving") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
M.lvCfg = M.lvCfg or {
    hideTiles = 18,       -- out of view and at least this far: gone
    goneTiles = 40,       -- this far: gone even if you could still see them
    stepTiles = 30,       -- each walk point is this far ahead
    walkMaxMs = 180000,   -- walked this long (real time) and you're not looking: gone
    tickMs = 1000,
    claimMs = 120000,
    hopH = 1,             -- road spot recomputed this often (game hours)
}
M.lvStats = M.lvStats or { sent = 0, walked = 0, gone = 0, met = 0, arrived = 0, stuck = 0 }

local function log(msg) if M.log then M.log("leaving: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function pxy(p) local x, y = nil, nil; pcall(function() x, y = p:getX(), p:getY() end); return x, y end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function store()
    local st = fn(M, "nbStore") and M.nbStore() or (M.lvMem or {})
    M.lvMem = st
    st.leavers = type(st.leavers) == "table" and st.leavers or {}
    return st
end
local function shellOf(uid)
    local sh = nil
    pcall(function() sh = PA().Talk.shellFor(uid) end)
    return sh
end
local function posOf(r, sh)
    local x, y = nil, nil
    if sh then pcall(function() x, y = sh:getX(), sh:getY() end) end
    if x == nil and type(r) == "table" and type(r.worldPosition) == "table" then x, y = tonumber(r.worldPosition.x), tonumber(r.worldPosition.y) end
    return x, y
end
local function setPos(uid, p, extra)
    local reg = PA().ActorRegistry
    if not (fn(reg, "read") and fn(reg, "update")) then return false end
    local r = reg.read(uid)
    if r == nil then return false end
    local ok, res = pcall(reg.update, r.uid, r.revision, function(e)
        e.memory = type(e.memory) == "table" and e.memory or {}
        if p then e.worldPosition = { x = math.floor(p.x) + 0.5, y = math.floor(p.y) + 0.5, z = p.z or 0 } end
        if extra then extra(e) end
    end)
    return ok and res ~= false
end
-- a spot near (x, y) on a road when A-Life knows the roads, else the spot itself
local function roadSpot(x, y)
    local G = PA().RoadGraph
    if fn(G, "snapToRoad") then
        local ok, s = pcall(G.snapToRoad, x, y, 48)
        if ok and type(s) == "table" and tonumber(s.x) then return { x = s.x, y = s.y, z = 0 } end
    end
    return { x = x, y = y, z = 0 }
end
M.lvRoadSpot = roadSpot

-- where they are on the road at game hour h (round trips go out and come back)
function M.lvWhere(L, h)
    local span = math.max(0.01, (tonumber(L.untilH) or h) - (tonumber(L.startH) or h))
    local f = math.max(0, math.min(1, (h - (tonumber(L.startH) or h)) / span))
    local ax, ay, bx, by = L.fx, L.fy, L.tx, L.ty
    if L.round then
        if f <= 0.4 then f = f / 0.4 elseif f <= 0.6 then f = 1 else f = 1 - (f - 0.6) / 0.4 end
    end
    return ax + (bx - ax) * f, ay + (by - ay) * f, f
end
-- where they're headed right now
local function headingTo(L, h)
    if L.round and (h - L.startH) > ((L.untilH - L.startH) * 0.5) then return L.fx, L.fy end
    return L.tx, L.ty
end

-- send someone off. o = { tx, ty (where they go), untilH (when they get there; default: their walking time),
-- round (go and come back by untilH), final {x,y,z} (where they end up at untilH), tag, fx, fy (start; default now) }
function M.lvSend(uid, o)
    uid = tostring(uid or "")
    if uid == "" or type(o) ~= "table" or not tonumber(o.tx) or not tonumber(o.ty) then return false end
    if M.settings and M.settings.peopleLeave == false then return false end
    local reg = PA().ActorRegistry
    local r = fn(reg, "read") and reg.read(uid) or nil
    if r == nil or r.lifecycle == "dead" then return false end
    local h = hours()
    local x, y = posOf(r, shellOf(uid))
    local fx, fy = tonumber(o.fx) or x or o.tx, tonumber(o.fy) or y or o.ty
    local untilH = tonumber(o.untilH)
    if untilH == nil then
        local th = 6
        if fn(M, "travelH") then local ok, t = pcall(M.travelH, fx, fy, o.tx, o.ty, nil); if ok and tonumber(t) then th = t end end
        untilH = h + th * (o.round and 2 or 1)
    end
    local L = { uid = uid, tx = o.tx, ty = o.ty, fx = fx, fy = fy, startH = h, untilH = math.max(h + 0.05, untilH), round = o.round == true or nil,
        final = type(o.final) == "table" and { x = o.final.x, y = o.final.y, z = o.final.z or 0 } or nil, tag = tostring(o.tag or "trip"),
        phase = "walk", atMs = now(), hopH = -1e9 }
    store().leavers[uid] = L
    M.lvStats.sent = M.lvStats.sent + 1
    return true
end
function M.lvIsAway(uid) local L = store().leavers[tostring(uid)]; return L ~= nil, L end
function M.lvCancel(uid) store().leavers[tostring(uid)] = nil end

local function patch() return type(ALifeTalkPatch) == "table" and ALifeTalkPatch or nil end
local function claimWalk(L, sh, x, y, px, py, h)
    local P = patch()
    if not (P and fn(P, "claim")) then return false end
    local hx, hy = headingTo(L, h)
    local dx, dy = hx - x, hy - y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 3 then -- already where they're going (you're there too): walk away from you instead
        dx, dy = x - (px or x - 1), y - (py or y); len = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    end
    local step = M.lvCfg.stepTiles
    local wx, wy = x + dx / len * step, y + dy / len * step
    local spot = roadSpot(wx, wy)
    -- a road spot that brings them back toward you is no good
    if px and d2(spot.x, spot.y, px, py) < d2(x, y, px, py) then spot = { x = wx, y = wy, z = 0 } end
    local c = P.own and P.own.claims and P.own.claims[L.uid] or nil
    if c and c.kind == "leave" and type(c.spec) == "table" and not c.spec.arrived and type(c.spec.anchor) == "table"
            and d2(c.spec.anchor.x, c.spec.anchor.y, spot.x, spot.y) < 64 then
        return true
    end
    local ok, res = pcall(P.claim, L.uid, "leave", { ms = M.lvCfg.claimMs, anchor = { x = math.floor(spot.x), y = math.floor(spot.y), z = 0 }, player = playerOf() })
    return ok and res == true
end
local function goneNow(L, h)
    local spawn = PA().SpawnService
    if not fn(spawn, "dehydrate") then return false end
    local ok, res, why = pcall(spawn.dehydrate, L.uid, "alcp_leave")
    if not ok or res == false then -- A-Life said no (e.g. a person it keeps loaded): give up walking them after a few tries
        L.refused = (L.refused or 0) + 1
        if L.refused >= 5 then
            local P = patch()
            if P and fn(P, "release") then pcall(P.release, L.uid, "can't leave") end
            store().leavers[L.uid] = nil
            log("A-Life keeps " .. tostring(L.uid) .. " loaded (" .. tostring(ok and why or res) .. "): they stay")
        end
        return false
    end
    local P = patch()
    if P and fn(P, "release") then pcall(P.release, L.uid, "left") end
    L.phase, L.hopH = "away", -1e9
    M.lvStats.gone = M.lvStats.gone + 1
    return true
end
M.lvCfg.clearTiles = M.lvCfg.clearTiles or 70 -- never put them on the road this close to you (they'd pop in)
local function hop(L, h, px, py)
    if h - (tonumber(L.hopH) or -1e9) < M.lvCfg.hopH then return end
    L.hopH = h
    local x, y = M.lvWhere(L, h)
    local s = roadSpot(x, y)
    if px and d2(s.x, s.y, px, py) < M.lvCfg.clearTiles ^ 2 then return end
    s.x, s.y = s.x + (hash(L.uid) % 3) - 1, s.y + (hash(L.uid .. "y") % 3) - 1
    setPos(L.uid, s)
end
local function arrive(L)
    if L.final then setPos(L.uid, L.final) end
    store().leavers[L.uid] = nil
    M.lvStats.arrived = M.lvStats.arrived + 1
end

function M.lvStep(L, h, player, px, py, t)
    local reg = PA().ActorRegistry
    local r = reg.read(L.uid)
    if r == nil or r.lifecycle == "dead" then store().leavers[L.uid] = nil; return end
    if r.lifecycle == "active" then
        local sh = shellOf(L.uid)
        local x, y = posOf(r, sh)
        if x == nil then return end
        if L.phase == "away" then L.phase, L.atMs = "walk", t; M.lvStats.met = M.lvStats.met + 1 end -- you met them on the road
        local dist2 = px and d2(x, y, px, py) or 1e12
        local seen = false
        if player and sh and dist2 < M.lvCfg.goneTiles ^ 2 then pcall(function() seen = player:CanSee(sh) == true end) end
        if dist2 >= M.lvCfg.goneTiles ^ 2 or (not seen and dist2 >= M.lvCfg.hideTiles ^ 2)
                or (not seen and t - (tonumber(L.atMs) or t) > M.lvCfg.walkMaxMs) then
            if goneNow(L, h) then hop(L, h, px, py) end
            return
        end
        if not L.walked then L.walked = true; M.lvStats.walked = M.lvStats.walked + 1 end
        if not claimWalk(L, sh, x, y, px, py, h) and not L.noClaim then
            L.noClaim = true; M.lvStats.stuck = M.lvStats.stuck + 1 -- the patch can't walk them: they slip off when you look away
        end
        return
    end
    -- unloaded: on the road
    if L.phase == "walk" then L.phase = "away" end
    if h >= L.untilH then return arrive(L) end
    hop(L, h, px, py)
end

local lastMs = -1e12
function M.lvTick()
    local t = now()
    if t - lastMs < M.lvCfg.tickMs then return end
    lastMs = t
    local st = store()
    local any = false
    for _ in pairs(st.leavers) do any = true; break end
    if not any then return end
    local reg = PA().ActorRegistry
    if not fn(reg, "read") then return end
    local h, player = hours(), playerOf()
    local px, py = pxy(player)
    local list = {}
    for _, L in pairs(st.leavers) do list[#list + 1] = L end
    for _, L in ipairs(list) do
        if ALifeSide.mpServer() then -- MP: "you" = the online player nearest whoever is leaving
            local sh = nil
            pcall(function() sh = PA().Talk.shellFor(tostring(L.uid)) end)
            player = (sh and ALifeSide.nearestTo(sh)) or (fn(M, "homePlayer") and M.homePlayer()) or nil
            px, py = pxy(player)
        end
        M.lvStep(L, h, player, px, py, t)
    end
end

local broken = false
local function guardedTick()
    if broken then return end
    local ok, err = pcall(M.lvTick)
    if not ok then broken = true; print("[ALifeLeaving] tick failed, people leaving off for this session: " .. tostring(err)) end
end
if not M._lvHooked then
    M._lvHooked = true
    if type(ALifeHealth) == "table" then ALifeHealth.tickAdd("ALifeTalk_Leaving", guardedTick)
    elseif type(ALifeTick) == "table" then ALifeTick.add(guardedTick) end
end
print("[ALifeLeaving] loaded v0.6.17 (people walk off, travel the road, get there)")
