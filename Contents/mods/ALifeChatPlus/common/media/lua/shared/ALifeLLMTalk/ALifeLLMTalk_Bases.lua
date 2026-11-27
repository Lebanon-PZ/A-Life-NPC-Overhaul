-- A-Life Talk 0.5.2: NPC BASES. Groups (and loners) settle down in real houses and make them their own.
-- A-Life already has "Havens": a loaded natural group of 2+ may claim the nearest free building (or a camp) once a
-- day, walk back to it (return_base / haven_idle), do camp chores (CampLife), keep a stash, greet players it knows,
-- tell people where it lives and drop a map marker, and give it up when stale / crew gone / the player took it.
-- What this file adds on top, using A-Life's own Haven store and APIs (so A-Life's sim, patrols, stash, greetings
-- and offline logic treat these as real bases):
--  * founding decided by people: homebody vs nomad personality, group size, how long they've wandered, injuries,
--    the season (settle before winter), food and threats; loners too; works for unloaded (offline) people
--  * house choice: buildings scouted around them (A-Life's meta grid, also offline), scored by size, rooms
--    (kitchen / bathroom / bedrooms / storage = water, food, beds), doors / windows (when loaded), hordes,
--    distance; never the player's base, a safehouse, another group's place (A-Life's own exclusion rules + ours)
--  * the base as a place: a name ("the Mill House"), a leader, members, morale, food (person-days), a reputation
--    with you, a short history, growth squat -> camp -> fortified (real boarding by members inside through the
--    patch's barricade care; otherwise throttled work), daily life anchored at the base (night guard, sleep
--    inside, scavenge / chop / patrol by day)
--  * the world: hordes / raiders attack (offline, throttled), bases can be overrun (final deaths, scen73 rules),
--    abandoned on starvation or morale collapse (members become travellers again), and grow by taking in loners
--  * you: visits are remembered, welcome / turned away by standing, bond tier, reputation and raids; ask to stay
--    the night; merge their group into your base; helping defend raises your standing, raiding / killing lowers it
--  * the AI knows it all (own base + gossip about other bases); the Places window lists the bases you know
-- Settings: npcBases (master switch), npcBasesMax, npcBaseRate, npcBaseDanger. Nothing per frame: a 5 s presence
-- check (cheap bounds test), one base simulated per minute, one founding pass per 2 minutes, cached building scores.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Bases") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Bases"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Bases") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) if M.log then M.log("bases: " .. tostring(msg)) end end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function H() return PA().Havens end
local function hours()
    local hv = H()
    if fn(hv, "hours") then local ok, v = pcall(hv.hours); if ok and tonumber(v) then return tonumber(v) end end
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return h
end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r)
    if type(r) == "table" and r.virtual then return r.name or "one of them" end -- 0.5.2.1: an unseen squad member
    local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone"
end
local function firstOf(r)
    if type(r) == "table" and r.virtual then return r.first or "one of them" end
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function shellFor(uid) local pa = PA(); return fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil end
local function opinion(r, player) local v = nil; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end); return v end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function isEmpty(t) for _ in pairs(t) do return false end return true end
local function inside(b, x, y, pad)
    pad = pad or 0
    return type(b) == "table" and x ~= nil and x >= b.x1 - pad and x <= b.x2 + pad and y >= b.y1 - pad and y <= b.y2 + pad
end
local function overlaps(a, b, pad)
    pad = pad or 0
    return type(a) == "table" and type(b) == "table" and tonumber(a.x1) and tonumber(b.x1)
        and a.x1 - pad <= b.x2 and a.x2 + pad >= b.x1 and a.y1 - pad <= b.y2 and a.y2 + pad >= b.y1
end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function thePlayer() return ALifeSide.you() end
-- pre-1.0 MP (P5): NPC bases are world places shared by everyone. On a server: "near you" = near ANY online player
-- (the nearest one stands in for you), "your base" = any online player's base, "in your party" = anyone's party.
-- Visits are counted per player (nbAtBy). Single player: unchanged.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function everyone() if mpServer() then return ALifeSide.online() end; local p = thePlayer(); return p ~= nil and { p } or {} end
local function nearestTo(x, y) if mpServer() and x ~= nil then return ALifeSide.nearest(x, y) end; return thePlayer() end

