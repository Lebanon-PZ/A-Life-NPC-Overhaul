-- A-Life Talk 0.5.1: THE DEAD IN THE PAST TENSE: Relationships pages, ties of the living, and the AI's context
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_UIPast") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UIPast"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UIPast") end end -- 0.5.1.6 perf label
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur == nil then -- pre-1.0 MP: first player with people near
        for _, p in ipairs(ALifeSide.online()) do
            local x, y, z = pos(p)
            local list = M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}
            if #list > 0 then return list, p end
        end
        return {}, nil
    end
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_UIPast", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = true, nil
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- pre-1.0 MP: once per online player
            M.eachPlayer(function() local ok2, e2 = pcall(f, now); if not ok2 then ok, e = ok2, e2 end end)
        else ok, e = pcall(f, now) end
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
M.pastWords = {
    { "^Trusts ", "Trusted " }, { " trusts ", " trusted " }, { "^Likes ", "Liked " }, { " likes ", " liked " }, { "^Loves ", "Loved " },
    { " loves ", " loved " }, { "^Hates ", "Hated " }, { " hates ", " hated " }, { "^Fears ", "Feared " }, { " fears ", " feared " },
    { "^Wants ", "Wanted " }, { "^Thinks ", "Thought " }, { " thinks ", " thought " }, { "^Is ", "Was " }, { " is ", " was " },
    { "^Are ", "Were " }, { " are ", " were " }, { "^Has ", "Had " }, { " has ", " had " }, { "^Doesn't ", "Didn't " }, { " doesn't ", " didn't " },
    { "^Can't ", "Couldn't " }, { " can't ", " couldn't " }, { "^Won't ", "Wouldn't " }, { "^Always ", "Always " },
    { "^Fond of", "Was fond of" }, { "^Sweet on", "Was sweet on" }, { "^Your partner", "Was your partner" }, { "^Heartbroken", "Died heartbroken" },
    { "^Wary", "Was wary" }, { "^Friendly", "Was friendly" }, { "^Hostile", "Was hostile" }, { "^Neutral", "Was neutral" },
}
function M.pastTense(s)
    if type(s) ~= "string" or s == "" then return s end
    local out = s
    for _, p in ipairs(M.pastWords) do
        local n
        out, n = string.gsub(out, p[1], p[2])
    end
    return out
end
-- a trait / quirk line: "hot-headed" -> "Was hot-headed", "into fishing" -> "Was into fishing", "hums old songs" -> "Always hummed..."
function M.pastTrait(s)
    if type(s) ~= "string" or s == "" then return s end
    local low = string.lower(s)
    if string.find(low, "^was ") or string.find(low, "^were ") or string.find(low, "^had ") or string.find(low, "^used to") then return s end
    local p = M.pastTense(s)
    if p ~= s then return p end
    local first, rest = string.match(s, "^(%a+)(.*)$")
    if first then
        local f = string.lower(first)
        local verb = nil
        if string.sub(f, -3) == "ies" then verb = string.sub(f, 1, -4) .. "ied"
        elseif string.sub(f, -2) == "es" and (string.sub(f, -4) == "shes" or string.sub(f, -4) == "ches") then verb = string.sub(f, 1, -3) .. "ed"
        elseif string.sub(f, -1) == "s" and string.sub(f, -2) ~= "ss" and #f > 3 then
            verb = string.sub(f, 1, -2)
            if string.sub(verb, -1) == "e" then verb = verb .. "d" elseif string.match(verb, "[^aeiou][aeiou][mnpgt]$") then verb = verb .. string.sub(verb, -1) .. "ed" else verb = verb .. "ed" end
        end
        if verb then return "Always " .. verb .. rest end
    end
    return "Was " .. string.lower(string.sub(s, 1, 1)) .. string.sub(s, 2)
end
local function ago(h)
    h = math.max(0, hours() - (tonumber(h) or hours()))
    if h < 1 then return "just now" elseif h < 24 then return math.floor(h) .. " h ago" end
    local d = math.floor(h / 24)
    return d == 1 and "1 day ago" or (d .. " days ago")
end
-- "Killed by zombies, 2 days ago" / "Turned, 5 h ago" / "Put down after a bite"
function M.deathInfo(uid)
    uid = tostring(uid)
    local tz = bucket("turnedZ")[uid]
    local loss = nil
    for _, e in ipairs(bucket("losses")) do if e.uid == uid then loss = e end end
    local fs = bucket("finalState")[uid]
    local when = (loss and loss.h) or (fs and fs.h) or (tz and tz.h)
    local by = loss and loss.by or (fs and fs.by)
    local text
    if by == "a mercy kill after a bite" then text = "Put down after a bite"
    elseif by and by ~= "" and by ~= "zombies or something unseen" then text = "Killed by " .. (by == "player" and "you" or by)
    elseif by == "zombies or something unseen" then text = "Died - nobody saw how"
    else text = "Deceased" end
    if tz then text = text .. (text == "Deceased" and "" or "; ") .. (text == "Deceased" and "Turned" or "turned") end
    if text == "Deceased; turned" then text = "Turned" end
    if when then text = text .. ", " .. ago(when) end
    return { text = text, turned = tz ~= nil, h = when }
