-- A-Life NPC Overhaul 0.4.0: WORK ZONES + BODY DISPOSAL + GRAVES.
-- People who live at your base (settlers, Jeem residents) clear corpses out of areas you mark:
--  * Right-click > Work zones: mark two corners, then a drop point: a ground tile (a pile), a container (dumpster),
--    or a burn site (its own option; refused near anything that burns).
--  * Workers carry each body with the game's own corpse calls (IsoDeadBody:becomeCorpseItem -> square:tryAddCorpseToWorld
--    / container:AddItem), so nothing is deleted and bodies keep their clothes and loot.
--  * Burn sites: bodies pile up, and the pile is lit only when every body that was in the area when the batch started is
--    on it. Needs a lighter + petrol (worker's pockets or any container in the base). No fire with zombies
--    close, none in rain or wind, and one person watches it burn out. Fire = the call vanilla's "burn corpse" makes.
--  * Graves: when someone from your base dies, a worker finds a shovel (their own, then containers out to the search
--    distance), carries the body to a spot by the base and buries it under a filled grave. No shovel: they lay the
--    body out there and say they need one.
--  * Squeamish people (by personality) refuse body work. Others may grumble.
--  * Text / voice: "clear the bodies", "get rid of the bodies" ... and "leave the bodies" to pause.
-- Hooks: an A-Life behaviour module (like base building), one OnTick (1 s throttle), the world context menu,
-- ProjectALife_NpcDied. A-Life files are untouched.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_WorkZones") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Seeded"
require "ALifeLLMTalk/ALifeLLMTalk_Settlers"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeWorkZones]"
local VERSION = ALifeSide.MOD_VERSION

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
-- one clock for claims, bans and waits: A-Life's context.now when we have it, carried forward by real time
local CLOCK = { t = nil, at = 0 }
local function rawMs() return (type(getTimestampMs) == "function" and getTimestampMs()) or 0 end
local function nowMs() if CLOCK.t == nil then return rawMs() end; return CLOCK.t + (rawMs() - CLOCK.at) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function sqAt(x, y, z) local s = nil; pcall(function() s = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) end); return s end
-- PZ's Kahlua has no next(): emptiness by pairs
local function hasAny(t) if type(t) ~= "table" then return false end; for _ in pairs(t) do return true end; return false end
local function isA(o, cls) local ok, v = pcall(function() return instanceof(o, cls) end); return ok and v == true end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function firstName(uid)
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = r and fn(PA().Names, "of") and PA().Names.of(r) or nil
    return n and (string.match(n, "^(%S+)") or n) or "them"