setting("npcBases", true)       -- master switch
setting("npcBasesMax", 6)       -- most NPC bases at once (A-Life's own activitiesMaxBases cap still applies)
setting("npcBaseRate", 100)     -- founding rate, percent (0 = nobody founds new ones; existing bases still live)
setting("npcBaseDanger", true)  -- attacks / overruns (with final deaths) happen to bases while you're away
setting("honestScavenge", true) -- 0.6.0: NPC scavenging takes from real buildings, which then stay bare (ALifeDerelict)
setting("derelictDebug", false) -- 0.6.0: console detail on which buildings were stripped (off: counts only)
setting("npcForage", true)
setting("darkContent", false)
setting("itemWorth", true)     -- 0.6.14: every item has a worth from its own data (trades, raids, wealth)
setting("caravans", true)      -- 0.6.6: real people and real goods in Jeem's trader visits; groups trade off screen
setting("outposts", true)      -- 0.6.5: big groups send a few people to hold police stations, clinics, gas stations...
setting("nomads", true)        -- 0.6.5: starving groups on stripped land move on (off = they scatter, like before)   -- 0.6.4: slavers (and later executions, captives broken by force); off by default      -- 0.6.0: people at home forage / hunt a little food (renewable); off = only what they loot or trade
-- (settings rows: ALifeLLMTalk_UIBond)

M.nbCfg = {
    tickMs = 5000, simMs = 60000, foundMs = 120000, perPass = 3,
    probeRadii = { 8, 16, 26, 38, 50 }, probeAngles = 8, minArea = 20, maxArea = 600, scoreCache = 300, scoreTtlH = 24,
    minAgeH = 12, settleNeed = 45, campWork = 30, fortWork = 100, workPerCrewH = 0.35, careWork = 6,
    maxStepH = 24, maxCatchH = 72, homeTiles = 40, farTiles = 150, nearTiles = 120, visitPad = 4,
    foodStartDays = 3, foodCapDays = 20, -- foodStartDays: unused since 0.6.0 (a base starts with what its people carry)
    foodPerItem = 0.25,          -- 0.6.0: person-days per food item carried (the same 4 items = 1 day the stash uses)
    forageRate = 0.6,            -- 0.6.0: person-days a day each person at home forages / hunts (was 1.1 made from nothing)
    forageTown = 0.6,            -- 0.6.0: in town that's x0.6 (less to forage)
    starveCover = 0.5,           -- 0.6.0: out of food AND foraging covers less than half of what they eat = starving
    freshCapDays = 2,            -- 0.6.1: foraging surplus kept as fresh food, at most this many days a head
    abandonH = 48, lowMorale = 10, recruitTiles = 150, recruitMorale = 55, memberCap = 8,
    attackPerDay = 0.05, eventsKeep = 12, endedKeep = 30, guestH = 14, raidRep = 30, theftRep = 4, defendRepDay = 5,
    gossipTiles = 900, gossipMax = 2,
    reclaimH = 96, -- 0.5.2.1: a fallen / abandoned house is off-limits for 4 in-game days, then free to claim
}
-- 0.6.0: food a set of people really carries (A-Life keeps it per person: shellState.carried), in person-days.
-- Members can be A-Life records (memory.shellState) or offline squad members (shellState).
M.nbFoodType = M.nbFoodType or {}
function M.nbIsFood(t)
    if type(t) ~= "string" then return false end
    local c = M.nbFoodType[t]
    if c ~= nil then return c end
    c = false
    local D = ALifeDerelict
    if type(D) == "table" and type(D.KINDS) == "table" and D.KINDS[t] ~= nil then c = D.KINDS[t] == "food"
    elseif type(instanceItem) == "function" and type(instanceof) == "function" then
        pcall(function() local it = instanceItem(t); c = it ~= nil and instanceof(it, "Food") == true end)
    end
    M.nbFoodType[t] = c
    return c
end
function M.nbCarriedFood(people)
    local n = 0
    for _, p in ipairs(people or {}) do
        local st = type(p) == "table" and ((type(p.shellState) == "table" and p.shellState) or (type(p.memory) == "table" and type(p.memory.shellState) == "table" and p.memory.shellState)) or nil
        for _, e in ipairs(st and type(st.carried) == "table" and st.carried or {}) do
            local t = type(e) == "table" and e.type or e
            if M.nbIsFood(t) then n = n + 1 end
        end
    end
    return n * M.nbCfg.foodPerItem
end
-- 0.6.1: THE LEDGER. A base's goods are its stash: A-Life's haven stash (a list of item types while nobody is near)
-- and its depot container (real items once loaded). Food: they eat those items (4 items = 1 person-day), after a
-- small "rations" buffer (food from before 0.6.1, foraging surplus, gifts, raids). Nothing is made: every change
-- to food goes through M.nbFoodTake (removes real items) or M.nbFoodAdd (rations, from a real source).
M.nbKindCache = M.nbKindCache or {}
M.nbGoodsKinds = { "food", "water", "meds", "ammo", "tools", "materials", "fuel" }
function M.nbKindOf(t)
    if type(t) ~= "string" then return "other" end
    local c = M.nbKindCache[t]
    if c ~= nil then return c end
    c = "other"
    local D = ALifeDerelict
    local k = type(D) == "table" and type(D.KINDS) == "table" and D.KINDS[t] or nil
    if k then c = ({ food = "food", med = "meds", ammo = "ammo", tools = "tools", misc = "other" })[k] or "other"
    elseif string.find(t, "PetrolCan", 1, true) or string.find(t, "JerryCan", 1, true) or string.find(t, "GasCan", 1, true) or string.find(t, "Gasoline", 1, true) then c = "fuel" -- 0.6.11
    elseif string.find(t, "Water", 1, true) then c = "water"
    elseif type(instanceItem) == "function" then
        pcall(function()
            local it = instanceItem(t)
            if it == nil then return end
            if type(instanceof) == "function" and instanceof(it, "Food") then c = "food"; return end
            local cat = tostring(it:getDisplayCategory() or "")
            if cat == "FirstAid" or cat == "Medical" then c = "meds"
            elseif cat == "Ammo" then c = "ammo"
            elseif cat == "Tool" or cat == "ToolWeapon" then c = "tools"
            elseif cat == "Material" then c = "materials" end
        end)
    end
    M.nbKindCache[t] = c
    return c
end
function M.nbHavenOf(b)
    local hv = H()
    return b and fn(hv, "of") and hv.of(b.id) or nil
end
local function stashList(haven)
    local hv = H()
    if haven == nil or not fn(hv, "stashOf") then return nil end
    local ok, st = pcall(hv.stashOf, haven)
    return ok and type(st) == "table" and type(st.items) == "table" and st.items or nil
end
-- 0.6.5: create = make the stash list on a brand-new house (A-Life may only make it on first deposit)
M.nbStashList = function(haven, create)
    local l = stashList(haven)
    if l or not create or type(haven) ~= "table" then return l end
    haven.stock = type(haven.stock) == "table" and haven.stock or {}
    haven.stock.stash = type(haven.stock.stash) == "table" and haven.stock.stash or {}
    haven.stock.stash.items = type(haven.stock.stash.items) == "table" and haven.stock.stash.items or {}
    return stashList(haven) or haven.stock.stash.items
end
local function depotBox(haven)
    local hv = H()
    if haven == nil or type(haven.depot) ~= "table" or not fn(hv, "containerAt") then return nil end
    local ok, c = pcall(hv.containerAt, haven.depot)
    return ok and c or nil
end
-- count goods (stash list + loaded depot), refresh b.food = rations + food items
function M.nbFoodSync(b, haven)
    if b.ledgerV == nil then b.rations, b.ledgerV = tonumber(b.food) or 0, 1 end -- older saves keep the food they had
    haven = haven or M.nbHavenOf(b)
    local goods = { food = 0, water = 0, meds = 0, ammo = 0, tools = 0, materials = 0 }
    for _, e in ipairs(stashList(haven) or {}) do
        local k = M.nbKindOf(type(e) == "table" and e.type or e)
        if goods[k] then goods[k] = goods[k] + 1 end
    end
    local box = depotBox(haven)
    if box then
        pcall(function()
            local items = box:getItems()
            for i = 0, items:size() - 1 do
                local k = M.nbKindOf(items:get(i):getFullType())
                if goods[k] then goods[k] = goods[k] + 1 end
            end
        end)
    end
    b.goods = goods
    b.food = (tonumber(b.rations) or 0) + goods.food * M.nbCfg.foodPerItem
    return goods
end
-- take up to pd person-days of food: rations first, then real food items (stash, then depot). Returns what was taken.
function M.nbFoodTake(b, pd, haven)
    pd = tonumber(pd) or 0
    if pd <= 0 then return 0 end
    if b.ledgerV == nil then M.nbFoodSync(b, haven) end
    local taken = math.min(pd, math.max(0, tonumber(b.rations) or 0))
    b.rations = (tonumber(b.rations) or 0) - taken
    local per = M.nbCfg.foodPerItem
    haven = haven or M.nbHavenOf(b)
    b.foodBits = tonumber(b.foodBits) or 0 -- part of an item already eaten
    while taken < pd - 1e-9 do
        if b.foodBits >= per - 1e-9 then
            local bite = math.min(per, pd - taken)
            -- eat from the item already opened
            taken = taken + bite; b.foodBits = b.foodBits - bite
        else
            local got = false
            local list = stashList(haven)
            if list then
                for i = #list, 1, -1 do
                    local e = list[i]
                    if M.nbKindOf(type(e) == "table" and e.type or e) == "food" then table.remove(list, i); got = true; break end
                end
            end
            if not got then
                local box = depotBox(haven)
                if box then
                    pcall(function()
                        local items = box:getItems()
                        for i = items:size() - 1, 0, -1 do
                            local it = items:get(i)
                            if M.nbKindOf(it:getFullType()) == "food" then box:Remove(it); got = true; return end
                        end
                    end)
                end
            end
            if not got then break end
            b.foodBits = b.foodBits + per
        end
    end
    M.nbFoodSync(b, haven)
    return taken
end
function M.nbFoodAdd(b, pd)
    pd = tonumber(pd) or 0
    if pd <= 0 then return 0 end
    if b.ledgerV == nil then M.nbFoodSync(b) end
    local n = math.max(1, tonumber(b.crewN) or 1)
    local room = math.max(0, n * M.nbCfg.foodCapDays - (tonumber(b.food) or 0))
    local add = math.min(pd, room)
    b.rations = (tonumber(b.rations) or 0) + add
    b.food = (tonumber(b.food) or 0) + add
    return add
end
-- how they're doing, from the ledger: desperate / short / steady / rich, and whether they can afford a fight
function M.nbMood(b)
    local n = math.max(1, tonumber(b.crewN) or 1)
    local per = (tonumber(b.food) or 0) / n
    local g = type(b.goods) == "table" and b.goods or {}
    local ammo = tonumber(g.ammo) or 0
    local mood = (per < 1 and "desperate") or (per < 3 and "short") or ((per >= 7 and ammo >= n) and "rich") or "steady"
    return mood, { noAmmo = ammo == 0, noMeds = (tonumber(g.meds) or 0) == 0, perHead = per }
end
function M.nbGoodsWords(b)
    local g = type(b.goods) == "table" and b.goods or nil
    if g == nil then return nil end
    local out = {}
    if (g.ammo or 0) == 0 then out[#out + 1] = "out of ammo" elseif (g.ammo or 0) < math.max(1, b.crewN or 1) then out[#out + 1] = "low on ammo" end
    if (g.meds or 0) == 0 then out[#out + 1] = "no medicine" end
    if (g.tools or 0) >= 3 then out[#out + 1] = "well tooled" end
    if (g.materials or 0) >= 10 then out[#out + 1] = "building materials stored" end
    return #out > 0 and table.concat(out, ", ") or nil
end
-- 0.6.3: STRENGTH. What a group really is: its people, how armed and fed they are (their real stash), how dug in,
-- and their spirits. No tiers, nothing that refills: lose people, ammo or food and they're weaker.
function M.nbStrength(b)
    local n = tonumber(b and b.crewN) or 0
    if n <= 0 or b.status ~= "active" then return 0 end
    local g = type(b.goods) == "table" and b.goods or {}
    local armed = math.min(n, tonumber(g.ammo) or 0) / n            -- a box of rounds arms one of them
    local fed = math.min(1, ((tonumber(b.food) or 0) / n) / 3)        -- 3 days a head = fully fed
    local dug = ({ squat = 0, camp = 0.15, fortified = 0.35 })[b.stage] or 0
    local spirit = 0.7 + 0.3 * (tonumber(b.morale) or 50) / 100
    local hard = (b.trade == "warband" or b.trade == "slavers") and 1.15 or 1 -- 0.6.4: they fight for a living
    return n * (1 + 0.6 * armed) * (0.6 + 0.4 * fed) * (1 + dug) * spirit * hard
end
-- how they stand against the groups around them (words for the AI, never numbers on screen)
function M.nbStrengthWord(b)
    local mine = M.nbStrength(b)
    local best, total, count = 0, 0, 0
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and (o.x - b.x) ^ 2 + (o.y - b.y) ^ 2 <= M.nbCfg.gossipTiles ^ 2 then
            local s = M.nbStrength(o); total = total + s; count = count + 1; if s > best then best = s end
        end
    end
    if count == 0 then return nil end
    if mine >= best and mine >= 1.5 * (total / count) then return "the strongest group around here" end
    if mine >= total / count then return "stronger than most groups around" end
    if mine * 2 < total / count then return "weaker than the groups around them" end
    return "about as strong as the groups around"
end
-- 0.6.3: ABSORPTION. A beaten or broken group is taken in: its people and its stash become the winner's. Moved,
-- never made. The beaten group's house is given up (A-Life releases it first, then its people are re-homed).
function M.nbAbsorb(winner, loser, h)
    if type(winner) ~= "table" or type(loser) ~= "table" or winner.status ~= "active" or loser.status ~= "active" then return false end
    local wh, lh = M.nbHavenOf(winner), M.nbHavenOf(loser)
    if wh == nil or lh == nil then return false end
    local ls, ws = stashList(lh), stashList(wh)
    if ls and ws then
        for i = 1, #ls do ws[#ws + 1] = ls[i] end
        for i = #ls, 1, -1 do ls[i] = nil end
    end
    winner.rations = (tonumber(winner.rations) or 0) + (tonumber(loser.rations) or 0)
    loser.rations = 0
    local scan = M.nbScan(true)
    local people = {}
    for _, r in ipairs(scan.crews[loser.id] or {}) do if r.lifecycle ~= "dead" then people[#people + 1] = r end end
    local squads = {}
    for _, sid in ipairs(type(loser.squads) == "table" and loser.squads or {}) do squads[#squads + 1] = sid end
    M.nbAbandon(loser, "absorbed")
    local reg, moved = PA().ActorRegistry, 0
    local depot = type(wh.depot) == "table" and { x = wh.depot.x, y = wh.depot.y, z = wh.depot.z } or nil
    for _, r in ipairs(people) do
        if fn(reg, "update") then
            local ok, res = pcall(reg.update, r.uid, r.revision, function(e)
                e.memory = type(e.memory) == "table" and e.memory or {}
                e.memory.havenId = winner.id
                e.memory.supplyDepot = depot
            end)
            if ok and res ~= false then moved = moved + 1 end
        end
    end
    local led = PA().SquadLedger
    if M.sbHomeSquad and depot and type(led) == "table" and fn(led, "peek") then
        for _, sid in ipairs(squads) do
            local q = led.peek(sid)
            if q and q.state ~= "wiped" then
                local ok, res = pcall(M.sbHomeSquad, q, winner, depot, h)
                if ok and res ~= false then moved = moved + (type(q.members) == "table" and #q.members or 0) end
            end
        end
    end
    winner.absorbed = (tonumber(winner.absorbed) or 0) + 1
    M.nbScanCache = nil
    M.nbFoodSync(winner, wh)
    return true, moved
end
M.nbStats = { founded = 0, adopted = 0, considered = 0, refusedSite = 0, sims = 0, attacks = 0, overruns = 0, abandoned = 0,
    recruited = 0, deaths = 0, visits = 0, scans = 0, probes = 0, cacheHits = 0, ticks = 0, tickMs = 0, maxMs = 0 }
M.nbScore = M.nbScore or {} -- buildingKey -> { h, static, info } (bounded, not saved)
M.nbScoreN = M.nbScoreN or 0

function M.nbOn() return M.settings.npcBases ~= false and M.settings.enabled ~= false end
function M.nbStore()
    local b = bucket("npcBases")
    b.byId = type(b.byId) == "table" and b.byId or {}
    b.tried = type(b.tried) == "table" and b.tried or {}
    b.seen = type(b.seen) == "table" and b.seen or {}
    b.names = type(b.names) == "table" and b.names or {}
    return b
end
local function havensOn()
    local hv = H()
    if not fn(hv, "store") then return false end
    if M.nbHavensForce ~= nil then return M.nbHavensForce end
    if fn(hv, "enabled") then local ok, v = pcall(hv.enabled); return ok and v == true end
    return true
end
M.nbHavensOn = havensOn
function M.nbCap()
    local cap = tonumber(M.settings.npcBasesMax) or 6
    local hv = H()
    if fn(hv, "option") then
        local ok, a = pcall(hv.option, "activitiesMaxBases", type(hv.settings) == "table" and hv.settings.maxBases or 6)
        if ok and tonumber(a) then cap = math.min(cap, tonumber(a)) end
    end
    return math.max(0, math.floor(cap))
end
local function addEvent(b, text, kind)
    b.events = type(b.events) == "table" and b.events or {}
    b.events[#b.events + 1] = { h = hours(), t = tostring(text), k = kind }
    while #b.events > M.nbCfg.eventsKeep do table.remove(b.events, 1) end
    log((b.name or b.id) .. ": " .. tostring(text))
end
M.nbEvent = addEvent

----------------------------------------------------------------------------------------------------------------
-- seasons, people
----------------------------------------------------------------------------------------------------------------
function M.nbSeason()
    if M.nbSeasonOverride then return M.nbSeasonOverride end
    local mo = nil
    pcall(function() mo = tonumber(getGameTime():getMonth()) end)
    if mo == nil then
        local c = M.climate and select(2, pcall(M.climate)) or nil
        local s = type(c) == "table" and string.lower(tostring(c.season or "")) or ""
        if string.find(s, "wint") then return "winter" elseif string.find(s, "aut") or string.find(s, "fall") then return "autumn"
        elseif string.find(s, "spr") then return "spring" elseif string.find(s, "sum") then return "summer" end
        return "summer"
    end
    if mo == 11 or mo <= 1 then return "winter" elseif mo <= 4 then return "spring" elseif mo <= 7 then return "summer" end
    return "autumn"
end
local function injured(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.injuries) == "table" and #m.injuries > 0 then return true end
    if type(m.injury) == "table" or m.injury == true then return true end
    local sh = shellFor(r.uid)
    if sh then
        local hp = nil
        pcall(function() hp = sh:getHealth() end)
        if tonumber(hp) and hp < 0.7 then return true end
    end
    return false
end
local function lensOf(uid)
    if not M.lens then return {} end
    local ok, v = pcall(M.lens, tostring(uid))
    return ok and type(v) == "table" and v or {}
end
-- the same gates as A-Life's Havens.eligibleGroup, one record at a time (loners allowed here)
function M.nbEligible(r)
    if type(r) ~= "table" or r.lifecycle == "dead" or type(r.memory) ~= "table" then return false, "dead" end
    local m = r.memory
    local pa = PA()
    if fn(pa.ModuleRegistry, "allows") then
        local ok, v = pcall(pa.ModuleRegistry.allows, r, "home")
        if ok and v == false then return false, "module" end
    end
    if m.havenId ~= nil then return false, "haven" end
    if m.natural ~= true then return false, "not_natural" end
    if m.outpostId ~= nil or m.admin ~= nil or m.visit ~= nil or m.guest ~= nil or m.activityId == "hold" or m.garrisonPost ~= nil then
        return false, "busy"
    end
    if fn(pa.Catalog, "faction") then
        local ok, f = pcall(pa.Catalog.faction, r.factionId)
        if ok and type(f) == "table" and type(f.spawn) == "table" and f.spawn.havens == false then return false, "faction" end
    end
    local uid = tostring(r.uid)
    if M.settlerOf and M.settlerOf(uid) ~= nil then return false, "settler" end
    if mpServer() and M.bdInParty and M.bdInParty(uid) then return false, "party" end -- MP: anyone's party
    if M.partyIsMember and select(2, pcall(M.partyIsMember, uid, thePlayer())) == true then return false, "party" end
    if M.isFinalDead and select(2, pcall(M.isFinalDead, uid)) == true then return false, "dead" end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- one registry pass (every founding / sim pass, never per tick): groups, loners and base crews
----------------------------------------------------------------------------------------------------------------
function M.nbScan(force)
    local now = nowMs()
    if not force and M.nbScanCache and now - M.nbScanCache.at < 20000 then return M.nbScanCache end
    local out = { at = now, groups = {}, order = {}, crews = {}, loners = {} }
    local reg = PA().ActorRegistry
    if not fn(reg, "each") then M.nbScanCache = out; return out end
    M.nbStats.scans = M.nbStats.scans + 1
    pcall(reg.each, function(r)
        if type(r) == "table" and r.lifecycle ~= "dead" and type(r.memory) == "table" then
            local m = r.memory
            if m.havenId ~= nil then
                local c = out.crews[m.havenId] or {}
                out.crews[m.havenId] = c
                c[#c + 1] = r
            elseif m.natural == true then
                local gid = m.groupId ~= nil and tostring(m.groupId) or ("solo:" .. tostring(r.uid))
                local g = out.groups[gid]
                if g == nil then g = { id = gid, members = {}, solo = m.groupId == nil }; out.groups[gid] = g; out.order[#out.order + 1] = gid end
                g.members[#g.members + 1] = r
            end
        end
        return false
    end)
    table.sort(out.order)
    for _, gid in ipairs(out.order) do
        local g = out.groups[gid]
        if #g.members == 1 then out.loners[#out.loners + 1] = g end
    end
    M.nbScanCache = out
    return out
end

----------------------------------------------------------------------------------------------------------------
-- buildings: A-Life's meta grid (works when the cell isn't loaded), squares only when they are
----------------------------------------------------------------------------------------------------------------
function M.nbDefAt(x, y)
    if M.nbDefAtHook then return M.nbDefAtHook(x, y) end
    local def = nil
    pcall(function() def = getWorld():getMetaGrid():getBuildingAt(math.floor(x), math.floor(y)) end)
    if def == nil then
        pcall(function()
            local sq = getCell():getGridSquare(math.floor(x), math.floor(y), 0)
            local b = sq and sq:getBuilding() or nil
            def = b and b:getDef() or nil
        end)
    end
    return def
end
local function defBounds(def)
    local b = nil
    pcall(function()
        local x1, y1, x2, y2 = tonumber(def:getX()), tonumber(def:getY()), tonumber(def:getX2()), tonumber(def:getY2())
        if x1 and y1 and x2 and y2 then b = { x1 = math.floor(x1), y1 = math.floor(y1), x2 = math.floor(x2) - 1, y2 = math.floor(y2) - 1 } end
    end)
    return b
end
local function defRooms(def)
    local out = {}
    pcall(function()
        local rooms = def:getRooms()
        for i = 0, math.min(rooms:size(), 40) - 1 do
            local n = nil
            pcall(function() n = rooms:get(i):getName() end)
            if n then out[#out + 1] = string.lower(tostring(n)) end
        end
    end)
    return out
end
M.nbDefRooms = defRooms -- 0.6.5 (outposts)
function M.nbCandidates(origin)
    local seen, list = {}, {}
    local ox, oy = tonumber(origin.x), tonumber(origin.y)
    if ox == nil then return list end
    for _, r in ipairs(M.nbCfg.probeRadii) do
        for a = 0, M.nbCfg.probeAngles - 1 do
            local ang = a * 2 * math.pi / M.nbCfg.probeAngles
            local x, y = math.floor(ox + math.cos(ang) * r), math.floor(oy + math.sin(ang) * r)
            M.nbStats.probes = M.nbStats.probes + 1
            local def = M.nbDefAt(x, y)
            local b = def and defBounds(def) or nil
            if b then
                local key = b.x1 .. ":" .. b.y1
                if not seen[key] then
                    seen[key] = true
                    list[#list + 1] = { key = key, def = def, bounds = b, center = { x = (b.x1 + b.x2) / 2, y = (b.y1 + b.y2) / 2 } }
                end
            end
        end
    end
    return list
end
local ROOMS = {
    { "kitchen", "kitchen", 8 }, { "bathroom", "bathroom", 5 }, { "bedroom", "bedroom", 3 }, { "storage", "storage", 5 },
    { "garage", "storage", 4 }, { "shed", "storage", 3 }, { "pantry", "kitchen", 3 }, { "living", "living", 2 }, { "dining", "living", 1 },
    { "farm", "farm", 6 }, { "barn", "farm", 4 }, { "laundry", "bathroom", 1 },
}
local function roomCounts(rooms)
    local c = {}
    for _, n in ipairs(rooms) do
        for _, rr in ipairs(ROOMS) do
            if string.find(n, rr[1], 1, true) then c[rr[2]] = (c[rr[2]] or 0) + 1; c.points = (c.points or 0) + (c[rr[2]] <= 3 and rr[3] or 0); break end
        end
    end
    return c
end
-- loaded only: windows / doors (A-Life's OutpostBuilder probe), zombies close by
local function loadedFacts(b)
    local f = {}
    local hv = H()
    local sq = fn(hv, "squareAt") and hv.squareAt(math.floor((b.x1 + b.x2) / 2), math.floor((b.y1 + b.y2) / 2), 0) or nil
    if sq == nil then return nil end
    f.loaded = true
    local ob = PA().OutpostBuilder
    pcall(function()
        local bld = sq:getBuilding()
        if bld and fn(ob, "probeBuilding") then
            local p = ob.probeBuilding(bld)
            local wins = p and fn(p, "windows") and p.windows() or {}
            local doors = p and fn(p, "doors") and p.doors() or {}
            f.windows, f.doors, f.broken, f.boarded = #wins, #doors, 0, 0
            for _, w in ipairs(wins) do
                local o = type(w) == "table" and (w.object or w.window) or w
                pcall(function() if o:isSmashed() then f.broken = f.broken + 1 end end)
                if type(w) == "table" and w.barricaded == true then f.boarded = f.boarded + 1 end
            end
        end
    end)
    local P = patch()
    if P and fn(P, "zombiesNear") then
        local ok, n = pcall(P.zombiesNear, (b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2, 25)
        if ok and tonumber(n) then f.zombies = tonumber(n) end
    end
    return f
end
-- the parts that don't change: size, rooms, the kind of place, town or country
function M.nbStatic(c)
    local h = hours()
    local e = M.nbScore[c.key]
    if e and h - e.h < M.nbCfg.scoreTtlH then M.nbStats.cacheHits = M.nbStats.cacheHits + 1; return e end
    local b = c.bounds
    local area = (b.x2 - b.x1 + 1) * (b.y2 - b.y1 + 1)
    local rooms = c.rooms or (c.def and defRooms(c.def)) or {}
    local rc = roomCounts(rooms)
    local s, why = 0, {}
    if area < M.nbCfg.minArea or area > M.nbCfg.maxArea then s = s - 100; why[#why + 1] = "wrong size"
    elseif area >= 40 and area <= 260 then s = s + 15; why[#why + 1] = "a good size" else s = s + 6 end
    s = s + math.min(30, rc.points or 0)
    if (rc.kitchen or 0) > 0 then why[#why + 1] = "a kitchen" end
    if (rc.bathroom or 0) > 0 then why[#why + 1] = "water" end
    if (rc.bedroom or 0) > 0 then why[#why + 1] = (rc.bedroom or 0) .. " bedroom" .. ((rc.bedroom or 0) > 1 and "s" or "") end
    if (rc.storage or 0) > 0 then why[#why + 1] = "storage" end
    local kind = "town"
    local fair = PA().SpawnFairness
    if fn(fair, "kindAt") then local ok, k = pcall(fair.kindAt, c.center.x, c.center.y); if ok and k then kind = tostring(k) end end
    if kind == "town" then s = s - 6; why[#why + 1] = "but in town (hordes)" else s = s + 6; why[#why + 1] = "out of town, fewer dead" end
    e = { h = h, static = s, why = why, rooms = rc, roomNames = rooms, area = area, kind = kind }
    if M.nbScore[c.key] == nil then M.nbScoreN = M.nbScoreN + 1 end
    if M.nbScoreN > M.nbCfg.scoreCache then M.nbScore, M.nbScoreN = {}, 1 end
    M.nbScore[c.key] = e
    return e
end
-- not the player's place, a safehouse, a taken / recently abandoned house, an outpost, ... (A-Life's own rules first)
function M.nbExcluded(c, h)
    local hv = H()
    local b = c.bounds
    local cool = M.nbStore().cool
    if type(cool) == "table" then
        local key = fn(hv, "keyOf") and hv.keyOf(b) or c.key
        if key and (tonumber(cool[key]) or -1e9) > (tonumber(h) or hours()) then return "cooldown" end
    end
    if fn(hv, "excluded") and fn(hv, "store") then
        local ok, why = pcall(hv.excluded, b, c.center, h, hv.store())
        if ok and why ~= nil then return tostring(why) end
    end
    if type(SafeHouse) == "table" and type(SafeHouse.getSafeHouse) == "function" then
        local hit = false
        pcall(function() hit = SafeHouse.getSafeHouse(b.x1, b.y1, b.x2 - b.x1 + 1, b.y2 - b.y1 + 1) ~= nil end)
        if hit then return "safehouse" end
    end
    for _, player in ipairs(everyone()) do -- MP: no NPC base on top of ANY player's base
        if M.alifeBase then
            local ok, ab = pcall(M.alifeBase, player, false)
            local bb = ok and type(ab) == "table" and (type(ab.bounds) == "table" and ab.bounds or ab) or nil
            if bb and overlaps(bb, b, 20) then return "player_base" end
            if ok and type(ab) == "table" and tonumber(ab.x) and d2(ab.x, ab.y, c.center.x, c.center.y) <= 60 * 60 then return "player_base" end
        end
        if M.playerBase then
            local ok, pb, src = pcall(M.playerBase, player)
            if ok and type(pb) == "table" and src ~= "building" and overlaps(pb, b, 20) then return "player_base" end
        end
    end
    for _, s in pairs(bucket("settlers")) do
        if type(s) == "table" and tonumber(s.x) and d2(s.x, s.y, c.center.x, c.center.y) <= 60 * 60 then return "player_base" end
    end
    return nil
end
function M.nbHouseScore(c, origin, crewN, h, withLoaded)
    local st = M.nbStatic(c)
    local s = st.static
    local why = {}
    for _, w in ipairs(st.why) do why[#why + 1] = w end
    local beds = (st.rooms.bedroom or 0)
    if crewN > 2 and beds > 0 and beds * 2 < crewN then s = s - 6; why[#why + 1] = "cramped" end
    local f = withLoaded and loadedFacts(c.bounds) or nil
    if f then
        if f.windows then
            s = s + 10 - (f.broken or 0) * 3 - math.max(0, (f.doors or 0) - 2) * 2 + (f.boarded or 0)
            s = s - math.floor(math.max(0, (f.windows or 0) - st.area / 12))
            if (f.broken or 0) == 0 then why[#why + 1] = "windows intact" else why[#why + 1] = f.broken .. " broken window" .. (f.broken > 1 and "s" or "") end
        end
        if f.zombies then s = s - math.min(25, f.zombies * 2); if f.zombies >= 5 then why[#why + 1] = "dead nearby" end end
    end
    local dist = math.sqrt(d2(c.center.x, c.center.y, origin.x, origin.y))
    s = s - math.floor(dist / 4)
    return s, why, st, f
end
function M.nbChooseHouse(origin, crewN, h)
    local refused, ranked = {}, {}
    for _, c in ipairs(M.nbCandidates(origin)) do
        local ex = M.nbExcluded(c, h)
        if ex then refused[ex] = (refused[ex] or 0) + 1
        else
            c.score, c.why, c.static = M.nbHouseScore(c, origin, crewN, h, false)
            ranked[#ranked + 1] = c
        end
    end
    table.sort(ranked, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.key < b.key end)
    -- doors / windows / zombies only for the best few (the probe walks the building's squares)
    for i = 1, math.min(4, #ranked) do
        local c = ranked[i]
        c.score, c.why, c.static, c.facts = M.nbHouseScore(c, origin, crewN, h, true)
    end
    table.sort(ranked, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.key < b.key end)
    local best = ranked[1]
    if best == nil or best.score < 0 then return nil, refused, ranked end
    return best, refused, ranked
end

----------------------------------------------------------------------------------------------------------------
-- names, leaders, the base record (ours: "npcBases"; A-Life's haven stays the source of truth for the place)
----------------------------------------------------------------------------------------------------------------
M.nbAdj = { "Mill", "Creek", "Hill", "Stone", "Cedar", "Pine", "Hollow", "Lantern", "Crow's", "Old", "Red", "Quiet", "Long", "Rust",
    "Willow", "Fox", "Iron", "Birch", "Ridge", "Brook", "Kettle", "Blue", "Lamp", "Orchard" }
M.nbFeatures = { { "church", "Chapel" }, { "gas", "Gas Station" }, { "farm", "Farm" }, { "barn", "Farm" }, { "warehouse", "Warehouse" },
    { "school", "Schoolhouse" }, { "classroom", "Schoolhouse" }, { "motel", "Motel" }, { "hotel", "Motel" }, { "bar", "Tavern" },
    { "restaurant", "Diner" }, { "diner", "Diner" }, { "office", "Office" }, { "grocer", "Store" }, { "store", "Store" },
    { "fire", "Firehouse" }, { "police", "Station" }, { "clinic", "Clinic" }, { "medical", "Clinic" }, { "cabin", "Cabin" } }
local function nameTaken(name, id)
    for oid, b in pairs(M.nbStore().byId) do
        if oid ~= id and type(b) == "table" and b.status == "active" and b.name == name then return true end
    end
    return false
end
function M.nbName(haven, rooms, crew, leader)
    local feature = haven.kind == "camp" and "Camp" or "House"
    local area = type(haven.bounds) == "table" and (haven.bounds.x2 - haven.bounds.x1 + 1) * (haven.bounds.y2 - haven.bounds.y1 + 1) or 0
    if haven.kind ~= "camp" then
        if area >= 300 then feature = "Lodge" end
        for _, n in ipairs(rooms or {}) do
            for _, f in ipairs(M.nbFeatures) do if string.find(n, f[1], 1, true) then feature = f[2]; break end end
            if feature ~= "House" and feature ~= "Lodge" then break end
        end
    end
    local seed = tostring(haven.buildingKey or haven.id)
    if #(crew or {}) == 1 and leader and not (leader.virtual and leader.first == nil) then
        local nm = firstOf(leader) .. "'s " .. (haven.kind == "camp" and "Camp" or pick({ "Place", "Hideout", "Hole", "Roost" }, seed))
        if not nameTaken(nm, haven.id) then return nm end
    end
    for i = 0, #M.nbAdj - 1 do
        local adj = M.nbAdj[((hash(seed) + i) % #M.nbAdj) + 1]
        local nm = "the " .. adj .. " " .. feature
        if not nameTaken(nm, haven.id) then return nm end
    end
    return "the " .. feature .. " " .. tostring(haven.id)
end
local function leaderScore(r)
    local l = lensOf(r.uid)
    return (l.disciplined or 0) * 3 + (l.brave or 0) * 2 + (l.proud or 0) + (l.loyal or 0) + (l.calm or 0) - (l.fearful or 0) + (hash(r.uid) % 100) / 1000
end
function M.nbPickLeader(crew, current)
    for _, r in ipairs(crew or {}) do if current and tostring(r.uid) == tostring(current) and r.lifecycle ~= "dead" then return r end end
    -- A-Life's own group leader first
    local best, bs = nil, -1e9
    for _, r in ipairs(crew or {}) do
        local m = type(r.memory) == "table" and r.memory or {}
        local isLead = false
        pcall(function() local g = PA().ModuleLeader.groups[m.groupId]; isLead = g ~= nil and tostring(g.leaderUid) == tostring(r.uid) end)
        local s = (isLead and 100 or 0) + leaderScore(r)
        if s > bs then best, bs = r, s end
    end
    return best
end
function M.nbAdopt(haven, by, crew, extra)
    local st = M.nbStore()
    crew = crew or {}
    local def = M.nbDefAt(haven.x, haven.y)
    local rooms = def and defRooms(def) or {}
    local leader = M.nbPickLeader(crew, nil)
    local b = {
        id = haven.id, by = by or "alife", kind = haven.kind or "house", x = haven.x, y = haven.y, z = haven.z or 0,
        bounds = type(haven.bounds) == "table" and { x1 = haven.bounds.x1, y1 = haven.bounds.y1, x2 = haven.bounds.x2, y2 = haven.bounds.y2 } or nil,
        founded = tonumber(haven.foundedHours) or hours(), stage = "squat", work = 0, morale = 60, food = M.nbCarriedFood(crew),
        rep = 50, events = {}, visits = 0, status = "active", simH = hours(), crewN = #crew, lastItems = 0, lowH = 0, starveH = 0,
        leader = leader and tostring(leader.uid) or nil, leaderName = leader and not (leader.virtual and leader.name == nil) and nameOf(leader) or nil,
        faction = crew[1] and crew[1].factionId or nil, maxCrewN = #crew,
    }
    if extra then for k, v in pairs(extra) do b[k] = v end end
    b.roster = {} -- 0.5.2.1: who lives here (identity seed / uid -> name), for final-death bookkeeping
    for _, r in ipairs(crew) do
        local k = M.nbRosterKey and M.nbRosterKey(r) or nil
        if k then b.roster[k] = { n = r.virtual and r.name or (not r.virtual and nameOf(r)) or nil, sq = r.virtual and r.squadId or (type(r.memory) == "table" and r.memory.squadId) or nil, u = not r.virtual and tostring(r.uid) or nil } end
    end
    b.name = M.nbName(haven, rooms, crew, leader)
    st.byId[haven.id] = b
    if by == "alife" then M.nbStats.adopted = M.nbStats.adopted + 1 end
    local who = #crew == 1 and firstOf(crew[1]) or (math.max(1, #crew) .. " people")
    addEvent(b, who .. (by == "seed" and " already live here - they call it " or " settled in - they call it ") .. b.name .. ((extra and extra.whyText) and (" (" .. extra.whyText .. ")") or ""), "founded")
    return b
end
M.nbEndWords = { stale = "nobody came back for days", crew_gone = "everyone there died or left", player_took_it = "you took the place",
    cap = "too many bases around - they moved on", starved = "they ran out of food", morale = "they lost heart and scattered",
    overrun = "it was overrun", merged = "they moved in with you", absorbed = "another group took them in", gone = "it was given up", fallen = "everyone there died" }
-- 0.5.2.1: the house stays off-limits for a few in-game days after a base ends (fallen or abandoned), then anyone
-- (a new group, A-Life, the seeding) may claim it fresh. A-Life's tombstone is lengthened (never shortened: "you
-- took it" stays forever) and we keep our own copy in case A-Life prunes its tombstones.
function M.nbCooldown(b, h)
    if type(b) ~= "table" or type(b.bounds) ~= "table" then return end
    local hv = H()
    local key = fn(hv, "keyOf") and hv.keyOf(b.bounds) or (b.bounds.x1 .. ":" .. b.bounds.y1)
    local untilH = h + M.nbCfg.reclaimH
    if fn(hv, "store") then
        local ok, store = pcall(hv.store)
        if ok and type(store) == "table" then
            store.tombstones = type(store.tombstones) == "table" and store.tombstones or {}
            if (tonumber(store.tombstones[key]) or -1e9) < untilH then store.tombstones[key] = untilH end
            if store.byBuilding and store.byBuilding[key] == b.id then store.byBuilding[key] = nil end
        end
    end
    local st = M.nbStore()
    st.cool = type(st.cool) == "table" and st.cool or {}
    st.cool[key] = math.max(tonumber(st.cool[key]) or -1e9, untilH)
    for k, u in pairs(st.cool) do if (tonumber(u) or 0) < h then st.cool[k] = nil end end
end
function M.nbEnded(b, reason)
    if b.status ~= "active" then return end
    if reason == "fallen" then b.status = "fallen"
    else b.status = reason == "overrun" and "overrun" or (reason == "merged" and "merged" or "abandoned") end
    b.endedH, b.endReason = hours(), tostring(reason)
    b.lastCrewN = (reason == "fallen") and math.max(tonumber(b.maxCrewN) or 0, tonumber(b.crewN) or 0) or b.crewN
    if reason == "fallen" then b.crewN = 0 end
    addEvent(b, (reason == "fallen" and "Fallen: " or "Left behind: ") .. (M.nbEndWords[reason] or tostring(reason)), "ended")
    M.nbStats.abandoned = M.nbStats.abandoned + 1
    pcall(M.nbCooldown, b, b.endedH)
    -- old ended bases: keep the newest few (known NPCs themselves are never touched); the ones you know go last
    local st, ended = M.nbStore(), {}
    for id, e in pairs(st.byId) do if type(e) == "table" and e.status ~= "active" then ended[#ended + 1] = e end end
    if #ended > M.nbCfg.endedKeep then
        table.sort(ended, function(x, y)
            local kx, ky = x.known ~= nil and 1 or 0, y.known ~= nil and 1 or 0
            if kx ~= ky then return kx < ky end
            return (x.endedH or 0) < (y.endedH or 0)
        end)
        for i = 1, #ended - M.nbCfg.endedKeep do st.byId[ended[i].id] = nil end
    end
end
-- 0.5.2.1: a resident's final death. Off the roster at once, their home anchor cleared (the dead don't come back
-- to the base); when nobody living is left the base falls (M.nbFall). key = identity seed / uid.
local function rosterKey(r)
    if type(r) ~= "table" then return nil end
    if r.virtual then return r.seed end
    local m = type(r.memory) == "table" and r.memory or {}
    return type(m.identitySeed) == "string" and m.identitySeed or tostring(r.uid)
end
M.nbRosterKey = rosterKey
function M.nbNoteDeath(b, key, name, h)
    if type(b) ~= "table" or key == nil then return end
    b.roster = type(b.roster) == "table" and b.roster or {}
    b.dead = type(b.dead) == "table" and b.dead or {}
    for _, d in ipairs(b.dead) do if d.k == key then b.roster[key] = nil; return end end
    local e = b.roster[key]
    b.dead[#b.dead + 1] = { k = key, n = name or (type(e) == "table" and e.n) or nil, h = h or hours() }
    while #b.dead > 20 do table.remove(b.dead, 1) end
    b.roster[key] = nil
    b.lastGone, b.lastDeathH = "died", h or hours()
    if (tonumber(b.crewN) or 0) > 0 then b.crewN = b.crewN - 1 end
end
-- who is still alive and living here right now (registry crew + live homed squads)
function M.nbLiving(b)
    local n = 0
    M.nbScanCache = nil
    for _, r in ipairs(M.nbScan(true).crews[b.id] or {}) do
        if r.lifecycle ~= "dead" and not (M.isFinalDead and select(2, pcall(M.isFinalDead, tostring(r.uid))) == true) then n = n + 1 end
    end
    if M.sbCrewOf then local ok, extra = pcall(M.sbCrewOf, b); if ok and type(extra) == "table" then n = n + #extra end end
    if M.sbLiveSquadMembers then local ok, k = pcall(M.sbLiveSquadMembers, b, true); if ok and tonumber(k) then n = n + k end end
    return n
end
function M.nbFall(b, h)
    if b.status ~= "active" then return end
    local hv = H()
    if fn(hv, "abandon") then pcall(hv.abandon, b.id, "fallen") end
    M.nbEnded(b, "fallen")
    M.nbStats.fallen = (M.nbStats.fallen or 0) + 1
    M.nbScanCache = nil
end
-- A-Life's havens <-> our records (A-Life-founded havens get a name and a life too)
function M.nbSync(scan)
    local hv = H()
    if not fn(hv, "activeList") then return end
    scan = scan or M.nbScan()
    local st = M.nbStore()
    local okL, list = pcall(hv.activeList)
    for _, haven in ipairs(okL and list or {}) do
        local b = st.byId[haven.id]
        if b == nil or b.status ~= "active" then b = M.nbAdopt(haven, "alife", scan.crews[haven.id] or {}) end
        b.x, b.y, b.kind = haven.x, haven.y, haven.kind or b.kind
        if type(haven.knownBy) == "table" and not isEmpty(haven.knownBy) and b.known == nil then b.known = "told" end
    end
    for id, b in pairs(st.byId) do
        if type(b) == "table" and b.status == "active" and hv.of(id) == nil then
            local raw = hv.store().byId[id]
            M.nbEnded(b, type(raw) == "table" and raw.reason or "gone")
        end
    end
end
function M.nbActive()
    local out = {}
    for _, b in pairs(M.nbStore().byId) do if type(b) == "table" and b.status == "active" then out[#out + 1] = b end end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end
function M.nbOf(id) local b = id and M.nbStore().byId[id] or nil; return type(b) == "table" and b or nil end
function M.nbOfMember(uid)
    local r = type(uid) == "table" and uid or rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or nil
    if m == nil or m.havenId == nil then return nil end
    local b = M.nbOf(m.havenId)
    if b and b.status == "active" then return b end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- founding: do these people want to stop here? (personality, size, wandering, wounds, season, food, threats)
----------------------------------------------------------------------------------------------------------------
M.nbHome = { "fearful", "loyal", "kind", "calm", "disciplined", "devout" }
M.nbRoam = { "curious", "brave", "volatile", "unhinged", "proud" }
M.nbRoamCores = { drifter = true, loner = true, hermit = true, lonewolf = true, wanderer = true, nomad = true }
function M.nbSettleScore(members, gid, h)
    local s, why = 20, {}
    local home, roam, hurt, hungry = 0, 0, 0, 0
    for _, r in ipairs(members) do
        local l = lensOf(r.uid)
        for _, k in ipairs(M.nbHome) do home = home + (l[k] or 0) end
        for _, k in ipairs(M.nbRoam) do roam = roam + (l[k] or 0) end
        local p = M.partsOf and select(2, pcall(M.partsOf, tostring(r.uid))) or nil
        local core = type(p) == "table" and p.core and p.core.key or ""
        if M.nbRoamCores[core] then roam = roam + 0.4 end
        if injured(r) then hurt = hurt + 1 end
        if M.lifeOf then local ok, life = pcall(M.lifeOf, tostring(r.uid)); if ok and type(life) == "table" and (tonumber(life.hunger) or 0) >= 0.5 then hungry = hungry + 1 end end
    end
    local n = math.max(1, #members)
    local lean = math.floor((home - roam) / n * 40)
    s = s + lean
    if lean >= 6 then why[#why + 1] = "homebodies" elseif lean <= -6 then why[#why + 1] = "restless wanderers" end
    if n >= 3 then s = s + 10; why[#why + 1] = n .. " of them" end
    if n >= 5 then s = s + 6 end
    if n == 1 then s = s - 8 end
    local seen = tonumber(M.nbStore().seen[gid]) or h
    local age = h - seen
    if age >= 168 then s = s + 15; why[#why + 1] = "tired of the road"
    elseif age >= 72 then s = s + 8; why[#why + 1] = "worn out from moving" end
    if hurt > 0 then s = s + math.min(16, hurt * 8); why[#why + 1] = "wounded who need rest" end
    local season = M.nbSeason()
    if season == "autumn" then s = s + 20; why[#why + 1] = "winter is coming"
    elseif season == "winter" then s = s + 10; why[#why + 1] = "it's winter" elseif season == "summer" then s = s - 5 end
    if hungry > 0 then s = s + 6; why[#why + 1] = "need a place to keep food" end
    local P = patch()
    local x, y = nil, nil
    local wp = members[1] and members[1].worldPosition or nil
    if type(wp) == "table" then x, y = tonumber(wp.x), tonumber(wp.y) end
    local zs = 0
    if x and P and fn(P, "zombiesNear") and shellFor(members[1].uid) then local ok, v = pcall(P.zombiesNear, x, y, 30); zs = ok and tonumber(v) or 0 end
    if zs >= 8 then s = s + 6; why[#why + 1] = "the dead keep coming" end
    local rate = tonumber(M.settings.npcBaseRate) or 100
    s = math.floor(s * rate / 100)
    return s, why
end
-- A-Life's Havens.found, for a building we chose (same store, same fields, same member memory)
function M.nbCreate(gid, members, c, h, whyText)
    local hv = H()
    local store = hv.store()
    local depot = nil
    if fn(hv, "depotIn") then local ok, d = pcall(hv.depotIn, c.bounds, 0); if ok and type(d) == "table" then depot = d end end
    if depot == nil then depot = { x = math.floor(c.center.x) + 0.5, y = math.floor(c.center.y) + 0.5, z = 0 }; c.depotGuess = true end
    store.seq = (tonumber(store.seq) or 0) + 1
    local id = "haven:" .. store.seq
    local key = fn(hv, "keyOf") and hv.keyOf(c.bounds) or c.key
    local groupId = members[1] and type(members[1].memory) == "table" and members[1].memory.groupId or nil
    local haven = { id = id, kind = "house", state = "active", x = c.center.x, y = c.center.y, z = 0, buildingKey = key, bounds = c.bounds,
        depot = depot, foundedHours = h, lastHomeHours = h, stock = { items = 0 }, groupId = groupId, foundedBy = "ALifeTalk" }
    store.byId[id], store.byBuilding[key] = haven, id
    local reg = PA().ActorRegistry
    for _, r in ipairs(members) do
        pcall(reg.update, r.uid, r.revision, function(entry)
            entry.memory = type(entry.memory) == "table" and entry.memory or {}
            entry.memory.havenId = id
            entry.memory.supplyDepot = { x = depot.x, y = depot.y, z = depot.z }
        end)
    end
    if type(hv.metrics) == "table" then hv.metrics.founded = (hv.metrics.founded or 0) + 1 end
    if fn(hv, "dirty") then pcall(hv.dirty) end
    M.nbStats.founded = M.nbStats.founded + 1
    local b = M.nbAdopt(haven, "talk", members, { whyText = whyText, depotGuess = c.depotGuess or nil, houseWhy = c.why })
    if M.keyMem then for _, r in ipairs(members) do pcall(M.keyMem, tostring(r.uid), "home", "Settled into " .. b.name) end end
    if M.logInteraction then for _, r in ipairs(members) do pcall(M.logInteraction, tostring(r.uid), "Settled into a house - " .. b.name, nil, nil, "event") end end
    return haven, b
end
M.nbFoundCursor = 0
function M.nbFoundTick(h)
    if not M.nbOn() or not havensOn() then return 0 end
    local scan = M.nbScan(true)
    M.nbSync(scan)
    local st = M.nbStore()
    local day = math.floor(h / 24)
    for _, gid in ipairs(scan.order) do if st.seen[gid] == nil then st.seen[gid] = h end end
    if #M.nbActive() >= M.nbCap() then return 0 end
    if (tonumber(M.settings.npcBaseRate) or 100) <= 0 then return 0 end
    local n = #scan.order
    if n == 0 then return 0 end
    local looked = 0
    for _ = 1, n do
        M.nbFoundCursor = (M.nbFoundCursor % n) + 1
        local gid = scan.order[M.nbFoundCursor]
        local g = scan.groups[gid]
        if g and st.tried[gid] ~= day then
            local ok = true
            for _, r in ipairs(g.members) do if not M.nbEligible(r) then ok = false; break end end
            if ok and h - (tonumber(st.seen[gid]) or h) >= M.nbCfg.minAgeH then
                looked = looked + 1
                st.tried[gid] = day
                M.nbStats.considered = M.nbStats.considered + 1
                local score, why = M.nbSettleScore(g.members, gid, h)
                local roll = hash(gid .. "#settle#" .. day) % 100
                M.nbLastDecision = { gid = gid, score = score, roll = roll, why = why, h = h }
                if score >= 10 and roll < score then
                    local wp = g.members[1].worldPosition
                    if type(wp) == "table" then
                        local c, refused = M.nbChooseHouse({ x = wp.x, y = wp.y }, #g.members, h)
                        M.nbLastDecision.refused = refused
                        if c then
                            local haven, b = M.nbCreate(gid, g.members, c, h, table.concat(why, ", "))
                            M.nbLastDecision.founded = haven.id
                            log("founded " .. b.name .. " (" .. haven.id .. ") for " .. gid .. " score " .. score .. " roll " .. roll
                                .. " house " .. tostring(c.score) .. ": " .. table.concat(c.why or {}, ", "))
                            M.nbScanCache = nil
                            return 1
                        end
                        M.nbStats.refusedSite = M.nbStats.refusedSite + 1
                    end
                end
            end
        end
        if looked >= M.nbCfg.perPass then break end
    end
    -- forget wanderers we haven't seen in a long while (bounded)
    local cnt = 0
    for gid, sh in pairs(st.seen) do cnt = cnt + 1; if scan.groups[gid] == nil and h - (tonumber(sh) or h) > 24 * 14 then st.seen[gid] = nil end end
    for gid, d in pairs(st.tried) do if tonumber(d) == nil or d < day - 2 then st.tried[gid] = nil end end
    return 0
end

----------------------------------------------------------------------------------------------------------------
-- the life of a base (one base per minute; offline hours caught up in day-sized steps, at most 3 days)
----------------------------------------------------------------------------------------------------------------
M.nbStageDef = { squat = 0, camp = 15, fortified = 35 }
M.nbStageWords = { squat = "just moved in (squatting)", camp = "settled in (a proper camp)", fortified = "fortified (boarded up)" }
local function recentCount(list, h, win)
    local n = 0
    for _, e in ipairs(list or {}) do if h - (tonumber(e) or -1e9) <= win then n = n + 1 end end
    return n
end
local function pushH(b, key, h)
    b[key] = type(b[key]) == "table" and b[key] or {}
    local l = b[key]
    l[#l + 1] = h
    while #l > 8 do table.remove(l, 1) end
end
function M.nbRaidersNear(b)
    local led = PA().SquadLedger
    if not fn(led, "briefs") then return nil end
    local ok, list = pcall(led.briefs)
    for _, q in ipairs(ok and list or {}) do
        local id = string.lower(tostring(q.factionId or "") .. " " .. tostring(q.name or ""))
        if tonumber(q.x) and q.factionId ~= b.faction and d2(q.x, q.y, b.x, b.y) <= 300 * 300
                and (string.find(id, "bandit") or string.find(id, "raider") or string.find(id, "outlaw") or string.find(id, "gang") or string.find(id, "cult")) then
            return q
        end
    end
    return nil
end
function M.nbSetStage(b, h, near)
    local old = b.stage
    local new = "squat"
    if b.work >= M.nbCfg.fortWork then new = "fortified" elseif b.work >= M.nbCfg.campWork then new = "camp" end
    -- hysteresis: a fortified place only drops back when badly damaged
    if old == "fortified" and new == "camp" and b.work >= M.nbCfg.fortWork * 0.6 then new = "fortified" end
    if new ~= old then
        b.stage = new
        if new == "camp" and old == "squat" then addEvent(b, "Made " .. b.name .. " livable - beds, a cookfire, the doors shut", "stage")
        elseif new == "fortified" then addEvent(b, "Boarded up " .. b.name .. " - it's a real stronghold now", "stage")
        else addEvent(b, b.name .. " took damage - " .. (M.nbStageWords[new] or new) .. " again", "stage") end
    end
end
-- 0.5.2.1: the dead are not "of" a base any more (their A-Life record keeps everything else)
function M.nbClearAnchor(uid)
    local reg = PA().ActorRegistry
    local r = rec(uid)
    if r == nil or not fn(reg, "update") or type(r.memory) ~= "table" or r.memory.havenId == nil then return end
    pcall(reg.update, r.uid, r.revision, function(entry)
        if type(entry.memory) == "table" then entry.memory.havenId, entry.memory.supplyDepot = nil, nil end
    end)
end
function M.nbKill(r, why)
    local pa = PA()
    local uid = tostring(r.uid)
    if r.virtual then return M.sbKillVirtual ~= nil and M.sbKillVirtual(r, why) == true end -- 0.5.2.1: a squad member nobody has seen
    if r.lifecycle ~= "dormant" or shellFor(uid) ~= nil then return false end -- never someone you could be watching
    local ok = false
    if fn(pa.ActorRegistry, "markDead") then
        local pok, dead = pcall(pa.ActorRegistry.markDead, uid, r.revision, r.generation, type(r.worldPosition) == "table" and r.worldPosition or nil)
        ok = pok and dead ~= nil
    end
    if not ok then return false end
    if M.markFinalDead then pcall(M.markFinalDead, uid, why, r) end
    M.nbClearAnchor(uid)
    M.nbStats.deaths = M.nbStats.deaths + 1
    return true
end
function M.nbAbandon(b, reason)
    -- 0.5.2.1: nobody living left and the last of them died -> it fell (not "left")
    if b.status == "active" and (reason == "crew_gone" or reason == "overrun") and b.lastGone == "died" and M.nbLiving(b) == 0 then
        return M.nbFall(b, hours())
    end
    local hv = H()
    if fn(hv, "abandon") then pcall(hv.abandon, b.id, reason) end
    M.nbEnded(b, reason)
    M.nbScanCache = nil
end
function M.nbAttack(b, haven, crew, home, h, kind)
    kind = kind or (M.nbRaidersNear(b) and "raiders" or "horde")
    M.nbStats.attacks = M.nbStats.attacks + 1
    pushH(b, "attacks", h)
    local n = #crew
    local def = home * 12 + (M.nbStageDef[b.stage] or 0) + math.floor((b.morale or 50) / 5)
    local str = 15 + (hash(b.id .. "#str#" .. math.floor(h)) % 70) + (kind == "raiders" and 15 or 0) + (M.nbSeason() == "winter" and 5 or 0)
    if M.nbForceStrength then str = M.nbForceStrength end
    local what = kind == "raiders" and "a band of raiders" or "a horde of the dead"
    b.lastAttack = { h = h, kind = kind, str = str, def = def }
    if str <= def then
        b.morale = clamp((b.morale or 50) + 4, 0, 100)
        b.work = math.max(0, b.work - 5)
        addEvent(b, "Fought off " .. what .. " at " .. b.name, "attack")
        return "repelled"
    end
    if str <= def * 1.6 then
        b.morale = clamp((b.morale or 50) - 8, 0, 100)
        M.nbFoodTake(b, n) -- 0.6.1: the raiders / the dead took (or ruined) a day's food a head
        b.work = math.max(0, b.work - 15)
        M.nbSetStage(b, h)
        addEvent(b, what:gsub("^%l", string.upper) .. " broke into " .. b.name .. " - they lost supplies and boards", "attack")
        return "damaged"
    end
    -- overrun: final deaths only while nobody is watching (never a loaded / rendered NPC)
    M.nbStats.overruns = M.nbStats.overruns + 1
    local victims = (M.settings.npcBaseDanger ~= false) and (1 + math.floor(n / 3)) or 0
    local dead = {}
    local order = {}
    for _, r in ipairs(crew) do order[#order + 1] = r end
    table.sort(order, function(x, y) return hash(tostring(x.uid) .. b.id .. math.floor(h)) < hash(tostring(y.uid) .. b.id .. math.floor(h)) end)
    for _, r in ipairs(order) do
        if #dead >= victims then break end
        if M.nbKill(r, "killed when " .. b.name .. " was overrun by " .. what) then
            dead[#dead + 1] = firstOf(r); pushH(b, "losses", h)
            M.nbNoteDeath(b, rosterKey(r), nameOf(r), h)
        end
    end
    local left = n - #dead
    addEvent(b, b.name .. " was overrun by " .. what .. (#dead > 0 and (" - " .. table.concat(dead, ", ") .. " died") or ""), "overrun")
    if left < 2 or (b.morale or 50) < 30 then
        M.nbAbandon(b, "overrun")
        return "overrun", dead
    end
    b.morale = clamp((b.morale or 50) - 25, 0, 100)
    b.work = 0
    M.nbFoodTake(b, (tonumber(b.food) or 0) / 2) -- 0.6.1: half of what they had is gone
    b.stage = "squat"
    return "overrun_held", dead
end
function M.nbRecruit(b, haven, h, scan)
    local reg = PA().ActorRegistry
    for _, g in ipairs(scan.loners or {}) do
        local r = g.members[1]
        local wp = r and r.worldPosition or nil
        if type(wp) == "table" and tonumber(wp.x) and d2(wp.x, wp.y, b.x, b.y) <= M.nbCfg.recruitTiles ^ 2 and M.nbEligible(r) then
            local ok = pcall(reg.update, r.uid, r.revision, function(entry)
                entry.memory = type(entry.memory) == "table" and entry.memory or {}
                entry.memory.havenId = b.id
                entry.memory.supplyDepot = type(haven.depot) == "table" and { x = haven.depot.x, y = haven.depot.y, z = haven.depot.z } or nil
            end)
            if ok then
                M.nbStats.recruited = M.nbStats.recruited + 1
                addEvent(b, firstOf(r) .. " joined them at " .. b.name, "joined")
                if M.keyMem then pcall(M.keyMem, tostring(r.uid), "home", "Took in at " .. b.name) end
                M.nbScanCache = nil
                return r
            end
        end
    end
    return nil
end
function M.nbStep(b, haven, crew, home, dt, h, far, scan)
    local n = math.max(1, #crew)
    local cfg = M.nbCfg
    -- work: fixing the place up (real boarding by members inside adds more, see the activity hook)
    if b.stage ~= "fortified" or b.work < cfg.fortWork then
        local chores = 0
        if type(haven.chores) == "table" then chores = (tonumber(haven.chores.planks) or 0) + (tonumber(haven.chores.wood) or 0) end
        local delta = chores - (b.lastChores or 0)
        b.lastChores = chores
        b.work = math.min(cfg.fortWork, b.work + home * dt * cfg.workPerCrewH * (tonumber(b.workMul) or 1) + math.max(0, delta) * 0.5)
    end
    M.nbSetStage(b, h)
    -- food (person-days). 0.6.0: nothing from nowhere. In: what A-Life's scavengers bring to the stash (taken from real
    -- buildings, ALifeDerelict) and a little foraging / hunting by whoever is home (renewable, by season and place).
    local season = M.nbSeason()
    local sMul = ({ spring = 0.95, summer = 1.15, autumn = 1.05, winter = 0.45 })[season] or 1
    local stMul = ({ squat = 0.8, camp = 1.0, fortified = 1.1 })[b.stage] or 1
    local town = b.town
    if town == nil then
        town = false
        local fair = PA().SpawnFairness
        if fn(fair, "kindAt") then local okK, k = pcall(fair.kindAt, b.x, b.y); town = okK and k == "town" end
        b.town = town
    end
    local forage = 0
    if M.settings.npcForage ~= false then
        forage = home * dt / 24 * sMul * stMul * cfg.forageRate * (town and cfg.forageTown or 1) * (tonumber(b.forageMul) or 1)
    end
    -- 0.6.1: they eat forage first, then rations, then the real food in their stash / depot (taken out of it)
    -- (the Airport keeps its own food: ALifeTalk_Airport)
    local need = n * dt / 24
    local short = 0
    M.nbFoodSync(b, haven)
    if not b.airport then
        local fromForage = math.min(need, forage)
        if forage > need then
            local keep = math.max(0, n * cfg.freshCapDays - (tonumber(b.rations) or 0))
            b.rations = (tonumber(b.rations) or 0) + math.min(forage - need, keep)
        end
        local eaten = fromForage + M.nbFoodTake(b, need - fromForage, haven)
        short = need - eaten
    end
    -- morale
    local per = b.food / n
    local target = 50 + (per >= 3 and 12 or (per < 1 and -25 or 0)) + ({ squat = 0, camp = 5, fortified = 12 })[b.stage]
        + (n >= 3 and 5 or 0) - recentCount(b.losses, h, 72) * 12 - recentCount(b.attacks, h, 48) * 6 + (b.leader and 3 or -5)
    b.morale = clamp((b.morale or 50) + (target - (b.morale or 50)) * math.min(1, dt / 24 * 0.4), 0, 100)
    -- starving: less than half of what they need to eat (winter, towns, too many mouths, nothing in the stash)
    if short > need * (1 - cfg.starveCover) + 1e-9 then b.starveH = (b.starveH or 0) + dt else b.starveH = 0 end
    if b.morale < cfg.lowMorale then b.lowH = (b.lowH or 0) + dt else b.lowH = 0 end
    -- danger (offline only; never in front of you)
    if far and M.settings.npcBaseDanger ~= false then
        local fair = PA().SpawnFairness
        local town = true
        if fn(fair, "kindAt") then local ok, k = pcall(fair.kindAt, b.x, b.y); town = not ok or k == "town" end
        local raiders = M.nbRaidersNear(b) ~= nil
        local chance = cfg.attackPerDay * dt / 24 * (season == "winter" and 1.3 or 1) * (town and 1.4 or 1) + (raiders and 0.04 * dt / 24 or 0)
        if M.nbForceAttack then chance = 1 end
        local roll = ALifeRoll01 and ALifeRoll01(b.id .. "#atk#" .. math.floor(h * 4)) or ((hash(b.id .. "#atk#" .. math.floor(h * 4)) % 10000) / 10000) -- 0.6.8: well mixed
        if roll < chance then
            local res = M.nbAttack(b, haven, crew, home, h, raiders and "raiders" or "horde")
            if b.status ~= "active" then return end
            if res == "overrun_held" then return end
        end
    end
    if b.starveH >= cfg.abandonH then M.nbAbandon(b, "starved"); return end
    if b.lowH >= cfg.abandonH then M.nbAbandon(b, "morale"); return end
    -- growth: a loner nearby is taken in when things are going well (once a day)
    local day = math.floor(h / 24)
    if b.morale >= cfg.recruitMorale and per >= 2 and #crew < cfg.memberCap and b.recruitDay ~= day then
        b.recruitDay = day
        local r = M.nbRecruit(b, haven, h, scan)
        if r then crew[#crew + 1] = r end
    end
end
function M.nbSimBase(b, h, scan, force)
    local hv = H()
    local haven = fn(hv, "of") and hv.of(b.id) or nil
    if haven == nil then M.nbSync(scan); return end
    scan = scan or M.nbScan()
    local crew = {}
    for _, r in ipairs(scan.crews[b.id] or {}) do if r.lifecycle ~= "dead" then crew[#crew + 1] = r end end
    if M.sbCrewOf then -- 0.5.2.1: people of an offline A-Life squad homed here (never rendered = no registry record)
        local ok, extra = pcall(M.sbCrewOf, b)
        if ok and type(extra) == "table" then for _, r in ipairs(extra) do crew[#crew + 1] = r end end
    end
    b.crewN = #crew
    -- 0.5.2.1: roster - who was here last time and isn't now: dead (final) or left
    b.roster = type(b.roster) == "table" and b.roster or {}
    local now = {}
    for _, r in ipairs(crew) do
        local k = rosterKey(r)
        if k then now[k] = true; if b.roster[k] == nil then b.roster[k] = { n = (r.virtual and r.name) or (not r.virtual and nameOf(r)) or nil, sq = r.virtual and r.squadId or (type(r.memory) == "table" and r.memory.squadId) or nil, u = not r.virtual and tostring(r.uid) or nil } end end
    end
    for k, e in pairs(b.roster) do
        if not now[k] then
            local died = false
            local dead = type(e) == "table" and e.u and M.isFinalDead and select(2, pcall(M.isFinalDead, e.u)) == true
            if dead then died = true
            elseif type(e) == "table" and e.sq and M.sbSeedAlive then
                -- an A-Life squad member (rendered or not): alive while their squad still has them
                local alive = M.sbSeedAlive(e.sq, k, b)
                if alive == "left" then died = false elseif alive == true or alive == nil then died = nil else died = true end
            elseif type(e) == "table" and e.u then
                local rr = rec(e.u)
                died = rr ~= nil and rr.lifecycle == "dead"
                if rr == nil then died = true end
            end
            if died == true then M.nbNoteDeath(b, k, type(e) == "table" and e.n or nil, h); addEvent(b, ((type(e) == "table" and e.n) or "One of them") .. " of " .. b.name .. " is dead", "death")
            elseif died == false then b.roster[k] = nil; b.lastGone = "left" end
        end
    end
    b.crewN = #crew
    b.maxCrewN = math.max(tonumber(b.maxCrewN) or 0, #crew)
    if #crew == 0 then
        -- 0.5.2.1: a homed A-Life squad between offline and rendered (staging / rendering) is still theirs
        if M.sbInTransit and select(2, pcall(M.sbInTransit, b)) == true then return end
        M.nbAbandon(b, "crew_gone"); return
    end
    local leader = M.nbPickLeader(crew, b.leader)
    if leader and tostring(leader.uid) ~= b.leader then
        if b.leader or b.leaderName then addEvent(b, firstOf(leader) .. " leads them now", "leader") end
        b.leader, b.leaderName = tostring(leader.uid), nameOf(leader)
    end
    local dt = h - (tonumber(b.simH) or h)
    if dt < 0.25 and not force then return end
    dt = math.min(dt, M.nbCfg.maxCatchH)
    b.simH = h
    M.nbStats.sims = M.nbStats.sims + 1
    local player = nearestTo(b.x, b.y) -- MP: far = far from every player
    local px, py = pos(player)
    local far = px == nil or d2(px, py, b.x, b.y) > M.nbCfg.farTiles ^ 2
    -- who is home: rendered people where they stand; unseen people come home while you're far away (offline life)
    local reg = PA().ActorRegistry
    local home = 0
    local depot = type(haven.depot) == "table" and haven.depot or { x = b.x, y = b.y, z = 0 }
    for _, r in ipairs(crew) do
        local sh = shellFor(r.uid)
        local x, y = nil, nil
        if sh then x, y = pos(sh) elseif type(r.worldPosition) == "table" then x, y = tonumber(r.worldPosition.x), tonumber(r.worldPosition.y) end
        local m = type(r.memory) == "table" and r.memory or {}
        if x and inside(b.bounds, x, y, M.nbCfg.homeTiles) then home = home + 1
        elseif r.virtual then
            if far and M.sbBringHome and M.sbBringHome(r, b, depot, h) == true then home = home + 1 end
        elseif sh == nil and r.lifecycle == "dormant" and far and m.squadId == nil and m.activityId ~= "hold" and fn(reg, "update")
                and m.alcpRun == nil and not (M.lvIsAway and M.lvIsAway(r.uid)) then -- pre-1.0: people on the road (runs, war parties) stay on the road
            local ok = pcall(reg.update, r.uid, r.revision, function(entry)
                entry.worldPosition = { x = depot.x + (hash(r.uid) % 3) - 1, y = depot.y + (hash(r.uid .. "y") % 3) - 1, z = depot.z or 0 }
            end)
            if ok then home = home + 1 end
        end
    end
    b.home = home
    if home > 0 and fn(hv, "arrive") then pcall(hv.arrive, haven, h, 0) end -- keeps A-Life from calling it stale
    local left = dt
    while left > 0.001 and b.status == "active" do
        local step = math.min(left, M.nbCfg.maxStepH)
        M.nbStep(b, haven, crew, home, step, h - left + step, far, scan)
        left = left - step
    end
end
M.nbSimCursor = 0
function M.nbSimTick(h)
    if not M.nbOn() or not havensOn() then return 0 end
    local scan = M.nbScan()
    M.nbSync(scan)
    local list = M.nbActive()
    if #list == 0 then return 0 end
    M.nbSimCursor = (M.nbSimCursor % #list) + 1
    M.nbSimBase(list[M.nbSimCursor], h, scan)
    return 1
end

----------------------------------------------------------------------------------------------------------------
-- you and their base: visits, standing, welcome / turned away (Territory), staying the night, merging, raids
----------------------------------------------------------------------------------------------------------------
function M.nbMoraleWord(v) v = tonumber(v) or 50; if v >= 70 then return "high spirits" elseif v >= 45 then return "steady" elseif v >= 25 then return "low" end return "breaking" end
function M.nbFoodWord(b) local per = (tonumber(b.food) or 0) / math.max(1, b.crewN or 1); if per >= 7 then return "well stocked" elseif per >= 3 then return "enough food" elseif per >= 1 then return "food running low" end return "starving" end
function M.nbRepWord(v) v = tonumber(v) or 50; if v >= 75 then return "they like you" elseif v >= 55 then return "friendly to you" elseif v > 40 then return "neutral" elseif v > 20 then return "wary of you" end return "they hate you" end
function M.nbRep(b, d, why)
    b.rep = clamp((tonumber(b.rep) or 50) + d, 0, 100)
    if why then addEvent(b, why, d < 0 and "rep-" or "rep+") end
end
-- how they'd take you right now (also the Places window's "standing")
function M.nbStanding(b, player)
    local h = hours()
    local eff = math.floor(((tonumber(b.rep) or 50) - 50) / 2)
    local r = b.leader and rec(b.leader) or nil
    if r and player then eff = eff + (opinion(r, player) or 0) end
    if b.leader and M.bondTier then local ok, t = pcall(M.bondTier, b.leader); if ok and tonumber(t) then eff = eff + t * 5 end end
    if (tonumber(b.guestUntilH) or -1) > h then eff = eff + 60 end
    if h - (tonumber(b.raidedH) or -1e9) < 72 then eff = math.min(eff - 40, -40) end -- you killed one of theirs: enemies for days
    local tier = M.territoryTier and M.territoryTier(eff) or (eff >= 35 and "welcome" or (eff >= 15 and "tolerate" or (eff > -15 and "neutral" or "enemy")))
    return tier, eff
end
function M.nbAtPlayer(player)
    local x, y = pos(player)
    if x == nil then return nil end
    for _, b in ipairs(M.nbActive()) do if inside(b.bounds, x, y, M.nbCfg.visitPad) then return b end end
    return nil
end
M.nbAtBy = M.nbAtBy or {} -- MP: the base each player is at (by player key)
function M.nbPresence(now)
    if mpServer() then M.eachPlayer(M.nbPresenceFor, now); return end
    return M.nbPresenceFor(thePlayer(), now)
end
function M.nbPresenceFor(player, now)
    if player == nil then return end
    local b = M.nbAtPlayer(player)
    if mpServer() then
        local k = ALifeSide.keyOf(player)
        if b == nil then M.nbAtBy[k] = nil; return end
        if M.nbAtBy[k] == b.id then return end
        M.nbAtBy[k] = b.id
    else
        if b == nil then M.nbAt = nil; return end
        if M.nbAt == b.id then return end
        M.nbAt = b.id
    end
    local h = hours()
    b.visits = (b.visits or 0) + 1
    b.lastVisitH = h
    M.nbStats.visits = M.nbStats.visits + 1
    if b.known ~= "visited" then addEvent(b, "You came by " .. b.name .. " for the first time", "visit") end
    b.known = "visited"
end
-- Territory: their house is "home, the Mill House"; their reputation of you, guest nights and raids move the welcome
M._w52 = M._w52 or {}
local function wrapOnce(name, maker)
    if M._w52[name] or type(M[name]) ~= "function" then return end
    M._w52[name] = true
    M[name] = maker(M[name])
end
M.nbWrapOnce = wrapOnce
M.nbStayWords = { "stay the night", "spend the night", "crash here", "crash at your", "crash with you", "sleep here", "put me up", "room for one more",
    "can i stay", "could i stay", "let me stay", "bunk here", "bunk with you", "shelter for the night", "a place to sleep", "somewhere to sleep" }
M.nbMergeWords = { "join forces", "merge", "bring your people", "bring your group", "all of you come", "your whole group", "move your people",
    "your people can live", "combine our", "all of you can live", "your group should join", "your group can join", "pack up and come" }
function M.nbAskStay(l, player)
    local b = M.nbOfMember(l.record)
    if b == nil then return nil end
    local h = hours()
    local tier, eff = M.nbStanding(b, player)
    local uid = tostring(l.record.uid)
    local v = opinion(l.record, player) or 0
    eff = eff + math.floor(v / 2)
    local per = (tonumber(b.food) or 0) / math.max(1, b.crewN or 1)
    local ok, why
    if h - (tonumber(b.raidedH) or -1e9) < 72 then ok, why = false, "they hurt one of your people - not under your roof"
    elseif per < 1 then ok, why = false, "you can barely feed your own people at " .. b.name
    elseif eff >= 20 then ok, why = true, (tier == "welcome" and "they're a friend of " .. b.name or "they've been decent to you - one night") 
    elseif eff >= 5 and (hash(uid .. math.floor(h / 24)) % 2 == 0) then ok, why = true, "one night, and they keep their hands to themselves"
    else ok, why = false, "you don't know them well enough to let them sleep at " .. b.name end
    if ok then
        b.guestUntilH = h + M.nbCfg.guestH
        M.nbRep(b, 2, "Let you stay the night at " .. b.name)
    else addEvent(b, "Wouldn't let you stay at " .. b.name, "refused") end
    M.nbAskLast = { uid = uid, kind = "stay", ok = ok, why = why, at = nowMs(), base = b.name }
    return ok, why
end
function M.nbAskMerge(l, player)
    local b = M.nbOfMember(l.record)
    if b == nil then return nil end
    local h = hours()
    local base = M.baseState and M.baseState(player) or nil
    local _, eff = M.nbStanding(b, player)
    local per = (tonumber(b.food) or 0) / math.max(1, b.crewN or 1)
    -- liking you only gets you so far (max 40): a healthy home of their own, above all a fortified one, holds them
    local score = math.min(40, math.floor(eff / 2)) + ((b.morale or 50) < 40 and 25 or 0) + (per < 2 and 20 or 0)
        - (b.stage == "fortified" and 20 or 0) - ((b.morale or 50) >= 60 and 10 or 0) + (base and math.floor(((base.morale or 50) - 50) / 3) or 0)
    local ok, why
    if base == nil then ok, why = false, "they don't even have a place of their own" 
    elseif h - (tonumber(b.raidedH) or -1e9) < 72 then ok, why = false, "not after what they did to your people"
    elseif score >= 40 then ok, why = true, ((b.morale or 50) < 40 or per < 2) and ("things at " .. b.name .. " are falling apart - their place is better") or "together you're stronger"
    else ok, why = false, b.stage == "fortified" and ("you built " .. b.name .. " with your own hands - you're not leaving it") or ("your people are fine at " .. b.name .. " for now") end
    local moved = 0
    if ok and M.settleApply then
        local scan = M.nbScan(true)
        for _, r in ipairs(scan.crews[b.id] or {}) do
            local sh = shellFor(r.uid)
            if sh and select(2, pcall(M.settleApply, { record = r, shell = sh }, player, base, {})) == true then moved = moved + 1 end
        end
        if moved > 0 then M.nbAbandon(b, "merged")
        else ok, why = false, "you can't bring everyone right now" end
    end
    if not ok then addEvent(b, "Turned down moving in with you", "refused") end
    M.nbAskLast = { uid = tostring(l.record.uid), kind = "merge", ok = ok, why = why, at = nowMs(), base = b.name, moved = moved }
    return ok, why, moved
end
local function has(low, list) for _, w in ipairs(list) do if string.find(low, w, 1, true) then return w end end return nil end
function M.nbOnWords(player, text, loud, hearers)
    if not M.nbOn() or type(text) ~= "string" then return end
    local l = hearers and hearers[1] or nil
    if l == nil or l.record == nil or M.nbOfMember(l.record) == nil then return end
    local low = " " .. string.lower(text) .. " "
    local ok, why = nil, nil
    local kind = nil
    if has(low, M.nbMergeWords) then kind = "merge"; ok, why = M.nbAskMerge(l, player)
    elseif has(low, M.nbStayWords) then kind = "stay"; ok, why = M.nbAskStay(l, player) end
    if kind == nil then return end
    if M.logInteraction then pcall(M.logInteraction, tostring(l.record.uid), (ok and "Agreed" or "Refused") .. (kind == "stay" and " to let you stay the night (" or " to bring their people to your base (") .. tostring(why) .. ")", nil, nil, "event") end
    if not (M.bridgeAlive and M.bridgeAlive(nowMs())) and M.say and l.shell then
        local lines = kind == "stay" and (ok and { "Alright. One night. There's a spot by the stove.", "Sure - stay. Don't make me regret it." } or { "No. Not here.", "Sorry. Can't put you up." })
            or (ok and { "Alright. We'll pack up and come.", "Fine - we're in. Show us the way." } or { "No. This is our home.", "We're staying put." })
        pcall(M.say, l.shell, player, pick(lines, tostring(l.record.uid) .. kind), { record = l.record })
    end
end
-- deaths: grief for the base; you killing one of them is a raid
local function isPlayer(k)
    if k == nil then return false end
    if k == thePlayer() then return true end
    local ok, v = pcall(function() return instanceof(k, "IsoPlayer") end)
    return ok and v == true
end
function M.nbOnDeath(body, uid, killer)
    if not M.nbOn() then return end
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or nil
    local b = m and m.havenId and M.nbOf(m.havenId) or nil
    if b == nil or b.status ~= "active" then return end
    local h = hours()
    pushH(b, "losses", h)
    if isPlayer(killer) then
        b.raidedH = h
        M.nbRep(b, -M.nbCfg.raidRep, "You killed " .. firstOf(r) .. " of " .. b.name)
        if M.keyMem and b.leader then pcall(M.keyMem, b.leader, "grudge", "The newcomer killed " .. firstOf(r) .. " from " .. b.name) end
    else addEvent(b, firstOf(r) .. " of " .. b.name .. " died", "death") end
    if b.leader == tostring(uid) then b.leader = nil end
    -- 0.5.2.1: off the roster now, anchor cleared; the last one dead = the base falls
    M.nbNoteDeath(b, rosterKey(r), nameOf(r), h)
    M.nbClearAnchor(uid)
    M.nbScanCache = nil
    if M.nbLiving(b) == 0 then M.nbFall(b, h) end
end
-- taking from their stores while they watch
function M.nbOnTake(player, container)
    if not M.nbOn() or player == nil or container == nil then return end
    local mine = false
    pcall(function() mine = container:isInCharacterInventory(player) end)
    if mine then return end
    local x, y = nil, nil
    pcall(function() local p = container:getParent(); local sq = p and p:getSquare() or nil; if sq then x, y = sq:getX(), sq:getY() end end)
    if x == nil then pcall(function() local sq = container:getSourceGrid(); if sq then x, y = sq:getX(), sq:getY() end end) end
    if x == nil then return end
    local h = hours()
    for _, b in ipairs(M.nbActive()) do
        if inside(b.bounds, x, y, 1) and (tonumber(b.guestUntilH) or -1) <= h then
            local watcher = nil
            for _, r in ipairs((M.nbScan().crews or {})[b.id] or {}) do
                local sh = shellFor(r.uid)
                local sx, sy = pos(sh)
                if sx and d2(sx, sy, x, y) <= 20 * 20 then watcher = { record = r, shell = sh }; break end
            end
            if watcher then
                local now = nowMs()
                if now - (M.nbTakeAt or -1e12) < 30000 then return true end
                M.nbTakeAt = now
                M.nbRep(b, -M.nbCfg.theftRep, h - (tonumber(b.theftH) or -1e9) > 1 and ("Caught you taking from the stores at " .. b.name) or nil)
                b.theftH = h
                local line = pick({ "Hey! That's ours. Put it back.", "Those are our stores. Hands off.", "You don't take from us." }, b.id .. now)
                if not (M.react and M.react("npcBase", watcher, player, { what = "The newcomer is taking things from your base's stores (" .. b.name .. ") without asking. Tell them off.",
                        maxWords = 14, fallback = line }, { key = "npcBaseTake:" .. b.id, keyCooldownMs = 30000, modeCooldownMs = 5000, urgent = true, face = "player" })) and M.say then
                    pcall(M.say, watcher.shell, player, line, { record = watcher.record })
                end
                return true
            end
        end
    end
end
-- helping hold off the dead at their door
function M.nbOnZombieDead(z)
    if not M.nbOn() then return end
    local zx, zy = pos(z)
    local player = nearestTo(zx, zy) -- MP: the player who was there
    local px, py = pos(player)
    if zx == nil or px == nil or d2(zx, zy, px, py) > 30 * 30 then return end
    local h = hours()
    local day = math.floor(h / 24)
    for _, b in ipairs(M.nbActive()) do
        if inside(b.bounds, zx, zy, 15) then
            local present = false
            for _, r in ipairs((M.nbScan().crews or {})[b.id] or {}) do if shellFor(r.uid) then present = true; break end end
            if present then
                if b.defendDay ~= day then b.defendDay, b.defendN = day, 0 end
                if b.defendN < M.nbCfg.defendRepDay then
                    b.defendN = b.defendN + 1
                    M.nbRep(b, 1, b.defendN == 1 and ("You helped hold off the dead at " .. b.name) or nil)
                end
            end
            return
        end
    end
end
-- the AI: their own base, their mood, other bases (gossip); a base whose name is spoken becomes "heard of"
function M.nbBrief(b, h, player)
    local ev = {}
    for i = #(b.events or {}), math.max(1, #(b.events or {}) - 2), -1 do ev[#ev + 1] = b.events[i].t end
    local town = nil
    local hv = H()
    if fn(hv, "placeName") then local ok, p = pcall(hv.placeName, { x = b.x, y = b.y }); if ok and type(p) == "string" and p ~= "" then town = p end end
    return { name = b.name, stage = M.nbStageWords[b.stage] or b.stage, members = b.crewN or 0, leader = b.leaderName, morale = M.nbMoraleWord(b.morale),
        food = M.nbFoodWord(b), goods = M.nbGoodsWords and M.nbGoodsWords(b) or nil, power = M.nbStrengthWord and M.nbStrengthWord(b) or nil, living = b.trade and M.dirTradeWords and M.dirTradeWords[b.trade] or nil, road = M.nmWords and M.nmWords(b) or nil, wealth = type(ALifeWorth) == "table" and ALifeWorth.wealthWord(b) or nil, rep = M.nbRepWord(b.rep), events = ev, place = town,
        threatened = b.lastAttack ~= nil and h - (b.lastAttack.h or -1e9) < 48 or nil, raided = h - (tonumber(b.raidedH) or -1e9) < 72 or nil }
end
function M.nbExtras(req, player, listener, now)
    if not M.nbOn() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local h = hours()
    local uid = tostring(listener.record.uid)
    local b = M.nbOfMember(listener.record)
    if b then
        local nb = M.nbBrief(b, h, player)
        nb.role = b.leader == uid and "leader" or "member"
        nb.guest = (tonumber(b.guestUntilH) or -1) > h or nil
        local px, py = pos(player)
        nb.here = px ~= nil and inside(b.bounds, px, py, M.nbCfg.visitPad) or nil
        req.npcBase = nb
    end
    local x, y = pos(listener.shell)
    if x == nil and type(listener.record.worldPosition) == "table" then x, y = listener.record.worldPosition.x, listener.record.worldPosition.y end
    if x then
        local near = {}
        for _, o in ipairs(M.nbActive()) do
            if (b == nil or o.id ~= b.id) and d2(o.x, o.y, x, y) <= M.nbCfg.gossipTiles ^ 2 then near[#near + 1] = { o = o, d = d2(o.x, o.y, x, y) } end
        end
        table.sort(near, function(p, q) return p.d < q.d end)
        local out = {}
        for i = 1, math.min(M.nbCfg.gossipMax, #near) do
            local o = near[i].o
            out[#out + 1] = { name = o.name, leader = o.leaderName, members = o.crewN or 0, stage = M.nbStageWords[o.stage] or o.stage, morale = M.nbMoraleWord(o.morale),
                trouble = (o.lastAttack ~= nil and h - (o.lastAttack.h or -1e9) < 72) and "attacked lately" or (M.nbFoodWord(o) == "starving" and "starving" or nil),
                dist = math.floor(math.sqrt(near[i].d)) }
        end
        if #out > 0 then req.basesNearby = out end
    end
    local a = M.nbAskLast
    if a and a.uid == uid and now - a.at < 15000 then req.npcBaseAsk = { kind = a.kind, ok = a.ok, why = a.why } end
end
function M.nbHeard(text)
    if type(text) ~= "string" or text == "" then return end
    local low = string.lower(text)
    for _, b in ipairs(M.nbActive()) do
        if b.known == nil then
            local core = string.lower(string.gsub(tostring(b.name or ""), "^the ", ""))
            if #core >= 5 and string.find(low, core, 1, true) then b.known = "heard"; addEvent(b, "You heard about " .. b.name, "heard") end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- daily life anchored at the base (Activity / Habits): night guard, sleep inside, work by day, boarding up
----------------------------------------------------------------------------------------------------------------
function M.nbGuardOf(b, h)
    local loaded = {}
    for _, r in ipairs(((M.nbScanCache or {}).crews or {})[b.id] or {}) do if shellFor(r.uid) then loaded[#loaded + 1] = tostring(r.uid) end end
    if #loaded < 2 then return nil end -- a loner sleeps (A-Life still wakes them for danger)
    table.sort(loaded)
    return loaded[(math.floor(h / 24) % #loaded) + 1]
end
function M.nbCtx(uid, l, ctx)
    if not M.nbOn() or type(ctx) ~= "table" then return ctx end
    local b = M.nbOfMember(l.record)
    if b == nil then return ctx end
    local x, y = pos(l.shell)
    if x == nil or not inside(b.bounds, x, y, 12) then return ctx end
    local h = hours()
    ctx.npcBase = { id = b.id, stage = b.stage, inside = inside(b.bounds, x, y, 0), guard = M.nbGuardOf(b, h) == tostring(uid),
        boarded = b.stage == "fortified" or b.careDay == math.floor(h / 24) }
    ctx.camp = true
    return ctx
end
function M.nbWeights(uid, l, c, ctx, w)
    local nb = type(ctx) == "table" and ctx.npcBase or nil
    if nb == nil or type(w) ~= "table" then return w end
    local function add(kind, v) if M.actCatalog[kind] and v > 0 then w[kind] = (w[kind] or 0) + v end end
    if c.night then
        if nb.guard then add("guard", 70); add("watch", 20); w.sleep = math.floor((w.sleep or 0) * 0.2)
        else add("sleep", 30); w.chop, w.garden, w.scavenge = nil, nil, nil end
    else
        add("scavenge", 10); add("tinker", 6); add("patrol", 10); add("carry", 8); add("repair", 6)
        if not ctx.indoors then add("chop", 8); add("garden", 6) end
        if not nb.boarded then add("barricade", 35) end
    end
    return w
end
function M.nbActivityStarted(l, kind, now)
    local b = M.nbOfMember(l.record)
    if b == nil then return end
    local h = hours()
    if kind == "barricade" then
        if h - (tonumber(b.careH) or -1e9) >= 1 then
            b.careH = h
            b.work = math.min(M.nbCfg.fortWork, (b.work or 0) + M.nbCfg.careWork)
            if b.careDay ~= math.floor(h / 24) then addEvent(b, firstOf(l.record) .. " boarded up windows at " .. b.name, "work") end
            M.nbSetStage(b, h)
        end
        b.careDay = math.floor(h / 24)
    elseif kind == "guard" then b.guardH = h end
end

----------------------------------------------------------------------------------------------------------------
-- install: wrappers on other files (idempotent), events, ticks
----------------------------------------------------------------------------------------------------------------
function M.nbInstall()
    wrapOnce("actContext", function(orig) return function(uid, l, c)
        local ctx = orig(uid, l, c)
        local ok, out = pcall(M.nbCtx, uid, l, ctx)
        return ok and out or ctx
    end end)
    wrapOnce("actWeights", function(orig) return function(uid, l, c, ctx)
        local w = orig(uid, l, c, ctx)
        if not M.nbOn() then return w end
        local ok, out = pcall(M.nbWeights, uid, l, c, ctx, w)
        return ok and out or w
    end end)
    wrapOnce("startActivity", function(orig) return function(l, kind, now, opts)
        local ok, why = orig(l, kind, now, opts)
        if ok and M.nbOn() and type(l) == "table" and type(l.record) == "table" then pcall(M.nbActivityStarted, l, kind, now) end
        return ok, why
    end end)
    -- Territory: the base's name, and their reputation of you / guest nights / raids in the welcome
    wrapOnce("territoryAt", function(orig) return function(player, near)
        local t = orig(player, near)
        if M.nbOn() and type(t) == "table" and t.id then
            local b = M.nbOf(t.id)
            if b and b.status == "active" then t.kind = "home, " .. b.name; t.nbId = b.id end
        end
        return t
    end end)
    wrapOnce("territoryMood", function(orig) return function(l, player)
        local eff, stance = orig(l, player)
        if M.nbOn() and type(l) == "table" then
            local b = M.nbOfMember(l.record)
            if b then
                local h = hours()
                eff = (tonumber(eff) or 0) + math.floor(((tonumber(b.rep) or 50) - 50) / 2)
                if (tonumber(b.guestUntilH) or -1) > h then eff = eff + 60 end
                if h - (tonumber(b.raidedH) or -1e9) < 72 then eff = math.min(eff - 40, -40) end
                if M.bondTier then local ok, t = pcall(M.bondTier, tostring(l.record.uid)); if ok and tonumber(t) then eff = eff + t * 4 end end
            end
        end
        return eff, stance
    end end)
    wrapOnce("territoryStep", function(orig) return function(st, l, player, tier, now)
        local r = orig(st, l, player, tier, now)
        if M.nbOn() and type(st) == "table" and st.nbId and not st.nbNoted then
            local b = M.nbOf(st.nbId)
            if b and (tier == "welcome" or tier == "tolerate") then st.nbNoted = true; addEvent(b, (tier == "welcome" and "Welcomed you into " or "Let you into ") .. b.name, "welcome")
            elseif b and (st.step or 0) >= 1 then st.nbNoted = true; addEvent(b, "Turned you away from " .. b.name, "refused") end
        end
        return r
    end end)
    -- one of their people asked to live at your base: their own home pulls them back unless it's falling apart
    wrapOnce("settleVerdict", function(orig) return function(l, player, base)
        local ok, why, bring, score = orig(l, player, base)
        if not M.nbOn() or type(l) ~= "table" then return ok, why, bring, score end
        local b = M.nbOfMember(l.record)
        if b == nil then return ok, why, bring, score end
        local need = (M.settleCfg and M.settleCfg.need) or 40
        local per = (tonumber(b.food) or 0) / math.max(1, b.crewN or 1)
        score = tonumber(score) or 0
        if (b.morale or 50) < 30 or per < 1 then
            score = score + 15
            if not ok and score >= need then ok, why = true, "things at " .. b.name .. " are falling apart - their place is a better bet" end
        else
            score = score - 15
            if ok and score < need then ok, why = false, "you have a home already - " .. b.name .. " - and people there counting on you" end
        end
        return ok, why, bring, score
    end end)
    wrapOnce("settleApply", function(orig) return function(l, player, base, bring)
        local b = (M.nbOn() and type(l) == "table") and M.nbOfMember(l.record) or nil
        local ok = orig(l, player, base, bring)
        if ok and b then
            local r = l.record
            pcall(PA().ActorRegistry.update, r.uid, r.revision, function(entry)
                if type(entry.memory) == "table" then entry.memory.havenId, entry.memory.supplyDepot = nil, nil end
            end)
            addEvent(b, firstOf(r) .. " left " .. b.name .. " to live at your base", "left")
            M.nbScanCache = nil
        end
        return ok
    end end)
    wrapOnce("say", function(orig) return function(shell, player, text, opts)
        if M.nbOn() then pcall(M.nbHeard, text) end
        return orig(shell, player, text, opts)
    end end)
    -- taking from their stores (vanilla transfer action; method checked)
    if not M._w52.transfer and type(ISInventoryTransferAction) == "table" and type(ISInventoryTransferAction.perform) == "function" then
        M._w52.transfer = true
        local orig = ISInventoryTransferAction.perform
        ISInventoryTransferAction.perform = function(self, ...)
            pcall(M.nbOnTake, self and self.character, self and self.srcContainer)
            return orig(self, ...)
        end
    end
end

-- timers: presence 5 s, life 60 s (one base), founding 120 s (a few groups); all ms-gated, perf-counted
M.nbLast = { presence = -1e12, sim = -1e12, found = -1e12 }
function M.nbTick(now)
    if not M.nbOn() then return end
    if not M._w52.ready then M._w52.ready = true; pcall(M.nbInstall) end -- every file is loaded by the first tick
    local t0 = (getTimestampMs and getTimestampMs()) or nowMs()
    local L = M.nbLast
    if now - L.presence >= M.nbCfg.tickMs then L.presence = now; local ok, e = pcall(M.nbPresence, now); if not ok then log("presence error: " .. tostring(e)) end end
    if now - L.sim >= M.nbCfg.simMs then L.sim = now; local ok, e = pcall(M.nbSimTick, hours()); if not ok then log("sim error: " .. tostring(e)) end end
    if now - L.found >= M.nbCfg.foundMs then L.found = now; local ok, e = pcall(M.nbFoundTick, hours()); if not ok then log("found error: " .. tostring(e)) end end
    if M.sbTick then local ok, e = pcall(M.sbTick, now); if not ok then log("seed error: " .. tostring(e)) end end -- 0.5.2.1 pre-seeded bases
    local dt = ((getTimestampMs and getTimestampMs()) or nowMs()) - t0
    M.nbStats.ticks = M.nbStats.ticks + 1
    M.nbStats.tickMs = M.nbStats.tickMs + dt
    if dt > M.nbStats.maxMs then M.nbStats.maxMs = dt end
end
function M.nbPerf()
    local s = M.nbStats
    return "bases " .. #M.nbActive() .. " active, ticks " .. math.floor(s.ticks) .. ", avg " .. ALifeFmtDec(s.ticks > 0 and s.tickMs / s.ticks or 0, 3)
        .. " ms, max " .. ALifeFmtDec(s.maxMs, 1) .. " ms, scans " .. math.floor(s.scans) .. ", probes " .. math.floor(s.probes) .. ", cache hits "
        .. math.floor(s.cacheHits) .. ", sims " .. math.floor(s.sims) .. ", founded " .. math.floor(s.founded)
end

-- the Places window: the bases you know (visited, told, heard of), active first
function M.nbRows(player)
    local h = hours()
    local out = {}
    for _, b in pairs(M.nbStore().byId) do
        if type(b) == "table" and (b.known ~= nil or M.nbShowAll) then
            local fac = nil
            local cat = PA().Catalog
            if b.faction and fn(cat, "faction") then
                local ok, f = pcall(cat.faction, b.faction)
                if ok and type(f) == "table" and type(f.general) == "table" and type(f.general.name) == "string" then fac = f.general.name end
            end
            local tier, eff = M.nbStanding(b, player)
            local lv = b.lastVisitH and (h - b.lastVisitH < 24 and "today" or (math.floor((h - b.lastVisitH) / 24) .. " days ago")) or "never"
            local status = b.status == "active" and (M.nbStageWords[b.stage] or b.stage) or b.status == "fallen" and "fallen - everyone there died"
                or ((b.status == "overrun" and "overrun" or (b.status == "merged" and "moved in with you" or "abandoned"))
                .. (b.endReason and M.nbEndWords[b.endReason] and b.status == "abandoned" and (" - " .. M.nbEndWords[b.endReason]) or ""))
            out[#out + 1] = { id = b.id, name = b.name, faction = fac or b.faction or "survivors", leader = b.leaderName or "nobody", members = b.crewN or 0,
                status = status, active = b.status == "active", morale = M.nbMoraleWord(b.morale), food = M.nbFoodWord(b), lastVisit = lv,
                known = b.known, standing = tier, standingN = eff, rep = b.rep or 50, x = b.x, y = b.y,
                guest = (tonumber(b.guestUntilH) or -1) > h, event = b.events and b.events[#b.events] and b.events[#b.events].t or nil,
                fallen = b.status == "fallen" or nil, lastMembers = b.lastCrewN, seeded = b.seeded or nil,
                dead = (function() local t = {} for _, d in ipairs(b.dead or {}) do if d.n then t[#t + 1] = d.n end end return #t > 0 and t or nil end)() }
        end
    end
    table.sort(out, function(a, b) if a.active ~= b.active then return a.active end return tostring(a.name) < tostring(b.name) end)
    return out
end
function M.nbMark(id, player)
    local b = M.nbOf(id)
    local hv = H()
    if b == nil or not fn(hv, "sendMarker") then return false end
    local ok, r = pcall(hv.sendMarker, player or thePlayer(), { x = math.floor(b.x), y = math.floor(b.y), name = string.gsub(b.name, "^the ", "The ") })
    return ok and r == true
end
if type(M.requestExtras) == "table" then table.insert(M.requestExtras, function(req, player, listener, now) pcall(M.nbExtras, req, player, listener, now) end) end
-- pre-1.0 MP (P5): the Places window on an MP client: the bases you know come from the server ("nbRows" view: flat
-- rows, the dead joined into one line); "mark on map" runs there as you.
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    local function flat(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for _, x in ipairs(v) do
            if type(x) == "table" then x = x.t or x.text or x.n end
            if x ~= nil then t[#t + 1] = tostring(x) end
        end
        return string.sub(table.concat(t, "; "), 1, 280)
    end
    ALifeRemote.view("nbRows", function(player)
        local out = {}
        local rows = M.nbRows(player)
        if fn(M, "jnRows") and M.settings.journal ~= false then rows = M.jnRows(rows) end -- what you know, not what's true
        for i, r in ipairs(rows) do
            if i > 60 then break end
            local row = {}
            for k, v in pairs(r) do
                if type(v) == "table" then row[k] = flat(v) elseif type(v) == "string" then row[k] = string.sub(v, 1, 280) else row[k] = v end
            end
            out[#out + 1] = row
        end
        return out
    end, {})
    ALifeRemote.expose("nbMark", 1, 2)
end
if type(M.playerWordHooks) == "table" then table.insert(M.playerWordHooks, M.nbOnWords) end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
if type(M.eventModes) == "table" and M.reactRequest then M.eventModes.npcBase = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end
if type(Events) == "table" then
    if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Bases", function(body, uid, killer) pcall(M.nbOnDeath, body, uid, killer) end)
    end
    if type(Events.OnZombieDead) == "table" and type(Events.OnZombieDead.Add) == "function" then
        ALifeHealth.add(Events.OnZombieDead, "ALifeLLMTalk_Bases", function(z) pcall(M.nbOnZombieDead, z) end)
    end
    if type(Events.OnTick) == "table" and type(Events.OnTick.Add) == "function" then
        local last = -1e12
        ALifeHealth.tickAdd("ALifeLLMTalk_Bases", function()
            local now = nowMs()
            if now - last < 1000 then return end
            last = now
            M.nbTick(now)
        end)
    end
    if type(Events.OnGameStart) == "table" and type(Events.OnGameStart.Add) == "function" then
        Events.OnGameStart.Add(function() pcall(M.nbInstall) end)
    end
end
pcall(M.nbInstall)
return M
