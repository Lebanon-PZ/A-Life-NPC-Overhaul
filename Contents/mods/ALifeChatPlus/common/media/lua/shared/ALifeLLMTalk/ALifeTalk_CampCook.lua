-- ALifeTalk_CampCook.lua (0.5.3): the camp cook makes dinner.
-- Once a day, at meal time, the cook goes to the kitchen you mark, cooks from your stores (food that spoils first,
-- the closest to spoiling first, never anything rotten), and serves the whole camp. A good cook stretches the food
-- further. A hot meal lifts morale for a day; a thin one less; no food, no dinner, and people notice.
-- With no cook (or meals off in the sandbox) nobody eats from your stores, exactly like before.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampCook") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPMeals = true
M.cpDefaults.CPMealHour = 18
M.cpDefaults.CPMealPortions = 2
M.ckCfg = { cookMs = 8000, eatTiles = 15, maxTake = 30 }
M.ckStats = { meals = 0, thin = 0, missed = 0, used = 0 }
-- people one food item feeds, before the cook's skill: Hearty 1, Normal 1.5, Light 2
M.ckPerItem = { 1, 1.5, 2 }

function M.ckData()
    local d = M.cpData()
    d.cook = type(d.cook) == "table" and d.cook or {}
    return d.cook
end
function M.ckOn() return M.cpOpt("CPMeals") ~= false end
local function today() return math.floor(H.hours() / 24) end

