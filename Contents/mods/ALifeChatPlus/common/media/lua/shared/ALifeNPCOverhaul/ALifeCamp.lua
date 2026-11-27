-- A-Life NPC Overhaul pre-1.0: ONE CAMP, JEEM IS THE MASTER (docs/PLAN-JEEM-MERGE.md). World side (SP / MP server).
-- Jeem (3806944055) is required. Our camp no longer keeps its own people list: whoever lives at your camp is a Jeem
-- resident of a base you run.
--   * The base: your first Jeem base. None yet: one is made for you around A-Life's house (main + quarters, the house
--     box clamped to Jeem's side limit) the first time camp needs it; redraw it in Jeem's Base tab.
--   * Joining: "live at my base" (M.settleApply) = Jeem R.recruit with its refugee path (exactly this person, no
--     standing check or cost). Jeem refuses (base full ...): they don't move in and say why.
--   * Old saves: every settler (bucket "settlers") is moved into your Jeem base once, the first time this runs; who
--     can't be moved stays a settler and is tried again each day.
--   * Beds (Joe): joining never waits for a bed, they sleep rough (Jeem jimmyResident.rough). Rough every day = trust
--     down (campRoughTrust). They go looking for a bed themselves (Jeem Scavenger role while rough, their old role
--     back after); a sleeping bag / tent / mattress that comes home on a real trip = a priority card: set it up in the
--     quarters. Given a bed: trust up (campBedTrust). campRoughWarnDays = a priority card; campRoughDays (14) = they
--     leave, campRivalPct of them to an unfriendly group near you (who now knows where your camp is).
-- One adapter: other files ask ALifeCamp (people, base, bed), never Jeem directly for camp membership.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeCamp")
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
local K = ALifeCampKit
ALifeCamp = ALifeCamp or {}
local C = ALifeCamp
local TAG = "[ALifeCamp]"
C.VERSION = ALifeSide.MOD_VERSION
C.DEFAULTS = {
    campAutoBase = true,     -- no Jeem base yet: make one around A-Life's house
    campRoughTrust = 2,      -- trust lost each day someone sleeps rough
    campBedTrust = 6,        -- trust gained the day they get a bed
    campRoughWarnDays = 7,   -- days rough before a warning card
    campRoughDays = 14,      -- days rough before they leave
    campRivalPct = 30,       -- percent of those who leave that go to an unfriendly group
    campBedHunt = true,      -- people with no bed go scavenging for one (Jeem Scavenger role)
}
K.reg(C.DEFAULTS, {
    { "campAutoBase", "Camp: no Jeem base yet, make one around your house" },
    { "campRoughTrust", "Beds: trust lost each day someone has no bed", { 0, 1, 2, 4 } },
    { "campBedTrust", "Beds: trust gained when they get a bed", { 0, 3, 6, 10 } },
    { "campRoughWarnDays", "Beds: days without a bed before you're warned", { 3, 7, 10 } },
    { "campRoughDays", "Beds: days without a bed before they leave", { 7, 14, 21, 30 } },
    { "campRivalPct", "Beds: share of those who leave that join an unfriendly group (percent)", { 0, 15, 30, 60 } },
    { "campBedHunt", "Beds: people with no bed go scavenging for one" },
}, "Your camp and base")
local function num(k) return K.num(C.DEFAULTS, k) end
local function set(k) return K.set(C.DEFAULTS, k) end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function JR() local j = J(); return j and type(j.Residents) == "table" and j.Residents or nil end
local function JB() local j = J(); return j and type(j.BaseAreas) == "table" and j.BaseAreas or nil end
local function JM() local r = JR(); return r and type(r.manage) == "table" and r.manage or nil end
C.stats = C.stats or { joined = 0, refused = 0, moved = 0, rough = 0, bedded = 0, left = 0, rival = 0, bases = 0, found = 0 }
function C.data()
    local d = K.bucket("campMerge")
    for _, k in ipairs({ "rough", "oldRole", "warned", "roleWork", "modeSet" }) do if type(d[k]) ~= "table" then d[k] = {} end end
    return d
