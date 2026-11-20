-- A-Life NPC Overhaul: the NPC sizes you up.
-- A-Life already decides whether someone obeys, surrenders or fights back from "is the stranger armed / aiming /
-- with friends" (TalkOrders.edge). It doesn't look at HOW armed: a broken kitchen knife and a fresh fire axe count
-- the same, armor on you doesn't count at all, nor who's hurt. This adds that, both ways:
--   your weapon's real power and condition, your armor, your health, your people nearby
--   vs their weapon, their armor, their health, their crew
-- The difference shifts A-Life's own edge (so a well-geared stranger makes even a tough NPC fold, and a fresh
-- survivor with a bat gets laughed at and fought), and it's described to the AI so the words match:
-- scared people sound scared, confident people sound confident - whatever their archetype says on paper.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeSituation") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeSituation]"
ALifeSituation = ALifeSituation or {}
local S = ALifeSituation
S.MAX_SHIFT = 18
S.CLICK_TILES = 15              -- pulling an empty trigger: people this close hear the click
S.CLICK_MEMORY_MS = 10 * 60000  -- and remember your gun was empty this long (until they see you reload, roughly)
S.heardClick = S.heardClick or {}   -- uid -> ms they heard your gun click empty (cleared when they see you reload)
S.RELOAD_TILES = 12             -- people this close see or hear you reload                -- most this can move A-Life's edge either way (A-Life's own edge runs about -40..+40)

local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end

-- 0 (nothing) .. 10 (loaded rifle): what this weapon can actually do, worn down by its condition
function S.weaponPower(item, ownGun, believedEmpty)
    if item == nil or not (type(instanceof) == "function" and instanceof(item, "HandWeapon")) then return 0, "bare hands" end
    local full = tostring(call(item, "getFullType") or "")
    if full == "Base.BareHands" then return 0, "bare hands" end
    local name = tostring(call(item, "getDisplayName") or full)
    local cond, maxc = tonumber(call(item, "getCondition")) or 1, tonumber(call(item, "getConditionMax")) or 1
    local wear = maxc > 0 and math.max(0.25, cond / maxc) or 1
    if call(item, "isRanged") == true then
        local ammo = tonumber(call(item, "getCurrentAmmoCount"))
        -- only the holder knows if it's loaded: from the outside every gun looks loaded
        local loaded = ownGun ~= true or ammo == nil or ammo > 0
        if believedEmpty then loaded = false end      -- what they believe, not what's in it
        local p = loaded and 8 or 3
        if (tonumber(call(item, "getProjectileCount")) or 1) > 1 then p = p + 1 end
        return math.min(10, p * (0.7 + 0.3 * wear)), name .. (loaded and "" or " (empty)")
    end
    local dmg = tonumber(call(item, "getMaxDamage")) or 1
    local p = math.min(6, 1 + dmg * 2.2)                   -- knife ~2, bat/crowbar ~3.5, axe ~5, sledge ~6
    return p * wear, name .. (wear < 0.5 and " (beat up)" or "")
end

function S.armor(who)
    local Orders = ProjectALife and ProjectALife.TalkOrders
    if Orders ~= nil and type(Orders.armorOf) == "function" then
        local ok, v = pcall(Orders.armorOf, who)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return 0
end

