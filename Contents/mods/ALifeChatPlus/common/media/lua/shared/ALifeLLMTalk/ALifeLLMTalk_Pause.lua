-- A-Life Talk 0.5.1: PAUSE AND LISTEN.
-- Detected locally and instantly from the player's line (before the AI is asked):
--   * hostile NPC chasing / attacking within earshot + a stop word ("wait", "stop", "hold on", "don't shoot", "please",
--     "listen", "truce", "I give up"...): they halt for a few seconds and listen ("You got five seconds.").
--     Chance and length: calm / loyal / cowardly listen longer; hot-headed / cruel / sadistic barely pause or ignore it;
--     mood, the bond with you and how often you've used it (spamming stops working). Needs A-Life Talk Patch 1.3
--     (P.pauseHostile); without it they only answer. The next line you say goes to the AI first as a plea (the
--     existing combat-plea logic can talk them down); if it doesn't, they resume when the pause runs out.
--   * friendly / neutral NPC or companion walking, following or leaving + "hold on", "wait", "wait up", "stop",
--     "one sec": they stop, face you and wait (A-Life's own Talk.hold, through the patch also for companions),
--     with a short line ("What's up?" - impatient / grumpy types grumble). "come on", "let's go", "move", "never mind"
--     lets them carry on. They wait longer for close friends, then resume on their own.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Pause") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Pause"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Pause") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

if M.settings.pauseListen == nil then M.settings.pauseListen = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "pauseListen" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "pauseListen" end
end
M.pauseCfg = { talkTiles = 14, shoutTiles = 26, baseMs = 5000, minMs = 1500, maxMs = 11000, spamWindowMs = 180000,
    friendlyMs = 15000, friendlyMaxMs = 45000, planMs = 20000 }

M.stopWords = { "wait", "stop", "hold on", "hold up", "don't shoot", "dont shoot", "please", "listen", "truce", "i give up",
    "i surrender", "surrender", "hold your fire", "cease fire", "ceasefire", "don't kill", "dont kill", "enough", "mercy",
    "time out", "hang on", "easy", "calm down", "let's talk", "lets talk" }
M.waitWords = { "hold on", "wait up", "wait", "stop", "one sec", "one second", "hang on", "hold up", "just a sec", "a sec" }
M.goWords = { "come on", "let's go", "lets go", "move", "never mind", "nevermind", "carry on", "go on", "forget it", "keep going", "you can go" }

local function has(low, list)
    for _, w in ipairs(list) do
        local a, b = string.find(low, w, 1, true)
        if a then
            local before = a > 1 and string.sub(low, a - 1, a - 1) or " "
            local after = string.sub(low, b + 1, b + 1)
            if not string.find(before, "%w") and (after == "" or not string.find(after, "%w")) then return w end
        end
    end
    return nil
end
M.hasWord = has

-- how long (ms) this hostile NPC listens; 0 = ignores it
M.pauseUses = {} -- recent uses (spam)
function M.pauseLength(uid, player, now)
    local lens = M.lens and M.lens(uid) or {}
    local core = M.partsOf and M.partsOf(uid) or nil
    local k = core and core.core and core.core.key or ""
    local mult = 1 + (lens.calm or 0) * 1.2 + (lens.loyal or 0) * 0.6 + (lens.fearful or 0) * 0.9 + (lens.kind or 0) * 0.5
        - (lens.volatile or 0) * 1.0 - (lens.mean or 0) * 0.9 - (lens.proud or 0) * 0.3
    if k == "hothead" or k == "sadist" or k == "cruel" or k == "bully" or k == "ruthless" then mult = mult * 0.35 end
    if k == "coward" or k == "gentle" or k == "stoic" or k == "wise" or k == "shy" then mult = mult * 1.35 end
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    mult = mult - (b.anger or 0) * 0.6 + (b.fear or 0) * 0.3
    local op = 0
    pcall(function() op = tonumber((PA().NpcOpinion.valueOf(PA().ActorRegistry.read(uid), player))) or 0 end)
    mult = mult + op / 120
    if M.nemesisOf and (M.nemesisOf(uid) or {}).tier and M.nemesisOf(uid).tier >= 2 then mult = mult * 0.3 end
    -- spamming: each use in the last 3 minutes halves it
    local uses = 0
    for _, t in ipairs(M.pauseUses) do if now - t < M.pauseCfg.spamWindowMs then uses = uses + 1 end end
    mult = mult * (0.5 ^ uses)
    local chance = clamp(math.floor(55 + mult * 30), 3, 95)
    if hash(tostring(uid) .. "#" .. math.floor(now / 1000)) % 100 >= chance then return 0, chance end
    local ms = clamp(math.floor(M.pauseCfg.baseMs * mult), 0, M.pauseCfg.maxMs)
    if ms < M.pauseCfg.minMs then return 0, chance end
    return ms, chance
end

M.pauseLines = {
    listen = { "You got five seconds.", "Talk. Fast.", "...I'm listening.", "Make it quick.", "Start talking.", "Say it. Now." },
    ignore = { "Too late for that!", "Save your breath!", "Nope.", "Nice try!", "Begging won't help you." },
    mean = { "Five seconds. Then I gut you.", "Go on, beg. I like that.", "Talk, then. Make it good." },
    scared = { "W-what? What do you want?", "Okay, okay - talk!", "Don't move! Just - talk." },
    resume = { "Time's up.", "That's what I thought.", "Not good enough!", "Enough talk!" },
    wait = { "What's up?", "Yeah?", "What is it?", "Hm?", "Something wrong?" },
    wait_grumpy = { "What now?", "Make it quick.", "Ugh. What?", "Seriously?" },
    wait_close = { "Sure, take your time.", "I'm here. What's up?", "Yeah, I'll wait." },
    go = { "Alright.", "Okay, moving.", "Right.", "Sure." },
    resumeSelf = { "I'm heading on.", "Can't wait forever.", "Alright, I'm going.", "Catch up later." },
}
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end

local function sayQuick(l, player, line)
    if M.say then M.say(l.shell, player, line, { record = l.record, combat = true }) end
end

M.paused = {}   -- uid -> { untilMs, hostile = true/false, at }
function M.isPaused(uid)
    local p = M.paused[tostring(uid)]
    return p ~= nil and nowMs() < p.untilMs and p.hostile == true
end

-- hostile: someone chasing / attacking you within earshot
function M.pauseHostiles(player, text, loud)
    local pa = PA()
    local px, py, pz = pos(player)
    if px == nil or not M.nearbyNpcs then return 0 end
    local now = nowMs()
    local r = loud and M.pauseCfg.shoutTiles or M.pauseCfg.talkTiles
    local n = 0
    for _, l in ipairs(M.nearbyNpcs(px, py, pz, r)) do
        local stance = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or "neutral"
        if stance == "hostile" and n < 3 then
            n = n + 1
            local uid = tostring(l.record.uid)
            local ms, chance = M.pauseLength(uid, player, now)
            local P = patch()
            local _, style = nil, nil
            if M.personaKind then _, style = M.personaKind(uid) end
            if ms > 0 then
                local ok = false
                if P and fn(P, "pauseHostile") then ok = pcall(P.pauseHostile, uid, player, ms) end
                M.paused[uid] = { untilMs = now + ms, hostile = true, at = now, real = ok }
                local lens = M.lens and M.lens(uid) or {}
                local pool = (style == "insult" or style == "mock" or (lens.mean or 0) > 0.3) and M.pauseLines.mean
                    or ((lens.fearful or 0) > 0.3 and M.pauseLines.scared) or M.pauseLines.listen
                sayQuick(l, player, pick(pool, uid .. now))
                if M.feel then M.feel(uid, "confusion", 0.1, "you begged them to stop") end
                if M.logInteraction then pcall(M.logInteraction, uid, "Stopped to hear you out (" .. math.floor(ms / 1000) .. " s)", nil, nil, "event") end
                log("pause: " .. uid .. " listens " .. ms .. " ms (chance " .. chance .. "%" .. (ok and "" or ", no patch: words only") .. ")")
                -- the next line you say reaches them first (plea; the AI answers ahead of chatter)
                M.pleaFocus = { uid = uid, untilMs = now + ms + 2000 }
            else
                sayQuick(l, player, pick(M.pauseLines.ignore, uid .. now))
                log("pause: " .. uid .. " ignores it (chance " .. tostring(chance) .. "%)")
            end
        end
    end
    if n > 0 then M.pauseUses[#M.pauseUses + 1] = now end
    while #M.pauseUses > 8 do table.remove(M.pauseUses, 1) end
    return n
end

-- friendly / neutral: walking, following or leaving -> stop and wait
function M.friendlyWaitMs(uid, player)
    local ms = M.pauseCfg.friendlyMs
    local op = 0
    pcall(function() op = tonumber((PA().NpcOpinion.valueOf(PA().ActorRegistry.read(uid), player))) or 0 end)
    ms = ms + math.max(0, op) * 250
    local lens = M.lens and M.lens(uid) or {}
    ms = ms * (1 + (lens.calm or 0) * 0.6 + (lens.kind or 0) * 0.4 - (lens.volatile or 0) * 0.5 - (lens.proud or 0) * 0.3)
    return clamp(math.floor(ms), 5000, M.pauseCfg.friendlyMaxMs)
end
local function moving(l)
    local m = false
    pcall(function() m = l.shell:isMoving() == true end)
    if not m then
        local mem = type(l.record.memory) == "table" and l.record.memory or {}
        m = type(mem.walkWith) == "table" or l.record.activity == "travel" or l.record.intent == "leave"
    end
    local P = patch()
    if not m and P and fn(P, "companionOf") and P.companionOf(l.record.uid) then m = true end
    return m
end
function M.pauseFriendly(player, text, hearers)
    local pa = PA()
    local P = patch()
    local now = nowMs()
    local n = 0
    for _, l in ipairs(hearers or {}) do
        local uid = tostring(l.record.uid)
        local stance = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or "neutral"
        if stance ~= "hostile" and (moving(l) or (M.paused[uid] and not M.paused[uid].hostile)) and n < 3 then
            n = n + 1
            local ms = M.friendlyWaitMs(uid, player)
            local ok = false
            if P and fn(P, "holdFriendly") then ok = pcall(P.holdFriendly, uid, player, ms)
            elseif fn(pa.Talk, "hold") then ok = pcall(pa.Talk.hold, l.record, l.shell, player, now, ms) end
            if not ok then pcall(function() l.shell:setMoving(false) end) end -- vanilla fallback: a brief stop
            M.paused[uid] = { untilMs = now + ms, hostile = false, at = now }
            local _, style = nil, nil
            if M.personaKind then _, style = M.personaKind(uid) end
            local close = M.closenessToPlayer and M.closenessToPlayer(uid, player) or 0
            local pool = M.pauseLines.wait
            if style == "insult" or style == "mock" or style == "refuse" or style == "mope" then pool = M.pauseLines.wait_grumpy
            elseif close >= 0.6 then pool = M.pauseLines.wait_close end
            if M.pending == nil or tostring(M.pending.uid) ~= uid then sayQuick(l, player, pick(pool, uid .. now)) end
            if M.logInteraction then pcall(M.logInteraction, uid, "Waited for you (" .. math.floor(ms / 1000) .. " s)", nil, nil, "event") end
            log("wait: " .. uid .. " waits " .. ms .. " ms")
        end
    end
    return n
end
function M.resumeFriendly(player, text, hearers)
    local P = patch()
    local n = 0
    for uid, p in pairs(M.paused) do
        if not p.hostile and nowMs() < p.untilMs then
            M.paused[uid] = nil
            if P and fn(P, "resumeFriendly") then pcall(P.resumeFriendly, uid, player) end
            local pa = PA()
            if not (P and fn(P, "resumeFriendly")) and fn(pa.Talk, "releaseHold") then pcall(pa.Talk.releaseHold, uid, pa.Speech.playerKey(player)) end
            n = n + 1
            if n == 1 then
                local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
                if sh and M.say then M.say(sh, player, pick(M.pauseLines.go, uid .. nowMs()), { record = pa.ActorRegistry.read(uid) }) end
            end
        end
    end
    return n
end

function M.closenessToPlayer(uid, player)
    local v = 0
    pcall(function() v = tonumber((PA().NpcOpinion.valueOf(PA().ActorRegistry.read(uid), player))) or 0 end)
    return clamp(v / 80, 0, 1)
end

function M.onPauseWords(player, text, loud, hearers)
    if M.settings.pauseListen == false then return end
    local low = string.lower(tostring(text or ""))
    if has(low, M.goWords) then M.resumeFriendly(player, text, hearers); return end
    if has(low, M.stopWords) then
        local n = M.pauseHostiles(player, text, loud)
        if n > 0 then return end
    end
    if has(low, M.waitWords) then M.pauseFriendly(player, text, hearers) end
end
table.insert(M.playerWordHooks, M.onPauseWords)

-- hostile pauses running out: resume (not calmed) with a line
function M.pauseTick(now)
    local pa = PA()
    local player = ALifeSide.you()
    for uid, p in pairs(M.paused) do
        if now >= p.untilMs then
            M.paused[uid] = nil
            local r = pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid) or nil
            local sh = r and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
            if sh and type(ALifeSide) == "table" and ALifeSide.mpServer() then player = ALifeSide.nearestTo(sh) end -- MP: the player near them
            if p.hostile and r and sh and player and fn(pa.Talk, "stance") and pa.Talk.stance(r, player) == "hostile" then
                if M.say then M.say(sh, player, pick(M.pauseLines.resume, uid .. now), { record = r, combat = true }) end
                if M.logInteraction then pcall(M.logInteraction, uid, "Wasn't convinced - back to the fight", nil, nil, "event") end
            elseif not p.hostile and r and sh and player and M.say and p.untilMs - p.at >= 10000 then
                M.say(sh, player, pick(M.pauseLines.resumeSelf, uid .. now), { record = r })
            end
        end
    end
end
if type(Events) == "table" and Events.OnTick then
    local n = 0
    ALifeHealth.add(Events.OnTick, "ALifeLLMTalk_Pause", function()
        n = n + 1
        if n % 20 ~= 7 then return end
        pcall(M.pauseTick, nowMs())
    end)
end

table.insert(M.requestExtras, function(req, player, listener, now)
    local p = M.paused[tostring(listener.record.uid)]
    if p and now < p.untilMs then
        req.pause = { hostile = p.hostile == true, secs = math.max(1, math.floor((p.untilMs - now) / 1000)) }
    end
end)

return M
