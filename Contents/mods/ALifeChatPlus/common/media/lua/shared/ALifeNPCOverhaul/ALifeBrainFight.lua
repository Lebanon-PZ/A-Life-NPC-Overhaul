-- A-Life NPC Overhaul pre-1.0: BRAIN 2, R1 REAL FIGHTS WHEN LOADED (docs/PLAN-BRAIN-2.md, spike notes there).
-- A war party that reaches a place with people around (you near it, or anyone of either side loaded) no longer turns
-- back: the fight happens for real, with A-Life's own combat. Small and human, not a battle (Joe, Nov 27):
--   1. stand-off: they stop short (a staging spot fightStageTiles out, on their way in) and someone shouts. A few
--      minutes (fightStandoffMin). At your place they make their demand first; only a refusal brings the fight.
--   2. assault: at most fightMaxSide of them go in (A-Life's own hold order walks them: DecisionLoop.setOrder via
--      ALifeTalkPatch.order); the rest hang back at the staging spot. Hostility is switched on pair by pair
--      (ALifeTalkPatch.setPairStance, the wrap of A-Life's Relations.status we already have), only between the people
--      in this fight. Against you (a raid on your camp) or with you (your war party, you walking with them) one more
--      wrap of Relations.hostileToPlayer turns exactly those people on you. Nobody else is dragged in.
--   3. a side breaks early: fightBreakPct of who went in down or hurt, its leader down, or the fight brain says break
--      (ALifeFightBrain moods). The attackers pull out after fightMaxMinutes anyway. Hostility off, orders released,
--      A-Life's own after-fight grudges between these two sides wiped (both systems agree), survivors walk home.
--   4. a raid that wins carries off real things (their stash; your trading post when it's you). Deaths are A-Life's.
--      Nobody loaded and you gone again: the old off-screen math settles it with the same people.
-- One fight at a time (fightsAtOnce). World side (server in MP); nothing new crosses the network but letters and talk.
-- Unverified on 42.21: A-Life names (Relations.status / hostileToPlayer, DecisionLoop.setOrder), MP.
require "ALifeNPCOverhaul/ALifeBrainWar"
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll
local TAG = "[ALifeBrainFight]"
local function T() return ALifeTrade end
local function P() return type(ALifeTalkPatch) == "table" and ALifeTalkPatch or nil end
local function FB() return type(ALifeFightBrain) == "table" and ALifeFightBrain or nil end

BR.defaults({
    fightsOnScreen = true,   -- war parties fight for real when people are around (off = they turn back, settled on paper)
    fightMaxSide = 4,        -- most attackers who go in at once; the rest hang back
    fightBreakPct = 34,      -- share of who went in down or hurt before a side breaks (percent)
    fightMaxMinutes = 15,    -- game minutes before the attackers pull out anyway
    fightStandoffMin = 3,    -- game minutes of shouting at the stand-off before they push in
    fightStageTiles = 25,    -- the stand-off spot, this far out from the place on their way in
    fightJoinPlayer = true,  -- your war party waits for you if you're nearby, and you fight with them
    fightsAtOnce = 1,        -- fights running at the same time
    fightHurtPct = 40,       -- health percent under which someone counts as out of the fight
    fightWithTiles = 80,     -- MP: a camp player this close to a place your war party hits is in the fight
})
BR.addRows({
    { "fightsOnScreen", "Brain fights: war parties fight for real when you're around (off = they turn back)" },
    { "fightMaxSide", "Brain fights: most attackers who go in at once (the rest hang back)", { 2, 3, 4, 6 } },
    { "fightBreakPct", "Brain fights: share of a side down or hurt before it breaks (percent)", { 25, 34, 50 } },
    { "fightMaxMinutes", "Brain fights: game minutes before attackers pull out anyway", { 10, 15, 30 } },
    { "fightStandoffMin", "Brain fights: game minutes of shouting before they push in", { 1, 3, 6 } },
    { "fightJoinPlayer", "Brain fights: your war party waits for you when you're nearby and you fight with them" },
    { "fightsAtOnce", "Brain fights: fights at the same time", { 1, 2 } },
    { "fightWithTiles", "Brain fights (MP): how close a camp player must be to a place your war party hits to be in the fight", { 40, 80, 150 } },
})
BR.fightStats = BR.fightStats or { begun = 0, assaults = 0, attBroke = 0, defBroke = 0, timeouts = 0, offscreen = 0, demands = 0, ticks = 0 }
local FS = BR.fightStats
local function log(m) BR.log("fight: " .. tostring(m)); print(TAG .. " " .. tostring(m)) end
local function nowMin() return hours() * 60 end
local function rec(uid) local r = nil; pcall(function() r = BR.PA().ActorRegistry.read(tostring(uid)) end); return r end
local function shell(uid) local s = nil; pcall(function() s = BR.PA().Talk.shellFor(tostring(uid)) end); return s end
local function placeName(id, run) if type(run) == "table" and run.fightDef then return "the road" end if id == "you" then return "your place" end local o = BR.base(id); return o and tostring(o.name) or "the place" end
BR.fightOnEnd = BR.fightOnEnd or {} -- f(run, b, h, won, how): road fights (ALifeBrainRoads) settle their loot here

----------------------------------------------------------------------------------------------------------------
-- who is in which fight (index rebuilt from the saved runs: plain tables, no closures)
----------------------------------------------------------------------------------------------------------------
BR.fightIdx = BR.fightIdx or {} -- uid -> { runId, side = "att" | "def" | "back" }
function BR.fights()
    local out = {}
    local t = T()
    if not fn(t, "store") then return out end
    for _, id in ipairs(BR.sortedKeys(t.store().runs)) do
        local run = t.store().runs[id]
        if type(run) == "table" and type(run.fight) == "table" and run.fight.phase ~= "over" then out[#out + 1] = run end
    end
    return out
end
function BR.fightReindex()
    local idx = {}
    for _, run in ipairs(BR.fights()) do
        local f = run.fight
        for _, u in ipairs(f.att or {}) do idx[u] = { runId = run.id, side = "att" } end
        for _, u in ipairs(f.back or {}) do idx[u] = { runId = run.id, side = "back" } end
        for _, u in ipairs(f.def or {}) do idx[u] = { runId = run.id, side = "def" } end
    end
    BR.fightIdx = idx
    return idx
end
function BR.fightSideOf(uid)
    local e = BR.fightIdx[tostring(uid)]
    if e == nil then return nil end
    local run = fn(T(), "store") and T().store().runs[e.runId] or nil
    if type(run) ~= "table" or type(run.fight) ~= "table" or run.fight.phase == "over" then BR.fightIdx[tostring(uid)] = nil; return nil end
    return e.side, run.fight, run
end

----------------------------------------------------------------------------------------------------------------
-- hostility: pair stances between the two sides only; the player only for fights against / with you
----------------------------------------------------------------------------------------------------------------
local function pairsOn(f, on)
    local p = P()
    if p == nil then return 0 end
    local n = 0
    local hrs = BR.num("fightMaxMinutes") / 60 + 0.25
    for _, a in ipairs(f.att or {}) do
        for _, b in ipairs(f.def or {}) do
            if on then if fn(p, "setPairStance") and p.setPairStance(a, b, "hostile", hrs, "brain fight", "hostile") then n = n + 1 end
            elseif fn(p, "clearPairStance") then p.clearPairStance(a, b, true); n = n + 1 end
        end
    end
    return n
end
-- one side walks away: its people stop being enemies of the other side now
local function sideOff(f, side)
    local p = P()
    if p == nil or not fn(p, "clearPairStance") then return end
    local mine = side == "att" and f.att or f.def
    local theirs = side == "att" and f.def or f.att
    for _, a in ipairs(mine or {}) do for _, b in ipairs(theirs or {}) do p.clearPairStance(a, b, true) end end
end
-- A-Life's own after-fight grudges between these two sides (Relations.writeGrudge: memory.hostileToActorKeys)
local function wipeGrudges(f)
    if f.defYou or f.withYou or not fn(BR, "memSet") then return 0 end
    local n = 0
    local function wipe(list, other)
        for _, u in ipairs(list or {}) do
            BR.memSet(u, function(m)
                if type(m.hostileToActorKeys) == "table" then for _, o in ipairs(other or {}) do if m.hostileToActorKeys[o] then m.hostileToActorKeys[o] = nil; n = n + 1 end end end
            end)
        end
    end
    local allAtt = {}
    for _, u in ipairs(f.att or {}) do allAtt[#allAtt + 1] = u end
    for _, u in ipairs(f.back or {}) do allAtt[#allAtt + 1] = u end
    wipe(allAtt, f.def); wipe(f.def, allAtt)
    return n
end
BR.fightWipeGrudges = wipeGrudges
-- the player: only people in a live assault against you (or the defenders of a place you hit with your war party)
-- MP: only the camp's players (co-op: online with a base, BR.isCampPlayer); the defenders of a place your war party
-- hits only turn on camp players who are there (fightWithTiles), never on a passer-by.
function BR.fightHostileToPlayer(actor, player)
    local uid = type(actor) == "table" and actor.uid or nil
    if uid == nil then return nil end
    local side, f = BR.fightSideOf(uid)
    if f == nil or f.phase ~= "assault" then return nil end
    if not BR.isCampPlayer(player) then return nil end
    if side == "att" and f.defYou and not f.attOut then return true end
    if side == "def" and f.withYou and not f.defOut then
        local px, py = nil, nil
        pcall(function() px, py = player:getX(), player:getY() end)
        local t = BR.num("fightWithTiles")
        if px and (px - f.x) ^ 2 + (py - f.y) ^ 2 <= t * t then return true end
    end
    return nil
end
function BR.fightInstallPlayerWrap()
    local Rel = BR.PA().Relations
    if type(Rel) ~= "table" or type(Rel.hostileToPlayer) ~= "function" then return false end
    if Rel._alcpBrainFight == Rel.hostileToPlayer then return true end
    local orig = Rel.hostileToPlayer
    local w = function(actor, player, ...)
        local ok, v = pcall(BR.fightHostileToPlayer, actor, player)
        if ok and v == true then return true end
        return orig(actor, player, ...)
    end
    Rel.hostileToPlayer = w
    Rel._alcpBrainFight = w
    return true
end

----------------------------------------------------------------------------------------------------------------
-- moving people: A-Life's own hold order (it paths, opens doors, keeps fighting rules)
----------------------------------------------------------------------------------------------------------------
local ORDER_TAG = "brainFight"
local function holdAt(uid, x, y, ms)
    local p = P()
    if p == nil or not fn(p, "order") or shell(uid) == nil then return false end
    local ok, res = pcall(p.order, uid, "hold", { x = math.floor(x) + (BR.hash(uid) % 3) - 1, y = math.floor(y) + (BR.hash(uid .. "y") % 3) - 1, z = 0 }, ms, ORDER_TAG)
    return ok and res == true
end
local function letGo(uid) local p = P(); if p and fn(p, "releaseOrder") then pcall(p.releaseOrder, uid, ORDER_TAG) end end
local function say(uid, line) if uid and line then K.say(uid, line) end end
local function anyShell(list) for _, u in ipairs(list or {}) do if shell(u) then return true end end return false end

-- out of the fight: dead, or hurt worse than fightHurtPct (a body that's loaded and still standing counts)
local function outOf(uid)
    local r = rec(uid)
    if r == nil or r.lifecycle == "dead" then return true, "dead" end
    local sh = shell(uid)
    if sh then
        local hp = nil
        pcall(function() hp = sh:getHealth() end)
        if tonumber(hp) and hp * 100 < BR.num("fightHurtPct") then return true, "hurt" end
        local down = false
        pcall(function() down = sh:isOnFloor() == true end)
        if down then return true, "down" end
    end
    return false
end
local function moodBroke(list)
    local fb = FB()
    if fb == nil or type(fb.groups) ~= "table" or not fn(fb, "groupIdOf") then return false end
    for _, u in ipairs(list or {}) do
        local gid = fb.groupIdOf(rec(u))
        local st = gid and fb.groups[gid] or nil
        if type(st) == "table" and (st.mood == "break" or st.mood == "giveup") then return true end
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- starting a fight
----------------------------------------------------------------------------------------------------------------
local function busy() return #BR.fights() >= math.max(1, BR.num("fightsAtOnce")) end
local function stage(run)
    local t = T()
    local hx, hy = run.x0, run.y0
    if fn(t, "placeXY") then local x, y = t.placeXY(run.from); if x then hx, hy = x, y end end
    if type(run.stageFrom) == "table" and tonumber(run.stageFrom.x) then hx, hy = run.stageFrom.x, run.stageFrom.y end -- they learned which side you don't watch (R4)
    local dx, dy = (hx or run.x1) - run.x1, (hy or run.y1) - run.y1
    local len = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local tiles = math.min(BR.num("fightStageTiles"), len * 0.5)
    return run.x1 + dx / len * tiles, run.y1 + dy / len * tiles
end
local function defendersOf(target)
    if target == "you" then
        local out = {}
        if fn(BR, "youPeopleOf") then
            local ok, list = pcall(BR.youPeopleOf, BR.youRec())
            for _, p in ipairs(ok and list or {}) do if not p.away then out[#out + 1] = p.uid end end
        end
        -- friends who came to stand with you (R6 help parties staying at your place) fight too
        local t = T()
        for _, r in pairs(fn(t, "store") and t.store().runs or {}) do
            if type(r) == "table" and r.kind == "help" and r.target == "you" and r.state == "siege" then for _, u in ipairs(r.crew or {}) do out[#out + 1] = u end end
        end
        return out
    end
    local o = BR.base(target)
    if o == nil or not fn(BR, "homeCrew") then return {} end
    return BR.homeCrew(o)
end
function BR.playerNearXY(x, y, tiles)
    local ok, res = pcall(function()
        local list = {}
        if ALifeSide.mpServer() then list = ALifeSide.online() else local p = ALifeSide.you(); if p then list = { p } end end
        for _, p in ipairs(list) do if p and (p:getX() - x) ^ 2 + (p:getY() - y) ^ 2 < tiles * tiles then return true end end
        return false
    end)
    return ok and res == true
end
-- does this arrival become a real fight?
function BR.fightWanted(run, b, h)
    if not BR.flag("fightsOnScreen") or type(run) ~= "table" or run.kind ~= "war" or run.fight ~= nil then return false end
    if run.state == "siege" then return false end
    local seen = (fn(BR, "playersNear") and BR.playersNear(run.x1, run.y1)) or anyShell(run.crew) or anyShell(defendersOf(run.target))
    if not seen then return false end
    return true
end
function BR.fightBegin(run, b, h)
    local live = fn(BR, "runAlive") and BR.runAlive(run) or run.crew
    run.crew = live
    if #live == 0 then return false end
    local target = run.target
    local o = target ~= "you" and BR.base(target) or nil
    if target ~= "you" and o == nil and not run.fightDef then return false end
    if run.fightDef then o = nil end -- a fight on the road (an ambush): the defenders are the people walking by
    local order = {}
    for _, u in ipairs(live) do order[#order + 1] = u end
    -- whoever leads the party goes in first (the first of the crew), then the rest by a stable shuffle
    local lead = order[1]
    table.sort(order, function(a, c) if a == lead then return true elseif c == lead then return false end return BR.hash(a .. run.id) < BR.hash(c .. run.id) end)
    local maxIn = math.max(1, math.floor(BR.num("fightMaxSide")))
    local att, back = {}, {}
    for i, u in ipairs(order) do if i <= maxIn then att[#att + 1] = u else back[#back + 1] = u end end
    local def = run.fightDef or defendersOf(target)
    local sx, sy = stage(run)
    if run.fightDef then sx, sy = run.x1, run.y1 end -- they're already in cover by the road
    local f = { phase = "standoff", startMin = nowMin(), att = att, back = back, def = def, lead = lead, x = run.x1, y = run.y1, sx = sx, sy = sy,
        defYou = target == "you" or nil, withYou = (run.from == "you" and BR.flag("fightJoinPlayer") and BR.campPlayerNear(run.x1, run.y1, 60) ~= nil) or nil,
        nAtt = #att, nDef = #def, h = h }
    run.fight = f
    run.state = "assault"
    run.stay = BR.num("fightMaxMinutes") / 60 + BR.num("fightStandoffMin") / 60 + 1 -- the run engine waits; the fight tick ends it sooner
    FS.begun = FS.begun + 1
    BR.fightReindex()
    pcall(BR.fightInstallPlayerWrap)
    -- off the road: Leaving lets go of them (it would walk a loaded one away), the fight's orders take over
    for _, u in ipairs(live) do
        if fn(M, "lvCancel") then pcall(M.lvCancel, u) end
        local p = P()
        if p and fn(p, "owner") and p.owner(u) == "leave" and fn(p, "release") then pcall(p.release, u, "brain fight") end
    end
    for _, u in ipairs(att) do holdAt(u, sx, sy, 120000) end
    for _, u in ipairs(back) do holdAt(u, sx, sy, 600000) end
    local who = tostring(b.name)
    if f.defYou then
        say(lead, ({ "That's close enough! Nobody does anything stupid.", "We said pay up. You didn't.", "Last chance. Hand it over." })[(BR.hash(run.id) % 3) + 1])
        BR.campLetter("Armed people from " .. who .. " are at your gate, and they're not here to talk.", true)
    elseif run.from == "you" then
        if fn(BR, "youReport") then BR.youReport("Our people are outside " .. placeName(target, run) .. (f.withYou and ", waiting on you" or ""), "war") end
    else
        say(lead, ({ "Spread out. Nobody shoots till I say.", "Easy. Let them see us first.", "Wait for it." })[(BR.hash(run.id) % 3) + 1])
        do
            BR.nearLetter(run.x1, run.y1, 150, run.fightDef and ("People from " .. who .. " jumped some travellers on the road near you.") or ("Armed people from " .. who .. " are gathering outside " .. placeName(target, run) .. "."), true)
        end
    end
    BR.event(b, "Got to " .. placeName(target, run) .. " and squared up to them", "war")
    if o then BR.event(o, who .. "'s fighters showed up outside", "war") end
    log(who .. " -> " .. tostring(target) .. ": " .. #att .. " in, " .. #back .. " back, " .. #def .. " defending" .. (f.defYou and " (you)" or "") .. (f.withYou and " (with you)" or ""))
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the fight, minute by minute
----------------------------------------------------------------------------------------------------------------
local function lostOf(list)
    local n, dead = 0, {}
    for _, u in ipairs(list or {}) do
        local out, why = outOf(u)
        if out then n = n + 1; if why == "dead" then dead[#dead + 1] = u end end
    end
    return n, dead
end
local function need(n) return math.max(1, math.ceil(n * BR.num("fightBreakPct") / 100)) end
-- settle it off screen (everyone unloaded and you gone): the old math with the same people
local function offscreen(run, b, h, fromEngine)
    FS.offscreen = FS.offscreen + 1
    local f = run.fight
    pairsOn(f, false)
    for _, u in ipairs(f.att or {}) do letGo(u) end
    for _, u in ipairs(f.back or {}) do letGo(u) end
    f.phase = "over"
    BR.fightReindex()
    run.fight = nil
    run.state = "out"
    run.stay = nil
    run.waited = true
    run.offscreenFight = true
    local orig = BR.fightOrigArrive
    if orig then pcall(orig, run, b, h) end
    run.fight = { phase = "over" }
    local o = BR.base(run.target)
    if b.isCamp and o and run.won ~= nil and not run.repHit and fn(M, "nbRep") then run.repHit = true; pcall(M.nbRep, o, -20, "Your people attacked them") end
    if fromEngine then return end -- the run engine (runArrive) goes on from here: a stay, or home
    if fn(BR, "runAlive") and #BR.runAlive(run) == 0 then return BR.partyLost(run, h) end
    if run.stay then run.leave, run.arrive = h, h + run.stay; run.stay = nil; return end
    BR.turnHome(run, h, run.x1, run.y1)
end
function BR.fightEnd(run, b, h, how)
    local f = run.fight
    if type(f) ~= "table" or f.phase == "over" then return end
    local o = (run.target ~= "you" and not run.fightDef) and BR.base(run.target) or nil
    local lostA, deadA = lostOf(f.att)
    local lostD, deadD = lostOf(f.def)
    pairsOn(f, false)
    wipeGrudges(f)
    for _, u in ipairs(f.att or {}) do letGo(u) end
    for _, u in ipairs(f.back or {}) do letGo(u) end
    f.phase, f.how, f.endMin = "over", how, nowMin()
    BR.fightReindex()
    if fn(BR, "dropCrew") and #deadA > 0 then BR.dropCrew(run, deadA) end
    local won = how == "defBroke"
    local who = tostring(b.name)
    -- what a win carries off: their real stash, or your trading post
    local got = 0
    if won then
        if o and fn(BR, "warLoot") then got = BR.warLoot(run, o, #run.crew * 4, false)
        elseif run.target == "you" and fn(T(), "postTake") then
            for _, kind in ipairs({ "food", "ammo", "meds" }) do
                local items = T().postTake(kind, #run.crew * 2) or {}
                for _, it in ipairs(items) do run.items[#run.items + 1] = it end
                got = got + #items
            end
            run.lootN = (tonumber(run.lootN) or 0) + got
            if fn(T(), "splitPacks") then T().splitPacks(run) end
        end
    end
    if o and fn(BR, "warWin") then BR.warWin(b, o, run, h, won) else run.won = won end
    for _, cbk in ipairs(BR.fightOnEnd) do pcall(cbk, run, b, h, won, how) end
    if b.isCamp and o and not run.repHit and fn(M, "nbRep") then run.repHit = true; pcall(M.nbRep, o, -20, "Your people attacked them") end
    if run.target == "you" and fn(BR, "grudge") and fn(BR, "youRec") then BR.grudge(BR.youRec(), b.id, won and 40 or 20, won and "raided our place" or "attacked our place") end
    -- words
    local dA, dD = #deadA, #deadD
    if won then
        say(f.lead, ({ "Grab what you can and go!", "That's it, move!", "Get it and get out!" })[(BR.hash(run.id .. "w") % 3) + 1])
        BR.event(b, "Fought their way into " .. placeName(run.target, run) .. (got > 0 and (" and came away with " .. got .. " things") or "") .. (dA > 0 and (" - " .. dA .. " of theirs dead") or ""), "war")
        if o then BR.event(o, who .. " fought their way in" .. (dD > 0 and (" - " .. dD .. " dead") or ""), "raided") end
        if run.target == "you" then BR.campLetter(who .. "'s people broke through" .. (got > 0 and (" and took " .. got .. " things from your trading post") or "") .. ".", true) end
    else
        say(f.lead, how == "timeout" and "Enough! Pull back!" or ({ "Fall back! Fall back!", "Get out of here!", "Back, back!" })[(BR.hash(run.id .. "l") % 3) + 1])
        BR.event(b, (how == "timeout" and "Couldn't get into " or "Were driven off from ") .. placeName(run.target, run) .. (dA > 0 and (" - " .. dA .. " didn't make it") or ""), "war")
        if o then BR.event(o, "Drove off " .. who .. "'s fighters" .. (dD > 0 and (", but lost " .. dD) or ""), "defended") end
        if run.target == "you" then BR.campLetter(who .. "'s people pulled back.", false) end
    end
    if o and fn(BR, "grudge") then BR.grudge(o, b.id, 20 + dD * 10, "attacked them") end
    if dD > 0 and fn(BR, "interrupt") and o then BR.interrupt(o, "lost") end
    -- everyone walks home from the staging spot (hostility already off)
    if fn(BR, "runAlive") and #BR.runAlive(run) == 0 then return BR.partyLost(run, h) end
    BR.turnHome(run, h, f.sx or run.x1, f.sy or run.y1)
    log(who .. " vs " .. tostring(run.target) .. " over (" .. tostring(how) .. "): lost " .. lostA .. "/" .. f.nAtt .. " in, they lost " .. lostD .. "/" .. f.nDef)
end
function BR.fightStep(run, h)
    local f = run.fight
    if type(f) ~= "table" or f.phase == "over" then return end
    local b = BR.home(run.from)
    if b == nil then f.phase = "over"; pairsOn(f, false); BR.fightReindex(); return end
    local m = nowMin()
    local elapsed = m - (tonumber(f.startMin) or m)
    local seen = (fn(BR, "playersNear") and BR.playersNear(f.x, f.y)) or anyShell(f.att) or anyShell(f.def)
    if not seen then
        f.unseen = (tonumber(f.unseen) or 0) + 1
        if f.unseen >= 3 then return offscreen(run, b, h) end
        return
    end
    f.unseen = 0
    if f.phase == "standoff" then
        if elapsed < BR.num("fightStandoffMin") and not run.fightDef then return end -- an ambush springs at once
        if not anyShell(f.att) then
            if elapsed > BR.num("fightMaxMinutes") then return offscreen(run, b, h) end
            return -- not here yet
        end
        f.phase = "assault"
        f.assaultMin = m
        FS.assaults = FS.assaults + 1
        pairsOn(f, true)
        for _, u in ipairs(f.att) do holdAt(u, f.x, f.y, BR.num("fightMaxMinutes") * 60000) end
        say(f.lead, ({ "Go! Go!", "Now! Move in!", "Take them!" })[(BR.hash(run.id .. "g") % 3) + 1])
        if not f.defYou and not f.withYou then
            BR.nearLetter(f.x, f.y, 150, "Shooting near " .. placeName(run.target, run) .. ": " .. tostring(b.name) .. "'s people are attacking. Not your fight, unless you make it one.", true)
        end
        return
    end
    -- assault: who's had enough?
    local lostA = lostOf(f.att)
    local lostD = lostOf(f.def)
    local leadOut = f.lead and outOf(f.lead)
    local defLoaded = anyShell(f.def)
    if lostA >= need(f.nAtt) or leadOut or moodBroke(f.att) then FS.attBroke = FS.attBroke + 1; return BR.fightEnd(run, b, h, "attBroke") end
    if f.nDef > 0 and (lostD >= need(f.nDef) or moodBroke(f.def)) then FS.defBroke = FS.defBroke + 1; return BR.fightEnd(run, b, h, "defBroke") end
    -- nobody home to stop them (or nobody came out): after a few minutes the place is theirs
    if not defLoaded and not f.defYou and m - (tonumber(f.assaultMin) or m) >= 4 then FS.defBroke = FS.defBroke + 1; return BR.fightEnd(run, b, h, "defBroke") end
    if m - (tonumber(f.assaultMin) or m) >= BR.num("fightMaxMinutes") then FS.timeouts = FS.timeouts + 1; return BR.fightEnd(run, b, h, "timeout") end
end
function BR.fightTick()
    if not BR.on() then return end
    FS.ticks = FS.ticks + 1
    local h = hours()
    for _, run in ipairs(BR.fights()) do
        local ok, err = pcall(BR.fightStep, run, h)
        if not ok then log("step failed: " .. tostring(err)) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the hook: a war party's arrival (wraps BR.warArrive; NPC and camp runs alike)
----------------------------------------------------------------------------------------------------------------
local function install()
    return K.wrap(BR, "warArrive", "BrainFightArrive", function(orig)
        BR.fightOrigArrive = orig
        return function(run, b, h, ...)
            if type(run) == "table" and type(run.fight) == "table" then
                if run.fight.phase ~= "over" then
                    -- the engine came back before the fight ended (no ticks while unloaded): settle it now
                    offscreen(run, b, h, true)
                    return
                end
                return orig(run, b, h, ...)
            end
            if type(run) == "table" and run.kind == "war" and run.target == "you" and BR.flag("fightsOnScreen") and BR.fightWanted(run, b, h) then
                -- at your gate: the demand first; only a refusal (or bad blood) brings the fight
                local s = BR.of(b)
                local ans = type(s.answers) == "table" and s.answers.you or nil
                if ans == "paid" then BR.event(b, "Got what they came for at your place and left", "brain"); return end
                if ans ~= "refused" and BR.grudgeV(b, "you", h) < 50 and not run.demanded then
                    run.demanded = true
                    FS.demands = FS.demands + 1
                    BR.tributeToYou(b, h)
                    BR.campLetter("Armed people from " .. tostring(b.name) .. " are outside your place, waiting on your answer.", true)
                    run.stay = 6
                    return
                end
                if busy() then run.stay = 1; return end
                if BR.fightBegin(run, b, h) then return end
                return orig(run, b, h, ...)
            end
            -- your war party waits for you if you're on your way (fightJoinPlayer)
            if type(run) == "table" and run.kind == "war" and run.from == "you" and run.fight == nil and BR.flag("fightsOnScreen") and BR.flag("fightJoinPlayer")
                    and not run.waitedYou and BR.campPlayerNear(run.x1, run.y1, 60) == nil and BR.campPlayerNear(run.x1, run.y1, 300) ~= nil then
                run.waitedYou = true
                run.stay = 2
                if fn(BR, "youReport") then BR.youReport("Our people are waiting outside " .. placeName(run.target, run) .. " for you", "war") end
                return
            end
            if BR.fightWanted(run, b, h) then
                if busy() then if not run.waitedBusy then run.waitedBusy = true; run.stay = 1; return end; return orig(run, b, h, ...) end
                if BR.fightBegin(run, b, h) then return end
            end
            return orig(run, b, h, ...)
        end
    end)
end
BR.installers[#BR.installers + 1] = install
pcall(install)
do
    local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrainFight")
    if type(Events) == "table" and Events.EveryOneMinute and type(ALifeHealth) == "table" then ALifeHealth.add(Events.EveryOneMinute, "ALifeBrainFight", BR.fightTick) end
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            BR.fightReindex()
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": real fights " .. (BR.flag("fightsOnScreen") and "on" or "off") .. " (" .. math.floor(BR.num("fightMaxSide"))
                .. " a side, break at " .. math.floor(BR.num("fightBreakPct")) .. " pct, " .. #BR.fights() .. " going on)")
        end)
    end
end
