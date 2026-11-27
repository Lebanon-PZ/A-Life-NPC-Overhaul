-- A-Life NPC Overhaul pre-1.0: BRAIN B3, COMMANDER (docs/PLAN-BRAIN.md). Once a game day per group (and on
-- interrupts): read the situation from the ledger + beliefs, score seven stances (utility x personality x memory),
-- pick one and hold it (stanceMinDays; disciplined leaders longer, volatile ones less). A hidden pressure meter
-- (starving, no ammo, losses, overrun, sieged) pushes survive / secure up and damps the personality bend, so reality
-- beats pride. The stance sets each manager's share of the people and standing orders nobody breaks.
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll

BR.STANCES = { "survive", "secure", "grow", "trade", "expand", "dominate", "revenge" }
-- people shares per stance (percent of the group; the rest rests at home and still defends). Override: settings
-- table brainShares[stance] = { job = pct } (data, not a menu)
BR.SHARES = {
    survive  = { economy = 60, guard = 30, scout = 10 },
    secure   = { guard = 40, economy = 30, build = 10, scout = 10, trade = 10 },
    grow     = { economy = 40, build = 20, recruit = 10, trade = 10, guard = 15, scout = 5 },
    trade    = { economy = 30, trade = 35, guard = 20, build = 10, scout = 5 },
    expand   = { economy = 35, build = 15, guard = 20, trade = 10, scout = 10, recruit = 10 },
    dominate = { war = 40, economy = 25, guard = 20, scout = 15 },
    revenge  = { war = 35, guard = 25, economy = 30, scout = 10 },
}
-- standing orders the managers can't break
BR.ORDERS = {
    survive = { noWar = true, noTrade = false, gate = 1 },
    secure = { gate = 2, noRunsOnBadRoads = true },
    trade = { keepFoodDays = 5 },
    grow = { gate = 1 },
    expand = { gate = 1 },
    dominate = { gate = 1 },
    revenge = { gate = 1 },
}
function BR.shares(stance)
    local over = type(M.settings.brainShares) == "table" and M.settings.brainShares[stance] or nil
    local base = type(over) == "table" and over or (BR.SHARES[stance] or BR.SHARES.grow)
    local out = {}
    for k, v in pairs(base) do out[k] = tonumber(v) or 0 end
    out.economy = math.max(out.economy or 0, BR.num("brainEconomyFloor"))
    return out
end

