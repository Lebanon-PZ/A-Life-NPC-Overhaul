-- A-Life NPC Overhaul pre-1.0: BRAIN B1, KNOWLEDGE (docs/PLAN-BRAIN.md). Fog of war for NPC groups.
-- A group only knows what it saw or was told: its own scouts, its traders' visits, other groups' traders, radio
-- talk, fights, allies sharing, and you (claims you make; a lie caught costs trust). Beliefs age and die; far news
-- arrives late and goes stale sooner. Committing people (war, siege) needs fresh, sure intel; weak intel only sends
-- a scout. Setting brainCheat 1 gives a fuzzy look at the truth. Their own side is always known (the ledger).
-- Cost: beliefs change on events and once a day per group; nothing scans the map.
require "ALifeNPCOverhaul/ALifeBrain"
local BR = ALifeBrain
local M = BR and BR.M
if type(BR) ~= "table" or type(M) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll

local FIELDS = { "x", "y", "str", "crew", "food", "mood", "hostile", "wealth", "stage", "walls", "name", "holds" } -- holds: a road point they hold (Brain 2 roads)

-- where the player's camp is ("you" as a group)
function BR.youXY()
    local T = ALifeTrade
    if fn(T, "placeXY") then local ok, x, y = pcall(T.placeXY, "you"); if ok and tonumber(x) then return x, y end end
    local p = ALifeSide.you()
    if p and fn(M, "playerBase") then
        local ok, base = pcall(M.playerBase, p)
        if ok and type(base) == "table" and tonumber(base.x1) then return (base.x1 + base.x2) / 2, (base.y1 + base.y2) / 2 end
    end
    return nil
end
local function xyOf(id)
    if id == "you" then return BR.youXY() end
    local o = BR.base(id)
    if o then return tonumber(o.x), tonumber(o.y) end
    return nil
end

-- the real state of a group (what a sure, close look would show)
function BR.truth(id)
    if id == "you" then
        local x, y = BR.youXY()
        if x == nil then return nil end
        local L, p = ALifeKingmaker, ALifeSide.you()
        local str, crew = 1, 1
        if fn(L, "mine") then local ok, s = pcall(L.mine, p); if ok and tonumber(s) then str = s end end
        if fn(L, "people") then local ok, n = pcall(L.people, p); if ok and tonumber(n) then crew = n end end
        local post = fn(M, "tpStore") and M.tpStore().post or nil
        local items = type(post) == "table" and tonumber(post.items) or 0
        return { x = x, y = y, str = str, crew = crew, wealth = items >= 40 and 2 or (items >= 12 and 1 or 0), name = "your camp" }
    end
    local o = BR.base(id)
    if o == nil then return nil end
    local mood = fn(M, "nbMood") and select(1, M.nbMood(o)) or "steady"
    local wealth = 0
    if type(ALifeWorth) == "table" and fn(ALifeWorth, "wealthWord") then
        local ok, w = pcall(ALifeWorth.wealthWord, o)
        w = ok and tostring(w) or ""
        if w == "rich" or w == "comfortable" then wealth = 2 elseif w == "getting by" then wealth = 1 end
    else
        wealth = BR.foodDays(o) >= 7 and 2 or (BR.foodDays(o) >= 3 and 1 or 0)
    end
    local walls = 0
    if type(o.bd) == "table" then walls = tonumber(o.bd.layer) or (BR.count(o.bd.walls) > 0 and 1 or 0) end
    return { x = tonumber(o.x), y = tonumber(o.y), str = BR.str(o), crew = tonumber(o.crewN) or 0, food = BR.foodDays(o), mood = mood,
        wealth = wealth, stage = o.stage, walls = walls, name = o.name,
        hostile = (o.dir and (o.dir.creed == "raiders")) or o.trade == "warband" or o.trade == "slavers" or false }
end

-- how sure they are now: confidence fades with age, faster for far places
local function decayDays(b, k)
    local base = math.max(1, BR.num("knowDecayDays"))
    if tonumber(k.x) and tonumber(b.x) then
        local dist = math.sqrt(d2(k.x, k.y, b.x, b.y))
        base = base / (1 + BR.num("knowFarDecay") / 100 * dist / 1000)
    end
    return base
