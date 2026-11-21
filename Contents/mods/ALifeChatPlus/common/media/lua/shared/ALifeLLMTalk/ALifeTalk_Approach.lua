-- A-Life NPC Overhaul 0.8.3 step 8: THEY COME TO YOU, with a real reason. Now and then someone nearby walks up to you
-- and starts talking - only when they actually have something to say:
--   * "answer"  - last time they asked you something and you never answered;
--   * "bite"    - they got bitten, they're open about it, and they trust you;
--   * "loss"    - they're grieving and they like you enough to want to talk;
--   * "hungry"  - they're starving and they like you enough to ask;
--   * "checkin" - they like you a lot and haven't talked to you in a day.
-- Rate-limited (approachGapH between any two, approachPerNpcH per person), never mid-fight (the walk is a
-- ALifeTalkPatch claim: A-Life takes them back at any danger), never when they're hurt / fighting (yieldBusy), never
-- while a talk window is open. They walk up (patch kind "approach", A-Life's own Movement), stop a step away, say it
-- (AI line through M.react "approach"; with the AI off a fixed line), then wait for you a moment (claim "listen").
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Approach") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifeApproach = ALifeApproach or {}
local K = ALifeApproach
local TAG = "[ALifeApproach]"
K.VERSION = ALifeSide.MOD_VERSION
K.DEFAULTS = { talkApproach = true, approachGapH = 1.5, approachPerNpcH = 24, approachTiles = 20 }
K.metrics = K.metrics or { started = 0, arrived = 0, lost = 0, timedOut = 0 }
K.WALK_MS, K.LISTEN_MS = 45000, 20000

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function M() return ALifeLLMTalk end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` turns a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
local function first(name) return string.match(tostring(name or "someone"), "^(%S+)") or tostring(name or "someone") end
local function store(name)
    local m = M()
    if fn(m, "bucket") then local ok, b = pcall(m.bucket, name); if ok and type(b) == "table" then return b end end
    K.tmp = K.tmp or {}; K.tmp[name] = K.tmp[name] or {}
    return K.tmp[name]
end

local function opinionOf(record, player)
    local op = PA() and PA().NpcOpinion or nil
    if not fn(op, "valueOf") then return 0 end
    local ok, v = pcall(op.valueOf, record, player)
    return ok and tonumber(v) or 0
end

-- the reason they'd come over, or nil: { id, line (AI off), what (for the AI) }
function K.reasonFor(record, player, pkey, h)
    local m = M()
    local uid = tostring(record.uid)
    local op = opinionOf(record, player)
    local last = store("visits")[uid .. "|" .. tostring(pkey)]
    local lastH = type(last) == "table" and tonumber(last.h) or nil
    -- 1. you never answered their question (step 6 record, within two days)
    if type(last) == "table" and type(last.q) == "string" and last.q ~= "" and lastH and h - lastH <= 48 and not last.qChased then
        return { id = "answer", key = last, line = "Hey. You never answered me before.",
            what = "Last time you asked them \"" .. last.q .. "\" and they never answered. Walk up and ask again, your own way." }
    end
    -- 2. bitten, open about it, and they trust you
    if fn(m, "biteInfo") and op >= 40 then
        local ok, b = pcall(m.biteInfo, uid)
        local mode = fn(m, "biteMode") and m.biteMode(uid) or "all"
        if ok and type(b) == "table" and mode == "all" then
            return { id = "bite", line = "I need to tell you something. I got bit.",
                what = "You were bitten" .. (b.spot and (" on the " .. tostring(b.spot)) or "") .. ". You trust them; walk up and tell them." }
        end
    end
    -- 3. grieving and they like you
    if fn(m, "lossNow") and op >= 20 then
        local ok, L = pcall(m.lossNow, uid)
        if ok and type(L) == "table" and (tonumber(L.g) or 0) >= 0.5 and L.name ~= nil then
            return { id = "loss", line = "Got a minute? I can't stop thinking about " .. first(L.name) .. ".",
                what = "You're grieving " .. tostring(L.name) .. ". You need to talk to someone; walk up to them about it." }
        end
    end
    -- 4. starving and they like you
    if fn(m, "lifeOf") and op >= 20 then
        local ok, life = pcall(m.lifeOf, uid)
        if ok and type(life) == "table" and (tonumber(life.thirst) or 0) >= 0.85 then -- 0.8.2 part 2
            return { id = "hungry", line = "You got any water? I'm parched.",
                what = "You're badly thirsty. Walk up and ask them if they can spare some water." }
        end
        if ok and type(life) == "table" and (tonumber(life.hunger) or 0) >= 0.85 then
            return { id = "hungry", line = "Hey... you got anything to eat? I'm running on empty.",
                what = "You're starving. Walk up and ask them if they can spare any food." }
        end
    end
    -- 5. they like you a lot and haven't talked to you in a day
    if op >= 50 and lastH and h - lastH >= 24 then
        return { id = "checkin", line = "Hey, haven't seen you around. You doing alright?",
            what = "You like them and haven't talked in a while. Walk up and check in on them, short and friendly." }
    end
    return nil
end

-- who could come over right now
function K.candidates(player, now)
    local pa = PA()
    local talk = pa and pa.Talk or nil
    if not fn(talk, "listeners") then return {} end
    local ok, list = pcall(talk.listeners, player, tonumber(setting("approachTiles")) or 20)
    if not ok or type(list) ~= "table" then return {} end
    local m, P = M(), ALifeTalkPatch
    local out = {}
    local seen = store("approach")
    local h = hours()
    for _, l in ipairs(list) do
        local r = type(l) == "table" and l.record or nil
        if type(r) == "table" and l.shell ~= nil and type(r.memory) == "table" and r.memory.person == nil then
            local uid = tostring(r.uid)
            local ok2 = h - (tonumber(seen[uid]) or -1e9) >= (tonumber(setting("approachPerNpcH")) or 24)
            if ok2 and fn(m, "yields") and m.yields(l.shell, r) then ok2 = false end
            if ok2 and fn(talk, "stance") then local okS, st = pcall(talk.stance, r, player); if okS and st == "hostile" then ok2 = false end end
            if ok2 and type(P) == "table" and type(P.own) == "table" and P.own.claims[uid] ~= nil then ok2 = false end -- busy with something of ours
            if ok2 and fn(P, "busyStance") and P.busyStance(r) then ok2 = false end
            if ok2 then out[#out + 1] = l end
        end
    end
    return out
end

local function windowOpen()
    local W = ALifeWindowTalk
    if not fn(W, "window") then return false end
    local ok, win = pcall(W.window)
    return ok and win ~= nil
end

-- one step: start a walk-up, or follow the one under way
function K.tick(player, now)
    if setting("talkApproach") == false or player == nil then return end
    local P = ALifeTalkPatch
    if not (fn(P, "claim") and fn(P, "release") and type(P.own) == "table") then return end
    local p = K.pending
    if p ~= nil then
        local c = P.own.claims[p.uid]
        if c == nil or c.kind ~= "approach" then
            K.pending = nil; K.metrics.lost = K.metrics.lost + 1
            return
        end
        if c.spec.arrived then
            K.pending = nil; K.metrics.arrived = K.metrics.arrived + 1
            K.speak(p, player)
            pcall(P.claim, p.uid, "listen", { player = player, ms = K.LISTEN_MS })
        elseif now - p.at > K.WALK_MS then
            K.pending = nil; K.metrics.timedOut = K.metrics.timedOut + 1
            pcall(P.release, p.uid, "approach took too long")
        end
        return
    end
    local h = hours()
    if h - (tonumber(store("approach").__last) or -1e9) < (tonumber(setting("approachGapH")) or 1.5) then return end
    if windowOpen() then return end
    local m = M()
    local pkey = fn(m, "visitKey") and m.visitKey(player) or "local"
    local best, bestReason = nil, nil
    local rank = { answer = 5, bite = 4, loss = 3, hungry = 2, checkin = 1 }
    for _, l in ipairs(K.candidates(player, now)) do
        local okR, reason = pcall(K.reasonFor, l.record, player, pkey, h)
        if okR and reason ~= nil and (bestReason == nil or rank[reason.id] > rank[bestReason.id]) then best, bestReason = l, reason end
    end
    if best == nil then return end
    local uid = tostring(best.record.uid)
    local ok, why = P.claim(uid, "approach", { player = player, ms = K.WALK_MS })
    if not ok then return end
    store("approach")[uid] = h
    store("approach").__last = h
    if bestReason.id == "answer" and type(bestReason.key) == "table" then bestReason.key.qChased = true end
    K.pending = { uid = uid, reason = bestReason, record = best.record, at = now }
    K.metrics.started = K.metrics.started + 1
    log("someone comes over (" .. bestReason.id .. "): " .. uid)
end

function K.speak(p, player)
    local m = M()
    local talk = PA() and PA().Talk or nil
    local shell = fn(talk, "shellFor") and talk.shellFor(p.uid) or nil
    if shell == nil then return false end
    local listener = { record = p.record, shell = shell, distance = 1 }
    local r = p.reason
    local asked = fn(m, "react") and m.react("approach", listener, player, { what = r.what, maxWords = 20, fallback = r.line },
        { key = "approach:" .. p.uid, keyCooldownMs = 60000, modeCooldownMs = 5000, urgent = true, face = "player" })
    if asked then return true end
    if fn(m, "say") then return pcall(m.say, shell, player, r.line, { record = p.record }) end
    return false
end

-- load time: defaults + save keys
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "talkApproach", "approachGapH", "approachPerNpcH", "approachTiles" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
    end
end

if Events ~= nil and Events.OnTick ~= nil then
    local last = 0
    Events.OnTick.Add(function()
        local now = nowMs()
        if now - last < 1000 then return end
        last = now
        -- pre-1.0 MP (P5): runs where the world is, once per online player (SP: you); the walk itself is a patch claim
        local function one(player)
            local ok, err = pcall(K.tick, player, now)
            if not ok and not K.tickErr then K.tickErr = true; log("tick error (once): " .. tostring(err)) end
        end
        if ALifeSide.mpServer() then ALifeSide.each(one) else local p = nil; pcall(function() p = ALifeSide.you() end); one(p) end
    end)
end
log("ready v" .. K.VERSION .. ": they come to you with a real reason (every " .. tostring(K.DEFAULTS.approachGapH) .. " game h at most)")
