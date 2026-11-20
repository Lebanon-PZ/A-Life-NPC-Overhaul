-- A-Life NPC Overhaul pre-1.0: FISTFIGHTS (docs/PLAN-RIM.md #10). Two people at your camp who can't stand each other
-- (their bond <= fistPair), one of them fed up (unrest >= fistAt): now and then it comes to blows.
-- Hourly, one fight at a time, a pair at most once every fistGapDays, chance fistChance %.
--   * They walk at each other, shout, then trade punches and shoves (A-Life's own combat_punch / shove / hit_react
--     animations) for a few rounds. Fists only: no weapons, no real wounds (A-Life's hostile stance is never used, so
--     nobody gets killed over a grudge).
--   * A card: Let them / Break it up. Let them: it gets it out of their system (both unrest -fistRelief) but the bond
--     sours more. Break it up: no relief, both a little sour with you for stepping in.
--   * Letter, chronicle, the camp's day log. Whoever had the worse of it says so.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeFistfight") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeFistfight = ALifeFistfight or {}
local F = ALifeFistfight
local TAG = "[ALifeFistfight]"
F.VERSION = "pre-1.0"
F.DEFAULTS = {
    fist = true,         -- camp rivals can come to blows
    fistPair = -30,      -- how bad their bond must be (-100..100 inside)
    fistAt = 35,         -- how fed up one of them must be (unrest 0-100 inside)
    fistChance = 5,      -- % a game hour for such a pair
    fistGapDays = 4,     -- days at least between two fights of the same pair
    fistRounds = 6,      -- punches / shoves before it ends
    fistRelief = 15,     -- how much better they feel after (if you let them)
}
K.reg(F.DEFAULTS, {
    { "fist", "Camp: rivals at your camp come to blows now and then (fists only)" },
    { "fistChance", "Fistfights: chance each hour for a pair that's there (%)", { 2, 3, 5, 8, 12 } },
    { "fistAt", "Fistfights: how fed up one of them must be", { 20, 30, 35, 45, 55 } },
    { "fistPair", "Fistfights: how bad their bond must be", { -60, -45, -30, -20 } },
    { "fistGapDays", "Fistfights: days at least between two of the same pair", { 1, 2, 4, 7, 14 } },
    { "fistRounds", "Fistfights: punches and shoves before it ends", { 3, 4, 6, 8, 10 } },
    { "fistRelief", "Fistfights: how much better they feel after", { 5, 10, 15, 25 } },
}, "Your camp and base")
F.stats = { started = 0, finished = 0, brokenUp = 0, rounds = 0 }
local function set(k) return K.set(F.DEFAULTS, k) end
local function num(k) return K.num(F.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function F.on() return set("fist") ~= false end
function F.store() local s = K.bucket("rimFistfight"); s.last = type(s.last) == "table" and s.last or {}; return s end
local function pairKey(a, b) a, b = tostring(a), tostring(b); if a < b then return a .. "|" .. b end; return b .. "|" .. a end
function F.current() local f = F.store().fight; if type(f) == "table" then return f end; return nil end
function F.inFight(uid) local f = F.current(); return f ~= nil and (f.a == tostring(uid) or f.b == tostring(uid)) end
local function busy(uid) return type(ALifeBreaks) == "table" and K.fn(ALifeBreaks, "active") and ALifeBreaks.active(uid) ~= nil end

-- the pair that's about to go at it, or nil
function F.findPair(player)
    local people = K.people(player)
    local s = F.store()
    local h = K.hours()
    for i = 1, #people do
        for j = i + 1, #people do
            local a, b = people[i], people[j]
            if not busy(a) and not busy(b) then
                local worst = math.min(K.pairS(a, b), K.pairS(b, a))
                local fed = math.max(K.unrest(a), K.unrest(b))
                if worst <= num("fistPair") and fed >= num("fistAt") and h - (tonumber(s.last[pairKey(a, b)]) or -1e9) >= num("fistGapDays") * 24 then
                    return a, b
                end
            end
        end
    end
    return nil
end
function F.start(a, b, player)
    local s = F.store()
    if F.current() then return false end
    a, b = tostring(a), tostring(b)
    s.fight = { a = a, b = b, h = K.hours(), rounds = 0 }
    s.last[pairKey(a, b)] = K.hours()
    F.stats.started = F.stats.started + 1
    local na, nb = K.first(a), K.first(b)
    K.say(a, ({ "That's it. I've had it with you!", "Say that again. Go on.", "You want to do this? Let's do this." })[(K.hash(a .. K.day()) % 3) + 1])
    K.campLog("fight", na .. " and " .. nb .. " came to blows")
    log(na .. " vs " .. nb)
    local carded = K.card({ id = "fist:" .. pairKey(a, b), title = na .. " and " .. nb .. " are fighting", default = 1,
        text = na .. " and " .. nb .. " have finally gone for each other. Fists, so far. <LINE> <LINE> Letting it play out might clear the air. Stepping in stops it, but neither will thank you.",
        choices = {
            { label = "Let them", fn = function() end },
            { label = "Break it up", fn = function() F.breakUp(player) end },
        } })
    if not carded then K.letter(na .. " and " .. nb .. " are fighting.", 230, 150, 110) end
    return true
end
-- you step in
function F.breakUp(player)
    local f = F.current()
    if f == nil then return false end
    F.store().fight = nil
    F.stats.brokenUp = F.stats.brokenUp + 1
    K.opinion(f.a, player, -2, "stopped my fight")
    K.opinion(f.b, player, -2, "stopped my fight")
    K.pairBump(f.a, f.b, -5, "we fought and got pulled apart")
    K.pairBump(f.b, f.a, -5, "we fought and got pulled apart")
    K.say(f.a, "Fine. This isn't over.")
    K.chron(K.first(f.a) .. " and " .. K.first(f.b) .. " fought until someone pulled them apart", K.first(f.a))
    return true
end
-- who had the worse of it: brave / volatile / a stable roll
local function grit(uid)
    local l = K.lens(uid)
    return (tonumber(l.brave) or 0) + (tonumber(l.volatile) or 0) * 0.5 - (tonumber(l.fearful) or 0) + (K.hash(uid .. "#grit") % 100) / 100
end
function F.finish()
    local f = F.current()
    if f == nil then return false end
    F.store().fight = nil
    F.stats.finished = F.stats.finished + 1
    local relief = num("fistRelief")
    K.addUnrest(f.a, -relief)
    K.addUnrest(f.b, -relief)
    K.pairBump(f.a, f.b, -10, "we came to blows")
    K.pairBump(f.b, f.a, -10, "we came to blows")
    local winner, loser = f.a, f.b
    if grit(f.b) > grit(f.a) then winner, loser = f.b, f.a end
    K.say(loser, ({ "...Alright. Alright, enough.", "Get off me! Fine!", "You got lucky." })[(K.hash(loser) % 3) + 1])
    K.say(winner, ({ "Stay down.", "Don't ever talk to me like that again.", "We're done here." })[(K.hash(winner) % 3) + 1])
    local text = K.first(f.a) .. " and " .. K.first(f.b) .. " had it out with their fists. " .. K.first(loser) .. " got the worse of it."
    K.letter(text, 220, 170, 130)
    K.chron(text, K.first(winner))
    K.mem(f.a, "Fought " .. K.first(f.b) .. " at camp")
    K.mem(f.b, "Fought " .. K.first(f.a) .. " at camp")
    return true
end
function F.hourly(player, h)
    if not F.on() or player == nil then return 0 end
    local f = F.current()
    if f then
        if K.hours() - (tonumber(f.h) or 0) > 1 then F.finish() end -- an hour on: it's over one way or another
        return 0
    end
    local a, b = F.findPair(player)
    if a and K.chance(num("fistChance")) then return F.start(a, b, player) and 1 or 0 end
    return 0
end
F.ANIMS = { "combat_punch_a", "shove_default", "combat_punch_b", "hit_react", "combat_punch_c", "shove_default" }
F.JOB = {
    kind = "rim_fist", order = -2.8,
    pick = function(uid, shell, player, b, now)
        if not F.on() or not F.inFight(uid) then return nil end
        return { key = "fist:" .. tostring(uid), uid = tostring(uid), anim = "shout" }
    end,
    spot = function(j)
        local f = F.current()
        if f == nil then return nil end
        local other = (f.a == j.uid) and f.b or f.a
        local x, y, z = K.pos(K.shell(other))
        if x == nil then return nil end
        return { x = math.floor(x), y = math.floor(y), z = z or 0 }
    end,
    ms = function(j) return 1600 end,
    run = function(j, uid, shell, player)
        local f = F.current()
        if f == nil then return "done" end
        if f.a == tostring(uid) then -- one round per swing of the first one
            f.rounds = (f.rounds or 0) + 1
            F.stats.rounds = F.stats.rounds + 1
            if f.rounds >= num("fistRounds") then F.finish(); return "done" end
        end
        j.anim = F.ANIMS[((f.rounds or 0) + (f.a == tostring(uid) and 0 or 3)) % #F.ANIMS + 1]
        return "again"
    end,
}
function F.extra(req, player, listener)
    local uid = listener and listener.record and tostring(listener.record.uid) or nil
    if uid == nil or not F.inFight(uid) then return nil end
    return "You're in the middle of a fistfight with someone from camp. You're furious and out of breath."
end
function F.install()
    K.addJob(F.JOB)
    if not F._hourly then K.hourly(TAG, F.hourly); F._hourly = true end
    if not F._extra then K.addExtra(F.extra); F._extra = true end
    return 1
end
pcall(F.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        pcall(F.install)
        log("ready v" .. F.VERSION .. ": fistfights " .. (F.on() and "on" or "off") .. " (fists only, " .. num("fistChance") .. " %/h)")
    end)
end
return F
