-- A-Life NPC Overhaul 0.6.0: THE WORLD BLEEDS DRY. Derelict buildings.
--
-- Rule: the mod never creates loot. When people loot a building out of your sight (A-Life's offline scavenging, the
-- Airport, later your own expeditions), they take a haul set by that building's rooms, and the building becomes
-- derelict: its loot never rolls for anyone else. You find bare shelves when you get there.
--
-- How (all hooks wrap, never replace; every engine call guarded):
--  * Marking: buildings are A-Life's meta-grid BuildingDefs (they exist for the whole map, loaded or not). Key =
--    "x:y:x2:y2", the same key A-Life's picked-over buildings use. We also write the building into A-Life's
--    PickedOver record at level 3, so A-Life adds open doors, broken windows and bodies when no player is near.
--  * Emptying: LoadGridsquare - containers in a derelict building that were never opened are set explored, so vanilla
--    never rolls them (vanilla only rolls a container the first time it is seen: ISInventoryPage:checkExplored /
--    ISOpenContainerTimedAction call ItemPicker.fillContainer only when not isExplored()). Containers that were already
--    opened (their items are real) are emptied, but only with no player within 40 tiles. OnFillContainer empties
--    anything that still rolls (backstop).
--  * Never: a building a player has been in (def:isHasBeenVisited), a player base / safehouse / outpost (A-Life's own
--    PickedOver.protected), an NPC base, a building that's loaded right now, or one already derelict.
--  * Honest offline scavenging: A-Life's OfflineLoot.onArrive used to roll 1-3 imaginary houses from a fixed item list.
--    Wrapped: a scavenging squad now takes from 1-3 REAL eligible buildings near where it went (nearest first), and
--    they become derelict. No eligible building near = nothing found: the area is dry.
--  * Hidden: nothing here is shown to the player. The console gets counts only (detail behind the derelictDebug
--    setting), and the record lives in server ModData.
-- No per-frame work: LoadGridsquare returns at once when nothing is derelict, else one cached lookup per square.

require "ALifeNPCOverhaul/AA_Side"
ALifeDerelict = ALifeDerelict or {}
local D = ALifeDerelict
local TAG = "[ALifeDerelict]"
local VERSION = ALifeSide.MOD_VERSION
D.KEY = "ALifeChatPlus.Derelict"
D.cfg = {
    playerFar = 40,                         -- tiles: never empty an opened container closer than this to a player
    probeRadii = { 8, 18, 30, 45, 65 },     -- where a squad looks around its destination
    probeAngles = 12,
    houseCap = 40,                          -- items a building can give at most
    percentBase = 25,                       -- A-Life's Offline_LootPercent default = 1.0x haul
    cacheCap = 2000,
}
-- expected items per room (tuning values); a room name matches by substring, first match wins
D.ROOMS = {
    { "kitchen", { food = 8, misc = 1 } }, { "pantry", { food = 6 } }, { "bathroom", { med = 3 } },
    { "garage", { tools = 3, misc = 2 } }, { "shed", { tools = 2, misc = 1 } }, { "storage", { tools = 2, misc = 2, food = 1 } },
    { "bedroom", { misc = 1, med = 0.5, ammo = 0.2 } }, { "living", { misc = 1, food = 0.5 } }, { "dining", { food = 1 } },
    { "laundry", { misc = 1 } }, { "office", { misc = 1 } }, { "farm", { tools = 1, food = 1 } }, { "barn", { tools = 1, food = 1 } },
}
D.DEFAULT_ROOM = { misc = 0.5 }
-- what each kind of loot is, from A-Life's own offline loot list (the item types A-Life already gives its scavengers)
D.KINDS = {
    ["Base.Bandage"] = "med", ["Base.Disinfectant"] = "med", ["Base.Pills"] = "med",
    ["Base.TinnedBeans"] = "food", ["Base.CannedCorn"] = "food", ["Base.CannedChili"] = "food", ["Base.Crisps"] = "food",
    ["Base.Cereal"] = "food", ["Base.Chocolate"] = "food", ["Base.PeanutButter"] = "food",
    ["Base.Matches"] = "misc", ["Base.Lighter"] = "misc", ["Base.Battery"] = "misc",
    ["Base.Hammer"] = "tools", ["Base.Screwdriver"] = "tools", ["Base.Nails"] = "tools",
    ["Base.Bullets9mmBox"] = "ammo", ["Base.ShotgunShellsBox"] = "ammo",
}
D.stats = { marked = 0, sealed = 0, emptied = 0, filledEmptied = 0, arrivals = 0, dry = 0, items = 0, faults = 0 }
D.faulted = {}