end
-- pre-1.0 MP (P4): work zones belong to the one shared co-op camp. World logic where the world is; "you" =
-- M.homePlayer (the base's player). MP client: menu writes = M.wzAct on the server (as the sender); reads = the
-- copy the server shares ("ALifeChatPlus_ZonesView"); the base box comes with the camp copy. SP: unchanged.
local function mpClient() return type(ALifeSide) == "table" and ALifeSide.mpClient() end
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
M.WZ_VIEW = "ALifeChatPlus_ZonesView"
local function wzTouch() if type(ALifeRemote) == "table" and mpServer() then ALifeRemote.touch(M.WZ_VIEW) end end
-- MP: is any online player within tiles of (x, y)? (SP: the old single-player checks stay as they were)
local function anyNear(x, y, tiles) return mpServer() and ALifeSide.nearest(x, y, tiles) ~= nil end
local function halo(text, r, g, b)
    if mpServer() then
        if type(ALifeOut) == "table" then ALifeOut.note(ALifeSide.cur, tostring(text), r or 230, g or 200, b or 140) end
        return
    end
    local p = ALifeSide.you()
    if p then pcall(ALifeLetter, p, tostring(text), r or 230, g or 200, b or 140) end
end
local function say(shell, line)
    if shell == nil or line == nil then return end
    pcall(function() PA().Speech.say(shell, line, {}) end)
end

----------------------------------------------------------------------------------------------------------------
-- settings: sandbox page ALifeChatPlus (WZ*), safe defaults when missing
----------------------------------------------------------------------------------------------------------------
M.wzDefaults = {
    WZMaxZones = 10, WZMaxDistance = 75, WZWhileAway = true,
    WZBurnSafeRadius = 5, WZBurnZombieRadius = 30, WZBurnWeather = true, WZBurnWatch = true, WZSqueamish = true,
    WZShovelSearch = 50, WZGraveLayOut = true,
}
function M.wzOpt(key)
    local sv = type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or nil
    local v = sv and sv[key]
    if v == nil then return M.wzDefaults[key] end
    return v
end

M.wzCfg = {
    maxSide = 60,            -- largest side of one zone (tiles)
    workersPerZone = 2,
    pickMs = 4000, dropMs = 2500, burnMs = 6000, digMs = 20000, fetchMs = 2000,
    walkTimeoutMs = 90000, banMs = 300000, retryMs = 10000,
    scanMs = 6000, tickMs = 1000,
    loadedTiles = 70,        -- base counts as loaded (real work) when you're this close to it
    playerSafeTiles = 25,    -- unseen catch-up never moves bodies this close to you
    awayPerWorkerHour = 6,   -- bodies per worker per game hour while you're away
    watchMaxMs = 600000,     -- one person watches the fire at most this long (real time)
    graveMinFromBase = 3, graveMaxFromBase = 20,
    shovelScanPerTick = 400,
}
M.wzStats = { carried = 0, dumped = 0, piled = 0, burns = 0, graves = 0, laidOut = 0, refused = 0, bans = 0, unseen = 0, evals = 0 }

----------------------------------------------------------------------------------------------------------------
-- saved state (in the mod's save store)
----------------------------------------------------------------------------------------------------------------
function M.wzData()
    local d = nil
    if mpClient() then -- read-only copy from the server
        d = type(ALifeRemote) == "table" and ALifeRemote.shared(M.WZ_VIEW) or nil
        if type(d) ~= "table" then M._wzEmpty = M._wzEmpty or {}; d = M._wzEmpty end
    else
        d = bucket("workzones")
    end
    d.zones = type(d.zones) == "table" and d.zones or {}
    d.graves = type(d.graves) == "table" and d.graves or {}
    d.nextId = tonumber(d.nextId) or 1
    return d
end
function M.wzZoneList()
    local out = {}
    for _, z in pairs(M.wzData().zones) do if type(z) == "table" then out[#out + 1] = z end end
    table.sort(out, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return out
end
function M.wzZoneAt(x, y, z)
    for _, zn in ipairs(M.wzZoneList()) do
        if (zn.z or 0) == (z or 0) and x >= zn.x1 and x <= zn.x2 and y >= zn.y1 and y <= zn.y2 then return zn end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- who works: people who live at your base and are home
----------------------------------------------------------------------------------------------------------------
local function thePlayer() return M.homePlayer and M.homePlayer() or ALifeSide.you() end -- MP: the base's player
function M.wzBase(player)
    if mpClient() then -- the base box comes with the camp copy (the A-Life base lives on the server)
        local v = fn(M, "cpView") and M.cpView() or nil
        return v and type(v.base) == "table" and tonumber(v.base.x1) and v.base or nil
    end
    if not fn(M, "alifeBase") then return nil end
    local ok, b = pcall(M.alifeBase, player or thePlayer())
    if (not ok or b == nil) and mpServer() and player ~= nil then -- MP co-op: a player without a base of their own works the camp's
        local hp = M.homePlayer and M.homePlayer() or nil
        if hp ~= nil and hp ~= player then ok, b = pcall(M.alifeBase, hp) end
    end
    return ok and b or nil
end
function M.wzIsWorker(uid, player)
    uid = tostring(uid)
    if M.partyIsMember then local ok, inParty = pcall(M.partyIsMember, uid, player); if ok and inParty then return false end end
    if fn(M, "withPlayer") and M.withPlayer(uid, player) then return false end -- 0.6.12: following you
    if fn(M, "settlerHome") and M.settlerHome(uid) then return true end
    local r = rec(uid)
    local res = r and type(r.memory) == "table" and r.memory.jimmyResident or nil
    if type(res) == "table" and r.memory.jimmyMission == nil then
        local R = ProjectALifeJimmy and ProjectALifeJimmy.Residents
        if R and type(R.isMember) == "function" then
            local ok, yes = pcall(R.isMember, res.baseId, player)
            return ok and yes == true
        end
    end
    return false
end
-- squeamish: soft traits clearly outweigh hard ones (stable per person)
local SOFT = { fearful = true, kind = true, romantic = true, cheerful = true, devout = true }
local HARD = { brave = true, mean = true, disciplined = true, volatile = true, unhinged = true, calm = true }
M.wzSoftCache = {}
function M.wzTemper(uid)
    uid = tostring(uid)
    local c = M.wzSoftCache[uid]
    if c ~= nil then return c end
    local soft, hard = 0, 0
    if fn(M, "traitChart") then
        local ok, chart = pcall(M.traitChart, uid, 8)
        if ok and type(chart) == "table" then
            for _, t in ipairs(chart) do
                if SOFT[t.key] then soft = soft + (tonumber(t.pct) or 0) end
                if HARD[t.key] then hard = hard + (tonumber(t.pct) or 0) end
            end
        end
    end
    local v = "fine"
    if soft - hard >= 20 then v = "squeamish" elseif soft > hard then v = "grumbles" end
    M.wzSoftCache[uid] = v
    return v
end
function M.wzSqueamish(uid) return M.wzOpt("WZSqueamish") ~= false and M.wzTemper(uid) == "squeamish" end

----------------------------------------------------------------------------------------------------------------
-- the world: bodies, containers, fire safety, zombies, weather
----------------------------------------------------------------------------------------------------------------
local function bodyUid(b)
    local who = nil
    pcall(function()
        if not b:hasModData() then return end
        local md = b:getModData()
        local uid = md.ProjectALifeUID or md.ALifeUID or md.alifeUid
        if uid then who = tostring(uid) end
    end)
    return who
end
local function bodiesOn(sq)
    local list = nil
    pcall(function() list = sq:getDeadBodys() end)
    return list
end
-- the first body on a square that's ours to move (not a fake-dead zombie, not someone waiting for a grave)
local function movableBody(sq)
    local list = bodiesOn(sq)
    if list == nil then return nil end
    local graves = M.wzData().graves
    local found = nil
    pcall(function()
        for i = 0, list:size() - 1 do
            local b = list:get(i)
            local fake = false
            pcall(function() fake = b:isFakeDead() end)
            local who = bodyUid(b)
            if not fake and not (who and graves[who]) then found = b; break end
        end
    end)
    return found
end
local function containerOn(sq)
    local c, o = nil, nil
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local x = objs:get(i)
            local cc = x:getContainer()
            if cc ~= nil then c, o = cc, x; break end
        end
    end)
    return c, o
end
local function containerName(o)
    local n = nil
    pcall(function() n = o:getContainer():getType() end)
    return n and string.lower(tostring(n)) or "container"
end

-- what makes a burn site unsafe (nil = safe, else a short reason)
local FLAM_PREFIX = { "walls_", "fencing_", "furniture_", "fixtures_", "carpentry_", "construction_", "location_" }
local function flammableOn(sq)
    local why = nil
    pcall(function()
        if sq:isInARoom() then why = "indoors"; return end
        if sq:getVehicleContainer() ~= nil then why = "a vehicle"; return end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if instanceof(o, "IsoTree") then why = "a tree"; return end
            if instanceof(o, "IsoDoor") or instanceof(o, "IsoWindow") then why = "a door or window"; return end
            if instanceof(o, "IsoThumpable") then why = "something built"; return end
            if o:getContainer() ~= nil then why = "a container"; return end
            local nm = nil
            pcall(function() nm = o:getSprite():getName() end)
            if nm then
                for _, p in ipairs(FLAM_PREFIX) do
                    if string.sub(nm, 1, #p) == p then why = (p == "walls_" and "a wall") or (p == "fencing_" and "a fence") or "something that burns"; return end
                end
            end
        end
    end)
    return why
end
function M.wzBurnUnsafe(x, y, z)
    local r = math.floor(tonumber(M.wzOpt("WZBurnSafeRadius")) or 5)
    local site = sqAt(x, y, z)
    if site == nil then return "not loaded" end
    if site:isInARoom() then return "indoors" end
    for dx = -r, r do
        for dy = -r, r do
            local sq = sqAt(x + dx, y + dy, z)
            if sq ~= nil then
                local why = flammableOn(sq)
                if why then return why .. " " .. math.floor(math.sqrt(dx * dx + dy * dy) + 0.5) .. " tiles away" end
            end
        end
    end
    return nil
end
-- zombies (not A-Life people riding zombie bodies) within tiles of a point
function M.wzZombiesNear(x, y, tiles)
    local n = 0
    pcall(function()
        local list = getCell():getZombieList()
        local Perc = PA().Perception
        local t2 = tiles * tiles
        for i = 0, list:size() - 1 do
            local zb = list:get(i)
            if not zb:isDead() and d2(zb:getX(), zb:getY(), x, y) <= t2 then
                local person = false
                if Perc and Perc.activeActorForShell then pcall(function() person = Perc.activeActorForShell(zb) ~= nil end) end
                if not person then n = n + 1 end
            end
        end
    end)
    return n
end
function M.wzBadWeather()
    if M.wzOpt("WZBurnWeather") == false then return false end
    local bad = false
    pcall(function()
        local cm = getClimateManager()
        if cm:getPrecipitationIntensity() > 0.05 or cm:getWindIntensity() > 0.5 then bad = true end
    end)
    return bad
end

-- items: lighter / petrol / shovel
local function isLighter(item)
    local ok = false
    pcall(function()
        if item:hasTag(ItemTag.START_FIRE) then ok = true; return end
        local t = item:getType()
        if t == "Lighter" or t == "Matches" then ok = true end
    end)
    return ok
end
local function isPetrol(item)
    local ok = false
    pcall(function()
        local fc = item:getFluidContainer()
        ok = fc ~= nil and fc:contains(Fluid.Petrol) and fc:getAmount() >= ZomboidGlobals.BurnCorpsePetrolAmount
    end)
    return ok
end
local function isShovel(item)
    local ok = false
    pcall(function() ok = item:hasTag(ItemTag.DIG_GRAVE) end)
    return ok
end
local function firstIn(container, test)
    if container == nil then return nil end
    local found = nil
    pcall(function()
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if test(it) then found = it; return end
        end
    end)
    return found
end
local function moveItem(item, dst)
    if item == nil or dst == nil then return false end
    return pcall(function()
        local src = item:getContainer()
        if src == dst then return end
        if src then src:DoRemoveItem(item) end
        dst:AddItem(item)
    end)
end
local function invOf(shell) local inv = nil; pcall(function() inv = shell:getInventory() end); return inv end
-- lighter + petrol: { } = already in their pockets, { spot, ... } = containers in the base to take them from, nil = none
function M.wzSupplies(shell, b)
    local inv = invOf(shell)
    local needL, needP = firstIn(inv, isLighter) == nil, firstIn(inv, isPetrol) == nil
    local spots = {}
    if not needL and not needP then return spots end
    for zz = 0, 1 do
        for x = b.x1, b.x2 do
            for y = b.y1, b.y2 do
                local sq = sqAt(x, y, zz)
                local c = sq and containerOn(sq)
                if c then
                    local hasL = needL and firstIn(c, isLighter) ~= nil
                    local hasP = needP and firstIn(c, isPetrol) ~= nil
                    if hasL or hasP then
                        spots[#spots + 1] = { x = x, y = y, z = zz }
                        if hasL then needL = false end
                        if hasP then needP = false end
                        if not needL and not needP then return spots end
                    end
                end
            end
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- zones: creation (the right-click flow), bodies in a zone
----------------------------------------------------------------------------------------------------------------
M.wzSel = nil -- { x, y, z } first corner, then { area = {x1,y1,x2,y2,z} } waiting for a drop point
function M.wzInRange(player, x, y)
    local b = M.wzBase(player)
    if b == nil then return false, "you need a base first" end
    local far = tonumber(M.wzOpt("WZMaxDistance")) or 75
    local cx = math.max(b.x1, math.min(b.x2, x))
    local cy = math.max(b.y1, math.min(b.y2, y))
    if d2(cx, cy, x, y) > far * far then return false, "too far from your base (" .. far .. " tiles max)" end
    return true
end
function M.wzAddZone(area, drop)
    local d = M.wzData()
    local id = d.nextId
    d.nextId = id + 1
    local zn = { id = id, x1 = area.x1, y1 = area.y1, x2 = area.x2, y2 = area.y2, z = area.z or 0,
        drop = { x = drop.x, y = drop.y, z = drop.z or 0, kind = drop.kind }, active = true, made = hours() }
    d.zones[tostring(id)] = zn
    M.wzScanCache[tostring(id)] = nil
    log("zone " .. id .. " added: " .. zn.x1 .. "," .. zn.y1 .. " to " .. zn.x2 .. "," .. zn.y2 .. " -> " .. drop.kind .. " at " .. drop.x .. "," .. drop.y)
    return zn
end
function M.wzRemoveZone(zn)
    local d = M.wzData()
    d.zones[tostring(zn.id)] = nil
    M.wzScanCache[tostring(zn.id)] = nil
    for uid, j in pairs(M.wzJobs) do if j.zone == zn.id then M.wzRelease(uid, nil) end end
    log("zone " .. tostring(zn.id) .. " removed")
end

-- bodies in a zone (cached a few seconds): { { x, y, z }, ... } one entry per body
M.wzScanCache = {}
local function isDropSquare(zn, x, y)
    return zn.drop and math.floor(zn.drop.x) == x and math.floor(zn.drop.y) == y
end
function M.wzBodies(zn, now)
    local key = tostring(zn.id)
    local c = M.wzScanCache[key]
    if c and now - c.at < M.wzCfg.scanMs then return c.list, c.loaded end
    local list, loaded = {}, true
    for x = zn.x1, zn.x2 do
        for y = zn.y1, zn.y2 do
            local sq = sqAt(x, y, zn.z)
            if sq == nil then loaded = false
            elseif not isDropSquare(zn, x, y) then
                local bl = bodiesOn(sq)
                local n = 0
                pcall(function() n = bl and bl:size() or 0 end)
                if n > 0 and movableBody(sq) ~= nil then
                    for _ = 1, n do list[#list + 1] = { x = x, y = y, z = zn.z } end
                end
            end
        end
    end
    M.wzScanCache[key] = { at = now, list = list, loaded = loaded }
    return list, loaded
end
local function pileCount(zn)
    local sq = sqAt(zn.drop.x, zn.drop.y, zn.drop.z)
    local n = 0
    if sq then pcall(function() n = sq:getDeadBodys():size() end) end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- graves: a spot by the base (natural ground, outdoors, two free tiles), the shovel search
----------------------------------------------------------------------------------------------------------------
local function naturalFloor(sq)
    local ok = false
    pcall(function()
        if sq:getZ() ~= 0 or sq:isInARoom() then return end
        local f = sq:getFloor()
        local t = f and f:getTextureName() or nil
        if t and (string.sub(t, 1, 23) == "floors_exterior_natural" or string.sub(t, 1, 17) == "blends_natural_01") then ok = true end
    end)
    return ok
end
local function graveFree(sq)
    if sq == nil or not naturalFloor(sq) then return false end
    if flammableOn(sq) ~= nil then return false end -- nothing standing there (trees, walls, containers, built things)
    local busy = false
    pcall(function()
        if sq:getDeadBodys():size() > 0 then busy = true end
        local sp = sq:getSpecialObjects()
        if sp:size() > 0 then busy = true end
    end)
    return not busy
end
function M.wzGraveSpot(b, taken)
    local cfg = M.wzCfg
    for r = cfg.graveMinFromBase, cfg.graveMaxFromBase do
        for dx = -r, r do
            for _, dy in ipairs({ -r, r }) do
                for _, pair in ipairs({ { b.x2 + 1 + dx, b.y1 + dy }, { b.x1 - 1 + dx, b.y2 + dy } }) do
                    local x, y = pair[1], pair[2]
                    if not (x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2) and not (taken and taken[x .. ":" .. y]) then
                        local s1, s2 = sqAt(x, y, 0), sqAt(x - 1, y, 0)
                        if graveFree(s1) and graveFree(s2) then return { x = x, y = y, z = 0 } end
                    end
                end
            end
        end
    end
    return nil
end
-- shovel: scanned outward from the base a slice per tick; remembers the last container that had one
M.wzShovelScan = { r = 0, i = 0, found = nil, at = 0 }
function M.wzShovelStep(b)
    local s = M.wzShovelScan
    local maxR = math.floor(tonumber(M.wzOpt("WZShovelSearch")) or 50)
    if s.found then
        local sq = sqAt(s.found.x, s.found.y, s.found.z)
        local c = sq and containerOn(sq)
        if c and firstIn(c, isShovel) then return s.found end
        s.found = nil
    end
    local budget = M.wzCfg.shovelScanPerTick
    while budget > 0 do
        if s.r > maxR then s.r, s.i = 0, 0; return nil end
        local r = s.r
        local side = (r == 0) and 1 or (8 * r)
        if s.i >= side then s.r, s.i = r + 1, 0
        else
            local k = s.i
            local x, y
            if r == 0 then x, y = 0, 0
            elseif k < 2 * r then x, y = -r + k, -r
            elseif k < 4 * r then x, y = r, -r + (k - 2 * r)
            elseif k < 6 * r then x, y = r - (k - 4 * r), r
            else x, y = -r, r - (k - 6 * r) end
            s.i = k + 1
            for zz = 0, 1 do
                local sq = sqAt(b.x + x, b.y + y, zz)
                if sq then
                    local c = containerOn(sq)
                    if c and firstIn(c, isShovel) then s.found = { x = b.x + x, y = b.y + y, z = zz }; return s.found end
                end
            end
        end
        budget = budget - 1
    end
    return nil
end
-- someone from the base died: queue a burial
function M.wzOnDeath(body, uid, killer)
    uid = tostring(uid)
    local isOurs = fn(M, "settlerOf") and M.settlerOf(uid) ~= nil
    if not isOurs then
        for _, e in ipairs(bucket("baseLost")) do if tostring(e.uid) == uid and hours() - (tonumber(e.h) or -99) < 0.2 then isOurs = true end end
    end
    if not isOurs then
        local r = rec(uid)
        local res = r and type(r.memory) == "table" and r.memory.jimmyResident or nil
        local R = ProjectALifeJimmy and ProjectALifeJimmy.Residents
        if type(res) == "table" and R and type(R.isMember) == "function" then
            local ok, yes = pcall(R.isMember, res.baseId, thePlayer())
            isOurs = ok and yes == true
        end
    end
    if not isOurs then return end
    local x, y, z = pos(body)
    if x == nil then return end
    M.wzData().graves[uid] = { uid = uid, name = firstName(uid), x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), h = hours() }
    log("burial queued for " .. firstName(uid) .. " at " .. math.floor(x) .. "," .. math.floor(y))
end
-- the body of someone waiting for burial (near where they fell, or where it was laid out)
local function graveBody(g)
    local cx, cy = g.laid and g.site.x or g.x, g.laid and g.site.y or g.y
    for dx = -2, 2 do
        for dy = -2, 2 do
            local sq = sqAt(cx + dx, cy + dy, g.laid and 0 or g.z)
            local list = sq and bodiesOn(sq)
            if list then
                local found = nil
                pcall(function()
                    for i = 0, list:size() - 1 do
                        local b = list:get(i)
                        if bodyUid(b) == g.uid then found = b; return end
                    end
                end)
                if found then return found, sq end
            end
        end
    end
    return nil, nil
end

----------------------------------------------------------------------------------------------------------------
-- jobs: one per worker. steps walk somewhere, then do something there.
----------------------------------------------------------------------------------------------------------------
M.wzJobs, M.wzClaims, M.wzBans, M.wzNextTry = {}, {}, {}, {}
local function claim(key, uid)
    local o = M.wzClaims[key]
    if o ~= nil and o ~= uid then return false end
    if (M.wzBans[key] or 0) > nowMs() then return false end
    M.wzClaims[key] = uid
    return true
end
local function zoneWorkers(zid)
    local n = 0
    for _, j in pairs(M.wzJobs) do if j.zone == zid then n = n + 1 end end
    return n
end
-- never lose a body or a borrowed tool: whatever they hold goes back into the world
function M.wzRelease(uid, shell)
    uid = tostring(uid)
    local j = M.wzJobs[uid]
    if j == nil then return end
    if j.item ~= nil then
        local x, y, z = pos(shell)
        if x == nil then x, y, z = j.from.x, j.from.y, j.from.z end
        local sq = sqAt(x, y, z) or sqAt(j.from.x, j.from.y, j.from.z)
        local ok = sq and pcall(function() sq:tryAddCorpseToWorld(j.item, 0.5, 0.5) end)
        if not ok then log("could not put a carried body back down (" .. tostring(j.kind) .. ")") end
        j.item = nil
    end
    if j.tools and shell then
        local inv = invOf(shell)
        for _, t in ipairs(j.tools) do
            if t.back then
                local sq = sqAt(t.back.x, t.back.y, t.back.z)
                local c = sq and containerOn(sq)
                if c and inv and t.item:getContainer() == inv then moveItem(t.item, c) end
            end
        end
    end
    if j.key and M.wzClaims[j.key] == uid then M.wzClaims[j.key] = nil end
    M.wzJobs[uid] = nil
end

local GRUMBLE = { "Every damn day, more of these.", "I'm not doing this forever.", "Hold your breath and pull.", "Smells like hell out here.", "Somebody else's turn next time." }
local REFUSE = { "I can't. I can't touch them.", "Don't ask me to do that. Please.", "Not the bodies. Anything but that.", "Get someone else. I'll be sick." }
local OK_LINES = { "Alright. I'll get them moved.", "Yeah, I'll deal with the bodies.", "On it.", "Fine. Gloves on." }
local NOZONE = { "Where do you want them? Show me.", "Mark out where, and where they go.", "Which bodies? Show me the spot." }
local STOP_LINES = { "Leaving them where they are.", "Fine, I'll stop.", "Alright, they stay." }

-- pick a job: burials first, then a burn that's ready, then carrying bodies
function M.wzPick(uid, shell, player, now)
    local cfg = M.wzCfg
    local d = M.wzData()
    local b = M.wzBase(player)
    if b == nil then return nil end
    local sx, sy, sz = pos(shell)
    -- 1) burials (everyone helps bury their own)
    for guid, g in pairs(d.graves) do
        if claim("grave:" .. guid, uid) then
            local body, bsq = graveBody(g)
            if body == nil then
                if hours() - (tonumber(g.h) or 0) > 2 and not g.laid then
                    d.graves[guid] = nil -- gone (got up, or someone moved it): nothing to bury
                    log("burial for " .. tostring(g.name) .. " dropped: body not found")
                end
                M.wzClaims["grave:" .. guid] = nil
            else
                g.site = g.site or M.wzGraveSpot(b, nil)
                if g.site == nil then M.wzClaims["grave:" .. guid] = nil
                else
                    local j = { kind = "grave", key = "grave:" .. guid, grave = guid, step = "fetch", from = { x = bsq:getX(), y = bsq:getY(), z = bsq:getZ() } }
                    -- shovel: in their pockets, else the nearest container that has one
                    local inv = invOf(shell)
                    local own = firstIn(inv, isShovel)
                    if own then j.shovel = own; j.step = "body"
                    else
                        local spot = M.wzShovelStep(b)
                        if spot then j.shovelAt = spot
                        elseif g.laid then M.wzClaims["grave:" .. guid] = nil; j = nil -- laid out already, still no shovel: wait
                        else j.step = "body"; j.layOut = M.wzOpt("WZGraveLayOut") ~= false end
                    end
                    if j then
                        if j.layOut == false then M.wzClaims["grave:" .. guid] = nil
                        else return j end
                    end
                end
            end
        end
    end
    if M.wzSqueamish(uid) then return nil end
    -- 2) a burn site whose batch is done
    for _, zn in ipairs(M.wzZoneList()) do
        if zn.active and zn.drop.kind == "burn" and zn.ready and (zn.waitUntil or 0) <= now and claim("burn:" .. zn.id, uid) then
            local why = nil
            local site = sqAt(zn.drop.x, zn.drop.y, zn.drop.z)
            local burning = false
            if site then pcall(function() burning = site:haveFire() end) end
            if burning then why = "already burning"
            elseif pileCount(zn) == 0 then why = "nothing to burn"; zn.ready = nil
            elseif M.wzZombiesNear(zn.drop.x, zn.drop.y, tonumber(M.wzOpt("WZBurnZombieRadius")) or 30) > 0 then why = "zombies"
            elseif M.wzBadWeather() then why = "weather"
            else
                local unsafe = M.wzBurnUnsafe(zn.drop.x, zn.drop.y, zn.drop.z)
                if unsafe then
                    why = "unsafe"
                    if zn.unsafeSaid ~= unsafe then zn.unsafeSaid = unsafe; halo("Burn site " .. zn.id .. " isn't safe anymore: " .. unsafe, 255, 150, 110) end
                end
            end
            local fetch = nil
            if why == nil then
                fetch = M.wzSupplies(shell, b)
                if fetch == nil then
                    why = "supplies"
                    zn.waitUntil = now + 60000
                    if not zn.supplySaid then
                        zn.supplySaid = true
                        halo("Burn site " .. zn.id .. " needs a lighter and petrol (carried, or in a container in the base).", 255, 170, 110)
                    end
                end
            end
            if why == nil then
                zn.supplySaid = nil
                local j = { kind = "burn", key = "burn:" .. zn.id, zone = zn.id, fetch = fetch, fi = 1, tools = {},
                    step = (#fetch > 0) and "supplies" or "light", from = { x = sx, y = sy, z = sz } }
                return j
            end
            M.wzClaims["burn:" .. zn.id] = nil
        end
    end
    -- 3) carry a body
    for _, zn in ipairs(M.wzZoneList()) do
        if zn.active and not zn.ready and zoneWorkers(zn.id) < cfg.workersPerZone then
            local list = M.wzBodies(zn, now)
            local best, bd = nil, nil
            for _, t in ipairs(list) do
                local key = "body:" .. t.x .. ":" .. t.y
                if (M.wzClaims[key] == nil or M.wzClaims[key] == uid) and (M.wzBans[key] or 0) <= now then
                    local dd = d2(t.x, t.y, sx or t.x, sy or t.y)
                    if bd == nil or dd < bd then best, bd = t, dd end
                end
            end
            if best and claim("body:" .. best.x .. ":" .. best.y, uid) then
                if zn.drop.kind == "burn" and zn.batchLeft == nil then zn.batchLeft = #list end
                return { kind = "carry", key = "body:" .. best.x .. ":" .. best.y, zone = zn.id, step = "body", from = { x = best.x, y = best.y, z = best.z } }
            end
            -- area clear and bodies were carried since the last fire: burn what is there
            if #list == 0 and zn.drop.kind == "burn" and (zn.carried or 0) > 0 and pileCount(zn) > 0 then zn.ready = true; zn.batchLeft = nil end
        end
    end
    return nil
end

-- where the current step walks to
local function stepSpot(j)
    local d = M.wzData()
    if j.step == "fetch" and j.shovelAt then return j.shovelAt end
    if j.step == "body" then return j.from end
    if j.kind == "carry" and j.step == "drop" then
        local zn = d.zones[tostring(j.zone)]
        return zn and zn.drop or nil
    end
    if j.kind == "grave" then
        local g = d.graves[j.grave]
        if g == nil or g.site == nil then return nil end
        if j.step == "dig" or j.step == "lay" then return { x = g.site.x + 1, y = g.site.y, z = 0 } end
        if j.step == "return" then return j.shovelAt end
    end
    if j.kind == "burn" then
        local zn = d.zones[tostring(j.zone)]
        if zn == nil then return nil end
        if j.step == "supplies" then return j.fetch[j.fi] end
        if j.step == "light" then return { x = zn.drop.x + 1, y = zn.drop.y, z = zn.drop.z } end
        if j.step == "watch" then return { x = zn.drop.x + 3, y = zn.drop.y + 1, z = zn.drop.z } end
        if j.step == "return" then return j.fetch[j.fi] end
    end
    return nil
end
local function stepMs(j)
    local c = M.wzCfg
    if j.step == "body" then return c.pickMs end
    if j.step == "drop" or j.step == "lay" then return c.dropMs end
    if j.step == "dig" then return c.digMs end
    if j.step == "light" then return c.burnMs end
    if j.step == "watch" then return 3000 end
    return c.fetchMs
end
local function stepAnim(j)
    if j.step == "dig" then return "chop" end
    if j.step == "light" then return "search_low" end
    if j.step == "watch" then return nil end
    return "search_low"
end

-- place a filled grave over two tiles (vanilla's filled-grave sprites: empty sprite + 8)
function M.wzPlaceGrave(site)
    local ob = PA().OutpostBuilder
    if not fn(ob, "placeMapTile") then return false end
    local a = ob.placeMapTile(site.x, site.y, 0, "location_community_cemetary_01_41")
    local b = ob.placeMapTile(site.x - 1, site.y, 0, "location_community_cemetary_01_40")
    for _, o in ipairs({ a, b }) do
        if o ~= nil then
            pcall(function()
                o:setName("EmptyGraves")
                local md = o:getModData()
                md.filled = true; md.corpses = 1; md.chatplusGrave = true
            end)
        end
    end
    return a ~= nil and b ~= nil
end

-- finish the current step; returns "next" | "done" | "fail"
function M.wzDo(j, uid, shell, player)
    local d = M.wzData()
    local inv = invOf(shell)
    if j.kind == "carry" then
        local zn = d.zones[tostring(j.zone)]
        if zn == nil then return "fail" end
        if j.step == "body" then
            local sq = sqAt(j.from.x, j.from.y, j.from.z)
            local body = sq and movableBody(sq)
            if body == nil then M.wzScanCache[tostring(zn.id)] = nil; return "done" end
            local ok, item = pcall(function() return body:becomeCorpseItem(false) end)
            if not ok or item == nil then return "fail" end
            j.item = item
            M.wzStats.carried = M.wzStats.carried + 1
            M.wzScanCache[tostring(zn.id)] = nil
            if M.wzTemper(uid) == "grumbles" and (hash(uid .. M.wzStats.carried) % 4) == 0 then say(shell, GRUMBLE[(hash(uid .. "g" .. M.wzStats.carried) % #GRUMBLE) + 1]) end
            j.step = "drop"
            return "next"
        end
        if j.step == "drop" then
            local dsq = sqAt(zn.drop.x, zn.drop.y, zn.drop.z)
            if dsq == nil then return "fail" end
            local placed = false
            if zn.drop.kind == "container" then
                local c = containerOn(dsq)
                if c then
                    local fits = false
                    pcall(function() fits = c:getContentsWeight() + j.item:getActualWeight() <= c:getCapacity() end)
                    if fits and pcall(function() c:AddItem(j.item) end) then
                        pcall(function() sendAddItemToContainer(c, j.item) end)
                        placed = true; M.wzStats.dumped = M.wzStats.dumped + 1
                    end
                end
                if not placed then -- full (or gone): pile it beside
                    local side = sqAt(zn.drop.x + 1, zn.drop.y, zn.drop.z) or dsq
                    placed = pcall(function() side:tryAddCorpseToWorld(j.item, 0.5, 0.5) end)
                    if placed then
                        M.wzStats.piled = M.wzStats.piled + 1
                        if not zn.fullSaid then zn.fullSaid = true; say(shell, "The " .. (zn.dropName or "bin") .. " is full. I'm piling them next to it.") end
                    end
                end
            else
                local ox = 0.25 + (hash(uid .. M.wzStats.carried) % 50) / 100
                local oy = 0.25 + (hash(uid .. "y" .. M.wzStats.carried) % 50) / 100
                placed = pcall(function() dsq:tryAddCorpseToWorld(j.item, ox, oy) end)
                if placed then M.wzStats.piled = M.wzStats.piled + 1 end
            end
            if not placed then return "fail" end
            j.item = nil
            if zn.drop.kind == "burn" then zn.carried = (zn.carried or 0) + 1 end
            if zn.drop.kind == "burn" and zn.batchLeft then
                zn.batchLeft = zn.batchLeft - 1
                if zn.batchLeft <= 0 then zn.ready = true; zn.batchLeft = nil end
            end
            return "done"
        end
    end
    if j.kind == "grave" then
        local g = d.graves[j.grave]
        if g == nil then return "done" end
        if j.step == "fetch" then
            local sq = sqAt(j.shovelAt.x, j.shovelAt.y, j.shovelAt.z)
            local c = sq and containerOn(sq)
            local sh = c and firstIn(c, isShovel)
            if sh == nil or not moveItem(sh, inv) then M.wzShovelScan.found = nil; return "fail" end
            j.shovel = sh
            j.tools = { { item = sh, back = j.shovelAt } }
            j.step = "body"
            return "next"
        end
        if j.step == "body" then
            local body = graveBody(g)
            if body == nil then return "fail" end
            local ok, item = pcall(function() return body:becomeCorpseItem(false) end)
            if not ok or item == nil then return "fail" end
            j.item = item
            j.step = j.shovel and "dig" or "lay"
            return "next"
        end
        if j.step == "lay" then
            local sq = sqAt(g.site.x, g.site.y, 0)
            if sq == nil or not pcall(function() sq:tryAddCorpseToWorld(j.item, 0.5, 0.5) end) then return "fail" end
            j.item = nil
            g.laid = true
            M.wzStats.laidOut = M.wzStats.laidOut + 1
            say(shell, "I laid " .. tostring(g.name) .. " out by the house. We need a shovel to bury them.")
            halo(tostring(g.name) .. " is laid out by the base. Someone needs a shovel to bury them.", 230, 210, 160)
            return "done"
        end
        if j.step == "dig" then
            if not M.wzPlaceGrave(g.site) then return "fail" end
            j.item = nil -- the body goes into the grave
            d.graves[j.grave] = nil
            M.wzStats.graves = M.wzStats.graves + 1
            log("buried " .. tostring(g.name) .. " at " .. g.site.x .. "," .. g.site.y)
            for o in pairs(bucket("settlers")) do
                if M.keyMem then pcall(M.keyMem, o, "loss", "we buried " .. tostring(g.name) .. " by the house") end
            end
            say(shell, "Rest easy, " .. tostring(g.name) .. ".")
            if j.shovelAt then j.step = "return"; return "next" end
            return "done"
        end
        if j.step == "return" then
            local sq = sqAt(j.shovelAt.x, j.shovelAt.y, j.shovelAt.z)
            local c = sq and containerOn(sq)
            if c and j.shovel then moveItem(j.shovel, c) end
            j.tools = nil
            return "done"
        end
    end
    if j.kind == "burn" then
        local zn = d.zones[tostring(j.zone)]
        if zn == nil then return "fail" end
        if j.step == "supplies" then
            local spot = j.fetch[j.fi]
            local sq = sqAt(spot.x, spot.y, spot.z)
            local c = sq and containerOn(sq)
            if c then
                if firstIn(inv, isLighter) == nil then local l = firstIn(c, isLighter); if l and moveItem(l, inv) then j.tools[#j.tools + 1] = { item = l, back = spot } end end
                if firstIn(inv, isPetrol) == nil then local p = firstIn(c, isPetrol); if p and moveItem(p, inv) then j.tools[#j.tools + 1] = { item = p, back = spot } end end
            end
            if j.fi < #j.fetch then j.fi = j.fi + 1; return "next" end
            if firstIn(inv, isLighter) == nil or firstIn(inv, isPetrol) == nil then return "fail" end
            j.step = "light"
            return "next"
        end
        if j.step == "light" then
            local sq = sqAt(zn.drop.x, zn.drop.y, zn.drop.z)
            if sq == nil then return "fail" end
            local lighter, petrol = firstIn(inv, isLighter), firstIn(inv, isPetrol)
            if lighter == nil or petrol == nil then return "fail" end
            j.lighter, j.petrol = lighter, petrol
            local ok = pcall(function() IsoFireManager.StartFire(getCell(), sq, true, 100, 700) end)
            if not ok then log("fire did not start at burn site " .. zn.id); return "fail" end
            pcall(function()
                local fc = j.petrol:getFluidContainer()
                fc:adjustAmount(fc:getAmount() - ZomboidGlobals.BurnCorpsePetrolAmount)
            end)
            pcall(function() j.lighter:UseAndSync() end)
            M.wzStats.burns = M.wzStats.burns + 1
            zn.ready, zn.batchLeft, zn.carried = nil, nil, 0
            zn.burnedAt = hours()
            log("burn site " .. zn.id .. " lit (" .. pileCount(zn) .. " bodies)")
            if M.wzOpt("WZBurnWatch") ~= false then j.step = "watch"; j.watchFrom = nowMs(); return "next" end
            if #j.tools > 0 then j.step = "return"; j.fi = 1; return "next" end
            return "done"
        end
        if j.step == "watch" then
            local sq = sqAt(zn.drop.x, zn.drop.y, zn.drop.z)
            local burning = false
            if sq then pcall(function() burning = sq:haveFire() end) end
            if burning and nowMs() - (j.watchFrom or 0) < M.wzCfg.watchMaxMs then return "again" end
            log("burn site " .. zn.id .. " is out (" .. pileCount(zn) .. " bodies left on the pile)")
            if #j.tools > 0 then j.step = "return"; j.fi = 1; return "next" end
            return "done"
        end
        if j.step == "return" then
            local spot = j.fetch[j.fi]
            local sq = sqAt(spot.x, spot.y, spot.z)
            local c = sq and containerOn(sq)
            if c then
                for _, t in ipairs(j.tools) do
                    if t.back == spot and t.item:getContainer() == inv then moveItem(t.item, c) end
                end
            end
            if j.fi < #j.fetch then j.fi = j.fi + 1; return "next" end
            j.tools = nil
            return "done"
        end
    end
    return "fail"
end

----------------------------------------------------------------------------------------------------------------
-- A-Life behaviour module
----------------------------------------------------------------------------------------------------------------
function M.wzEvaluate(actor, shell, context)
    if shell == nil or type(context) ~= "table" or type(actor) ~= "table" then return nil end
    local uid = tostring(actor.uid)
    local player = M.homePlayer and M.homePlayer(pos(shell)) or thePlayer() -- MP: the base's player nearest them
    if context.threat ~= nil then
        if M.wzJobs[uid] then M.wzRelease(uid, shell) end
        return nil
    end
    local j = M.wzJobs[uid]
    if type(M.alHolds) == "function" and M.alHolds(uid, player) then -- camp alarm: drop the shovel
        if j then M.wzRelease(uid, shell) end
        return nil
    end
    if j == nil and not hasAny(M.wzData().zones) and not hasAny(M.wzData().graves) then return nil end
    if not M.wzIsWorker(uid, player) then
        if j then M.wzRelease(uid, shell) end
        return nil
    end
    M.wzStats.evals = M.wzStats.evals + 1
    local now = tonumber(context.now) or nowMs()
    CLOCK.t, CLOCK.at = now, rawMs()
    if j == nil then
        if (M.wzNextTry[uid] or 0) > now then return nil end
        j = M.wzPick(uid, shell, player, now)
        if j == nil then M.wzNextTry[uid] = now + M.wzCfg.retryMs; return nil end
        j.started = now
        M.wzJobs[uid] = j
    end
    local spot = stepSpot(j)
    if spot == nil then M.wzRelease(uid, shell); return nil end
    local sx, sy = pos(shell)
    if sx == nil then M.wzRelease(uid, shell); return nil end
    if d2(sx, sy, spot.x + 0.5, spot.y + 0.5) > 1.8 ^ 2 then
        j.workFrom = nil
        if now - (j.stepAt or j.started) > M.wzCfg.walkTimeoutMs then
            M.wzBans[j.key] = now + M.wzCfg.banMs
            M.wzStats.bans = M.wzStats.bans + 1
            M.wzRelease(uid, shell)
            return nil
        end
        if type(context.startMovement) ~= "function" then M.wzRelease(uid, shell); return nil end
        return context.startMovement(actor, shell, { x = spot.x + 0.5, y = spot.y + 0.5, z = spot.z or 0 }, "chatplus_" .. j.kind,
            { pace = "walk", timeoutMs = 15000, tolerance = 1.2 })
    end
    j.workFrom = j.workFrom or now
    local anim = PA().Animations
    local a = stepAnim(j)
    if a and fn(anim, "apply") then pcall(anim.apply, shell, a) end
    if type(context.setActivity) == "function" then pcall(context.setActivity, actor, "idle", "chatplus_" .. j.kind) end
    if now - j.workFrom < stepMs(j) then return { kind = "idle", intent = "chatplus_" .. j.kind, cooldownUntilMs = now + 1000 } end
    local ok, res = pcall(M.wzDo, j, uid, shell, player)
    if fn(anim, "clear") then pcall(anim.clear, shell) end
    if not ok then log("step error (" .. tostring(j.kind) .. "/" .. tostring(j.step) .. "): " .. tostring(res)); res = "fail" end
    if res == "next" then j.workFrom = nil; j.stepAt = now
    elseif res == "again" then j.workFrom = nil
    else
        if res == "fail" then M.wzBans[j.key] = now + 30000 end
        M.wzRelease(uid, shell)
    end
    return { kind = "idle", intent = "chatplus_" .. j.kind, cooldownUntilMs = now + 1500 }
end
function M.wzRegister()
    if M._wzRegistered then return true end
    local reg = PA().ModuleRegistry
    if not fn(reg, "register") then return false end
    local ok, done, why = pcall(reg.register, {
        id = "chatplus_zones", label = "NPC Overhaul: work zones",
        summary = "People at your base clear bodies from marked areas, burn them, and bury their own.",
        kind = "orders", priority = 92, defaultEnabled = true,
        evaluate = function(actor, shell, context)
            local ok2, res = pcall(M.wzEvaluate, actor, shell, context)
            if not ok2 then
                if not M._wzErr then M._wzErr = true; log("module error (logged once): " .. tostring(res)) end
                return nil
            end
            return res
        end,
    })
    if ok and (done == true or (done == false and tostring(why):find("duplicate", 1, true))) then
        local prof = PA().BehaviorProfiles
        local n = 0
        if type(prof) == "table" and type(prof.definitions) == "table" then
            for _, def in ipairs(prof.definitions) do
                if type(def) == "table" and type(def.overlays) == "table" then def.overlays.chatplus_zones = true; n = n + 1 end
            end
        end
        if n == 0 then log("A-Life behaviour profiles not found - work zones may never run") end
        M._wzRegistered = true
        log("registered with A-Life's behaviour modules (priority 92, " .. n .. " profiles)")
        return true
    end
    log("could not register with A-Life: " .. tostring(why or done))
    return false
end

----------------------------------------------------------------------------------------------------------------
-- while you're away: bodies get moved on a ledger, settled when you come back (never within 25 tiles of you)
----------------------------------------------------------------------------------------------------------------
function M.wzWorkersHome(player)
    local n = 0
    for uid in pairs(bucket("settlers")) do
        if M.wzIsWorker(uid, player) and not M.wzSqueamish(uid) then n = n + 1 end
    end
    return math.min(n, M.wzCfg.workersPerZone)
end
function M.wzCatchUp(player, px, py, awayH)
    if M.wzOpt("WZWhileAway") == false or awayH < 1 then return end
    local workers = M.wzWorkersHome(player)
    if workers == 0 then return end
    local budget = math.floor(awayH * workers * M.wzCfg.awayPerWorkerHour)
    local safe2 = M.wzCfg.playerSafeTiles ^ 2
    local moved = 0
    for _, zn in ipairs(M.wzZoneList()) do
        if zn.active and budget > 0 and d2(zn.drop.x, zn.drop.y, px, py) > safe2 and not anyNear(zn.drop.x, zn.drop.y, M.wzCfg.playerSafeTiles) then
            M.wzScanCache[tostring(zn.id)] = nil
            local list, loaded = M.wzBodies(zn, nowMs())
            if loaded then
                local dsq = sqAt(zn.drop.x, zn.drop.y, zn.drop.z)
                local c = (zn.drop.kind == "container" and dsq) and containerOn(dsq) or nil
                for _, t in ipairs(list) do
                    if budget <= 0 then break end
                    if d2(t.x, t.y, px, py) > safe2 and not anyNear(t.x, t.y, M.wzCfg.playerSafeTiles) then
                        local sq = sqAt(t.x, t.y, t.z)
                        local body = sq and movableBody(sq)
                        if body and dsq then
                            if zn.drop.kind == "burn" then
                                -- burned while you were away: the body is gone, the pile is ash
                                if pcall(function() sq:removeCorpse(body, false) end) then moved = moved + 1; budget = budget - 1 end
                            else
                                local ok, item = pcall(function() return body:becomeCorpseItem(false) end)
                                if ok and item then
                                    local placed = false
                                    if c then
                                        pcall(function() if c:getContentsWeight() + item:getActualWeight() <= c:getCapacity() then c:AddItem(item); placed = true end end)
                                    end
                                    if not placed then placed = pcall(function() dsq:tryAddCorpseToWorld(item, 0.5, 0.5) end) end
                                    if placed then moved = moved + 1; budget = budget - 1 end
                                end
                            end
                        end
                    end
                end
            end
            M.wzScanCache[tostring(zn.id)] = nil
        end
    end
    if moved > 0 then
        M.wzStats.unseen = M.wzStats.unseen + moved
        log("while you were away: " .. moved .. " bodies cleared (" .. math.floor(awayH) .. " h, " .. workers .. " workers)")
    end
end

----------------------------------------------------------------------------------------------------------------
-- tick (1 s): registration, the away ledger
----------------------------------------------------------------------------------------------------------------
M.wzLastTick = 0
function M.wzTick()
    local now = rawMs()
    if now - M.wzLastTick < M.wzCfg.tickMs then return end
    M.wzLastTick = now
    if not M._wzRegistered then pcall(M.wzRegister) end
    local d = M.wzData()
    if not hasAny(d.zones) and not hasAny(d.graves) then return end
    local player = thePlayer()
    local px, py = pos(player)
    local b = px and M.wzBase(player) or nil
    if b == nil then return end
    if mpServer() then -- MP: "near" = any online player near the base (the nearest one stands in for you)
        local np = ALifeSide.nearest(b.x, b.y)
        if np ~= nil then player = np; px, py = pos(np) end
    end
    local h = hours()
    local near = d2(b.x, b.y, px, py) <= M.wzCfg.loadedTiles ^ 2
    if near then
        if d.awayFrom then
            local awayH = h - d.awayFrom
            d.awayFrom = nil
            pcall(M.wzCatchUp, player, px, py, awayH)
        end
        if hasAny(d.graves) then pcall(M.wzShovelStep, b) end
    elseif d.awayFrom == nil then
        d.awayFrom = h
    end
end

----------------------------------------------------------------------------------------------------------------
-- the right-click menu
----------------------------------------------------------------------------------------------------------------
function M.wzContext(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    local sq = nil
    for _, o in ipairs(worldobjects or {}) do
        pcall(function() sq = o:getSquare() end)
        if sq then break end
    end
    if sq == nil or player == nil then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local parent = context:addOption(ALifeTr("IGUI_ALCP_Menu_Work_zones", "Work zones"))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(parent, sub)
    local inRange, why = M.wzInRange(player, x, y)
    local function off(opt, reason)
        opt.notAvailable = true
        local tip = ISWorldObjectContextMenu.addToolTip()
        tip.description = reason
        opt.toolTip = tip
    end
    local pick = M.wzSel
    if pick == nil then
        local opt = sub:addOption(ALifeTr("IGUI_ALCP_Menu_Body_cleanup_first_corner_here", "Body cleanup: first corner here"), nil, function()
            M.wzSel = { x = x, y = y, z = z }
            halo("First corner set. Right-click the opposite corner.")
        end)
        local count = #M.wzZoneList()
        local maxZ = tonumber(M.wzOpt("WZMaxZones")) or 10
        if not inRange then off(opt, why)
        elseif count >= maxZ then off(opt, "You already have " .. count .. " work zones (max " .. maxZ .. ").") end
    elseif pick.area == nil then
        local opt = sub:addOption(ALifeTr("IGUI_ALCP_Menu_Body_cleanup_opposite_corner_here", "Body cleanup: opposite corner here"), nil, function()
            local a = { x1 = math.min(pick.x, x), y1 = math.min(pick.y, y), x2 = math.max(pick.x, x), y2 = math.max(pick.y, y), z = pick.z }
            M.wzSel = { area = a }
            halo("Area set. Now right-click where the bodies go: the ground, a container, or a burn site.")
        end)
        if z ~= pick.z then off(opt, "Both corners must be on the same floor.")
        elseif math.abs(x - pick.x) + 1 > M.wzCfg.maxSide or math.abs(y - pick.y) + 1 > M.wzCfg.maxSide then off(opt, "Too big. Keep each side under " .. M.wzCfg.maxSide .. " tiles.")
        elseif not inRange then off(opt, why) end
        sub:addOption(ALifeTr("IGUI_ALCP_Menu_Cancel", "Cancel"), nil, function() M.wzSel = nil end)
    else
        local a = pick.area
        local o1 = sub:addOption(ALifeTr("IGUI_ALCP_Menu_Drop_bodies_here_pile", "Drop bodies here (pile)"), nil, function()
            M.wzSel = nil
            M.wzAct("zone", a.x1, a.y1, a.x2, a.y2, a.z, x, y, z, "ground", player)
        end)
        if not inRange then off(o1, why) end
        local c, co = containerOn(sq)
        if c then
            local nm = containerName(co)
            local o2 = sub:addOption("Drop bodies in this " .. nm, nil, function()
                M.wzSel = nil
                M.wzAct("zone", a.x1, a.y1, a.x2, a.y2, a.z, x, y, z, "container", player)
            end)
            if not inRange then off(o2, why) end
        end
        local o3 = sub:addOption(ALifeTr("IGUI_ALCP_Menu_Burn_site_here", "Burn site here"), nil, function()
            local unsafe = M.wzBurnUnsafe(x, y, z)
            if unsafe then halo("Can't burn here: " .. unsafe .. ".", 255, 150, 110); return end
            M.wzSel = nil
            M.wzAct("zone", a.x1, a.y1, a.x2, a.y2, a.z, x, y, z, "burn", player)
        end)
        local unsafe = M.wzBurnUnsafe(x, y, z)
        if not inRange then off(o3, why) elseif unsafe then off(o3, "Too close to " .. unsafe .. ".") end
        sub:addOption(ALifeTr("IGUI_ALCP_Menu_Cancel", "Cancel"), nil, function() M.wzSel = nil end)
    end
    local zn = M.wzZoneAt(x, y, z)
    if zn then
        sub:addOption(zn.active and ("Pause work zone " .. zn.id) or ("Resume work zone " .. zn.id), nil, function() M.wzAct("active", zn.id, not zn.active, nil, nil, nil, nil, nil, nil, nil, player) end)
        sub:addOption("Remove work zone " .. zn.id, nil, function() M.wzAct("remove", zn.id, nil, nil, nil, nil, nil, nil, nil, nil, player) end)
    end
    sub:addOption(M.wzShow and "Hide work zones" or "Show work zones", nil, function() M.wzShow = not M.wzShow end)
end

----------------------------------------------------------------------------------------------------------------
-- showing zones (only while toggled on): outline per zone, drop point, first corner
----------------------------------------------------------------------------------------------------------------
-- pre-1.0 MP (P4): EVERY WORK-ZONE MENU WRITE, in one place. SP: called directly by the menu (what each option did
-- before). MP client: forwarded to the server, run as the sender, values checked here.
local function num(v) v = tonumber(v); if v == nil then return nil end; return math.floor(v) end
function M.wzAct(kind, a, b, c, d4, e, f, g, h, i, player)
    player = player or thePlayer()
    kind = tostring(kind)
    if kind == "zone" then
        local x1, y1, x2, y2, z, x, y, dz = num(a), num(b), num(c), num(d4), num(e) or 0, num(f), num(g), num(h) or 0
        local dk = tostring(i)
        if x1 == nil or y1 == nil or x2 == nil or y2 == nil or x == nil or y == nil then return false end
        if dk ~= "ground" and dk ~= "container" and dk ~= "burn" then return false end
        if math.abs(x2 - x1) + 1 > M.wzCfg.maxSide or math.abs(y2 - y1) + 1 > M.wzCfg.maxSide then return false end
        if #M.wzZoneList() >= (tonumber(M.wzOpt("WZMaxZones")) or 10) then return false end
        local okR = M.wzInRange(player, x, y)
        if not okR then return false end
        local area = { x1 = math.min(x1, x2), y1 = math.min(y1, y2), x2 = math.max(x1, x2), y2 = math.max(y1, y2), z = z }
        if dk == "burn" then
            local unsafe = M.wzBurnUnsafe(x, y, dz)
            if unsafe then halo("Can't burn here: " .. unsafe .. ".", 255, 150, 110); return false end
            M.wzAddZone(area, { x = x, y = y, z = dz, kind = "burn" })
            halo("Burn site set. They'll pile the bodies here and burn them once the area is clear.")
        elseif dk == "container" then
            local sq = sqAt(x, y, dz)
            local cont, co = nil, nil
            if sq then cont, co = containerOn(sq) end
            if cont == nil then return false end
            local nm = containerName(co)
            local zn = M.wzAddZone(area, { x = x, y = y, z = dz, kind = "container" })
            zn.dropName = nm
            halo("Work zone set. Bodies go in the " .. nm .. ".")
        else
            M.wzAddZone(area, { x = x, y = y, z = dz, kind = "ground" })
            halo("Work zone set. Your people will pile the bodies here.")
        end
    elseif kind == "active" then
        local zn = M.wzData().zones[tostring(num(a))]
        if type(zn) ~= "table" then return false end
        zn.active = b == true
    elseif kind == "remove" then
        local zn = M.wzData().zones[tostring(num(a))]
        if type(zn) ~= "table" then return false end
        M.wzRemoveZone(zn)
    else
        return false
    end
    wzTouch()
    return true
end
M.wzShow = false
function M.wzRender()
    if type(addAreaHighlight) ~= "function" then return end
    local pick = M.wzSel
    if pick and pick.area == nil and pick.x then addAreaHighlight(pick.x, pick.y, pick.x + 1, pick.y + 1, pick.z, 1, 0.8, 0.2, 0.6) end
    if pick and pick.area then local a = pick.area; addAreaHighlight(a.x1, a.y1, a.x2 + 1, a.y2 + 1, a.z, 1, 0.8, 0.2, 0.35) end
    if not M.wzShow then return end
    for _, zn in pairs(M.wzData().zones) do
        if type(zn) == "table" then
            if zn.active then addAreaHighlight(zn.x1, zn.y1, zn.x2 + 1, zn.y2 + 1, zn.z, 0.4, 0.8, 0.4, 0.3)
            else addAreaHighlight(zn.x1, zn.y1, zn.x2 + 1, zn.y2 + 1, zn.z, 0.6, 0.6, 0.6, 0.25) end
            local r, g = 0.9, 0.9
            if zn.drop.kind == "burn" then g = 0.4 end
            addAreaHighlight(zn.drop.x, zn.drop.y, zn.drop.x + 1, zn.drop.y + 1, zn.drop.z, r, g, 0.2, 0.6)
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- words: "clear the bodies" / "leave the bodies"
----------------------------------------------------------------------------------------------------------------
local function pickLine(list, seed) return list[(hash(seed) % #list) + 1] end
function M.wzOrder(record, player, stop)
    local uid = tostring(record.uid)
    if not M.wzIsWorker(uid, player) then return nil end
    local seed = uid .. tostring(math.floor(hours() * 10))
    if stop then
        for _, zn in ipairs(M.wzZoneList()) do zn.active = false end
        for u in pairs(M.wzJobs) do local s = PA().Talk and PA().Talk.shellFor and PA().Talk.shellFor(u); M.wzRelease(u, s) end
        return pickLine(STOP_LINES, seed)
    end
    if M.wzSqueamish(uid) then M.wzStats.refused = M.wzStats.refused + 1; return pickLine(REFUSE, seed) end
    local list = M.wzZoneList()
    if #list == 0 then
        halo("Right-click the ground > Work zones to mark an area and where the bodies go.")
        return pickLine(NOZONE, seed)
    end
    for _, zn in ipairs(list) do zn.active = true end
    M.wzNextTry[uid] = nil
    return pickLine(OK_LINES, seed)
end
M.wzIntents = {
    { id = "ORDER_BODIES", stop = false, patterns = "clear the bodies|clean up the bodies|get rid of the bodies|move the bodies|dump the bodies|burn the bodies|deal with the bodies|haul the bodies|drag the bodies|clear the corpses|clean up the corpses|get rid of the corpses|move the corpses|burn the corpses|clean up the dead|get rid of the dead" },
    { id = "ORDER_BODIES_STOP", stop = true, patterns = "leave the bodies|stop moving the bodies|stop clearing the bodies|stop with the bodies|leave the corpses|stop moving the corpses" },
}
function M.wzInstallTalk()
    if M._wzTalk then return true end
    local Data, Intents, Talk = PA().DialogueData, PA().TalkIntents, PA().Talk
    if Data == nil or Talk == nil then return false end
    pcall(Data.load)
    Talk.choiceHandlers = Talk.choiceHandlers or {}
    for _, def in ipairs(M.wzIntents) do
        pcall(Data.intent, def.id, 82, def.patterns)
        Talk.choiceHandlers[def.id] = function(record, shell, player, context, now, text)
            local ok, line = pcall(M.wzOrder, record, player, def.stop)
            if not ok then log("order failed: " .. tostring(line)); return nil end
            if line == nil or not PA().Speech.say(shell, line, { face = player }) then return nil end
            return line, "answered"
        end
    end
    if Intents then Intents.cache = {} end
    M._wzTalk = true
    return true
end
-- in conversation: someone laid out and no shovel
function M.wzExtra(req, player, listener)
    if type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    if not M.wzIsWorker(listener.record.uid, player) then return end
    for _, g in pairs(M.wzData().graves) do
        if g.laid then
            req.psyche = type(req.psyche) == "table" and req.psyche or {}
            local note = tostring(g.name) .. " from your group died and is laid out by the house; you need a shovel to bury them."
            req.psyche.mood = req.psyche.mood and (tostring(req.psyche.mood) .. ". " .. note) or note
            return
        end
    end
end

function M.wzPerf()
    local s = M.wzStats
    return "carried " .. s.carried .. ", piled " .. s.piled .. ", dumped " .. s.dumped .. ", burns " .. s.burns .. ", graves " .. s.graves
        .. ", laid out " .. s.laidOut .. ", refused " .. s.refused .. ", bans " .. s.bans .. ", unseen " .. s.unseen .. ", evals " .. s.evals
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
if type(Events) == "table" then
    if Events.OnFillWorldObjectContextMenu then
        ALifeRadial.addFiller("workzones", "camp", function(p, context, worldobjects, test)   -- 0.5.11: radial registry
            local ok, err = pcall(M.wzContext, p, context, worldobjects, test)
            if not ok and not M._wzMenuErr then M._wzMenuErr = true; log("menu error (logged once): " .. tostring(err)) end
        end)
    end
    if Events.OnTick then
        ALifeHealth.add(Events.OnTick, "ALifeTalk_WorkZones", function()
            if M._wzTickDead then return end
            local ok, err = pcall(M.wzTick)
            if not ok then M._wzTickDead = true; log("tick error, work zone tick off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnPostRender then
        Events.OnPostRender.Add(function()
            if M._wzRenderDead or (not M.wzShow and M.wzSel == nil) then return end
            local ok, err = pcall(M.wzRender)
            if not ok then M._wzRenderDead = true; log("render error, zone outlines off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(M.wzRegister)
            pcall(M.wzInstallTalk)
            if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
                ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeTalk_WorkZones", function(body, uid, killer)
                    local ok, err = pcall(M.wzOnDeath, body, uid, killer)
                    if not ok then log("death hook error: " .. tostring(err)) end
                end)
            else
                log("ProjectALife_NpcDied not found - graves are off")
            end
            if not M._wzExtraOn and type(M.requestExtras) == "table" then
                table.insert(M.requestExtras, function(req, player, listener, now) pcall(M.wzExtra, req, player, listener) end)
                M._wzExtraOn = true
            end
            print(TAG .. " loaded v" .. VERSION .. " (A-Life module " .. (M._wzRegistered and "registered" or "not yet")
                .. ", talk " .. (M._wzTalk and "on" or "off") .. ", " .. #M.wzZoneList() .. " zones)")
        end)
    end
end
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    ALifeRemote.expose("wzAct", 10, 11)
    ALifeRemote.share(M.WZ_VIEW, function() return M.wzData() end)
end
return M
