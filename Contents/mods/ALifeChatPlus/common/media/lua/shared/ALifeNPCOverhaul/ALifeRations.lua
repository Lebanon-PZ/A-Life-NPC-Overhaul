-- A-Life NPC Overhaul 0.8.8: RATIONS. A town eats from its stores; you decide how much.
-- Jeem already does the real part (read in Jeem 3806944055): the crew's supplies come out of the Food stores
-- (Residents/Stores.lua, S.tick every ten game minutes: supplies -= residents x (eatPerDay - foragePerDay) x days), a base
-- with no supplies for hungryDays is "hungry" (base.hungry, raids read it) and the crew walks after leaveDays; residents'
-- hunger is eased by base meals while the base isn't hungry (Needs/Server.lua S.advance: baseMeal x feedScale an hour).
-- What this adds, a rule per base (set in game, by you or your lieutenant):
--   full    everyone eats as Jeem has it
--   short   three quarters: the stores last a third longer, everyone a bit hungrier
--   half    half: the stores last twice as long, everyone hungry
--   guards  whoever's on watch (Jeem role "sentry" or on a guard shift now) eats full, everyone else half
-- Both sides move together: what the stores don't lose (S.addSupplies back after the tick) is what the people don't eat
-- (hunger added back after S.advance). Hunger does the rest on its own: Household's ration arguments (hungry >= 60),
-- weakness, people walking out. No numbers shown: a letter says what the rule is and roughly how long the food lasts.
-- Server side; wraps Jeem's R.stores.tick and J.Needs.server.advance (both looked up through their table each call).
require "ALifeNPCOverhaul/ALifeCmd"

