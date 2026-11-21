-- A-Life NPC Overhaul 0.9.5 (Legacy): THE REGION BOSS'S RULES (Joe, Nov 14). The group that won the last war
-- (ALifeRegion regionLeader) lays down the law for everyone near it, and enforces it with real fights.
--   * THE RULES, from who they are:
--       kingdom / coalition: NO RAIDING (no group attacks another) + NO CHAINS (nobody keeps people captive)
--       warlord (a raider creed): NOBODY RAIDS BUT US (they still raid; captives are their business)
--     Announced once by a messenger (letter), the news and the Chronicle.
--   * NPC GROUPS that raid another group (power plays' attacks: ALifePower.attack) break it. The boss comes for them
--     regionRulePunishDays later: a real off-screen assault with the boss's real strength (ALifePower.attack).
--   * YOU break it by killing someone from a group that wasn't hostile to you (self-defence doesn't count: A-Life's
--     Relations.hostileToPlayer), or by holding captives under NO CHAINS (ALifeBondsPower, checked weekly).
--     Strike 1: a warning, and the boss thinks less of you. Strike regionRuleStrikes within regionRuleForgetDays: the
--     boss's people come for you (A-Life's own raid: RaidDirector.warn with the boss's faction), and strikes reset.
--   * The rules end when the boss falls, or the order breaks (ALifeRegion.checkOrder "broken"), or free towns settle.
-- No numbers shown: "a warning", "they're coming". Settings: regionRules, regionRuleChains, regionRulePunishDays,
-- regionRuleStrikes, regionRuleForgetDays, regionRuleRep.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_RegionRules") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeRegionRules = ALifeRegionRules or {}
local RR = ALifeRegionRules
local TAG = "[ALifeRegionRules]"
RR.VERSION = ALifeSide.MOD_VERSION
RR.DEFAULTS = {
    regionRules = true,          -- the region boss lays down rules and enforces them
    regionRuleChains = true,     -- a kingdom / coalition boss forbids keeping captives
    regionRulePunishDays = 2,    -- days before the boss comes for a group that broke the rules
    regionRuleStrikes = 2,       -- your strikes before the boss comes for you
    regionRuleForgetDays = 30,   -- days before your strikes are forgotten
    regionRuleRep = 10,          -- how much less the boss thinks of you per strike
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = RR.DEFAULTS[k] end; return v end
local function num(k) return tonumber(setting(k)) or tonumber(RR.DEFAULTS[k]) or 0 end
local function letter(p, t) -- pre-1.0 MP: to that player (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, p, t, 220, 180, 150) end; return end
    if type(ALifeLetter) == "function" and p then pcall(ALifeLetter, p, t, 220, 180, 150) end
end
local function chron(k, what) if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = k, what = what }) end end
local function news(t) if fn(M, "newsNote") then pcall(M.newsNote, "politics", t) end end
local function byId(id) return id ~= nil and fn(M, "nbOf") and M.nbOf(id) or nil end
local function alive(b) return type(b) == "table" and b.status == "active" end
local function rec(uid) local r = nil; pcall(function() r = ProjectALife.ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(RR.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function RR.on() return setting("regionRules") ~= false and type(ALifeRegion) == "table" and (not fn(ALifeRegion, "on") or ALifeRegion.on()) end
function RR.store()
    local s = fn(M, "bucket") and M.bucket("regionRules") or (RR._mem or {})
    if not fn(M, "bucket") then RR._mem = s end
    s.punish = type(s.punish) == "table" and s.punish or {}
    s.strikes = type(s.strikes) == "table" and s.strikes or {}
    return s
end

-- the boss, while the rules hold (nil otherwise)
function RR.boss()
    if not RR.on() then return nil end
    local s = ALifeRegion.store()
    if type(s) ~= "table" or not s.lastWarDone or s.regionLeader == nil then return nil end
    if type(s.order) == "table" and s.order.kind == "free" then return nil end
    local b = byId(s.regionLeader)
    return alive(b) and b or nil
end
function RR.kind(boss) return (type(boss) == "table" and type(boss.dir) == "table" and boss.dir.creed == "raiders") and "warlord" or "kingdom" end
function RR.rules(boss)
    if boss == nil then return {} end
    if RR.kind(boss) == "warlord" then return { raid = "ours" } end
    return { raid = "none", chains = setting("regionRuleChains") ~= false }
end
function RR.rulesText(boss)
    local r = RR.rules(boss)
    if r.raid == "ours" then return "Nobody raids but them." end
    return "No group raids another." .. (r.chains and " Nobody keeps people in chains." or "")
end
-- once per boss: the messenger
function RR.announce(player)
    local boss = RR.boss()
    local s = RR.store()
    if boss == nil or s.told == boss.id then return false end
    s.told = boss.id
    letter(player, "A messenger from " .. tostring(boss.name) .. ". They run the region now, and these are the rules: " .. RR.rulesText(boss) .. " Break them and they come for you.")
    news(tostring(boss.name) .. " lay down the law: " .. RR.rulesText(boss))
    chron("leader", tostring(boss.name) .. " laid down the law for the region: " .. RR.rulesText(boss))
    return true
end

-- ---------------------------------------------------------------------------------------------- groups breaking it
function RR.onAttack(from, to)
    local boss = RR.boss()
    if boss == nil or type(from) ~= "table" or type(to) ~= "table" or from.id == boss.id then return nil end
    local s = RR.store()
    if s.punish[from.id] then return "queued" end
    s.punish[from.id] = { h = hours() + num("regionRulePunishDays") * 24, victim = to.id }
    news(tostring(from.name) .. " raided " .. tostring(to.name) .. ". " .. tostring(boss.name) .. " won't let that stand")
    return "broke"
end
function RR.punishDue(h)
    local boss = RR.boss()
    local s = RR.store()
    local n = 0
    for id, p in pairs(s.punish) do
        if boss == nil then s.punish[id] = nil
        elseif h >= (tonumber(p.h) or 0) then
            s.punish[id] = nil
            local b = byId(id)
            if alive(b) and fn(ALifePower, "attack") then
                RR.enforcing = true
                local ok, res = pcall(ALifePower.attack, boss, b, h)
                RR.enforcing = nil
                local held = ok and res == "repelled"
                news(tostring(boss.name) .. " came for " .. tostring(b.name) .. (held and ", and were driven off" or " for breaking the peace"))
                chron("war", tostring(boss.name) .. " punished " .. tostring(b.name) .. " for raiding" .. (held and ", and failed" or ""))
                n = n + 1
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------- you breaking it
local function key(player)
    local k = nil
    pcall(function() k = ALifeBonds.keyOf(player) end)
    if k == nil then pcall(function() k = ALifeLegacy.keyOf(player) end) end
    return tostring(k or "sp:0")
end
function RR.strike(player, why)
    local boss = RR.boss()
    if boss == nil then return nil end
    local s = RR.store()
    local k = key(player)
    local h = hours()
    local st = s.strikes[k]
    if type(st) ~= "table" or h - (tonumber(st.h) or -1e9) > num("regionRuleForgetDays") * 24 then st = { n = 0 } end
    st.n, st.h = st.n + 1, h
    s.strikes[k] = st
    if fn(M, "nbRep") then pcall(M.nbRep, boss, -num("regionRuleRep"), why and ("Broke the region's law: " .. why) or nil) end
    if st.n < num("regionRuleStrikes") then
        letter(player, tostring(boss.name) .. " heard you " .. tostring(why or "broke the rules") .. ". A warning: " .. RR.rulesText(boss) .. " Next time they come.")
        return "warned"
    end
    s.strikes[k] = nil
    local ok = false
    pcall(function() ok = ProjectALife.RaidDirector.warn(player, boss.faction, h) == true end)
    letter(player, tostring(boss.name) .. " are done warning you. They're coming.")
    chron("war", tostring(boss.name) .. " came for us for breaking the region's law")
    news(tostring(boss.name) .. " move against the newcomer for breaking the law")
    return ok and "raid" or "raidFailed"
end
-- you killed someone from a group: only if they weren't out for you
function RR.onDeath(body, uid, killer)
    local boss = RR.boss()
    if boss == nil then return nil end
    local player = killer
    local isP = false
    pcall(function() isP = instanceof(killer, "IsoPlayer") end)
    if not isP then return nil end
    local r = rec(uid)
    local hb = r and fn(M, "nbOfMember") and M.nbOfMember(r) or nil
    if not alive(hb) then return nil end
    local rules = RR.rules(boss)
    if rules.raid == "ours" and hb.id == boss.id then return nil end -- a warlord's own: that's a war, not a rule
    local hostile = false
    pcall(function() hostile = ProjectALife.Relations.hostileToPlayer(r, player) == true end)
    if hostile then return nil end
    return RR.strike(player, "killed one of " .. tostring(hb.name))
end
-- holding captives under NO CHAINS (weekly)
function RR.chains(player, h)
    local boss = RR.boss()
    if boss == nil or not RR.rules(boss).chains then return nil end
    local s = RR.store()
    if h - (tonumber(s.chainsH) or -1e9) < 7 * 24 then return nil end
    local n = 0
    pcall(function() n = tonumber(ALifeBondsPower.captivesOf(key(player))) or 0 end)
    if n <= 0 then return nil end
    s.chainsH = h
    return RR.strike(player, "keep people in chains")
end

-- ---------------------------------------------------------------------------------------------- hooks
function RR.hook()
    local n = 0
    local W = ALifePower
    if fn(W, "attack") and not rawget(W, "_rulesAttack") then
        local orig = W.attack
        W.attack = function(from, to, h, ...)
            if not RR.enforcing then pcall(RR.onAttack, from, to) end
            return orig(from, to, h, ...)
        end
        rawset(W, "_rulesAttack", true)
        n = n + 1
    end
    if fn(M, "nbOnDeath") and not M._rulesDeath then
        local origD = M.nbOnDeath
        M.nbOnDeath = function(body, uid, killer, ...)
            pcall(RR.onDeath, body, uid, killer)
            return origD(body, uid, killer, ...)
        end
        M._rulesDeath = true
        n = n + 1
    end
    -- the order breaks: the boss loses the region
    local R = ALifeRegion
    if fn(R, "checkOrder") and not rawget(R, "_rulesOrder") then
        local origO = R.checkOrder
        R.checkOrder = function(...)
            local res = origO(...)
            if res == "broken" then
                local s = R.store()
                local b = byId(s.regionLeader)
                s.regionLeader = nil
                RR.store().punish = {}
                if b then news(tostring(b.name) .. "'s law means nothing now") end
            end
            return res
        end
        rawset(R, "_rulesOrder", true)
        n = n + 1
    end
    return n
end
function RR.daily(player)
    if not RR.on() then return end
    local h = hours()
    RR.announce(player)
    RR.punishDue(h)
    RR.chains(player, h)
end
function RR.install()
    pcall(RR.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "regionRules", "Region boss: the group that won the last war lays down rules and enforces them" },
            { "regionRuleChains", "Region boss: a kingdom forbids keeping captives" },
            { "regionRulePunishDays", "Region boss: days before they come for a group that broke the rules", { 1, 2, 5 } },
            { "regionRuleStrikes", "Region boss: times you can break the rules before they come for you", { 1, 2, 3 } },
            { "regionRuleForgetDays", "Region boss: days before your broken rules are forgotten", { 14, 30, 60 } },
            { "regionRuleRep", "Region boss: how much less they think of you each time", { 5, 10, 20 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. RR.VERSION .. ": the region boss's rules (" .. (setting("regionRules") ~= false and "on" or "off") .. ")")
end
pcall(RR.hook)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(RR.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(RR.daily, playerOf()) end) end
end
return RR
