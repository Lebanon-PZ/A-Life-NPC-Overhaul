-- A-Life NPC Overhaul pre-1.0: THE BRAIN (docs/PLAN-BRAIN.md). An RTS-style mind for every NPC group.
-- One mind per group sees what the group believes (Knowledge, fog of war), wants things (Commander: a stance, held for
-- days), splits its real people into jobs (Allocator: the supply cap), and drives the systems that already exist
-- (trade runs, deals, walls, recruiting, outposts, nomads) as tools it alone starts. War is real people walking the
-- road (war parties on the trade-run engine). Nothing new on screen: you see it in what they do.
--   ALifeBrain.lua          namespace, settings, per-group state, tools, interrupts, the tick (this file)
--   ALifeBrainKnow.lua      B1 beliefs: sources, decay, distance fog, lies
--   ALifeBrainMind.lua      B2 weights from creed + rule + the leader's lens, memory, grudges, debts, succession stain
--   ALifeBrainCommand.lua   B3 situation, stances, pressure, standing orders, interrupts
--   ALifeBrainAlloc.lua     B4 people budget, jobs, executor gates (every old daily roll asks the brain)
--   ALifeBrainManagers.lua  B5 Economy, Defense, Trade, Military, Diplomacy, Scouting, Growth
--   ALifeBrainWar.lua       B6 war parties, sieges, tribute, scouts, envoys (runs on the TradeRuns engine)
--   ALifeBrainPlans.lua     B7 multi-day plans (one slot), aborts
--   ALifeBrainWords.lua     B8 Directive goals from the brain, talk lines, why lines, debug dump
-- Brain off (setting "brain", or directives off): every wrap passes straight through = the old behaviour.
-- MP: world side only (server); nothing new crosses the network.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrain")
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeBrain = ALifeBrain or {}
local BR = ALifeBrain
BR.VERSION = ALifeSide.MOD_VERSION
BR.TAG = "[ALifeBrain]"
BR.M = M

----------------------------------------------------------------------------------------------------------------
-- settings (rule 2: keys into fileKeys at LOAD; rows added when the settings list exists)
----------------------------------------------------------------------------------------------------------------
BR.DEFAULTS = BR.DEFAULTS or {}
function BR.defaults(t)
    for k, v in pairs(t) do BR.DEFAULTS[k] = v end
    if type(M.settings) ~= "table" then return end
    M.fileKeys = M.fileKeys or {}
    local have = {}
    for _, x in ipairs(M.fileKeys) do have[x] = true end
    for k, v in pairs(t) do
        if M.settings[k] == nil then M.settings[k] = v end
        if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
function BR.setting(k)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[k] end
    if v == nil then v = BR.DEFAULTS[k] end
    return v
