-- A-Life NPC Overhaul 0.9.1 (Legacy): NPC VS NPC STAND-OFFS. When two people are about to fight each other (a feud,
-- a nemesis, bad blood: every NPC-on-NPC fight this mod starts goes through ALifeTalkPatch.npcFeud) and you're close
-- enough to see it, it's held at the moment it starts: a card, the game pauses, you choose.
--   * Step in: you try to talk them down. How well depends on what both think of you (A-Life NpcOpinion) and on
--     whether they're your own people (you run the camp). It works: no fight, the two cool off a little, they remember
--     it. It doesn't: the fight starts anyway.
--   * Side with one: the one you back likes you more, the other less. Facing you too, the other usually backs down
--     (npcStandoffBackDown %); a predator doesn't, and the fight starts.
--   * Walk away (the default if you don't answer): the fight starts, as it would have.
-- Too far away (npcStandoffTiles) = you never knew; the fight starts on its own. The small version of the wars to come.
-- Written to the Chronicle. Settings: npcStandoff, npcStandoffTiles, npcStandoffBackDown, npcStandoffCoolH.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_NpcStandoff") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeNpcStandoff = ALifeNpcStandoff or {}
local S = ALifeNpcStandoff
local TAG = "[ALifeNpcStandoff]"
S.VERSION = ALifeSide.MOD_VERSION
S.DEFAULTS = {
    npcStandoff = true,       -- fights between people near you are held: step in, pick a side, or walk away
    npcStandoffTiles = 25,    -- how close you must be to see it start (tiles)
    npcStandoffBackDown = 60, -- % the other one backs down when you side against them
    npcStandoffCoolH = 24,    -- game hours a talked-down pair stays calm (and no second card for the same pair)
}
S.stats = { held = 0, talked = 0, failed = 0, sided = 0, backedDown = 0, walked = 0 }
S.holds = S.holds or {}   -- [pairKey] = { a, b, why, hrs, mutual }
S.cool = S.cool or {}     -- [pairKey] = { h, peace = bool }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = S.DEFAULTS[k] end; return v end -- explicit nil check: false stays false
local function first(uid)
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or "someone"
end
local function shellOf(uid) local s = nil; pcall(function() s = PA().Talk.shellFor(tostring(uid)) end); return s end
local function opinion(uid, player) local v = 0; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(rec(uid), player))) or 0 end); return v end
local function adjust(uid, player, d, why) pcall(function() PA().NpcOpinion.adjust(rec(uid), player, d, why) end) end
local function keyMem(uid, kind, text) if fn(M, "keyMem") then pcall(M.keyMem, uid, kind, text) end end
local function temper(uid) local t = nil; pcall(function() t = PA().Speech.contextFor(rec(uid), nil).temperament end); return t end
local function key(a, b) a, b = tostring(a), tostring(b); if a < b then return a .. "|" .. b end return b .. "|" .. a end
S.key = key
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(S.DEFAULTS) do
            if M.settings[k] == nil then M.settings[k] = v end
            if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end
local function chron(what, aUid)
    if type(ALifeChronicleUI) == "table" and fn(ALifeChronicleUI, "note") then pcall(ALifeChronicleUI.note, "standoff", nil, aUid, what) end
end
-- one of yours (lives at your base)
local function ours(uid)
    if fn(M, "settlerOf") then local ok, s = pcall(M.settlerOf, uid); if ok and s then return true end end
    return false
end

-- can you see it? both loaded and close
function S.inSight(a, b, player)
    if player == nil then return false end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    if px == nil then return false end
    local r = tonumber(setting("npcStandoffTiles")) or 25
    for _, u in ipairs({ a, b }) do
        local sh = shellOf(u)
        local x, y = nil, nil
        pcall(function() x, y = sh:getX(), sh:getY() end)
        if x == nil or (x - px) ^ 2 + (y - py) ^ 2 > r * r then return false end
    end
    return true
end
-- the chance you talk them down: what both think of you, your own people listen more
function S.calmChance(a, b, player)
    local oa, ob = opinion(a, player), opinion(b, player)
    local c = 0.25 + (math.min(oa, ob) + math.max(oa, ob) * 0.5) / 200
    if ours(a) and ours(b) then c = c + 0.3 elseif ours(a) or ours(b) then c = c + 0.1 end
    if c < 0.05 then c = 0.05 elseif c > 0.9 then c = 0.9 end
    return c
end
local function roll100(rollFn)
    if rollFn then return rollFn() end
    local r = 99
    pcall(function() r = ZombRand(100) end)
    return r
end

-- the fight starts, as it would have
function S.fight(h)
    S.cool[key(h.a, h.b)] = { h = hours(), peace = false }
    if S.orig then pcall(S.orig, h.a, h.b, h.why, h.hrs, h.mutual) end
end
-- the choices (rollFn for tests)
function S.stepIn(h, player, rollFn)
    local k = key(h.a, h.b)
    S.holds[k] = nil
    local c = S.calmChance(h.a, h.b, player)
    if roll100(rollFn) < c * 100 then
        S.stats.talked = S.stats.talked + 1
        S.cool[k] = { h = hours(), peace = true }
        if fn(M, "pairBump") then pcall(M.pairBump, h.a, h.b, 10, "the newcomer talked them down") end
        for _, u in ipairs({ h.a, h.b }) do
            adjust(u, player, 3, "talked them down before it came to blows")
            keyMem(u, "kindness", "The newcomer stepped between me and " .. first(u == h.a and h.b or h.a) .. " before it got bloody")
        end
        chron(first(h.a) .. " and " .. first(h.b) .. " nearly came to blows; it was talked down", h.a)
        return "calm"
    end
    S.stats.failed = S.stats.failed + 1
    for _, u in ipairs({ h.a, h.b }) do adjust(u, player, -2, "got in the way of their fight") end
    chron(first(h.a) .. " and " .. first(h.b) .. " fought; nobody could stop it", h.a)
    S.fight(h)
    return "fight"