end
function C.ready() return JR() ~= nil and JB() ~= nil and fn(JR(), "recruit") end

----------------------------------------------------------------------------------------------------------------
-- the base
----------------------------------------------------------------------------------------------------------------
function C.who(player)
    local B = JB()
    if B == nil or not fn(B, "who") then return nil end
    local ok, w = pcall(B.who, player)
    return ok and type(w) == "table" and w or nil
end
function C.bases(player)
    local B, w = JB(), C.who(player)
    if w == nil or not fn(B, "basesFor") then return {} end
    local ok, list = pcall(B.basesFor, w.key, w.faction, w.admin)
    return ok and type(list) == "table" and list or {}
end
-- the house A-Life uses for you: x1, y1, x2, y2 (A-Life SafehouseDirector via M.alifeBase), or nil
local function houseBox(player)
    local M = K.M()
    if M == nil or not fn(M, "alifeBase") then return nil end
    local ok, b = pcall(M.alifeBase, player)
    if not ok or type(b) ~= "table" then return nil end
    if tonumber(b.x1) and tonumber(b.x2) then return { x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, name = b.name } end
    if tonumber(b.x) and tonumber(b.y) then return { x1 = b.x - 6, y1 = b.y - 6, x2 = b.x + 6, y2 = b.y + 6, name = b.name } end
    return nil
end
-- your camp's base (Jeem). make: create one around the house when there is none (campAutoBase)
function C.base(player, make)
    local list = C.bases(player)
    if #list > 0 then return list[1] end
    if not make or set("campAutoBase") == false then return nil end
    local B = JB()
    local box = houseBox(player)
    local w = C.who(player)
    if box == nil or w == nil or not fn(B, "createBase") then return nil, "nohouse" end
    local side = 40
    if fn(B, "sideLimit") then local ok, s = pcall(B.sideLimit, nil, w.admin); if ok and tonumber(s) then side = s end end
    local cx, cy = math.floor((box.x1 + box.x2) / 2), math.floor((box.y1 + box.y2) / 2)
    local hw = math.floor(math.min(side, box.x2 - box.x1 + 1) / 2)
    local hh = math.floor(math.min(side, box.y2 - box.y1 + 1) / 2)
    local r = { x1 = cx - hw, y1 = cy - hh, x2 = cx - hw + math.min(side, box.x2 - box.x1 + 1) - 1, y2 = cy - hh + math.min(side, box.y2 - box.y1 + 1) - 1 }
    local ok, base, why = pcall(B.createBase, { name = box.name or "Home", x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, role = "main" }, w)
    if not ok or type(base) ~= "table" then log("couldn't make your base: " .. tostring(ok and why or base)); return nil, ok and why or "error" end
    -- (the house is also the quarters, so Jeem counts the beds in it; unverified in game: a main + quarters on one rect)
    if fn(B, "addArea") then pcall(B.addArea, base.id, { x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, role = "quarters" }, w) end
    C.stats.bases = C.stats.bases + 1
    log("made your Jeem base '" .. tostring(base.name) .. "' around your house")
    K.letter("Your camp is now a Jeem base around your house. Redraw it any time in the Base tab.", 200, 200, 120)
    return base
end

----------------------------------------------------------------------------------------------------------------
-- people (Jeem residents of your bases)
----------------------------------------------------------------------------------------------------------------
function C.resident(uid)
    local r = K.rec(uid)
    local res = r and type(r.memory) == "table" and r.memory.jimmyResident or nil
    if type(res) ~= "table" then return nil end
    return r, res
