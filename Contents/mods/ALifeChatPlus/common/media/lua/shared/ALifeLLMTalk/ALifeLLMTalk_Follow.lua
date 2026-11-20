-- A-Life Talk v3.2: "Follow me" / "Stop following" (right-click) and travelling companions.
-- The request goes through A-Life's own menu path, Talk.choose(player, {uid, choice = "WALK_WITH_ME" | "WALK_STOP"}),
-- so A-Life's trust rules apply unchanged: stance must be friendly, TalkSocial's gate, NpcOpinion.talkRefusal
-- (opinion below ~25: "Not yet. Ask me when I trust you more."), the 2 h cooldown after a walk, busy stances, and
-- Talk.walkWith itself. When A-Life says no without a line of its own, the NPC says a short AI refusal.
-- While someone walks with you: A-Life's walk lasts Talk.walkHours (1 in-game hour); we renew it through the same
-- Talk.walkWith call shortly before it runs out (only while you stay within 40 tiles and never after you said stop),
-- tell the model about the trip (where from, how long), and let the follower comment now and then.
-- A-Life limits (not changed): no following into vehicles, the walk drops past 60 tiles, the shell must be loaded.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Follow") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Follow"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Follow") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end
local function log(msg) M.log(msg) end
local function pos(o)
    if o == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end)
    return x, y, z
end
local function hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return h
end

M.follow = { renewTiles = 40, renewBeforeHours = 0.1, chatEveryMs = 6 * 60000, chatChance = 35, carGapMs = 120000 }
M.trips = {} -- uid -> { startH, sx, sy, from, keep, lastChatMs, carMs }

local refuseWhy = {
    not_friendly = "you don't know or trust them enough to go wandering with them",
    busy = "you're busy / you just walked with them and need a break",
    hostile = "you're not on good terms",
    walk_off = "you're not going anywhere with anyone right now",
    unavailable = "you can't right now",
}

-- A-Life's menu rules, read-only, so the model is never offered WALK_WITH_ME when A-Life would refuse it
function M.followVerdict(listener, player)
    local pa = PA()
    if not fn(pa and pa.Talk, "walkWith") then return "unavailable" end
    if pa.PersonalRep == nil or pa.PersonalRep.enabled ~= true then return "walk_off" end
    if fn(pa.Talk, "stance") and pa.Talk.stance(listener.record, player) ~= "friendly" then return "not_friendly" end
    if fn(pa.NpcOpinion, "talkRefusal") then
        local refusal = pa.NpcOpinion.talkRefusal(player, listener.record, { id = "WALK_WITH_ME" })
        if refusal ~= nil then return "not_yet", refusal end
    end
    local memory = type(listener.record.memory) == "table" and listener.record.memory or {}
    if memory.stance ~= nil and memory.stance ~= "route" and memory.stance ~= "walkWith" then return "busy" end
    if hours() < (tonumber(memory.walkCooldownUntilHours) or -math.huge) then return "busy" end
    return nil
end

function M.followStart(listener, player)
    local P = M.patch and M.patch() or nil -- v0.3.3: A-Life Talk Patch companion mode (no time limit, catch-up)
    if P ~= nil and type(P.startCompanion) == "function" and type(P.companionOf) == "function"
            and P.companionOf(listener.record.uid) == nil then pcall(P.startCompanion, player, listener) end
    local uid = tostring(listener.record.uid)
    local x, y, z = pos(player)
    M.trips[uid] = { startH = hours(), sx = x, sy = y, from = (x and M.placeName) and M.placeName(x, y, z or 0) or nil,
        keep = true, lastChatMs = nowMs() }
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and player ~= nil then M.trips[uid].pk = ALifeSide.keyOf(player) end -- pre-1.0 MP: whose trip
    log("follow: " .. uid .. " walks with you")
end

-- 0.6.12: is this person with you right now (said yes to "follow me", in your party, a companion)? Daily life
-- (rest, chores, camp jobs, work zones) leaves them alone: someone who agreed to follow you follows you.
function M.withPlayer(uid, player)
    uid = tostring(uid)
    local t = M.trips[uid]
    if t and t.keep then return true end
    if M.bucket and M.bucket("party")[uid] then return true end
    local P = M.patch and M.patch() or nil
    if P and fn(P, "companionOf") then local ok, c = pcall(P.companionOf, uid); if ok and c ~= nil then return true end end
    local pa = PA()
    local r = nil
    if pa and pa.ActorRegistry and fn(pa.ActorRegistry, "read") then pcall(function() r = pa.ActorRegistry.read(uid) end) end
    local m = r and type(r.memory) == "table" and r.memory or nil
    if m and (m.stance == "walkWith" or m.walkWithPlayer ~= nil) then return true end
    return false
end
function M.followEnd(uid)
    if M.trips[tostring(uid)] then log("follow: " .. tostring(uid) .. " stopped") end
    M.trips[tostring(uid)] = nil
end

