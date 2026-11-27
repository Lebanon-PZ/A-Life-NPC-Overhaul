-- A-Life NPC Overhaul pre-1.0: BRAIN B6, WAR AS REAL MARCHES (docs/PLAN-BRAIN.md). Scouts, envoys, war parties and
-- help parties are runs on the TradeRuns engine: the people the allocator handed over walk the real road time
-- (Leaving puts them along the road; meet them), carry their own food, and come home with what they took.
--  * scout: a close look (belief 0.8); may be spotted, chased off, or killed by a hostile group.
--  * envoy: tribute demands, peace, alliances, in person (radio when in range for peace / help).
--  * war party: raid (grab goods, leave), assault (break them), siege (camp outside, they can't forage or trade,
--    starve them out; ends at siegeMaxDays or when the party's food runs out). Off screen: the party's real people
--    and strength against the defenders at home, their walls and allies who came. On screen: no made-up fight; if
--    the place or the party is loaded they hold back and leave (real fights are A-Life's, unverified hook).
--  * against you: they camp outside your place and demand tribute (an offer in the Trade tab); word reaches you
--    (setting brainWarn) when they're halfway. Settings brainVsPlayer / brainPlayerGrace.
--  * nothing strands: an aborted plan, a recall (Defense) or a home that's gone turns every member home from where
--    they are, and their job is cleared the moment the run ends (return to pool).
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll
local function T() return ALifeTrade end
local function R() return BR.PA().ActorRegistry end
local function shellOf(uid) local sh = nil; pcall(function() sh = BR.PA().Talk.shellFor(tostring(uid)) end); return sh end
local function memSet(uid, f)
    local reg = R()
    if not (fn(reg, "read") and fn(reg, "update")) then return false end
    local r = reg.read(tostring(uid))
    if r == nil then return false end
    local ok, res = pcall(reg.update, r.uid, r.revision, function(e) e.memory = type(e.memory) == "table" and e.memory or {}; f(e.memory) end)
    return ok and res ~= nil and res ~= false -- A-Life: nil + reason on failure
end
local function alive(run)
    local reg = R()
    local out = {}
    for _, uid in ipairs(run.crew or {}) do
        local r = fn(reg, "read") and reg.read(uid) or nil
        if r and r.lifecycle ~= "dead" then out[#out + 1] = uid end
    end
    return out
end
local function anyLoaded(run) for _, uid in ipairs(run.crew or {}) do if shellOf(uid) then return true end end; return false end
local function placeName(id) if id == "you" then return "your place" end local o = BR.base(id); return o and tostring(o.name) or "another group" end
local FOOD_ITEM = function() return (M.nbCfg and M.nbCfg.foodPerItem) or 0.25 end

----------------------------------------------------------------------------------------------------------------
-- launching (the allocator hands over the people; nobody else)
----------------------------------------------------------------------------------------------------------------
-- food for the road out of their stash (never below what they keep at home)
function BR.packFood(b, personDays)
    local list = fn(M, "nbStashList") and M.nbStashList(M.nbHavenOf(b)) or nil
    if list == nil or personDays <= 0 then return {} end
    local keep = math.floor((tonumber(b.crewN) or 1) * 3 / FOOD_ITEM())
    local have = 0
    for _, it in ipairs(list) do if M.nbKindOf(type(it) == "table" and it.type or it) == "food" then have = have + 1 end end
    local want = math.ceil(personDays / FOOD_ITEM())
    local out = {}
    for i = #list, 1, -1 do
        if #out >= want or have <= keep then break end
        local t = type(list[i]) == "table" and list[i].type or list[i]
        if M.nbKindOf(t) == "food" then table.remove(list, i); out[#out + 1] = t; have = have - 1 end
    end
    if #out > 0 and fn(M, "nbFoodSync") then pcall(M.nbFoodSync, b, M.nbHavenOf(b)) end
    return out
end
function BR.launch(b, kind, to, people, h, opts)
    opts = opts or {}
    local t = T()
    if not (fn(t, "placeXY") and fn(t, "store") and fn(t, "newId") and fn(M, "travelH")) then return nil, "no_engine" end
    local fx, fy = t.placeXY(b.id)
    local tx, ty = t.placeXY(to)
    if fx == nil or tx == nil then return nil, "no_place" end
    local th = M.travelH(fx, fy, tx, ty, b)
    local job = (kind == "scout" or kind == "envoy") and "scout" or "war"
    local run = { id = t.newId(kind), from = b.id, fromName = b.name, kind = kind, brain = true, brainJob = job, goal = opts.goal, target = to,
        legs = { { to = to } }, leg = 1, items = {}, crew = {}, escorts = 0, leave = h, arrive = h + th, x0 = fx, y0 = fy, x1 = tx, y1 = ty,
        state = "out", packs = {}, loaded = {}, orig = {}, withYouMs = 0, planId = opts.planId, tripH = th }
    for _, uid in ipairs(people or {}) do
        if memSet(uid, function(m) m.alcpRun = run.id; m.alcpJob = job end) then run.crew[#run.crew + 1] = tostring(uid) end
    end
    if #run.crew == 0 then return nil, "nobody" end
    run.sent = #run.crew
    -- their food for the road (war parties for the siege too)
    local days = th * 2 / 24 + (kind == "war" and opts.goal == "siege" and BR.num("siegeMaxDays") or 0.5)
    run.items = BR.packFood(b, #run.crew * days)
    run.str0 = BR.str(b) * #run.crew / math.max(1, tonumber(b.crewN) or 1)
    if fn(t, "splitPacks") then t.splitPacks(run) end
    t.store().runs[run.id] = run
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = run.arrive, tag = "brain_" .. kind }) end
    local s = BR.of(b)
    if type(s.plan) == "table" and opts.planId == s.plan.id then s.plan.sent = (tonumber(s.plan.sent) or 0) + #run.crew; s.plan.runId = run.id end
    BR.log(tostring(b.name) .. " " .. kind .. " " .. run.id .. " -> " .. tostring(to) .. ": " .. #run.crew .. " people, " .. math.floor(th * 10 + 0.5) / 10 .. " h")
    return run
end
-- the run is over: people back in the pool at once (job cleared), everyone told
function BR.finishRun(run, why)
    for _, uid in ipairs(run.crew or {}) do memSet(uid, function(m) m.alcpRun = nil; m.alcpJob = nil end) end
    run.state = "done"
    local t = T()
    if fn(t, "store") then t.store().runs[run.id] = nil end
    for _, f in ipairs((t and t.onRunDone) or {}) do pcall(f, run, why) end
end
-- turn home from (x0, y0)
function BR.turnHome(run, h, x0, y0)
    local t = T()
    local tx, ty = t.placeXY(run.from)
    if tx == nil then BR.finishRun(run, "homeless"); return false end
    local b = BR.home(run.from)
    local th = M.travelH(x0, y0, tx, ty, b)
    run.legs = { run.legs[1] or { to = run.target } }
    run.leg = 2
    run.state = "home"
    run.x0, run.y0, run.x1, run.y1, run.leave, run.arrive = x0, y0, tx, ty, h, h + th
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = run.arrive, tag = "brain_home",
        final = { x = tx + (BR.hash(uid) % 3) - 1, y = ty + (BR.hash(uid .. "y") % 3) - 1, z = 0 } }) end
    return true
end
local function whereNow(run, h)
    local f = clamp((h - run.leave) / math.max(0.01, run.arrive - run.leave), 0, 1)
    if run.state == "siege" then f = 1 end
    return run.x0 + (run.x1 - run.x0) * f, run.y0 + (run.y1 - run.y0) * f
end
-- call a run home from wherever it is now (aborted plan, Defense, a siege lifted). Trade runs keep their goods.
function BR.recallRun(run, h, why)
    if type(run) ~= "table" or run.state == "home" or run.state == "done" then return false end
    h = h or hours()
    local x, y = whereNow(run, h)
    if run.state == "siege" then BR.siegeLift(run) end
    if run.brain then
        BR.turnHome(run, h, x, y)
    else
        -- a trade run: same as being turned back on the road (TradeRuns robRoll), goods still in their packs
        local t = T()
        local tx, ty = t.placeXY(run.from)
        if tx == nil then return false end
        run.legs = { run.legs[run.leg] or run.legs[1] }
        run.state = "home"
        run.leg = #run.legs + 1
        local th = M.travelH(x, y, tx, ty, BR.home(run.from))
        run.x0, run.y0, run.x1, run.y1, run.leave, run.arrive = x, y, tx, ty, h, h + th
        for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = run.arrive, tag = "trade_run" }) end
    end
    run.recalled = why or true
    BR.stats.recalls = BR.stats.recalls + 1
    local b = BR.home(run.from)
    if b then BR.event(b, "Called their " .. (run.kind == "war" and "fighters" or (run.kind == "scout" and "scout" or "people")) .. " home" .. (why and (": " .. tostring(why)) or ""), "brain") end
    return true
end
function BR.recallRuns(b, h, why, only)
    local t = T()
    if not fn(t, "runsOf") then return 0 end
    local n = 0
    for _, run in ipairs(t.runsOf(b.id)) do
        if (only == nil or only(run)) and run.state == "out" and BR.recallRun(run, h, why) then n = n + 1 end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- tools
----------------------------------------------------------------------------------------------------------------
local function planIdOf(b) local p = type(b.brain) == "table" and b.brain.plan or nil; return type(p) == "table" and p.id or nil end
BR.tool({ id = "scoutRun", job = "scout", minPeople = 1, maxPeople = 1,
    start = function(b, people, target)
        if type(target) ~= "table" or target.to == nil then return false end
        local run = BR.launch(b, "scout", target.to, people, hours(), { planId = planIdOf(b) })
        if run then BR.stats.scouts = BR.stats.scouts + 1; BR.of(b).scoutH = hours(); BR.event(b, "Sent someone to have a look at " .. placeName(target.to), "brain") end
        return run ~= nil
    end })
BR.tool({ id = "envoy", job = "scout", minPeople = 1, maxPeople = 2,
    start = function(b, people, target)
        if type(target) ~= "table" or target.to == nil then return false end
        local run = BR.launch(b, "envoy", target.to, people, hours(), { goal = target.goal, planId = planIdOf(b) })
        if run then BR.stats.envoys = BR.stats.envoys + 1; BR.event(b, "Sent word to " .. placeName(target.to) .. " in person", "brain") end
        return run ~= nil
    end })
BR.tool({ id = "warParty", job = "war", minPeople = 2, maxPeople = 12,
    owned = function() return BR.flag("warParties") end,
    start = function(b, people, target)
        if type(target) ~= "table" or target.to == nil or not BR.flag("warParties") then return false end
        local run = BR.launch(b, "war", target.to, people, hours(), { goal = target.goal or "raid", planId = planIdOf(b) })
        if run then
            BR.stats.parties = BR.stats.parties + 1
            local words = { raid = "Armed, they set out to raid ", assault = "They set out to break ", siege = "They marched out to lay siege to " }
            BR.event(b, (words[run.goal] or "They set out against ") .. placeName(target.to), "war")
            if fn(M, "dirTieAdd") and BR.base(target.to) then pcall(M.dirTieAdd, b, BR.base(target.to), -10) end
        end
        return run ~= nil
    end })
BR.tool({ id = "help", job = "war", minPeople = 1, maxPeople = 4,
    start = function(b, people, target)
        if type(target) ~= "table" or (BR.base(target.to) == nil and target.to ~= "you") then return false end -- Brain 2 R6: allies help your camp too
        local run = BR.launch(b, "help", target.to, people, hours(), {})
        if run then BR.event(b, "Sent fighters to help " .. placeName(target.to), "war"); BR.of(b).helpAsk = nil end
        return run ~= nil
    end })

-- an envoy bid (or the radio, when they're in range and it isn't a demand)
function BR.envoyBid(b, bids, to, goal, value)
    local o = BR.base(to)
    if goal ~= "tribute" and o and tonumber(o.x) and d2(o.x, o.y, b.x, b.y) <= BR.num("knowRadioTiles") ^ 2 then
        return BR.envoyArrive(b, to, goal, hours(), nil)
    end
    local t = T()
    for _, r in ipairs(fn(t, "runsOf") and t.runsOf(b.id) or {}) do if r.kind == "envoy" then return false end end
    bids[#bids + 1] = { job = "scout", n = 1, value = value or 2, tool = "envoy", target = { to = to, goal = goal }, key = "envoy:" .. tostring(goal) }
    return true
end
-- radio for help (allies in range only: nobody waits days for a messenger in a fight)
function BR.askHelp(b, ally, against, h)
    if type(ally) ~= "table" or not tonumber(ally.x) or d2(ally.x, ally.y, b.x, b.y) > BR.num("knowRadioTiles") ^ 2 then return false end
    local s = BR.of(ally)
    s.helpAsk = { by = b.id, h = h, against = against }
    BR.interrupt(ally, "allyAsks", { a = b.id })
    BR.event(b, "Called " .. tostring(ally.name) .. " for help", "brain")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- arriving
----------------------------------------------------------------------------------------------------------------
local function playersNear(x, y)
    local far = (M.nbCfg and M.nbCfg.farTiles) or 150
    local ok, res = pcall(function()
        local list = {}
        if ALifeSide.mpServer() then list = ALifeSide.online() else local p = ALifeSide.you(); if p then list = { p } end end
        for _, p in ipairs(list) do if p and (p:getX() - x) ^ 2 + (p:getY() - y) ^ 2 < far * far then return true end end
        return false
    end)
    return ok and res == true
end
-- kill n of the given uids (off screen only: nbKill refuses anyone loaded or awake)
local function casualties(uids, n, why, h)
    local dead = {}
    if n <= 0 or not fn(M, "nbKill") then return dead end
    local list = {}
    for _, u in ipairs(uids) do list[#list + 1] = u end
    table.sort(list, function(a, c) return BR.hash(a .. why .. math.floor(h)) < BR.hash(c .. why .. math.floor(h)) end)
    local reg = R()
    for _, u in ipairs(list) do
        if #dead >= n then break end
        local r = fn(reg, "read") and reg.read(u) or nil
        if r and M.nbKill(r, why) then dead[#dead + 1] = u end
    end
    return dead
end
local function dropCrew(run, dead)
    if #dead == 0 then return end
    local gone = {}
    for _, u in ipairs(dead) do gone[u] = true end
    local keep = {}
    for _, u in ipairs(run.crew) do if not gone[u] then keep[#keep + 1] = u end end
    run.crew = keep
    run.lost = (tonumber(run.lost) or 0) + #dead
    local b = BR.home(run.from)
    local s = b and BR.of(b) or nil
    if s and type(s.plan) == "table" and run.planId == s.plan.id then s.plan.lost = (tonumber(s.plan.lost) or 0) + #dead end
    if fn(T(), "splitPacks") then T().splitPacks(run) end
end
local function homeCrew(o)
    local out = {}
    for _, r in ipairs(((fn(M, "nbScan") and M.nbScan() or {}).crews or {})[o.id] or {}) do
        local m = type(r.memory) == "table" and r.memory or {}
        if r.lifecycle ~= "dead" and m.alcpRun == nil and not r.virtual then out[#out + 1] = tostring(r.uid) end
    end
    table.sort(out)
    return out
end
-- the defenders' real strength at home: guards and whoever's around, walls, allies who came
function BR.defStr(o, h)
    local n = math.max(1, tonumber(o.crewN) or 1)
    local def = math.min(n, BR.defenders(o))
    local str = BR.str(o) * def / n
    local s = type(o.brain) == "table" and o.brain or nil
    if s and type(s.helpers) == "table" then
        for k, x in pairs(s.helpers) do
            if type(x) == "table" and h < (tonumber(x.untilH) or 0) then str = str + (tonumber(x.str) or 0) else s.helpers[k] = nil end
        end
    end
    return str
end
local function partyStr(run) return (tonumber(run.str0) or 1) * #run.crew / math.max(1, tonumber(run.sent) or 1) end
local function loot(run, o, n, skipFood)
    local tl = fn(M, "nbStashList") and M.nbStashList(M.nbHavenOf(o)) or nil
    if tl == nil or n <= 0 then return 0 end
    local idx = {}
    if type(ALifeWorth) == "table" and fn(ALifeWorth, "best") then idx = ALifeWorth.best(tl, n, skipFood and { water = true } or nil)
    else for i = #tl, math.max(1, #tl - n + 1), -1 do idx[#idx + 1] = i end end
    table.sort(idx, function(x, y) return x > y end)
    local got = 0
    for _, i in ipairs(idx) do
        local it = table.remove(tl, i)
        if it then run.items[#run.items + 1] = type(it) == "table" and it.type or it; got = got + 1; run.lootN = (tonumber(run.lootN) or 0) + 1 end
    end
    if fn(M, "nbFoodSync") then pcall(M.nbFoodSync, o, M.nbHavenOf(o)) end
    if fn(T(), "splitPacks") then T().splitPacks(run) end
    return got
end
local function win(b, o, run, h, ok)
    if fn(M, "wmRecord") then pcall(M.wmRecord, b, o, h, ok) end
    run.won = ok
    if ok and type(b.dir) == "table" then
        b.dir.raids = (tonumber(b.dir.raids) or 0) + 1
        if type(b.dir.goals) == "table" and type(b.dir.goals.week) == "table" then b.dir.goals.week.hit = true end
    end
    if type(o.dir) == "table" then
        o.dir.enemies = type(o.dir.enemies) == "table" and o.dir.enemies or {}
        o.dir.enemies[b.id] = h
        o.dir.hits = (tonumber(o.dir.hits) or 0) + 1
    end
    if fn(M, "dirBumpTie") and type(o.dir) == "table" and type(b.dir) == "table" then pcall(M.dirBumpTie, b, o, -35) end
end

-- the scout's look
function BR.scoutArrive(run, b, h)
    local to = run.target
    local o = BR.base(to)
    local t = BR.truth(to)
    if t == nil then return end
    local hostile = o and (BR.tie(o, b) <= -20 or BR.grudgeV(o, b.id, h) >= 20 or (o.dir and o.dir.creed == "raiders")) or false
    local guards = o and (type(o.brain) == "table" and type(o.brain.alloc) == "table" and (o.brain.alloc.guard or 0) or 1) or 0
    if o and roll(run.id .. "seen") < 0.15 + 0.1 * guards then
        BR.learn(o, b.id, { x = b.x, y = b.y, hostile = true, name = b.name }, 0.6, "caught_scout", h)
        BR.interrupt(o, "scouted", { a = b.id })
        if hostile and roll(run.id .. "kill") < 0.4 then
            local dead = casualties(run.crew, 1, "caught scouting " .. tostring(o.name), h)
            dropCrew(run, dead)
            if #dead > 0 then
                BR.event(b, "Their scout never came back from " .. tostring(o.name), "brain")
                BR.event(o, "Caught a scout from " .. tostring(b.name) .. " and dealt with them", "brain")
                BR.grudge(b, o.id, 20, "killed their scout")
                return
            end
        end
        BR.learn(b, to, { x = t.x, y = t.y, crew = t.crew, stage = t.stage, hostile = hostile or t.hostile, name = t.name }, 0.5, "scout", h)
        BR.event(b, "Their scout was spotted at " .. placeName(to) .. " and had to run", "brain")
        return
    end
    t.hostile = hostile or t.hostile
    BR.learn(b, to, t, 0.8, "scout", h)
end

-- an envoy (or a radio call) arrives: tribute, peace, alliance
function BR.envoyArrive(b, to, goal, h, run)
    local s = BR.of(b)
    s.answers = type(s.answers) == "table" and s.answers or {}
    if to == "you" then
        if goal == "tribute" then BR.tributeToYou(b, h) end
        return true
    end
    local o = BR.base(to)
    if o == nil then return false end
    local so = BR.of(o)
    local wo = BR.w(o, h)
    if goal == "tribute" then
        local mine, theirs = BR.str(o), BR.str(b)
        local scared = theirs >= mine * 2 and (wo.pride or 1) < 1.4 or (so.pressure or 0) >= 60
        if scared then
            local kind = (type(s.want) == "table" and s.want[1]) or "food"
            local got = {}
            if fn(T(), "takeKind") then got = T().takeKind(o, kind, 20) end
            if #got == 0 and fn(T(), "takeKind") then got = T().takeKind(o, "food", 20) end
            if run then for _, x in ipairs(got) do run.items[#run.items + 1] = x end; run.lootN = (tonumber(run.lootN) or 0) + #got; if fn(T(), "splitPacks") then T().splitPacks(run) end
            elseif #got > 0 and fn(T(), "putIn") then T().putIn(b, got) end
            s.tribute = type(s.tribute) == "table" and s.tribute or {}
            s.tribute[o.id] = { h = h, kind = kind }
            BR.stats.tribute = BR.stats.tribute + 1
            BR.grudge(o, b.id, 15, "made them pay")
            BR.event(o, "Paid " .. tostring(b.name) .. " to be left alone", "brain")
            BR.event(b, tostring(o.name) .. " paid them to be left alone", "brain")
            s.answers[o.id] = "paid"
        else
            BR.grudge(b, o.id, 20, "refused to pay")
            if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, o, -15) end
            BR.event(o, "Sent " .. tostring(b.name) .. "'s people away when they demanded payment", "brain")
            BR.event(b, tostring(o.name) .. " refused to pay them", "brain")
            s.answers[o.id] = "refused"
        end
        BR.learn(o, b.id, { x = b.x, y = b.y, hostile = true, name = b.name }, 0.6, "envoy", h)
        BR.interrupt(o, "demand", { a = b.id })
    elseif goal == "peace" then
        local yes = (so.pressure or 0) >= 40 or (wo.kindness or 1) >= 1.2 or BR.grudgeV(o, b.id, h) < 30
        if yes and fn(M, "dirTieAdd") then
            local tie = BR.tie(b, o)
            pcall(M.dirTieAdd, b, o, -10 - tie)
            so.grudges[b.id] = nil
            BR.of(b).grudges[o.id] = nil
            BR.event(b, "Made peace with " .. tostring(o.name), "brain")
            BR.event(o, "Made peace with " .. tostring(b.name), "brain")
        else
            BR.event(b, tostring(o.name) .. " wouldn't hear of peace", "brain")
        end
        s.answers[o.id] = yes and "peace" or "refused"
    elseif goal == "ally" then
        local yes = BR.tie(o, b) >= 0 and (so.threatBy ~= nil or (wo.kindness or 1) >= 1.1)
        if yes and fn(M, "dirBumpTie") then pcall(M.dirBumpTie, b, o, 25) end
        s.answers[o.id] = yes and "allied" or "refused"
        BR.event(b, yes and ("Agreed with " .. tostring(o.name) .. " to stand together") or (tostring(o.name) .. " wouldn't stand with them"), "brain")
    end
    return true
end
-- a demand on you: an offer in the Trade tab ("their leaving you alone for your food, every week")
function BR.tributeToYou(b, h)
    local t = T()
    if not (fn(t, "store") and fn(t, "newId")) or not BR.flag("brainTribute") then return false end
    local st = t.store()
    for _, off in pairs(st.offers) do if off.from == b.id then return false end end
    local kind = (type(BR.of(b).want) == "table" and BR.of(b).want[1]) or "food"
    local off = { id = t.newId("offer"), from = b.id, name = tostring(b.name), give = "safety", want = kind, every = 7, h = h, tribute = true }
    st.offers[off.id] = off
    BR.stats.tribute = BR.stats.tribute + 1
    if fn(BR, "campLetter") then BR.campLetter(tostring(b.name) .. "'s people came to your place: they want " .. (t.KIND_WORDS[kind] or kind) .. " every week, or else. Answer in the Trade tab.", true) end
    BR.event(b, "Told the newcomer to pay up", "brain")
    return true
end

-- the fight, off screen, with the real people on both sides
function BR.warArrive(run, b, h)
    local to = run.target
    if to == "you" then
        local x, y = run.x1, run.y1
        if playersNear(x, y) or anyLoaded(run) then
            -- you're there: whatever happens now is real (A-Life's hostility follows how they feel about you)
            if fn(M, "nbRep") then pcall(M.nbRep, b, -10, nil) end
            run.stay = run.stayed and nil or 6
            run.stayed = true
            return
        end
        -- they camp outside your place for a while and make their demand
        run.siegeDays = (tonumber(run.siegeDays) or 0) + 1
        if run.siegeDays == 1 then
            BR.tributeToYou(b, h)
            if BR.flag("brainWarn") then BR.campLetter("Armed people from " .. tostring(b.name) .. " are camped outside your place.", true) end
        end
        if run.siegeDays <= BR.num("siegeMaxDays") and BR.eatOnSiege(run) then run.state = "siege"; run.stay = 24 end
        return
    end
    local o = BR.base(to)
    if o == nil then BR.event(b, "Got to " .. tostring(run.targetName or "the place") .. " and found it empty", "war"); return end
    if run.state ~= "siege" and (playersNear(o.x, o.y) or anyLoaded(run)) then
        -- people around who'd see it: they hold back (no made-up fight on screen)
        if not run.waited then run.waited = true; run.stay = 3; return end
        BR.event(b, "Their fighters turned back from " .. tostring(o.name) .. " - too many eyes around", "war")
        return
    end
    local goal = run.goal or "raid"
    if goal == "siege" then return BR.siegeDay(run, b, o, h) end
    local ps, ds = partyStr(run), BR.defStr(o, h)
    local odds = ps / math.max(0.1, ps + ds * 1.2)
    local ok = roll(run.id .. "win") < odds
    if ok then
        if goal == "assault" then
            local home = homeCrew(o)
            local dead = casualties(home, 1 + math.floor(#home / 3), "killed when " .. tostring(b.name) .. " stormed " .. tostring(o.name), h)
            local got = loot(run, o, #run.crew * 4, false)
            o.morale = clamp((tonumber(o.morale) or 50) - 25, 0, 100)
            BR.event(b, "They stormed " .. tostring(o.name) .. (got > 0 and (" and carried off " .. got .. " things") or ""), "war")
            BR.event(o, tostring(b.name) .. " stormed them" .. (#dead > 0 and (" - " .. #dead .. " dead") or ""), "war")
            win(b, o, run, h, true)
            BR.surrender(b, o, h, run)
        else
            local got = loot(run, o, #run.crew * 4, false)
            o.morale = clamp((tonumber(o.morale) or 50) - 12, 0, 100)
            b.morale = clamp((tonumber(b.morale) or 50) + 6, 0, 100)
            BR.event(b, "Raided " .. tostring(o.name) .. (got > 0 and (" and came away with " .. got .. " things") or " but found little worth taking"), "war")
            BR.event(o, tostring(b.name) .. " raided them", "raided")
            win(b, o, run, h, true)
        end
    else
        local n = goal == "assault" and (1 + math.floor(#run.crew / 3)) or (odds < 0.35 and 1 or 0)
        local dead = casualties(run.crew, n, "killed attacking " .. tostring(o.name), h)
        dropCrew(run, dead)
        b.morale = clamp((tonumber(b.morale) or 50) - 8, 0, 100)
        BR.event(b, "Their attack on " .. tostring(o.name) .. " went bad" .. (#dead > 0 and (" - " .. #dead .. " didn't come back") or ""), "war")
        BR.event(o, "Drove off " .. tostring(b.name) .. "'s fighters", "defended")
        win(b, o, run, h, false)
    end
end
-- beaten badly: they give in (absorbed if the winners take people in, else they pay)
function BR.surrender(b, o, h, run)
    if o.status ~= "active" then return end
    local left = tonumber(o.crewN) or 0
    if left >= 3 and (tonumber(o.morale) or 50) >= 30 then return end
    if type(b.dir) == "table" and b.dir.creed ~= "closed" and fn(M, "nbAbsorb") then
        local ok = pcall(M.nbAbsorb, b, o, h)
        if ok and o.status ~= "active" then BR.event(b, "What was left of " .. tostring(o.name) .. " gave in and came over", "war"); return end
    end
    local s = BR.of(b)
    s.tribute = type(s.tribute) == "table" and s.tribute or {}
    s.tribute[o.id] = { h = h, kind = "food" }
    BR.event(o, "Gave in to " .. tostring(b.name) .. " - they pay them now", "war")
end
-- a siege party eats its own food; none left = they go home
function BR.eatOnSiege(run)
    local need = math.ceil(#run.crew / FOOD_ITEM())
    local eaten = 0
    for i = #run.items, 1, -1 do
        if eaten >= need then break end
        if M.nbKindOf(run.items[i]) == "food" then table.remove(run.items, i); eaten = eaten + 1 end
    end
    if fn(T(), "splitPacks") then T().splitPacks(run) end
    return eaten >= need
end
function BR.siegeLift(run)
    local o = BR.base(run.target)
    if o and type(o.brain) == "table" and type(o.brain.sieged) == "table" and o.brain.sieged.by == run.from then o.brain.sieged = nil end
end
function BR.siegeDay(run, b, o, h)
    local so = BR.of(o)
    run.siegeDays = (tonumber(run.siegeDays) or 0) + 1
    if run.siegeDays == 1 then
        BR.stats.sieges = BR.stats.sieges + 1
        BR.event(b, "They're camped outside " .. tostring(o.name) .. ", nobody gets in or out", "war")
        BR.event(o, tostring(b.name) .. " have them under siege", "war")
        BR.interrupt(o, "sieged", { a = b.id })
    end
    -- the defenders come out if they're stronger
    local ps, ds = partyStr(run), BR.defStr(o, h)
    if ds > ps * 1.3 then
        local dead = casualties(run.crew, 1 + math.floor(#run.crew / 3), "killed when " .. tostring(o.name) .. " broke the siege", h)
        dropCrew(run, dead)
        BR.event(o, "Came out and broke " .. tostring(b.name) .. "'s siege", "defended")
        BR.event(b, tostring(o.name) .. " broke their siege" .. (#dead > 0 and (" - " .. #dead .. " dead") or ""), "war")
        win(b, o, run, h, false)
        BR.siegeLift(run)
        return
    end
    -- starved out: they give in
    if BR.foodDays(o) < 1 then
        local got = loot(run, o, #run.crew * 4, false)
        BR.event(b, tostring(o.name) .. " gave in to the siege" .. (got > 0 and (" and handed over " .. got .. " things") or ""), "war")
        BR.event(o, "Starved out, they gave in to " .. tostring(b.name), "war")
        win(b, o, run, h, true)
        BR.siegeLift(run)
        BR.surrender(b, o, h, run)
        return
    end
    if run.siegeDays > BR.num("siegeMaxDays") or not BR.eatOnSiege(run) then
        BR.event(b, "Gave up the siege of " .. tostring(o.name) .. " and went home", "war")
        BR.event(o, tostring(b.name) .. " gave up their siege", "defended")
        BR.siegeLift(run)
        return
    end
    so.sieged = { by = b.id, untilH = h + 26 }
    run.state = "siege"
    run.stay = 24
end
function BR.helpArrive(run, b, h)
    local o = BR.home(run.target) -- your camp's record for "you" (One Brain), else the base
    if o == nil then return end
    local so = BR.of(o)
    so.helpers = type(so.helpers) == "table" and so.helpers or {}
    if run.helping then so.helpers[b.id] = nil; return end
    run.helping = true
    so.helpers[b.id] = { n = #run.crew, str = partyStr(run), untilH = h + 48 }
    BR.debt(o, b.id, 20, "came when they called")
    if fn(M, "dirBumpTie") then pcall(M.dirBumpTie, b, o, 6) end
    BR.event(o, tostring(b.name) .. " sent fighters to stand with them", "brain")
    run.state = "siege" -- staying put
    run.stay = 48
end

-- a brain run reached the end of a leg
function BR.runArrive(run, h)
    local b = BR.home(run.from)
    if b == nil then BR.siegeLift(run); BR.finishRun(run, "homeless"); return end
    local stay = nil
    if run.state ~= "home" then
        if run.kind == "scout" then BR.scoutArrive(run, b, h)
        elseif run.kind == "envoy" then BR.envoyArrive(b, run.target, run.goal, h, run)
        elseif run.kind == "war" then BR.warArrive(run, b, h)
        elseif run.kind == "help" then BR.helpArrive(run, b, h) end
        stay = run.stay
        run.stay = nil
        if #alive(run) == 0 then return BR.partyLost(run, h) end
        if stay then run.leave, run.arrive = h, h + stay; return end
        if run.state == "siege" then BR.siegeLift(run) end
        return BR.turnHome(run, h, run.x1, run.y1)
    end
    -- home: what they carry goes into the stash
    local items = {}
    for _, uid in ipairs(run.crew) do for _, x in ipairs((run.packs or {})[uid] or {}) do items[#items + 1] = x end end
    if #items > 0 and fn(T(), "putIn") then T().putIn(b, items) end
    if run.kind == "war" then
        local lootN = math.min(#items, tonumber(run.lootN) or 0)
        BR.event(b, "Their fighters came home" .. (lootN > 0 and (" with " .. lootN .. " things they took") or "") .. ((tonumber(run.lost) or 0) > 0 and (", " .. run.lost .. " fewer than left") or ""), "war")
    elseif run.kind == "scout" and run.target then
        BR.event(b, "Their scout came back from " .. placeName(run.target), "brain")
    end
    BR.finishRun(run, "home")
end
function BR.partyLost(run, h)
    local b = BR.home(run.from)
    BR.siegeLift(run)
    if b then
        local words = { war = "Their war party never came back", scout = "Their scout never came back", envoy = "Their messenger never came back", help = "The fighters they sent never came back" }
        BR.event(b, words[run.kind] or "Their people never came back", "war")
        BR.interrupt(b, "partyLost")
    end
    BR.finishRun(run, "lost")
end

-- halfway: does the target see them coming? (lookouts, the road)
function BR.runHalfway(run, h)
    if run.kind ~= "war" or run.seenHalf or run.state ~= "out" then return end
    if h < run.leave + (run.arrive - run.leave) * 0.5 then return end
    run.seenHalf = true
    local b = BR.home(run.from)
    if run.target == "you" then
        if BR.flag("brainWarn") and b then BR.campLetter("Word on the radio: armed people from " .. tostring(b.name) .. " are heading your way.", true) end
        return
    end
    local o = BR.base(run.target)
    if o == nil or b == nil then return end
    local guards = type(o.brain) == "table" and type(o.brain.alloc) == "table" and (o.brain.alloc.guard or 0) or 1
    if roll(run.id .. "spot") < 0.4 + 0.15 * guards then
        local so = BR.of(o)
        so.incoming = { by = b.id, untilH = run.arrive + 24 }
        BR.learn(o, b.id, { x = b.x, y = b.y, hostile = true, name = b.name, str = run.str0 }, 0.7, "lookout", h)
        BR.event(o, "Their lookouts saw " .. tostring(b.name) .. "'s fighters coming", "brain")
        BR.interrupt(o, "warparty", { a = b.id })
    end
end

----------------------------------------------------------------------------------------------------------------
-- hooks into the run engine (one each, marked)
----------------------------------------------------------------------------------------------------------------
local function install()
    local t = T()
    if type(t) ~= "table" or not (fn(t, "legDone") and fn(t, "runStep") and fn(t, "robRoll")) then return false end
    if t._brainRuns then return true end
    t._brainRuns = true
    local legDone, runStep, robRoll = t.legDone, t.runStep, t.robRoll
    t.legDone = function(run, h, ...)
        if type(run) ~= "table" or not run.brain then return legDone(run, h, ...) end
        local live = alive(run)
        if #live == 0 then return BR.partyLost(run, h) end
        for _, uid in ipairs(live) do
            local sh = shellOf(uid)
            if sh and run.loaded[uid] and fn(t, "packRead") then run.packs[uid] = t.packRead(run, uid, sh, true); run.loaded[uid] = false end
        end
        run.crew = live
        return BR.runArrive(run, h)
    end
    t.runStep = function(run, h, ...)
        if type(run) == "table" and run.brain then
            if #alive(run) == 0 then return BR.partyLost(run, h) end
            pcall(BR.runHalfway, run, h)
        end
        return runStep(run, h, ...)
    end
    -- armed parties and scouts aren't robbed like traders (scouts have their own risk at the other end)
    t.robRoll = function(run, h, ...)
        if type(run) == "table" and run.brain then return false end
        return robRoll(run, h, ...)
    end
    -- tribute deals: nothing comes with their people; they take what was agreed
    if fn(t, "startRun") then
        local sr = t.startRun
        t.startRun = function(b, legs, h, opts, ...)
            if type(legs) == "table" and type(legs[1]) == "table" and legs[1].give == "safety" then
                opts = opts or {}; opts.empty = true; opts.items = {}
                local was = t.KIND_WORDS.safety
                t.KIND_WORDS.safety = "nothing but their demand"
                local ok, a, c = pcall(sr, b, legs, h, opts, ...)
                t.KIND_WORDS.safety = was
                if ok then return a, c end
                return nil, "error"
            end
            return sr(b, legs, h, opts, ...)
        end
    end
    if fn(t, "tradeWithYou") then
        local tw = t.tradeWithYou
        t.tradeWithYou = function(run, leg, h, ...)
            if type(leg) == "table" and leg.give == "safety" and fn(t, "postBox") and t.postBox() ~= nil then
                local got = t.postTake(leg.want, 20)
                local a = BR.home(run.from)
                BR.campLetter(tostring(a and a.name or "Their people") .. " took " .. #got .. " " .. (t.KIND_WORDS[leg.want] or "things") .. " from your trading post, as agreed.", false)
                if #got == 0 then return {}, got, "short" end
                return {}, got, nil
            end
            return tw(run, leg, h, ...)
        end
    end
    t.KIND_WORDS = t.KIND_WORDS or {}
    t.KIND_WORDS.safety = "being left alone"
    -- a refused demand: they remember (and may come)
    if fn(M, "trDealAnswer") and not M._alcpHooks.brainTribute then
        M._alcpHooks.brainTribute = true
        local da = M.trDealAnswer
        M.trDealAnswer = function(offerId, yes, player, ...)
            local off = t.store().offers[tostring(offerId or "")]
            local res = da(offerId, yes, player, ...)
            if type(off) == "table" and off.tribute and BR.on() then
                local b = BR.base(off.from)
                local ok = yes == true or yes == "true" or yes == 1
                if b then
                    local s = BR.of(b)
                    s.answers = type(s.answers) == "table" and s.answers or {}
                    s.answers.you = ok and "paid" or "refused"
                    if not ok then BR.grudge(b, "you", 25, "refused to pay"); s.provoked = hours(); BR.interrupt(b, "you") end
                end
            end
            return res
        end
    end
    -- the end of any run: people back in the pool now; plans count what came home
    t.onRunDone = t.onRunDone or {}
    t.onRunDone[#t.onRunDone + 1] = function(run, why)
        local b = BR.home(run.from)
        if b == nil or not BR.on() then return end
        local s = BR.of(b)
        s.dirty = true
        if run.brain then for _, uid in ipairs(run.crew or {}) do s.jobs[uid] = nil end end
        if type(s.plan) == "table" and run.planId == s.plan.id then
            s.plan.runDone = { why = why, won = run.won, kind = run.kind, h = hours() }
        end
    end
    return true
end
-- unanswered demands on you expire (silence = no)
function BR.tributeExpire(h)
    local t = T()
    if not fn(t, "store") then return end
    for id, off in pairs(t.store().offers) do
        if type(off) == "table" and off.tribute and h - (tonumber(off.h) or h) >= 72 then
            t.store().offers[id] = nil
            local b = BR.base(off.from)
            if b then BR.grudge(b, "you", 20, "ignored their demand"); BR.of(b).provoked = h; BR.of(b).answers = BR.of(b).answers or {}; BR.of(b).answers.you = "refused"; BR.interrupt(b, "you") end
        end
    end
end
-- Brain 2 (ALifeBrainFight, ALifeBrainRoads) reuse these
BR.warWin, BR.warLoot, BR.homeCrew, BR.playersNear, BR.runAlive, BR.dropCrew, BR.memSet, BR.casualties, BR.whereNow, BR.partyStr = win, loot, homeCrew, playersNear, alive, dropCrew, memSet, casualties, whereNow, partyStr
BR.installers[#BR.installers + 1] = install
pcall(install)
local function tenMin() if BR.on() then pcall(BR.tributeExpire, hours()) end end
do
    local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrainWar")
    if type(Events) == "table" and Events.EveryTenMinutes and type(ALifeHealth) == "table" then ALifeHealth.add(Events.EveryTenMinutes, "ALifeBrainWar", tenMin) end
end