-- only what someone can SEE: open wounds bleeding, bandages, limping, exhaustion, and - once an infection is far
-- along - looking pale and feverish. A fresh bite under a sleeve shows nothing; your hidden health bar shows nothing.
function S.visible(player)
    local bd = call(player, "getBodyDamage")
    local bleeding = tonumber(call(bd, "getNumPartsBleeding")) or 0
    local bandaged = tonumber(call(bd, "getNumPartsBandaged")) or 0
    local infection = tonumber(call(bd, "getInfectionLevel")) or 0
    local stats = call(player, "getStats")
    local endurance = tonumber(call(stats, "getEndurance")) or 1
    local limping = false
    pcall(function()
        local legs = { BodyPartType.Foot_L, BodyPartType.Foot_R, BodyPartType.LowerLeg_L, BodyPartType.LowerLeg_R, BodyPartType.UpperLeg_L, BodyPartType.UpperLeg_R }
        for _, t in ipairs(legs) do
            local part = bd:getBodyPart(t)
            if part ~= nil and (part:getFractureTime() > 0 or part:getDeepWoundTime() > 0 or part:bleeding()) then limping = true end
        end
    end)
    local look, h = {}, 100
    if bleeding > 0 then look[#look + 1] = "bleeding"; h = h - 15 * math.min(3, bleeding) end
    if bandaged > 0 then look[#look + 1] = "bandaged"; h = h - 5 * math.min(3, bandaged) end
    if limping then look[#look + 1] = "limping"; h = h - 15 end
    if endurance < 0.3 then look[#look + 1] = "exhausted"; h = h - 10 end
    if infection >= 50 then look[#look + 1] = "pale, sweating, feverish"; h = h - 15 end
    return math.max(0, h), look
end

local function playerHealth(player)
    local h = S.visible(player)
    return h
end

-- the dead close by (to them): count within this many tiles
function S.deadNear(who, tiles)
    tiles = tiles or 15
    local n = 0
    pcall(function()
        local x, y = who:getX(), who:getY()
        local list = getCell():getZombieList()
        local Talk = ProjectALife.Talk
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            if not z:isDead() and (z:getX() - x) ^ 2 + (z:getY() - y) ^ 2 <= tiles * tiles then
                -- A-Life NPCs ride on zombie bodies: don't count living people as the dead
                local isPerson = false
                pcall(function()
                    local perception = ProjectALife.Perception
                    if perception and perception.activeActorForShell and perception.activeActorForShell(z) ~= nil then isPerson = true end
                end)
                if not isPerson then n = n + 1 end
            end
        end
    end)
    return n
end

local function npcHealth(record)
    local m = type(record) == "table" and record.memory or nil
    local h = type(m) == "table" and (tonumber(m.health) or tonumber(m.hp)) or tonumber(record and record.health)
    if h == nil then return 100 end
    if h <= 1.5 then h = h * 100 end
    return math.max(0, math.min(100, h))
end

local function crewOf(record, shell)
    local Orders = ProjectALife and ProjectALife.TalkOrders
    if Orders ~= nil and type(Orders.crew) == "function" then
        local ok, c = pcall(Orders.crew, record, shell)
        if ok and type(c) == "table" then return c end
    end
    return { { record = record, shell = shell } }
end

local function partyOf(player)
    local Orders = ProjectALife and ProjectALife.TalkOrders
    if Orders ~= nil and type(Orders.partyOf) == "function" then
        local ok, n = pcall(Orders.partyOf, player)
        if ok and tonumber(n) then return tonumber(n) end
    end
    return 0
end

-- How the two sides compare. shift > 0: you have the upper hand.
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

function S.read(record, shell, player)
    -- they only know your gun is empty if they heard it click, and it still is
    local heard = type(record) == "table" and record.uid and S.heardClick[record.uid]
    local knows = heard ~= nil and nowMs() - heard < S.CLICK_MEMORY_MS
    local yw, ywName = S.weaponPower(call(player, "getPrimaryHandItem"), false, knows)
    local ya, yh, yp = S.armor(player), playerHealth(player), partyOf(player)
    local crew = crewOf(record, shell)
    local tw, twName, ta, best = 0, "bare hands", 0, 0
    for _, m in ipairs(crew) do
        local p, n = S.weaponPower(call(m.shell, "getPrimaryHandItem"), true)   -- they know their own ammo
        tw = tw + p
        if m.shell == shell or p > best then if m.shell == shell then twName = n end; best = math.max(best, p) end
        ta = ta + S.armor(m.shell)
    end
    local th = npcHealth(record)
    -- A-Life's edge already counts "armed / gun / aiming", heads on each side and distance; this adds quality only
    local you = yw * 2 + ya * 2 + (yh - 100) / 10
    local them = (best * 2 + (tw - best) * 0.5) + ta / math.max(1, #crew) * 2 + (th - 100) / 10
    local shift = math.max(-S.MAX_SHIFT, math.min(S.MAX_SHIFT, math.floor(you - them + 0.5)))
    local feel
    if shift >= 10 then feel = "outmatched: the stranger is far better armed and protected than you; you are afraid of them"
    elseif shift >= 4 then feel = "at a disadvantage: the stranger is better equipped than you; you are wary and careful"
    elseif shift <= -10 then feel = "stronger: you are far better armed than the stranger; you are not intimidated at all"
    elseif shift <= -4 then feel = "the upper hand: you are better equipped than the stranger; you are confident"
    else feel = "evenly matched: neither of you has a clear edge" end
    local _, look = S.visible(player)
    local dead = S.deadNear(shell, 15)
    local text = string.format("Stranger: %s, %s, %s%s. You: %s, %s, %s%s. You feel %s.%s",
        ywName, ya >= 2 and "well armored" or (ya >= 1 and "some armor" or "no armor"),
        #look > 0 and table.concat(look, ", ") or "looks healthy", yp > 0 and (", with " .. yp .. " others") or ", alone",
        twName, ta >= 2 and "well armored" or (ta >= 1 and "some armor" or "no armor"),
        th < 60 and "hurt" or "healthy", #crew > 1 and (", with " .. (#crew - 1) .. " of your people") or ", alone", feel,
        dead >= 8 and (" DANGER: a horde of the dead is right here (" .. dead .. " close by) - you are scared for your life.")
        or (dead >= 3 and (" Several of the dead are close by (" .. dead .. ").") or ""))
    return { shift = shift, text = text, you = you, them = them, dead = dead }
end

function S.install()
    if S.__installed then return true end
    local Orders = ProjectALife and ProjectALife.TalkOrders
    if Orders == nil or type(Orders.edge) ~= "function" then return false end
    S.__installed = true
    -- A-Life's edge treats your gun as empty if it is; nobody can see that from across the street
    if type(Orders.gunEmpty) == "function" then Orders.gunEmpty = function() return false end end
    local original = Orders.edge
    Orders.edge = function(shell, player, crew)
        local base = original(shell, player, crew)
        local ok, extra = pcall(function()
            local record
            for _, m in ipairs(type(crew) == "table" and crew or {}) do if m.shell == shell then record = m.record end end
            return S.read(record or { memory = {} }, shell, player).shift
        end)
        if ok and type(extra) == "number" then return base + extra end
        return base
    end
    print(TAG .. " ready (weapon quality, armor and health now count when NPCs decide to obey or fight)")
    return true
end

-- an empty gun clicks: everyone close enough hears it
function S.onSwing(character, weapon)
    if character == nil or weapon == nil then return end
    if not ALifeSide.isOnlinePlayer(character) then return end -- pre-1.0 MP: any online player (SP: you)
    if call(weapon, "isRanged") ~= true then return end
    local ammo = tonumber(call(weapon, "getCurrentAmmoCount")) or 1
    if ammo > 0 or call(weapon, "isRoundChambered") == true then return end
    local Talk = ProjectALife and ProjectALife.Talk
    if Talk == nil or type(Talk.listeners) ~= "function" then return end
    local ok, list = pcall(Talk.listeners, character, S.CLICK_TILES)
    if not ok or type(list) ~= "table" then return end
    local t = nowMs()
    for _, l in ipairs(list) do
        S.heardClick[l.record.uid] = t
        if ALifeMemory ~= nil then pcall(ALifeMemory.add, l.record, "you heard the stranger's gun click empty") end
    end
end

-- a reload: whoever is close enough sees it and knows you're loaded again; the rest still think you're dry
local lastAmmo, lastGun = nil, nil
function S.watchReload()
    local player = ALifeSide.campPlayer()
    local gun = call(player, "getPrimaryHandItem")
    if gun == nil or call(gun, "isRanged") ~= true then lastAmmo, lastGun = nil, nil; return end
    local ammo = (tonumber(call(gun, "getCurrentAmmoCount")) or 0) + (call(gun, "isRoundChambered") == true and 1 or 0)
    if gun == lastGun and lastAmmo ~= nil and ammo > lastAmmo then
        local Talk = ProjectALife and ProjectALife.Talk
        local ok, list = pcall(Talk.listeners, player, S.RELOAD_TILES)
        if ok and type(list) == "table" then
            for _, l in ipairs(list) do
                if S.heardClick[l.record.uid] ~= nil then
                    S.heardClick[l.record.uid] = nil
                    if ALifeMemory ~= nil then pcall(ALifeMemory.add, l.record, "you saw the stranger reload") end
                end
            end
        end
    end
    lastAmmo, lastGun = ammo, gun
end

local reloadTick = 0
if Events ~= nil and Events.OnTick ~= nil then
    ALifeHealth.add(Events.OnTick, "ALifeSituation", function()
        reloadTick = reloadTick + 1
        if reloadTick < 20 then return end
        reloadTick = 0
        pcall(S.watchReload)
    end)
end

if Events ~= nil and Events.OnWeaponSwing ~= nil then
    ALifeHealth.add(Events.OnWeaponSwing, "ALifeSituation", function(c, w) pcall(S.onSwing, c, w) end)
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(S.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
