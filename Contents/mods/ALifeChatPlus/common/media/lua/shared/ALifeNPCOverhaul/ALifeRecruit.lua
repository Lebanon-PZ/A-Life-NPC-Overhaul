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
    ALifeHealth.note(TAG, string.format("%s: score %d (%s)%s", kind, score, tostring(why), no and (" -> " .. no) or " -> yes"))
    if no ~= nil then return pick(RC.LINES[no]), "refused" end
    RC.approved[record.uid] = true
    local ok, n, err = pcall(Rs.recruit, player, record.uid, base.id, false)
    RC.approved[record.uid] = nil
    if not ok or n == nil then
        local e = tostring(ok and err or n)
        ALifeHealth.note(TAG, "Jeem refused: " .. e)
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

-- ADMIN SECRET (not in the settings list; docs only): typed to an NPC, "Do you have a towel on you? It's a bit chilly."
-- skips the "will you come?" check and they join your base now with their whole group (Jeem's real recruit, so beds /
-- room still apply). Single player: anyone; MP: admins only. Off: settings key adminTowel = false.
RC.TOWEL = "do you have a towel on you its a bit chilly"
-- the answer: they know where their towel is (Hitchhiker's Guide nods, our own words)
RC.TOWEL_YES = {
    "A towel? Never go anywhere without one. Don't panic - we're coming with you.",
    "Of course I know where my towel is. Someone who knows where theirs is, that's someone worth following. Lead on.",
    "Bit chilly, end of the world, same thing really. Got my towel. We'll come.",
    "Ha. A fellow traveller. Grab your towel, everyone - we're going with them.",
    "Forty-two reasons to say no and one towel to say yes. We're in.",
}
-- your place is full (or Jeem said no): they walk with you instead
RC.TOWEL_FULL = {
    "No room at yours? Then the road it is. Towel's packed - we'll walk with you.",
    "Full up back home, huh. Don't panic. We'll stick with you instead.",
}
-- no base of yours: they walk with you instead (the whole crew)
RC.TOWEL_WALK = {
    "No place of your own? Doesn't matter. A hoopy frood with a towel - we'll walk with you.",
    "Homeless, cold, end of the world. Don't panic. Towels out, everyone, we go with them.",
    "Mostly harmless, you look. Fine. We'll tag along until you find somewhere.",
}
-- your party, them and their crew (TalkOrders.crew), through the same join a yes to "join me" uses (M.recruitApply,
-- wrapped in Party.lua: A-Life walk-with, else the patch's follow order, then the party list). Returns how many came.
-- No recruitApply: A-Life walk-with + companion mode only.
-- the towel's people stay: marked here (saved with the world), never judged by the party's "treated badly / starving /
-- too scared" check nor the base's "fed up" walk-out (the same two hooks the oath uses, ALifeOathWatch)
function RC.towelKept()
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.bucket) == "function" then local ok, b = pcall(M.bucket, "towelKept"); if ok and type(b) == "table" then return b end end
    RC._kept = RC._kept or {}
    return RC._kept
end
-- kept, and A-Life's opinion of you lifted to friendly (NpcOpinion.adjust, 42.20 source; the unscaled original if
-- our Bond wrap is on: M.origAdjust)
function RC.towelKeep(uid, player)
    if uid == nil then return end
    RC.towelKept()[tostring(uid)] = true
    if player == nil then return end
    pcall(function()
        local Op = ProjectALife.NpcOpinion
        local r = ProjectALife.ActorRegistry.read(tostring(uid))
        if r == nil or Op == nil then return end
        local v = tonumber((Op.valueOf(r, player))) or 0
        local M = ALifeLLMTalk
        local f = (type(M) == "table" and M.origAdjust) or Op.adjust
        if v < 40 then f(r, player, 40 - v, "admin") end
    end)
