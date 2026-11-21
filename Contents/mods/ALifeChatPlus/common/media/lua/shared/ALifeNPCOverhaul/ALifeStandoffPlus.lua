-- A-Life NPC Overhaul 0.8.5: STAND-OFFS, built ON A-Life 1.5's ALifeStandoff.lua (never replacing it).
-- A-Life runs the stand-off (profiles, phases, answer kinds, outcomes, the "they asked" strip); we wrap it:
--   1. Voice (SP, AI on): every stand-off line in that NPC's own voice, in A-Life's order and with A-Life's meaning;
--      A-Life's own line if ours is later than standoffVoiceMs. Quick escalation lines (turn, betray) stay A-Life's.
--   2. Typed answers: words A-Life can't read ("talk") go to the AI, which says which answer kind they meant
--      (bridge 0.8.5 sokind); A-Life's own reading if the AI is late.
--   3. Lies checked against the world: "just me" with your people in view -> spotted (hidden, sneaking ones far off
--      aren't seen); "not much" with a full pack -> they take it anyway (outlaws) or don't believe you.
--   4. Memory (per crew and player, kept in the save): past lies / fights make them jumpier; paying before makes
--      them lean on you (a bigger toll, more shakedowns).
--   5. Your party's orders mid stand-off still go to your people (not taken as your answer): hold fire / lower
--      weapons calms it; a flank with the numbers makes them back off, without them it sets them off.
--   6. Calling for backup on the radio where they can hear it (or on a channel their walkie is on) sets outlaws and
--      rough crews off, makes law and military warn.
--   7. Your side's size and arms: outnumbered 2:1 (standoffOutnumber) they back down instead of turning, betray and
--      surprise less, and ask a smaller toll; outnumbering an unarmed you, they push harder.
--   8. Toll: A-Life's own robbery takes your most valuable things (its item worth); haggle it down (standoffHaggle %).
--  10. Call someone out yourself: "<their name>, stop right there / hands up / don't move" - only if you know their
--      name. They comply, back off or fight, by who they are and the odds.
--  12. Any direction: talk them down (calm), haggle, or - rarely, if they like you a lot - they lower arms and join.
-- Gate guard (9), NPC vs NPC stand-offs (11) and capture (13): see docs/PLAN-0.8.md.
-- Server-authoritative: the wraps run where A-Life's stand-off runs (server / SP). The AI parts are single-player only
-- (the bridge runs beside the SP game); in MP A-Life's own lines and word reading stay.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeStandoffPlus = ALifeStandoffPlus or {}
local P = ALifeStandoffPlus
local TAG = "[ALifeStandoffPlus]"
P.VERSION = ALifeSide.MOD_VERSION
P.metrics = P.metrics or { voiced = 0, late = 0, aiRead = 0, aiReadLate = 0, liesAlone = 0, liesLittle = 0, jumpy = 0, lean = 0,
    backDown = 0, pushed = 0, haggled = 0, haggleNo = 0, calmed = 0, partyOrders = 0, radioSetOff = 0, callOuts = 0, joinBoost = 0 }

P.DEFAULTS = {
    standoffPlus = true,        -- the whole 0.8.5 stand-off layer (off = A-Life's stand-offs exactly as they are)
    standoffVoice = true,       -- AI on: stand-off lines in their own voice
    standoffVoiceMs = 2500,     -- ... A-Life's line if ours isn't back this fast (ms)
    standoffTyped = true,       -- AI on: it reads what you typed when A-Life can't
    standoffLies = true,        -- lies are checked against what they can see
    standoffLieSight = 20,      -- tiles: your people this close (and not sneaking far off) give "just me" away
    standoffFullPack = 70,      -- % of what you can carry that makes "not much" a lie
    standoffMemory = true,      -- they remember past stand-offs with you
    standoffJumpy = 50,         -- % more likely to betray / jump you per past lie or fight (at most double)
    standoffLean = 1,           -- extra things taken per earlier toll you paid them (at most 2)
    standoffOdds = true,        -- your side's size and arms change how it goes
    standoffOutnumber = 2,      -- your side this many times theirs: they back down
    standoffTollCut = 1,        -- things fewer when they're outnumbered (and per good haggle)
    standoffHaggle = 50,        -- % a haggle works
    standoffRadioSetOff = true, -- calling for backup where they can hear it sets them off
    standoffCallOut = true,     -- you can call out someone whose name you know
    standoffJoin = true,        -- someone who likes you a lot may lower arms and join
    standoffJoinOpinion = 60,   -- ... this much
}
P.FILE_KEYS = {}
for k in pairs(P.DEFAULTS) do P.FILE_KEYS[#P.FILE_KEYS + 1] = k end
table.sort(P.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function S() local pa = PA(); return pa and pa.Standoff or nil end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end
local function pct(p) return roll(100) < num(p, 0) end

function P.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = P.DEFAULTS[key] end
    return v
end
function P.on() return P.setting("standoffPlus") ~= false end
function P.nowMs() if type(getTimestampMs) == "function" then return getTimestampMs() end return 0 end

-- ---------------------------------------------------------------------------------------------------- memory
function P.store()
    local d = nil
    if ModData ~= nil and fn(ModData, "getOrCreate") then
        local ok, t = pcall(ModData.getOrCreate, "ALifeChatPlus_Standoff")
        if ok then d = t end
    end
    if d == nil then P._mem = P._mem or {}; d = P._mem end
    if type(d.crews) ~= "table" then d.crews = {} end
    return d
end
function P.memOf(s)
    if type(s) ~= "table" or s.crewKey == nil or s.playerKey == nil then return {} end
    local k = tostring(s.crewKey) .. "|" .. tostring(s.playerKey)
    local m = P.store().crews[k]
    if type(m) ~= "table" then m = { lies = 0, fights = 0, paid = 0 }; P.store().crews[k] = m end
    return m
end
-- our per-stand-off state, keyed by A-Life's stand-off table itself (its id restarts at 1 after a reload)
P.live = P.live or setmetatable({}, { __mode = "k" })
function P.st(s)
    local x = P.live[s]
    if x == nil then x = { tollCut = 0 }; P.live[s] = x end
    return x
end
-- still running? (a finished or forgotten stand-off's late AI job is dropped, never shown)
function P.alive(s)
    local St = S()
    return type(s) == "table" and s.phase ~= "done" and (St == nil or type(St.active) ~= "table" or St.active[s.id] == s)
end

-- ---------------------------------------------------------------------------------------------------- the world
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
local function xy(o) return num(call(o, "getX"), nil), num(call(o, "getY"), nil) end
local function dist(a, b)
    local ax, ay = xy(a)
    local bx, by = xy(b)
    if ax == nil or bx == nil then return math.huge end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- your people near you: { uid, shell, armed, sneaking, d }
function P.party(player, reach)
    local out = {}
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "each") then return out end
    local key = nil
    if fn(pa.Speech, "playerKey") then local ok, k = pcall(pa.Speech.playerKey, player); if ok then key = k end end
    local mine = ALifeCommands
    pa.ActorRegistry.each(function(rec)
        if type(rec) == "table" and rec.lifecycle == "active" then
            local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(rec.uid) or nil
            if shell ~= nil and call(shell, "isDead") ~= true then
                local d = dist(shell, player)
                if d <= reach then
                    local own = false
                    if fn(mine, "isMine") then local ok, y = pcall(mine.isMine, tostring(rec.uid), player); own = ok and y == true
                    elseif fn(pa.Companions, "entry") then local ok, e = pcall(pa.Companions.entry, rec); own = ok and type(e) == "table" and e.owner == key end
                    if own then
                        local w = call(shell, "getPrimaryHandItem")
                        out[#out + 1] = { uid = tostring(rec.uid), shell = shell, d = d, armed = w ~= nil and call(w, "isRanged") == true,
                            sneaking = call(shell, "isSneaking") == true }
                    end
                end
            end
        end
        return false
    end)
    return out
end

-- can the crew see any of your people? (line of sight from A-Life's ModuleCareful when it's there)
function P.partySeen(s)
    local reach = num(P.setting("standoffLieSight"), 20)
    local careful = PA() and PA().ModuleCareful or nil
    local St = S()
    for _, m in ipairs(P.party(s.player, reach)) do
        if not (m.sneaking and m.d > 8) then
            for _, uid in ipairs(s.members or {}) do
                local shell = St and St.shellFor(uid) or nil
                if shell ~= nil then
                    local seen = true
                    if fn(careful, "lineOfSight") then local ok, v = pcall(careful.lineOfSight, shell, m.shell); seen = ok and v == true end
                    if seen then return true, m end
                end
            end
        end
    end
    return false, nil
end

-- is your pack full? (inventory weight vs what you can carry)
function P.packFull(player)
    local inv = call(player, "getInventory")
    local w = num(call(inv, "getCapacityWeight"), nil)
    local cap = num(call(player, "getMaxWeight"), nil)
    if w == nil or cap == nil or cap <= 0 then return false end
    return w / cap * 100 >= num(P.setting("standoffFullPack"), 70)
end

function P.playerArmed(player)
    local St = S()
    if St ~= nil and fn(St, "playerArmed") then return St.playerArmed(player) == true end
    return false
end

-- ---------------------------------------------------------------------------------------------------- lines
P.LINES = {
    lie_alone = { "Just you, huh? Then who's that?", "Alone? I can see your friend.", "Don't lie to me. I see them." },
    lie_little = { "Not much? Your pack says otherwise.", "Bag's full and you've got nothing? Sure.", "You're loaded down. Don't lie." },
    haggle_ok = { "Fine. Less, then. Don't push it.", "Alright. Half. Move." },
    haggle_no = { "No deal. Pay or turn around.", "That wasn't a question." },
    calm = { "Alright... alright. Easy.", "Okay. Nobody does anything stupid." },
    radio = { "Who're you calling?! Drop it!", "You calling your friends? Big mistake." },
    backdown = { "Okay, okay. We're going.", "Not worth it. We're leaving." },
    flank_off = { "Your friend's moving on us! That's it!", "Flanking us? Wrong move!" },
    co_comply = { "Okay! Okay. Easy. I'm not doing anything.", "Alright, alright. Hands where you can see them." },
    co_leave = { "Not my fight. I'm going.", "Whatever this is, I'm out." },
    co_fight = { "You picked the wrong one.", "Make me." },
    co_refuse = { "I don't take orders from you.", "Who do you think you are?" },
}
function P.line(key)
    local l = P.LINES[key]
    if type(l) ~= "table" then return nil end
    return l[roll(#l) + 1]
end

-- what A-Life's stand-off lines mean (so our voice says the same thing in their words)
P.MEANING = {
    ENC_SURPRISE = "you just spotted a stranger and have your weapon on them; tell them to stop right there",
    ENC_REVENGE = "you found the person who wronged you; threaten them",
    ENC_AGAIN = "you met this person before and it went fine; tell them to keep moving",
    ENC_CALLOUT = "someone is hiding in a building; call them out where you can see them",
    ENC_BASE_CALLOUT = "you're outside their place; call whoever's inside to come out",
    ENC_CALLOUT_REPEAT = "they still haven't come out; call again, impatient",
    ENC_ASK_WHO = "ask who they are", ENC_ASK_INTENT = "ask what they want around here",
    ENC_ASK_HOWMANY = "ask how many of them there are", ENC_ASK_CARRY = "ask what they're carrying",
    ENC_DEMAND_DROP = "tell them to drop their weapon, now", ENC_DEMAND_LEAVE = "tell them to leave",
    ENC_DEMAND_TOLL = "demand a toll for passing", ENC_SILENCE = "they didn't answer; demand an answer",
    ENC_SILENCE_LAST = "last warning: answer or else", ENC_WALK_AWAY = "they're walking away; tell them to stop",
    ENC_REPLY_OK = "you accept their answer, still wary", ENC_REPLY_DOUBT = "you don't believe them",
    ENC_NO_FLANKER = "they say someone's flanking; deny it", ENC_JOIN_NO = "turn down their offer to join you",
    ENC_JOIN_YES = "accept them joining you", ENC_PART = "let them go their way", ENC_LEAVE = "back off and leave",
    ENC_PAID = "they paid; tell them to move along", ENC_COME_OUT = "tell them to come out", ENC_CAME_OUT = "they came out; keep them covered",
    ENC_STALL = "stall them while a friend moves around their side", ENC_CAUGHT = "your friend got spotted; back off",
    ENC_WARNING_SHOT = "you fire a warning shot; last warning",
}
P.ANSWERS = {
    { id = "alone", label = "says they're alone" }, { id = "group", label = "says there are more of them" },
    { id = "passing", label = "just passing through, no trouble" }, { id = "little", label = "says they carry little or nothing" },
    { id = "pay", label = "agrees to pay / hand things over" }, { id = "comply", label = "does what you said (weapon down)" },
    { id = "leave", label = "says they'll leave" }, { id = "refuse", label = "refuses, insults or threatens you" },
    { id = "join", label = "asks to join you" }, { id = "flanker", label = "says they see your friend sneaking around" },
    { id = "haggle", label = "tries to pay less or offers something else" }, { id = "calm", label = "tries to talk you down, calm, reasonable" },
    { id = "yes", label = "just yes" }, { id = "no", label = "just no" },
}
P.ANSWER_OK = {}
for _, a in ipairs(P.ANSWERS) do P.ANSWER_OK[a.id] = true end

-- ---------------------------------------------------------------------------------------------------- the AI (SP)
local function M() return type(ALifeLLMTalk) == "table" and ALifeLLMTalk or nil end
function P.aiReady()
    local m = M()
    if m == nil or not fn(m, "isSP") or not ((fn(m, "aiHere") and m.aiHere()) or m.isSP()) or not fn(m, "submit") or not fn(m, "bridgeAlive") then return false end -- pre-1.0 MP: the server asks a player's bridge (relay)
    if type(m.settings) == "table" and m.settings.enabled == false then return false end
    return m.bridgeAlive(P.nowMs()) == true
end
P.pending = P.pending or {} -- AI jobs waiting: { s, uid, event, text, deadline, shown, kind = "say" | "read" }

-- show a line over their head (A-Life's own speech path, through the mod's M.say when it's there)
function P.show(s, uid, text)
    local St = S()
    local shell = St and St.shellFor(uid) or nil
    if shell == nil or type(text) ~= "string" or text == "" then return false end
    local m = M()
    if m ~= nil and fn(m, "say") then
        local rec = St.read(uid)
        return pcall(m.say, shell, s.player, text, { record = rec, combat = true })
    end
    local sp = PA() and PA().Speech
    if fn(sp, "say") then return pcall(sp.say, shell, text, {}) end
    return false
end

-- after a line is "said": A-Life's own bookkeeping (Standoff.say's tail), so the stand-off flows the same
function P.afterSay(s, uid, text)
    local St = S()
    s.lastLine = text
    if fn(St, "noteLine") then pcall(St.noteLine, s, uid, text) end
    if fn(St, "relay") then pcall(St.relay, s, text) end
    local talk = PA() and PA().Talk
    if fn(talk, "issueOrder") and fn(St, "orderTtl") then pcall(talk.issueOrder, s.player, uid, "standoff", St.orderTtl(s, P.nowMs())) end
end

-- a line of ours in a stand-off (lies spotted, haggling...): voiced when the AI is up, else the fixed line
function P.sayOwn(s, uid, key, meaning)
    local text = P.line(key)
    if text == nil then return nil end
    P.afterSay(s, uid, text)
    if not P.voice(s, uid, meaning or key, text) then P.show(s, uid, text) end
    return text
end

-- ask the AI for this line; the fixed one goes out when time's up
function P.voice(s, uid, meaning, fallback)
    if P.setting("standoffVoice") == false or not P.aiReady() then return false end
    local St, m = S(), M()
    local rec, shell = St.read(uid), St.shellFor(uid)
    if rec == nil or shell == nil then return false end
    -- one line at a time, in A-Life's order: anything still waiting goes out now
    for _, j in ipairs(P.pending) do if j.s == s and j.kind == "say" and not j.shown then j.shown = true; P.show(s, j.uid, j.text) end end
    local now = P.nowMs()
    local job = { kind = "say", s = s, uid = uid, text = fallback, deadline = now + num(P.setting("standoffVoiceMs"), 2500) }
    P.pending[#P.pending + 1] = job
    local ok = pcall(m.submit, { mode = "standoff", uid = tostring(uid), player = s.player, listener = { record = rec, shell = shell },
        react = { what = "A tense stand-off; you and yours have weapons ready. Say this, in your own words: " .. tostring(meaning),
            style = "clipped, tense, in character; what they'd say: \"" .. tostring(fallback) .. "\"", maxWords = 14 },
        startMs = now, depth = 0, soJob = job })
    if not ok then job.shown = true; P.show(s, uid, fallback) end
    P.metrics.voiced = P.metrics.voiced + 1
    return true
end

-- what you typed, read by the AI: the kind comes back as sokind
function P.read(s, text, now)
    if P.setting("standoffTyped") == false or not P.aiReady() then return false end
    local St, m = S(), M()
    local uid = s.leaderUid
    local rec, shell = St.read(uid), St.shellFor(uid)
    if rec == nil or shell == nil then return false end
    local waitMs = fn(St, "waitMs") and St.waitMs(now) or 6000
    local job = { kind = "read", s = s, uid = uid, said = text, deadline = now + math.max(1500, waitMs - 1500), question = s.pending }
    P.pending[#P.pending + 1] = job
    local ok = pcall(m.submit, { mode = "standoff", uid = tostring(uid), player = s.player, listener = { record = rec, shell = shell },
        react = { what = "A tense stand-off; you asked them: " .. tostring(P.MEANING[s.pending or ""] or "who they are") .. ". React in two or three words", maxWords = 4 },
        standoff = { said = text, kinds = P.ANSWERS }, startMs = now, depth = 0, soJob = job })
    if not ok then job.shown = true; return false end
    P.metrics.aiRead = P.metrics.aiRead + 1
    return true
end

-- the AI answered (client, SP): r.text, r.sokind
function P.onAi(job, r)
    if type(job) ~= "table" or job.shown then return end
    job.shown = true
    local s = job.s
    if not P.alive(s) then return end
    if job.kind == "say" then
        local text = type(r) == "table" and type(r.text) == "string" and r.text ~= "" and r.text or job.text
        P.show(s, job.uid, text)
        if text ~= job.text then
            s.lastLine = text
            local St = S()
            if fn(St, "closeAsk") and fn(St, "syncAsk") and s.askId ~= nil then
                pcall(St.closeAsk, s, "done")
                s.askedKind = nil
                pcall(St.syncAsk, s, P.nowMs())
            end
        end
        return
    end
    local kind = type(r) == "table" and type(r.sokind) == "string" and string.lower(r.sokind) or ""
    if not P.ANSWER_OK[kind] then kind = "talk" end
    P.answer(s, kind, P.nowMs())
end
function P.tick(now)
    now = now or P.nowMs()
    for i = #P.pending, 1, -1 do
        local j = P.pending[i]
        if j.shown then table.remove(P.pending, i)
        elseif now >= j.deadline then
            j.shown = true
            table.remove(P.pending, i)
            if not P.alive(j.s) then -- the stand-off is over: nothing to say any more
            elseif j.kind == "say" then P.metrics.late = P.metrics.late + 1; P.show(j.s, j.uid, j.text)
            else P.metrics.aiReadLate = P.metrics.aiReadLate + 1; P.answer(j.s, "talk", now) end
        end
    end
end

-- an answer, ours or A-Life's kind
function P.answer(s, kind, now)
    local St = S()
    if St == nil or s == nil or s.phase == "done" then return end
    pcall(St.answer, s, kind, now)
end

-- ---------------------------------------------------------------------------------------------------- the wraps
P.SKIP_VOICE = { ENC_TURN = true, ENC_BETRAY = true }
P.orig = P.orig or {}

function P.wrapSay(St)
    local orig = St.say
    P.orig.say = orig
    St.say = function(s, uid, event)
        if not P.on() or P.setting("standoffVoice") == false or P.SKIP_VOICE[event] or type(St.adapters.say) == "function"
                or not P.aiReady() or type(s) ~= "table" then
            return orig(s, uid, event)
        end
        -- A-Life's line, picked but not shown (EncounterScript.line: Speech.pick + render + remember)
        local script = PA().EncounterScript
        local rec, shell = St.read(uid), St.shellFor(uid)
        local text = nil
        if fn(script, "line") and rec ~= nil and shell ~= nil then
            local ok, t = pcall(script.line, rec, shell, s.player, event, nil)
            if ok then text = t end
        end
        if text == nil then return orig(s, uid, event) end
        if fn(script, "gesture") and type(script.gestures) == "table" then pcall(script.gesture, shell, script.gestures[event]) end
        P.afterSay(s, uid, text)
        if not P.voice(s, uid, P.MEANING[event] or "say something fitting", text) then P.show(s, uid, text) end
        return text
    end
end

function P.wrapStart(St)
    local orig = St.start
    P.orig.start = orig
    St.start = function(actor, shell, player, requested, extra, now)
        local s, why = orig(actor, shell, player, requested, extra, now)
        if s ~= nil and P.on() then pcall(P.shape, s, actor) end
        return s, why
    end
end

-- memory, odds, joining: the profile for THIS stand-off (a copy A-Life made for it)
function P.shape(s, actor)
    local pr = s.profile
    if type(pr) ~= "table" then return end
    local x = P.st(s)
    if P.setting("standoffMemory") ~= false then
        local mem = P.memOf(s)
        local bad = num(mem.lies, 0) + num(mem.fights, 0)
        if bad > 0 then
            local k = 1 + math.min(1, bad * num(P.setting("standoffJumpy"), 50) / 100)
            pr.betray, pr.surpriseAttack = num(pr.betray, 0) * k, num(pr.surpriseAttack, 0) * k
            P.metrics.jumpy = P.metrics.jumpy + 1
        end
        if num(mem.paid, 0) > 0 and pr.toll then
            x.tollCut = x.tollCut - math.min(2, num(mem.paid, 0) * num(P.setting("standoffLean"), 1))
            pr.shakedown = math.min(0.9, num(pr.shakedown, 0) + 0.1 * num(mem.paid, 0))
            P.metrics.lean = P.metrics.lean + 1
        end
    end
    if P.setting("standoffOdds") ~= false then
        local party = P.party(s.player, 25)
        local mine = #party + 1
        local theirs = math.max(1, #(s.members or {}))
        local armed = P.playerArmed(s.player)
        for _, m in ipairs(party) do if m.armed then armed = true end end
        x.mine, x.theirs = mine, theirs
        if mine >= num(P.setting("standoffOutnumber"), 2) * theirs and armed then
            x.outnumbered = true
            pr.betray, pr.surpriseAttack = num(pr.betray, 0) * 0.3, num(pr.surpriseAttack, 0) * 0.3
            for _, k in ipairs({ "refuse", "silence", "walkAway", "afterWarn" }) do if pr[k] == "turn" then pr[k] = "left" end end
            if pr.toll then x.tollCut = x.tollCut + num(P.setting("standoffTollCut"), 1) end
            P.metrics.backDown = P.metrics.backDown + 1
        elseif theirs >= 2 * mine and not armed then
            pr.betray, pr.surpriseAttack = math.min(1, num(pr.betray, 0) * 1.3), math.min(1, num(pr.surpriseAttack, 0) * 1.3)
            P.metrics.pushed = P.metrics.pushed + 1
        end
    end
    if P.setting("standoffJoin") ~= false and actor ~= nil then
        local O = PA().NpcOpinion
        if fn(O, "valueOf") then
            local ok, v = pcall(O.valueOf, actor, s.player)
            local need = num(P.setting("standoffJoinOpinion"), 60)
            if ok and num(v, 0) >= need then
                pr.join = math.min(0.5, num(pr.join, 0) + (num(v, 0) - need + 10) / 200)
                P.metrics.joinBoost = P.metrics.joinBoost + 1
            end
        end
    end
end

function P.wrapHandle(St)
    local orig = St.handle
    P.orig.handle = orig
    St.handle = function(s, kind, now, question)
        if not P.on() or type(s) ~= "table" then return orig(s, kind, now, question) end
        local x = P.st(s)
        if P.setting("standoffLies") ~= false then
            if kind == "alone" then
                local seen = P.partySeen(s)
                if seen then
                    P.metrics.liesAlone = P.metrics.liesAlone + 1
                    local mem = P.memOf(s); mem.lies = num(mem.lies, 0) + 1
                    P.sayOwn(s, s.leaderUid, "lie_alone", "they said they're alone, but you can see someone with them; call the lie")
                    return St.react(s, s.profile.refuse, now)
                end
            elseif kind == "little" and (question == "ENC_ASK_CARRY" or question == "ENC_DEMAND_TOLL") and P.packFull(s.player) then
                P.metrics.liesLittle = P.metrics.liesLittle + 1
                local mem = P.memOf(s); mem.lies = num(mem.lies, 0) + 1
                P.sayOwn(s, s.leaderUid, "lie_little", "they say they carry little, but their pack is stuffed; call the lie")
                if s.profile.toll then return St.outcome(s, "paid", now, true) end
                return St.react(s, s.profile.refuse, now)
            end
        end
        if kind == "haggle" then
            if question == "ENC_DEMAND_TOLL" and s.profile.toll then
                if not x.haggled and pct(P.setting("standoffHaggle")) then
                    x.haggled = true
                    x.tollCut = x.tollCut + num(P.setting("standoffTollCut"), 1)
                    P.metrics.haggled = P.metrics.haggled + 1
                    P.sayOwn(s, s.leaderUid, "haggle_ok", "they haggled; you take less, grudgingly")
                    return St.outcome(s, "paid", now, true)
                end
                P.metrics.haggleNo = P.metrics.haggleNo + 1
                P.sayOwn(s, s.leaderUid, "haggle_no", "they tried to haggle; no deal")
                if not x.haggled then x.haggled = true; table.insert(s.queue, 1, "ENC_DEMAND_TOLL"); return end
                return St.react(s, s.profile.refuse, now)
            end
            kind = "pay"
        elseif kind == "calm" then
            P.metrics.calmed = P.metrics.calmed + 1
            if s.betray and not s.flanking and roll(2) == 0 then s.betray = false end
            kind = "passing"
        end
        return orig(s, kind, now, question)
    end
end

function P.wrapRemember(St)
    local orig = St.remember
    P.orig.remember = orig
    St.remember = function(s, outcome, now)
        local r = orig(s, outcome, now)
        if P.on() and type(s) == "table" then
            local mem = P.memOf(s)
            if outcome == "fought" then mem.fights = num(mem.fights, 0) + 1 end
            if outcome == "paid" then
                mem.paid = num(mem.paid, 0) + 1
                -- the toll this time: A-Life's robbery takes its usual count, shifted by odds / haggling / leaning
                P.tollNext = P.tollNext or {}
                P.tollNext[tostring(s.crewKey) .. "|" .. tostring(s.playerKey)] = { cut = P.st(s).tollCut, at = num(now, 0) }
            end
            mem.at = num(now, 0)
            if outcome ~= nil and outcome ~= "paid" then P.live[s] = nil end
        end
        return r
    end
end

-- A-Life's toll is its robbery: it takes your most valuable things (its own item worth); we change how many
function P.wrapRobberyTake()
    local R = PA() and PA().ModuleRobbery
    if not fn(R, "take") or type(R.settings) ~= "table" or P.orig.take then return false end
    local orig = R.take
    P.orig.take = orig
    R.take = function(state)
        local adj = nil
        if P.on() and type(state) == "table" and type(P.tollNext) == "table" then
            local crew = type(state.crew) == "table" and state.crew.key or state.crewKey
            local k = tostring(crew) .. "|" .. tostring(state.playerKey)
            adj = P.tollNext[k]
            P.tollNext[k] = nil
        end
        if adj == nil or num(adj.cut, 0) == 0 then return orig(state) end
        local a, b = R.settings.itemsTaken, R.settings.itemsTakenBigCrew
        R.settings.itemsTaken = math.max(1, num(a, 3) - num(adj.cut, 0))
        R.settings.itemsTakenBigCrew = math.max(1, num(b, 4) - num(adj.cut, 0))
        local ok, taken = pcall(orig, state)
        R.settings.itemsTaken, R.settings.itemsTakenBigCrew = a, b
        if not ok then log("toll take failed: " .. tostring(taken)); return {} end
        return taken
    end
    return true
end

-- your words in a stand-off: party orders go to your people; free words the AI reads
function P.wrapWords(St)
    local orig = St.onPlayerWords
    P.orig.words = orig
    St.onPlayerWords = function(player, text, loud, now)
        if not P.on() then return orig(player, text, loud, now) end
        local s = fn(St, "stateFor") and St.stateFor(player) or nil
        if s == nil or s.phase == "done" or s.phase == "turning" then return orig(player, text, loud, now) end
        local order = P.partyOrder(text, player)
        if order ~= nil then
            P.metrics.partyOrders = P.metrics.partyOrders + 1
            pcall(P.onPartyOrder, s, order, num(now, P.nowMs()))
            return false -- not an answer: the mod's commands take it (A-Life's Talk goes on to the next handler)
        end
        local kind = fn(St, "kindOfWords") and St.kindOfWords(text) or "talk"
        if kind == "talk" and s.phase == "interrogate" then
            local near = false
            for _, uid in ipairs(s.members or {}) do
                if fn(St, "heard") and St.heard(s, player, uid, loud == true and St.shoutReach or St.answerReach) then
                    near = true
                    if fn(St, "noteFar") then St.noteFar(player, uid) end
                    break
                end
            end
            if near and P.read(s, text, num(now, P.nowMs())) then return true end
        end
        return orig(player, text, loud, now)
    end
end

-- an order to your own people? (the mod's command words: hold fire, lower weapons, flank, stay hidden ...)
P.ORDER_WORDS = {
    calm = { "hold fire", "don't shoot", "dont shoot", "lower your weapons", "lower weapons", "weapons down", "guns down", "stand down", "easy everyone" },
    flank = { "flank them", "flank left", "flank right", "go around", "get around them", "flank" },
    hide = { "stay hidden", "stay down", "keep hidden", "stay out of sight", "go dark" },
}
function P.partyOrder(text, player)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    for kind, words in pairs(P.ORDER_WORDS) do
        for _, w in ipairs(words) do
            if string.find(low, w, 1, true) then
                if #P.party(player, 30) > 0 then return kind end
                return nil
            end
        end
    end
    return nil
end
function P.onPartyOrder(s, order, now)
    local St = S()
    local x = P.st(s)
    if order == "calm" and not x.calmed then
        x.calmed = true
        s.profile.surpriseAttack = num(s.profile.surpriseAttack, 0) * 0.5
        s.profile.betray = num(s.profile.betray, 0) * 0.5
        if s.betray and not s.flanking and roll(2) == 0 then s.betray = false end
    elseif order == "flank" and not x.flanked then
        x.flanked = true
        local mine = #P.party(s.player, 30) + 1
        if mine >= #(s.members or {}) then
            P.sayOwn(s, s.leaderUid, "backdown", "their people are moving around you; you're outnumbered, so back off")
            St.outcome(s, "left", now, true)
        else
            P.sayOwn(s, s.leaderUid, "flank_off", "their friend is flanking you; you won't have it")
            St.turn(s, now, false, true)
        end
    end
end

-- calling on the radio where they can hear you (ALifeWalkie's hook): sets them off
function P.onRadioCall(player, args, res)
    if not P.on() or P.setting("standoffRadioSetOff") == false then return end
    local St = S()
    local s = St and fn(St, "stateFor") and St.stateFor(player) or nil
    if s == nil or s.phase == "done" or s.phase == "turning" then return end
    if args == nil or (args.kind ~= "help" and args.kind ~= "serious" and args.kind ~= "come") then return end
    local hears = false
    for _, uid in ipairs(s.members or {}) do
        if dist(St.shellFor(uid), player) <= num(St.answerReach, 14) then hears = true end
        for _, h in ipairs(type(res) == "table" and type(res.heardBy) == "table" and res.heardBy or {}) do if h.uid == uid then hears = true end end
    end
    if not hears then return end
    P.metrics.radioSetOff = P.metrics.radioSetOff + 1
    local now = P.nowMs()
    local voice = s.profile and s.profile.voice or "civilian"
    P.sayOwn(s, s.leaderUid, "radio", "they're calling for backup on the radio right in front of you")
    if voice == "outlaw" or voice == "rough" then return St.turn(s, now, false, true) end
    if voice == "law" or voice == "military" then return St.react(s, "warn", now) end
    return St.outcome(s, "left", now, true)
end

-- ---------------------------------------------------------------------------------------------------- call out (10)
P.CALLOUT_WORDS = { "stop right there", "hands up", "don't move", "dont move", "freeze", "drop it", "drop your weapon", "on your knees",
    "put your hands up", "hold it right there" }
function P.calledOut(text)
    local low = string.lower(tostring(text or ""))
    for _, w in ipairs(P.CALLOUT_WORDS) do if string.find(low, w, 1, true) then return true end end
    return false
end
-- { uid } (named in the words) -> they comply, back off, refuse or fight. Returns the outcome
function P.callOut(player, uid, now)
    if not P.on() or P.setting("standoffCallOut") == false then return nil end
    local pa = PA()
    local St = S()
    local rec = St and St.read(tostring(uid)) or nil
    local shell = St and St.shellFor(tostring(uid)) or nil
    if rec == nil or shell == nil or St == nil then return nil end
    local key = St.keyOf(player)
    if fn(pa.Names, "knows") then
        local ok, k = pcall(pa.Names.knows, rec, key)
        if ok and k ~= true then return "unknown" end
    end
    if dist(shell, player) > num(St.shoutReach, 25) then return "far" end
    -- 0.8.11.1: their group is in a gunfight with you: fight talk (ALifeFightTalk) answers, not a second call-out reply
    local FT = ALifeFightTalk
    if fn(FT, "inFight") then
        local ok, yes = pcall(FT.inFight, rec, now)
        if ok and yes then return "fighttalk" end
    end
    P.metrics.callOuts = P.metrics.callOuts + 1
    local pr = St.profileFor(rec)
    local voice = pr.voice or "civilian"
    local mine = #P.party(player, 25) + 1
    local theirs = #(St.crewOf(rec, shell) or {})
    local armed = P.playerArmed(player)
    local out
    if voice == "civilian" then out = (armed or mine > theirs) and "comply" or "leave"
    elseif voice == "law" or voice == "military" then out = (mine >= 2 * theirs and armed) and "comply" or "refuse"
    else
        if mine >= num(P.setting("standoffOutnumber"), 2) * theirs and armed then out = roll(2) == 0 and "comply" or "leave"
        elseif theirs > mine then out = "fight" else out = roll(3) == 0 and "fight" or "leave" end
    end
    local line = P.line("co_" .. out)
    local talk = pa.Talk
    if out == "comply" and fn(talk, "hold") then pcall(talk.hold, rec, shell, player, num(now, P.nowMs()), 20000) end
    if out == "fight" and fn(ALifeTalkPatch, "attackNow") then
        pcall(ALifeTalkPatch.attackNow, tostring(uid), player, "called out") -- the mod's own "straight to attacking"
    end
    if line ~= nil then
        local m = M()
        if m ~= nil and fn(m, "say") then pcall(m.say, shell, player, line, { record = rec })
        elseif fn(pa.Speech, "say") then pcall(pa.Speech.say, shell, line, {}) end
    end
    return out
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("standoffCallOut", function(player, args)
        if type(args) ~= "table" or type(args.uid) ~= "string" then return nil end
        return P.callOut(player, args.uid, P.nowMs())
    end)
end

-- ---------------------------------------------------------------------------------------------------- install
function P.install()
    if P.installed then return true end
    local St = S()
    if type(St) ~= "table" or not fn(St, "say") or not fn(St, "handle") or not fn(St, "start") then return false end
    if type(St.adapters) ~= "table" then St.adapters = {} end
    P.installed = true
    local n = 0
    for _, w in ipairs({ { "say", P.wrapSay }, { "start", P.wrapStart }, { "handle", P.wrapHandle }, { "remember", P.wrapRemember },
            { "onPlayerWords", P.wrapWords } }) do
        if fn(St, w[1]) then
            local ok, err = pcall(w[2], St)
            if ok then n = n + 1 else log("wrap " .. w[1] .. " failed: " .. tostring(err)) end
        end
    end
    if P.wrapRobberyTake() then n = n + 1 end
    if type(ALifeWalkie) == "table" then
        ALifeWalkie.afterCall = ALifeWalkie.afterCall or {}
        table.insert(ALifeWalkie.afterCall, function(player, args, res) pcall(P.onRadioCall, player, args, res) end)
    end
    log("ready v" .. P.VERSION .. ": " .. n .. "/6 hooks on A-Life's stand-offs (voice, typed answers, lies, memory, odds, toll, party orders, radio, call out)")
    return true
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() local ok, e = pcall(P.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(P.install) end) end
    if Events.OnTick ~= nil then Events.OnTick.Add(function() if #P.pending > 0 then pcall(P.tick) end end) end
end
