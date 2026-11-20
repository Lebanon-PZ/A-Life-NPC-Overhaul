-- A-Life Talk v3.2: reactions to bad injuries and zombie bites/scratches (NPCs and the player).
-- Read only: player BodyDamage (bitten / scratched / bleeding / deep wounds / health); A-Life NPC wound data on
-- the shell's ModData (ProjectALifeLastBiteAtMs, ProjectALifeTurnAtHours = infected, Speech.severeWound).
-- NPCs who can see it react (one line, cooldowns), shaped by their bond with the victim (our pair layer / A-Life
-- opinion for the player). Some turn on a bitten PLAYER through A-Life only: NpcOpinion.adjust (+ spreadTo for
-- hard cases) and, if that drops them to "Resents you" while close, A-Life's Talk.escalate ladder. A-Life has no
-- NPC->NPC hostility switch, so for a bitten NPC we only change our pair layer and the line they say.
-- Every bite / bad injury goes into the witnesses' (and victim's) event memory.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Injury") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Injury"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Injury") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end
local function log(msg) M.log(msg) end
local function pos(o)
    if o == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end)
    return x, y, z
end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
-- v0.4.0: no-argument engine probes; a method that is missing or needs arguments (B42 BodyDamage:IsBitten(part))
-- is skipped for the rest of the session after its first failure (PZ prints every Java exception, even in pcall)
local function call(obj, ...)
    if obj == nil then return nil end
    for _, name in ipairs({ ... }) do
        if not M.probeOff("inj:" .. name) then
            local f = nil
            pcall(function() f = obj[name] end)
            if f ~= nil then -- (a missing method on this object is just skipped; only a throwing call is switched off)
                local ok, v = pcall(function() return f(obj) end)
                if not ok then M.probeOff("inj:" .. name, true)
                elseif v ~= nil then return v end
            end
        end
    end
    return nil
end

M.inj = { everyMs = 2000, watchTiles = 25, seeTiles = 15, nearSeeTiles = 6, gapMs = 90000,
    turnBase = 15, turnLowOpinion = 25, turnHarsh = 20, turnFriend = -30, turnMax = 70 }
M.injState = {}
M.injNextAt = 0
for _, mode in ipairs({ "injury_self" }) do M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish } end

function M.playerHurt(player)
    local bd = call(player, "getBodyDamage")
    if bd == nil then return nil end
    local s = { bitten = false, scratched = false, severe = false, bleeding = 0 }
    local nb = tonumber((call(bd, "getNumPartsBitten"))) or 0
    local ns = tonumber((call(bd, "getNumPartsScratched"))) or 0
    s.bitten = nb > 0 -- (B42 IsBitten needs a body part; the part count is enough)
    s.scratched = ns > 0
    s.infected = call(bd, "IsInfected", "isInfected") == true
    local health = tonumber((call(bd, "getOverallBodyHealth", "getHealth"))) or 100
    pcall(function()
        local parts = bd:getBodyParts()
        for i = 0, parts:size() - 1 do
            local p = parts:get(i)
            if p:bleeding() then s.bleeding = s.bleeding + 1 end
            if p:deepWounded() and p:bleeding() then s.deep = true end
            if p:bitten() then s.bitten = true end
        end
    end)
    s.severe = health < 40 or s.bleeding >= 2 or s.deep == true
    s.health = math.floor(health)
    return s
end

function M.npcHurt(record, shell)
    local pa = PA()
    local s = { bitten = false, severe = false }
    local data = nil
    pcall(function() data = shell:getModData() end)
    if type(data) ~= "table" then return s end
    s.biteAt = tonumber(data.ProjectALifeLastBiteAtMs)
    s.infected = data.ProjectALifeTurnAtHours ~= nil or (type(record.memory) == "table" and record.memory.infectedTurnAtHours ~= nil)
    if fn(pa.Speech, "severeWound") then pcall(function() s.severe = pa.Speech.severeWound(shell, data, record) == true end) end
    return s
end

