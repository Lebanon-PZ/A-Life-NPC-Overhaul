-- A-Life NPC Overhaul pre-1.0: BRAIN B8, WORDS (docs/PLAN-BRAIN.md). Directive's goals become the readable summary
-- of the brain's plan, so every existing line (talk, Places, Chronicle, the AI) keeps working:
--   day = the main job today ("keep watch", "scrounge up food"), week = the stance / plan ("get even with Ridge",
--   "stock up"), month = the ambition. Brain off: Directive picks its goals exactly as before.
--  * M.brainLine(b): one sentence a member says when asked what's going on (first of the base's recent events).
--  * M.brainWhy(b): stance + plan in words for the AI prompt.
--  * each person's own job ("you're on watch tonight") goes into their talk context.
--  * disagreement: members whose own nature fights the stance sometimes grumble (never changes the order).
--  * no numbers anywhere (rule 6). Dev: M.brainDump(id) prints a group's mind; brainDebug shows it on the Roads map.
require "ALifeNPCOverhaul/ALifeBrain"
require "ALifeNPCOverhaul/ALifeRemote"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, roll = BR.fn, BR.hours, BR.roll

local NEW_WORDS = {
    lockdown = "stay locked down till the trouble moves on", hold = "hold on and keep everyone alive", trade = "trade what they have plenty of",
    expand = "find a second place to hold", dominate = "make the groups around here pay them", avengeyou = "get even with the newcomer",
    tradeday = "run goods to the neighbours", march = "get ready for a fight", plan = "follow through on a plan", recruitday = "look for people to take in",
    steady = "keep things running",
}
local BRAIN_CODES = { lockdown = true, hold = true, trade = true, expand = true, dominate = true, avengeyou = true, plan = true, steady = true }
local function addWords() if type(M.dirGoalWords) == "table" then for k, v in pairs(NEW_WORDS) do if M.dirGoalWords[k] == nil then M.dirGoalWords[k] = v end end end end
addWords()

-- the main job today
function BR.dayCode(b)
    local s = BR.of(b)
    local a = s.alloc or {}
    if s.stance == "survive" and BR.foodDays(b) < 2 then return "forage" end
    local best, bn = "forage", -1
    local order = { { "guard", "guard" }, { "war", "march" }, { "build", b.stage ~= "fortified" and "fortify" or "scout" }, { "trade", "tradeday" },
        { "scout", "scout" }, { "recruit", "recruitday" }, { "economy", "forage" } }
    for _, x in ipairs(order) do
        local n = tonumber(a[x[1]]) or 0
        if x[1] == "guard" and (s.stance == "grow" or s.stance == "trade") then n = n * 0.5 end -- a watch is normal, not the day's work
        if n > bn then best, bn = x[2], n end
    end
    if bn <= 0 then return (tonumber(b.morale) or 50) < 35 and "rest" or "forage" end
    return best