end
-- pre-1.0 fix: the towel only took the crew A-Life sees near the one you spoke to (TalkOrders.crew, crewRadius); the
-- rest of their group stayed as they were and could turn on you. Now: the whole group (same groupId / outpostId in
-- A-Life's registry, loaded or not) is kept and lifted to friendly; everyone loaded within towelCrewRadius joins.
function RC.towelGroup(record)
    local out = {}
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    local gid, oid = m.groupId, m.outpostId
    if gid == nil and oid == nil then return out end
    pcall(function()
        ProjectALife.ActorRegistry.each(function(other)
            if type(other) ~= "table" or other.uid == record.uid or other.lifecycle ~= "active" then return end
            local om = type(other.memory) == "table" and other.memory or {}
            if (gid ~= nil and om.groupId == gid) or (oid ~= nil and om.outpostId == oid) then out[#out + 1] = other end
        end)
    end)
    return out
end
function RC.towelKeepGroup(record, player)
    if type(record) ~= "table" then return 0 end
    RC.towelKeep(record.uid, player)
    local n = 1
    for _, r in ipairs(RC.towelGroup(record)) do RC.towelKeep(r.uid, player); n = n + 1 end
    return n
end
function RC.towelCrew(record, shell)
    local list = { { record = record, shell = shell } }
    local M = ALifeLLMTalk
    local radius = type(M) == "table" and type(M.settings) == "table" and tonumber(M.settings.towelCrewRadius) or 60
    pcall(function() local c = ProjectALife.TalkOrders.crew(record, shell, radius); if type(c) == "table" and #c > 0 then list = c end end)
    return list
end
function RC.isTowelKept(uid) return uid ~= nil and RC.towelKept()[tostring(uid)] == true end
function RC.towelHooks()
    local M = ALifeLLMTalk
    if type(M) ~= "table" then return false end
    if type(M.partyLeaveCheck) == "function" and not M._towelLeave then
        M._towelLeave = true
        local orig = M.partyLeaveCheck
        M.partyLeaveCheck = function(uid, player, now, ...)
            if RC.isTowelKept(uid) then return nil end
            return orig(uid, player, now, ...)
        end
    end
    if type(M.baseLeave) == "function" and not M._towelBase then
        M._towelBase = true
        local origB = M.baseLeave
        M.baseLeave = function(uid, player, why, ...)
            if RC.isTowelKept(uid) and tostring(why) == "fed up" then return false end
            return origB(uid, player, why, ...)
        end
    end
    return true
end
function RC.towelWalk(player, record, shell)
    local list = RC.towelCrew(record, shell)
    RC.towelKeepGroup(record, player) -- nobody of theirs stays hostile, near or far
    local M = ALifeLLMTalk
    local n = 0
    for _, l in ipairs(list) do
        if type(l) == "table" and type(l.record) == "table" then
            if type(M) == "table" and type(M.partyIsMember) == "function" and M.partyIsMember(l.record.uid, player)
                    and type(M.bucket) == "function" and M.bucket("party")[tostring(l.record.uid)] then
                n = n + 1 -- already in your party
                RC.towelKeep(l.record.uid, player)
            elseif type(M) == "table" and type(M.recruitApply) == "function" then
                local ok, yes = pcall(M.recruitApply, l, player)
                if not (ok and yes == true) then
                    -- admin: whatever kept them (their own squad / guard / patrol stance, a walk cooldown) lets go, then again
                    pcall(ProjectALife.Talk.writeMemory, l.record.uid, function(m)
                        if m.stance ~= "walkWith" then m.stance, m.stanceAnchor = nil, nil end
                        m.walkCooldownUntilHours = nil
                    end)
                    ok, yes = pcall(M.recruitApply, l, player)
                end
                if not (ok and yes == true) and type(M.partyJoin) == "function" then
                    -- last resort: on your party list with the patch's companion mode (follows you, no time limit)
                    if type(M.followStart) == "function" then pcall(M.followStart, l, player) end
                    pcall(M.partyJoin, l.record.uid, player, "admin")
                    ok, yes = true, true
                end
                if ok and yes == true then n = n + 1; RC.towelKeep(l.record.uid, player) end
            else
                local ok, yes = pcall(ProjectALife.Talk.walkWith, player, l, "WALK_WITH_ME")
                if ok and yes then
                    n = n + 1
                    RC.towelKeep(l.record.uid, player)
                    if type(M) == "table" and type(M.followStart) == "function" then pcall(M.followStart, l, player) end
                end
            end
        end
    end
    return n
end
do
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" then
        if M.settings.adminTowel == nil then M.settings.adminTowel = true end
        if M.settings.towelCrewRadius == nil then M.settings.towelCrewRadius = 60 end
        if M.settings.towelHearTiles == nil then M.settings.towelHearTiles = 15 end -- towel: reaches the nearest person this close, even hostile -- towel: how far (tiles) their group joins from
        M.fileKeys = M.fileKeys or {}
        local have = false
        for _, k in ipairs(M.fileKeys) do if k == "adminTowel" then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = "adminTowel" end
        have = false
        for _, k in ipairs(M.fileKeys) do if k == "towelCrewRadius" then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = "towelCrewRadius" end
        have = false
        for _, k in ipairs(M.fileKeys) do if k == "towelHearTiles" then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = "towelHearTiles" end
    end
end
function RC.towelSaid(text)
    if type(text) ~= "string" then return false end
    local t = string.lower(text)
    t = string.gsub(t, "['`]", "")
    t = string.gsub(t, "[^%w]+", " ")
    return string.find(" " .. t .. " ", " " .. RC.TOWEL .. " ", 1, true) ~= nil
end
-- nil = not the phrase (normal talk goes on); else the line they say (spoken here) and "answered" / "refused"
local towelInner
function RC.towel(player, listener, text)
    local line, why = towelInner(player, listener, text)
    local shell = type(listener) == "table" and listener.shell or nil
    if line ~= nil and shell ~= nil then pcall(function() ProjectALife.Speech.say(shell, line, { face = player }) end) end
    return line, why
end
towelInner = function(player, listener, text)
    if not RC.towelSaid(text) then return nil end
    pcall(RC.towelHooks)
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" and M.settings.adminTowel == false then return nil end
    if not ALifeSide.isAdmin(player) then return nil end
    local record = type(listener) == "table" and listener.record or nil
    local shell = type(listener) == "table" and listener.shell or nil
    if type(record) ~= "table" then return nil end
    if type(record.memory) == "table" and type(record.memory.jimmyResident) == "table" then return "I'm already with you.", "answered" end
    local Rs = J() and J().Residents
    local base = (Rs ~= nil and type(Rs.recruit) == "function") and RC.baseFor(player, record, shell) or nil
    if base == nil then
        local n = RC.towelWalk(player, record, shell)
        ALifeHealth.note(TAG, "towel: no base, " .. tostring(n) .. " walk with you")
        if n > 0 then return pick(RC.TOWEL_WALK), "answered" end
        return pick(RC.LINES.no_busy), "refused"
    end
    RC.approved[record.uid] = true
    local ok, n, err = pcall(Rs.recruit, player, record.uid, base.id, true)
    RC.approved[record.uid] = nil
    if not ok or n == nil then
        -- admin: Jeem said no (beds, room, on a trip, a fight): they join your party instead
        local e = tostring(ok and err or n)
        local w = RC.towelWalk(player, record, shell)
        ALifeHealth.note(TAG, "towel: Jeem refused (" .. e .. "), " .. tostring(w) .. " in your party instead")
        if w > 0 then return pick(RC.TOWEL_FULL), "answered" end
        return pick(RC.LINES.no_busy), "refused"
    end
    pcall(function() local B = ALifeBonds; B.change(B.keyOf(player), record.uid, 4, 0, 0, { player = player, record = record }) end)
    RC.towelKeepGroup(record, player)
    ALifeHealth.note(TAG, "towel: " .. tostring(record.uid) .. " joined with " .. tostring(n) .. " (admin phrase)")
    return pick(RC.TOWEL_YES), "answered"
end

-- pre-1.0 fix (Joe Nov 27: a hostile NPC "wouldn't take the towel"): A-Life only hands a typed line to someone
-- Speech.talkable (not fighting you, not hostile), so an attacker never heard the admin phrase. The phrase now reaches
-- the nearest A-Life person within towelHearTiles whatever their mood, before A-Life picks a listener. Admin only.
function RC.towelNearest(player)
    local px, py, pz = nil, nil, nil
    pcall(function() px, py, pz = player:getX(), player:getY(), player:getZ() end)
    if px == nil then return nil end
    local M = ALifeLLMTalk
    local reach = type(M) == "table" and type(M.settings) == "table" and tonumber(M.settings.towelHearTiles) or 15
    local best, bd = nil, reach * reach
    pcall(function()
        ProjectALife.ActorRegistry.each(function(r)
            if type(r) ~= "table" or r.lifecycle ~= "active" then return end
            local sh = ProjectALife.Talk.shellFor(r.uid)
            if sh == nil then return end
            local d = (sh:getX() - px) ^ 2 + (sh:getY() - py) ^ 2
            if math.floor(sh:getZ()) == math.floor(pz) and d < bd then best, bd = { record = r, shell = sh }, d end
        end)
    end)
    return best
end
function RC.towelWrapText()
    local Talk = ProjectALife and ProjectALife.Talk
    if Talk == nil or type(Talk.onPlayerText) ~= "function" or RC._towelText then return false end
    RC._towelText = true
    local orig = Talk.onPlayerText
    Talk.onPlayerText = function(player, text, loud, ...)
        if RC.towelSaid(text) and ALifeSide.isAdmin(player) then
            local l = RC.towelNearest(player)
            if l ~= nil then
                local ok, line = pcall(RC.towel, player, l, text)
                if ok and line ~= nil then return true, "towel" end
            end
        end
        return orig(player, text, loud, ...)
    end
    return true
end
function RC.install()
    if RC.__installed then return true end
    pcall(RC.towelHooks)
    pcall(RC.towelWrapText)
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
