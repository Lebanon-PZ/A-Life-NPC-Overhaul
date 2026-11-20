-- A-Life NPC Overhaul 0.8.10a: fight brain, client side = settings only (the brain runs where A-Life fights:
-- shared/ALifeNPCOverhaul/ALifeFightBrain.lua, server / SP). Defaults in, keys listed at LOAD time (else they reset on
-- restart), rows under a "Fights" heading in Settings.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_FightBrain") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeFightBrain"
require "ALifeNPCOverhaul/ALifePartyTactics"
require "ALifeNPCOverhaul/ALifeUnderFire"
require "ALifeNPCOverhaul/ALifeFightTalk"
require "ALifeNPCOverhaul/ALifeDropLoot"
require "ALifeNPCOverhaul/ALifeFakeRun"
require "ALifeNPCOverhaul/ALifeAmbush"
require "ALifeNPCOverhaul/ALifeCarBlock"
require "ALifeNPCOverhaul/ALifeGunSense"
require "ALifeNPCOverhaul/ALifeMeleeStyle"
require "ALifeNPCOverhaul/ALifeBodyAmmo"
require "ALifeLLMTalk/ALifeTalk_Commands"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeFightBrain) ~= "table" then return end
local B = ALifeFightBrain
ALifeTalkFightBrain = ALifeTalkFightBrain or {}
local K = ALifeTalkFightBrain
K.CAT = "Fights"

