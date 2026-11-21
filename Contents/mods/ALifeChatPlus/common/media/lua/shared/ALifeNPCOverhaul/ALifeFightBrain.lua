-- A-Life NPC Overhaul 0.8.10a: FIGHT BRAIN. One brain per fighting group reads the fight and picks a mood:
--   push / steady / careful / fall back / break / give up.
-- It never moves anyone itself. A-Life 1.5.1 already has the tactics (PushPlan, FlankPlan, StanceBound, Suppression,
-- Cover, Withdraw, Panic, Radioman, InjuryRescue...). The brain turns A-Life's own modules on/off per group through
-- ProjectALife.ModuleRegistry.veto (chained the way JuggernautDoctrine and MeleeSwitch chain it).
--   - Non-player groups: the brain runs the show (veto).
--   - Your party: advice only (a companion calls out what the other side is doing, or that you can't hold). Never a veto.
-- Inputs, all real: heads both sides (hurt, downed, lost since the fight began), leader lost, A-Life Bravery broken
-- share, dry guns (no rounds, nothing to reload), zombies near, night, home turf, class (military/police tight,
-- criminals flaky), people who want you alive (they don't push to kill you once you're hurt).
-- Give up: only to an armed player in sight within reach, A-Life's own TalkOrders.surrenderCrew (then A-Life's
-- surrender + our captives). Never at home. Against NPCs a give-up is a break (NPC vs NPC stand-offs are 0.9).
-- Server-authoritative (SP or server). Every number is a setting (DEFAULTS).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeFightBrain = ALifeFightBrain or {}
local B = ALifeFightBrain
local TAG = "[ALifeFightBrain]"
B.VERSION = ALifeSide.MOD_VERSION
B.metrics = B.metrics or { ticks = 0, groups = 0, changes = 0, vetoes = 0, gaveUp = 0, giveUpNo = 0, barks = 0, advice = 0 }
B.groups = B.groups or {}      -- groupId -> state { mood, sinceMs, atMs, startCount, leaderUid, leaderLost, advisory, ... }
B.parties = B.parties or {}    -- playerKey -> { atMs, low = bool }
B.partyOrders = B.partyOrders or {} -- uid -> { untilMs }: your companion told to suppress (ALifePartyTactics)
B.preThink = B.preThink or {}       -- 0.8.11: functions(groupId, st, f, contact, now) run before each think (ALifeAmbush)

