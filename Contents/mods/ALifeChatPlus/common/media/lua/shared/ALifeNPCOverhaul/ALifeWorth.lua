-- A-Life NPC Overhaul 0.6.14: WHAT THINGS ARE WORTH. Every item has a worth, from the game's own item data.
-- One number drives everything: trading with caravans (both sides of the deal), Airport supply flights, trade runs
-- between groups, what raiders go for, and how rich a group is.
-- Scale: the same as the Jeem Extension's trader prices, so the two fit together: a tin of beans ~2, a bandage ~2,
-- a hammer ~5, a crowbar ~8, an axe ~10, antibiotics ~12, a box of rounds ~5, a hunting rifle ~25.
--   food        by calories (a meal ~2), more for food that keeps (tins, dry goods), less for fresh
--   drink       by how much it holds
--   medicine    by what it does (antibiotics far above a plaster)
--   ammo        by the rounds in it
--   guns        by damage; melee weapons and tools by damage and durability; known tools by name
--   clothing    by bite / scratch protection and warmth; bags by how much they carry
--   books       skill books and recipe magazines are worth a lot; the rest little
--   fuel        by how much the can holds; generators, propane, batteries, radios by name
--   junk        a token by weight
-- A real item (in a container, in someone's hands) is worth less used: worn tools and weapons by condition, drinks
-- and fuel by how full, half-used drainables by what's left, rotten food nothing.
-- What it's worth TO A GROUP also depends on what they're short of (ALifeWorth.need): starving groups pay more for food,
-- groups out of ammo for ammo, and a group drowning in something pays less for more of it.
-- Performance: worth per item type is worked out once (one item made from its script, cached for the session); a
-- group's wealth is recounted only when its stash changes (cached by size).
ALifeWorth = ALifeWorth or {}
local W = ALifeWorth
W.cache, W.cacheN = W.cache or {}, W.cacheN or 0
W.stats = W.stats or { types = 0, items = 0, wealth = 0 }

local function has(t, w) return string.find(t, w, 1, true) ~= nil end
local function num(f) local ok, v = pcall(f); return ok and tonumber(v) or nil end

-- known by name (lower-case piece of the type -> worth); first match wins, longest pieces first
W.named = {
    { "antibiotic", 12 }, { "suture", 5 }, { "disinfectant", 5 }, { "splint", 5 }, { "pillsbeta", 4 }, { "pillsantidep", 4 },
    { "pillssleeping", 4 }, { "pillsvitamins", 3 }, { "pills", 4 }, { "tweezers", 4 }, { "alcoholwipes", 3 }, { "bandage", 2.5 },
    { "bandaid", 2 }, { "cottonballs", 2 }, { "coldpack", 2 }, { "comfrey", 2 }, { "plantain", 2 },
    { "generator", 60 }, { "propanetank", 20 }, { "blowtorch", 10 }, { "weldingmask", 6 }, { "hamradio", 15 },
    { "walkietalkie", 6 }, { "radio", 4 }, { "battery", 2 }, { "flashlight", 4 }, { "torch", 4 }, { "lighter", 2 }, { "matches", 1 },
    { "sledgehammer", 12 }, { "woodaxe", 12 }, { "handaxe", 8 }, { "axe", 10 }, { "crowbar", 8 }, { "gardensaw", 5 }, { "saw", 6 },
    { "pipewrench", 5 }, { "wrench", 4 }, { "screwdriver", 3 }, { "hammer", 5 }, { "shovel", 6 }, { "pickaxe", 8 },
    { "machete", 9 }, { "katana", 14 }, { "huntingknife", 6 }, { "kitchenknife", 3 }, { "needle", 1 }, { "thread", 1 },
    { "nailsbox", 3 }, { "nails", 0.2 }, { "screwsbox", 3 }, { "plank", 0.5 }, { "log", 1 }, { "sheetmetal", 4 },
    { "smallsheetmetal", 2 }, { "barbedwire", 4 }, { "ducttape", 3 }, { "woodglue", 2 }, { "glue", 2 }, { "rope", 3 }, { "twine", 2 },
    { "propane", 20 }, { "seed", 1 }, { "watchfirealarm", 1 },
}
table.sort(W.named, function(a, b) return #a[1] > #b[1] end)

-- worth of one item type, as new / full (cached). kind: food / water / meds / ammo / tools / weapon / clothing / books / fuel / materials / other
function W.of(fullType)
    if type(fullType) ~= "string" then return 0, "other" end
    local c = W.cache[fullType]
    if c then return c[1], c[2] end
    local v, kind = W.compute(fullType)
    if W.cacheN > 4000 then W.cache, W.cacheN = {}, 0 end
    W.cache[fullType], W.cacheN = { v, kind }, W.cacheN + 1
    W.stats.types = W.stats.types + 1
    return v, kind
end
function W.compute(fullType)
    local t = string.lower(fullType)
    local it = nil
    if type(instanceItem) == "function" then pcall(function() it = instanceItem(fullType) end) end
    local isa = function(cls) local ok, r = pcall(function() return instanceof(it, cls) end); return ok and r == true end
    local cat = ""
    if it then pcall(function() cat = string.lower(tostring(it:getDisplayCategory() or "")) end) end
    local weight = (it and num(function() return it:getActualWeight() end)) or (it and num(function() return it:getWeight() end)) or 0.5
    -- fuel and gas cans
    if has(t, "petrolcan") or has(t, "jerrycan") or has(t, "gascan") or has(t, "gasoline") then
        local cap = it and num(function() return it:getFluidContainer():getCapacity() end) or 10
        return math.max(2, cap * 0.4), "fuel"
    end
    -- ammo: by rounds (a box of 50 ~5)
    if cat == "ammo" or has(t, "bullets") or has(t, "shells") or has(t, "round") and not has(t, "ground") then
        local rounds = 1
        local GW = type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy.GiftWorth or nil
        if GW and type(GW.rounds) == "function" then local ok, r = pcall(GW.rounds, fullType); if ok and tonumber(r) and r > 0 then rounds = r end
        elseif has(t, "carton") then rounds = 200 elseif has(t, "box") then rounds = 50 end
        return math.max(0.1, rounds * 0.1), "ammo"
    end
    -- guns first (a sawn-off is a gun, not a saw)
    if it and isa("HandWeapon") then
        local ranged = false
        pcall(function() ranged = it:isRanged() == true end)
        if ranged then return math.min(60, 15 + (num(function() return it:getMaxDamage() end) or 1) * 6), "weapon" end
    end
    -- known by name
    for _, e in ipairs(W.named) do
        if has(t, e[1]) then
            local kind = (cat == "firstaid" or cat == "medical") and "meds" or (isa("HandWeapon") and "weapon" or "tools")
            if has(t, "seed") then kind = "other" end
            if e[2] >= 15 and not isa("HandWeapon") then kind = "other" end
            if has(t, "plank") or has(t, "log") or has(t, "nail") or has(t, "sheetmetal") or has(t, "wire") or has(t, "screws") then kind = "materials" end
            return e[2], kind
        end
    end
    if it == nil then return 0.5, "other" end
    -- food and drink
    if isa("Food") then
        local cal = num(function() return it:getCalories() end) or 0
        local hunger = math.abs(num(function() return it:getHungChange() end) or num(function() return it:getHungerChange() end) or 0)
        local v = cal > 0 and cal / 300 or hunger * 10
        local keeps = num(function() return it:getOffAgeMax() end) or 0
        if keeps <= 0 or keeps >= 1000000 or has(t, "canned") or has(t, "tinned") or has(t, "dried") then v = v * 1.3
        elseif keeps < 7 then v = v * 0.7 end
        local fluid = nil
        pcall(function() fluid = it:getFluidContainer() end)
        if fluid and v < 0.5 then return math.max(0.5, (num(function() return fluid:getCapacity() end) or 1) * 2), "water" end
        return math.max(0.2, math.min(8, v)), "food"
    end
    if has(t, "water") or has(t, "bottle") and has(t, "pop") then
        local cap = num(function() return it:getFluidContainer():getCapacity() end) or 1
        return math.max(0.5, cap * 2), "water"
    end
    if cat == "firstaid" or cat == "medical" then return 3, "meds" end
    -- guns
    if isa("HandWeapon") then
        local ranged = false
        pcall(function() ranged = it:isRanged() == true end)
        local dmg = num(function() return it:getMaxDamage() end) or 1
        if ranged then return math.min(60, 15 + dmg * 6), "weapon" end
        local cond = num(function() return it:getConditionMax() end) or 10
        return math.max(1, math.min(20, dmg * 3 + cond * 0.25)), "weapon"
    end
    -- clothing and bags
    if isa("InventoryContainer") then
        local cap = num(function() return it:getCapacity() end) or 5
        return math.max(1, cap * 0.35), "clothing"
    end
    if isa("Clothing") then
        local bite = num(function() return it:getBiteDefense() end) or 0
        local scratch = num(function() return it:getScratchDefense() end) or 0
        local warm = num(function() return it:getInsulation() end) or 0
        return math.max(0.3, math.min(15, bite * 0.15 + scratch * 0.05 + warm * 3)), "clothing"
    end
    -- books
    if isa("Literature") or cat == "literature" or cat == "skillbook" then
        local lvl = num(function() return it:getLvlSkillTrained() end) or 0
        local recipes = 0
        pcall(function() local r = it:getTeachedRecipes(); recipes = r and r:size() or 0 end)
        if lvl > 0 then return 6 + lvl, "books" end
        if recipes > 0 then return 6, "books" end
        return 0.3, "books"
    end
    if cat == "tool" or cat == "toolweapon" then return math.max(2, math.min(10, 2 + weight * 1.5)), "tools" end
    if cat == "material" then return math.max(0.2, math.min(4, weight * 0.3)), "materials" end
    if cat == "electronics" then return math.max(1, math.min(6, 1 + weight)), "other" end
    -- everything else: a token by weight
    return math.max(0.1, math.min(2, 0.1 + weight * 0.05)), "other"
end

-- a real item: worn, used up, half-full, rotten
function W.item(item)
    if item == nil then return 0, "other" end
    local t = nil
    pcall(function() t = item:getFullType() end)
    local v, kind = W.of(t)
    local f = 1
    -- 0.8.3.1: isRotten is Food's only (other items have no such method -> "tried to call nil" in the log)
    pcall(function() if instanceof(item, "Food") and item:isRotten() then f = 0 end end)
    if f > 0 then
        pcall(function()
            local cm = tonumber(item:getConditionMax()) or 0
            if cm > 0 then f = f * math.max(0.15, (tonumber(item:getCondition()) or cm) / cm) end
        end)
        pcall(function()
            local fl = item:getFluidContainer()
            if fl then local cap = tonumber(fl:getCapacity()) or 0; if cap > 0 then f = f * math.max(0, (tonumber(fl:getAmount()) or cap) / cap) end end
        end)
        pcall(function() if instanceof(item, "DrainableComboItem") then f = f * math.max(0, tonumber(item:getCurrentUsesFloat()) or 1) end end)
    end
    W.stats.items = W.stats.items + 1
    return v * f, kind
end

-- what it's worth to a group, by what they're short of (b: an NPC base record)
function W.need(b, kind)
    if type(b) ~= "table" then return 1 end
    local n = math.max(1, tonumber(b.crewN) or 1)
    local g = type(b.goods) == "table" and b.goods or {}
    if kind == "food" or kind == "water" then
        local days = (tonumber(b.food) or 0) / n
        if days < 1 then return 2 elseif days < 3 then return 1.5 elseif days > 10 then return 0.7 end
    elseif kind == "meds" then
        if (g.meds or 0) == 0 then return 1.5 elseif (g.meds or 0) > n * 4 then return 0.7 end
    elseif kind == "ammo" then
        if (g.ammo or 0) == 0 then return 1.5 elseif (g.ammo or 0) > n * 4 then return 0.7 end
    elseif kind == "fuel" then
        if type(b.vehicle) == "table" and (tonumber(b.vehicle.fuel) or 0) < 10 then return 1.4 end
    end
    return 1
end
function W.to(b, fullType)
    local v, kind = W.of(fullType)
    return v * W.need(b, kind), kind
end

-- how rich a group is: what its stash is worth, plus its fresh food (a person-day of food ~8: four meals)
local function stashList(b)
    local M = ALifeLLMTalk
    if type(M) ~= "table" or type(M.nbStashList) ~= "function" or type(M.nbHavenOf) ~= "function" then return nil end
    local ok, l = pcall(function() return M.nbStashList(M.nbHavenOf(b)) end)
    return ok and l or nil
end
function W.wealth(b)
    if type(b) ~= "table" then return 0 end
    local list = stashList(b) or {}
    local sig = #list
    if b.wealthSig == sig and tonumber(b.wealth) then return b.wealth + (tonumber(b.rations) or 0) * 8 end
    local sum = 0
    for _, it in ipairs(list) do sum = sum + (W.of(type(it) == "table" and it.type or it)) end
    b.wealth, b.wealthSig = math.floor(sum + 0.5), sig
    W.stats.wealth = W.stats.wealth + 1
    return b.wealth + (tonumber(b.rations) or 0) * 8
end
W.wealthWords = { { 150, "rich" }, { 60, "comfortable" }, { 20, "getting by" }, { 5, "scraping by" }, { -1, "destitute" } }
function W.wealthWord(b)
    local per = W.wealth(b) / math.max(1, tonumber(b and b.crewN) or 1)
    for _, e in ipairs(W.wealthWords) do if per > e[1] then return e[2] end end
    return "destitute"
end
-- the most valuable things in a list of { type } (indexes, best first), up to n
function W.best(list, n, skip)
    local idx = {}
    for i, it in ipairs(list or {}) do
        local t = type(it) == "table" and it.type or it
        local v, kind = W.of(t)
        if not (skip and skip[kind]) then idx[#idx + 1] = { i = i, v = v } end
    end
    table.sort(idx, function(a, b) return a.v > b.v end)
    local out = {}
    for k = 1, math.min(n, #idx) do out[k] = idx[k].i end
    return out
end
function W.perf()
    local s = W.stats
    return "worth: item types valued " .. s.types .. " (cached " .. W.cacheN .. "), real items valued " .. s.items .. ", wealth recounts " .. s.wealth
end
return W
