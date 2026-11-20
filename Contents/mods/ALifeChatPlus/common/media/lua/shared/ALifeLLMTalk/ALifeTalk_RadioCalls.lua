-- A-Life NPC Overhaul 0.6.7: RADIO CALLS, HELP AND BOUNTIES.
--
-- RADIO. With a two-way radio that's on (a walkie-talkie in your inventory, or a ham radio within 2 tiles), right-click
-- (or the A-Life radial) > Radio. "Call out" reaches every group within your radio's real transmit range that keeps a
-- radio and doesn't hate you; they answer with who they are and roughly where. Groups you've raised you can call again:
--   * ask for traders: if they can spare people and goods, a caravan sets out for your base (0.6.6: real people, real
--     goods, real road time; they tell you roughly when to expect them)
--   * ask for help (groups that like you): 2-3 of their fighters set out for you, walking the real road time, join your
--     party when they arrive (they follow you and fight: defend your base or come along on a raid), and after a day
--     they go home. Real people: if they die, they're dead.
-- BOUNTIES. A group that hates you (and lives by fighting, or hates you badly enough) sends hunters: real members,
-- walking the real road time, who come at you from out of sight. Each wave is bigger than the last, up to what the
-- group can spare. Make peace (their standing above "wary") and it stops.
-- Sandbox: radio calls on/off, radio range %, share of groups with a radio, help on/off, bounties on/off.
-- Performance: menus only list groups when opened; trips are checked every ten minutes (a handful at most).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_RadioCalls") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "RadioCalls"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("RadioCalls") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("radiocalls: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "radio") end end
local function line(text) if fn(M, "radioLine") then pcall(M.radioLine, nil, text) else print(text) end end
local function fmt1(x) return ALifeFmtDec and ALifeFmtDec(x, 0) or tostring(math.floor(x + 0.5)) end

for k, v in pairs({ radioCalls = true, radioRangePct = 100, radioShare = 60, allyHelp = true, bounties = true }) do
    if M.settings[k] == nil then M.settings[k] = v end
end
M.rcCfg = { helpers = 3, keepHome = 2, helpH = 24, helpCooldownH = 72, hunters = 6, huntH = 12, waveGapH = { 72, 120 },
    placeFrom = 45, placeTo = 60, clear = 45, hateAt = 15, peaceAt = 30, warlikeHate = 15, anyHate = 5, defaultRange = 4000 }
M.rcStats = { calls = 0, answers = 0, traders = 0, helps = 0, hunts = 0, arrived = 0, home = 0 }

-- pre-1.0 MP (P5): radio calls are made by one player: helpers / hunters travel to THAT player (trip.pk), a bounty
-- hunts the camp's player (Main's M.homePlayer). The radio menu on an MP client: the groups in range come from the
-- server ("rcBases" view), the calls run there as the caller (exposed, by base id). SP: unchanged.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function mpClient() return type(ALifeSide) == "table" and ALifeSide.mpClient() end
local function playerOf()
    if mpServer() and ALifeSide.cur == nil and fn(M, "homePlayer") then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function pxy(p) local x, y = nil, nil; pcall(function() x, y = p:getX(), p:getY() end); return x, y end
local function keyOf(p)
    local k = nil
    pcall(function() k = PA().Speech.playerKey(p) end)
    return k
end
local function homeOf(id)
    local st = M.nbStore and M.nbStore() or nil
    local b, n = st and st.byId[id] or nil, 0
    while type(b) == "table" and b.status ~= "active" and b.movedTo and n < 5 do n = n + 1; b = st.byId[b.movedTo] end
    return type(b) == "table" and b.status == "active" and b or nil
end
local function store()
    local st = M.nbStore()
    st.rcTrips = type(st.rcTrips) == "table" and st.rcTrips or {}
    return st
end
M.rcStore = store

----------------------------------------------------------------------------------------------------------------
-- the radio in your hands (or on the table next to you)
----------------------------------------------------------------------------------------------------------------
local function deviceOk(dd)
    if dd == nil then return false end
    local twoWay, on, power = false, false, true
    pcall(function() twoWay = dd:getIsTwoWay() == true end)
    pcall(function() on = dd:getIsTurnedOn() == true end)
    pcall(function() if dd:getIsBatteryPowered() then power = (tonumber((dd:getPower())) or 0) > 0 end end)
    return twoWay and on and power
