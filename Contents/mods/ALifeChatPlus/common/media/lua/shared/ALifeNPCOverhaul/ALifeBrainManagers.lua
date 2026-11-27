-- A-Life NPC Overhaul pre-1.0: BRAIN B5, MANAGERS (docs/PLAN-BRAIN.md). Each reads the situation, beliefs and memory
-- and bids for people { job, n, value, tool, target } (or asks for a call that needs nobody). The allocator decides.
--   Economy    food / supplies; tells Trade what it lacks
--   Defense    guards from the threat, walls, calls allies, pulls runs home when a war party is coming
--   Trade      the only caller of trade runs, middlemen, deal offers and caravans to you for its group; avoids bad
--              roads and partners that cost them before (memory)
--   Scouting   keeps beliefs fresh: one scout to the stalest belief that matters
--   Growth     takes in loners, founds outposts when crowded (expand), moves on when the land is stripped (survive)
--   Diplomacy  alliances against a shared threat, tribute demands, peace after a bad war, absorbing the broken
--   Military   targets by gain vs loss, raid / assault / siege, party size from the odds, never on stale intel
-- The tools the old systems register here (war tools: ALifeBrainWar).
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll
local function T() return ALifeTrade end

----------------------------------------------------------------------------------------------------------------
-- tools from the existing systems
----------------------------------------------------------------------------------------------------------------
local function runsOf(b) local t = T(); return fn(t, "runsOf") and t.runsOf(b.id) or {} end
local function nRuns(b, kind) local n = 0; for _, r in ipairs(runsOf(b)) do if kind == nil or r.kind == kind then n = n + 1 end end; return n end
BR.tool({ id = "tradeRun", job = "trade", minPeople = 1, maxPeople = 3,
    start = function(b, people, target)
        if type(target) ~= "table" or not fn(M, "cvRunWith") then return false end
        local o = BR.base(target.to)
        if o == nil then return false end
        local before = nRuns(b)
        M.cvRunWith(b, o, target.give, target.want, hours())
        return nRuns(b) > before
    end })
BR.tool({ id = "middleman", job = "trade", minPeople = 1, maxPeople = 3,
    start = function(b, people)
        local t = T()
        if not fn(t, "brokerDay") then return false end
        local before = nRuns(b, "broker")
        b.trBrokerDay = nil
        t.brokerDay(b, hours())
        return nRuns(b, "broker") > before
    end })
BR.tool({ id = "offer", start = function(b) local t = T(); if fn(t, "offerDay") then t.offerDay(b, hours()); return true end; return false end })
BR.tool({ id = "postCaravan", start = function(b) if fn(M, "tpDaily") then M.tpDaily(b, hours()); return true end; return false end })
BR.tool({ id = "recruit", job = "recruit",
    start = function(b)
        if not (fn(M, "nbRecruit") and fn(M, "nbHavenOf") and fn(M, "nbScan")) then return false end
        local hv = M.nbHavenOf(b)
        if hv == nil then return false end
        return M.nbRecruit(b, hv, hours(), M.nbScan()) ~= nil
    end })
BR.tool({ id = "outpost", start = function(b) if fn(M, "opFound") then b.opLastH = hours(); return M.opFound(b, hours()) ~= nil end; return false end })
BR.tool({ id = "nomadMove", start = function(b) if fn(M, "nmTryLeave") then return M.nmTryLeave(b, hours()) == true end; return false end })
-- raids on paper: owned (switched off) only while war parties replace them
BR.tool({ id = "paperRaid", owned = function() return BR.flag("warParties") end, start = function() return false end })

