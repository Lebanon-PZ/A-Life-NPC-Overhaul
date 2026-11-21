-- A-Life NPC Overhaul 0.9.4 (Legacy): THE FORTRESS. When the airport stands empty (the Guard flew out or broke apart:
-- ALifeTalk_AirportEnd), the strongest group within fortressTiles wants it: walls, fences, a runway you can see
-- anyone coming across. A card tells you who, and that they'll move in after fortressDays.
--   * You get there first: make a base there (Jeem base within 200 tiles of the airport) before they come. Then it's
--     yours, and they hold it against you (their leader's grudge; war if they're the kind).
--   * You don't: they move in and dig in (their camp counts as fortified from then on: harder to break, nbStrength).
-- Written to the Chronicle and the news. Settings: fortress, fortressDays, fortressTiles.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Fortress") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeFortress = ALifeFortress or {}
local F = ALifeFortress
local TAG = "[ALifeFortress]"
F.VERSION = ALifeSide.MOD_VERSION
F.DEFAULTS = { fortress = true, fortressDays = 5, fortressTiles = 3000 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = F.DEFAULTS[k] end; return v end
local function letter(t) -- pre-1.0 MP: on a server the player handled, else everyone online (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, ALifeSide.cur, t, 220, 200, 150) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 220, 200, 150) end
end
local function chron(k, what) if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = k, what = what }) end end
local function news(t) if fn(M, "newsNote") then pcall(M.newsNote, "politics", t) end end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(F.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function F.state()
    local s = fn(M, "apStore") and M.apStore() or nil
    return type(s) == "table" and s or nil
end
-- where the airport is: the old base record (it ended, but its position stays)
function F.site(s)
    local b = s.baseId and fn(M, "nbOf") and M.nbOf(s.baseId) or nil
    if b and tonumber(b.x) then return b.x, b.y end
    local c = M.apCfg and M.apCfg.louisville
    if c then return (c.x1 + c.x2) / 2, (c.y1 + c.y2) / 2 end
    return nil
end
function F.claimant(x, y)
    local best, bestS = nil, 0
    local r = tonumber(setting("fortressTiles")) or 3000
    for _, b in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if tonumber(b.x) and (b.x - x) ^ 2 + (b.y - y) ^ 2 <= r * r then
            local ok, st = pcall(M.nbStrength, b)
            if ok and tonumber(st) and st > bestS then best, bestS = b, st end
        end
    end
    return best
end
-- a base of yours there (Jeem: a base area within 200 tiles of the airport)
function F.yours(x, y, player)
    local j = type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil
    local mine = false
    pcall(function()
        local b = j.BaseAreas.baseAt(x, y, 200)
        if b then
            local who = j.BaseAreas.who(player)
            mine = j.BaseAreas.canManage(b, who.key, who.faction, who.admin) == true
        end
    end)
    return mine
end
function F.daily(player)
    if setting("fortress") == false or player == nil then return nil end
    local s = F.state()
    if s == nil or s.emptyAt == nil or s.fortressDone then return nil end
    local x, y = F.site(s)
    if x == nil then return nil end
    if s.fortress == nil then
        local c = F.claimant(x, y)
        if c == nil then return nil end
        s.fortress = { by = c.id, name = c.name, h = hours() }
        letter(tostring(c.name) .. " want the empty airport. In " .. tostring(setting("fortressDays")) .. " days they'll move in, unless someone gets there first and makes it their own.")
        news(tostring(c.name) .. " are eyeing the empty airport")
        return "claimed"
    end
    local f = s.fortress
    if F.yours(x, y, player) then
        s.fortressDone = { who = "you", h = hours() }
        local c = fn(M, "nbOf") and M.nbOf(f.by) or nil
        if c and c.leader and fn(M, "addGrudge") then pcall(M.addGrudge, c.leader, 50, "took the airport out from under us", player) end
        if c and fn(M, "nbRep") then pcall(M.nbRep, c, -20, "took the airport before they could") end
        letter("The airport is yours. " .. tostring(f.name) .. " won't forget it.")
        chron("war", "We took the empty airport before " .. tostring(f.name) .. " could")
        return "yours"
    end
    if hours() - (tonumber(f.h) or 0) >= (tonumber(setting("fortressDays")) or 5) * 24 then
        local c = fn(M, "nbOf") and M.nbOf(f.by) or nil
        if c == nil or c.status ~= "active" then s.fortress = nil; return "gone" end
        c.stage = "fortified"
        c.fortress = true
        s.fortressDone = { who = c.id, h = hours() }
        if fn(M, "nbEvent") then pcall(M.nbEvent, c, "They moved into the airport and dug in", "politics") end
        news(tostring(c.name) .. " moved into the airport. They'll be hard to shift now")
        chron("war", tostring(c.name) .. " took the airport for their fortress")
        return "theirs"
    end
    return "waiting"
end
-- a group that dug into the airport stays fortified (Bases' nbSetStage recomputes the stage from boarding work)
function F.hook()
    if F.hooked or not fn(M, "nbSetStage") then return F.hooked == true end
    local orig = M.nbSetStage
    M.nbSetStage = function(b, ...)
        local r = orig(b, ...)
        if type(b) == "table" and b.fortress then b.stage = "fortified" end
        return r
    end
    F.hooked = true
    return true
end
function F.install()
    pcall(F.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "fortress", "Fortress: when the airport empties, the strongest group near it wants it (you can get there first)" },
            { "fortressDays", "Fortress: days before they move in", { 3, 5, 10 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. F.VERSION .. ": the empty airport as a fortress (" .. (setting("fortress") ~= false and "on" or "off") .. ")")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(F.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(F.daily, playerOf()) end) end
end
return F
