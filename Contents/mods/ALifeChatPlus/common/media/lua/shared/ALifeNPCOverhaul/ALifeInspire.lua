-- A-Life NPC Overhaul pre-1.0: INSPIRATIONS (docs/PLAN-RIM.md #2). The flip side of a breakdown: someone at your camp
-- who's been content for days has one really good day.
-- Hourly: a calm streak counts up while their unrest stays <= inspCalmAt (it resets the moment it doesn't). Once the
-- streak reaches inspDays, once a day they roll inspChance %. What kind:
--   work  (they have a camp job)      : better at it (role fit +inspWork %) for inspHours
--   calm  (kind / cheerful, or no job): their mood rubs off: everyone else's unrest -inspEase once, and the camp
--                                       mood leans better while it lasts
-- A letter says it in words; they say a line. The streak starts over after.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeInspire") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeInspire = ALifeInspire or {}
local I = ALifeInspire
local TAG = "[ALifeInspire]"
I.VERSION = "pre-1.0"
I.DEFAULTS = {
    insp = true,        -- content people can have a really good day
    inspCalmAt = 5,     -- unrest at or under this counts as content (0-100 inside)
    inspDays = 2,       -- days content in a row before it can happen
    inspChance = 25,    -- % a day once they're there
    inspHours = 24,     -- game hours it lasts
    inspWork = 40,      -- % better at their camp job (work kind)
    inspEase = 10,      -- how much better everyone else feels (calm kind)
}
K.reg(I.DEFAULTS, {
    { "insp", "Camp: content people have a really good day now and then (inspired)" },
    { "inspDays", "Inspired: days content in a row first", { 1, 2, 3, 5, 7 } },
    { "inspChance", "Inspired: chance a day once there (%)", { 10, 15, 25, 40, 60 } },
    { "inspHours", "Inspired: game hours it lasts", { 8, 12, 24, 48 } },
    { "inspWork", "Inspired: % better at their camp job", { 20, 30, 40, 60, 80 } },
    { "inspEase", "Inspired: how much better everyone else feels (calm)", { 5, 10, 15, 25 } },
    { "inspCalmAt", "Inspired: how calm counts as content", { 0, 5, 10, 15 } },
}, "Your camp and base")
I.stats = { started = 0, work = 0, calm = 0 }
local function set(k) return K.set(I.DEFAULTS, k) end
local function num(k) return K.num(I.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function I.on() return set("insp") ~= false end
function I.store()
    local s = K.bucket("rimInspire")
    s.on = type(s.on) == "table" and s.on or {}
    s.streak = type(s.streak) == "table" and s.streak or {}
    s.rolled = type(s.rolled) == "table" and s.rolled or {}
    return s
end
function I.active(uid)
    local a = I.store().on[tostring(uid)]
    if type(a) ~= "table" then return nil end
    if K.hours() >= (tonumber(a.untilH) or 0) then I.store().on[tostring(uid)] = nil; return nil end
    return a
end
I.WORDS = {
    work = { letter = "%s is in a really good place today. It shows in their work.", line = { "I feel good today. Really good.", "Let's get things done.", "Funny. I actually feel like myself today." } },
    calm = { letter = "%s's good mood is rubbing off on everyone.", line = { "Hey. We're going to be okay, you know that?", "Come on, smile. We're still here.", "Good day today. Let's enjoy it." } },
}
function I.kindFor(uid)
    local l = K.lens(uid)
    local warm = (tonumber(l.kind) or 0) + (tonumber(l.cheerful) or 0)
    if K.roleOf(uid) == "general" then return "calm" end
    if warm >= 0.6 and K.rnd() < 0.5 then return "calm" end
    return "work"
end
function I.start(uid, kind, player)
    uid = tostring(uid)
    local s = I.store()
    if I.active(uid) then return false end
    kind = kind or I.kindFor(uid)
    s.on[uid] = { kind = kind, h = K.hours(), untilH = K.hours() + num("inspHours"), role = K.roleOf(uid) }
    s.streak[uid] = 0
    I.stats.started = I.stats.started + 1
    I.stats[kind] = (I.stats[kind] or 0) + 1
    if kind == "calm" then
        for _, o in ipairs(K.people(player)) do if o ~= uid then K.addUnrest(o, -num("inspEase")) end end
    end
    local name = K.first(uid)
    local w = I.WORDS[kind]
    K.letter(string.format(w.letter, name), 190, 220, 160)
    K.say(uid, w.line[(K.hash(uid .. K.day()) % #w.line) + 1])
    K.campLog("inspired", string.format(w.letter, name))
    K.mem(uid, "Had a really good day at camp")
    log(name .. " inspired: " .. kind)
    return true
end
function I.hourly(player, h)
    if not I.on() or player == nil then return 0 end
    local s = I.store()
    local day = K.day()
    local n = 0
    for _, uid in ipairs(K.people(player)) do
        local broke = type(ALifeBreaks) == "table" and K.fn(ALifeBreaks, "active") and ALifeBreaks.active(uid) ~= nil
        if K.unrest(uid) <= num("inspCalmAt") and not broke then s.streak[uid] = (tonumber(s.streak[uid]) or 0) + 1 else s.streak[uid] = 0 end
        if I.active(uid) == nil and s.streak[uid] >= num("inspDays") * 24 and s.rolled[uid] ~= day then
            s.rolled[uid] = day
            if K.chance(num("inspChance")) and I.start(uid, nil, player) then n = n + 1 end
        end
    end
    return n
end
-- calm: everyone else leans better while it lasts
function I.mood(uid)
    if not I.on() then return 0 end
    local s = I.store()
    for o, a in pairs(s.on) do
        if o ~= tostring(uid) and type(a) == "table" and a.kind == "calm" and K.hours() < (tonumber(a.untilH) or 0) then return -2 end
    end
    return 0
end
function I.hook()
    local M = K.M()
    if M == nil then return 0 end
    return K.wrap(M, "cpFit", "inspire:cpFit", function(orig)
        return function(uid, role, ...)
            local f = orig(uid, role, ...)
            if type(f) ~= "number" or not I.on() then return f end
            local a = I.active(uid)
            if a and a.kind == "work" and role == a.role then return f * (1 + num("inspWork") / 100) end
            return f
        end
    end) and 1 or 0
end
function I.extra(req, player, listener)
    local uid = listener and listener.record and tostring(listener.record.uid) or nil
    local a = uid and I.active(uid) or nil
    if a == nil then return nil end
    return "Today you're in a really good mood, energetic and warm (inspired)."
end
function I.install()
    local n = I.hook()
    if not I._mood then K.addMood(function(uid) return I.mood(uid) end); I._mood = true end
    if not I._extra then K.addExtra(I.extra); I._extra = true end
    if not I._hourly then K.hourly(TAG, I.hourly); I._hourly = true end
    return n
end
pcall(I.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(I.install)
        log("ready v" .. I.VERSION .. ": inspirations " .. (I.on() and "on" or "off") .. " (" .. tostring(ok and n or 0) .. "/1 camp hook)")
    end)
end
return I
