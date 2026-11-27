-- A-Life NPC Overhaul pre-1.0: CAMP ROLES x JEEM JOBS (player request, Ruse). Our camp roles ran beside Jeem's jobs
-- and shifts without looking at them: a Jeem resident did our role work in the middle of Jeem's Work or Guard shift,
-- and our Farmer and Jeem's farmer job both tended the same plants.
--  * SHIFTS (campJeemShifts): a Jeem resident does our role work (patrol, meals, armory, farm duty, haul & sort) only
--    while Jeem has them free: Jeem's Shifts.busy says no (not asleep, not on a post, on a Free shift, not called
--    soon). Give them Free shifts on Jeem's Schedule tab for their camp role. The bitten still go to quarantine and
--    the night watch you picked still stands it (you chose them by name).
--  * ONE FARMER (campJeemFarm): our Farmer = Jeem's farmer job. Making a Jeem resident our Farmer sets their Jeem job
--    to farmer (Manage.setJob; if the base can't run it, e.g. no food store, our farm duty does it instead); another
--    role clears it. A Jeem farmer shows as our Farmer. Jeem tends their plants (Farmer.lua), our farm duty skips them.
--  * Settlers and camps without Jeem: unchanged.
-- Jeem (3806944055) read in 42/media/lua/server/ProjectALifeJimmy/Features/Residents: Shifts.lua Sh.busy(base, record,
-- nowH) (= Roster.busy), R.shifts = Sh; Roster.lua Ro.roleOf(record) -> { k = "worker", job }; Manage.lua M.jobs.farmer,
-- R.manage.setJob(player, uid, job|nil) -> true | nil, why; J.BaseAreas.base(id), J.worldHours(). Server side (world).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpSetRole) ~= "function" then return end
ALifeCampJeem = ALifeCampJeem or {}
local CJ = ALifeCampJeem
local TAG = "[ALifeCampJeem]"
CJ.VERSION = ALifeSide.MOD_VERSION
CJ.DEFAULTS = { campJeemShifts = true, campJeemFarm = true }
CJ.stats = { gated = 0, synced = 0, cleared = 0, refused = 0 }
-- new setting keys go in fileKeys at load (CLAUDE.md rule 2)
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(CJ.DEFAULTS) do
            if M.settings[k] == nil then M.settings[k] = v end
            if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end
local function setting(k)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[k] end
    if v == nil then v = CJ.DEFAULTS[k] end
    return v
end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) if M.log then M.log("campjeem: " .. tostring(msg)) else print(TAG .. " " .. tostring(msg)) end end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function R() local j = J(); return j and type(j.Residents) == "table" and j.Residents or nil end

-- their A-Life record and Jeem resident row, or nil (not a Jeem resident)
function CJ.resident(uid)
    local rec = nil
    pcall(function() rec = ProjectALife.ActorRegistry.read(tostring(uid)) end)
    local res = type(rec) == "table" and type(rec.memory) == "table" and rec.memory.jimmyResident or nil
    if type(res) ~= "table" then return nil end
    return rec, res
end
function CJ.baseOf(res)
    local j = J()
    if j == nil or not fn(j.BaseAreas, "base") then return nil end
    local ok, b = pcall(j.BaseAreas.base, res.baseId)
    return ok and type(b) == "table" and b or nil
end
-- their Jeem job (schedule mode: the Worker role's job; old mode: the resident's job), or nil
function CJ.jobOf(uid)
    local rec, res = CJ.resident(uid)
    if rec == nil then return nil end
    local r = R()
    local Ro = r and r.roster or nil
    if fn(Ro, "roleOf") then
        local ok, role = pcall(Ro.roleOf, rec)
        if ok and type(role) == "table" then return role.k == "worker" and role.job or nil end
    end
    return type(res.job) == "string" and res.job or nil
