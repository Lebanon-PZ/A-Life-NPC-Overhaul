-- A-Life NPC Overhaul 0.8.11: TALK THEM INTO GIVING UP, mid-fight. A-Life has "hands up / drop it / surrender"
-- orders (TalkOrders, its own odds: who they are, your gun and aim, your people, their crew and arms, distance, cover,
-- fear, your rep), but in a fight A-Life's Talk answers "busy". We wrap Talk.onPlayerText: when a group the fight
-- brain is running is fighting you and hears you, a demand rolls A-Life's own odds plus their mood:
--   pushing = no chance, steady = little, careful = some, falling back = good, running = best.
-- Yes: A-Life's own surrender (TalkOrders.surrenderCrew); "drop it" also drops their guns on the floor (A-Life's
-- disarm). The give-up then goes on as any give-up (captives, feint for criminals if that's on).
-- No: they shout back, nothing else (they're already fighting you). One try per group every fightTalkGapMs.
-- Never at home. Words: ours below plus A-Life's typed intents (HANDS_UP, STOP_FREEZE, DROP_WEAPON).
-- AI on (SP): their answer in their own voice (bridge react mode "standoff"), the fixed line if late.
-- Server / SP (where A-Life's Talk runs). Every number is a setting.
require "ALifeNPCOverhaul/ALifeFightBrain"

ALifeFightTalk = ALifeFightTalk or {}
local F = ALifeFightTalk
local B = ALifeFightBrain
local TAG = "[ALifeFightTalk]"
F.VERSION = "0.8.11.1"
F.metrics = F.metrics or { heard = 0, tried = 0, yes = 0, no = 0, home = 0, gap = 0, voiced = 0 }
F.pending = F.pending or {}

F.DEFAULTS = {
    fightTalk = true,           -- you can talk a losing group into giving up mid-fight
    fightTalkPush = -100,       -- odds shift by their mood (added to A-Life's own order odds), pushing
    fightTalkSteady = -40,      -- ... fighting steady
    fightTalkCareful = -15,     -- ... careful
    fightTalkFallBack = 10,     -- ... falling back
    fightTalkBreak = 25,        -- ... running
    fightTalkMax = 90,          -- odds never above this (%)
    fightTalkReach = 12,        -- tiles they hear you say it
    fightTalkShoutReach = 25,   -- tiles they hear you shout it
    fightTalkGapMs = 8000,      -- ms between tries on one group
    fightTalkVoiceMs = 2500,    -- AI on: wait this long for their answer in their own voice (ms)
}
F.FILE_KEYS = {}
for k in pairs(F.DEFAULTS) do F.FILE_KEYS[#F.FILE_KEYS + 1] = k end
table.sort(F.FILE_KEYS)
F.MOOD_KEY = { push = "fightTalkPush", steady = "fightTalkSteady", careful = "fightTalkCareful", fallback = "fightTalkFallBack", ["break"] = "fightTalkBreak" }

-- what you said -> A-Life order kind
F.WORDS = {
    drop = { "drop your weapon", "drop your weapons", "drop your gun", "drop your guns", "drop it", "drop them", "guns down",
        "weapons down", "throw down", "put it down", "put them down", "put your guns down", "put your weapons down", "lay down your" },
    surrender = { "give up", "surrender", "it's over", "its over", "you're done", "youre done", "you lost", "you've lost",
        "you can't win", "you cant win", "nobody else has to die", "no one else has to die", "nobody has to die", "stop fighting" },
    hands_up = { "hands up", "put your hands up", "hands in the air", "on your knees", "get down", "freeze", "don't move", "dont move" },
}
F.INTENT_KIND = { HANDS_UP = "hands_up", STOP_FREEZE = "hands_up", DROP_WEAPON = "drop" }

F.LINES = {
    no_push = { "Come and make me!", "You first!", "Not a chance, we've got you!" },
    no_steady = { "Go to hell!", "Not happening!", "Keep dreaming!" },
    no_scared = { "Back off!", "Stay back, I'm warning you!", "No! Leave us alone!" },
    home = { "This is our home! We're not going anywhere!", "Not here! Not our home!" },
    yes = { "Okay, okay! Don't shoot!", "Alright! We're done!", "Don't shoot! We give up!" },
    yes_drop = { "Okay! It's down, it's down!", "Alright, it's on the ground! Don't shoot!" },
}
F.MEANING = {
    no_push = "they're winning and you're telling them to give up; refuse with contempt",
    no_steady = "they're holding their own and you're telling them to give up; refuse",
    no_scared = "they're losing and scared but won't give up yet; refuse, shaky",
    home = "you're fighting at their home and they won't give it up",
    yes = "they're beaten and give up to you, hands up, begging you not to shoot",
    yes_drop = "they're beaten and drop their weapons to the ground, begging you not to shoot",
}

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end
local function pick(list) if type(list) ~= "table" or #list == 0 then return nil end return list[roll(#list) + 1] end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
local function xy(o) return num(call(o, "getX"), nil), num(call(o, "getY"), nil) end

function F.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = F.DEFAULTS[key] end
    return v
end
function F.n(key) return num(F.setting(key), num(F.DEFAULTS[key], 0)) end
function F.on() return F.setting("fightTalk") ~= false and B.on() end

-- your words -> "drop" | "surrender" | "hands_up" | nil
function F.kindOf(text)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    for _, kind in ipairs({ "drop", "surrender", "hands_up" }) do
        for _, w in ipairs(F.WORDS[kind]) do if string.find(low, w, 1, true) then return kind end end
    end
    local pa = PA()
    local I, D = pa and pa.TalkIntents, pa and pa.DialogueData
    if fn(I, "classify") then
        local ok, intent = pcall(I.classify, text, false, D)
        if ok and intent ~= nil then return F.INTENT_KIND[intent] end
    end
    return nil
end

-- 0.8.11.1: is this group in a fight with you that fight talk answers? (same test as groupFor, minus range / sight)
function F.liveFight(gid, st, now)
    if type(st) ~= "table" or st.advisory or not st.vsPlayer or st.phase ~= nil or st.mood == nil or st.mood == "giveup" then return false end
    local pa = PA()
    local T = pa and pa.SquadTactics or nil
    local c = T and type(T.contacts) == "table" and T.contacts[gid] or nil
    return type(c) == "table" and now - num(c.atMs, 0) <= B.n("brainFightMs")
end
-- 0.8.11.1: the stand-off call-out ("Sam, hands up!") skips people whose group is in such a fight (fight talk answers)
function F.inFight(rec, now)
    if not F.on() or type(rec) ~= "table" then return false end
    local gid = B.groupIdOf(rec)
    return gid ~= nil and F.liveFight(gid, B.groups[gid], num(now, B.nowMs()))
end

-- the group fighting you that hears you (nearest member who hears and sees you). Returns gid, st, member, facts
function F.groupFor(player, loud, now)
    local px, py = xy(player)
    if px == nil then return nil end
    local reach = loud and F.n("fightTalkShoutReach") or F.n("fightTalkReach")
    local pa = PA()
    local T = pa and pa.SquadTactics or nil
    local contacts = T and type(T.contacts) == "table" and T.contacts or {}
    local best, bd = nil, reach * reach
    for gid, st in pairs(B.groups) do
        local c = contacts[gid]
        if F.liveFight(gid, st, now) then
            local f = B.facts(gid, c, st, now)
            for _, m in ipairs(f and f.list or {}) do
                local x, y = xy(m.shell)
                local down = type(m.actor) == "table" and type(m.actor.memory) == "table" and type(m.actor.memory.injury) == "table" and m.actor.memory.injury.s == "down"
                if x ~= nil and not down then
                    local dd = (x - px) ^ 2 + (y - py) ^ 2
                    if dd <= bd and B.sees(player, m.shell, m.actor) then best, bd = { gid = gid, st = st, m = m, f = f }, dd end
                end
            end
        end
    end
    if best == nil then return nil end
    return best.gid, best.st, best.m, best.f
end

-- odds: A-Life's own order odds for this person + mood shift, capped
function F.chance(kind, st, m, player)
    local pa = PA()
    local O = pa and pa.TalkOrders or nil
    local base = 30
    if fn(O, "chanceFor") then
        local ctx = nil
        if fn(O, "memberContext") then local ok, c = pcall(O.memberContext, { record = m.actor, shell = m.shell }, player); if ok then ctx = c end end
        local ok, c = pcall(O.chanceFor, kind, m.actor, m.shell, player, ctx)
        if ok and tonumber(c) then base = tonumber(c) end
    end
    local key = F.MOOD_KEY[st.mood]
    local shift = key and F.n(key) or -100
    local c = base + shift
    if c > F.n("fightTalkMax") then c = F.n("fightTalkMax") end
    if c < 0 then c = 0 end
    return math.floor(c + 0.5), base
end

-- their answer: AI voice when up (SP), else the fixed line
function F.aiReady()
    local P = ALifeStandoffPlus
    return fn(P, "aiReady") and P.aiReady() == true
end
function F.show(shell, player, rec, text)
    if shell == nil or type(text) ~= "string" then return false end
    local m = ALifeLLMTalk
    if type(m) == "table" and fn(m, "say") then return pcall(m.say, shell, player, text, { record = rec, combat = true }) end
    return B.say(shell, text)
end
function F.answer(m, player, key)
    local text = pick(F.LINES[key])
    if text == nil then return nil end
    if F.aiReady() then
        local M = ALifeLLMTalk
        local now = B.nowMs()
        local job = { shell = m.shell, player = player, rec = m.actor, text = text, deadline = now + F.n("fightTalkVoiceMs") }
        F.pending[#F.pending + 1] = job
        local ok = pcall(M.submit, { mode = "fighttalk", uid = tostring(m.uid or (type(m.actor) == "table" and m.actor.uid) or ""), player = player,
            listener = { record = m.actor, shell = m.shell },
            react = { what = "A gunfight; the person you're fighting just yelled at you to give up. Say this, in your own words: " .. tostring(F.MEANING[key]),
                style = "shouted, short, in character; what they'd say: \"" .. text .. "\"", maxWords = 12 },
            startMs = now, depth = 0, ftJob = job })
        if ok then F.metrics.voiced = F.metrics.voiced + 1; return text end
        job.shown = true
    end
    F.show(m.shell, player, m.actor, text)
    return text
end
function F.onAi(job, r)
    if type(job) ~= "table" or job.shown then return end
    job.shown = true
    local text = type(r) == "table" and type(r.text) == "string" and r.text ~= "" and r.text or job.text
    F.show(job.shell, job.player, job.rec, text)
end
function F.tick(now)
    for i = #F.pending, 1, -1 do
        local j = F.pending[i]
        if j.shown then table.remove(F.pending, i)
        elseif now >= j.deadline then j.shown = true; F.show(j.shell, j.player, j.rec, j.text); table.remove(F.pending, i) end
    end
end

-- a player said something. true = it was for a fight (handled here)
function F.handle(player, text, loud, now)
    if not F.on() or not B.authoritative() then return false end
    local kind = F.kindOf(text)
    if kind == nil then return false end
    now = num(now, B.nowMs())
    local gid, st, m, f = F.groupFor(player, loud == true, now)
    if gid == nil then return false end
    F.metrics.heard = F.metrics.heard + 1
    if now < num(st.talkAtMs, 0) then F.metrics.gap = F.metrics.gap + 1; return true end
    st.talkAtMs = now + F.n("fightTalkGapMs")
    if f.home then
        F.metrics.home = F.metrics.home + 1
        F.answer(m, player, "home")
        return true
    end
    F.metrics.tried = F.metrics.tried + 1
    local chance, base = F.chance(kind, st, m, player)
    local r = roll(100)
    local pa = PA()
    local O = pa and pa.TalkOrders or nil
    if r < chance and fn(O, "surrenderCrew") then
        local ok, any = pcall(O.surrenderCrew, m.actor, m.shell, player, now, kind)
        if ok and any == true then
            if kind == "drop" and fn(O, "crew") and fn(O, "disarm") then
                local okC, crew = pcall(O.crew, m.actor, m.shell)
                for _, mem in ipairs(okC and crew or {}) do pcall(O.disarm, mem.shell) end
            end
            st.mood, st.sinceMs, st.surrendered, st.giveUpRolled, st.talkedDown = "giveup", now, true, true, true
            B.metrics.gaveUp = B.metrics.gaveUp + 1
            F.metrics.yes = F.metrics.yes + 1
            log("group " .. tostring(gid) .. " talked into giving up (" .. kind .. ", odds " .. chance .. "%, A-Life " .. base .. "%)")
            F.answer(m, player, kind == "drop" and "yes_drop" or "yes")
            if type(ALifeDropLoot) == "table" and fn(ALifeDropLoot, "onGiveUp") then pcall(ALifeDropLoot.onGiveUp, gid, st, f, now) end
            return true
        end
    end
    F.metrics.no = F.metrics.no + 1
    local key = (st.mood == "push") and "no_push" or ((st.mood == "steady") and "no_steady" or "no_scared")
    F.answer(m, player, key)
    log("group " .. tostring(gid) .. " won't give up (" .. tostring(st.mood) .. ", odds " .. chance .. "%)")
    return true
end

-- wrap A-Life's Talk.onPlayerText (server/ file: hook late). Ours first; not ours -> A-Life's, unchanged.
function F.hook()
    if F.hooked then return true end
    local pa = PA()
    local T = pa and pa.Talk or nil
    if not fn(T, "onPlayerText") then return false end
    if T.onPlayerText_ALifeFightTalk == nil then
        local orig = T.onPlayerText
        T.onPlayerText = function(player, text, loud, ...)
            local ok, done = pcall(F.handle, player, text, loud)
            if not ok and not F.failLogged then F.failLogged = true; log("failed (once): " .. tostring(done)) end
            if ok and done == true then return true, "fight_talk" end
            return orig(player, text, loud, ...)
        end
        T.onPlayerText_ALifeFightTalk = orig
    end
    F.hooked = true
    log("hooked ProjectALife.Talk.onPlayerText")
    return true
end
F.tries = F.tries or 0
function F.tryHook()
    if F.hooked or F.gaveUp then return end
    F.tries = F.tries + 1
    if F.hook() then return end
    if F.tries >= 600 then
        F.gaveUp = true
        if not (type(isClient) == "function" and isClient()) then log("A-Life Talk.onPlayerText not found: talking them down off") end
    end
end
F.tryHook()
if type(Events) == "table" and Events.OnTick ~= nil then
    Events.OnTick.Add(function()
        if not F.hooked and not F.gaveUp then F.tryHook() end
        if #F.pending > 0 then pcall(F.tick, B.nowMs()) end
    end)
end
print(TAG .. " ready v" .. F.VERSION .. ": talk a losing group into giving up mid-fight (setting fightTalk), hook " .. (F.hooked and "on" or "waiting"))

return F
