-- A-Life Talk 0.5.1: THREATS THAT SOMETIMES WORK (intimidation).
-- A-Life already has a real intimidation system (TalkOrders: chanceFor = class, your weapon / aim, empty gun, party,
-- their crew + arms + armour, distance, cover, fear state, reputation, opinion; comply = group surrender / disarm /
-- frisk / send away; refuse = run or Careful turn). It only fires for its own menu rows and a few exact phrases, so
-- free-typed threats ("drop it or I shoot", "hand over your stuff", "back off") never reached it. Here they do:
--   detect locally -> kind (hands_up / drop / surrender / rob / out / back_off) -> chance = A-Life's own
--   Orders.chanceFor + personality, mood / fear, health on both sides, injuries, numbers, bond, nemesis grudge,
--   faction backup, cornered, repeated threats (less each time) -> outcome:
--     comply: A-Life's own surrender / disarm / frisk / send-away / flee (and stop chasing through the patch pause)
--     bluff: you're unarmed and threaten to shoot -> they call it
--     refuse: argue and posture
--     escalate: A-Life's own Orders.turnCrew (hostile)
-- Effects: opinion down, fear up, a grudge (Nemesis), a rumor ("heard you rob people"), witnesses react; the target's
-- AI line voices the outcome (req.threat), with a stock line when the bridge is down. Phrases A-Life itself
-- classifies as an order (HANDS_UP, DROP_WEAPON, DEMAND_ITEMS, the Orders rows) stay A-Life's.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Threats") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Threats"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Threats") end end -- 0.5.1.6 perf label

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
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end

if M.settings.threats == nil then M.settings.threats = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "threats" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "threats" end
end
M.threatCfg = { tiles = 12, shoutTiles = 20, repeatWindowMs = 600000, repeatPenalty = 15, fearMs = 1800000 }

-- kind, words (order matters: specific first)
M.threatWords = {
    { "rob", { "hand over", "give me your", "give me everything", "empty your", "your stuff", "your bag", "your pack", "drop your bag",
        "everything you got", "everything you've got", "wallet", "this is a robbery", "your loot" } },
    { "drop", { "drop it", "drop the gun", "drop your gun", "drop your weapon", "drop the weapon", "drop the knife", "put it down",
        "put the gun down", "lower your weapon", "weapon down", "gun down" } },
    { "hands_up", { "hands up", "hands in the air", "hands where i can see", "get on the ground", "on your knees", "freeze", "don't move", "dont move" } },
    { "out", { "get out of here", "get the hell out", "beat it", "scram", "get lost", "go away", "piss off", "clear out", "move along" } },
    { "back_off", { "back off", "back away", "step back", "stay back", "get back", "stop right there", "keep your distance", "don't come closer",
        "dont come closer", "leave me alone" } },
}
M.threatTail = { "or i shoot", "or i'll shoot", "or ill shoot", "or i'll kill you", "or ill kill you", "or you die", "or else",
    "i'll shoot", "ill shoot", "i will shoot", "i'll blow your", "or i'll blow", "i'll put you down", "i'll cut you", "or i swear",
    "i'll end you", "you're dead", "last warning" }

-- 0.8.11.2: whole words only ("freezer" is not "freeze", "your bagel" is not "your bag")
local function hasPhrase(low, w) return string.find(low, " " .. w .. " ", 1, true) ~= nil end
function M.parseThreat(text)
    local low = " " .. string.gsub(string.lower(tostring(text or "")), "[^%w']+", " ") .. " "
    local kind = nil
    for _, row in ipairs(M.threatWords) do
        for _, w in ipairs(row[2]) do if hasPhrase(low, w) then kind = row[1]; break end end
        if kind then break end
    end
    local tail = nil
    for _, w in ipairs(M.threatTail) do if hasPhrase(low, w) then tail = w end end
    if kind == nil and tail ~= nil then kind = "back_off" end
    if kind == nil then return nil end
    local gunWord = hasPhrase(low, "shoot") or hasPhrase(low, "blow your") or hasPhrase(low, "gun")
    return kind, tail ~= nil, gunWord ~= nil
end

