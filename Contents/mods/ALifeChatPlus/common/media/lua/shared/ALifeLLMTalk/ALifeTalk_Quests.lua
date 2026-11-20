-- A-Life NPC Overhaul 0.8.6: PEOPLE WANT THINGS, client side: the settings (defaults + save keys at load time, rows on
-- the Settings tab). The rules live in shared/ALifeNPCOverhaul/ALifeQuests.lua (A-Life's task board, made honest).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Quests") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UIBond" here (client-only file, loads after shared; used at call time only)
require "ALifeNPCOverhaul/ALifeQuests"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Quests86"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Quests86") end end

local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeQuests) ~= "table" then return end
local Q = ALifeQuests

ALifeTalkQuests = ALifeTalkQuests or {}
local K = ALifeTalkQuests
K.VERSION = "0.8.6"

-- load time, before the settings file is read (else the keys reset on restart)
function K.settings()
    if type(M.settings) ~= "table" then return end
    for k, v in pairs(Q.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    if M.settings.questsOld == nil then M.settings.questsOld = false end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, k in ipairs(M.fileKeys) do have[k] = true end
        for _, k in ipairs(Q.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
        if not have.questsOld then M.fileKeys[#M.fileKeys + 1] = "questsOld" end
    end
end
K.settings()

K.ROWS = {
    { "questsReal", "Tasks: A-Life's task board made honest (real pay, nothing from nothing, real people)" },
    { "questRealPay", "Tasks: pay comes out of the giver's own pack (nothing to spare = they owe you)" },
    { "questPayScale", "Tasks: how much they try to pay (x)", { 0.5, 1, 1.5, 2 } },
    { "questNoSpawns", "Tasks: no zombies spawned for a task (only the real dead)" },
    { "questMap", "Tasks: your active task's place is marked on the world map" },
    { "questNoGifts", "Tasks: nothing appears in your pack when you reach a place" },
    { "questRealPlaces", "Tasks: a store, pharmacy or house is a real building (none near = no task, not a spot in the woods)" },
    { "questFakeOff", "Tasks: hide tasks with a made-up premise (lost crate, made-up missing person, nobody to meet)" },
    { "questClearHouse", "Tasks: A-Life's \"clear a house\" task" },
    { "questWants", "Tasks: people ask for real things they lack (smokes, a drink, books, glasses, music)" },
    { "questFindPerson", "Tasks: find someone of theirs and tell them the truth" },
    { "questDeliver", "Tasks: carry word to someone of a friendly group" },
    { "questDeliverMax", "Tasks: furthest a word is sent (tiles)", { 600, 1500, 3000 } },
    { "questMissingFar", "Tasks: a groupmate this far away counts as gone (tiles)", { 150, 250, 500 } },
    { "questOddsUncommon", "Tasks: chance a giver brings up an uncommon task on a day (0-100)", { 25, 50, 75, 100 } },
    { "questOddsRare", "Tasks: chance for a rare task (0-100)", { 10, 25, 50, 100 } },
    { "questOddsVeryRare", "Tasks: chance for a very rare task (0-100)", { 5, 10, 25, 100 } },
    { "questCompany", "Tasks: settlers want company on a run, or a quiet walk (they walk with you)" },
    { "questHandBack", "Tasks: their people ask for someone you hold back" },
    { "questChains", "Tasks: someone of theirs you found with another group: their people ask you to bring them home" },
    { "questPersuadeTrust", "Tasks: how much someone must like you to come home with you", { 10, 25, 40, 60 } },
    { "questFactionJobs", "Tasks: groups ask you to hurt groups they hate (a hit, their stash, drive them out)" },
    { "questWitnessCost", "Tasks: how much a group likes you less when they saw you rob them", { 0, 4, 8, 15 } },
    { "questsOld","Tasks: also the old 0.5 jobs from typed talk (no made-up reward either way)" },
}
function K.addRows()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(K.ROWS) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
        if type(ALifeTalkSettings) == "table" and tonumber(ALifeTalkSettings.PER_COL) then
            ALifeTalkSettings.PER_COL = math.max(ALifeTalkSettings.PER_COL, math.ceil(#M.settingRows / 3))
        end
    end
    if type(M.settingCatOf) == "table" then for _, r in ipairs(K.ROWS) do M.settingCatOf[r[1]] = "Groups, trade and the world" end end
end
K.addRows()

if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        print("[ALifeTalkQuests] ready v" .. K.VERSION .. ": settings on the Settings tab (" .. #K.ROWS .. " rows), old 0.5 job offers "
            .. (M.settings.questsOld == true and "on" or "off"))
    end)
end
return K