----------------------------------------------------------------------------------------------------------------
-- managers
----------------------------------------------------------------------------------------------------------------
BR.managers = BR.managers or {}
local function manager(name, f) BR.managers[#BR.managers + 1] = { name = name, f = f } end
local function bid(bids, t) bids[#bids + 1] = t; return t end
local function day(h) return math.floor(h / 24) end
local function shareOf(s, job) return tonumber(BR.shares(s.stance or "grow")[job]) or 0 end

-- Economy: everyone not needed elsewhere scrounges; the hungrier, the more it's worth
manager("economy", function(b, sit, h, s, bids)
    local v = 1 + (sit.food < 3 and 2 or 0) + (sit.food < 1 and 2 or 0) + (sit.trend < 0 and 0.5 or 0)
    bid(bids, { job = "economy", n = sit.crew, value = v, key = "economy" })
    -- what they lack goes to Trade
    s.want = {}
    local t = T()
    if fn(t, "ratio") then for _, k in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do if t.ratio(b, k) < 0.6 then s.want[#s.want + 1] = k end end end
end)

-- Defense: guards from the threat, walls, allies, runs home
manager("defense", function(b, sit, h, s, bids)
    local gate = math.max(BR.num("minGuards"), tonumber((s.orders or {}).gate) or 0)
    local n = gate + math.ceil(math.min(1.5, sit.threat) * sit.crew * 0.3)
    bid(bids, { job = "guard", n = n, value = 2 + sit.threat * 3, force = sit.threat >= 1 or sit.incoming, key = "guard" })
    local walls = b.stage ~= "fortified"
    if walls or sit.winterSoon or s.stance == "secure" then
        bid(bids, { job = "build", n = (walls and 2 or 1), value = 1.5 + (s.stance == "secure" and 1 or 0) + (sit.winterSoon and 0.5 or 0), key = "build" })
    end
    -- a war party coming: pull runs home
    if sit.incoming and fn(BR, "recallRuns") then BR.recallRuns(b, h, "a war party is coming") end
    -- a threat far stronger: ask allies
    if sit.threat >= 1.5 and fn(BR, "askHelp") and h - (tonumber(s.askedHelpH) or -1e9) >= 48 then
        for _, o in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
            if o.id ~= b.id and BR.tieState(BR.tie(b, o)) == "allied" then
                s.askedHelpH = h
                BR.askHelp(b, o, sit.threatBy, h)
                break
            end
        end
        if fn(BR, "coalitionCall") then pcall(BR.coalitionCall, b, sit, h, s) end -- Brain 2 R6: coalition partners too
    end
end)

-- Trade: who, what, which road (one run out at a time)
function BR.tradePartner(b, h, safeOnly)
    local t = T()
    if not (fn(M, "nbStashList") and fn(M, "nbHavenOf") and fn(M, "cvSpareKind") and fn(M, "cvLacksKind")) then return nil end
    local function counts(o)
        local by = {}
        for _, it in ipairs(M.nbStashList(M.nbHavenOf(o)) or {}) do
            local k = M.nbKindOf(type(it) == "table" and it.type or it); by[k] = (by[k] or 0) + 1
        end
        return by
    end
    local have = counts(b)
    local tiles = (M.cvRunCfg and M.cvRunCfg.tiles) or 1000
    local best, bs, give, want = nil, -1e9, nil, nil
    for _, k in ipairs(BR.known(b, h)) do
        local o = BR.base(k.id)
        if o and not o.airport and not o.road and k.dist <= tiles and BR.tie(b, o) >= 0 and o.trade ~= "warband" and o.trade ~= "slavers" and not k.hostile
                and not (fn(t, "embargoed") and t.embargoed(o.id, b.id)) and not (type(o.brain) == "table" and type(o.brain.sieged) == "table" and h < (tonumber(o.brain.sieged.untilH) or 0)) then
            local safe = fn(t, "routeSafe") and t.routeSafe(b.id, o.id) or 50
            if not (safeOnly and safe < ((t.num and t.num("escortBelow")) or 35)) then
                local theirs = counts(o)
                local mem = BR.mem(b, "trade:" .. o.id, h)
                for _, g in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do
                    for _, w in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do
                        if g ~= w and M.cvSpareKind(b, have, g) and M.cvLacksKind(b, have, w) and M.cvSpareKind(o, theirs, w) and M.cvLacksKind(o, theirs, g) then
                            local sc = (have[g] or 0) + (theirs[w] or 0) - k.dist / 50 - (mem.robbed or 0) * 6 + BR.debtV(b, o.id, h) / 10 + (safe - 50) / 10
                            if sc > bs then best, bs, give, want = o, sc, g, w end
                        end
                    end
                end
            end
        end
    end
    if best == nil then return nil end
    return { to = best.id, give = give, want = want }
end
manager("trade", function(b, sit, h, s, bids)
    local o = s.orders or {}
    if o.noTrade or shareOf(s, "trade") <= 0 then return end
    if (tonumber(o.keepFoodDays) or 0) > 0 and sit.food < o.keepFoodDays and s.stance ~= "trade" then return end
    -- the old rhythm: traders and trade stance every day, others every few days
    local every = (b.trade == "traders" or s.stance == "trade") and 1 or 3
    if day(h) - (tonumber(s.tradeDay) or -99) < every then return end
    if nRuns(b) == 0 and h - (tonumber(s.tradeTryH) or -1e9) >= 12 then
        s.tradeTryH = h -- a try that couldn't start waits half a day
        local p = BR.tradePartner(b, h, o.noRunsOnBadRoads)
        local crew = math.floor((T() and T().num and T().num("runCrew")) or 2)
        if p then
            local x = bid(bids, { job = "trade", n = crew, value = 1.5 + (s.stance == "trade" and 1.5 or 0), tool = "tradeRun", target = p, key = "trade" })
            x.onStart = function() s.tradeDay = day(h) end
        elseif b.trade == "traders" then
            bid(bids, { job = "trade", n = crew, value = 1.2, tool = "middleman", key = "middleman" })
            s.tradeDay = day(h)
        end
    end
    -- calls that need nobody yet: deal offers to you, caravans to your trading post
    if s.stance ~= "survive" and s.stance ~= "secure" then
        bid(bids, { call = "offer" })
        bid(bids, { call = "postCaravan" })
    end
end)

-- Scouting: the stalest belief that matters
manager("scouting", function(b, sit, h, s, bids)
    if not BR.flag("scouts") or s.stance == "survive" or nRuns(b, "scout") > 0 then return end
    if h - (tonumber(s.scoutH) or -1e9) < 24 then return end
    local target, tv = nil, 0
    local reach = ((M.dirCfg and M.dirCfg.raidTiles) or 700) * 2
    local planT = type(s.plan) == "table" and s.plan.target or nil
    for _, k in ipairs(BR.known(b, h)) do
        if k.dist <= reach and k.id ~= "you" or (k.id == "you" and BR.vsPlayerOk(b, h)) then
            local matters = (k.hostile and 1 or 0) + (BR.grudgeV(b, k.id, h) >= 20 and 1 or 0) + (k.id == planT and 2 or 0) + (k.id == sit.threatBy and 1 or 0)
            for _, p in ipairs(sit.prey) do if p.id == k.id then matters = matters + 1 end end
            local v = matters * (1 - k.c)
            if matters > 0 and k.c < 0.7 and v > tv then target, tv = k.id, v end
        end
    end
    if target then bid(bids, { job = "scout", n = 1, value = 1 + tv * 2 + (target == planT and 2 or 0), tool = "scoutRun", target = { to = target }, key = "scout" }) end
end)

-- Growth: loners, outposts, moving on
manager("growth", function(b, sit, h, s, bids)
    local cfg = M.nbCfg or {}
    if (s.stance == "grow" or s.stance == "expand" or sit.crew < 4) and (tonumber(b.morale) or 50) >= (cfg.recruitMorale or 55)
            and sit.food >= 2 and sit.crew < (cfg.memberCap or 8) and s.recruitDay ~= day(h) then
        local x = bid(bids, { job = "recruit", n = 1, value = 1.3, tool = "recruit", key = "recruit" })
        x.onStart = function() s.recruitDay = day(h) end
    end
    if s.stance == "expand" and fn(M, "opFound") and h - (tonumber(b.opLastH) or -1e9) >= ((M.opCfg and M.opCfg.everyH) or 168)
            and (tonumber(M.nmSearchH) or -1e9) <= h - ((M.nmCfg and M.nmCfg.searchEveryH) or 6) then
        bid(bids, { call = "outpost", farOnly = true })
    end
    if s.stance == "survive" and sit.food < 1.5 and fn(M, "nmStripped") and select(2, pcall(M.nmStripped, b)) == true then
        bid(bids, { call = "nomadMove" })
    end
end)

-- Diplomacy: allies against a shared threat, tribute, peace, absorbing the broken
manager("diplomacy", function(b, sit, h, s, bids)
    if s.diploDay == day(h) then return end
    s.diploDay = day(h)
    local w = BR.w(b, h)
    -- a shared enemy brings neighbours together
    if sit.threatBy and fn(M, "dirBumpTie") then
        for _, o in ipairs(M.nbActive()) do
            if o.id ~= b.id and o.id ~= sit.threatBy and BR.tie(b, o) >= 0 and BR.tieState(BR.tie(b, o)) ~= "allied" then
                local ok = BR.belief(b, o.id, h)
                local theirs = type(o.brain) == "table" and o.brain.threatBy or nil
                if ok and theirs == sit.threatBy then pcall(M.dirBumpTie, b, o, math.floor(3 + 3 * (w.kindness or 1))) end
            end
        end
    end
    -- tribute: the strong lean on the weak (an envoy walks over)
    if BR.flag("brainTribute") and (s.stance == "dominate") and fn(BR, "envoyBid") then
        for _, p in ipairs(sit.prey) do
            local paid = type(s.tribute) == "table" and s.tribute[p.id] or nil
            if p.sure and p.ratio < 0.5 and not (type(paid) == "table" and h - (tonumber(paid.h) or 0) < 168) and not (type(s.plan) == "table" and s.plan.key == "tribute") then
                if p.id ~= "you" or BR.vsPlayerOk(b, h) then BR.envoyBid(b, bids, p.id, "tribute", 2.5); break end
            end
        end
    end
    -- peace after a war that's going badly
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and BR.tie(b, o) <= -50 then
            local m = BR.mem(b, "raid:" .. o.id, h)
            if (s.pressure >= 50 or (m.losses or 0) >= 2) and fn(BR, "envoyBid") then BR.envoyBid(b, bids, o.id, "peace", 2); break end
        end
    end
end)

-- Military: targets, odds, party size
function BR.warTarget(b, sit, h, s)
    local actConf = BR.num("knowActConf") / 100
    local pick = nil
    if s.stance == "revenge" and sit.grudgeTo and string.sub(sit.grudgeTo, 1, 6) ~= "place:" then pick = sit.grudgeTo
    elseif s.stance == "dominate" and sit.prey[1] then pick = sit.prey[1].id end
    if type(s.plan) == "table" and s.plan.target and s.plan.wantWar then pick = s.plan.target end
    if pick == nil then return nil end
    if pick == "you" and not BR.vsPlayerOk(b, h) then return nil end
    local k = BR.belief(b, pick, h)
    if k == nil then return { id = pick, scout = true } end
    local _, _, rnd = BR.w(b, h)
    local w = BR.w(b, h)
    local reckless = rnd > 0.6 and (w.aggression or 1) > 1.5
    if k.c < actConf and not reckless then return { id = pick, scout = true } end
    return { id = pick, k = k }
end
function BR.partySize(b, k, h)
    local crew = math.max(1, tonumber(b.crewN) or 1)
    local per = BR.str(b) / crew
    local def = (tonumber(k.str) or 1) * 0.7 * (1 + (tonumber(k.walls) or 0) * 0.15)
    local need = math.ceil(def * 1.3 / math.max(0.1, per))
    local max = math.floor(BR.num("warPartyMax") / 100 * crew)
    return math.max(2, need), max
end
manager("military", function(b, sit, h, s, bids)
    if not BR.flag("warParties") or (s.orders or {}).noWar or nRuns(b, "war") > 0 then return end
    -- an ally asked for help
    if type(s.helpAsk) == "table" and h - (tonumber(s.helpAsk.h) or -1e9) < 48 and s.stance ~= "survive" and (BR.base(s.helpAsk.by) or s.helpAsk.by == "you") then
        bid(bids, { job = "war", n = 2, value = 2 + BR.debtV(b, s.helpAsk.by, h) / 20, tool = "help", target = { to = s.helpAsk.by }, key = "help", force = true })
    end
    if s.stance ~= "dominate" and s.stance ~= "revenge" and not (type(s.plan) == "table" and s.plan.wantWar) then return end
    -- a plan in hand steers: no war until its war step (scout first, the quiet before the hit)
    if type(s.plan) == "table" and not s.plan.wantWar then return end
    local t = BR.warTarget(b, sit, h, s)
    if t == nil then return end
    if t.scout then
        if BR.flag("scouts") and nRuns(b, "scout") == 0 then bid(bids, { job = "scout", n = 1, value = 3, tool = "scoutRun", target = { to = t.id }, key = "warscout" }) end
        return
    end
    local need, max = BR.partySize(b, t.k, h)
    local _, _, rnd = BR.w(b, h)
    if need > max and not (rnd > 0.6) then return end -- the odds are bad: no war today
    local goal = "raid"
    local grudge = BR.grudgeV(b, t.id, h)
    if t.id == "you" then goal = "siege"
    elseif (tonumber(t.k.walls) or 0) >= 1 or t.k.stage == "fortified" then goal = sit.food >= 6 and "siege" or "raid"
    elseif grudge >= 60 or (s.stance == "dominate" and (tonumber(t.k.str) or 1) < sit.str * 0.4) then goal = "assault" end
    if type(s.plan) == "table" and s.plan.goal then goal = s.plan.goal end
    bid(bids, { job = "war", n = math.min(need, max), value = 3 + grudge / 30, tool = "warParty", target = { to = t.id, goal = goal }, key = "war" })
end)

----------------------------------------------------------------------------------------------------------------
-- manage: managers bid, plans steer, the allocator decides, the tools run
----------------------------------------------------------------------------------------------------------------
function BR.manage(b, h, far)
    local s = BR.of(b)
    if s.stance == nil then BR.think(b, h, "day") end
    local sit = BR.situation(b, h)
    local bids = {}
    -- the plan first (it steers the managers: a war it wants, a quiet before the hit)
    if BR.flag("brainPlans") and fn(BR, "planStep") then
        local ok, err = pcall(BR.planStep, b, sit, h, bids, far)
        if not ok then BR.log("plan failed: " .. tostring(err)) end
    elseif type(s.plan) == "table" and fn(BR, "planAbort") then BR.planAbort(b, "stance", h) end
    for _, mg in ipairs(BR.managers) do
        local ok, err = pcall(mg.f, b, sit, h, s, bids, far)
        if not ok then BR.log("manager " .. mg.name .. " failed: " .. tostring(err)) end
    end
    local people = {}
    for _, x in ipairs(bids) do if x.job then people[#people + 1] = x end end
    BR.allocate(b, h, people)
    for _, x in ipairs(people) do
        if x.started and x.onStart then pcall(x.onStart) end
        if x.started and x.tool and not BR.AWAY[x.job] then BR.call(x.tool, b, {}, x.target, x.opts) end
    end
    for _, x in ipairs(bids) do
        if x.call and (not x.farOnly or far) then BR.call(x.call, b, {}, x.target, x.opts) end
    end
    s.sit = { threat = sit.threat, threatBy = sit.threatBy, food = sit.food, prey = sit.prey[1] and sit.prey[1].id or nil }
    if fn(BR, "wordsAfter") then pcall(BR.wordsAfter, b, h) end
end

-- memory from the roads: runs that got through, runs robbed
local function install()
    M._alcpHooks = M._alcpHooks or {}
    local t = T()
    if type(t) == "table" and type(t.onLeg) == "table" and not t._brainMem then
        t._brainMem = true
        t.onLeg[#t.onLeg + 1] = function(run, leg, gave, got, why)
            if not BR.on() or run.brain or run.from == "you" or type(leg) ~= "table" or leg.to == "you" then return end
            local b = BR.base(run.from)
            if b then BR.remember(b, "trade:" .. tostring(leg.to), "runs", 1); if why == nil then BR.remember(b, "trade:" .. tostring(leg.to), "profit", #(got or {})) end end
        end
    end
    if not M._alcpHooks.brainRobbed and fn(M, "trRouteRobbed") then
        M._alcpHooks.brainRobbed = true
        local rr = M.trRouteRobbed
        M.trRouteRobbed = function(b, o, robber, ...)
            local r = rr(b, o, robber, ...)
            if BR.on() and type(b) == "table" then
                pcall(function()
                    if type(o) == "table" then BR.remember(b, "trade:" .. tostring(o.id), "robbed", 1) end
                    if type(robber) == "table" then
                        local mx, my = type(o) == "table" and (b.x + o.x) / 2 or b.x, type(o) == "table" and (b.y + o.y) / 2 or b.y
                        BR.grudge(b, robber.id, 15, "robbed their traders", "place:" .. math.floor(mx) .. "," .. math.floor(my))
                        BR.interrupt(b, "robbed", { a = robber.id })
                    end
                end)
            end
            return r
        end
    end
    -- a deal broken: the side left waiting holds it against the other
    if type(t) == "table" and fn(t, "dealMiss") and not t._brainDeal then
        t._brainDeal = true
        local dm = t.dealMiss
        t.dealMiss = function(d, why, ...)
            local r = dm(d, why, ...)
            if BR.on() and type(d) == "table" and t.store().deals[d.id] == nil and d.b ~= "you" then
                local wronged, by = BR.base(d.b), BR.base(d.a)
                if wronged and by then BR.grudge(wronged, by.id, 10, "broke a deal"); BR.remember(wronged, "trade:" .. by.id, "robbed", 1); BR.interrupt(wronged, "dealBroken", { a = by.id }) end
            end
            return r
        end
    end
    -- a group ended: whoever knew it thinks again (its people may come looking for a home; its land is free)
    if not M._alcpHooks.brainEnded and fn(M, "nbEnded") then
        M._alcpHooks.brainEnded = true
        local en = M.nbEnded
        M.nbEnded = function(b, reason, ...)
            local r = en(b, reason, ...)
            if BR.on() and type(b) == "table" and fn(M, "nbActive") then
                pcall(function()
                    for _, o in ipairs(M.nbActive()) do
                        if o.id ~= b.id and type(o.brain) == "table" and type(o.brain.know) == "table" and o.brain.know[b.id] ~= nil then
                            o.brain.know[b.id] = nil
                            BR.interrupt(o, "groupEnded", { a = b.id })
                        end
                    end
                end)
            end
            return r
        end
    end
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)

----------------------------------------------------------------------------------------------------------------
-- Brain 2 R6: coalitions and the last war go through the minds (ALifeRegion's rules stay the checks)
--   * a coalition only holds the members who know the big one and fear it (a belief, a threat, a grudge): fog of war
--   * coalition partners never pick each other as targets, and call each other for help like allies
--   * the last war waits while either side is just trying to survive
----------------------------------------------------------------------------------------------------------------
function BR.fearsIt(b, bigId, h)
    if not BR.runs(b) then return true end -- not on the brain: Region's own rule
    local k = BR.belief(b, bigId, h)
    if k == nil then return false end
    local s = BR.of(b)
    if s.threatBy == bigId or BR.grudgeV(b, bigId, h) >= 20 then return true end
    return (tonumber(k.str) or 0) >= BR.str(b) * 1.5
end
function BR.coalitionPartners(b)
    local R = ALifeRegion
    if type(R) ~= "table" or not fn(R, "coalitionOf") then return {} end
    local c = R.coalitionOf(b.id)
    if type(c) ~= "table" then return {} end
    local out = {}
    for _, id in ipairs(c.members or {}) do if id ~= b.id then out[#out + 1] = id end end
    return out
end
local function installRegion()
    local R = ALifeRegion
    if type(R) ~= "table" or not fn(R, "formCoalitions") then return false end
    if R._brainCoal then return true end
    R._brainCoal = true
    local fc = R.formCoalitions
    R.formCoalitions = function(h, ...)
        local before = #(R.store().coalitions or {})
        local made = fc(h, ...)
        if BR.on() then
            local list = R.store().coalitions
            for i = #list, before + 1, -1 do
                local c = list[i]
                local keep = {}
                for _, id in ipairs(c.members or {}) do local b = BR.base(id); if b and BR.fearsIt(b, c.against, h) then keep[#keep + 1] = id end end
                if #keep < 2 then table.remove(list, i); made = math.max(0, (tonumber(made) or 1) - 1)
                else
                    c.members = keep
                    for _, id in ipairs(keep) do local b = BR.base(id); if b then BR.interrupt(b, "coalition", { a = c.against }) end end
                end
            end
        end
        return made
    end
    if fn(R, "warPair") then
        local wp = R.warPair
        R.warPair = function(...)
            local a, b = wp(...)
            if a and b and BR.on() then
                for _, side in ipairs({ a, b }) do
                    local o = BR.base(side.id)
                    local s = o and type(o.brain) == "table" and o.brain or nil
                    if s and (s.stance == "survive" or (tonumber(s.pressure) or 0) >= 60) then return nil, "a side is just trying to survive" end
                end
            end
            return a, b
        end
    end
    return true
end
BR.installers[#BR.installers + 1] = installRegion
pcall(installRegion)
-- partners are never targets
do
    local wt = BR.warTarget
    BR.warTarget = function(b, sit, h, s, ...)
        local t = wt(b, sit, h, s, ...)
        if type(t) == "table" and t.id ~= nil then
            for _, id in ipairs(BR.coalitionPartners(b)) do if id == t.id then return nil end end
        end
        return t
    end
end
-- partners answer a call for help like allies (Defense calls only allied groups today)
do
    BR.coalitionCall = function(b, sit, h, s)
        if not (sit.threat >= 1.5 and h - (tonumber(s.askedHelpH) or -1e9) >= 48) then return false end
        for _, id in ipairs(BR.coalitionPartners(b)) do
            local o = BR.base(id)
            if o and fn(BR, "askHelp") then s.askedHelpH = h; BR.askHelp(b, o, sit.threatBy, h); return true end
        end
        return false
    end
end