-- what A-Life itself would do with this line (its own order rows / typed intents): leave those to A-Life
function M.aLifeOrderIntent(text)
    local pa = PA()
    if not fn(pa and pa.TalkIntents, "classify") then return false end
    local ok, intent = pcall(function()
        if pa.DialogueData and fn(pa.DialogueData, "load") then pa.DialogueData.load() end
        return pa.TalkIntents.classify(text, false, pa.DialogueData)
    end)
    if not ok or intent == nil then return false end
    if intent == "HANDS_UP" or intent == "STOP_FREEZE" or intent == "DROP_WEAPON" or intent == "DEMAND_ITEMS" then return true end
    if string.sub(tostring(intent), 1, 6) == "ORDER_" or string.sub(tostring(intent), 1, 6) == "FRISK_" then return true end
    return false
end

-- an A-Life robbery of the player or a standoff is running: its own words logic answers
function M.aLifeScene(player)
    local pa = PA()
    local busy = false
    pcall(function()
        local key = pa.Speech.playerKey(player)
        local R = pa.ModuleRobbery
        if R and key ~= nil and type(R.byPlayer) == "table" and R.byPlayer[key] ~= nil and type(R.active) == "table" then
            local st = R.active[R.byPlayer[key]]
            if st ~= nil and st.phase ~= "release" and st.phase ~= "execute" then busy = true end
        end
        local S = pa.Standoff
        if not busy and S and type(S.stateFor) == "function" then
            local s = S.stateFor(player)
            if s ~= nil and s.phase ~= "done" and s.phase ~= "turning" then busy = true end
        end
    end)
    return busy
end

local function playerArms(player)
    local pa = PA()
    if fn(pa and pa.TalkOrders, "threatOf") then
        local ok, armed, ranged, aiming = pcall(pa.TalkOrders.threatOf, player)
        if ok then return armed, ranged, aiming end
    end
    local armed, ranged, aiming = false, false, false
    pcall(function()
        local w = player:getPrimaryHandItem()
        if w ~= nil and instanceof(w, "HandWeapon") and tostring(w:getFullType()) ~= "Base.BareHands" then armed, ranged = true, w:isRanged() == true end
        aiming = player:isAiming() == true
    end)
    return armed, ranged, aiming
end