-- where the ingredients come from: fresh-food drop points, then keeping food, then the kitchen's own container
local function sources(k)
    local out, seen = {}, {}
    local function add(p)
        if p == nil then return end
        local key = math.floor(p.x) .. ":" .. math.floor(p.y) .. ":" .. math.floor(p.z or 0)
        if seen[key] then return end
        seen[key] = true
        local sq = H.sqAt(p.x, p.y, p.z)
        local c = sq and H.containerOn(sq)
        if c then out[#out + 1] = c end
    end
    local drops = M.cpData().drops
    for _, p in ipairs(drops.fresh or {}) do add(p) end
    for _, p in ipairs(drops.cans or {}) do add(p) end
    add(k)
    return out
end
-- how long until it spoils (hours of shelf life left; huge for cans); nil = rotten, don't use
local function shelfLeft(it)
    local rotten, left = false, 1e9
    pcall(function() rotten = instanceof(it, "Food") and it:isRotten() == true end) -- 0.8.3.1: Food only
    if rotten then return nil end
    pcall(function()
        local age, off = tonumber(it:getAge()) or 0, tonumber(it:getOffAgeMax()) or 1e9
        left = off - age
    end)
    return left
end
-- pick `need` ingredients, spoiling-soonest first; returns { {c=container, it=item} ... }, rottenSeen
function M.ckPick(k, need)
    local all, rotten = {}, 0
    for _, c in ipairs(sources(k)) do
        pcall(function()
            local items = c:getItems()
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                local cat = M.cpCatOf(it)
                if cat == "fresh" or cat == "cans" then
                    local left = shelfLeft(it)
                    if left == nil then rotten = rotten + 1 else all[#all + 1] = { c = c, it = it, left = left } end
                end
            end
        end)
        if #all >= M.ckCfg.maxTake * 4 then break end
    end
    table.sort(all, function(a, b) return a.left < b.left end)
    local out = {}
    for i = 1, math.min(need, #all, M.ckCfg.maxTake) do out[i] = all[i] end
    return out, rotten
end
-- portions: everyone home + you
function M.ckMouths(player) return #M.cpPeople(player) + 1 end
function M.ckNeed(cookUid, player)
    local per = M.ckPerItem[tonumber(M.cpOpt("CPMealPortions")) or 2] or 1.5
    local stretch = 0.6 + 0.5 * M.cpFit(cookUid, "cook") -- 0.75 (hopeless) .. 1.4 (born for it)
    return math.max(1, math.ceil(M.ckMouths(player) / (per * stretch)))
end

local SERVED = { "Dinner's ready. Come and get it.", "Food's on. Eat while it's hot.", "Soup's on. Don't make me call twice." }
local THIN = { "It's not much. That's the last of it.", "Thin tonight. Make it last.", "Half rations. Sorry. It's what we've got." }
local NONE = { "There's nothing to cook. Nothing.", "Pantry's empty. No dinner tonight." }
local ROTTEN = "Some of it's gone bad. I threw it to the back. Nobody eats that."

-- the cook at the stove: take, cook, serve
function M.ckServe(uid, shell, player)
    local k = M.ckData()
    local need = M.ckNeed(uid, player)
    local picks, rotten = M.ckPick(k.kitchen, need)
    local got = 0
    for _, p in ipairs(picks) do
        if pcall(function() p.c:DoRemoveItem(p.it) end) then got = got + 1 end
    end
    M.ckStats.used = M.ckStats.used + got
    k.day = today()
    if got == 0 then
        k.fedQ, k.missedAt = nil, H.hours()
        M.ckStats.missed = M.ckStats.missed + 1
        H.say(shell, H.pickLine(NONE, uid .. k.day))
        H.halo("No dinner tonight: the stores are empty.", 255, 170, 110)
        M.cpLog("meal", "there was no dinner, the stores were empty")
        return 0
    end
    local fill = math.min(1, got / need)
    local q = M.cpFit(uid, "cook") * fill
    k.fedQ, k.fedAt, k.missedAt = q, H.hours(), nil
    M.ckStats.meals = M.ckStats.meals + 1
    if fill < 1 then M.ckStats.thin = M.ckStats.thin + 1 end
    H.say(shell, H.pickLine(fill < 1 and THIN or SERVED, uid .. k.day))
    if rotten > 0 and not k.rottenSaid then k.rottenSaid = true; H.say(shell, ROTTEN) end
    -- you eat with them if you're close (B42 stats; guarded)
    local px, py = H.pos(player)
    local sx, sy = H.pos(shell)
    if px and sx and H.d2(px, py, sx, sy) <= M.ckCfg.eatTiles ^ 2 then
        H.tryOnce("mealStats", function()
            local st = player:getStats()
            st:remove(CharacterStat.HUNGER, 0.3 * fill)
            st:remove(CharacterStat.UNHAPPINESS, 10 * q)
        end)
        H.halo("You eat with the others." .. (fill < 1 and " It isn't much." or ""), 230, 210, 150)
    end
    M.cpLog("meal", fill < 1 and (H.firstName(uid) .. " served a thin dinner") or (H.firstName(uid) .. " made a good dinner"))
    H.log("dinner: " .. got .. "/" .. need .. " items for " .. M.ckMouths(player) .. " people, quality " .. math.floor(q * 100 + 0.5))
    return got
end

-- morale: a hot meal helps for a day (more from a good cook); a missed dinner hurts for a day
local function moraleHook(uid, r, st, player)
    if not M.ckOn() then return 0 end
    local k = M.ckData()
    local h = H.hours()
    if k.fedQ and h - (tonumber(k.fedAt) or -1e9) < 24 then return -4 * k.fedQ end
    if k.missedAt and h - k.missedAt < 24 then return 3 end
    return 0
end
M.cpMoraleHooks = M.cpMoraleHooks or {}
table.insert(M.cpMoraleHooks, moraleHook)

M.cpAddJob({
    kind = "meal", order = 5,
    pick = function(uid, shell, player, b, now)
        if not M.ckOn() or M.cpRoleOf(uid) ~= "cook" then return nil end
        local k = M.ckData()
        if k.kitchen == nil then
            if not k.noKitchenSaid then
                k.noKitchenSaid = true
                H.say(shell, "Where's the kitchen? Show me where to cook.")
                H.halo("Right-click your stove > Camp > Kitchen > Cook here.")
            end
            return nil
        end
        if k.day == today() or H.hourOfDay() < (tonumber(M.cpOpt("CPMealHour")) or 18) then return nil end
        return { key = "meal", anim = "search_mid" }
    end,
    spot = function(j) return M.ckData().kitchen end,
    ms = function(j) return M.ckCfg.cookMs end,
    run = function(j, uid, shell, player) M.ckServe(uid, shell, player); return "done" end,
})

-- why the cook is not cooking, in words (nil = fine). Shown on the camp board so a silent failure is visible.
function M.ckWhy(uid, player)
    if M.cpRoleOf(uid) ~= "cook" then return nil end
    if not M.ckOn() then return "camp meals are off in the sandbox" end
    local k = M.ckData()
    if k.kitchen == nil then return "no kitchen marked: stove > Camp > Kitchen > Cook here" end
    if k.day == today() then return nil end
    local mh = tonumber(M.cpOpt("CPMealHour")) or 18
    if H.hourOfDay() < mh then return "cooks at " .. mh .. ":00" end
    local ok, picks = pcall(M.ckPick, k.kitchen, 1)
    if ok and type(picks) == "table" and #picks == 0 then return "nothing fresh or canned in the kitchen or food drops" end
    return nil
end

-- menu: Camp > Kitchen
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local km, ko = child("Kitchen")
    if not M.ckOn() then off(ko, "Camp meals are off in this world's sandbox settings.") end
    local k = M.ckData()
    local here = k.kitchen and k.kitchen.x == x and k.kitchen.y == y and k.kitchen.z == z
    if here then
        km:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_kitchen_anymore", "Not the kitchen anymore"), nil, function() M.cpAct("ckKitchenOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = km:addOption(k.kitchen and "Move the kitchen here" or "Cook here", nil, function() M.cpAct("ckKitchen", x, y, z, nil, nil, player) end)
        if not inRange then off(o, why or "Too far from your base.") end
    end
    local cooks = M.cpWithRole("cook", player)
    if #cooks > 0 then
        local need = M.ckNeed(cooks[1], player)
        local info = km:addOption("Dinner takes about " .. need .. " food a day (" .. M.ckMouths(player) .. " mouths)")
        off(info, "A better cook stretches it further. Spoiling food goes first.")
    end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender)
M.cpActs = M.cpActs or {}
M.cpActs.ckKitchenOff = function() M.ckData().kitchen = nil end
M.cpActs.ckKitchen = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    local k = M.ckData()
    k.kitchen, k.noKitchenSaid = { x = x, y = y, z = z }, nil
    H.halo("Kitchen set. The cook makes dinner here every evening from your food stores.")
    if #M.cpWithRole("cook", player) == 0 then H.halo("Nobody's the cook yet. Camp > Roles.", 255, 200, 120) end
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function() local k = M.ckData().kitchen; if k then return { { k, 1, 0.6, 0.2 } } end end)

-- AI: tonight's dinner colours the mood
M.cpExtras = M.cpExtras or {}
table.insert(M.cpExtras, function(req, player, listener)
    if not M.ckOn() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    if not M.cpIsHome(tostring(listener.record.uid), player) then return end
    local k = M.ckData()
    local h = H.hours()
    local note = nil
    if k.fedQ and h - (tonumber(k.fedAt) or -1e9) < 24 then note = k.fedQ >= 1 and "You ate well tonight." or "Dinner was thin." end
    if k.missedAt and h - k.missedAt < 24 then note = "There was no dinner. You're hungry." end
    return note
end)