end
-- the week: the stance, or the plan
function BR.weekGoal(b, h)
    local s = BR.of(b)
    local st = s.stance or "grow"
    local plan = s.plan
    if type(plan) == "table" and plan.target and (plan.key == "scoutRaid" or plan.key == "siege" or plan.key == "armsFirst") then
        if plan.target == "you" then return { g = "avengeyou", brain = true } end
        return { g = "avenge", target = plan.target }
    end
    if type(plan) == "table" and BR.planWords then
        local w = BR.planWords(b, plan)
        if w then return { g = "plan", brain = true, words = w } end
    end
    local fd = BR.foodDays(b)
    local g = type(b.goods) == "table" and b.goods or {}
    local stocked = fd >= (tonumber(M.settings.greedStockDays) or 30) -- a goal that's already met would finish again and again
    if st == "survive" then
        if fd < 3 and not stocked then return { g = "stockpile" } end
        if (tonumber(g.ammo) or 0) == 0 then return { g = "ammo" } end
        return { g = "hold", brain = true }
    elseif st == "secure" then
        if b.stage ~= "fortified" then return { g = "finish" } end
        return { g = "lockdown", brain = true }
    elseif st == "grow" then
        if (tonumber(b.crewN) or 1) < ((M.nbCfg and M.nbCfg.memberCap) or 8) and (b.dir and b.dir.creed ~= "closed") then return { g = "grow" } end
        if not stocked then return { g = "stockpile" } end
        return { g = "steady", brain = true }
    elseif st == "trade" then return { g = "trade", brain = true }
    elseif st == "expand" then return { g = "expand", brain = true }
    elseif st == "dominate" then
        local prey = fn(M, "dirPrey") and M.dirPrey(b) or nil
        if prey and b.dir and b.dir.creed ~= "closed" then return { g = "absorb", target = prey.id } end
        return { g = "dominate", brain = true }
    elseif st == "revenge" then
        local to = BR.topGrudge(b, h)
        if to == "you" then return { g = "avengeyou", brain = true } end
        if to and BR.base(to) then return { g = "avenge", target = to } end
        return { g = "lockdown", brain = true }
    end
    if not stocked then return { g = "stockpile" } end
    return { g = "steady", brain = true }
end
local function monthCode(b, h, orig)
    local w = BR.w(b, h)
    if (w.aggression or 1) >= 1.4 and (w.ambition or 1) >= 1.1 then return "rule" end
    if b.dir and b.dir.rule == "faith" then return "flock" end
    if (w.kindness or 1) >= 1.3 and (tonumber(b.crewN) or 1) >= 4 then return "grow8" end
    return orig
end

-- after each manager tick: keep Directive's goals in step with the brain
function BR.wordsAfter(b, h)
    local d = b.dir
    if type(d) ~= "table" then return end
    addWords()
    d.goals = d.goals or {}
    local day = BR.dayCode(b)
    if type(d.goals.day) ~= "table" or d.goals.day.g ~= day then d.goals.day = { g = day, at = h, brain = true } end
    local wk = BR.weekGoal(b, h)
    local cur = d.goals.week
    if type(cur) ~= "table" or cur.g ~= wk.g or cur.target ~= wk.target or (wk.words and cur.words ~= wk.words) then
        local goods = type(b.goods) == "table" and b.goods or {}
        d.goals.week = { g = wk.g, at = h, target = wk.target, crew0 = tonumber(b.crewN) or 1, meds0 = tonumber(goods.meds) or 0, brain = wk.brain, words = wk.words }
    end
end
-- a change of stance, in words (the Chronicle / their talk); never numbers
BR.STANCE_WHY = {
    survive = "Things got bad enough that all that matters now is getting through",
    secure = "They pulled everyone in close and put people on watch",
    grow = "Things are steady enough to think about growing",
    trade = "They've got more than they need of some things and mean to trade it",
    expand = "They're crowded and looking for a second place to hold",
    dominate = "They know they're the strongest around and mean to use it",
    revenge = "They want to get even",
}
function BR.onStance(b, old, new, sit, h)
    local why = BR.STANCE_WHY[new]
    if new == "secure" and sit and sit.threatBy then
        local o = BR.base(sit.threatBy)
        why = "They pulled everyone back after hearing about " .. (sit.threatBy == "you" and "the newcomer" or tostring(o and o.name or "trouble nearby"))
    elseif new == "revenge" and sit and sit.grudgeTo then
        local o = BR.base(sit.grudgeTo)
        local g = BR.of(b).grudges[sit.grudgeTo]
        why = "They want to get even with " .. (sit.grudgeTo == "you" and "the newcomer" or tostring(o and o.name or "the ones who hurt them"))
            .. (type(g) == "table" and g.why and (" - they " .. tostring(g.why)) or "")
    elseif new == "trade" and sit and BR.debtV(b, "you", h) > 0 then
        why = why .. "; they owe the newcomer a good turn"
    end
    if why then BR.event(b, why, "brain") end
    -- the week's goal follows at once
    if type(b.dir) == "table" and type(b.dir.goals) == "table" then b.dir.goals.week = nil end
