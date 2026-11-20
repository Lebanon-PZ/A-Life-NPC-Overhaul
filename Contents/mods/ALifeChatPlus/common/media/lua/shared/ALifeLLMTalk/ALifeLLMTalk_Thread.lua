-- A-Life Talk 0.5.2.8 [pt265u]: THE CONVERSATION THREAD. "when he said it should've been me i asked whats wrong and he
-- talked about his leg". The NPC's own last line (grief, activity, ambient, stock or AI) is kept per NPC and sent with
-- the next request as req.lastLine = { text, ago, about }; the bridge puts it in the never-cut core ("You just said:
-- ...") so a short follow-up ("dont say that", "whats wrong", "give me one") is answered in that context. Off: talkThread.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Thread") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if ALifeTalkEnd == nil then require "ALifeNPCOverhaul/ALifeTalkEnd" end -- pre-1.0: loaded first by folder order before (ALifeChatPlus sorted first); now a real require
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Thread"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Thread") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function nowMs() return M.nowMs() end

if M.settings.talkThread == nil then M.settings.talkThread = true end
if M.settings.likesSaidOnly == nil then M.settings.likesSaidOnly = true end
if type(M.fileKeys) == "table" then
    for _, key in ipairs({ "talkThread", "likesSaidOnly" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end

M.threadCfg = { keepMs = 180000, aboutMs = 90000 }
M.lastLines = M.lastLines or {}

local GRIEF_WORDS = { "miss", "gone", "been me", "dead", "should've", "shoulda", "lost", "grave", "amen", "lord" }
-- what that line was about (so "what's wrong?" lands on it): a loss line, a grieving activity, a fresh loss
function M.threadAbout(uid, text, now)
    uid = tostring(uid)
    local L = nil
    pcall(function() L = M.lossNow and M.lossNow(uid) or nil end)
    local ll = M.lossLastLine
    if type(ll) == "table" and ll.uid == uid and now - (tonumber(ll.at) or -1e12) < M.threadCfg.aboutMs and ll.what then
        return string.sub(tostring(ll.what), 1, 140)
    end
    local a = type(M.activities) == "table" and M.activities[uid] or nil
    if type(a) == "table" and a.kind == "grieve" then
        return L and ("you were grieving " .. tostring(L.name) .. " out loud") or "you were grieving out loud"
    end
    if L and (tonumber(L.g) or 0) >= 0.2 then
        local low = string.lower(tostring(text or ""))
        local nm = string.lower(tostring(L.name or "?"))
        local firstName = string.match(nm, "^(%S+)") or nm
        if string.find(low, firstName, 1, true) then return "your grief for " .. tostring(L.name) end
        for _, w in ipairs(GRIEF_WORDS) do
            if string.find(low, w, 1, true) then return "your grief for " .. tostring(L.name) end
        end
    end
    return nil
end

function M.threadNote(uid, text, now)
    if M.settings.talkThread == false or uid == nil or type(text) ~= "string" or text == "" then return end
    now = now or nowMs()
    local about = nil
    pcall(function() about = M.threadAbout(uid, text, now) end)
    M.lastLines[tostring(uid)] = { text = string.sub(text, 1, 240), at = now, about = about }
end

if type(M.npcLineHooks) == "table" then
    table.insert(M.npcLineHooks, function(shell, uid, text) if uid ~= nil then M.threadNote(uid, text) end end)
end

-- the next request carries it (the bridge keeps it in the never-cut core)
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.talkThread == false or listener == nil or listener.record == nil then return end
    local e = M.lastLines[tostring(listener.record.uid)]
    if type(e) ~= "table" or now - (e.at or 0) > M.threadCfg.keepMs or now < (e.at or 0) then return end
    req.lastLine = { text = e.text, ago = math.floor((now - e.at) / 1000), about = e.about }
end)

-- 0.8.3 step 1: THE VISIT THREAD. Every line between you and one NPC while you talk (no gap longer than visitGapSec)
-- is kept per player + NPC and sent with the next request as req.visit, so follow-ups three lines back still land.
-- Your line is added when its request is built; theirs come from npcLineHooks while a visit is open. Off: talkVisit.
local VISIT_DEFAULTS = { talkVisit = true, visitGapSec = 300, visitTurns = 12, visitChars = 1600,
    talkRemember = true, rememberDays = 7 } -- 0.8.3 step 6
for k, v in pairs(VISIT_DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
-- 0.8.3 step 2 (shared/ALifeNPCOverhaul/ALifeTalkEnd.lua loads before Main, so its keys are listed here)
if type(ALifeTalkEnd) == "table" and type(ALifeTalkEnd.DEFAULTS) == "table" then
    for k, v in pairs(ALifeTalkEnd.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
end
if type(M.fileKeys) == "table" then
    for _, key in ipairs({ "talkVisit", "visitGapSec", "visitTurns", "visitChars", "talkRemember", "rememberDays",
            "talkEndClose", "talkEndCloseMs", "talkEndRefuse", "talkPushCost", "talkPushMax" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end

M.visits = M.visits or {} -- [uid][playerKey] = { turns = { {w, t, at} }, earlier = { topics }, lastAt }
local function num(key) local v = tonumber(M.settings[key]); if v == nil then v = VISIT_DEFAULTS[key] end; return v end

function M.visitKey(player)
    local k = nil
    pcall(function()
        local S = ProjectALife and ProjectALife.Speech or nil
        if S ~= nil and type(S.playerKey) == "function" then k = S.playerKey(player) end
    end)
    if k == nil or k == "" then k = "local" end
    return tostring(k)
end

-- 0.8.3 step 6: REMEMBERED THREADS. A finished visit is kept in the save (bucket "visits", uid|playerKey, newest
-- REMEMBER_KEEP): when, how it ended, its last lines, earlier topics, a question of theirs you never answered. The
-- first line of your next visit to them (within rememberDays) carries it once as req.lastVisit. Off: talkRemember.
local REMEMBER_KEEP = 300
local function gameHours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function store()
    if type(M.bucket) == "function" then
        local ok, b = pcall(M.bucket, "visits")
        if ok and type(b) == "table" then return b end
    end
    M.visitStoreTmp = M.visitStoreTmp or {}
    return M.visitStoreTmp
end

function M.visitSave(uid, pkey, v, how)
    if M.settings.talkRemember == false or type(v) ~= "table" or #v.turns < 2 then return false end
    local you, them = false, false -- only a real exchange is worth remembering
    for _, x in ipairs(v.turns) do if x.w == "you" then you = true elseif x.w == "them" then them = true end end
    if not (you and them) then return false end
    local last = {}
    for i = math.max(1, #v.turns - 2), #v.turns do last[#last + 1] = { w = v.turns[i].w, t = v.turns[i].t, n = v.turns[i].n } end
    local earlier = {}
    for i = 1, math.min(2, #v.earlier) do earlier[#earlier + 1] = v.earlier[i] end
    local b = store()
    b[tostring(uid) .. "|" .. tostring(pkey)] = { h = tonumber(v.lastH) or gameHours(), how = how or v.endHow or "trailed", turns = last,
        earlier = earlier, q = v.unanswered }
    local keys, n = {}, 0
    for k, x in pairs(b) do n = n + 1; keys[#keys + 1] = { k = k, h = type(x) == "table" and tonumber(x.h) or 0 } end
    if n > REMEMBER_KEEP then
        table.sort(keys, function(a, c) return a.h < c.h end)
        for i = 1, n - REMEMBER_KEEP do b[keys[i].k] = nil end
    end
    return true
end

-- a visit ends: kept (if anything was said) and closed
local function dropVisit(uid, pkey, how)
    local byP = M.visits[tostring(uid)]
    local v = byP and byP[pkey] or nil
    if v == nil then return end
    pcall(M.visitSave, uid, pkey, v, how)
    byP[pkey] = nil
end

-- the talk was ended on purpose (ALifeTalkEnd: "walked" = they walked out, "bye" = you said goodbye)
function M.visitEnd(uid, player, how)
    dropVisit(tostring(uid), M.visitKey(player), how)
end
-- 0.8.3 step 9: someone else in the group said something into your talk with uid (ALifeTalk_Group.lua)
function M.visitOther(uid, player, name, text, now)
    local byP = M.visits[tostring(uid)]
    local v = byP and byP[M.visitKey(player)] or nil
    if v == nil or type(text) ~= "string" or text == "" then return false end
    M.visitAdd(v, "other", text, now or nowMs(), tostring(name or "someone else"))
    return true
end
-- a question of theirs you never answered (ALifeAskBack): remembered with this visit
function M.visitUnanswered(uid, player, q)
    local byP = M.visits[tostring(uid)]
    local v = byP and byP[M.visitKey(player)] or nil
    if v ~= nil and type(q) == "string" then v.unanswered = string.sub(q, 1, 200) end
end

function M.visitOpen(uid, pkey, now)
    local byP = M.visits[tostring(uid)]
    local v = byP and byP[pkey] or nil
    if v == nil then return nil end
    if now < v.lastAt or now - v.lastAt > num("visitGapSec") * 1000 then dropVisit(uid, pkey); return nil end
    return v
end

local function topicOf(text)
    local t = string.gsub(tostring(text or ""), "%s+", " ")
    if #t > 50 then t = string.sub(t, 1, 47) .. "..." end
    return t
end

-- add one line; past the caps the oldest lines move to `earlier` (your lines only, as short topics, max 4)
function M.visitAdd(v, who, text, now, name)
    text = string.sub(tostring(text), 1, 240)
    local last = v.turns[#v.turns]
    if last ~= nil and last.w == who and last.t == text then v.lastAt = now; return end
    v.turns[#v.turns + 1] = { w = who, t = text, at = now, n = name } -- 0.8.3 step 9: w = "other" + n = someone else there
    v.lastAt = now
    v.lastH = gameHours() -- 0.8.3 step 6: when it ended, in game time
    local function chars() local n = 0; for _, x in ipairs(v.turns) do n = n + #x.t end; return n end
    while #v.turns > 1 and (#v.turns > num("visitTurns") or chars() > num("visitChars")) do
        local old = table.remove(v.turns, 1)
        if old.w == "you" then
            v.earlier[#v.earlier + 1] = topicOf(old.t)
            if #v.earlier > 4 then table.remove(v.earlier, 1) end
        end
    end
end

if type(M.npcLineHooks) == "table" then
    table.insert(M.npcLineHooks, function(shell, uid, text)
        if M.settings.talkVisit == false or uid == nil or type(text) ~= "string" or text == "" then return end
        local byP = M.visits[tostring(uid)]
        if byP == nil then return end
        local now = nowMs()
        local keys = {}
        for pkey, _ in pairs(byP) do keys[#keys + 1] = pkey end
        for _, pkey in ipairs(keys) do
            local v = M.visitOpen(uid, pkey, now)
            if v ~= nil then M.visitAdd(v, "them", text, now) end
        end
    end)
end

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.talkVisit == false or listener == nil or listener.record == nil then return end
    if type(req.said) ~= "string" or req.said == "" then return end
    local uid = tostring(listener.record.uid)
    local pkey = M.visitKey(player)
    -- drop finished visits (no next() in Kahlua: collect keys with pairs first)
    local stale = {}
    for u, byP in pairs(M.visits) do
        for p, x in pairs(byP) do
            if now < x.lastAt or now - x.lastAt > num("visitGapSec") * 1000 then stale[#stale + 1] = { u, p } end
        end
    end
    for _, s in ipairs(stale) do dropVisit(s[1], s[2]) end
    local v = M.visitOpen(uid, pkey, now)
    if v == nil then
        M.visits[uid] = M.visits[uid] or {}
        v = { turns = {}, earlier = {}, lastAt = now, startAt = now }
        M.visits[uid][pkey] = v
        -- 0.8.3 step 6: the last time you two talked, once
        if M.settings.talkRemember ~= false then
            local b = store()
            local key = uid .. "|" .. pkey
            local last = b[key]
            local ago = type(last) == "table" and (gameHours() - (tonumber(last.h) or 0)) or nil
            if ago ~= nil and ago >= 0 and ago <= num("rememberDays") * 24 and not last.used then
                req.lastVisit = { agoH = math.floor(ago * 10) / 10, how = last.how, turns = last.turns, earlier = last.earlier,
                    q = last.q }
                last.used = true
            end
        end
    end
    if #v.turns > 0 or #v.earlier > 0 then
        local turns = {}
        for _, x in ipairs(v.turns) do turns[#turns + 1] = { w = x.w, t = x.t, n = x.n, ago = math.floor((now - x.at) / 1000) } end
        local earlier = {}
        for _, x in ipairs(v.earlier) do earlier[#earlier + 1] = x end
        req.visit = { turns = turns, earlier = earlier, min = math.floor((now - (v.startAt or now)) / 60000) }
    end
    M.visitAdd(v, "you", req.said, now)
end)
