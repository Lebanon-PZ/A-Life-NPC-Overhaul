-- A-Life NPC Overhaul 0.9.5 (Legacy): LAST SECRETS. The small hidden things (Knox theories, oddballs and donor cameos
-- already live in ALifeRadioKnox / ALifeStrangers / ALifeDonors):
--   * SEASONAL NIGHTS at camp, in the evening when you're home: Halloween (ghost stories at the fire), Thanksgiving
--     (the fourth Thursday of November: a feast from the real stores), New Year's Eve (a toast to another year; a feast
--     too). The feasts are ALifeSeasonsCamp's (nothing from nothing: not enough food, no feast).
--   * AGES AND BIRTHDAYS: everyone has an age (A-Life's when it has one, else picked once from who they are) and a
--     birthday. A year of game time makes them a year older. On a camp member's birthday they mention it.
--   * LETTERS ON THE DEAD: now and then (secretLetterChance %) one of a group's people carries a letter: where their
--     group keeps its stash (the real depot of their real place). Found on the body.
-- Settings: secrets, secretLetterChance.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Secrets") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeSecrets = ALifeSecrets or {}
local S = ALifeSecrets
local TAG = "[ALifeSecrets]"
S.VERSION = "0.9.5"
S.DEFAULTS = { secrets = true, secretLetterChance = 8 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = S.DEFAULTS[k] end; return v end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function letter(t) -- pre-1.0 MP: on a server the player handled, else everyone online (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, ALifeSide.cur, t, 210, 200, 240) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 210, 200, 240) end
end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(uid)
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or "Someone"
end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(S.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function S.on() return setting("secrets") ~= false end
function S.store() local s = fn(M, "bucket") and M.bucket("secrets") or (S._mem or {}); if not fn(M, "bucket") then S._mem = s end; s.done = type(s.done) == "table" and s.done or {}; s.ages = type(s.ages) == "table" and s.ages or {}; return s end
-- the calendar: game month (0-11), day of month (1-31), weekday, from the game's clock
function S.date()
    local mo, d, y = 6, 1, 1993
    pcall(function() local gt = getGameTime(); mo = gt:getMonth(); d = gt:getDay() + 1; y = gt:getYear() end)
    return mo, d, y
end
-- day of the week (0 = Sunday), Zeller-style, so Thanksgiving falls on the real fourth Thursday
function S.weekday(y, mo, d)
    local m = mo + 1
    if m < 3 then m = m + 12; y = y - 1 end
    local k, j = y % 100, math.floor(y / 100)
    local h = (d + math.floor(13 * (m + 1) / 5) + k + math.floor(k / 4) + math.floor(j / 4) + 5 * j) % 7
    return (h + 6) % 7
end
function S.occasion()
    local mo, d, y = S.date()
    if mo == 9 and d == 31 then return "halloween", y end
    if mo == 11 and d == 31 then return "newyear", y end
    if mo == 10 and d >= 22 and d <= 28 and S.weekday(y, mo, d) == 4 then return "thanksgiving", y end
    return nil, y
end
S.GHOST = { "Ever hear about the house on the hill out past the quarry?", "My grandma swore the dead walked. Guess she was right.", "There's a story about a man who never stopped knocking..." }
function S.evening(player)
    if not S.on() or player == nil then return nil end
    local L = ALifeSeasonsCamp
    local occ, y = S.occasion()
    if occ == nil then return nil end
    local key = occ .. ":" .. tostring(y)
    local s = S.store()
    if s.done[key] then return nil end
    local hod = math.floor(hours() % 24)
    if hod < 17 or hod > 21 then return nil end
    local b = fn(L, "base") and L.base(player) or nil
    if b == nil or not (fn(L, "home") and L.home(player, b)) then return nil end
    s.done[key] = hours()
    local people = fn(L, "atTable") and L.atTable(player, b) or {}
    if occ == "halloween" then
        local teller = people[1]
        if teller and fn(M, "say") then pcall(function() M.say(PA().Talk.shellFor(teller), player, S.GHOST[(hash(key) % #S.GHOST) + 1]) end) end
        for _, u in ipairs(people) do if fn(M, "keyMem") then pcall(M.keyMem, u, "occasion", "Ghost stories by the fire on Halloween") end end
        letter("Halloween. Someone starts telling ghost stories by the fire. Nobody laughs as much as they would have, once.")
        return "halloween"
    end
    if fn(L, "feast") then
        local title = occ == "thanksgiving" and "Thanksgiving" or "New Year's Eve"
        pcall(L.feast, player, b, people, key, title, occ == "thanksgiving" and "We gave thanks at Thanksgiving. For each other, mostly" or "We saw in another year. Still here")
    end
    return occ
end

-- ages and birthdays
function S.ageOf(uid)
    local s = S.store()
    local a = s.ages[tostring(uid)]
    if type(a) == "table" then return a.age, a end
    local r = rec(uid)
    local age = nil
    pcall(function() age = tonumber(r.memory.age) or tonumber(r.age) end)
    if age == nil then age = 18 + hash(tostring(uid) .. "#age") % 50 end
    a = { age = math.floor(age), bday = hash(tostring(uid) .. "#bday") % 365, setH = hours() }
    s.ages[tostring(uid)] = a
    return a.age, a
end
function S.birthdays(player)
    if not S.on() or player == nil or not fn(M, "cpPeople") then return 0 end
    local n = 0
    local mo, d = S.date()
    local doy = mo * 30 + d -- close enough: a birthday is a day in the year, the same one every year
    for _, uid in ipairs(M.cpPeople(player) or {}) do
        local age, a = S.ageOf(uid)
        local key = "bday:" .. tostring(uid) .. ":" .. math.floor(hours() / (24 * 365))
        if a.bday % 360 == doy % 360 and not S.store().done[key] then
            S.store().done[key] = hours()
            a.age = a.age + 1
            if fn(M, "keyMem") then pcall(M.keyMem, uid, "occasion", "Turned " .. a.age .. ". Didn't think I'd see it") end
            letter(first(uid) .. " mentions it's their birthday. " .. a.age .. ". \"Didn't think I'd make it this far.\"")
            n = n + 1
        end
    end
    return n
end

-- letters on the dead: where their group keeps its stash
function S.onDied(body, uid, killer, rollFn)
    if not S.on() or body == nil then return nil end
    local r = rec(uid)
    local b = (r and fn(M, "nbOfMember")) and M.nbOfMember(r) or nil
    if b == nil or b.status ~= "active" then return nil end
    local roll = 99
    if rollFn then roll = rollFn() else pcall(function() roll = ZombRand(100) end) end
    if roll >= (tonumber(setting("secretLetterChance")) or 8) then return nil end
    local h = fn(M, "nbHavenOf") and M.nbHavenOf(b) or nil
    local dp = type(h) == "table" and type(h.depot) == "table" and h.depot or h
    if type(dp) ~= "table" or tonumber(dp.x) == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = body:getX(), body:getY(), body:getZ() end)
    if x == nil or not fn(M, "dropNote") then return nil end
    local text = "If anything happens to me: what " .. tostring(b.name) .. " keep is near " .. math.floor(dp.x) .. ", " .. math.floor(dp.y) .. ". Don't let them starve. - " .. first(uid)
    local ok = pcall(M.dropNote, x, y, z or 0, "A folded letter", text, { kind = "secret", uid = tostring(uid) })
    return ok and text or nil
end
function S.install()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "secrets", "Secrets: seasonal nights at camp, ages and birthdays, letters on the dead" },
            { "secretLetterChance", "Secrets: chance one of a group's dead carries a letter about their stash (%)", { 0, 3, 8, 20 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Secrets and roadmap" end
        end
    end
    print(TAG .. " ready v" .. S.VERSION .. ": seasonal nights, birthdays, letters on the dead (" .. (S.on() and "on" or "off") .. ")")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(S.install) end) end
    if Events.EveryHours then Events.EveryHours.Add(function() local p = playerOf(); pcall(S.evening, p) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(S.birthdays, playerOf()) end) end
    if type(Events.ProjectALife_NpcDied) == "table" and fn(Events.ProjectALife_NpcDied, "Add") then
        Events.ProjectALife_NpcDied.Add(function(body, uid, killer) pcall(S.onDied, body, uid, killer) end)
    end
end
return S