end

-- one sentence: mood + plan
function BR.line(b, h)
    if not BR.runs(b) or type(b.brain) ~= "table" or b.brain.stance == nil then return nil end
    h = h or hours()
    local s = b.brain
    local plan = s.plan
    local tgt = type(plan) == "table" and plan.target or (s.sit and s.sit.threatBy) or nil
    local name = tgt == "you" and "you" or (BR.base(tgt) and BR.base(tgt).name) or nil
    local st = s.stance
    if st == "secure" then
        if name then return "We're locked down till " .. tostring(name) .. " move on." end
        return "We're keeping our heads down for now."
    elseif st == "survive" then return "We're just trying to get through this."
    elseif st == "revenge" and name then return "We owe " .. tostring(name) .. " for what they did. They'll get it."
    elseif st == "dominate" then
        if name then return "Everyone round here pays us something. " .. tostring(name) .. " will learn that." end
        return "Nobody round here is stronger than us. They'd better remember it."
    elseif st == "trade" then return "We've got more than we need of some things. Time to trade."
    elseif st == "expand" then return "Getting crowded. We're looking for a second place."
    end
    if BR.foodDays(b) < 5 and fn(M, "nbSeason") and M.nbSeason() == "autumn" then return "Stocking up before winter." end
    return "Things are steady. We're building up."