K.ROWS = {
    { "fightBrain", "Fights: enemy groups read the fight (push, hold, fall back, run, give up)" },
    { "fightPreset", "Fights: enemy smarts - 1 plain A-Life, 2 smart, 3 brutal", { 1, 2, 3 } },
    { "brainTickMs", "Fights: how often a group rethinks (ms)", { 1000, 2000, 4000 } },
    { "brainReach", "Fights: only fights this close to you get a brain (tiles)", { 40, 60, 100 } },
    { "brainFightMs", "Fights: quiet this long and the fight is over (ms)", { 15000, 30000, 60000 } },
    { "brainMinGroup", "Fights: smallest group with a brain (people)", { 2, 3, 4 } },
    { "moodMinMs", "Fights: a group keeps its mood at least this long (ms)", { 4000, 8000, 15000 } },
    { "moodBand", "Fights: how far past a line before the mood changes (0-1)", { 0.03, 0.06, 0.1 } },
    { "moodPush", "Fights: odds score to push (0.5 = even)", { 0.6, 0.66, 0.75 } },
    { "moodSteady", "Fights: odds score to fight steady", { 0.42, 0.46, 0.5 } },
    { "moodCareful", "Fights: odds score to play it careful (below = fall back)", { 0.3, 0.36, 0.42 } },
    { "moodFallBack", "Fights: odds score to fall back (below = run)", { 0.18, 0.24, 0.3 } },
    { "moodBreak", "Fights: odds score to run (below = give up)", { 0.08, 0.14, 0.2 } },
    { "leaderLostCost", "Fights: how much losing their leader shakes them", { 0, 0.06, 0.12, 0.2 } },
    { "lossCost", "Fights: how much their dead shake them", { 0, 0.1, 0.15, 0.25 } },
    { "brokenCost", "Fights: how much shaken friends shake them", { 0, 0.1, 0.15, 0.25 } },
    { "dryCost", "Fights: how much empty guns shake them", { 0, 0.05, 0.1, 0.2 } },
    { "zombieCost", "Fights: how much each zombie near the fight cools them", { 0, 0.01, 0.02, 0.04 } },
    { "zombieCostMax", "Fights: most zombies can cool them", { 0, 0.1, 0.15, 0.3 } },
    { "nightCost", "Fights: how much more careful at night", { 0, 0.04, 0.08 } },
    { "homeBonus", "Fights: how much harder they hold at home (never run or give up there)", { 0, 0.05, 0.1, 0.2 } },
    { "trainedBonus", "Fights: how much tighter military and police hold", { 0, 0.04, 0.08, 0.15 } },
    { "flakyCost", "Fights: how much sooner criminals fold", { 0, 0.05, 0.1 } },
    { "giveUp", "Fights: a beaten group can give up to you (you armed, close, in sight)" },
    { "giveUpChance", "Fights: chance a beaten group gives up instead of running (%)", { 0, 25, 50, 75 } },
    { "giveUpReach", "Fights: how close you must be for them to give up to you (tiles)", { 8, 12, 20 } },
    { "wantsAliveSoft", "Fights: people who want you alive stop pushing to kill once you're hurt" },
    { "wantsAliveHealth", "Fights: ... your health under this", { 30, 50, 70 } },
    { "brainBarks", "Fights: they shout what they're doing (Fall back!, Push!)" },
    { "barkGapMs", "Fights: time between their shouts (ms)", { 3000, 6000, 12000 } },
    { "partyAdvice", "Fights: your people call out what the other side does" },
    { "partyAdviceGapMs", "Fights: time between your people's callouts (ms)", { 5000, 10000, 20000 } },
    -- 0.8.10b
    { "brainPersona", "Fights: who they are counts - brave hold, scared fold (single player)" },
    { "nerveCost", "Fights: how much who they are counts", { 0, 0.04, 0.08, 0.15 } },
    { "enemyHunt", "Fights: after a fight they were winning they come after your noise for a while" },
    { "enemyHuntMin", "Fights: how long they hunt you (game minutes)", { 30, 60, 180 } },
    { "enemyHuntRestMin", "Fights: after giving up, how long they leave noises alone (game minutes)", { 60, 120, 360 } },
    { "suppressMs", "Orders: suppress them - how long they keep the fire up (ms)", { 6000, 12000, 20000 } },
    { "flankTiles", "Orders: flank - how far out to the side they swing (tiles)", { 6, 10, 15 } },
    { "flankGiveUpMs", "Orders: flank - they attack from where they got to after this long (ms)", { 20000, 45000, 90000 } },
    -- 0.8.10c
    { "enemyLure", "Fights: a group that breaks may yell to pull the dead onto you as it runs" },
    { "enemyLureChance", "Fights: chance they yell for the dead (%)", { 0, 15, 35, 60 } },
    { "enemyLureNoise", "Fights: how far their yell carries (tiles)", { 25, 40, 60 } },
    { "feint", "Fights: criminals may fake giving up and turn on you up close (dirty)" },
    { "feintChance", "Fights: chance a criminal give-up is a trick (%)", { 10, 30, 50 } },
    { "feintTiles", "Fights: how close you walk in before the trick (tiles)", { 2, 3, 5 } },
    { "carFlee", "Fights: a group that breaks runs for its car and drives off" },
    { "carFleeTiles", "Fights: how far a broken group drives off (tiles)", { 80, 150, 300 } },
    -- 0.8.10.1
    { "dryCharge", "Fights: guns empty and you close, they rush you with what's in their hands" },
    { "dryChargeTiles", "Fights: how close for that rush (tiles)", { 5, 8, 12 } },
    { "bleedCost", "Fights: how much their bleeding shakes them", { 0, 0.03, 0.06, 0.12 } },
    { "nightSeeBonus", "Fights: at night, how much a light on (yours or theirs) gives the other side", { 0, 0.03, 0.06, 0.12 } },
    { "brainCover", "Fights: cover counts (in the open they fold sooner)" },
    { "openCost", "Fights: how much being in the open shakes them", { 0, 0.03, 0.06, 0.12 } },
    { "homeReach", "Fights: how near where they live counts as home turf (tiles)", { 15, 30, 60 } },
    -- 0.8.11
    { "underFire", "Fights: rounds cracking past you raise your panic (worse aim, slower reload)" },
    { "underFirePanic", "Fights: panic per near miss (moodle levels at 6, 30, 65, 80)", { 6, 12, 20, 30 } },
    { "underFireStack", "Fights: pinned - each near miss in a row hits this much harder (pct)", { 0, 25, 50, 100 } },
    { "underFirePinnedMs", "Fights: near misses this close together count as pinned (ms)", { 3000, 6000, 10000 } },
    { "underFireMax", "Fights: near misses never push panic past this", { 30, 50, 70, 90 } },
    { "underFireStress", "Fights: stress per near miss (0-1)", { 0, 0.01, 0.03, 0.06 } },
    { "underFireTiles", "Fights: how close a round must pass to count (tiles)", { 2, 3, 5 } },
    { "underFireTraits", "Fights: Cowardly, Brave, Desensitized change it like vanilla panic" },
    { "fightTalk", "Fights: yell at a losing group to give up or drop it (A-Life's odds plus how the fight goes)" },
    { "fightTalkPush", "Fights: give-up odds when they're pushing", { -100, -60, -30 } },
    { "fightTalkSteady", "Fights: give-up odds when they fight steady", { -60, -40, -20 } },
    { "fightTalkCareful", "Fights: give-up odds when they're careful", { -30, -15, 0 } },
    { "fightTalkFallBack", "Fights: give-up odds when they fall back", { 0, 10, 20 } },
    { "fightTalkBreak", "Fights: give-up odds when they run", { 10, 25, 40 } },
    { "fightTalkMax", "Fights: give-up odds never above (pct)", { 60, 75, 90 } },
    { "fightTalkReach", "Fights: they hear you say it this close (tiles)", { 8, 12, 16 } },
    { "fightTalkShoutReach", "Fights: they hear you shout it this close (tiles)", { 18, 25, 35 } },
    { "fightTalkGapMs", "Fights: time between tries on one group (ms)", { 4000, 8000, 15000 } },
    { "dropLoot", "Fights: people who run drop their bag or heavy things to run faster" },
    { "dropLootChance", "Fights: chance each runner drops something (pct)", { 20, 40, 70 } },
    { "dropLootBag", "Fights: the bag on their back goes first" },
    { "dropLootItems", "Fights: no bag - this many of their heaviest things", { 1, 2, 4 } },
    { "dropLootMinWeight", "Fights: ... only things at least this heavy", { 0.5, 1.5, 3 } },
    { "giveUpDropGuns", "Fights: a group that gives up puts its guns on the floor" },
    { "fakeRun", "Fights: smart groups may fake a run to draw you out, then turn on you" },
    { "fakeRunChance", "Fights: chance they try it, once per fight (pct)", { 10, 25, 50 } },
    { "fakeRunWho", "Fights: who fakes it - 1 military/police, 2 + led criminals, 3 everyone", { 1, 2, 3 } },
    { "fakeRunReach", "Fights: only when you're this close (tiles)", { 20, 30, 45 } },
    { "fakeRunMs", "Fights: longest they keep the act up (ms)", { 6000, 10000, 16000 } },
    { "fakeRunTurnTiles", "Fights: chase in this close and they turn (tiles)", { 6, 10, 14 } },
    { "gunSense", "Fights: on the dead, blades first; guns only when outnumbered AND cornered (a shot draws the whole town)" },
    { "gunSenseWho", "Fights: gun sense for - 1 people walking with you, 2 everyone (your party: its order wheel)", { 1, 2 } },
    { "gunSenseCrowdN", "Fights: outnumbered = this many dead near them (or A-Life's own horde alarm)", { 4, 6, 10 } },
    { "gunSenseCrowdTiles", "Fights: ... within this many tiles", { 5, 8, 12 } },
    { "gunSenseCloseN", "Fights: cornered = this many dead right on them", { 2, 3, 5 } },
    { "gunSenseCloseTiles", "Fights: ... this close (tiles)", { 1, 2, 3 } },
    { "gunSenseExits", "Fights: also cornered: one dead that close and this many open squares around them or fewer", { 1, 2, 3 } },
    { "gunSenseHurt", "Fights: also cornered: one dead that close and they are this hurt or worse (health pct)", { 25, 40, 60 } },
    { "bodyAmmo", "Fights: the dead drop their real spare ammo (filled mags) for the gun they carried, modded guns too" },
    { "bodyAmmoMags", "Fights: most spare mags dropped per gun", { 1, 3, 5 } },
    { "bodyAmmoChance", "Fights: chance each of those mags is still on them (pct)", { 35, 70, 100 } },
    { "ammoWant", "Fights: gun carriers short of spare mags look for ammo first on a scavenge run" },
    { "ammoWantMags", "Fights: spare mags they want (A-Life reserve cap Ammo_ReserveLoads limits it)", { 2, 3, 5 } },
    { "packMags", "Fights: guns that take a magazine - spare ammo is real filled mags in the pack, a reload swaps a real mag (none left: they fill one from loose rounds)" },
    { "packMagsMax", "Fights: most real spare mags per gun", { 2, 4, 6 } },
    { "meleeStyle", "Fights: everyone has a melee kind they know (blade, blunt, axe, spear...); their skill with each decides what they swing and how well" },
    { "meleeStyleSpread", "Fights: how much better than A-Life's melee skill someone can be with their own kind (levels)", { 1, 3, 5 } },
    { "meleeStyleFamilyGap", "Fights: how much worse with the kind next to theirs, e.g. knife for a machete man (levels)", { 1, 2, 3 } },
    { "meleeStyleOtherGap", "Fights: how much worse with every other kind (levels)", { 2, 4, 6 } },
    { "meleeStyleFavBonus", "Fights: how much they lean to their own kind when picking a weapon (pct)", { 0, 15, 30 } },
    { "meleeStyleHits", "Fights: hits with a kind to get better at it (times the level; 0 = never learn)", { 0, 15, 30, 60 } },
    { "meleeStyleCue", "Fights: Party tab says \"good with ...\" from this level (0 = never)", { 0, 4, 5, 7 } },
    { "followCatchUpWarp", "Fights: someone walking with you who falls far behind pops in beside you (off: they walk to you)" },
    { "ambush", "Fights: smart groups at home may lie in wait and spring on you up close" },
    { "ambushChance", "Fights: chance they lie in wait, once per fight (pct)", { 10, 20, 40 } },
    { "ambushWho", "Fights: who lies in wait - 1 military/police, 2 + led criminals, 3 everyone", { 1, 2, 3 } },
    { "ambushMinTiles", "Fights: you must still be this far off when they spot you (tiles)", { 8, 12, 20 } },
    { "ambushMs", "Fights: longest they lie in wait (ms)", { 30000, 60000, 120000 } },
    { "ambushAhead", "Fights: where they lie in wait - this far out from their home toward you (tiles)", { 5, 10, 20 } },
    { "carBlock", "Fights: hostile crews stop their car in the road and fight from behind it" },
    { "carBlockChase", "Fights: ... when you chase them in a car" },
    { "carBlockCamp", "Fights: ... when you drive at their home, they drive out to block you" },
    { "carBlockChance", "Fights: chance they block (pct)", { 25, 50, 75 } },
    { "carBlockChaseMs", "Fights: you behind them this long before they decide (ms)", { 3000, 6000, 12000 } },
    { "carBlockKmh", "Fights: your car going at least this fast (km/h)", { 10, 20, 40 } },
    { "carBlockCampReach", "Fights: you this close to their home, driving in (tiles)", { 150, 250, 400 } },
    { "carBlockCampAhead", "Fights: how far out toward you they set up (tiles)", { 20, 40, 70 } },
    { "carBlockSwing", "Fights: they swing the car across the road before they stop (single player)" },
    { "carBlockSwingMs", "Fights: time they get to turn the car (ms)", { 1000, 1500, 2500 } },
    { "carBlockSwingTiles", "Fights: how hard they turn (tiles off to the side)", { 3, 5, 8 } },
}

