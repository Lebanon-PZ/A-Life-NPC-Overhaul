-- A-Life NPC Overhaul pre-1.0: SCHEDULES (docs/PLAN-RIM.md #8). Each person at your camp keeps hours.
--   Day    sleep 22-6, work 6-18, free 18-22
--   Night  sleep 8-16, free 16-20, work 20-8   (they take the night watch first)
--   Early  sleep 20-4, work 4-14, free 14-20
--   None   no hours: works whenever there's work (how it was before)
-- Camp > Schedules sets it per person; the camp default is a setting (schedDefault).
--   * Sleep hours: they go to bed (their own bed, ALifeBeds) and sleep (the activity layer's sleep, ALifeLLMTalk_Activity).
--   * Free time: no camp work; dinner, the evening fire and A-Life's own idle life take over.
--   * Urgent jobs (quarantine, sick bay, a breakdown, walking back inside) and the night watch are never held back.
--   * Keeping hours with free time in them leans the camp mood a little better (schedFreeMood).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeSchedule") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeSchedule = ALifeSchedule or {}
local C = ALifeSchedule
local TAG = "[ALifeSchedule]"
C.VERSION = "pre-1.0"
C.DEFAULTS = {
    sched = true,       -- people keep hours (sleep / work / free time)
    schedDefault = 2,   -- the camp's default: 1 none, 2 day, 3 night, 4 early
    schedFreeMood = 1,  -- how much keeping hours with free time helps (camp mood)
    schedBed = true,    -- in sleep hours they go to bed and sleep
}
C.CODES = { "none", "day", "night", "early" }
K.reg(C.DEFAULTS, {
    { "sched", "Camp: people keep hours (sleep, work, free time)" },
    { "schedDefault", "Schedules: the camp's default hours", { 1, 2, 3, 4 }, { "None", "Day", "Night", "Early" } },
    { "schedFreeMood", "Schedules: how much free time helps", { 0, 1, 2, 3 } },
    { "schedBed", "Schedules: in sleep hours they go to bed and sleep" },
}, "Your camp and base")
-- hour ranges [from, to) wrapping midnight
C.PRESETS = {
    day = { label = "Day", sleep = { 22, 6 }, free = { 18, 22 } },
    night = { label = "Night", sleep = { 8, 16 }, free = { 16, 20 } },
    early = { label = "Early", sleep = { 20, 4 }, free = { 14, 20 } },
    none = { label = "None" },
}
C.stats = { held = 0, toBed = 0, slept = 0, watchSwaps = 0 }
-- free time is for these (dinner, the evening fire): not work
C.FREE_OK = { meal = true, evening = true }
local function set(k) return K.set(C.DEFAULTS, k) end
local function num(k) return K.num(C.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function C.on() return set("sched") ~= false end
function C.store() local s = K.bucket("rimSchedule"); s.of = type(s.of) == "table" and s.of or {}; s.tried = type(s.tried) == "table" and s.tried or {}; return s end
function C.presetOf(uid)
    local p = C.store().of[tostring(uid)]
    if C.PRESETS[p or ""] then return p end
    return C.CODES[math.floor(num("schedDefault"))] or "day"
end
local function within(h, r) if r == nil then return false end; local a, b = r[1], r[2]; if a > b then return h >= a or h < b end; return h >= a and h < b end
-- "sleep" | "free" | "work"
function C.period(uid, hour)
    if not C.on() then return "work" end
    local p = C.PRESETS[C.presetOf(uid)]
    if p == nil or p.sleep == nil then return "work" end
    hour = hour or K.hourOfDay()
    if within(hour, p.sleep) then return "sleep" end
    if within(hour, p.free) then return "free" end
    return "work"
end
function C.urgent(j)
    local M = K.M()
    if j.kind == "watch" then return true end
    if string.sub(tostring(j.kind), 1, 4) == "rim_" then return true end
    local def = M.cpKinds and M.cpKinds[j.kind] or nil
    return def ~= nil and (def.order or 0) < 0
end
local function dropJob(j, uid, shell)
    local M = K.M()
    if j.key and M.cpClaims and M.cpClaims[j.key] == tostring(uid) then M.cpClaims[j.key] = nil end
    local def = M.cpKinds and M.cpKinds[j.kind] or nil
    if def and type(def.release) == "function" then pcall(def.release, j, tostring(uid), shell) end
end
-- bedtime: walk to bed, lie down (once per sleep stretch; the activity keeps them there)
C.JOB = {
    kind = "rim_bed", order = -2,
    pick = function(uid, shell, player, b, now)
        if not C.on() or set("schedBed") == false or C.period(uid) ~= "sleep" then return nil end
        local M = K.M()
        uid = tostring(uid)
        if K.fn(M, "cpWatcher") and M.cpWatcher(player) == uid then return nil end
        if type(ALifeBreaks) == "table" and K.fn(ALifeBreaks, "active") and ALifeBreaks.active(uid) then return nil end
        if type(M.activities) == "table" and M.activities[uid] ~= nil then return nil end
        local s = C.store()
        local stretch = math.floor(K.hours())
        if s.tried[uid] ~= nil and stretch - s.tried[uid] < 2 then return nil end -- tried in the last 2 h: let them be
        local spot = nil
        if type(ALifeBeds) == "table" and K.fn(ALifeBeds, "bedOf") then spot = ALifeBeds.bedOf(uid) end
        if spot == nil and K.fn(M, "findBedNear") then
            local ok, bed = pcall(M.findBedNear, { record = K.rec(uid), shell = shell })
            if ok and type(bed) == "table" then spot = bed end
        end
        if spot == nil then
            local x, y, z = K.pos(shell)
            if x == nil then return nil end
            spot = { x = math.floor(x), y = math.floor(y), z = z or 0 }
        end
        C.stats.toBed = C.stats.toBed + 1
        return { key = "bed:" .. uid, spot = { x = spot.x, y = spot.y, z = spot.z or 0 } }
    end,
    spot = function(j) return j.spot end,
    ms = function(j) return 1000 end,
    run = function(j, uid, shell, player)
        local M = K.M()
        C.store().tried[tostring(uid)] = math.floor(K.hours())
        if K.fn(M, "startActivity") then
            local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
            local ok, started = pcall(M.startActivity, { record = K.rec(uid), shell = shell }, "sleep", now)
            if ok and started then C.stats.slept = C.stats.slept + 1 end
        end
        return "done"
    end,
}
function C.hook()
    local M = K.M()
    if M == nil then return 0 end
    local n = 0
    if K.wrap(M, "cpPick", "sched:cpPick", function(orig)
        return function(uid, shell, player, now, ...)
            local j = orig(uid, shell, player, now, ...)
            if j == nil or not C.on() or C.urgent(j) then return j end
            local per = C.period(uid)
            if per == "free" and C.FREE_OK[j.kind] then return j end
            if per ~= "work" then
                dropJob(j, uid, shell)
                C.stats.held = C.stats.held + 1
                return nil
            end
            return j
        end
    end) then n = n + 1 end
    -- the night watch: night shift first (the camp's own pick stays if nobody's on nights)
    if K.wrap(M, "cpWatcher", "sched:cpWatcher", function(orig)
        return function(player, ...)
            local w = orig(player, ...)
            if w == nil or not C.on() or C.presetOf(w) == "night" then return w end
            local d = M.cpData()
            for _, uid in ipairs(K.people(player)) do
                if C.presetOf(uid) == "night" and not (type(ALifeBreaks) == "table" and ALifeBreaks.active(uid)) then
                    d.watcher = uid
                    C.stats.watchSwaps = C.stats.watchSwaps + 1
                    return uid
                end
            end
            return w
        end
    end) then n = n + 1 end
    return n
end
function C.mood(uid)
    if not C.on() then return 0 end
    local p = C.PRESETS[C.presetOf(uid)]
    if p and p.free then return -num("schedFreeMood") end
    return 0
end
function C.menu(child, off, player)
    if not C.on() then return end
    local s = C.store()
    local m = child("Schedules")
    for _, uid in ipairs(K.people(player)) do
        local cur = C.presetOf(uid)
        local im = ISContextMenu:getNew(m)
        m:addSubMenu(m:addOption(K.first(uid) .. " (" .. C.PRESETS[cur].label .. ")"), im)
        for _, id in ipairs({ "day", "night", "early", "none" }) do
            local p = C.PRESETS[id]
            local tip = p.sleep and (" (sleep " .. p.sleep[1] .. "-" .. p.sleep[2] .. ", free " .. p.free[1] .. "-" .. p.free[2] .. ")") or " (works whenever)"
            local o = im:addOption(p.label .. tip, nil, function() K.run("schSet", player, uid, id) end)
            if s.of[uid] == id then off(o, "Already this.") end
        end
        if s.of[uid] ~= nil then im:addOption("Camp default", nil, function() K.run("schSet", player, uid, "default") end) end
    end
end
-- pre-1.0 MP (P4): this menu's write (SP directly; MP on the server as the sender, values checked)
K.act("schSet", function(player, uid, id)
    id = tostring(id)
    if uid == nil or (id ~= "default" and C.PRESETS[id] == nil) then return false end
    C.store().of[tostring(uid)] = id ~= "default" and id or nil
end)
function C.extra(req, player, listener)
    if not C.on() then return nil end
    local uid = listener and listener.record and tostring(listener.record.uid) or nil
    if uid == nil then return nil end
    local per = C.period(uid)
    if per == "sleep" then return "It's your sleeping hours; you're tired." end
    if per == "free" then return "It's your free time; you're off work." end
    return nil
end
function C.install()
    local n = C.hook()
    K.addJob(C.JOB)
    if not C._mood then K.addMood(function(uid) return C.mood(uid) end); C._mood = true end
    if not C._menu then K.addMenu(function(child, off, player) return C.menu(child, off, player) end); C._menu = true end
    if not C._extra then K.addExtra(C.extra); C._extra = true end
    return n
end
pcall(C.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(C.install)
        log("ready v" .. C.VERSION .. ": schedules " .. (C.on() and "on" or "off") .. ", default " .. tostring(C.CODES[math.floor(num("schedDefault"))]) .. " (" .. tostring(ok and n or 0) .. "/2 camp hooks)")
    end)
end
return C
