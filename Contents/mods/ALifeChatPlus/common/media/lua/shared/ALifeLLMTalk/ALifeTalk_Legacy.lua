-- A-Life NPC Overhaul 0.9.2 (Legacy): THE CAMP OUTLIVES YOU, client side (the decisions: shared/ALifeLegacy.lua).
--   * You die (vanilla OnPlayerDeath): what each of your people thought of you is kept, the server picks the heir and
--     your title. Your name goes on the camp's memorial (CampGrief's dead: remembered on the anniversaries).
--   * Your old self: the zombie that gets up where you fell is tagged like a turned friend (Turned's TalkWasUid),
--     so it can walk home one day (Every Story Ends' familiar face) and the camp knows who it was.
--   * Your next character (OnCreatePlayer): a popup says whose camp it is now and how they remember you. As a stranger
--     (legacyStranger), what they thought of the old you doesn't carry over: their opinion of the new you starts at
--     zero (A-Life keys opinions by player, and a new character in single player has the same key).
--   * Words: "I want the camp back" / "give me the camp back" -> legacyAsk; "I'm <old name>'s brother / sister /
--     son / daughter / kin / cousin" -> legacyKin.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Legacy") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeLegacy"
local M = ALifeLLMTalk
local G = ALifeLegacy
if type(M) ~= "table" or type(G) ~= "table" then return end
ALifeLegacyUI = ALifeLegacyUI or {}
local U = ALifeLegacyUI
local TAG = "[ALifeLegacyUI]"
U.VERSION = ALifeSide.MOD_VERSION
U.stats = { deaths = 0, tagged = 0, zeroed = 0, asks = 0, claims = 0 }
U.pending = U.pending or nil
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function toast(t) if fn(M, "momToast") then pcall(M.momToast, t) end end
local function send(player, name, args) if player and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, player, name, args or {}) end end
local function nameOf(p)
    local n = nil
    pcall(function() local d = p:getDescriptor(); n = d:getForename() end)
    return n or "The boss"
end

-- you died
function U.onDeath(player)
    if not G.on() or player == nil then return false end
    local key = G.keyOf(player)
    local base = G.baseOf(key)
    if base == nil then return false end
    local old = {}
    for _, r in ipairs(G.residents(base)) do
        local v = nil
        pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end)
        if v then old[tostring(r.uid)] = math.floor(v) end
    end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = player:getX(), player:getY(), player:getZ() end)
    local name = nameOf(player)
    local female = nil
    pcall(function() female = player:isFemale() == true end)
    U.stats.deaths = U.stats.deaths + 1
    send(player, "legacyDied", { name = name, x = x and math.floor(x) or nil, y = y and math.floor(y) or nil, z = z and math.floor(z) or 0, old = old })
    -- the memorial: your name with the camp's dead
    if fn(M, "grData") then
        pcall(function()
            local g = M.grData()
            local day = math.floor(G.hours() / 24)
            table.insert(g.dead, { uid = "player:" .. tostring(key), name = name, day = day, h = G.hours(), how = "the boss" })
        end)
    end
    -- the zombie that gets up there: yours
    if x then U.pending = { uid = "player:" .. tostring(key), name = name, x = x, y = y, z = z or 0, female = female, untilH = G.hours() + 6 } end
    return true
end
-- tag your old self when it stands up (reanimation takes a while: watch for up to 6 game hours)
function U.tagTick()
    local e = U.pending
    if e == nil then return false end
    if G.hours() > e.untilH then U.pending = nil; return false end
    local cell = nil
    pcall(function() cell = getCell() end)
    if cell == nil then return false end
    local list, n = nil, 0
    pcall(function() list = cell:getZombieList() end)
    pcall(function() n = list:size() end)
    for i = 0, math.min(n, 800) - 1 do
        local zb = list:get(i)
        local zx, zy, zz = nil, nil, nil
        pcall(function() zx, zy, zz = zb:getX(), zb:getY(), zb:getZ() end)
        if zx and math.floor(zz or 0) == math.floor(e.z or 0) and (zx - e.x) ^ 2 + (zy - e.y) ^ 2 <= 2.2 * 2.2 then
            local md = nil
            pcall(function() md = zb:getModData() end)
            local sexOk = true
            if e.female ~= nil then pcall(function() sexOk = (zb:isFemale() == true) == (e.female == true) end) end
            if type(md) == "table" and md.TalkWasUid == nil and sexOk then
                md.TalkWasUid, md.TalkWasName = e.uid, e.name
                if fn(M, "bucket") then pcall(function() M.bucket("turnedZ")[e.uid] = { n = e.name, x = math.floor(e.x), y = math.floor(e.y), h = G.hours() } end) end
                U.pending = nil
                U.stats.tagged = U.stats.tagged + 1
                log("tagged your old self: " .. tostring(e.name))
                return true
            end
        end
    end
    return false
end

