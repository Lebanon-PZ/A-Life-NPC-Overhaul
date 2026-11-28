-- A-Life NPC Overhaul pre-1.0: BRAIN JOBS BECOME REAL WORK (Joe Nov 27: "NPCs still doing idle animations, not doing
-- something productive, just wasting time").
-- Why: the brain's allocator (ALifeBrainAlloc) hands each stranger at home a job (guard, economy, build, clear, idle),
-- but for strangers that job was only a label (memory.alcpJob / brain.jobs); what they actually do is A-Life's own
-- activity planner (ProjectALife.ActivityPlanner: scavenge, hunt, fish, forage, fetch water, fortify, patrol, haven
-- rest). The two never met, so groups picked "haven_idle" and stood around while the brain thought they were working.
-- Now: A-Life's planner has a per-group bias hook (Planner.score adds ctx.bias[activity], read in A-Life 42.20 source).
-- We fill it from the brain's jobs for that group's people: food jobs push scavenge / forage / water / hunt / fish,
-- build pushes fortify, guard and clear push patrol, and resting at the haven loses weight by how many have work.
-- A-Life still decides (needs, weather, night, health, its own eligibility); nothing is moved raw, nothing spawned.
-- World side (server in MP). Settings: brainWork (on), brainWorkBias (5, A-Life scores are ~1..10).
require "ALifeNPCOverhaul/AA_Side"
pcall(require, "ALifeNPCOverhaul/ALifeBrain")
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn = BR.fn
local TAG = "[ALifeBrainWork]"

BR.defaults({
    brainWork = true,      -- the brain's home jobs steer what A-Life has its people do (no more standing around)
    brainWorkBias = 5,     -- how hard (A-Life's own activity scores run about 1..10)
})
BR.addRows({
    { "brainWork", "Brain: groups' home jobs become real work (food runs, foraging, patrols, fortifying)" },
    { "brainWorkBias", "Brain: how hard jobs steer what they do", { 2, 5, 8, 12 } },
})

-- brain job -> A-Life activities it pushes (activity ids from A-Life's ActivityCatalog, 42.20)
BR.WORK_PUSH = {
    economy = { "scavenge", "forage", "fetch_water", "hunt", "fish" },
    build = { "fortify" },
    guard = { "patrol_route" },
    clear = { "patrol_route" },
}
BR.WORK_REST = { idle = true, rest = true, lead = true } -- these may rest; everyone else has work

-- uid -> brain job, rebuilt at most every 20 s from the brain's bases
BR.workMap, BR.workMapAt = BR.workMap or {}, -1e12
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
function BR.workJobs()
    local t = now()
    if t - BR.workMapAt < 20000 then return BR.workMap end
    BR.workMapAt = t
    local map = {}
    if fn(M, "nbScan") then
        local ok, scan = pcall(M.nbScan)
        if ok and type(scan) == "table" and type(scan.crews) == "table" then
            for bid in pairs(scan.crews) do
                local b = BR.base(bid)
                local s = type(b) == "table" and type(b.brain) == "table" and b.brain or nil
                if s and type(s.jobs) == "table" and BR.runs(b) then
                    for uid, job in pairs(s.jobs) do map[tostring(uid)] = job end
                end
            end
        end
    end
    BR.workMap = map
    return map
end

-- the bias for one A-Life group, from its members' brain jobs (pure: testable)
function BR.workBias(uids, jobs, weight)
    local n, counts = 0, {}
    for _, uid in ipairs(uids) do
        local j = jobs[tostring(uid)]
        if j ~= nil then n = n + 1; counts[j] = (counts[j] or 0) + 1 end
    end
    if n == 0 then return nil end
    local bias, working = {}, 0
    for job, list in pairs(BR.WORK_PUSH) do
        local c = counts[job] or 0
        if c > 0 then
            working = working + c
            for _, act in ipairs(list) do bias[act] = (bias[act] or 0) + weight * c / n end
        end
    end
    for job, c in pairs(counts) do if not BR.WORK_REST[job] and BR.WORK_PUSH[job] == nil then working = working + c end end
    if working > 0 then bias.haven_idle = (bias.haven_idle or 0) - weight * working / n end
    return bias
end

local function uidsOf(list)
    local out = {}
    for _, m in ipairs(type(list) == "table" and list or {}) do
        local uid = type(m) == "table" and (m.uid or (type(m.record) == "table" and m.record.uid)) or m
        if uid ~= nil then out[#out + 1] = tostring(uid) end
    end
    return out
end
local function addBias(ctx, members)
    if type(ctx) ~= "table" or not BR.on() or not BR.flag("brainWork") then return ctx end
    local b = BR.workBias(uidsOf(members), BR.workJobs(), BR.num("brainWorkBias"))
    if b == nil then return ctx end
    ctx.bias = type(ctx.bias) == "table" and ctx.bias or {}
    for k, v in pairs(b) do ctx.bias[k] = (tonumber(ctx.bias[k]) or 0) + v end
    BR.workMetrics.biased = BR.workMetrics.biased + 1
    return ctx
end
BR.workMetrics = BR.workMetrics or { biased = 0 }

function BR.workInstall()
    local PA = BR.PA()
    local S, P = PA.ActivityService, PA.ActivityPlanner
    local a = K.wrap(S, "loadedContext", "BrainWorkLoaded", function(orig) return function(id, members, ...)
        return addBias(orig(id, members, ...), members)
    end end)
    local b = K.wrap(P, "offlineContext", "BrainWorkOffline", function(orig) return function(squad, ...)
        return addBias(orig(squad, ...), type(squad) == "table" and squad.members or nil)
    end end)
    return a, b
end

local Events = ALifeSide.hooks("world", "ALifeBrainWork")
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local okI, a, b = pcall(BR.workInstall)
        print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": brain jobs steer A-Life's activities (loaded "
            .. tostring(okI and a) .. ", off screen " .. tostring(okI and b) .. ", weight " .. tostring(BR.num("brainWorkBias")) .. ")")
    end)
end
return BR