end
function BR.num(k) local v = tonumber(BR.setting(k)); if v == nil then v = tonumber(BR.DEFAULTS[k]) end; return v or 0 end
function BR.flag(k) return BR.setting(k) ~= false end
BR.rows = BR.rows or {}
function BR.addRows(list) for _, r in ipairs(list) do BR.rows[#BR.rows + 1] = r end end
function BR.installRows()
    if type(M.settingRows) ~= "table" then return false end
    local have = {}
    for _, r in ipairs(M.settingRows) do have[r[1]] = true end
    for _, r in ipairs(BR.rows) do
        if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r; have[r[1]] = true end
        if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
    end
    return true
end

BR.defaults({
    brain = true,               -- the brain runs NPC groups (off = the old daily rolls, exactly as before)
    brainCheat = 0,             -- 0 strict fog of war, 1 they get a fuzzy look at the truth
    brainVsPlayer = 2,          -- 2 on (your camp is just another group), 1 only once you provoke them, 0 off
    brainPlayerGrace = 7,       -- days at the start nobody plans against you
    brainAggression = 100,      -- percent: how warlike groups are overall
    stanceMinDays = 3,          -- days a group holds its stance before it may change (interrupts aside)
    brainManagerH = 4,          -- game hours between the managers' small adjustments
    brainInterruptsPerHour = 2, -- at most this many "think now" per group per hour
    minGuards = 1,              -- never fewer on guard at home
    minHomePct = 40,            -- never fewer than this percent of people on home jobs
    brainEconomyFloor = 20,     -- every stance keeps at least this percent on food / supplies
    brainHurtPct = 60,          -- people hurt worse than this (health percent) stay home and rest
    knowDecayDays = 10,         -- days until a belief is worth nothing
    knowFarDecay = 50,          -- percent faster decay per 1000 tiles away
    knowActConf = 60,           -- percent sure before they commit people (war, siege); weaker intel = send a scout
    knowMax = 12,               -- beliefs kept per group (the most important)
    knowSeeTiles = 300,         -- neighbours this close are always known by sight
    knowRadioTiles = 1500,      -- groups this close hear each other's radio talk
    memFadeDays = 30,           -- memory of outcomes and grudges fades over this many days
    stainDays = 7,              -- days a new leader takes to make the group theirs
    planAbortLoss = 30,         -- percent of the people sent lost: the plan is dropped
    brainPlans = true,          -- multi-day plans (scout then raid, sieges, tribute ...)
    warParties = true,          -- war is real people walking the road (off = the old raids on paper)
    warPartyMax = 50,           -- percent of the group that may go to war at once
    siegeMaxDays = 5,           -- longest a siege lasts
    scouts = true,              -- groups send scouts to see for themselves
    brainTribute = true,        -- strong groups demand tribute from weak ones (and from you)
    brainWarn = true,           -- word reaches you (radio, rumour) when a war party heads your way
    brainRaidGap = 7,           -- days after one of A-Life's own raids on you before a group marches on you
    brainDebug = false,         -- dev: brain state in the console and on the Roads map
})
BR.addRows({
    { "brain", "Brain: NPC groups think like a commander (beliefs, a stance, people split into jobs); off = the old daily rolls" },
    { "brainCheat", "Brain: how much groups know", { 0, 1 }, { "only what they saw or heard", "a fuzzy look at the truth" } },
    { "brainVsPlayer", "Brain: groups can plan against your camp", { 0, 1, 2 }, { "never", "only once you provoke them", "yes, like any group" } },
    { "brainPlayerGrace", "Brain: days at the start nobody plans against you", { 3, 7, 14, 30 } },
    { "brainAggression", "Brain: how warlike groups are (percent)", { 50, 100, 150 } },
    { "stanceMinDays", "Brain: days a group sticks to what it decided", { 1, 3, 7 } },
    { "minGuards", "Brain: people a group always keeps on guard", { 0, 1, 2 } },
    { "minHomePct", "Brain: least share of a group that stays home (percent)", { 25, 40, 60 } },
    { "brainEconomyFloor", "Brain: least share of a group on food and supplies (percent)", { 10, 20, 30 } },
    { "knowDecayDays", "Brain: days until what a group knows about another is stale", { 5, 10, 20 } },
    { "knowActConf", "Brain: how sure a group must be before it attacks (percent)", { 40, 60, 80 } },
    { "memFadeDays", "Brain: days groups take to forget (grudges, bad roads, failed raids)", { 14, 30, 60 } },
    { "stainDays", "Brain: days a new leader needs to change how the group acts", { 3, 7, 14 } },
    { "planAbortLoss", "Brain: share of the people sent lost before a plan is dropped (percent)", { 20, 30, 50 } },
    { "brainPlans", "Brain: groups make plans over days (scout then raid, sieges, tribute, walls before winter)" },
    { "warParties", "Brain: raids and wars are real people walking the road (off = settled on paper)" },
    { "warPartyMax", "Brain: most of a group that goes to war at once (percent)", { 30, 50, 70 } },
    { "siegeMaxDays", "Brain: longest a siege lasts (days)", { 2, 5, 10 } },
    { "scouts", "Brain: groups send scouts to see for themselves" },
    { "brainTribute", "Brain: strong groups demand tribute from weak ones, and from you" },
    { "brainWarn", "Brain: word reaches you when a war party heads your way" },
    { "brainRaidGap", "Brain: days after an A-Life raid on you before a group may march on you", { 0, 7, 14 } },
    { "brainDebug", "Brain (dev): print each group's mind to the console and show it on the Roads map" },
})

----------------------------------------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------------------------------------
function BR.fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local fn = BR.fn
function BR.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
function BR.d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
function BR.hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
function BR.roll(key) if type(ALifeRoll01) == "function" then return ALifeRoll01(key) end return (BR.hash(key) % 10000) / 10000 end
function BR.clamp(v, lo, hi) v = tonumber(v) or 0; if v < lo then return lo elseif v > hi then return hi end return v end
function BR.log(msg) if M.log then M.log("brain: " .. tostring(msg)) end; if BR.setting("brainDebug") == true then print(BR.TAG .. " " .. tostring(msg)) end end
function BR.event(b, text, kind) if fn(M, "nbEvent") and type(b) == "table" then pcall(M.nbEvent, b, text, kind or "brain") end end
function BR.PA() return type(ProjectALife) == "table" and ProjectALife or {} end
function BR.base(id)
    if id == nil or id == "you" or not fn(M, "nbOf") then return nil end
    local b = M.nbOf(id)
    return type(b) == "table" and b.status == "active" and b or nil
end
-- the group a run belongs to: an NPC base, or (One Brain, ALifeBrainYou) your camp's record for "you"
function BR.home(id) return BR.base(id) end
function BR.count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
function BR.sortedKeys(t) local o = {}; for k in pairs(t or {}) do o[#o + 1] = k end; table.sort(o, function(a, b) return tostring(a) < tostring(b) end); return o end
function BR.str(b) if not fn(M, "nbStrength") then return 0 end local ok, s = pcall(M.nbStrength, b); return ok and tonumber(s) or 0 end
function BR.foodDays(b) return (tonumber(b and b.food) or 0) / math.max(1, tonumber(b and b.crewN) or 1) end
function BR.tie(b, o) if not fn(M, "dirTie") or type(o) ~= "table" then return 0 end local ok, v = pcall(M.dirTie, b, o); return ok and tonumber(v) or 0 end
function BR.tieState(v) if fn(M, "dirTieState") then return M.dirTieState(v) end return "neutral" end

-- MP (co-op: one shared camp): the camp's players = everyone online with a base (the same rule as M.homePlayer);
-- nobody with a base yet: the home player. Single player: you. Cached 2 s per player (M.alifeBase is a 1-slot cache).
BR._campBase = BR._campBase or {}
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function hasBase(p)
    local key = ALifeSide.keyOf(p) or tostring(p)
    local c = BR._campBase[key]
    local t = nowMs()
    if c == nil or t - c.at > 2000 or t < c.at then
        local ok, b = pcall(function() return fn(M, "alifeBase") and M.alifeBase(p) or nil end)
        c = { at = t, has = ok and b ~= nil }
        BR._campBase[key] = c
    end
    return c.has
end
local function mp() return fn(ALifeSide, "mpServer") and ALifeSide.mpServer() == true end
function BR.campPlayers()
    if not mp() then
        local p = nil
        if fn(ALifeSide, "localPlayer") then pcall(function() p = ALifeSide.localPlayer() end) end
        if p == nil and fn(ALifeSide, "you") then pcall(function() p = ALifeSide.you() end) end
        return p and { p } or {}
    end
    local out = {}
    for _, p in ipairs(ALifeSide.online()) do if hasBase(p) then out[#out + 1] = p end end
    if #out == 0 and fn(M, "homePlayer") then local ok, hp = pcall(M.homePlayer); if ok and hp ~= nil then out[1] = hp end end
    return out
end
function BR.isCampPlayer(player)
    if player == nil then return false end
    if not mp() then return true end
    local key = ALifeSide.keyOf(player)
    for _, p in ipairs(BR.campPlayers()) do if p == player or (key ~= nil and ALifeSide.keyOf(p) == key) then return true end end
    return false
end
local function xyOf(p) local x, y = nil, nil; pcall(function() x, y = p:getX(), p:getY() end); return x, y end
-- a camp player within tiles of (x, y)?
function BR.campPlayerNear(x, y, tiles)
    for _, p in ipairs(BR.campPlayers()) do local px, py = xyOf(p); if px and (px - x) ^ 2 + (py - y) ^ 2 < tiles * tiles then return p end end
    return nil
end
-- letters / cards to the whole camp (SP: you), or to whoever is near a spot
local function letterTo(p, text, bad)
    local T = ALifeTrade
    if fn(T, "letter") then return pcall(T.letter, p, text, bad == true) end
    if fn(ALifeSide, "outLetter") then return pcall(ALifeSide.outLetter, p, text, nil, nil, nil, bad == true) end
end
function BR.campLetter(text, bad)
    local n = 0
    for _, p in ipairs(BR.campPlayers()) do letterTo(p, text, bad); n = n + 1 end
    if n == 0 and not mp() then letterTo(nil, text, bad); n = 1 end -- SP with no player handle yet: the old path
    return n
end
function BR.nearLetter(x, y, tiles, text, bad)
    local n = 0
    if not (tonumber(x) and tonumber(y)) then return 0 end
    for _, p in ipairs(ALifeSide.online()) do
        local px, py = xyOf(p)
        if px and (px - x) ^ 2 + (py - y) ^ 2 < tiles * tiles then letterTo(p, text, bad); n = n + 1 end
    end
    return n
end
-- the same card to every camp player (MP: one ALifeOut card each, the choice runs as whoever answers; the first
-- answer settles it, a late click on the others finds it gone). SP: once.
function BR.campCard(card)
    if not mp() then
        if fn(M, "momCard") then local ok, r = pcall(M.momCard, card); return ok and r end
        return false
    end
    local any = false
    for _, p in ipairs(BR.campPlayers()) do local ok, r = pcall(ALifeSide.outCard, p, card); any = any or (ok and r) end
    return any
end

-- the brain runs only with Directive (it writes its goals) and the base simulation
function BR.on() return BR.setting("brain") ~= false and M.settings.directives ~= false end
-- a group the brain runs (main bases; outposts follow their parent, nomads on the road wait till they settle)
function BR.runs(b)
    return BR.on() and type(b) == "table" and b.status == "active" and not b.road and not b.outpostOf and not b.airport
end

-- per-group state, saved with the base record (plain tables, bounded lists)
function BR.of(b)
    if type(b) ~= "table" then return nil end
    local s = b.brain
    if type(s) ~= "table" then s = {}; b.brain = s end
    for _, k in ipairs({ "know", "inbox", "mind", "memory", "grudges", "debts", "alloc", "jobs", "events", "scores", "orders" }) do
        if type(s[k]) ~= "table" then s[k] = {} end
    end
    s.pressure = tonumber(s.pressure) or 0
    return s
end

----------------------------------------------------------------------------------------------------------------
-- tools: every existing system that uses a group's people registers here and is only started by the brain
-- spec = { id, job, minPeople, maxPeople, duration(b, target) (h), risk(b, target) (0..1), start(b, people, target, opts), stop(b, why) }
----------------------------------------------------------------------------------------------------------------
BR.tools = BR.tools or {}
function BR.tool(spec) if type(spec) == "table" and spec.id then BR.tools[spec.id] = spec end; return spec end
-- the brain owns this tool: its old daily roll is off (one caller per tool)
function BR.owns(id)
    local t = BR.tools[id]
    if not BR.on() or t == nil then return false end
    if type(t.owned) == "function" then local ok, v = pcall(t.owned); return ok and v == true end
    return true
end
BR.calling = nil -- { id, b } while the brain itself runs a tool
-- may the old code path run this tool for b now? (brain off, or it's the brain calling)
function BR.permit(id, b)
    if not BR.owns(id) then return true end
    if type(b) == "table" and (b.road or b.outpostOf or b.airport) then return true end -- not run by the brain
    local c = BR.calling
    return type(c) == "table" and c.id == id and (b == nil or c.b == b)
end
function BR.call(id, b, people, target, opts)
    local t = BR.tools[id]
    if t == nil or type(t.start) ~= "function" then return false, "no_tool" end
    local prev = BR.calling
    BR.calling = { id = id, b = b, people = people }
    local ok, a, c = pcall(t.start, b, people or {}, target, opts or {})
    BR.calling = prev
    if not ok then BR.log("tool " .. tostring(id) .. " failed: " .. tostring(a)); return false, "error" end
    BR.stats.tools = BR.stats.tools + 1
    return a, c
end

----------------------------------------------------------------------------------------------------------------
-- interrupts (think now, not tomorrow)
----------------------------------------------------------------------------------------------------------------
BR.stats = BR.stats or { thinks = 0, interrupts = 0, manages = 0, tools = 0, stanceChanges = 0, parties = 0, sieges = 0, scouts = 0,
    envoys = 0, tribute = 0, aborts = 0, plans = 0, beliefs = 0, lies = 0, recalls = 0, ms = 0 }
function BR.interrupt(b, kind, data)
    if not BR.runs(b) then return false end
    local s = BR.of(b)
    local ev = s.events
    for _, e in ipairs(ev) do if e.k == kind and e.a == (data and data.a) then return false end end
    ev[#ev + 1] = { k = tostring(kind), h = BR.hours(), a = data and data.a or nil }
    while #ev > 8 do table.remove(ev, 1) end
    s.urgent = true
    BR.stats.interrupts = BR.stats.interrupts + 1
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the tick: rides the base simulation (one base per tick slice already = staggered)
----------------------------------------------------------------------------------------------------------------
function BR.step(b, h, far, crew)
    if not BR.runs(b) or type(b.dir) ~= "table" then return end
    local s = BR.of(b)
    local day = math.floor(h / 24)
    local t0 = type(getTimestampMs) == "function" and getTimestampMs() or 0
    -- people changed (death, someone left / joined, a run came home): recount now
    local n = tonumber(b.crewN) or 0
    if s.crewSeen ~= n then
        if s.crewSeen and n < s.crewSeen then BR.interrupt(b, "lost"); s.lostToday = (tonumber(s.lostToday) or 0) + (s.crewSeen - n) end
        s.crewSeen = n; s.dirty = true
    end
    if b.lastAttack and (tonumber(b.lastAttack.h) or 0) > (tonumber(s.attackSeenH) or -1) then
        s.attackSeenH = b.lastAttack.h
        BR.interrupt(b, "attacked")
    end
    if s.knowDay ~= day and fn(BR, "knowDay") then s.knowDay = day; pcall(BR.knowDay, b, h) end
    if fn(BR, "mindRefresh") then pcall(BR.mindRefresh, b, h) end
    local think = s.thinkDay ~= day
    if not think and s.urgent then
        local every = 1 / math.max(0.1, BR.num("brainInterruptsPerHour"))
        if h - (tonumber(s.lastInterruptH) or -1e9) >= every then think = true; s.lastInterruptH = h end
    end
    if think and fn(BR, "think") then
        local why = s.thinkDay ~= day and "day" or "interrupt"
        s.thinkDay = day
        s.urgent = false
        local ok, err = pcall(BR.think, b, h, why)
        if not ok then BR.log("think failed for " .. tostring(b.name) .. ": " .. tostring(err)) end
        BR.stats.thinks = BR.stats.thinks + 1
        s.dirty = true
    end
    if (s.dirty or h - (tonumber(s.mgrH) or -1e9) >= BR.num("brainManagerH")) and fn(BR, "manage") then
        s.mgrH = h
        s.dirty = false
        local ok, err = pcall(BR.manage, b, h, far)
        if not ok then BR.log("manage failed for " .. tostring(b.name) .. ": " .. tostring(err)) end
        BR.stats.manages = BR.stats.manages + 1
    end
    if type(getTimestampMs) == "function" then BR.stats.ms = BR.stats.ms + (getTimestampMs() - t0) end
end

function BR.perf()
    local s = BR.stats
    return "brain: thinks " .. s.thinks .. ", interrupts " .. s.interrupts .. ", manages " .. s.manages .. ", tools " .. s.tools
        .. ", stance changes " .. s.stanceChanges .. ", war parties " .. s.parties .. ", sieges " .. s.sieges .. ", scouts " .. s.scouts
        .. ", envoys " .. s.envoys .. ", tribute " .. s.tribute .. ", plans " .. s.plans .. ", aborts " .. s.aborts .. ", recalls " .. s.recalls
        .. ", beliefs " .. s.beliefs .. ", lies caught " .. s.lies .. ", " .. s.ms .. " ms"
end
M.brainPerf = BR.perf

----------------------------------------------------------------------------------------------------------------
-- install: one nbStep wrap (the brain is the last link, so it sees the day after everything else ran)
----------------------------------------------------------------------------------------------------------------
BR.installers = BR.installers or {} -- sub-files add f() -> true when their wraps are in
M._alcpHooks = M._alcpHooks or {}
function BR.install()
    local okAll = true
    if not M._alcpHooks.brainStep and type(M.nbStep) == "function" then
        M._alcpHooks.brainStep = true
        local step = M.nbStep
        M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
            local r = step(b, haven, crew, home, dt, h, far, scan, ...)
            if BR.on() and type(b) == "table" and b.status == "active" then
                local ok, err = pcall(BR.step, b, h, far, crew)
                if not ok then BR.log("step failed: " .. tostring(err)) end
            end
            return r
        end
    end
    if not M._alcpHooks.brainStep then okAll = false end
    for _, f in ipairs(BR.installers) do
        local ok, res = pcall(f)
        if not ok then BR.log("install failed: " .. tostring(res)); okAll = false elseif res == false then okAll = false end
    end
    return okAll
end
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(BR.install)
        pcall(BR.installRows)
        local n, tools = 0, BR.count(BR.tools)
        if fn(M, "nbActive") then for _, b in ipairs(M.nbActive()) do if type(b.brain) == "table" then n = n + 1 end end end
        print(BR.TAG .. " ready v" .. BR.VERSION .. ": brain " .. (BR.on() and "on" or "off") .. " (" .. n .. " groups thinking, " .. tools
            .. " tools), war parties " .. (BR.flag("warParties") and "on" or "off") .. ", fog " .. (BR.num("brainCheat") > 0 and "fuzzy" or "strict"))
    end)
end
