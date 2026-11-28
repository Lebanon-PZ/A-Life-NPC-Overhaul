-- A-Life NPC Overhaul pre-1.0: BRAIN 3, THE DEAD (docs/PLAN-BRAIN-3.md). NPC groups that live by the same world you do.
--   1. The brain sees the dead: horde attacks on the base (repelled / broke in / overrun) and the dead seen around it
--      while loaded feed a "dead" score in the situation. It pushes the secure stance (guards, walls, fewer runs) and the
--      hidden pressure; bad enough (overrun again and again, or stripped land on top) they move away (nomads).
--   2. Off-screen hordes follow your sandbox: SandboxVars.ZombieConfig.PopulationMultiplier (vanilla, 0.65 = Normal)
--      scales how often hordes hit a base and how hard (square root / 0.3 power, so Insane is about twice Normal, not 4x).
--      hordeBaseHit softens or hardens it. Works with the brain off too (it's the world, not a mind).
--   3. Survival habits when loaded: the patch's shelter / fall-back trigger (hordeN) drops on high pop; A-Life's own
--      "retreat from hordes" module (off in its sandbox by default) is turned on with a pop-scaled count (deadRetreat).
--      Only A-Life's own modules move people; nothing raw.
--   4. Clear their own block: a real job ("clear") from the allocator costs hands (fewer on food) and lowers the
--      off-screen horde chance for clearDays. Loaded, A-Life's own fighting does the clearing; no zombie is deleted.
--   5. Strength in numbers: on high pop small groups ask a friendly neighbour to take them in (the real nbAbsorb, off
--      screen only), and groups take in loners even when morale is low.
-- World side (server in MP). Nothing new on the network. Every number a setting (fileKeys at load).
-- Unverified on 42.21: ProjectALife.ModuleHordeRetreat (read in A-Life 42.20 source: settings / configure).
require "ALifeNPCOverhaul/ALifeBrainManagers"
pcall(require, "ALifeNPCOverhaul/ALifeBrainAlloc")
pcall(require, "ALifeNPCOverhaul/ALifeBrainCommand")
pcall(require, "ALifeNPCOverhaul/ALifeBrainWords")
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn, hours, clamp, roll = BR.fn, BR.hours, BR.clamp, BR.roll
local TAG = "[ALifeBrainDead]"

BR.defaults({
    brainDead = true,        -- the brain sees the dead (stance, pressure, moving away, clearing, merging, loaded habits)
    hordePop = true,         -- off-screen hordes follow the sandbox's zombie count
    hordeBaseHit = 100,      -- percent: how hard hordes hit NPC bases off screen
    deadWeight = 100,        -- percent: how much the dead weigh in a group's mind
    deadMoveScore = 4,       -- overrun = 2, broke in = 1, within deadMoveDays: this much and they move away
    deadMoveDays = 14,
    deadShelter = true,      -- loaded: people take shelter / fall back from fewer of the dead on high pop
    deadRetreat = true,      -- loaded: A-Life's "retreat from hordes" on, its count scaled by pop
    deadRetreatCount = 10,   -- the dead close by before they pull back, at Normal pop (fewer on high pop)
    deadClear = true,        -- groups clear the dead around home (a real job, costs hands)
    clearDays = 3,           -- days cleared ground stays quieter
    clearCut = 50,           -- percent: how much quieter cleared ground is (all hands on it)
    deadMerge = true,        -- on high pop small groups ask to be taken in, loners are taken in sooner
    deadMergePop = 150,      -- percent of Normal pop from which strength in numbers kicks in
    deadMergeChance = 20,    -- percent a day a small, hard-pressed group asks a friendly neighbour
})
BR.addRows({
    { "brainDead", "Brain 3: groups see the dead (walls and guards first, move away when overrun, clear, merge)" },
    { "hordePop", "Brain 3: hordes hit NPC bases off screen as often as your zombie count says" },
    { "hordeBaseHit", "Brain 3: how hard hordes hit NPC bases off screen (percent)", { 25, 50, 100, 150 } },
    { "deadWeight", "Brain 3: how much the dead weigh in a group's mind (percent)", { 50, 100, 150 } },
    { "deadMoveScore", "Brain 3: hits before a group moves away (overrun 2, broke in 1)", { 3, 4, 6, 99 } },
    { "deadMoveDays", "Brain 3: days those hits count", { 7, 14, 30 } },
    { "deadShelter", "Brain 3: on high pop people take shelter from fewer of the dead" },
    { "deadRetreat", "Brain 3: A-Life's retreat from hordes on, scaled by your zombie count" },
    { "deadRetreatCount", "Brain 3: the dead close by before they pull back (Normal pop)", { 6, 10, 15 } },
    { "deadClear", "Brain 3: groups clear the dead around home (costs hands)" },
    { "clearDays", "Brain 3: days cleared ground stays quieter", { 1, 3, 7 } },
    { "clearCut", "Brain 3: how much quieter cleared ground gets (percent)", { 25, 50, 75 } },
    { "deadMerge", "Brain 3: on high pop small groups join friends, loners are taken in sooner" },
    { "deadMergePop", "Brain 3: zombie count (percent of Normal) where that starts", { 100, 150, 250 } },
    { "deadMergeChance", "Brain 3: chance a day a small group asks to be taken in (percent)", { 10, 20, 40 } },
})
BR.deadStats = BR.deadStats or { hits = 0, seen = 0, moves = 0, clears = 0, merges = 0, recruits = 0, retreat = 0 }
local DS = BR.deadStats
local function on() return BR.flag("brainDead") end
local function day(h) return math.floor(h / 24) end
local function isYou(b) return type(b) == "table" and (b.isCamp == true or b.id == "you") end

----------------------------------------------------------------------------------------------------------------
-- the world's zombie count (vanilla: Insane 2.5, Very High 1.6, High 1.2, Normal 0.65, Low 0.15, None 0)
----------------------------------------------------------------------------------------------------------------
BR.POP_NORMAL = 0.65
function BR.popRatio()
    local v = nil
    pcall(function() v = tonumber(SandboxVars.ZombieConfig.PopulationMultiplier) end)
    if v == nil then return 1 end
    return math.max(0, v / BR.POP_NORMAL)
end
local function clearCutNow(b, h)
    local s = type(b.brain) == "table" and b.brain or nil
    if s == nil or not BR.flag("deadClear") or not on() then return 0 end
    if h - (tonumber(s.clearH) or -1e9) >= BR.num("clearDays") * 24 then return 0 end
    local crew = math.max(1, tonumber(b.crewN) or 1)
    return BR.num("clearCut") / 100 * math.min(1, (tonumber(s.clearN) or 0) * 3 / crew)
end
-- Bases.lua asks: "chance" (how often) or "str" (how hard) a horde hits this base off screen
function M.nbHordeMul(b, what, h)
    h = h or hours()
    local r = BR.flag("hordePop") and BR.popRatio() or 1
    local hit = math.max(0, BR.num("hordeBaseHit")) / 100
    if what == "str" then return math.max(0.3, r ^ 0.3) * math.sqrt(hit) end
    return math.sqrt(r) * hit * (1 - clearCutNow(b, h))
end

----------------------------------------------------------------------------------------------------------------
-- 1. what the dead did to them, and what they saw
----------------------------------------------------------------------------------------------------------------
local HIT_W = { repelled = 0.25, damaged = 0.6, overrun = 1.2, overrun_held = 1.2 }
local MOVE_W = { damaged = 1, overrun = 2, overrun_held = 2 }
function BR.deadNote(b, res, h)
    if type(b) ~= "table" then return end
    local list = type(b.deadHits) == "table" and b.deadHits or {}
    list[#list + 1] = { h = h, r = tostring(res) }
    while #list > 10 do table.remove(list, 1) end
    b.deadHits = list
    DS.hits = DS.hits + 1
end
function BR.deadSee(b, n, h)
    local s = BR.of(b)
    local old = (tonumber(s.deadSeen) or 0) * math.max(0, 1 - (h - (tonumber(s.deadSeenH) or h)) / 48)
    s.deadSeen, s.deadSeenH = math.max(old, tonumber(n) or 0), h
    DS.seen = DS.seen + 1
end
-- the moving-away score: overrun 2, broke in 1, within deadMoveDays
function BR.deadMoveScore(b, h)
    local n = 0
    for _, x in ipairs(type(b.deadHits) == "table" and b.deadHits or {}) do
        if h - (tonumber(x.h) or -1e9) <= BR.num("deadMoveDays") * 24 then n = n + (MOVE_W[x.r] or 0) end
    end
    return n
end
-- 0 = quiet; 1 = the dead are a real worry; 2+ = they're losing to them
function BR.deadScore(b, h)
    if type(b) ~= "table" or not on() then return 0 end
    local v = 0
    for _, x in ipairs(type(b.deadHits) == "table" and b.deadHits or {}) do
        local age = h - (tonumber(x.h) or -1e9)
        if age >= 0 and age < 168 then v = v + (HIT_W[x.r] or 0.25) * (1 - age / 168) end
    end
    local s = type(b.brain) == "table" and b.brain or {}
    local seenAge = h - (tonumber(s.deadSeenH) or -1e9)
    if seenAge < 48 then v = v + math.min(1.5, (tonumber(s.deadSeen) or 0) / 20) * (1 - seenAge / 48) end
    if b.town == true and BR.popRatio() >= 1.5 then v = v + 0.2 end
    return v * math.max(0, BR.num("deadWeight")) / 100
end

----------------------------------------------------------------------------------------------------------------
-- tools
----------------------------------------------------------------------------------------------------------------
BR.tool({ id = "deadMove", start = function(b)
    if not fn(M, "nmTryLeave") then return false end
    b.nmWhy = "dead"
    local ok, res = pcall(M.nmTryLeave, b, hours())
    b.nmWhy = nil
    if ok and res == true then
        DS.moves = DS.moves + 1
        if fn(BR, "worldAdd") then pcall(BR.worldAdd, { k = "dead", text = tostring(b.name) .. " gave up their place - the dead kept coming", x = b.x, y = b.y, ids = { b.id } }) end
        return true
    end
    return false
end })
-- strength in numbers: a small group asks a friendly neighbour with room to take them in (off screen only)
function BR.deadMergeTry(b, h)
    if not (fn(M, "nbAbsorb") and fn(M, "nbActive")) then return false end
    local cap = (M.nbCfg and M.nbCfg.memberCap) or 8
    local far = (M.nbCfg and M.nbCfg.farTiles) or 150
    local n = tonumber(b.crewN) or 1
    if ALifeSide.nearest(b.x, b.y, far) ~= nil then return false end
    local best, bd = nil, 1500 ^ 2
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and not o.airport and not o.road and not o.outpostOf and not isYou(o) then
            local st = BR.tieState(BR.tie(b, o))
            local d = BR.d2(b.x, b.y, o.x, o.y)
            if (st == "allied" or st == "friendly") and (tonumber(o.crewN) or 0) + n <= cap and d < bd and ALifeSide.nearest(o.x, o.y, far) == nil then best, bd = o, d end
        end
    end
    if best == nil then return false end
    BR._worldQuiet = true
    local ok, done, moved = pcall(M.nbAbsorb, best, b, h)
    BR._worldQuiet = nil
    if not ok or not done then return false end
    if fn(BR, "worldAdd") then pcall(BR.worldAdd, { k = "merge", text = tostring(b.name) .. " joined " .. tostring(best.name) .. " - too few to hold out against the dead alone", x = best.x, y = best.y, ids = { best.id, b.id } }) end
    DS.merges = DS.merges + 1
    BR.event(best, "What was left of " .. tostring(b.name) .. " came to them - safer in numbers with so many of the dead about", "merge")
    BR.event(b, "They joined " .. tostring(best.name) .. " - too few to hold out against the dead alone", "merge")
    if fn(M, "dirBumpTie") then pcall(M.dirBumpTie, best, b, 10) end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the manager: guards, walls, clearing, moving away, merging, taking in loners
----------------------------------------------------------------------------------------------------------------
function BR.deadManage(b, sit, h, s, bids, far)
    if not on() or isYou(b) then return end
    local dead = tonumber(sit.dead) or 0
    local crew = tonumber(sit.crew) or 1
    if dead >= 0.5 then
        bids[#bids + 1] = { job = "guard", n = math.ceil(math.min(1.5, dead) * crew * 0.25), value = 2 + dead * 2, force = dead >= 1, key = "deadGuard" }
        if b.stage ~= "fortified" then bids[#bids + 1] = { job = "build", n = dead >= 1 and 2 or 1, value = 2 + dead, force = dead >= 1, key = "deadWalls" } end
        if BR.flag("deadClear") and crew >= 3 then
            bids[#bids + 1] = { job = "clear", n = math.max(1, math.floor(crew * 0.2)), value = 1.6 + dead * 0.5, force = true, key = "deadClear" }
        end
    end
    -- overrun again and again (or broken into on stripped land): move away
    local ms = BR.deadMoveScore(b, h)
    local need = BR.num("deadMoveScore")
    if ms >= need or (ms >= math.ceil(need / 2) and fn(M, "nmStripped") and select(2, pcall(M.nmStripped, b)) == true) then
        bids[#bids + 1] = { call = "deadMove" }
    end
    -- strength in numbers (once a day)
    if BR.flag("deadMerge") and s.deadDay ~= day(h) then
        s.deadDay = day(h)
        local r = BR.popRatio()
        if r * 100 >= BR.num("deadMergePop") then
            if crew <= 3 and (dead >= 0.5 or r >= 2.5) and roll(b.id .. "#deadMerge" .. day(h)) < BR.num("deadMergeChance") / 100 * math.min(2, r / 1.5) then
                if BR.deadMergeTry(b, h) then return end
            end
            local cfg = M.nbCfg or {}
            local growthWill = (s.stance == "grow" or s.stance == "expand" or crew < 4) and (tonumber(b.morale) or 50) >= (cfg.recruitMorale or 55)
            if not growthWill and crew < (cfg.memberCap or 8) and (tonumber(sit.food) or 0) >= 1.5 and s.recruitDay ~= day(h) then
                local x = { job = "recruit", n = 1, value = 1.4, tool = "recruit", key = "deadRecruit" }
                x.onStart = function() s.recruitDay = day(h); DS.recruits = DS.recruits + 1 end
                bids[#bids + 1] = x
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 3. loaded habits: the patch's shelter trigger and A-Life's horde retreat, scaled by pop
----------------------------------------------------------------------------------------------------------------
function BR.deadHabits()
    local r = math.max(1, BR.popRatio())
    local P = ALifeTalkPatch
    if type(P) == "table" and type(P.settings) == "table" and type(P.settings.shelter) == "table" then
        local sh = P.settings.shelter
        if P._deadBaseHordeN == nil then P._deadBaseHordeN = tonumber(sh.hordeN) or 12 end
        local want = P._deadBaseHordeN
        if on() and BR.flag("deadShelter") then want = math.max(5, math.floor(P._deadBaseHordeN / math.sqrt(r) + 0.5)) end
        sh.hordeN = want
    end
    -- A-Life's ModuleHordeRetreat (42.20 source: settings { enabled, count, radius, scope }, configure(options))
    local H = BR.PA().ModuleHordeRetreat
    if type(H) == "table" and type(H.settings) == "table" and fn(H, "configure") then
        local st = H.settings
        if BR._deadRetreatOrig == nil then BR._deadRetreatOrig = { enabled = st.enabled == true, count = tonumber(st.count) or 8 } end
        if on() and BR.flag("deadRetreat") then
            local count = math.max(4, math.floor(BR.num("deadRetreatCount") / math.sqrt(r) + 0.5))
            if st.enabled ~= true or tonumber(st.count) ~= count then
                pcall(H.configure, { enabled = true, count = count, radius = st.radius, scope = st.scope })
                DS.retreat = DS.retreat + 1
            end
            BR._deadRetreatOurs = true
        elseif BR._deadRetreatOurs then
            local o = BR._deadRetreatOrig
            pcall(H.configure, { enabled = o.enabled, count = o.count, radius = st.radius, scope = st.scope })
            BR._deadRetreatOurs = nil
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- wiring
----------------------------------------------------------------------------------------------------------------
BR.DEAD_WHY = { "the dead keep coming at them, so they keep close to home", "they are losing ground to the dead" }
local function install()
    -- the clear job (a home job: no road time; the allocator only fills it from a forced bid)
    local have = false
    for _, j in ipairs(BR.JOBS or {}) do if j == "clear" then have = true end end
    if not have and type(BR.JOBS) == "table" then
        local at = #BR.JOBS + 1
        for i, j in ipairs(BR.JOBS) do if j == "idle" then at = i end end
        table.insert(BR.JOBS, at, "clear")
    end
    if type(BR.JOB_WORDS) == "table" then BR.JOB_WORDS.clear = "out clearing the dead around home" end
    -- every horde attack on a base is remembered
    K.wrap(M, "nbAttack", "BrainDeadNote", function(orig) return function(b, haven, crew, home, h, kind, ...)
        local res, dead = orig(b, haven, crew, home, h, kind, ...)
        if type(b) == "table" and type(b.lastAttack) == "table" and b.lastAttack.kind == "horde" then pcall(BR.deadNote, b, res, h) end
        return res, dead
    end end)
    -- the situation carries the dead
    K.wrap(BR, "situation", "BrainDeadSit", function(orig) return function(b, h, ...)
        local sit = orig(b, h, ...)
        if type(sit) == "table" then sit.dead = (not isYou(b)) and BR.deadScore(b, h) or 0 end
        return sit
    end end)
    -- reality: the dead push pressure and the secure / survive stances, and damp the rest
    K.wrap(BR, "pressureDay", "BrainDeadPressure", function(orig) return function(b, sit, h, ...)
        local p = orig(b, sit, h, ...)
        local dead = type(sit) == "table" and tonumber(sit.dead) or 0
        if dead >= 1 then local s = BR.of(b); s.pressure = clamp(s.pressure + 4 * dead, 0, 100); return s.pressure end
        return p
    end end)
    K.wrap(BR, "scoreStances", "BrainDeadStances", function(orig) return function(b, sit, h, ...)
        local sc, disc = orig(b, sit, h, ...)
        local dead = type(sit) == "table" and tonumber(sit.dead) or 0
        if type(sc) == "table" and dead > 0 then
            sc.secure = (sc.secure or 0) + 0.4 * dead
            if dead >= 1.5 then sc.survive = math.max(sc.survive or 0, 0.5 + 0.2 * (dead - 1.5)) end
            local damp = 1 - math.min(0.6, dead * 0.3)
            for _, k in ipairs({ "grow", "trade", "expand", "dominate" }) do sc[k] = (sc[k] or 0) * damp end
            sc.grow = math.max(sc.grow, 0.05)
        end
        return sc, disc
    end end)
    -- the clear job pays off: quieter ground for clearDays
    K.wrap(BR, "allocate", "BrainDeadClear", function(orig) return function(b, h, bids, ...)
        local a = orig(b, h, bids, ...)
        if type(b) == "table" and type(a) == "table" and (tonumber(a.clear) or 0) > 0 then
            local s = BR.of(b)
            if day(tonumber(s.clearH) or -1e9) ~= day(h) then DS.clears = DS.clears + 1 end
            s.clearH, s.clearN = h, a.clear
        end
        return a
    end end)
    -- words: the AI's picture of them
    K.wrap(BR, "why", "BrainDeadWhy", function(orig) return function(b, h, ...)
        local w = orig(b, h, ...)
        local dead = BR.deadScore(b, h or hours())
        if w and dead >= 1 then w = w .. "; " .. BR.DEAD_WHY[dead >= 2 and 2 or 1] end
        return w
    end end)
    local have2 = false
    for _, mg in ipairs(BR.managers or {}) do if mg.name == "dead" then have2 = true end end
    if not have2 and type(BR.managers) == "table" then BR.managers[#BR.managers + 1] = { name = "dead", f = BR.deadManage } end
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
do
    local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrainDead")
    -- hourly: the dead seen around bases near a player (zombie counts only where the cell is loaded), loaded habits
    K.hourly(TAG, function(p, h)
        pcall(BR.deadHabits)
        if not on() or not fn(M, "nbActive") then return end
        local P = ALifeTalkPatch
        if not fn(P, "zombiesNear") then return end
        for _, b in ipairs(M.nbActive()) do
            if not isYou(b) and tonumber(b.x) and ALifeSide.nearest(b.x, b.y, 80) ~= nil then
                local ok, n = pcall(P.zombiesNear, b.x, b.y, 30)
                if ok and tonumber(n) then BR.deadSee(b, n, h) end
            end
        end
    end)
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            pcall(BR.deadHabits)
            local r = BR.popRatio()
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": the dead " .. (on() and "on" or "off") .. ", zombie count x" .. tostring(math.floor(r * 100 + 0.5))
                .. "% of Normal, horde chance x" .. math.floor(math.sqrt(BR.flag("hordePop") and r or 1) * BR.num("hordeBaseHit") + 0.5) .. "%, retreat " .. (BR._deadRetreatOurs and "on" or "as A-Life set it"))
        end)
    end
end
