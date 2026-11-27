-- A-Life Chat Plus (merged with A-Life Talk): GROUP DIRECTIVES.
-- Every NPC base (A-Life Talk's bases: real houses, real members, morale, food, attacks) gets a way of running
-- itself, a belief about outsiders, and goals for today, this week and this month. The goals push the base's own
-- simulation (food, fortifying, taking people in, raiding), so when you come back a week or two later things have
-- really changed: people lost or taken in, the place boarded up or falling apart, a new leader, a vote that closed
-- the gates. All of it goes into the base's history and into what its people say to you. Nothing is shown as
-- numbers; you learn it by talking to them or by what you find.
--   rule:  leader (one person decides) | council (the steady ones decide together) | vote (everyone votes) |
--          faith (a preacher and the flock)
--   creed: open (strangers welcome) | wary (prove yourself) | closed (no outsiders) | raiders (take what we need) |
--          faithful (save the lost) | traders (deal with anyone)
-- Deaths are never invented: losses come from A-Life Talk's own attacks / A-Life. Raids between bases move food
-- and morale, not lives. Runs inside the base simulation (one base per minute, offline-friendly).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Directive") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Directive"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Directive") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(seed) if ALifeRoll01 then return ALifeRoll01(seed) end local h = (hash(seed) * 16807) % 2147483647; h = (h * 16807) % 2147483647; return (h % 10000) / 10000 end -- 0.6.8: well mixed
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function log(msg) if M.log then M.log("directive: " .. tostring(msg)) end end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "directive") end end
local function lensOf(uid) local ok, l = pcall(function() return M.lens(tostring(uid)) end); return ok and type(l) == "table" and l or {} end
local function coreKey(uid)
    local ok, k = pcall(function() local p = M.partsOf(tostring(uid)); return p and p.core and p.core.key end)
    return ok and k or nil
end

if M.settings.directives == nil then M.settings.directives = true end
M.dirCfg = { raidEveryH = 120, raidTiles = 700, weekH = 168, monthH = 720 }

M.dirRuleWords = {
    leader = "one person calls the shots and the rest follow",
    council = "the steadiest few decide things together",
    vote = "big decisions go to a vote, everyone has a say",
    faith = "a preacher leads and the rest are a flock",
}
M.dirCreedWords = {
    open = "strangers are welcome if they pull their weight",
    wary = "strangers have to prove themselves first",
    closed = "no outsiders, period",
    raiders = "they take what they need from others",
    faithful = "they believe they're meant to save the lost",
    traders = "they'll deal with anyone who has something to trade",
}
M.dirGoalWords = {
    forage = "scrounge up food", fortify = "board the place up", guard = "keep watch after the last attack",
    rest = "rest and patch people up", scout = "scout the area", stockpile = "stock up for the weeks ahead",
    finish = "finish fortifying the house", grow = "take in more people", medicine = "find medicine",
    avenge = "get even with %s", raid = "hit another group for supplies", selfsufficient = "become self-sufficient",
    grow8 = "grow into a real community", rule = "make this area theirs", flock = "bring more people into the faith",
    endure = "make it through the month",
    ammo = "find ammunition", absorb = "take over %s", -- 0.6.3
}

----------------------------------------------------------------------------------------------------------------
-- founding a directive: how a group runs itself and what it believes comes from who leads it and who they are
----------------------------------------------------------------------------------------------------------------
local LEADERISH = { hothead = 1, bossy = 1, proud = 1, shotcaller = 1, sheriff = 1, sergeant_law = 1, officer_mil = 1, nco = 1,
    hardass = 1, mobster = 1, biker_pres = 1, ruthless = 1, cruel = 1, bully = 1 }
local FAITHISH = { devout = 1, pastor = 1, chaplain = 1, churchlady = 1, delusional = 1, penitent = 1, doomsayer = 1 }
local KINDISH = { gentle = 1, kind = 1, nurturing = 1, idealist = 1, cheerful = 1, generous = 1, teacher = 1, nurse = 1, honest = 1 }
local HARDISH = { ruthless = 1, cruel = 1, greedy = 1, mean = 1, sadist = 1, mercenary_soul = 1, gangbanger = 1, methcook = 1, hitman = 1 }