local function canSee(shell, target, dist2)
    if dist2 <= M.inj.nearSeeTiles ^ 2 then return true end
    local ok, seen = pcall(function() return shell:CanSee(target) end)
    if ok then return seen == true end
    return dist2 <= 10 * 10
end

local function harsh(record)
    local pa = PA()
    local temper = ""
    if fn(pa.DialogueRoles, "describe") then
        pcall(function() local who = pa.DialogueRoles.describe(record, 0); temper = tostring(who.temperament or "") end)
    end
    return temper == "predator" or temper == "veteran"
end

-- one event: kind = "bite" | "injury"; victim = player or { record, shell }
function M.onHurt(kind, victim, isPlayer, player, detail)
    local pa = PA()
    -- 0.5.1.6: no bites / wounds for the dead (a corpse or a dead record is not "bitten again")
    if not isPlayer then
        if type(victim) ~= "table" or type(victim.record) ~= "table" then return end
        if victim.record.lifecycle == "dead" then return end
        local u = tostring(victim.record.uid)
        if (M.deathRecent and M.deathRecent(u)) or (M.isFinalDead and M.isFinalDead(u)) then return end
        local deadShell = false
        pcall(function() deadShell = victim.shell == nil or victim.shell:isDead() == true end)
        if deadShell then return end
    end
    local now = nowMs()
    local vx, vy = pos(isPlayer and player or victim.shell)
    if vx == nil then return end
    local vname = isPlayer and "the newcomer" or ((fn(pa.Names, "of") and pa.Names.of(victim.record)) or "someone")
    local vuid = isPlayer and "player" or tostring(victim.record.uid)
    local witnesses = {}
    -- v0.4.0: everyone nearby (Talk.listeners skips busy/hostile NPCs, so fights had "0 witnesses")
    local _, _, vz = pos(isPlayer and player or victim.shell)
    for _, l in ipairs(M.nearbyNpcs(vx, vy, vz, M.inj.watchTiles, isPlayer and nil or vuid)) do
        if tostring(l.record.uid) ~= vuid then
            local x, y = pos(l.shell)
            local dd = x and d2(x, y, vx, vy) or 1e12
            if dd <= M.inj.seeTiles ^ 2 and canSee(l.shell, isPlayer and player or victim.shell, dd) then
                local w, t = 0, "stranger"
                if isPlayer then
                    local v = fn(pa.NpcOpinion, "valueOf") and pa.NpcOpinion.valueOf(l.record, player) or 0
                    w, t = math.max(0, math.min(1, (v + 20) / 100)), (M.playerTie and M.playerTie(l.record, player)) or "stranger"
                    l.opinion = v
                elseif M.closeness then w, t = M.closeness(l.record.uid, victim.record.uid) end
                l.w, l.t, l.harsh = w, t, harsh(l.record)
                witnesses[#witnesses + 1] = l
            end
        end
    end
    local spot = (not isPlayer and kind == "bite" and M.biteSpot) and M.biteSpot(vuid, victim.shell, victim.record) or nil
    if not isPlayer and kind ~= "bite" and M.woundsOf then -- 0.5.1: name the worst wound
        local okW, list = pcall(M.woundsOf, vuid, victim.shell, victim.record)
        if okW and list and list[1] then detail = M.woundText(list[1], { short = true }) end
    end
    local what = (kind == "bite") and (vname .. " got bitten by a zombie" .. (spot and (" on the " .. spot) or ""))
        or (vname .. " got badly hurt" .. (detail and (" (" .. detail .. ")") or ""))
    log("hurt: " .. what .. ", " .. #witnesses .. " witness(es)")
    -- memory: witnesses (+ the bitten NPC itself)
    local uids = {}
    for _, l in ipairs(witnesses) do uids[#uids + 1] = tostring(l.record.uid) end
    if not isPlayer then uids[#uids + 1] = vuid end
    if #uids > 0 then
        M.submit({ mode = "event", uid = uids[1], player = player, listener = witnesses[1] or victim,
            event = { kind = kind, what = what, where = M.placeName and M.placeName(vx, vy, 0) or "", x = math.floor(vx), y = math.floor(vy),
                witnesses = uids, victim = vname, victimUid = vuid }, startMs = now, depth = 0 })
        if M.keyMem then for _, u in ipairs(uids) do pcall(M.keyMem, u, kind == "bite" and "bite" or "event", "Saw: " .. what) end end
    end
    -- 0.5.2.10 [pt270u]: the bite row (who saw it, how they deal with it) - the group finds out from here (Bite.lua)
    local biteOn = kind == "bite" and not isPlayer and M.settings.biteCore ~= false and M.noteBite ~= nil
    if biteOn then
        local px, py = pos(player)
        local playerSaw = px ~= nil and d2(px, py, vx, vy) <= M.inj.seeTiles ^ 2
        local wu = {}
        for _, l in ipairs(witnesses) do wu[#wu + 1] = tostring(l.record.uid) end
        pcall(M.noteBite, vuid, spot, wu, playerSaw)
    end
    -- the bitten NPC may speak first (scared, or hiding it). 0.5.2.10: always, in their own way (hide / pray / ask for help)
    if kind == "bite" and not isPlayer and (biteOn or M.roll(100) < 50) then
        local spot = M.biteSpot and M.biteSpot(vuid, victim.shell, victim.record) or nil -- 0.5.1: the exact spot
        local style = (#witnesses > 0 and M.roll(100) < 40) and "you try to hide or downplay it from the others" or "scared, shaken, maybe in denial"
        if biteOn and M.biteSelfStyle then style = M.biteSelfStyle(vuid, witnesses) end
        M.react("injury_self", victim, player, { what = "You just got bitten by a zombie" .. (spot and (" - it bit your " .. spot) or "")
            .. ". You know what that usually means - almost always death",
            style = style, maxWords = 16 }, { key = "self:" .. vuid, keyCooldownMs = M.inj.gapMs, urgent = true })
    end
    if #witnesses == 0 then return end
    table.sort(witnesses, function(a, b) return (a.w or 0) > (b.w or 0) end)
    -- who turns on the victim? (scaled, random; close friends rarely)
    local turned = nil
    if kind == "bite" then
        for _, l in ipairs(witnesses) do
            local p = M.inj.turnBase + (l.harsh and M.inj.turnHarsh or 0)
            if isPlayer then
                if (l.opinion or 0) < 0 then p = p + M.inj.turnLowOpinion end
                if (l.opinion or 0) >= 41 then p = p + M.inj.turnFriend end
                if fn(pa.Party, "friendly") and pa.Party.friendly(l.record, player) then p = p - 20 end
            else
                if (l.w or 0) < 0.15 then p = p + M.inj.turnLowOpinion end
                if (l.w or 0) >= 0.5 then p = p + M.inj.turnFriend end
            end
            p = math.max(0, math.min(M.inj.turnMax, p))
            if M.roll(100) < p then
                turned = l
                if isPlayer and fn(pa.NpcOpinion, "adjust") then
                    local delta = -(10 + M.roll(11))
                    pa.NpcOpinion.adjust(l.record, player, delta, "You got bitten. You could turn.")
                    if l.harsh and fn(pa.NpcOpinion, "spreadTo") then pcall(pa.NpcOpinion.spreadTo, l.record, player, math.floor(delta / 2), "You got bitten.", false) end
                    local v = fn(pa.NpcOpinion, "valueOf") and pa.NpcOpinion.valueOf(l.record, player) or 0
                    local px, py = pos(player)
                    local lx, ly = pos(l.shell)
                    if v <= -41 and px and lx and d2(px, py, lx, ly) <= 144 then pcall(M.escalate, l.record, l.shell, player, pa.Talk.stance(l.record, player)) end
                    log("bite: " .. tostring(pa.Names.of(l.record)) .. " turns on you (" .. delta .. ")")
                else
                    if M.pairBump then pcall(M.pairBump, l.record.uid, victim.record.uid, -30, "got bitten - a danger now") end
                    -- v0.3.3: with A-Life Talk Patch they really turn on the bitten NPC (A-Life targeting): harsh types
                    -- attack, others keep away; the bitten one is wary of them; both fade after a day
                    local P = M.patch and M.patch() or nil
                    if P ~= nil and type(P.setPairStance) == "function" then
                        pcall(P.setPairStance, l.record.uid, victim.record.uid, l.harsh and "hostile" or "careful", 24, "bitten", "careful")
                    end
                end
                break
            end
        end
    end
    local speaker = turned or witnesses[1]
    local close = (speaker.w or 0) >= 0.5
    local style
    if kind == "bite" then
        if speaker == turned then style = "you turn on them: they're bitten, they'll turn; demand they leave or keep away, maybe threaten"
        elseif close then style = "they're your " .. tostring(speaker.t) .. ": denial, grief, desperate hope, offer to help"
        else style = "fear and suspicion; you know what a bite means" end
        if biteOn and speaker ~= turned and M.biteStance and M.biteStanceText then -- 0.5.2.10: from the tie AND who they are
            local st = M.biteStance(speaker.record.uid, vuid)
            style = "they're your " .. tostring(speaker.t) .. ": " .. tostring(M.biteStanceText[st])
        end
        if not turned and close and M.pairBump and not isPlayer then pcall(M.pairBump, speaker.record.uid, victim.record.uid, 5, "stood by them when bitten") end
    else
        style = close and ("they're your " .. tostring(speaker.t) .. ": worried, rush to help (bandage, stop the bleeding)")
            or "concern or a practical warning; offer help if you're decent"
    end
    M.react("injury", speaker, player, { what = "You just saw " .. what, style = style, maxWords = 16 },
        { key = "injury:" .. vuid .. ":" .. kind, keyCooldownMs = M.inj.gapMs, urgent = kind == "bite", face = isPlayer and "player" or nil })
end

function M.injuryTick()
    local now = nowMs()
    if now < M.injNextAt or not M.settings.enabled then return end
    M.injNextAt = now + M.inj.everyMs
    M.eachPlayer(M.injuryTickFor) -- pre-1.0 MP (P3): every player's wounds (single player: yours)
end
-- pre-1.0 MP: a player's own state slot ("player" in single player, as before; "player:<key>" on a server)
function M.injSlot(player)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and player ~= nil then return "player:" .. tostring(ALifeSide.keyOf(player)) end
    return "player"
end
function M.injuryTickFor(player)
    local pa = PA()
    if player == nil or not fn(pa and pa.Talk, "listeners") then return end
    local ps = M.playerHurt(player)
    local slot = M.injSlot(player)
    local old = M.injState[slot]
    if ps ~= nil then
        if old ~= nil then
            if (ps.bitten and not old.bitten) then M.onHurt("bite", nil, true, player, nil)
            elseif ps.severe and not old.severe then M.onHurt("injury", nil, true, player, ps.deep and "deep bleeding wound" or ("health " .. ps.health)) end
        end
        M.injState[slot] = ps
    end
    for _, l in ipairs(pa.Talk.listeners(player, M.inj.watchTiles)) do
        local uid = tostring(l.record.uid)
        local s = M.npcHurt(l.record, l.shell)
        local o = M.injState[uid]
        if o ~= nil then
            local newBite = (s.biteAt ~= nil and s.biteAt ~= o.biteAt) or (s.infected and not o.infected)
            if newBite then M.onHurt("bite", l, false, player, nil)
            elseif s.severe and not o.severe then M.onHurt("injury", l, false, player, "badly wounded") end
        end
        M.injState[uid] = s
    end
    if M.biteTick then pcall(M.biteTick, player) end -- 0.5.2.10 [pt270u]: confide / news, one step per bitten person per gap
end

-- prompt: the player's visible state (so "let me see your arm" can happen later)
table.insert(M.requestExtras, function(req, player, listener, now)
    local s = M.injState[M.injSlot(player)]
    if s ~= nil and (s.bitten or s.severe or s.bleeding > 0) then
        req.you = req.you or {}
        req.you.hurt = (s.bitten and "bitten " or "") .. ((s.bleeding > 0) and "bleeding " or "") .. (s.severe and "badly hurt" or "")
    end
end)

return M
