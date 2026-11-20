-- ALifeTalk_CampArmory.lua (0.5.5): the armory.
-- Mark a container as the armory. Your fighters (the same people who man the posts on the alarm) gear up from it
-- once a day, when you say "gear up", and on their way to their post when the alarm sounds: the best weapon that
-- beats what they hold, ammo that fits their gun, and armor for any slot they have free. Everyone else leaves it alone.
-- Equipping goes through A-Life's own hand-over code (the same as giving them a weapon yourself).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampArmory") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPArmory = true
M.cpDefaults.CPArmoryAmmo = true
M.cpDefaults.CPArmoryArmor = true
M.cpDefaults.CPArmoryAmmoWho = 1 -- 1 all fighters, 2 guards only
M.cpDefaults.CPArmoryRepair = true
-- repair supplies on the rack: one piece fixes 30% of the weapon's condition
M.arRepairItems = { ["Base.DuctTape"] = true, ["Base.Glue"] = true, ["Base.Woodglue"] = true, ["Base.Scotchtape"] = true }
M.arCfg = { gearMs = 3000, ammoPerVisit = 2, armorPerVisit = 2 }
M.arStats = { visits = 0, weapons = 0, ammo = 0, armor = 0 }

function M.arOn() return M.cpOpt("CPArmory") ~= false end
function M.arData()
    local d = M.cpData()
    d.armory = type(d.armory) == "table" and d.armory or {}
    d.armory.day = type(d.armory.day) == "table" and d.armory.day or {}
    return d.armory
end
local function today() return math.floor(H.hours() / 24) end
local function fighter(uid)
    if H.fn(M, "alFighter") then return M.alFighter(uid) end
    return M.cpRoleOf(uid) == "guard"
end
local function rack()
    local a = M.arData()
    if a.spot == nil then return nil end
    local sq = H.sqAt(a.spot.x, a.spot.y, a.spot.z)
    return sq and H.containerOn(sq) or nil
end
local function items(c)
    local out = {}
    pcall(function() local list = c:getItems(); for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end end)
    return out
end
local function isWeapon(it) return H.isA(it, "HandWeapon") end
local function isArmor(it)
    if not H.isA(it, "Clothing") then return false end
    local def = 0
    pcall(function() def = (tonumber(it:getBiteDefense()) or 0) + (tonumber(it:getScratchDefense()) or 0) end)
    return def > 0
end
local function slotFree(shell, it)
    local free = false
    pcall(function()
        local loc = it:getBodyLocation()
        if loc == nil or loc == "" then return end
        free = shell:getWornItems():getItem(loc) == nil
    end)
    return free
end
local function held(shell) local W = H.PA().Weapons; local g = nil; if W and W.current then pcall(function() g = W.current(shell) end) end; return g end
local function ranged(it) local r = false; pcall(function() r = it:isRanged() == true end); return r end
local function nameOf(it) local n = "something"; pcall(function() n = it:getDisplayName() end); return tostring(n) end
-- a weapon you've set aside for someone (inventory right-click > Camp: keep for...)
function M.arKeptFor(it) local v = nil; pcall(function() v = it:getModData().ALifeKeepFor end); return v ~= nil and tostring(v) or nil end
local function fullType(it) local t = ""; pcall(function() t = it:getFullType() end); return tostring(t) end
local function cond(it) local c, m = nil, nil; pcall(function() c, m = tonumber(it:getCondition()), tonumber(it:getConditionMax()) end); return c, m end