ALifeRations = ALifeRations or {}
local A = ALifeRations
local TAG = "[ALifeRations]"
A.VERSION = "0.8.8"
A.DEFAULTS = {
    rations = true,      -- you can put the camp on short or half rations
    rationShort = 75,    -- % of a full meal on short rations
    rationHalf = 50,     -- % on half rations (and for those not on watch under "guards eat first")
}
A.KEYS = { "rations", "rationShort", "rationHalf" }
A.LEVELS = { full = true, short = true, half = true, guards = true }
A.metrics = A.metrics or { saved = 0, hungrier = 0, set = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function clamp(v) return math.max(0, math.min(100, v)) end
function A.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = A.DEFAULTS[key] end
    return v
end
function A.on() return A.setting("rations") ~= false end
function A.store()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeRations") or (A.tmp or {})
    if type(ModData) ~= "table" then A.tmp = s end
    s.level = type(s.level) == "table" and s.level or {}
    return s
end
function A.levelOf(baseId)
    local l = A.store().level[tostring(baseId)]
    return A.LEVELS[l or ""] and l or "full"
end
-- the share of a full meal this person gets under the base's rule (1 = full)
function A.shareFor(level, memory)
    if level == "full" then return 1 end
    if level == "short" then return num(A.setting("rationShort"), 75) / 100 end
    local half = num(A.setting("rationHalf"), 50) / 100
    if level == "half" then return half end
    if level == "guards" then
        local res = type(memory) == "table" and type(memory.jimmyResident) == "table" and memory.jimmyResident or {}
        local role = type(res.role) == "table" and res.role.k or nil
        if role == "sentry" or res.now == "guard" or (type(memory) == "table" and memory.jimmyTargetHold == true) then return 1 end
        return half
    end
    return 1
end

-- ---------------------------------------------------------------------------------------------- the stores side
function A.afterStores(hours, before)
    local j = J()
    if j == nil or j.opt == nil or j.opt("Residents_NeedFood", false) ~= true then return 0 end
    local R = j.Residents
    local St = R and R.stores
    if not fn(St, "addSupplies") or not fn(R, "residents") then return 0 end
    local saved = 0
    local after = St.data().ateAt or {}
    for baseId, at in pairs(before) do
        local level = A.levelOf(baseId)
        -- only where this tick really fed them (Jeem moves ateAt only then)
        if level ~= "full" and after[baseId] ~= nil and after[baseId] ~= at then
            local people = R.residents(baseId) or {}
            local dt = math.max(0, num(after[baseId], 0) - num(at, 0))
            local per = (num(St.eatPerDay, 1) - num(St.foragePerDay, 0.5)) * dt / 24
            local back = 0
            for _, r in ipairs(people) do back = back + per * (1 - A.shareFor(level, type(r) == "table" and r.memory or nil)) end
            if back > 0 then St.addSupplies(baseId, back); saved = saved + back end
        end
    end
    A.metrics.saved = A.metrics.saved + saved
    return saved
end

-- ---------------------------------------------------------------------------------------------- the people side
function A.afterNeeds(record, needs, lastHours, hours)
    if type(needs) ~= "table" or type(record) ~= "table" then return end
    local m = type(record.memory) == "table" and record.memory or {}
    local res = type(m.jimmyResident) == "table" and m.jimmyResident or nil
    if res == nil or res.baseId == nil then return end
    local level = A.levelOf(res.baseId)
    if level == "full" then return end
    local j = J()
    local S = j and j.Needs and j.Needs.server or nil
    if S == nil then return end
    local bases = fn(j.BaseAreas, "data") and j.BaseAreas.data().bases or {}
    local base = bases[res.baseId]
    if base == nil or base.hungry == true then return end -- (a hungry base already eats nothing)
    if fn(S, "planMeals") and S.planMeals(needs, record.lifecycle == "active", hours) then return end
    local dt = math.max(0, num(hours, 0) - num(lastHours, hours))
    local meal = num(S.baseMeal, 6) * (fn(S, "feedScale") and S.feedScale() or 1) * dt
    local less = meal * (1 - A.shareFor(level, m))
    if less > 0 then needs.hunger = clamp(num(needs.hunger, 0) + less); A.metrics.hungrier = A.metrics.hungrier + 1 end
end

function A.install()
    local j = J()
    if j == nil then return 0 end
    A.hooked = A.hooked or {}
    local St = j.Residents and j.Residents.stores
    if not A.hooked.stores and fn(St, "tick") and fn(St, "data") then
        local orig = St.tick
        St.tick = function(hours)
            local before = nil
            if A.on() and not A.offStores then
                before = {}
                pcall(function() for id, at in pairs(St.data().ateAt or {}) do before[id] = at end end)
            end
            local a, b, c = orig(hours)
            if before ~= nil then
                local ok, err = pcall(A.afterStores, hours, before)
                if not ok then A.offStores = true; log("stores side failed, off for this session: " .. tostring(err)) end
            end
            return a, b, c
        end
        A.hooked.stores = true
    end
    local S = j.Needs and j.Needs.server
    if not A.hooked.needs and fn(S, "advance") then
        local orig = S.advance
        S.advance = function(record, needs, hours, hour)
            local last = type(needs) == "table" and needs.lastHours or nil
            local out = orig(record, needs, hours, hour)
            if out ~= nil and A.on() and not A.offNeeds then
                local ok, err = pcall(A.afterNeeds, record, out, last, hours)
                if not ok then A.offNeeds = true; log("needs side failed, off for this session: " .. tostring(err)) end
            end
            return out
        end
        A.hooked.needs = true
    end
    local n = 0
    for _ in pairs(A.hooked) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------------------------- setting the rule
A.SAY = { full = "Full rations.", short = "Short rations: three quarters of a meal.", half = "Half rations.",
    guards = "Whoever's on watch eats full. Everyone else, half." }
-- the base's food, roughly, in days at this rule (nil when Jeem can't count it)
function A.daysLeft(base)
    local j = J()
    local R = j and j.Residents
    local St = R and R.stores
    if base == nil or not fn(St, "foodCount") or not fn(R, "residents") then return nil end
    local ok, c = pcall(St.foodCount, base)
    if not ok or type(c) ~= "table" or c.items == nil then return nil end
    local people = R.residents(base.id) or {}
    if #people == 0 then return nil end
    local level, per = A.levelOf(base.id), 0
    for _, r in ipairs(people) do per = per + num(St.eatPerDay, 1) * A.shareFor(level, type(r) == "table" and r.memory or nil) end
    return (num(c.items, 0) + num(St.data().supplies[base.id], 0)) / math.max(0.1, per)
