-- A-Life NPC Overhaul 0.8.11: DROP LOOT. Real people shed weight to run.
--   A group the fight brain says is running ("break"): each runner may drop their bag, else their heaviest carried
--   things (never what's in their hands, never what they wear but the bag, never a weapon). Real items from their
--   real inventory, onto the floor where they stood. Nothing spawned.
--   A group that gives up (brain give-up or talked down): guns down on the floor (A-Life's own TalkOrders.disarm,
--   as A-Life's own "surrender" order does).
-- Hooked on the fight brain's think (B.thinkGroup) and on ALifeFightTalk's give-up. Server / SP. All settings.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeFightBrain"

ALifeDropLoot = ALifeDropLoot or {}
local D = ALifeDropLoot
local B = ALifeFightBrain
local TAG = "[ALifeDropLoot]"
D.VERSION = ALifeSide.MOD_VERSION
D.metrics = D.metrics or { runners = 0, bags = 0, items = 0, gunsDown = 0 }

D.DEFAULTS = {
    dropLoot = true,           -- runners drop their bag or heavy things
    dropLootChance = 40,       -- % each runner drops something
    dropLootBag = true,        -- the bag on their back goes first (unverified on 42.21: model update, see docs)
    dropLootItems = 2,         -- no bag: this many of their heaviest things
    dropLootMinWeight = 1.5,   -- ... only things at least this heavy
    giveUpDropGuns = true,     -- a group that gives up puts its guns on the floor
}
D.FILE_KEYS = {}
for k in pairs(D.DEFAULTS) do D.FILE_KEYS[#D.FILE_KEYS + 1] = k end
table.sort(D.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end

function D.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = D.DEFAULTS[key] end
    return v
end
function D.n(key) return num(D.setting(key), num(D.DEFAULTS[key], 0)) end

local function isDown(m)
    local mem = type(m.actor) == "table" and m.actor.memory or nil
    return type(mem) == "table" and type(mem.injury) == "table" and mem.injury.s == "down"
end

-- off the inventory, onto the floor (A-Life's disarm / companion drop pattern; MP: sendRemoveItemFromContainer)
function D.toFloor(shell, inv, item, i)
    local square = nil
    pcall(function() square = shell:getCurrentSquare() end)
    if square == nil then return false end
    return pcall(function()
        inv:Remove(item)
        if ALifeSide.server() and type(sendRemoveItemFromContainer) == "function" then
            sendRemoveItemFromContainer(inv, item)
        end
        square:AddWorldInventoryItem(item, 0.2 + (i % 4) * 0.15, 0.3 + (i % 3) * 0.2, 0)
    end) == true
end

-- the bag on their back: an InventoryContainer they wear (as A-Life's CompanionSheet.bagName finds it)
function D.bagOf(shell)
    local bag, list = nil, nil
    pcall(function()
        list = shell:getWornItems()
        for i = 0, list:size() - 1 do
            local it = list:get(i):getItem()
            if bag == nil and it ~= nil and instanceof(it, "InventoryContainer") then bag = it end
        end
    end)
    return bag, list
end
-- take it off (WornItems.remove, 42.21 jar; setWornItems + resetModelNextFrame as A-Life's Cold.dressPass), drop it
function D.dropBag(shell, inv)
    local bag, list = D.bagOf(shell)
    if bag == nil then return false end
    local off = pcall(function()
        list:remove(bag)
        shell:setWornItems(list)
    end)
    if not off then return false end
    D.dropVisual(shell, bag)
    pcall(function() shell:resetModelNextFrame() end)
    return D.toFloor(shell, inv, bag, 0)
end
-- 0.8.11.1: an NPC shell (IsoZombie) draws from its ItemVisuals, not its worn items: take the bag's visual out too.
-- A-Life's own ways: DeathDrops (visuals:remove(item:getVisual())), else by type (ItemVisual:getItemType, as
-- A-Life's DeathVoice / AIFence read it; 42.21 jar has getItemType). One visual only.
function D.dropVisual(shell, item)
    local done = false
    pcall(function()
        local visuals = shell:getItemVisuals()
        if visuals == nil then return end
        local v = item:getVisual()
        if v ~= nil and visuals:contains(v) then visuals:remove(v); done = true; return end
        local full, short = item:getFullType(), item:getType()
        for i = visuals:size() - 1, 0, -1 do
            local iv = visuals:get(i)
            local t = iv:getItemType()
            if t ~= nil and (t == full or t == short) then visuals:remove(iv); done = true; return end -- by object (remove(int) is ambiguous from Lua)
        end
    end)
    if done then D.metrics.visuals = (D.metrics.visuals or 0) + 1 end
    return done
end

-- heaviest carried things: not in hands, not worn, not a weapon
function D.heavy(shell, inv, limit, minW)
    local held1, held2, list = nil, nil, nil
    pcall(function() held1 = shell:getPrimaryHandItem() end)
    pcall(function() held2 = shell:getSecondaryHandItem() end)
    pcall(function() list = shell:getWornItems() end)
    local cands = {}
    pcall(function()
        local items = inv:getItems()
        for i = 0, math.min(items:size(), 120) - 1 do
            local it = items:get(i)
            if it ~= nil and it ~= held1 and it ~= held2 and not instanceof(it, "HandWeapon") then
                local worn = false
                if list ~= nil then pcall(function() worn = list:contains(it) == true end) end
                if not worn then
                    local w = 0
                    pcall(function() w = tonumber(it:getActualWeight()) or 0 end)
                    if w >= minW then cands[#cands + 1] = { item = it, w = w } end
                end
            end
        end
    end)
    table.sort(cands, function(a, b) return a.w > b.w end)
    local out = {}
    for i = 1, math.min(limit, #cands) do out[i] = cands[i].item end
    return out
end

-- one runner. Returns "bag" | n items | nil
function D.runner(m)
    local shell = m.shell
    local inv = nil
    pcall(function() inv = shell:getInventory() end)
    if inv == nil then return nil end
    if D.setting("dropLootBag") ~= false and D.dropBag(shell, inv) then D.metrics.bags = D.metrics.bags + 1; return "bag" end
    local n = 0
    for i, it in ipairs(D.heavy(shell, inv, math.floor(D.n("dropLootItems")), D.n("dropLootMinWeight"))) do
        if D.toFloor(shell, inv, it, i) then n = n + 1 end
    end
    D.metrics.items = D.metrics.items + n
    if n > 0 then return n end
    return nil
end

function D.onBreak(gid, st, f)
    if st.droppedLoot or D.setting("dropLoot") == false then return 0 end
    st.droppedLoot = true
    local count = 0
    for _, m in ipairs(f and f.list or {}) do
        if m.shell ~= nil and not isDown(m) and roll(100) < D.n("dropLootChance") then
            local ok, r = pcall(D.runner, m)
            if ok and r ~= nil then count = count + 1 end
        end
    end
    if count > 0 then
        D.metrics.runners = D.metrics.runners + count
        log("group " .. tostring(gid) .. ": " .. count .. " dropped stuff to run")
    end
    return count
end

function D.onGiveUp(gid, st, f, now)
    if st.gunsDown or D.setting("giveUpDropGuns") == false then return 0 end
    -- 0.8.11.1: criminals who may fake it (brain feint on) keep a gun hidden until the feint roll is done
    if B.setting("feint") == true and st.class == "criminal" and st.vsPlayer and not st.feintRolled then return 0 end
    st.gunsDown = true
    local pa = PA()
    local O = pa and pa.TalkOrders or nil
    if not fn(O, "disarm") then return 0 end
    local n = 0
    for _, m in ipairs(f and f.list or {}) do
        if m.shell ~= nil then
            local ok, c = pcall(O.disarm, m.shell)
            if ok then n = n + (tonumber(c) or 0) end
        end
    end
    D.metrics.gunsDown = D.metrics.gunsDown + n
    if n > 0 then log("group " .. tostring(gid) .. ": " .. n .. " weapons on the floor") end
    return n
end

-- after each think of the brain: running -> drop; given up (surrendered) -> guns down
function D.hook()
    if D.hooked then return true end
    if not fn(B, "thinkGroup") then return false end
    local orig = B.thinkGroup
    B.thinkGroup = function(groupId, contact, now, ...)
        local st, f = orig(groupId, contact, now, ...)
        if type(st) == "table" and not st.advisory and type(f) == "table" then
            if st.mood == "break" then pcall(D.onBreak, groupId, st, f) end
            if st.mood == "giveup" and st.surrendered then pcall(D.onGiveUp, groupId, st, f, now) end
        end
        return st, f
    end
    D.hooked = true
    return true
end
D.hook()
print(TAG .. " ready v" .. D.VERSION .. ": runners drop bags / heavy things, give-ups drop guns (hook " .. (D.hooked and "on" or "OFF") .. ")")

return D