----------------------------------------------------------------------------------------------------------------
-- the situation: their own ledger (always known) + what they believe about everyone else
----------------------------------------------------------------------------------------------------------------
function BR.situation(b, h)
    local s = BR.of(b)
    local n = math.max(1, tonumber(b.crewN) or 1)
    local g = type(b.goods) == "table" and b.goods or {}
    local sit = { crew = n, food = BR.foodDays(b), ammo = (tonumber(g.ammo) or 0) / n, meds = (tonumber(g.meds) or 0) / n,
        str = math.max(0.1, BR.str(b)), stage = b.stage, morale = tonumber(b.morale) or 50, threats = {}, prey = {}, partners = 0 }
    sit.trend = sit.food - (tonumber(s.lastFood) or sit.food)
    local season = fn(M, "nbSeason") and M.nbSeason() or "summer"
    sit.winterSoon = season == "autumn" or season == "winter"
    local cap = (M.nbCfg and M.nbCfg.memberCap) or 8
    sit.crowded = n >= math.max(5, math.floor(cap * 0.75))
    sit.overrun = b.lastAttack ~= nil and h - (tonumber(b.lastAttack.h) or -1e9) < 72 and (b.stage == "squat") and (tonumber(b.morale) or 50) < 40
    sit.attacked = b.lastAttack ~= nil and h - (tonumber(b.lastAttack.h) or -1e9) < 48
    sit.sieged = type(s.sieged) == "table" and h < (tonumber(s.sieged.untilH) or 0)
    sit.incoming = type(s.incoming) == "table" and h < (tonumber(s.incoming.untilH) or 0)
    sit.threat, sit.bestNeighbour, sit.opportunity = 0, 0, 0
    local reach = ((M.dirCfg and M.dirCfg.raidTiles) or 700) * 1.5
    local tradeTiles = (M.cvRunCfg and M.cvRunCfg.tiles) or 1000
    local actConf = BR.num("knowActConf") / 100
    for _, k in ipairs(BR.known(b, h)) do
        local id = k.id
        local o = BR.base(id)
        local tie = o and BR.tie(b, o) or (id == "you" and ((tonumber(b.rep) or 50) - 50) or 0)
        local st = BR.tieState(tie)
        local grudge = BR.grudgeV(b, id, h)
        local hostile = k.hostile == true or st == "war" or st == "rivals" or grudge >= 30
        local ratio = (tonumber(k.str) or 1) / sit.str
        local near = k.dist <= reach
        if id ~= "you" or BR.vsPlayerOk(b, h) or hostile then
            if hostile and near then
                local recent = (s.lastHitBy == id and h - (tonumber(s.lastHitH) or -1e9) < 168) and 1.5 or 1
                local t = ratio * k.c * recent
                sit.threats[#sit.threats + 1] = { id = id, v = t, ratio = ratio, dist = k.dist }
                if t > sit.threat then sit.threat, sit.threatBy = t, id end
            end
            if k.dist <= 1500 and tonumber(k.str) and k.str > sit.bestNeighbour then sit.bestNeighbour = k.str end
            if st ~= "allied" and st ~= "friendly" and k.dist <= reach * 1.5 and ratio < 0.7 then
                local gain = ((tonumber(k.wealth) or 0) + (k.food and k.food >= 5 and 1 or 0) + grudge / 40) * (1 - ratio)
                sit.prey[#sit.prey + 1] = { id = id, gain = gain, ratio = ratio, c = k.c, sure = k.c >= actConf, dist = k.dist }
                if k.c >= actConf and gain > sit.opportunity then sit.opportunity = gain end
            end
            if o and not hostile and tie >= 0 and k.dist <= tradeTiles then sit.partners = sit.partners + 1 end
        end
    end
    table.sort(sit.prey, function(a, c) if a.gain ~= c.gain then return a.gain > c.gain end return tostring(a.id) < tostring(c.id) end)
    sit.strongest = sit.bestNeighbour > 0 and sit.str >= 1.4 * sit.bestNeighbour
    sit.surplus = false
    local T = ALifeTrade
    if fn(T, "ratio") then for _, kind in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do if T.ratio(b, kind) >= 1.5 then sit.surplus = true end end end
    sit.grudgeTo, sit.grudge = BR.topGrudge(b, h)
    return sit
end

-- your camp in their plans: setting brainVsPlayer (2 on / 1 provoked only / 0 off) and grace days
function BR.vsPlayerOk(b, h)
    local mode = BR.num("brainVsPlayer")
    if mode <= 0 then return false end
    if h / 24 < BR.num("brainPlayerGrace") then return false end
    if mode == 1 then return type(b) == "table" and type(b.brain) == "table" and b.brain.provoked ~= nil end
    return true
end

-- the hidden pressure meter (0..100, never shown): reality overrides pride
function BR.pressureDay(b, sit, h)
    local s = BR.of(b)
    local add = 0
    if sit.food < 1 then add = add + 20 elseif sit.food < 2 then add = add + 8 end
    if sit.ammo <= 0 then add = add + 5 end
    if sit.overrun then add = add + 30 elseif sit.attacked then add = add + 10 end
    if sit.sieged then add = add + 15 end
    local lost = tonumber(s.lostToday) or 0
    add = add + lost * 10
    s.lostToday = 0
    if add == 0 then s.pressure = math.max(0, s.pressure - 10) else s.pressure = clamp(s.pressure + add, 0, 100) end
    return s.pressure
end

-- stance scores (0..~1.5)
function BR.scoreStances(b, sit, h)
    local s = BR.of(b)
    local w, disc, rnd = BR.w(b, h)
    local p = s.pressure / 100
    -- pressure damps the personality bend: reality first
    local function W(k) return 1 + ((tonumber(w[k]) or 1) - 1) * (1 - p) end
    local sc = {}
    sc.survive = math.max(sit.food < 1 and 1 or (sit.food < 2 and 0.6 or 0), sit.overrun and 0.9 or 0, sit.threat >= 2.5 and 0.8 or 0)
    sc.secure = clamp(sit.threat * 0.5 + (sit.stage ~= "fortified" and 0.15 or 0) + (sit.ammo <= 0 and 0.15 or 0)
        + (sit.attacked and 0.3 or 0) + ((sit.incoming or sit.sieged) and 1 or 0), 0, 1.5)
    sc.grow = (1 - math.min(1, sit.threat)) * clamp(sit.food / 6, 0, 1) * 0.7 + (sit.crew < 4 and 0.15 or 0)
    sc.trade = 0
    if sit.surplus and sit.partners > 0 then sc.trade = (0.4 + 0.1 * math.min(3, sit.partners)) * (1 - math.min(1, sit.threat) * 0.5) end
    if b.trade == "traders" or (b.dir and b.dir.creed == "traders") then sc.trade = sc.trade + 0.2 end
    sc.expand = (sit.crowded and sit.food >= 4) and (0.6 * (1 - math.min(1, sit.threat))) or 0
    sc.dominate = 0
    if sit.strongest then sc.dominate = 0.5 + math.min(0.3, sit.opportunity * 0.1) end
    sc.revenge = 0
    if sit.grudgeTo and sit.grudge >= 40 then
        local k = BR.belief(b, sit.grudgeTo, h)
        local odds = k and tonumber(k.str) and sit.str / math.max(0.1, k.str) or 0
        local need = 0.8 - (W("pride") - 1) * 0.3 + (W("caution") - 1) * 0.3
        if odds >= need then
            local m = BR.mem(b, "raid:" .. tostring(sit.grudgeTo), h)
            sc.revenge = (0.4 + sit.grudge / 200) / (1 + (m.losses or 0))
        end
    end
    -- personality
    sc.survive = sc.survive * (0.7 + 0.3 * W("fear"))
    sc.secure = sc.secure * W("caution")
    sc.grow = sc.grow * (0.5 * W("kindness") + 0.5 * W("greed"))
    sc.trade = sc.trade * (0.4 * W("greed") + 0.3 * W("kindness") + 0.3)
    sc.expand = sc.expand * W("ambition")
    sc.dominate = sc.dominate * W("aggression") * W("ambition")
    sc.revenge = sc.revenge * W("pride") * W("aggression") * (1.5 - 0.5 * W("caution"))
    -- reality: pressure lifts survive / secure; standing rules
    sc.survive = sc.survive * (1 + s.pressure / 50)
    sc.secure = sc.secure * (1 + s.pressure / 100)
    local stain = BR.stainKind(b, h)
    if stain == "shaken" then sc.secure = sc.secure * 1.3; sc.dominate = sc.dominate * 0.5; sc.revenge = sc.revenge * 0.5
    elseif stain == "vengeful" then sc.revenge = sc.revenge * 1.6 end
    -- volatile minds wobble
    if rnd > 0 then
        for _, k in ipairs(BR.STANCES) do sc[k] = math.max(0, sc[k] + (roll(b.id .. k .. math.floor(h / 24)) - 0.5) * 0.3 * rnd) end
    end
    sc.grow = math.max(sc.grow, 0.05) -- the default when nothing presses
    return sc, disc
end

-- think: once a day (and on interrupts)
function BR.think(b, h, why)
    local s = BR.of(b)
    local sit = BR.situation(b, h)
    if why == "day" then BR.pressureDay(b, sit, h); s.lastFood = sit.food end
    local sc, disc = BR.scoreStances(b, sit, h)
    s.scores = sc
    local best, bv = "grow", -1
    for _, k in ipairs(BR.STANCES) do if sc[k] > bv then best, bv = k, sc[k] end end
    local cur = s.stance
    local curV = cur and sc[cur] or 0
    local hold = BR.num("stanceMinDays") * 24 * (1 + 0.5 * disc)
    local urgent = (best == "survive" or best == "secure") and why ~= "day"
    local change = cur == nil
    if not change and best ~= cur then
        local held = h - (tonumber(s.stanceH) or -1e9)
        if BR.stainKind(b, h) == "unsure" and best ~= "survive" then change = false        -- a new leader feeling things out
        elseif held >= hold and bv > curV * 1.15 then change = true
        elseif urgent and bv > curV * 1.2 then change = true
        elseif sc.survive >= 0.9 and best == "survive" then change = true end              -- reality beats pride, always
    end
    if change and best ~= cur then
        s.stance, s.stanceH = best, h
        s.orders = {}
        for k, v in pairs(BR.ORDERS[best] or {}) do s.orders[k] = v end
        if cur ~= nil then BR.stats.stanceChanges = BR.stats.stanceChanges + 1 end
        s.sit = nil
        if fn(BR, "onStance") then pcall(BR.onStance, b, cur, best, sit, h) end
        -- plans that fight the new stance go
        if type(s.plan) == "table" and fn(BR, "planFits") and not BR.planFits(b, s.plan, best) then BR.planAbort(b, "stance", h) end
    end
    s.threatBy = sit.threatBy
    s.lastThinkH = h
    if s.events then s.events = {} end
    if BR.setting("brainDebug") == true then print(BR.TAG .. " " .. tostring(b.name) .. " thinks (" .. tostring(why) .. "): " .. tostring(s.stance) .. ", pressure " .. math.floor(s.pressure)) end
    return s.stance
end
