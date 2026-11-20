-- A-Life NPC Overhaul pre-1.0: plant a claim sign from the inventory (right-click the Claim Sign -> Plant claim sign -> kind).
-- It goes on the square in front of you. Logic: shared ALifeClaimSign.plant (legacy side, same machine).
require "ALifeNPCOverhaul/ALifeClaimSign"
local CS = ALifeClaimSign
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_Claim_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
local WHY = {
    claimed = "That's {1} ground. Their sign stands near here.",
    blocked = "Something's in the way.",
    far = "Too far.",
    noitem = "No sign to plant.",
    kind = "Not that kind.",
    off = "Claim signs are off.",
}
local KIND_WORDS = { hostile = "Hostile (keep out)", neutral = "Neutral (no trouble)", friendly = "Friendly (welcome)", slaver = "Slaver" }

local function say(player, text) pcall(function() player:Say(text) end) end

-- the square in front of the player
local function frontOf(player)
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local ok, v = pcall(function() return player:getForwardDirection() end)
    if ok and v then
        local fx, fy = 0, 0
        pcall(function() fx, fy = v:getX(), v:getY() end)
        if math.abs(fx) > 0.38 then x = x + (fx > 0 and 1 or -1) end
        if math.abs(fy) > 0.38 then y = y + (fy > 0 and 1 or -1) end
    end
    return x, y, z
end

local function plant(player, kind)
    local x, y, z = frontOf(player)
    local ok, why, name = CS.plant(player, { kind = kind, x = x, y = y, z = z })
    if ok then say(player, tr("Planted", "This ground is ours now.")); return end
    say(player, tr("Why_" .. tostring(why), WHY[why] or "Can't plant it here.", tostring(name or "someone's")))
end

local function fill(playerNum, context, items)
    if not CS.on() then return end
    local player = getSpecificPlayer(playerNum)
    if player == nil then return end
    for _, v in ipairs(items or {}) do
        local it = type(v) == "table" and v.items and v.items[1] or v
        local ok, full = pcall(function() return it:getFullType() end)
        if ok and full == CS.ITEM then
            local opt = context:addOption(tr("Plant", "Plant claim sign"), nil, nil)
            local sub = ISContextMenu:getNew(context)
            context:addSubMenu(opt, sub)
            for _, kind in ipairs(CS.kindsFor(player)) do
                sub:addOption(tr("Kind_" .. kind, KIND_WORDS[kind] or kind), player, plant, kind)
            end
            return
        end
    end
end
if type(Events) == "table" and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(function(a, b, c)
        local ok, e = pcall(fill, a, b, c)
        if not ok and not CS._menuErr then CS._menuErr = true; print("[ALifeClaimSign] menu error (logged once): " .. tostring(e)) end
    end)
end
