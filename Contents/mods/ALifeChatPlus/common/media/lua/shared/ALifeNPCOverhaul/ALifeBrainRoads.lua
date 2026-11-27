-- A-Life NPC Overhaul pre-1.0: BRAIN 2, R2 THE ROADS ARE THE BATTLEFIELD (docs/PLAN-BRAIN-2.md). Runs already walk real
-- roads, so the map already has supply lines. Now groups fight over them:
--   * traffic is intel: a run seen passing near a group (or a point it holds) teaches it who goes where, how many,
--     armed or not (beliefs + a remembered spot on that group's road).
--   * ambush (tool "ambush", job war): a few fighters wait by a road the group BELIEVES its enemy uses (a spot where
--     their people were seen), for up to ambushHours. An enemy run passing within ambushReach tiles is hit: off screen
--     the real crews' odds (escorts count); on screen a real fight (ALifeBrainFight, at the roadside). A win takes
--     the run's real packs; the run limps home.
--   * escorts: a group sends an armed escort (TradeRuns' own escort rule) when the road is bad, and now also when it
--     believes hostile people sit near the road (beliefs lower the road's safety for that group).
--   * held points: crossroads and chokepoints (ALifeTalk_Chokepoints finds them) held by a few real people for
--     holdDays (tool "hold"). Friendly runs pass; neutral ones pay a toll (holdTax); enemy runs are turned back, or
--     robbed by a group out to dominate. Everyone near knows who holds it. Breaking a hold is a fight there.
--   * blockade: a siege holds the roads too: the besieged can't send runs, outside traders turn away, and their food
--     goes faster (blockadeDrain).
-- World side (server in MP). Bounded lists: seen spots per group (knowMax), held points (one per group).
require "ALifeNPCOverhaul/ALifeBrainFight"
pcall(require, "ALifeNPCOverhaul/ALifeBrainManagers")
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll
local TAG = "[ALifeBrainRoads]"
local function T() return ALifeTrade end

BR.defaults({
    ambushes = true,      -- groups lie in wait on the roads their enemies use
    ambushHours = 24,     -- longest an ambush waits (game hours)
    ambushReach = 40,     -- a run this close to the ambush spot is hit (tiles)
    escorts = true,       -- what a group believes about the road (hostile people near it) makes it send escorts
    holdPoints = true,    -- groups hold crossroads and chokepoints with a few real people
    holdDays = 5,         -- days a hold lasts before the people come home
    holdTax = true,       -- a held point takes a toll from passers-by who aren't friends
    blockades = true,     -- a siege holds the roads: nobody in or out, food runs short faster
    blockadeDrain = 50,   -- extra food the besieged lose each day (percent of a day's food)
})
BR.addRows({
    { "ambushes", "Brain roads: groups lie in wait on the roads their enemies use" },
    { "ambushHours", "Brain roads: longest an ambush waits (hours)", { 12, 24, 48 } },
    { "ambushReach", "Brain roads: how close a passing run must come to be hit (tiles)", { 25, 40, 60 } },
    { "escorts", "Brain roads: groups send escorts when they believe the road is watched" },
    { "holdPoints", "Brain roads: groups hold crossroads and chokepoints with real people" },
    { "holdDays", "Brain roads: days a group holds a point before coming home", { 2, 5, 10 } },
    { "holdTax", "Brain roads: held points take a toll from passers-by who aren't friends" },
    { "blockades", "Brain roads: a siege also holds the roads (nobody in or out)" },
    { "blockadeDrain", "Brain roads: extra food the besieged lose each day (percent of a day)", { 0, 50, 100 } },
})
BR.roadStats = BR.roadStats or { ambushes = 0, sprung = 0, ambushWon = 0, ambushLost = 0, holds = 0, tolls = 0, turned = 0, robbed = 0, seen = 0, blocked = 0 }
local RS = BR.roadStats
local function log(m) BR.log("roads: " .. tostring(m)) end
local function placeName(id) if id == "you" then return "your place" end local o = BR.base(id); return o and tostring(o.name) or "another group" end
local function runs() local t = T(); return fn(t, "store") and t.store().runs or {} end
local function hostileTo(b, otherId, h)
    if type(b) ~= "table" or otherId == nil or otherId == b.id then return false end
    local o = BR.base(otherId)
    local tie = o and BR.tie(b, o) or (otherId == "you" and (((tonumber(b.rep) or 50) - 50) * 2) or 0)
    return tie <= -20 or BR.grudgeV(b, otherId, h) >= 20 or BR.tieState(tie) == "war"
end
BR.roadHostile = hostileTo

----------------------------------------------------------------------------------------------------------------
-- traffic is intel: who saw which run go by (once a game hour per run)
----------------------------------------------------------------------------------------------------------------
function BR.seenSpot(b, otherId, h)
    local s = BR.of(b)
    local r = type(s.seen) == "table" and s.seen[otherId] or nil
    if type(r) ~= "table" or h - (tonumber(r.h) or -1e9) > 24 * 7 then return nil end
    return r
end
function BR.roadSeen(run, h)
    if type(run) ~= "table" or run.state == "done" or run.state == "siege" or run.state == "ambush" or run.state == "hold" then return end
    if math.floor(h) == run.seenHour then return end
    run.seenHour = math.floor(h)
    local x, y = BR.whereNow(run, h)
    local tiles = BR.num("knowSeeTiles")
    local function note(b, conf, src)
        if b.id == run.from or b.isCamp then return end
        local s = BR.of(b)
        s.seen = type(s.seen) == "table" and s.seen or {}
        s.seen[run.from] = { x = math.floor(x), y = math.floor(y), h = h, to = run.target or (run.legs and run.legs[run.leg or 1] and run.legs[run.leg or 1].to), kind = run.kind, n = #(run.crew or {}) }
        -- bounded: forget the oldest
        local keys = BR.sortedKeys(s.seen)
        if #keys > BR.num("knowMax") then
            table.sort(keys, function(a, c) return (tonumber(s.seen[a].h) or 0) < (tonumber(s.seen[c].h) or 0) end)
            s.seen[keys[1]] = nil
        end
        local home = BR.home(run.from)
        if home and not home.isCamp then
            BR.learn(b, run.from, { x = home.x, y = home.y, name = home.name, hostile = (run.kind == "war" and run.target == b.id) or nil }, conf, src, h)
        end
        RS.seen = RS.seen + 1
    end
    for _, b in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if BR.runs(b) and tonumber(b.x) and d2(b.x, b.y, x, y) <= tiles * tiles then note(b, 0.5, "sight") end
    end
    for _, hp in pairs(BR.heldPoints()) do
        local hb = BR.base(hp.by)
        if hb and d2(hp.x, hp.y, x, y) <= (BR.num("ambushReach") * 2) ^ 2 then note(hb, 0.7, "lookout") end
    end
end

----------------------------------------------------------------------------------------------------------------
-- held points (one per group): BR store in the trade store (saved with the runs)
----------------------------------------------------------------------------------------------------------------
function BR.heldPoints()
    local t = T()
    if not fn(t, "store") then return {} end
    local st = t.store()
    st.held = type(st.held) == "table" and st.held or {}
    -- a hold whose people are gone is over
    for k, hp in pairs(st.held) do
        local run = runs()[hp.runId or ""]
        if type(run) ~= "table" or run.state ~= "hold" then st.held[k] = nil end
    end
    return st.held
end
local function chokepoints()
    local out = {}
    if fn(M, "chkPoints") then local ok, list = pcall(M.chkPoints); if ok and type(list) == "table" then out = list end end
    if type(ALifeChokepoints) == "table" then for _, p in ipairs(ALifeChokepoints) do out[#out + 1] = p end end
    return out
end
-- is (x, y) on the straight road a -> b (within tiles)?
local function onLine(px, py, ax, ay, bx, by, tiles)
    local vx, vy = bx - ax, by - ay
    local L2 = vx * vx + vy * vy
    local t = L2 > 0 and math.max(0, math.min(1, ((px - ax) * vx + (py - ay) * vy) / L2)) or 0
    local qx, qy = ax + vx * t, ay + vy * t
    return t > 0.02 and t < 0.98 and d2(px, py, qx, qy) <= tiles * tiles
end
BR.roadOnLine = onLine

-- a run passes a held point: friends pass, others pay or are turned back / robbed
function BR.heldPass(run, h)
    if not BR.flag("holdPoints") or type(run) ~= "table" or run.state ~= "out" or run.kind == "hold" or run.kind == "ambush" then return end
    run.heldDone = type(run.heldDone) == "table" and run.heldDone or {}
    for key, hp in pairs(BR.heldPoints()) do
        if hp.by ~= run.from and not run.heldDone[key] and onLine(hp.x, hp.y, run.x0, run.y0, run.x1, run.y1, BR.num("ambushReach") * 1.5) then
            local x, y = BR.whereNow(run, h)
            if d2(x, y, hp.x, hp.y) <= (BR.num("ambushReach") * 1.5) ^ 2 then
                run.heldDone[key] = true
                local holder = BR.base(hp.by)
                local hrun = runs()[hp.runId or ""]
                if holder and type(hrun) == "table" then BR.heldMeet(run, holder, hrun, hp, h) end
            end
        end
    end
end
function BR.heldMeet(run, holder, hrun, hp, h)
    local from = BR.home(run.from)
    local name = from and tostring(from.name) or "travellers"
    local tie = from and (from.isCamp and (((tonumber(holder.rep) or 50) - 50) * 2) or BR.tie(holder, from)) or 0
    local st = BR.tieState(tie)
    if st == "allied" or st == "friendly" then return "pass" end
    local s = BR.of(holder)
    local enemy = hostileTo(holder, run.from, h)
    if enemy and run.kind == "war" then
        -- a war party at a held point: that's a fight to get past (off screen: the odds)
        local ps, hs = BR.partyStr(run), BR.partyStr(hrun)
        if roll(run.id .. hp.label .. "brk") < ps / math.max(0.1, ps + hs * 1.3) then
            BR.event(holder, name .. "'s fighters pushed past their people at the " .. tostring(hp.label), "war")
            hrun.broken = true
            BR.recallRun(hrun, h, "driven off the " .. tostring(hp.label))
            return "broke"
        end
        BR.recallRun(run, h, "stopped at the " .. tostring(hp.label))
        BR.event(holder, "Their people at the " .. tostring(hp.label) .. " turned back " .. name .. "'s fighters", "defended")
        RS.turned = RS.turned + 1
        return "turned"
    end
    if enemy then
        if (s.stance == "dominate" or s.stance == "revenge" or holder.trade == "warband") and #(run.items or {}) > 0 then
            local n = #run.items
            for _, it in ipairs(run.items) do hrun.items[#hrun.items + 1] = it end
            run.items = {}
            run.packs = {}
            if fn(T(), "splitPacks") then T().splitPacks(run); T().splitPacks(hrun) end
            hrun.lootN = (tonumber(hrun.lootN) or 0) + n
            RS.robbed = RS.robbed + 1
            if from and not from.isCamp and fn(M, "trRouteRobbed") then pcall(M.trRouteRobbed, from, nil, holder) end
            BR.event(holder, "Their people at the " .. tostring(hp.label) .. " took everything " .. name .. "'s traders carried", "raid")
            if run.from == "you" then BR.campLetter("Your traders were robbed at the " .. tostring(hp.label) .. " by " .. tostring(holder.name) .. "'s people.", true) end
            BR.recallRun(run, h, "robbed at the " .. tostring(hp.label))
            return "robbed"
        end
        RS.turned = RS.turned + 1
        BR.recallRun(run, h, "turned back at the " .. tostring(hp.label))
        if run.from == "you" then BR.campLetter(tostring(holder.name) .. "'s people at the " .. tostring(hp.label) .. " turned your traders back.", true) end
        return "turned"
    end
    if BR.flag("holdTax") and #(run.items or {}) >= 4 then
        local n = math.max(1, math.floor(#run.items * 0.1 + 0.5))
        for i = 1, n do local it = table.remove(run.items); if it then hrun.items[#hrun.items + 1] = it end end
        if fn(T(), "splitPacks") then T().splitPacks(run); T().splitPacks(hrun) end
        RS.tolls = RS.tolls + 1
        if run.from == "you" then BR.campLetter("Your traders paid a toll at the " .. tostring(hp.label) .. " to " .. tostring(holder.name) .. "'s people.", false) end
        return "toll"
    end
    return "pass"
end

----------------------------------------------------------------------------------------------------------------
-- tools: ambush, hold (both walk to a spot on the road and wait there)
----------------------------------------------------------------------------------------------------------------
local function launchAt(b, kind, to, x, y, people, h, opts)
    local run = BR.launch(b, kind, to, people, h, opts or {})
    if run == nil then return nil end
    local th = fn(M, "travelH") and M.travelH(run.x0, run.y0, x, y, b) or run.tripH
    run.x1, run.y1, run.arrive, run.tripH = x, y, h + th, th
    run.brainJob = "war"
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = x, ty = y, untilH = run.arrive, tag = "brain_" .. kind }) end
    return run
end
BR.tool({ id = "ambush", job = "war", minPeople = 2, maxPeople = 5,
    owned = function() return BR.flag("ambushes") end,
    start = function(b, people, target)
        if type(target) ~= "table" or not tonumber(target.x) or not BR.flag("ambushes") then return false end
        local run = launchAt(b, "ambush", target.to or b.id, target.x, target.y, people, hours(), { goal = "ambush" })
        if run then
            run.ambushOn = target.to
            RS.ambushes = RS.ambushes + 1
            BR.event(b, "Sent a few people to watch the road " .. placeName(target.to) .. " uses", "war")
        end
        return run ~= nil
    end })
BR.tool({ id = "hold", job = "war", minPeople = 2, maxPeople = 4,
    owned = function() return BR.flag("holdPoints") end,
    start = function(b, people, target)
        if type(target) ~= "table" or not tonumber(target.x) or not BR.flag("holdPoints") then return false end
        local run = launchAt(b, "hold", b.id, target.x, target.y, people, hours(), { goal = "hold" })
        if run then
            run.holdLabel = tostring(target.label or "crossroads")
            RS.holds = RS.holds + 1
            BR.event(b, "Sent people to hold the " .. run.holdLabel, "brain")
        end
        return run ~= nil
    end })

-- arriving: dig in and wait (re-checked every game hour by the run engine)
function BR.roadArrive(run, b, h)
    if run.kind == "ambush" then
        if run.state ~= "ambush" then run.state = "ambush"; run.waitUntil = h + BR.num("ambushHours") end
        if h >= (tonumber(run.waitUntil) or h) or run.sprung then return false end
        run.leave, run.arrive = h, h + 1
        return true
    elseif run.kind == "hold" then
        local st = T().store()
        st.held = type(st.held) == "table" and st.held or {}
        if run.state ~= "hold" then
            run.state = "hold"
            run.waitUntil = h + BR.num("holdDays") * 24
            st.held[run.from] = { x = run.x1, y = run.y1, by = run.from, label = run.holdLabel or "crossroads", runId = run.id, h = h }
            -- everyone near knows who holds it
            for _, o in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
                if o.id ~= run.from and BR.runs(o) and d2(o.x, o.y, run.x1, run.y1) <= (BR.num("knowSeeTiles") * 2) ^ 2 then
                    BR.learn(o, run.from, { x = b.x, y = b.y, name = b.name, holds = run.holdLabel }, 0.7, "sight", h)
                end
            end
            if fn(BR, "youRec") and tonumber(BR.youRec().x) and d2(BR.youRec().x, BR.youRec().y, run.x1, run.y1) <= (BR.num("knowSeeTiles") * 2) ^ 2 then
                BR.learn(BR.youRec(), run.from, { x = b.x, y = b.y, name = b.name, holds = run.holdLabel }, 0.7, "sight", h)
            end
        end
        if h >= (tonumber(run.waitUntil) or h) or run.broken then st.held[run.from] = nil; return false end
        run.leave, run.arrive = h, h + 1
        return true
    end
    return false
end

-- an enemy run passes an ambush: spring it
function BR.ambushCheck(run, h)
    if not BR.flag("ambushes") or type(run) ~= "table" or run.kind == "ambush" or run.kind == "hold" or run.state == "done" or run.state == "siege" or run.state == "ambush" then return end
    local x, y = BR.whereNow(run, h)
    local reach = BR.num("ambushReach")
    for _, id in ipairs(BR.sortedKeys(runs())) do
        local a = runs()[id]
        if type(a) == "table" and a.kind == "ambush" and a.state == "ambush" and not a.sprung and a.from ~= run.from then
            local b = BR.home(a.from)
            if b and (run.from == a.ambushOn or hostileTo(b, run.from, h)) and d2(x, y, a.x1, a.y1) <= reach * reach then
                return BR.ambushSpring(a, b, run, h)
            end
        end
    end
end
local function victimStr(run)
    local home = BR.home(run.from)
    local per = home and BR.str(home) / math.max(1, tonumber(home.crewN) or 1) or 1
    local n = #((fn(BR, "runAlive") and BR.runAlive(run)) or run.crew or {})
    local esc = tonumber(run.escorts) or 0
    -- traders carry what they carry; an escort fights like two, a war party like itself
    if run.kind == "war" then return BR.partyStr(run) end
    return per * (n * 0.5 + esc * 1.5)
end
function BR.ambushSpring(a, b, run, h)
    a.sprung = true
    RS.sprung = RS.sprung + 1
    local victim = BR.home(run.from)
    local vname = victim and tostring(victim.name) or "travellers"
    local x, y = BR.whereNow(run, h)
    a.victim = run.id
    -- on screen: a real fight by the road
    if BR.flag("fightsOnScreen") and (BR.playerNearXY(x, y, (M.nbCfg and M.nbCfg.farTiles) or 150)) then
        a.fightDef = (fn(BR, "runAlive") and BR.runAlive(run)) or run.crew
        a.x1, a.y1 = x, y
        run.state = "ambushed" -- held up by the road while the fight lasts (runStep skips it)
        if BR.fightBegin(a, b, h) then return "fight" end
        a.fightDef = nil
        run.state = "out"
    end
    -- off screen: the odds with the real crews
    local as, vs = BR.partyStr(a), victimStr(run)
    local odds = as / math.max(0.1, as + vs * 1.1)
    if roll(a.id .. run.id .. "amb") < odds then
        BR.ambushWin(a, b, run, h)
    else
        RS.ambushLost = RS.ambushLost + 1
        local dead = BR.casualties(a.crew, 1, "killed in an ambush on " .. vname .. "'s people", h)
        BR.dropCrew(a, dead)
        BR.event(b, "Their ambush on " .. vname .. "'s people went wrong" .. (#dead > 0 and (" - " .. #dead .. " dead") or ""), "war")
        if victim then BR.event(victim, "Their people fought their way out of an ambush by " .. tostring(b.name), "defended"); BR.grudge(victim, b.id, 20, "ambushed their people") end
        BR.turnHome(a, h, a.x1, a.y1)
    end
    return "offscreen"
end
function BR.ambushWin(a, b, run, h)
    RS.ambushWon = RS.ambushWon + 1
    local victim = BR.home(run.from)
    local vname = victim and tostring(victim.name) or "travellers"
    local n = 0
    for _, it in ipairs(run.items or {}) do a.items[#a.items + 1] = it; n = n + 1 end
    run.items, run.packs = {}, {}
    a.lootN = (tonumber(a.lootN) or 0) + n
    if fn(T(), "splitPacks") then T().splitPacks(a); T().splitPacks(run) end
    if run.kind ~= "war" and (tonumber(run.escorts) or 0) > 0 then BR.dropCrew(run, BR.casualties(run.crew, 1, "killed in an ambush by " .. tostring(b.name), h)) end
    BR.event(b, "Ambushed " .. vname .. "'s people on the road" .. (n > 0 and (" and took " .. n .. " things") or ""), "war")
    if victim then
        BR.grudge(victim, b.id, 25, "ambushed their people")
        if not victim.isCamp then BR.remember(victim, "trade:road", "robbed", 1); BR.interrupt(victim, "robbed", { a = b.id }) end
        BR.event(victim, "Their people were ambushed on the road by " .. tostring(b.name), "raided")
    end
    if run.from == "you" then BR.campLetter("Your people were ambushed on the road by " .. tostring(b.name) .. (n > 0 and (" and lost " .. n .. " things") or "") .. ".", true) end
    if run.state ~= "done" then BR.recallRun(run, h, "ambushed") end
    BR.turnHome(a, h, a.x1, a.y1)
end
-- a road fight ended (ALifeBrainFight): the winner takes the victim run's packs
BR.fightOnEnd[#BR.fightOnEnd + 1] = function(a, b, h, won, how)
    if a.kind ~= "ambush" or a.victim == nil then return end
    local run = runs()[a.victim]
    a.fightDef = nil
    if type(run) ~= "table" then return end
    if run.state == "ambushed" then run.state = "out" end
    if won then
        local n = 0
        for _, it in ipairs(run.items or {}) do a.items[#a.items + 1] = it; n = n + 1 end
        run.items, run.packs = {}, {}
        a.lootN = (tonumber(a.lootN) or 0) + n
        if fn(T(), "splitPacks") then T().splitPacks(a); T().splitPacks(run) end
        RS.ambushWon = RS.ambushWon + 1
        local victim = BR.home(run.from)
        if victim then BR.grudge(victim, b.id, 25, "ambushed their people") end
        BR.recallRun(run, h, "ambushed")
    else
        RS.ambushLost = RS.ambushLost + 1
    end
end

----------------------------------------------------------------------------------------------------------------
-- the manager: where to lie in wait, what to hold
----------------------------------------------------------------------------------------------------------------
local function nKind(b, kind) local n = 0; for _, r in ipairs(fn(T(), "runsOf") and T().runsOf(b.id) or {}) do if r.kind == kind then n = n + 1 end end; return n end
function BR.roadsManage(b, sit, h, s, bids)
    if b.isCamp then return end
    local o = s.orders or {}
    if o.noWar then return end
    -- ambush: an enemy whose road we've seen
    local aggressive = s.stance == "dominate" or s.stance == "revenge" or b.trade == "warband" or (b.dir and b.dir.creed == "raiders")
    if BR.flag("ambushes") and aggressive and nKind(b, "ambush") == 0 and nKind(b, "war") == 0 then
        local pick = sit.grudgeTo or (sit.prey[1] and sit.prey[1].id) or nil
        local spot = pick and BR.seenSpot(b, pick, h) or nil
        if spot == nil then
            for _, id in ipairs(BR.sortedKeys(s.seen or {})) do
                if hostileTo(b, id, h) and BR.seenSpot(b, id, h) then pick, spot = id, BR.seenSpot(b, id, h); break end
            end
        end
        if pick and spot and pick ~= "you" or (pick == "you" and spot and BR.vsPlayerOk(b, h)) then
            bids[#bids + 1] = { job = "war", n = 3, value = 2 + BR.grudgeV(b, pick, h) / 40, tool = "ambush", target = { to = pick, x = spot.x, y = spot.y }, key = "ambush" }
        end
    end
    -- hold a chokepoint near home (expand / dominate, or secure against a known threat); one at a time
    if BR.flag("holdPoints") and (s.stance == "expand" or s.stance == "dominate" or (s.stance == "secure" and sit.threatBy)) and (tonumber(b.crewN) or 0) >= 5
            and nKind(b, "hold") == 0 and h - (tonumber(s.holdH) or -1e9) >= 24 * 3 then
        local best, bd = nil, 1e18
        for _, p in ipairs(chokepoints()) do
            local dd = d2(p.x, p.y, b.x, b.y)
            local taken = false
            for _, hp in pairs(BR.heldPoints()) do if d2(hp.x, hp.y, p.x, p.y) < 400 then taken = true end end
            if not taken and dd >= 50 * 50 and dd <= 600 * 600 and dd < bd then best, bd = p, dd end
        end
        if best then
            s.holdH = h
            bids[#bids + 1] = { job = "war", n = 2, value = 1.6, tool = "hold", target = { x = best.x, y = best.y, label = best.label or "crossroads" }, key = "hold", force = true }
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- hooks: the run engine, the road's safety, trade runs out of a besieged place, siege days
----------------------------------------------------------------------------------------------------------------
local function install()
    local t = T()
    if type(t) ~= "table" then return false end
    -- the managers list: roads after military
    local have = false
    for _, mg in ipairs(BR.managers or {}) do if mg.name == "roads" then have = true end end
    if not have and type(BR.managers) == "table" then BR.managers[#BR.managers + 1] = { name = "roads", f = BR.roadsManage } end
    M._alcpHooks = M._alcpHooks or {}
    if not M._alcpHooks.brainRoadsArrive then
        M._alcpHooks.brainRoadsArrive = true
        local ra = BR.runArrive
        BR.runArrive = function(run, h, ...)
            if type(run) == "table" and (run.kind == "ambush" or run.kind == "hold") and run.state ~= "home" then
                local b = BR.home(run.from)
                if b and BR.roadArrive(run, b, h) then return end
                if b then
                    if run.state == "hold" then local st = T().store(); if type(st.held) == "table" then st.held[run.from] = nil end end
                    return BR.turnHome(run, h, run.x1, run.y1)
                end
            end
            return ra(run, h, ...)
        end
    end
    if not t._brainRoadsStep and fn(t, "runStep") then
        t._brainRoadsStep = true
        local rs = t.runStep
        t.runStep = function(run, h, ...)
            if BR.on() and type(run) == "table" and run.state ~= "done" then
                pcall(BR.roadSeen, run, h)
                pcall(BR.heldPass, run, h)
                pcall(BR.ambushCheck, run, h)
                if run.state == "ambushed" then return end -- held up in a fight by the road
            end
            return rs(run, h, ...)
        end
    end
    -- what a group believes about the road: hostile people near it = less safe = escorts (TradeRuns' own rule)
    if not t._brainRoadsSafe and fn(t, "routeSafe") then
        t._brainRoadsSafe = true
        local safe = t.routeSafe
        t.routeSafe = function(aId, bId, ...)
            local v = safe(aId, bId, ...)
            if not (BR.on() and BR.flag("escorts")) then return v end
            local ok, cut = pcall(function()
                local a, o = BR.base(aId), BR.base(bId)
                if a == nil or o == nil or not BR.runs(a) then return 0 end
                local h = hours()
                local c = 0
                for _, k in ipairs(BR.known(a, h)) do
                    if k.id ~= bId and hostileTo(a, k.id, h) and tonumber(k.x) and onLine(k.x, k.y, a.x, a.y, o.x, o.y, 300) then c = math.max(c, 15) end
                end
                for _, hp in pairs(BR.heldPoints()) do
                    if hp.by ~= aId and hostileTo(a, hp.by, h) and onLine(hp.x, hp.y, a.x, a.y, o.x, o.y, 90) then c = math.max(c, 25) end
                end
                return c
            end)
            return clamp((tonumber(v) or 50) - (ok and cut or 0), 0, 100)
        end
    end
    -- blockade: nobody leaves a besieged place, nobody trades into it
    if not t._brainRoadsBlock and fn(t, "startRun") then
        t._brainRoadsBlock = true
        local sr = t.startRun
        t.startRun = function(b, legs, h, opts, ...)
            if BR.on() and BR.flag("blockades") and type(b) == "table" then
                local hh = tonumber(h) or hours()
                local s = type(b.brain) == "table" and b.brain or nil
                if s and type(s.sieged) == "table" and hh < (tonumber(s.sieged.untilH) or 0) then RS.blocked = RS.blocked + 1; return nil, "blockaded" end
                local to = type(legs) == "table" and type(legs[1]) == "table" and legs[1].to or nil
                local o = to and BR.base(to) or nil
                local so = o and type(o.brain) == "table" and o.brain or nil
                if so and type(so.sieged) == "table" and hh < (tonumber(so.sieged.untilH) or 0) and so.sieged.by ~= b.id then RS.blocked = RS.blocked + 1; return nil, "blockaded" end
            end
            return sr(b, legs, h, opts, ...)
        end
    end
    -- a siege day: the besieged eat into their food faster (nothing comes in)
    if not M._alcpHooks.brainRoadsSiege then
        M._alcpHooks.brainRoadsSiege = true
        local sd = BR.siegeDay
        BR.siegeDay = function(run, b, o, h, ...)
            local r = sd(run, b, o, h, ...)
            if BR.flag("blockades") and type(o) == "table" and type(o.brain) == "table" and type(o.brain.sieged) == "table" then
                local drain = (tonumber(o.crewN) or 1) * BR.num("blockadeDrain") / 100
                o.food = math.max(0, (tonumber(o.food) or 0) - drain)
            end
            return r
        end
    end
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
do
    local Events = ALifeSide.hooks("world", "ALifeBrainRoads")
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            local n = 0
            for _ in pairs(BR.heldPoints()) do n = n + 1 end
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": ambushes " .. (BR.flag("ambushes") and "on" or "off") .. ", held points " .. n .. ", blockades " .. (BR.flag("blockades") and "on" or "off"))
        end)
    end
end
