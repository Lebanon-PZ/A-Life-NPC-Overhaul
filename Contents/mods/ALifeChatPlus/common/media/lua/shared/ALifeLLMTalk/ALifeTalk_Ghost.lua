-- A-Life NPC Overhaul 0.8.12 (Rock List 2) / 0.9.0.1: GHOST BUILD, the client side: placing plans, seeing them, the
-- Build tab, and the builders. The queue and costs: shared/ALifeNPCOverhaul/ALifeGhostBuild.lua.
--   * PLACING: Build tab > Plan something > a category > a thing (everything vanilla's build menu builds, plus the six
--     basic types). The cursor is vanilla's own build cursor (ISBuildIsoEntity, same placement rules, rotation with R,
--     same sprites) with two changes: it needs no materials, and placing records a plan ("ghostPlace") instead of
--     building. Keep clicking for more. 0.9.0.1: SHIFT-click a start and SHIFT-click an end = a straight line;
--     CTRL+SHIFT on the end = a box (north walls top and bottom, west walls left and right, the way the game hangs
--     walls on a square's edge). Right-click / Esc stops. Plans go inside your base unless outposts are on.
--   * SEEING: plans are drawn see-through in the world (vanilla IsoSprite:RenderGhostTileColor during the world's
--     floor pass, Events.OnPostFloorLayerDraw - read in the 42.21 jar: IsoCell triggers it per layer). Blue = waiting
--     or being built, amber = stuck, red = to be taken down.
--   * BUILDING: an A-Life behaviour module (like work zones). People who live at your base and are home take the
--     top plan they can do (a plan given to someone waits for them first): they need the recipe's tool in their
--     pockets or in storage, the recipe's skill, and the materials. Storage = containers in the base and
--     ghostFetchTiles around it, plus the building stockpiles you marked (right-click a container) within
--     ghostHaulTiles. Materials in a stockpile outside the base are HAULED (and everything for a plan outside the
--     base, an outpost): they walk to the container, take what the job
--     needs into their pockets (a real move), then walk to the plan. They hammer for the
--     recipe's time (slower when only just good enough), making real noise the dead hear (vanilla's addSound, radius
--     20 like vanilla hammering), then the materials are taken for real (drainables lose uses, like vanilla's
--     buildUtil.useDrainable) and vanilla's own build code puts the object up (ISBuildIsoEntity:setInfo).
--   * APPRENTICES: a worker with nothing to do who's less skilled than someone building joins them: the stage goes
--     faster and the helper learns half again as much.
--   * TAKING DOWN: right-click something dismantlable at the base > "Plan: take this down". A builder with a saw and a
--     screwdriver (vanilla ISDismantleAction's tools) takes it apart like vanilla: what was in it on the ground, the
--     materials back (random share, vanilla's getBuildMaterials), stairs / floors as vanilla does them.
--   * REPAIRS: "fix the fence / wall / gate", and on their own (ghostAutoRepair): wooden walls and fences at the base
--     under ghostRepairBelow % health, worst first. 1 plank + 2 nails, a hammer.
--   * WORDS: "get building" / "stop building", "fix the fence", "Sam builds the gate" (gives that plan to Sam).
--   * LAYOUTS: save the plans around you as a layout; stamp it down at your feet somewhere else (Build tab).
-- Multiplayer: plans and orders go through the server (ALifeCmd); the builders run where A-Life drives your settlers
-- (single player; like every other camp job). Settings: ALifeGhostBuild.DEFAULTS.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Ghost") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeGhostBuild"
local M = ALifeLLMTalk
local G = ALifeGhostBuild
if type(M) ~= "table" or type(G) ~= "table" then return end
local TAG = "[ALifeGhost]"
ALifeGhost = ALifeGhost or {}
local K = ALifeGhost
K.VERSION = ALifeSide.MOD_VERSION
G.registerSettings()
K.plans = K.plans or {}
K.layouts = K.layouts or {}
K.piles = K.piles or {}
K.jobs = K.jobs or {}
K.next = K.next or {}
K.saidAt = K.saidAt or {}
K.whoSince = K.whoSince or {}
K.stats = { placed = 0, stages = 0, done = 0, stuck = 0, repairs = 0, hauls = 0, downs = 0, noise = 0, helped = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
-- pre-1.0 MP (P6): the builders (the A-Life module, K.evaluate) run where the world is; on a server "you" = the player
-- being handled, else the camp's player. Placing / drawing / the Build tab stay on your machine (ghostPlace etc. go to
-- the server through ALifeCmd, as before); an MP client keeps asking for the plan list ("ghostAsk").
local function playerOf()
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function pos(o) local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function sqAt(x, y, z) local s = nil; pcall(function() s = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) end); return s end
local function isMP() return ALifeSide.client() end
local function keyDown(f) local ok, v = pcall(function() return f() end); return ok and v == true end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_Ghost_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
local function toast(t) if fn(M, "momToast") then pcall(M.momToast, t) end end
local function nameOf(uid)
    local r = nil
    pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or "Someone"
end
K.nameOf = nameOf

----------------------------------------------------------------------------------------------------------------
-- the plans this client knows (single player: the store itself; multiplayer: the server's answer)
----------------------------------------------------------------------------------------------------------------
function K.refreshPlans(force)
    local t = nowMs()
    if not isMP() then
        K.plans = G.list(); K.layouts = G.layoutNames(); K.piles = G.store().piles
        return K.plans
    end
    if force or t - (K.askedAt or -1e12) > 5000 then
        K.askedAt = t
        local p = playerOf()
        if p and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, p, "ghostAsk", {}) end
    end
    return K.plans
end
K.WHY = { far = "Too far: plan it closer to where you stand.", full = "That's as many as the camp can keep track of.",
    taken = "There's already a plan there.", leader = "Only the base's owner changes the plans.", off = "Ghost build is off (Settings).",
    type = "Unknown kind of build.", gone = "That plan is gone.", edge = "", bad = "Can't plan there.",
    outside = "That's outside your base. (Outposts: Settings > ghost build outside the base.)", line = "Line too long: the rest wasn't planned.",
    empty = "No plans near you to save.", noBase = "You need a base first." }
function K.onList(p)
    if type(p) ~= "table" then return end
    if type(p.list) == "table" then K.plans = p.list end
    if type(p.layouts) == "table" then K.layouts = p.layouts end
    if type(p.piles) == "table" then K.piles = p.piles end
    if p.ok == false and p.why then
        local w = K.WHY[tostring(p.why)]
        if w and w ~= "" then toast(tr("Why_" .. tostring(p.why), w)) end
    end
    if K.win then pcall(function() K.win:refresh() end) end
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("ghostList", function(p) pcall(K.onList, p) end) end
local function send(name, args)
    local p = playerOf()
    if p and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, p, name, args or {}) end
    if not isMP() then K.refreshPlans(true) end
end
K.send = send