end
-- freeze what they were at the moment of death (pie chart, mood, activity, opinion)
function M.snapshotDead(uid, killerName)
    uid = tostring(uid)
    local fs = bucket("finalState")
    if fs[uid] then return fs[uid] end
    local s = { h = hours(), by = killerName }
    pcall(function() s.chart = M.traitChart and M.traitChart(uid, 5) or nil end)
    pcall(function() s.feel = M.moodOf and M.moodOf(uid, 3) or nil end)
    pcall(function() local a = M.activityLine and M.activityLine(uid); s.activity = a end)
    fs[uid] = s
    return s
end
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_UIPast", function(body, uid, killer)
        pcall(function()
            local kn = M.killerOf and select(1, M.killerOf(killer, ALifeSide.you(), body)) or nil
            M.snapshotDead(uid, kn)
        end)
    end)
end
local function isDead(uid) local r = rec(uid); return r ~= nil and r.lifecycle == "dead" end
-- Relationships window data
function M.pastRelationship(d)
    if type(d) ~= "table" then return d end
    if d.dead then
        d.deceased = M.deathInfo(d.uid)
        d.muted = true
        d.label = M.pastTense(d.label)
        d.why = M.pastTense(d.why)
        d.mood = "Deceased"
        d.lastTalked = d.lastTalked and ("last talked " .. tostring(d.lastTalked)) or nil
        if type(d.persona) == "table" then
            local p = d.persona
            if type(p.traits) == "table" then local t = {}; for i, x in ipairs(p.traits) do t[i] = M.pastTrait(x) end; p.traits = t end
            if type(p.traits) == "string" then p.traits = M.pastTrait(p.traits) end
            p.quirk = M.pastTrait(p.quirk)
            p.label = p.label and ("Was " .. tostring(p.label)) or nil
            if type(p.values) == "string" then p.values = M.pastTense(p.values) end
            if type(p.dislikes) == "string" then p.dislikes = M.pastTense(p.dislikes) end
        end
        if type(d.romance) == "table" then d.romance.word = M.pastTense(d.romance.word) end
        if type(d.love) == "string" then d.love = "Was " .. string.lower(string.sub(d.love, 1, 1)) .. string.sub(d.love, 2) end
        d.seen = nil
        for _, t in ipairs(d.ties or {}) do t.word = "was " .. tostring(t.name) .. "'s " .. tostring(t.word or t.type); t.past = true end
    else
        for _, t in ipairs(d.ties or {}) do
            if t.dead or (t.uid and t.uid ~= "player" and isDead(t.uid)) then
                t.dead = true
                t.word = tostring(t.word or t.type) .. " (deceased)"
            end
        end
    end
    return d
end
-- Personality page data
function M.pastPersonality(d)
    if type(d) ~= "table" then return d end
    if isDead(d.uid) then
        d.dead, d.muted = true, true
        d.deceased = M.deathInfo(d.uid)
        local fs = bucket("finalState")[d.uid]
        if fs and type(fs.chart) == "table" and #fs.chart > 0 then d.chart = fs.chart end -- the pie stays as it was
        local t, q = {}, {}
        for i, x in ipairs(d.traits or {}) do t[i] = type(x) == "table" and x or M.pastTrait(x) end
        for i, x in ipairs(d.quirks or {}) do q[i] = type(x) == "table" and x or M.pastTrait(x) end
        d.traits, d.quirks = t, q
        for _, f in ipairs(d.feel or {}) do f.label = "Felt " .. tostring(f.label) end
        if fs and type(fs.feel) == "table" and #(d.feel or {}) == 0 then
            for i, e in ipairs(fs.feel) do if i <= 3 and (e.v or 0) >= 0.12 then d.feel[#d.feel + 1] = { label = "Felt " .. tostring(e.adj), rgb = e.rgb, v = e.v } end end
        end
        d.opinionWord = M.pastTense(d.opinionWord)
        d.activity = fs and fs.activity and ("last seen " .. tostring(fs.activity)) or nil
        d.injuries = nil
        d.sub = (d.sub and d.sub ~= "" and (d.sub .. "  \194\183  ") or "") .. d.deceased.text
        for _, tt in ipairs(d.ties or {}) do tt.tag = "was " .. tostring(tt.tag) end
    else
        for _, tt in ipairs(d.ties or {}) do
            if tt.dead then
                tt.name = string.gsub(tostring(tt.name), " %(dead%)$", "") .. " (deceased)"
                tt.tag = tostring(tt.tag)
            end
        end
    end
    return d
end
function M.pastInstall()
    if not M.pastRelWrapped and type(M.relationshipData) == "function" then
        M.pastRelWrapped = true
        local o = M.relationshipData
        M.relationshipData = function(uid, player, ...) local d = o(uid, player, ...); pcall(M.pastRelationship, d); return d end
    end
    if not M.pastPageWrapped and type(M.personalityData) == "function" then
        M.pastPageWrapped = true
        local o2 = M.personalityData
        M.personalityData = function(uid, player, ...) local d = o2(uid, player, ...); pcall(M.pastPersonality, d); return d end
    end
end
pcall(M.pastInstall)
-- AI context: the people they knew who are dead are dead (spoken of in the past tense)
table.insert(M.requestExtras, function(req, player, listener, now)
    local uid = tostring(listener.record.uid)
    local out = {}
    for _, t in ipairs(M.tiesOf and M.tiesOf(uid, nil, 10, true) or {}) do
        if t.dead then
            local r = rec(t.uid)
            local info = M.deathInfo(t.uid)
            out[#out + 1] = (r and nameOf(r) or t.name) .. " (your " .. tostring(t.word or t.type) .. "): " .. info.text
            if #out >= 4 then break end
        end
    end
    if #out > 0 then req.deadTies = out end
end)
return M
