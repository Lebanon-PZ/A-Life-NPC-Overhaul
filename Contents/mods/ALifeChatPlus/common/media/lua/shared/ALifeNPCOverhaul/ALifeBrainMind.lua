-- A-Life NPC Overhaul pre-1.0: BRAIN B2, MIND (docs/PLAN-BRAIN.md). Who the group is.
--  * weights w = { greed, fear, aggression, pride, kindness, caution, loyalty, ambition, faith } (0..2): the creed sets
--    the base, the rule decides whose traits count (leader alone; council = leader half + the two steadiest; vote =
--    everyone; faith = preacher + the devout), and those people's persona lens (M.lens) bends it.
--  * discipline (finishes plans, holds stances) vs randomness (volatile, unhinged).
--  * memory of outcomes per action and target ("raid:ridge", "trade:mill"), grudges and debts with a target (a group,
--    "you", or a place), all fading over memFadeDays.
--  * succession stain: a new leader takes stainDays to make the group theirs; how the old one went (killed by an
--    enemy, peaceful) leaves the group shaken, vengeful or unsure meanwhile.
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, clamp = BR.fn, BR.hours, BR.clamp

BR.WKEYS = { "greed", "fear", "aggression", "pride", "kindness", "caution", "loyalty", "ambition", "faith" }
BR.CREED_W = {
    open = { kindness = 1.4, aggression = 0.6, caution = 0.8 },
    wary = { caution = 1.2 },
    closed = { caution = 1.5, kindness = 0.6, fear = 1.2 },
    raiders = { aggression = 1.6, kindness = 0.4, greed = 1.4, ambition = 1.3, caution = 0.7 },
    faithful = { faith = 1.6, kindness = 1.2, aggression = 0.7 },
    traders = { greed = 1.3, kindness = 1.1, aggression = 0.7, caution = 1.1 },
}
-- lens trait (0..1) -> weight bends
BR.LENS_BEND = {
    greedy = { greed = 1.0, ambition = 0.3 },
    paranoid = { fear = 0.8, caution = 0.8 },
    fearful = { fear = 1.0, caution = 0.6, aggression = -0.4 },
    brave = { aggression = 0.6, fear = -0.6 },
    proud = { pride = 1.0, aggression = 0.4, ambition = 0.4 },
    kind = { kindness = 1.0, aggression = -0.4 },
    mean = { aggression = 0.5, kindness = -0.6 },
    calm = { caution = 0.3 },
    loyal = { loyalty = 1.0 },
    devout = { faith = 1.0 },
    disciplined = { caution = 0.2 },
    unhinged = { aggression = 0.5, caution = -0.5 },
    volatile = { aggression = 0.3 },
}
local function lensOf(uid)
    if uid == nil or not fn(M, "lens") then return {} end
    local ok, l = pcall(M.lens, tostring(uid))
    return ok and type(l) == "table" and l or {}
