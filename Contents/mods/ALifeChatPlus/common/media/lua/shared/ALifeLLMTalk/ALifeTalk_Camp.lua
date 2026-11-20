-- A-Life NPC Overhaul 0.5.0: CAMP LIFE.
-- People who live at your base (settlers, Jeem residents at home) get:
--  * CAMP ROLES: General (everyone starts here, no benefits), Cook, Medic, Guard, Builder. You give the role
--    (right-click > Camp > Roles, or say "you're our cook"). How well they do it comes from who they were
--    (A-Life background) and who they are (personality). Some flatly refuse a job they can't stomach.
--      Cook    - a decent meal lifts the whole base (less unrest), only while the base has food.
--      Medic   - patches up hurt housemates with bandages / splints they carry (the patch's own treatment call).
--      Guard   - walks the patrol route and takes the night watch first. A-Life's base duty sees them as a guard.
--      Builder - sorts building materials first when hauling, and the base feels like it's getting somewhere.
--  * MORALE: no number anywhere. It feeds the existing unrest at home (food, danger, clashes, you): roles, losses,
--    and you breaking your own rules move it. Low for too long: they walk out, the volatile turn on you.
--  * CAMP RULES you set ("no killing prisoners", ...). Break your own rule and the people who saw it (or heard
--    about it) think less of you - by who they are.
--  * PATROL: mark up to N points. Guards walk them in order and call out zombies and strangers.
--  * NIGHT WATCH: one person stays up at night and wakes you for a horde (and strangers, by the setting).
--  * HAUL & SORT: mark a collect area and drop points per category (several per category). They carry things over
--    in real trips, nearest drop point with room first; spoiling food goes to fridges/freezers first.
-- Hooks: one A-Life behaviour module (priority 91, after work zones), a 1 s OnTick, the world context menu,
-- ProjectALife_NpcDied, talk intents. A-Life files are untouched.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Camp") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Seeded"
require "ALifeLLMTalk/ALifeLLMTalk_Settlers"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeCamp]"
local VERSION = "0.5.10"

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function rawMs() return (type(getTimestampMs) == "function" and getTimestampMs()) or 0 end
local CLOCK = { t = nil, at = 0 }
local function nowMs() if CLOCK.t == nil then return rawMs() end; return CLOCK.t + (rawMs() - CLOCK.at) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hourOfDay() local h = nil; pcall(function() h = getGameTime():getHour() end); return tonumber(h) or (math.floor(hours()) % 24) end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pickLine(list, seed) return list[(hash(seed) % #list) + 1] end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function sqAt(x, y, z) local s = nil; pcall(function() s = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) end); return s end
local function hasAny(t) if type(t) ~= "table" then return false end; for _ in pairs(t) do return true end; return false end -- Kahlua: no next()
local function isA(o, cls) local ok, v = pcall(function() return instanceof(o, cls) end); return ok and v == true end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function thePlayer() return M.homePlayer and M.homePlayer() or ALifeSide.you() end -- MP: the base's player (Main)
local function shellFor(uid) local t = PA().Talk; return fn(t, "shellFor") and t.shellFor(tostring(uid)) or nil end
local function patch() return M.patch and M.patch() or nil end
-- pre-1.0 MP (P4): the camp is ONE shared co-op camp. World logic runs where the world is (SP / server); "you" for
-- the camp = M.homePlayer (the player whose base it is). An MP client never writes the camp: its menu calls
-- M.cpAct (exposed: runs on the server as the sender) and reads a read-only copy (ALifeRemote share
-- "ALifeChatPlus_CampView": the camp table + who lives there + first names + the base box). SP: unchanged.
local function mpClient() return type(ALifeSide) == "table" and ALifeSide.mpClient() end
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
M.CP_VIEW = "ALifeChatPlus_CampView"
function M.cpView() if type(ALifeRemote) ~= "table" then return nil end; return ALifeRemote.shared(M.CP_VIEW) end
local function cpTouch() if type(ALifeRemote) == "table" and mpServer() then ALifeRemote.touch(M.CP_VIEW) end end
M.cpTouch = cpTouch
local function firstName(uid)
    if mpClient() then
        local v = M.cpView()
        local n = v and type(v.names) == "table" and v.names[tostring(uid)] or nil
        return type(n) == "string" and n or "Someone"
    end
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = r and fn(PA().Names, "of") and PA().Names.of(r) or nil
    return n and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function halo(text, r, g, b)
    if mpServer() then -- MP: to the player being handled (window call / talk), else everyone online
        if type(ALifeOut) == "table" then ALifeOut.note(ALifeSide.cur, tostring(text), r or 230, g or 200, b or 140) end
        return
    end
    if type(M.momNote) == "function" then M.momNote(text, r or 230, g or 200, b or 140); return end
    local p = thePlayer()
    if p then pcall(ALifeLetter, p, tostring(text), r or 230, g or 200, b or 140) end
end
local function say(shell, line)
    if shell == nil or line == nil then return false end
    local ok, res = pcall(function() return PA().Speech.say(shell, line, {}) end)
    return ok and res ~= false
end
-- one guarded call per uncertain engine method: first failure logs one line, then it's off for the session
local retired = {}
local function tryOnce(id, f)
    if retired[id] then return false end
    local ok, err = pcall(f)
    if ok then return true end
    retired[id] = true
    log(id .. " failed, off for this session: " .. tostring(err))
    return false
end

----------------------------------------------------------------------------------------------------------------
-- settings: sandbox page ALifeChatPlus (CP*), safe defaults when missing
----------------------------------------------------------------------------------------------------------------
M.cpDefaults = {
    CPPatrolPoints = 5, CPNightWatch = true, CPWatchWakes = 2, CPHordeSize = 10,
    CPHaulDrops = 5, CPHaulOverflow = true, CPHaulFridgeWarn = true,
    CPMorale = true, CPMoraleRate = 2, CPMoraleLeave = true, CPRules = true,
    CPFortify = true, CPFortifyOwn = true,
    CPFarm = true, CPFarmWaterAt = 40, CPFarmHarvest = true,
}
function M.cpOpt(key)
    local sv = type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or nil
    local v = sv and sv[key]
    if v == nil then return M.cpDefaults[key] end
    return v
end
M.cpCfg = {
    tickMs = 1000, retryMs = 8000, walkTimeoutMs = 90000, banMs = 300000,
    patrolWaitMs = 4000, patrolScanTiles = 22, strangerTiles = 25,
    watchScanMs = 5000, watchTiles = 30, alertGapMs = 120000, wakeGapH = 2,
    haulers = 2, haulMaxItems = 8, haulMaxWeight = 12, haulScanMs = 8000, takeMs = 2500, putMs = 2000,
    maxHaulAreas = 5, maxSide = 60, medicEveryMs = 30000, loadedTiles = 70,
    waterTripUses = 40, farmScanMs = 10000, farmPerTrip = 6, fillMs = 3000, waterMs = 2500, harvestMs = 3000, farmRange = 45,
}
M.cpStats = { patrols = 0, alerts = 0, wakes = 0, hauled = 0, trips = 0, overflow = 0, treated = 0, rulesBroken = 0, bans = 0, evals = 0, watered = 0, harvested = 0 }

----------------------------------------------------------------------------------------------------------------
-- saved state
----------------------------------------------------------------------------------------------------------------
function M.cpData()
    local d = nil
    if mpClient() then -- read-only copy from the server (an empty camp until the first copy arrives)
        local v = M.cpView()
        d = v and type(v.camp) == "table" and v.camp or nil
        if d == nil then M._cpEmpty = M._cpEmpty or {}; d = M._cpEmpty end
    else
        d = bucket("camp")
    end
    d.roles = type(d.roles) == "table" and d.roles or {}
    d.rules = type(d.rules) == "table" and d.rules or {}
    d.patrol = type(d.patrol) == "table" and d.patrol or {}
    d.patrollers = type(d.patrollers) == "table" and d.patrollers or {}
    d.areas = type(d.areas) == "table" and d.areas or {}
    d.drops = type(d.drops) == "table" and d.drops or {}
    d.hypo = type(d.hypo) == "table" and d.hypo or {}
    d.heard = type(d.heard) == "table" and d.heard or {}
    d.nextArea = tonumber(d.nextArea) or 1
    if d.haulOn == nil then d.haulOn = true end
    return d
end

----------------------------------------------------------------------------------------------------------------
-- who lives here: the same people work zones use
----------------------------------------------------------------------------------------------------------------
function M.cpIsHome(uid, player)
    if fn(M, "wzIsWorker") then local ok, yes = pcall(M.wzIsWorker, uid, player); return ok and yes == true end
    return fn(M, "settlerHome") and M.settlerHome(uid) or false
end
-- everyone who lives at the base and is home right now (settlers + Jeem residents with a loaded body)
-- 0.6.16: who's at camp, cached for a few seconds and shared by every caller. With Jeem residents this walks A-Life's
-- whole registry (every NPC in the world); camp systems asked for it many times a second (the bite check twice every
-- 5 s alone: a ~35 ms hitch each time). Membership doesn't change faster than this.
M.cpPeopleTtlMs = 3000
function M.cpPeople(player)
    if mpClient() then
        local v = M.cpView()
        local out = {}
        for i, uid in ipairs(v and type(v.people) == "table" and v.people or {}) do out[i] = tostring(uid) end
        return out
    end
    local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
    local c = M._cpPeopleCache
    local sig = 0
    for _ in pairs(bucket("settlers")) do sig = sig + 1 end
    if c and c.sig == sig and now - c.at < M.cpPeopleTtlMs and now >= c.at then
        local copy = {}
        for i = 1, #c.list do copy[i] = c.list[i] end
        return copy
    end
    local out = M.cpPeopleNow(player)
    local keep = {}
    for i = 1, #out do keep[i] = out[i] end
    M._cpPeopleCache = { at = now, list = keep, sig = sig }
    return out
end
function M.cpPeopleNow(player)
    local out, seen = {}, {}
    for uid in pairs(bucket("settlers")) do
        uid = tostring(uid)
        local r = rec(uid)
        if r and r.lifecycle ~= "dead" and M.cpIsHome(uid, player) then out[#out + 1] = uid; seen[uid] = true end
    end
    local R = ProjectALifeJimmy and ProjectALifeJimmy.Residents
    if R and type(R.isMember) == "function" and fn(PA().ActorRegistry, "each") then
        pcall(function()
            PA().ActorRegistry.each(function(r)
                local uid = tostring(r.uid)
                if not seen[uid] and r.lifecycle ~= "dead" and type(r.memory) == "table" and type(r.memory.jimmyResident) == "table"
                    and M.cpIsHome(uid, player) and shellFor(uid) ~= nil then out[#out + 1] = uid; seen[uid] = true end
                return false
            end)
        end)
    end
    table.sort(out)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- ROLES
----------------------------------------------------------------------------------------------------------------
M.cpRoles = {
    { id = "general", label = "General" },
    { id = "cook", label = "Cook" },
    { id = "medic", label = "Medic" },
    { id = "guard", label = "Guard" },
    { id = "builder", label = "Builder" },
    { id = "farmer", label = "Farmer" },
}
M.cpRoleLabel = { general = "General", cook = "Cook", medic = "Medic", guard = "Guard", builder = "Builder", farmer = "Farmer" }
-- who they were (A-Life background key) per role
M.cpRoleBg = {
    cook = { homemaker = 1, waitress = 1, bartender = 0.8, cook_prison = 1, granny = 1, dad = 0.5, farmer = 0.6, hunter = 0.5, fisher = 0.5, methcook = 0.3 },
    medic = { nurse = 1, doctor = 1, paramedic = 1, medic_mil = 1, pharmacist = 0.8, vet_animal = 0.8, firefighter = 0.6, chaplain = 0.3 },
    guard = { grunt = 1, nco = 1, mp = 1, sf = 1, delta_bg = 1, swat_bg = 1, cop = 0.9, deputy = 0.9, sheriff = 0.9, trooper = 0.9, guard = 0.9,
        officer_mil = 0.9, gulfvet = 0.8, namvet = 0.7, militiaman = 0.8, contractor = 0.9, trainee_bg = 0.6, tanker = 0.7, hunter = 0.6,
        bruiser_bg = 0.6, biker_bg = 0.5, lookout_bg = 0.6, deserter_bg = 0.6, prepper = 0.6, detective = 0.6, sergeant_law = 0.7 },
    farmer = { farmer = 1, granny = 0.8, grandpa = 0.8, homemaker = 0.5, prepper = 0.6, hunter = 0.3, dad = 0.4, fisher = 0.3 },
    builder = { factory = 1, mechanic = 0.9, lineman = 0.9, grandpa = 0.8, scrapper = 0.9, farmer = 0.7, trucker = 0.5, fisher = 0.4, prepper = 0.7, dad = 0.5 },
}
-- who they are (personality lens) per role
M.cpRoleLens = {
    cook = { kind = 0.6, cheerful = 0.5, calm = 0.3, mean = -0.4, unhinged = -0.3 },
    medic = { kind = 0.7, calm = 0.5, disciplined = 0.3, volatile = -0.4, mean = -0.4 },
    guard = { brave = 0.7, disciplined = 0.5, paranoid = 0.4, fearful = -0.8, romantic = -0.2 },
    builder = { disciplined = 0.5, calm = 0.3, curious = 0.3, volatile = -0.3 },
    farmer = { calm = 0.4, disciplined = 0.3, curious = 0.3, volatile = -0.3 },
}
local function bgKey(uid)
    local k = nil
    pcall(function() local p = M.partsOf and M.partsOf(uid); k = p and p.bg and (p.bg.key or p.bg.k) end)
    return k and tostring(k) or nil
end
-- how well they'd do it: 0.3 (hopeless) .. 1.6 (born for it). Stable per person.
function M.cpFit(uid, role)
    if role == "general" or M.cpRoleBg[role] == nil then return 1 end
    local f = 0.75
    local bg = bgKey(uid)
    if bg and M.cpRoleBg[role][bg] then f = f + 0.6 * M.cpRoleBg[role][bg] end
    local lens = {}
    pcall(function() lens = M.lens(tostring(uid)) end)
    for k, w in pairs(M.cpRoleLens[role]) do f = f + (tonumber(lens[k]) or 0) * w end
    if f < 0.3 then f = 0.3 elseif f > 1.6 then f = 1.6 end
    return f
end
function M.cpRoleOf(uid) local r = M.cpData().roles[tostring(uid)]; return (type(r) == "string" and M.cpRoleLabel[r]) and r or "general" end
function M.cpWithRole(role, player)
    local out = {}
    for _, uid in ipairs(M.cpPeople(player)) do if M.cpRoleOf(uid) == role then out[#out + 1] = uid end end
    return out
end
local ROLE_LINES = {
    good = { cook = "I can feed people. Did it for years.", medic = "Bring me the bleeding ones. I know what I'm doing.", guard = "I'll keep watch. Nothing gets past me.", builder = "I'll keep this place standing.", farmer = "Grew up on a farm. I'll keep things growing." },
    ok = { cook = "I'll cook. Don't expect much.", medic = "I'll patch people up as best I can.", guard = "Alright. I'll stand guard.", builder = "Sure. I'll fix what needs fixing.", farmer = "I'll water and pick. Can't promise miracles." },
    poor = { cook = "Me? Cook? ...I'll try. Don't complain.", medic = "I've never done this. I'll try not to kill anyone.", guard = "I'm not much of a fighter. But fine.", builder = "I don't know a hammer from a wrench, but okay.", farmer = "I kill houseplants. But fine, I'll try." },
    refuse = { guard = "No. I can't. I'd freeze up and get someone killed.", medic = "I can't stand blood. Pick someone else.", cook = "Not a chance. Find someone else.", builder = "Not my thing. Ask someone else.", farmer = "Dig in the dirt all day? No." },
    general = "Back to whatever needs doing, then.",
}
-- returns the line they say (and whether the role was taken)
function M.cpSetRole(uid, role, player)
    uid = tostring(uid)
    local d = M.cpData()
    if role == "general" then
        d.roles[uid] = nil
        local s = M.settlerOf and M.settlerOf(uid) or nil
        if s and s.role == "guard" then s.role = nil end
        d.patrollers[uid] = nil
        return ROLE_LINES.general, true
    end
    local fit = M.cpFit(uid, role)
    local lens = {}
    pcall(function() lens = M.lens(uid) end)
    -- refuse: hopeless at it and proud / scared enough to say so
    if fit <= 0.45 and ((role == "guard" and (tonumber(lens.fearful) or 0) >= 0.25) or (tonumber(lens.proud) or 0) >= 0.3 or (tonumber(lens.volatile) or 0) >= 0.3) then
        return ROLE_LINES.refuse[role], false
    end
    d.roles[uid] = role
    local s = M.settlerOf and M.settlerOf(uid) or nil
    if s then
        if role == "guard" then s.role = "guard" elseif s.role == "guard" then s.role = nil end
    end
    if role ~= "guard" then d.patrollers[uid] = nil end
    log(uid .. " is now " .. role .. " (fit " .. math.floor(fit * 100 + 0.5) .. ")")
    if M.histAdd then pcall(M.histAdd, uid, "party", "Became the base's " .. string.lower(M.cpRoleLabel[role])) end
    local tier = (fit >= 1.2 and "good") or (fit >= 0.8 and "ok") or "poor"
    return ROLE_LINES[tier][role], true
end

-- medics treat hurt housemates (bandages / splints they carry; the patch decides what's needed)
M.cpMedicAt = 0
function M.cpMedics(player, now)
    if now - M.cpMedicAt < M.cpCfg.medicEveryMs then return end
    M.cpMedicAt = now
    local P = patch()
    if P == nil or not fn(P, "treatOther") then return end
    local medics = M.cpWithRole("medic", player)
    if #medics == 0 then return end
    local people = M.cpPeople(player)
    if fn(M, "mdScore") then table.sort(people, function(a, b) return M.mdScore(a) > M.mdScore(b) end) end
    for _, m in ipairs(medics) do
        for _, p in ipairs(people) do
            if p ~= m then
                local ok, done, kind = pcall(P.treatOther, m, p)
                if ok and done then
                    M.cpStats.treated = M.cpStats.treated + 1
                    log(firstName(m) .. " (medic) treated " .. firstName(p) .. " with " .. tostring(kind))
                    return
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- MORALE: what the camp adds to the daily unrest check (positive = worse, negative = better)
----------------------------------------------------------------------------------------------------------------
M.cpRateMul = { 0.6, 1, 1.5 }
function M.cpMoralePush(r, st, player)
    if M.cpOpt("CPMorale") == false then return 0 end
    local uid = tostring(r.uid)
    local push = 0
    local d = M.cpData()
    -- a cook with food to cook
    if (st.foodPer or 9) >= 1 and not (fn(M, "ckOn") and M.ckOn()) then
        for _, c in ipairs(M.cpWithRole("cook", player)) do push = push - 3 * M.cpFit(c, "cook"); break end
    end
    for _, f in ipairs(M.cpMoraleHooks or {}) do local okH, v = pcall(f, uid, r, st, player); if okH and tonumber(v) then push = push + v end end
    -- someone who can patch you up / someone on watch
    for _, c in ipairs(M.cpWithRole("medic", player)) do push = push - 1.5 * M.cpFit(c, "medic"); break end
    if (st.safety or 100) < 70 then
        for _, c in ipairs(M.cpWithRole("guard", player)) do push = push - 2 * M.cpFit(c, "guard"); break end
    end
    for _, c in ipairs(M.cpWithRole("builder", player)) do push = push - 1 * M.cpFit(c, "builder"); break end
    -- recent losses
    if M.baseLossMorale then local okL, hit = pcall(M.baseLossMorale); if okL and tonumber(hit) then push = push + hit / 4 end end
    -- you broke your own rules where they could see (fades over 3 days)
    local hy = d.hypo[uid]
    if type(hy) == "table" then
        local age = hours() - (tonumber(hy.h) or 0)
        if age < 72 then push = push + (tonumber(hy.v) or 0) * (1 - age / 72) else d.hypo[uid] = nil end
    end
    local mul = M.cpRateMul[tonumber(M.cpOpt("CPMoraleRate")) or 2] or 1
    if push > 0 then push = push * mul end
    return push
end
-- a good stretch shows too: once a day someone content says so (behavior, never a number)
local GOOD = { "Good to have a hot meal for once.", "Feels almost like a home here.", "Slept the whole night. Haven't done that in a while.", "We're doing alright. I mean it." }
function M.cpContent(player)
    if M.cpOpt("CPMorale") == false then return end
    local store = M.store and M.store() or {}
    local unrest = type(store.unrest) == "table" and store.unrest or {}
    local day = math.floor(hours() / 24)
    local d = M.cpData()
    if d.contentDay == day then return end
    for _, uid in ipairs(M.cpPeople(player)) do
        local u = unrest[uid]
        if (u == nil or (tonumber(u.v) or 0) <= 0) and #M.cpWithRole("cook", player) > 0 then
            local sh = shellFor(uid)
            local px, py = pos(player)
            local sx, sy = pos(sh)
            if sx and px and d2(sx, sy, px, py) <= 20 * 20 and say(sh, pickLine(GOOD, uid .. day)) then d.contentDay = day; return end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- CAMP RULES
----------------------------------------------------------------------------------------------------------------
M.cpRules = {
    { id = "prisoners", label = "No killing prisoners", broke = "killed a prisoner" },
    { id = "harmless", label = "No killing people who aren't a threat", broke = "killed someone who wasn't a threat" },
    { id = "steal", label = "No stealing from other groups", broke = "stole from another group" },
    { id = "share", label = "Everyone shares food", broke = "kept food to yourself while the base went short" },
}
local RULE = {}
for _, r in ipairs(M.cpRules) do RULE[r.id] = r end
local JUDGE = { kind = 1.3, disciplined = 1.3, loyal = 1.2, devout = 1.3, mean = 0.5, greedy = 0.6, unhinged = 0.5 }
local CALLOUT = {
    "Your rule. Not mine. Yours.", "So the rules are just for us, then?", "I heard what you did. That was your own rule.",
    "Don't ever lecture us again.", "We all saw that.",
}
function M.cpRuleOn(id) return M.cpOpt("CPRules") ~= false and M.cpData().rules[id] == true end
function M.cpBreak(id, player, wx, wy)
    if not M.cpRuleOn(id) then return end
    local rule = RULE[id]
    M.cpLog("rule", "you " .. tostring(rule and rule.broke or id) .. ", against your own rule")
    local d = M.cpData()
    local px, py = pos(player)
    wx, wy = wx or px, wy or py
    local h = hours()
    M.cpStats.rulesBroken = M.cpStats.rulesBroken + 1
    local said = false
    for _, uid in ipairs(M.cpPeople(player)) do
        local sh = shellFor(uid)
        local sx, sy = pos(sh)
        local saw = sx ~= nil and wx ~= nil and d2(sx, sy, wx, wy) <= 30 * 30
        local lens = {}
        pcall(function() lens = M.lens(uid) end)
        local w = 1
        for k, m in pairs(JUDGE) do w = w + ((tonumber(lens[k]) or 0) * (m - 1)) end
        local hit = math.floor(6 * w + 0.5)
        if saw then
            local hy = d.hypo[uid] or { v = 0 }
            hy.v, hy.h = math.min(20, (tonumber(hy.v) or 0) + hit), h
            d.hypo[uid] = hy
            local r = rec(uid)
            if r then pcall(function() PA().NpcOpinion.adjust(r, player, -hit, "You broke your own camp rule: " .. rule.label) end) end
            if M.keyMem then pcall(M.keyMem, uid, "event", "saw the newcomer break their own rule (" .. rule.label .. ")") end
            if not said and sh and say(sh, pickLine(CALLOUT, uid .. h)) then said = true end
        else
            -- not there: they may hear about it tomorrow
            d.heard[uid] = { id = id, h = h, hit = math.floor(hit / 2) }
        end
    end
    log("rule broken: " .. id .. " (" .. rule.broke .. ")")
end
-- word gets around (checked hourly): the ones who weren't there hear about it, half the sting
function M.cpHearsay(player)
    local d = M.cpData()
    local h = hours()
    for uid, e in pairs(d.heard) do
        if type(e) ~= "table" or h - (tonumber(e.h) or 0) > 48 then d.heard[uid] = nil
        elseif h - (tonumber(e.h) or 0) >= 6 and M.cpIsHome(uid, player) then
            d.heard[uid] = nil
            if (hash(uid .. tostring(e.h)) % 100) < 60 then
                local hy = d.hypo[uid] or { v = 0 }
                hy.v, hy.h = math.min(20, (tonumber(hy.v) or 0) + (tonumber(e.hit) or 3)), h
                d.hypo[uid] = hy
                local r = rec(uid)
                local rule = RULE[e.id]
                if r and rule then pcall(function() PA().NpcOpinion.adjust(r, player, -(tonumber(e.hit) or 3), "Heard you broke your own camp rule: " .. rule.label) end) end
            end
        end
    end
end
-- deaths: prisoners / harmless people killed by you
M.cpDeathHooks = {}
function M.cpOnDeath(body, uid, killer)
    local judged = false
    for _, f in ipairs(M.cpDeathHooks) do
        local okH, skip = pcall(f, body, uid, killer)
        if okH and skip == true then judged = true end -- a hook judged this death itself (a mercy kill)
    end
    if judged then return end
    if M.cpOpt("CPRules") == false then return end
    local d = M.cpData()
    if d.rules.prisoners ~= true and d.rules.harmless ~= true then return end
    local player = thePlayer()
    if mpServer() and ALifeSide.isOnlinePlayer(killer) then player = killer end -- MP: the player who killed them
    if player == nil or not fn(M, "killerOf") then return end
    local okK, _, killerUid = pcall(M.killerOf, killer, player, body)
    if not okK or killerUid ~= "player" then return end
    local r = rec(uid)
    local bx, by = pos(body)
    local captive = false
    if ALifePrisonWork and type(ALifePrisonWork.captive) == "function" and r then pcall(function() captive = ALifePrisonWork.captive(r, player) ~= nil end) end
    if captive then M.cpBreak("prisoners", player, bx, by); return end
    if d.rules.harmless == true and r then
        local op = 0
        pcall(function() op = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end)
        local hostile = false
        pcall(function() local m = r.memory or {}; hostile = type(m.hostileToPlayerKeys) == "table" and hasAny(m.hostileToPlayerKeys) end)
        if op > -16 and not hostile then M.cpBreak("harmless", player, bx, by) end
    end
end
-- food: the base is short and you carry plenty (checked once a day, before the unrest check)
function M.cpFoodCheck(player)
    if not M.cpRuleOn("share") or not M.baseState then return end
    local st = nil
    pcall(function() st = M.baseState(player) end)
    if type(st) ~= "table" or (st.foodPer or 9) >= 2 then return end
    local n = 0
    pcall(function()
        local items = player:getInventory():getItems()
        for i = 0, items:size() - 1 do if instanceof(items:get(i), "Food") then n = n + 1 end end
    end)
    if n >= 6 then M.cpBreak("share", player) end
end
-- theft: the world-pushes-back check decides if taking counted as theft; we watch what it decided
function M.cpWrapTake()
    if M._cpTakeWrapped or not fn(M, "dynTake") then return end
    local orig = M.dynTake
    M.dynTake = function(player, container, ...)
        local before = 0
        for _, v in pairs(M.dynTakeAt or {}) do before = before + (tonumber(v) or 0) end
        local res = orig(player, container, ...)
        local after = 0
        for _, v in pairs(M.dynTakeAt or {}) do after = after + (tonumber(v) or 0) end
        if after ~= before then pcall(M.cpBreak, "steal", player) end
        return res
    end
    M._cpTakeWrapped = true
end

----------------------------------------------------------------------------------------------------------------
-- spotting: zombies (not A-Life people riding zombie bodies) and strangers near a point
----------------------------------------------------------------------------------------------------------------
local function compass(fromX, fromY, x, y)
    local dx, dy = x - fromX, y - fromY
    if dx * dx + dy * dy < 36 then return "right here" end
    local ns = (dy < -math.abs(dx) / 2 and "north") or (dy > math.abs(dx) / 2 and "south") or ""
    local ew = (dx > math.abs(dy) / 2 and "east") or (dx < -math.abs(dy) / 2 and "west") or ""
    return "to the " .. ns .. ew
end
function M.cpSpot(x, y, tiles, player)
    local out = { zombies = 0, zx = 0, zy = 0, strangers = 0, sx = nil, sy = nil, hostile = false }
    pcall(function()
        local list = getCell():getZombieList()
        local Perc = PA().Perception
        local t2 = tiles * tiles
        local s2 = M.cpCfg.strangerTiles ^ 2
        for i = 0, list:size() - 1 do
            local zb = list:get(i)
            if not zb:isDead() then
                local zx, zy = zb:getX(), zb:getY()
                local dd = d2(zx, zy, x, y)
                if dd <= t2 then
                    local actor = nil
                    if Perc and Perc.activeActorForShell then pcall(function() actor = Perc.activeActorForShell(zb) end) end
                    if actor == nil then
                        out.zombies = out.zombies + 1; out.zx = out.zx + zx; out.zy = out.zy + zy
                    elseif dd <= s2 then
                        local uid = tostring(actor.uid)
                        local ours = M.settlerOf and M.settlerOf(uid) ~= nil
                        if not ours and M.partyIsMember then local okP, inP = pcall(M.partyIsMember, uid, player); ours = okP and inP end
                        if not ours and M.cpIsHome(uid, player) then ours = true end
                        if not ours then
                            out.strangers = out.strangers + 1
                            out.sx, out.sy = out.sx or zx, out.sy or zy
                            local r = rec(uid)
                            if r and player then
                                pcall(function() if (tonumber((PA().NpcOpinion.valueOf(r, player))) or 0) <= -41 then out.hostile = true end end)
                            end
                        end
                    end
                end
            end
        end
    end)
    if out.zombies > 0 then out.zx, out.zy = out.zx / out.zombies, out.zy / out.zombies end
    return out
end
M.cpAlertAt = {}
local function alert(key, shell, line, player, wake)
    local now = rawMs()
    if now - (M.cpAlertAt[key] or -1e12) < M.cpCfg.alertGapMs then return false end
    M.cpAlertAt[key] = now
    M.cpStats.alerts = M.cpStats.alerts + 1
    say(shell, line)
    local px, py = pos(player)
    local sx, sy = pos(shell)
    if wake then
        local asleep = false
        pcall(function() asleep = player:isAsleep() == true end)
        if asleep then
            -- not verified in 42.21: the call vanilla uses to wake a sleeping player. Guarded: one log line if missing.
            if tryOnce("forceAwake", function() player:forceAwake() end) then M.cpStats.wakes = M.cpStats.wakes + 1; log("night watch woke you: " .. line) end
        end
    end
    if sx and px and d2(sx, sy, px, py) > 12 * 12 then halo(line, 255, 190, 120) end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- PATROL + NIGHT WATCH
----------------------------------------------------------------------------------------------------------------
local function isNight() local h = hourOfDay(); return h >= 22 or h < 6 end
function M.cpPatrolPoints() return M.cpData().patrol end
-- tonight's watcher: a guard first, else the most watchful; same person all night
function M.cpWatcher(player)
    if M.cpOpt("CPNightWatch") == false or not isNight() then return nil end
    local d = M.cpData()
    local night = math.floor((hours() + 2) / 24)
    if d.watchNight == night and d.watcher and M.cpIsHome(d.watcher, player) then return d.watcher end
    local best, bs = nil, nil
    for _, uid in ipairs(M.cpPeople(player)) do
        local lens = {}
        pcall(function() lens = M.lens(uid) end)
        local s = (M.cpRoleOf(uid) == "guard" and 10 or 0) + (tonumber(lens.paranoid) or 0) * 3 + (tonumber(lens.brave) or 0) * 2
            - (tonumber(lens.fearful) or 0) * 3 + (hash(uid .. night) % 100) / 100
        if bs == nil or s > bs then best, bs = uid, s end
    end
    d.watchNight, d.watcher = night, best
    if best then log("night watch tonight: " .. firstName(best)) end
    return best
end
function M.cpIsPatroller(uid, player)
    if #M.cpPatrolPoints() == 0 then return false end
    local d = M.cpData()
    if d.patrolOff then return false end
    return M.cpRoleOf(uid) == "guard" or d.patrollers[tostring(uid)] == true
end
local WARN = {
    horde = { "Horde! %d of them, %s! Get up!", "Wake up! A big group, %s - %d at least!" },
    zombies = { "%d of them %s.", "Got %d dead ones %s." },
    stranger = { "Someone's out there, %s. Not one of ours.", "We've got company %s." },
    hostile = { "Armed people %s! They don't look friendly!", "Trouble %s! Get ready!" },
}
local function warnLine(kind, seed, n, dir)
    local l = pickLine(WARN[kind], seed)
    if kind == "horde" and string.find(l, "^Wake") then return string.format(l, dir, n) end
    if kind == "horde" or kind == "zombies" then return string.format(l, n, dir) end
    return string.format(l, dir)
end
-- one look around from (x, y). wake: night watch rules apply
function M.cpLook(uid, shell, player, x, y, tiles, night, b)
    local s = M.cpSpot(x, y, tiles, player)
    local cx, cy = b and b.x or x, b and b.y or y
    local mode = tonumber(M.cpOpt("CPWatchWakes")) or 2
    local horde = tonumber(M.cpOpt("CPHordeSize")) or 10
    if s.zombies >= horde then
        local wl = warnLine("horde", uid .. math.floor(hours()), s.zombies, compass(cx, cy, s.zx, s.zy))
        if fn(M, "alRaise") then pcall(M.alRaise, "horde", player, firstName(uid) .. ": \"" .. wl .. "\"") end
        return alert("horde", shell, wl, player, night)
    end
    if s.strangers > 0 and (not night or mode >= 2) then
        if s.hostile and fn(M, "alRaise") then pcall(M.alRaise, "hostile", player, firstName(uid) .. ": \"" .. warnLine("hostile", uid .. math.floor(hours()), 0, compass(cx, cy, s.sx, s.sy)) .. "\"") end
        return alert("stranger", shell, warnLine(s.hostile and "hostile" or "stranger", uid .. math.floor(hours()), 0, compass(cx, cy, s.sx, s.sy)), player, night)
    end
    if s.zombies > 0 and (not night or mode >= 3) then
        if not night and s.zombies < 3 then return false end
        return alert("zombies", shell, warnLine("zombies", uid .. math.floor(hours()), s.zombies, compass(cx, cy, s.zx, s.zy)), player, night)
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- HAUL & SORT
----------------------------------------------------------------------------------------------------------------
M.cpCats = {
    { id = "fresh", label = "Food that spoils" }, { id = "cans", label = "Food that keeps" }, { id = "meds", label = "Meds" },
    { id = "clothes", label = "Clothes" }, { id = "weapons", label = "Weapons" }, { id = "ammo", label = "Ammo" },
    { id = "tools", label = "Tools" }, { id = "materials", label = "Building materials" }, { id = "other", label = "Everything else" },
}
M.cpCatLabel = {}
for _, c in ipairs(M.cpCats) do M.cpCatLabel[c.id] = c.label end
local DC = {
    firstaid = "meds", ammo = "ammo", weapon = "weapons", weaponcrafted = "weapons", explosives = "weapons",
    clothing = "clothes", accessory = "clothes", protectivegear = "clothes", bag = "clothes",
    tool = "tools", toolweapon = "tools", cooking = "tools", gardening = "tools", fishing = "tools", camping = "tools", electronics = "tools", lightsource = "tools",
    material = "materials", carpentry = "materials", metalwork = "materials", building = "materials", construction = "materials",
}
function M.cpCatOf(item)
    if isA(item, "Food") then
        local keeps = false
        pcall(function() keeps = (tonumber(item:getOffAgeMax()) or 0) >= 1000000 end)
        return keeps and "cans" or "fresh"
    end
    local dc = ""
    pcall(function() dc = string.lower(tostring(item:getDisplayCategory() or "")) end)
    if DC[dc] then return DC[dc] end
    if isA(item, "Clothing") then return "clothes" end
    if isA(item, "HandWeapon") then return "weapons" end
    return "other"
end
local function containerOn(sq)
    local c, o = nil, nil
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local x = objs:get(i)
            if not instanceof(x, "IsoDeadBody") then
                local cc = x:getContainer()
                if cc ~= nil then c, o = cc, x; break end
            end
        end
    end)
    return c, o
end
local function containerType(c) local t = ""; pcall(function() t = string.lower(tostring(c:getType() or "")) end); return t end
local function isCold(c) local t = containerType(c); return string.find(t, "fridge", 1, true) ~= nil or string.find(t, "freezer", 1, true) ~= nil end
local function hasRoom(c, w)
    local ok = false
    pcall(function() ok = c:getContentsWeight() + (w or 0.5) <= c:getCapacity() end)
    return ok
end
local function invOf(shell) local inv = nil; pcall(function() inv = shell:getInventory() end); return inv end
local function dropKey(x, y, z) return math.floor(x) .. ":" .. math.floor(y) .. ":" .. math.floor(z or 0) end
function M.cpDropAt(x, y, z)
    local k = dropKey(x, y, z)
    for cat, list in pairs(M.cpData().drops) do
        for i, p in ipairs(list) do if dropKey(p.x, p.y, p.z) == k then return cat, i end end
    end
    return nil
end
function M.cpAddDrop(cat, x, y, z)
    local d = M.cpData()
    d.drops[cat] = type(d.drops[cat]) == "table" and d.drops[cat] or {}
    local list = d.drops[cat]
    local maxN = tonumber(M.cpOpt("CPHaulDrops")) or 5
    if #list >= maxN then return false, "already " .. #list .. " drop points for " .. string.lower(M.cpCatLabel[cat]) .. " (max " .. maxN .. ")" end
    if M.cpDropAt(x, y, z) then return false, "that container is already a drop point" end
    list[#list + 1] = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }
    M.cpScan = nil
    log("drop point for " .. cat .. " at " .. math.floor(x) .. "," .. math.floor(y))
    return true
end
function M.cpRemoveDrop(x, y, z)
    local cat, i = M.cpDropAt(x, y, z)
    if cat == nil then return false end
    table.remove(M.cpData().drops[cat], i)
    M.cpScan = nil
    return true
end
local function inArea(a, x, y, z) return (a.z or 0) == (z or 0) and x >= a.x1 and x <= a.x2 and y >= a.y1 and y <= a.y2 end
function M.cpAreaAt(x, y, z)
    for i, a in ipairs(M.cpData().areas) do if inArea(a, x, y, z) then return a, i end end
    return nil
end
-- what's waiting to be sorted: { { x, y, z, cat, ground }, ... } (cached a few seconds)
M.cpScan, M.cpScanAt = nil, 0
function M.cpHaulList(now)
    if M.cpScan and now - M.cpScanAt < M.cpCfg.haulScanMs then return M.cpScan end
    local d = M.cpData()
    local out = {}
    local wanted = {}
    for cat, list in pairs(d.drops) do if #list > 0 then wanted[cat] = true end end
    if hasAny(wanted) then
        for _, a in ipairs(d.areas) do
            for x = a.x1, a.x2 do
                for y = a.y1, a.y2 do
                    local sq = sqAt(x, y, a.z)
                    if sq then
                        if M.cpDropAt(x, y, a.z) == nil then
                            local c = containerOn(sq)
                            if c then
                                pcall(function()
                                    local items = c:getItems()
                                    for i = 0, items:size() - 1 do
                                        local cat = M.cpCatOf(items:get(i))
                                        if wanted[cat] then out[#out + 1] = { x = x, y = y, z = a.z, cat = cat }; break end
                                    end
                                end)
                            end
                        end
                        pcall(function()
                            local wos = sq:getWorldObjects()
                            for i = 0, wos:size() - 1 do
                                local cat = M.cpCatOf(wos:get(i):getItem())
                                if wanted[cat] then out[#out + 1] = { x = x, y = y, z = a.z, cat = cat, ground = true }; break end
                            end
                        end)
                    end
                end
            end
        end
    end
    M.cpScan, M.cpScanAt = out, now
    return out
end
-- take up to N items of one category from a spot into the hauler's pockets; returns how many
local function takeFrom(j, shell)
    local inv = invOf(shell)
    if inv == nil then return 0 end
    local sq = sqAt(j.from.x, j.from.y, j.from.z)
    if sq == nil then return 0 end
    local n, w = 0, 0
    local cfg = M.cpCfg
    if j.ground then
        local picks = {}
        pcall(function()
            local wos = sq:getWorldObjects()
            for i = 0, wos:size() - 1 do
                local wo = wos:get(i)
                local it = wo:getItem()
                if it and M.cpCatOf(it) == j.cat and #picks < cfg.haulMaxItems then picks[#picks + 1] = wo end
            end
        end)
        for _, wo in ipairs(picks) do
            local it = nil
            pcall(function() it = wo:getItem() end)
            local iw = 0
            pcall(function() iw = it:getActualWeight() end)
            if it and w + iw <= cfg.haulMaxWeight then
                local ok = pcall(function() sq:transmitRemoveItemFromSquare(wo) end)
                if ok then
                    pcall(function() wo:removeFromWorld() end)
                    pcall(function() wo:removeFromSquare() end)
                    pcall(function() it:setWorldItem(nil) end)
                    if pcall(function() inv:AddItem(it) end) then n = n + 1; w = w + iw; j.items[#j.items + 1] = it end
                end
            end
        end
    else
        local c = containerOn(sq)
        if c == nil then return 0 end
        local picks = {}
        pcall(function()
            local items = c:getItems()
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                if M.cpCatOf(it) == j.cat and #picks < cfg.haulMaxItems then picks[#picks + 1] = it end
            end
        end)
        for _, it in ipairs(picks) do
            local iw = 0
            pcall(function() iw = it:getActualWeight() end)
            if w + iw <= cfg.haulMaxWeight then
                if pcall(function() c:DoRemoveItem(it); inv:AddItem(it) end) then n = n + 1; w = w + iw; j.items[#j.items + 1] = it end
            end
        end
    end
    j.weight = w
    j.minW = nil
    for _, it in ipairs(j.items) do local iw = 0.1; pcall(function() iw = it:getActualWeight() end); if j.minW == nil or iw < j.minW then j.minW = iw end end
    return n
end
-- the drop point for this load: nearest with room for at least one piece (w = lightest piece); spoiling food to
-- cold storage first. Whatever doesn't fit goes on to the next one.
function M.cpBestDrop(cat, x, y, w)
    local list = M.cpData().drops[cat] or {}
    local best, bd, bestCold, bdc = nil, nil, nil, nil
    for i, p in ipairs(list) do
        local sq = sqAt(p.x, p.y, p.z)
        local c = sq and containerOn(sq)
        if c and hasRoom(c, w) then
            local dd = d2(p.x, p.y, x, y)
            if cat == "fresh" and isCold(c) then
                if bdc == nil or dd < bdc then bestCold, bdc = p, dd end
            elseif bd == nil or dd < bd then best, bd = p, dd end
        end
    end
    return bestCold or best
end
local function overflowSpot(cat)
    local list = M.cpData().drops[cat] or {}
    local last = list[#list]
    if last == nil then return nil end
    return { x = last.x + 1, y = last.y, z = last.z, pile = true }
end
-- put what they carry where it goes; returns "done" | "next" (more to put elsewhere) | "fail"
local function putDown(j, shell, uid)
    local inv = invOf(shell)
    local sq = sqAt(j.to.x, j.to.y, j.to.z)
    if sq == nil or inv == nil then return "fail" end
    local d = M.cpData()
    local left = {}
    if j.to.pile then
        for _, it in ipairs(j.items) do
            local ok = pcall(function() inv:DoRemoveItem(it) end) and pcall(function() sq:AddWorldInventoryItem(it, 0.3 + (hash(tostring(it)) % 40) / 100, 0.5, 0) end)
            if ok then M.cpStats.overflow = M.cpStats.overflow + 1 end
        end
        if not d.overflowSaid then d.overflowSaid = true; say(shell, "Everything's full. I'm stacking the rest on the floor by the last one.") end
        j.items = {}
        return "done"
    end
    local c = containerOn(sq)
    if c == nil then return "fail" end
    if j.cat == "fresh" and isCold(c) and M.cpOpt("CPHaulFridgeWarn") ~= false then
        local powered = true
        tryOnce("isPowered", function() powered = c:isPowered() == true end)
        if not powered and not d.coldSaid then d.coldSaid = true; say(shell, "Fridge isn't running. This stuff's going to spoil in here.") end
    end
    for _, it in ipairs(j.items) do
        local iw = 0
        pcall(function() iw = it:getActualWeight() end)
        if hasRoom(c, iw) and pcall(function() inv:DoRemoveItem(it); c:AddItem(it) end) then
            M.cpStats.hauled = M.cpStats.hauled + 1
        else
            left[#left + 1] = it
        end
    end
    j.items = left
    if #left == 0 then d.overflowSaid = nil; return "done" end
    -- more than fits: the next drop point, or the overflow pile
    local w = nil
    for _, it in ipairs(left) do local iw = 0.1; pcall(function() iw = it:getActualWeight() end); if w == nil or iw < w then w = iw end end
    local nxt = M.cpBestDrop(j.cat, j.to.x, j.to.y, w)
    if nxt and dropKey(nxt.x, nxt.y, nxt.z) ~= dropKey(j.to.x, j.to.y, j.to.z) then j.to = nxt; return "next" end
    if M.cpOpt("CPHaulOverflow") ~= false then j.to = overflowSpot(j.cat); if j.to then return "next" end end
    if not d.fullSaid then d.fullSaid = true; say(shell, "No room left for the " .. string.lower(M.cpCatLabel[j.cat]) .. ". I'll hold onto it.") end
    return "fail"
end
-- never lose an item: whatever a hauler still holds goes back where it came from (or at their feet)
function M.cpDropHeld(j, shell)
    if j == nil or type(j.items) ~= "table" or #j.items == 0 then return end
    local inv = invOf(shell)
    local x, y, z = pos(shell)
    local sq = (x and sqAt(x, y, z)) or (j.from and sqAt(j.from.x, j.from.y, j.from.z))
    for _, it in ipairs(j.items) do
        local held = false
        pcall(function() held = it:getContainer() == inv end)
        if held and sq then pcall(function() inv:DoRemoveItem(it); sq:AddWorldInventoryItem(it, 0.5, 0.5, 0) end) end
    end
    j.items = {}
end


----------------------------------------------------------------------------------------------------------------
-- 0.5.1 FORTIFY YOUR BASE: the same real building NPC bases do (board windows, log palisade, a gate), pointed at
-- your house. Materials come from the stockpile container you pick (Camp > Fortify). With "only your materials"
-- (default) they never chop, strip or salvage anything: they build from what you put in the stockpile.
-- Builders do it if you have any; otherwise anyone at home who isn't a guard, on watch or busy with another job.
-- Only while you're near (no unseen progress at your base).
----------------------------------------------------------------------------------------------------------------
function M.cpFortData()
    local d = M.cpData()
    d.fort = type(d.fort) == "table" and d.fort or {}
    d.fort.bd = type(d.fort.bd) == "table" and d.fort.bd or {}
    return d.fort
end
function M.cpFortOn() return M.cpOpt("CPFortify") ~= false and M.cpFortData().on == true end
M.cpFortB = nil
function M.cpFortBase(player)
    if not M.cpFortOn() then return nil end
    local base = fn(M, "wzBase") and M.wzBase(player or thePlayer()) or nil
    if base == nil then return nil end
    local f = M.cpFortData()
    local b = M.cpFortB
    if b == nil or b.key ~= base.key then
        b = { key = base.key }
        M.cpFortB = b
    end
    b.id, b.name, b.status, b.playerBase = "player:" .. tostring(base.key), "your base", "active", true
    b.x, b.y, b.z = base.x, base.y, base.z or 0
    b.bounds = { x1 = base.x1, y1 = base.y1, x2 = base.x2, y2 = base.y2 }
    b.depot = f.depot
    b.bd = f.bd -- saved with your camp: what's built, the want list
    return b
end
function M.cpFortWorker(uid, player)
    uid = tostring(uid)
    if not M.cpIsHome(uid, player) then return false end
    local role = M.cpRoleOf(uid)
    if role == "guard" or M.cpWatcher(player) == uid or M.cpData().patrollers[uid] then return false end
    local j = M.cpJobs[uid]
    if j ~= nil then return false end
    if type(M.wzJobs) == "table" and M.wzJobs[uid] then return false end
    if #M.cpWithRole("builder", player) > 0 then return role == "builder" end
    return true
end
function M.cpFortInstall()
    if M._cpFortWrapped then return true end
    if not (fn(M, "bdBaseOf") and fn(M, "bdDepot") and fn(M, "bdContainer") and fn(M, "bdScanStep")) then return false end
    local baseOf, depot, cont = M.bdBaseOf, M.bdDepot, M.bdContainer
    M.bdBaseOf = function(actor, ...)
        local b = baseOf(actor, ...)
        if b ~= nil then return b end
        if type(actor) ~= "table" or not M.cpFortOn() then return nil end
        local player = thePlayer()
        local ok, yes = pcall(M.cpFortWorker, actor.uid, player)
        if ok and yes then return M.cpFortBase(player) end
        return nil
    end
    M.bdDepot = function(b, ...)
        if type(b) == "table" and b.playerBase then return b.depot or { x = b.x, y = b.y, z = b.z or 0 } end
        return depot(b, ...)
    end
    M.bdContainer = function(b, ...)
        if type(b) == "table" and b.playerBase then
            local dp = b.depot
            local sq = dp and sqAt(dp.x, dp.y, dp.z or 0)
            return sq and (containerOn(sq)) or nil
        end
        return cont(b, ...)
    end
    M._cpFortWrapped = true
    log("fortify: hooked into NPC base building")
    return true
end
-- your base is seen work only: scan (when you allow gathering) while you're near
function M.cpFortTick(player)
    if not M.cpFortOn() or not M._cpFortWrapped then return end
    local b = M.cpFortBase(player)
    if b == nil then return end
    local px, py = pos(player)
    if px == nil or d2(b.x, b.y, px, py) > M.cpCfg.loadedTiles ^ 2 then return end
    if M.cpOpt("CPFortifyOwn") == false then pcall(M.bdScanStep, b, hours()) end
end
function M.cpFortStart(player, on)
    local f = M.cpFortData()
    if on and f.depot == nil then return false, "Pick a stockpile first: right-click a container > Camp > Fortify > Stockpile here." end
    f.on = on and true or nil
    if on then
        local ok = pcall(M.cpFortInstall)
        log("fortify " .. (on and "on" or "off") .. (ok and "" or " (building module not found)"))
    end
    return true
end
----------------------------------------------------------------------------------------------------------------
-- jobs (one per person): watch > patrol > haul
----------------------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------------------
-- 0.5.2 FARM DUTY: farmers water thirsty crops (fetching water from the spot you mark) and pick what's ripe,
-- then carry the food to your fresh-food drop point. Uses vanilla's own farming system (single player: the
-- server farming objects live in the same Lua), so yields, seeds and regrowing crops are vanilla's.
-- Water comes out of the barrel / sink you mark, the same way vanilla takes it (0.5.6.1).
----------------------------------------------------------------------------------------------------------------
function M.cpFarmData()
    local d = M.cpData()
    d.farm = type(d.farm) == "table" and d.farm or {}
    return d.farm
end
function M.cpFarmOn() return M.cpOpt("CPFarm") ~= false and M.cpFarmData().off ~= true end
local function farmSys() local S = SFarmingSystem; return type(S) == "table" and S.instance or nil end
M.cpFarmScan, M.cpFarmScanAt = nil, -1e12
-- live plants at the base: { ripe = {...}, dry = {...} } of { x, y, z, lvl }
function M.cpFarmList(b, now)
    if M.cpFarmScan and now - M.cpFarmScanAt < M.cpCfg.farmScanMs then return M.cpFarmScan end
    local out = { ripe = {}, dry = {} }
    local sys = farmSys()
    if sys == nil or b == nil then M.cpFarmScan, M.cpFarmScanAt = out, now; return out end
    local x1, y1, x2, y2 = b.x1, b.y1, b.x2, b.y2
    if x1 == nil then local r = M.cpCfg.farmRange; x1, y1, x2, y2 = b.x - r, b.y - r, b.x + r, b.y + r end
    local waterAt = tonumber(M.cpOpt("CPFarmWaterAt")) or 40
    local harvest = M.cpOpt("CPFarmHarvest") ~= false
    tryOnce("farmScan", function()
        for i = 1, sys:getLuaObjectCount() do
            local p = sys:getLuaObjectByIndex(i)
            local px, py = tonumber(p and p.x), tonumber(p and p.y)
            if px and px >= x1 and px <= x2 and py >= y1 and py <= y2 and p.typeOfSeed and p.typeOfSeed ~= "none"
                and p.state ~= "plow" and p.state ~= "dead" and p.state ~= "rotten" and p.state ~= "destroyed" and p.state ~= "harvested" then
                local t = { x = px, y = py, z = tonumber(p.z) or 0, lvl = tonumber(p.waterLvl) or 100 }
                if harvest and type(p.canHarvest) == "function" and p:canHarvest() then out.ripe[#out.ripe + 1] = t
                elseif t.lvl < waterAt then out.dry[#out.dry + 1] = t end
            end
        end
    end)
    M.cpFarmScan, M.cpFarmScanAt = out, now
    return out
end
local function plantAt(t) local sys = farmSys(); return sys and sys:getLuaObjectAt(t.x, t.y, t.z or 0) or nil end
-- stand beside the plant, never on a plot (NPC bodies can trample crops)
local function besideSpot(t)
    local sys = farmSys()
    for _, o in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local x, y = t.x + o[1], t.y + o[2]
        local occupied = false
        pcall(function() occupied = sys:getLuaObjectAt(x, y, t.z or 0) ~= nil end)
        if not occupied and sqAt(x, y, t.z) then return { x = x, y = y, z = t.z or 0 } end
    end
    return { x = t.x, y = t.y, z = t.z or 0 }
end
-- a farming skill for vanilla's yield roll: 0..8 from how good they are at it
local function farmSkill(uid) local f = M.cpFit(uid, "farmer"); return math.max(0, math.min(8, math.floor((f - 0.3) / 1.3 * 8 + 0.5))) end
local function harvestInto(t, shell, uid, j)
    local inv = invOf(shell)
    local p = plantAt(t)
    if inv == nil or p == nil or not p:canHarvest() then return 0 end
    local before = {}
    pcall(function() local items = inv:getItems(); for i = 0, items:size() - 1 do before[items:get(i)] = true end end)
    -- vanilla puts the crop in "the player's" inventory: hand it the farmer's pockets instead
    local skill = farmSkill(uid)
    local hands = { getPerkLevel = function() return skill end, getInventory = function() return inv end,
        getStats = function() return { remove = function() end } end }
    if not tryOnce("harvest", function() farmSys():harvest(p, hands) end) then return 0 end
    local x, y, z = pos(shell)
    local sq = x and sqAt(x, y, z)
    local n = 0
    pcall(function()
        local items = inv:getItems()
        local got = {}
        for i = 0, items:size() - 1 do local it = items:get(i); if not before[it] then got[#got + 1] = it end end
        for _, it in ipairs(got) do
            if M.cpCatOf(it) == "fresh" then j.items[#j.items + 1] = it; n = n + 1
            elseif sq then pcall(function() inv:DoRemoveItem(it); sq:AddWorldInventoryItem(it, 0.5, 0.5, 0) end) end -- seeds: left by the plot
        end
    end)
    M.cpStats.harvested = M.cpStats.harvested + 1
    if n > 0 then M.cpLog("harvest", firstName(uid) .. " brought in the harvest") end
    return n
end
-- B42 water: 1 "use" = vanilla's farming millilitres per use (200 ml); a farmer carries up to 40 uses (8 L) a trip
local function mlPerUse() local v = nil; pcall(function() v = tonumber(ZomboidGlobals.farmingFluidContainerMillilitresPerUse) end); return v or 200 end
local function usesFor(t) local p = plantAt(t); local lvl = p and tonumber(p.waterLvl) or 0; return math.max(1, math.ceil((85 - lvl) / 10)) end
-- the object holding water on the marked square (rain barrel, plumbed sink, well, trough...)
local function waterSource(spot)
    local sq = spot and sqAt(spot.x, spot.y, spot.z)
    if sq == nil then return nil end
    local best, amt = nil, 0
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local a = 0
            pcall(function() a = tonumber(o:getFluidAmount()) or 0 end)
            if a > amt then best, amt = o, a end
        end
    end)
    return best, amt
end
-- fill up: take the water this trip needs out of the source, the way vanilla does (moveFluidToTemporaryContainer)
-- returns uses carried, or 0 (dry / nothing there). If the fluid API is missing: one log line, then free water as before.
function M.cpFetchWater(j)
    local want = 0
    for _, t in ipairs(j.queue) do want = want + usesFor(t) end
    want = math.min(want, M.cpCfg.waterTripUses)
    if retired.fluid then return want end
    local src, have = waterSource(M.cpFarmData().water)
    if src == nil or have <= 0 then return 0 end
    local per = mlPerUse() / 1000
    local uses = math.min(want, math.floor(have / per))
    if uses <= 0 then return 0 end
    local ok = tryOnce("fluid", function()
        local fc = src:moveFluidToTemporaryContainer(uses * per)
        FluidContainer.DisposeContainer(fc)
    end)
    if not ok then return want end
    M.cpStats.litres = (M.cpStats.litres or 0) + uses * per
    return uses
end
local function waterOne(t, budget)
    local p = plantAt(t)
    if p == nil or type(p.water) ~= "function" then return 0 end
    local uses = math.min(usesFor(t), budget or 99)
    if uses <= 0 then return 0 end
    if not tryOnce("water", function() p:water(nil, uses) end) then return 0 end
    M.cpStats.watered = M.cpStats.watered + 1
    return uses
end
function M.cpFarmJob(uid, shell, b, now)
    if not M.cpFarmOn() or M.cpRoleOf(uid) ~= "farmer" then return nil end
    local list = M.cpFarmList(b, now)
    local sx, sy = pos(shell)
    local function claimed(t) local k = "farm:" .. t.x .. ":" .. t.y; return (M.cpClaims[k] ~= nil and M.cpClaims[k] ~= uid) or (M.cpBans[k] or 0) > now end
    for _, t in ipairs(list.ripe) do
        if not claimed(t) then
            local key = "farm:" .. t.x .. ":" .. t.y
            M.cpClaims[key] = uid
            return { kind = "harvest", key = key, cat = "fresh", step = "take", items = {}, plant = t, from = besideSpot(t) }
        end
    end
    local fd = M.cpFarmData()
    if #list.dry > 0 and fd.water and (tonumber(fd.dryUntil) or -1) <= hours() then
        local q = {}
        for _, t in ipairs(list.dry) do if #q < M.cpCfg.farmPerTrip and not claimed(t) then q[#q + 1] = t end end
        if #q == 0 then return nil end
        table.sort(q, function(a, c) return d2(a.x, a.y, sx or a.x, sy or a.y) < d2(c.x, c.y, sx or c.x, sy or c.y) end)
        for _, t in ipairs(q) do M.cpClaims["farm:" .. t.x .. ":" .. t.y] = uid end
        return { kind = "water", key = "farmwater:" .. uid, step = "fill", queue = q, i = 1 }
    end
    if #list.dry > 0 and not fd.noWaterSaid then
        fd.noWaterSaid = true
        say(shell, "The crops need water. Where do I get it from?")
        halo("Right-click your rain barrel or well > Camp > Farm > Water from here.")
    end
    return nil
end

M.cpJobs, M.cpClaims, M.cpBans, M.cpNextTry = {}, {}, {}, {}
----------------------------------------------------------------------------------------------------------------
-- plug-in jobs (0.5.3+): other camp files add job kinds here.
-- M.cpAddJob{ kind=, order=, pick=function(uid, shell, player, b, now) -> job|nil, spot=function(j) -> {x,y,z},
--   ms=function(j) -> ms, run=function(j, uid, shell, player) -> "next"|"again"|"done"|"fail", release=function(j, uid, shell) }
-- order < 0 runs before the night watch (the bitten), order >= 0 after patrol and before farm duty.
----------------------------------------------------------------------------------------------------------------
M.cpKinds, M.cpPlugs = {}, {}
function M.cpAddJob(def)
    M.cpKinds[def.kind] = def
    for i = #M.cpPlugs, 1, -1 do if M.cpPlugs[i].kind == def.kind then table.remove(M.cpPlugs, i) end end
    M.cpPlugs[#M.cpPlugs + 1] = def
    table.sort(M.cpPlugs, function(a, c) return (a.order or 0) < (c.order or 0) end)
end
local function plugPick(uid, shell, player, b, now, early)
    for _, def in ipairs(M.cpPlugs) do
        if ((def.order or 0) < 0) == early then
            local ok, j = pcall(def.pick, uid, shell, player, b, now)
            if not ok then log("job pick error (" .. def.kind .. "): " .. tostring(j))
            elseif j then j.kind = def.kind; return j end
        end
    end
    return nil
end
-- helpers the plug-ins share
M.cpH = { sqAt = sqAt, containerOn = containerOn, invOf = invOf, hasRoom = hasRoom, isCold = isCold, say = say, halo = halo,
    pos = pos, d2 = d2, hash = hash, pickLine = pickLine, tryOnce = tryOnce, hours = hours, hourOfDay = hourOfDay,
    rec = rec, shellFor = shellFor, firstName = firstName, thePlayer = thePlayer, log = log, PA = PA, fn = fn, hasAny = hasAny, isA = isA,
    putDown = function(...) return putDown(...) end, overflowSpot = function(...) return overflowSpot(...) end, retired = retired }
-- the camp's day: what happened, for evening talk, the camp board and the AI (kept 48 game hours)
function M.cpLog(kind, text)
    local d = M.cpData()
    d.dayLog = type(d.dayLog) == "table" and d.dayLog or {}
    local h = hours()
    table.insert(d.dayLog, { h = h, k = tostring(kind), t = tostring(text) })
    while #d.dayLog > 0 and h - (tonumber(d.dayLog[1].h) or 0) > 48 do table.remove(d.dayLog, 1) end
    while #d.dayLog > 40 do table.remove(d.dayLog, 1) end
end
function M.cpToday(maxH)
    local d = M.cpData()
    local out, h = {}, hours()
    for _, e in ipairs(type(d.dayLog) == "table" and d.dayLog or {}) do if h - (tonumber(e.h) or 0) <= (maxH or 24) then out[#out + 1] = e end end
    return out
end
function M.cpRelease(uid, shell)
    uid = tostring(uid)
    local j = M.cpJobs[uid]
    if j == nil then return end
    if j.kind == "haul" or j.kind == "harvest" or (M.cpKinds[j.kind] and type(j.items) == "table") then M.cpDropHeld(j, shell or shellFor(uid)) end
    local def = M.cpKinds[j.kind]
    if def and def.release then pcall(def.release, j, uid, shell or shellFor(uid)) end
    if j.key and M.cpClaims[j.key] == uid then M.cpClaims[j.key] = nil end
    if j.kind == "water" then for _, t in ipairs(j.queue or {}) do local k = "farm:" .. t.x .. ":" .. t.y; if M.cpClaims[k] == uid then M.cpClaims[k] = nil end end end
    M.cpJobs[uid] = nil
end
local function haulers()
    local n = 0
    for _, j in pairs(M.cpJobs) do if j.kind == "haul" then n = n + 1 end end
    return n
end
function M.cpPick(uid, shell, player, now)
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    if b == nil then return nil end
    local d = M.cpData()
    -- 0) urgent plug-ins (the bitten go to quarantine)
    local pj = plugPick(uid, shell, player, b, now, true)
    if pj then return pj end
    -- 1) night watch
    if M.cpWatcher(player) == uid then
        return { kind = "watch", key = "watch", spot = { x = b.x, y = b.y, z = b.z or 0 } }
    end
    -- 2) patrol (by day; at night only if there's no night watch)
    if M.cpIsPatroller(uid, player) and (not isNight() or M.cpOpt("CPNightWatch") == false) then
        local pts = M.cpPatrolPoints()
        local i = ((tonumber(d.patrolNext and d.patrolNext[uid]) or 0) % #pts) + 1
        return { kind = "patrol", key = "patrol:" .. uid, i = i }
    end
    -- 3) plug-in jobs (meals, armory)
    pj = plugPick(uid, shell, player, b, now, false)
    if pj then return pj end
    -- 3b) farm duty (farmers only)
    local fj = M.cpFarmJob(uid, shell, b, now)
    if fj then return fj end
    -- 4) haul & sort
    if d.haulOn and haulers() < M.cpCfg.haulers and hasAny(d.drops) and #d.areas > 0 then
        local list = M.cpHaulList(now)
        local sx, sy = pos(shell)
        local builder = M.cpRoleOf(uid) == "builder"
        local best, bd = nil, nil
        for _, t in ipairs(list) do
            local key = "haul:" .. t.x .. ":" .. t.y .. ":" .. t.cat
            if (M.cpClaims[key] == nil or M.cpClaims[key] == uid) and (M.cpBans[key] or 0) <= now then
                local dd = d2(t.x, t.y, sx or t.x, sy or t.y)
                if builder and t.cat == "materials" then dd = dd - 1e6 end
                if bd == nil or dd < bd then best, bd = t, dd end
            end
        end
        if best then
            local key = "haul:" .. best.x .. ":" .. best.y .. ":" .. best.cat
            M.cpClaims[key] = uid
            return { kind = "haul", key = key, cat = best.cat, ground = best.ground, step = "take", items = {},
                from = { x = best.x, y = best.y, z = best.z } }
        end
    end
    return nil
end
local function stepSpot(j)
    if M.cpKinds[j.kind] then return M.cpKinds[j.kind].spot(j) end
    if j.kind == "watch" then return j.spot end
    if j.kind == "patrol" then return M.cpPatrolPoints()[j.i] end
    if j.kind == "haul" or j.kind == "harvest" then return j.step == "take" and j.from or j.to end
    if j.kind == "water" then
        if j.step == "fill" then return M.cpFarmData().water end
        local t = j.queue[j.i]
        if t then j.at = j.at or besideSpot(t) end
        return t and j.at or nil
    end
    return nil
end
local function stepMs(j)
    if M.cpKinds[j.kind] then return M.cpKinds[j.kind].ms(j) end
    if j.kind == "watch" then return M.cpCfg.watchScanMs end
    if j.kind == "patrol" then return M.cpCfg.patrolWaitMs end
    if j.kind == "water" then return j.step == "fill" and M.cpCfg.fillMs or M.cpCfg.waterMs end
    if j.kind == "harvest" and j.step == "take" then return M.cpCfg.harvestMs end
    return j.step == "take" and M.cpCfg.takeMs or M.cpCfg.putMs
end
-- finish the step: "next" | "done" | "again" | "fail"
function M.cpDo(j, uid, shell, player)
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    if M.cpKinds[j.kind] then return M.cpKinds[j.kind].run(j, uid, shell, player) end
    if j.kind == "watch" then
        if M.cpWatcher(player) ~= uid then return "done" end
        local x, y = pos(shell)
        M.cpLook(uid, shell, player, x, y, M.cpCfg.watchTiles, true, b)
        return "again"
    end
    if j.kind == "patrol" then
        local p = M.cpPatrolPoints()[j.i]
        if p == nil then return "done" end
        M.cpStats.patrols = M.cpStats.patrols + 1
        M.cpLook(uid, shell, player, p.x, p.y, M.cpCfg.patrolScanTiles, false, b)
        local d = M.cpData()
        d.patrolNext = type(d.patrolNext) == "table" and d.patrolNext or {}
        d.patrolNext[uid] = j.i
        return "done"
    end
    if j.kind == "water" then
        if j.step == "fill" then
            j.uses = M.cpFetchWater(j)
            if j.uses <= 0 then
                local fd = M.cpFarmData()
                fd.dryUntil = hours() + 1
                if (fd.drySaid or -1) ~= math.floor(hours() / 24) then fd.drySaid = math.floor(hours() / 24); say(shell, "The water's dry here. Crops'll have to wait for rain.") end
                return "done"
            end
            j.step = "water"
            return "next"
        end
        j.uses = (j.uses or 99) - waterOne(j.queue[j.i], j.uses)
        local k = "farm:" .. j.queue[j.i].x .. ":" .. j.queue[j.i].y
        if M.cpClaims[k] == uid then M.cpClaims[k] = nil end
        j.i, j.at = j.i + 1, nil
        M.cpFarmScan = nil
        if j.queue[j.i] == nil or (j.uses or 0) <= 0 then return "done" end
        return "next"
    end
    if j.kind == "harvest" then
        if j.step == "take" then
            local n = harvestInto(j.plant, shell, uid, j)
            M.cpFarmScan = nil
            if n == 0 then return "done" end
            j.minW = nil
            for _, it in ipairs(j.items) do local iw = 0.1; pcall(function() iw = it:getActualWeight() end); if j.minW == nil or iw < j.minW then j.minW = iw end end
            j.to = M.cpBestDrop("fresh", j.from.x, j.from.y, j.minW)
            if j.to == nil and M.cpOpt("CPHaulOverflow") ~= false then j.to = overflowSpot("fresh") end
            if j.to == nil then
                local fd = M.cpFarmData()
                if not fd.noDropSaid then fd.noDropSaid = true; say(shell, "Nowhere to put the food. I'm leaving it by the field.") end
                return "fail"
            end
            j.step = "put"
            return "next"
        end
        return putDown(j, shell, uid)
    end
    if j.kind == "haul" then
        if j.step == "take" then
            local n = takeFrom(j, shell)
            M.cpScan = nil
            if n == 0 then return "done" end
            M.cpStats.trips = M.cpStats.trips + 1
            j.to = M.cpBestDrop(j.cat, j.from.x, j.from.y, j.minW)
            if j.to == nil and M.cpOpt("CPHaulOverflow") ~= false then j.to = overflowSpot(j.cat) end
            if j.to == nil then return "fail" end
            j.step = "put"
            return "next"
        end
        return putDown(j, shell, uid)
    end
    return "fail"
end
function M.cpEvaluate(actor, shell, context)
    if shell == nil or type(context) ~= "table" or type(actor) ~= "table" then return nil end
    local uid = tostring(actor.uid)
    local j = M.cpJobs[uid]
    if context.threat ~= nil then
        if j then M.cpRelease(uid, shell) end
        return nil
    end
    local d = M.cpData()
    if j == nil and #d.patrol == 0 and not hasAny(d.drops) and M.cpOpt("CPNightWatch") == false and M.cpRoleOf(uid) ~= "farmer" and #M.cpPlugs == 0 then return nil end
    if type(M.wzJobs) == "table" and M.wzJobs[uid] then return nil end -- busy with bodies
    local player = M.homePlayer and M.homePlayer(pos(shell)) or thePlayer() -- MP: the base's player nearest them
    if fn(M, "alHolds") and M.alHolds(uid, player) then -- alarm: drop everything
        if j then M.cpRelease(uid, shell) end
        return nil
    end
    if not M.cpIsHome(uid, player) then
        if j then M.cpRelease(uid, shell) end
        return nil
    end
    local inCar = false
    pcall(function() inCar = shell:getVehicle() ~= nil end)
    if inCar or (fn(M, "withPlayer") and M.withPlayer(uid, player)) then -- 0.6.12: following you / in a vehicle: no camp job pulls them away
        if j then M.cpRelease(uid, shell) end
        return nil
    end
    M.cpStats.evals = M.cpStats.evals + 1
    local now = tonumber(context.now) or nowMs()
    CLOCK.t, CLOCK.at = now, rawMs()
    -- the watcher drops whatever else they were doing when night falls
    if j and j.kind ~= "watch" and M.cpWatcher(player) == uid then M.cpRelease(uid, shell); j = nil end
    if j == nil then
        if (M.cpNextTry[uid] or 0) > now then return nil end
        j = M.cpPick(uid, shell, player, now)
        if j == nil then M.cpNextTry[uid] = now + M.cpCfg.retryMs; return nil end
        j.started = now
        M.cpJobs[uid] = j
    end
    local spot = stepSpot(j)
    if spot == nil then M.cpRelease(uid, shell); return nil end
    local sx, sy = pos(shell)
    if sx == nil then M.cpRelease(uid, shell); return nil end
    if d2(sx, sy, spot.x + 0.5, spot.y + 0.5) > 1.8 ^ 2 then
        j.workFrom = nil
        if now - (j.stepAt or j.started) > M.cpCfg.walkTimeoutMs then
            if j.key then M.cpBans[j.key] = now + M.cpCfg.banMs end
            M.cpStats.bans = M.cpStats.bans + 1
            if j.kind == "patrol" then local dd = M.cpData(); dd.patrolNext = dd.patrolNext or {}; dd.patrolNext[uid] = j.i end -- skip a point they can't reach
            M.cpRelease(uid, shell)
            return nil
        end
        if type(context.startMovement) ~= "function" then M.cpRelease(uid, shell); return nil end
        return context.startMovement(actor, shell, { x = spot.x + 0.5, y = spot.y + 0.5, z = spot.z or 0 }, "chatplus_" .. j.kind,
            { pace = "walk", timeoutMs = 15000, tolerance = 1.2 })
    end
    j.workFrom = j.workFrom or now
    if type(context.setActivity) == "function" then pcall(context.setActivity, actor, "idle", "chatplus_" .. j.kind) end
    local animName = (M.cpKinds[j.kind] and j.anim) or ((j.kind == "haul" or j.kind == "harvest" or (j.kind == "water" and j.step == "water")) and "search_low") or nil
    if animName then local anim = PA().Animations; if fn(anim, "apply") then pcall(anim.apply, shell, animName) end end
    if now - j.workFrom < stepMs(j) then return { kind = "idle", intent = "chatplus_" .. j.kind, cooldownUntilMs = now + 1000 } end
    local ok, res = pcall(M.cpDo, j, uid, shell, player)
    if animName then local anim = PA().Animations; if fn(anim, "clear") then pcall(anim.clear, shell) end end
    if not ok then log("step error (" .. tostring(j.kind) .. "): " .. tostring(res)); res = "fail" end
    if res == "next" then j.workFrom = nil; j.stepAt = now
    elseif res == "again" then j.workFrom = nil
    else
        if res == "fail" and j.key then M.cpBans[j.key] = now + 30000 end
        M.cpRelease(uid, shell)
    end
    return { kind = "idle", intent = "chatplus_" .. j.kind, cooldownUntilMs = now + 1500 }
end
function M.cpRegister()
    if M._cpRegistered then return true end
    local reg = PA().ModuleRegistry
    if not fn(reg, "register") then return false end
    local ok, done, why = pcall(reg.register, {
        id = "chatplus_camp", label = "NPC Overhaul: camp",
        summary = "People at your base walk the patrol, keep the night watch and haul and sort supplies.",
        kind = "orders", priority = 91, defaultEnabled = true,
        evaluate = function(actor, shell, context)
            local ok2, res = pcall(M.cpEvaluate, actor, shell, context)
            if not ok2 then
                if not M._cpErr then M._cpErr = true; log("module error (logged once): " .. tostring(res)) end
                return nil
            end
            return res
        end,
    })
    if ok and (done == true or (done == false and tostring(why):find("duplicate", 1, true))) then
        local prof = PA().BehaviorProfiles
        local n = 0
        if type(prof) == "table" and type(prof.definitions) == "table" then
            for _, def in ipairs(prof.definitions) do
                if type(def) == "table" and type(def.overlays) == "table" then def.overlays.chatplus_camp = true; n = n + 1 end
            end
        end
        if n == 0 then log("A-Life behaviour profiles not found - camp jobs may never run") end
        M._cpRegistered = true
        log("registered with A-Life's behaviour modules (priority 91, " .. n .. " profiles)")
        return true
    end
    log("could not register with A-Life: " .. tostring(why or done))
    return false
end

----------------------------------------------------------------------------------------------------------------
-- tick (1 s): registration, medics, hourly hearsay, the daily food-rule check (before 18:00's unrest check)
----------------------------------------------------------------------------------------------------------------
M.cpLastTick = 0
function M.cpTick()
    local now = rawMs()
    if now - M.cpLastTick < M.cpCfg.tickMs then return end
    M.cpLastTick = now
    if not M._cpRegistered then pcall(M.cpRegister) end
    M.cpWrapTake()
    local player = M.homePlayer and M.homePlayer() or thePlayer() -- MP: one shared camp, run once for its player
    if player == nil then return end
    local d = M.cpData()
    local h = hours()
    pcall(M.cpMedics, player, now)
    pcall(M.cpFortTick, player)
    local hr = math.floor(h)
    if d.lastHour ~= hr then
        d.lastHour = hr
        pcall(M.cpHearsay, player)
        if hourOfDay() == 17 then pcall(M.cpFoodCheck, player) end
        if hourOfDay() == 19 then pcall(M.cpContent, player) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the right-click menu: Camp > Roles / Rules / Patrol / Haul & sort / Farm / Fortify / Alarm
----------------------------------------------------------------------------------------------------------------
M.cpSel = nil -- { x, y, z } first corner of a collect area
M.cpShow = false
-- pre-1.0 MP (P4): EVERY CAMP MENU WRITE, in one place. Single player: the menu calls it directly (what each menu
-- option did before, unchanged). MP client: ALifeRemote forwards it to the server, which runs it as the sender
-- (plain values only; checked here, since a client can send anything). Returns true when something changed.
local function num(v) v = tonumber(v); if v == nil then return nil end; return math.floor(v) end
M.cpNum = num
-- plug-ins add their writes here: M.cpActs[kind] = function(player, a, b, c, d, e) ... end (false = nothing changed)
M.cpActs = M.cpActs or {}
function M.cpAct(kind, a, b, c, d5, e, player)
    player = player or thePlayer()
    kind = tostring(kind)
    local d = M.cpData()
    local function spot() local x, y, z = num(a), num(b), num(c) or 0; if x == nil or y == nil then return nil end; return x, y, z end
    local function reach(x, y) if fn(M, "wzInRange") then return M.wzInRange(player, x, y) end; return true end
    if kind == "role" then
        local uid, role = tostring(a), tostring(b)
        if M.cpRoleLabel[role] == nil then return false end
        local line = M.cpSetRole(uid, role, player)
        if not say(shellFor(uid), line) then halo(firstName(uid) .. ": " .. tostring(line)) end
    elseif kind == "rule" then
        local r = RULE[tostring(a)]
        if r == nil then return false end
        local want = b == true
        d.rules[r.id] = want or nil
        halo(want and ("New camp rule: " .. r.label .. ". Your people will hold you to it.") or ("Rule dropped: " .. r.label))
    elseif kind == "patrolAdd" then
        local x, y, z = spot()
        if x == nil or #d.patrol >= (tonumber(M.cpOpt("CPPatrolPoints")) or 5) or not reach(x, y) then return false end
        d.patrol[#d.patrol + 1] = { x = x, y = y, z = z }
        halo("Patrol point " .. #d.patrol .. " set. Guards walk the points in order.")
        if #M.cpWithRole("guard", player) == 0 then halo("Nobody's a guard yet. Camp > Roles, or tell someone to walk the patrol.", 255, 200, 120) end
    elseif kind == "patrolPop" then
        table.remove(d.patrol); d.patrolNext = {}
    elseif kind == "patrolClear" then
        for i = #d.patrol, 1, -1 do d.patrol[i] = nil end; d.patrolNext = {}
    elseif kind == "patrolPause" then
        d.patrolOff = a == true
    elseif kind == "area" then
        local x1, y1, x2, y2, z = num(a), num(b), num(c), num(d5), num(e) or 0
        if x1 == nil or y1 == nil or x2 == nil or y2 == nil or #d.areas >= M.cpCfg.maxHaulAreas then return false end
        if math.abs(x2 - x1) + 1 > M.cpCfg.maxSide or math.abs(y2 - y1) + 1 > M.cpCfg.maxSide or not reach(x2, y2) then return false end
        local ar = { id = d.nextArea, x1 = math.min(x1, x2), y1 = math.min(y1, y2), x2 = math.max(x1, x2), y2 = math.max(y1, y2), z = z }
        d.nextArea = d.nextArea + 1
        d.areas[#d.areas + 1] = ar
        M.cpScan = nil
        halo("Collect area set. Now right-click containers > Camp > Haul & sort to set drop points.")
    elseif kind == "areaRemove" then
        local x, y, z = spot()
        local ai = nil
        if x ~= nil then local _, i = M.cpAreaAt(x, y, z); ai = i end
        if ai == nil then return false end
        table.remove(d.areas, ai); M.cpScan = nil
    elseif kind == "dropRemove" then
        local x, y, z = spot()
        if x == nil or not M.cpRemoveDrop(x, y, z) then return false end
    elseif kind == "dropAdd" then
        local cat = tostring(a)
        local x, y, z = num(b), num(c), num(d5) or 0
        if M.cpCatLabel[cat] == nil or x == nil or y == nil or not reach(x, y) then return false end
        local ok, why2 = M.cpAddDrop(cat, x, y, z)
        if ok then halo("Drop point set: " .. string.lower(M.cpCatLabel[cat]) .. ".") else halo("Can't: " .. tostring(why2) .. ".", 255, 150, 110); return false end
    elseif kind == "haul" then
        d.haulOn = a == true
    elseif kind == "farmWaterStop" then
        M.cpFarmData().water = nil
    elseif kind == "farmWater" then
        local x, y, z = spot()
        if x == nil or not reach(x, y) then return false end
        local fdat = M.cpFarmData()
        fdat.water, fdat.noWaterSaid = { x = x, y = y, z = z }, nil
        halo("Farmers fill up here, then water the thirsty crops at the base.")
        if #M.cpWithRole("farmer", player) == 0 then halo("Nobody's a farmer yet. Camp > Roles.", 255, 200, 120) end
    elseif kind == "farmPause" then
        M.cpFarmData().off = (a == true) or nil
    elseif kind == "fortDepot" then
        local x, y, z = spot()
        if x == nil or not reach(x, y) then return false end
        M.cpFortData().depot = { x = x, y = y, z = z }
        halo("Stockpile set. Put logs, planks, nails, hinges and doorknobs in it. They build from what's there.")
    elseif kind == "fortStop" then
        M.cpFortStart(player, false); halo("They'll stop fortifying.")
    elseif kind == "fortStart" then
        local ok, msg = M.cpFortStart(player, true)
        halo(ok and (M.cpOpt("CPFortifyOwn") ~= false and "They'll board the windows and raise a palisade from your stockpile." or "They'll fortify, and gather wood if the stockpile runs dry.") or msg)
        if not ok then return false end
    elseif type(M.cpActs[kind]) == "function" then -- a camp plug-in's own menu write (alarm, armory, cook, ...)
        local ok, res = pcall(M.cpActs[kind], player, a, b, c, d5, e)
        if not ok then log("menu " .. kind .. " failed: " .. tostring(res)); return false end
        if res == false then return false end
    else
        return false
    end
    cpTouch()
    return true
end
function M.cpContext(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    local sq = nil
    for _, o in ipairs(worldobjects or {}) do
        pcall(function() sq = o:getSquare() end)
        if sq then break end
    end
    if sq == nil or player == nil then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    local d = M.cpData()
    local parent = context:addOption(ALifeTr("IGUI_ALCP_Menu_Camp", "Camp"))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(parent, sub)
    local function off(opt, reason)
        opt.notAvailable = true
        local tip = ISWorldObjectContextMenu.addToolTip()
        tip.description = reason
        opt.toolTip = tip
    end
    local function child(label)
        local o = sub:addOption(label)
        local m = ISContextMenu:getNew(sub)
        sub:addSubMenu(o, m)
        return m, o
    end
    if b == nil then
        off(sub:addOption(ALifeTr("IGUI_ALCP_Menu_You_need_a_base_first", "You need a base first")), "Camp roles, rules, patrols and sorting work at your A-Life base.")
        return
    end
    local inRange, why = true, nil
    if fn(M, "wzInRange") then inRange, why = M.wzInRange(player, x, y) end
    -- roles
    local people = M.cpPeople(player)
    local rm, ro = child("Roles")
    if #people == 0 then off(ro, "Nobody lives at your base (or they're all out).") end
    for _, uid in ipairs(people) do
        local cur = M.cpRoleOf(uid)
        local pm = ISContextMenu:getNew(rm)
        rm:addSubMenu(rm:addOption(firstName(uid) .. " (" .. M.cpRoleLabel[cur] .. ")"), pm)
        for _, role in ipairs(M.cpRoles) do
            local opt = pm:addOption(role.label, nil, function() M.cpAct("role", uid, role.id, nil, nil, nil, player) end)
            if role.id == cur then off(opt, "Already their job.") end
        end
    end
    -- rules
    local rlm, rlo = child("Rules")
    if M.cpOpt("CPRules") == false then off(rlo, "Camp rules are off in this world's sandbox settings.") end
    for _, r in ipairs(M.cpRules) do
        local on = d.rules[r.id] == true
        rlm:addOption((on and "Drop rule: " or "Set rule: ") .. r.label, nil, function() M.cpAct("rule", r.id, not on, nil, nil, nil, player) end)
    end
    -- patrol
    local pm2 = child("Patrol")
    local pts = d.patrol
    local maxP = tonumber(M.cpOpt("CPPatrolPoints")) or 5
    local add = pm2:addOption("Add patrol point here (" .. (#pts + 1) .. ")", nil, function() M.cpAct("patrolAdd", x, y, z, nil, nil, player) end)
    if #pts >= maxP then off(add, "You already have " .. #pts .. " patrol points (max " .. maxP .. ").")
    elseif not inRange then off(add, why or "Too far from your base.") end
    if #pts > 0 then
        pm2:addOption(ALifeTr("IGUI_ALCP_Menu_Remove_last_patrol_point", "Remove last patrol point"), nil, function() M.cpAct("patrolPop", nil, nil, nil, nil, nil, player) end)
        pm2:addOption(ALifeTr("IGUI_ALCP_Menu_Clear_the_patrol_route", "Clear the patrol route"), nil, function() M.cpAct("patrolClear", nil, nil, nil, nil, nil, player) end)
        pm2:addOption(d.patrolOff and "Resume patrols" or "Pause patrols", nil, function() M.cpAct("patrolPause", not d.patrolOff, nil, nil, nil, nil, player) end)
    end
    -- haul & sort
    local hm = child("Haul & sort")
    if M.cpSel == nil then
        local o1 = hm:addOption(ALifeTr("IGUI_ALCP_Menu_Collect_area_first_corner_here", "Collect area: first corner here"), nil, function() M.cpSel = { x = x, y = y, z = z }; halo("First corner set. Right-click the opposite corner.") end)
        if #d.areas >= M.cpCfg.maxHaulAreas then off(o1, "You already have " .. #d.areas .. " collect areas (max " .. M.cpCfg.maxHaulAreas .. ").")
        elseif not inRange then off(o1, why or "Too far from your base.") end
    else
        local sel = M.cpSel
        local o2 = hm:addOption(ALifeTr("IGUI_ALCP_Menu_Collect_area_opposite_corner_here", "Collect area: opposite corner here"), nil, function()
            M.cpSel = nil
            M.cpAct("area", sel.x, sel.y, x, y, sel.z, player)
        end)
        if z ~= sel.z then off(o2, "Both corners must be on the same floor.")
        elseif math.abs(x - sel.x) + 1 > M.cpCfg.maxSide or math.abs(y - sel.y) + 1 > M.cpCfg.maxSide then off(o2, "Too big. Keep each side under " .. M.cpCfg.maxSide .. " tiles.")
        elseif not inRange then off(o2, why or "Too far from your base.") end
        hm:addOption(ALifeTr("IGUI_ALCP_Menu_Cancel", "Cancel"), nil, function() M.cpSel = nil end)
    end
    local c = containerOn(sq)
    local here = M.cpDropAt(x, y, z)
    if here then
        hm:addOption("Remove drop point here (" .. string.lower(M.cpCatLabel[here]) .. ")", nil, function() M.cpAct("dropRemove", x, y, z, nil, nil, player) end)
    elseif c then
        local dm, dmo = ISContextMenu:getNew(hm), hm:addOption(ALifeTr("IGUI_ALCP_Menu_Drop_point_here_for", "Drop point here for..."))
        hm:addSubMenu(dmo, dm)
        if not inRange then off(dmo, why or "Too far from your base.") end
        for _, cat in ipairs(M.cpCats) do
            local n = d.drops[cat.id] and #d.drops[cat.id] or 0
            dm:addOption(cat.label .. (n > 0 and (" (" .. n .. " already)") or ""), nil, function() M.cpAct("dropAdd", cat.id, x, y, z, nil, player) end)
        end
    end
    local a, ai = M.cpAreaAt(x, y, z)
    if a then hm:addOption(ALifeTr("IGUI_ALCP_Menu_Remove_this_collect_area", "Remove this collect area"), nil, function() M.cpAct("areaRemove", x, y, z, nil, nil, player) end) end
    if #d.areas > 0 or hasAny(d.drops) then
        hm:addOption(d.haulOn and "Pause hauling" or "Resume hauling", nil, function() M.cpAct("haul", not d.haulOn, nil, nil, nil, nil, player) end)
    end
    -- farm
    local fam, fao = child("Farm")
    local fdat = M.cpFarmData()
    if M.cpOpt("CPFarm") == false then off(fao, "Farm duty is off in this world's sandbox settings.") end
    local wsp = fdat.water
    if wsp and wsp.x == x and wsp.y == y and wsp.z == z then
        fam:addOption(ALifeTr("IGUI_ALCP_Menu_Stop_fetching_water_here", "Stop fetching water here"), nil, function() M.cpAct("farmWaterStop", nil, nil, nil, nil, nil, player) end)
    else
        local wo = fam:addOption(wsp and "Fetch water from here instead" or "Water from here", nil, function() M.cpAct("farmWater", x, y, z, nil, nil, player) end)
        if not inRange then off(wo, why or "Too far from your base.") end
    end
    fam:addOption(fdat.off and "Resume farm work" or "Pause farm work", nil, function() M.cpAct("farmPause", not fdat.off, nil, nil, nil, nil, player) end)
    -- fortify
    local fm, fo = child("Fortify")
    local fd = M.cpFortData()
    if M.cpOpt("CPFortify") == false then off(fo, "Fortifying your base is off in this world's sandbox settings.") end
    if c then
        local here2 = fd.depot and fd.depot.x == x and fd.depot.y == y and fd.depot.z == z
        local so = fm:addOption(here2 and "This is the stockpile" or "Stockpile here", nil, function() M.cpAct("fortDepot", x, y, z, nil, nil, player) end)
        if here2 then off(so, "Already the stockpile.") elseif not inRange then off(so, why or "Too far from your base.") end
    end
    if fd.on then
        fm:addOption(ALifeTr("IGUI_ALCP_Menu_Stop_fortifying", "Stop fortifying"), nil, function() M.cpAct("fortStop", nil, nil, nil, nil, nil, player) end)
    else
        local st = fm:addOption(ALifeTr("IGUI_ALCP_Menu_Start_fortifying", "Start fortifying"), nil, function() M.cpAct("fortStart", nil, nil, nil, nil, nil, player) end)
        if fd.depot == nil then off(st, "Pick a stockpile first: right-click a container > Camp > Fortify > Stockpile here.") end
    end
    if fn(M, "alMenu") then M.alMenu(child, off, player, x, y, z, inRange, why) end
    for _, f in ipairs(M.cpMenus or {}) do local okM, e = pcall(f, child, off, player, x, y, z, inRange, why, sub); if not okM then log("menu plug-in error: " .. tostring(e)) end end
    sub:addOption(M.cpShow and "Hide camp markings" or "Show camp markings", nil, function() M.cpShow = not M.cpShow end)
end

-- markings (only while toggled on): patrol points, collect areas, drop points
function M.cpRender()
    if type(addAreaHighlight) ~= "function" then return end
    local sel = M.cpSel
    if sel then addAreaHighlight(sel.x, sel.y, sel.x + 1, sel.y + 1, sel.z, 0.3, 0.6, 1, 0.6) end
    if not M.cpShow then return end
    local d = M.cpData()
    for _, p in ipairs(d.patrol) do addAreaHighlight(p.x, p.y, p.x + 1, p.y + 1, p.z, 1, 0.5, 0.2, 0.6) end
    local fw = type(d.farm) == "table" and d.farm.water or nil
    if fw then addAreaHighlight(fw.x, fw.y, fw.x + 1, fw.y + 1, fw.z or 0, 0.2, 0.6, 1, 0.7) end
    local fdp = type(d.fort) == "table" and d.fort.depot or nil
    if fdp then addAreaHighlight(fdp.x, fdp.y, fdp.x + 1, fdp.y + 1, fdp.z or 0, 0.9, 0.8, 0.3, 0.6) end
    for _, a in ipairs(d.areas) do addAreaHighlight(a.x1, a.y1, a.x2 + 1, a.y2 + 1, a.z, 0.3, 0.6, 1, 0.25) end
    for _, f in ipairs(M.cpMarks or {}) do
        local okK, list = pcall(f)
        if okK and type(list) == "table" then for _, m in ipairs(list) do local p = m[1]; addAreaHighlight(p.x, p.y, p.x + 1, p.y + 1, p.z or 0, m[2], m[3], m[4], 0.7) end end
    end
    for _, list in pairs(d.drops) do
        for _, p in ipairs(list) do addAreaHighlight(p.x, p.y, p.x + 1, p.y + 1, p.z, 0.3, 1, 0.6, 0.6) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- words
----------------------------------------------------------------------------------------------------------------
local OK = { "Alright.", "On it.", "Sure.", "Fine." }
function M.cpOrder(kind, record, player)
    local uid = tostring(record.uid)
    if not M.cpIsHome(uid, player) then return nil end
    local d = M.cpData()
    local seed = uid .. tostring(math.floor(hours() * 10))
    if kind == "patrol" then
        if #d.patrol == 0 then halo("Right-click the ground > Camp > Patrol to mark the route."); return "Walk where? Show me the route." end
        d.patrollers[uid], d.patrolOff = true, nil
        M.cpNextTry[uid] = nil
        return "I'll walk the route. I'll shout if I see anything."
    elseif kind == "patrol_stop" then
        d.patrollers[uid] = nil
        if M.cpJobs[uid] and M.cpJobs[uid].kind == "patrol" then M.cpRelease(uid, shellFor(uid)) end
        return pickLine(OK, seed)
    elseif kind == "sort" then
        if #d.areas == 0 or not hasAny(d.drops) then halo("Right-click the ground > Camp > Haul & sort to mark where things come from and where they go."); return "Sort it where? Show me where things go." end
        d.haulOn = true
        M.cpNextTry[uid] = nil
        return "I'll start putting things where they go."
    elseif kind == "sort_stop" then
        d.haulOn = false
        for u, j in pairs(M.cpJobs) do if j.kind == "haul" then M.cpRelease(u, shellFor(u)) end end
        return pickLine(OK, seed)
    elseif kind == "watch" then
        if M.cpOpt("CPNightWatch") == false then return "We don't keep a night watch here." end
        local night = math.floor((hours() + 2) / 24)
        if not isNight() then night = night + 1 end
        d.watchNight, d.watcher = night, uid
        return "I'll take the watch tonight. Sleep. I'll wake you if anything comes."
    end
    if kind == "fortify" or kind == "fortify_stop" then
        local ok, msg = M.cpFortStart(player, kind == "fortify")
        if not ok then halo(msg); return "Build with what? Show me where the materials go." end
        return kind == "fortify" and "We'll start on the windows and the wall." or pickLine(OK, seed)
    end
    local role = string.match(kind, "^role_(.+)$")
    if role then local line = M.cpSetRole(uid, role, player); return line end
    return nil
end
M.cpIntents = {
    { id = "CAMP_PATROL", kind = "patrol", patterns = "walk the route|walk the patrol|patrol the base|start the patrol|patrol our route|walk our route|do the patrol" },
    { id = "CAMP_PATROL_STOP", kind = "patrol_stop", patterns = "stop patrolling|stop the patrol|off patrol|you can stop patrolling" },
    { id = "CAMP_SORT", kind = "sort", patterns = "sort the stuff|sort the supplies|sort everything|organize the supplies|put things away|put the stuff away|haul the loot|sort the loot" },
    { id = "CAMP_SORT_STOP", kind = "sort_stop", patterns = "stop sorting|leave the stuff|stop hauling|leave the supplies" },
    { id = "CAMP_WATCH", kind = "watch", patterns = "take the night watch|keep watch tonight|stand watch tonight|you have the watch|take first watch|night watch" },
    { id = "CAMP_FORTIFY", kind = "fortify", patterns = "fortify the base|fortify the house|build a wall around|build the palisade|put up a wall|start fortifying" },
    { id = "CAMP_FORTIFY_STOP", kind = "fortify_stop", patterns = "stop fortifying|stop building the wall|leave the wall" },
    { id = "CAMP_ROLE_COOK", kind = "role_cook", patterns = "you're our cook|you are our cook|you're the cook|be our cook|you cook for us|you can cook for us" },
    { id = "CAMP_ROLE_MEDIC", kind = "role_medic", patterns = "you're our medic|you are our medic|you're the medic|be our medic|you're our doctor|be our doctor" },
    { id = "CAMP_ROLE_GUARD", kind = "role_guard", patterns = "you're our guard|you are our guard|you're on guard duty|be our guard|you're a guard now" },
    { id = "CAMP_ROLE_BUILDER", kind = "role_builder", patterns = "you're our builder|you are our builder|be our builder|you're the builder|you build for us" },
    { id = "CAMP_ROLE_FARMER", kind = "role_farmer", patterns = "you're our farmer|you are our farmer|be our farmer|tend the crops|work the farm|look after the crops|you're the farmer" },
    { id = "CAMP_ROLE_GENERAL", kind = "role_general", patterns = "you're off duty|no more special job|back to general duties|you're just general now" },
}
function M.cpInstallTalk()
    if M._cpTalk then return true end
    local Data, Intents, Talk = PA().DialogueData, PA().TalkIntents, PA().Talk
    if Data == nil or Talk == nil then return false end
    pcall(Data.load)
    Talk.choiceHandlers = Talk.choiceHandlers or {}
    for _, def in ipairs(M.cpIntents) do
        pcall(Data.intent, def.id, 82, def.patterns)
        Talk.choiceHandlers[def.id] = function(record, shell, player, context, now, text)
            local ok, line = pcall(M.cpOrder, def.kind, record, player)
            if not ok then log("order failed: " .. tostring(line)); return nil end
            if line == nil or not PA().Speech.say(shell, line, { face = player }) then return nil end
            return line, "answered"
        end
    end
    if Intents then Intents.cache = {} end
    M._cpTalk = true
    return true
end
-- in conversation (AI): their camp job, so they talk like it
function M.cpExtra(req, player, listener)
    if type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local uid = tostring(listener.record.uid)
    if not M.cpIsHome(uid, player) then return end
    local role = M.cpRoleOf(uid)
    local note = nil
    if role ~= "general" then note = "Your job at this base is " .. string.lower(M.cpRoleLabel[role]) .. "." end
    if M.cpWatcher(player) == uid then note = (note and (note .. " ") or "") .. "You're on night watch tonight." end
    for _, f in ipairs(M.cpExtras or {}) do
        local okE, extra = pcall(f, req, player, listener)
        if okE and type(extra) == "string" and extra ~= "" then note = (note and (note .. " ") or "") .. extra end
    end
    if note then
        req.psyche = type(req.psyche) == "table" and req.psyche or {}
        req.psyche.mood = req.psyche.mood and (tostring(req.psyche.mood) .. ". " .. note) or note
    end
end
function M.cpPerf()
    local s = M.cpStats
    return "patrols " .. s.patrols .. ", alerts " .. s.alerts .. ", wakes " .. s.wakes .. ", hauled " .. s.hauled .. " (" .. s.trips .. " trips, "
        .. s.overflow .. " overflow), treated " .. s.treated .. ", watered " .. s.watered .. ", harvested " .. s.harvested .. ", rules broken " .. s.rulesBroken .. ", bans " .. s.bans .. ", evals " .. s.evals
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
if type(Events) == "table" then
    if Events.OnFillWorldObjectContextMenu then
        ALifeRadial.addFiller("camp", "camp", function(p, context, worldobjects, test)   -- 0.5.11: radial registry
            if M._cpMenuDead then return end
            local ok, err = pcall(M.cpContext, p, context, worldobjects, test)
            if not ok then M._cpMenuDead = true; log("menu error, camp menu off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnTick then
        ALifeHealth.add(Events.OnTick, "ALifeTalk_Camp", function()
            if M._cpTickDead then return end
            local ok, err = pcall(M.cpTick)
            if not ok then M._cpTickDead = true; log("tick error, camp tick off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnPostRender then
        Events.OnPostRender.Add(function()
            if M._cpRenderDead or (not M.cpShow and M.cpSel == nil) then return end
            local ok, err = pcall(M.cpRender)
            if not ok then M._cpRenderDead = true; log("render error, camp markings off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(M.cpRegister)
            pcall(M.cpInstallTalk)
            pcall(M.cpWrapTake)
            if M.cpFortOn() then pcall(M.cpFortInstall) end
            if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
                ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeTalk_Camp", function(body, uid, killer)
                    local ok, err = pcall(M.cpOnDeath, body, uid, killer)
                    if not ok then log("death hook error: " .. tostring(err)) end
                end)
            end
            if not M._cpExtraOn and type(M.requestExtras) == "table" then
                table.insert(M.requestExtras, function(req, player, listener, now) pcall(M.cpExtra, req, player, listener) end)
                M._cpExtraOn = true
            end
            local d = M.cpData()
            cpTouch()
            print(TAG .. " loaded v" .. VERSION .. " (A-Life module " .. (M._cpRegistered and "registered" or "not yet")
                .. ", talk " .. (M._cpTalk and "on" or "off") .. ", " .. #d.patrol .. " patrol points, " .. #d.areas .. " collect areas)")
        end)
    end
end
-- pre-1.0 MP (P4): the camp menu on an MP client. Writes = M.cpAct on the server (as the sender); reads = the camp
-- copy the server shares (camp table, who lives there, first names, the base box for the range checks).
function M.cpViewBuild()
    local player = thePlayer()
    local people = M.cpPeople(player)
    local names = {}
    for _, uid in ipairs(people) do names[uid] = firstName(uid) end
    for uid in pairs(M.cpData().roles) do if names[uid] == nil then names[uid] = firstName(uid) end end
    local base = fn(M, "wzBase") and M.wzBase(player) or nil
    local buckets = {} -- camp-life modules' own stores (ALifeCampKit K.bucket)
    for name in pairs(M.cpShareBuckets or {}) do buckets[name] = M.bucket(name) end
    return { camp = M.cpData(), people = people, names = names, base = base, buckets = buckets }
end
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    ALifeRemote.expose("cpAct", 6, 7)
    ALifeRemote.share(M.CP_VIEW, M.cpViewBuild)
end
return M
