-- A-Life NPC Overhaul pre-1.0: TRADE, PART 2. RUNS YOU CAN SEE, ROUTES, ESCORTS, MIDDLEMEN (docs/PLAN-TRADE.md T1 T5 T6).
--  * a trade run between groups is no longer goods moved on paper: real members leave home with the goods (out of the
--    stash), walk the real road time (ALifeTalk_Leaving puts them along the road while nobody's near), trade at the
--    other end, and walk home with what they got. Meet them on the road and the goods are really in their packs:
--    talk, haggle, walk with them, or rob them (ALifeTalk_TradeEmbargo for what that costs you).
--  * a run is legs: { to, give, want }. A swap = there and home. A middleman (trader groups only) = buy at a group
--    with plenty, sell at a group that lacks it, home. Deals (TradeDeals) and your own caravans (TradeOwn) use it too.
--  * routes: every pair of groups has a road that gets safer as runs get through and worse when they're robbed;
--    groups send escorts on bad roads (fighters away from home for real) or don't go at all.
--  * robbery off screen is rolled once at the halfway point; on screen it is whatever really happens.
-- Performance: one pass a second over the runs on the road (usually 0-4); off-screen legs only compare clock hours.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_TradeRuns")
require "ALifeLLMTalk/ALifeTalk_TradePrice"
require "ALifeLLMTalk/ALifeTalk_Caravans"
local M = ALifeLLMTalk
local T = ALifeTrade
if type(M) ~= "table" or type(T) ~= "table" then return end
local fn, d2, hours, hash, log, event = T.fn, T.d2, T.hours, T.hash, T.log, T.event

T.defaults({ tradeRuns = true, runCrew = 2, runKeepHome = 1, runWorth = 20, runSeeTiles = 120,
    routeSafeGain = 5, routeRobLoss = 25, routeFadeDay = 2, escortBelow = 35, escortCrew = 1, skipBelow = 10,
    escortRobCut = 50, youEscortMin = 3, youEscortRep = 5,
    brokers = true, brokerRuns = 1, brokerRange = 1200 })
T.addRows({
    { "tradeRuns", "Trade runs between groups are real people walking the road with the goods (meet, trade with, escort or rob them)" },
    { "runCrew", "Trade runs: people a group sends with the goods", { 1, 2, 3 } },
    { "runWorth", "Trade runs: how much a run carries (worth)", { 10, 20, 40 } },
    { "escortBelow", "Trade routes: road this bad (of 100) and they send an armed escort", { 20, 35, 50 } },
    { "skipBelow", "Trade routes: road this bad (of 100) and they don't go at all", { 0, 10, 20 } },
    { "youEscortMin", "Trade runs: minutes you walk with a run for it to count as escorting them", { 2, 3, 6 } },
    { "brokers", "Middlemen: trader groups buy where something's plentiful and carry it to where it's short" },
    { "brokerRange", "Middlemen: how far a trader group looks for a deal (tiles)", { 800, 1200, 2000 } },
})
M.trStats = M.trStats or { runs = 0, arrived = 0, home = 0, robbed = 0, lost = 0, met = 0, escorted = 0, brokers = 0, skipped = 0, escorts = 0 }
local S = M.trStats

local function reg() return T.PA().ActorRegistry end
local function shellOf(uid) local sh = nil; pcall(function() sh = T.PA().Talk.shellFor(uid) end); return sh end
local function update(uid, f)
    local R = reg()
    if not (fn(R, "read") and fn(R, "update")) then return false end
    local r = R.read(uid)
    if r == nil then return false end
    local ok, res = pcall(R.update, r.uid, r.revision, function(e) e.memory = type(e.memory) == "table" and e.memory or {}; f(e) end)
    return ok and res ~= false
end
local function stashOf(b, create) return fn(M, "nbStashList") and M.nbStashList(M.nbHavenOf(b), create) or nil end
local function typeOf(it) return type(it) == "table" and it.type or it end
local function kindOf(t) return fn(M, "nbKindOf") and M.nbKindOf(t) or "other" end
local function worthOf(t) return type(ALifeWorth) == "table" and math.max(0.1, (ALifeWorth.of(t))) or 1 end
local function sync(b) if type(b) == "table" then pcall(M.nbFoodSync, b, M.nbHavenOf(b)) end end

----------------------------------------------------------------------------------------------------------------
-- goods in and out of a stash (plain lists of item types while on the road)
----------------------------------------------------------------------------------------------------------------
-- take things of a kind out of b's stash until their worth reaches cap (food: never below what they keep)
function T.takeKind(b, kind, cap)
    local list = stashOf(b)
    local out, got = {}, 0
    if list == nil then return out, 0 end
    local keep = 0
    if kind == "food" or kind == "water" then keep = math.floor((tonumber(b.crewN) or 1) * ((M.cvCfg and M.cvCfg.foodKeepDays) or 5) / ((M.nbCfg and M.nbCfg.foodPerItem) or 0.25)) end
    local have = 0
    if keep > 0 then for _, it in ipairs(list) do if kindOf(typeOf(it)) == kind then have = have + 1 end end end
    for i = #list, 1, -1 do
        if got >= cap or (keep > 0 and have <= keep) then break end
        local t = typeOf(list[i])
        if t and kindOf(t) == kind then
            local v = worthOf(t)
            if got + v <= cap * 1.25 or #out == 0 then
                table.remove(list, i); out[#out + 1] = t; got = got + v; have = have - 1
            end
        end
    end
    if #out > 0 then sync(b) end
    return out, got
end
function T.putIn(b, items)
    local list = stashOf(b, true)
    if list == nil then return 0 end
    for _, t in ipairs(items or {}) do list[#list + 1] = { type = t } end
    sync(b)
    return #(items or {})
end
function T.worthOfList(items) local w = 0; for _, t in ipairs(items or {}) do w = w + worthOf(t) end; return w end
function T.kindsOfList(items) local k = {}; for _, t in ipairs(items or {}) do local x = kindOf(t); k[x] = (k[x] or 0) + 1 end; return k end
function T.mainKind(items)
    local best, bn = nil, 0
    for k, n in pairs(T.kindsOfList(items)) do if n > bn or (n == bn and tostring(k) < tostring(best)) then best, bn = k, n end end
    return best
end

----------------------------------------------------------------------------------------------------------------
-- T5: routes
----------------------------------------------------------------------------------------------------------------
local function rkey(a, b) a, b = tostring(a), tostring(b); if a < b then return a .. "|" .. b end return b .. "|" .. a end
function T.route(aId, bId)
    local st = T.store()
    local k = rkey(aId, bId)
    local r = st.routes[k]
    if type(r) ~= "table" then r = { safe = 50, runs = 0, robbed = 0, a = tostring(aId), b = tostring(bId), dayH = hours() }; st.routes[k] = r end
    return r
end
function T.routeFade(r, h)
    local days = math.floor((h - (tonumber(r.dayH) or h)) / 24)
    if days <= 0 then return end
    r.dayH = (tonumber(r.dayH) or h) + days * 24
    local f = T.num("routeFadeDay") * days
    if r.safe > 50 then r.safe = math.max(50, r.safe - f) elseif r.safe < 50 then r.safe = math.min(50, r.safe + f) end
end
function T.routeSafe(aId, bId) local r = T.route(aId, bId); T.routeFade(r, hours()); return r.safe end
function T.routeWord(safe)
    safe = tonumber(safe) or 50
    if safe >= 70 then return "safe" elseif safe >= 45 then return "quiet" elseif safe >= 25 then return "risky" end
    return "bad"
end
M.trRouteRobbed = function(b, o, robber)
    local r = T.route(b.id, o.id)
    r.safe = math.max(0, r.safe - T.num("routeRobLoss")); r.robbed = r.robbed + 1; r.lastRob = hours()
    r.robber = robber and robber.id or r.robber
    if fn(T, "feudRobbed") and robber then pcall(T.feudRobbed, robber, b) end
end
-- the off-screen robbery chance on a road: worse roads more, an escort cuts it
M.trRouteRobChance = function(b, o, chance)
    local safe = T.routeSafe(b.id, o.id)
    local c = chance * (1 + (50 - safe) / 100)
    local run = T.curRun
    if type(run) == "table" and (tonumber(run.escorts) or 0) > 0 then c = c * (1 - T.num("escortRobCut") / 100) end
    return math.max(0, math.min(0.95, c))
end
-- a warband ended near a road: the roads round there get safer
function T.routesCleared(w)
    if type(w) ~= "table" or not tonumber(w.x) then return end
    local robTiles = (M.cvRunCfg and M.cvRunCfg.robTiles) or 400
    for _, r in pairs(T.store().routes) do
        local a, b = T.base(r.a), T.base(r.b)
        if a and b and d2((a.x + b.x) / 2, (a.y + b.y) / 2, w.x, w.y) <= robTiles ^ 2 then r.safe = math.min(100, r.safe + 30) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- T1: a run
----------------------------------------------------------------------------------------------------------------
-- a place a leg goes to: an NPC base id, or "you" (your trading post / base: TradeDeals, TradeOwn)
function T.placeXY(to, run)
    if to == "you" then
        local post = fn(M, "tpStore") and M.tpStore().post or nil
        if type(post) == "table" and tonumber(post.x) then return post.x, post.y, post.z or 0 end
        local ob = fn(M, "ovBase") and M.ovBase() or nil
        if ob then return ob.x, ob.y, ob.z or 0 end
        return nil
    end
    local b = T.base(to)
    if b and tonumber(b.x) then
        local hv = M.nbHavenOf(b)
        local dp = hv and type(hv.depot) == "table" and hv.depot or nil
        if dp then return dp.x, dp.y, dp.z or 0 end
        return b.x, b.y, 0
    end
    return nil
end
local function homeLegTo(run) return run.from end
function T.runsOf(bId)
    local out = {}
    for _, run in pairs(T.store().runs) do if run.from == bId and run.state ~= "done" then out[#out + 1] = run end end
    return out
end
function T.crewBusy(uid) local m = nil; pcall(function() local r = reg().read(uid); m = r and r.memory end); return type(m) == "table" and m.alcpRun ~= nil end
-- a group sends people off on a run. legs = { { to, give, want, worth }, ... } (the last leg is home, added here)
-- opts = { kind, deal, items (already packed), crewN, owner, tag }
function T.startRun(b, legs, h, opts)
    opts = opts or {}
    if type(b) ~= "table" or type(legs) ~= "table" or #legs == 0 then return nil, "no_legs" end
    local first = legs[1]
    local fx, fy = T.placeXY(b.id)
    local tx, ty = T.placeXY(first.to)
    if fx == nil or tx == nil then return nil, "no_place" end
    -- the road: bad enough and they don't go; bad and they take a fighter along
    local safe = first.to ~= "you" and T.routeSafe(b.id, first.to) or 50
    if safe < T.num("skipBelow") then S.skipped = S.skipped + 1; return nil, "road_bad" end
    local escorts = (safe < T.num("escortBelow")) and math.floor(T.num("escortCrew")) or 0
    local want = math.max(1, math.floor(tonumber(opts.crewN) or T.num("runCrew"))) + escorts
    local can = (tonumber(b.crewN) or 0) - math.max(0, math.floor(T.num("runKeepHome")))
    if can < 1 then return nil, "nobody_spare" end
    local who = fn(M, "cvTravellers") and M.cvTravellers(b, math.min(want, can)) or {}
    if #who == 0 then return nil, "nobody_spare" end
    if #who <= escorts then escorts = math.max(0, #who - 1) end
    -- the goods (out of the stash now)
    local items = opts.items
    if items == nil then items = T.takeKind(b, first.give, tonumber(first.worth) or T.num("runWorth")) end
    if #items == 0 and not opts.empty then return nil, "nothing_to_send" end
    local th = M.travelH(fx, fy, tx, ty, b)
    local run = { id = T.newId("run"), from = b.id, fromName = b.name, kind = opts.kind or "swap", deal = opts.deal, owner = opts.owner,
        legs = legs, leg = 1, items = items, crew = {}, escorts = escorts, leave = h, arrive = h + th, x0 = fx, y0 = fy, x1 = tx, y1 = ty,
        state = "out", packs = {}, loaded = {}, orig = {}, withYouMs = 0, tag = opts.tag }
    for _, r in ipairs(who) do
        local uid = tostring(r.uid)
        if update(uid, function(e) e.memory.alcpRun = run.id end) then run.crew[#run.crew + 1] = uid end
    end
    if #run.crew == 0 then T.putIn(b, items); return nil, "nobody_spare" end
    T.splitPacks(run)
    T.store().runs[run.id] = run
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = run.arrive, tag = "trade_run" }) end
    S.runs = S.runs + 1
    if escorts > 0 then S.escorts = S.escorts + 1 end
    local toName = first.to == "you" and "your place" or tostring((T.base(first.to) or {}).name or "another group")
    event(b, "Sent " .. #run.crew .. " people" .. (escorts > 0 and " (one armed, the road's bad)" or "") .. " with " .. (T.KIND_WORDS[first.give] or "goods") .. " to " .. toName, "trade")
    log(tostring(b.name) .. " run " .. run.id .. " -> " .. tostring(first.to) .. ": " .. #run.crew .. " crew, " .. #items .. " items, " .. tostring(math.floor(th * 10 + 0.5) / 10) .. " h")
    return run
end
-- the goods split between the crew (what each one carries)
function T.splitPacks(run)
    run.packs = {}
    for _, uid in ipairs(run.crew) do run.packs[uid] = {} end
    local n = #run.crew
    if n == 0 then return end
    for i, t in ipairs(run.items or {}) do local uid = run.crew[(i - 1) % n + 1]; local p = run.packs[uid]; p[#p + 1] = t end
end
local function gatherItems(run)
    local out = {}
    for _, uid in ipairs(run.crew) do for _, t in ipairs(run.packs[uid] or {}) do out[#out + 1] = t end end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- packs on real people (you met them): the goods are real items in their inventory while they're loaded
----------------------------------------------------------------------------------------------------------------
local function itemsOf(sh)
    local out = {}
    pcall(function() local l = sh:getInventory():getItems(); for i = 0, l:size() - 1 do out[#out + 1] = l:get(i) end end)
    return out
end
local function idOf(it) local id = nil; pcall(function() id = it:getID() end); return id and tostring(id) or tostring(it) end
local function worn(sh, it)
    local yes = false
    pcall(function() if sh:isEquipped(it) then yes = true end end)
    pcall(function() if sh:isEquippedClothing(it) then yes = true end end)
    return yes
end
function T.packOn(run, uid, sh)
    local orig = {}
    for _, it in ipairs(itemsOf(sh)) do orig[idOf(it)] = true end
    run.orig[uid] = orig
    pcall(function() local inv = sh:getInventory(); for _, t in ipairs(run.packs[uid] or {}) do inv:AddItem(t) end end)
    run.loaded[uid] = true
end
-- what they carry for the run now (weapons are their own: A-Life keeps them)
function T.packRead(run, uid, sh, take)
    local orig = run.orig[uid] or {}
    local out = {}
    pcall(function()
        local inv = sh:getInventory()
        for _, it in ipairs(itemsOf(sh)) do
            local weapon = false
            pcall(function() weapon = instanceof(it, "HandWeapon") end)
            if not orig[idOf(it)] and not weapon and not worn(sh, it) then
                local t = nil; pcall(function() t = it:getFullType() end)
                if t then out[#out + 1] = t; if take then pcall(function() inv:Remove(it) end) end end
            end
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- the legs
----------------------------------------------------------------------------------------------------------------
local function finishRun(run, why)
    for _, uid in ipairs(run.crew) do update(uid, function(e) e.memory.alcpRun = nil end) end
    run.state = "done"
    T.store().runs[run.id] = nil
    for _, f in ipairs(T.onRunDone or {}) do pcall(f, run, why) end
end
T.onRunDone = T.onRunDone or {}
T.onLeg = T.onLeg or {} -- f(run, leg, gave, got) when a leg's trade is done (deals, your caravans)
local function aliveCrew(run)
    local R = reg()
    local alive = {}
    for _, uid in ipairs(run.crew) do
        local r = R.read(uid)
        if r and r.lifecycle ~= "dead" then alive[#alive + 1] = uid end
    end
    return alive
end
local function sendOn(run, h, tx, ty, untilH)
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = untilH, tag = "trade_run",
        final = run.state == "home" and { x = tx + (hash(uid) % 3) - 1, y = ty + (hash(uid .. "y") % 3) - 1, z = 0 } or nil }) end
end
-- a leg's trade at an NPC base: they hand over what they carry, get back what it's worth to the other side
function T.tradeAt(run, leg, h)
    local o = T.base(leg.to)
    local b = T.base(run.from)
    local gave = gatherItems(run)
    if o == nil then return gave, {}, "gone" end
    if run.from == "you" then
        -- your people at their gate: turned away if they won't trade with you; robbed if they hate you
        if fn(T, "embargoed") and T.embargoed(o.id, "you") then return {}, gave, "embargo" end
        if (tonumber(o.rep) or 50) <= 20 and T.roll(run.id .. "hostile") < 0.5 then
            T.putIn(o, gave)
            event(o, "Took everything your people brought to trade and sent them off", "trade")
            return gave, {}, "robbed"
        end
    end
    local sent = T.worthOfList(gave)
    T.putIn(o, gave)
    local got = {}
    if leg.want and sent > 0 then
        local giveKind = leg.give or T.mainKind(gave)
        local fair = sent * (type(ALifeWorth) == "table" and ALifeWorth.need(o, giveKind) or 1) / math.max(0.5, type(ALifeWorth) == "table" and b and ALifeWorth.need(b, leg.want) or 1)
        got = T.takeKind(o, leg.want, fair)
    end
    if run.from == "you" then
        if fn(M, "nbRep") then pcall(M.nbRep, o, 2, "Traded with your people") end
        if not o.knowsYou then o.knowsYou = h end
    end
    if b then
        if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, o, 3) end
        if b.knowsYou and not o.knowsYou then o.knowsYou = h; event(o, "Heard about your place from " .. tostring(b.name), "heard") end
        if o.knowsYou and not b.knowsYou then b.knowsYou = h; event(b, "Heard about your place from " .. tostring(o.name), "heard") end
        event(o, "Traders from " .. tostring(b.name) .. " brought " .. #gave .. " " .. (T.KIND_WORDS[leg.give] or "things") .. " for " .. #got .. " " .. (T.KIND_WORDS[leg.want] or "things"), "trade")
    end
    return gave, got, nil
end
function T.legDone(run, h)
    local leg = run.legs[run.leg]
    local alive = aliveCrew(run)
    if #alive == 0 then S.lost = S.lost + 1; return finishRun(run, "lost") end
    -- at your place and nobody there to hand it to (the post isn't loaded): they wait a while, packs untouched
    if run.state ~= "home" and leg and leg.to == "you" and not run.giveUp and fn(T, "postBox") and T.postBox() == nil then
        if run.state ~= "wait" then run.state, run.waitFrom, run.waitH = "wait", h, T.num("dealWaitH") end
        return
    end
    -- loaded right now: what's really in their packs
    for _, uid in ipairs(alive) do
        local sh = shellOf(uid)
        if sh and run.loaded[uid] then run.packs[uid] = T.packRead(run, uid, sh, true); run.loaded[uid] = false end
    end
    run.crew = alive
    if run.state == "home" then
        local b = T.base(run.from)
        local items = gatherItems(run)
        if run.from == "you" then
            if fn(T, "ownHome") then pcall(T.ownHome, run, items, h) end
        elseif b then T.putIn(b, items) end
        S.home = S.home + 1
        if run.withYouMs >= T.num("youEscortMin") * 60000 and b and fn(M, "nbRep") then
            S.escorted = S.escorted + 1
            pcall(M.nbRep, b, T.num("youEscortRep"), "You walked the road with their traders")
        end
        if b and #items > 0 then event(b, "Their traders came home with " .. #items .. " " .. (T.KIND_WORDS[T.mainKind(items)] or "things"), "trade") end
        return finishRun(run, "home")
    end
    local gave, got, why
    if leg.to == "you" then
        if fn(T, "tradeWithYou") then
            local ok, a, c, w = pcall(T.tradeWithYou, run, leg, h)
            if ok then gave, got, why = a, c, w else gave, got, why = {}, gatherItems(run), "error" end
            if why == "wait" then return end -- nobody there to hand it over to yet (TradeDeals waits a while)
        else gave, got = {}, gatherItems(run) end
    else
        gave, got, why = T.tradeAt(run, leg, h)
        if why == nil then
            local o = T.base(leg.to)
            if o then local r = T.route(run.from, o.id); r.safe = math.min(100, r.safe + T.num("routeSafeGain")); r.runs = r.runs + 1 end
        end
    end
    S.arrived = S.arrived + 1
    for _, f in ipairs(T.onLeg) do pcall(f, run, leg, gave or {}, got or {}, why) end
    run.items = got or {}
    T.splitPacks(run)
    run.leg = run.leg + 1
    run.robRolled = nil
    local x0, y0 = run.x1, run.y1
    local nextLeg = run.legs[run.leg]
    local tx, ty
    if nextLeg then tx, ty = T.placeXY(nextLeg.to); run.state = "out" end
    if tx == nil then tx, ty = T.placeXY(homeLegTo(run)); run.state = "home" end
    if tx == nil then
        -- home is gone: what they carry goes where they stand (nobody's), and they're on their own
        S.lost = S.lost + 1
        return finishRun(run, "homeless")
    end
    local b = T.base(run.from)
    local th = M.travelH(x0, y0, tx, ty, b)
    run.x0, run.y0, run.x1, run.y1, run.leave, run.arrive = x0, y0, tx, ty, h, h + th
    sendOn(run, h, tx, ty, run.arrive)
end
-- halfway: robbed off screen? (only when nobody of the crew is loaded: on screen, what happens happens)
function T.robRoll(run, h)
    if run.robRolled then return false end
    if h < run.leave + (run.arrive - run.leave) * 0.5 then return false end
    run.robRolled = true
    for _, uid in ipairs(run.crew) do if shellOf(uid) then return false end end
    local b = T.base(run.from)
    local leg = run.legs[run.leg]
    if run.from == "you" then
        local px, py = T.placeXY("you")
        if px then b = { id = "you", name = "your people", x = px, y = py, you = true } end
    end
    local o = T.base(leg and leg.to)
    if b == nil or o == nil or not fn(M, "cvRobber") then return false end
    T.curRun = run
    local okR, w = pcall(M.cvRobber, b, o, run.id .. ":" .. run.leg)
    T.curRun = nil
    if not okR or w == nil then return false end
    -- an escort fights: half the time they get away with half the goods
    local items = gatherItems(run)
    local kept = {}
    if (tonumber(run.escorts) or 0) > 0 and T.roll(run.id .. "esc") < 0.5 then
        for i, t in ipairs(items) do if i % 2 == 0 then kept[#kept + 1] = t end end
    end
    local lost = #items - #kept
    local wl = {}
    for i, t in ipairs(items) do if not (#kept > 0 and i % 2 == 0) then wl[#wl + 1] = t end end
    T.putIn(w, wl)
    run.items = kept
    T.splitPacks(run)
    S.robbed = S.robbed + 1
    if M.cvStats then M.cvStats.robbed = M.cvStats.robbed + 1 end
    if b.you then
        T.letter(run.owner and ALifeSide.byKey(run.owner) or nil, "Your traders were robbed on the road by " .. tostring(w.name) .. (#kept > 0 and ". The escort saved some of it." or "."), true)
        if fn(M, "nbRep") then pcall(M.nbRep, w, -5, nil) end
        local r = T.route("you", o.id); r.safe = math.max(0, r.safe - T.num("routeRobLoss")); r.robbed = r.robbed + 1; r.lastRob = h
    else
        event(b, "Their traders were robbed on the road by " .. tostring(w.name) .. (#kept > 0 and " (their escort saved some of it)" or ""), "trade")
        if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, w, -15) end
        pcall(M.trRouteRobbed, b, o, w)
    end
    event(w, "Robbed traders from " .. tostring(b.name) .. " (" .. lost .. " things)", "trade")
    -- robbed on the way there: nothing left to trade, they turn back
    if run.state ~= "home" and #kept == 0 then
        run.legs = { run.legs[run.leg] }
        run.state = "home"
        local tx, ty = T.placeXY(run.from)
        if tx then
            local b = T.base(run.from)
            local wx, wy = run.x0 + (run.x1 - run.x0) * 0.5, run.y0 + (run.y1 - run.y0) * 0.5
            local th = M.travelH(wx, wy, tx, ty, b)
            run.x0, run.y0, run.x1, run.y1, run.leave, run.arrive = wx, wy, tx, ty, h, h + th
            run.leg = #run.legs + 1
            sendOn(run, h, tx, ty, run.arrive)
        end
    end
    return true
end
-- one run, one pass
function T.runStep(run, h, t, dtMs)
    -- loaded crew: goods into their packs once; you near them counts as walking with them
    local anyLoaded = false
    for _, uid in ipairs(run.crew) do
        local sh = shellOf(uid)
        if sh then
            anyLoaded = true
            if not run.loaded[uid] then T.packOn(run, uid, sh); if not run.met then run.met = true; S.met = S.met + 1 end
            elseif t - (tonumber(run.packAt) or -1e12) >= 5000 then run.packs[uid] = T.packRead(run, uid, sh, false) end
            local p = ALifeSide.nearestTo(sh, 20)
            if p then run.withYouMs = (tonumber(run.withYouMs) or 0) + dtMs end
        elseif run.loaded[uid] then
            run.loaded[uid] = false -- gone dormant: their last look is what they carry
        end
    end
    if anyLoaded and t - (tonumber(run.packAt) or -1e12) >= 5000 then run.packAt = t end
    if #aliveCrew(run) == 0 then
        S.lost = S.lost + 1
        local b = T.base(run.from)
        if b then event(b, "Their traders never came back", "trade") end
        return finishRun(run, "lost")
    end
    if run.state == "wait" then
        if h - (tonumber(run.waitFrom) or h) > (tonumber(run.waitH) or 24) then run.giveUp = true end
        return T.legDone(run, h)
    end
    T.robRoll(run, h)
    if h >= run.arrive then
        -- someone on screen still walking: give them till they slip away (Leaving), at most a few hours late
        if anyLoaded and h < run.arrive + 3 then return end
        T.legDone(run, h)
    end
end

-- cvRun hands its swap here (M.cvRunWith)
M.trRunStart = function(b, best, give, want, h)
    if not T.on("tradeRuns") then return false end
    if #T.runsOf(b.id) > 0 then return true end -- one run out at a time: no swap today
    local run = T.startRun(b, { { to = best.id, give = give, want = want } }, h, { kind = "swap" })
    return run ~= nil
end

----------------------------------------------------------------------------------------------------------------
-- T6: middlemen (trader groups only): carry what's plentiful somewhere to where it's short
----------------------------------------------------------------------------------------------------------------
function T.brokerDay(b, h)
    if not T.on("brokers") or not T.on("tradeRuns") or b.trade ~= "traders" or b.airport or b.road then return end
    local day = math.floor(h / 24)
    if b.trBrokerDay == day then return end
    b.trBrokerDay = day
    local mine = 0
    for _, run in ipairs(T.runsOf(b.id)) do if run.kind == "broker" then mine = mine + 1 end end
    if mine >= T.num("brokerRuns") or #T.runsOf(b.id) > 0 then return end
    local range2 = T.num("brokerRange") ^ 2
    local near = {}
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and not o.airport and not o.road and tonumber(o.x) and d2(o.x, o.y, b.x, b.y) <= range2
                and (not fn(M, "dirTie") or M.dirTie(b, o) >= 0) and o.trade ~= "warband" and o.trade ~= "slavers"
                and not (fn(T, "embargoed") and T.embargoed(o.id, b.id)) then near[#near + 1] = o end
    end
    -- what the trader can pay with: its own most plentiful kind
    local pay, pr = nil, 0
    for _, k in ipairs(T.KINDS) do local r = T.ratio(b, k); if r > pr then pay, pr = k, r end end
    if pay == nil or pr < 1.2 then return end
    local best, bs
    for _, a in ipairs(near) do
        for _, c in ipairs(near) do
            if a.id ~= c.id then
                for _, k in ipairs(T.KINDS) do
                    if k ~= pay and T.ratio(a, k) >= 2 and T.need(c, k) >= 1.4 and T.need(a, pay) >= 1 then
                        local s = T.need(c, k) - math.sqrt(d2(a.x, a.y, b.x, b.y) + d2(c.x, c.y, a.x, a.y)) / 1000
                        if bs == nil or s > bs then
                            -- what c pays back with: its most plentiful kind
                            local back, brr = nil, 0
                            for _, w in ipairs(T.KINDS) do if w ~= k then local r = T.ratio(c, w); if r > brr then back, brr = w, r end end end
                            if back then best, bs = { a = a, c = c, k = k, back = back }, s end
                        end
                    end
                end
            end
        end
    end
    if best == nil then return end
    local run = T.startRun(b, { { to = best.a.id, give = pay, want = best.k }, { to = best.c.id, give = best.k, want = best.back } }, h, { kind = "broker" })
    if run then
        S.brokers = S.brokers + 1
        event(b, "Set out to buy " .. (T.KIND_WORDS[best.k] or best.k) .. " from " .. tostring(best.a.name) .. " for " .. tostring(best.c.name), "trade")
    end
end

----------------------------------------------------------------------------------------------------------------
-- the tick, the hooks
----------------------------------------------------------------------------------------------------------------
local lastMs, broken = -1e12, false
function T.runTick()
    local t = type(getTimestampMs) == "function" and getTimestampMs() or 0
    local dtMs = t - lastMs
    if dtMs < 1000 then return end
    if dtMs > 60000 then dtMs = 1000 end
    lastMs = t
    local list = {}
    for _, run in pairs(T.store().runs) do list[#list + 1] = run end
    if #list == 0 then return end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    local h = hours()
    for _, run in ipairs(list) do
        local ok, err = pcall(T.runStep, run, h, t, dtMs)
        if not ok then log("run " .. tostring(run.id) .. " failed: " .. tostring(err)); run.errors = (run.errors or 0) + 1; if run.errors > 5 then finishRun(run, "error") end end
    end
end
local function guarded()
    if broken then return end
    local ok, err = pcall(T.runTick)
    if not ok then broken = true; print(T.TAG .. " run tick failed, trade runs paused this session: " .. tostring(err)) end
end
function T.installRuns()
    M._alcpHooks = M._alcpHooks or {}
    if M._alcpHooks.tradeRuns then return true end
    if type(M.nbStep) ~= "function" then return false end
    M._alcpHooks.tradeRuns = true
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        if not broken and type(b) == "table" and b.status == "active" then
            local ok, err = pcall(T.brokerDay, b, h)
            if not ok then log("broker failed: " .. tostring(err)) end
            for _, f in ipairs(T.onBaseDay or {}) do pcall(f, b, h) end
        end
        return r
    end
    if fn(M, "nbEnded") then
        local ended = M.nbEnded
        M.nbEnded = function(b, reason, ...)
            if type(b) == "table" and (b.trade == "warband" or b.trade == "slavers") then pcall(T.routesCleared, b) end
            return ended(b, reason, ...)
        end
    end
    return true
end
T.onBaseDay = T.onBaseDay or {}
if not M._trRunHooked then
    M._trRunHooked = true
    if type(ALifeHealth) == "table" then ALifeHealth.tickAdd("ALifeTalk_TradeRuns", guarded) end
end
pcall(T.installRuns)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(T.installRuns)
        local n = 0
        for _ in pairs(T.store().runs) do n = n + 1 end
        print(T.TAG .. " ready v" .. T.VERSION .. ": trade runs " .. (T.on("tradeRuns") and "on" or "off") .. " (" .. n .. " on the road), middlemen " .. (T.on("brokers") and "on" or "off"))
    end)
end
function M.trPerf()
    return "trade runs: " .. S.runs .. " sent, " .. S.arrived .. " legs done, " .. S.home .. " home, robbed " .. S.robbed .. ", lost " .. S.lost
        .. ", met " .. S.met .. ", walked with " .. S.escorted .. ", escorts " .. S.escorts .. ", skipped " .. S.skipped .. ", middlemen " .. S.brokers
end