B.DEFAULTS = {
    fightBrain = true,          -- the whole 0.8.10 fight brain (off = A-Life's own fighting exactly as it is)
    fightPreset = 2,            -- 1 plain A-Life (brain off), 2 smart, 3 brutal (hold longer, push sooner, give up late)
    brainTickMs = 2000,         -- ms between thinks per group
    brainReach = 60,            -- tiles: only fights this close to a player get a brain
    brainFightMs = 30000,       -- ms since the last contact before the fight counts as over
    brainMinGroup = 2,          -- a group needs this many people for a brain (one person = A-Life alone)
    brainGroupReach = 40,       -- tiles: members this close to the fight count
    brainEnemyReach = 25,       -- tiles: your side within this of who they're fighting counts
    moodMinMs = 8000,           -- ms a mood holds before it may change
    moodBand = 0.06,            -- score past a line before the mood crosses it (no flip-flop)
    moodPush = 0.66,            -- score lines (0.5 = an even fight)
    moodSteady = 0.46,
    moodCareful = 0.36,
    moodFallBack = 0.24,
    moodBreak = 0.14,
    leaderLostCost = 0.12,      -- score lost when their leader goes down
    lossCost = 0.15,            -- score lost at "everyone we started with is gone"
    brokenCost = 0.15,          -- score lost at "all of us are shaken" (A-Life Bravery broken)
    dryCost = 0.10,             -- score lost at "all our guns are dry"
    zombieCost = 0.02,          -- score lost per zombie near the fight
    zombieCostMax = 0.15,       -- ... at most
    nightCost = 0.04,           -- score lost at night (fighting blind = careful)
    homeBonus = 0.10,           -- score gained on home turf (and no break / give up at home)
    trainedBonus = 0.08,        -- military / police
    flakyCost = 0.05,           -- criminals
    giveUp = true,              -- enemies can give up to you
    giveUpChance = 50,          -- % a beaten group gives up instead of breaking
    giveUpReach = 12,           -- tiles: you must be this close, armed, in sight
    wantsAliveSoft = true,      -- people who'd want you alive stop pushing to kill once you're hurt
    wantsAliveHealth = 50,      -- ... your health under this
    brainBarks = true,          -- they shout their mood ("Fall back!") - real info for you
    barkGapMs = 6000,           -- ms between mood shouts per group
    partyAdvice = true,         -- your people call out what the other side does / when you can't hold
    partyAdviceGapMs = 10000,
    -- 0.8.10b
    brainPersona = true,        -- who they are counts: brave / steady / calm hold, fearful / jumpy fold (single player:
    nerveCost = 0.08,           -- ... personality lives on the client) - score moved at "everyone brave" / "everyone scared"
    enemyHunt = true,                -- after a fight they were winning, they go after your noise for a while, then give up
    -- 0.8.10c
    enemyLure = true,                -- a group that breaks may yell to pull the dead onto you while they slip away
    enemyLureChance = 35,            -- ... % (only with the dead near)
    enemyLureNoise = 40,             -- ... how far the yell carries (tiles)
    enemyLureZeds = 3,               -- ... at least this many dead within enemyLureNoise
    feint = false,              -- criminals may fake giving up and turn on you when you walk in close (off: dirty)
    feintChance = 30,           -- ... %
    feintTiles = 3,             -- ... you this close
    feintMs = 6000,             -- ... after at least this long with their hands up (ms)
    carFlee = true,             -- a group that breaks runs for its car and drives off (A-Life's own car leaving)
    -- 0.8.10.1
    dryCharge = true,           -- guns dry and you close: they go in with blades / fists (A-Life's all-in charge) when pushing
    dryChargeTiles = 8,         -- ... this close (tiles)
    bleedCost = 0.06,           -- score lost at "all of us bleeding"
    nightSeeBonus = 0.06,       -- at night: your light on, theirs off = they see you (and the other way round)
    brainCover = true,          -- cover counts: in the open they fold sooner (A-Life's own cover finder)
    openCost = 0.06,            -- ... score lost at "none of us has cover"
    coverSample = 3,            -- ... people checked per think (it's raycasts)
    coverCacheMs = 6000,        -- ... how long a check holds (ms)
    homeReach = 30,             -- tiles from where they live (A-Life home / leash) that count as home turf
    enemyHuntMin = 60,          -- hunt: game minutes they keep after you (game clock)
    enemyHuntRestMin = 120,     -- hunt: game minutes they leave noises alone after
    huntMarkMs = 20000,         -- hunt: how often they re-mark where they last saw you (ms)
}
B.FILE_KEYS = {}
for k in pairs(B.DEFAULTS) do B.FILE_KEYS[#B.FILE_KEYS + 1] = k end
table.sort(B.FILE_KEYS)

-- mood levels, low to high
B.LEVEL = { giveup = 0, ["break"] = 1, fallback = 2, careful = 3, steady = 4, push = 5 }
B.NAME = { [0] = "giveup", [1] = "break", [2] = "fallback", [3] = "careful", [4] = "steady", [5] = "push" }
B.LINE_KEYS = { "moodBreak", "moodFallBack", "moodCareful", "moodSteady", "moodPush" } -- line i = bottom of level i

-- A-Life module ids each mood forces on (true) / off (false). Not listed = A-Life decides.
-- Never primary conducts (stealth, sniper, medic, ambusher, leader): forcing those skips A-Life's one-conduct rule.
B.VETO = {
    push = { squadPush = true, flanking = true, withdraw = false, careful = false },
    steady = {},
    careful = { squadPush = false, supportFire = true, cover = true, careful = true, radioman = true, healing = true },
    fallback = { squadPush = false, flanking = false, withdraw = true, supportFire = true, cover = true, radioman = true, healing = true },
    ["break"] = { squadPush = false, flanking = false, supportFire = false, gunner = false, withdraw = true, flee = true, panic = true, healing = false },
    giveup = { squadPush = false, flanking = false, supportFire = false, gunner = false, suppression = false },
    hunt = { investigate = true },   -- after the fight: walk to your noise (A-Life "investigate")
    rest = { investigate = false },  -- hunt over: leave noises alone for a while
    -- 0.8.11 fake run (ALifeFakeRun): pull back like a run, but in order (no panic), ready to turn
    fakerun = { squadPush = false, flanking = false, supportFire = false, withdraw = true, flee = true, panic = false, cover = false },
    -- 0.8.11 ambush (ALifeAmbush): A-Life's own "ambusher" conduct (cover, hold fire, spring at 7 tiles), quiet otherwise
    ambush = { ambusher = true, squadPush = false, flanking = false, supportFire = false, suppression = false, withdraw = false, radioman = false },
    -- preset 1 "dumb": A-Life's group tactics off for everyone (no push plans, flanks, cover fire, fall backs, radio)
    dumb = { squadPush = false, flanking = false, supportFire = false, withdraw = false, radioman = false, careful = false },
}
-- (healing on in careful / fall back = A-Life's InjuryRescue drags the wounded to cover; off when they run = left behind)

B.BARKS = {
    push = { "Push them!", "Move up, move up!", "They're done, go!" },
    careful = { "Stay in cover!", "Keep your heads down!", "Hold here, watch the angles!" },
    fallback = { "Fall back!", "Pull back, cover each other!", "Back, back!" },
    ["break"] = { "Run!", "Forget it, get out of here!", "I'm out!" },
    giveup = { "Okay, okay! We give up!", "Don't shoot! We're done!" },
}
B.ADVICE = {
    push = { "Here they come!", "They're pushing us!" },
    fallback = { "They're pulling back!", "They're backing off!" },
    ["break"] = { "They're running!", "They broke!" },
    giveup = { "They're giving up, hold fire!" },
    low = { "There's too many, we should pull back!", "We can't hold this!" },
}

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end
local function pct(p) return roll(100) < num(p, 0) end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
local function xyz(o) return num(call(o, "getX"), nil), num(call(o, "getY"), nil), num(call(o, "getZ"), 0) end
local function d2(ax, ay, bx, by) return (ax - bx) * (ax - bx) + (ay - by) * (ay - by) end
local function clamp(v, a, b) if v < a then return a end if v > b then return b end return v end

function B.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = B.DEFAULTS[key] end
    return v
end
function B.n(key) return num(B.setting(key), num(B.DEFAULTS[key], 0)) end
function B.preset() return math.floor(B.n("fightPreset")) end
function B.on() return B.setting("fightBrain") ~= false and B.preset() >= 2 end
B.adapters = B.adapters or {} -- tests: nowMs, hour, players
function B.nowMs()
    if fn(B.adapters, "nowMs") then return B.adapters.nowMs() end
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return 0
end
-- whole game minutes (getWorldAgeHours drifts as a float; rounded)
function B.worldMin()
    if fn(B.adapters, "worldMin") then return num(B.adapters.worldMin(), 0) end
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return math.floor(num(h, 0) * 60 + 0.5)
end
function B.authoritative()
    if ALifeSide.client() then return false end
    return true
end

-- ---------------------------------------------------------------------------------------------------- mood math
-- score -> level, with hysteresis: to leave the current level the score must pass the line by `band`.
function B.levelFor(score, current, band)
    score = num(score, 0.5); band = num(band, 0)
    local level = 0
    for i = 1, #B.LINE_KEYS do
        local line = B.n(B.LINE_KEYS[i])
        if current ~= nil then
            if current >= i then line = line - band else line = line + band end
        end
        if score >= line then level = i end
    end
    return level
end

-- preset 3 (brutal): braver and pushier
function B.presetShift()
    if B.preset() >= 3 then return 0.08 end
    return 0
end

-- f = facts table (see B.facts). Returns score 0..1 and the reasons that moved it.
function B.score(f)
    local why = {}
    local us = num(f.alive, 0) - num(f.downed, 0) - 0.5 * num(f.hurt, 0)
    local them = num(f.enemies, 0) - 0.5 * num(f.enemiesHurt, 0)
    if us < 0 then us = 0 end
    if them < 0 then them = 0 end
    local s = 0.5
    if us + them > 0 then s = us / (us + them) end
    local start = num(f.startCount, 0)
    if start > 0 then
        local lost = clamp((start - num(f.alive, 0)) / start, 0, 1)
        if lost > 0 then s = s - lost * B.n("lossCost"); why[#why + 1] = "lost " .. tostring(start - num(f.alive, 0)) end
    end
    if f.leaderLost then s = s - B.n("leaderLostCost"); why[#why + 1] = "leader down" end
    if num(f.alive, 0) > 0 then
        local broken = clamp(num(f.broken, 0) / num(f.alive, 1), 0, 1)
        if broken > 0 then s = s - broken * B.n("brokenCost"); why[#why + 1] = tostring(f.broken) .. " shaken" end
        local dry = clamp(num(f.dry, 0) / num(f.alive, 1), 0, 1)
        if dry > 0 then s = s - dry * B.n("dryCost"); why[#why + 1] = tostring(f.dry) .. " dry" end
    end
    if num(f.zombies, 0) > 0 then
        s = s - math.min(B.n("zombieCostMax"), num(f.zombies, 0) * B.n("zombieCost")); why[#why + 1] = tostring(f.zombies) .. " zeds"
    end
    if f.night then
        s = s - B.n("nightCost"); why[#why + 1] = "night"
        -- who sees who: your light on and theirs off = they see you, you don't see them (and the other way round)
        local theirs = num(f.lit, 0) > 0
        if f.targetLit and not theirs then s = s + B.n("nightSeeBonus"); why[#why + 1] = "you're lit up"
        elseif theirs and f.targetLit == false then s = s - B.n("nightSeeBonus"); why[#why + 1] = "they're lit up" end
    end
    if num(f.bleeding, 0) > 0 and num(f.alive, 0) > 0 then
        s = s - clamp(num(f.bleeding, 0) / num(f.alive, 1), 0, 1) * B.n("bleedCost"); why[#why + 1] = tostring(f.bleeding) .. " bleeding"
    end
    if num(f.coverChecked, 0) > 0 then
        local open = 1 - num(f.covered, 0) / num(f.coverChecked, 1)
        if open > 0 then s = s - open * B.n("openCost"); why[#why + 1] = "no cover" end
    end
    if f.home then s = s + B.n("homeBonus"); why[#why + 1] = "home" end
    if f.class == "military" or f.class == "police" then s = s + B.n("trainedBonus")
    elseif f.class == "criminal" then s = s - B.n("flakyCost") end
    if f.nerve ~= nil and f.nerve ~= 0 then
        s = s + clamp(f.nerve, -1, 1) * B.n("nerveCost")
        why[#why + 1] = f.nerve > 0 and "steady crew" or "scared crew"
    end
    s = s + B.presetShift()
    return clamp(s, 0, 1), why
end

-- level after the rules that cap it (home: never break/give up; want-you-alive: no push once you're hurt)
function B.capLevel(level, f)
    if f.home and level < B.LEVEL.fallback then level = B.LEVEL.fallback end
    if f.wantsAlive and f.targetHurt and B.setting("wantsAliveSoft") ~= false and level > B.LEVEL.steady then level = B.LEVEL.steady end
    if level == B.LEVEL.giveup and not f.vsPlayer then level = B.LEVEL["break"] end
    return level
end

-- one think for one group: facts in, new mood out (state changed in place). Returns changed, oldMood.
function B.think(state, f, now)
    local score, why = B.score(f)
    local cur = state.mood and B.LEVEL[state.mood] or nil
    local level = B.levelFor(score, cur, B.n("moodBand"))
    level = B.capLevel(level, f)
    -- a beaten group rolls once per fight: give up, else break
    if level == B.LEVEL.giveup then
        if state.giveUpRolled == nil then
            state.giveUpRolled = (B.setting("giveUp") ~= false) and pct(num(B.setting("giveUpChance"), 50))
        end
        if not state.giveUpRolled then level = B.LEVEL["break"] end
    end
    state.score, state.why = score, why
    local want = B.NAME[level]
    if state.mood == nil then state.mood, state.sinceMs = want, now; return true, nil end
    if want == state.mood then return false, state.mood end
    if state.mood == "giveup" then return false, state.mood end -- giving up is final for the fight
    if now - num(state.sinceMs, 0) < B.n("moodMinMs") then return false, state.mood end
    local old = state.mood
    state.mood, state.sinceMs = want, now
    return true, old
end

-- ---------------------------------------------------------------------------------------------------- A-Life reads
local function recordOf(uid)
    local pa = PA()
    local reg = pa and pa.ActorRegistry or nil
    if reg == nil or uid == nil then return nil end
    local f = reg.peek or reg.read
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, tostring(uid))
    if ok then return r end
    return nil
end
B.recordOf = recordOf
local function shellOf(uid)
    local pa = PA()
    local wd = pa and pa.Watchdog or nil
    local b = wd and type(wd.bindings) == "table" and wd.bindings[uid] or nil
    return type(b) == "table" and b.shell or nil
end
local function uidOfShell(shell)
    local pa = PA()
    if pa and fn(pa.Suppression, "uidOf") then local ok, u = pcall(pa.Suppression.uidOf, shell); if ok then return u end end
    local data = call(shell, "getModData")
    return type(data) == "table" and data.ProjectALifeUID or nil
end
function B.groupIdOf(record)
    local m = type(record) == "table" and record.memory or nil
    if type(m) ~= "table" then return nil end
    if type(m.groupId) == "string" then return m.groupId end
    if m.outpostId ~= nil then return "outpost:" .. tostring(m.outpostId) end
    return nil
end
local function downed(record)
    local m = type(record) == "table" and record.memory or nil
    local inj = type(m) == "table" and m.injury or nil
    return type(inj) == "table" and inj.s == "down"
end
local function healthOf(record, shell)
    local pa = PA()
    if pa and fn(pa.Survival, "healthRatio") then
        local ok, r = pcall(pa.Survival.healthRatio, record, shell)
        if ok and tonumber(r) then return tonumber(r) end
    end
    return 1
end
local function isDry(shell)
    local pa = PA()
    local combat = pa and pa.Combat or nil
    local w = call(shell, "getPrimaryHandItem")
    if w == nil or combat == nil or not fn(combat, "isRanged") or not fn(combat, "currentAmmo") then return false end
    local okR, ranged = pcall(combat.isRanged, w)
    if not okR or ranged ~= true then return false end
    local okA, cur = pcall(combat.currentAmmo, w)
    if not okA or num(cur, 1) > 0 then return false end
    local mags = pa.MagazineState
    if fn(mags, "canReload") then
        local okC, can = pcall(mags.canReload, shell, w)
        if okC and can == true then return false end
    end
    return true
end
local function brokenNow(record, shell, now)
    local pa = PA()
    if pa and fn(pa.Bravery, "broken") then
        local ok, b = pcall(pa.Bravery.broken, record, shell, now)
        return ok and b == true
    end
    return false
end
local function classOf(record)
    local pa = PA()
    if pa and fn(pa.ModuleFear, "memberClass") then
        local ok, c = pcall(pa.ModuleFear.memberClass, record)
        if ok and type(c) == "string" then return c end
    end
    return nil
end
-- nerve -1..1 from our Persona traits + Psyche fear. Lives on the client (ALifeLLMTalk): single player only; nil in MP.
B.NERVE = { brave = 1, disciplined = 0.5, calm = 0.5, fearful = -1, paranoid = -0.5, gloomy = -0.3 }
function B.nerveOf(uid)
    local m = ALifeLLMTalk
    if B.setting("brainPersona") == false or type(m) ~= "table" or not fn(m, "traitChart") then return nil end
    local n = 0
    local ok, chart = pcall(m.traitChart, uid, 5)
    if ok and type(chart) == "table" then
        for _, c in ipairs(chart) do n = n + (B.NERVE[c.key] or 0) * num(c.pct, 0) / 100 end
    end
    if fn(m, "emoRow") then
        local okE, row = pcall(m.emoRow, uid)
        local e = okE and type(row) == "table" and type(row.e) == "table" and row.e or {}
        n = n - math.min(1, num(e.fear, 0) + 0.5 * num(e.dread, 0) + 0.3 * num(e.anxiety, 0))
    end
    return clamp(n, -1, 1)
end
local function zombiesNear(shell, tiles)
    local pa = PA()
    if pa and fn(pa.CombatVoice, "zombiesNear") then
        local ok, n = pcall(pa.CombatVoice.zombiesNear, shell, tiles or 15)
        if ok then return num(n, 0) end
    end
    return 0
end
local function isNight()
    local h = 12
    if fn(B.adapters, "hour") then h = num(B.adapters.hour(), 12)
    else pcall(function() h = getGameTime():getHour() end) end
    return h >= 21 or h < 6
end
local function isCompanion(record)
    local m = type(record) == "table" and record.memory or nil
    return type(m) == "table" and type(m.companion) == "table"
end
local function isPlayer(o)
    if o == nil then return false end
    if type(instanceof) == "function" then local ok, r = pcall(instanceof, o, "IsoPlayer"); return ok and r == true end
    return type(o) == "table" and o.isPlayerStub == true
end
local function playerHealth(player)
    local bd = call(player, "getBodyDamage")
    return num(call(bd, "getOverallBodyHealth"), 100)
end

function B.players()
    if fn(B.adapters, "players") then return B.adapters.players() end
    local out = {}
    pcall(function()
        if ALifeSide.server() and type(getOnlinePlayers) == "function" then
            local l = getOnlinePlayers()
            for i = 0, l:size() - 1 do out[#out + 1] = l:get(i) end
        else
            local p = getSpecificPlayer(0)
            if p ~= nil then out[1] = p end
        end
    end)
    return out
end

-- living members of a group near (x, y): list of { uid, actor, shell }
function B.members(groupId, x, y, radius)
    local pa = PA()
    local T = pa and pa.SquadTactics or nil
    if not fn(T, "livingMembers") then return {} end
    local ok, _, list = pcall(T.livingMembers, groupId, nil, x, y, radius)
    if ok and type(list) == "table" then return list end
    return {}
end

-- your side as they see it: players and companions near who they're fighting
function B.playerSide(tx, ty, reach)
    local count, hurt = 0, 0
    local r2 = reach * reach
    for _, p in ipairs(B.players()) do
        local px, py = xyz(p)
        if px ~= nil and d2(px, py, tx, ty) <= r2 and call(p, "isDead") ~= true then
            count = count + 1
            if playerHealth(p) < 50 then hurt = hurt + 1 end
        end
    end
    local pa = PA()
    local reg = pa and pa.ActorRegistry or nil
    if fn(reg, "each") then
        pcall(reg.each, function(rec)
            if type(rec) == "table" and rec.lifecycle == "active" and isCompanion(rec) and not downed(rec) then
                local sh = shellOf(rec.uid)
                local x, y = xyz(sh)
                if x ~= nil and d2(x, y, tx, ty) <= r2 then
                    count = count + 1
                    if healthOf(rec, sh) < 0.5 then hurt = hurt + 1 end
                end
            end
            return false
        end)
    end
    return count, hurt
end

function B.leaderUidOf(groupId)
    local pa = PA()
    local L = pa and pa.ModuleLeader or nil
    local g = L and type(L.groups) == "table" and L.groups[groupId] or nil
    return type(g) == "table" and g.leaderUid or nil
end

-- 0.8.10.1 reads ----------------------------------------------------------------------------------------------
-- bleeding: A-Life Blood.bleeding(shell modData) (bleed-out timer or bleeding wounds)
function B.bleeding(shell)
    local pa = PA()
    local data = call(shell, "getModData")
    if type(data) ~= "table" or not (pa and fn(pa.Blood, "bleeding")) then return false end
    local ok, b = pcall(pa.Blood.bleeding, data)
    return ok and b == true
end
-- an NPC's light is on: A-Life NightLightLoop sets ProjectALifeFlashlight on the shell
function B.lit(shell)
    local data = call(shell, "getModData")
    return type(data) == "table" and data.ProjectALifeFlashlight == true
end
-- your light is on: a light item in your hands that's switched on (vanilla canEmitLight / isActivated, as
-- ISLightSourceRadialMenu)
function B.playerLit(player)
    for _, getter in ipairs({ "getPrimaryHandItem", "getSecondaryHandItem" }) do
        local item = call(player, getter)
        if item ~= nil and call(item, "canEmitLight") == true and call(item, "isActivated") == true then return true end
    end
    return false
end
-- in cover: A-Life ModuleCover.find(shell, target) finds a spot close by (cached per person, coverCacheMs)
B.coverCache = B.coverCache or {}
function B.inCover(m, target, now)
    local pa = PA()
    if B.setting("brainCover") == false or target == nil or not (pa and fn(pa.ModuleCover, "find")) then return nil end
    local uid = tostring(m.uid or (type(m.actor) == "table" and m.actor.uid) or "")
    local row = B.coverCache[uid]
    if row ~= nil and now < row.untilMs then return row.v end
    local ok, spot = pcall(pa.ModuleCover.find, m.shell, target, {})
    local v = ok and spot ~= nil or false
    B.coverCache[uid] = { v = v, untilMs = now + B.n("coverCacheMs") }
    return v
end
-- at home: within homeReach of their A-Life home / leash (where they live), not only A-Life outposts
function B.atHome(mem, shell)
    if type(mem) ~= "table" then return false end
    local x, y = xyz(shell)
    if x == nil then return false end
    for _, k in ipairs({ "home", "leash" }) do
        local p = mem[k]
        if type(p) == "table" and tonumber(p.x) ~= nil and tonumber(p.y) ~= nil
                and d2(x, y, tonumber(p.x), tonumber(p.y)) <= B.n("homeReach") ^ 2 then return true end
    end
    return false
end

-- read everything the brain scores for one group's fight. contact = SquadTactics.contacts[groupId]
function B.facts(groupId, contact, state, now)
    local f = { alive = 0, downed = 0, hurt = 0, broken = 0, dry = 0, zombies = 0, enemies = 0, enemiesHurt = 0 }
    local tx, ty
    if type(contact.position) == "table" then tx, ty = num(contact.position.x, nil), num(contact.position.y, nil) end
    local ax, ay = xyz(contact.target)
    if ax ~= nil then tx, ty = ax, ay end
    local rx, ry = xyz(shellOf(contact.reportedBy))
    if rx == nil then rx, ry = tx, ty end
    if rx == nil then return nil end
    local list = B.members(groupId, rx, ry, B.n("brainGroupReach"))
    f.list = list
    f.vsPlayerHint = contact.kind == "player" or isPlayer(contact.target)
    local firstShell = nil
    local nerveSum, nerveN = 0, 0
    for _, m in ipairs(list) do
        f.alive = f.alive + 1
        local rec = m.actor
        if downed(rec) then f.downed = f.downed + 1
        else
            local nv = B.nerveOf(m.uid or (type(rec) == "table" and rec.uid))
            if nv ~= nil then nerveSum, nerveN = nerveSum + nv, nerveN + 1 end
            if healthOf(rec, m.shell) < 0.5 then f.hurt = f.hurt + 1 end
            if B.bleeding(m.shell) then f.bleeding = (f.bleeding or 0) + 1 end
            if brokenNow(rec, m.shell, now) then f.broken = f.broken + 1 end
            if isDry(m.shell) then
                m.dry = true
                -- dry with you close: they go in with what's in their hands (A-Life's own charge), not a reason to fold
                local mx, my = xyz(m.shell)
                if f.vsPlayerHint and mx ~= nil and tx ~= nil and d2(mx, my, tx, ty) <= B.n("dryChargeTiles") ^ 2 and B.setting("dryCharge") ~= false then
                    f.dryClose = (f.dryClose or 0) + 1
                else
                    f.dry = f.dry + 1
                end
            end
            if B.lit(m.shell) then f.lit = (f.lit or 0) + 1 end
            f.standing = (f.standing or 0) + 1
            if (f.coverChecked or 0) < B.n("coverSample") then
                local c = B.inCover(m, contact.target, now)
                if c ~= nil then
                    f.coverChecked = (f.coverChecked or 0) + 1
                    if c then f.covered = (f.covered or 0) + 1 end
                end
            end
            firstShell = firstShell or m.shell
        end
        if isCompanion(rec) then f.advisory = true end
        local mem = type(rec) == "table" and rec.memory or {}
        if mem.outpostId ~= nil or (type(groupId) == "string" and string.sub(groupId, 1, 8) == "outpost:") then f.home = true end
        if not f.home and B.atHome(mem, m.shell) then f.home = true end
        f.class = f.class or classOf(rec)
        -- once per fight: ALifeCapture.wantsAlive rolls for rough crews, so don't re-roll every think
        if state.wantsAlive == nil and type(ALifeCapture) == "table" and fn(ALifeCapture, "wantsAlive") then
            local ok, k = pcall(ALifeCapture.wantsAlive, rec)
            state.wantsAlive = (ok and k ~= nil) and true or false
        end
    end
    f.wantsAlive = state.wantsAlive == true
    if nerveN > 0 then f.nerve = nerveSum / nerveN end
    f.firstShell = firstShell
    f.zombies = firstShell and zombiesNear(firstShell) or 0
    f.night = isNight()
    -- the other side
    f.vsPlayer = contact.kind == "player" or isPlayer(contact.target)
    if tx ~= nil then
        if f.vsPlayer then
            f.enemies, f.enemiesHurt = B.playerSide(tx, ty, B.n("brainEnemyReach"))
            if isPlayer(contact.target) then
                f.targetHurt = playerHealth(contact.target) < B.n("wantsAliveHealth")
                if f.night then f.targetLit = B.playerLit(contact.target) end
            end
        else
            local tuid = uidOfShell(contact.target)
            local trec = recordOf(tuid)
            if trec == nil then f.vsZombies = true; return f end -- zombies: A-Life alone (HordeRetreat etc.)
            local tg = B.groupIdOf(trec)
            if tg ~= nil then
                for _, m in ipairs(B.members(tg, tx, ty, B.n("brainEnemyReach"))) do
                    if not downed(m.actor) then
                        f.enemies = f.enemies + 1
                        if healthOf(m.actor, m.shell) < 0.5 then f.enemiesHurt = f.enemiesHurt + 1 end
                    end
                end
            end
            if f.enemies == 0 then f.enemies = 1 end
        end
    end
    -- the fight so far
    if state.startCount == nil or f.alive > state.startCount then state.startCount = f.alive end
    f.startCount = state.startCount
    local lu = B.leaderUidOf(groupId)
    if state.leaderUid == nil then state.leaderUid = lu end
    if state.leaderUid ~= nil and not state.leaderLost then
        local lr = recordOf(state.leaderUid)
        if lr == nil or lr.lifecycle ~= "active" or downed(lr) then state.leaderLost = true end
    end
    f.leaderLost = state.leaderLost == true
    return f
end

-- ---------------------------------------------------------------------------------------------------- the veto
function B.veto(actor, id)
    -- your own order first (suppress): only supportFire, only while it runs; works with the brain off too
    local uid = type(actor) == "table" and actor.uid ~= nil and tostring(actor.uid) or nil
    local po = uid and B.partyOrders[uid] or nil
    if po ~= nil then
        if B.nowMs() > num(po.untilMs, 0) then B.partyOrders[uid] = nil
        elseif id == "supportFire" then return true end
    end
    if not B.on() then
        -- preset 1: plain, dumb fighting for every non-player group (your party is never touched)
        if B.setting("fightBrain") ~= false and B.preset() == 1 and type(actor) == "table" and not isCompanion(actor) then
            local v = B.VETO.dumb[id]
            if v ~= nil then return v end
        end
        return nil
    end
    local gid = B.groupIdOf(actor)
    local st = gid and B.groups[gid] or nil
    if st == nil or st.advisory or st.mood == nil then return nil end
    local key = st.mood
    if st.fake ~= nil then key = "fakerun" end
    if st.ambush ~= nil then key = "ambush" end
    if st.phase == "hunt" then key = "hunt"
    elseif st.phase == "rest" then key = "rest"
    elseif B.nowMs() - num(st.atMs, 0) > B.n("brainFightMs") then return nil end
    local row = B.VETO[key]
    if type(row) ~= "table" then return nil end
    local v = row[id] -- explicit: `row and row[id] or nil` would turn a false verdict into nil
    if v ~= nil then B.metrics.vetoes = B.metrics.vetoes + 1 end
    return v
end

function B.installVeto()
    local pa = PA()
    local reg = pa and pa.ModuleRegistry or nil
    if reg == nil then return false end
    if B.vetoInstalled then return true end
    local previous = reg.veto
    reg.veto = function(actor, id)
        local ok, verdict = pcall(B.veto, actor, id)
        if ok and verdict ~= nil then return verdict end
        if type(previous) == "function" then return previous(actor, id) end
        return nil
    end
    B.vetoInstalled = true
    return true
end

-- ---------------------------------------------------------------------------------------------------- voice
local function pick(list) if type(list) ~= "table" or #list == 0 then return nil end return list[roll(#list) + 1] end
function B.say(shell, text)
    local pa = PA()
    if shell == nil or text == nil or pa == nil or not fn(pa.Speech, "sayLine") then return false end
    local ok = pcall(pa.Speech.sayLine, shell, text, "directed")
    return ok
end
function B.bark(state, f, now)
    if B.setting("brainBarks") == false or state.advisory then return false end
    if now < num(state.barkAtMs, 0) then return false end
    local line = pick(B.BARKS[state.mood])
    if line == nil then return false end
    for _, m in ipairs(f.list or {}) do
        if not downed(m.actor) and m.shell ~= nil then
            if B.say(m.shell, line) then
                state.barkAtMs = now + B.n("barkGapMs")
                B.metrics.barks = B.metrics.barks + 1
                return true
            end
        end
    end
    return false
end

-- your people call it: what an enemy group near you just did
function B.companionNear(player, reach)
    local px, py = xyz(player)
    if px == nil then return nil end
    local pa = PA()
    local reg = pa and pa.ActorRegistry or nil
    local best, bestD = nil, reach * reach
    if fn(reg, "each") then
        pcall(reg.each, function(rec)
            if type(rec) == "table" and rec.lifecycle == "active" and isCompanion(rec) and not downed(rec) then
                local sh = shellOf(rec.uid)
                local x, y = xyz(sh)
                if x ~= nil then
                    local dd = d2(x, y, px, py)
                    if dd <= bestD then best, bestD = sh, dd end
                end
            end
            return false
        end)
    end
    return best
end
function B.advise(kind, near)
    if B.setting("partyAdvice") == false then return false end
    local line = pick(B.ADVICE[kind])
    if line == nil or type(near) ~= "table" then return false end
    local now = B.nowMs()
    local said = false
    for _, p in ipairs(B.players()) do
        local key = tostring(call(p, "getUsername") or "p0")
        local row = B.parties[key] or {}
        B.parties[key] = row
        local px, py = xyz(p)
        if px ~= nil and d2(px, py, near.x, near.y) <= B.n("brainReach") ^ 2 and now >= num(row.atMs, 0) then
            local sh = B.companionNear(p, 20)
            if sh ~= nil and B.say(sh, line) then
                row.atMs = now + B.n("partyAdviceGapMs")
                B.metrics.advice = B.metrics.advice + 1
                said = true
            end
        end
    end
    return said
end

-- ---------------------------------------------------------------------------------------------------- give up
function B.armed(player)
    local pa = PA()
    if pa and fn(pa.Standoff, "playerArmed") then
        local ok, a = pcall(pa.Standoff.playerArmed, player)
        return ok and a == true
    end
    return false
end
function B.sees(player, shell, record)
    local pa = PA()
    if pa and fn(pa.Talk, "lineOfSight") then
        local ok, s = pcall(pa.Talk.lineOfSight, player, shell, record)
        return ok and s == true
    end
    return true
end
-- returns true if they gave up to a player
function B.giveUp(groupId, state, f, contact, now)
    local player = isPlayer(contact.target) and contact.target or nil
    if player == nil then return false end
    local reach2 = B.n("giveUpReach") ^ 2
    local px, py = xyz(player)
    if px == nil or not B.armed(player) then B.metrics.giveUpNo = B.metrics.giveUpNo + 1; return false end
    local pa = PA()
    local Orders = pa and pa.TalkOrders or nil
    if not fn(Orders, "surrenderCrew") then return false end
    for _, m in ipairs(f.list or {}) do
        local x, y = xyz(m.shell)
        if x ~= nil and not downed(m.actor) and d2(x, y, px, py) <= reach2 and B.sees(player, m.shell, m.actor) then
            local ok, any = pcall(Orders.surrenderCrew, m.actor, m.shell, player, now, "surrender")
            if ok and any == true then
                state.surrendered = true
                B.metrics.gaveUp = B.metrics.gaveUp + 1
                log("group " .. tostring(groupId) .. " gave up to " .. tostring(call(player, "getUsername") or "you"))
                return true
            end
        end
    end
    B.metrics.giveUpNo = B.metrics.giveUpNo + 1
    return false
end

-- 0.8.10c feint (off by default): criminals with their hands up wait for you to walk in close, then turn on you.
-- A-Life's own surrender is ended (TalkOrders.release) and the group pushes. Rolled once per fight.
B.FEINT_LINES = { "Now!", "Get him!", "Sucker!" }
function B.feint(groupId, st, f, contact, now)
    if st.mood ~= "giveup" or not st.surrendered or st.feintRolled or B.setting("feint") ~= true then return false end
    if st.class ~= "criminal" or not isPlayer(contact.target) then return false end
    if now - num(st.sinceMs, now) < B.n("feintMs") then return false end
    local px, py = xyz(contact.target)
    if px == nil then return false end
    local close = false
    for _, m in ipairs(f.list or {}) do
        local x, y = xyz(m.shell)
        if x ~= nil and d2(x, y, px, py) <= B.n("feintTiles") ^ 2 then close = true end
    end
    if not close then return false end
    st.feintRolled = true
    if not pct(B.n("feintChance")) then return false end
    local pa = PA()
    local Orders = pa and pa.TalkOrders or nil
    if not fn(Orders, "release") then return false end
    for _, m in ipairs(f.list or {}) do
        local uid = m.uid or (type(m.actor) == "table" and m.actor.uid)
        if uid ~= nil then pcall(Orders.release, uid, "feint", true) end
    end
    st.mood, st.sinceMs, st.surrendered, st.feinted = "push", now, false, true
    st.giveUpRolled = false -- tricked you once: no second give-up, they run when beaten
    B.metrics.feints = (B.metrics.feints or 0) + 1
    log("group " .. tostring(groupId) .. ": the give-up was a trick, they turn on you")
    local line = pick(B.FEINT_LINES)
    for _, m in ipairs(f.list or {}) do if not downed(m.actor) and B.say(m.shell, line) then break end end
    return true
end

-- 0.8.10c lure: a group that breaks yells to pull the dead onto the fight, then slips away. A real yell (vanilla
-- addSound, as A-Life's AimRetreat / Standoff and our 0.8.9 lure use it); only with enough dead near to come.
B.LURE_LINES = { "HEY! Over here!", "Come on, come and get it!", "HEY! HEY!" }
function B.lure(groupId, st, f, now)
    if st.lured or B.setting("enemyLure") == false or f.firstShell == nil then return false end
    st.lured = true
    if zombiesNear(f.firstShell, B.n("enemyLureNoise")) < B.n("enemyLureZeds") then return false end
    if not pct(B.n("enemyLureChance")) then return false end
    local x, y, z = xyz(f.firstShell)
    if x == nil then return false end
    local r = math.floor(B.n("enemyLureNoise"))
    local ok = false
    if type(addSound) == "function" then
        ok = pcall(addSound, f.firstShell, math.floor(x), math.floor(y), math.floor(z or 0), r, r)
    end
    if not ok then return false end
    B.say(f.firstShell, pick(B.LURE_LINES))
    B.metrics.lures = (B.metrics.lures or 0) + 1
    log("group " .. tostring(groupId) .. " yells to pull the dead in as they run")
    return true
end

-- dry guns, you close, they're pushing: A-Life's own all-in charge (MeleeSwitch.allIn: run in, melee). Once each.
function B.dryCharge(st, f, contact, now)
    if B.setting("dryCharge") == false or not isPlayer(contact.target) then return 0 end
    local pa = PA()
    local Sw = pa and pa.MeleeSwitch or nil
    if not fn(Sw, "allIn") then return 0 end
    local px, py = xyz(contact.target)
    if px == nil then return 0 end
    st.charged = st.charged or {}
    local n = 0
    for _, m in ipairs(f.list or {}) do
        local uid = tostring(m.uid or (type(m.actor) == "table" and m.actor.uid) or "")
        local x, y = xyz(m.shell)
        if m.dry and not st.charged[uid] and x ~= nil and not downed(m.actor) and d2(x, y, px, py) <= B.n("dryChargeTiles") ^ 2 then
            local ok = pcall(Sw.allIn, m.actor, m.shell, contact.target, now, math.sqrt(d2(x, y, px, py)))
            if ok then st.charged[uid] = true; n = n + 1 end
        end
    end
    if n > 0 then B.metrics.dryCharges = (B.metrics.dryCharges or 0) + n end
    return n
end

-- your side looks beaten from where they stand (they push and outnumber you 2 to 1): one of yours says so.
-- Works without your companions ever showing up in A-Life's fight contacts.
function B.partyCantHold(st, f, contact, now)
    if st.mood ~= "push" or st.saidCantHold then return false end
    local ours = num(f.enemies, 0) - 0.5 * num(f.enemiesHurt, 0)
    local theirs = num(f.alive, 0) - num(f.downed, 0)
    if ours <= 0 or theirs < 2 * ours then return false end
    local x, y = xyz(contact.target)
    if x == nil then return false end
    if B.advise("low", { x = x, y = y }) then st.saidCantHold = true; return true end
    return false
end

-- hunt: a "contact" mark where they last saw you, addressed to their own group (A-Life Investigation.reportContact:
-- the group walks there). Re-marked every huntMarkMs while the hunt lasts; noises (investigate) on top.
function B.markLastSeen(gid, st, now)
    st.markAtMs = now + B.n("huntMarkMs")
    local pa = PA()
    local inv = pa and pa.Investigation or nil
    if not fn(inv, "reportContact") or type(st.lastSeen) ~= "table" then return false end
    local actor = recordOf(st.reporter)
    if actor == nil or actor.lifecycle ~= "active" then
        for _, m in ipairs(B.members(gid, st.lastSeen.x, st.lastSeen.y, 80)) do if not downed(m.actor) then actor = m.actor; break end end
    end
    if actor == nil then return false end
    local ok, done = pcall(inv.reportContact, actor, st.target, st.lastSeen.x, st.lastSeen.y, st.lastSeen.z, 20)
    if ok and done == true then B.metrics.huntMarks = (B.metrics.huntMarks or 0) + 1 end
    return ok and done == true
end

-- 0.8.10c car: A-Life's CarLeaveServer asks "afraid?" per crew member before driving off; a group the brain says has
-- broken counts as afraid. Chained over any earlier adapter.
function B.installCar()
    local pa = PA()
    local Leave = pa and pa.CarLeaveServer or nil
    if type(Leave) ~= "table" or type(Leave.adapters) ~= "table" or B.carInstalled then return B.carInstalled == true end
    local previous = Leave.adapters.afraid
    Leave.adapters.afraid = function(actor, shell, now, ...)
        if B.on() and B.setting("carFlee") ~= false then
            local gid = B.groupIdOf(actor)
            local st = gid and B.groups[gid] or nil
            if st ~= nil and not st.advisory and st.phase == nil and st.mood == "break" and st.fake == nil then return true end
        end
        if type(previous) == "function" then return previous(actor, shell, now, ...) end
        if type(Leave.defaults) == "table" and type(Leave.defaults.afraid) == "function" then return Leave.defaults.afraid(actor, shell, now, ...) end
        return false
    end
    B.carInstalled = true
    return true
end

-- ---------------------------------------------------------------------------------------------------- tick
local function hash(s)
    local h = 17
    s = tostring(s or "")
    for i = 1, #s do h = (h * 31 + string.byte(s, i)) % 2147483647 end
    return h
end
function B.nearPlayer(x, y)
    if x == nil then return false end
    local r2 = B.n("brainReach") ^ 2
    for _, p in ipairs(B.players()) do
        local px, py = xyz(p)
        if px ~= nil and d2(px, py, x, y) <= r2 then return true end
    end
    return false
end

-- one group, one think (exposed for tests)
function B.thinkGroup(groupId, contact, now)
    local st = B.groups[groupId]
    if st == nil then st = { firstMs = now }; B.groups[groupId] = st end
    st.atMs = num(contact.atMs, now)
    if type(contact.position) == "table" then st.lastSeen = { x = num(contact.position.x, 0), y = num(contact.position.y, 0), z = num(contact.position.z, 0) } end
    st.reporter = contact.reportedBy
    st.target = contact.target
    local f = B.facts(groupId, contact, st, now)
    -- group size counts at the start of the fight (the last one standing of a beaten group still runs or gives up)
    if f == nil or f.vsZombies or contact.kind == "zombie" or num(f.startCount, 0) < B.n("brainMinGroup") or f.alive < 1 then
        if st.mood == nil then B.groups[groupId] = nil end
        return nil
    end
    st.advisory = f.advisory == true
    st.vsPlayer = f.vsPlayer == true
    st.class = f.class
    if st.phase ~= nil then
        log("group " .. tostring(groupId) .. ": back in the fight (" .. tostring(st.phase) .. " over)")
        st.phase = nil
    end
    -- 0.8.11: add-ons that must decide before the think (ambush goes quiet before the first shout)
    for _, h in ipairs(B.preThink) do pcall(h, groupId, st, f, contact, now) end
    if not st.advisory and B.feint(groupId, st, f, contact, now) then return st, f end
    local changed, old = B.think(st, f, now)
    if not st.advisory and st.mood == "push" then B.dryCharge(st, f, contact, now) end
    if not st.advisory and st.vsPlayer and st.fake == nil and st.ambush == nil then B.partyCantHold(st, f, contact, now) end -- 0.8.11.1: not while a trick is on
    if changed then
        B.metrics.changes = B.metrics.changes + 1
        log("group " .. tostring(groupId) .. ": " .. tostring(old or "start") .. " -> " .. tostring(st.mood)
            .. " (score " .. tostring(math.floor(num(st.score, 0) * 100 + 0.5) / 100) .. "; " .. tostring(f.alive) .. " us, "
            .. tostring(f.enemies) .. " them" .. ((#st.why > 0) and ("; " .. table.concat(st.why, ", ")) or "") .. ")")
        if st.advisory then
            if st.mood == "fallback" or st.mood == "break" or st.mood == "giveup" then
                local x, y = xyz(contact.target)
                if x ~= nil then B.advise("low", { x = x, y = y }) end
            end
        else
            if st.mood == "giveup" and not st.surrendered then
                if not B.giveUp(groupId, st, f, contact, now) then st.mood, st.sinceMs = "break", now end
            end
            if st.mood == "break" and st.vsPlayer then B.lure(groupId, st, f, now) end
            -- 0.8.11.1: quiet while an ambush or a fake run is on (a mood shout would give the trick away)
            if st.ambush == nil and st.fake == nil and (old ~= nil or st.mood ~= "steady") then B.bark(st, f, now) end
            local first = f.list and f.list[1] and f.list[1].shell or nil
            local x, y = xyz(first)
            if x ~= nil and st.ambush == nil and st.fake == nil and st.mood ~= "steady" and st.mood ~= "careful" then B.advise(st.mood, { x = x, y = y }) end
        end
    end
    return st, f
end

function B.tick()
    if not B.on() or not B.authoritative() then return end
    local now = B.nowMs()
    if now < num(B.nextMs, 0) then return end
    B.nextMs = now + 250
    local pa = PA()
    local T = pa and pa.SquadTactics or nil
    if T == nil or type(T.contacts) ~= "table" then return end
    B.metrics.ticks = B.metrics.ticks + 1
    local fightMs, tickMs = B.n("brainFightMs"), B.n("brainTickMs")
    for gid, c in pairs(T.contacts) do
        if type(c) == "table" and now - num(c.atMs, 0) <= fightMs then
            local st = B.groups[gid]
            local slot = (hash(gid) % 8) * (tickMs / 8)
            if st == nil or now >= num(st.nextMs, 0) then
                local x, y = nil, nil
                if type(c.position) == "table" then x, y = num(c.position.x, nil), num(c.position.y, nil) end
                if B.nearPlayer(x, y) then
                    local ok, e = pcall(B.thinkGroup, gid, c, now)
                    if not ok then log("think failed for " .. tostring(gid) .. ": " .. tostring(e)) end
                    st = B.groups[gid]
                    if st ~= nil then st.nextMs = now + tickMs + (st.nextMs == nil and slot or 0) end
                end
            end
        end
    end
    -- fights that went quiet: winners hunt you (where they last saw you, then your noise) a while on the game clock,
    -- then give up and rest; everyone else is forgotten
    local gone = {}
    local wm = B.worldMin()
    for gid, st in pairs(B.groups) do
        if st.phase == nil and now - num(st.atMs, 0) > fightMs then
            local winning = st.mood == "push" or st.mood == "steady" or st.mood == "careful"
            if B.setting("enemyHunt") ~= false and st.vsPlayer and winning and not st.advisory then
                st.phase, st.phaseUntilMin = "hunt", wm + B.n("enemyHuntMin")
                log("group " .. tostring(gid) .. ": lost you, hunting you")
                B.markLastSeen(gid, st, now)
            else
                gone[#gone + 1] = gid
            end
        elseif st.phase == "hunt" then
            if wm >= num(st.phaseUntilMin, 0) then
                st.phase, st.phaseUntilMin = "rest", wm + B.n("enemyHuntRestMin")
                B.metrics.huntsGivenUp = (B.metrics.huntsGivenUp or 0) + 1
                log("group " .. tostring(gid) .. ": gave up the hunt")
            elseif now >= num(st.markAtMs, 0) then
                B.markLastSeen(gid, st, now)
            end
        elseif st.phase == "rest" and wm >= num(st.phaseUntilMin, 0) then
            gone[#gone + 1] = gid
        end
    end
    for _, gid in ipairs(gone) do B.groups[gid] = nil end
    B.metrics.groups = 0
    for _ in pairs(B.groups) do B.metrics.groups = B.metrics.groups + 1 end
end

function B.qaLine()
    local m = B.metrics
    return "[ALIFE-QA] FightBrain: groups=" .. m.groups .. " changes=" .. m.changes .. " vetoes=" .. m.vetoes
        .. " gaveUp=" .. m.gaveUp .. " giveUpNo=" .. m.giveUpNo .. " barks=" .. m.barks .. " advice=" .. m.advice
        .. " huntsGivenUp=" .. tostring(m.huntsGivenUp or 0) .. " lures=" .. tostring(m.lures or 0) .. " feints=" .. tostring(m.feints or 0)
end

-- ---------------------------------------------------------------------------------------------------- install
function B.install()
    if B.installed then return true end
    B.installed = true
    local v = B.installVeto()
    local car = B.installCar()
    local pa = PA()
    local have = pa and type(pa.SquadTactics) == "table" and type(pa.SquadTactics.contacts) == "table"
    log("ready v" .. B.VERSION .. ": " .. (B.on() and ("on, preset " .. B.preset()) or "off")
        .. ", veto " .. (v and "hooked" or "NOT hooked") .. ", contacts " .. (have and "read" or "NOT found")
        .. ", car flee " .. (car and "hooked" or "NOT hooked")
        .. " (moods push/steady/careful/fall back/break/give up; hunt, lure, feint " .. (B.setting("feint") == true and "on" or "off")
        .. "; your party: advice only)")
    return v
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() local ok, e = pcall(B.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(B.install) end) end
    if Events.OnTick ~= nil then Events.OnTick.Add(function() local ok, e = pcall(B.tick); if not ok then log("tick failed: " .. tostring(e)) end end) end
end

return B
