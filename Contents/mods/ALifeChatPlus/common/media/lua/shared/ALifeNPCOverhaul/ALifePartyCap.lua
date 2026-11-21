-- A-Life NPC Overhaul 0.8.2: A BIGGER PARTY, EARNED.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifePartyCap") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)
require "ALifeNPCOverhaul/ALifeCellCars"
-- Your party size (setting "partyCap") is 6 by default and can go up to 10 ("partyMax"). Up to 6 ("partyFree") is
-- free. Each place above that needs something real, one slot per thing (each can be switched off in settings):
--   * beds:  your base has a bed for everyone (you included)                         (capBeds, capBedTiles)
--   * food:  your base's stores hold enough food (and water) for everyone for a few days (capFood, capFoodDays, capFoodPerDay, capWater)
--   * trust: most of your party thinks well of you (someone sworn to you counts twice) (capTrust, capTrustShare, capTrustOpinion)
--   * seats: there are enough real car seats near you for everyone                      (capSeats, capSeatsTiles)
-- Party now = min(your size, the max, the free part + what's met). Losing one never sends anyone away: you just can't
-- take anyone else on until you're back under. A-Life's own companion cap (CompanionRules.maxPerPlayer, 5) is set to
-- the same number, so A-Life's "Come with me" and our recruiting agree.
-- Rechecked once a minute (real time) at most; every read is guarded, and what can't be read counts as not met.
-- The size you pick in game is kept with the world (beats the sandbox value on reload).
-- Not checked against 42.21 yet: which bed sprites count (names with "bedding"), and how water is read (items whose
-- name or type says water). Both are only used for slots above 6.
ALifePartyCap = ALifePartyCap or {}
local L = ALifePartyCap
local TAG = "[ALifePartyCap]"
L.VERSION = ALifeSide.MOD_VERSION
L.metrics = L.metrics or { checks = 0, synced = 0 }
L.cache = L.cache or { at = -1e12, cap = nil, met = nil }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function M() return ALifeLLMTalk end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end

L.DEFAULTS = {
    partyCap = 6, partyMax = 10, partyFree = 6,
    capBeds = true, capBedTiles = 2,          -- bed tiles per bed (most beds are two tiles)
    capFood = true, capFoodDays = 3, capFoodPerDay = 2, capWater = true, capWaterPerDay = 1,
    capTrust = true, capTrustShare = 60, capTrustOpinion = 40,
    capSeats = true, capSeatsTiles = 40,
    capRecheckMs = 60000, capBaseRecheckMs = 300000,
}
function L.setting(key)
    local m = M()
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = L.DEFAULTS[key] end
    return v
end
local function on(key) return L.setting(key) ~= false end
local function num(key) return tonumber(L.setting(key)) or tonumber(L.DEFAULTS[key]) or 0 end

local function members(player)
    local m = M()
    if fn(m, "partyMembers") then
        local ok, list = pcall(m.partyMembers, player)
        if ok and type(list) == "table" then return list end
    end
    return {}
end

-- the base's squares (your marked base), scanned at most this many containers / objects
L.SCAN_MAX = 400
local function baseOf(player)
    local m = M()
    if not fn(m, "playerBase") then return nil end
    local ok, b = pcall(m.playerBase, player)
    if ok and type(b) == "table" and tonumber(b.x1) and tonumber(b.y1) and tonumber(b.x2) and tonumber(b.y2) then return b end
    return nil
end
-- the base scan is the only heavy part: it runs only when your size is set above the free part, at most every
-- 5 minutes (capBaseRecheckMs), and stops after L.SCAN_SQUARES squares
L.SCAN_SQUARES = 6000
L.baseCache = L.baseCache or { at = -1e12, out = nil }
function L.baseCounts(player)
    local now = nowMs()
    if L.baseCache.out ~= nil and now - L.baseCache.at < num("capBaseRecheckMs") and now >= L.baseCache.at then return L.baseCache.out end
    local out = L.scanBase(player)
    L.baseCache = { at = now, out = out }
    return out
end
function L.scanBase(player)
    local out = { beds = 0, food = 0, water = 0, ok = false }
    local b = baseOf(player)
    if b == nil then return out end
    out.ok = true
    local tiles = 0
    pcall(function()
        local cell = getCell()
        local seen, squares = 0, 0
        for z = 0, 1 do
            for x = b.x1, b.x2 do
                for y = b.y1, b.y2 do
                    squares = squares + 1
                    if squares > L.SCAN_SQUARES then return end
                    local sq = cell:getGridSquare(x, y, z)
                    if sq ~= nil then
                        local objs = sq:getObjects()
                        for i = 0, objs:size() - 1 do
                            local o = objs:get(i)
                            local sname = ""
                            pcall(function() local sp = o:getSprite(); if sp ~= nil then sname = tostring(sp:getName() or "") end end)
                            if string.find(sname, "bedding", 1, true) then tiles = tiles + 1 end
                            local cont = nil
                            pcall(function() cont = o:getContainer() end)
                            if cont ~= nil then
                                seen = seen + 1
                                local items = cont:getItems()
                                for j = 0, items:size() - 1 do
                                    local it = items:get(j)
                                    local cat, name = "", ""
                                    pcall(function() cat = tostring(it:getCategory()) end)
                                    pcall(function() name = string.lower(tostring(it:getFullType()) .. " " .. tostring(it:getDisplayName())) end)
                                    if string.find(name, "water", 1, true) then out.water = out.water + 1
                                    elseif cat == "Food" then out.food = out.food + 1 end
                                end
                            end
                            if seen > L.SCAN_MAX then return end
                        end
                    end
                end
            end
        end
    end)
    -- pre-1.0: the same food count as the camp widget (marked Food stores, every floor, no rotten food); this scan's own is the fallback
    local m = M()
    if fn(m, "foodScan") then
        local okF, scan = pcall(m.foodScan, b, player)
        if okF and type(scan) == "table" then out.food = tonumber(scan.items) or out.food end
    end
    out.beds = math.floor(tiles / math.max(1, num("capBedTiles")))
    -- 0.8.8: a Jeem base counts its own beds (real bed places, Residents/Beds.lua; base.beds is sent to clients).
    -- Its residents sleep there too, so their beds are taken (headcount only where Jeem's server side runs).
    local jb = L.jeemBeds(player)
    if jb ~= nil then out.beds, out.jeem = jb, true end
    return out
end
function L.jeemBeds(player)
    local j = ProjectALifeJimmy
    if type(j) ~= "table" or type(j.BaseAreas) ~= "table" or type(j.BaseAreas.baseAt) ~= "function" then return nil end
    local base = nil
    pcall(function() base = j.BaseAreas.baseAt(player:getX(), player:getY(), 30) end)
    if type(base) ~= "table" or tonumber(base.beds) == nil then return nil end
    local beds = tonumber(base.beds)
    local R = j.Residents
    if type(R) == "table" and type(R.headcount) == "function" then
        local ok, n = pcall(R.headcount, base.id)
        if ok and tonumber(n) then beds = beds - tonumber(n) end
    end
    return math.max(0, beds)
end

function L.seatsNear(player)
    local seats = 0
    pcall(function()
        local px, py = player:getX(), player:getY()
        local r2 = num("capSeatsTiles") ^ 2
        for _, v in ipairs(ALifeCellCars.list()) do -- 0.9.5: 42.21 cell vehicles = HashSet (no get(i))
            if (v:getX() - px) ^ 2 + (v:getY() - py) ^ 2 <= r2 then
                for s = 0, v:getMaxPassengers() - 1 do
                    local okS, inst = pcall(function() return v:isSeatInstalled(s) end)
                    if not okS or inst then seats = seats + 1 end
                end
            end
        end
    end)
    return seats
end

function L.trustShare(player)
    local list = members(player)
    if #list == 0 then return 0, 0 end
    local pa = PA()
    local good, total = 0, 0
    for _, uid in ipairs(list) do
        local weight = 1
        if fn(ALifeOathWatch, "isSworn") then local ok, s = pcall(ALifeOathWatch.isSworn, uid); if ok and s then weight = 2 end end
        total = total + weight
        local v = nil
        pcall(function() v = tonumber((pa.NpcOpinion.valueOf(pa.ActorRegistry.read(tostring(uid)), player))) end)
        if v ~= nil and v >= num("capTrustOpinion") then good = good + weight end
    end
    return math.floor(good * 100 / math.max(1, total) + 0.5), total
end

-- what's met for a party of `size` (you + them): a list of { id, on, met, words }
function L.prereqs(player, size)
    local people = size + 1
    local out = {}
    local base = (on("capBeds") or on("capFood")) and L.baseCounts(player) or { beds = 0, food = 0, water = 0, ok = false }
    if on("capBeds") then
        out[#out + 1] = { id = "beds", met = base.ok and base.beds >= people,
            words = not base.ok and "You have no base marked." or ("Beds at your base: " .. base.beds .. " of " .. people .. ".") }
    end
    if on("capFood") then
        local needFood = people * num("capFoodPerDay") * num("capFoodDays")
        local needWater = on("capWater") and people * num("capWaterPerDay") * num("capFoodDays") or 0
        local met = base.ok and base.food >= needFood and base.water >= needWater
        local w = not base.ok and "You have no base marked." or ("Food in your stores: " .. base.food .. " of " .. needFood
            .. (needWater > 0 and (", water: " .. base.water .. " of " .. needWater) or "") .. " (" .. num("capFoodDays") .. " days for " .. people .. ").")
        out[#out + 1] = { id = "food", met = met, words = w }
    end
    if on("capTrust") then
        local share, total = L.trustShare(player)
        out[#out + 1] = { id = "trust", met = total > 0 and share >= num("capTrustShare"),
            words = total == 0 and "Nobody with you yet." or (share .. "% of your party trusts you (" .. num("capTrustShare") .. "% needed).") }
    end
    if on("capSeats") then
        local seats = L.seatsNear(player)
        out[#out + 1] = { id = "seats", met = seats >= people, words = "Car seats near you: " .. seats .. " of " .. people .. "." }
    end
    return out
end

-- the party size you can have right now
function L.capNow(player, force)
    local now = nowMs()
    if not force and L.cache.cap ~= nil and now - L.cache.at < num("capRecheckMs") and now >= L.cache.at then return L.cache.cap, L.cache.met end
    L.metrics.checks = L.metrics.checks + 1
    pcall(L.noteSize)
    local chosen = math.max(1, math.floor(num("partyCap")))
    local max = math.max(1, math.floor(num("partyMax")))
    local free = math.max(1, math.floor(num("partyFree")))
    local cap = math.min(chosen, max)
    local met = {}
    if cap > free and player ~= nil then
        local metCount = 0
        local ok, list = pcall(L.prereqs, player, free + 1)
        if ok then met = list; for _, p in ipairs(list) do if p.met then metCount = metCount + 1 end end end
        cap = math.min(cap, free + metCount)
    end
    L.cache = { at = now, cap = cap, met = met }
    L.sync(cap)
    return cap, met
end

-- A-Life's own cap follows ours
function L.sync(cap)
    local pa = PA()
    local rules = pa ~= nil and pa.CompanionRules or nil
    if type(rules) ~= "table" or tonumber(cap) == nil then return false end
    if rules.maxPerPlayer ~= cap then
        rules.maxPerPlayer = cap
        L.metrics.synced = L.metrics.synced + 1
    end
    return true
end

-- The party size you pick in game is kept with this world (global mod data), so it outlasts a reload and beats the
-- world's sandbox value (the sandbox is copied over the settings on every load). A world from before 0.8.2 still on
-- the old default 4 moves to 6 once; pick 4 again in game and it stays 4.
local function worldStore()
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeChatPlus_Settings") end)
    return d
end
function L.applyWorldSize()
    local m = M()
    local d = worldStore()
    if type(m) ~= "table" or type(m.settings) ~= "table" or d == nil then return end
    local s = m.settings
    if d.partySize == nil then
        local cur = tonumber(s.partyCap)
        if cur == nil or cur == 4 then s.partyCap = L.DEFAULTS.partyCap end
        d.partySize = tonumber(s.partyCap)
    else
        s.partyCap = tonumber(d.partySize) or s.partyCap
    end
end
-- a change made in game (the Settings window) is remembered for this world
function L.noteSize()
    local m = M()
    local d = worldStore()
    if type(m) ~= "table" or type(m.settings) ~= "table" or d == nil or m._sbApplying then return end
    local cur = tonumber(m.settings.partyCap)
    if cur ~= nil and cur ~= tonumber(d.partySize) then d.partySize = cur; L.cache.at = -1e12 end
end
function L.install()
    local m = M()
    if type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    local s = m.settings
    if fn(m, "sandboxApply") and not m._partyCapSbWrapped then
        m._partyCapSbWrapped = true
        local orig = m.sandboxApply
        m.sandboxApply = function(...)
            local r = orig(...)
            pcall(L.applyWorldSize)
            return r
        end
    end
    pcall(L.applyWorldSize)
    for k, v in pairs(L.DEFAULTS) do if s[k] == nil then s[k] = v end end
    if type(m.fileKeys) == "table" then
        local have = {}
        for _, k in ipairs(m.fileKeys) do have[k] = true end
        for _, k in ipairs({ "partyMax", "partyFree", "capBeds", "capBedTiles", "capFood", "capFoodDays", "capFoodPerDay", "capWater",
                "capWaterPerDay", "capTrust", "capTrustShare", "capTrustOpinion", "capSeats", "capSeatsTiles" }) do
            if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end
        end
    end
    -- the mod's party code asks this for the cap from now on
    -- pre-1.0 MP: an MP client reads the cap from the server's party view (ALifeLLMTalk_Party partyRemoteInstall)
    if type(ALifeSide) == "table" and ALifeSide.mpClient() then return true end
    m.partyCapNow = function(player) local ok, cap = pcall(L.capNow, player); return ok and cap or (tonumber(s.partyCap) or 6) end
    return true
end

if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, done = pcall(L.install)
        if not ok then log("install failed: " .. tostring(done)); return end
        local p = nil
        pcall(function() p = getSpecificPlayer(0) end)
        local okC, cap = pcall(L.capNow, p, true)
        log("ready v" .. L.VERSION .. ": party " .. tostring(okC and cap or "?") .. " now (size " .. tostring(L.setting("partyCap"))
            .. ", max " .. tostring(L.setting("partyMax")) .. ", free " .. tostring(L.setting("partyFree")) .. ")")
    end)
end
print(TAG .. " loaded v" .. L.VERSION)