end
function S.side(h, player, withUid, rollFn)
    local k = key(h.a, h.b)
    S.holds[k] = nil
    S.stats.sided = S.stats.sided + 1
    local other = tostring(withUid) == tostring(h.a) and h.b or h.a
    adjust(withUid, player, 6, "you took their side against " .. first(other))
    adjust(other, player, -8, "you took " .. first(withUid) .. "'s side against them")
    keyMem(withUid, "kindness", "The newcomer stood with me against " .. first(other))
    keyMem(other, "grudge", "The newcomer sided with " .. first(withUid) .. " against me")
    if fn(M, "pairBump") then pcall(M.pairBump, h.a, h.b, -5, "the newcomer took sides") end
    local hard = temper(other) == "predator"
    if not hard and roll100(rollFn) < (tonumber(setting("npcStandoffBackDown")) or 60) then
        S.stats.backedDown = S.stats.backedDown + 1
        S.cool[k] = { h = hours(), peace = true }
        chron(first(other) .. " backed down from " .. first(withUid) .. " when the boss took a side", withUid)
        return "backdown"
    end
    chron(first(withUid) .. " and " .. first(other) .. " fought; the boss took " .. first(withUid) .. "'s side", withUid)
    S.fight(h)
    return "fight"
end
function S.walk(h)
    S.holds[key(h.a, h.b)] = nil
    S.stats.walked = S.stats.walked + 1
    S.fight(h)
    return "fight"
end

-- the held moment: a card (primary: popup + pause; default walk away)
function S.hold(a, b, why, hrs, mutual, player)
    local k = key(a, b)
    local h = { a = tostring(a), b = tostring(b), why = why, hrs = hrs, mutual = mutual }
    S.holds[k] = h
    S.stats.held = S.stats.held + 1
    local na, nb = first(a), first(b)
    local card = { id = "npcstandoff:" .. k, title = na .. " and " .. nb .. " are about to fight", default = 4,
        text = na .. " and " .. nb .. " squared up" .. (why and why ~= "" and (" (" .. tostring(why) .. ")") or "") .. ". It's going to get bloody. <LINE> <LINE> Step in, pick a side, or walk away?",
        choices = {
            { label = "Step in", fn = function() S.stepIn(h, playerOf()) end },
            { label = "Side with " .. na, fn = function() S.side(h, playerOf(), h.a) end },
            { label = "Side with " .. nb, fn = function() S.side(h, playerOf(), h.b) end },
            { label = "Walk away", fn = function() S.walk(h) end },
        } }
    if ALifeSide.canOutCard() then
        local ok = pcall(ALifeSide.outCard, playerOf(), card)
        if ok then return true end
    end
    S.walk(h)
    return false
end

-- the wrapped start of every NPC-on-NPC fight
function S.onFeud(a, b, why, hrs, mutual)
    local player = playerOf()
    if ALifeSide.mpServer() then -- pre-1.0 MP: the player who'd see it (nearest to the first of them)
        local sh = nil
        pcall(function() sh = PA().Talk.shellFor(tostring(a)) end)
        player = (sh and ALifeSide.nearestTo(sh)) or player
    end
    if setting("npcStandoff") == false or a == nil or b == nil then return nil end
    local ra, rb = rec(a), rec(b)
    if not (ra and rb and ra.lifecycle == "active" and rb.lifecycle == "active") then return nil end
    local k = key(a, b)
    if S.holds[k] then return true end -- waiting on you
    local c = S.cool[k]
    if c and hours() - (tonumber(c.h) or 0) < (tonumber(setting("npcStandoffCoolH")) or 24) then
        if c.peace then return true end -- talked down: it stays down for a while
        return nil -- already fighting / you walked away: let it run
    end
    if not S.inSight(a, b, player) then return nil end
    S.hold(a, b, why, hrs, mutual, player)
    return true
end
function S.hook()
    local P = ALifeTalkPatch
    if type(P) ~= "table" or not fn(P, "npcFeud") then return false end
    if rawget(P, "_npcStandoffWrapped") then return true end
    S.orig = P.npcFeud
    P.npcFeud = function(a, b, why, hrs, mutual, ...)
        local ok, held = pcall(S.onFeud, a, b, why, hrs, mutual)
        if ok and held then return true end
        return S.orig(a, b, why, hrs, mutual, ...)
    end
    rawset(P, "_npcStandoffWrapped", true)
    S.hooked = true
    return true
end
function S.install()
    pcall(S.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "npcStandoff", "Stand-offs: a fight between people near you is held so you can step in, pick a side or walk away" },
            { "npcStandoffTiles", "Stand-offs: how close you must be to see a fight start (tiles)", { 15, 25, 40 } },
            { "npcStandoffBackDown", "Stand-offs: chance the other one backs down when you side against them (%)", { 30, 60, 90 } },
            { "npcStandoffCoolH", "Stand-offs: game hours a talked-down pair stays calm", { 12, 24, 72 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Injury, death and prisoners" end
        end
    end
    print(TAG .. " ready v" .. S.VERSION .. ": NPC fights near you held (" .. (S.hooked and "hooked" or "NOT hooked: no ALifeTalkPatch.npcFeud") .. ")")
end
pcall(S.hook)
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(S.install) end) end
return S