end
local function memberUids(b)
    local out = {}
    for _, k in ipairs(BR.sortedKeys(b.roster)) do
        local e = b.roster[k]
        if type(e) == "table" and e.u then out[#out + 1] = tostring(e.u) end
    end
    return out
end
-- whose traits count, and how much: { { uid, share } }
function BR.voices(b)
    local rule = type(b.dir) == "table" and b.dir.rule or "council"
    local leader = b.leader and tostring(b.leader) or nil
    local all = memberUids(b)
    local out = {}
    if rule == "vote" and #all > 0 then
        for _, u in ipairs(all) do out[#out + 1] = { u, 1 / #all } end
        return out
    end
    if rule == "council" then
        local steady = {}
        for _, u in ipairs(all) do
            if u ~= leader then local l = lensOf(u); steady[#steady + 1] = { u = u, v = (l.disciplined or 0) + (l.calm or 0) - (l.volatile or 0) } end
        end
        table.sort(steady, function(a, c) if a.v ~= c.v then return a.v > c.v end return a.u < c.u end)
        if leader then out[#out + 1] = { leader, 0.5 } end
        local rest = leader and 0.5 or 1
        local n = math.min(2, #steady)
        for i = 1, n do out[#out + 1] = { steady[i].u, rest / n } end
        if n == 0 and leader then out[1][2] = 1 end
        return out
    end
    if rule == "faith" then
        local devout = {}
        for _, u in ipairs(all) do if u ~= leader and (lensOf(u).devout or 0) > 0.1 then devout[#devout + 1] = u end end
        if leader then out[#out + 1] = { leader, #devout > 0 and 0.6 or 1 } end
        for _, u in ipairs(devout) do out[#out + 1] = { u, (leader and 0.4 or 1) / #devout } end
        return out
    end
    if leader then out[#out + 1] = { leader, 1 } end
    return out
end
-- the blended lens of the voices that count
function BR.groupLens(b)
    local L = {}
    for _, v in ipairs(BR.voices(b)) do
        for k, x in pairs(lensOf(v[1])) do
            if type(x) == "number" then L[k] = (L[k] or 0) + x * v[2] end
        end
    end
    return L
end
-- weights from creed + lens (no stain / pressure yet)
function BR.weightsFor(b)
    local creed = type(b.dir) == "table" and b.dir.creed or "wary"
    local w = {}
    for _, k in ipairs(BR.WKEYS) do w[k] = 1 end
    for k, v in pairs(BR.CREED_W[creed] or {}) do w[k] = v end
    if b.trade == "warband" or b.trade == "slavers" then w.aggression = w.aggression + 0.3 end
    if b.trade == "traders" then w.greed = w.greed + 0.2 end
    local L = BR.groupLens(b)
    for trait, bends in pairs(BR.LENS_BEND) do
        local x = tonumber(L[trait]) or 0
        if x > 0 then for k, d in pairs(bends) do w[k] = w[k] + d * x * 1.5 end end
    end
    w.aggression = w.aggression * BR.num("brainAggression") / 100
    for _, k in ipairs(BR.WKEYS) do w[k] = clamp(w[k], 0, 2) end
    local disc = (L.disciplined or 0) + (L.calm or 0) * 0.5 - (L.volatile or 0) * 0.7 - (L.unhinged or 0) * 0.7
    return w, clamp(disc * 2, -1, 1), clamp(((L.volatile or 0) + (L.unhinged or 0)) * 2, 0, 1)
end

-- refresh when the leader, creed or rule changes (and once a week anyway: people change)
function BR.mindRefresh(b, h)
    local s = BR.of(b)
    local mind = s.mind
    local d = type(b.dir) == "table" and b.dir or {}
    local week = math.floor(h / 168)
    local leader = b.leader and tostring(b.leader) or "none"
    if mind.leader == leader and mind.creed == d.creed and mind.rule == d.rule and mind.week == week and type(mind.base) == "table" then return false end
    local w, disc, rnd = BR.weightsFor(b)
    -- a new leader: the stain (how the old one went) and a slow blend into the new ways
    if mind.leader ~= nil and mind.leader ~= leader and type(mind.base) == "table" then
        local kind = "unsure"
        local recentHit = (b.lastAttack and h - (tonumber(b.lastAttack.h) or -1e9) < 72) or (h - (tonumber(s.lastHitH) or -1e9) < 72)
        if recentHit then
            local proud = (tonumber(mind.base.pride) or 1) >= 1.1
            local mine = BR.str(b)
            local strong = mine >= (tonumber(s.lastHitStr) or mine)
            kind = (proud and strong) and "vengeful" or "shaken"
            if kind == "vengeful" and s.lastHitBy then BR.grudge(b, s.lastHitBy, (BR.grudgeV(b, s.lastHitBy) or 20), "killed their leader") end
        end
        s.mind.stain = { kind = kind, fromH = h, untilH = h + BR.num("stainDays") * 24, old = mind.base }
        local words = { shaken = "Losing their leader shook them. They're keeping their heads down",
            vengeful = "They want blood for their leader", unsure = "Under new leadership, they're feeling things out" }
        BR.event(b, words[kind], "brain")
        BR.interrupt(b, "leader")
    end
    mind.leader, mind.creed, mind.rule, mind.week = leader, d.creed, d.rule, week
    mind.base, mind.disc, mind.rnd = w, disc, rnd
    return true
end
-- the weights now (stain blended, stain effects applied)
function BR.w(b, h)
    local s = BR.of(b)
    local mind = s.mind
    if type(mind.base) ~= "table" then BR.mindRefresh(b, h or hours()) end
    local base = mind.base or {}
    local w = {}
    for _, k in ipairs(BR.WKEYS) do w[k] = tonumber(base[k]) or 1 end
    local st = mind.stain
    h = h or hours()
    if type(st) == "table" then
        if h >= (tonumber(st.untilH) or 0) then mind.stain = nil
        else
            local f = clamp((h - st.fromH) / math.max(1, st.untilH - st.fromH), 0, 1)
            for _, k in ipairs(BR.WKEYS) do w[k] = (tonumber(st.old and st.old[k]) or w[k]) * (1 - f) + w[k] * f end
            if st.kind == "shaken" then w.fear = math.min(2, w.fear + 0.5); w.caution = math.min(2, w.caution + 0.4); w.aggression = w.aggression * 0.6
            elseif st.kind == "vengeful" then w.aggression = math.min(2, w.aggression + 0.4); w.pride = math.min(2, w.pride + 0.3) end
        end
    end
    -- desperate groups take risks
    local fd = BR.foodDays(b)
    if fd < 1 then w.aggression = math.min(2, w.aggression + 0.3); w.caution = math.max(0, w.caution - 0.3) end
    return w, tonumber(mind.disc) or 0, tonumber(mind.rnd) or 0
end
function BR.stainKind(b, h)
    local st = BR.of(b).mind.stain
    if type(st) == "table" and (h or hours()) < (tonumber(st.untilH) or 0) then return st.kind end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- memory of outcomes, grudges, debts (all fade over memFadeDays)
----------------------------------------------------------------------------------------------------------------
local function fade(h0, h)
    local days = math.max(0, ((h or hours()) - (tonumber(h0) or 0)) / 24)
    return 0.5 ^ (days / math.max(1, BR.num("memFadeDays")))
end
function BR.remember(b, key, field, add, h)
    local s = BR.of(b)
    h = h or hours()
    local m = s.memory[key]
    if type(m) ~= "table" then
        m = {}; s.memory[key] = m
        local keys = BR.sortedKeys(s.memory)
        if #keys > 24 then
            local oldK, oldH = nil, 1e12
            for _, k in ipairs(keys) do local x = s.memory[k]; if type(x) == "table" and (tonumber(x.h) or 0) < oldH and k ~= key then oldK, oldH = k, tonumber(x.h) or 0 end end
            if oldK then s.memory[oldK] = nil end
        end
    end
    -- older counts fade before the new one is added
    local f = fade(m.h, h)
    for k, v in pairs(m) do if k ~= "h" and type(v) == "number" then m[k] = v * f end end
    m[field] = (tonumber(m[field]) or 0) + (tonumber(add) or 1)
    m.h = h
    return m
end
function BR.mem(b, key, h)
    local m = BR.of(b).memory[key]
    if type(m) ~= "table" then return {} end
    local f = fade(m.h, h)
    local out = {}
    for k, v in pairs(m) do if type(v) == "number" and k ~= "h" then out[k] = v * f end end
    return out
end
-- a grudge against a target (group id, "you", or "place:x,y"); pride makes it bite deeper
function BR.grudge(b, target, v, why, place, h)
    if type(b) ~= "table" or target == nil or target == b.id then return end
    local s = BR.of(b)
    h = h or hours()
    local base = type(s.mind.base) == "table" and s.mind.base or {}
    local amp = 0.7 + 0.3 * (tonumber(base.pride) or 1)
    local g = s.grudges[tostring(target)]
    local cur = type(g) == "table" and (tonumber(g.v) or 0) * fade(g.h, h) or 0
    s.grudges[tostring(target)] = { v = math.min(100, cur + (tonumber(v) or 10) * amp), why = why or (type(g) == "table" and g.why) or nil,
        place = place or (type(g) == "table" and g.place) or nil, h = h }
    local keys = BR.sortedKeys(s.grudges)
    if #keys > 8 then
        local lowK, lowV = nil, 1e9
        for _, k in ipairs(keys) do local x = BR.grudgeV(b, k, h); if x < lowV then lowK, lowV = k, x end end
        if lowK then s.grudges[lowK] = nil end
    end
end
function BR.grudgeV(b, target, h)
    local g = BR.of(b).grudges[tostring(target)]
    if type(g) ~= "table" then return 0 end
    return (tonumber(g.v) or 0) * fade(g.h, h)
end
-- the grudge that points revenge (never "someone"): target, value
function BR.topGrudge(b, h)
    local best, bv = nil, 0
    for _, k in ipairs(BR.sortedKeys(BR.of(b).grudges)) do
        local v = BR.grudgeV(b, k, h)
        if v > bv and (k == "you" or BR.base(k) or string.sub(k, 1, 6) == "place:") then best, bv = k, v end
    end
    return best, bv
end
function BR.debt(b, target, v, why, h)
    if type(b) ~= "table" or target == nil or target == b.id then return end
    local s = BR.of(b)
    h = h or hours()
    local d = s.debts[tostring(target)]
    local cur = type(d) == "table" and (tonumber(d.v) or 0) * fade(d.h, h) or 0
    s.debts[tostring(target)] = { v = math.min(100, cur + (tonumber(v) or 10)), why = why, h = h }
end
function BR.debtV(b, target, h)
    local d = BR.of(b).debts[tostring(target)]
    if type(d) ~= "table" then return 0 end
    return (tonumber(d.v) or 0) * fade(d.h, h)
end

-- the world tells the mind: raids, robbed runs, aid, a member killed by you
local function install()
    M._alcpHooks = M._alcpHooks or {}
    if not M._alcpHooks.brainMindEvent and fn(M, "nbEvent") then
        M._alcpHooks.brainMindEvent = true
        local ev = M.nbEvent
        M.nbEvent = function(b, text, kind, ...)
            local r = ev(b, text, kind, ...)
            if BR.on() and type(b) == "table" and b.status == "active" then
                pcall(function()
                    if kind == "raided" then BR.interrupt(b, "raided")
                    elseif kind == "aid" and type(text) == "string" and string.find(text, "sent them food", 1, true) and fn(M, "nbActive") then
                        for _, o in ipairs(M.nbActive()) do
                            if o.id ~= b.id and string.find(text, tostring(o.name), 1, true) then BR.debt(b, o.id, 15, "sent food when they starved"); break end
                        end
                    end
                end)
            end
            return r
        end
    end
    if not M._alcpHooks.brainMindDeath and fn(M, "nbOnDeath") then
        M._alcpHooks.brainMindDeath = true
        local od = M.nbOnDeath
        M.nbOnDeath = function(body, uid, killer, ...)
            local b = nil
            if BR.on() then
                pcall(function()
                    local r = BR.PA().ActorRegistry.read(tostring(uid))
                    local m = r and type(r.memory) == "table" and r.memory or nil
                    b = m and m.havenId and M.nbOf(m.havenId) or nil
                end)
            end
            local res = od(body, uid, killer, ...)
            if b and b.status == "active" then
                pcall(function()
                    local isP = false
                    pcall(function() isP = killer ~= nil and instanceof(killer, "IsoPlayer") end)
                    if isP then
                        BR.grudge(b, "you", 30, "killed one of theirs")
                        local s = BR.of(b)
                        s.provoked = hours()
                        BR.interrupt(b, "killedByYou")
                    else BR.interrupt(b, "lost") end
                end)
            end
            return res
        end
    end
    if not M._alcpHooks.brainMindRep and fn(M, "nbRep") then
        M._alcpHooks.brainMindRep = true
        local rep = M.nbRep
        M.nbRep = function(b, d, why, ...)
            local r = rep(b, d, why, ...)
            if BR.on() and type(b) == "table" and tonumber(d) then
                pcall(function()
                    if d <= -8 then BR.grudge(b, "you", -d, why); BR.of(b).provoked = hours(); BR.interrupt(b, "you")
                    elseif d >= 8 then BR.debt(b, "you", d, why); BR.interrupt(b, "you") end
                end)
            end
            return r
        end
    end
    return M._alcpHooks.brainMindEvent == true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