function M.dirFound(b)
    local leadKey = b.leader and coreKey(b.leader) or nil
    local kind, hard, faith = 0, 0, 0
    for k in pairs(b.roster or {}) do
        local e = b.roster[k]
        local ck = type(e) == "table" and e.u and coreKey(e.u) or nil
        if ck then
            if KINDISH[ck] then kind = kind + 1 end
            if HARDISH[ck] then hard = hard + 1 end
            if FAITHISH[ck] then faith = faith + 1 end
        end
    end
    local n = math.max(1, tonumber(b.crewN) or 1)
    local rule = "council"
    if FAITHISH[leadKey] or faith * 2 >= n then rule = "faith"
    elseif LEADERISH[leadKey] or n <= 2 then rule = "leader"
    elseif n >= 4 and kind * 2 >= n then rule = "vote" end
    local fac = tostring(b.faction or "")
    local creed = "wary"
    if rule == "faith" then creed = "faithful"
    elseif HARDISH[leadKey] or hard * 2 >= n or string.find(fac, "raider") or string.find(fac, "bandit") or string.find(fac, "gang") then creed = "raiders"
    elseif KINDISH[leadKey] or kind * 2 >= n then creed = "open"
    elseif string.find(fac, "trader") or string.find(fac, "merchant") then creed = "traders"
    elseif roll(b.id .. "#creed") < 0.25 then creed = "closed" end
    b.dir = { rule = rule, creed = creed, since = hours(), goals = {}, enemies = {}, visits = {}, lastLeader = b.leader,
        startCrew = n, raids = 0, lastDay = -1 }
    log((b.name or b.id) .. ": rule " .. rule .. ", creed " .. creed)
end

----------------------------------------------------------------------------------------------------------------
-- goals
----------------------------------------------------------------------------------------------------------------
local function perHead(b) return (tonumber(b.food) or 0) / math.max(1, tonumber(b.crewN) or 1) end
-- pre-1.0 (greed, ALifeTalk_TradeGreed): how much is "enough" is a setting now; it's the apocalypse, they want more
local function greed(key, old) local v = M.settings and tonumber(M.settings[key]); if v == nil or (M.settings and M.settings.greed == false) then return old end; return v end
local function recent(list, h, win) local c = 0; for _, t in ipairs(list or {}) do if h - (tonumber(t) or -1e9) <= win then c = c + 1 end end; return c end
local function nearestEnemy(b)
    for id, _ in pairs(b.dir.enemies or {}) do
        local o = M.nbOf and M.nbOf(id) or nil
        if o and o.status == "active" then return o end
    end
    return nil
end

function M.dirPickDay(b, h)
    local d = b.dir
    local ph = perHead(b)
    local g
    if b.lastAttack and h - (b.lastAttack.h or -1e9) < 48 then g = "guard"
    elseif ph < greed("greedForageDays", 2) then g = "forage"
    elseif (tonumber(b.morale) or 50) < 35 then g = "rest"
    elseif b.stage ~= "fortified" then g = "fortify"
    else g = (roll(b.id .. "#day" .. math.floor(h / 24)) < 0.5) and "forage" or "scout" end
    d.goals.day = { g = g, at = h }
end

function M.dirPickWeek(b, h, crew)
    local d = b.dir
    pcall(M.dirSpecialize, b, crew) -- 0.6.4: once a week
    local g, target
    local enemy = nearestEnemy(b)
    local mood, mf = "steady", {}
    if M.nbMood then mood, mf = M.nbMood(b) end
    local prey = M.dirPrey and M.dirPrey(b) or nil
    if prey and d.creed ~= "closed" then g, target = "absorb", prey.id      -- 0.6.3: strong enough to take a weak group in
    elseif mf.noAmmo and d.creed ~= "faithful" then g = "ammo"              -- 0.6.3: from what's really in their stash
    elseif enemy and (d.creed == "raiders" or d.rule == "leader") then g, target = "avenge", enemy.id
    elseif d.creed == "raiders" then g = "raid"
    elseif perHead(b) < greed("greedStockBelow", 5) then g = "stockpile"
    elseif b.stage ~= "fortified" then g = "finish"
    elseif (tonumber(b.crewN) or 1) < 5 and (d.creed == "open" or d.creed == "faithful") then g = "grow"
    elseif recent(b.losses, h, 168) > 0 or roll(b.id .. "#med" .. math.floor(h / 168)) < 0.3 then g = "medicine"
    else g = "stockpile" end
    local goods = type(b.goods) == "table" and b.goods or {}
    d.goals.week = { g = g, at = h, target = target, crew0 = tonumber(b.crewN) or 1, meds0 = tonumber(goods.meds) or 0 }
end

function M.dirPickMonth(b, h)
    local d = b.dir
    local g
    if d.creed == "raiders" then g = "rule"
    elseif d.rule == "faith" then g = "flock"
    elseif (tonumber(b.crewN) or 1) >= 4 and (d.creed == "open" or d.creed == "traders") then g = "grow8"
    elseif b.stage == "fortified" then g = "selfsufficient"
    else g = "endure" end
    d.goals.month = { g = g, at = h, crew0 = tonumber(b.crewN) or 1, raids0 = d.raids or 0 }
end

local function goalText(goal, b)
    if type(goal) ~= "table" then return nil end
    local w = M.dirGoalWords[goal.g] or goal.g
    if goal.g == "avenge" or goal.g == "absorb" then
        local o = goal.target and M.nbOf and M.nbOf(goal.target)
        w = string.format(w, o and o.name or "the ones who hit them")
    end
    return w
end