end
function C.people(player)
    local out = {}
    local R = JR()
    if R == nil or not fn(R, "residents") then return out end
    for _, b in ipairs(C.bases(player)) do
        local ok, list = pcall(R.residents, b.id)
        for _, r in ipairs(ok and type(list) == "table" and list or {}) do out[#out + 1] = tostring(r.uid) end
    end
    return out
end
function C.isMine(uid, player)
    local _, res = C.resident(uid)
    if res == nil then return false end
    for _, b in ipairs(C.bases(player)) do if b.id == res.baseId then return true end end
    return false
end

-- move uid in (Jeem refugee path: exactly them, no standing check or cost). Returns true or nil, why
function C.join(uid, player)
    uid = tostring(uid)
    if C.resident(uid) then return true end
    local R = JR()
    if R == nil or not fn(R, "recruit") then return nil, "nojeem" end
    local base, bwhy = C.base(player, true)
    if base == nil then return nil, bwhy or "no_base" end
    local opts = { refugee = { uids = { uid } } }
    local okC, n, why = pcall(R.recruit, player, uid, base.id, false, { refugee = opts.refugee, check = true })
    if not okC or n == nil then C.stats.refused = C.stats.refused + 1; return nil, okC and why or "error" end
    -- off our old settler anchor first (Jeem retags their home), then in
    local P = K.M() and fn(K.M(), "patch") and K.M().patch() or nil
    if P and fn(P, "unsettle") and K.M().settlerOf and K.M().settlerOf(uid) then pcall(P.unsettle, uid) end
    local ok, got, rwhy = pcall(R.recruit, player, uid, base.id, false, opts)
    if not ok or got == nil then C.stats.refused = C.stats.refused + 1; return nil, ok and rwhy or "error" end
    C.mirror(uid, player)
    C.stats.joined = C.stats.joined + 1
    return true
end

-- the old settler list is a MIRROR of Jeem residents (one source: Jeem). Every settler feature (come with me, morale,
-- grief, the AI's "you live here") keeps working and sees Jeem residents. Entries carry jeem = true.
function C.mirror(uid, player)
    local M = K.M()
    if M == nil or not fn(M, "bucket") then return end
    local r, res = C.resident(uid)
    local s = M.bucket("settlers")
    if res == nil then if type(s[uid]) == "table" and s[uid].jeem then s[uid] = nil end; return end
    local e = type(s[uid]) == "table" and s[uid] or {}
    e.jeem, e.baseId = true, res.baseId
    local B = JB()
    if fn(B, "areasOf") then
        local ok, areas = pcall(B.areasOf, res.baseId)
        local a = ok and type(areas) == "table" and areas[1] or nil
        if a then e.x, e.y, e.z = math.floor((a.x1 + a.x2) / 2), math.floor((a.y1 + a.y2) / 2), 0 end
    end
    e.h = e.h or K.hours()
    if r.memory.jimmyMission ~= nil then e.away = e.away or "mission"
    elseif e.away == "mission" then e.away = nil end
    s[uid] = e
end
function C.sync(player)
    local M = K.M()
    if M == nil or not fn(M, "bucket") then return end
    local mine = {}
    for _, uid in ipairs(C.people(player)) do mine[uid] = true; C.mirror(uid, player) end
    local s = M.bucket("settlers")
    local drop = {}
    for uid, e in pairs(s) do if type(e) == "table" and e.jeem and not mine[tostring(uid)] then drop[#drop + 1] = uid end end
    for _, uid in ipairs(drop) do s[uid] = nil end
end

-- old saves: every settler into the Jeem base (once a day for those that couldn't)
function C.migrate(player)
    local M = K.M()
    if M == nil or not fn(M, "bucket") then return 0 end
    local d = C.data()
    local n, left = 0, 0
    local ids = {}
    for uid, e in pairs(M.bucket("settlers")) do if not (type(e) == "table" and e.jeem) then ids[#ids + 1] = tostring(uid) end end
    table.sort(ids)
    for _, uid in ipairs(ids) do
        local r = K.rec(uid)
        if r == nil or r.lifecycle == "dead" then M.bucket("settlers")[uid] = nil
        elseif C.join(uid, player) then n = n + 1
        else left = left + 1 end
    end
    C.stats.moved = C.stats.moved + n
    if n > 0 and not d.migratedOnce then
        d.migratedOnce = true
        K.card({ id = "campMerge", title = "Your camp is one camp now", default = 1,
            text = n .. " of your people now live at your Jeem base: one list, one schedule, one set of stores. <LINE> <LINE> "
                .. "Everyone needs somewhere to sleep. Anyone without a bed sleeps on the ground, trusts you less every day, and leaves after "
                .. num("campRoughDays") .. " days. A sleeping bag or tent in the quarters is enough.",
            choices = { { label = "Got it", fn = function() end } } }, player)
    end
    if left > 0 then log(left .. " settler(s) couldn't move in yet, trying again tomorrow") end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- the clock: Jeem's 3 shifts are the only schedule (Joe). day 6-14, evening 14-22, night 22-6 (RosterRules.hours)
-- A camp role (Cook, Medic ...) has no Jeem job: its Work shift is a Jeem "free" cell + our tag (roleWork), so Jeem
-- leaves them be and our camp code works them then. Guard is Jeem's guard cell.
----------------------------------------------------------------------------------------------------------------
C.SHIFTS = { "day", "evening", "night" }
function C.shiftAt(hour)
    hour = tonumber(hour) or K.hourOfDay()
    if hour >= 6 and hour < 14 then return "day" elseif hour >= 14 and hour < 22 then return "evening" end
    return "night"
end
function C.baseOf(uid)
    local _, res = C.resident(uid)
    local B = JB()
    if res == nil or not fn(B, "base") then return nil end
    local ok, b = pcall(B.base, res.baseId)
    return ok and b or nil
end
function C.onSchedule(base)
    local Ro = JR() and JR().roster or nil
    if base == nil or not fn(Ro, "on") then return false end
    local ok, on = pcall(Ro.on, base)
    return ok and on == true
end
-- what uid does on a shift, in our words: "sleep" | "work" | "guard" | "free", or nil (no Jeem row)
function C.shiftOf(uid, shift)
    local _, res = C.resident(uid)
    if res == nil or type(res.roster) ~= "table" then return nil end
    local cell = res.roster[shift]
    if type(cell) ~= "table" then return nil end
    if cell.k == "sleep" then return "sleep" end
    if cell.k == "guard" then return "guard" end
    if cell.k == "free" then
        local tag = C.data().roleWork[tostring(uid)]
        return (type(tag) == "table" and tag[shift]) and "work" or "free"
    end
    return "work" -- work, train, trip
end
-- ALifeSchedule asks this: "sleep" | "free" | "work", or nil (not ours to say: no Jeem row)
function C.period(uid, hour)
    local w = C.shiftOf(uid, C.shiftAt(hour))
    if w == nil then return nil end
    if w == "guard" then return "work" end
    return w
end
-- the base runs on the shift schedule (Joe: automatic, once per base, a letter)
function C.scheduleMode(player, base)
    local Mg = JM()
    if base == nil or Mg == nil or not fn(Mg, "setShiftMode") or C.onSchedule(base) then return false end
    local d = C.data()
    local ok, done = pcall(Mg.setShiftMode, player, base.id, 2)
    if ok and done and not d.modeSet[base.id] then
        d.modeSet[base.id] = true
        K.letter((base.name or "Your base") .. " now runs on shifts: day, evening, night. Set who does what when in the Work tab.", 200, 200, 120)
    end
    return ok and done == true
end
-- set uid's shift to kind (sleep / work / guard / free) through Jeem's roster. Returns true or nil, why
function C.setShift(uid, shift, kind, player)
    uid = tostring(uid)
    local okS = false
    for _, sh in ipairs(C.SHIFTS) do if sh == shift then okS = true end end
    if not okS then return nil, "unknown_shift" end
    local base = C.baseOf(uid)
    local Mg = JM()
    if base == nil then return nil, "not_resident" end
    if Mg == nil or not fn(Mg, "setRoster") then return nil, "nojeem" end
    if not C.onSchedule(base) then C.scheduleMode(player, base) end
    local _, res = C.resident(uid)
    local row = { v = 1 }
    local old = type(res.roster) == "table" and res.roster or {}
    for _, sh in ipairs(C.SHIFTS) do
        local c = old[sh]
        row[sh] = type(c) == "table" and c or { k = (sh == "night") and "sleep" or "free" }
    end
    local d = C.data()
    local tag = type(d.roleWork[uid]) == "table" and d.roleWork[uid] or {}
    local jeemJob = nil
    if fn(ALifeCampJeem, "jobOf") then local ok, j = pcall(ALifeCampJeem.jobOf, uid); if ok then jeemJob = j end end
    tag[shift] = nil
    if kind == "sleep" then row[shift] = { k = "sleep" }
    elseif kind == "guard" then row[shift] = { k = "guard" }
    elseif kind == "free" then row[shift] = { k = "free" }
    elseif kind == "work" then
        if jeemJob then row[shift] = { k = "work", job = jeemJob }
        else row[shift] = { k = "free" }; tag[shift] = true end
    else return nil, "unknown_kind" end
    local ok, done, why, errors = pcall(Mg.setRoster, player, base.id, { [uid] = row })
    if not ok then return nil, "error" end
    if not done then
        local e = type(errors) == "table" and errors[uid] or nil
        return nil, (type(e) == "table" and e.a) or why or "refused"
    end
    d.roleWork[uid] = tag
    return true
end

----------------------------------------------------------------------------------------------------------------
-- beds
----------------------------------------------------------------------------------------------------------------
C.BED_ITEMS = { "sleepingbag", "tent", "bedroll", "mattress", "cot" }
function C.isBedItem(fullType)
    local t = string.lower(tostring(fullType or ""))
    for _, w in ipairs(C.BED_ITEMS) do if string.find(t, w, 1, true) then return true end end
    return false
end
-- rough: Jeem knows they have no bed (jimmyResident.rough; a bed = jimmyResident.bed)
function C.rough(uid)
    local _, res = C.resident(uid)
    if res == nil then return false end
    return res.rough == true and type(res.bed) ~= "table"
end
local function setRole(player, uid, role)
    local Mg = JM()
    if Mg == nil or not fn(Mg, "setRole") then return false end
    local ok, done = pcall(Mg.setRole, player, uid, role)
    return ok and done == true
end
-- a rival: an unfriendly group near your camp (their regard for you under 40), nearest first
function C.rival(player)
    local M = K.M()
    if M == nil or not fn(M, "nbActive") then return nil end
    local px, py = K.pos(player)
    local best, bd = nil, nil
    for _, b in ipairs(M.nbActive()) do
        if (tonumber(b.rep) or 50) < 40 and not b.road and tonumber(b.x) then
            local d = px and K.d2(px, py, b.x, b.y) or 0
            if bd == nil or d < bd then best, bd = b, d end
        end
    end
    return best
end
function C.leave(uid, player, why)
    local r = K.rec(uid)
    local R = JR()
    if r == nil or R == nil or not fn(R, "leaveOnTheirOwn") then return false end
    local name = K.first(uid) or "Someone"
    K.say(uid, "I can't keep sleeping in the dirt. I'm done.")
    local ok, done = pcall(R.leaveOnTheirOwn, r, why or "no_bed")
    if not ok or not done then return false end
    C.mirror(uid, player)
    C.stats.left = C.stats.left + 1
    C.data().rough[uid] = nil
    local rival = nil
    if K.chance(num("campRivalPct")) then rival = C.rival(player) end
    if rival then
        local reg = K.PA().ActorRegistry
        local fresh = K.rec(uid)
        if fresh and fn(reg, "update") then
            pcall(reg.update, uid, fresh.revision, function(e)
                e.memory = type(e.memory) == "table" and e.memory or {}
                e.memory.havenId = rival.id
            end)
        end
        -- they know your camp now (B1 knowledge: a first-hand look from someone who lived there)
        if fn(ALifeBrain, "learn") then
            local base = C.base(player)
            local B = JB()
            local x, y = nil, nil
            if base and fn(B, "areasOf") then local a = B.areasOf(base.id)[1]; if a then x, y = (a.x1 + a.x2) / 2, (a.y1 + a.y2) / 2 end end
            pcall(ALifeBrain.learn, rival, "you", { x = x, y = y }, 0.8, "defector", K.hours())
        end
        C.stats.rival = C.stats.rival + 1
        K.hist(uid, "Left your camp for " .. tostring(rival.name) .. ". No bed, no reason to stay.")
        K.card({ id = "campLeft:" .. uid, title = name .. " left for " .. tostring(rival.name), default = 1,
            text = name .. " slept on the ground for too long and walked out. Word is they went over to " .. tostring(rival.name)
                .. ", and they know your camp.", choices = { { label = "Damn", fn = function() end } } }, player)
    else
        K.hist(uid, "Left your camp. No bed, no reason to stay.")
        K.card({ id = "campLeft:" .. uid, title = name .. " left", default = 1,
            text = name .. " slept on the ground for too long and walked out.", choices = { { label = "Damn", fn = function() end } } }, player)
    end
    return true
end
-- once a game day: trust, warnings, leaving, the bed hunt
function C.daily(player)
    local d = C.data()
    local day = K.day()
    if d.day == day then return end
    d.day = day
    pcall(C.migrate, player)
    pcall(C.sync, player)
    for _, b in ipairs(C.bases(player)) do pcall(C.scheduleMode, player, b) end
    local still = {}
    for _, uid in ipairs(C.people(player)) do
        if C.rough(uid) then
            still[uid] = true
            local row = d.rough[uid]
            if type(row) ~= "table" then
                row = { since = day }
                d.rough[uid] = row
                C.stats.rough = C.stats.rough + 1
                if set("campBedHunt") ~= false then
                    local r, res = C.resident(uid)
                    d.oldRole[uid] = type(res.role) == "table" and { k = res.role.k, job = res.role.job } or false
                    if setRole(player, uid, { k = "scavenger" }) then row.hunting = true end
                end
                K.card({ id = "rough:" .. uid, title = (K.first(uid) or "Someone") .. " has no bed", default = 1,
                    text = (K.first(uid) or "They") .. " is sleeping on the ground. " .. (row.hunting and "They'll go out looking for a sleeping bag or a tent themselves. " or "")
                        .. "Put a bed, a sleeping bag or a tent in the quarters and they'll settle in. Every night on the ground they trust you a little less.",
                    choices = { { label = "On it", fn = function() end } } }, player)
            end
            local days = day - (tonumber(row.since) or day)
            if num("campRoughTrust") > 0 then K.opinion(uid, player, -num("campRoughTrust"), "Still no bed") end
            if days >= num("campRoughDays") then
                C.leave(uid, player, "no_bed")
            elseif days >= num("campRoughWarnDays") and not row.warned then
                row.warned = true
                local left = num("campRoughDays") - days
                K.card({ id = "roughWarn:" .. uid, title = (K.first(uid) or "Someone") .. " is fed up", default = 1,
                    text = (K.first(uid) or "They") .. " has slept on the ground for " .. days .. " nights and is talking about leaving. About "
                        .. left .. " more days and they'll go. Even a sleeping bag in the quarters will do.",
                    choices = { { label = "On it", fn = function() end } } }, player)
                K.say(uid, "I'm sleeping in the dirt here. How long is this going to last?")
            end
        end
    end
    -- got a bed: trust up, old role back
    for uid, row in pairs(d.rough) do
        if not still[uid] then
            d.rough[uid] = nil
            if C.resident(uid) then
                C.stats.bedded = C.stats.bedded + 1
                if num("campBedTrust") > 0 then K.opinion(uid, player, num("campBedTrust"), "Gave me a bed") end
                K.say(uid, "A real place to sleep. Thank you. I mean it.")
                if type(row) == "table" and row.hunting then
                    local old = d.oldRole[uid]
                    setRole(player, uid, type(old) == "table" and old or nil)
                end
            end
            d.oldRole[uid] = nil
        end
    end
end
-- a scavenging trip came home (ALifeExpeditions): a bed in the haul while someone sleeps rough = a priority card
function C.onHaul(m, haul)
    local found = nil
    for _, t in ipairs(type(haul) == "table" and haul or {}) do if C.isBedItem(t) then found = t; break end end
    if found == nil then return end
    local player = K.player()
    local roughOne = nil
    for uid in pairs(C.data().rough) do roughOne = roughOne or uid end
    if roughOne == nil then return end
    C.stats.found = C.stats.found + 1
    local what = string.lower(string.gsub(string.gsub(tostring(found), "^.*%.", ""), "_.*$", ""))
    what = (string.find(what, "tent", 1, true) and "a tent") or (string.find(what, "sleeping", 1, true) and "a sleeping bag") or "something to sleep on"
    K.card({ id = "bedFound:" .. roughOne .. ":" .. K.day(), title = "They brought back " .. what, default = 1,
        text = "The scavengers came home with " .. what .. ". It's in the stores. Set it up in the quarters so " .. (K.first(roughOne) or "they")
            .. " can finally sleep properly. They'll remember you did.",
        choices = { { label = "I'll set it up", fn = function() end } } }, player)
end

----------------------------------------------------------------------------------------------------------------
-- storage: Jeem stores are the only stores (Joe). Our haul's drop points are a live view of them: spoiling food to the
-- food stores (fridges first, cpBestDrop as before), everything else to the drop box (Jeem's quartermaster sorts it);
-- no drop box = the store of that kind. Marking a drop point marks a Jeem store; old drop points converted once.
----------------------------------------------------------------------------------------------------------------
C.CAT_KIND = { fresh = "food", cans = "food", meds = "medical", clothes = "clothing", weapons = "weapons", ammo = "ammo",
    tools = "tools", materials = "materials", other = "dropbox" }
local function storesOf(base, kind)
    local B = JB()
    if base == nil or not fn(B, "storesOf") then return {} end
    local ok, list = pcall(B.storesOf, base, kind)
    return ok and type(list) == "table" and list or {}
end
-- cat -> { {x, y, z}, ... } for the camp's base
function C.dropsView(player)
    local base = C.base(player)
    local out = {}
    if base == nil then return out end
    local box = storesOf(base, "dropbox")
    for cat, kind in pairs(C.CAT_KIND) do
        local list = {}
        local src = (cat == "fresh") and storesOf(base, "food") or box
        if #src == 0 then src = storesOf(base, kind) end
        for _, st in ipairs(src) do list[#list + 1] = { x = st.x, y = st.y, z = st.z or 0 } end
        out[cat] = list
    end
    return out
end
function C.markStore(cat, x, y, z, on, player)
    local base, B, w = C.base(player, true), JB(), C.who(player)
    if base == nil or w == nil or not fn(B, "setStore") then return false, "no_base" end
    local kind = C.CAT_KIND[cat] or "dropbox"
    local ok, done, why = pcall(B.setStore, base.id, x, y, z, kind, on ~= false, w)
    if not ok then return false, "error" end
    return done == true, why
end
function C.migrateDrops(player, d)
    if type(d) ~= "table" or type(d.drops) ~= "table" or d.dropsMoved then return 0 end
    local base = C.base(player, true)
    if base == nil then return 0 end
    local n = 0
    for cat, list in pairs(d.drops) do
        for _, p in ipairs(type(list) == "table" and list or {}) do
            if C.markStore(cat, p.x, p.y, p.z, true, player) then n = n + 1 end
        end
    end
    d.dropsMoved = true
    d.oldDrops = d.drops
    if n > 0 then K.letter(n .. " of your drop points are Jeem stores now. Mark stores in the Base tab from here on.", 200, 200, 120) end
    return n
end
function C.installStorage()
    local M = K.M()
    if M == nil or M._alcpCampStores or not fn(M, "cpData") then return false end
    M._alcpCampStores = true
    local cpData = M.cpData
    local cache = { at = -1e9 }
    M.cpData = function(...)
        local d = cpData(...)
        if not C.ready() or ALifeSide.mpClient() then return d end
        local player = K.player()
        if not d.dropsMoved then pcall(C.migrateDrops, player, d) end
        local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
        if cache.view == nil or now - cache.at > 5000 or now < cache.at then
            local ok, v = pcall(C.dropsView, player)
            if ok and type(v) == "table" then cache.view, cache.at = v, now end
        end
        if cache.view then d.drops = cache.view end
        return d
    end
    C.dropsCache = cache
    if fn(M, "cpAddDrop") then
        M.cpAddDrop = function(cat, x, y, z)
            local ok, why = C.markStore(cat, x, y, z, true, K.player())
            cache.at = -1e9
            if not ok then return false, "Jeem won't take that store (" .. tostring(why) .. ")" end
            return true
        end
    end
    if fn(M, "cpRemoveDrop") then
        M.cpRemoveDrop = function(x, y, z)
            local base, B, w = C.base(K.player()), JB(), C.who(K.player())
            if base == nil or not fn(B, "setStore") then return false end
            local ok, done = pcall(B.setStore, base.id, x, y, z, "all", false, w)
            cache.at = -1e9
            return ok and done == true
        end
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- install: settling in = Jeem resident; the daily beat; the haul hook
----------------------------------------------------------------------------------------------------------------
function C.install()
    pcall(C.installStorage)
    local M = K.M()
    if M and fn(M, "settleApply") and not M._alcpCampSettle then
        M._alcpCampSettle = true
        local orig = M.settleApply
        M.settleApply = function(l, player, base, bring, ...)
            if not C.ready() or type(l) ~= "table" or type(l.record) ~= "table" then return orig(l, player, base, bring, ...) end
            local ok, why = C.join(l.record.uid, player)
            if not ok then log("couldn't move " .. tostring(l.record.uid) .. " in: " .. tostring(why)); return false end
            for _, b in ipairs(bring or {}) do pcall(C.join, b.uid, player) end
            if M.keyMem then pcall(M.keyMem, l.record.uid, "settled", "Moved into the newcomer's base") end
            if M.feel then pcall(M.feel, l.record.uid, "hope", 0.4, "a real home again") end
            K.opinion(l.record.uid, player, 3, "You gave them a home")
            return true
        end
    end
    if type(ALifeExpeditions) == "table" then
        ALifeExpeditions.hauls = ALifeExpeditions.hauls or {}
        local have = false
        for _, f in ipairs(ALifeExpeditions.hauls) do if f == C.onHaul then have = true end end
        if not have then table.insert(ALifeExpeditions.hauls, C.onHaul) end
    end
    return true
end
K.hourly(TAG, function(p) if C.ready() then pcall(C.sync, p); C.daily(p) end end)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(C.install)
        log("ready v" .. C.VERSION .. ": one camp (" .. (C.ready() and "Jeem found" or "JEEM MISSING: camp off") .. "), beds: leave after "
            .. num("campRoughDays") .. " days rough")
    end)
end
