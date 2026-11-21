-- A-Life NPC Overhaul 0.9.5 (Legacy): ROMANCE, DEEPER. Builds on the romance you already earn (Roleplay: fond ->
-- sweet on you -> partner). All earned, no numbers shown.
--   * ANNIVERSARIES: a month, a hundred days, a year together: they mark it (a letter, a memory, they think more of you).
--   * MARRIAGE: "will you marry me?" to your partner. Long enough together (romanceMarryDays) and they love you enough:
--     yes, and the camp holds a wedding (a feast from the real stores, ALifeSeasonsCamp) and the Chronicle writes it.
--     Too soon: "not yet", no harm done.
--   * REUNIONS: apart for days (romanceApartDays) and then together again: they run to you.
--   * GRIEF AND LEGACY: lose your partner and the camp knows what it cost you (Chronicle). Die yourself, and a partner
--     living at your base is the one the camp turns to first (ALifeLegacy's heir; setting romancePartnerHeir).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_RomanceDeep") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeRomanceDeep = ALifeRomanceDeep or {}
local R = ALifeRomanceDeep
local TAG = "[ALifeRomanceDeep]"
R.VERSION = ALifeSide.MOD_VERSION
R.DEFAULTS = { romanceDeep = true, romanceMarryDays = 60, romanceMarryLove = 70, romanceApartDays = 3, romancePartnerHeir = true }
R.MARKS = { { d = 30, w = "a month" }, { d = 100, w = "a hundred days" }, { d = 365, w = "a year" } }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = R.DEFAULTS[k] end; return v end
local function letter(t) -- pre-1.0 MP: on a server the player handled, else everyone online (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, ALifeSide.cur, t, 240, 190, 200) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 240, 190, 200) end
end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(uid)
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or "them"
end
local function opinion(uid, player) local v = 0; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(rec(uid), player))) or 0 end); return v end
local function adjust(uid, player, d, why) pcall(function() PA().NpcOpinion.adjust(rec(uid), player, d, why) end) end
local function keyMem(uid, k, t) if fn(M, "keyMem") then pcall(M.keyMem, uid, k, t) end end
local function feel(uid, k, a, why) if fn(M, "feel") then pcall(M.feel, uid, k, a, why) end end
local function chron(k, who, uid, what) if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = k, who = who, uid = uid, what = what }) end end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(R.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function R.on() return setting("romanceDeep") ~= false and M.settings.romance ~= false end
-- your partners (romance stage 3)
function R.partners()
    local out = {}
    if not fn(M, "bucket") then return out end
    for uid, ro in pairs(M.bucket("romance")) do
        if type(ro) == "table" and (tonumber(ro.stage) or 0) >= 3 then out[#out + 1] = { uid = tostring(uid), ro = ro } end
    end
    return out
end
local function today() return math.floor(hours() / 24) end
local function shellPos(uid) local x, y = nil, nil; pcall(function() local sh = PA().Talk.shellFor(tostring(uid)); x, y = sh:getX(), sh:getY() end); return x, y end
local function nearYou(uid, player, r)
    local x, y = shellPos(uid)
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    return x ~= nil and px ~= nil and (x - px) ^ 2 + (y - py) ^ 2 <= r * r
end

-- anniversaries
function R.anniversaries(player)
    local n = 0
    for _, p in ipairs(R.partners()) do
        local ro = p.ro
        if ro.since ~= nil then
            ro.marks = type(ro.marks) == "table" and ro.marks or {}
            local days = today() - tonumber(ro.since)
            for _, mk in ipairs(R.MARKS) do
                if days >= mk.d and not ro.marks[tostring(mk.d)] then
                    ro.marks[tostring(mk.d)] = today()
                    keyMem(p.uid, "kindness", mk.w .. " together with the newcomer")
                    adjust(p.uid, player, 3, mk.w .. " together")
                    letter(first(p.uid) .. " remembered: " .. mk.w .. " since the two of you got together.")
                    n = n + 1
                end
            end
        end
    end
    return n
end
-- marriage
function R.propose(player, uid)
    if not R.on() then return false, "off" end
    local ro = fn(M, "romanceOf") and M.romanceOf(uid) or nil
    if ro == nil or (tonumber(ro.stage) or 0) < 3 then return false, "notpartner" end
    if ro.married then return false, "married" end
    local days = today() - (tonumber(ro.since) or today())
    if days < (tonumber(setting("romanceMarryDays")) or 60) then return false, "soon" end
    if opinion(uid, player) < (tonumber(setting("romanceMarryLove")) or 70) then return false, "love" end
    ro.married = today()
    keyMem(uid, "kindness", "Married the newcomer")
    feel(uid, "joy", 0.8, "got married")
    chron("story", first(uid), uid, "married the boss")
    -- a wedding: a feast from the real stores
    local L = ALifeSeasonsCamp
    if fn(L, "feast") and fn(L, "base") and fn(L, "atTable") then
        local b = L.base(player)
        if b then pcall(L.feast, player, b, L.atTable(player, b), "wedding:" .. tostring(uid), "a wedding", "We held a wedding. A real one") end
    end
    return true, "yes"
end
R.SAY = { yes = "\"Yes. God, yes.\"", soon = "\"Ask me again. Not yet. But ask me again.\"", love = "\"I... I'm not there yet. I'm sorry.\"",
    married = "\"We already are, you idiot.\"", notpartner = "\"What? We're not even together.\"" }
-- reunions: apart for days, then together again
function R.reunions(player)
    local n = 0
    local apart = (tonumber(setting("romanceApartDays")) or 3) * 24
    for _, p in ipairs(R.partners()) do
        local ro = p.ro
        if nearYou(p.uid, player, 10) then
            if ro.seenH and hours() - ro.seenH >= apart then
                feel(p.uid, "joy", 0.6, "you came back")
                adjust(p.uid, player, 2, "you came back to them")
                keyMem(p.uid, "kindness", "The newcomer came back after days away. Ran to them")
                letter(first(p.uid) .. " sees you and runs to you.")
                n = n + 1
            end
            ro.seenH = hours()
        end
    end
    return n
end
-- grief: your partner died
function R.onDied(body, uid, killer)
    if not R.on() or not fn(M, "bucket") then return false end
    local ro = M.bucket("romance")[tostring(uid)]
    if type(ro) ~= "table" or (tonumber(ro.stage) or 0) < 3 or ro.lost then return false end
    ro.lost = today()
    chron("death", first(uid), tostring(uid), (ro.married and "the boss's wife or husband" or "the boss's partner") .. ", gone")
    letter("You lost " .. first(uid) .. ".")
    return true
end
-- legacy: a partner at your base is the one the camp turns to first
function R.hookLegacy()
    local G = ALifeLegacy
    if not fn(G, "heir") or rawget(G, "_romanceHeir") then return false end
    local orig = G.heir
    G.heir = function(key, base, people, ...)
        if setting("romancePartnerHeir") ~= false and R.on() then
            for _, p in ipairs(R.partners()) do
                if not p.ro.lost then
                    for _, r in ipairs(people or {}) do if tostring(r.uid) == p.uid and r.lifecycle ~= "dead" then return r, "partner" end end
                end
            end
        end
        return orig(key, base, people, ...)
    end
    rawset(G, "_romanceHeir", true)
    return true
end
function R.onWords(player, text)
    if not R.on() then return false end
    local low = string.lower(tostring(text or ""))
    if string.find(low, "marry me", 1, true) then
        local best = nil
        for _, p in ipairs(R.partners()) do if nearYou(p.uid, player, 4) then best = p.uid end end
        if best == nil then return false end
        local ok, why = R.propose(player, best)
        letter(first(best) .. ": " .. (R.SAY[tostring(why)] or "\"...\""))
        return true
    end
    return false
end
if type(M.playerWordHooks) == "table" and not R.wordsHooked then
    R.wordsHooked = true
    table.insert(M.playerWordHooks, function(player, text) pcall(R.onWords, player, text) end)
end
function R.install()
    pcall(R.hookLegacy)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "romanceDeep", "Romance: anniversaries, marriage (\"will you marry me?\"), reunions" },
            { "romanceMarryDays", "Romance: days together before marriage is possible", { 30, 60, 120 } },
            { "romancePartnerHeir", "Romance: when you die, a partner at your base takes over first" },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Relationships and feelings" end
        end
    end
    print(TAG .. " ready v" .. R.VERSION .. ": anniversaries, marriage, reunions, partner heir")
end
pcall(R.hookLegacy)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(R.install) end) end
    if Events.EveryHours then Events.EveryHours.Add(function() local p = playerOf(); if p and R.on() then pcall(R.anniversaries, p); pcall(R.reunions, p) end end) end
    if type(Events.ProjectALife_NpcDied) == "table" and fn(Events.ProjectALife_NpcDied, "Add") then
        Events.ProjectALife_NpcDied.Add(function(body, uid, killer) pcall(R.onDied, body, uid, killer) end)
    end
end
return R