function K.settingsIn()
    local PT = ALifePartyTactics
    local MORE = {} -- 0.8.11 modules: DEFAULTS + FILE_KEYS (a nil in a list literal would stop ipairs)
    for _, X in pairs({ a = ALifeUnderFire, b = ALifeFightTalk, c = ALifeDropLoot, d = ALifeFakeRun, e = ALifeAmbush, f = ALifeCarBlock, g = ALifeGunSense, h = ALifeMeleeStyle, i = ALifeBodyAmmo }) do
        if type(X) == "table" then MORE[#MORE + 1] = X end
    end
    if type(M.settings) == "table" then
        for k, v in pairs(B.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
        if type(PT) == "table" then for k, v in pairs(PT.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end end
        for _, X in ipairs(MORE) do
            if type(X) == "table" and type(X.DEFAULTS) == "table" then for k, v in pairs(X.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end end
        end
    end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for _, k in ipairs(B.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
        for _, X in ipairs(MORE) do
            if type(X) == "table" and type(X.FILE_KEYS) == "table" then
                for _, k in ipairs(X.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
            end
        end
        if type(PT) == "table" then
            for _, k in ipairs(PT.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
            for _, c in ipairs(PT.CMDS) do local k = "cmd_" .. c.id; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
        end
    end
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(K.ROWS) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
        if type(ALifeTalkSettings) == "table" and tonumber(ALifeTalkSettings.PER_COL) then
            ALifeTalkSettings.PER_COL = math.max(ALifeTalkSettings.PER_COL, math.ceil(#M.settingRows / 3))
        end
    end
    if type(M.settingCatOf) ~= "table" then M.settingCatOf = {} end
    for _, r in ipairs(K.ROWS) do M.settingCatOf[r[1]] = K.CAT end
end
-- the heading: Settings builds M.settingCats when it loads (after this file); add ours before "Other"
function K.catIn()
    local cats = M.settingCats
    if type(cats) ~= "table" then return end
    for _, c in ipairs(cats) do if c == K.CAT then return end end
    local at = #cats + 1
    for i, c in ipairs(cats) do if c == "Other" then at = i end end
    table.insert(cats, at, K.CAT)
end
-- the "enemy" spot (suppress / flank): the nearest hostile person within cmdPointReach - an A-Life NPC who hates you
-- (opinion <= -41, as the "threat" spot) or is fighting you; else where you're looking, 15 tiles out.
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
function K.enemyPoint(player)
    local px, py, pz = nil, nil, 0
    pcall(function() px, py, pz = player:getX(), player:getY(), player:getZ() end)
    if px == nil then return nil end
    local reach = tonumber(ALifeCommands and ALifeCommands.setting and ALifeCommands.setting("cmdPointReach")) or 40
    local best, bd = nil, reach * reach
    pcall(function()
        local list = getCell():getZombieList()
        local Perc = PA().Perception
        for i = 0, list:size() - 1 do
            local zb = list:get(i)
            if not zb:isDead() then
                local d = (zb:getX() - px) ^ 2 + (zb:getY() - py) ^ 2
                if d < bd then
                    local actor = nil
                    if Perc and fn(Perc, "activeActorForShell") then pcall(function() actor = Perc.activeActorForShell(zb) end) end
                    if actor ~= nil then
                        local hostile = false
                        local r = nil
                        pcall(function() r = PA().ActorRegistry.read(tostring(actor.uid)) end)
                        pcall(function() hostile = (tonumber((PA().NpcOpinion.valueOf(r, player))) or 0) <= -41 end)
                        if not hostile and type(r) == "table" and r.activity == "combat" then
                            local m = type(r.memory) == "table" and r.memory or {}
                            hostile = m.combatTargetKind == nil or m.combatTargetKind == "player"
                        end
                        if hostile and not (type(r) == "table" and type(r.memory) == "table" and type(r.memory.companion) == "table") then
                            best, bd = { x = math.floor(zb:getX()), y = math.floor(zb:getY()), z = math.floor(zb:getZ()) }, d
                        end
                    end
                end
            end
        end
    end)
    if best then return best end
    local dx, dy = nil, nil
    pcall(function() local v = player:getForwardDirection(); dx, dy = v:getX(), v:getY() end) -- unverified on 42.21 (guarded)
    if dx == nil or (dx == 0 and dy == 0) then return nil end
    local l = math.sqrt(dx * dx + dy * dy)
    return { x = math.floor(px + dx / l * 15), y = math.floor(py + dy / l * 15), z = math.floor(pz) }
end
function K.wrapPoint()
    local TC = ALifeTalkCommands
    if K.pointWrapped or not fn(TC, "point") then return end
    local orig = TC.point
    TC.point = function(player, kind, ...)
        if kind == "enemy" then return K.enemyPoint(player) end
        return orig(player, kind, ...)
    end
    K.pointWrapped = true
end
-- talking them down (ALifeFightTalk): their answer in their own voice, bridge react mode "standoff" (no bridge change)
if type(M.eventModes) == "table" then
    M.eventModes.fighttalk = {
        request = function(job, now)
            if not fn(M, "reactRequest") then return nil end
            local req = M.reactRequest(job, now)
            if type(req) ~= "table" then return nil end
            req.mode = "standoff"
            req.react = job.react
            return req
        end,
        finish = function(p, r) if fn(ALifeFightTalk, "onAi") then pcall(ALifeFightTalk.onAi, p.ftJob, r) end end,
        fallback = function(p) if fn(ALifeFightTalk, "onAi") then pcall(ALifeFightTalk.onAi, p.ftJob, nil) end end,
    }
end
pcall(K.wrapPoint)
pcall(K.settingsIn) -- load time
pcall(K.catIn)
if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function() pcall(K.settingsIn); pcall(K.catIn) end)
end
