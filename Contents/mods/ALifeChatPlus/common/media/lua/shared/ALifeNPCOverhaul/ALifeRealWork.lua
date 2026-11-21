-- A-Life NPC Overhaul pre-1.0: REAL WORK BEFORE POSTS.
-- Why: A-Life asks its behaviour modules in priority order and takes the first answer (ModuleRegistry.evaluate, one
-- "decision" chain for orders + upkeep). Jeem's resident post module (jimmy_resident_post, priority 12) answers for
-- every resident holding their spot, and calls an off-duty one back once they stray past its roam (Mover.lua M.roam,
-- 8 tiles). Our real-work modules sit far behind it (camp 91, ghost build 91, work zones 92), so residents either never
-- got asked or got walked out to a plan and pulled straight back: the build / chop pose with nothing built.
-- What: one module of ours at priority 10.5 (after A-Life's orders at 10 and Jeem's upkeep at 1-9: rest, medic, wounds,
-- captives; before Jeem's day acts at 11 and posts at 12). For a Jeem resident who is free right now it asks our own
-- real-work modules (ghost build, camp jobs, work zones, in that order) and answers only when one of them has real work.
-- No real work: nil, and Jeem places them as before. Nothing of Jeem's is edited or copied (rule 5).
-- Free right now = all of: daytime (realWorkFrom..realWorkTo; at night only the camp's night watcher), no player order,
-- no Jeem mission / errand / task other than rest, not on a guard post, no Jeem job or work shift (Jeem counts a
-- worker's hours wherever they are: pulling them would make the same hours twice), not trading, no day block playing
-- (sleep / meal / relax), no base alarm, not worn out, no threat they see or remember.
-- Read in Jeem (3806944055) shared/ProjectALifeJimmy/Features/Residents: Residents.lua R.residentOf, R.companionAway,
-- R.alarmed, R.spent; Mover.lua M.offDuty, M.dayActsRun, M.stand, M.roam, M.evaluatePost (Perception.lastKnownFor,
-- M.inContact); server Manage.lua tickJobs (hours count while away). A-Life 1.5.1 ModuleRegistry.register / evaluate.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeRealWork") -- pre-1.0 MP: runs where the NPC AI runs
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.settings) ~= "table" then require "ALifeLLMTalk/ALifeLLMTalk_Main" end
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
local K = ALifeCampKit
ALifeRealWork = ALifeRealWork or {}
local W = ALifeRealWork
local TAG = "[ALifeRealWork]"
W.VERSION = ALifeSide.MOD_VERSION
W.ID = "chatplus_realwork"
W.PRIORITY = 10.5
W.DEFAULTS = {
    realWorkFirst = true, -- free residents do our real work (plans, camp jobs, bodies) before Jeem parks them
    realWorkFrom = 7,     -- from this hour
    realWorkTo = 21,      -- until this hour (night: only the night watch)
    realWorkBuilder = true, -- the camp's Builder role: they put down their Jeem job (and pick it back up after)
}
K.reg(W.DEFAULTS, {
    { "realWorkFirst", "Camp: free people do real work (build plans, camp jobs, bodies) before standing at their spot" },
    { "realWorkFrom", "Real work: from this hour", { 5, 6, 7, 8, 9 } },
    { "realWorkTo", "Real work: until this hour", { 18, 19, 20, 21, 22 } },
    { "realWorkBuilder", "Camp: a Builder leaves their Jeem job to build (back to it when they stop being Builder)" },
})
W.metrics = W.metrics or { asks = 0, claims = 0, ghost = 0, camp = 0, zones = 0, skip = {} }
W.held = W.held or {}          -- uid -> which module has them now
W.registered = W.registered or false

local fn = K.fn
local function set(k) return K.set(W.DEFAULTS, k) end
local function num(k) return K.num(W.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
local function jr() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy.Residents or nil end
local function mover() local R = jr(); return R and R.mover or nil end
local function skip(why) W.metrics.skip[why] = (W.metrics.skip[why] or 0) + 1; return false, why end

function W.on() return set("realWorkFirst") ~= false end
function W.daytime(hour)
    local a, b = num("realWorkFrom"), num("realWorkTo")
    hour = tonumber(hour) or K.hourOfDay()
    if a <= b then return hour >= a and hour < b end
    return hour >= a or hour < b
end

-- the camp's Builder role (ALifeTalk_Camp M.cpRoleOf)
function W.isBuilder(uid)
    local M = K.M()
    if not fn(M, "cpRoleOf") then return false end
    local ok, r = pcall(M.cpRoleOf, tostring(uid))
    return ok and r == "builder"
end

----------------------------------------------------------------------------------------------------------------
-- BUILDER = A JOB. Taking the camp's Builder role puts down their Jeem job (Jeem's own Residents.manage.setJob(player,
-- uid, nil): guard duty / All-rounder), so their Jeem hours stop and their day is ours to fill with plans. The old job
-- is kept (camp data builderWas) and given back when they stop being Builder (setJob with it; Jeem may refuse if the
-- base can't run it any more: then they stay on guard duty). Jeem's manage is a server file: SP / server call it here,
-- an MP client sends our "campWork" command (ALifeCampWork, server checks the base is yours).
----------------------------------------------------------------------------------------------------------------
W.JOB_WORDS = { woodcutter = "the axe", carpenter = "the saw", branches = "the branch gathering", twigs = "the twig gathering",
    stones = "the stone gathering", quartermaster = "the sorting", farmer = "the farming" }
local function record(uid)
    local AR = K.PA().ActorRegistry
    if not fn(AR, "read") then return nil end
    local ok, r = pcall(AR.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
-- their Jeem job now: jimmyResident.job, or on Jeem's schedule a Worker role's job
function W.jeemJob(uid)
    local R = jr()
    local r = record(uid)
    local res = (r and R and fn(R, "residentOf")) and R.residentOf(r) or nil
    if type(res) ~= "table" then return nil end
    if type(res.job) == "string" then return res.job end
    if type(res.role) == "table" and res.role.k == "worker" and type(res.role.job) == "string" then return res.role.job end
    return nil
end
-- set (job) or put down (nil) their Jeem job. Returns "done", "sent" or nil, why
function W.setJeemJob(player, uid, job)
    local CW = ALifeCampWork
    local Mg = (type(CW) == "table" and fn(CW, "manage")) and CW.manage() or nil
    if Mg ~= nil and fn(Mg, "setJob") then
        local ok, a, b = pcall(Mg.setJob, player, tostring(uid), job)
        if ok and a then return "done" end
        return nil, ok and (b or "refused") or "error"
    end
    if type(ALifeCmd) == "table" and fn(ALifeCmd, "send") and player ~= nil then
        local ok = pcall(ALifeCmd.send, player, "campWork", { uid = tostring(uid), job = job or "none" })
        if ok then return "sent" end
    end
    return nil, "nojeem"
end
function W.builderWas()
    local M = K.M()
    if not fn(M, "cpData") then return {} end
    local d = M.cpData()
    d.builderWas = type(d.builderWas) == "table" and d.builderWas or {}
    return d.builderWas
end
-- after a role change that took: returns an extra few words for their answer, or nil
function W.onRole(uid, before, role, player)
    if set("realWorkBuilder") == false then return nil end
    uid = tostring(uid)
    if role == "builder" and before ~= "builder" then
        local job = W.jeemJob(uid)
        if job == nil then return nil end
        local done, why = W.setJeemJob(player, uid, nil)
        if done == nil then log("could not put down " .. uid .. "'s Jeem job (" .. tostring(why) .. ")"); return nil end
        W.builderWas()[uid] = job
        W.metrics.builders = (W.metrics.builders or 0) + 1
        return "I'll leave " .. (W.JOB_WORDS[job] or "my old job") .. " for now."
    end
    if before == "builder" and role ~= "builder" then
        local was = W.builderWas()
        local job = was[uid]
        if job == nil then return nil end
        was[uid] = nil
        local done, why = W.setJeemJob(player, uid, job)
        if done == nil then log("could not give " .. uid .. " back their Jeem job " .. tostring(job) .. " (" .. tostring(why) .. ")"); return nil end
        return "Back to " .. (W.JOB_WORDS[job] or "my old job") .. ", then."
    end
    return nil
end
-- wrap M.cpSetRole (after Camp's and Animals' own wraps; again at game start in case a later file wrapped it)
function W.wrapRole()
    local M = K.M()
    if not fn(M, "cpSetRole") or M.cpSetRole == W._roleWrap then return false end
    local base = M.cpSetRole
    W._roleWrap = function(uid, role, player)
        local before = nil
        if fn(M, "cpRoleOf") then local ok, r = pcall(M.cpRoleOf, tostring(uid)); before = ok and r or nil end
        local line, took = base(uid, role, player)
        if took == false then return line, took end
        local ok, extra = pcall(W.onRole, uid, before, role, player)
        if ok and type(extra) == "string" then line = (type(line) == "string" and (line .. " ") or "") .. extra end
        return line, took
    end
    M.cpSetRole = W._roleWrap
    return true
end
W.wrapRole()

-- is this resident free for our work right now? true / false, why
function W.free(actor, shell, context)
    local R = jr()
    if R == nil or not fn(R, "residentOf") then return skip("no_jeem") end
    local res = R.residentOf(actor)
    if type(res) ~= "table" then return skip("not_resident") end
    if fn(R, "companionAway") and R.companionAway(actor) then return skip("away") end
    local m = type(actor.memory) == "table" and actor.memory or {}
    if m.jimmyOrder ~= nil then return skip("order") end
    if m.jimmyMission ~= nil then return skip("mission") end
    if m.jimmyJob ~= nil then return skip("errand") end
    -- a Builder has no Jeem job (put down when they took the role), so Jeem puts them on guard duty: build first
    if m.jimmyTargetHold == true and not W.isBuilder(actor.uid) then return skip("guard") end
    if res.job ~= nil or res.now == "work" then return skip("jeem_job") end
    if res.trading == true then return skip("trading") end
    local task = m.jimmyTask
    if type(task) == "table" and task.kind ~= nil and task.kind ~= "rest" then return skip("task") end
    local Mv = mover()
    if Mv and fn(Mv, "dayActsRun") then
        local ok, yes = pcall(Mv.dayActsRun, actor)
        if ok and yes then return skip("day_block") end
    end
    if fn(R, "alarmed") then local ok, yes = pcall(R.alarmed, actor); if ok and yes then return skip("alarm") end end
    if fn(R, "spent") then local ok, yes = pcall(R.spent, shell); if ok and yes then return skip("spent") end end
    if type(context) == "table" and context.threat ~= nil then return skip("threat") end
    local P = K.PA().Perception
    if fn(P, "lastKnownFor") then
        local ok, last = pcall(P.lastKnownFor, actor, type(context) == "table" and context.now or nil)
        if ok and last ~= nil then return skip("lead") end
    end
    return true
end

-- our real-work modules, asked in this order; each already checks its own rules (plans, tools, materials, alarm)
function W.sources()
    local M, G = K.M(), ALifeGhost
    return {
        { id = "ghost", f = G and G.evaluate or nil, day = true },
        { id = "camp", f = M and M.cpEvaluate or nil, night = true },
        { id = "zones", f = M and M.wzEvaluate or nil, day = true },
    }
end
-- the camp's night watcher (ALifeTalk_Camp M.cpWatcher), else nil
local function watcher()
    local M = K.M()
    if not fn(M, "cpWatcher") then return nil end
    local ok, uid = pcall(M.cpWatcher, K.player())
    return ok and uid ~= nil and tostring(uid) or nil
end

function W.evaluate(actor, shell, context)
    if not W.on() or shell == nil or type(actor) ~= "table" or actor.uid == nil then return nil end
    local uid = tostring(actor.uid)
    W.metrics.asks = W.metrics.asks + 1
    local ok = W.free(actor, shell, context)
    if not ok then W.held[uid] = nil; return nil end
    local day = W.daytime()
    if not day and watcher() ~= uid then W.held[uid] = nil; return nil end
    for _, s in ipairs(W.sources()) do
        if type(s.f) == "function" and ((day and s.day) or s.night) then
            local okE, res = pcall(s.f, actor, shell, context)
            if not okE then
                if not W["err_" .. s.id] then W["err_" .. s.id] = true; log(s.id .. " error (logged once): " .. tostring(res)) end
            elseif res ~= nil then
                if W.held[uid] ~= s.id then
                    -- up from Jeem's sitting pose / out of any act of Jeem's at once, so the walk can start
                    local Mv = mover()
                    if Mv and fn(Mv, "stand") then pcall(Mv.stand, shell) end
                    W.metrics.claims = W.metrics.claims + 1
                end
                W.held[uid] = s.id
                W.metrics[s.id] = (W.metrics[s.id] or 0) + 1
                return res
            end
        end
    end
    W.held[uid] = nil
    return nil
end

function W.register()
    if W.registered then return true end
    local reg = K.PA().ModuleRegistry
    if not fn(reg, "register") then return false end
    local ok, done, why = pcall(reg.register, {
        id = W.ID, label = "NPC Overhaul: real work first",
        summary = "Free residents do the real work at your base (build plans, camp jobs, bodies) before standing at their spot.",
        kind = "orders", priority = W.PRIORITY, defaultEnabled = true,
        evaluate = function(actor, shell, context)
            local ok2, res = pcall(W.evaluate, actor, shell, context)
            if not ok2 then
                if not W.err then W.err = true; log("module error (logged once): " .. tostring(res)) end
                return nil
            end
            return res
        end,
    })
    if not (ok and (done == true or (done == false and tostring(why):find("duplicate", 1, true)))) then
        log("could not register with A-Life: " .. tostring(ok and why or done))
        return false
    end
    -- A-Life only runs a module for an NPC whose behaviour profile lists it (BehaviorProfiles.allows)
    local prof = K.PA().BehaviorProfiles
    local n = 0
    if type(prof) == "table" and type(prof.definitions) == "table" then
        for _, d in ipairs(prof.definitions) do
            if type(d) == "table" and type(d.overlays) == "table" then d.overlays[W.ID] = true; n = n + 1 end
        end
    end
    W.registered = true
    print(TAG .. " ready v" .. W.VERSION .. ": free residents do real work before Jeem's posts (priority " .. W.PRIORITY
        .. ", " .. n .. " profiles, " .. (jr() and "Jeem found" or "no Jeem: idle") .. ", " .. (W.on() and "on" or "off") .. ")")
    return true
end

if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(W.wrapRole); pcall(W.register) end) end
if type(Events) == "table" and Events.EveryOneMinute ~= nil then
    Events.EveryOneMinute.Add(function() if not W.registered then pcall(W.register) end end)
end