-- what this fighter would take right now: { weapon = item|nil, ammo = {..}, armor = {..} }
function M.arWants(uid, shell)
    local c = rack()
    local out = { ammo = {}, armor = {} }
    if c == nil then return out end
    local O, W = H.PA().TalkOrders, H.PA().Weapons
    -- the best weapon on the rack that beats what they hold: guns over melee, then the hardest hitter
    local function dmg(it) local v = 0; pcall(function() v = tonumber(it:getMaxDamage()) or 0 end); return v end
    local function beats(a, b) if ranged(a) ~= ranged(b) then return ranged(a) end; return dmg(a) > dmg(b) end
    local best = nil
    local mine = nil
    for _, it in ipairs(items(c)) do
        if isWeapon(it) then
            local kept = M.arKeptFor(it)
            if kept == tostring(uid) then mine = mine or it
            elseif kept == nil and O and O.better then
                local ok, better = pcall(O.better, shell, it)
                if ok and better and (best == nil or beats(it, best)) then best = it end
            end
        end
    end
    if mine then best, out.kept = mine, true end
    out.weapon = best
    local gun = best or held(shell)
    local ammoOk = M.cpOpt("CPArmoryAmmo") ~= false and ((tonumber(M.cpOpt("CPArmoryAmmoWho")) or 1) == 1 or M.cpRoleOf(uid) == "guard")
    if ammoOk and gun and ranged(gun) and W and W.ammoFits and W.ammoValue then
        for _, it in ipairs(items(c)) do
            if #out.ammo >= M.arCfg.ammoPerVisit then break end
            local okF, fits = pcall(W.ammoFits, it, gun)
            local okV, v = pcall(W.ammoValue, it)
            if not isWeapon(it) and okF and fits and okV and (tonumber(v) or 0) > 0 then out.ammo[#out.ammo + 1] = it end
        end
    end
    if M.cpOpt("CPArmoryArmor") ~= false then
        local taken = {}
        for _, it in ipairs(items(c)) do
            if #out.armor >= M.arCfg.armorPerVisit then break end
            if isArmor(it) and slotFree(shell, it) then
                local loc = ""
                pcall(function() loc = tostring(it:getBodyLocation()) end)
                if not taken[loc] then taken[loc] = true; out.armor[#out.armor + 1] = it end
            end
        end
    end
    -- repair: the weapon they carry is under 60% and there's tape or glue on the rack
    if M.cpOpt("CPArmoryRepair") ~= false then
        local hw = held(shell)
        local cnow, cmax = nil, nil
        if hw then cnow, cmax = cond(hw) end
        if cnow and cmax and cmax > 0 and cnow < cmax * 0.6 then
            for _, it in ipairs(items(c)) do if M.arRepairItems[fullType(it)] then out.repair = it; break end end
        end
    end
    return out
end
local function anything(w) return w.weapon ~= nil or #w.ammo > 0 or #w.armor > 0 or w.repair ~= nil end
-- equip one of yours even if it isn't "better" than what you hold (A-Life's hand-over refuses that)
local function equipKept(shell, it)
    local W = H.PA().Weapons
    if W == nil or type(W.select) ~= "function" then return false end
    local ok, done = pcall(function()
        local slot = W.slot(it)
        if slot == nil then slot = ranged(it) and "primary" or "melee"; it:getModData().ProjectALifeWeaponSlot = slot end
        return W.select(shell, it, slot)
    end)
    return ok and done == true
end

-- at the rack: take it, equip it, wear it. Returns a short summary or nil.
function M.arGear(uid, shell)
    local c = rack()
    local inv = H.invOf(shell)
    if c == nil or inv == nil then return nil end
    local w = M.arWants(uid, shell)
    local O, W = H.PA().TalkOrders, H.PA().Weapons
    local got = {}
    M.arStats.visits = M.arStats.visits + 1
    if w.weapon and O and O.equipWeapon then
        local it = w.weapon
        if pcall(function() c:DoRemoveItem(it); inv:AddItem(it) end) then
            local ok, done = false, false
            if w.kept then ok, done = true, equipKept(shell, it) else ok, done = pcall(O.equipWeapon, shell, it) end
            if ok and done then got[#got + 1] = (w.kept and "their " or "the ") .. nameOf(it); M.arStats.weapons = M.arStats.weapons + 1
            else pcall(function() inv:DoRemoveItem(it); c:AddItem(it) end) end -- couldn't use it: back on the rack
        end
    end
    local rounds = 0
    for _, it in ipairs(w.ammo) do
        local ok, slot, n = pcall(W.creditFor, shell, it)
        if ok and (tonumber(n) or 0) > 0 and pcall(function() c:DoRemoveItem(it) end) then
            pcall(W.addReserve, shell, slot, n)
            rounds = rounds + n
            M.arStats.ammo = M.arStats.ammo + 1
        end
    end
    if rounds > 0 then got[#got + 1] = rounds .. " rounds" end
    for _, it in ipairs(w.armor) do
        if O and O.wearArmor and pcall(function() c:DoRemoveItem(it); inv:AddItem(it) end) then
            local ok, done = pcall(O.wearArmor, shell, it)
            if ok and done then got[#got + 1] = string.lower(nameOf(it)); M.arStats.armor = M.arStats.armor + 1
            else pcall(function() inv:DoRemoveItem(it); c:AddItem(it) end) end
        end
    end
    if w.repair then
        local hw = held(shell)
        local cnow, cmax = nil, nil
        if hw then cnow, cmax = cond(hw) end
        if cnow and cmax then
            local used = false
            local drain = false
            pcall(function() drain = w.repair:IsDrainable() == true end) -- same check vanilla farming uses
            if drain then used = pcall(function() w.repair:Use() end) end
            if not used then used = pcall(function() c:DoRemoveItem(w.repair) end) end
            if used and pcall(function() hw:setCondition(math.min(cmax, math.floor(cnow + cmax * 0.3 + 0.5))) end) then
                got[#got + 1] = "fixed up the " .. nameOf(hw)
                M.arStats.repairs = (M.arStats.repairs or 0) + 1
            end
        end
    end
    if #got == 0 then return nil end
    local list = table.concat(got, ", ")
    H.log(uid .. " geared up: " .. list)
    M.cpLog("gear", H.firstName(uid) .. " took " .. list .. " from the armory")
    return list
end
local GEAR = { "Taking %s.", "Got %s. I'm set.", "%s. That'll do." }
local function announce(uid, shell, list)
    if list == nil then return end
    local line = string.format(H.pickLine(GEAR, uid .. list), list)
    line = string.upper(string.sub(line, 1, 1)) .. string.sub(line, 2)
    H.say(shell, line)
    H.halo(H.firstName(uid) .. " took " .. list .. " from the armory.", 200, 220, 255)
end

-- daily gear-up (and after "gear up")
M.cpAddJob({
    kind = "arm", order = 6,
    pick = function(uid, shell, player, b, now)
        if not M.arOn() or not fighter(uid) or rack() == nil then return nil end
        local a = M.arData()
        if a.day[uid] == today() then return nil end
        a.day[uid] = today() -- checked today either way
        if not anything(M.arWants(uid, shell)) then return nil end
        return { key = "arm:" .. uid, anim = "search_mid" }
    end,
    spot = function(j) return M.arData().spot end,
    ms = function(j) return M.arCfg.gearMs end,
    run = function(j, uid, shell, player) announce(uid, shell, M.arGear(uid, shell)); return "done" end,
})

-- on the alarm: fighters stop at the rack on the way to their post (once per alarm)
if H.fn(M, "alSpot") then
    local baseSpot = M.alSpot
    function M.alSpot(uid, player)
        local spot, kind = baseSpot(uid, player)
        if kind ~= "post" or not M.arOn() or rack() == nil then return spot, kind end
        local al = M.alData()
        al.geared = type(al.geared) == "table" and al.geared or {}
        if al.geared[tostring(uid)] then return spot, kind end
        local sh = H.shellFor(uid)
        if sh == nil or not anything(M.arWants(uid, sh)) then al.geared[tostring(uid)] = true; return spot, kind end
        return M.arData().spot, "armory"
    end
end
-- the alarm module calls this when someone reaches the armory on the alarm
function M.arAlarmStop(uid, shell)
    local al = M.alData()
    al.geared = type(al.geared) == "table" and al.geared or {}
    al.geared[tostring(uid)] = true
    announce(uid, shell, M.arGear(uid, shell))
end

-- "gear up"
table.insert(M.cpIntents, { id = "CAMP_GEAR_UP", kind = "gear_up", patterns = "gear up|grab your weapons|arm yourselves|get your guns|get armed|grab your gear|hit the armory" })
local baseOrder = M.cpOrder
function M.cpOrder(kind, record, player)
    if kind ~= "gear_up" then return baseOrder(kind, record, player) end
    local uid = tostring(record.uid)
    if not M.cpIsHome(uid, player) then return nil end
    if not M.arOn() then return "We don't keep an armory here." end
    if rack() == nil then H.halo("Right-click a container > Camp > Armory > Armory here."); return "Gear up from what? We don't have an armory." end
    local a = M.arData()
    for _, u in ipairs(M.cpPeople(player)) do a.day[u] = nil; M.cpNextTry[u] = nil end
    return fighter(uid) and "Grabbing my gear." or "I'm not one of the fighters. But I'll tell them."
end

-- menu: Camp > Armory
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local am, ao = child("Armory")
    if not M.arOn() then off(ao, "The armory is off in this world's sandbox settings.") end
    local a = M.arData()
    local sq = H.sqAt(x, y, z)
    local c = sq and H.containerOn(sq)
    local here = a.spot and a.spot.x == x and a.spot.y == y and a.spot.z == z
    if here then
        am:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_armory_anymore", "Not the armory anymore"), nil, function() M.cpAct("arSpotOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = am:addOption(a.spot and "Move the armory here" or "Armory here", nil, function() M.cpAct("arSpot", x, y, z, nil, nil, player) end)
        if c == nil then off(o, "Pick a container: a gun locker, a crate, a shelf.")
        elseif not inRange then off(o, why or "Too far from your base.") end
    end
    if a.spot then
        am:addOption(ALifeTr("IGUI_ALCP_Menu_Gear_up_now", "Gear up now"), nil, function() M.cpAct("arGearUp", nil, nil, nil, nil, nil, player) end)
    end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender)
M.cpActs = M.cpActs or {}
M.cpActs.arSpotOff = function() M.arData().spot = nil end
M.cpActs.arSpot = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    M.arData().spot = { x = x, y = y, z = z }
    H.halo("Armory set. Fighters take the best weapon, fitting ammo and armor from here, once a day and on the alarm.")
end
M.cpActs.arGearUp = function(player)
    local a = M.arData()
    if a.spot == nil then return false end
    for _, u in ipairs(M.cpPeople(player)) do a.day[u] = nil; M.cpNextTry[u] = nil end
    H.halo("Your fighters head to the armory.")
end
-- inventory right-click on a weapon: Camp: keep for... (only your fighters take a kept weapon, and only its owner)
function M.arItemMenu(playerNum, context, list)
    if not M.arOn() then return end
    local it = nil
    for _, v in ipairs(list or {}) do
        local x = v
        if type(v) == "table" and v.items then x = v.items[1] end
        if x and isWeapon(x) then it = x; break end
    end
    if it == nil then return end
    local player = getSpecificPlayer(playerNum)
    local fighters = {}
    for _, u in ipairs(M.cpPeople(player)) do if fighter(u) then fighters[#fighters + 1] = u end end
    if #fighters == 0 and M.arKeptFor(it) == nil then return end
    local o = context:addOption(ALifeTr("IGUI_ALCP_Menu_Camp_keep_for", "Camp: keep for..."))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(o, sub)
    local cur = M.arKeptFor(it)
    for _, u in ipairs(fighters) do
        sub:addOption(H.firstName(u) .. (cur == u and " (theirs now)" or ""), nil, function()
            pcall(function() it:getModData().ALifeKeepFor = u end)
            H.halo(nameOf(it) .. " is " .. H.firstName(u) .. "'s now. Put it in the armory and they'll take it.")
        end)
    end
    if cur then sub:addOption(ALifeTr("IGUI_ALCP_Menu_Anyone_no_owner", "Anyone (no owner)"), nil, function() pcall(function() it:getModData().ALifeKeepFor = nil end) end) end
end
if type(Events) == "table" and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(function(p, context, list)
        if M._arMenuDead then return end
        local ok, err = pcall(M.arItemMenu, p, context, list)
        if not ok then M._arMenuDead = true; H.log("armory item menu error, off for this session: " .. tostring(err)) end
    end)
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function() local s = M.arData().spot; if s then return { { s, 0.8, 0.8, 0.8 } } end end)