end
M.brainLine = function(b) local ok, l = pcall(BR.line, b); return ok and l or nil end
function BR.why(b, h)
    if not BR.runs(b) or type(b.brain) ~= "table" or b.brain.stance == nil then return nil end
    local s = b.brain
    local parts = { BR.STANCE_WHY[s.stance] or s.stance }
    if type(s.plan) == "table" then local w = BR.planWords(b, s.plan); if w then parts[#parts + 1] = "the plan: " .. w end end
    local to = BR.topGrudge(b, h)
    if to then
        local g = s.grudges[to]
        parts[#parts + 1] = "they hold a grudge against " .. (to == "you" and "the newcomer" or tostring((BR.base(to) or {}).name or "someone")) .. ((type(g) == "table" and g.why) and (" (" .. tostring(g.why) .. ")") or "")
    end
    return table.concat(parts, "; ")
end
M.brainWhy = function(b) local ok, w = pcall(BR.why, b); return ok and w or nil end

-- members whose own nature fights the stance grumble now and then (a small morale nudge, never an order change)
BR.MUTTER = {
    { st = { survive = true, secure = true }, trait = "brave", line = "Hiding again. We should hit them while they're weak." },
    { st = { dominate = true, revenge = true }, trait = "kind", line = "I didn't survive this long to become the thing everyone's scared of." },
    { st = { dominate = true, revenge = true }, trait = "fearful", line = "This is going to get people killed. Us." },
    { st = { trade = true, grow = true }, trait = "paranoid", line = "All these strangers coming and going. Somebody's going to take advantage." },
    { st = { grow = true }, trait = "greedy", line = "Every new mouth eats out of my share." },
}
function BR.mutter(b, uid, h)
    local s = type(b.brain) == "table" and b.brain or nil
    if s == nil or s.stance == nil or not fn(M, "lens") then return nil end
    local ok, l = pcall(M.lens, tostring(uid))
    if not ok or type(l) ~= "table" then return nil end
    for _, m in ipairs(BR.MUTTER) do
        if m.st[s.stance] and (tonumber(l[m.trait]) or 0) >= 0.25 and roll(tostring(uid) .. m.trait .. math.floor(h / 24)) < 0.35 then
            if s.mutterDay ~= math.floor(h / 24) then s.mutterDay = math.floor(h / 24); b.morale = math.max(0, (tonumber(b.morale) or 50) - 1) end
            return m.line
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- debug (dev only): console dump, and a line per group for the Roads map
----------------------------------------------------------------------------------------------------------------
local function r2(v) v = tonumber(v) or 0; return tostring(math.floor(v * 100 + 0.5) / 100) end
local function r0(v) return tostring(math.floor((tonumber(v) or 0) + 0.5)) end
function BR.debugLine(b)
    local s = type(b) == "table" and b.brain or nil
    if type(s) ~= "table" then return nil end
    local a = s.alloc or {}
    local jobs = {}
    for _, j in ipairs(BR.JOBS or {}) do if (a[j] or 0) > 0 then jobs[#jobs + 1] = j .. " " .. a[j] end end
    local plan = type(s.plan) == "table" and (s.plan.key .. " step " .. tostring(s.plan.step) .. (s.plan.target and (" -> " .. tostring(s.plan.target)) or "")) or "no plan"
    return tostring(s.stance) .. ", pressure " .. math.floor(tonumber(s.pressure) or 0) .. ", " .. plan .. ", " .. table.concat(jobs, ", ")
end
function BR.dump(id)
    local b = BR.base(id) or (fn(M, "nbOf") and M.nbOf(id)) or nil
    if b == nil then print(BR.TAG .. " no group " .. tostring(id)); return nil end
    local h = hours()
    local s = BR.of(b)
    local out = { BR.TAG .. " " .. tostring(b.name) .. " (" .. tostring(b.id) .. "): " .. tostring(BR.debugLine(b)) }
    local sc = {}
    for _, k in ipairs(BR.STANCES or {}) do sc[#sc + 1] = k .. " " .. r2((s.scores or {})[k]) end
    out[#out + 1] = "  scores: " .. table.concat(sc, ", ")
    local w = BR.w(b, h)
    local ws = {}
    for _, k in ipairs(BR.WKEYS) do ws[#ws + 1] = k .. " " .. r2(w[k] or 1) end
    out[#out + 1] = "  mind: " .. table.concat(ws, ", ") .. (BR.stainKind(b, h) and (", stain " .. BR.stainKind(b, h)) or "")
    for _, k in ipairs(BR.known(b, h)) do
        out[#out + 1] = "  knows " .. tostring(k.id) .. " (" .. tostring(k.src) .. ", sure " .. r2(k.c) .. "): str " .. r2(k.str)
            .. ", crew " .. tostring(k.crew) .. (k.hostile and ", hostile" or "")
    end
    for _, g in ipairs(BR.sortedKeys(s.grudges)) do out[#out + 1] = "  grudge " .. g .. " " .. r0(BR.grudgeV(b, g, h)) .. " (" .. tostring(s.grudges[g].why) .. ")" end
    for _, l in ipairs(out) do print(l) end
    return out
end
M.brainDump = BR.dump

----------------------------------------------------------------------------------------------------------------
-- hooks: Directive's pickers, goal checks, brief; the talk context
----------------------------------------------------------------------------------------------------------------
local function brainOn(b) return BR.runs(b) and type(b.brain) == "table" and b.brain.stance ~= nil end
local function install()
    M._alcpHooks = M._alcpHooks or {}
    addWords()
    if not M._alcpHooks.brainWords and fn(M, "dirPickDay") and fn(M, "dirPickWeek") and fn(M, "dirPickMonth") and fn(M, "dirCheckGoals") then
        M._alcpHooks.brainWords = true
        local pd, pw, pm, cg = M.dirPickDay, M.dirPickWeek, M.dirPickMonth, M.dirCheckGoals
        M.dirPickDay = function(b, h, ...)
            if not brainOn(b) then return pd(b, h, ...) end
            b.dir.goals.day = { g = BR.dayCode(b), at = h, brain = true }
        end
        M.dirPickWeek = function(b, h, crew, ...)
            if not brainOn(b) then return pw(b, h, crew, ...) end
            pcall(M.dirSpecialize, b, crew) -- still once a week
            local wk = BR.weekGoal(b, h)
            local goods = type(b.goods) == "table" and b.goods or {}
            b.dir.goals.week = { g = wk.g, at = h, target = wk.target, crew0 = tonumber(b.crewN) or 1, meds0 = tonumber(goods.meds) or 0, brain = wk.brain, words = wk.words }
        end
        M.dirPickMonth = function(b, h, ...)
            local r = pm(b, h, ...)
            if brainOn(b) and type(b.dir.goals.month) == "table" then b.dir.goals.month.g = monthCode(b, h, b.dir.goals.month.g) end
            return r
        end
        -- the brain's own week goals run out quietly (no "plans fell through"): the brain reports its own outcomes
        M.dirCheckGoals = function(b, h, ...)
            local w = type(b) == "table" and type(b.dir) == "table" and type(b.dir.goals) == "table" and b.dir.goals.week or nil
            if type(w) == "table" and w.brain and BRAIN_CODES[w.g] and h - (tonumber(w.at) or h) >= ((M.dirCfg and M.dirCfg.weekH) or 168) then b.dir.goals.week = nil end
            return cg(b, h, ...)
        end
    end
    -- goal words for brain codes ("plan" carries its own words)
    if not M._alcpHooks.brainBrief and fn(M, "nbBrief") then
        M._alcpHooks.brainBrief = true
        local brief = M.nbBrief
        M.nbBrief = function(b, h, player, ...)
            local nb = brief(b, h, player, ...)
            if brainOn(b) and type(nb) == "table" then
                pcall(function()
                    local w = b.dir and b.dir.goals and b.dir.goals.week
                    if type(nb.goals) == "table" and type(w) == "table" then
                        if w.g == "plan" and w.words then nb.goals.week = w.words end
                    end
                    local line = BR.line(b, h)
                    if line then
                        nb.events = type(nb.events) == "table" and nb.events or {}
                        table.insert(nb.events, 1, line)
                        while #nb.events > 3 do table.remove(nb.events) end
                    end
                end)
            end
            return nb
        end
    end
    -- their own job, and a grumble now and then, in what they talk about
    if not M._alcpHooks.brainExtras and fn(M, "nbExtras") then
        M._alcpHooks.brainExtras = true
        local ex = M.nbExtras
        M.nbExtras = function(req, player, listener, now, ...)
            local r = ex(req, player, listener, now, ...)
            pcall(function()
                if not BR.on() or type(req) ~= "table" or type(req.npcBase) ~= "table" or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
                local b = fn(M, "nbOfMember") and M.nbOfMember(listener.record) or nil
                if not brainOn(b) then return end
                local uid = tostring(listener.record.uid)
                local job = b.brain.jobs[uid] or (type(listener.record.memory) == "table" and listener.record.memory.alcpJob) or nil
                req.npcBase.goals = type(req.npcBase.goals) == "table" and req.npcBase.goals or {}
                if job and BR.JOB_WORDS and BR.JOB_WORDS[job] then req.npcBase.goals.today = "you're " .. BR.JOB_WORDS[job] .. " today" end
                local m = BR.mutter(b, uid, hours())
                if m then req.npcBase.goals.today = tostring(req.npcBase.goals.today or "") .. " (you don't like how things are going: \"" .. m .. "\")" end
            end)
            return r
        end
    end
    -- dev: the brain beside each group on the Roads map
    local T = ALifeTrade
    if type(T) == "table" and fn(T, "viewGroups") and not T._brainView then
        T._brainView = true
        local vg = T.viewGroups
        T.viewGroups = function(...)
            local rows = vg(...)
            if BR.setting("brainDebug") == true and type(rows) == "table" then
                for _, r in ipairs(rows) do if type(r) == "table" and r.id then local b = BR.base(r.id); r.brain = b and BR.debugLine(b) or nil end end
            end
            return rows
        end
        -- the view was registered by reference: register the wrapped one (MP: built on the server, flat rows)
        if type(ALifeRemote) == "table" and fn(ALifeRemote, "view") then ALifeRemote.view("trGroups", T.viewGroups, {}) end
    end
    return M._alcpHooks.brainWords == true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
pcall(BR.install)
