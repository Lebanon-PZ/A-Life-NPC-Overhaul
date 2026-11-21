-- A-Life NPC Overhaul 0.8.8: SETTLEMENT, the client side.
--   * Settings for the 0.8.8 server modules (ALifeCampVote, ALifeRations, ALifeGrowth, ALifeLieutenant), registered at
--     load so they survive a restart, on the Settings tab under "Your camp and base".
--   * NEW CAMP ROLES: Scout, Mechanic, Teacher (beside Cook, Medic, Guard, Builder, Farmer, Shepherd). Hunter and Trader
--     are not in: no real hunting or trade path for them yet.
--   * PEOPLE WHO GET BETTER: time in a role adds to how well they do it (up to roleGrowMax % over roleSeasonDays), on top
--     of who they were and who they are (Camp's cpFit). The roles go to the server every few hours ("campRoles"), where
--     A-Life companions practise their skill (ALifeGrowth).
--   * RATIONS by word, to anyone of yours: "full rations", "short rations", "half rations", "guards eat first".
--   * LIEUTENANTS by word: "you're in charge while I'm gone" (1st), "you're next in line" (2nd). Pecking order: someone
--     sworn to you (the Oath) who is passed over for 1st holds it against you; someone who swears after you picked a 1st
--     wants the job and turns rival to whoever has it. The 1st reports back when you return (ltReport).
--   * Letters for what the server says: the camp's view of people at the door (campVote), rations (rationSet), skills
--     and scout sightings (campReport), the lieutenant's report (ltReport).
--   * People you already know moving in through Settle go through the same camp vote (campVoteDone).
--   * 0.8.8 UI: STAND DOWN ("stand down", or the camp board's button): costs their opinion of you by how long they had
--     it, who they are (temperament, traits), how you get on (NpcOpinion), sworn or not, and whether they're hurt.
--     The screens themselves: ALifeTalk_SettlementUI.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Settlement") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeTalk_Camp"
require "ALifeNPCOverhaul/ALifeCmd"
if ALifeOut == nil then require "ALifeNPCOverhaul/ALifeOut" end -- pre-1.0: loaded first by folder order before (ALifeChatPlus sorted first); now a real require
if ALifeSettingsNet == nil then require "ALifeNPCOverhaul/ALifeSettingsNet" end
require "ALifeNPCOverhaul/ALifeCommands"
require "ALifeNPCOverhaul/ALifeCampVote"
require "ALifeNPCOverhaul/ALifeRations"
require "ALifeNPCOverhaul/ALifeGrowth"
require "ALifeNPCOverhaul/ALifeLieutenant"
require "ALifeNPCOverhaul/ALifeGivenKeep"
require "ALifeNPCOverhaul/ALifeCampWork"
require "ALifeNPCOverhaul/ALifeGateGuard"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Settlement"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Settlement") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end

ALifeSettlement = ALifeSettlement or {}
local K = ALifeSettlement
local TAG = "[ALifeSettlement]"
K.VERSION = ALifeSide.MOD_VERSION
K.metrics = K.metrics or { sent = 0, letters = 0, lts = 0, passed = 0, rivals = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(uid)
    local r = rec(uid)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
-- 0.8.8 UI (ALifeTalk_SettlementUI): what the screens add, client side
K.UI = { DEFAULTS = {
    campLogKeep = 20,     -- how many camp reports (lieutenant, scouts, the door) the camp board and journal keep
    scoutMarks = true,    -- scouts' sightings go on your map, roughly
    scoutMarkDays = 3,    -- days before a scout's mark comes off your map
    voteCueMenu = true,   -- the camp's view shows at Jeem's "Take them in" / "Send them away"
} }
K.UI.KEYS = { "campLogKeep", "scoutMarks", "scoutMarkDays", "voteCueMenu" }
local function setting(key)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[key] end -- (not "and ... or": a false setting must stay false)
    if v == nil then
        for _, mod in ipairs({ ALifeCampVote, ALifeRations, ALifeGrowth, ALifeLieutenant, ALifeGivenKeep, ALifeCampWork, ALifeGateGuard, K.UI }) do
            if type(mod) == "table" and type(mod.DEFAULTS) == "table" and mod.DEFAULTS[key] ~= nil then return mod.DEFAULTS[key] end
        end
    end
    return v
end
K.setting = setting
local function send(player, name, args)
    if player == nil or not fn(ALifeCmd, "send") then return false end
    K.metrics.sent = K.metrics.sent + 1
    return ALifeCmd.send(player, name, args)
end
-- pre-1.0 MP (P4): this file runs where the world is (SP / the server). "You" on the server = the camp's player
-- (Main's M.homePlayer: the player being handled, else the one whose base it is); letters go through ALifeOut.
K.player = function()
    if ALifeSide.mpServer() and fn(M, "homePlayer") then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function letter(text, bad)
    if text == nil or text == "" then return end
    K.metrics.letters = K.metrics.letters + 1
    if ALifeSide.mpServer() then
        if type(ALifeOut) == "table" then ALifeOut.letter(ALifeSide.cur, text, nil, nil, nil, bad) end
        return
    end
    local p = K.player()
    if type(ALifeLetter) == "function" then pcall(ALifeLetter, p, text, nil, nil, nil, bad) else log(text) end
end

-- ---------------------------------------------------------------------------------------------- settings (load time)
do
    local mods = { ALifeCampVote, ALifeRations, ALifeGrowth, ALifeLieutenant, ALifeGivenKeep, ALifeCampWork, ALifeGateGuard, K.UI, ALifeOut, ALifeSettingsNet }
    if type(M.settings) == "table" then
        for _, mod in ipairs(mods) do
            if type(mod) == "table" and type(mod.DEFAULTS) == "table" then
                for k, v in pairs(mod.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
            end
        end
    end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for _, mod in ipairs(mods) do
            for _, k in ipairs(type(mod) == "table" and mod.KEYS or {}) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
        end
    end
    K.ROWS = {
        { "campVote", "Camp: your people have a say in who gets in (and you feel it when you go against them)" },
        { "voteLoseCost", "Camp: how much someone who cared likes you less when you go against them", { 2, 4, 8 } },
        { "voteWinGain", "Camp: how much more when you go with them", { 0, 2, 4 } },
        { "voteFoodDays", "Camp: days of food left below which newcomers worry people", { 1, 3, 7 } },
        { "voteCareAt", "Camp: how strongly someone must feel to hold your choice against you", { 8, 15, 30 } },
        { "voteExile", "Camp: your people have a say when you send someone away (and remember it)" },
        { "voteLead", "Camp: your people have a say in who you leave in charge (and remember it)" },
        { "rations", "Camp: you can put the camp on short or half rations" },
        { "rationShort", "Camp: share of a meal on short rations (0-100)", { 60, 75, 90 } },
        { "rationHalf", "Camp: share of a meal on half rations (0-100)", { 30, 50, 60 } },
        { "growth", "Camp: people get better at their camp job over time" },
        { "growDays", "Camp: days of practice per skill level (times the level)", { 3, 6, 10 } },
        { "roleGrowMax", "Camp: how much better (%) someone gets at their role with time in it", { 20, 40, 60 } },
        { "roleSeasonDays", "Camp: days in a role to get that good", { 30, 90, 180 } },
        { "teachBoost", "Camp: % faster training at a Jeem base with a teacher", { 25, 50, 100 } },
        { "scoutReach", "Camp: tiles a scout looks around", { 150, 300, 600 } },
        { "scoutReport", "Camp: scouts report once a day" },
        { "lieutenants", "Camp: you can leave someone in charge while you're away" },
        { "ltAwayTiles", "Camp: you count as away this far from the base (tiles)", { 80, 150, 300 } },
        { "ltAwayHours", "Camp: hours away before your lieutenant starts deciding", { 2, 6, 24 } },
        { "ltDoor", "Camp: your lieutenant answers people at the door while you're away" },
        { "ltFood", "Camp: your lieutenant sets rations while you're away" },
        { "ltPassedCost", "Camp: how much less someone sworn to you likes you when passed over for first", { 5, 10, 20 } },
        { "ltStandCost", "Camp: most it costs to make a lieutenant stand down (who they are and how you get on change it)", { 0, 8, 16 } },
        { "ltStandDays", "Camp: days in charge before standing down stings fully", { 3, 7, 14 } },
        { "voteCueMenu", "Camp: see what your people think when you answer people at the door (right-click)" },
        { "campLogKeep", "Camp: camp reports kept on the camp board and in the journal", { 10, 20, 40 } },
        { "scoutMarks", "Camp: scouts' sightings go on your map, roughly" },
        { "scoutMarkDays", "Camp: days before a scout's mark comes off your map", { 1, 3, 7 } },
        { "campWork", "Camp: tell your base's people what job or watch to take (Jeem's jobs: wood, planks, branches, twigs, stones, sorting, farming)" },
        { "gateGuard", "Camp: you can put someone on the gate; they meet people at the door and tell you (radio when you're away)" },
        { "gateTurnHostile", "Camp: the gate guard sends off people who run with your enemies without asking" },
        { "gateWaitH", "Camp: hours the gate guard waits for your answer before deciding (0 = never)", { 0, 4, 12 } },
        { "gateSpyChance", "Camp: % the gate guard notices a would-be plant at the door", { 25, 50, 80 } },
        { "ledgeGuard", "People stop at an open edge on upper floors and platforms instead of stepping off and breaking a leg" },
        { "ledgeLookTiles", "Ledge guard: how far ahead (tiles) they look for an edge", { 0.5, 1, 2 } },
        { "ledgeCheckMs", "Ledge guard: how often (ms) it looks; lower is safer but costs more", { 50, 150, 500 } },
        { "givenStays", "What you hand someone stays on their body when they die (not thinned like their own loot)" },
        { "offerMatch", "Offering food, a gun, ammo or medicine only hands over that kind from your hands (not whatever you hold)" },
        { "scoutMarkTiles", "Camp: how rough a scout's mark is (tiles)", { 25, 50, 100 } },
    }
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(K.ROWS) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Your camp and base" end
        end
    end
end

-- ---------------------------------------------------------------------------------------------- new roles
K.NEW_ROLES = {
    scout = { label = "Scout", bg = { hunter = 1, sf = 1, lookout_bg = 1, trooper = 0.7, prepper = 0.7, deserter_bg = 0.6, fisher = 0.4, trucker = 0.4 },
        lens = { brave = 0.4, curious = 0.5, paranoid = 0.3, fearful = -0.6 },
        words = "you're our scout|you are our scout|be our scout|scout around for us|keep an eye on the area|you're the scout",
        lines = { good = "I'll go take a look around. Nobody sees me unless I want them to.", ok = "I'll have a look around each day.",
            poor = "Me, sneaking around out there? ...Okay.", refuse = "Out there alone? No way." } },
    mechanic = { label = "Mechanic", bg = { mechanic = 1, trucker = 0.7, factory = 0.6, lineman = 0.5, scrapper = 0.6, tanker = 0.6, dad = 0.4, grandpa = 0.4 },
        lens = { disciplined = 0.4, curious = 0.4, calm = 0.2, volatile = -0.3 },
        words = "you're our mechanic|you are our mechanic|be our mechanic|look after the cars|keep the cars running|you're the mechanic",
        lines = { good = "Engines I know. Leave it to me.", ok = "I'll keep them running if I can.",
            poor = "I can find the hood latch. That's about it. But okay.", refuse = "I don't touch engines. Find someone else." } },
    teacher = { label = "Teacher", bg = { chaplain = 0.8, doctor = 0.6, nurse = 0.5, officer_mil = 0.7, nco = 0.8, granny = 0.6, grandpa = 0.6, detective = 0.4 },
        lens = { kind = 0.4, calm = 0.4, disciplined = 0.3, volatile = -0.4, mean = -0.3 },
        words = "you're our teacher|you are our teacher|be our teacher|teach the others|train the others|you're the teacher",
        lines = { good = "I can teach. Send them to me.", ok = "I'll show them what I know.",
            poor = "I'm not much of a teacher. I'll try.", refuse = "I don't have the patience. No." } },
}
function K.addRoles()
    if K.rolesAdded or type(M.cpRoles) ~= "table" or not fn(M, "cpSetRole") then return false end
    for id, def in pairs(K.NEW_ROLES) do
        local have = false
        for _, r in ipairs(M.cpRoles) do if r.id == id then have = true end end
        if not have then table.insert(M.cpRoles, { id = id, label = def.label }) end
        if type(M.cpRoleLabel) == "table" then M.cpRoleLabel[id] = def.label end
        if type(M.cpRoleBg) == "table" then M.cpRoleBg[id] = def.bg end
        if type(M.cpRoleLens) == "table" then M.cpRoleLens[id] = def.lens end
        if type(M.cpIntents) == "table" then table.insert(M.cpIntents, { id = "CAMP_ROLE_" .. string.upper(id), kind = "role_" .. id, patterns = def.words }) end
    end
    local baseSet = M.cpSetRole
    M.cpSetRole = function(uid, role, player)
        local line, took = baseSet(uid, role, player)
        -- time in a role: stamped when it changes
        if took ~= false then
            pcall(function()
                local d = M.cpData()
                d.roleSince = type(d.roleSince) == "table" and d.roleSince or {}
                if role == "general" then d.roleSince[tostring(uid)] = nil
                else d.roleSince[tostring(uid)] = { r = role, h = hours() } end
            end)
            K.dirty = true
        end
        local def = K.NEW_ROLES[role]
        if def == nil then return line, took end
        if took == false then return def.lines.refuse, false end
        local f = M.cpFit(uid, role)
        return (f >= 1.2 and def.lines.good) or (f >= 0.8 and def.lines.ok) or def.lines.poor, took
    end
    -- better with time in the role (on top of who they were and who they are)
    local baseFit = M.cpFit
    M.cpFit = function(uid, role)
        local f = baseFit(uid, role)
        if role == "general" or setting("growth") == false then return f end
        return f * (1 + K.grown(uid, role))
    end
    K.rolesAdded = true
    return true
end
-- 0 .. roleGrowMax/100, by days in this role
function K.grown(uid, role)
    local d = nil
    pcall(function() d = M.cpData() end)
    local since = type(d) == "table" and type(d.roleSince) == "table" and d.roleSince[tostring(uid)] or nil
    if type(since) ~= "table" or since.r ~= role then return 0 end
    local days = math.max(0, (hours() - (tonumber(since.h) or hours())) / 24)
    local max = (tonumber(setting("roleGrowMax")) or 40) / 100
    local season = math.max(1, tonumber(setting("roleSeasonDays")) or 90)
    return math.min(max, max * days / season)
end
pcall(K.addRoles)

-- the roles go to the server (ALifeGrowth: practice, teacher, scout)
function K.syncRoles(player)
    if player == nil or setting("growth") == false then return false end
    local d = nil
    pcall(function() d = M.cpData() end)
    if type(d) ~= "table" or type(d.roles) ~= "table" then return false end
    local out, n = {}, 0
    for uid, role in pairs(d.roles) do
        if type(role) == "string" and role ~= "general" and n < 40 then out[tostring(uid)] = role; n = n + 1 end
    end
    K.dirty = false
    return send(player, "campRoles", { roles = out })
end

-- ---------------------------------------------------------------------------------------------- rations and lieutenants by word
K.defs = K.defs or {} -- pre-1.0 MP: every camp command by id (the server looks them up for a forwarded command)
local function cmd(def) K.defs[def.id] = def; if type(ALifeCommands) == "table" and type(ALifeCommands.CMDS) == "table" and ALifeCommands.byId[def.id] == nil then
    table.insert(ALifeCommands.CMDS, #ALifeCommands.CMDS, def); ALifeCommands.byId[def.id] = def end end
if type(ALifeCommands) == "table" and type(ALifeCommands.GROUPS) == "table" then
    local have = false
    for _, g in ipairs(ALifeCommands.GROUPS) do if g == "Your camp" then have = true end end
    if not have then table.insert(ALifeCommands.GROUPS, "Your camp") end
end
cmd({ id = "rations_full", group = "Your camp", client = true, camp = "ration", level = "full", label = "full rations",
    words = { "full rations", "everyone eats", "back to full rations", "eat as much as you need" },
    say = { "Full rations." }, what = "Everyone at the base eats a full share. Needs a Jeem base you run." })
cmd({ id = "rations_short", group = "Your camp", client = true, camp = "ration", level = "short", label = "short rations",
    words = { "short rations", "cut the rations", "eat a bit less", "go easy on the food" },
    say = { "Short rations from now on." }, what = "Three quarters of a meal each. The food lasts longer; everyone's a bit hungrier." })
cmd({ id = "rations_half", group = "Your camp", client = true, camp = "ration", level = "half", label = "half rations",
    words = { "half rations", "half the food", "we eat half", "everyone on half" },
    say = { "Half rations." }, what = "Half a meal each. The food lasts twice as long; everyone goes hungry." })
cmd({ id = "rations_guards", group = "Your camp", client = true, camp = "ration", level = "guards", label = "guards eat first",
    words = { "guards eat first", "feed the guards first", "the watch eats first", "whoever's on watch eats" },
    say = { "Whoever's on watch eats first." }, what = "Whoever's on watch eats full, everyone else half." })
cmd({ id = "make_lt", group = "Your camp", client = true, mine = true, camp = "lt", rank = 1, label = "you're in charge",
    words = { "you're in charge while i'm gone", "youre in charge while im gone", "you're in charge when i'm away", "you're my second in command",
        "you're my lieutenant", "you run things while i'm gone", "you're in charge" },
    say = { "You're in charge while I'm gone." }, what = "They run the base while you're away (people at the door, the food) and tell you when you're back." })
cmd({ id = "make_lt2", group = "Your camp", client = true, mine = true, camp = "lt", rank = 2, label = "you're next in line",
    words = { "you're next in line", "youre next in line", "you're second in line", "if they're gone you're in charge", "you're my second lieutenant" },
    say = { "You're next in line." }, what = "They take over if your first lieutenant isn't there." })
cmd({ id = "stand_down", group = "Your camp", client = true, mine = true, camp = "standdown", label = "stand down",
    words = { "stand down", "you're not in charge any more", "youre not in charge any more", "you're not in charge anymore", "youre not in charge anymore",
        "step down", "i'm taking you off", "you're relieved", "you're done running things" },
    say = { "Stand down. You're not in charge any more." }, what = "They stop running the base while you're away. How they take it depends on who they are, how long they had it and how you two get on." })

-- 0.8.8: CAMP WORK BY WORD. Said to one of your base's people (the one you're talking to): a Jeem job or a watch.
-- The server (ALifeCampWork) goes through Jeem's own Manage.setJob / setShift; they answer yes, or why not.
K.WORK = {
    { id = "work_wood", job = "woodcutter", label = "go chop wood", words = { "chop wood", "chop some wood", "cut some trees", "go cut wood", "you're on wood", "fell some trees" },
        say = { "Go chop some wood." }, yes = { "Axe and a tree. On it.", "I'll bring logs back." } },
    { id = "work_planks", job = "carpenter", label = "make planks", words = { "make planks", "saw planks", "saw some planks", "turn the logs into planks", "you're on planks" },
        say = { "Saw the logs into planks." }, yes = { "Planks. Got it.", "I'll get sawing." } },
    { id = "work_branches", job = "branches", label = "gather branches", words = { "gather branches", "get some branches", "collect branches", "pick up branches" },
        say = { "Gather some branches." }, yes = { "Branches. Easy enough." } },
    { id = "work_twigs", job = "twigs", label = "gather twigs", words = { "gather twigs", "get some twigs", "collect twigs", "get kindling", "gather kindling" },
        say = { "Get us some twigs." }, yes = { "Kindling. Sure." } },
    { id = "work_stones", job = "stones", label = "gather stones", words = { "gather stones", "collect stones", "get some stones", "find some rocks" },
        say = { "Gather some stones." }, yes = { "Rocks. Fine." } },
    { id = "work_sort", job = "quartermaster", label = "sort the stores", words = { "sort the stores", "sort the drop box", "sort the supplies", "you're quartermaster", "you're our quartermaster", "keep the stores sorted" },
        say = { "Keep the stores sorted." }, yes = { "Everything in its place. I'll do it.", "I'll sort it." } },
    { id = "work_farm", job = "farmer", label = "tend the crops", words = { "tend the crops", "work the farm", "look after the crops", "water the plants", "you're on the farm", "tend the garden" },
        say = { "Look after the crops." }, yes = { "I'll keep them alive.", "Farm it is." } },
    { id = "work_none", job = "none", label = "drop the job", words = { "drop the job", "you're off that job", "stop that job", "no more work for now", "back to guard duty" },
        say = { "Drop that job." }, yes = { "Fine by me.", "Alright." } },
    { id = "watch_day", shift = "day", label = "take the day watch", words = { "take the day watch", "you're on days", "watch during the day", "day shift" },
        say = { "You take the day watch." }, yes = { "Days. Good.", "I'll keep an eye out." } },
    { id = "watch_evening", shift = "evening", label = "take the evening watch", words = { "take the evening watch", "you're on evenings", "evening shift" },
        say = { "You take the evening watch." }, yes = { "Evenings. Alright." } },
    { id = "watch_night", shift = "night", label = "take the night watch", words = { "take the night watch", "you're on nights", "watch at night", "night shift" },
        say = { "You take the night watch." }, yes = { "Nights. I'll stay sharp.", "Fine. Coffee, if we have any." } },
    { id = "watch_auto", shift = "auto", label = "off the watch", words = { "off the watch", "you're off watch", "no watch for you", "let the roster decide" },
        say = { "You're off the watch." }, yes = { "Finally some sleep." } },
}
K.WORK_WHY = {
    no_material_store = "We've got nowhere to put it. Mark a materials store first.",
    no_woodlot = "Chop where? Mark a woodlot first.",
    no_dropbox = "There's no drop box to sort. Mark one.",
    no_food_store = "No food store marked. Where does it all go?",
    not_resident = "I don't live at your base.",
    not_yours = "You don't run this place.",
    moving = "Give me a minute, I'm in the middle of something.",
    routines_off = "Can't right now.",
    unknown_shift = "Which watch?",
    nojeem = "We don't have that kind of set-up here.",
    off = nil,
}
K.workById = {}
for _, w in ipairs(K.WORK) do
    K.workById[w.id] = w
    cmd({ id = w.id, group = "Your camp", client = true, camp = "work", job = w.job, shift = w.shift, label = w.label, words = w.words, say = w.say,
        what = w.job and "Jeem's job at your base: needs what the job needs (stores, a woodlot)." or "Their watch at your base." })
end
function K.work(player, c, uid)
    if player == nil or uid == nil or setting("campWork") == false then return false end
    K.pendingWork = K.pendingWork or {}
    K.pendingWork[tostring(uid)] = c.id
    return send(player, "campWork", { uid = tostring(uid), job = c.job, shift = c.shift })
end
function K.onWorkDone(p)
    if type(p) ~= "table" or p.uid == nil then return end
    local id = K.pendingWork and K.pendingWork[tostring(p.uid)] or nil
    if K.pendingWork then K.pendingWork[tostring(p.uid)] = nil end
    local w = id and K.workById[id] or nil
    local line
    if p.ok then
        local list = w and w.yes or { "Alright." }
        line = list[(math.floor(hours()) % #list) + 1]
    else
        line = K.WORK_WHY[tostring(p.why)]
        if line == nil and p.why ~= "off" then line = "Can't do that here." end
    end
    if line == nil then return end
    local sh = nil
    pcall(function() sh = PA().Talk.shellFor(tostring(p.uid)) end)
    if sh ~= nil and fn(M, "say") then pcall(M.say, sh, K.player(), line, { record = rec(p.uid) })
    else letter(first(p.uid) .. ": \"" .. line .. "\"", not p.ok) end
end

-- 0.8.8: THE GATE GUARD (server: ALifeGateGuard). "You're on the gate" to one of your base's people.
cmd({ id = "gate_on", group = "Your camp", client = true, camp = "gate", label = "you're on the gate",
    words = { "you're on the gate", "youre on the gate", "watch the gate", "guard the gate", "you're our gatekeeper", "you decide who comes in", "mind the gate" },
    say = { "You're on the gate." }, what = "They meet people who come to your door, send off anyone who runs with your enemies, and tell you about the rest (by radio when you're away)." })
cmd({ id = "gate_off", group = "Your camp", client = true, camp = "gateoff", label = "off the gate",
    words = { "off the gate", "you're off the gate", "youre off the gate", "someone else takes the gate" },
    say = { "You're off the gate." }, what = "They stop watching the gate." })
K.GATE_LINES = { on = { "Nobody gets in without me looking at them first.", "Gate's mine. I'll let you know who shows up." },
    off = { "Fine. Someone else can stand out there." }, notOn = { "I wasn't on the gate." } }
function K.gate(player, uid, off)
    if player == nil or uid == nil or setting("gateGuard") == false then return false end
    return send(player, "gateSet", { uid = tostring(uid), off = off == true or nil })
end
local function speak(uid, line)
    local sh = nil
    pcall(function() sh = PA().Talk.shellFor(tostring(uid)) end)
    if sh ~= nil and fn(M, "say") then pcall(M.say, sh, K.player(), line, { record = rec(uid) }); return true end
    return false
end
function K.onGateSet(p)
    if type(p) ~= "table" or p.uid == nil then return end
    local line
    if p.ok then
        local list = p.off and K.GATE_LINES.off or K.GATE_LINES.on
        line = list[(math.floor(hours()) % #list) + 1]
        if not p.off and fn(M, "keyMem") then pcall(M.keyMem, p.uid, "trust", "Put on the gate: decides who gets near the camp") end
        if p.was ~= nil and fn(M, "keyMem") then pcall(M.keyMem, p.was, "insult", "Taken off the gate for " .. first(p.uid)) end
    elseif p.why == "not_on_gate" then line = K.GATE_LINES.notOn[1]
    else line = K.WORK_WHY[tostring(p.why)] end
    if line ~= nil and not speak(p.uid, line) then letter(first(p.uid) .. ": \"" .. line .. "\"", not p.ok) end
end
-- a would-be plant (0.7.14 saboteur) among them: the same roll ALifeSaboteur.consider makes when they join, so the guard
-- only ever suspects someone who really would be one. Noticed at gateSpyChance %.
function K.spyAmong(uids, guardUid)
    local S = ALifeSaboteur
    if not fn(S, "openGrudge") or not fn(S, "enabled") or not S.enabled() or type(S.cfg) ~= "table" then return nil end
    local g = nil
    pcall(function() g = S.openGrudge() end)
    if g == nil then return nil end
    if fn(S, "planted") and S.planted() ~= nil then return nil end -- (one plant at a time: consider() would skip them)
    local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
    for _, u in ipairs(uids) do
        if (hash(u .. "#plant#" .. tostring(g.id)) % 10000) / 10000 < (tonumber(S.cfg.chance) or 0) then
            local seen = (hash(u .. "#gate#" .. tostring(guardUid)) % 100) < (tonumber(setting("gateSpyChance")) or 50)
            if seen then return u end
            return nil
        end
    end
    return nil
end
function K.onGateReport(p)
    if type(p) ~= "table" or type(p.text) ~= "string" then return end
    if p.how == "radio" then
        local h = type(ALifeTalkWalkie) == "table" and ALifeTalkWalkie.lastHeard or nil
        if type(h) ~= "table" or h.kind ~= "gate" or h.heard ~= true then return end -- (the call didn't reach you)
    end
    local text = p.text
    if p.kind == "door" and type(p.uids) == "string" then
        local uids = {}
        for u in string.gmatch(p.uids, "[^,]+") do uids[#uids + 1] = u end
        local spy = K.spyAmong(uids, p.uid)
        if spy ~= nil then text = text .. " And " .. first(spy) .. " asks too many questions about how many of us there are. I don't like it." end
    end
    if p.how ~= "radio" then letter(tostring(p.who or "The gate") .. ": " .. text, p.kind == "turned")
    elseif text ~= p.text and type(ALifeTalkWalkie) == "table" and fn(ALifeTalkWalkie, "line") then
        pcall(ALifeTalkWalkie.line, "[Radio] " .. string.sub(text, #p.text + 2))
    end
    if fn(K, "logAdd") then pcall(K.logAdd, "gate", p.who, tostring(p.who or "The gate") .. ": " .. text) end
end
-- people let in through Jeem's door are new to the base: the saboteur's join check, as for Settle and the party
function K.onJoined(p)
    if type(p) ~= "table" or type(p.uids) ~= "string" then return end
    local S = ALifeSaboteur
    if not fn(S, "consider") then return end
    for u in string.gmatch(p.uids, "[^,]+") do pcall(S.consider, u, K.player()) end
end

function K.command(player, c, uid)
    -- pre-1.0 MP: lieutenants / stand down need the world (opinions, who's sworn): on an MP client they run on the
    -- server as this player (M.settleCommand, exposed; only once the forwarder is in). Work, gate and rations already
    -- go to the server modules by ALifeCmd, as since 0.8.8.
    if ALifeSide.mpClient() and type(c) == "table" and c.id ~= nil and (c.camp == "lt" or c.camp == "standdown")
        and type(ALifeRemote) == "table" and ALifeRemote.wrapped.settleCommand ~= nil and ALifeRemote.wrapped.settleCommand == M.settleCommand then
        return M.settleCommand(tostring(c.id), uid ~= nil and tostring(uid) or nil, player)
    end
    if c.camp == "work" then return K.work(player, c, uid) end
    if c.camp == "gate" then return K.gate(player, uid, false) end
    if c.camp == "gateoff" then return K.gate(player, uid, true) end
    if c.camp == "ration" then return send(player, "rationSet", { level = c.level }) end
    if c.camp == "lt" then return K.setLt(player, uid, c.rank) end
    if c.camp == "standdown" then return K.standDown(player, uid) end
    return false
end

-- server side of a forwarded camp command (and SP: the same call): only the camp commands this file registered
function M.settleCommand(cid, uid, player)
    local c = K.defs[tostring(cid)]
    if type(c) ~= "table" or c.camp == nil or player == nil then return false end
    return K.command(player, c, uid ~= nil and tostring(uid) or nil)
end
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then ALifeRemote.expose("settleCommand", 2, 3) end
K.LT_LINES = { [1] = { "I'll keep the place standing. My way.", "Go. I've got it.", "Alright. Nobody burns it down while you're gone." },
    [2] = { "If it comes to that, I'll be ready.", "Second. Got it." } }
function K.ltData()
    local b = nil
    pcall(function() b = M.bucket("lieutenants") end)
    if type(b) ~= "table" then K.tmp = K.tmp or {}; b = K.tmp end
    b.lts = type(b.lts) == "table" and b.lts or {}
    b.passed = type(b.passed) == "table" and b.passed or {}
    b.wants = type(b.wants) == "table" and b.wants or {}
    b.since = type(b.since) == "table" and b.since or {} -- [uid] = hour named (either rank)
    b.ran = type(b.ran) == "table" and b.ran or {}       -- [uid] = true once they ran the camp while you were away
    return b
end
local function sworn()
    local s = nil
    if fn(ALifeOathWatch, "store") then pcall(function() s = ALifeOathWatch.store() end) end
    return type(s) == "table" and type(s.sworn) == "table" and s.sworn or {}
end
local function opinion(uid, player, d, why)
    local O = PA().NpcOpinion
    local r = rec(uid)
    if r ~= nil and fn(O, "adjust") then pcall(O.adjust, r, player, d, why) end
end
function K.setLt(player, uid, rank)
    if player == nil or uid == nil or setting("lieutenants") == false then return false end
    uid = tostring(uid)
    local b = K.ltData()
    local lts = {}
    for _, u in ipairs(b.lts) do if u ~= uid then lts[#lts + 1] = u end end
    rank = math.max(1, math.min(2, tonumber(rank) or 1))
    table.insert(lts, math.min(rank, #lts + 1), uid)
    while #lts > 2 do table.remove(lts) end
    b.lts = lts
    if lts[1] == uid then b.since1 = hours() end
    if b.since[uid] == nil then b.since[uid] = hours() end
    K.pruneSince(b)
    K.metrics.lts = K.metrics.lts + 1
    send(player, "ltSet", { uids = table.concat(lts, ",") })
    if fn(K, "askStatus") then pcall(K.askStatus, player, true) end
    local list = K.LT_LINES[rank]
    if fn(M, "say") then
        local sh = nil
        pcall(function() sh = PA().Talk.shellFor(uid) end)
        if sh ~= nil then pcall(M.say, sh, player, list[(math.floor(hours()) % #list) + 1], { record = rec(uid) }) end
    end
    if fn(M, "keyMem") then pcall(M.keyMem, uid, "trust", rank == 1 and "Left in charge of the camp when the newcomer is away" or "Next in line to run the camp") end
    -- passed over: someone sworn to you who isn't the 1st
    if rank == 1 then
        for s in pairs(sworn()) do
            s = tostring(s)
            local r = rec(s)
            if s ~= uid and r ~= nil and r.lifecycle ~= "dead" and b.passed[s] ~= uid then
                b.passed[s] = uid
                K.metrics.passed = K.metrics.passed + 1
                opinion(s, player, -(tonumber(setting("ltPassedCost")) or 10), "You passed them over and put " .. first(uid) .. " in charge.")
                if fn(M, "feel") then pcall(M.feel, s, "resentment", 0.5, "passed over for " .. first(uid)) end
                if fn(M, "keyMem") then pcall(M.keyMem, s, "betrayal", "Swore an oath, and still got passed over for " .. first(uid)) end
                if fn(M, "pairBump") then pcall(M.pairBump, s, uid, -20, "got the job they should have had") end
            end
        end
    end
    return true
end
-- (collected first, then cleared: no clearing a table while walking it)
function K.pruneSince(b)
    local drop = {}
    for u in pairs(b.since) do
        local keep = false
        for _, x in ipairs(b.lts) do if x == u then keep = true end end
        if not keep then drop[#drop + 1] = u end
    end
    for _, u in ipairs(drop) do b.since[u] = nil; b.ran[u] = nil end
end

-- 0.8.8 UI: STAND DOWN. What it costs depends on who they are, how long they had it, what they did with it and how
-- the two of you get on. Returns cost (opinion points, 0 = takes it fine), tone ("rest", "fine", "stung", "bitter").
K.STAND_TEMPER = { predator = 0.4, veteran = 0.4, seasoned = 0, fresh = -0.2 }
function K.standCost(uid, player)
    uid = tostring(uid)
    local b = K.ltData()
    local most = tonumber(setting("ltStandCost")) or 8
    if most <= 0 then return 0, "fine" end
    local rank = nil
    for i, u in ipairs(b.lts) do if u == uid then rank = i end end
    if rank == nil then return 0, "fine" end
    -- how long they had it (a day: hardly; ltStandDays: fully; longer: a bit more)
    local since = tonumber(b.since[uid]) or (rank == 1 and tonumber(b.since1)) or hours()
    local days = math.max(0, (hours() - since) / 24)
    local f = math.min(1.5, days / math.max(1, tonumber(setting("ltStandDays")) or 7))
    if rank > 1 then f = f * 0.6 end -- next in line never ran it day to day
    -- who they are: proud and quick-tempered take it hard, calm and kind let it go
    local lens = {}
    if fn(M, "lens") then pcall(function() lens = M.lens(uid) or {} end) end
    local function l(k) return tonumber(lens[k]) or 0 end
    local p = 1 + 0.6 * l("volatile") + 0.5 * l("mean") + 0.3 * l("disciplined") + 0.3 * l("paranoid") - 0.5 * l("calm") - 0.4 * l("kind")
    local temper = nil
    pcall(function() temper = PA().Speech.contextFor(rec(uid), nil).temperament end)
    p = p + (K.STAND_TEMPER[temper or ""] or 0)
    p = math.max(0.2, math.min(2.5, p))
    -- how you get on (A-Life's NpcOpinion, -100..100): trust softens it, a grudge sharpens it
    local rel = 1
    local O = PA().NpcOpinion
    if fn(O, "valueOf") and player ~= nil then
        local ok, v = pcall(O.valueOf, rec(uid), player)
        if ok and tonumber(v) then rel = 1 - 0.5 * math.max(-100, math.min(100, tonumber(v))) / 100 end
    end
    -- what happened: sworn to you stings more; they ran it for you while you were gone, more; hurt / bitten / grieving,
    -- they understand you're giving them the rest
    local ctx, tone = 1, nil
    for s in pairs(sworn()) do if tostring(s) == uid then ctx = ctx * 1.3 end end
    if b.ran[uid] then ctx = ctx * 1.25 end
    local notes = {}
    if fn(M, "bdNotes") then pcall(function() notes = M.bdNotes(uid, player) or {} end) end
    for _, n in ipairs(notes) do
        if n == "bitten" or string.find(n, "^bitten") or n == "hurt" or n == "bleeding" or n == "broken bone" or string.find(n, "^grieving") then ctx = ctx * 0.3; tone = "rest" end
    end
    local cost = math.floor(most * f * p * rel * ctx + 0.5)
    if tone == nil then tone = cost <= 1 and "fine" or (cost < most and "stung" or "bitter") end
    return cost, tone
end
K.STAND_LINES = {
    rest = { "Yeah. I need the rest anyway.", "Fair. I'm in no shape for it." },
    fine = { "Fine by me.", "Alright. Less to worry about.", "Sure. Your call." },
    stung = { "If that's how you want it.", "...Right. Fine.", "Okay. I thought I was doing alright." },
    bitter = { "After everything I did for this place? Fine.", "Got it. Wasn't good enough for you.", "Don't come asking when it falls apart." },
}
function K.standDown(player, uid)
    if player == nil or uid == nil or setting("lieutenants") == false then return false end
    uid = tostring(uid)
    local b = K.ltData()
    local was = nil
    for i, u in ipairs(b.lts) do if u == uid then was = i end end
    local sh = nil
    pcall(function() sh = PA().Talk.shellFor(uid) end)
    local function say(line) if sh ~= nil and fn(M, "say") then pcall(M.say, sh, player, line, { record = rec(uid) }) end end
    if was == nil then say("I wasn't running anything."); return false end
    local cost, tone = K.standCost(uid, player)
    local lts = {}
    for _, u in ipairs(b.lts) do if u ~= uid then lts[#lts + 1] = u end end
    b.lts = lts
    if was == 1 then b.since1 = lts[1] ~= nil and hours() or nil end
    K.pruneSince(b)
    K.metrics.stood = (K.metrics.stood or 0) + 1
    send(player, "ltSet", { uids = table.concat(lts, ",") })
    local list = K.STAND_LINES[tone] or K.STAND_LINES.fine
    say(list[(math.floor(hours()) % #list) + 1])
    if cost > 0 then opinion(uid, player, -cost, "You took them off running the camp.") end
    if tone == "bitter" then
        if fn(M, "feel") then pcall(M.feel, uid, "resentment", 0.4, "taken off running the camp") end
        if fn(M, "keyMem") then pcall(M.keyMem, uid, "betrayal", "Ran the camp for the newcomer, then got pushed aside") end
    elseif tone == "stung" and fn(M, "keyMem") then pcall(M.keyMem, uid, "insult", "Taken off running the camp")
    elseif tone == "rest" and fn(M, "keyMem") then pcall(M.keyMem, uid, "kindness", "Let off running the camp while they got over it") end
    if was == 1 and lts[1] ~= nil then letter(first(lts[1]) .. " runs things while you're away now.") end
    if fn(K, "askStatus") then pcall(K.askStatus, player, true) end
    return true, cost, tone
end

-- someone who swore after you picked a 1st wants the job, and turns rival to whoever has it
function K.checkRivals(player)
    local b = K.ltData()
    local lt1 = b.lts[1]
    if lt1 == nil or b.since1 == nil then return 0 end
    local n = 0
    for s, row in pairs(sworn()) do
        s = tostring(s)
        local h = type(row) == "table" and tonumber(row.h) or nil
        if s ~= lt1 and h ~= nil and h > b.since1 and b.wants[s] ~= lt1 and b.passed[s] ~= lt1 then
            b.wants[s] = lt1
            n = n + 1
            K.metrics.rivals = K.metrics.rivals + 1
            if fn(M, "pairBump") then pcall(M.pairBump, s, lt1, -25, "wants to be first, and " .. first(lt1) .. " is in the way") end
            if fn(M, "keyMem") then pcall(M.keyMem, s, "ambition", "Swore to the newcomer and wants to be their first, not " .. first(lt1)) end
            if fn(M, "keyMem") then pcall(M.keyMem, lt1, "rivalry", first(s) .. " wants your place") end
        end
    end
    return n
end
function K.lieutenants() return K.ltData().lts end

-- ---------------------------------------------------------------------------------------------- what the server says
-- 0.8.8 UI: everything worth keeping also goes in the camp log (ALifeTalk_SettlementUI: camp board, journal, map)
local function keep(kind, who, text, extra)
    if fn(K, "logAdd") then pcall(K.logAdd, kind, who, text, extra) end
end
if fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("campVote", function(p) if type(p) == "table" then letter(p.text); keep("door", nil, p.text) end end)
    ALifeCmd.onClient("campReport", function(p)
        if type(p) ~= "table" then return end
        letter(p.text)
        keep(p.kind or "report", p.who, p.text)
        if p.kind == "scout" and type(p.marks) == "table" and fn(K, "marksAdd") then pcall(K.marksAdd, p.marks, p.who) end
    end)
    ALifeCmd.onClient("rationSet", function(p)
        if type(p) ~= "table" then return end
        if p.ok then letter(p.text); if fn(K, "askStatus") then pcall(K.askStatus, K.player(), true) end
        elseif p.why == "nobase" then letter("You need to be at a base you run (marked in the Bases menu).", true)
        elseif p.why == "notyours" then letter("That's not your base to ration.", true) end
    end)
    ALifeCmd.onClient("ltReport", function(p)
        if type(p) ~= "table" or type(p.lines) ~= "table" then return end
        local lines = {}
        for i = 1, 12 do if type(p.lines[i]) == "string" then lines[#lines + 1] = p.lines[i] end end
        if #lines == 0 then return end
        letter(tostring(p.who or "Your lieutenant") .. " fills you in: " .. lines[1] .. ".")
        for i = 2, #lines do letter("Also: " .. lines[i] .. ".") end
        for i = 1, #lines do keep("lt", p.who, tostring(p.who or "Your lieutenant") .. " " .. lines[i] .. ".") end
        if p.uid then K.ltData().ran[tostring(p.uid)] = true end
        if fn(M, "keyMem") and p.uid then pcall(M.keyMem, p.uid, "trust", "Ran the camp while the newcomer was away") end
    end)
    -- answers the screens asked for (ALifeTalk_SettlementUI)
    ALifeCmd.onClient("campVoteCue", function(p) if type(p) == "table" and fn(K, "onVoteCue") then K.onVoteCue(p) end end)
    ALifeCmd.onClient("campWorkDone", function(p) K.onWorkDone(p) end)
    ALifeCmd.onClient("gateSetDone", function(p) K.onGateSet(p) end)
    ALifeCmd.onClient("gateReport", function(p) K.onGateReport(p) end)
    ALifeCmd.onClient("campJoined", function(p) K.onJoined(p) end)
    ALifeCmd.onClient("campStatus", function(p) if type(p) == "table" and fn(K, "onStatus") then K.onStatus(p) end end)
end

-- ---------------------------------------------------------------------------------------------- hooks
function K.hook()
    K.hooked = K.hooked or {}
    if not K.hooked.settle and fn(M, "settleApply") then
        local orig = M.settleApply
        M.settleApply = function(l, player, base, bring)
            local ok = orig(l, player, base, bring)
            if ok and not K.offSettle and setting("campVote") ~= false then
                local good, err = pcall(function()
                    local uids = { tostring(l.record.uid) }
                    for _, b in ipairs(bring or {}) do uids[#uids + 1] = tostring(b.uid) end
                    send(player, "campVoteDone", { uids = table.concat(uids, ","), yes = true })
                end)
                if not good then K.offSettle = true; log("settle vote failed, off for this session: " .. tostring(err)) end
            end
            return ok
        end
        K.hooked.settle = true
    end
    return K.hooked.settle == true
end
pcall(K.hook)

if type(Events) == "table" then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            pcall(K.addRoles)
            pcall(K.hook)
            log("ready v" .. K.VERSION .. ": settlement (roles " .. (K.rolesAdded and "+3" or "not added") .. ", settle vote "
                .. ((K.hooked and K.hooked.settle) and "on" or "off") .. ", " .. #K.ROWS .. " settings)")
        end)
    end
    if Events.EveryHours ~= nil then
        Events.EveryHours.Add(function()
            local p = K.player()
            if p == nil then return end
            K.tick = (K.tick or 0) + 1
            if K.dirty or K.tick % 6 == 1 then pcall(K.syncRoles, p) end
            pcall(K.checkRivals, p)
        end)
    end
end