end
local function rangeOf(dd)
    local r = M.rcCfg.defaultRange
    pcall(function() local v = dd:getTransmitRange(); if type(v) == "number" and v > 0 then r = v end end)
    return r * math.max(0, tonumber(M.settings.radioRangePct) or 100) / 100
end
-- returns range (tiles) or nil, why
function M.rcRadio(player)
    if fn(M, "findRadio") then
        local item, ok = M.findRadio(player)
        if item and ok then local dd = nil; pcall(function() dd = item:getDeviceData() end); return rangeOf(dd) end
    end
    local best = nil
    pcall(function()
        local sq = player:getCurrentSquare()
        local cell = getCell()
        for dx = -2, 2 do for dy = -2, 2 do
            local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            local objs = s and s:getObjects()
            for i = 0, (objs and objs:size() or 0) - 1 do
                local o = objs:get(i)
                if instanceof(o, "IsoWaveSignal") then
                    local dd = o:getDeviceData()
                    if deviceOk(dd) then local r = rangeOf(dd); if best == nil or r > best then best = r end end
                end
            end
        end end
    end)
    if best then return best end
    return nil, "You need a two-way radio that's on (a walkie-talkie, or a ham radio next to you)"
end
-- does this group keep a radio (and listen)? fixed per group
function M.rcHasRadio(b)
    local share = tonumber(M.settings.radioShare) or 60
    share = share + (b.trade == "traders" and 20 or 0) + (b.stage == "fortified" and 15 or 0) + (b.outpostOf and 25 or 0)
    return (hash(tostring(b.id) .. "#radio") % 100) < share
