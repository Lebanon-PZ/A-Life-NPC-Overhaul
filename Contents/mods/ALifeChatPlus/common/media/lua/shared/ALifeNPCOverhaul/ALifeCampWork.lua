-- A-Life NPC Overhaul 0.8.8: CAMP WORK BY WORD (server side).
-- Tell one of your base's people what to do and they do it, through Jeem's own job and watch system (never a copy):
--   * jobs: woodcutter, carpenter, branches, twigs, stones, quartermaster, farmer -> J.Residents.manage.setJob(player, uid, job)
--     (nil = back to the guard / all-rounder default). Jeem checks the base can run it (materials store, woodlot, drop box,
--     food store) and that you run the base; the schedule mode turns it into a Worker role itself.
--   * watches: day / evening / night / auto -> J.Residents.manage.setShift(player, uid, shift).
-- Read in Jeem (3806944055) server/ProjectALifeJimmy/Features/Residents/Manage.lua: M.jobs, M.jobOk, M.setJob, M.setShift,
-- managed() (resident of a base this player manages: "not_resident" / "not_yours"), why codes no_material_store,
-- no_woodlot, no_dropbox, no_food_store, unknown_job, unknown_shift, moving. R.manage = M (J.Residents.manage).
-- Answer to the client: "campWorkDone" { uid, ok, why, job, shift } (the person says yes, or why not, in their own words:
-- client ALifeTalk_Settlement).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeCampWork") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)
require "ALifeNPCOverhaul/ALifeCmd"

ALifeCampWork = ALifeCampWork or {}
local W = ALifeCampWork
local TAG = "[ALifeCampWork]"
W.VERSION = "0.8.8"
W.DEFAULTS = { campWork = true }
W.KEYS = { "campWork" }
W.JOBS = { woodcutter = true, carpenter = true, branches = true, twigs = true, stones = true, quartermaster = true, farmer = true }
W.SHIFTS = { day = true, evening = true, night = true, auto = true }
W.metrics = W.metrics or { asked = 0, done = 0, refused = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
function W.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = W.DEFAULTS[key] end
    return v
end
function W.on() return W.setting("campWork") ~= false end
function W.manage()
    local j = J()
    local R = j and j.Residents or nil
    return type(R) == "table" and type(R.manage) == "table" and R.manage or nil
end

-- args { uid, job = id | "none" } or { uid, shift = day|evening|night|auto }. Returns ok, why.
function W.apply(player, args)
    if not W.on() then return nil, "off" end
    if type(args) ~= "table" or type(args.uid) ~= "string" or args.uid == "" then return nil, "args" end
    local Mg = W.manage()
    if Mg == nil then return nil, "nojeem" end
    W.metrics.asked = W.metrics.asked + 1
    local ok, a, b
    if type(args.job) == "string" then
        local job = args.job
        if job == "none" then job = nil elseif not W.JOBS[job] then return nil, "unknown_job" end
        if not fn(Mg, "setJob") then return nil, "nojeem" end
        ok, a, b = pcall(Mg.setJob, player, args.uid, job)
    elseif type(args.shift) == "string" then
        if not W.SHIFTS[args.shift] then return nil, "unknown_shift" end
        if not fn(Mg, "setShift") then return nil, "nojeem" end
        ok, a, b = pcall(Mg.setShift, player, args.uid, args.shift)
    else
        return nil, "args"
    end
    if not ok then log("Jeem refused with an error: " .. tostring(a)); return nil, "error" end
    if a then W.metrics.done = W.metrics.done + 1; return true end
    W.metrics.refused = W.metrics.refused + 1
    return nil, b or "refused"
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("campWork", function(player, args)
        local ok, why = W.apply(player, args)
        if type(args) == "table" and type(args.uid) == "string" then
            ALifeCmd.reply(player, "campWorkDone", { uid = args.uid, ok = ok == true, why = why,
                job = type(args.job) == "string" and args.job or nil, shift = type(args.shift) == "string" and args.shift or nil })
        end
        return ok and "ok" or tostring(why)
    end)
end

if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        log("ready v" .. W.VERSION .. ": camp work by word (" .. (W.manage() and "Jeem jobs found" or "Jeem jobs not found here")
            .. ", " .. (W.on() and "on" or "off") .. ")")
    end)
end