end
function BR.confNow(b, k, h)
    if type(k) ~= "table" then return 0 end
    h = h or hours()
    local age = math.max(0, h - (tonumber(k.h) or h)) / 24
    return clamp((tonumber(k.conf) or 0) * (1 - age / decayDays(b, k)), 0, 1)
end

-- a stable fuzz on a number by how unsure the source is
local function fuzz(v, conf, key)
    v = tonumber(v)
    if v == nil then return nil end
    local f = (roll(key) - 0.5) * 2 * (1 - conf) * 0.6
    return math.max(0, v * (1 + f))
end

-- learn: fields seen / told, with a confidence, from a source
function BR.learn(b, id, fields, conf, src, h)
    if type(b) ~= "table" or id == nil or id == b.id or type(fields) ~= "table" then return nil end
    local s = BR.of(b)
    h = h or hours()
    id = tostring(id)
    local k = s.know[id]
    local fresh = k == nil
    if fresh then k = {}; s.know[id] = k; BR.stats.beliefs = BR.stats.beliefs + 1 end
    local nowC = BR.confNow(b, k, h)
    -- a lie caught: what you claimed, and now a sure look says otherwise
    if k.claim and conf >= 0.75 and src ~= "you" then
        local c = k.claim
        local caught = false
        if c.str and tonumber(fields.str) and fields.str > 0 then local r = c.str / fields.str; if r > 1.6 or r < 0.6 then caught = true end end
        if c.food and tonumber(fields.food) and math.abs(c.food - fields.food) > 3 then caught = true end
        if c.hostile ~= nil and fields.hostile ~= nil and c.hostile ~= fields.hostile then caught = true end
        k.claim = nil
        if caught then
            s.youTrust = clamp((tonumber(s.youTrust) or 50) - 20, 0, 100)
            BR.stats.lies = BR.stats.lies + 1
            if fn(M, "nbRep") then pcall(M.nbRep, b, -5, "You lied to them about " .. tostring(k.name or "another group")) end
            BR.event(b, "Found out the newcomer lied to them about " .. tostring(k.name or "another group"), "brain")
            if fn(BR, "grudge") then BR.grudge(b, "you", 10, "lied to them") end
        else
            s.youTrust = clamp((tonumber(s.youTrust) or 50) + 5, 0, 100)
        end
    end
    -- newer or surer wins, field by field (a fresh rumour doesn't overwrite a sure look from yesterday)
    if fresh or conf >= nowC * 0.8 or (h - (tonumber(k.h) or 0)) > 24 then
        for _, f in ipairs(FIELDS) do
            local v = fields[f]
            if v ~= nil then
                if f == "str" or f == "crew" or f == "food" then v = fuzz(v, conf, tostring(b.id) .. id .. f .. math.floor(h / 24)) end
                if f == "crew" and v then v = math.floor(v + 0.5) end
                k[f] = v
            end
        end
        k.conf, k.h, k.src = conf, h, src
        if src == "you" then k.claim = { str = fields.str, food = fields.food, hostile = fields.hostile, h = h } end
    end
    return k
end

-- what they believe now (nil = nothing worth acting on). brainCheat 1: a fuzzy look at the truth fills the gaps.
function BR.belief(b, id, h)
    if type(b) ~= "table" then return nil end
    h = h or hours()
    local s = BR.of(b)
    local k = s.know[tostring(id)]
    local c = BR.confNow(b, k, h)
    if BR.num("brainCheat") >= 1 and c < 0.5 then
        local t = BR.truth(id)
        if t then
            local out = { conf = 0.5, h = h, src = "cheat", c = 0.5 }
            for _, f in ipairs(FIELDS) do out[f] = t[f] end
            out.str = fuzz(out.str, 0.5, tostring(b.id) .. tostring(id) .. "cheat" .. math.floor(h / 24))
            return out
        end
    end
    if k == nil or c < 0.05 then return nil end
    local out = {}
    for kk, v in pairs(k) do out[kk] = v end
    out.c = c
    return out
end
-- every group they believe in, nearest first: { { id, k } }
function BR.known(b, h)
    h = h or hours()
    local s = BR.of(b)
    local out = {}
    local ids = BR.sortedKeys(s.know)
    if BR.num("brainCheat") >= 1 and fn(M, "nbActive") then
        local seen = {}
        for _, id in ipairs(ids) do seen[id] = true end
        for _, o in ipairs(M.nbActive()) do if o.id ~= b.id and not seen[o.id] and not o.outpostOf then ids[#ids + 1] = o.id end end
    end
    for _, id in ipairs(ids) do
        local k = BR.belief(b, id, h)
        if k and (id == "you" or BR.base(id)) then
            k.id = id
            k.dist = (tonumber(k.x) and tonumber(b.x)) and math.sqrt(d2(k.x, k.y, b.x, b.y)) or 1e6
            out[#out + 1] = k
        end
    end
    table.sort(out, function(a, c) if a.dist ~= c.dist then return a.dist < c.dist end return tostring(a.id) < tostring(c.id) end)
    return out
end

-- news that has to travel: it arrives later the farther it comes from (messenger / rumour hops)
function BR.hear(b, id, fields, conf, src, fromX, fromY, h)
    if type(b) ~= "table" or id == b.id then return end
    h = h or hours()
    local delay = 0
    if tonumber(fromX) and tonumber(b.x) then
        local dist = math.sqrt(d2(fromX, fromY, b.x, b.y))
        delay = 2 + dist / 1000 * 12
    end
    if delay <= 0.5 then return BR.learn(b, id, fields, conf, src, h) end
    local s = BR.of(b)
    s.inbox[#s.inbox + 1] = { id = tostring(id), f = fields, c = conf, src = src, at = h + delay, seenH = h }
    while #s.inbox > 10 do table.remove(s.inbox, 1) end
end
function BR.inboxTick(b, h)
    local s = BR.of(b)
    local keep = {}
    for _, e in ipairs(s.inbox) do
        if h >= (tonumber(e.at) or 0) then
            -- what they hear is how it was when it was said: aged by the trip
            local k = BR.learn(b, e.id, e.f or {}, tonumber(e.c) or 0.3, e.src, h)
            if k and tonumber(e.seenH) then k.h = e.seenH end
        else keep[#keep + 1] = e end
    end
    s.inbox = keep
end

-- importance (what they keep when the list is full): sure, close, dangerous
local function importance(b, id, k, h)
    local c = BR.confNow(b, k, h)
    local dist = (tonumber(k.x) and tonumber(b.x)) and math.sqrt(d2(k.x, k.y, b.x, b.y)) or 3000
    local v = c * (1 + 1000 / math.max(100, dist))
    if k.hostile then v = v * 2 end
    if id == "you" then v = v * 1.5 end
    if type(BR.of(b).grudges[id]) == "table" then v = v * 2 end
    return v
end
function BR.knowPrune(b, h)
    local s = BR.of(b)
    local list = {}
    for id, k in pairs(s.know) do
        if type(k) ~= "table" or BR.confNow(b, k, h) < 0.05 or (id ~= "you" and BR.base(id) == nil) then s.know[id] = nil
        else list[#list + 1] = { id = id, v = importance(b, id, k, h) } end
    end
    local max = math.max(2, math.floor(BR.num("knowMax")))
    if #list <= max then return end
    table.sort(list, function(a, c) if a.v ~= c.v then return a.v > c.v end return tostring(a.id) < tostring(c.id) end)
    for i = max + 1, #list do s.know[list[i].id] = nil end
end

-- once a day: what they see over the fence, hear on the radio, and what allies tell them
function BR.knowDay(b, h)
    if not fn(M, "nbActive") then return end
    local see2 = BR.num("knowSeeTiles") ^ 2
    local radio2 = BR.num("knowRadioTiles") ^ 2
    local heard = 0
    local day = math.floor(h / 24)
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and tonumber(o.x) and tonumber(b.x) and not o.outpostOf then
            local dd = d2(o.x, o.y, b.x, b.y)
            local t = nil
            if dd <= see2 then
                -- neighbours: people coming and going, the boards on the windows, who carries a gun (no stash)
                t = t or BR.truth(o.id)
                if t then BR.learn(b, o.id, { x = t.x, y = t.y, crew = t.crew, stage = t.stage, walls = t.walls, str = t.str, hostile = t.hostile, name = t.name }, 0.6, "sight", h) end
            elseif dd <= radio2 and heard < 3 and BR.tie(b, o) >= -20 and BR.roll(b.id .. o.id .. "#radio" .. day) < 0.35 then
                -- radio talk: rumour-grade, and late
                heard = heard + 1
                t = t or BR.truth(o.id)
                if t then BR.hear(b, o.id, { x = t.x, y = t.y, crew = t.crew, mood = t.mood, hostile = t.hostile, name = t.name, str = t.str }, 0.4, "radio", o.x, o.y, h) end
            end
            -- allies share what they know (copies, less sure)
            if BR.tieState(BR.tie(b, o)) == "allied" and type(o.brain) == "table" and type(o.brain.know) == "table" then
                local n = 0
                for _, id in ipairs(BR.sortedKeys(o.brain.know)) do
                    if n >= 4 then break end
                    if id ~= b.id then
                        local k = o.brain.know[id]
                        local c = BR.confNow(o, k, h) * 0.7
                        local mine = BR.of(b).know[id]
                        if c > 0.1 and c > BR.confNow(b, mine, h) then
                            local f = {}
                            for _, x in ipairs(FIELDS) do f[x] = k[x] end
                            local kk = BR.learn(b, id, f, c, "ally", h)
                            if kk then kk.h = k.h end
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    -- you: once they've heard of you, word of your place keeps reaching them (weak)
    if b.knowsYou or b.radioKnown or b.known == "visited" then
        local k = BR.of(b).know.you
        if BR.confNow(b, k, h) < 0.4 then
            local t = BR.truth("you")
            if t then BR.learn(b, "you", t, 0.4, "word", h) end
        end
    end
    BR.inboxTick(b, h)
    BR.knowPrune(b, h)
end

-- a fight: both sides learn the other's real strength; groups in radio range hear of it
function BR.knowFight(by, on, h, won)
    h = h or hours()
    for _, pair in ipairs({ { by, on }, { on, by } }) do
        local x, y = pair[1], pair[2]
        if type(x) == "table" and type(y) == "table" and x.status == "active" then
            local t = BR.truth(y.id)
            if t then t.hostile = true; BR.learn(x, y.id, t, 0.9, "fight", h) end
        end
    end
    -- the mind keeps score: the hit side holds a grudge; the attacker remembers how it went
    if type(by) == "table" and type(on) == "table" and fn(BR, "grudge") then
        BR.grudge(on, by.id, won and 25 or 10, won and "raided them" or "tried to raid them")
        local so = BR.of(on)
        so.lastHitBy, so.lastHitH, so.lastHitStr = by.id, h, BR.str(by)
        BR.remember(by, "raid:" .. tostring(on.id), won and "wins" or "losses", 1, h)
        BR.remember(by, "raid:" .. tostring(on.id), "tries", 1, h)
        BR.interrupt(on, "raided", { a = by.id })
    end
    if not fn(M, "nbActive") or type(on) ~= "table" or not tonumber(on.x) then return end
    local r2 = BR.num("knowRadioTiles") ^ 2
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= by.id and o.id ~= on.id and tonumber(o.x) and d2(o.x, o.y, on.x, on.y) <= r2 then
            BR.hear(o, by.id, { x = by.x, y = by.y, hostile = true, name = by.name }, 0.3, "rumour", on.x, on.y, h)
        end
    end
end

-- trade visits: the traveller's group sees the place they reached; the hosts see the traders and hear their news
function BR.knowVisit(from, to, h)
    if type(from) ~= "table" or type(to) ~= "table" then return end
    h = h or hours()
    local t = BR.truth(to.id)
    if t then BR.learn(from, to.id, t, 0.7, "trade", h) end
    local u = BR.truth(from.id)
    if u then BR.learn(to, from.id, { x = u.x, y = u.y, crew = u.crew, mood = u.mood, wealth = u.wealth, name = u.name, hostile = u.hostile }, 0.5, "visitors", h) end
    -- second hand: what the traders' group knows, passed on over a meal (three things, less sure)
    if type(from.brain) == "table" and type(from.brain.know) == "table" then
        local n = 0
        for _, id in ipairs(BR.sortedKeys(from.brain.know)) do
            if n >= 3 then break end
            if id ~= to.id then
                local k = from.brain.know[id]
                local c = BR.confNow(from, k, h) * 0.5
                if c > 0.1 and c > BR.confNow(to, BR.of(to).know[id], h) then
                    local f = {}
                    for _, x in ipairs(FIELDS) do f[x] = k[x] end
                    local kk = BR.learn(to, id, f, c, "second", h)
                    if kk then kk.h = k.h end
                    n = n + 1
                end
            end
        end
    end
end

-- what you tell them ("Ridge is weak", "Mill Farm is starving", "the Fort is coming for you"): a claim,
-- as sure as they trust you; a later sure look checks it
BR.CLAIM_WORDS = {
    { w = { "weak", "easy pickings", "nothing left", "falling apart" }, f = function(t) return { str = (t.str or 4) * 0.4 } end },
    { w = { "strong", "dangerous", "armed to the teeth", "too many" }, f = function(t) return { str = (t.str or 4) * 2 } end },
    { w = { "starving", "out of food", "hungry" }, f = function() return { food = 0.5 } end },
    { w = { "rich", "loaded", "stocked up" }, f = function(t) return { wealth = 2, food = math.max(8, t.food or 8) } end },
    { w = { "coming for you", "after you", "hostile", "want you dead" }, f = function() return { hostile = true } end },
    { w = { "friendly", "harmless", "peaceful" }, f = function() return { hostile = false } end },
}
function BR.claimFromWords(b, text, h)
    if not BR.runs(b) or type(text) ~= "string" or not fn(M, "nbActive") then return nil end
    local low = " " .. string.lower(text) .. " "
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id then
            local core = string.lower(string.gsub(tostring(o.name or ""), "^[Tt]he ", ""))
            if #core >= 4 and string.find(low, core, 1, true) then
                for _, row in ipairs(BR.CLAIM_WORDS) do
                    for _, w in ipairs(row.w) do
                        if string.find(low, w, 1, true) then
                            local s = BR.of(b)
                            local trust = (tonumber(s.youTrust) or 50) / 100 * clamp((tonumber(b.rep) or 50) / 60, 0.2, 1.2)
                            local cur = BR.belief(b, o.id, h) or {}
                            local f = row.f(cur)
                            f.x, f.y, f.name = o.x, o.y, o.name
                            if (tonumber(cur.c) or 0) <= clamp(trust, 0.1, 0.7) then BR.learn(b, o.id, f, clamp(trust, 0.1, 0.7), "you", h) end
                            return o.id
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function install()
    M._alcpHooks = M._alcpHooks or {}
    if not M._alcpHooks.brainKnowWm and fn(M, "wmRecord") then
        M._alcpHooks.brainKnowWm = true
        local rec = M.wmRecord
        M.wmRecord = function(by, on, h, won, ...)
            local r = rec(by, on, h, won, ...)
            if BR.on() then pcall(BR.knowFight, by, on, h, won) end
            return r
        end
    end
    local T = ALifeTrade
    if type(T) == "table" and type(T.onLeg) == "table" and not T._brainKnowLeg then
        T._brainKnowLeg = true
        T.onLeg[#T.onLeg + 1] = function(run, leg, gave, got, why)
            if not BR.on() or type(leg) ~= "table" or run.from == "you" or leg.to == "you" then return end
            if run.brain then return end -- scouts / envoys / war parties learn in ALifeBrainWar
            pcall(BR.knowVisit, BR.base(run.from), BR.base(leg.to), hours())
        end
    end
    if type(M.playerWordHooks) == "table" and not M._alcpHooks.brainClaims then
        M._alcpHooks.brainClaims = true
        table.insert(M.playerWordHooks, function(player, text, loud, hearers)
            if not BR.on() then return end
            local l = type(hearers) == "table" and hearers[1] or nil
            local b = l and l.record and fn(M, "nbOfMember") and M.nbOfMember(l.record) or nil
            if b then pcall(BR.claimFromWords, b, text, hours()) end
        end)
    end
    return M._alcpHooks.brainKnowWm == true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
