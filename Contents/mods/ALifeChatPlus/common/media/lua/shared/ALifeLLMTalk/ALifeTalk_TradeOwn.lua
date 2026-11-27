-- A-Life NPC Overhaul pre-1.0: TRADE, PART 4. YOUR OWN CARAVANS (docs/PLAN-TRADE.md T2).
--  * send your people to trade at a group you know: pick the group, what to take (a kind of goods out of your trading
--    post) and what to bring back. The goods come out of the post for real; your people walk the real road (on a
--    trade run, ALifeTalk_TradeRuns), trade at the other end by what each side lacks, and walk home.
--  * who goes: settlers at home. Each one may say no: low loyalty (A-Life opinion, temperament), scared, hurt.
--  * what comes back lands in the trading post (or waits at the gate until the post is loaded).
--  * on the road they can be robbed like anyone; a group that won't trade with you turns them away; a group that hates
--    you may take everything.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_TradeOwn")
require "ALifeLLMTalk/ALifeTalk_TradeRuns"
local M = ALifeLLMTalk
local T = ALifeTrade
if type(M) ~= "table" or type(T) ~= "table" then return end
local fn, d2, hours, log, event = T.fn, T.d2, T.hours, T.log, T.event

T.defaults({ ownRuns = true, ownRunCrew = 2, ownRunWorth = 40, ownRefuseHurt = 60, ownRefuseFear = 60, ownRunRange = 2000 })
T.addRows({
    { "ownRuns", "Your caravans: send your settlers with goods from the trading post to trade at other groups" },
    { "ownRunCrew", "Your caravans: people you send", { 1, 2, 3 } },
    { "ownRunWorth", "Your caravans: most they carry (worth)", { 20, 40, 80 } },
    { "ownRunRange", "Your caravans: farthest group they'll walk to (tiles)", { 1000, 2000, 4000 } },
})
M.trOwnStats = M.trOwnStats or { sent = 0, refused = 0, home = 0, landed = 0 }
local S = M.trOwnStats

----------------------------------------------------------------------------------------------------------------
-- the trading post container (real items; only while its square is loaded)
----------------------------------------------------------------------------------------------------------------
function T.postBox()
    local post = fn(M, "tpStore") and M.tpStore().post or nil
    if type(post) ~= "table" then return nil, "no_post" end
    local box = nil
    pcall(function()
        local sq = getCell():getGridSquare(post.x, post.y, post.z or 0)
        if sq == nil then return end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local c = nil; pcall(function() c = objs:get(i):getContainer() end)
            if c then box = c; return end
        end
    end)
    if box == nil then return nil, "not_loaded" end
    return box
end
-- what's in the post, by kind (counts of real items)
function T.postKinds()
    local box = T.postBox()
    local out = {}
    if box == nil then return out, false end
    pcall(function()
        local l = box:getItems()
        for i = 0, l:size() - 1 do
            local k = fn(M, "nbKindOf") and M.nbKindOf(l:get(i):getFullType()) or "other"
            out[k] = (out[k] or 0) + 1
        end
    end)
    return out, true