-- the day's work actually moves the base along (on top of A-Life Talk's own simulation)
function M.dirWork(b, home, dt)
    local d, cfg = b.dir, M.nbCfg or {}
    local day = d.goals.day and d.goals.day.g
    local n = math.max(1, tonumber(b.crewN) or 1)
    b.forageMul = 1 -- 0.6.1: goals push how hard they forage (real food from the land), never make food
    if day == "forage" then
        b.forageMul = 1.5
    elseif day == "fortify" and b.stage ~= "fortified" then
        b.work = math.min(cfg.fortWork or 100, (b.work or 0) + home * dt * (cfg.workPerCrewH or 0.35) * 0.6)
    elseif day == "rest" then
        b.morale = clamp((b.morale or 50) + dt / 24 * 5, 0, 100)
    end
    local week = d.goals.week and d.goals.week.g
    if week == "stockpile" then b.forageMul = (b.forageMul or 1) + 0.25 end
    M.dirTradeEffects(b) -- 0.6.4
end

-- 0.6.4: SPECIALIZATION. As the world runs dry a group drifts into what it's good at: who its people were (their
-- backgrounds, the same table camp roles use), what their house is (fields and barns), what's in their stash, how they
-- behave. Re-checked once a week; it only changes when something else is clearly better. Nothing is made: farmers
-- forage more from their land, crafters work faster, warbands raid, traders get along with everyone.
--   slavers (dark content setting, off by default): a hard-ruled warband; taking captives comes with 0.7's captives.
M.dirTradeWords = { farmers = "they live off their fields and animals", crafters = "they fix and make things",
    traders = "they trade with anyone", warband = "they live by taking from others", slavers = "they take people" }
local FARM_ROOMS = { "farm", "barn", "greenhouse", "stable", "silo", "orchard", "coop" }
local function bgOf(uid)
    local k = nil
    pcall(function() local p = M.partsOf and M.partsOf(tostring(uid)); k = p and p.bg and (p.bg.key or p.bg.k) end)
    return k and tostring(k) or nil
end
local function farmRooms(b)
    if b.farmRooms ~= nil then return b.farmRooms end
    local n = 0
    pcall(function()
        local def = M.nbDefAt and M.nbDefAt(b.x, b.y)
        local rooms = def and def:getRooms()
        for i = 0, (rooms and math.min(rooms:size(), 40) or 0) - 1 do
            local name = string.lower(tostring(rooms:get(i):getName() or ""))
            for _, w in ipairs(FARM_ROOMS) do if string.find(name, w, 1, true) then n = n + 1; break end end
        end
    end)
    b.farmRooms = n
    return n
end
function M.dirTradeScores(b, crew)
    local bgT = M.cpRoleBg or {}
    local sc = { farmers = 0, crafters = 0, traders = 0, warband = 0 }
    for _, r in ipairs(crew or {}) do
        local bg = r and r.uid and bgOf(r.uid) or nil
        if bg then
            sc.farmers = sc.farmers + ((bgT.farmer or {})[bg] or 0)
            sc.crafters = sc.crafters + ((bgT.builder or {})[bg] or 0)
            sc.warband = sc.warband + 0.6 * ((bgT.guard or {})[bg] or 0)
        end
    end
    sc.farmers = sc.farmers + 2 * farmRooms(b) + (b.town == false and 1 or 0)
    local g = type(b.goods) == "table" and b.goods or {}
    if (g.tools or 0) >= 3 then sc.crafters = sc.crafters + 1.5 end
    if (g.materials or 0) >= 10 then sc.crafters = sc.crafters + 1 end
    local d = b.dir or {}
    if d.creed == "raiders" then sc.warband = sc.warband + 3 end
    sc.warband = sc.warband + 0.5 * (tonumber(d.raids) or 0)
    if d.creed == "traders" then sc.traders = sc.traders + 3 end
    return sc
end
function M.dirSpecialize(b, crew)
    local sc = M.dirTradeScores(b, crew)
    local best, bs = nil, 1.5                          -- below this they're just survivors, nothing special
    for k, v in pairs(sc) do if v > bs or (v == bs and best and k < best) then best, bs = k, v end end
    local cur = b.trade
    if cur and cur ~= "slavers" and sc[cur] and (best and bs < sc[cur] + 1 or not best and sc[cur] >= 1) then best = cur end -- sticky: change only for clearly better
    if best == "warband" and M.settings.darkContent == true and (b.dir and b.dir.rule == "leader") and (b.dir.creed == "raiders") then best = "slavers" end
    if cur ~= best then
        b.trade = best
        if best then event(b, "They've become " .. (({ warband = "a warband" })[best] or best) .. ": " .. tostring(M.dirTradeWords[best] or best), "trade") end
    end
    return best
end
function M.dirTradeEffects(b)
    local t = b.trade
    b.workMul = (t == "crafters") and 1.5 or 1
    if t == "farmers" then b.forageMul = (tonumber(b.forageMul) or 1) * ((b.town == false) and 1.6 or 1.2) end