function M.followAsk(player, uid, stop)
    local pa = PA()
    local l = nil
    for _, row in ipairs(pa.Talk.listeners(player, 8)) do if tostring(row.record.uid) == tostring(uid) then l = row end end
    if l == nil then return end
    local choice = stop and "WALK_STOP" or "WALK_WITH_ME"
    local ok, reason
    if fn(pa.Talk, "choose") then
        ok, reason = pa.Talk.choose(player, { uid = tostring(uid), choice = choice })
    else -- very old A-Life: same rules by hand
        local v, text = M.followVerdict(l, player)
        if stop or v == nil then
            ok, reason = pa.Talk.walkWith(player, l, choice)
            if ok then if M.ownSay then M.ownSay(l.shell, reason, { face = player }) else pa.Speech.say(l.shell, reason, { face = player }) end; reason = "answered" end
        elseif text then if M.ownSay then M.ownSay(l.shell, text, { face = player }) else pa.Speech.say(l.shell, text, { face = player }) end; ok, reason = true, "answered"
        else ok, reason = false, v end
    end
    local walking = M.walkingWith(l, player)
    log("follow menu: " .. choice .. " -> " .. tostring(ok) .. " / " .. tostring(reason) .. " (walking=" .. tostring(walking) .. ")")
    if stop then
        M.followEnd(uid)
        return
    end
    if walking then M.followStart(l, player); return end
    if reason ~= "answered" then -- refused without a line of its own: an AI refusal line
        M.react("follow", l, player, { what = "They asked you to follow them / come along. You say no: "
            .. (refuseWhy[tostring(reason)] or "not now"), style = "short refusal in your own voice", maxWords = 12 },
            { key = "followno:" .. tostring(uid), keyCooldownMs = 5000, urgent = true, face = "player" })
    end
end

function M.addFollowMenu(context, player, l, name)
    if not fn(PA().Talk, "walkWith") then return end
    local uid = tostring(l.record.uid)
    local walking = M.walkingWith(l, player)
    local label = walking and ("A-Life: Stop following (" .. tostring(name or "them") .. ")")
        or ("A-Life: Follow me (" .. tostring(name or "them") .. ")")
    M.menuOpt(context, "follow", label, uid, function(u)
        local ok, err = pcall(M.followAsk, player, u, walking == true)
        if not ok then log("follow error: " .. tostring(err)) end
    end)
end

-- renew / trip chat / car warning
function M.followTick()
    M.eachPlayer(M.followTickFor) -- pre-1.0 MP (P3): every player's trips (single player: yours)
end
function M.followTickFor(player)
    local pa = PA()
    if player == nil or not fn(pa and pa.Talk, "listeners") then return end
    local myKey = (type(ALifeSide) == "table" and ALifeSide.mpServer()) and tostring(ALifeSide.keyOf(player)) or nil
    local now, h = nowMs(), hours()
    local near = {}
    for _, l in ipairs(pa.Talk.listeners(player, M.follow.renewTiles)) do near[tostring(l.record.uid)] = l end
    local inCar = false
    pcall(function() inCar = player:getVehicle() ~= nil end)
    for uid, trip in pairs(M.trips) do
      if myKey == nil or trip.pk == nil or tostring(trip.pk) == myKey then -- pre-1.0 MP: only this player's trips
        local l = near[uid]
        local rec = l and l.record or (fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid))
        local memory = rec and type(rec.memory) == "table" and rec.memory or {}
        local walk = memory.walkWith
        if type(walk) ~= "table" then
            if l ~= nil and trip.keep and (h - (trip.startH or h)) < 0.02 then -- not written yet
            else M.followEnd(uid) end
        elseif l ~= nil then
            local P = M.patch and M.patch() or nil
            local patched = P ~= nil and type(P.companionOf) == "function" and P.companionOf(uid) ~= nil
            if trip.keep and not patched and (tonumber(walk.untilHours) or 0) - h < M.follow.renewBeforeHours then
                local ok = pa.Talk.walkWith(player, l, "WALK_WITH_ME") -- A-Life's own renewal path (stance already walkWith)
                log("follow: renew " .. uid .. " -> " .. tostring(ok))
            end
            if inCar then
                if now - (trip.carMs or -1e12) > M.follow.carGapMs then
                    trip.carMs = now
                    M.react("follow", l, player, { what = patched and "They just got into a vehicle; you're coming along with them"
                        or "They just got into a vehicle and you are on foot following them",
                        style = patched and "a quick line as you climb in (shotgun, hold on, drive careful)" or "call out (wait / you're leaving me / let me in)", maxWords = 10 }, { key = "car:" .. uid, keyCooldownMs = M.follow.carGapMs, urgent = true })
                end
            elseif now - (trip.lastChatMs or now) > M.follow.chatEveryMs then
                trip.lastChatMs = now
                if M.roll(100) < M.follow.chatChance then
                    M.react("follow", l, player, { what = "You're travelling with them; small talk about the trip (where you're headed, "
                        .. "how far you've come, what's around, how you feel)", style = "casual, one line", maxWords = 16 },
                        { key = "tripchat:" .. uid, keyCooldownMs = M.follow.chatEveryMs })
                end
            end
        end
      end
    end
end

-- prompt: the trip / whether they'd follow you
table.insert(M.requestExtras, function(req, player, listener, now)
    local uid = tostring(listener.record.uid)
    local walking = M.walkingWith(listener, player)
    local trip = M.trips[uid]
    if walking then
        local mins = trip and math.floor((hours() - (trip.startH or hours())) * 60) or nil
        local px, py = pos(player)
        local dist = (trip and trip.sx and px) and math.floor(math.sqrt((px - trip.sx) ^ 2 + (py - trip.sy) ^ 2)) or nil
        req.follow = { mins or -1, trip and trip.from or "", dist or -1 }
    elseif req.said ~= nil and req.said ~= "" then
        local low = string.lower(req.said)
        for _, w in ipairs(M.actWords.WALK_WITH_ME or {}) do
            if string.find(low, w, 1, true) then
                local v = M.followVerdict(listener, player)
                if v ~= nil then req.followNo = refuseWhy[v] or "you don't trust them enough yet" end
                break
            end
        end
    end
end)

return M
