-- A-Life NPC Overhaul pre-1.0: BRAIN 2, R4 THEY LEARN HOW YOU PLAY (docs/PLAN-BRAIN-2.md). Each group keeps a small
-- model of you, only from what it really saw (fog of war still holds):
--   * when you hit (the hour you killed one of theirs, in 4-hour blocks), how (guns or not, at night, alone or with a
--     crew), where you go (map blocks they saw you in), your roads (where your caravans went past them), how you answer
--     (paid / refused / ignored demands), whether they saw you far from home.
--   * counters, and they cost them: more guards at the hours you come (fewer hands on food), traders kept off the
--     roads you walk (escorts or no run), raids on you from the side you're seen least, and when they saw you leave
--     (quiet while you're home), bigger demands if you always pay.
--   * shared: allies and traders pass it on (less sure), so a habit known in one valley spreads.
--   * fades over learnFadeDays. Setting brainLearn: 0 off, 1 slow (half), 2 on.
--   * words: their talk shows it ("You always come at night."), so you know they adapted. No numbers.
-- World side (server in MP). Bounded: 6 hour blocks, 8 map blocks, 6 roads per group.
require "ALifeNPCOverhaul/ALifeBrainFight"
pcall(require, "ALifeNPCOverhaul/ALifeBrainWords")
pcall(require, "ALifeNPCOverhaul/ALifeBrainManagers")
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll
local TAG = "[ALifeBrainLearn]"

BR.defaults({
    brainLearn = 2,       -- 0 off, 1 slow, 2 on: groups learn how you play and counter it
    learnFadeDays = 21,   -- days a habit of yours takes to fade from their minds
})
BR.addRows({
    { "brainLearn", "Brain learning: groups learn how you play and counter it", { 0, 1, 2 }, { "off", "slow", "on" } },
    { "learnFadeDays", "Brain learning: days your habits take to fade from their minds", { 7, 21, 45 } },
})
BR.learnStats = BR.learnStats or { kills = 0, sightings = 0, roads = 0, answers = 0, shared = 0, guards = 0, rerouted = 0, flank = 0, waited = 0 }
local LS = BR.learnStats
local BLOCK = 300 -- tiles per map block
local function rate() local v = BR.num("brainLearn"); return v >= 2 and 1 or (v >= 1 and 0.5 or 0) end
local function hourOfDay() local h = 12; pcall(function() h = getGameTime():getHour() end); return tonumber(h) or 12 end

----------------------------------------------------------------------------------------------------------------
-- the model (per group, saved with its brain)
----------------------------------------------------------------------------------------------------------------
function BR.youModel(b)
    local s = BR.of(b)
    local m = s.youModel
    if type(m) ~= "table" then m = {}; s.youModel = m end
    for _, k in ipairs({ "hrs", "where", "roads", "ans", "style" }) do if type(m[k]) ~= "table" then m[k] = {} end end
    return m
end
local function fadeAll(m, h)
    local last = tonumber(m.fadeH) or h
    local days = (h - last) / 24
    if days < 1 then return end
    m.fadeH = h
    local f = 0.5 ^ (days / math.max(1, BR.num("learnFadeDays") / 2))
    for _, k in ipairs({ "hrs", "where", "roads", "ans", "style" }) do
        for key, v in pairs(m[k]) do local nv = (tonumber(v) or 0) * f; if nv < 0.2 then m[k][key] = nil else m[k][key] = nv end end
    end
end
local function bump(t, key, by, cap)
    t[key] = (tonumber(t[key]) or 0) + by
    local keys = BR.sortedKeys(t)
    if cap and #keys > cap then
        local low, lv = nil, 1e9
        for _, k in ipairs(keys) do if (tonumber(t[k]) or 0) < lv then low, lv = k, tonumber(t[k]) or 0 end end
        if low ~= nil and low ~= key then t[low] = nil end
    end
end
function BR.youNote(b, what, key, h, by)
    local r = rate()
    if r <= 0 or type(b) ~= "table" or b.isCamp then return end
    h = h or hours()
    local m = BR.youModel(b)
    if m.fadeH == nil then m.fadeH = h end
    fadeAll(m, h)
    local caps = { hrs = 6, where = 8, roads = 6, ans = 3, style = 5 }
    bump(m[what], key, (by or 1) * r, caps[what])
    m.h = h
end
-- the strongest habit in a part of the model: key, weight, share of all
function BR.youTop(b, what)
    local m = BR.youModel(b)
    local best, bv, sum = nil, 0, 0
    for _, k in ipairs(BR.sortedKeys(m[what])) do local v = tonumber(m[what][k]) or 0; sum = sum + v; if v > bv then best, bv = k, v end end
    return best, bv, sum > 0 and bv / sum or 0
end
local function blockOf(x, y) return math.floor(x / BLOCK) .. "," .. math.floor(y / BLOCK) end
local function blockXY(key) local a, c = string.match(tostring(key), "^(%-?%d+),(%-?%d+)$"); if a == nil then return nil end; return (tonumber(a) + 0.5) * BLOCK, (tonumber(c) + 0.5) * BLOCK end
BR.learnBlockOf, BR.learnBlockXY = blockOf, blockXY

----------------------------------------------------------------------------------------------------------------
-- what they see
----------------------------------------------------------------------------------------------------------------
-- you killed one of theirs: when, how
function BR.learnKill(b, killer, h)
    if type(b) ~= "table" then return end
    local s = BR.of(b)
    s.lastHitBy, s.lastHitH = "you", h -- (the commander reads these: the one who hit them last)
    BR.youNote(b, "hrs", tostring(math.floor(hourOfDay() / 4)), h, 2)
    local night = hourOfDay() >= 21 or hourOfDay() < 5
    if night then BR.youNote(b, "style", "night", h) end
    local gun = false
    pcall(function() local it = killer:getPrimaryHandItem(); gun = it ~= nil and it:isRanged() == true end)
    BR.youNote(b, "style", gun and "guns" or "melee", h)
    local crew = false
    pcall(function() crew = type(M.partyCount) == "function" and (M.partyCount(killer) or 0) > 0 end)
    BR.youNote(b, "style", crew and "crew" or "alone", h)
    local x, y = nil, nil
    pcall(function() x, y = killer:getX(), killer:getY() end)
    if x then BR.youNote(b, "where", blockOf(x, y), h, 2) end
    LS.kills = LS.kills + 1
end
-- once an hour: groups that can see you (near their place) note where you are, and whether you're far from home
function BR.learnSight(player, h)
    if rate() <= 0 or player == nil then return end
    local x, y = nil, nil
    pcall(function() x, y = player:getX(), player:getY() end)
    if x == nil then return end
    local see2 = BR.num("knowSeeTiles") ^ 2
    local cx, cy = nil, nil
    if fn(BR, "youXY") then cx, cy = BR.youXY() end
    local farHome = cx ~= nil and d2(x, y, cx, cy) > 300 * 300
    for _, b in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if BR.runs(b) and tonumber(b.x) and d2(b.x, b.y, x, y) <= see2 then
            BR.youNote(b, "where", blockOf(x, y), h)
            local m = BR.youModel(b)
            if farHome then m.awayH = h else m.homeH = h end
            LS.sightings = LS.sightings + 1
        end
    end
end
-- your caravans going past them (the roads manager's traffic: run.from == "you")
local function learnRoad(run, h)
    if type(run) ~= "table" or run.from ~= "you" or run.brain then return end
    local x, y = BR.whereNow(run, h)
    local see2 = BR.num("knowSeeTiles") ^ 2
    local to = type(run.legs) == "table" and run.legs[run.leg or 1] and run.legs[run.leg or 1].to or run.target
    for _, b in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if BR.runs(b) and tonumber(b.x) and d2(b.x, b.y, x, y) <= see2 and to ~= nil and to ~= b.id then
            BR.youNote(b, "roads", tostring(to), h)
            BR.youNote(b, "where", blockOf(x, y), h, 0.5)
            BR.youModel(b).awayH = h
            LS.roads = LS.roads + 1
        end
    end
end
-- allies pass it on (half as sure)
local function share(b, h)
    if rate() <= 0 or b.isCamp then return end
    local day = math.floor(h / 24)
    for _, o in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if o.id ~= b.id and BR.tieState(BR.tie(b, o)) == "allied" and type(o.brain) == "table" and type(o.brain.youModel) == "table" and roll(b.id .. o.id .. "share" .. day) < 0.3 then
            local theirs = o.brain.youModel
            local mine = BR.youModel(b)
            for _, k in ipairs({ "hrs", "where", "roads", "style" }) do
                for key, v in pairs(theirs[k] or {}) do if (tonumber(mine[k][key]) or 0) < (tonumber(v) or 0) * 0.5 then mine[k][key] = (tonumber(v) or 0) * 0.5 end end
            end
            LS.shared = LS.shared + 1
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the counters (each costs them something real: guards off food, runs held back)
----------------------------------------------------------------------------------------------------------------
-- the hour block you usually come at: strong enough to act on (2+ times, half of all)
function BR.learnHotHour(b)
    local key, v, share = BR.youTop(b, "hrs")
    if key == nil or v < 2 or share < 0.4 then return nil end
    return tonumber(key)
end
-- your usual ground: map blocks seen 3+ times
function BR.learnYourGround(b)
    local out = {}
    for key, v in pairs(BR.youModel(b).where) do if (tonumber(v) or 0) >= 3 then local x, y = blockXY(key); if x then out[#out + 1] = { x = x, y = y, v = v } end end end
    return out
end
-- they saw you leave (and not come back since)
function BR.learnSawYouLeave(b, h)
    local m = BR.youModel(b)
    return m.awayH ~= nil and h - m.awayH < 12 and (m.homeH == nil or m.homeH < m.awayH)
end
-- raids on you come from the side you're seen least: a staging direction away from your usual ground
function BR.learnFlank(b, cx, cy)
    local ground = BR.learnYourGround(b)
    if #ground == 0 then return nil end
    local sx, sy, w = 0, 0, 0
    for _, g in ipairs(ground) do sx, sy, w = sx + (g.x - cx) * g.v, sy + (g.y - cy) * g.v, w + g.v end
    if w <= 0 then return nil end
    local dx, dy = -sx / w, -sy / w
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return nil end
    return cx + dx / len * 60, cy + dy / len * 60
end

local function install()
    M._alcpHooks = M._alcpHooks or {}
    -- you killed one of theirs (A-Life's NpcDied event -> M.nbOnDeath)
    if not M._alcpHooks.brainLearnDeath and fn(M, "nbOnDeath") then
        M._alcpHooks.brainLearnDeath = true
        local od = M.nbOnDeath
        M.nbOnDeath = function(body, uid, killer, ...)
            local b = nil
            pcall(function()
                local r = BR.PA().ActorRegistry.read(tostring(uid))
                local m = r and type(r.memory) == "table" and r.memory or nil
                b = m and m.havenId and BR.base(m.havenId) or nil
            end)
            local res = od(body, uid, killer, ...)
            if b and BR.on() and killer ~= nil then
                local isP = false
                pcall(function() isP = instanceof(killer, "IsoPlayer") == true end)
                if isP then pcall(BR.learnKill, b, killer, hours()) end
            end
            return res
        end
    end
    -- more guards at the hours you come (Defense, after the managers bid)
    K.wrap(BR, "allocate", "BrainLearnGuards", function(orig) return function(b, h, bids, ...)
        if type(b) == "table" and not b.isCamp and rate() > 0 and type(bids) == "table" then
            local hot = BR.learnHotHour(b)
            if hot ~= nil and math.floor(hourOfDay() / 4) == hot then
                for _, x in ipairs(bids) do
                    if x.job == "guard" then x.n = (tonumber(x.n) or 1) + math.max(1, math.floor((tonumber(b.crewN) or 1) * 0.2 * rate())); x.force = true; x.learned = true; LS.guards = LS.guards + 1; break end
                end
            end
        end
        return orig(b, h, bids, ...)
    end end)
    -- their traders keep off the roads you walk
    local t = ALifeTrade
    if type(t) == "table" and fn(t, "routeSafe") and not t._brainLearnSafe then
        t._brainLearnSafe = true
        local rs = t.routeSafe
        t.routeSafe = function(aId, bId, ...)
            local v = rs(aId, bId, ...)
            if rate() <= 0 or not BR.on() then return v end
            local ok, cut = pcall(function()
                local a, o = BR.base(aId), BR.base(bId)
                if a == nil or o == nil or (tonumber(a.rep) or 50) > 40 then return 0 end -- only groups at odds with you mind
                for _, g in ipairs(BR.learnYourGround(a)) do
                    if fn(BR, "roadOnLine") and BR.roadOnLine(g.x, g.y, a.x, a.y, o.x, o.y, BLOCK) then LS.rerouted = LS.rerouted + 1; return 20 * rate() end
                end
                return 0
            end)
            return clamp((tonumber(v) or 50) - (ok and cut or 0), 0, 100)
        end
    end
    -- raids on you from the side you're seen least
    K.wrap(BR, "fightBegin", "BrainLearnFlank", function(orig) return function(run, b, h, ...)
        if type(run) == "table" and run.target == "you" and type(b) == "table" and not b.isCamp and rate() > 0 then
            local fx, fy = BR.learnFlank(b, run.x1, run.y1)
            if fx then run.stageFrom = { x = fx, y = fy }; LS.flank = LS.flank + 1 end
        end
        return orig(run, b, h, ...)
    end end)
    -- war on you when they saw you leave; quiet while you're home (they wait a day)
    K.wrap(BR, "call", "BrainLearnWait", function(orig) return function(id, b, people, target, opts, ...)
        if id == "warParty" and type(b) == "table" and not b.isCamp and type(target) == "table" and target.to == "you" and rate() >= 1 then
            local m = BR.youModel(b)
            local h = hours()
            if m.homeH ~= nil and h - m.homeH < 6 and not BR.learnSawYouLeave(b, h) and (tonumber(m.waitedH) or -1e9) < h - 48 then
                m.waitedH = h
                LS.waited = LS.waited + 1
                BR.event(b, "Held off on the newcomer: they're home", "brain")
                return false, "waiting"
            end
        end
        return orig(id, b, people, target, opts, ...)
    end end)
    -- bigger demands if you always pay (they come back sooner)
    K.wrap(BR, "tributeToYou", "BrainLearnTribute", function(orig) return function(b, h, ...)
        local r = orig(b, h, ...)
        if r and type(b) == "table" and rate() > 0 then
            local paid = tonumber(BR.youModel(b).ans.paid) or 0
            if paid >= 2 and fn(ALifeTrade, "store") then
                for _, off in pairs(ALifeTrade.store().offers) do
                    if type(off) == "table" and off.tribute and off.from == b.id then off.every = math.max(3, 7 - math.floor(paid)); off.more = true end
                end
            end
        end
        return r
    end end)
    -- how you answer (the brain's tribute answer hook writes s.answers.you)
    if fn(M, "trDealAnswer") and not M._alcpHooks.brainLearnAns then
        M._alcpHooks.brainLearnAns = true
        local da = M.trDealAnswer
        M.trDealAnswer = function(offerId, yes, player, ...)
            local off = fn(ALifeTrade, "store") and ALifeTrade.store().offers[tostring(offerId or "")] or nil
            if type(off) == "table" and off.tribute then
                local b = BR.base(off.from)
                local ok = yes == true or yes == "true" or yes == 1
                if b then pcall(BR.youNote, b, "ans", ok and "paid" or "refused", hours()); LS.answers = LS.answers + 1 end
            end
            return da(offerId, yes, player, ...)
        end
    end
    K.wrap(BR, "tributeExpire", "BrainLearnIgnored", function(orig) return function(h, ...)
        local before = {}
        if fn(ALifeTrade, "store") then for id, off in pairs(ALifeTrade.store().offers) do if type(off) == "table" and off.tribute then before[id] = off.from end end end
        local r = orig(h, ...)
        if fn(ALifeTrade, "store") then for id, from in pairs(before) do if ALifeTrade.store().offers[id] == nil then local b = BR.base(from); if b then BR.youNote(b, "ans", "ignored", h) end end end end
        return r
    end end)
    -- allies pass it on (daily, with what they know)
    K.wrap(BR, "knowDay", "BrainLearnShare", function(orig) return function(b, h, ...)
        local r = orig(b, h, ...)
        if type(b) == "table" and not b.isCamp then pcall(share, b, h) end
        return r
    end end)
    -- their words show it
    K.wrap(BR, "line", "BrainLearnLine", function(orig) return function(b, h, ...)
        local l = orig(b, h, ...)
        local said = BR.learnLine(b)
        if said and type(b) == "table" and roll(tostring(b.id) .. "ll" .. math.floor(hours())) < 0.4 then return said end
        return l
    end end)
    K.wrap(BR, "why", "BrainLearnWhy", function(orig) return function(b, h, ...)
        local w = orig(b, h, ...)
        local said = BR.learnLine(b)
        if said then return (w and (tostring(w) .. " ") or "") .. "What they've noticed about the newcomer: " .. said end
        return w
    end end)
    return true
end
BR.LEARN_HOURS = { [0] = "in the dead of night", [1] = "at first light", [2] = "in the morning", [3] = "in the afternoon", [4] = "in the evening", [5] = "at night" }
-- one line a member might say to you (nil = nothing they've noticed yet)
function BR.learnLine(b)
    if type(b) ~= "table" or b.isCamp or rate() <= 0 then return nil end
    local m = BR.youModel(b)
    local st, sv = BR.youTop(b, "style")
    local hot = BR.learnHotHour(b)
    if hot ~= nil then
        if (tonumber(m.style.night) or 0) >= 2 then return "You always come at night. We'll be waiting." end
        return "You always come " .. (BR.LEARN_HOURS[hot] or "at the same time") .. ". We've noticed."
    end
    if st == "guns" and sv >= 2 then return "We hear you coming. You're not quiet with that gun." end
    if st == "alone" and sv >= 2 then return "Always on your own. That's going to catch up with you." end
    local paid = tonumber(m.ans.paid) or 0
    if paid >= 2 then return "You always pay. Good. Keep it coming." end
    local road = BR.youTop(b, "roads")
    if road and (tonumber(m.roads[road]) or 0) >= 2 then local o = BR.base(road); return "Your people use the road to " .. tostring(o and o.name or "the east") .. " a lot." end
    return nil
end
BR.installers[#BR.installers + 1] = install
pcall(install)
do
    local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrainLearn")
    K.hourly(TAG, function(p, h)
        if not BR.on() or rate() <= 0 then return end
        if ALifeSide.mpServer() then for _, pl in ipairs(ALifeSide.online() or {}) do pcall(BR.learnSight, pl, h) end else pcall(BR.learnSight, p, h) end
        local t = ALifeTrade
        if fn(t, "store") then for _, run in pairs(t.store().runs) do pcall(learnRoad, run, h) end end
    end)
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": learning " .. ({ [0] = "off", [1] = "slow", [2] = "on" })[math.floor(BR.num("brainLearn"))] .. ", fades over " .. BR.num("learnFadeDays") .. " days")
        end)
    end
end
