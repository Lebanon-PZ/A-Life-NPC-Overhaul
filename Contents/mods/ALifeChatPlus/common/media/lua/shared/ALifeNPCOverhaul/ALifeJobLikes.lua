-- A-Life NPC Overhaul pre-1.0: JOB LIKES (docs/PLAN-RIM.md #3). Everyone at your camp likes one or two camp jobs and
-- can't stand one. Picked once per person from who they were (background), who they are (personality) and a bit of
-- plain taste (a stable roll), through the same fit the camp roles use (M.cpFit). Never shown as a list: they say it
-- when you give them the job ("Honestly? I'd like that."), and the AI knows it when you talk.
--   In a job they like: the camp mood treats them better (jobLikeMood) and they're a bit better at it (jobLikeFit %).
--   In a job they hate: worse mood (jobHateMood) and a bit worse at it.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeJobLikes") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeJobLikes = ALifeJobLikes or {}
local L = ALifeJobLikes
local TAG = "[ALifeJobLikes]"
L.VERSION = "pre-1.0"
L.DEFAULTS = {
    jobLikes = true,     -- people like some camp jobs and hate one
    jobLikeMood = 2,     -- how much a liked job lifts them (camp mood, each day)
    jobHateMood = 3,     -- how much a hated job drags them down
    jobLikeFit = 15,     -- % better at a job they like (worse at one they hate)
    jobLikeCue = true,   -- they say so when you give them the job
}
K.reg(L.DEFAULTS, {
    { "jobLikes", "Camp: people like some jobs and hate one (mood, how well they do it)" },
    { "jobLikeMood", "Job likes: how much a liked job lifts them", { 0, 1, 2, 3, 5 } },
    { "jobHateMood", "Job likes: how much a hated job drags them down", { 0, 1, 2, 3, 5, 8 } },
    { "jobLikeFit", "Job likes: % better at a liked job (worse at a hated one)", { 0, 5, 10, 15, 25 } },
    { "jobLikeCue", "Job likes: they say so when you give them the job" },
}, "Your camp and base")
local function set(k) return K.set(L.DEFAULTS, k) end
local function num(k) return K.num(L.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function L.on() return set("jobLikes") ~= false end
function L.store() local s = K.bucket("rimJobLikes"); s.of = type(s.of) == "table" and s.of or {}; return s end

-- the camp jobs (General isn't one)
function L.roles()
    local M = K.M()
    local out = {}
    for _, r in ipairs(M and type(M.cpRoles) == "table" and M.cpRoles or {}) do if r.id ~= "general" then out[#out + 1] = r.id end end
    return out
end
-- { like = { role, role? }, hate = role }: once per person, kept
function L.of(uid)
    uid = tostring(uid)
    local s = L.store()
    local row = s.of[uid]
    if type(row) == "table" and type(row.like) == "table" then return row end
    local M = K.M()
    local roles = L.roles()
    if #roles < 2 then return { like = {} } end
    local scored = {}
    for _, role in ipairs(roles) do
        local f = 1
        if M and K.fn(M, "cpFit") then local ok, v = pcall(M.cpFit, uid, role); if ok and tonumber(v) then f = v end end
        scored[#scored + 1] = { role = role, s = f + (K.hash(uid .. "#like#" .. role) % 100) / 100 * 0.6 }
    end
    table.sort(scored, function(a, b) if a.s ~= b.s then return a.s > b.s end; return a.role < b.role end)
    row = { like = { scored[1].role } }
    if #scored >= 3 and scored[2].s >= 1.3 and K.hash(uid .. "#two") % 2 == 0 then row.like[2] = scored[2].role end
    row.hate = scored[#scored].role
    s.of[uid] = row
    return row
end
function L.feel(uid, role)
    if role == nil or role == "general" or not L.on() then return nil end
    local row = L.of(uid)
    for _, r in ipairs(row.like or {}) do if r == role then return "like" end end
    if row.hate == role then return "hate" end
    return nil
end

-- camp mood (positive = worse)
function L.mood(uid)
    local f = L.feel(uid, K.roleOf(uid))
    if f == "like" then return -num("jobLikeMood") end
    if f == "hate" then return num("jobHateMood") end
    return 0
end
L.SAY_LIKE = { "Honestly? I'd like that.", "Good. That's the kind of work I like.", "Now that I can do happily." }
L.SAY_HATE = { "...Not my favourite thing. But fine.", "Ugh. Of all the jobs.", "If I have to." }
function L.hook()
    local M = K.M()
    if M == nil then return 0 end
    local n = 0
    if K.wrap(M, "cpFit", "likes:cpFit", function(orig)
        return function(uid, role, ...)
            local f = orig(uid, role, ...)
            if type(f) ~= "number" then return f end
            local feel = L.feel(uid, role)
            if feel == "like" then return f * (1 + num("jobLikeFit") / 100) end
            if feel == "hate" then return f * (1 - num("jobLikeFit") / 100) end
            return f
        end
    end) then n = n + 1 end
    if K.wrap(M, "cpSetRole", "likes:cpSetRole", function(orig)
        return function(uid, role, player, ...)
            local line, took = orig(uid, role, player, ...)
            if took ~= false and role ~= "general" and set("jobLikeCue") ~= false and type(line) == "string" then
                local feel = L.feel(uid, role)
                if feel == "like" then line = line .. " " .. L.SAY_LIKE[(K.hash(uid .. role) % #L.SAY_LIKE) + 1]
                elseif feel == "hate" then line = line .. " " .. L.SAY_HATE[(K.hash(uid .. role) % #L.SAY_HATE) + 1] end
            end
            return line, took
        end
    end) then n = n + 1 end
    return n
end
function L.extra(req, player, listener)
    if not L.on() then return nil end
    local uid = listener and listener.record and tostring(listener.record.uid) or nil
    if uid == nil then return nil end
    local M = K.M()
    local row = L.of(uid)
    local lab = function(r) return string.lower(tostring(M and M.cpRoleLabel and M.cpRoleLabel[r] or r)) end
    local likes = {}
    for _, r in ipairs(row.like or {}) do likes[#likes + 1] = lab(r) end
    if #likes == 0 then return nil end
    return "Camp work you enjoy: " .. table.concat(likes, " and ") .. "." .. (row.hate and (" Camp work you can't stand: " .. lab(row.hate) .. ".") or "")
end
function L.install()
    local n = L.hook()
    if not L._mood then K.addMood(function(uid) return L.mood(uid) end); L._mood = true end
    if not L._extra then K.addExtra(L.extra); L._extra = true end
    return n
end
pcall(L.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(L.install)
        log("ready v" .. L.VERSION .. ": job likes " .. (L.on() and "on" or "off") .. " (" .. tostring(ok and n or 0) .. "/2 camp hooks)")
    end)
end
return L
