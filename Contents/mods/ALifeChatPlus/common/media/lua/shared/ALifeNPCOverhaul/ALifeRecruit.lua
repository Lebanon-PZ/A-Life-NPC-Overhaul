-- A-Life NPC Overhaul: recruiting the way people actually decide.
-- Jeem only lets someone move into your base once their group fully trusts you (standing "allied"). Real people
-- also come because they're starving, hurt, alone, scared of you, or because what you're offering is exactly what
-- they lack. This decides "will you come?" from all of it:
--   trust (A-Life's opinion of you), love / fear / need (Bonds), how outgunned they are (Situation),
--   their hunger, thirst, exhaustion, wounds, being alone or at night, and what your pitch offers them
--   ("we've got food, water, walls, a doctor"), minus pride (hardened types) and any harm you did them.
-- Two asks:
--   "Come with me / join us / come live with us"           -> they join your base now (Jeem's real recruit)
--   "Go to <place>, find me there, I've got a base"        -> they agree to head for your base on their own: a lower bar
--                                                            (they keep their freedom to look first); they set off now
-- Yes goes through Jeem's own recruit (beds, capacity, their crew comes too, their old faction notices), only past its
-- "allied" check. No gets a reason that fits why: "I don't know you", "my people", "not like this".
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeRecruit") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeRecruit]"
ALifeRecruit = ALifeRecruit or {}
local RC = ALifeRecruit
RC.JOIN_BAR, RC.MEET_BAR = 50, 15   -- "come check my place out" is an easy yes for anyone not against you
RC.approved = {}                -- uid -> true while Jeem's recruit runs for someone we said yes to

RC.INTENTS = {
    { id = "INVITE_BASE", kind = "meet", prio = 84,
      patterns = "find me at|find me in|find me there|meet me at|meet me in|meet me there|look for me at|look for me in|look for me there|come to my base|go to my base|head to my base|i have a base|ive got a base|i got a base|we have a base|weve got a base|come find me|come to my place|go to my place|my camp is|my base is|come to our base|head to our base|our base is" },
}
RC.JOIN_IDS = { COME_WITH_ME = "join", JOIN_REQUEST = "join" }

RC.LINES = {
    yes_trust = { "Yeah. Yeah, I'd like that.", "Alright. I trust you. Lead the way.", "Okay. Better than out here alone." },
    yes_need = { "...Alright. If you really have food, I'll come.", "I can't keep going like this. Okay.", "Fine. I need it more than I want to admit." },
    yes_fear = { "Okay, okay. I'll come. Just... easy.", "Alright. I'm not stupid. I'll come.", "Fine. Whatever you say." },
    meet_trust = { "%s? Alright. I'll find it. Don't make me regret it.", "Okay. %s. I'll head that way.", "I'll come by %s. Keep a light on." },
    meet_need = { "...If there's food at %s, I'll find it.", "%s. Alright. I've got nothing left out here." },
    meet_fear = { "%s. Alright. Just leave me be till then.", "Fine. I'll be at %s." },
    no_stranger = { "I don't even know you.", "Thanks, but I don't walk off with strangers.", "Ask me again when I know who you are." },
    no_proud = { "I do fine on my own.", "I don't need saving.", "Not a chance." },
    no_harm = { "After what you did? No.", "You think I forgot? No." },
    no_hostile = { "Get the hell away from me.", "Not happening." },
    no_full = { "You've got no room for me." },
    no_base = { "Come where? You don't have anywhere." },
    no_busy = { "Not now.", "Can't. Not right now." },
}

local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
local function J() return ProjectALifeJimmy end
local function has(t, w) return string.find(t, w, 1, true) ~= nil end

-- what your pitch offers, matched to what they lack
function RC.pitch(text, needs, hurt)
    local t = " " .. string.lower(tostring(text or "")) .. " "
    local s, why = 0, nil
    local hunger, thirst = tonumber(needs.hunger) or 0, tonumber(needs.thirst) or 0
    if has(t, "food") or has(t, "eat") or has(t, "meal") then s = s + (hunger >= 40 and 12 or 4); if hunger >= 40 then why = "need" end end
    if has(t, "water") or has(t, "drink") then s = s + (thirst >= 40 and 12 or 4); if thirst >= 40 then why = "need" end end
    if has(t, "wall") or has(t, "safe") or has(t, "shelter") or has(t, "fence") or has(t, "bed") or has(t, "roof") then s = s + 6 end
    if has(t, "doctor") or has(t, "medic") or has(t, "meds") or has(t, "medicine") or has(t, "bandage") then s = s + (hurt and 12 or 3); if hurt then why = "need" end end
    if has(t, "gun") or has(t, "ammo") or has(t, "weapon") then s = s + 4 end
    if has(t, "people") or has(t, "others") or has(t, "family") or has(t, "group") then s = s + 3 end
    return math.min(25, s), why
end

-- Will they? Returns score, bar-independent reason ("trust" / "need" / "fear"), refusal key or nil.
function RC.weigh(record, shell, player, text, kind)
    local B = ALifeBonds
    local key = B and B.keyOf(player) or nil
    local r = (B and key) and B.row(key, record.uid, false) or nil
    local Talk = ProjectALife.Talk
    local stance = "neutral"
    pcall(function() stance = Talk.stance(record, player) end)
    if stance == "hostile" then return 0, nil, "no_hostile" end
    if ALifeOrders ~= nil and type(ALifeOrders.shunned) == "function" and ALifeOrders.shunned(record) then return 0, nil, "no_harm" end
    if r ~= nil and (tonumber(r.harm) or 0) >= 2 and B.stageOf(B.effectiveFear(key, record.uid, r)) < 3 then return 0, nil, "no_harm" end
    local parts = { trust = 0, need = 0, fear = 0 }
    -- trust: A-Life's own opinion of you, and love/loyalty from Bonds
    local Op = ProjectALife.NpcOpinion
    if Op ~= nil and type(Op.valueOf) == "function" then
        local ok, v = pcall(Op.valueOf, record, player)
        if ok and tonumber(v) then parts.trust = parts.trust + math.max(-30, math.min(30, tonumber(v) / 2)) end
    end
    if r ~= nil then
        parts.trust = parts.trust + B.stageOf(r.l) * 8 + B.stageOf(r.d or 0) * 5
        parts.need = parts.need + B.stageOf(r.n) * 8
        parts.fear = parts.fear + B.stageOf(B.effectiveFear(key, record.uid, r)) * 10
    end
    -- how outgunned they are
    local S = ALifeSituation
    if S ~= nil and type(S.read) == "function" then
        local ok, sit = pcall(S.read, record, shell, player)
        if ok and type(sit) == "table" then
            if sit.shift >= 10 then parts.fear = parts.fear + 25 elseif sit.shift >= 4 then parts.fear = parts.fear + 12
            elseif sit.shift <= -10 then parts.fear = parts.fear - 10 end
        end
    end
    -- their state
    local needs = {}
    pcall(function() needs = J().Needs.needs(record.memory) or {} end)
    local hunger, thirst, tired = tonumber(needs.hunger) or 0, tonumber(needs.thirst) or 0, tonumber(needs.fatigue) or 0
    if hunger >= 60 then parts.need = parts.need + 12 elseif hunger >= 40 then parts.need = parts.need + 6 end
    if thirst >= 60 then parts.need = parts.need + 12 elseif thirst >= 40 then parts.need = parts.need + 6 end
    if tired >= 70 then parts.need = parts.need + 5 end
    local m = type(record.memory) == "table" and record.memory or {}
    local hp = tonumber(m.health) or 100
    if hp <= 1.5 then hp = hp * 100 end
    local hurt = hp < 60
    if hurt then parts.need = parts.need + 12 end
    local alone = true
    pcall(function()
        local crew = ProjectALife.TalkOrders.crew(record, shell)
        alone = type(crew) ~= "table" or #crew <= 1
    end)
    if alone then parts.need = parts.need + 8 end
    pcall(function()
        local h = math.floor(getGameTime():getTimeOfDay())
        if h >= 20 or h < 5 then parts.need = parts.need + 4 end
    end)
    local p, pwhy = RC.pitch(text, needs, hurt)
    parts.need = parts.need + p
    -- who they are
    local temper = ""
    pcall(function() temper = tostring(ProjectALife.Speech.contextFor(record, player).temperament or "") end)
    local pride = (temper == "veteran" and 12) or (temper == "predator" and 20) or (temper == "fresh" and -6) or 0
    if stance == "careful" then pride = pride + 5 elseif stance == "friendly" then pride = pride - 10 end
    local score = math.floor(parts.trust + parts.need + parts.fear - pride + 0.5)
    local why = "trust"
    if parts.fear > parts.trust and parts.fear >= parts.need then why = "fear"
    elseif parts.need > parts.trust or pwhy == "need" then why = "need" end
    local no = nil
    if score < (kind == "meet" and RC.MEET_BAR or RC.JOIN_BAR) then
        no = (pride >= 12 and parts.trust < 20) and "no_proud" or "no_stranger"
    end
    return score, why, no
end

-- your base (the one closest to them)
function RC.baseFor(player, record, shell)
    local B = J() and J().BaseAreas
    if B == nil then return nil end
    local who = B.who(player)
    local best, bestD
    local x, y = 0, 0
    pcall(function() x, y = shell:getX(), shell:getY() end)
    for _, base in ipairs(B.basesFor(who.key, who.faction, false)) do
        if type(B.canManage) ~= "function" or B.canManage(base, who.key, who.faction, who.admin) then
            local d = 0
            pcall(function() d = J().Residents.radio.distance(base.id, x, y) or 0 end)
            if bestD == nil or d < bestD then best, bestD = base, d end
        end
    end
    return best, bestD
end

function RC.ask(kind, record, shell, player, text)
    local Rs = J() and J().Residents
    if Rs == nil or type(Rs.recruit) ~= "function" then return nil end              -- no Jeem: A-Life handles it
    if type(record.memory) == "table" and type(record.memory.jimmyResident) == "table" then return nil end  -- already yours
    local base = RC.baseFor(player, record, shell)
    if base == nil then return pick(RC.LINES.no_base), "refused" end
    local score, why, no = RC.weigh(record, shell, player, text, kind)
    print(string.format("%s %s: score %d (%s)%s", TAG, kind, score, tostring(why), no and (" -> " .. no) or " -> yes"))
    if no ~= nil then return pick(RC.LINES[no]), "refused" end
    RC.approved[record.uid] = true
    local ok, n, err = pcall(Rs.recruit, player, record.uid, base.id, false)
    RC.approved[record.uid] = nil
    if not ok or n == nil then
        local e = tostring(ok and err or n)
        print(TAG .. " Jeem refused: " .. e)
        if e == "full" or e == "full_cap" or e == "no_beds" then return pick(RC.LINES.no_full), "refused" end
        return pick(RC.LINES.no_busy), "refused"
    end
    -- what made them come colours the bond: fear stays fear, need stays need (Bonds' loyalty/desertion take it from here)
    pcall(function()
        local B = ALifeBonds
        if why == "fear" then B.change(B.keyOf(player), record.uid, 0, 4, 0, { player = player, record = record })
        elseif why == "need" then B.change(B.keyOf(player), record.uid, 0, 0, 6, { player = player, record = record })
        else B.change(B.keyOf(player), record.uid, 4, 0, 0, { player = player, record = record }) end
    end)
    local pool = RC.LINES[(kind == "meet" and "meet_" or "yes_") .. why] or RC.LINES.yes_trust
    local line = pick(pool)
    if string.find(line, "%s", 1, true) then line = string.format(line, tostring(base.name or "your place")) end
    if kind == "meet" and ALifeMemory ~= nil then pcall(ALifeMemory.add, record, "the stranger invited you to their base, " .. tostring(base.name)) end
    return line, "answered"
end

function RC.install()
    if RC.__installed then return true end
    local Data, Intents, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.TalkIntents,
        ProjectALife and ProjectALife.Talk
    local Rs = J() and J().Residents
    if Data == nil or Talk == nil then return false end
    RC.__installed = true
    pcall(Data.load)
    Talk.choiceHandlers = Talk.choiceHandlers or {}
    local function handlerFor(kind, fallback)
        return function(record, shell, player, context, now, text, asked)
            local ok, line, why = pcall(RC.ask, kind, record, shell, player, text)
            if not ok then print(TAG .. " failed: " .. tostring(line)) end
            if ok and line ~= nil then
                if why ~= "answered" and why ~= "refused" then return line, why end
                if ProjectALife.Speech.say(shell, line, { face = player }) then return line, why end
                return nil
            end
            if type(fallback) == "function" then return fallback(record, shell, player, context, now, text, asked) end
            return nil
        end
    end
    for _, def in ipairs(RC.INTENTS) do
        pcall(Data.intent, def.id, def.prio, def.patterns)
        Talk.choiceHandlers[def.id] = handlerFor(def.kind)
    end
    for id, kind in pairs(RC.JOIN_IDS) do Talk.choiceHandlers[id] = handlerFor(kind, Talk.choiceHandlers[id]) end
    if Intents ~= nil then Intents.cache = {} end
    -- A-Life's "not with strangers" gate runs before handlers for typed lines; this decision replaces it for these asks
    local Social = ProjectALife.TalkSocial
    if Social ~= nil and type(Social.typed) == "function" then
        local orig = Social.typed
        Social.typed = function(player, listener, intent)
            if RC.JOIN_IDS[intent] or intent == "INVITE_BASE" then return nil end
            return orig(player, listener, intent)
        end
    end
    -- Jeem's "allied only" check, opened just for people this decided would come
    if Rs ~= nil and type(Rs.isAlly) == "function" then
        local origAlly = Rs.isAlly
        Rs.isAlly = function(key, record)
            if type(record) == "table" and RC.approved[record.uid] then return true end
            return origAlly(key, record)
        end
    end
    print(TAG .. " ready (trust, need and fear decide who joins" .. (Rs and Rs.recruit and "" or " - Jeem residents NOT found") .. ")")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(RC.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
