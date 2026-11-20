-- A-Life NPC Overhaul pre-1.0: RAIDS DRAWN BY WHAT THEY KNOW (docs/PLAN-RIM.md #9). Not RimWorld's "wealth calls raids":
-- raiders only come for your stores once somebody out there KNOWS what you have.
--   * Your camp's worth: once a day while you're near, what your drop points and the stockpile hold (ALifeWorth, the
--     same scale trades use). Loaded containers only; nothing is guessed while you're away.
--   * Who knows: strangers who were inside your base (any A-Life person who isn't one of yours, seen there on the hour,
--     traders and visitors too), and anyone who walked out of your camp (M.baseLeave). Knowledge fades (worthFadeDays).
--   * A-Life's raid roll (RaidDirector.allowed, read in A-Life 1.5.1 server/World/ALifeRaidDirector.lua: tick() rolls
--     random()*100 against chancePerCheckPct) is scaled: nobody knows = x worthHiddenMul; somebody knows = x 1 up to
--     x worthMaxMul for a rich camp (worth / worthRich). Forced raids (start / tipOff pass 0) are untouched.
-- A vague letter when word gets out. No numbers.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeKnownWorth") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeKnownWorth = ALifeKnownWorth or {}
local W = ALifeKnownWorth
local TAG = "[ALifeKnownWorth]"
W.VERSION = "pre-1.0"
W.DEFAULTS = {
    worthRaid = true,       -- A-Life raids come more when people know what you have, less when nobody does
    worthHiddenMul = 50,    -- % raid chance while nobody out there knows your camp
    worthMaxMul = 300,      -- % raid chance for a rich camp people know about
    worthRich = 1500,       -- what your stores are worth when they count as rich (trade scale: beans ~2, axe ~10)
    worthFadeDays = 14,     -- days until what they saw is old news
    worthScanMax = 3000,    -- most items counted
}
K.reg(W.DEFAULTS, {
    { "worthRaid", "Raids: come more when people know what you have, less when nobody does" },
    { "worthHiddenMul", "Raids: chance while nobody knows your camp (%)", { 25, 50, 75, 100 } },
    { "worthMaxMul", "Raids: chance for a rich camp people know about (%)", { 100, 150, 200, 300, 500 } },
    { "worthRich", "Raids: what your stores are worth when rich (beans ~2, axe ~10)", { 500, 1000, 1500, 3000, 6000 } },
    { "worthFadeDays", "Raids: days until what strangers saw is old news", { 3, 7, 14, 30, 60 } },
}, "Groups, trade and the world")
W.stats = { scans = 0, seen = 0, left = 0, rolls = 0, scaled = 0 }
local function set(k) return K.set(W.DEFAULTS, k) end
local function num(k) return K.num(W.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function W.on() return set("worthRaid") ~= false end
function W.store() local s = K.bucket("rimKnownWorth"); s.known = type(s.known) == "table" and s.known or {}; return s end

-- worth of what your camp holds (nil while you're away: containers not loaded)
function W.count(player)
    local Wo = ALifeWorth
    if type(Wo) ~= "table" or not K.fn(Wo, "item") then return nil end
    local list = nil
    if type(ALifeKeepStocked) == "table" and K.fn(ALifeKeepStocked, "containers") then list = ALifeKeepStocked.containers(player) end
    if list == nil then return nil end
    local sum, n = 0, 0
    for _, c in ipairs(list) do
        pcall(function()
            local items = c:getItems()
            for i = 0, items:size() - 1 do
                if n >= num("worthScanMax") then return end
                n = n + 1
                local v = Wo.item(items:get(i))
                sum = sum + (tonumber(v) or 0)
            end
        end)
    end
    return math.floor(sum + 0.5)
end
function W.richness() local s = W.store(); return K.clamp((tonumber(s.worth) or 0) / math.max(1, num("worthRich")), 0, 1) end
function W.knownNow()
    local s = W.store()
    local fade = num("worthFadeDays") * 24
    local h = K.hours()
    local n = 0
    for k, e in pairs(s.known) do
        if type(e) ~= "table" or h - (tonumber(e.h) or -1e9) > fade then s.known[k] = nil else n = n + 1 end
    end
    return n
end
-- the multiplier on A-Life's raid roll (1 = as A-Life has it)
function W.mul()
    if not W.on() then return 1 end
    if W.knownNow() == 0 then return math.max(0.01, num("worthHiddenMul") / 100) end
    local top = math.max(1, num("worthMaxMul") / 100)
    return 1 + (top - 1) * W.richness()
end
function W.learn(who, how, quiet)
    local s = W.store()
    local k = tostring(who or "*")
    local old = s.known[k]
    s.known[k] = { h = K.hours(), how = how }
    if old == nil and not quiet then
        if how == "left" then K.letter("Whoever walked out knows what you've got here. Word travels.", 220, 180, 130)
        elseif W.richness() >= 0.3 then K.letter("Strangers got a good look at your stores.", 220, 180, 130) end
    end
    return old == nil
end
-- strangers inside the base right now (A-Life people who aren't yours)
function W.scanSeen(player)
    local b = K.base(player)
    local Reg = K.PA().ActorRegistry
    if b == nil or not K.fn(Reg, "each") then return 0 end
    local mine = {}
    for _, uid in ipairs(K.people(player)) do mine[uid] = true end
    local M = K.M()
    local n = 0
    pcall(function()
        Reg.each(function(r)
            local uid = tostring(r.uid)
            if not mine[uid] and r.lifecycle ~= "dead" then
                local inParty = false
                if M and K.fn(M, "partyIsMember") then local ok, y = pcall(M.partyIsMember, uid, player); inParty = ok and y == true end
                local sh = (not inParty) and K.shell(uid) or nil
                local x, y = K.pos(sh)
                if x and K.inBase(b, x, y) then
                    n = n + 1
                    W.learn(r.factionId and ("f:" .. tostring(r.factionId)) or ("p:" .. uid), "seen")
                end
            end
            return false
        end)
    end)
    W.stats.seen = W.stats.seen + n
    return n
end
function W.hourly(player, h)
    if not W.on() or player == nil then return 0 end
    local s = W.store()
    if type(ALifeKeepStocked) == "table" and K.fn(ALifeKeepStocked, "near") and ALifeKeepStocked.near(player) then
        local day = K.day()
        if s.worthDay ~= day then
            local v = W.count(player)
            if v ~= nil then s.worth, s.worthDay = v, day; W.stats.scans = W.stats.scans + 1 end
        end
        W.scanSeen(player)
    end
    return 1
end
function W.hook()
    local n = 0
    local M = K.M()
    if M and K.wrap(M, "baseLeave", "worth:baseLeave", function(orig)
        return function(uid, player, why, ...)
            local r = orig(uid, player, why, ...)
            if W.on() then W.stats.left = W.stats.left + 1; W.learn("left:" .. tostring(uid), "left") end
            return r
        end
    end) then n = n + 1 end
    local R = K.PA().RaidDirector
    if K.wrap(R, "allowed", "worth:raidAllowed", function(orig)
        return function(enabled, day, hours, lastHour, rolledPct, ...)
            local r = tonumber(rolledPct)
            if W.on() and r ~= nil and r > 0 then
                W.stats.rolls = W.stats.rolls + 1
                local m = W.mul()
                if m ~= 1 then W.stats.scaled = W.stats.scaled + 1; rolledPct = r / m end
            end
            return orig(enabled, day, hours, lastHour, rolledPct, ...)
        end
    end) then n = n + 1 end
    return n
end
function W.install()
    local n = W.hook()
    if not W._hourly then K.hourly(TAG, W.hourly); W._hourly = true end
    return n
end
pcall(W.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(W.install)
        log("ready v" .. W.VERSION .. ": raids by known worth " .. (W.on() and "on" or "off") .. " (" .. tostring(ok and n or 0) .. "/2 hooks: walk-outs, A-Life raid roll)")
    end)
end
return W