end
function A.roughly(days)
    if days == nil then return nil end
    if days < 1 then return "The food won't last the day." end
    if days < 3 then return "A couple of days of food left." end
    if days < 7 then return "Food for a few days." end
    if days < 14 then return "Food for a week or so." end
    return "Plenty of food for now."
end
-- set by a player who runs the base (or by the lieutenant: key given, player nil)
function A.set(base, level, by)
    if not A.on() then return nil, "off" end
    if type(base) ~= "table" or not A.LEVELS[level or ""] then return nil, "level" end
    A.store().level[tostring(base.id)] = level
    A.metrics.set = A.metrics.set + 1
    log("rations at " .. tostring(base.id) .. " -> " .. level .. (by and (" by " .. tostring(by)) or ""))
    return level
end
if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("rationSet", function(player, args)
        if type(args) ~= "table" then return "args" end
        local level = tostring(args.level or "")
        local j = J()
        local base = fn(ALifeCampVote, "baseFor") and ALifeCampVote.baseFor(player) or nil
        if j == nil or base == nil then ALifeCmd.reply(player, "rationSet", { ok = false, why = "nobase" }); return "nobase" end
        local who = fn(j.BaseAreas, "who") and j.BaseAreas.who(player) or {}
        if fn(j.BaseAreas, "canManage") and not j.BaseAreas.canManage(base, who.key, who.faction, who.admin) then
            ALifeCmd.reply(player, "rationSet", { ok = false, why = "notyours" }); return "notyours"
        end
        local ok, why = A.set(base, level, who.key)
        ALifeCmd.reply(player, "rationSet", { ok = ok ~= nil, why = why, level = level, text = ok and ((A.SAY[level] or "") .. " " .. (A.roughly(A.daysLeft(base)) or "")) or nil })
        return why
    end)
    -- 0.8.8 UI: the camp board's status line. The base you're at if you run it, else the nearest one you run.
    -- Answer "campStatus" { base, level, food } (food in words, never a number) or { none = true }.
    ALifeCmd.onServer("campStatusAsk", function(player, args)
        local base = A.baseOfPlayer(player)
        if base == nil then ALifeCmd.reply(player, "campStatus", { none = true }); return "nobase" end
        ALifeCmd.reply(player, "campStatus", { base = base.name and tostring(base.name) or nil, level = A.levelOf(base.id),
            food = A.roughly(A.daysLeft(base)), rations = A.on() })
        return "ok"
    end)
end
-- a base this player runs: the one they're at, else the nearest (Jeem BaseAreas.data().bases + canManage)
function A.baseOfPlayer(player)
    local j = J()
    local B = j and j.BaseAreas or nil
    if player == nil or not fn(B, "who") or not fn(B, "canManage") then return nil end
    local who = B.who(player) or {}
    local function mine(b) return type(b) == "table" and B.canManage(b, who.key, who.faction, who.admin) == true end
    local here = fn(ALifeCampVote, "baseFor") and ALifeCampVote.baseFor(player) or nil
    if mine(here) then return here end
    if not fn(B, "data") then return nil end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    local best, bestD = nil, nil
    for _, b in pairs(B.data().bases or {}) do
        if mine(b) then
            local cx, cy = nil, nil
            if fn(ALifeLieutenant, "centre") then cx, cy = ALifeLieutenant.centre(b) end
            local d = (cx ~= nil and px ~= nil) and ((cx - px) ^ 2 + (cy - py) ^ 2) or 1e18
            -- (ties: lowest id, Kahlua's pairs has no order)
            if best == nil or d < bestD or (d == bestD and tostring(b.id) < tostring(best.id)) then best, bestD = b, d end
        end
    end
    return best
end

pcall(A.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(A.install)
        log("ready v" .. A.VERSION .. ": rations (" .. tostring(ok and n or 0) .. "/2 hooks on Jeem's stores and meals, " .. (A.on() and "on" or "off") .. ")")
    end)
end
if type(Events) == "table" and Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(A.install) end) end