end
-- 0.6.3: a weak group nearby that this one could take in: much weaker, or desperate, and not their ally
function M.dirPrey(b)
    if not (M.nbStrength and M.nbActive) or b.status ~= "active" then return nil end
    local mine = M.nbStrength(b)
    if mine <= 0 then return nil end
    local best, bestD = nil, (M.dirCfg.raidTiles or 600) ^ 2
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and not o.airport and o.outpostOf ~= b.id and b.outpostOf ~= o.id then -- 0.6.5: never their own outpost
            local st = M.dirTieState(M.dirTie(b, o))
            local theirs = M.nbStrength(o)
            local omood = M.nbMood and M.nbMood(o) or "steady"
            local dd = (o.x - b.x) ^ 2 + (o.y - b.y) ^ 2
            if st ~= "allied" and dd <= bestD and (mine >= 2 * theirs or (omood == "desperate" and mine > theirs)) then best, bestD = o, dd end
        end
    end
    return best
end
local function playersFar(b, o)
    local far = M.nbCfg and M.nbCfg.farTiles or 150
    local ok, res = pcall(function()
        local list = {}
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then list = ALifeSide.online() -- pre-1.0 MP: every online player
        else
            local n = (type(getNumActivePlayers) == "function" and getNumActivePlayers()) or 1
            for i = 0, n - 1 do list[#list + 1] = getSpecificPlayer(i) end
        end
        for _, p in ipairs(list) do
            if p then
                for _, x in ipairs({ b, o }) do
                    if (p:getX() - x.x) ^ 2 + (p:getY() - x.y) ^ 2 < far * far then return false end
                end
            end
        end
        return true
    end)
    return ok and res
end
-- the attempt, once a day while the goal stands: a contest of real strength with real chance in it. The weak can
-- hold them off (and the attacker pays for trying); the desperate may just give in. Only while nobody is watching.
M.dirAbsorbStats = { tries = 0, taken = 0, held = 0 }
function M.dirTryAbsorb(b, w, h)
    local o = w.target and M.nbOf and M.nbOf(w.target) or nil
    if o == nil or o.status ~= "active" then w.hit = nil; b.dir.goals.week = nil; return end
    if not playersFar(b, o) then return end
    M.dirAbsorbStats.tries = M.dirAbsorbStats.tries + 1
    local mine, theirs = M.nbStrength(b), M.nbStrength(o)
    local omood = M.nbMood and M.nbMood(o) or "steady"
    local give = (omood == "desperate") and 0.35 or 0                          -- starving people may just come over
    local p = give + (1 - give) * (mine / (mine + theirs * 1.5))                -- defenders count for more
    if roll(b.id .. "#absorb" .. o.id .. math.floor(h / 24)) < p then
        local ok, moved = M.nbAbsorb(b, o, h)
        if ok then
            M.dirAbsorbStats.taken = M.dirAbsorbStats.taken + 1
            w.hit = true
            event(b, "They took in what was left of " .. tostring(o.name) .. ((moved or 0) > 0 and (" - " .. moved .. " people came over") or ""), "absorb")
            event(o, tostring(b.name) .. " took them in", "absorbed")
            M.dirBumpTie(b, o, 20)
        end
    else
        M.dirAbsorbStats.held = M.dirAbsorbStats.held + 1
        b.morale = clamp((b.morale or 50) - 8, 0, 100)
        o.morale = clamp((o.morale or 50) + 6, 0, 100)
        M.dirBumpTie(b, o, -25)
        event(b, "They tried to take over " .. tostring(o.name) .. " and were sent off", "absorb")
        event(o, "They held off " .. tostring(b.name), "held")
        w.at = w.at - (M.dirCfg.weekH or 168) -- one failed try ends the week's plan
    end
end

local function finishGoal(b, slot, ok, text)
    local d = b.dir
    d.goals[slot] = nil
    if ok then
        b.morale = clamp((b.morale or 50) + (slot == "month" and 15 or 6), 0, 100)
        event(b, text, "goal_done")
    else
        b.morale = clamp((b.morale or 50) - (slot == "month" and 10 or 4), 0, 100)
        event(b, text, "goal_failed")
        d.fails = (d.fails or 0) + 1
    end
end

function M.dirCheckGoals(b, h, haven, scan)
    local d = b.dir
    local w = d.goals.week
    if w then
        local age = h - w.at
        local done = (w.g == "stockpile" and perHead(b) >= greed("greedStockDays", 10)) or (w.g == "finish" and b.stage == "fortified")
            or (w.g == "grow" and (tonumber(b.crewN) or 1) >= w.crew0 + 2)
            or (w.g == "medicine" and (tonumber(type(b.goods) == "table" and b.goods.meds) or 0) > (tonumber(w.meds0) or 0)) -- 0.6.3: real medicine came in
            or (w.g == "ammo" and (tonumber(type(b.goods) == "table" and b.goods.ammo) or 0) > 0)
            or (w.g == "absorb" and w.hit == true)
            or ((w.g == "raid" or w.g == "avenge") and w.hit == true)
        if done then
            local words = { stockpile = "They stocked up enough food for a couple of weeks", finish = "They finished boarding up " .. tostring(b.name),
                grow = "They took in new people", medicine = "Someone came back with medicine", raid = "Their raid paid off",
                avenge = "They got even", ammo = "They found ammunition", absorb = "They took in what was left of another group" }
            finishGoal(b, "week", true, words[w.g] or "They got what they set out to do")
        elseif age >= M.dirCfg.weekH then
            local words = { stockpile = "They never managed to stock up - food is still tight", finish = "The boarding-up stalled",
                grow = "Nobody new came", medicine = "They never found the medicine they needed", raid = "The raid never happened",
                avenge = "They never got their revenge", ammo = "They're still short of ammunition", absorb = "The takeover never happened" }
            finishGoal(b, "week", false, words[w.g] or "Their plans fell through")
        elseif w.g == "absorb" and b.dir.absorbDay ~= math.floor(h / 24) then
            b.dir.absorbDay = math.floor(h / 24)
            local ok, res = pcall(M.dirTryAbsorb, b, w, h)
            if not ok then log("absorb error: " .. tostring(res)) end
            if b.status ~= "active" then return end
        elseif w.g == "grow" and M.nbRecruit and b.dir.growDay ~= math.floor(h / 24) and (tonumber(b.morale) or 50) >= 40 then
            b.dir.growDay = math.floor(h / 24)
            pcall(M.nbRecruit, b, haven, h, scan or (M.nbScan and M.nbScan()) or {})
        end
    end
    local m = d.goals.month
    if m then
        local age = h - m.at
        local done = (m.g == "selfsufficient" and b.stage == "fortified" and perHead(b) >= greed("greedSelfDays", 12))
            or (m.g == "grow8" and (tonumber(b.crewN) or 1) >= 8)
            or (m.g == "rule" and (d.raids or 0) - (m.raids0 or 0) >= 2)
            or (m.g == "flock" and (tonumber(b.crewN) or 1) >= m.crew0 + 3)
        if done then
            local words = { selfsufficient = tostring(b.name) .. " can feed and defend itself now", grow8 = "They've grown into a real community",
                rule = "Everyone around here knows to pay them or stay away", flock = "Their flock has grown" }
            finishGoal(b, "month", true, words[m.g] or "They made it")
        elseif age >= M.dirCfg.monthH then
            if m.g == "endure" then finishGoal(b, "month", true, "They made it through another month")
            else finishGoal(b, "month", false, "A month on, they're no closer to what they wanted") end
        end
    end
end


----------------------------------------------------------------------------------------------------------------
-- community relations: bases near each other build ties (trade, help, raids, grudges) -> allies, rivals, war
----------------------------------------------------------------------------------------------------------------
M.dirTieWords = { allied = "allies", friendly = "on good terms", neutral = "no dealings", rivals = "rivals", war = "at war" }
function M.dirTieState(v) v = tonumber(v) or 0; if v >= 40 then return "allied" elseif v >= 15 then return "friendly" elseif v <= -50 then return "war" elseif v <= -20 then return "rivals" end return "neutral" end
local CREED_PULL = { open = 2, traders = 3, faithful = 1, wary = 0, closed = -1, raiders = -4 }
function M.dirTie(b, o) return b.dir and b.dir.ties and tonumber(b.dir.ties[o.id]) or 0 end
-- 0.6.6: nudge how two groups feel about each other (both ways), -100..100
function M.dirTieAdd(b, o, delta)
    if type(b) ~= "table" or type(o) ~= "table" or b.id == o.id then return end
    for _, pair in ipairs({ { b, o }, { o, b } }) do
        local x, y = pair[1], pair[2]
        x.dir = type(x.dir) == "table" and x.dir or {}
        x.dir.ties = type(x.dir.ties) == "table" and x.dir.ties or {}
        x.dir.ties[y.id] = math.max(-100, math.min(100, (tonumber(x.dir.ties[y.id]) or 0) + (tonumber(delta) or 0)))
    end
end
function M.dirBumpTie(a, b, d, why)
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local x, y = pair[1], pair[2]
        if type(x.dir) == "table" then
            x.dir.ties = x.dir.ties or {}
            local before = M.dirTieState(x.dir.ties[y.id])
            x.dir.ties[y.id] = clamp((tonumber(x.dir.ties[y.id]) or 0) + d, -100, 100)
            local after = M.dirTieState(x.dir.ties[y.id])
            if after ~= before and x == a then
                local words = { allied = "%s and %s made a pact to look out for each other", friendly = "%s and %s are on good terms now",
                    neutral = "%s and %s stopped having anything to do with each other", rivals = "Bad blood between %s and %s",
                    war = "%s and %s are at war" }
                local t = string.format(words[after], tostring(a.name), tostring(b.name))
                event(a, t, "tie"); event(b, t, "tie")
            end
        end
    end
end
function M.dirNeighbours(b)
    local out = {}
    for _, o in ipairs(M.nbActive and M.nbActive() or {}) do
        if o.id ~= b.id and o.status == "active" and type(o.dir) == "table" and (o.x - b.x) ^ 2 + (o.y - b.y) ^ 2 <= M.dirCfg.raidTiles ^ 2 then out[#out + 1] = o end
    end
    return out
end
function M.dirRelations(b, h, far)
    local d = b.dir
    local day = math.floor(h / 24)
    if d.tieDay == day then return end
    d.tieDay = day
    for _, o in ipairs(M.dirNeighbours(b)) do
        if b.id < o.id then -- each pair once a day
            local pull = (CREED_PULL[d.creed] or 0) + (CREED_PULL[o.dir.creed] or 0)
                + ((b.trade == "traders" or o.trade == "traders") and 1 or 0) -- 0.6.4: traders keep the peace
            local jitter = math.floor(roll(b.id .. o.id .. "#tie" .. day) * 5) - 2
            M.dirBumpTie(b, o, pull + jitter)
            -- allies help each other when one is starving (offline)
            if far and M.dirTieState(M.dirTie(b, o)) == "allied" then
                for _, pair in ipairs({ { b, o }, { o, b } }) do
                    local giver, taker = pair[1], pair[2]
                    if perHead(taker) < 1 and perHead(giver) >= 4 then
                        local give = math.min((giver.food or 0) * 0.3, (taker.crewN or 1) * 3)
                        if M.nbFoodTake then give = M.nbFoodTake(giver, give); M.nbFoodAdd(taker, give) -- 0.6.1: moved, not made
                        else giver.food = (giver.food or 0) - give; taker.food = (taker.food or 0) + give end
                        event(giver, "They sent food to their allies at " .. tostring(taker.name), "aid")
                        event(taker, tostring(giver.name) .. " sent them food when they were starving", "aid")
                        M.dirBumpTie(giver, taker, 8)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- raids between bases (offline only): food and morale change hands, never lives
----------------------------------------------------------------------------------------------------------------
function M.dirRaid(b, h, far)
    local d = b.dir
    -- 0.6.1: the ledger decides too: the desperate raid even if they never did; with no ammo they don't pick fights
    local mood, mf = "steady", {}
    if M.nbMood then mood, mf = M.nbMood(b) end
    local warlike = d.creed == "raiders" or b.trade == "warband" or b.trade == "slavers" -- 0.6.4
    if not far or not warlike and not (d.goals.week and d.goals.week.g == "avenge") and mood ~= "desperate" then return end
    if mf.noAmmo and mood ~= "desperate" then return end
    if h - (d.lastRaidH or -1e9) < M.dirCfg.raidEveryH then return end
    if roll(b.id .. "#raid" .. math.floor(h / 24)) > (mood == "desperate" and 0.5 or 0.25) then return end
    local target = d.goals.week and d.goals.week.target and M.nbOf and M.nbOf(d.goals.week.target) or nil
    if target == nil and M.nbActive then
        local best, bd = nil, M.dirCfg.raidTiles ^ 2
        for _, o in ipairs(M.nbActive()) do
            local st = M.dirTieState(M.dirTie(b, o))
            if o.id ~= b.id and o.status == "active" and st ~= "allied" and st ~= "friendly" then
                local dd = (o.x - b.x) ^ 2 + (o.y - b.y) ^ 2
                if st == "war" or st == "rivals" then dd = dd * 0.25 end
                if dd < bd then best, bd = o, dd end
            end
        end
        target = best
    end
    if target == nil then return end
    d.lastRaidH = h
    local mine, theirs = math.max(1, tonumber(b.crewN) or 1), math.max(1, tonumber(target.crewN) or 1)
    local odds = mine / (mine + theirs) + (target.stage == "fortified" and -0.2 or 0)
    if mf.noAmmo then odds = odds - 0.15 end -- 0.6.1: going in with knives
    if M.nbMood then local _, tf = M.nbMood(target); if tf.noAmmo then odds = odds + 0.1 end end
    target.dir = target.dir or nil
    if roll(b.id .. "#raidwin" .. math.floor(h)) < odds then
        local took = math.min(tonumber(target.food) or 0, mine * 3)
        if took < 1 then
            event(b, "They hit " .. tostring(target.name) .. " but there was nothing worth taking", "raid")
            event(target, tostring(b.name) .. " raided them, but found the cupboards bare", "raided")
            if type(M.wmRecord) == "function" then pcall(M.wmRecord, b, target, h, true) end -- 0.7.0: the war map keeps score
            return
        end
        if M.nbFoodTake then took = M.nbFoodTake(target, took); M.nbFoodAdd(b, took) -- 0.6.1: moved, not made
        else target.food = (tonumber(target.food) or 0) - took; b.food = (tonumber(b.food) or 0) + took end
        target.morale = clamp((target.morale or 50) - 12, 0, 100)
        b.morale = clamp((b.morale or 50) + 6, 0, 100)
        d.raids = (d.raids or 0) + 1
        if d.goals.week then d.goals.week.hit = true end
        -- 0.6.14: and the most valuable things they can carry off (moved, not made)
        local loot = 0
        pcall(function()
            if type(ALifeWorth) ~= "table" or M.settings.itemWorth == false then return end
            local tl = M.nbStashList(M.nbHavenOf(target))
            local ml = M.nbStashList(M.nbHavenOf(b), true)
            if tl == nil or ml == nil then return end
            local idx = ALifeWorth.best(tl, math.min(4, mine), { food = true, water = true })
            table.sort(idx, function(x, y) return x > y end)
            for _, i in ipairs(idx) do ml[#ml + 1] = table.remove(tl, i); loot = loot + 1 end
            if M.nbFoodSync then M.nbFoodSync(target, M.nbHavenOf(target)); M.nbFoodSync(b, M.nbHavenOf(b)) end
        end)
        event(b, "They raided " .. tostring(target.name) .. " and came back with food" .. (loot > 0 and (" and " .. loot .. " of their best things") or ""), "raid")
        event(target, tostring(b.name) .. " raided them and took food", "raided")
        if type(M.wmRecord) == "function" then pcall(M.wmRecord, b, target, h, true) end
    else
        b.morale = clamp((b.morale or 50) - 8, 0, 100)
        event(b, "Their raid on " .. tostring(target.name) .. " went bad - they were driven off", "raid_failed")
        event(target, "They drove off a raid by " .. tostring(b.name), "defended")
        if type(M.wmRecord) == "function" then pcall(M.wmRecord, b, target, h, false) end
    end
    if type(target.dir) == "table" then M.dirBumpTie(b, target, -35) end
    if target.dir then
        target.dir.enemies = target.dir.enemies or {}
        target.dir.enemies[b.id] = h
        target.dir.hits = (target.dir.hits or 0) + 1
    end
end

----------------------------------------------------------------------------------------------------------------
-- politics: who leads, what they believe, and how that changes with what happens to them
----------------------------------------------------------------------------------------------------------------
function M.dirPolitics(b, h)
    local d = b.dir
    -- a new leader (the old one died or left): how it happens depends on how they run things
    if b.leader ~= d.lastLeader then
        local who = b.leaderName or "someone"
        if d.lastLeader ~= nil and b.leader ~= nil then
            local how = ({ leader = who .. " took charge after they lost their leader", council = "The others picked " .. who .. " to lead now",
                vote = "They held a vote - " .. who .. " leads now", faith = who .. " says the calling passed to them now" })[d.rule]
            event(b, how or (who .. " leads them now"), "leader")
            if d.rule == "leader" and roll(b.id .. "#split" .. math.floor(h)) < 0.3 then
                d.rule = "council"; event(b, "Without their old leader they started deciding things together", "rule")
            end
        end
        d.lastLeader = b.leader
    end
    local day = math.floor(h / 24)
    if d.lastDay == day then return end
    d.lastDay = day
    local morale = tonumber(b.morale) or 50
    local hits = recent(b.attacks, h, 168) + (d.hits or 0)
    d.hits = 0
    -- hardening after being hit
    if hits >= 2 and (d.creed == "open" or d.creed == "traders" or d.creed == "faithful") and roll(b.id .. "#harden" .. day) < 0.5 then
        local was = d.creed; d.creed = "wary"
        event(b, (d.rule == "vote" and "After the attacks they voted to stop taking in strangers so easily" or "After the attacks they stopped trusting strangers"), "creed")
        log((b.name or b.id) .. ": " .. was .. " -> wary")
    elseif hits >= 2 and d.creed == "wary" and roll(b.id .. "#close" .. day) < 0.35 then
        d.creed = "closed"
        event(b, (d.rule == "vote" and "They voted to close the gates to outsiders" or "They closed the gates to outsiders"), "creed")
    end
    -- hunger turns people
    if (tonumber(b.starveH) or 0) >= 36 and d.creed ~= "raiders" then
        local lk = b.leader and coreKey(b.leader) or nil
        local hard = HARDISH[lk] or LEADERISH[lk]
        local chance = hard and 0.4 or ((KINDISH[lk] or d.creed == "faithful") and 0.03 or 0.1)
        if roll(b.id .. "#starve" .. day) < chance then
            d.creed = "raiders"
            event(b, "Starving, they decided to take what they need from others", "creed")
        end
    end
    -- good times soften
    if morale >= 70 and hits == 0 and (d.creed == "closed" or d.creed == "wary") and roll(b.id .. "#soften" .. day) < 0.1 then
        d.creed = d.creed == "closed" and "wary" or "open"
        event(b, (d.rule == "vote" and "Things are good - they voted to open up to newcomers again" or "With things going well they've started letting people in again"), "creed")
    end
    -- unrest: a leader who keeps failing gets pushed out, a council can turn into a vote
    if morale < 25 and (d.fails or 0) >= 2 then
        d.fails = 0
        if d.rule == "leader" or d.rule == "faith" then
            d.rule = "council"
            event(b, "People got fed up with " .. tostring(b.leaderName or "their leader") .. " calling the shots - they decide together now", "rule")
        elseif d.rule == "council" and (tonumber(b.crewN) or 1) >= 4 then
            d.rule = "vote"
            event(b, "Arguments boiled over; now they put everything to a vote", "rule")
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- hooks into A-Life Talk's base simulation, welcome rules and AI context
----------------------------------------------------------------------------------------------------------------
function M.dirTick(b, haven, crew, home, dt, h, far, scan)
    if type(b) == "table" and (type(b.road) == "table" or b.outpostOf) then return end -- 0.6.5: on the road / an outpost (its main base decides)
    if M.settings.directives == false or type(b) ~= "table" or b.status ~= "active" then return end
    if type(b.dir) ~= "table" then M.dirFound(b) end
    local d = b.dir
    d.goals = d.goals or {}
    if d.goals.day == nil or math.floor(d.goals.day.at / 24) ~= math.floor(h / 24) then M.dirPickDay(b, h) end
    if d.goals.week == nil then M.dirPickWeek(b, h, crew) end
    if d.goals.month == nil then M.dirPickMonth(b, h) end
    M.dirWork(b, home or 0, dt or 0)
    M.dirRelations(b, h, far)
    M.dirRaid(b, h, far)
    M.dirCheckGoals(b, h, haven, scan)
    M.dirPolitics(b, h)
end

M.dirCreedStanding = { open = 15, wary = 0, closed = -25, raiders = -35, faithful = 10, traders = 5 }

local function install()
    if M.__dirInstalled or type(M.nbStep) ~= "function" then return false end
    M.__dirInstalled = true
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        pcall(M.dirTick, b, haven, crew, home, dt, h, far, scan)
        return r
    end
    if type(M.nbStanding) == "function" then
        local standing = M.nbStanding
        M.nbStanding = function(b, player, ...)
            local tier, eff = standing(b, player, ...)
            if type(b) == "table" and type(b.dir) == "table" and tonumber(eff) and (tonumber(b.guestUntilH) or -1) <= hours() then
                eff = eff + (M.dirCreedStanding[b.dir.creed] or 0)
                tier = M.territoryTier and M.territoryTier(eff) or (eff >= 35 and "welcome" or (eff >= 15 and "tolerate" or (eff > -15 and "neutral" or "enemy")))
            end
            return tier, eff
        end
    end
    if type(M.nbBrief) == "function" then
        local brief = M.nbBrief
        M.nbBrief = function(b, h, player, ...)
            local nb = brief(b, h, player, ...)
            pcall(function()
                local d = type(b) == "table" and b.dir or nil
                if type(nb) ~= "table" or type(d) ~= "table" then return end
                nb.rule = M.dirRuleWords[d.rule]
                nb.creed = M.dirCreedWords[d.creed]
                local al, en = {}, {}
                for _, o in ipairs(M.dirNeighbours(b)) do
                    local st = M.dirTieState(M.dirTie(b, o))
                    if st == "allied" or st == "friendly" then al[#al + 1] = o.name elseif st == "war" or st == "rivals" then en[#en + 1] = o.name end
                end
                nb.allies = #al > 0 and al or nil
                nb.enemies = #en > 0 and en or nil
                nb.goals = { today = goalText(d.goals.day, b), week = goalText(d.goals.week, b), month = goalText(d.goals.month, b) }
                -- coming back after a while: what changed since the newcomer was last here
                local px, py = nil, nil
                pcall(function() px, py = player:getX(), player:getY() end)
                local here = px ~= nil and b.bounds and px >= b.bounds.x1 - 4 and px <= b.bounds.x2 + 4 and py >= b.bounds.y1 - 4 and py <= b.bounds.y2 + 4
                if here then
                    local last = tonumber(d.lastVisitH)
                    if last and h - last >= 72 then
                        local list = {}
                        for _, e in ipairs(b.events or {}) do if (tonumber(e.h) or 0) > last then list[#list + 1] = e.t end end
                        if #list > 0 then d.changed = { days = math.floor((h - last) / 24), list = list, untilH = h + 6 } end
                    end
                    d.lastVisitH = h
                end
                if type(d.changed) == "table" and h < (tonumber(d.changed.untilH) or 0) then
                    nb.changed = { days = d.changed.days, list = d.changed.list }
                end
            end)
            return nb
        end
    end
    log("ready (rule, creed, daily/weekly/monthly goals, raids, politics)")
    return true
end

if not install() and Events and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(install) end) end