end
-- Jeem has them busy now (asleep, on a post, on a Work / Guard / Train shift, called soon)
function CJ.busy(uid)
    if setting("campJeemShifts") == false then return false end
    local rec, res = CJ.resident(uid)
    if rec == nil then return false end
    local r, j = R(), J()
    local Sh = r and r.shifts or nil
    if not fn(Sh, "busy") then return false end
    local base = CJ.baseOf(res)
    if base == nil then return false end
    local nowH = nil
    if fn(j, "worldHours") then pcall(function() nowH = j.worldHours() end) end
    local ok, yes = pcall(Sh.busy, base, rec, nowH)
    return ok and yes == true
end
-- set / clear their Jeem job (true when Jeem took it)
function CJ.setJob(uid, job, player)
    local r = R()
    local Mg = r and r.manage or nil
    if not fn(Mg, "setJob") then return false, "no_jeem" end
    player = player or (fn(M, "homePlayer") and M.homePlayer() or nil)
    if player == nil then return false, "no_player" end
    local ok, done, why = pcall(Mg.setJob, player, tostring(uid), job)
    if ok and done == true then return true end
    return false, ok and why or "error"
end

function CJ.install()
    if M._cjInstalled then return true end
    M._cjInstalled = true
    -- shifts: M.cpPick asks after the urgent plug-ins and the night watch
    M.cpJeemBusy = function(uid)
        local yes = CJ.busy(uid)
        if yes then CJ.stats.gated = CJ.stats.gated + 1 end
        return yes
    end
    -- one farmer: a Jeem farmer is our Farmer, and Jeem does the tending
    local roleOf = M.cpRoleOf
    M.cpRoleOf = function(uid, ...)
        local role = roleOf(uid, ...)
        if role == "general" and setting("campJeemFarm") ~= false and CJ.jobOf(uid) == "farmer" then return "farmer" end
        return role
    end
    local farm = M.cpFarmJob
    if type(farm) == "function" then
        M.cpFarmJob = function(uid, ...)
            if setting("campJeemFarm") ~= false and CJ.jobOf(uid) == "farmer" then return nil end
            return farm(uid, ...)
        end
    end
    local setRole = M.cpSetRole
    M.cpSetRole = function(uid, role, player, ...)
        local line, took = setRole(uid, role, player, ...)
        if took and setting("campJeemFarm") ~= false and CJ.resident(uid) ~= nil then
            local job = CJ.jobOf(uid)
            if role == "farmer" and job ~= "farmer" then
                local ok, why = CJ.setJob(uid, "farmer", player)
                if ok then CJ.stats.synced = CJ.stats.synced + 1; log(tostring(uid) .. ": Jeem job farmer too")
                else CJ.stats.refused = CJ.stats.refused + 1; log(tostring(uid) .. ": Jeem won't take farmer (" .. tostring(why) .. "), our farm duty does it") end
            elseif role ~= "farmer" and job == "farmer" then
                if CJ.setJob(uid, nil, player) then CJ.stats.cleared = CJ.stats.cleared + 1 end
            end
        end
        return line, took
    end
    return true
end

function CJ.rows()
    if type(M.settingRows) ~= "table" then return end
    local have = {}
    for _, r in ipairs(M.settingRows) do have[r[1]] = true end
    for _, r in ipairs({
        { "campJeemShifts", "Jeem: camp roles only work while Jeem's schedule has them free (give them Free shifts for their role)" },
        { "campJeemFarm", "Jeem: our Farmer and Jeem's farmer job are one job (Jeem does the tending)" },
    }) do
        if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
        if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Your camp and base" end
    end
end

pcall(CJ.install)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(CJ.install)
        pcall(CJ.rows)
        print(TAG .. " ready v" .. tostring(CJ.VERSION) .. ": camp roles follow Jeem (shifts " .. (setting("campJeemShifts") ~= false and "on" or "off")
            .. ", one farmer " .. (setting("campJeemFarm") ~= false and "on" or "off") .. ", Jeem " .. (R() and "found" or "not here") .. ")")
    end)
end
return CJ