-- your next character
function U.onCreate(player)
    if not G.on() or player == nil then return false end
    local key = G.keyOf(player)
    local row = G.of(key)
    if row == nil or row.back ~= nil then return false end
    local done = fn(M, "bucket") and M.bucket("legacySeen") or {}
    local mark = tostring(key) .. "@" .. tostring(row.h)
    if done[mark] then return false end
    done[mark] = true
    -- a stranger: what they thought of the old you stays with the dead
    if G.setting("legacyStranger") ~= false then
        local base = G.baseOf(key)
        if base == nil then
            local j = type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil
            pcall(function() base = j.BaseAreas.base(row.baseId) end)
        end
        for _, r in ipairs(G.residents(base)) do
            local v = nil
            pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end)
            if v and v ~= 0 then
                pcall(function() PA().NpcOpinion.adjust(r, player, -v, "a stranger") end)
                U.stats.zeroed = U.stats.zeroed + 1
            end
        end
    end
    local text = row.name .. " is dead. " .. (row.heirName and (row.heirName .. " runs " .. tostring(row.baseName or "the camp") .. " now.") or "Nobody runs the camp now.")
        .. " They remember " .. row.name .. " as " .. tostring(G.TITLE_WORDS[row.title] or "nobody much") .. "."
    if G.setting("legacyStranger") ~= false then
        text = text .. " <LINE> <LINE> To them you're a stranger. Earn their trust and ask for the camp back" .. (G.setting("legacyKinClaim") ~= false and (", or tell them you're " .. row.name .. "'s kin (they may not believe you).") or ".")
    end
    if fn(M, "momCard") then
        pcall(M.momCard, { id = "legacy:" .. mark, title = "After " .. row.name, default = 1, text = text, choices = { { label = "Go on", fn = function() end } } })
    else
        toast(text)
    end
    return true
end

-- words
U.KIN = { "brother", "sister", "son", "daughter", "kin", "cousin", "niece", "nephew", "wife", "husband" }
function U.onWords(player, text)
    local low = string.lower(tostring(text or ""))
    local key = G.keyOf(player)
    local row = G.of(key)
    if row == nil or row.back ~= nil then return false end
    if string.find(low, "camp back", 1, true) or string.find(low, "hand it back", 1, true) or string.find(low, "hand over the camp", 1, true) then
        U.stats.asks = U.stats.asks + 1
        send(player, "legacyAsk", {})
        return true
    end
    local nm = string.lower(tostring(row.name or ""))
    if nm ~= "" and string.find(low, nm, 1, true) then
        for _, w in ipairs(U.KIN) do
            if string.find(low, nm .. "'s " .. w, 1, true) or string.find(low, nm .. "s " .. w, 1, true) or string.find(low, w .. " of " .. nm, 1, true) then
                U.stats.claims = U.stats.claims + 1
                send(player, "legacyKin", { as = w })
                return true
            end
        end
    end
    return false
end
U.SAY = {
    earned = "\"It was always yours, I think. Take it.\" The camp is yours again.",
    noheir = "Nobody's left to argue. The camp is yours.",
    kin = "\"You've got their eyes.\" They believe you. The camp is yours.",
    notyet = "\"I don't know you well enough for that. Not yet.\"",
    never = "\"This camp has moved on.\"",
    caught = "\"Don't lie to me. Not about them.\" They don't believe a word, and they won't forget it.",
    tried = "\"We've had this talk.\"",
}
function U.onState(a)
    if type(a) ~= "table" then return end
    U.row = a.row
    if a.ev == "ask" or a.ev == "kin" then local t = U.SAY[tostring(a.why)]; if t then toast(t) end end
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("legacyState", function(a) pcall(U.onState, a) end) end
if type(M.playerWordHooks) == "table" and not U.wordsHooked then
    U.wordsHooked = true
    table.insert(M.playerWordHooks, function(player, text) pcall(U.onWords, player, text) end)
end
function U.install()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "legacy", "Legacy: when you die the camp goes on (an heir, your title, the Chronicle)" },
            { "legacyHeir", "Legacy: who takes over (lt = your lieutenant first, vote = the camp picks, dissolve = nobody)", { "lt", "vote", "dissolve" } },
            { "legacyStranger", "Legacy: your next character is a stranger to the camp (off: it stays yours)" },
            { "legacyHandBack", "Legacy: getting it back (earn their trust / they decide when you ask / never)", { "earn", "ask", "never" } },
            { "legacyTrust", "Legacy: how much the heir must like the new you to hand it back", { 20, 40, 60 } },
            { "legacyKinClaim", "Legacy: you can claim to be your old character's kin" },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Your camp and base" end
        end
    end
    print(TAG .. " ready v" .. U.VERSION .. ": death, memorial, your old self, the stranger, words")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(U.install) end) end
    if Events.OnPlayerDeath then Events.OnPlayerDeath.Add(function(p) pcall(U.onDeath, p) end) end
    if Events.OnCreatePlayer then Events.OnCreatePlayer.Add(function(i, p) pcall(U.onCreate, p) end) end
    if Events.EveryOneMinute then Events.EveryOneMinute.Add(function() if U.pending then pcall(U.tagTick) end end) end
end
return U
