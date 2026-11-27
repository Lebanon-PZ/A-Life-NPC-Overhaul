-- A-Life NPC Overhaul pre-1.0: BRAIN B7, PLANS (docs/PLAN-BRAIN.md). Multi-day intent, one plan slot per group.
-- A plan is a few steps with conditions: their traders vanish from the roads, scouts appear, then the hit comes.
-- Library (data): scout then raid; siege (starve them out); arms first then attack; tribute, raid if refused; walls
-- before winter; envoy for an alliance; an outpost. Disciplined leaders finish plans; volatile ones drop them for a
-- shiny chance; fearful ones abort when a step looks bad. Abort (checked every manager tick): lost planAbortLoss of
-- the people sent, food critical, the target reinforced past the odds, the leader died, a bigger threat, the target
-- gone. Abort = every plan run called home from where it is, the slot freed, the commander thinks now.
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, clamp, roll = BR.fn, BR.hours, BR.clamp, BR.roll

-- steps: { act, ... }   acts: scout, wait, stock, armup, envoy, answer, war, build, outpost
BR.PLANS = {
    scoutRaid = { fits = { dominate = true, revenge = true }, words = "hit %s", steps = {
        { act = "scout" }, { act = "wait", days = 3, quiet = true }, { act = "war", goal = "raid" } } },
    siege = { fits = { dominate = true, revenge = true }, words = "starve %s out", steps = {
        { act = "scout" }, { act = "stock", food = 8, days = 7 }, { act = "war", goal = "siege" } } },
    armsFirst = { fits = { dominate = true, revenge = true }, words = "arm up, then deal with %s", steps = {
        { act = "armup", days = 7 }, { act = "scout" }, { act = "war", goal = "assault" } } },
    tribute = { fits = { dominate = true }, words = "make %s pay", steps = {
        { act = "envoy", goal = "tribute" }, { act = "answer", days = 3 }, { act = "war", goal = "raid", ifRefused = true } } },
    wallsWinter = { fits = { secure = true, grow = true, survive = true }, words = "get the walls up before winter", steps = {
        { act = "build", days = 10 } } },
    ally = { fits = { secure = true, survive = true, grow = true }, words = "find friends against %s", steps = {
        { act = "envoy", goal = "ally" }, { act = "answer", days = 2 } } },
    outpost = { fits = { expand = true }, words = "find a second place to hold", steps = { { act = "outpost" } } },
}
-- each plan can be switched off (rule 2): brainPlan_<key>
do
    local d, rows = {}, {}
    local label = { scoutRaid = "scout, wait for the moment, then raid", siege = "lay siege and starve a fortified group out",
        armsFirst = "trade for ammunition before a fight", tribute = "demand tribute, raid if refused", wallsWinter = "get the walls up before winter",
        ally = "send an envoy to find allies against a threat", outpost = "found an outpost when crowded" }
    for _, k in ipairs(BR.sortedKeys(BR.PLANS)) do d["brainPlan_" .. k] = true; rows[#rows + 1] = { "brainPlan_" .. k, "Brain plans: " .. tostring(label[k] or k) } end
    BR.defaults(d)
    BR.addRows(rows)
end
function BR.planOn(key) return BR.flag("brainPlan_" .. tostring(key)) end
function BR.planFits(b, plan, stance)
    local def = BR.PLANS[plan and plan.key or ""]
    return def ~= nil and def.fits[stance] == true
end
function BR.planWords(b, plan)
    local def = BR.PLANS[plan and plan.key or ""]
    if def == nil then return nil end
    local name = plan.target == "you" and "the newcomer" or (BR.base(plan.target) and BR.base(plan.target).name) or "them"
    return string.format(def.words, tostring(name))
end

-- pick a plan for the stance (only when the slot is free)
function BR.planPick(b, sit, h)
    local s = BR.of(b)
    local st = s.stance
    local key, target = nil, nil
    if st == "dominate" or st == "revenge" then
        local t = fn(BR, "warTarget") and BR.warTarget(b, sit, h, s) or nil
        if t == nil then return nil end
        target = t.id
        local k = BR.belief(b, target, h)
        if st == "dominate" and BR.flag("brainTribute") and k and k.c >= 0.5 and (tonumber(k.str) or 1) < sit.str * 0.5
                and not (type(s.tribute) == "table" and s.tribute[target] and h - (tonumber(s.tribute[target].h) or 0) < 168) then key = "tribute"
        elseif sit.ammo < 0.5 then key = "armsFirst"
        elseif k and ((tonumber(k.walls) or 0) >= 1 or k.stage == "fortified") and target ~= "you" then key = "siege"
        else key = "scoutRaid" end
        if target == "you" then key = (key == "tribute") and "tribute" or "scoutRaid" end
    elseif (st == "secure" or st == "grow" or st == "survive") and sit.winterSoon and b.stage ~= "fortified" then key = "wallsWinter"
    elseif (st == "secure" or st == "survive") and sit.threat >= 1.2 and sit.threatBy then
        for _, o in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
            if o.id ~= b.id and o.id ~= sit.threatBy and BR.tie(b, o) >= 15 and BR.tieState(BR.tie(b, o)) ~= "allied" and BR.belief(b, o.id, h) then key, target = "ally", o.id; break end
        end
    elseif st == "expand" and fn(M, "opFound") then key = "outpost" end
    if key == nil or not BR.planOn(key) then return nil end
    local k = target and BR.belief(b, target, h) or nil
    local plan = { id = "p" .. tostring(BR.hash(tostring(b.id) .. key .. tostring(h)) % 100000), key = key, target = target, step = 1, stepH = h, startH = h,
        sent = 0, lost = 0, str0 = k and tonumber(k.str) or nil, myStr0 = sit.str, leader0 = b.leader }
    s.plan = plan
    BR.stats.plans = BR.stats.plans + 1
    local w = BR.planWords(b, plan)
    if w then BR.event(b, "They've made up their minds to " .. w, "brain") end
    return plan
end

-- drop the plan: every run of it walks home from where it is now, the slot is free, think again now
function BR.planAbort(b, why, h)
    local s = BR.of(b)
    local plan = s.plan
    if type(plan) ~= "table" then return false end
    h = h or hours()
    if fn(BR, "recallRuns") then BR.recallRuns(b, h, nil, function(run) return run.brain and run.planId == plan.id end) end
    -- a siege party is "out" in siege state too
    local t = ALifeTrade
    if type(t) == "table" and fn(t, "runsOf") then
        for _, run in ipairs(t.runsOf(b.id)) do if run.brain and run.planId == plan.id and run.state == "siege" then BR.recallRun(run, h, nil) end end
    end
    s.plan = nil
    if type(s.orders) == "table" then s.orders.noTrade = (BR.ORDERS[s.stance or ""] or {}).noTrade end
    s.lastPlan = { key = plan.key, target = plan.target, why = why, h = h }
    BR.stats.aborts = BR.stats.aborts + 1
    local words = { loss = "They lost too many people and called it off", food = "Hunger put an end to their plans", reinforced = "Word came the other side was too strong now - they called it off",
        leader = "With their leader gone the plan fell apart", threat = "Something bigger came up and they dropped their plans", gone = "Their target was gone",
        stance = "They changed their minds", impulse = "They dropped what they'd planned for an easier chance", fear = "They lost their nerve" }
    BR.event(b, words[why] or "They gave up on what they'd planned", "brain")
    BR.interrupt(b, "planAbort")
    return true
end
local function resetOrders(s) if type(s.orders) == "table" then s.orders.noTrade = (BR.ORDERS[s.stance or ""] or {}).noTrade end end
local function planDone(b, ok, h)
    local s = BR.of(b)
    local plan = s.plan
    s.plan = nil
    resetOrders(s)
    s.lastPlan = { key = plan.key, target = plan.target, why = ok and "done" or "failed", h = h }
    local w = BR.planWords(b, plan)
    if w then BR.event(b, ok and ("They did what they set out to: " .. w) or ("They tried to " .. w .. " and it didn't work out"), "brain") end
end

local function abortWhy(b, plan, sit, h, s)
    if plan.sent > 0 and plan.lost / plan.sent * 100 >= BR.num("planAbortLoss") then return "loss" end
    if sit.food < 1 and plan.key ~= "wallsWinter" then return "food" end
    if plan.target and plan.target ~= "you" and BR.base(plan.target) == nil then return "gone" end
    if plan.leader0 ~= b.leader then return "leader" end
    if sit.threatBy and plan.target ~= sit.threatBy and sit.threat >= 1.5 and plan.key ~= "ally" and plan.key ~= "wallsWinter" then return "threat" end
    if plan.target and plan.str0 then
        local k = BR.belief(b, plan.target, h)
        if k and k.c >= 0.5 and tonumber(k.str) and k.str > plan.str0 * 1.5 and k.str > sit.str * 0.9 then return "reinforced" end
    end
    local w, disc, rnd = BR.w(b, h)
    -- volatile minds drop a plan for a shiny chance; disciplined ones don't
    if disc < 0 and sit.prey[1] and sit.prey[1].id ~= plan.target and sit.prey[1].sure and roll(b.id .. "impulse" .. math.floor(h / 24)) < (-disc) * 0.2 + rnd * 0.1 then return "impulse" end
    -- fearful minds lose their nerve when a step looks bad
    if (w.fear or 1) >= 1.5 and plan.lost > 0 and disc < 0.5 then return "fear" end
    return nil
end

-- every manager tick: check aborts, then do the current step (adds bids)
function BR.planStep(b, sit, h, bids, far)
    local s = BR.of(b)
    local plan = s.plan
    if type(plan) ~= "table" then
        if s.planDay ~= math.floor(h / 24) then s.planDay = math.floor(h / 24); BR.planPick(b, sit, h) end
        return
    end
    local why = abortWhy(b, plan, sit, h, s)
    if why then return BR.planAbort(b, why, h) end
    local def = BR.PLANS[plan.key]
    local step = def and def.steps[plan.step] or nil
    if step == nil then return planDone(b, true, h) end
    plan.wantWar = false
    local days = (h - (tonumber(plan.stepH) or h)) / 24
    local function nextStep() plan.step = plan.step + 1; plan.stepH = h; plan.runId = nil; plan.runDone = nil end
    local act = step.act
    local k = plan.target and BR.belief(b, plan.target, h) or nil
    if act == "scout" then
        if k and k.c >= BR.num("knowActConf") / 100 and h - (tonumber(k.h) or -1e9) < 48 then return nextStep() end
        if not BR.flag("scouts") then return nextStep() end
        if days >= 6 then return BR.planAbort(b, "gone", h) end
        bids[#bids + 1] = { job = "scout", n = 1, value = 4, tool = "scoutRun", target = { to = plan.target }, key = "planScout" }
    elseif act == "wait" then
        -- the quiet before: their own traders stay home (no runs out), and they wait for the target's runs to be out
        if step.quiet then s.orders = s.orders or {}; s.orders.noTrade = true end
        local theirRuns = 0
        if plan.target ~= "you" and type(ALifeTrade) == "table" and fn(ALifeTrade, "runsOf") then theirRuns = #ALifeTrade.runsOf(plan.target) end
        if days >= (step.days or 3) or theirRuns > 0 then if step.quiet and s.orders then s.orders.noTrade = nil end; return nextStep() end
    elseif act == "stock" then
        if sit.food >= (step.food or 8) or days >= (step.days or 7) then return nextStep() end
        bids[#bids + 1] = { job = "economy", n = sit.crew, value = 3, key = "planStock" }
    elseif act == "armup" then
        if sit.ammo >= 1 or days >= (step.days or 7) then return nextStep() end
        s.want = { "ammo" }
    elseif act == "envoy" then
        if plan.runId == nil and not plan.radioed then
            local ok = fn(BR, "envoyBid") and BR.envoyBid(b, bids, plan.target, step.goal, 4)
            -- the radio answers at once (no run): straight to the answer step
            if ok == true and type(s.answers) == "table" and s.answers[plan.target] then plan.radioed = true; return nextStep() end
            for _, x in ipairs(bids) do if x.tool == "envoy" then x.onStart = function() plan.envoyOut = true end end end
        end
        if plan.runId ~= nil or plan.envoyOut then return nextStep() end
        if days >= 4 then return BR.planAbort(b, "gone", h) end
    elseif act == "answer" then
        local a = type(s.answers) == "table" and s.answers[plan.target] or nil
        if a ~= nil and (plan.runDone ~= nil or plan.radioed or plan.runId == nil) then
            plan.answer = a
            s.answers[plan.target] = nil
            if a == "paid" or a == "peace" or a == "allied" then return planDone(b, true, h) end
            return nextStep()
        end
        if days >= (step.days or 3) then plan.answer = "refused"; return nextStep() end
    elseif act == "war" then
        if step.ifRefused and plan.answer ~= "refused" then return planDone(b, true, h) end
        if plan.runDone ~= nil then return planDone(b, plan.runDone.won == true, h) end
        if plan.runId == nil then
            plan.wantWar, plan.goal = true, step.goal
            if days >= 7 then return BR.planAbort(b, "fear", h) end
        end
    elseif act == "build" then
        if b.stage == "fortified" or days >= (step.days or 10) then return planDone(b, b.stage == "fortified", h) end
        bids[#bids + 1] = { job = "build", n = 2, value = 3.5, key = "planBuild", force = true }
    elseif act == "outpost" then
        bids[#bids + 1] = { call = "outpost", farOnly = true }
        return planDone(b, true, h)
    end
end