M.threatUses = {} -- uid -> list of ms
function M.threatChance(l, player, kind, now, opts)
    opts = opts or {}
    local pa = PA()
    local uid = tostring(l.record.uid)
    local O = pa and pa.TalkOrders
    local aKind = (kind == "back_off") and "out" or kind
    local base, why = 30, {}
    if fn(O, "chanceFor") then
        local okC, ctx = pcall(function() return O.memberContext({ record = l.record, shell = l.shell }, player) end)
        local ok, c = pcall(O.chanceFor, aKind, l.record, l.shell, player, okC and ctx or {})
        if ok and tonumber(c) then base = tonumber(c); why[#why + 1] = "A-Life " .. base end
    else
        local armed, ranged, aiming = playerArms(player)
        base = base + (ranged and aiming and 28 or ranged and 14 or armed and 8 or -15)
    end
    local c = base
    -- personality / mood
    local lens = M.lens and M.lens(uid) or {}
    local core = M.partsOf and M.partsOf(uid) or nil
    local k = core and core.core and core.core.key or ""
    c = c + (lens.fearful or 0) * 30 + (lens.gloomy or 0) * 12 - (lens.volatile or 0) * 25 - (lens.proud or 0) * 20
        - (lens.unhinged or 0) * 25 - (lens.brave or 0) * 15
    if k == "coward" or k == "shy" or k == "broken" or k == "depressive" or k == "hopeless" then c = c + 15 end
    if k == "hothead" or k == "proud" or k == "sadist" or k == "zealot" or k == "bully" then c = c - 15 end
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    c = c + (b.fear or 0) * 25 - (b.anger or 0) * 20
    -- health: theirs (A-Life wounds) vs yours
    local hp = 100
    if M.woundState then local okW, s = pcall(M.woundState, uid); if okW and s and tonumber(s.hp) then hp = s.hp end; if okW and s and (s.limp or s.downed) then c = c + 10 end end
    local mine = 100
    pcall(function() local bd = player:getBodyDamage(); mine = bd and tonumber((bd:getOverallBodyHealth())) or 100 end)
    c = c + (mine - hp) * 0.2
    -- bond and grudge
    local v = 0
    pcall(function() v = tonumber((pa.NpcOpinion.valueOf(l.record, player))) or 0 end)
    if v >= 40 then c = c - 10 end -- a friend is shocked rather than scared
    if M.nemesisOf and M.nemesisOf(uid) ~= nil then c = c - 20 end
    local tie = M.playerTie and select(1, M.playerTie(l.record, player)) or nil
    if tie == "nemesis" then c = c - 20 end
    -- cornered: alone, hurt and close
    local x, y = pos(l.shell)
    local px, py = pos(player)
    local d2 = (x and px) and (x - px) ^ 2 + (y - py) ^ 2 or 99
    local crew = 0
    pcall(function() crew = #pa.Talk.groupMembers(l.record, 15, l.shell) end)
    local cornered = crew == 0 and d2 <= 9 and hp < 50
    if cornered then c = c + ((lens.brave or 0) + (lens.volatile or 0) > 0.4 and -15 or 10) end
    -- repeated threats wear out
    local uses = 0
    for _, t in ipairs(M.threatUses[uid] or {}) do if now - t < M.threatCfg.repeatWindowMs then uses = uses + 1 end end
    c = c - uses * M.threatCfg.repeatPenalty
    return clamp(math.floor(c + 0.5), 2, 96), { base = base, cornered = cornered, uses = uses, crew = crew, hp = hp, v = v, core = k }
end

-- outcome: comply / bluff / refuse / escalate
function M.threatOutcome(l, player, kind, gunWord, now, rollValue, opts)
    local uid = tostring(l.record.uid)
    local chance, f = M.threatChance(l, player, kind, now)
    local armed, ranged = playerArms(player)
    local r = rollValue or (hash(uid .. "#threat#" .. math.floor(now / 1000)) % 100)
    local lens = M.lens and M.lens(uid) or {}
    if gunWord and not ranged then
        local call = 55 + (lens.brave or 0) * 30 + (lens.volatile or 0) * 20 - (lens.fearful or 0) * 30
        if r < clamp(call, 10, 95) then return "bluff", chance, f end
    end
    if r < chance then return "comply", chance, f end
    local esc = 10 + (lens.volatile or 0) * 40 + (lens.proud or 0) * 20 + (lens.unhinged or 0) * 30 + (lens.mean or 0) * 20
    if f.core == "hothead" or f.core == "sadist" or f.core == "bully" then esc = esc + 25 end
    if (f.crew or 0) >= 2 then esc = esc + 10 end
    if not armed then esc = esc - 10 end
    if (hash(uid .. "#esc#" .. math.floor(now / 1000)) % 100) < clamp(esc, 0, 85) then
        -- 0.8.11.2 hostile needs 2 signs: a bare "back off" is one; a tail ("or I shoot") or a gun on them is another.
        -- Not enough yet -> they don't attack: the scared run, the rest stand their ground and argue.
        local _, ranged2, aiming2 = playerArms(player)
        local w = 1 + ((opts and opts.tail) and 1 or 0) + ((ranged2 and aiming2) and 1 or 0)
        if not M.hostileSign or M.hostileSign(l.record, player, w, "threat '" .. tostring(kind) .. "'", now) then
            return "escalate", chance, f
        end
        if (lens.fearful or 0) >= 0.3 then return "comply", chance, f end
    end
    return "refuse", chance, f
end

M.threatLines = {
    comply_hands_up = { "Okay! Okay, hands up!", "Don't shoot! I'm not doing anything!", "Easy... easy. Hands are up." },
    comply_drop = { "Alright, it's down! It's down!", "Okay - dropping it. Don't shoot.", "There. Happy?" },
    comply_rob = { "Take it! Just take it!", "Fine - here, take it all.", "Okay, okay - it's yours." },
    comply_out = { "I'm going, I'm going!", "Alright! I'm leaving!", "Okay - I'm out of here." },
    comply_back_off = { "Okay, backing off.", "Fine, fine - I'm backing off.", "Alright, easy. I'm going." },
    beg = { "Please - I've got nothing!", "Don't, please... I'll do what you want.", "Please don't hurt me." },
    bluff = { "With what? Your finger?", "You're not even armed.", "Shoot me with what, genius?", "Nice bluff." },
    refuse = { "You don't scare me.", "No.", "Try it and see what happens.", "Big talk.", "I'm not going anywhere." },
    escalate = { "Wrong move!", "You threatening me?!", "That's it - you're dead!", "Bad idea, pal!" },
}

local function witnesses(player, exceptUid)
    local x, y, z = pos(player)
    local out = {}
    for _, w in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z or 0, 16, exceptUid) or {}) do out[#out + 1] = w end
    return out
end

M.lastThreat = {}
M.intimidated = {}
function M.intimidatedBoost(uid)
    local t = M.intimidated[tostring(uid)]
    if t == nil or nowMs() - t > M.threatCfg.fearMs then return 0 end
    return 0.25
end

function M.applyThreat(l, player, kind, outcome, chance, talkingTo)
    local pa = PA()
    local O = pa and pa.TalkOrders
    local uid = tostring(l.record.uid)
    local now = nowMs()
    local detail = nil
    local P = patch()
    local ctx = {}
    pcall(function() ctx = O.memberContext({ record = l.record, shell = l.shell }, player) end)
    if outcome == "comply" then
        if (kind == "hands_up" or kind == "drop" or kind == "rob") and fn(O, "groupSurrender") then
            local okS, members = pcall(O.groupSurrender, kind == "drop" and "drop" or kind == "rob" and "rob" or "hands_up", l.record, l.shell, player, ctx, now)
            members = okS and type(members) == "table" and members or { { record = l.record, shell = l.shell } }
            if kind == "drop" and fn(O, "disarm") then
                local n = 0
                for _, m in ipairs(members) do local ok, d = pcall(O.disarm, m.shell); if ok then n = n + (tonumber(d) or 0) end end
                detail = n > 0 and "dropped their weapon" or "had nothing to drop"
            elseif kind == "rob" and fn(O, "robCrew") then
                local ok, taken = pcall(O.robCrew, l.record, l.shell, player, now, members)
                taken = ok and taken or {}
                if #taken > 0 then
                    pcall(O.markRobbed, members, now)
                    pcall(O.noteRobbery, l.record, player)
                    detail = "handed over " .. (fn(O, "listOf") and O.listOf(taken) or tostring(#taken) .. " items")
                else detail = "had nothing worth taking" end
            else detail = "put their hands up" end
        elseif kind == "out" then
            if M.terr and M.terr.speaker == uid then M.terr = nil end -- leaving their own camp? they just stop pressing you
            if fn(O, "sendAway") then pcall(O.sendAway, l.record, l.shell, player, now) end
            detail = "backed off and left"
        else -- back_off: stop chasing / back away
            local stance = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or "neutral"
            if stance == "hostile" and P and fn(P, "pauseHostile") then pcall(P.pauseHostile, uid, player, 9000) end
            if fn(O, "runAway") then pcall(O.runAway, l.record, l.shell, player, now) end
            detail = "backed off"
        end
        M.intimidated[uid] = now
        -- a hostile one that gives in stops attacking: the patch's calm entry (A-Life's targeting skips you), else a pause
        local stance = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or "neutral"
        if stance == "hostile" and P then
            local calmed = false
            if fn(P, "grantCalm") then local okG, g = pcall(P.grantCalm, l.record, player, "intimidated"); calmed = okG and g ~= false and g ~= nil end
            if not calmed and fn(P, "pauseHostile") then pcall(P.pauseHostile, uid, player, 12000) end
        end
        if fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, l.record, player, -4, "Threatened by you") end
        if M.feel then M.feel(uid, "fear", 0.45, "you threatened them"); M.feel(uid, "shame", 0.15, "gave in to a threat") end
        if M.addGrudge then pcall(M.addGrudge, uid, kind == "rob" and 20 or 8, "you threatened them", player) end
        if M.addDeed and (kind == "rob" or kind == "hands_up" or kind == "drop") then
            local x, y = pos(player)
            local wit = {}
            for _, w in ipairs(witnesses(player)) do wit[#wit + 1] = tostring(w.record.uid) end
            pcall(M.addDeed, "threat", kind == "rob" and "the newcomer robs people at gunpoint" or "the newcomer pulls weapons on people", -3, wit, x, y)
        end
    elseif outcome == "escalate" then
        local turned = false
        if fn(O, "turnCrew") then local ok, r = pcall(O.turnCrew, l.record, l.shell, player); turned = ok and r == true end
        if not turned and P and fn(P, "attackNow") and M.settings.attackPlayer ~= false then pcall(P.attackNow, uid, player, "threatened") end
        if fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, l.record, player, -8, "Threatened by you") end
        if M.feel then M.feel(uid, "anger", 0.5, "you threatened them") end
        detail = "turned on you"
    else
        local noted = false
        if fn(pa.NpcOpinion, "note") then local okN = pcall(pa.NpcOpinion.note, "threat_failed", l.record, player); noted = okN end -- A-Life: -6
        if not noted and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, l.record, player, -4, outcome == "bluff" and "Called your bluff" or "Threatened by you") end
        if M.feel then M.feel(uid, outcome == "bluff" and "amusement" or "anger", 0.25, "you threatened them") end
        detail = outcome == "bluff" and "called your bluff" or "refused"
    end
    M.lastThreat[uid] = { kind = kind, outcome = outcome, detail = detail, at = now, chance = chance }
    local list = M.threatUses[uid] or {}
    list[#list + 1] = now
    while #list > 6 do table.remove(list, 1) end
    M.threatUses[uid] = list
    -- witnesses
    for i, w in ipairs(witnesses(player, uid)) do
        if i > 4 then break end
        local wu = tostring(w.record.uid)
        if M.feel then M.feel(wu, "fear", 0.15, "saw you threaten " .. ((M.nameParts and (M.nameParts(l.record) or {}).first) or "someone")) end
        if fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, w.record, player, -1, "Saw you threaten someone") end
    end
    if M.logInteraction then pcall(M.logInteraction, uid, "Threatened (" .. kind:gsub("_", " ") .. "): " .. tostring(detail) .. " (" .. tostring(chance) .. "%)", nil, nil, "event") end
    if M.keyMem then pcall(M.keyMem, uid, "threat", "The newcomer threatened you (" .. kind:gsub("_", " ") .. "); you " .. tostring(detail)) end
    -- the one you spoke to answers with the AI (req.threat); stock line when the bridge is down / for the rest
    local stockKey = outcome == "comply" and ("comply_" .. kind) or outcome
    local line = pick(M.threatLines[stockKey] or M.threatLines.refuse, uid .. now)
    if outcome == "comply" and (kind == "hands_up" or kind == "rob") and (hash(uid) % 3 == 0) then line = pick(M.threatLines.beg, uid .. now) end
    if not talkingTo or not (M.bridgeAlive and M.bridgeAlive(now)) then
        if M.say then M.say(l.shell, player, line, { record = l.record, combat = true }) end
    end
    log("threat '" .. kind .. "' to " .. uid .. ": " .. outcome .. " (" .. tostring(chance) .. "%) - " .. tostring(detail))
    return outcome, detail