end
function T.postTake(kind, cap)
    local box = T.postBox()
    if box == nil then return {}, 0 end
    local out, got = {}, 0
    pcall(function()
        local l = box:getItems()
        local pick = {}
        for i = 0, l:size() - 1 do
            local it = l:get(i)
            local t = it:getFullType()
            if (fn(M, "nbKindOf") and M.nbKindOf(t) or "other") == kind then pick[#pick + 1] = { it = it, t = t, v = type(ALifeWorth) == "table" and ALifeWorth.item(it) or 1 } end
        end
        table.sort(pick, function(a, c) return a.v > c.v end)
        for _, e in ipairs(pick) do
            if got >= cap then break end
            if got + e.v <= cap * 1.25 or #out == 0 then box:Remove(e.it); out[#out + 1] = e.t; got = got + e.v end
        end
    end)
    return out, got
end
function T.postPut(items)
    local box = T.postBox()
    if box == nil then return false end
    pcall(function() for _, t in ipairs(items) do box:AddItem(t) end end)
    return true
end

----------------------------------------------------------------------------------------------------------------
-- who'll go
----------------------------------------------------------------------------------------------------------------
local function healthOf(uid)
    local hp = nil
    pcall(function() local sh = T.PA().Talk.shellFor(uid); if sh then hp = sh:getHealth() * 100 end end) -- loaded: the real body (0..1)
    if hp == nil then pcall(function() local r = T.PA().ActorRegistry.read(uid); hp = tonumber(r and r.health) end) end -- unverified field: guarded
    return tonumber(hp) or 100
end
local function nameOf(uid)
    if type(ALifeCampKit) == "table" and fn(ALifeCampKit, "first") then local ok, n = pcall(ALifeCampKit.first, uid); if ok and n then return n end end
    return "Someone"
end
-- { uid, name, why } for everyone at home: why = nil if they'd go
function T.ownCandidates(player)
    local out = {}
    local people = fn(M, "cpPeople") and select(2, pcall(M.cpPeople, player)) or {}
    for _, row in ipairs(type(people) == "table" and people or {}) do
        local uid = tostring(type(row) == "table" and (row.uid or row.id) or row)
        local home = not fn(M, "cpIsHome") or select(2, pcall(M.cpIsHome, uid, player)) == true
        if home and not T.crewBusy(uid) and not (fn(M, "lvIsAway") and M.lvIsAway(uid)) then
            local why = nil
            local hp = healthOf(uid)
            local fear = 0
            if fn(M, "emoBehavior") then local ok, b = pcall(M.emoBehavior, uid); if ok and type(b) == "table" then fear = (tonumber(b.fear) or 0) * 100 end end
            local obey = fn(M, "obeyChance") and select(2, pcall(M.obeyChance, uid, "player", "trade")) or 60
            if hp < T.num("ownRefuseHurt") then why = "hurt"
            elseif fear >= T.num("ownRefuseFear") then why = "scared"
            elseif T.roll(uid .. ":own:" .. math.floor(hours() / 6)) * 100 >= (tonumber(obey) or 60) then why = "won't" end
            out[#out + 1] = { uid = uid, name = nameOf(uid), why = why, obey = tonumber(obey) or 60 }
        end
    end
    table.sort(out, function(a, c) if (a.why == nil) ~= (c.why == nil) then return a.why == nil end return a.obey > c.obey end)
    return out
end
T.REFUSE = { hurt = "%1 is too hurt to walk that far.", scared = "%1 is too scared to go out there.", ["won't"] = "%1 won't go. Not for you, not now." }

-- groups your people could go to: known, in range, not at war with you
function T.ownTargets(player)
    local px, py = T.placeXY("you")
    local out = {}
    if px == nil then return out end
    local range2 = T.num("ownRunRange") ^ 2
    for _, b in ipairs(M.nbActive()) do
        if b.knowsYou and not b.airport and not b.road and tonumber(b.x) and d2(b.x, b.y, px, py) <= range2 then
            out[#out + 1] = { id = b.id, name = b.name, embargo = T.embargoed and T.embargoed(b.id, "you") or false,
                safe = T.routeSafe("you", b.id), hours = M.travelH(px, py, b.x, b.y, nil) }
        end
    end
    table.sort(out, function(a, c) return a.hours < c.hours end)
    return out
end

-- send them. Returns ok, message
function T.ownSend(player, groupId, give, want)
    if not T.on("ownRuns") or not T.on("tradeRuns") then return false, "Your caravans are off in settings." end
    local o = T.base(groupId)
    if o == nil then return false, "That group is gone." end
    if not o.knowsYou then return false, "Your people don't know the way there." end
    local box, why = T.postBox()
    if box == nil then return false, why == "no_post" and "You need a trading post to send goods from." or "Be at your trading post to pack the goods." end
    local cands = T.ownCandidates(player)
    local crew, said = {}, {}
    for _, c in ipairs(cands) do
        if #crew >= T.num("ownRunCrew") then break end
        if c.why == nil then crew[#crew + 1] = c.uid
        else said[#said + 1] = string.gsub(T.REFUSE[c.why] or "%1 won't go.", "%%1", c.name); S.refused = S.refused + 1 end
    end
    if #crew == 0 then return false, (#said > 0 and table.concat(said, " ") or "Nobody at home to send.") end
    local items = T.postTake(give, T.num("ownRunWorth"))
    if #items == 0 then return false, "There's no " .. (T.KIND_WORDS[give] or give) .. " in the trading post." end
    local fx, fy = T.placeXY("you")
    local tx, ty = T.placeXY(o.id)
    local h = hours()
    local th = M.travelH(fx, fy, tx, ty, nil)
    local run = { id = T.newId("run"), from = "you", fromName = "your people", kind = "own", owner = player and ALifeSide.keyOf(player) or nil,
        legs = { { to = o.id, give = give, want = want } }, leg = 1, items = items, crew = {}, escorts = 0, leave = h, arrive = h + th,
        x0 = fx, y0 = fy, x1 = tx, y1 = ty, state = "out", packs = {}, loaded = {}, orig = {}, withYouMs = 0 }
    for _, uid in ipairs(crew) do
        local okU = false
        pcall(function()
            local R = T.PA().ActorRegistry
            local r = R.read(uid)
            okU = r ~= nil and R.update(r.uid, r.revision, function(e) e.memory = type(e.memory) == "table" and e.memory or {}; e.memory.alcpRun = run.id end) ~= false
        end)
        if okU then run.crew[#run.crew + 1] = uid end
    end
    if #run.crew == 0 then T.postPut(items); return false, "Nobody could go." end
    T.splitPacks(run)
    T.store().runs[run.id] = run
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = run.arrive, tag = "trade_run" }) end
    S.sent = S.sent + 1
    local names = {}
    for _, uid in ipairs(run.crew) do names[#names + 1] = nameOf(uid) end
    local msg = table.concat(names, " and ") .. " set out for " .. tostring(o.name) .. " with " .. (T.KIND_WORDS[give] or give) .. "."
    if #said > 0 then msg = msg .. " " .. table.concat(said, " ") end
    log("own run " .. run.id .. " -> " .. tostring(o.name) .. ": " .. #run.crew .. " crew, " .. #items .. " items")
    return true, msg
end
-- player is an MP player object on the server; exposed (window button) as M.trOwnSend(groupId, give, want, player)
function M.trOwnSend(groupId, give, want, player)
    player = ALifeSide.you(player)
    local ok, msg = T.ownSend(player, tostring(groupId or ""), tostring(give or ""), tostring(want or ""))
    T.letter(player, msg, not ok)
    return ok, msg
end
function M.trOwnRecall(runId, player)
    local run = T.store().runs[tostring(runId or "")]
    if type(run) ~= "table" or run.from ~= "you" or run.state == "home" then return false end
    -- they turn round where they are and come home with what they carry
    local h = hours()
    local f = math.max(0, math.min(1, (h - run.leave) / math.max(0.01, run.arrive - run.leave)))
    local wx, wy = run.x0 + (run.x1 - run.x0) * f, run.y0 + (run.y1 - run.y0) * f
    local tx, ty = T.placeXY("you")
    if tx == nil then return false end
    run.state, run.leg = "home", #run.legs + 1
    run.x0, run.y0, run.x1, run.y1, run.leave = wx, wy, tx, ty, h
    run.arrive = h + M.travelH(wx, wy, tx, ty, nil)
    for _, uid in ipairs(run.crew) do pcall(M.lvSend, uid, { tx = tx, ty = ty, untilH = run.arrive, tag = "trade_run" }) end
    T.letter(ALifeSide.you(player), "Your traders are turning back.", false)
    return true
end

-- home: into the post, or waiting at the gate until it's loaded
function T.ownHome(run, items, h)
    S.home = S.home + 1
    local o = T.base((run.legs[1] or {}).to)
    local what = #items > 0 and (#items .. " " .. (T.KIND_WORDS[T.mainKind(items)] or "things")) or "nothing"
    local why = run.lastWhy
    local text = "Your traders are back from " .. tostring(o and o.name or "the road") .. " with " .. what .. "."
    if why == "embargo" then text = "Your traders were turned away at " .. tostring(o and o.name or "the gate") .. " and brought the goods back."
    elseif why == "robbed" then text = "Your traders came back empty-handed: " .. tostring(o and o.name or "they") .. " took everything." end
    if #items > 0 and not T.postPut(items) then
        local own = T.store().own
        own.pending = type(own.pending) == "table" and own.pending or {}
        for _, t in ipairs(items) do own.pending[#own.pending + 1] = t end
        text = text .. " They'll put it in the trading post when you're there."
    elseif #items > 0 then S.landed = S.landed + #items end
    T.letter(nil, text, why == "robbed")
end
-- remember why a leg went the way it did (for the letter home)
T.onLeg[#T.onLeg + 1] = function(run, leg, gave, got, why) if run.from == "you" then run.lastWhy = why end end
-- goods waiting at the gate go in once the post is loaded
function T.ownPendingTick()
    local own = T.store().own
    if type(own.pending) ~= "table" or #own.pending == 0 then return end
    if T.postPut(own.pending) then S.landed = S.landed + #own.pending; own.pending = {} end
end
if type(Events) == "table" and Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_TradeOwn", function() pcall(T.ownPendingTick) end) end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "expose") then
    ALifeRemote.expose("trOwnSend", 3, 4)
    ALifeRemote.expose("trOwnRecall", 1, 2)
end
