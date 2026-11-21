-- A-Life NPC Overhaul 0.9.5 (Legacy): WALK AWAY. The last quest in the mod, and the rarest.
-- Only when everything is in place (a year in, the region at peace or settled, a big camp that loves you), and then
-- only by chance (walkAwayChance % a day, once): a card. You can leave it all behind.
--   * Say yes: the camp goes on without you (ALifeLegacy: your heir takes over, you're remembered as a Legend who
--     walked away), and gives you what it can spare for the road: real things out of the base's own storage (food,
--     water, medicine, ammunition), more the bigger the camp. Then you go. Your character goes on, a stranger to it.
--   * Say no: it doesn't come again.
-- Settings: walkAway, walkAwayDay, walkAwayPeople, walkAwayChance.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_WalkAway") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeWalkAway = ALifeWalkAway or {}
local W = ALifeWalkAway
local TAG = "[ALifeWalkAway]"
W.VERSION = ALifeSide.MOD_VERSION
W.DEFAULTS = { walkAway = true, walkAwayDay = 365, walkAwayPeople = 10, walkAwayChance = 1, walkAwayLove = 40 }
W.GIFT_KINDS = { food = true, water = true, medicine = true, ammo = true }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = W.DEFAULTS[k] end; return v end
local function letter(t) -- pre-1.0 MP: on a server the player handled, else everyone online (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, ALifeSide.cur, t, 230, 220, 200) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 230, 220, 200) end
end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(W.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function W.store() local s = fn(M, "bucket") and M.bucket("walkAway") or (W._mem or {}); if not fn(M, "bucket") then W._mem = s end; return s end
-- everything in place?
function W.ready(player)
    if setting("walkAway") == false or player == nil then return false, "off" end
    if W.store().done then return false, "done" end
    if hours() < (tonumber(setting("walkAwayDay")) or 365) * 24 then return false, "early" end
    local R = ALifeRegion
    if type(R) == "table" and fn(R, "store") then
        local rs = R.store()
        if rs.war ~= nil then return false, "war" end
    end
    local G = ALifeLegacy
    if not fn(G, "baseOf") then return false, "nolegacy" end
    local key = G.keyOf(player)
    local base = G.baseOf(key)
    if base == nil then return false, "nobase" end
    local people = G.residents(base)
    if #people < (tonumber(setting("walkAwayPeople")) or 10) then return false, "small" end
    local sum = 0
    for _, r in ipairs(people) do local v = 0; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end); sum = sum + v end
    if sum / #people < (tonumber(setting("walkAwayLove")) or 40) then return false, "love" end
    return true, base, people
end
-- the camp's gift: real things from the base's storage (Ghost build's container scan), more for a bigger camp
function W.gift(player, nPeople)
    local want = math.min(40, 2 * nPeople)
    local K = ALifeGhost
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    local list = (fn(K, "containers") and b) and K.containers(b) or {}
    local inv = nil
    pcall(function() inv = player:getInventory() end)
    if inv == nil then return 0 end
    local got = 0
    for _, e in ipairs(list) do
        if got >= want then break end
        pcall(function()
            local items = e.c:getItems()
            for i = items:size() - 1, 0, -1 do
                if got >= want then break end
                local it = items:get(i)
                local kind = fn(M, "nbKindOf") and M.nbKindOf(it:getFullType()) or nil
                if W.GIFT_KINDS[kind or ""] then
                    e.c:Remove(it)
                    pcall(sendRemoveItemFromContainer, e.c, it)
                    inv:AddItem(it)
                    pcall(sendAddItemToContainer, inv, it)
                    got = got + 1
                end
            end
        end)
    end
    return got
end
function W.leave(player, people)
    local s = W.store()
    s.done = hours()
    local n = W.gift(player, #people)
    local G = ALifeLegacy
    local name = nil
    pcall(function() name = player:getDescriptor():getForename() end)
    local row = nil
    if fn(G, "died") then
        local old = {}
        for _, r in ipairs(people) do local v = nil; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end); if v then old[tostring(r.uid)] = math.floor(v) end end
        local ok, r = pcall(G.died, player, { name = name or "The boss", old = old })
        if ok then row = r end
        if type(row) == "table" then row.title = "LEGEND"; row.walked = hours() end
    end
    if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then
        pcall(ALifeChronicle.add, { k = "legacy", who = name, what = tostring(name or "The boss") .. " walked away, with what the camp could spare. We let them go" })
    end
    letter("You walk away. They gave you what they could spare (" .. (n > 0 and "a full pack" or "their blessing") .. "). " .. (type(row) == "table" and row.heirName and (row.heirName .. " has the camp now.") or "The camp is theirs now."))
    return n, row
end
function W.daily(player, rollFn)
    local ok, base, people = W.ready(player)
    if not ok then return nil end
    local roll = 99
    if rollFn then roll = rollFn() else pcall(function() roll = ZombRand(100) end) end
    if roll >= (tonumber(setting("walkAwayChance")) or 1) then return nil end
    local s = W.store()
    s.done = hours() -- offered once
    if ALifeSide.canOutCard() then
        pcall(ALifeSide.outCard, playerOf(), { id = "walkaway", title = "A chance to walk away", default = 2,
            text = "The camp runs itself now. They'd be fine without you. For the first time since it all started, you could just... go. "
                .. "<LINE> <LINE> They'd give you what they can spare for the road. The camp would be theirs. This won't come again.",
            choices = { { label = "Walk away", fn = function() W.leave(player, people) end }, { label = "Stay", fn = function() end } } })
    end
    return "offered"
end
function W.install()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "walkAway", "Walk away: once, very rarely, when everything is in place, you can leave it all behind" },
            { "walkAwayDay", "Walk away: not before this day", { 180, 365, 730 } },
            { "walkAwayChance", "Walk away: chance a day once everything is in place (%)", { 1, 3, 10 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Secrets and roadmap" end
        end
    end
    print(TAG .. " ready v" .. W.VERSION .. ": the last quest (" .. (setting("walkAway") ~= false and "on" or "off") .. ")")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(W.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(W.daily, playerOf()) end) end
end
return W
