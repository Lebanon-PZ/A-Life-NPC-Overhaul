-- A-Life NPC Overhaul 0.6.1: one-time notice when a world's loot settings fight "the world bleeds dry".
-- Checked once per load, a few seconds in; shown once per world (ModData), the console line every load.
-- The mod never changes the settings itself.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Notices") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local TAG = "[ALifeNotice]"
local N = {}
ALifeNotices = N
local function sv(path)
    local t = SandboxVars
    for part in string.gmatch(path, "[^%.]+") do
        if type(t) ~= "table" then return nil end
        t = t[part]
    end
    return t
end
function N.lootIssues()
    local out = {}
    local dim = tonumber(sv("MaximumDiminishedLoot"))
    if dim and dim > 0 then out[#out + 1] = "Diminished Loot is " .. math.floor(dim) .. " (recommended: None)" end
    local looted = tonumber(sv("MaximumLooted"))
    if looted and looted > 0 then out[#out + 1] = "Looted Buildings is " .. math.floor(looted) .. " (recommended: None)" end
    local on = sv("ALife.PickedOver_Enabled")
    if on == false then out[#out + 1] = "A-Life's \"Previously scavenged buildings\" is off (recommended: on, it adds the open doors and bodies)" end
    local rate = tonumber(sv("ALife.PickedOver_Strength"))
    if on ~= false and rate and rate > 0 then out[#out + 1] = "A-Life's \"Previously scavenged building rate\" is " .. math.floor(rate) .. " (recommended: 0)" end
    return out
end
function N.check()
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" and (M.settings.enabled == false or M.settings.honestScavenge == false) then return end
    local issues = N.lootIssues()
    if #issues == 0 then return end
    print(TAG .. " loot settings that fight \"the world bleeds dry\": " .. table.concat(issues, "; "))
    local md = ModData and ModData.getOrCreate and ModData.getOrCreate("ALifeChatPlus.Notices") or nil
    if md == nil or md.lootSettings then return end
    md.lootSettings = true
    if ISModalRichText == nil or getCore == nil then return end
    local text = (ALifeTr or function(_, e, x) return (string.gsub(e, "%%1", function() return x end)) end)("IGUI_ALCP_NoticeLoot", "<SIZE:medium> A-Life NPC Overhaul: loot settings <LINE> <SIZE:small> <LINE> In this mod, loot only disappears when someone in the world takes it: NPCs strip real houses and those stay bare. These world settings also take loot away on their own, so the world will run dry faster than intended: <LINE> <LINE> - %1 <LINE> <LINE> They're your settings and nothing has been changed. You'll only see this once in this world.", table.concat(issues, " <LINE> - "))
    local w, h = 560, 320
    local modal = ISModalRichText:new(math.max(0, (getCore():getScreenWidth() - w) / 2), math.max(0, (getCore():getScreenHeight() - h) / 2), w, h, text, false, nil, nil, 0)
    modal:initialise()
    modal:addToUIManager()
end
-- 0.6.12: Living Factions alongside. NPC Overhaul replaces it: both run faction worlds, and Living Factions spawns
-- loot and people, which breaks "nothing spawns". Never disabled for you: a console line every load, a notice once.
function N.livingFactions()
    local on = type(ADW) == "table"
    pcall(function()
        local mods = getActivatedMods()
        for i = 0, mods:size() - 1 do
            local id = tostring(mods:get(i))
            if string.find(id, "AliveJeemDynamicWorld", 1, true) then on = true end
        end
    end)
    return on
end
function N.checkLF()
    if not N.livingFactions() then return end
    print(TAG .. " A-Life: Living Factions is also enabled. NPC Overhaul already runs living factions (without spawning loot or people); running both doubles up and breaks \"nothing spawns\". Recommended: disable Living Factions.")
    local md = ModData and ModData.getOrCreate and ModData.getOrCreate("ALifeChatPlus.Notices") or nil
    if md == nil or md.livingFactions then return end
    md.livingFactions = true
    if ISModalRichText == nil or getCore == nil then return end
    local text = (ALifeTr or function(_, e) return e end)("IGUI_ALCP_NoticeLF", "<SIZE:medium> A-Life NPC Overhaul: Living Factions is also on <LINE> <SIZE:small> <LINE> NPC Overhaul already runs living factions: groups that trade, raid, starve, take each other over and come to your door. Living Factions does the same job its own way, and it spawns loot and people, which this mod never does. Running both doubles up the factions and breaks \"the world bleeds dry\". <LINE> <LINE> Recommended: disable A-Life: Living Factions. <LINE> <LINE> Nothing has been changed. You'll only see this once in this world.")
    local w, h = 560, 300
    local modal = ISModalRichText:new(math.max(0, (getCore():getScreenWidth() - w) / 2), math.max(0, (getCore():getScreenHeight() - h) / 2), w, h, text, false, nil, nil, 0)
    modal:initialise()
    modal:addToUIManager()
end
-- a few seconds after load (no per-frame work once done: the tick removes itself)
N.at = nil
function N.tick()
    local now = getTimestampMs()
    if N.at == nil then N.at = now + 5000 end
    if now < N.at then return end
    ALifeHealth.remove(Events.OnTick, N.tick)
    local ok, err = pcall(N.check)
    if not ok then print(TAG .. " check failed: " .. tostring(err)) end
    local ok2, err2 = pcall(N.checkLF)
    if not ok2 then print(TAG .. " Living Factions check failed: " .. tostring(err2)) end
end
if type(Events) == "table" and Events.OnGameStart and Events.OnTick then
    Events.OnGameStart.Add(function() N.at = nil; ALifeHealth.add(Events.OnTick, "ALifeTalk_Notices", N.tick) end)
end
return N