local function log(m) print(TAG .. " " .. tostring(m)) end
local function fault(where, err)
    D.stats.faults = D.stats.faults + 1
    if not D.faulted[where] then D.faulted[where] = true; log(where .. " failed (logged once): " .. tostring(err)) end
end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function authority() return ALifeSide.world() end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function hash01(s)
    local h = 5381; s = tostring(s)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return (h % 100000) / 100000
end
local function setting(k)
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" then return M.settings[k] end
    return nil
end
function D.on() return setting("honestScavenge") ~= false end
local function debugOn() return setting("derelictDebug") == true end

----------------------------------------------------------------------------------------------------------------
-- the record (server ModData; never sent to clients)
----------------------------------------------------------------------------------------------------------------
D.store, D.count = nil, 0
function D.data()
    if D.store ~= nil then return D.store end
    if ModData == nil or not fn(ModData, "getOrCreate") then return nil end
    local d = ModData.getOrCreate(D.KEY)
    d.buildings = type(d.buildings) == "table" and d.buildings or {}
    local n = 0
    for _ in pairs(d.buildings) do n = n + 1 end
    D.store, D.count = d, n
    return d
end
function D.keyOf(def)
    local k = nil
    pcall(function() k = def:getX() .. ":" .. def:getY() .. ":" .. def:getX2() .. ":" .. def:getY2() end)
    return k
end
D.keyCache, D.keyCacheN = {}, 0
local function cachedKey(def)
    local k = D.keyCache[def]
    if k ~= nil then return k or nil end
    k = D.keyOf(def)
    if D.keyCacheN >= D.cfg.cacheCap then D.keyCache, D.keyCacheN = {}, 0 end
    D.keyCache[def] = k or false
    D.keyCacheN = D.keyCacheN + 1
    return k
end
function D.isDerelict(def)
    local d = D.data()
    if d == nil or D.count == 0 or def == nil then return nil end
    local k = cachedKey(def)
    return k and d.buildings[k] or nil
end
function D.mark(def, by)
    local d = D.data()
    local k = def and D.keyOf(def) or nil
    if d == nil or k == nil or d.buildings[k] ~= nil then return false end
    d.buildings[k] = { h = math.floor(hours()), by = by and tostring(by) or nil }
    D.count = D.count + 1
    D.stats.marked = D.stats.marked + 1
    -- A-Life's picked-over record at the top level: its doors / windows / bodies when nobody is near
    local P = PA().PickedOver
    if fn(P, "data") then
        pcall(function()
            local pd = P.data()
            if pd and type(pd.buildings) == "table" and pd.buildings[k] == nil then
                pd.buildings[k] = { level = 3, faction = by, hours = hours(), applied = {} }
                if type(P.cache) == "table" and P.cache[def] ~= nil then P.cache[def] = nil end
            end
        end)
    end
    if debugOn() then log("marked " .. k .. " (" .. tostring(by) .. ")") end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- may this building be looted off screen?
----------------------------------------------------------------------------------------------------------------
local function loadedNow(def)
    local loaded = false
    pcall(function()
        local cx = math.floor((def:getX() + def:getX2()) / 2)
        local cy = math.floor((def:getY() + def:getY2()) / 2)
        loaded = getCell():getGridSquare(cx, cy, 0) ~= nil
    end)
    return loaded
end
local function npcBase(def)
    local M = ALifeLLMTalk
    if not (type(M) == "table" and fn(M, "nbStore")) then return false end
    local inside = false
    pcall(function()
        local cx, cy = (def:getX() + def:getX2()) / 2, (def:getY() + def:getY2()) / 2
        for _, b in pairs(M.nbStore().byId or {}) do
            local bb = type(b) == "table" and b.status == "active" and b.bounds or nil
            if bb and cx >= bb.x1 - 2 and cx <= bb.x2 + 2 and cy >= bb.y1 - 2 and cy <= bb.y2 + 2 then inside = true; return end
        end
    end)
    return inside