end
function M.rcInRange(player, range)
    local x, y = pxy(player)
    local out = {}
    if x == nil then return out end
    for _, b in ipairs(M.nbActive and M.nbActive() or {}) do
        if not b.airport and not b.road and tonumber(b.x) and d2(b.x, b.y, x, y) <= range * range and M.rcHasRadio(b) then out[#out + 1] = b end
    end
    table.sort(out, function(a, c) return d2(a.x, a.y, x, y) < d2(c.x, c.y, x, y) end)
    return out
end
local DIRS = { "east", "southeast", "south", "southwest", "west", "northwest", "north", "northeast" }
local function where(px, py, b)
    local ang = math.atan2(b.y - py, b.x - px)
    local i = math.floor(((ang / (2 * math.pi)) * 8 + 0.5)) % 8
    local th = fn(M, "travelH") and M.travelH(px, py, b.x, b.y, b) or (math.sqrt(d2(px, py, b.x, b.y)) / 150)
    local walk = th < 1.5 and "less than two hours' walk" or (th < 24 and ("about " .. fmt1(th) .. " hours' walk") or ("about " .. fmt1(th / 10) .. " days' walk"))
    return DIRS[i + 1], walk
end

-- "Call out": everyone listening in range who doesn't hate you answers
function M.rcCallOut(player)
    local range, why = M.rcRadio(player)
    if range == nil then line("[Radio] " .. why); return 0 end
    M.rcStats.calls = M.rcStats.calls + 1
    line("[Radio] You call out on the open channels...")
    local px, py = pxy(player)
    local n = 0
    for _, b in ipairs(M.rcInRange(player, range)) do
        if (tonumber(b.rep) or 50) > 20 then
            n = n + 1
            local dir, walk = where(px, py, b)
            if not b.radioKnown then b.radioKnown = hours(); event(b, "Answered your call on the radio", "radio") end
            line("[Radio] " .. tostring(b.name) .. ": We hear you. We're " .. dir .. " of you, " .. walk .. ".")
            if fn(M, "jnLearn") then -- 0.6.9: what they said, and roughly where (from where you stood and what they told you)
                local rough = 0.15 * math.sqrt(d2(px, py, b.x, b.y))
                local jx = b.x + (((ALifeRoll01 and ALifeRoll01(b.id .. "#rx") or 0.5) - 0.5) * 2 * rough)
                local jy = b.y + (((ALifeRoll01 and ALifeRoll01(b.id .. "#ry") or 0.5) - 0.5) * 2 * rough)
                pcall(M.jnLearn, b, "radio", { x = jx, y = jy }, "On the radio: " .. dir .. " of where you were, " .. walk)
            end
            if fn(M, "chkTell") then pcall(M.chkTell, b, hours(), "radio") end -- 0.6.21: who holds the roads near them
            if fn(M, "wmTell") then pcall(M.wmTell, b, hours(), "radio") end -- 0.7.0: the wars they're in
        end
    end
    if n == 0 then line("[Radio] *kssht*... nobody answers.") end
    M.rcStats.answers = M.rcStats.answers + n
    return n
end

-- ask a group you've raised for traders
function M.rcAskTraders(player, b)
    local range, why = M.rcRadio(player)
    if range == nil then line("[Radio] " .. why); return false end
    local px, py = pxy(player)
    if d2(b.x, b.y, px, py) > range * range then line("[Radio] *kssht*... " .. tostring(b.name) .. " is out of range."); return false end
    local J = type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil
    local base = nil
    if fn(M, "jeemBaseHouse") then
        pcall(function()
            local house = M.jeemBaseHouse(player)
            local id = house and house.key and string.match(tostring(house.key), "^jeem:(.+)$")
            if id and J and J.BaseAreas and fn(J.BaseAreas, "base") then base = J.BaseAreas.base(id) end
        end)
    end
    if base == nil and fn(M, "ovBase") then base = M.ovBase(player) end -- 0.6.18: no Jeem base: your trading post / base
    if base == nil or not fn(M, "cvSetOut") or M.settings.caravans == false then
        line("[Radio] " .. tostring(b.name) .. ": Where would we even come to? Get yourself a place first.")
        return false
    end
    if fn(M, "cvTripFor") and M.cvTripFor(base.id, b.id) then line("[Radio] " .. tostring(b.name) .. ": Our people are already on the way to you."); return false end
    local why2 = M.cvSetOut(base, hours(), b.id)
    if why2 ~= "on_the_way" then
        local creed = type(b.dir) == "table" and b.dir.creed or nil
        local say = (tonumber(b.rep) or 50) < 40 and "We don't deal with you." or (creed == "closed" and "We keep to ourselves." or "Nothing to spare right now. Try us another time.")
        line("[Radio] " .. tostring(b.name) .. ": " .. say)
        return false
    end
    local trip = M.cvTripFor(base.id, b.id) or {}
    M.rcStats.traders = M.rcStats.traders + 1
    line("[Radio] " .. tostring(b.name) .. ": Alright. We'll send people with goods. Expect them in about " .. fmt1(math.max(1, (trip.at or hours()) - hours())) .. " hours.")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- trips: real people going somewhere for a while (help, hunters)
----------------------------------------------------------------------------------------------------------------
local function fighters(b, n)
    local scan = M.nbScan()
    local guards = M.cpRoleBg and M.cpRoleBg.guard or {}
    local list = {}
    for _, r in ipairs(scan.crews[b.id] or {}) do
        local m = type(r.memory) == "table" and r.memory or {}
        if r.lifecycle == "dormant" and not r.virtual and tostring(r.uid) ~= tostring(b.leader) and m.squadId == nil
                and m.jimmyTrader == nil and m.alcpCaravan == nil and m.alcpTrip == nil then
            local bg = nil
            pcall(function() local p = M.partsOf(tostring(r.uid)); bg = p and p.bg and (p.bg.key or p.bg.k) end)
            list[#list + 1] = { r = r, s = (guards[bg] or 0) + (hash(tostring(r.uid)) % 100) / 1000 }
        end
    end
    table.sort(list, function(a, c) return a.s > c.s end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i].r end
    return out
end
local function mark(uid, f)
    local reg = PA().ActorRegistry
    local r = fn(reg, "read") and reg.read(uid) or nil
    if r == nil then return false end
    local ok, res = pcall(reg.update, r.uid, r.revision, function(e) e.memory = type(e.memory) == "table" and e.memory or {}; f(e) end)
    return ok and res ~= false and res ~= nil
end
function M.rcSend(kind, b, n, player, h)
    local who = fighters(b, n)
    if #who == 0 then return nil end
    local px, py = pxy(player)
    local th = fn(M, "travelH") and M.travelH(b.x, b.y, px, py, b) or (math.sqrt(d2(b.x, b.y, px, py)) / 150)
    local uids = {}
    for _, r in ipairs(who) do
        local uid = tostring(r.uid)
        if mark(uid, function(e) e.memory.alcpTrip = { kind = kind, home = b.id } end) then uids[#uids + 1] = uid end
    end
    if #uids == 0 then return nil end
    local st = store()
    local trip = { kind = kind, home = b.id, uids = uids, leftH = h, at = h + th, key = keyOf(player), name = b.name,
        pk = mpServer() and player ~= nil and ALifeSide.keyOf(player) or nil }
    st.rcTrips[#st.rcTrips + 1] = trip
    return trip
end
function M.rcAskHelp(player, b)
    local range, why = M.rcRadio(player)
    if range == nil then line("[Radio] " .. why); return false end
    local px, py = pxy(player)
    if d2(b.x, b.y, px, py) > range * range then line("[Radio] *kssht*... " .. tostring(b.name) .. " is out of range."); return false end
    local h = hours()
    if M.settings.allyHelp == false then return false end
    if (tonumber(b.rep) or 50) < 75 then line("[Radio] " .. tostring(b.name) .. ": We don't know you well enough to bleed for you."); return false end
    if (tonumber(b.rcHelpH) or -1e9) > h - M.rcCfg.helpCooldownH then line("[Radio] " .. tostring(b.name) .. ": We just sent people. We can't spare more yet."); return false end
    local n = math.min(M.rcCfg.helpers, (tonumber(b.crewN) or 0) - M.rcCfg.keepHome)
    local trip = n >= 1 and M.rcSend("help", b, n, player, h) or nil
    if trip == nil then line("[Radio] " .. tostring(b.name) .. ": There's nobody we can send. Sorry."); return false end
    b.rcHelpH = h
    M.rcStats.helps = M.rcStats.helps + 1
    event(b, "Sent " .. #trip.uids .. " fighters to help you", "radio")
    line("[Radio] " .. tostring(b.name) .. ": Hold on. " .. #trip.uids .. " of ours are coming. About " .. fmt1(math.max(1, trip.at - h)) .. " hours.")
    return true
end

-- a spot out of sight on the side they come from: 45-60 tiles from you, outdoors, free
local function spotFor(px, py, hx, hy)
    local ang = math.atan2(hy - py, hx - px)
    local cell = nil
    pcall(function() cell = getCell() end)
    for _, da in ipairs({ 0, 0.3, -0.3, 0.6, -0.6, 1.0, -1.0 }) do
        for d = M.rcCfg.placeFrom, M.rcCfg.placeTo, 5 do
            local x, y = math.floor(px + math.cos(ang + da) * d), math.floor(py + math.sin(ang + da) * d)
            local ok = true
            if cell then
                local s = nil
                pcall(function() s = cell:getGridSquare(x, y, 0) end)
                if s then pcall(function() ok = s:isFree(false) and s:getRoom() == nil end) end
            end
            if ok then return x, y end
        end
    end
    return math.floor(px + math.cos(ang) * 50), math.floor(py + math.sin(ang) * 50)
end
local function arrive(trip, player, h)
    local px, py = pxy(player)
    local b = homeOf(trip.home)
    if px == nil or b == nil then return false end
    local x, y = spotFor(px, py, b.x, b.y)
    local placed = 0
    for i, uid in ipairs(trip.uids) do
        local reg = PA().ActorRegistry
        local r = reg.read(uid)
        if r and r.lifecycle == "dormant" then
            local okU = mark(uid, function(e)
                e.worldPosition = { x = x + (i % 3) - 1, y = y + math.floor(i / 3), z = 0 }
                if trip.kind == "hunt" and trip.key then
                    e.memory.hostileToPlayerKeys = type(e.memory.hostileToPlayerKeys) == "table" and e.memory.hostileToPlayerKeys or {}
                    e.memory.hostileToPlayerKeys[trip.key] = true
                end
            end)
            if okU then
                placed = placed + 1
                if trip.kind == "help" and fn(M, "partyJoin") then pcall(M.partyJoin, uid, player, "came to help (radio)") end
            end
        end
    end
    trip.placed, trip.untilH = true, h + (trip.kind == "help" and M.rcCfg.helpH or M.rcCfg.huntH)
    M.rcStats.arrived = M.rcStats.arrived + 1
    if trip.kind == "help" then line("[Radio] " .. tostring(trip.name) .. ": We're close. Coming to you now.") end
    if trip.kind == "help" and b and fn(M, "wmTell") then pcall(M.wmTell, b, h, "fighters") end -- 0.7.0
    if trip.kind == "help" and fn(M, "jnLearn") and b then -- 0.6.9: they talk about home
        local snap = M.jnSnapshot(b)
        pcall(M.jnLearn, b, "fighters", snap, "Their fighters said: " .. snap.members .. " at home, " .. tostring(snap.food) .. ", " .. tostring(snap.morale))
    end
    log(trip.kind .. " from " .. tostring(trip.name) .. ": " .. placed .. " placed at " .. x .. "," .. y)
    return placed > 0
end
-- going home: out of sight, then back at home once the walk is done; helpers leave your party first
local function goHome(trip, player, h)
    local px, py = pxy(player)
    local b = homeOf(trip.home)
    local reg, spawn = PA().ActorRegistry, PA().SpawnService
    if not trip.leaving then
        trip.leaving = true
        if trip.kind == "help" then
            for _, uid in ipairs(trip.uids) do if fn(M, "partyLeave") then pcall(M.partyLeave, uid, player, "went home", "We have to get back. Good luck.") end end
        end
        local th = (b and px and fn(M, "travelH")) and M.travelH(px, py, b.x, b.y, b) or 6
        trip.homeAt = h + th
        -- 0.6.17: they walk off down the road and travel home (not vanish where they stand)
        if b and fn(M, "lvSend") then
            for _, uid in ipairs(trip.uids) do pcall(M.lvSend, uid, { tx = b.x, ty = b.y, untilH = trip.homeAt, tag = "trip" }) end
        end
    end
    local left = 0
    for _, uid in ipairs(trip.uids) do
        local r = reg.read(uid)
        if r and r.lifecycle ~= "dead" and type(r.memory) == "table" and r.memory.alcpTrip then
            left = left + 1
            if r.lifecycle == "active" then
                local x, y = nil, nil
                pcall(function() local sh = PA().Talk.shellFor(uid); if sh then x, y = sh:getX(), sh:getY() end end)
                if x == nil and type(r.worldPosition) == "table" then x, y = r.worldPosition.x, r.worldPosition.y end
                local leaving = fn(M, "lvIsAway") and M.lvIsAway(uid)
                if not leaving and x and px and d2(x, y, px, py) >= M.rcCfg.clear ^ 2 and fn(spawn, "dehydrate") then pcall(spawn.dehydrate, uid, "alcp_trip") end
            elseif r.lifecycle == "dormant" and h >= (tonumber(trip.homeAt) or h) then
                local haven = b and M.nbHavenOf(b) or nil
                local depot = haven and type(haven.depot) == "table" and haven.depot or (b and { x = b.x, y = b.y, z = 0 }) or nil
                if mark(uid, function(e)
                    e.memory.alcpTrip = nil
                    if b then e.memory.havenId = b.id end
                    if depot then e.worldPosition = { x = depot.x + (hash(uid) % 3) - 1, y = depot.y + (hash(uid .. "y") % 3) - 1, z = depot.z or 0 } end
                end) then left = left - 1; M.rcStats.home = M.rcStats.home + 1 end
            end
        end
    end
    return left == 0
end
function M.rcTick()
    local st = store()
    if #st.rcTrips == 0 then return end
    local h, player = hours(), playerOf()
    local reg = PA().ActorRegistry
    for i = #st.rcTrips, 1, -1 do
        local trip = st.rcTrips[i]
        if mpServer() then player = (trip.pk and ALifeSide.byKey(trip.pk)) or playerOf() end -- MP: the player who called them
        local alive = 0
        for _, uid in ipairs(trip.uids or {}) do local r = reg.read(uid); if r and r.lifecycle ~= "dead" then alive = alive + 1 end end
        local done = false
        if alive == 0 then
            done = true
            local b = homeOf(trip.home)
            if b then event(b, trip.kind == "help" and "None of the fighters they sent to you came back" or "None of the hunters they sent after you came back", "radio") end
        elseif not trip.placed then
            if h >= (tonumber(trip.at) or 0) and player then arrive(trip, player, h) end
            if h - (tonumber(trip.at) or h) > 24 and not trip.placed then trip.untilH = h end -- couldn't find you: they give up
            if trip.untilH and not trip.placed then trip.placed = true end
        elseif h >= (tonumber(trip.untilH) or 0) then
            done = goHome(trip, player, h)
        end
        if done then table.remove(st.rcTrips, i) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- BOUNTIES
----------------------------------------------------------------------------------------------------------------
local function warlike(b)
    local creed = type(b.dir) == "table" and b.dir.creed or nil
    return b.trade == "warband" or b.trade == "slavers" or creed == "raiders"
end
-- standing changes: hate lights it, peace puts it out
function M.rcOnRep(b)
    if type(b) ~= "table" or b.status ~= "active" then return end
    local rep = tonumber(b.rep) or 50
    if rep >= M.rcCfg.peaceAt then
        if b.bounty then b.bounty = nil; event(b, "They've stopped hunting you", "bounty") end
        return
    end
    if b.bounty == nil and M.settings.bounties ~= false and (rep <= M.rcCfg.anyHate or (warlike(b) and rep <= M.rcCfg.warlikeHate)) then
        b.bounty = { waves = 0, nextH = hours() + 12 + (hash(b.id .. "#bounty") % 36) }
        event(b, "They want you dead", "bounty")
    end
end
function M.rcBountyDaily(b, h)
    if M.settings.bounties == false or type(b) ~= "table" or type(b.bounty) ~= "table" or b.road then return end
    if h < (tonumber(b.bounty.nextH) or 0) then return end
    for _, t in ipairs(store().rcTrips) do if t.home == b.id and t.kind == "hunt" then return end end
    local player = playerOf()
    if player == nil then return end
    local n = math.min(M.rcCfg.hunters, 1 + (tonumber(b.bounty.waves) or 0), (tonumber(b.crewN) or 0) - 1)
    if n < 1 then b.bounty.nextH = h + 24; return end
    local trip = M.rcSend("hunt", b, n, player, h)
    if trip == nil then b.bounty.nextH = h + 24; return end
    b.bounty.waves = (tonumber(b.bounty.waves) or 0) + 1
    local gap = M.rcCfg.waveGapH
    b.bounty.nextH = trip.at + gap[1] + (hash(b.id .. b.bounty.waves) % (gap[2] - gap[1] + 1))
    M.rcStats.hunts = M.rcStats.hunts + 1
    event(b, "Sent " .. #trip.uids .. " hunters after you", "bounty")
    log(tostring(b.name) .. " sent " .. #trip.uids .. " hunters (wave " .. b.bounty.waves .. "), " .. fmt1(trip.at - h) .. " h out")
end

----------------------------------------------------------------------------------------------------------------
-- the menu: right-click / A-Life radial > Radio
----------------------------------------------------------------------------------------------------------------
function M.rcFill(playerNum, context, worldobjects, test)
    if test == true or M.settings.radioCalls == false or not M.settings.enabled or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
    local player = getSpecificPlayer(playerNum or 0)
    if player == nil then return end
    local range = M.rcRadio(player)
    if range == nil then return end
    local opt = context:addOption(ALifeTr("IGUI_ALCP_Radio", "Radio"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(opt, sub)
    sub:addOption(ALifeTr("IGUI_ALCP_RadioCallOut", "Call out on the open channels"), player, function(p) M.rcCallOut(p) end)
    local inRange = nil
    if mpClient() and type(ALifeRemote) == "table" then -- MP: the groups in range, as the server sees them
        inRange = {}
        for _, row in ipairs(ALifeRemote.get("rcBases", player) or {}) do
            if type(row) == "table" and row.id ~= nil then inRange[#inRange + 1] = { id = row.id, name = row.name, radioKnown = row.known == true } end
        end
    end
    for _, b in ipairs(inRange or M.rcInRange(player, range)) do
        if b.radioKnown then
            local o2 = sub:addOption(tostring(b.name), nil, nil)
            local s2 = ISContextMenu:getNew(sub)
            sub:addSubMenu(o2, s2)
            s2:addOption(ALifeTr("IGUI_ALCP_RadioAskTraders", "Ask for traders"), player, function(p) M.rcAskId("traders", b.id, p) end)
            if M.settings.allyHelp ~= false then s2:addOption(ALifeTr("IGUI_ALCP_RadioAskHelp", "Ask for help"), player, function(p) M.rcAskId("help", b.id, p) end) end
        end
    end
end
function M.rcPerf()
    local s = M.rcStats
    return "radio: calls " .. s.calls .. ", answers " .. s.answers .. ", traders asked " .. s.traders .. ", help " .. s.helps
        .. ", hunts " .. s.hunts .. ", arrived " .. s.arrived .. ", went home " .. s.home .. ", trips now " .. #store().rcTrips
end

----------------------------------------------------------------------------------------------------------------
-- hooks (wrap, never replace; marked)
----------------------------------------------------------------------------------------------------------------
M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeRadioCalls] " .. where .. " failed, radio calls / bounties off for this session: " .. tostring(a)) end
    return ok and a or nil
end
function M.rcInstall()
    if M._alcpHooks.radioCalls or type(M.nbStep) ~= "function" or type(M.nbRep) ~= "function" then return false end
    M._alcpHooks.radioCalls = true
    local rep = M.nbRep
    M.nbRep = function(b, d, why, ...)
        local r = rep(b, d, why, ...)
        guard("standing", M.rcOnRep, b)
        return r
    end
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        if type(b) == "table" and b.status == "active" and b.bounty then guard("bounty", M.rcBountyDaily, b, h) end
        return r
    end
    if type(ALifeRadial) == "table" and fn(ALifeRadial, "addFiller") then
        ALifeRadial.addFiller("radio", "windows", function(...) guard("menu", M.rcFill, ...) end)
    end
    if type(Events) == "table" and Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_RadioCalls", function() guard("trips", M.rcTick) end) end
    print("[ALifeRadioCalls] loaded v0.6.7 (radio: traders, help from allies; bounties)")
    return true
end
-- pre-1.0 MP (P5): a call to one group by its id (SP: the same call; MP client: forwarded, run as the caller)
function M.rcAskId(what, id, player)
    player = player or ALifeSide.you()
    local b = fn(M, "nbOf") and M.nbOf(id) or nil
    if b == nil or player == nil then return false end
    if what == "help" then if M.settings.allyHelp == false then return false end; return M.rcAskHelp(player, b) end
    if what == "traders" then return M.rcAskTraders(player, b) end
    return false
end
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    ALifeRemote.expose("rcAskId", 2, 3)
    ALifeRemote.expose("rcCallOut", 0, 1)
    ALifeRemote.view("rcBases", function(player)
        local out = {}
        local range = player and M.rcRadio(player) or nil
        if range == nil then return out end
        for i, b in ipairs(M.rcInRange(player, range)) do
            if i > 20 then break end
            out[#out + 1] = { id = tostring(b.id), name = string.sub(tostring(b.name), 1, 80), known = b.radioKnown == true }
        end
        local ap = fn(M, "apStore") and M.apStore() or nil
        out.airport = type(ap) == "table" and ap.radioKnown == true or nil
        return out
    end, {})
end
if not M.rcInstall() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.rcInstall() end) end
