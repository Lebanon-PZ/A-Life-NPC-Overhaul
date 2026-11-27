-- A-Life NPC Overhaul pre-1.0: BRAIN B4, PEOPLE BUDGET (docs/PLAN-BRAIN.md). People are the supply cap.
--  * supply = real living members, minus the leader (stays home), the hurt (rest), and whoever is on the road (a trade
--    run, scout, envoy, war party, a caravan to you: they hold that job for the real road time, both ways).
--  * jobs: economy (food / supplies: A-Life's planner pull + foraging), guard, build, trade, scout, war, recruit, idle.
--    The stance gives each a share; managers bid; the allocator fills by value inside the shares. Reserve rule: never
--    fewer than minGuards on guard nor fewer than minHomePct of people on home jobs (an enemy at the gate = all home).
--  * one caller per tool: while the brain is on, the old daily rolls (trade swaps, middlemen, offers, caravans to
--    you, recruiting, wall rings, raids on paper, outpost founding) only run when the brain starts them.
--  * return-to-pool: a run home, a party wiped, a death -> recount at once (not tomorrow).
--  * jobs are stamped on people (memory.alcpJob) so talk can say "I'm on watch tonight". Loaded people are never
--    yanked: their stamp changes once they're out of sight.
-- Unverified (read ProjectALife Activities on 42.20 copy): A-Life's planner steers whole groups, not one member, so
-- the economy job is a group-level pull (ctx.havenId) and only runs / scouts / war parties are per person.
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, clamp = BR.fn, BR.hours, BR.clamp

BR.JOBS = { "guard", "economy", "build", "recruit", "trade", "scout", "war", "idle" }
BR.AWAY = { trade = true, scout = true, war = true }
BR.JOB_WORDS = { guard = "on watch", economy = "out for food and supplies", build = "working on the walls", recruit = "looking for people to take in",
    trade = "on a trade run", scout = "out scouting", war = "with the war party", idle = "resting at home", lead = "keeping things running", rest = "laid up, healing" }

local function shellOf(uid) local sh = nil; pcall(function() sh = BR.PA().Talk.shellFor(tostring(uid)) end); return sh end
local function hurt(r)
    local m = type(r.memory) == "table" and r.memory or {}
    if type(m.injuries) == "table" and #m.injuries > 0 then return true end
    if type(m.injury) == "table" or m.injury == true then return true end
    local sh = shellOf(r.uid)
    if sh then
        local hp = nil
        pcall(function() hp = sh:getHealth() end)
        if tonumber(hp) and hp * 100 < BR.num("brainHurtPct") then return true end
    end
    return false
end
function BR.jobOfRun(run)
    if type(run) ~= "table" then return "trade" end
    if run.brainJob then return run.brainJob end
    return "trade"
end
-- everyone in the group and where they stand now
function BR.people(b)
    local out = {}
    if not fn(M, "nbScan") then return out, 0 end
    local scan = M.nbScan()
    local runs = type(ALifeTrade) == "table" and fn(ALifeTrade, "store") and ALifeTrade.store().runs or {}
    local real = 0
    for _, r in ipairs((scan.crews or {})[b.id] or {}) do
        if type(r) == "table" and r.lifecycle ~= "dead" and not r.virtual then
            real = real + 1
            local uid = tostring(r.uid)
            local m = type(r.memory) == "table" and r.memory or {}
            local p = { uid = uid, r = r, leader = uid == tostring(b.leader), loaded = shellOf(uid) ~= nil, dormant = r.lifecycle == "dormant", job0 = m.alcpJob }
            if m.alcpRun ~= nil then p.away = BR.jobOfRun(runs[m.alcpRun]); p.run = m.alcpRun
            elseif m.alcpCaravan ~= nil or m.alcpTrip ~= nil or m.jimmyTrader ~= nil then p.away = "trade"
            elseif fn(M, "lvIsAway") and M.lvIsAway(uid) then p.away = "trade"
            elseif m.squadId ~= nil then p.away = "economy" end
            if not p.away then p.hurt = hurt(r) end
            out[#out + 1] = p
        end
    end
    table.sort(out, function(a, c) return a.uid < c.uid end)
    local virtual = math.max(0, (tonumber(b.crewN) or 0) - real)
    return out, virtual
end

-- stamp a job on a person (dormant only: never yank someone you might be watching)
local function stamp(p, job)
    if p.job0 == job then return true end
    if p.loaded then return false end
    local R = BR.PA().ActorRegistry
    if not (fn(R, "read") and fn(R, "update")) then return false end
    local r = R.read(p.uid)
    if r == nil then return false end
    -- a talk-only label: A-Life's transient update (no save snapshot per stamp; it's saved with the next real write).
    -- A-Life returns nil + a reason on failure (ActorRegistry.update / updateTransient, read in 42.20 source)
    local f = function(e) e.memory = type(e.memory) == "table" and e.memory or {}; e.memory.alcpJob = job end
    local ok, res
    if fn(R, "updateTransient") then ok, res = pcall(R.updateTransient, r.uid, r.revision, f, true)
    else ok, res = pcall(R.update, r.uid, r.revision, f) end
    return ok and res ~= nil and res ~= false
end

-- bids = { { job, n, value, tool, target, opts, force } }: fill by value inside the stance's shares
function BR.allocate(b, h, bids)
    local s = BR.of(b)
    local people, virtual = BR.people(b)
    local total = #people + virtual
    local shares = BR.shares(s.stance or "grow")
    local orders = s.orders or {}
    local caps, have = {}, {}
    for _, j in ipairs(BR.JOBS) do caps[j] = math.floor((tonumber(shares[j]) or 0) / 100 * total + 0.5); have[j] = 0 end
    have.economy = virtual -- people of an unseen A-Life squad homed here: they scavenge with their squad
    local pool, prev = {}, {}
    local awayN, homeN = 0, virtual
    s.jobs = {}
    for _, p in ipairs(people) do
        if p.away then have[p.away] = (have[p.away] or 0) + 1; awayN = awayN + 1; s.jobs[p.uid] = p.away; stamp(p, p.away)
        elseif p.leader then homeN = homeN + 1; s.jobs[p.uid] = "lead"; stamp(p, "lead")
        elseif p.hurt then homeN = homeN + 1; s.jobs[p.uid] = "rest"; stamp(p, "rest")
        else homeN = homeN + 1; pool[#pool + 1] = p end
    end
    local homeMin = math.ceil(BR.num("minHomePct") / 100 * total)
    local awayRoom = math.max(0, homeN - homeMin)
    local warRoom = math.max(0, math.floor(BR.num("warPartyMax") / 100 * total) - have.war)
    local gateAt = s.enemyAtGate == true or (type(s.sieged) == "table" and h < (tonumber(s.sieged.untilH) or 0))
    local assign = {}
    -- take n from the pool for a job; prefer people already on it (no reshuffling for nothing)
    local function take(job, n, awayOnly)
        local got = {}
        if n <= 0 then return got end
        for pass = 1, 2 do
            for i = #pool, 1, -1 do
                if #got >= n then break end
                local p = pool[i]
                local fits = (pass == 2 or p.job0 == job) and (not awayOnly or (p.dormant and not p.loaded))
                if fits then got[#got + 1] = p; table.remove(pool, i) end
            end
        end
        for _, p in ipairs(got) do assign[p.uid] = job end
        have[job] = (have[job] or 0) + #got
        return got
    end
    -- an enemy at the gate: everyone at home fights, nobody leaves
    if gateAt then
        take("guard", #pool)
    else
        local gate = math.max(BR.num("minGuards"), tonumber(orders.gate) or 0)
        take("guard", math.min(#pool, gate))
        take("economy", math.max(0, math.ceil(BR.num("brainEconomyFloor") / 100 * total) - have.economy))
        table.sort(bids, function(x, y) if (x.value or 0) ~= (y.value or 0) then return (x.value or 0) > (y.value or 0) end return tostring(x.key or x.job) < tostring(y.key or y.job) end)
        for _, bid in ipairs(bids) do
            local job = bid.job
            local room = (bid.force and math.max(caps[job] or 0, tonumber(bid.n) or 0) or (caps[job] or 0)) - (have[job] or 0)
            local n = math.min(tonumber(bid.n) or 0, room, #pool)
            if BR.AWAY[job] then
                n = math.min(n, awayRoom)
                if job == "war" then n = math.min(n, warRoom) end
                local tool = bid.tool and BR.tools[bid.tool] or nil
                local minP = tool and tonumber(tool.minPeople) or 1
                if tool and n >= minP then
                    local avail = 0
                    for _, p in ipairs(pool) do if p.dormant and not p.loaded then avail = avail + 1 end end
                    n = math.min(n, avail, tonumber(tool.maxPeople) or n)
                    if n >= minP then
                        local got = take(job, n, true)
                        local uids = {}
                        for _, p in ipairs(got) do uids[#uids + 1] = p.uid end
                        local ok = BR.call(bid.tool, b, uids, bid.target, bid.opts)
                        if ok then
                            awayRoom = awayRoom - #got
                            if job == "war" then warRoom = warRoom - #got end
                            for _, p in ipairs(got) do s.jobs[p.uid] = job end
                            bid.started = true
                        else
                            -- the tool didn't go: back in the pool
                            have[job] = have[job] - #got
                            for _, p in ipairs(got) do assign[p.uid] = nil; pool[#pool + 1] = p end
                        end
                    end
                end
            elseif n > 0 then
                take(job, n)
                bid.started = true
            end
        end
        -- leftovers: food first (up to its share), then rest at home (still defends)
        take("economy", math.max(0, (caps.economy or 0) - have.economy))
    end
    take("idle", #pool)
    for uid, job in pairs(assign) do
        s.jobs[uid] = job
        for _, p in ipairs(people) do if p.uid == uid and not BR.AWAY[job] then stamp(p, job) end end
    end
    s.alloc = { total = total, home = homeN, away = awayN, virtual = virtual }
    for _, j in ipairs(BR.JOBS) do s.alloc[j] = have[j] or 0 end
    s.alloc.econFrac = total > 0 and (have.economy or 0) / total or 0
    s.alloc.h = h
    return s.alloc
end

-- how many really defend the place right now (home guards count fully, the rest less)
function BR.defenders(b)
    local s = type(b) == "table" and type(b.brain) == "table" and b.brain or nil
    local a = s and s.alloc or nil
    if type(a) ~= "table" or not tonumber(a.total) then return tonumber(b and b.home) or tonumber(b and b.crewN) or 1 end
    return (a.guard or 0) + (a.idle or 0) + (a.build or 0) + (a.recruit or 0) * 0.5 + (a.economy or 0) * 0.5 + 1
end

----------------------------------------------------------------------------------------------------------------
-- executor gates: every old daily roll asks the brain first (brain off = straight through)
----------------------------------------------------------------------------------------------------------------
local function stanceOf(b) return type(b) == "table" and type(b.brain) == "table" and b.brain.stance or nil end
local function allocOf(b) return type(b) == "table" and type(b.brain) == "table" and type(b.brain.alloc) == "table" and b.brain.alloc or nil end
function BR.gateOpen(id, b)
    if not BR.runs(b) then return true end -- not a group the brain runs: old rules
    return BR.permit(id, b)
end
local function wrapM(name, tool, flag)
    if M._alcpHooks[flag] or not fn(M, name) then return M._alcpHooks[flag] == true end
    M._alcpHooks[flag] = true
    local f = M[name]
    M[name] = function(b, ...)
        if not BR.gateOpen(tool, b) then return nil end
        return f(b, ...)
    end
    return true
end
local function install()
    M._alcpHooks = M._alcpHooks or {}
    local T = ALifeTrade
    wrapM("cvRun", "tradeRun", "brainGateCvRun")          -- the daily swap roll
    wrapM("tpDaily", "postCaravan", "brainGateTp")        -- caravans to your trading post
    wrapM("nbRecruit", "recruit", "brainGateRecruit")      -- taking in loners
    wrapM("dirRaid", "paperRaid", "brainGateRaid")         -- raids on paper (war parties replace them)
    if type(T) == "table" and not T._brainGates then
        T._brainGates = true
        if fn(T, "brokerDay") then local f = T.brokerDay; T.brokerDay = function(b, ...) if not BR.gateOpen("middleman", b) then return nil end; return f(b, ...) end end
        if fn(T, "offerDay") then local f = T.offerDay; T.offerDay = function(b, ...) if not BR.gateOpen("offer", b) then return nil end; return f(b, ...) end end
        -- the people a run takes: the brain's hand when it calls; otherwise never its guards, scouts or fighters
        if fn(M, "cvTravellers") then
            local tr = M.cvTravellers
            M.cvTravellers = function(b, n, ...)
                local list = tr(b, n + 8, ...)
                if not BR.runs(b) then while #list > n do table.remove(list) end; return list end
                local c = BR.calling
                local out = {}
                if type(c) == "table" and c.b == b and type(c.people) == "table" and #c.people > 0 then
                    local want = {}
                    for _, u in ipairs(c.people) do want[tostring(u)] = true end
                    for _, r in ipairs(list) do if want[tostring(r.uid)] and #out < n then out[#out + 1] = r end end
                    return out
                end
                local jobs = type(b.brain) == "table" and b.brain.jobs or {}
                local keepGuards = math.max(0, math.floor(BR.num("minGuards")))
                local guardsLeft = 0
                for _, j in pairs(jobs) do if j == "guard" then guardsLeft = guardsLeft + 1 end end
                for _, r in ipairs(list) do
                    local j = jobs[tostring(r.uid)]
                    local ok = j ~= "scout" and j ~= "war"
                    if j == "guard" then ok = guardsLeft > keepGuards; if ok then guardsLeft = guardsLeft - 1 end end
                    if ok and #out < n then out[#out + 1] = r end
                end
                return out
            end
        end
        -- A-Life's planner pull toward supplies follows the economy share (ctx.havenId = the base)
        if fn(T, "greedBias") then
            local gb = T.greedBias
            T.greedBias = function(id, ctx, ...)
                local v = gb(id, ctx, ...)
                if not BR.on() or type(ctx) ~= "table" or ctx.havenId == nil or not tonumber(v) or v <= 0 then return v end
                local b = BR.base(ctx.havenId)
                local a = allocOf(b)
                if a == nil then return v end
                return v * clamp((tonumber(a.econFrac) or 0.4) / 0.4, 0.5, 1.75)
            end
        end
    end
    -- build pace follows the people on the walls
    if not M._alcpHooks.brainGateBuild and fn(M, "bdCrew") then
        M._alcpHooks.brainGateBuild = true
        local bc = M.bdCrew
        M.bdCrew = function(b, ...)
            local n = bc(b, ...)
            if not BR.runs(b) then return n end
            local a = allocOf(b)
            if a == nil then return n end
            return math.min(tonumber(n) or 0, (a.build or 0) + math.floor((a.idle or 0) / 2))
        end
    end
    -- new wall rings only while they're digging in or growing
    local W = ALifeWalls
    if type(W) == "table" and fn(W, "maybeLayer") and not W._brainGate then
        W._brainGate = true
        local ml = W.maybeLayer
        W.maybeLayer = function(b, ...)
            if BR.runs(b) and stanceOf(b) and stanceOf(b) ~= "secure" and stanceOf(b) ~= "grow" then return false end
            return ml(b, ...)
        end
    end
    -- outposts: founding only when the brain chose to expand (keeping supplied ones goes on)
    if not M._alcpHooks.brainGateOutpost and fn(M, "opFound") then
        M._alcpHooks.brainGateOutpost = true
        local of = M.opFound
        M.opFound = function(b, ...)
            if not BR.gateOpen("outpost", b) then return nil end
            return of(b, ...)
        end
    end
    -- the day's work: food share pulls foraging; a siege stops it
    if not M._alcpHooks.brainGateWork and fn(M, "dirWork") then
        M._alcpHooks.brainGateWork = true
        local dw = M.dirWork
        M.dirWork = function(b, ...)
            local r = dw(b, ...)
            if BR.runs(b) then
                local a = allocOf(b)
                if a then b.forageMul = (tonumber(b.forageMul) or 1) * clamp((tonumber(a.econFrac) or 0.4) / 0.4, 0.6, 1.5) end
                local s = b.brain
                if type(s) == "table" and type(s.sieged) == "table" and hours() < (tonumber(s.sieged.untilH) or 0) then b.forageMul = 0 end
            end
            return r
        end
    end
    return M._alcpHooks.brainGateCvRun == true and M._alcpHooks.brainGateRecruit == true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
