-- A-Life NPC Overhaul pre-1.0: WORK PRIORITIES + THE CAMP BRAIN (docs/PLAN-WORK.md). World side (SP / MP server).
-- One list of camp work: our camp roles (Cook, Medic, Guard, Builder, Farmer, Shepherd, settlement roles: M.cpRoles)
-- and Jeem's base jobs (woodcutter, carpenter, branches, twigs, stones, quartermaster, farmer: J.Residents.manage.jobs).
-- Everyone does ONE thing (the brain's supply cap): a camp role clears their Jeem job and a Jeem job makes them General.
--   * Priorities per person per work: 1 (first) .. 4 (last), 0 = never. The Work tab sets them.
--   * Direct order from the tab: "do this now" (locks them on it until you let them choose again).
--   * Auto pass every workAutoH game hours (and right after a change): each person in earshot takes their best
--     priority work the base can run (Jeem jobOk) that they didn't refuse today (camp roles: M.cpSetRole may refuse).
--     Without the camp brain only people you gave priorities to are moved; ties go to the work with fewest people.
--   * THE CAMP BRAIN is the real group brain now (One Brain, ALifeBrainYou; dial in the Work tab: Off / Advisor /
--     Run it). On Advisor or Run it it runs everyone in earshot (unset priorities count as 3): the brain's allocator
--     says how many go on guard, food and building (its stance: hungry = food, a threat = guards, walls before winter),
--     this pass picks WHO inside your priorities, nobody piled on one job, a medic once the camp is big enough.
--     Never overrides a "never" or a direct order. Off: only people you gave priorities to move.
--   * Earshot: orders through the tab reach only people within workRange tiles of their base's edge (Jeem resident:
--     their base's marked areas; settler: the A-Life base box). Away on a Jeem mission = out of earshot.
-- MP: one shared co-op camp (like camp roles); the tab calls exposed functions, reads the "wkRows" view.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeWork")
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
local K = ALifeCampKit
ALifeWork = ALifeWork or {}
local W = ALifeWork
local TAG = "[ALifeWork]"
W.VERSION = ALifeSide.MOD_VERSION
W.DEFAULTS = {
    workTab = true,        -- the Work tab and work priorities
    workRange = 100,       -- tiles from the edge of their base an order from the tab still reaches them
    workAutoH = 2,         -- game hours between auto passes (priorities / camp brain)
    workBrainMedicAt = 4,  -- the camp brain wants a medic once the camp has this many people
}
K.reg(W.DEFAULTS, {
    { "workTab", "Work tab: set work priorities and give camp jobs without talking to people" },
    { "workRange", "Work tab: orders reach people this many tiles from their base's edge", { 50, 100, 200, 400 } },
    { "workAutoH", "Work tab: game hours between people picking work by priority", { 1, 2, 4, 8 } },
    { "workBrainMedicAt", "Camp brain: camp size before it wants a medic", { 2, 4, 6, 10 } },
}, "Your camp and base")
local function set(k) return K.set(W.DEFAULTS, k) end
local function num(k) return K.num(W.DEFAULTS, k) end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function JR() local j = J(); return j and type(j.Residents) == "table" and j.Residents or nil end
local function JB() local j = J(); return j and type(j.BaseAreas) == "table" and j.BaseAreas or nil end
local function JM() local r = JR(); return r and type(r.manage) == "table" and r.manage or nil end
local function oneFarmer() local M = K.M(); return type(ALifeCampJeem) == "table" and not (M and type(M.settings) == "table" and M.settings.campJeemFarm == false) end
W.metrics = W.metrics or { passes = 0, moved = 0, refused = 0, orders = 0, far = 0 }

function W.on() return set("workTab") ~= false end

----------------------------------------------------------------------------------------------------------------
-- the work list: camp roles, then Jeem jobs ("j_" + Jeem's id). Jeem's farmer is our Farmer while CampJeem's
-- campJeemFarm is on (one job: ALifeCampJeem), so it isn't listed twice.
----------------------------------------------------------------------------------------------------------------
W.FOOD = { cook = true, farmer = true, shepherd = true, j_farmer = true }
function W.works()
    local out = {}
    local M = K.M()
    for _, r in ipairs(M and type(M.cpRoles) == "table" and M.cpRoles or {}) do
        if r.id ~= "general" then out[#out + 1] = { id = r.id, label = r.label or r.id, kind = "role", role = r.id } end
    end
    local Mg = JM()
    if Mg and type(Mg.jobOrder) == "table" and type(Mg.jobs) == "table" then
        for _, id in ipairs(Mg.jobOrder) do
            local job = Mg.jobs[id]
            if job and not (id == "farmer" and oneFarmer()) then
                local label = nil
                pcall(function() label = job.name end)
                if type(label) ~= "string" or label == "" or string.sub(label, 1, 5) == "IGUI_" then label = string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2) end
                out[#out + 1] = { id = "j_" .. id, label = label, kind = "jeem", job = id }
            end
        end
    end
    return out
end
function W.work(id) for _, w in ipairs(W.works()) do if w.id == id then return w end end return nil end

----------------------------------------------------------------------------------------------------------------
-- saved state: one shared camp (MP co-op, like camp roles)
----------------------------------------------------------------------------------------------------------------
function W.data()
    local d = K.bucket("work")
    for _, k in ipairs({ "prio", "lock", "refused" }) do if type(d[k]) ~= "table" then d[k] = {} end end
    return d
end
-- the camp brain (ALifeBrainYou): its dial, 0 Off / 1 Advisor / 2 Run it
local function BRY() return type(ALifeBrain) == "table" and type(ALifeBrain.youDial) == "function" and ALifeBrain or nil end
function W.dial() local b = BRY(); if b == nil then return 0 end; local ok, v = pcall(b.youDial); return ok and tonumber(v) or 0 end
function W.brainOn() local b = BRY(); return b ~= nil and type(b.on) == "function" and b.on() and W.dial() >= 1 end
-- priority of work w for uid: 0..4, or nil (not set)
function W.prio(uid, w)
    local row = W.data().prio[tostring(uid)]
    local v = type(row) == "table" and tonumber(row[w]) or nil
    return v
end
function W.hasPrio(uid)
    local row = W.data().prio[tostring(uid)]
    if type(row) ~= "table" then return false end
    for _ in pairs(row) do return true end -- (pairs + return: no next() in Kahlua)
    return false
end

----------------------------------------------------------------------------------------------------------------
-- people: settlers + Jeem residents of bases this player runs, not following anyone
----------------------------------------------------------------------------------------------------------------
local function bases(player)
    local B = JB()
    if B == nil or not fn(B, "basesFor") or not fn(B, "who") then return {} end
    local ok, list = pcall(function() local w = B.who(player); return B.basesFor(w.key, w.faction, w.admin) end)
    return ok and type(list) == "table" and list or {}
end
function W.people(player)
    local M = K.M()
    local out, seen = {}, {}
    local function add(uid)
        uid = tostring(uid)
        if seen[uid] then return end
        local r = K.rec(uid)
        if r == nil or r.lifecycle == "dead" then return end
        if M and fn(M, "partyIsMember") then local ok, yes = pcall(M.partyIsMember, uid, player); if ok and yes then return end end
        if M and fn(M, "withPlayer") then local ok, yes = pcall(M.withPlayer, uid, player); if ok and yes then return end end
        seen[uid] = true
        out[#out + 1] = uid
    end
    if M and fn(M, "bucket") then for uid in pairs(M.bucket("settlers")) do add(uid) end end
    local R = JR()
    if R and fn(R, "residents") then
        for _, b in ipairs(bases(player)) do
            local ok, list = pcall(R.residents, b.id)
            for _, r in ipairs(ok and type(list) == "table" and list or {}) do add(r.uid) end
        end
    end
    table.sort(out)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- earshot: tiles from the edge of their base (0 inside), or nil (no base / away on a mission)
----------------------------------------------------------------------------------------------------------------
local function rectDist(x, y, a)
    local x1, y1, x2, y2 = tonumber(a.x1), tonumber(a.y1), tonumber(a.x2), tonumber(a.y2)
    if x1 == nil or y1 == nil or x2 == nil or y2 == nil then return nil end
    local dx = math.max(x1 - x, 0, x - x2)
    local dy = math.max(y1 - y, 0, y - y2)
    return math.sqrt(dx * dx + dy * dy)
end
function W.boxesOf(uid, player)
    local boxes = {}
    local r = K.rec(uid)
    local res = r and type(r.memory) == "table" and r.memory.jimmyResident or nil
    local B = JB()
    if type(res) == "table" and res.baseId ~= nil and B and fn(B, "areasOf") then
        local ok, list = pcall(B.areasOf, res.baseId)
        for _, a in ipairs(ok and type(list) == "table" and list or {}) do boxes[#boxes + 1] = a end
    end
    if #boxes == 0 then local b = K.base(player); if type(b) == "table" and tonumber(b.x1) then boxes[1] = b end end
    return boxes
end
function W.where(uid)
    local sh = K.shell(uid)
    if sh ~= nil then local x, y = K.pos(sh); if x ~= nil then return x, y, true end end
    local r = K.rec(uid)
    if r and tonumber(r.x) and tonumber(r.y) then return tonumber(r.x), tonumber(r.y), false end
    return nil
end
function W.dist(uid, player)
    local r = K.rec(uid)
    if r and type(r.memory) == "table" and r.memory.jimmyMission ~= nil then return nil, "away" end
    local x, y = W.where(uid)
    if x == nil then return nil, "lost" end
    local best = nil
    for _, a in ipairs(W.boxesOf(uid, player)) do
        local d = rectDist(x, y, a)
        if d ~= nil and (best == nil or d < best) then best = d end
    end
    if best == nil then return nil, "nobase" end
    return best
end
function W.inRange(uid, player)
    local d, why = W.dist(uid, player)
    if d == nil then return false, why end
    if d > num("workRange") then return false, "far", d end
    return true, nil, d
end

----------------------------------------------------------------------------------------------------------------
-- what they do now, and giving work
----------------------------------------------------------------------------------------------------------------
function W.jeemJob(uid)
    if fn(ALifeCampJeem, "jobOf") then local ok, j = pcall(ALifeCampJeem.jobOf, uid); if ok and type(j) == "string" then return j end end
    return nil
end
-- work id now ("general" = nothing in particular)
function W.current(uid)
    local j = W.jeemJob(uid)
    if j == "farmer" and oneFarmer() then return "farmer" end
    if j then return "j_" .. j end
    local M = K.M()
    if M and fn(M, "cpRoleOf") then local ok, r = pcall(M.cpRoleOf, uid); if ok and type(r) == "string" and r ~= "general" then return r end end
    return "general"
end
local function jeemBase(uid)
    local r = K.rec(uid)
    local res = r and type(r.memory) == "table" and r.memory.jimmyResident or nil
    local B = JB()
    if type(res) ~= "table" or B == nil or not fn(B, "base") then return nil end
    local ok, b = pcall(B.base, res.baseId)
    return ok and type(b) == "table" and b or nil
end
-- can this person do work w at all (Jeem jobs: Jeem residents of a base that has what the job needs)
function W.can(uid, w)
    if type(w) ~= "table" then return false, "unknown" end
    if w.kind == "role" then return true end
    local base = jeemBase(uid)
    if base == nil then return false, "not_resident" end
    local Mg = JM()
    if Mg == nil or not fn(Mg, "jobOk") then return false, "nojeem" end
    local ok, yes, why = pcall(Mg.jobOk, base, w.job)
    if ok and yes then return true end
    return false, ok and why or "error"
end
-- give uid work id ("general" = nothing in particular). Returns ok, why, line (a camp role's answer)
function W.give(uid, id, player)
    uid = tostring(uid)
    local M = K.M()
    local cur = W.current(uid)
    if cur == id then return true end
    if id == "general" then
        if string.sub(cur, 1, 2) == "j_" and type(ALifeCampWork) == "table" then pcall(ALifeCampWork.apply, player, { uid = uid, job = "none" }) end
        if M and fn(M, "cpSetRole") then pcall(M.cpSetRole, uid, "general", player) end
        return true
    end
    local w = W.work(id)
    local can, why = W.can(uid, w)
    if not can then return false, why end
    if w.kind == "role" then
        if not (M and fn(M, "cpSetRole")) then return false, "nocamp" end
        local ok, line, took = pcall(M.cpSetRole, uid, w.role, player)
        if not ok then return false, "error" end
        if took == false then return false, "refused", line end
        -- (our Farmer: CampJeem sets the Jeem farmer job itself; leave it)
        if string.sub(cur, 1, 2) == "j_" and not (w.role == "farmer" and oneFarmer()) and type(ALifeCampWork) == "table" then pcall(ALifeCampWork.apply, player, { uid = uid, job = "none" }) end
        return true, nil, line
    end
    if type(ALifeCampWork) ~= "table" or not fn(ALifeCampWork, "apply") then return false, "nojeem" end
    local ok, done, jwhy = pcall(ALifeCampWork.apply, player, { uid = uid, job = w.job })
    if not ok then return false, "error" end
    if not done then return false, jwhy or "refused" end
    if M and fn(M, "cpRoleOf") and fn(M, "cpSetRole") then
        local okR, r = pcall(M.cpRoleOf, uid)
        if okR and r ~= "general" then pcall(M.cpSetRole, uid, "general", player) end
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the camp brain: what the camp needs (0..2 per work), from what the camp really has
----------------------------------------------------------------------------------------------------------------
-- what the camp needs (0..2 per work) = the brain's allocator view: how many it wants on guard, food and building.
-- Returns need, word (the brain's one line), targets (nil when the brain doesn't run the camp yet)
function W.needs(player, people)
    local n = #people
    local need = {}
    for _, w in ipairs(W.works()) do need[w.id] = 0.5 end
    local b = BRY()
    local a = b and type(b.youTargets) == "function" and b.youTargets() or nil
    local total = math.max(1, a and tonumber(a.total) or n)
    local food = a and ((tonumber(a.economy) or 0) / total) or 0.4
    for id in pairs(W.FOOD) do if need[id] then need[id] = 0.4 + 1.6 * food end end
    if need.guard then need.guard = (a and (tonumber(a.guard) or 0) > 0) and 1.2 or 0.3 end
    if need.builder then need.builder = (a and (tonumber(a.build) or 0) > 0) and 1.3 or 0.4 end
    if need.medic then need.medic = n >= num("workBrainMedicAt") and 1.1 or 0.2 end
    local word = b and type(b.youLine) == "function" and b.youLine() or nil
    return need, word, a
end
W.WORDS = {
    steady = "Thinking it over.",
    off = "Off. People keep what you gave them; priorities still move the ones you set. Nobody brings you ideas.",
}

----------------------------------------------------------------------------------------------------------------
-- the auto pass
----------------------------------------------------------------------------------------------------------------
local function refusedToday(uid, w)
    local row = W.data().refused[tostring(uid)]
    return type(row) == "table" and row[w] == K.day()
end
local function markRefused(uid, w)
    local d = W.data()
    local row = d.refused[tostring(uid)]
    if type(row) ~= "table" or row.day ~= K.day() then row = { day = K.day() }; d.refused[tostring(uid)] = row end
    row[w] = K.day()
end
-- candidates for uid, best first: { id, p } (p = priority 1..4)
function W.choices(uid, brain)
    local out = {}
    for _, w in ipairs(W.works()) do
        local p = W.prio(uid, w.id)
        if p == nil and brain then p = 3 end
        if p ~= nil and p >= 1 and p <= 4 and not refusedToday(uid, w.id) and W.can(uid, w) then out[#out + 1] = { id = w.id, p = p } end
    end
    return out
end
-- one pass for the camp. Returns people moved.
function W.pass(player, why)
    if not W.on() then return 0 end
    local d = W.data()
    local brain = W.brainOn()
    local people = W.people(player)
    local count = {}
    local cur = {}
    for _, uid in ipairs(people) do cur[uid] = W.current(uid); count[cur[uid]] = (count[cur[uid]] or 0) + 1 end
    local need, word, targets = nil, nil, nil
    if brain then need, word, targets = W.needs(player, people) end
    -- guards first (camp brain): as many on guard as the brain's allocator wants, from those who may guard and are in earshot
    local moved = 0
    local todo = {}
    for _, uid in ipairs(people) do
        if d.lock[uid] == nil and (brain or W.hasPrio(uid)) and W.inRange(uid, player) then todo[#todo + 1] = uid end
    end
    -- (no allocation yet: the brain's own reserve rule, minGuards)
    local guards = targets and math.floor(tonumber(targets.guard) or 0) or math.floor(tonumber(BRY() and BRY().num and BRY().num("minGuards")) or 1)
    if brain and need.guard ~= nil then
        local want = guards - (count.guard or 0)
        if want > 0 then
            local cands = {}
            for _, uid in ipairs(todo) do
                local p = W.prio(uid, "guard") or 3
                if cur[uid] ~= "guard" and p >= 1 and not refusedToday(uid, "guard") then cands[#cands + 1] = { uid = uid, p = p } end
            end
            table.sort(cands, function(a, b) if a.p ~= b.p then return a.p < b.p end return a.uid < b.uid end)
            for i = 1, math.min(want, #cands) do
                local uid = cands[i].uid
                local ok, rwhy = W.give(uid, "guard", player)
                if ok then count[cur[uid]] = (count[cur[uid]] or 1) - 1; cur[uid] = "guard"; count.guard = (count.guard or 0) + 1; moved = moved + 1
                elseif rwhy == "refused" then markRefused(uid, "guard"); W.metrics.refused = W.metrics.refused + 1 end
            end
        end
    end
    for _, uid in ipairs(todo) do
        local held = brain and cur[uid] == "guard" and (count.guard or 0) <= guards
        if not held then
            local list = W.choices(uid, brain)
            if #list > 0 then
                local top = list[1].p
                for _, c in ipairs(list) do if c.p < top then top = c.p end end
                local curP = nil
                for _, c in ipairs(list) do if c.id == cur[uid] then curP = c.p end end
                -- keep what they do when it is already in the best tier (no churn)
                if curP ~= top then
                    local best, bs = nil, nil
                    for _, c in ipairs(list) do
                        if c.p == top then
                            local s = -(count[c.id] or 0)
                            if brain then s = (need[c.id] or 0.5) / (1 + (count[c.id] or 0)) end
                            if bs == nil or s > bs then best, bs = c.id, s end
                        end
                    end
                    -- try the best, then the rest of the tier, then lower tiers
                    table.sort(list, function(a, b)
                        if a.id == best then return b.id ~= best end
                        if b.id == best then return false end
                        if a.p ~= b.p then return a.p < b.p end
                        return (count[a.id] or 0) < (count[b.id] or 0)
                    end)
                    for _, c in ipairs(list) do
                        if curP ~= nil and c.p >= curP then break end
                        local ok, rwhy = W.give(uid, c.id, player)
                        if ok then
                            count[cur[uid]] = math.max(0, (count[cur[uid]] or 1) - 1); cur[uid] = c.id; count[c.id] = (count[c.id] or 0) + 1
                            moved = moved + 1
                            break
                        end
                        if rwhy == "refused" then markRefused(uid, c.id); W.metrics.refused = W.metrics.refused + 1 end
                    end
                end
            end
        end
    end
    d.word = word
    d.passH = K.hours()
    W.metrics.passes = W.metrics.passes + 1
    W.metrics.moved = W.metrics.moved + moved
    return moved
end

----------------------------------------------------------------------------------------------------------------
-- the tab's calls (exposed: on an MP client they run on the server as the sender)
----------------------------------------------------------------------------------------------------------------
local M = K.M()
local function okPerson(uid, player)
    uid = tostring(uid or "")
    if uid == "" then return nil, "args" end
    for _, u in ipairs(W.people(player)) do if u == uid then return uid end end
    return nil, "not_yours"
end
-- a change: people pick again now (and the hourly clock restarts)
function W.soon(player)
    local ok, err = pcall(W.pass, player, "change")
    if not ok then log("pass failed: " .. tostring(err)); W.data().dirty = true end
end
local function tell(player, text) if text and fn(ALifeSide, "outToast") then pcall(ALifeSide.outToast, player, text) end end
W.WHY = {
    far = "Too far from the base to hear you.", away = "Away on a mission.", lost = "Nobody knows where they are.",
    nobase = "They have no base to work at.", not_yours = "Not one of your people.", refused = "They won't do that.",
    not_resident = "Only people living at a Jeem base do base jobs.", no_material_store = "The base needs a materials store for that.",
    no_woodlot = "The base needs a woodlot marked for that.", no_dropbox = "The base needs a drop box for that.",
    no_food_store = "The base needs a food store for that.", shifts_off = "Shifts are switched off in Jeem's sandbox options.",
    schedule_off = "The base isn't on the shift schedule yet.", one_sleep = "Everyone needs one sleep shift, and only one.", nojeem = "Base jobs need Jeem's extension.", moving = "They're on the move. Try again in a moment.",
}
function W.whyText(why) return W.WHY[tostring(why)] or "Couldn't." end
-- set a priority (level 0..4, or -1 = clear)
function W.setPrio(uid, id, level, player)
    if not W.on() then return false end
    local u, why = okPerson(uid, player)
    if u == nil then return false, why end
    if W.work(id) == nil then return false, "unknown" end
    local okR, rwhy = W.inRange(u, player)
    if not okR then W.metrics.far = W.metrics.far + 1; tell(player, W.whyText(rwhy)); return false, rwhy end
    level = math.floor(tonumber(level) or -1)
    local d = W.data()
    d.prio[u] = type(d.prio[u]) == "table" and d.prio[u] or {}
    if level < 0 or level > 4 then d.prio[u][id] = nil else d.prio[u][id] = level end
    W.soon(player)
    return true
end
-- "do this now": locks them on it until W.free
function W.order(uid, id, player)
    if not W.on() then return false end
    local u, why = okPerson(uid, player)
    if u == nil then return false, why end
    local okR, rwhy = W.inRange(u, player)
    if not okR then W.metrics.far = W.metrics.far + 1; tell(player, W.whyText(rwhy)); return false, rwhy end
    local ok, gwhy, line = W.give(u, id, player)
    if ok then
        local d = W.data()
        d.lock[u] = id
        W.metrics.orders = W.metrics.orders + 1
        if line then K.say(u, line) end
        return true
    end
    if gwhy == "refused" and line then K.say(u, line) end
    tell(player, (K.first(u) or "They") .. ": " .. W.whyText(gwhy))
    return false, gwhy
end
function W.free(uid, player)
    local u, why = okPerson(uid, player)
    if u == nil then return false, why end
    local okR, rwhy = W.inRange(u, player)
    if not okR then tell(player, W.whyText(rwhy)); return false, rwhy end
    W.data().lock[u] = nil
    W.soon(player)
    return true
end
-- a shift (day / evening / night) through Jeem's roster: kind sleep / work / guard / free (ALifeCamp.setShift)
W.SHIFT_KINDS = { sleep = true, work = true, guard = true, free = true }
function W.setShift(uid, shift, kind, player)
    if not W.on() then return false end
    local u, why = okPerson(uid, player)
    if u == nil then return false, why end
    local okR, rwhy = W.inRange(u, player)
    if not okR then W.metrics.far = W.metrics.far + 1; tell(player, W.whyText(rwhy)); return false, rwhy end
    if not W.SHIFT_KINDS[tostring(kind)] then return false, "unknown" end
    if not fn(ALifeCamp, "setShift") then return false, "nojeem" end
    local ok, done, swhy = pcall(ALifeCamp.setShift, u, tostring(shift), tostring(kind), player)
    if ok and done then return true end
    tell(player, (K.first(u) or "They") .. ": " .. W.whyText(ok and swhy or "error"))
    return false, swhy
end
-- the dial (0 Off / 1 Advisor / 2 Run it); W.setBrain(on) = Advisor / Off (old callers)
function W.setDial(level, player)
    if not W.on() then return false end
    local b = BRY()
    if b == nil or type(b.youSetDial) ~= "function" then return false end
    b.youSetDial(level)
    W.soon(player)
    return true
end
function W.setBrain(on, player) return W.setDial(on == true and 1 or 0, player) end
if type(M) == "table" then
    M.wkPrio = function(uid, id, level, player) return W.setPrio(uid, id, level, player or ALifeSide.you()) end
    M.wkOrder = function(uid, id, player) return W.order(uid, id, player or ALifeSide.you()) end
    M.wkFree = function(uid, player) return W.free(uid, player or ALifeSide.you()) end
    M.wkBrain = function(on, player) return W.setBrain(on, player or ALifeSide.you()) end
    M.wkDial = function(level, player) return W.setDial(level, player or ALifeSide.you()) end
    M.wkShift = function(uid, shift, kind, player) return W.setShift(uid, shift, kind, player or ALifeSide.you()) end
    if type(ALifeRemote) == "table" then
        ALifeRemote.expose("wkPrio", 3, 4)
        ALifeRemote.expose("wkOrder", 2, 3)
        ALifeRemote.expose("wkFree", 1, 2)
        ALifeRemote.expose("wkBrain", 1, 2)
        ALifeRemote.expose("wkDial", 1, 2)
        ALifeRemote.expose("wkShift", 3, 4)
    end
end

----------------------------------------------------------------------------------------------------------------
-- the view: flat rows (ALifeCmd depth 3: priorities as one digit per work, in the head row's order)
----------------------------------------------------------------------------------------------------------------
function W.view(player)
    local out = {}
    if not W.on() then return out end
    local d = W.data()
    local works = W.works()
    local ids, labels = {}, {}
    for i, w in ipairs(works) do ids[i] = w.id; labels[i] = w.label end
    local brain = W.brainOn()
    local words = brain and (d.word or W.WORDS.steady) or W.WORDS.off
    out[1] = { k = "head", works = table.concat(ids, "|"), labels = table.concat(labels, "|"), brain = brain, dial = W.dial(),
        words = tostring(words), range = num("workRange") }
    for _, uid in ipairs(W.people(player)) do
        local digits = {}
        for i, w in ipairs(works) do
            local p = W.prio(uid, w.id)
            if not W.can(uid, w) then digits[i] = "x"
            elseif p == nil then digits[i] = brain and "." or "-"
            else digits[i] = tostring(p) end
        end
        local sh = {}
        for i, shift in ipairs({ "day", "evening", "night" }) do
            local k = nil
            if fn(ALifeCamp, "shiftOf") then local okS, v = pcall(ALifeCamp.shiftOf, uid, shift); if okS then k = v end end
            sh[i] = ({ sleep = "S", work = "W", guard = "G", free = "F" })[tostring(k)] or "-"
        end
        local okR, why, dist = W.inRange(uid, player)
        out[#out + 1] = { k = "p", uid = uid, name = K.first(uid) or uid, cur = W.current(uid), prio = table.concat(digits),
            lock = d.lock[uid], near = okR == true, shifts = table.concat(sh), why = (not okR) and W.whyText(why) or nil,
            dist = dist and math.floor(dist) or nil }
    end
    return out
end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "view") then ALifeRemote.view("wkRows", W.view, {}) end

----------------------------------------------------------------------------------------------------------------
-- the clock: a pass every workAutoH hours, or the next hour after a change
----------------------------------------------------------------------------------------------------------------
function W.hourly(player, h)
    if not W.on() then return end
    local d = W.data()
    local every = math.max(1, num("workAutoH"))
    if d.dirty or h - (tonumber(d.passH) or -1e9) >= every then
        d.dirty = false
        W.pass(player, "hour")
    end
end
K.hourly(TAG, function(p, h) W.hourly(p, h) end)

if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        log("ready v" .. W.VERSION .. ": work priorities " .. (W.on() and "on" or "off") .. ", " .. #W.works() .. " kinds of work, camp brain dial "
            .. W.dial() .. ", orders reach " .. num("workRange") .. " tiles past the base")
    end)
end