end
function D.eligible(def)
    if def == nil then return false, "none" end
    local k = D.keyOf(def)
    if k == nil then return false, "nokey" end
    local d = D.data()
    if d and d.buildings[k] ~= nil then return false, "derelict" end
    local visited = false
    pcall(function() visited = def:isHasBeenVisited() == true end)
    if visited then return false, "visited" end
    local P = PA().PickedOver
    if fn(P, "protected") then
        local ok, prot = pcall(P.protected, def, nil)
        if ok and prot then return false, "protected" end
    end
    if fn(P, "data") then
        local picked = false
        pcall(function() local pd = P.data(); picked = pd and pd.buildings and pd.buildings[k] ~= nil end)
        if picked then return false, "picked" end
    end
    if npcBase(def) then return false, "base" end
    if loadedNow(def) then return false, "loaded" end
    return true
end
function D.defAt(x, y)
    local def = nil
    pcall(function() def = getWorld():getMetaGrid():getBuildingAt(math.floor(x), math.floor(y)) end)
    return def
end
-- up to n eligible buildings around (x, y), nearest first; radii = the rings to probe
function D.findNear(x, y, n, radii, angles)
    local out, seen = {}, {}
    radii, angles = radii or D.cfg.probeRadii, angles or D.cfg.probeAngles
    local center = D.defAt(x, y)
    local function try(def)
        local k = def and D.keyOf(def) or nil
        if k == nil or seen[k] then return end
        seen[k] = true
        if D.eligible(def) then out[#out + 1] = def end
    end
    if center then try(center) end
    for _, r in ipairs(radii) do
        if #out >= n then break end
        for a = 0, angles - 1 do
            local ang = a * 2 * math.pi / angles
            try(D.defAt(x + math.cos(ang) * r, y + math.sin(ang) * r))
            if #out >= n then break end
        end
    end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- the haul: set by the building's rooms (deterministic per building), item types from A-Life's own loot list
----------------------------------------------------------------------------------------------------------------
local function roomNames(def)
    local out = {}
    pcall(function()
        local rooms = def:getRooms()
        for i = 0, math.min(rooms:size(), 40) - 1 do
            local name = nil
            pcall(function() name = rooms:get(i):getName() end)
            if name then out[#out + 1] = string.lower(tostring(name)) end
        end
    end)
    return out
end
function D.expected(def)
    local want = { food = 0, med = 0, tools = 0, misc = 0, ammo = 0 }
    for _, name in ipairs(roomNames(def)) do
        local loot = D.DEFAULT_ROOM
        for _, row in ipairs(D.ROOMS) do
            if string.find(name, row[1], 1, true) then loot = row[2]; break end
        end
        for kind, n in pairs(loot) do want[kind] = want[kind] + n end
    end
    return want
end
local function typesByKind()
    if D.byKind then return D.byKind end
    local by = { food = {}, med = {}, tools = {}, misc = {}, ammo = {} }
    local L = PA().OfflineLoot
    local rows = type(L) == "table" and type(L.table) == "table" and L.table or nil
    if rows then
        for _, row in ipairs(rows) do
            local kind = D.KINDS[row.type]
            if kind and by[kind] then by[kind][#by[kind] + 1] = { type = row.type, weight = tonumber(row.weight) or 1 } end
        end
    else
        for t, kind in pairs(D.KINDS) do by[kind][#by[kind] + 1] = { type = t, weight = 1 } end
        for _, list in pairs(by) do table.sort(list, function(a, b) return a.type < b.type end) end
    end
    D.byKind = by
    return by
end
local function pickType(list, r)
    local total = 0
    for _, e in ipairs(list) do total = total + e.weight end
    if total <= 0 then return nil end
    local t = r * total
    for _, e in ipairs(list) do t = t - e.weight; if t <= 0 then return e.type end end
    return list[#list].type
end
local function percentMul()
    local L = PA().OfflineLoot
    local p = D.cfg.percentBase
    if fn(L, "percent") then local ok, v = pcall(L.percent); if ok and tonumber(v) then p = tonumber(v) end end
    return math.max(0, p) / D.cfg.percentBase
end
-- the exact item types this building gives (rarity rules respected), at most houseCap
function D.haul(def)
    local key = D.keyOf(def) or "?"
    local want = D.expected(def)
    local mul = percentMul()
    local by = typesByKind()
    local R = PA().LootRarity
    local out = {}
    for _, kind in ipairs({ "food", "med", "tools", "misc", "ammo" }) do
        local n = want[kind] * mul * (0.6 + 0.8 * hash01(key .. ":" .. kind))
        local count = math.floor(n + hash01(key .. ":" .. kind .. ":r"))
        for i = 1, count do
            if #out >= D.cfg.houseCap then break end
            local t = pickType(by[kind] or {}, hash01(key .. ":" .. kind .. ":" .. i))
            local okR = true
            if t and fn(R, "allowedItem") then local ok, yes = pcall(R.allowedItem, t); okR = not ok or yes ~= false end
            if t and okR then out[#out + 1] = t end
        end
    end
    return out
end
function D.isFoodType(t) return D.KINDS[t] == "food" end

----------------------------------------------------------------------------------------------------------------
-- take from real buildings near (x, y): marks them derelict, returns the item types and how many buildings
----------------------------------------------------------------------------------------------------------------
function D.lootNear(x, y, nBuildings, by, radii, angles)
    local defs = D.findNear(x, y, nBuildings, radii, angles)
    local types = {}
    for _, def in ipairs(defs) do
        for _, t in ipairs(D.haul(def)) do types[#types + 1] = t end
        D.mark(def, by)
    end
    if #defs == 0 then D.stats.dry = D.stats.dry + 1 end
    return types, #defs
end

----------------------------------------------------------------------------------------------------------------
-- A-Life's offline scavenging, made honest (wraps OfflineLoot.onArrive; the original runs when we're switched off)
----------------------------------------------------------------------------------------------------------------
function D.onArrive(orig, record, roll)
    local L = PA().OfflineLoot
    local task = type(record) == "table" and record.task or nil
    if not D.on() or type(task) ~= "table" or task.kind ~= "scavenge" or not fn(L, "percent") or L.percent() <= 0 then
        D.applied = true -- A-Life's own path: never run it twice
        return orig(record, roll)
    end
    local graph = PA().RoadGraph
    local node = type(graph) == "table" and type(graph.nodes) == "table" and task.dest ~= nil and graph.nodes[task.dest] or nil
    local x, y = node and tonumber(node.x) or tonumber(record.x), node and tonumber(node.y) or tonumber(record.y)
    D.stats.arrivals = D.stats.arrivals + 1
    if x and y then
        local s = L.settings or {}
        local want = (tonumber(s.housesMinimum) or 1) + math.floor((type(roll) == "function" and roll() or 0) * (tonumber(s.housesSpan) or 3))
        D.applied = true -- from here buildings are marked and items given: never fall back to A-Life's roll
        local types, houses = D.lootNear(x, y, want, record.factionId)
        local given, overflow = 0, 0
        if #types > 0 and fn(L, "give") then given, overflow = L.give(record, types, roll) end
        record.lootHouses = (tonumber(record.lootHouses) or 0) + houses
        record.lootGathered = (tonumber(record.lootGathered) or 0) + (tonumber(given) or 0)
        if type(L.metrics) == "table" then
            L.metrics.arrivals = (L.metrics.arrivals or 0) + 1
            L.metrics.houses = (L.metrics.houses or 0) + houses
            L.metrics.items = (L.metrics.items or 0) + (tonumber(given) or 0)
            L.metrics.overflow = (L.metrics.overflow or 0) + (tonumber(overflow) or 0)
        end
        D.stats.items = D.stats.items + (tonumber(given) or 0)
    end
    local St = PA().Stash
    if fn(St, "depositHome") then return St.depositHome(record) end
    return nil
end
function D.wrapScavenging()
    local L = PA().OfflineLoot
    if not fn(L, "onArrive") then return false end
    local marks = rawget(L, "_alcpHooks")
    if type(marks) ~= "table" then marks = {}; rawset(L, "_alcpHooks", marks) end
    local mark = marks.onArrive
    if type(mark) == "table" and L.onArrive == mark.wrapper then return true end
    local orig = (type(mark) == "table" and mark.orig) or L.onArrive
    local wrapper = function(record, roll)
        if D.dead then return orig(record, roll) end
        D.applied = false
        local ok, res = pcall(D.onArrive, orig, record, roll)
        if ok then return res end
        D.dead = true
        fault("scavenging wrap (A-Life's own scavenging restored)", res)
        if D.applied then return nil end -- part of this arrival already happened: never hand out loot twice
        return orig(record, roll)
    end
    L.onArrive = wrapper
    marks.onArrive = { orig = orig, wrapper = wrapper }
    return true
end

----------------------------------------------------------------------------------------------------------------
-- keeping derelict buildings bare
----------------------------------------------------------------------------------------------------------------
local function playerNear(x, y, r)
    local near = false
    pcall(function()
        local n = (type(getNumActivePlayers) == "function" and getNumActivePlayers()) or 1
        for i = 0, n - 1 do
            local p = getSpecificPlayer(i)
            if p and not p:isDead() then
                local dx, dy = p:getX() - x, p:getY() - y
                if dx * dx + dy * dy <= r * r then near = true; return end
            end
        end
    end)
    return near
end
local function emptyContainer(c)
    local list = c:getItems()
    local items = {}
    for i = 0, list:size() - 1 do items[#items + 1] = list:get(i) end
    for _, it in ipairs(items) do c:Remove(it) end
    return #items
end
function D.onLoadSquare(sq)
    if D.count == 0 or sq == nil or not authority() or not D.on() then return end
    local b = sq:getBuilding()
    if b == nil then return end
    local rec = D.isDerelict(b:getDef())
    if rec == nil then return end
    local objs = sq:getObjects()
    local far = nil
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local nc = o and o.getContainerCount and o:getContainerCount() or 0
        if nc > 0 and not (o:hasModData() and o:getModData().alcpDerelict) then
            local done = true
            for ci = 0, nc - 1 do
                local c = o:getContainerByIndex(ci)
                if c then
                    if not c:isExplored() then
                        c:setExplored(true)               -- vanilla will never roll it: nothing was left
                        D.stats.sealed = D.stats.sealed + 1
                    elseif c:getItems():size() > 0 then
                        if far == nil then far = not playerNear(sq:getX(), sq:getY(), D.cfg.playerFar) end
                        if far then D.stats.emptied = D.stats.emptied + emptyContainer(c) else done = false end
                    end
                end
            end
            if done then o:getModData().alcpDerelict = rec.h or 1 end
        end
    end
end
function D.onFill(roomName, containerType, container)
    if D.count == 0 or container == nil or not authority() or not D.on() then return end
    -- 42.22: ItemPickerJava also fires OnFillContainer with the loot-table entry (ItemPickerJava$ItemPickerContainer)
    -- as the 3rd arg for procedural/bag rolls. Only a real ItemContainer is a box in the world; the room fill fires
    -- again with the real container, so nothing is missed.
    if instanceof(container, "ItemContainer") == false then return end
    local parent = container:getParent()
    local sq = parent and parent.getSquare and parent:getSquare() or nil
    local b = sq and sq:getBuilding() or nil
    if b == nil or D.isDerelict(b:getDef()) == nil then return end
    D.stats.filledEmptied = D.stats.filledEmptied + emptyContainer(container)
end

function D.perf()
    local s = D.stats
    return "derelict " .. D.count .. " (marked " .. s.marked .. " this session), scavenging arrivals " .. s.arrivals .. ", dry " .. s.dry
        .. ", items " .. s.items .. ", sealed " .. s.sealed .. ", emptied " .. s.emptied .. "+" .. s.filledEmptied .. ", faults " .. s.faults
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
function D.install()
    if not authority() then return end
    D.store = nil
    D.data()
    local wrapped = D.wrapScavenging()
    log("loaded v" .. VERSION .. " (" .. D.count .. " derelict buildings; A-Life scavenging " .. (wrapped and "made honest" or "NOT found")
        .. "; picked-over " .. (fn(PA().PickedOver, "data") and "linked" or "not found") .. (D.on() and "" or "; switched off in settings") .. ")")
end
if type(Events) == "table" then
    -- the record before any square loads (squares around you load before OnGameStart)
    if Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(function() D.store = nil; pcall(D.data) end) end
    if Events.OnGameStart then Events.OnGameStart.Add(function() local ok, e = pcall(D.install); if not ok then fault("install", e) end end) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(function() local ok, e = pcall(D.install); if not ok then fault("install", e) end end) end
    if Events.LoadGridsquare then
        Events.LoadGridsquare.Add(function(sq)
            if D.count == 0 or D.loadDead then return end
            local ok, e = pcall(D.onLoadSquare, sq)
            if not ok then D.loadDead = true; fault("square load (derelict emptying off this session)", e) end
        end)
    end
    if Events.OnFillContainer then
        Events.OnFillContainer.Add(function(roomName, containerType, container)
            if D.count == 0 or D.fillDead then return end
            local ok, e = pcall(D.onFill, roomName, containerType, container)
            if not ok then D.fillDead = true; fault("container fill (derelict emptying off this session)", e) end
        end)
    end
end
