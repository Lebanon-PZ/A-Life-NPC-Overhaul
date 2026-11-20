-- A-Life NPC Overhaul 0.9.4 (Legacy): DEMOCRACY, client side (the votes: shared/ALifeDemocracy.lua).
--   * Words: "let's vote on short rations" / "vote on half rations" / "vote on full rations" / "vote on guards eating
--     first", "put the door to a vote" / "vote on opening the door" / "vote on closing the door", "vote on no killing
--     prisoners" (or the other camp rules), "call an election".
--   * A rule the camp voted in is switched on in the camp's rules (ALifeTalk_Camp), the same as setting it yourself.
--   * No elections: your camp follows you for love, need or fear (Bonds). "Call an election" says so.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Democracy") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeDemocracy"
local M = ALifeLLMTalk
local D = ALifeDemocracy
if type(M) ~= "table" or type(D) ~= "table" then return end
ALifeDemocracyUI = ALifeDemocracyUI or {}
local U = ALifeDemocracyUI
U.VERSION = "0.9.5"
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function isMP() return type(isClient) == "function" and isClient() end
local function letter(t) if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 200, 210, 230) end end
local function send(name, args) local p = playerOf(); if p and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, p, name, args or {}) end end
U.WORDS = {
    { "short rations", "rations", "short" }, { "half rations", "rations", "half" }, { "full rations", "rations", "full" },
    { "guards eat", "rations", "guards" }, { "guards eating", "rations", "guards" },
    { "opening the door", "door", "open" }, { "open the door", "door", "open" }, { "door open", "door", "open" },
    { "closing the door", "door", "closed" }, { "close the door", "door", "closed" }, { "door closed", "door", "closed" }, { "the door to a vote", "door", "open" },
    { "killing prisoners", "rule", "prisoners" }, { "aren't a threat", "rule", "harmless" }, { "arent a threat", "rule", "harmless" },
    { "no stealing", "rule", "steal" }, { "shares food", "rule", "share" }, { "sharing food", "rule", "share" },
}
function U.result(passed, law, value, t)
    if passed == nil then
        letter(({ off = "Votes are off (Settings).", nobase = "You need a base with people in it first.", nobody = "Nobody's here to vote.", law = "Vote on what?" })[tostring(t)] or "No vote.")
        return
    end
    local what = D.lawWords(law, value)
    local words = type(t) == "table" and t.words or "some of them"
    letter("The camp voted on " .. tostring(what) .. ": " .. (passed and "it passed" or "voted down") .. ". " .. tostring(words):gsub("^%l", string.upper) .. " were for it." .. (type(t) == "table" and t.loud and (" " .. t.loud .. ".") or ""))
    if passed and law == "rule" and fn(M, "cpData") then pcall(function() M.cpData().rules[value] = true end) end
end
function U.elected(who, t)
    if who == nil then
        local why = type(t) == "string" and t or "?"
        letter(({ bonds = "Nobody votes on who leads here. They follow you because they love you, need you, or fear you.", nobase = "You need a base first." })[why] or "No election.")
        return
    end
    if who == "player" then letter("The camp voted. They want you to keep leading. " .. tostring(type(t) == "table" and t.words or ""):gsub("^%l", string.upper) .. " stood with you.")
    else letter("The camp voted, and you lost. " .. tostring(type(t) == "table" and t.rival or "Someone else") .. " leads the camp now, their way, until the next vote.") end
end
function U.onWords(player, text)
    local low = string.lower(tostring(text or ""))
    if string.find(low, "call an election", 1, true) or string.find(low, "hold an election", 1, true) then
        U.elected(D.election(player))
        return true
    end
    if not (string.find(low, "vote on", 1, true) or string.find(low, "to a vote", 1, true) or string.find(low, "vote for", 1, true)) then return false end
    for _, w in ipairs(U.WORDS) do
        if string.find(low, w[1], 1, true) then
            if isMP() then send("demVote", { law = w[2], value = w[3] })
            else local passed, t = D.voteLaw(player, w[2], w[3]); U.result(passed, w[2], w[3], t) end
            return true
        end
    end
    return false
end
function U.daily(player) end -- no elections (love / need / fear)
if fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("demResult", function(a)
        if type(a) ~= "table" then return end
        if a.ev == "law" then U.result(a.passed, a.law, a.value, a.why or { words = a.words, loud = a.loud }) end
    end)
end
if type(M.playerWordHooks) == "table" and not U.wordsHooked then
    U.wordsHooked = true
    table.insert(M.playerWordHooks, function(player, text) pcall(U.onWords, player, text) end)
end
function U.install()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "democracyLaws", "Democracy: you can put laws to a vote (rations, the door, the camp's rules)" },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Your camp and base" end
        end
    end
    print("[ALifeDemocracyUI] ready v" .. U.VERSION .. ": vote words, no elections")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(U.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(U.daily, playerOf()) end) end
end
return U
