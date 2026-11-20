-- A-Life Talk 0.5.1: TERRITORY and "LEAVE".
-- Territory = A-Life's real places: Havens (group houses / camps: Havens.takenAt), outposts / safehouses run by
-- factions (OutpostRegistry.list bounds), encounter camps (memory.encounter == "camp" + memory.home), and the
-- building an NPC group is sheltering in (memory.shelterBuildingId = the IsoBuilding's ID, set by A-Life).
-- (1) You walk in: a resident warns you; stay and the warnings escalate on a timer; after the last one they go
--     hostile through the existing path (patch: P.attackNow -> A-Life's Careful.turnGroup). The RELATIONSHIP decides
--     most: close friends / allies welcome you, liked ones tolerate you, neutral ones warn slowly, disliked ones warn
--     fast, enemies hardly warn. Personality only modifies it. Plea / gift (opinion going up) or "wait" buys time;
--     leaving resets it.
-- (2) "leave" / "get out" / "get lost" / "out of my house" inside YOUR base (A-Life SafehouseDirector: a marked
--     house, a vanilla safehouse claim or BaseHeat's base; your current building as the fallback): friends go without
--     fuss but are hurt, neutrals go grudgingly, disliked ones argue / stall / refuse, enemies may turn hostile.
--     They walk out with A-Life's hold order outside (patch P.leaveArea). "you can stay" takes it back.
-- (3) NPCs of other factions / groups inside a territory are told to leave too (pair bond decides: move along,
--     refuse, a feud).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Territory") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Territory"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Territory") end end -- 0.5.1.6 perf label

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
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function inside(b, x, y, margin)
    margin = margin or 0
    return type(b) == "table" and x ~= nil and x >= b.x1 - margin and x <= b.x2 + margin and y >= b.y1 - margin and y <= b.y2 + margin
end
local function opinion(r, player)
    local v = 0
    pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end)
    return v
end

if M.settings.territory == nil then M.settings.territory = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "territory" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "territory" end
end
M.terrCfg = { tickMs = 2000, scanTiles = 40, speakTiles = 22, steps = 3, npcGapMs = 30000, leaveMs = 300000, repeatMs = 120000 }

local function buildingBounds(building)
    local b = nil
    pcall(function()
        local def = building:getDef()
        b = { x1 = def:getX(), y1 = def:getY(), x2 = def:getX2() - 1, y2 = def:getY2() - 1 }
    end)
    return b
end
local function buildingOf(o)
    local b = nil
    -- 0.5.1.4: nil-checked (a pcall'd error still prints a full stack trace to console.txt in Kahlua)
    if o == nil or o.getCurrentSquare == nil then return nil end
    pcall(function()
        local sq = o:getCurrentSquare()
        if sq ~= nil then b = sq:getBuilding() end
    end)
    return b
end
local function buildingId(b)
    local id = nil
    pcall(function() id = tostring(b:getID()) end)
    return id
end

-- the territory at the player's spot (nil = none), with the residents that are around
function M.territoryAt(player, near)
    local pa = PA()
    local x, y, z = pos(player)
    if x == nil then return nil end
    near = near or (M.nearbyNpcs and M.nearbyNpcs(x, y, z, M.terrCfg.scanTiles) or {})
    local function residents(test)
        local out = {}
        for _, l in ipairs(near) do
            local m = type(l.record.memory) == "table" and l.record.memory or {}
            if test(l, m) then out[#out + 1] = l end
        end
        return out
    end
    -- A-Life haven (group house / camp)
    if fn(pa.Havens, "takenAt") then
        local ok, h = pcall(pa.Havens.takenAt, x, y, 1)
        if ok and type(h) == "table" then
            local list = residents(function(l, m) return m.havenId == h.id or (h.groupId ~= nil and m.groupId == h.groupId) end)
            if #list > 0 then return { kind = h.kind == "camp" and "camp" or "house", id = tostring(h.id), bounds = h.bounds, residents = list } end
        end
    end
    -- faction outposts / safehouses
    if fn(pa.OutpostRegistry, "list") then
        local ok, sites = pcall(pa.OutpostRegistry.list)
        for _, s in ipairs(ok and sites or {}) do
            if s.state ~= "expired" and inside(s.bounds, x, y, 2) then
                local list = residents(function(l, m) return m.outpostId == s.id or (s.factionId ~= nil and l.record.factionId == s.factionId) end)
                if #list > 0 then return { kind = "outpost", id = tostring(s.id), bounds = s.bounds, residents = list, factionId = s.factionId } end
            end
        end
    end
    -- encounter camps
    local camp = residents(function(l, m)
        return m.encounter == "camp" and type(m.home) == "table" and tonumber(m.home.x) and (m.home.x - x) ^ 2 + (m.home.y - y) ^ 2 <= 64
    end)
    if #camp > 0 then
        local h = camp[1].record.memory.home
        return { kind = "camp", id = "camp:" .. math.floor(h.x) .. ":" .. math.floor(h.y), bounds = { x1 = h.x - 8, y1 = h.y - 8, x2 = h.x + 8, y2 = h.y + 8 }, residents = camp }
    end
    -- a group sheltering in the building you walked into
    local b = buildingOf(player)
    local bid = b and buildingId(b) or nil
    if bid then
        local list = residents(function(l, m) return m.shelterBuildingId ~= nil and tostring(m.shelterBuildingId) == bid end)
        if #list > 0 then return { kind = "shelter", id = "bld:" .. bid, bounds = buildingBounds(b), residents = list } end
    end
    return nil
end

-- how the residents feel about you being here: relationship first, personality second
function M.territoryMood(l, player)
    local pa = PA()
    local uid = tostring(l.record.uid)
    local v = opinion(l.record, player)
    local stance = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or "neutral"
    local eff = v
    if stance == "friendly" then eff = eff + 20 end
    if fn(pa.Party, "friendly") and pa.Party.friendly(l.record, player) == true then eff = eff + 60 end
    local tie = M.playerTie and select(1, M.playerTie(l.record, player)) or nil
    if tie == "ally" or tie == "best friend" then eff = eff + 25 elseif tie == "nemesis" then eff = eff - 40 end
    local lens = M.lens and M.lens(uid) or {}
    eff = eff + ((lens.kind or 0) + (lens.calm or 0)) * 10 - ((lens.paranoid or 0) + (lens.volatile or 0) + (lens.greedy or 0) * 0.5) * 12
    return eff, stance
end
function M.territoryTier(eff)
    if eff >= 35 then return "welcome" elseif eff >= 15 then return "tolerate" elseif eff > -15 then return "neutral"
    elseif eff > -45 then return "disliked" end
    return "enemy"
end
M.terrInterval = { neutral = 45000, disliked = 20000, enemy = 9000 }

M.terrLines = {
    welcome = { "Hey! Come on in - you're welcome here.", "Good to see you. Make yourself at home.", "Look who it is. Come in, come in." },
    tolerate = { "You can stay a bit. Don't touch our stuff.", "Alright, you can hang around. Keep your hands to yourself." },
    warn1 = { "You're on our ground. Turn around.", "Hey - this place is taken. Keep walking.", "That's far enough. This is our place." },
    warn2 = { "I said turn around. Now.", "Second time I'm telling you. Get moving.", "Don't make me say it again." },
    warn3 = { "Last warning. Walk away or we put you down.", "That's it. Leave NOW.", "Final warning!" },
    left = { "Yeah, keep walking.", "Smart.", "And stay out." },
    npcWarn = { "You're on our ground. Move along.", "This place is ours. Find your own.", "Keep walking, friend." },
    npcGo = { "Alright, alright. I'm going.", "Fine. Keep your dump.", "Easy. Leaving." },
    npcNo = { "Make me.", "I'm not going anywhere.", "Says who?" },
    leaveFriend = { "Oh. Okay... I'll go.", "Sure. Didn't mean to overstay.", "Right. Sorry. I'm going." },
    leaveNeutral = { "Fine, fine. I'm going.", "Alright, I'm leaving. Relax.", "Okay. Your place, your rules." },
    leaveArgue = { "We were here first.", "Make me.", "Or what?", "I'll leave when I'm ready." },
    leaveRefuse = { "No.", "I'm staying right here.", "You and what army?" },
    stay = { "Thanks. I appreciate it.", "Oh - thanks. Means a lot.", "Alright. I'll behave." },
}

local function speak(l, player, mode, what, style, line)
    if M.react and M.react(mode, l, player, { what = what, style = style, maxWords = 14, fallback = line },
            { key = mode .. ":" .. tostring(l.record.uid), keyCooldownMs = 8000, modeCooldownMs = 3000, urgent = true, face = "player" }) then
        return true
    end
    if M.say then M.say(l.shell, player, line, { record = l.record }) end
    return false
end

M.terr = nil -- { id, step, nextAt, speaker, opinionAt, warned, tier }
-- pre-1.0 MP (P5): one trespass state per player on a server (M.terrBy[key]; M.terr is that player's while their turn
-- runs). Single player: M.terr as before.
M.terrBy = M.terrBy or {}
local function terrSwap(player, f, ...)
    if not (type(ALifeSide) == "table" and ALifeSide.mpServer()) or player == nil then return f(...) end
    local k = ALifeSide.keyOf(player)
    local keep = M.terr
    M.terr = M.terrBy[k]
    local ok, a = pcall(f, ...)
    M.terrBy[k] = M.terr
    M.terr = keep
    if not ok then error(a) end
    return a
end
function M.territoryTick(now)
    if M.settings.territory == false then return end
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then
        M.eachPlayer(function(p) terrSwap(p, M.territoryTickFor, now) end)
        return
    end
    return M.territoryTickFor(now)
end
function M.territoryTickFor(now)
    local player = ALifeSide.you()
    if player == nil then return end
    local x, y, z = pos(player)
    local near = M.nearbyNpcs and M.nearbyNpcs(x, y, z, M.terrCfg.scanTiles) or {}
    local t = M.territoryAt(player, near)
    local st = M.terr
    if t == nil or (st and st.id ~= t.id) then
        if st and st.warned and st.speaker then
            local r = rec(st.speaker)
            if r and M.logInteraction then pcall(M.logInteraction, st.speaker, "You left their " .. st.kind .. " when warned", nil, nil, "event") end
        end
        M.terr = nil
        st = nil
    end
    if t ~= nil then
        -- speaker: the closest resident who isn't fighting
        local pa = PA()
        local best, bd = nil, 1e9
        for _, l in ipairs(t.residents) do
            local sx, sy = pos(l.shell)
            local d = sx and (sx - x) ^ 2 + (sy - y) ^ 2 or 1e9
            if d < bd and d <= M.terrCfg.speakTiles ^ 2 and not (fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now)) then best, bd = l, d end
        end
        if best ~= nil then
            local stance
            local eff
            eff, stance = M.territoryMood(best, player)
            if stance ~= "hostile" then
                local tier = M.territoryTier(eff)
                if st == nil then
                    st = { id = t.id, kind = t.kind, step = 0, nextAt = now, speaker = tostring(best.record.uid), opinionAt = opinion(best.record, player),
                        tier = tier, bounds = t.bounds }
                    M.terr = st
                end
                M.territoryStep(st, best, player, tier, now)
            end
        end
    end
    pcall(M.territoryNpcs, near, now)
end

function M.territoryStep(st, l, player, tier, now)
    local uid = tostring(l.record.uid)
    st.speaker = uid
    if tier == "welcome" or tier == "tolerate" then
        if not st.greeted then
            st.greeted = true
            speak(l, player, "warn", tier == "welcome" and "The newcomer walked into your " .. st.kind .. ". You like them - welcome them in"
                or "The newcomer walked into your " .. st.kind .. ". You don't mind them, but they should behave", nil, pick(M.terrLines[tier], uid))
            if M.logInteraction then pcall(M.logInteraction, uid, (tier == "welcome" and "Welcomed you into their " or "Let you stay in their ") .. st.kind, nil, nil, "event") end
        end
        return
    end
    -- held: a pause ("wait") or a plea / gift that raised their opinion buys time
    if M.paused and M.paused[uid] and now < M.paused[uid].untilMs then st.nextAt = math.max(st.nextAt, M.paused[uid].untilMs + 3000); return end
    local v = opinion(l.record, player)
    if v >= st.opinionAt + 3 and st.step > 0 then
        st.step = st.step - 1
        st.opinionAt = v
        st.nextAt = now + (M.terrInterval[tier] or 30000)
        log("territory: talked down a step (" .. uid .. ", opinion " .. v .. ")")
        return
    end
    if now < st.nextAt then return end
    local mult = 1
    local lens = M.lens and M.lens(uid) or {}
    mult = mult * (1 + (lens.calm or 0) * 0.5 + (lens.kind or 0) * 0.3 - (lens.volatile or 0) * 0.5 - (lens.paranoid or 0) * 0.3)
    mult = clamp(mult, 0.5, 1.6)
    st.step = st.step + 1
    st.warned = true
    st.opinionAt = v
    st.nextAt = now + math.floor((M.terrInterval[tier] or 30000) * mult)
    if st.step <= 3 then
        local key = "warn" .. st.step
        speak(l, player, "warn", "The newcomer is inside your " .. st.kind .. " and you want them out (warning " .. st.step .. " of 3"
            .. (st.step == 3 and ", the last one - after this you fight" or "") .. ")", "firm, short, in character", pick(M.terrLines[key], uid .. st.step))
        if M.logInteraction then pcall(M.logInteraction, uid, "Warned you off their " .. st.kind .. " (" .. st.step .. "/3)", nil, nil, "event") end
        if st.step >= 2 and fn(PA().NpcOpinion, "adjust") then pcall(PA().NpcOpinion.adjust, l.record, player, -1, "Trespassing on their " .. st.kind) end
        if M.feel then M.feel(uid, "irritation", 0.15, "a trespasser") end
        return
    end
    -- after the last warning: neutral ones (not disliked) just stay sour; disliked / enemies turn hostile
    if tier == "neutral" and v >= 0 then
        if not st.sour then
            st.sour = true
            if fn(PA().NpcOpinion, "adjust") then pcall(PA().NpcOpinion.adjust, l.record, player, -4, "Ignored their warnings") end
            if M.say then M.say(l.shell, player, "Fine. But I'm watching you.", { record = l.record }) end
        end
        return
    end
    local P = patch()
    local turned = false
    if P and fn(P, "attackNow") and M.settings.attackPlayer ~= false then
        local ok, r = pcall(P.attackNow, uid, player, "trespassing")
        turned = ok and r == true
    end
    if M.logInteraction then pcall(M.logInteraction, uid, turned and "Attacked you for trespassing" or "Gave up warning you", nil, nil, "event") end
    if M.addDeed then
        local x, y = pos(player)
        local wit = {}
        for _, w in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, 0, 20) or {}) do wit[#wit + 1] = tostring(w.record.uid) end
        pcall(M.addDeed, "trespass", "the newcomer pushed into someone's " .. st.kind .. " and wouldn't leave", -2, wit, x, y)
    end
    M.terr.done = true
    st.nextAt = now + 3600000
end

-- (3) other NPCs inside a territory
M.terrNpcAt = -1e12
function M.territoryNpcs(near, now)
    if now - M.terrNpcAt < M.terrCfg.npcGapMs then return end
    local pa = PA()
    for _, l in ipairs(near) do
        local m = type(l.record.memory) == "table" and l.record.memory or {}
        local x, y = pos(l.shell)
        local t = nil
        if fn(pa.Havens, "takenAt") then
            local ok, h = pcall(pa.Havens.takenAt, x, y, 0)
            if ok and type(h) == "table" and m.havenId ~= h.id and (h.groupId == nil or m.groupId ~= h.groupId) then t = h end
        end
        if t ~= nil then
            local res = nil
            for _, o in ipairs(near) do
                local om = type(o.record.memory) == "table" and o.record.memory or {}
                if om.havenId == t.id and o ~= l then res = o; break end
            end
            local same = res and res.record.factionId ~= nil and res.record.factionId == l.record.factionId
            if res and not same then
                M.terrNpcAt = now
                local a, b = tostring(res.record.uid), tostring(l.record.uid)
                local row = M.pairRow and M.pairRow(a, b) or nil
                local s = row and tonumber(row.s) or 0
                if s >= 20 then return end -- a friend: no problem
                if M.say then M.say(res.shell, nil, pick(M.terrLines.npcWarn, a .. now), { record = res.record }) end
                local P = patch()
                if s > -15 then
                    if M.say then M.say(l.shell, nil, pick(M.terrLines.npcGo, b .. now), { record = l.record }) end
                    if P and fn(P, "leaveArea") then pcall(P.leaveArea, b, t.bounds, res.shell, M.terrCfg.leaveMs) end
                    if M.pairBump then pcall(M.pairBump, a, b, -2, "told to leave their place") end
                else
                    if M.say then M.say(l.shell, nil, pick(M.terrLines.npcNo, b .. now), { record = l.record }) end
                    if M.pairBump then pcall(M.pairBump, a, b, -5, "refused to leave their place") end
                    if row then
                        row.tr = (row.tr or 0) + 1
                        if row.tr >= 2 and P and fn(P, "npcFeud") and M.settings.attackNpc ~= false then pcall(P.npcFeud, a, b, "territory", 6, true) end
                    end
                end
                if M.logInteraction then
                    pcall(M.logInteraction, a, "Told " .. nameOf(l.record) .. " to leave their place", nil, nil, "event")
                    pcall(M.logInteraction, b, nameOf(res.record) .. " told them to leave", nil, nil, "event")
                end
                return
            end
        end
    end
end

-- (2) the player's base and "leave"
function M.playerBase(player)
    local pa = PA()
    local D = pa and pa.SafehouseDirector
    local key = nil -- 0.5.1.8: marks are keyed by the Director's own playerKey (was Speech.playerKey)
    if D and fn(D, "playerKey") then local okK, k = pcall(D.playerKey, player); if okK then key = k end end
    if key == nil and fn(pa and pa.Speech, "playerKey") then key = pa.Speech.playerKey(player) end
    if D then
        if fn(D, "markOf") and key then local ok, h = pcall(D.markOf, key); if ok and type(h) == "table" and tonumber(h.x1) then return h, "mark" end end
        if fn(D, "claimOf") then local ok, c = pcall(D.claimOf, player); if ok and type(c) == "table" then return c, "safehouse" end end
        if fn(D, "baseOf") then local ok, b = pcall(D.baseOf, player); if ok and type(b) == "table" then return b, "base" end end
    end
    local b = buildingOf(player)
    if b then return buildingBounds(b), "building" end
    return nil
end
M.leaveWords = { "get out of my house", "out of my house", "get out of my", "get out", "get lost", "leave", "go away", "beat it",
    "scram", "out of here", "get off my", "this is my place", "you need to go", "time for you to go", "piss off" }
M.stayWords = { "you can stay", "stay here if you want", "you're welcome to stay", "you are welcome to stay", "stay as long",
    "you can crash here", "make yourself at home" }
M.leaveAsked = {}
function M.leaveDecision(l, player)
    local uid = tostring(l.record.uid)
    local v = opinion(l.record, player)
    local lens = M.lens and M.lens(uid) or {}
    local core = M.partsOf and M.partsOf(uid) or nil
    local k = core and core.core and core.core.key or ""
    local eff = v
    if k == "stubborn" or k == "hothead" or k == "greedy" or k == "proud" or k == "bully" then eff = eff - 15 end
    eff = eff + ((lens.disciplined or 0) + (lens.kind or 0)) * 10 - ((lens.volatile or 0) + (lens.proud or 0)) * 10
    if eff >= 30 then return "friend", eff elseif eff >= -10 then return "neutral", eff elseif eff >= -40 then return "argue", eff end
    return "refuse", eff
end
function M.onLeaveWords(player, text, loud, hearers)
    if M.settings.territory == false then return end
    local low = " " .. string.lower(tostring(text or "")) .. " "
    local has = M.hasWord or function(s, list) for _, w in ipairs(list) do if string.find(s, w, 1, true) then return w end end end
    local stay = has(low, M.stayWords)
    local leave = not stay and has(low, M.leaveWords)
    if not stay and not leave then return end
    local base = M.playerBase(player)
    if base == nil then return end
    local all = string.find(low, "all of you", 1, true) or string.find(low, "everyone", 1, true) or string.find(low, "you all", 1, true)
        or string.find(low, "you people", 1, true)
    local targets = {}
    for i, l in ipairs(hearers or {}) do
        local x, y = pos(l.shell)
        if inside(base, x, y, 3) and (all or i == 1) then targets[#targets + 1] = l end
    end
    local P = patch()
    local now = nowMs()
    local pa = PA()
    for i, l in ipairs(targets) do
        local uid = tostring(l.record.uid)
        local talkingTo = i == 1 and not all
        if stay then
            if P and fn(P, "releaseOrder") then pcall(P.releaseOrder, uid, "leave") end
            M.leaveAsked[uid] = { how = "stay", at = now }
            if fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, l.record, player, 2, "Said they could stay") end
            if M.feel then M.feel(uid, "gratitude", 0.2, "allowed to stay") end
            if not talkingTo and M.say then M.say(l.shell, player, pick(M.terrLines.stay, uid), { record = l.record }) end
            if M.logInteraction then pcall(M.logInteraction, uid, "You said they could stay", nil, nil, "event") end
        else
            local how, eff = M.leaveDecision(l, player)
            local prev = M.leaveAsked[uid]
            if prev and prev.how ~= "stay" and now - prev.at < M.terrCfg.repeatMs then
                if how == "argue" then how = eff < -30 and "fight" or "neutral" elseif how == "refuse" then how = "fight" end
            end
            M.leaveAsked[uid] = { how = how, at = now }
            local line, delta, why = nil, 0, nil
            if how == "friend" then line, delta, why = pick(M.terrLines.leaveFriend, uid .. now), -3, "Told to leave your place"
            elseif how == "neutral" then line, delta, why = pick(M.terrLines.leaveNeutral, uid .. now), -1, "Told to leave your place"
            elseif how == "argue" then line, delta, why = pick(M.terrLines.leaveArgue, uid .. now), -2, "Told to leave - argued"
            elseif how == "refuse" then line, delta, why = pick(M.terrLines.leaveRefuse, uid .. now), -3, "Told to leave - refused"
            else line, delta, why = "You asked for it!", -5, "Told to leave - turned on you" end
            if how == "friend" or how == "neutral" then
                if P and fn(P, "leaveArea") then pcall(P.leaveArea, uid, base, player, M.terrCfg.leaveMs) end
                if M.feel then M.feel(uid, how == "friend" and "sadness" or "irritation", 0.25, "told to leave") end
                if how == "friend" and M.leaveNote and (eff or 0) >= 45 then -- 0.5.1 notes: a close friend leaves a goodbye letter
                    local pn = nil
                    pcall(function() pn = player:getDescriptor():getForename() end)
                    pcall(M.leaveNote, l, "goodbye", { to = pn })
                end
            elseif how == "fight" then
                if P and fn(P, "attackNow") and M.settings.attackPlayer ~= false then pcall(P.attackNow, uid, player, "told to leave") end
            elseif M.feel then M.feel(uid, "anger", 0.2, "told to leave") end
            if delta ~= 0 and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, l.record, player, delta, why) end
            if not talkingTo and M.say then M.say(l.shell, player, line, { record = l.record }) end
            if M.keyMem then pcall(M.keyMem, uid, "leave", "The newcomer told you to leave their place (" .. how .. ")") end
            if M.logInteraction then pcall(M.logInteraction, uid, why, nil, nil, "event") end
            log("leave: " .. uid .. " -> " .. how .. " (" .. tostring(eff) .. ")")
        end
    end
end

table.insert(M.playerWordHooks, M.onLeaveWords)

table.insert(M.requestExtras, function(req, player, listener, now)
    local uid = tostring(listener.record.uid)
    local a = M.leaveAsked[uid]
    if a and now - a.at < 8000 then req.leaveOrder = { how = a.how } end
    local st = M.terr
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and player ~= nil then st = M.terrBy[ALifeSide.keyOf(player)] end -- MP: the talker's
    if st and st.speaker == uid and not st.done then req.territory = { kind = st.kind, step = st.step, tier = st.tier } end
end)

if type(Events) == "table" and Events.OnTick then
    local n = 0
    ALifeHealth.tickAdd("ALifeLLMTalk_Territory", function()
        n = n + 1
        if n % 60 ~= 41 then return end
        local ok, e = pcall(M.territoryTick, nowMs())
        if not ok then log("territory error: " .. tostring(e)) end
    end)
end

return M