end

function M.onThreatWords(player, text, loud, hearers)
    if M.settings.threats == false then return end
    local kind, tail, gunWord = M.parseThreat(text)
    if kind == nil then return end
    if M.aLifeOrderIntent(text) then return end -- A-Life's own order system takes this one
    if M.aLifeScene(player) then return end -- an A-Life robbery / standoff owns the moment
    local now = nowMs()
    local px, py, pz = pos(player)
    -- a "get out" inside your own base is the LEAVE system (Territory.lua), not a threat - unless you add a threat tail
    if kind == "out" and not tail and M.leaveAsked then
        for _, l in ipairs(hearers or {}) do
            local a = M.leaveAsked[tostring(l.record.uid)]
            if a and now - a.at < 1500 then return end
        end
    end
    local pa = PA()
    -- the target: the one you addressed (A-Life's hearer) or the nearest hostile in earshot
    -- the target: the nearest one who is hostile to you in earshot (they don't show up as A-Life listeners), else the
    -- one you addressed (A-Life's first hearer), else the nearest NPC
    local target = nil
    local near = M.nearbyNpcs and M.nearbyNpcs(px, py, pz, loud and M.threatCfg.shoutTiles or M.threatCfg.tiles) or {}
    for _, l in ipairs(near) do
        if fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) == "hostile" then target = l; break end
    end
    target = target or (hearers and hearers[1]) or near[1]
    if target == nil then return end
    -- 0.8.11.2 (Miller): "get out of here!" / "back off!" to someone fighting the dead (not you) is a warning
    if (kind == "out" or kind == "back_off") and not tail and M.settings.fightWarnTalk ~= false then
        local st = fn(pa.Talk, "stance") and pa.Talk.stance(target.record, player) or "neutral"
        local busy = fn(pa.Talk, "busy") and pa.Talk.busy(target.record, now) or false
        if st ~= "hostile" and busy then
            log("threat words '" .. kind .. "' to someone fighting the dead: a warning, not a threat")
            return
        end
    end
    local outcome, chance = M.threatOutcome(target, player, kind, gunWord, now, nil, { tail = tail })
    M.applyThreat(target, player, kind, outcome, chance, true)
end
table.insert(M.playerWordHooks, M.onThreatWords)

table.insert(M.requestExtras, function(req, player, listener, now)
    local t = M.lastThreat[tostring(listener.record.uid)]
    if t and now - t.at < 8000 then req.threat = { kind = t.kind, outcome = t.outcome, detail = t.detail } end
end)

return M