----------------------------------------------------------------------------------------------------------------
-- the base (also the shared core's "inside the base" check, here where the base is known)
----------------------------------------------------------------------------------------------------------------
function K.base(player)
    if fn(M, "wzBase") then return M.wzBase(player) end
    if fn(M, "alifeBase") then local ok, b = pcall(M.alifeBase, player); if ok then return b end end
    return nil
end
G.baseOf = function(player) return K.base(player) end
function K.inBase(player, x, y)
    if G.setting("ghostOutside") == true then return true end
    return G.inBase(player, x, y)
end

----------------------------------------------------------------------------------------------------------------
-- the cursor: vanilla's build cursor, no materials needed, placing records a plan; shift = line, ctrl+shift = box
----------------------------------------------------------------------------------------------------------------
-- a straight line from a to b along the longer side (the shorter one is dropped)
function K.lineCells(ax, ay, bx, by)
    local out = {}
    if math.abs(bx - ax) >= math.abs(by - ay) then
        local s = (bx >= ax) and 1 or -1
        for x = ax, bx, s do out[#out + 1] = { x = x, y = ay } end
    else
        local s = (by >= ay) and 1 or -1
        for y = ay, by, s do out[#out + 1] = { x = ax, y = y } end
    end
    return out
end
-- a box around the squares a..b: north-facing walls (nSprite 2) along the top edge and under the bottom row, west-facing
-- (nSprite 1) along the left edge and right of the last column (vanilla nSprite: 1 W, 2 N, 3 E, 4 S)
function K.boxCells(ax, ay, bx, by)
    local x1, x2 = math.min(ax, bx), math.max(ax, bx)
    local y1, y2 = math.min(ay, by), math.max(ay, by)
    local out = {}
    for x = x1, x2 do out[#out + 1] = { x = x, y = y1, nSprite = 2 }; out[#out + 1] = { x = x, y = y2 + 1, nSprite = 2 } end
    for y = y1, y2 do out[#out + 1] = { x = x1, y = y, nSprite = 1 }; out[#out + 1] = { x = x2 + 1, y = y, nSprite = 1 } end
    return out
end
function K.cursorClass()
    if K.Cursor then return K.Cursor end
    if type(ISBuildIsoEntity) ~= "table" or not fn(ISBuildIsoEntity, "derive") then return nil end
    local C = ISBuildIsoEntity:derive("ALifeGhostCursor")
    function C:haveMaterial() return true end
    function C:isValid(square)
        if square == nil then return false end
        local p = getSpecificPlayer(self.player)
        local r = G.num("ghostRange")
        if p and d2(p:getX(), p:getY(), square:getX(), square:getY()) > r * r then return false end
        if p and not self.ghostOnly and not K.inBase(p, square:getX(), square:getY()) then return false end
        local here = G.at(square:getX(), square:getY(), square:getZ())
        if isMP() then
            for _, pl in ipairs(K.plans) do if pl.x == square:getX() and pl.y == square:getY() and pl.z == square:getZ() and pl.nSprite == self.nSprite and pl.kind ~= "down" then return false end end
        elseif here and here.nSprite == self.nSprite and here.kind ~= "down" then return false end
        if self.ghostOnly then return true end -- finishing a later stage: vanilla's checks only
        return ISBuildIsoEntity.isValid(self, square)
    end
    function C:tryBuild(x, y, z)
        local shift = keyDown(isShiftKeyDown)
        if shift and K.anchor == nil then
            K.anchor = { x = x, y = y, z = z }
            toast(tr("LineStart", "Start set. Shift-click the end for a line, Ctrl+Shift for a box."))
            return nil
        end
        if shift and K.anchor then
            local a = K.anchor
            K.anchor = nil
            K.placeMany(self, a, x, y, z, keyDown(isCtrlKeyDown))
            return nil
        end
        local sprite = self:getSprite()
        send("ghostPlace", { type = self.ghostType, x = x, y = y, z = z, nSprite = self.nSprite, north = self.north == true, sprite = sprite })
        K.stats.placed = K.stats.placed + 1
        return nil
    end
    K.Cursor = C
    return C
end
-- a line / box: every cell checked with vanilla's own placement rules first (with its own facing for a box)
function K.placeMany(cur, a, x, y, z, box)
    local p = playerOf()
    if p == nil then return 0 end
    local cells = box and K.boxCells(a.x, a.y, x, y) or K.lineCells(a.x, a.y, x, y)
    local byFacing = {}
    local out = {}
    for _, c in ipairs(cells) do
        local ns = c.nSprite or cur.nSprite
        local cc = byFacing[ns]
        if cc == nil then
            if ns == cur.nSprite then cc = cur else cc = K.newCursor(p, cur.ghostType, 1, ns) or false end
            byFacing[ns] = cc
        end
        local sq = sqAt(c.x, c.y, a.z)
        if cc and sq then
            local spr = nil
            pcall(function() spr = cc:getSprite() end)
            local ok, valid = pcall(function() return cc:isValid(sq) end)
            if ok and valid then out[#out + 1] = { x = c.x, y = c.y, z = a.z, nSprite = cc.nSprite, sprite = spr } end
        end
    end
    if #out == 0 then toast(tr("LineNone", "Nothing in that line can go there.")); return 0 end
    send("ghostPlaceMany", { type = cur.ghostType, z = a.z, cells = out })
    K.stats.placed = K.stats.placed + #out
    toast(tr("LineDone", "Planned {1} ({2} squares were blocked).", #out, #cells - #out))
    return #out
end
function K.newCursor(player, typeId, stageIndex, nSprite)
    local C = K.cursorClass()
    local t = G.typeOf(typeId)
    if C == nil or t == nil then return nil end
    local info = G.infoOf(t.stages[stageIndex or 1])
    if info == nil then return nil end
    local containers = {}
    pcall(function() containers = ISInventoryPaneContextMenu.getContainers(player) end)
    local c = nil
    local ok, err = pcall(function() c = C:new(player, info, nSprite or 1, containers) end)
    if not ok or c == nil then log("cursor failed: " .. tostring(err)); return nil end
    c.player = player:getPlayerNum()
    c.ghostType = typeId
    c.dragNilAfterPlace = false
    return c
end
function K.place(typeId)
    local p = playerOf()
    if p == nil then return false end
    if G.setting("ghostBuild") == false then toast(tr("Off", "Ghost build is off (Settings).")); return false end
    local c = K.newCursor(p, typeId, 1, 1)
    if c == nil then toast(tr("NoInfo", "Can't read the game's build list for that.")); return false end
    K.anchor = nil
    pcall(function() getCell():setDrag(c, p:getPlayerNum()) end)
    toast(tr("Placing", "Click to plan it, R turns it, keep clicking for more. Shift-click start and end for a line (Ctrl+Shift: a box). Right-click or Esc to stop. No materials needed now."))
    return true
end

----------------------------------------------------------------------------------------------------------------
-- seeing them: see-through, during the world's floor pass
----------------------------------------------------------------------------------------------------------------
K.spriteCache, K.isoSprites = K.spriteCache or {}, K.isoSprites or {}
-- the finished look (last stage) for this facing
function K.spriteFor(plan)
    if plan.kind == "down" then return plan.sprite end
    local key = tostring(plan.type) .. ":" .. tostring(plan.nSprite)
    if K.spriteCache[key] ~= nil then return K.spriteCache[key] or nil end
    local s = nil
    local p = playerOf()
    local t = G.typeOf(plan.type)
    if p and t then
        local c = K.newCursor(p, plan.type, #t.stages, plan.nSprite)
        if c then pcall(function() s = c:getSprite() end) end
    end
    s = s or plan.sprite
    K.spriteCache[key] = s or false
    return s
end
local function isoSprite(name)
    local s = K.isoSprites[name]
    if s == nil then
        pcall(function() s = IsoSprite.new(); s:LoadSingleTexture(name) end)
        K.isoSprites[name] = s or false
    end
    return s or nil
end
function K.drawLayer(z)
    if G.setting("ghostBuild") == false or #K.plans == 0 then return end
    local p = playerOf()
    if p == nil then return end
    local px, py = p:getX(), p:getY()
    for _, plan in ipairs(K.plans) do
        if plan.z == z and d2(px, py, plan.x, plan.y) <= 60 * 60 then
            local name = K.spriteFor(plan)
            local s = name and isoSprite(name)
            if s then
                local r, g, b = 0.55, 0.75, 1.0
                if plan.kind == "down" then r, g, b = 1.0, 0.35, 0.3
                elseif plan.state == "blocked" then r, g, b = 1.0, 0.7, 0.3 end
                pcall(function() s:RenderGhostTileColor(plan.x, plan.y, plan.z, r, g, b, 0.45) end)
            end
        end
    end
end
if type(Events) == "table" and Events.OnPostFloorLayerDraw ~= nil then
    Events.OnPostFloorLayerDraw.Add(function(z) local ok, e = pcall(K.drawLayer, z); if not ok and not K.drawWarned then K.drawWarned = true; log("draw failed: " .. tostring(e)) end end)
end

----------------------------------------------------------------------------------------------------------------
-- builders: skill, tools, materials
----------------------------------------------------------------------------------------------------------------
-- Woodwork-like level 0..10: camp builder fit (who they were / are: 0.3..1.6 -> 1..8), A-Life companion carpentry,
-- + what they learned building here (bucket ghostXp: a level per 100)
function K.skillOf(uid)
    uid = tostring(uid)
    local lvl = 3
    if fn(M, "cpFit") then local ok, f = pcall(M.cpFit, uid, "builder"); if ok and tonumber(f) then lvl = math.floor(tonumber(f) * 5 + 0.5) end end
    pcall(function()
        local snap = PA().Companions.snapshot(uid)
        local c = snap and snap.skills and tonumber(snap.skills.carpentry)
        if c and c > lvl then lvl = math.floor(c) end
    end)
    local xp = M.bucket and tonumber((M.bucket("ghostXp") or {})[uid]) or 0
    lvl = lvl + math.min(4, math.floor((xp or 0) / 100))
    if lvl < 0 then lvl = 0 elseif lvl > 10 then lvl = 10 end
    return lvl
end
function K.addXp(uid, n)
    if not M.bucket then return end
    local b = M.bucket("ghostXp")
    local before = math.floor((tonumber(b[tostring(uid)]) or 0) / 100)
    b[tostring(uid)] = (tonumber(b[tostring(uid)]) or 0) + n
    local after = math.floor(b[tostring(uid)] / 100)
    if after > before and after <= 4 and fn(M, "histAdd") then pcall(M.histAdd, tostring(uid), "skill", "Got better at building") end
end
-- containers in the base and around it (rescanned every 15 s), then the building stockpiles near the base
local function containerOn(sq)
    local c = nil
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if not instanceof(o, "IsoDeadBody") then local cc = o:getContainer(); if cc ~= nil then c = cc; return end end
        end
    end)
    return c
end
K.containerOn = containerOn
function K.containers(b)
    if b == nil then return {} end
    local t = nowMs()
    if K.cScan and K.cScan.key == b.key and t - K.cScan.at < 15000 then return K.cScan.list end
    local pad = math.floor(G.num("ghostFetchTiles"))
    local out = {}
    for zz = 0, 1 do
        for x = b.x1 - pad, b.x2 + pad do
            for y = b.y1 - pad, b.y2 + pad do
                local sq = sqAt(x, y, zz)
                local c = sq and containerOn(sq)
                if c then out[#out + 1] = { c = c, x = x, y = y, z = zz } end
            end
        end
    end
    local haul = G.num("ghostHaulTiles")
    local bx, by = b.x or math.floor((b.x1 + b.x2) / 2), b.y or math.floor((b.y1 + b.y2) / 2)
    for _, pl in ipairs(K.piles or {}) do
        local inBox = pl.x >= b.x1 - pad and pl.x <= b.x2 + pad and pl.y >= b.y1 - pad and pl.y <= b.y2 + pad and (pl.z or 0) <= 1
        if not inBox and d2(pl.x, pl.y, bx, by) <= haul * haul then
            local sq = sqAt(pl.x, pl.y, pl.z or 0)
            local c = sq and containerOn(sq)
            if c then out[#out + 1] = { c = c, x = pl.x, y = pl.y, z = pl.z or 0, pile = true } end
        end
    end
    K.cScan = { key = b.key, at = t, list = out }
    return out
end
local function invOf(sh) local inv = nil; pcall(function() inv = sh:getInventory() end); return inv end
local function countIn(c, types)
    local n = 0
    if c == nil then return 0 end
    for _, ty in ipairs(types) do pcall(function() n = n + (tonumber(c:getCountTypeRecurse(ty)) or 0) end) end
    return n
end
-- uses left in drainables of these types (a propane torch, paint, glue)
local function usesIn(c, types)
    local n = 0
    if c == nil then return 0 end
    for _, ty in ipairs(types) do
        pcall(function()
            local all = c:getAllTypeRecurse(ty)
            for i = 0, all:size() - 1 do n = n + (tonumber(all:get(i):getCurrentUses()) or 0) end
        end)
    end
    return n
end
local function amountIn(c, e) if e.uses then return usesIn(c, e.types) end return countIn(c, e.types) end
local function hasIn(c, types)
    if c == nil then return false end
    for _, ty in ipairs(types) do local ok, yes = pcall(function() return c:containsTypeRecurse(ty) end); if ok and yes then return true end end
    return false
end
-- what's missing for a stage: tools (list of words), items { { types, n } }; nil, nil = all there
function K.check(cost, shell, list)
    local inv = invOf(shell)
    local toolsMissing, itemsMissing = {}, {}
    for _, group in ipairs(cost.tools or {}) do
        local have = hasIn(inv, group)
        if not have then for _, e in ipairs(list) do if hasIn(e.c, group) then have = true; break end end end
        if not have then toolsMissing[#toolsMissing + 1] = G.itemWord(group[1]) end
    end
    for _, need in ipairs(cost.items or {}) do
        local n = amountIn(inv, need)
        for _, e in ipairs(list) do if n >= need.n then break end; n = n + amountIn(e.c, need) end
        if n < need.n then itemsMissing[#itemsMissing + 1] = { types = need.types, n = need.n - n, uses = need.uses } end
    end
    if #toolsMissing == 0 and #itemsMissing == 0 then return nil, nil end
    return toolsMissing, itemsMissing
end
-- take n of these types: their pockets first, then the containers (real removal, synced like vanilla's build code)
function K.take(types, n, shell, list)
    local taken = {}
    local sources = { invOf(shell) }
    for _, e in ipairs(list) do sources[#sources + 1] = e.c end
    for _, c in ipairs(sources) do
        if n <= 0 then break end
        for _, ty in ipairs(types) do
            while n > 0 do
                local it = nil
                pcall(function() it = c:getFirstTypeRecurse(ty) end)
                if it == nil then break end
                local from = nil
                pcall(function() from = it:getContainer() end)
                from = from or c
                local ok = pcall(function() from:Remove(it) end)
                if not ok then break end
                pcall(sendRemoveItemFromContainer, from, it)
                taken[#taken + 1] = ty
                n = n - 1
            end
        end
    end
    return taken, n
end
-- use n uses of drainables of these types (vanilla buildUtil.useDrainable: UseAndSync per use); pockets first
function K.drain(types, n, shell, list)
    local sources = { invOf(shell) }
    for _, e in ipairs(list) do sources[#sources + 1] = e.c end
    for _, c in ipairs(sources) do
        if n <= 0 then break end
        for _, ty in ipairs(types) do
            if n <= 0 then break end
            pcall(function()
                local all = c:getAllTypeRecurse(ty)
                for i = 0, all:size() - 1 do
                    if n <= 0 then break end
                    local it = all:get(i)
                    local used = 0
                    if type(buildUtil) == "table" and fn(buildUtil, "useDrainable") then used = buildUtil.useDrainable(it, n)
                    else
                        local k = math.min(n, tonumber(it:getCurrentUses()) or 0)
                        for _ = 1, k do it:UseAndSync() end
                        used = k
                    end
                    n = n - (tonumber(used) or 0)
                end
            end)
        end
    end
    return n
end
-- hauling: what of this cost has to be carried: from a building stockpile (outside the base), or anything at all for a
-- plan outside the base (an outpost). Inside the base, its own storage is within reach as before.
-- returns { { e = container entry, types, n, uses, tool } } in walking order, nil when nothing needs carrying
function K.haulList(cost, shell, list, tx, ty, b)
    local inv = invOf(shell)
    local out = {}
    local pad = G.num("ghostBaseTiles")
    local planIn = b == nil or (tx >= b.x1 - pad and tx <= b.x2 + pad and ty >= b.y1 - pad and ty <= b.y2 + pad)
    local function near(e) return planIn and not e.pile end
    for _, group in ipairs(cost.tools or {}) do
        if not hasIn(inv, group) then
            local closeOne = false
            for _, e in ipairs(list) do if near(e) and hasIn(e.c, group) then closeOne = true; break end end
            if not closeOne then
                for _, e in ipairs(list) do if hasIn(e.c, group) then out[#out + 1] = { e = e, types = group, n = 1, tool = true }; break end end
            end
        end
    end
    for _, need in ipairs(cost.items or {}) do
        local n = amountIn(inv, need)
        for _, e in ipairs(list) do if near(e) then n = n + amountIn(e.c, need) end end
        local left = need.n - n
        for _, e in ipairs(list) do
            if left <= 0 then break end
            if not near(e) then
                local here = amountIn(e.c, need)
                if here > 0 then
                    local take = math.min(here, left)
                    out[#out + 1] = { e = e, types = need.types, n = take, uses = need.uses }
                    left = left - take
                end
            end
        end
    end
    if #out == 0 then return nil end
    return out
end
-- move items from a container into the builder's pockets (a real move, synced like vanilla's transfers)
function K.carry(item, shell)
    local inv = invOf(shell)
    if inv == nil then return 0 end
    local moved = 0
    local function moveOne(it)
        local from = nil
        pcall(function() from = it:getContainer() end)
        if from == nil then return false end
        local ok = pcall(function() from:Remove(it) end)
        if not ok then return false end
        pcall(sendRemoveItemFromContainer, from, it)
        pcall(function() inv:AddItem(it) end)
        pcall(sendAddItemToContainer, inv, it)
        return true
    end
    for _, ty in ipairs(item.types) do
        if item.uses or item.tool then -- a drainable or a tool: carry one whole item (it comes back with them)
            local it = nil
            pcall(function() it = item.e.c:getFirstTypeRecurse(ty) end)
            if it and moveOne(it) then return 1 end
        else
            while moved < item.n do
                local it = nil
                pcall(function() it = item.e.c:getFirstTypeRecurse(ty) end)
                if it == nil or not moveOne(it) then break end
                moved = moved + 1
            end
            if moved >= item.n then break end
        end
    end
    return moved
end

----------------------------------------------------------------------------------------------------------------
-- finishing a stage: vanilla's own build code puts it up
----------------------------------------------------------------------------------------------------------------
function K.putUp(plan, stageIndex, consumed)
    local p = playerOf()
    if p == nil then return false, "no player" end
    local c = K.newCursor(p, plan.type, stageIndex, plan.nSprite)
    if c == nil then return false, "no info" end
    c.ghostOnly = false
    local sq = sqAt(plan.x, plan.y, plan.z)
    if sq == nil then return false, "no square" end
    c:getSprite()
    local okV, valid = pcall(function() return ISBuildIsoEntity.isValid(c, sq) end)
    if not okV or not valid then return false, "blocked" end
    for _, ty in ipairs(consumed or {}) do c.modData["need:" .. ty] = (c.modData["need:" .. ty] or 0) + 1 end -- dismantle refunds, as vanilla records them
    local ok, err = pcall(function()
        local face = c:getFace()
        local openFace = c:getOpenFace(c.north)
        if openFace and (openFace:getWidth() ~= face:getWidth() or openFace:getHeight() ~= face:getHeight()) then openFace = nil end
        for zz = 0, face:getzLayers() - 1 do
            for xx = 0, face:getWidth() - 1 do
                for yy = 0, face:getHeight() - 1 do
                    local tileInfo = face:getTileInfo(xx, yy, zz)
                    local openTileInfo = openFace and openFace:getTileInfo(xx, yy, zz)
                    local s2 = getCell():getGridSquare(plan.x + xx, plan.y + yy, plan.z + zz)
                    if s2 and tileInfo and tileInfo:getSpriteName() then
                        c:setInfo(s2, c.north, tileInfo:getSpriteName(), openTileInfo and openTileInfo:getSpriteName() or false)
                    end
                end
            end
        end
    end)
    if not ok then log("put up failed: " .. tostring(err)); return false, "error" end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- noise: hammering / sawing / welding is loud (vanilla addSound, the radius vanilla hammering uses)
----------------------------------------------------------------------------------------------------------------
function K.noise(shell, x, y, z, now)
    if G.setting("ghostNoise") == false then return false end
    local key = tostring(shell)
    K.noiseAt = K.noiseAt or {}
    if now - (K.noiseAt[key] or -1e12) < 8000 then return false end
    K.noiseAt[key] = now
    local r = G.num("ghostNoiseTiles")
    local ok = pcall(function() addSound(shell, math.floor(x), math.floor(y), math.floor(z or 0), r, r) end)
    if ok then K.stats.noise = K.stats.noise + 1 end
    return ok
end

----------------------------------------------------------------------------------------------------------------
-- taking down: vanilla's ISDismantleAction (a saw and a screwdriver; contents and materials onto the ground)
----------------------------------------------------------------------------------------------------------------
local function notBroken(it) return not it:isBroken() end
local function hasTag(c, tagName, fallbackTypes)
    if c == nil then return false end
    local ok, yes = pcall(function() return c:containsTagEval(ItemTag[tagName], notBroken) end)
    if ok and yes then return true end
    return hasIn(c, fallbackTypes)
end
K.DOWN_TOOLS = { { tag = "SAW", word = "a saw", types = { "Base.Saw", "Base.GardenSaw", "Base.SmallSaw" } },
    { tag = "SCREWDRIVER", word = "a screwdriver", types = { "Base.Screwdriver" } } }
function K.downTools(shell, list)
    local missing = {}
    for _, t in ipairs(K.DOWN_TOOLS) do
        local have = hasTag(invOf(shell), t.tag, t.types)
        if not have then for _, e in ipairs(list) do if hasTag(e.c, t.tag, t.types) then have = true; break end end end
        if not have then missing[#missing + 1] = t.word end
    end
    return missing
end
function K.downTarget(plan)
    local sq = sqAt(plan.x, plan.y, plan.z)
    if sq == nil then return nil end
    local found = nil
    pcall(function()
        local objs = sq:getSpecialObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if instanceof(o, "IsoThumpable") and tostring(o:getName() or "") == tostring(plan.obj or "") then found = o; return end
        end
    end)
    return found
end
-- vanilla ISDismantleAction:complete, line by line
function K.dismantle(o)
    local sq = o:getSquare()
    pcall(function()
        if o:getContainer() and o:getContainer():getItems() then
            local items = o:getContainer():getItems()
            for i = 0, items:size() - 1 do sq:AddWorldInventoryItem(items:get(i), 0.0, 0.0, 0.0) end
        end
    end)
    pcall(function()
        for ty, v in pairs(o:getBuildMaterials()) do
            if ty == "Base.Torch" then
                o:toggleLightSource(false)
                local item = instanceItem(ty)
                if item then item:setUsedDelta(0); sq:AddWorldInventoryItem(item, 0, 0, 0) end
                item = o:removeCurrentFuel(nil)
                if item then sq:AddWorldInventoryItem(item, 0, 0, 0) end
            else
                local count = ZombRand(tonumber(v) or 1) + 1
                for _ = 1, count do sq:AddWorldInventoryItem(ty, 0, 0, 0) end
            end
        end
    end)
    local stairs = {}
    pcall(function() stairs = buildUtil.getStairObjects(o) end)
    if type(stairs) == "table" and #stairs > 0 then
        for i = 1, #stairs do pcall(function() stairs[i]:getSquare():transmitRemoveItemFromSquare(stairs[i]) end) end
        return true
    end
    local isFloor = false
    pcall(function() isFloor = sq:getZ() <= 0 and (o:isFloor() or (o:getSprite() and o:getSprite():getProperties():has(IsoFlagType.solidfloor))) end)
    if isFloor then
        pcall(function()
            local floor = sq:getFloor()
            if floor then
                floor:setSpriteFromName("blends_natural_01_64")
                if ALifeSide.client() then floor:transmitUpdatedSpriteToServer() end
                if ALifeSide.server() then floor:transmitUpdatedSpriteToClients() end
            end
        end)
        return true
    end
    local ok = pcall(function() sq:transmitRemoveItemFromSquare(o) end)
    return ok
end

----------------------------------------------------------------------------------------------------------------
-- the job: pick, (haul), walk, work, finish
----------------------------------------------------------------------------------------------------------------
K.paused = K.paused or false
local function builders()
    local n = 0
    for _, j in pairs(K.jobs) do if not j.helps then n = n + 1 end end
    return n
end
local function claimedBy(id) for uid, j in pairs(K.jobs) do if j.id == id and not j.helps then return uid end end return nil end
function K.release(uid, shell)
    local j = K.jobs[tostring(uid)]
    K.jobs[tostring(uid)] = nil
    if j and j.planRef then
        if j.helps then
            if j.planRef.helper == tostring(uid) then j.planRef.helper = nil end
        else
            j.planRef.builder = nil
            if j.planRef.state == "building" then j.planRef.state = "waiting" end
        end
    end
    local anim = PA().Animations
    if shell and fn(anim, "clear") then pcall(anim.clear, shell) end
end
-- a stuck plan: say it once, one letter (ghostAskMin apart)
function K.stuck(plan, uid, shell, why, needText)
    plan.state, plan.why = "blocked", why
    K.stats.stuck = K.stats.stuck + 1
    local key = plan.id .. ":" .. why
    local t = nowMs()
    if t - (K.saidAt[key] or -1e12) < G.num("ghostAskMin") * 60000 then return end
    K.saidAt[key] = t
    local t2 = G.TYPES[plan.type]
    local what = plan.kind == "down" and tostring(plan.label or "that") or (t2 and string.lower(t2.label) or "plan")
    local line = needText and tr("SayNeed", "Can't do the {1}. We need {2}.", what, needText) or tr("Say_" .. why, why)
    local p = playerOf()
    if shell and fn(M, "say") and p then pcall(M.say, shell, p, line) end
    if G.setting("ghostLetters") ~= false and type(ALifeLetter) == "function" and p then
        pcall(ALifeLetter, p, tr("LetterStuck", "Building: the {1} is stuck. {2}", what, needText and tr("Needs", "Needs {1} in base storage.", needText) or line), 242, 200, 120)
    end
    -- A-Life's own scavengers look for tools / nails when they go out (their "wanted" list; unverified for settlers)
    if needText and uid then pcall(function() PA().Talk.writeMemory(tostring(uid), function(m) m.scavengeWanted = "tools" end) end) end
end
-- may this person take this plan? (given to someone else: wait for them ghostAssignWaitMin, then anyone)
function K.mayTake(plan, uid)
    if plan.who == nil or plan.who == uid then return true end
    local now = nowMs()
    if K.whoSince[plan.id] == nil then K.whoSince[plan.id] = now end
    return now - K.whoSince[plan.id] >= G.num("ghostAssignWaitMin") * 60000
end
function K.pickDown(plan, uid, shell, cs)
    local o = K.downTarget(plan)
    if o == nil then -- already gone: done
        local _, i = G.byId(plan.id)
        if i then table.remove(G.store().list, i); G.transmit() end
        return nil
    end
    local miss = K.downTools(shell, cs)
    if #miss > 0 then
        K.stuck(plan, uid, shell, "materials", table.concat(miss, ", "))
        plan.retryAt = nowMs() + 30000
        return nil
    end
    plan.state, plan.why, plan.builder = "building", nil, tostring(uid)
    return { id = plan.id, planRef = plan, down = true, cost = { time = 200 }, skill = 5, need = 0, started = nowMs() }
end
function K.pick(uid, shell, player, b)
    if K.paused or builders() >= G.num("ghostBuilders") then return nil end
    local list = G.store().list
    if #list == 0 then return nil end
    local cs = K.containers(b)
    local skill = K.skillOf(uid)
    for _, plan in ipairs(list) do
        local t = G.typeOf(plan.type)
        if (t or plan.kind == "down") and not claimedBy(plan.id) and (plan.retryAt or 0) <= nowMs() and K.mayTake(plan, uid) then
            local near = b == nil or d2(plan.x, plan.y, b.x or plan.x, b.y or plan.y) <= G.num("ghostRange") ^ 2
            if plan.kind == "down" then
                if near then local j = K.pickDown(plan, uid, shell, cs); if j then return j end end
            else
                local stageName = t.stages[plan.stage] or t.stages[#t.stages]
                local cost = G.costOf(stageName)
                if cost and near then
                    local need = cost.skill and tonumber(cost.skill[2]) or 0
                    if skill < need then
                        plan.why, plan.state = "skill", "blocked"
                    else
                        local tools, items = K.check(cost, shell, cs)
                        if tools == nil and items == nil then
                            plan.state, plan.why, plan.need, plan.builder = "building", nil, nil, tostring(uid)
                            local j = { id = plan.id, planRef = plan, stageName = stageName, cost = cost, skill = skill, need = need, started = nowMs() }
                            j.haul = K.haulList(cost, shell, cs, plan.x, plan.y, b)
                            return j
                        end
                        plan.need = items
                        local text = (#items > 0) and G.needText(items) or nil
                        if #tools > 0 then text = (text and (text .. ", ") or "") .. table.concat(tools, ", ") end
                        K.stuck(plan, uid, shell, "materials", text)
                        plan.retryAt = nowMs() + 30000
                    end
                end
            end
        end
    end
    return nil
end
-- an apprentice: someone with nothing to do, less skilled than a builder at work, goes to help
function K.pickHelp(uid, shell)
    if G.setting("ghostApprentice") == false or K.paused then return nil end
    local mine = K.skillOf(uid)
    for buid, j in pairs(K.jobs) do
        if not j.helps and not j.down and j.planRef and j.planRef.helper == nil and buid ~= uid and (j.skill or 0) > mine then
            j.planRef.helper = tostring(uid)
            return { helps = buid, id = j.id, planRef = j.planRef, started = nowMs() }
        end
    end
    return nil
end
-- real time for this stage: recipe time x ghostTimeMs, slower when only just able, faster when good
function K.stageMs(j)
    local diff = (j.skill or 0) - (j.need or 0)
    local f = 1.6 - 0.12 * diff
    if f < 0.5 then f = 0.5 elseif f > 2.0 then f = 2.0 end
    return math.floor((tonumber(j.cost.time) or 200) * G.num("ghostTimeMs") * f)
end
function K.finish(j, uid, shell, b)
    local plan = j.planRef
    local cs = K.containers(b)
    if j.down then
        local o = K.downTarget(plan)
        if o and K.dismantle(o) then K.stats.downs = K.stats.downs + 1 end
        local _, i = G.byId(plan.id)
        if i then table.remove(G.store().list, i) end
        if fn(M, "histAdd") then pcall(M.histAdd, tostring(uid), "work", "Took down a " .. string.lower(tostring(plan.label or "thing")) .. " at the base") end
        G.transmit()
        return true
    end
    local tools, items = K.check(j.cost, shell, cs)
    if tools ~= nil or items ~= nil then
        local text = items and #items > 0 and G.needText(items) or nil
        K.stuck(plan, uid, shell, "materials", text)
        return false
    end
    local consumed = {}
    for _, need in ipairs(j.cost.items or {}) do
        if need.uses then K.drain(need.types, need.n, shell, cs)
        else
            local got = K.take(need.types, need.n, shell, cs)
            for _, ty in ipairs(got) do consumed[#consumed + 1] = ty end
        end
    end
    -- only just good enough: may waste one more of the first counted material (if there is one)
    local first = nil
    for _, need in ipairs(j.cost.items or {}) do if not need.uses then first = need; break end end
    if (j.skill or 0) - (j.need or 0) <= 1 and first then
        local roll = 100
        pcall(function() roll = ZombRand(100) end)
        if roll < G.num("ghostWasteChance") then K.take(first.types, 1, shell, cs) end
    end
    local ok, why = K.putUp(plan, plan.stage, consumed)
    if not ok then
        K.stuck(plan, uid, shell, why == "blocked" and "blocked" or "error", nil)
        plan.retryAt = nowMs() + 60000
        return false
    end
    K.stats.stages = K.stats.stages + 1
    local xp = math.floor((tonumber(j.cost.time) or 200) / 10)
    K.addXp(uid, xp)
    if plan.helper and K.jobs[plan.helper] and K.jobs[plan.helper].atSite then
        K.addXp(plan.helper, math.floor(xp * 1.5))
        K.stats.helped = K.stats.helped + 1
    end
    local t = G.typeOf(plan.type)
    if plan.stage >= #t.stages then
        local _, i = G.byId(plan.id)
        if i then table.remove(G.store().list, i) end
        K.stats.done = K.stats.done + 1
        K.whoSince[plan.id] = nil
        if fn(M, "histAdd") then pcall(M.histAdd, tostring(uid), "work", "Built a " .. string.lower(t.label) .. " at the base") end
        if G.setting("ghostLetters") ~= false and #G.store().list == 0 and playerOf() then
            pcall(ALifeSide.outLetter, playerOf(), tr("AllDone", "Building: every plan is done."), 150, 220, 150)
        end
    else
        plan.stage, plan.work, plan.state, plan.why = plan.stage + 1, 0, "waiting", nil
    end
    G.transmit()
    return true
end
-- walk somewhere (A-Life movement); returns the A-Life answer
local function walk(context, actor, shell, x, y, z)
    if not fn(context, "startMovement") then return nil end
    return context.startMovement(actor, shell, { x = x + 0.5, y = y + 0.5, z = z or 0 }, "chatplus_ghost", { pace = "walk", timeoutMs = 15000, tolerance = 1.2 })
end
function K.evaluate(actor, shell, context)
    if shell == nil or type(context) ~= "table" or type(actor) ~= "table" or G.setting("ghostBuild") == false then return nil end
    local uid = tostring(actor.uid)
    local j = K.jobs[uid]
    local player = playerOf()
    if j == nil and #G.store().list == 0 and K.repairWant == nil and G.setting("ghostAutoRepair") == false then return nil end
    if context.threat ~= nil then if j then K.release(uid, shell) end; return nil end -- zombies: stop, the frame stays
    if fn(M, "alHolds") and M.alHolds(uid, player) then if j then K.release(uid, shell) end; return nil end
    if not (fn(M, "wzIsWorker") and M.wzIsWorker(uid, player)) then if j then K.release(uid, shell) end; return nil end
    local now = tonumber(context.now) or nowMs()
    local b = K.base(player)
    if j == nil then
        if (K.next[uid] or 0) > now then return nil end
        K.autoRepair(b, now)
        j = K.repairPick(uid, shell, b) or K.pick(uid, shell, player, b) or K.pickHelp(uid, shell)
        if j == nil then K.next[uid] = now + 10000; return nil end
        K.jobs[uid] = j
    end
    local sx, sy = pos(shell)
    if sx == nil then K.release(uid, shell); return nil end
    -- an apprentice: stand by the builder's plan while the builder works
    if j.helps then
        local bj = K.jobs[j.helps]
        if bj == nil or bj.id ~= j.id then K.release(uid, shell); return nil end
        local p = j.planRef
        if d2(sx, sy, p.x + 1.5, p.y + 0.5) > 1.8 ^ 2 then
            j.atSite = nil
            if now - j.started > 90000 then K.release(uid, shell); return nil end
            return walk(context, actor, shell, p.x + 1, p.y, p.z) or (function() K.release(uid, shell); return nil end)()
        end
        j.atSite = true
        local anim = PA().Animations
        if fn(anim, "apply") then pcall(anim.apply, shell, "build_crate") end
        return { kind = "idle", intent = "chatplus_ghost", cooldownUntilMs = now + 1000 }
    end
    -- hauling: to each container in turn, take what the job needs into their pockets
    if j.haul and #j.haul > 0 then
        local h = j.haul[1]
        if d2(sx, sy, h.e.x + 0.5, h.e.y + 0.5) > 1.8 ^ 2 then
            if now - j.started > 180000 then if j.planRef then j.planRef.retryAt = now + 120000 end; K.release(uid, shell); return nil end
            return walk(context, actor, shell, h.e.x, h.e.y, h.e.z) or (function() K.release(uid, shell); return nil end)()
        end
        K.carry(h, shell)
        K.stats.hauls = K.stats.hauls + 1
        table.remove(j.haul, 1)
        j.started = now -- the walk to the plan starts now
        return { kind = "idle", intent = "chatplus_ghost", cooldownUntilMs = now + 800 }
    end
    local tx, ty, tz = j.x or j.planRef.x, j.y or j.planRef.y, j.z or j.planRef.z
    if d2(sx, sy, tx + 0.5, ty + 0.5) > 1.8 ^ 2 then
        j.workFrom = nil
        if now - j.started > 90000 then if j.planRef then j.planRef.retryAt = now + 120000 end; K.release(uid, shell); return nil end
        return walk(context, actor, shell, tx, ty, tz) or (function() K.release(uid, shell); return nil end)()
    end
    local anim = PA().Animations
    if fn(anim, "apply") then pcall(anim.apply, shell, j.down and "saw" or "build_crate") end
    if fn(context, "setActivity") then pcall(context.setActivity, actor, "idle", "chatplus_ghost") end
    K.noise(shell, tx, ty, tz, now)
    local last = j.workFrom or now
    j.workFrom = now
    if j.planRef then
        local step = math.max(0, math.min(5000, now - last))
        local helper = j.planRef.helper and K.jobs[j.planRef.helper]
        if helper and helper.atSite then step = math.floor(step * 1.3) end
        j.planRef.work = (tonumber(j.planRef.work) or 0) + step
        if j.planRef.work < K.stageMs(j) then return { kind = "idle", intent = "chatplus_ghost", cooldownUntilMs = now + 1000 } end
        local ok, err = pcall(K.finish, j, uid, shell, b)
        if not ok then log("finish error: " .. tostring(err)) end
    else
        j.work = (j.work or 0) + math.max(0, math.min(5000, now - last))
        if j.work < 15000 then return { kind = "idle", intent = "chatplus_ghost", cooldownUntilMs = now + 1000 } end
        pcall(K.repairDo, j, uid, shell, b)
    end
    if j.planRef and j.planRef.helper then
        local hj = K.jobs[j.planRef.helper]
        if hj and hj.helps == uid then K.release(j.planRef.helper, nil) end
    end
    K.release(uid, shell)
    return { kind = "idle", intent = "chatplus_ghost", cooldownUntilMs = now + 1500 }
end
function K.register()
    if K.registered then return true end
    local reg = PA().ModuleRegistry
    if not fn(reg, "register") then return false end
    local ok, done, why = pcall(reg.register, { id = "chatplus_ghost", label = "NPC Overhaul: ghost build",
        summary = "People at your base build the plans you placed, from base storage, with real tools and skill.",
        kind = "orders", priority = 91, defaultEnabled = true,
        evaluate = function(actor, shell, context)
            local ok2, res = pcall(K.evaluate, actor, shell, context)
            if not ok2 then if not K.err then K.err = true; log("module error (logged once): " .. tostring(res)) end; return nil end
            return res
        end })
    if ok and (done == true or (done == false and tostring(why):find("duplicate", 1, true))) then
        local prof = PA().BehaviorProfiles
        if type(prof) == "table" and type(prof.definitions) == "table" then
            for _, def in ipairs(prof.definitions) do if type(def) == "table" and type(def.overlays) == "table" then def.overlays.chatplus_ghost = true end end
        end
        K.registered = true
        return true
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- repairs: "fix the fence" -> the most damaged one of those at the base; on their own: wooden walls / fences under
-- ghostRepairBelow %, worst first. 1 plank + 2 nails, a hammer.
----------------------------------------------------------------------------------------------------------------
K.REPAIR = { items = { { types = { "Base.Plank" }, n = 1 }, { types = { "Base.Nails" }, n = 2 } }, tools = { { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" } } }
-- wood that a plank and nails can mend (metal, brick, sandbags and wire can't be)
function K.woodName(nm)
    nm = string.lower(tostring(nm or ""))
    if string.find(nm, "metal", 1, true) or string.find(nm, "sandbag", 1, true) or string.find(nm, "barbed", 1, true) or string.find(nm, "brick", 1, true) or string.find(nm, "stone", 1, true) then return false end
    return string.find(nm, "wood", 1, true) ~= nil or string.find(nm, "log", 1, true) ~= nil or string.find(nm, "fence", 1, true) ~= nil
        or string.find(nm, "wall", 1, true) ~= nil or string.find(nm, "gate", 1, true) ~= nil or string.find(nm, "plank", 1, true) ~= nil
end
function K.damagedAt(b, word, below, woodOnly)
    if b == nil then return nil end
    local best, bestF = nil, below or 0.999
    for zz = 0, 1 do
        for x = b.x1 - 6, b.x2 + 6 do
            for y = b.y1 - 6, b.y2 + 6 do
                local sq = sqAt(x, y, zz)
                if sq then
                    pcall(function()
                        local objs = sq:getSpecialObjects()
                        for i = 0, objs:size() - 1 do
                            local o = objs:get(i)
                            if instanceof(o, "IsoThumpable") then
                                local nm = string.lower(tostring(o:getName() or ""))
                                local f = o:getHealth() / math.max(1, o:getMaxHealth())
                                if (word == nil or string.find(nm, word, 1, true)) and (not woodOnly or K.woodName(nm)) and f < bestF then best, bestF = { o = o, x = x, y = y, z = zz }, f end
                            end
                        end
                    end)
                end
            end
        end
    end
    return best
end
-- on their own: once a real minute at most, look for something below ghostRepairBelow %
function K.autoRepair(b, now)
    if G.setting("ghostAutoRepair") == false or K.repairWant ~= nil or K.paused or b == nil then return false end
    if now - (K.autoAt or -1e12) < 60000 then return false end
    K.autoAt = now
    local t = K.damagedAt(b, nil, G.num("ghostRepairBelow") / 100, true)
    if t == nil then return false end
    K.repairWant = { auto = true, below = G.num("ghostRepairBelow") / 100, at = now }
    return true
end
function K.repairPick(uid, shell, b)
    local w = K.repairWant
    if w == nil or builders() >= G.num("ghostBuilders") then return nil end
    local target = K.damagedAt(b, w.word, w.below, w.auto)
    if target == nil then K.repairWant = nil; return nil end
    local tools, items = K.check(K.REPAIR, shell, K.containers(b))
    if tools or items then
        local text = G.needText(items or {})
        if tools and #tools > 0 then text = (text ~= "" and (text .. ", ") or "") .. table.concat(tools, ", ") end
        local p = playerOf()
        if p and fn(M, "say") and not w.auto then pcall(M.say, shell, p, tr("RepairNeed", "Can't fix it without {1}.", text)) end
        K.repairWant = nil
        return nil
    end
    K.repairWant = nil
    return { repair = target, x = target.x, y = target.y, z = target.z, started = nowMs() }
end
function K.repairDo(j, uid, shell, b)
    local cs = K.containers(b)
    if K.check(K.REPAIR, shell, cs) ~= nil then return false end
    K.take({ "Base.Plank" }, 1, shell, cs)
    K.take({ "Base.Nails" }, 2, shell, cs)
    pcall(function() local o = j.repair.o; o:setHealth(o:getMaxHealth()); if o.sync then o:sync() end end)
    K.stats.repairs = K.stats.repairs + 1
    K.addXp(uid, 5)
    return true
end

----------------------------------------------------------------------------------------------------------------
-- totals: everything the plans still need vs what's in storage
----------------------------------------------------------------------------------------------------------------
function K.totals(b)
    local need = {}
    for _, p in ipairs(K.plans) do G.remaining(p, need) end
    local cs = K.containers(b)
    local rows = {}
    for _, e in pairs(need) do
        local have = 0
        for _, c in ipairs(cs) do have = have + amountIn(c.c, e) end
        rows[#rows + 1] = { types = e.types, n = e.n, uses = e.uses, have = have, short = math.max(0, e.n - have) }
    end
    table.sort(rows, function(a, c) return tostring(a.types[1]) < tostring(c.types[1]) end)
    return rows
end
function K.totalsText(rows)
    local all, short = {}, {}
    for _, r in ipairs(rows) do
        all[#all + 1] = { types = r.types, n = r.n, uses = r.uses }
        if r.short > 0 then short[#short + 1] = { types = r.types, n = r.short, uses = r.uses } end
    end
    return G.needText(all), G.needText(short), #short
end
-- send for it: the base's scavengers look for building supplies (A-Life's own "wanted" list; settlers going out on
-- it is unverified), and a letter says what's short
function K.askFor(b)
    local rows = K.totals(b)
    local _, shortText, n = K.totalsText(rows)
    if n == 0 then toast(tr("NothingShort", "Storage has everything the plans need.")); return 0 end
    local asked = 0
    pcall(function()
        PA().ActorRegistry.each(function(rec)
            local uid = rec and rec.uid
            if uid and fn(M, "wzIsWorker") and M.wzIsWorker(uid, playerOf()) then
                PA().Talk.writeMemory(tostring(uid), function(m) m.scavengeWanted = "tools" end)
                asked = asked + 1
            end
        end)
    end)
    if playerOf() then
        pcall(ALifeSide.outLetter, playerOf(), tr("Asked", "Building: told the scavengers to look for building supplies. Short: {1}.", shortText), 200, 200, 140)
    end
    return asked
end

----------------------------------------------------------------------------------------------------------------
-- who builds it: the people who'd build (workers at your base)
----------------------------------------------------------------------------------------------------------------
function K.workers()
    local out = {}
    local p = playerOf()
    pcall(function()
        PA().ActorRegistry.each(function(rec)
            local uid = rec and rec.uid
            if uid and fn(M, "wzIsWorker") and M.wzIsWorker(uid, p) then out[#out + 1] = tostring(uid) end
        end)
    end)
    table.sort(out, function(a, b) return nameOf(a) < nameOf(b) end)
    return out
end
function K.assignByWords(name, thing)
    name, thing = string.lower(tostring(name or "")), string.lower(tostring(thing or ""))
    local who = nil
    for _, uid in ipairs(K.workers()) do if string.lower(nameOf(uid)) == name then who = uid; break end end
    if who == nil then return false end
    for _, p in ipairs(K.plans) do
        local t = G.typeOf(p.type)
        local w = t and (string.lower(tostring(t.word or "")) .. " " .. string.lower(tostring(t.label or ""))) or ""
        if p.kind ~= "down" and thing ~= "" and string.find(w, thing, 1, true) then
            send("ghostAssign", { id = p.id, who = who })
            toast(tr("Assigned", "{1} builds the {2}.", nameOf(who), string.lower(tostring(t.label))))
            return true
        end
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- words
----------------------------------------------------------------------------------------------------------------
function K.onWords(player, text)
    local low = string.lower(tostring(text or ""))
    if string.find(low, "stop building", 1, true) or string.find(low, "quit building", 1, true) then
        K.paused = true
        for uid in pairs(K.jobs) do K.release(uid, nil) end
        toast(tr("Paused", "Building paused. Say \"get building\" to start again."))
        return true
    end
    local fix = string.match(low, "fix the (%a+)") or string.match(low, "repair the (%a+)") or string.match(low, "mend the (%a+)")
    if fix then
        local map = { fence = "fence", wall = "wall", gate = "gate", walls = "wall", fences = "fence" }
        K.repairWant = { word = map[fix] or nil, at = nowMs() }
        for uid in pairs(K.next) do K.next[uid] = 0 end
        return true
    end
    -- "Sam builds the gate" / "Sam, build the gate"
    local nm, thing = string.match(low, "^%s*(%a+),? builds? the ([%a ]+)")
    if nm and thing and nm ~= "get" and nm ~= "start" and nm ~= "you" and nm ~= "we" and nm ~= "lets" and K.assignByWords(nm, (string.gsub(thing, "%s+$", ""))) then return true end
    if string.find(low, "get building", 1, true) or string.find(low, "back to building", 1, true) or string.find(low, "build that", 1, true)
            or string.find(low, "build the ", 1, true) or string.find(low, "start building", 1, true) then
        K.paused = false
        for _, plan in ipairs(G.store().list) do plan.retryAt = nil end
        for uid in pairs(K.next) do K.next[uid] = 0 end
        if #G.store().list == 0 then toast(tr("NoPlans", "No plans yet: A-Life window > Build tab, then place them.")) end
        return true
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- right-click in the world: take this down, building stockpile, stamp a layout here
----------------------------------------------------------------------------------------------------------------
function K.fillContext(playerNum, context, worldObjects, test)
    if test or G.setting("ghostBuild") == false or type(worldObjects) ~= "table" then return end
    local p = playerOf()
    local sq = nil
    for _, o in ipairs(worldObjects) do pcall(function() sq = sq or o:getSquare() end) end
    if sq == nil or p == nil then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local downs, seen = {}, {}
    pcall(function()
        local objs = sq:getSpecialObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if instanceof(o, "IsoThumpable") and o:isDismantable() and not seen[tostring(o:getName())] then
                seen[tostring(o:getName())] = true
                downs[#downs + 1] = o
            end
        end
    end)
    for _, o in ipairs(downs) do
        local nm = tostring(o:getName() or "")
        local label = nm
        pcall(function() local t = o:getTextureName(); label = nm ~= "" and nm or t end)
        context:addOption(tr("Down", "Plan: take this down ({1})", label), nil, function()
            local spr = nil
            pcall(function() spr = o:getSprite():getName() end)
            send("ghostDown", { x = x, y = y, z = z, name = nm, label = label, north = (function() local n = false; pcall(function() n = o:getNorth() end); return n end)(), sprite = spr })
        end)
    end
    if containerOn(sq) then
        local on = false
        for _, pl in ipairs(K.piles or {}) do if pl.x == x and pl.y == y and (pl.z or 0) == z then on = true end end
        context:addOption(on and tr("PileOff", "Not a building stockpile any more") or tr("PileOn", "Building stockpile (builders haul from here)"), nil, function()
            send("ghostPile", { x = x, y = y, z = z })
        end)
    end
    if #K.layouts > 0 then
        local opt = context:addOption(tr("StampHere", "Stamp a building layout here"), nil, nil)
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(opt, sub)
        for _, l in ipairs(K.layouts) do
            sub:addOption(tostring(l.name) .. " (" .. tostring(l.n) .. ")", nil, function() send("ghostStamp", { index = l.index, x = x, y = y, z = z }) end)
        end
    end
end
if type(Events) == "table" and Events.OnFillWorldObjectContextMenu ~= nil then
    Events.OnFillWorldObjectContextMenu.Add(function(a, b, c, d) pcall(K.fillContext, a, b, c, d) end)
end

----------------------------------------------------------------------------------------------------------------
-- the Build tab
----------------------------------------------------------------------------------------------------------------
local STATE = { waiting = "waiting", building = "being built", blocked = "stuck" }
local WHY = { materials = "missing materials", skill = "needs someone better at building", blocked = "something's in the way", error = "couldn't put it up" }
function K.rowText(p)
    local t = G.typeOf(p.type) or {}
    local stages = t.stages and #t.stages or 1
    local s = tostring(p.kind == "down" and p.label or (t.label or p.type))
    if p.kind ~= "down" and stages > 1 then s = s .. " (" .. (p.stage == 1 and tr("Frame", "frame first") or tr("Stage", "step {1} of {2}", p.stage, stages)) .. ")" end
    s = s .. "  -  " .. tostring(STATE[p.state] or p.state)
    if p.builder then s = s .. tr("By", " by {1}", nameOf(p.builder)) end
    if p.helper then s = s .. tr("Helper", " (with {1})", nameOf(p.helper)) end
    if p.who and not p.builder then s = s .. tr("For", " (for {1})", nameOf(p.who)) end
    if p.state == "blocked" then
        s = s .. ": " .. tostring(WHY[p.why] or p.why or "")
        -- p.needText: multiplayer (ALifeCmd drops the need list, nested too deep: payload > list > plan > need)
        local nt = (type(p.need) == "table" and #p.need > 0 and type(p.need[1]) == "table" and p.need[1].types) and G.needText(p.need) or p.needText
        if nt and nt ~= "" then s = s .. tr("NeedList", " (needs {1})", nt) end
    elseif p.state ~= "building" and p.kind ~= "down" then
        local cost = t.stages and G.costOf(t.stages[p.stage] or t.stages[1])
        if cost then s = s .. tr("Cost", "  (this step: {1})", G.needText(cost.items)) end
    end
    return s
end
-- the "Plan something" menu: basic types, then vanilla's categories (each thing's cost in its tooltip)
function K.planMenu(x, y)
    local cm = ISContextMenu.get(0, x or getMouseX(), y or getMouseY())
    local function tipFor(opt, id)
        local t = G.TYPES[id]
        local c = t and G.costOf(t.stages[1])
        if c == nil then return end
        pcall(function()
            local tip = ISToolTip:new()
            tip:initialise(); tip:setVisible(false)
            tip:setName(t.label)
            local txt = tr("BtnTip", "Plan a {1}. Each step costs: {2}.", string.lower(t.label), G.needText(c.items))
            if #t.stages > 1 then txt = txt .. " " .. tr("Steps", "{1} steps.", #t.stages) end
            if c.skill then txt = txt .. " " .. tr("Skill", "Needs {1} {2}.", c.skill[1], c.skill[2]) end
            tip.description = txt
            if t.icon then tip:setTexture(t.icon) end
            opt.toolTip = tip
        end)
    end
    local basic = cm:addOption(tr("Basic", "Walls and fences (basic)"), nil, nil)
    local sub = ISContextMenu:getNew(cm)
    cm:addSubMenu(basic, sub)
    for i = 1, G.BASIC_COUNT do
        local id = G.ORDER[i]
        local t = G.TYPES[id]
        if t then local o = sub:addOption(t.label, nil, function() K.place(id) end); tipFor(o, id) end
    end
    for _, c in ipairs(G.catList()) do
        local opt = cm:addOption(c.cat, nil, nil)
        local s2 = ISContextMenu:getNew(cm)
        cm:addSubMenu(opt, s2)
        for _, id in ipairs(c.ids) do
            local t = G.TYPES[id]
            local o = s2:addOption(t.label, nil, function() K.place(id) end)
            tipFor(o, id)
        end
    end
    return cm
end
function K.whoMenu(plan)
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    cm:addOption(tr("Anyone", "Anyone"), nil, function() send("ghostAssign", { id = plan.id }) end)
    for _, uid in ipairs(K.workers()) do
        cm:addOption(nameOf(uid) .. tr("SkillWord", " ({1})", K.skillWord(K.skillOf(uid))), nil, function() send("ghostAssign", { id = plan.id, who = uid }) end)
    end
    return cm
end
function K.skillWord(l)
    if l <= 2 then return tr("Sk1", "new to it") elseif l <= 4 then return tr("Sk2", "handy") elseif l <= 7 then return tr("Sk3", "good with their hands") end
    return tr("Sk4", "a real builder")
end
function K.layoutMenu()
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    local p = playerOf()
    cm:addOption(tr("SaveLayout", "Save the plans around me as a layout"), nil, function()
        if p then send("ghostSaveLayout", { x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()), radius = 20 }) end
    end)
    for _, l in ipairs(K.layouts) do
        cm:addOption(tr("StampAt", "Stamp \"{1}\" at my feet ({2} plans)", l.name, l.n), nil, function()
            if p then send("ghostStamp", { index = l.index, x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()) }) end
        end)
    end
    for _, l in ipairs(K.layouts) do
        cm:addOption(tr("DelLayout", "Forget \"{1}\"", l.name), nil, function() send("ghostDelLayout", { index = l.index }) end)
    end
    return cm
end
function K.addTab()
    if K.tabAdded then return true end
    local kit = M.winKit
    if type(kit) ~= "table" or not fn(M, "hubAddTab") or ALifeTalkHubPage == nil then return false end
    local T, S = M.Theme, M.UIStyle
    local P = kit.page("ALifeTalkGhostPage", "Build", "build",
        tr("Tip", "<SIZE:medium> Build <LINE> <SIZE:small> Plan anything the game lets you build, at your base, without materials. The people who live there build it over time, from what's in storage, with real tools. Top of the list goes first."))
    function P:createChildren()
        ALifeTalkHubPage.createChildren(self)
        K.win = self
    end
    function P:selected()
        local i = self.list and self.list.selected or 0
        local it = self.list and self.list.items and self.list.items[i]
        return it and it.item or nil
    end
    function P:layoutMore(top, by)
        local fh = 16
        pcall(function() fh = getTextManager():getFontHeight(self.font) end)
        if self.list == nil then
            self.list = ISScrollingListBox:new(10, top, self.width - 20, 100)
            self.list:initialise(); self.list:instantiate()
            self.list.font = self.font
            self.list.itemheight = fh + 10
            self.list.drawBorder = true
            self.list.backgroundColor = { r = 0.08, g = 0.08, b = 0.09, a = 0.8 }
            self.list.doDrawItem = function(list, y, item, alt)
                local p = item.item
                if list.selected == item.index then list:drawRect(0, y, list:getWidth(), list.itemheight, 0.3, 0.55, 0.45, 0.25) end
                local c = p.kind == "down" and { 1, 0.5, 0.45 } or (p.state == "blocked" and { 1, 0.7, 0.3 } or (p.state == "building" and { 0.6, 0.85, 0.5 } or { 0.87, 0.88, 0.9 }))
                list:drawText(tostring(item.index) .. ". " .. K.rowText(p), 8, y + 5, c[1], c[2], c[3], 1, list.font)
                return y + list.itemheight
            end
            self:addChild(self.list)
        end
        local listH = math.max(60, math.floor((by - top) * 0.55))
        self.list:setX(10); self.list:setY(top); self.list:setWidth(self.width - 20); self.list:setHeight(listH)
        self.body:setY(top + listH + 6); self.body:setHeight(math.max(30, by - top - listH - 12))
        pcall(function() self.body:updateScrollbars() end)
    end
    function P:text()
        local plans = K.refreshPlans()
        if self.list then
            local sel = self.list.selected
            self.list:clear()
            for _, p in ipairs(plans) do self.list:addItem(p.id, p) end
            if sel and sel <= #plans then self.list.selected = sel end
        end
        local out = {}
        if #plans == 0 then out[#out + 1] = kit.DIM .. tr("Empty", "No plans. Plan something, then click where it goes. You don't need the materials now.") .. " <LINE> " end
        local b = K.base(playerOf())
        if b == nil then out[#out + 1] = kit.RED .. tr("NoBase", "You need a base first (A-Life's base mark or a safehouse): the people who live there do the building.") .. " <LINE> " end
        if #plans > 0 and b then
            local rows = K.totals(b)
            local allText, shortText, nShort = K.totalsText(rows)
            if allText ~= "" then out[#out + 1] = tr("AllNeed", "All plans need: {1}.", allText) .. " <LINE> " end
            if nShort > 0 then out[#out + 1] = kit.GOLD .. tr("Short", "Short in storage: {1}.", shortText) .. " <LINE> "
            elseif allText ~= "" then out[#out + 1] = kit.DIM .. tr("Enough", "Storage has it all.") .. " <LINE> " end
        end
        if #(K.piles or {}) > 0 then out[#out + 1] = kit.DIM .. tr("Piles", "Building stockpiles: {1} (right-click a container to add or remove one).", #K.piles) .. " <LINE> " end
        out[#out + 1] = kit.DIM .. tr("How", "Builders take the top plan they can do, and carry what they need from storage and your building stockpiles. Missing something: they say what. Zombies close: they stop. Shift-click a start and an end for a line, Ctrl+Shift for a box. Right-click something at the base to take it down. Say \"stop building\" / \"get building\", \"fix the fence\", or \"Sam builds the gate\".") .. " <LINE> "
        if K.paused then out[#out + 1] = kit.GOLD .. tr("PausedNote", "Paused: say \"get building\".") .. " <LINE> " end
        return table.concat(out)
    end
    function P:actions()
        local a = {}
        a[#a + 1] = { label = tr("PlanBtn", "Plan something"), tip = tr("PlanTip", "Everything the game's build menu builds, by category. Hover one for what it costs."),
            fn = function(win) K.planMenu() end }
        a[#a + 1] = { label = tr("Up", "Up"), fn = function(win) local p = win:selected(); if p then send("ghostMove", { id = p.id, dir = -1 }) end end }
        a[#a + 1] = { label = tr("Down", "Down"), fn = function(win) local p = win:selected(); if p then send("ghostMove", { id = p.id, dir = 1 }) end end }
        a[#a + 1] = { label = tr("WhoBtn", "Who builds it"), tip = tr("WhoTip", "Give the plan to one person. If they don't come for it, anyone takes it later."),
            fn = function(win) local p = win:selected(); if p then K.whoMenu(p) end end }
        a[#a + 1] = { label = tr("AskBtn", "Send for supplies"), tip = tr("AskTip", "Tell the base's scavengers to look for building supplies on their runs."),
            fn = function(win) K.askFor(K.base(playerOf())) end }
        a[#a + 1] = { label = tr("LayoutsBtn", "Layouts"), tip = tr("LayoutsTip", "Save the plans around you, and stamp them down somewhere else."),
            fn = function(win) K.layoutMenu() end }
        a[#a + 1] = { label = tr("Cancel", "Cancel plan"), accent = S and S.red or nil, tip = tr("CancelTip", "Nothing is lost: materials are only used when a step is finished. A finished frame stays."),
            fn = function(win) local p = win:selected(); if p then send("ghostCancel", { id = p.id }) end end }
        return a
    end
    function P:onPageClose() if K.win == self then K.win = nil end end
    M.hubAddTab({ id = "build", label = "Build", class = "ALifeTalkGhostPage", open = function() K.refreshPlans(true); return kit.openPage(P, "winGhost") end,
        ref = function() return M.winGhost end, show = function() return G.setting("ghostBuild") ~= false end }, "settings")
    K.tabAdded = true
    return true
end

if type(M.playerWordHooks) == "table" and not K.wordsHooked then -- at load, like the other word hooks (Main's per-file list)
    K.wordsHooked = true
    table.insert(M.playerWordHooks, function(player, text) pcall(K.onWords, player, text) end)
end
function K.install()
    pcall(K.addTab)
    pcall(K.register)
    pcall(G.loadCatalog)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "ghostBuild", "Ghost build: plan things at your base; the people who live there build them (Build tab)" },
            { "ghostAllVanilla", "Ghost build: everything the game's build menu builds can be planned (off: the six basic walls and fences)" },
            { "ghostLeaderOnly", "Ghost build (multiplayer): only the base's owner places and cancels plans" },
            { "ghostBuilders", "Ghost build: most people building at once", { 1, 2, 3, 4, 6 } },
            { "ghostTimeMs", "Ghost build: work speed (ms per recipe time unit; lower is faster)", { 50, 100, 200, 400 } },
            { "ghostFetchTiles", "Ghost build: how far around the base they look for materials (tiles)", { 0, 6, 12, 25 } },
            { "ghostHaulTiles", "Ghost build: building stockpiles count this far from the base (tiles; they carry from there)", { 50, 100, 150, 300 } },
            { "ghostRange", "Ghost build: plans only this far from you (tiles)", { 30, 60, 100 } },
            { "ghostOutside", "Ghost build: plans outside the base too (outposts; builders carry the materials out)" },
            { "ghostBaseTiles", "Ghost build: 'inside the base' reaches this far past its edge (tiles)", { 0, 3, 6, 12 } },
            { "ghostLineMax", "Ghost build: most plans in one line or box", { 20, 40, 80 } },
            { "ghostWasteChance", "Ghost build: chance someone only just good enough wastes material (%)", { 0, 10, 25, 50 } },
            { "ghostNoise", "Ghost build: building makes real noise the dead hear" },
            { "ghostNoiseTiles", "Ghost build: how far the noise carries (tiles; vanilla hammering is 20)", { 10, 20, 30 } },
            { "ghostAutoRepair", "Ghost build: builders mend damaged wooden walls and fences on their own" },
            { "ghostRepairBelow", "Ghost build: mend on their own below this health (%)", { 30, 50, 60, 80 } },
            { "ghostApprentice", "Ghost build: idle, less skilled workers help a builder (faster; they learn more)" },
            { "ghostAssignWaitMin", "Ghost build: a plan given to one person waits this long for them (real minutes)", { 5, 15, 30, 60 } },
            { "ghostLetters", "Ghost build: a letter when a plan is stuck, and when all are done" },
        }) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
    end
    if type(M.settingCatOf) == "table" then for k in pairs(G.DEFAULTS) do M.settingCatOf[k] = M.settingCatOf[k] or "Your camp and base" end end
    if type(M.winHelp) == "table" then
        table.insert(M.winHelp, { "Building", "Build tab > Plan something: anything the game's build menu builds, with no materials. The people who live at your base build it from storage with real tools and skill; they carry what's in your building stockpiles (right-click a container). Shift-click start and end for a line, Ctrl+Shift for a box. Right-click something to take it down. Layouts: save plans and stamp them elsewhere. \"stop building\" / \"get building\" / \"fix the fence\" / \"Sam builds the gate\"." })
    end
    print(TAG .. " ready v" .. K.VERSION .. ": Build tab " .. (K.tabAdded and "on" or "OFF") .. ", builders " .. (K.registered and "registered" or "NOT registered")
        .. ", " .. #G.ORDER .. " types (" .. tostring(G.catalogN or 0) .. " from vanilla's build list), see-through plans " .. ((type(Events) == "table" and Events.OnPostFloorLayerDraw) and "on" or "off")
        .. ", lines / boxes, take down, stockpiles, layouts, auto repair " .. (G.setting("ghostAutoRepair") ~= false and "on" or "off") .. ", noise " .. (G.setting("ghostNoise") ~= false and "on" or "off"))
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
if type(Events) == "table" and Events.OnTick ~= nil and ALifeHealth and ALifeHealth.tickAdd then
    local last = -1e12
    ALifeHealth.tickAdd("ALifeGhost", function()
        local t = nowMs()
        if t - last < 1000 then return end
        last = t
        if not K.registered then pcall(K.register) end
        pcall(K.refreshPlans)
    end)
end
-- pre-1.0 MP (P6): an MP client has no world tick here; it still asks for the plan list (the Build tab, the drawing)
if ALifeSide.mpClient() and type(_G.Events) == "table" and _G.Events.OnTick ~= nil then
    local lastC = -1e12
    _G.Events.OnTick.Add(function()
        local t = nowMs()
        if t - lastC < 1000 then return end
        lastC = t
        pcall(K.refreshPlans)
    end)
end
return K
