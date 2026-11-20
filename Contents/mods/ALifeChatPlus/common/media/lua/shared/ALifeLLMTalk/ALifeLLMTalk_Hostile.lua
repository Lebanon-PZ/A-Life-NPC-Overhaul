-- A-Life Talk v3.2: talking to hostile NPCs, also mid-fight.
--
-- Where it was blocked: A-Life's Talk.listeners / Talk.addressee do NOT filter hostiles (only other floors and
-- downed/dead bodies), but Talk.respond answers a fighting NPC with a TALK_BUSY_COMBAT bark and a hostile one with
-- canned TALK_IGNORE_HOSTILE lines, and our own 0.3.x tryDefer bailed out on Talk.busy / hostile. A fighting NPC
-- beyond A-Life's listen radius (12 / shout 25 tiles) is "nobody" to A-Life.
-- Now: free-text lines to a hostile or fighting NPC get a short AI combat line (threat, taunt, bark, or wavering).
-- A-Life's own handlers still win first and unchanged: robbery and standoff words (Talk.onPlayerText runs
-- ModuleRobbery / Standoff before anyone answers), shout warnings (ModuleCareful.hearShout), A-Life's yes/no
-- questions and every preset intent (M.isNative) -> A-Life's normal reply.
-- Persuasion only through A-Life: NpcOpinion.adjust (bounded +1..+3 per plea, diminishing, cooldown) and, when
-- they are NOT in a fight, not holding a grudge and opinion >= hostileCalmAt, A-Life's own talk-down encounter
-- Standoff.start(actor, shell, player, "surprise") which can end in a truce (A-Life then treats them as careful).
-- Insults mid-fight cost opinion. We never set anyone friendly.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Hostile") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Hostile"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Hostile") end end -- 0.5.1.6 perf label

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
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

M.settings.hostileTalk = true
M.combat = {
    reachTiles = 20, shoutReachTiles = 35,   -- fighting NPCs you can still reach by voice beyond A-Life's radius
    lineGapMs = 2500,                        -- per NPC
    pleaWindowMs = 600000, pleaCooldownMs = 15000, pleaMax = 3,
    calmAt = -25,                            -- opinion needed before we ask A-Life for a talk-down (Standoff)
    calmCooldownMs = 300000,
    tauntEveryMs = 3000, tauntChance = 30, tauntGapMs = 25000, tauntTiles = 25,
    pleaWords = { "surrender", "i give up", "don't shoot", "dont shoot", "please", "truce", "peace", "stop fighting",
        "sorry", "mercy", "i yield", "we don't have to", "no need to", "let's talk", "lets talk", "hold your fire",
        "cease fire", "ceasefire", "i'm unarmed", "im unarmed", "put it down" },
}
M.pleas = {}
M.lineAt = {}

local function lower(s) return string.lower(tostring(s or "")) end
local function hasAny(low, list) for _, w in ipairs(list) do if string.find(low, w, 1, true) then return true end end return false end

-- what is this NPC doing in the fight? (prompt context; read only)
function M.fightView(record, shell, player, now)
    local pa = PA()
    local talk = pa.Talk
    local v = { hostile = fn(talk, "stance") and talk.stance(record, player) == "hostile" or false,
        fighting = fn(talk, "busy") and talk.busy(record, now) or false }
    if not v.hostile and not v.fighting then return nil end
    pcall(function()
        local t = shell:getTarget()
        if t == nil then return end
        if t == player then v.target = "you (the newcomer)"
        elseif instanceof(t, "IsoZombie") then
            local uid = M.uidOf(t)
            if uid ~= nil then
                local r = pa.ActorRegistry.read(uid)
                v.target = (r and fn(pa.Names, "of") and pa.Names.of(r)) or "another survivor"
            else v.target = "zombies" end
        elseif instanceof(t, "IsoPlayer") then v.target = "another person" end
    end)
    pcall(function()
        local data = shell:getModData()
        local maximum = tonumber(data.ProjectALifeMaximumHealth)
        local sim = pa.ShellSimulation
        local hp = fn(sim, "trueHealth") and tonumber((sim.trueHealth(shell))) or tonumber((shell:getHealth()))
        if maximum and maximum > 0 and hp then v.hp = math.floor(clamp(hp / maximum, 0, 1) * 100) end
    end)
    if v.hp == nil and fn(pa.Speech, "severeWound") then
        pcall(function() if pa.Speech.severeWound(shell, shell:getModData(), record) then v.hp = 20 end end)
    end
    if record.activity == "fleeing" or record.intent == "retreat" or record.intent == "gun_flee" then v.fleeing = true end
    local mates = 0
    if fn(talk, "groupMembers") then pcall(function() mates = #talk.groupMembers(record, 15, shell) end) end
    v.mates = mates
    -- 0.8.11.2 (Miller): what the AI needs to read a shout right: the dead around them, you fighting beside them, trust
    pcall(function() M.fightExtras(v, record, shell, player) end)
    return v
end

M.combat.zombieTiles = M.combat.zombieTiles or 8
M.combat.besideTiles = M.combat.besideTiles or 4
function M.fightExtras(v, record, shell, player)
    local x, y, z = pos(shell)
    local px, py, pz = pos(player)
    if x == nil then return end
    local near, mine = 0, 0
    local zr, br = M.combat.zombieTiles, M.combat.besideTiles
    local list = getCell() and getCell():getZombieList() or nil
    if list ~= nil then
        for i = 0, math.min(list:size(), 400) - 1 do
            local zz = list:get(i)
            local zx, zy, zzz = pos(zz)
            if zx ~= nil and math.floor(zzz or 0) == math.floor(z or 0) then
                local alive = true
                pcall(function() alive = not zz:isDead() end)
                if alive then
                    if (zx - x) ^ 2 + (zy - y) ^ 2 <= zr * zr then near = near + 1 end
                    if px ~= nil and (zx - px) ^ 2 + (zy - py) ^ 2 <= br * br then mine = mine + 1 end
                end
            end
        end
    end
    v.zombies = near
    local armed = false
    pcall(function()
        local w = player:getPrimaryHandItem()
        armed = w ~= nil and instanceof(w, "HandWeapon") and tostring(w:getFullType()) ~= "Base.BareHands"
    end)
    local close = px ~= nil and (px - x) ^ 2 + (py - y) ^ 2 <= 100
    v.youHelp = (close and mine > 0 and armed) or nil -- you're fighting the dead right next to them
    local okV, val = pcall(function() return PA().NpcOpinion.valueOf(record, player) end)
    local o = okV and tonumber(val) or nil
    if o ~= nil then
        v.trust = o >= 41 and "trusts" or o >= 10 and "warming" or o > -25 and "stranger" or "distrusts"
    end
    if v.target ~= nil and string.find(v.target, "you", 1, true) == nil then v.vsDead = (v.target == "zombies") or nil end
    if v.target == nil and near > 0 and not v.hostile then v.vsDead = true end
end

-- "Get outta here!" / "Back off!" / "Run!" / "Behind you!" to someone fighting the dead: a warning, not a threat.
-- No threat words, no insults; whole words only.
M.fightWarnWords = { "get outta here", "get out of here", "get out", "get outta", "get back", "back off", "get away",
    "go go", "run", "move", "leave", "fall back", "retreat", "behind you", "look out", "watch out", "get clear",
    "get down", "they're coming", "theyre coming", "too many", "come on", "this way", "over here", "go now", "go" }
M.fightWarnVeto = { "kill you", "shoot you", "or i", "or else", "i'll", "ill kill", "you're dead", "youre dead", "fuck you",
    "bitch", "asshole", "idiot", "hands up", "drop it", "drop your", "hand over", "give me" }
function M.isFightWarning(text)
    local low = " " .. string.gsub(string.lower(tostring(text or "")), "[^%w']+", " ") .. " "
    for _, w in ipairs(M.fightWarnVeto) do if string.find(low, " " .. w .. " ", 1, true) then return false end end
    for _, w in ipairs(M.fightWarnWords) do
        if string.find(low, " " .. w .. " ", 1, true) then return true end
    end
    return false
end

table.insert(M.requestExtras, function(req, player, listener, now)
    local v = M.fightView(listener.record, listener.shell, player, now)
    if v ~= nil then req.fight = v end
end)

-- called from Main.tryDefer for hostile / fighting listeners
function M.hostileDefer(player, listener, text, now, stance)
    if not M.settings.hostileTalk then return false end
    local pa = PA()
    local talk, speech, data, intents = pa.Talk, pa.Speech, pa.DialogueData, pa.TalkIntents
    local record, shell = listener.record, listener.shell
    data.load()
    local playerKey = speech.playerKey(player)
    local state = talk.state(playerKey, record.uid, now)
    local intent = intents.classify(text, state.pending ~= nil, data)
    if M.isNative(intent, state) then return false end -- A-Life's own preset answer
    if now - (M.lineAt[tostring(record.uid)] or -1e12) < M.combat.lineGapMs then return false end
    M.lineAt[tostring(record.uid)] = now
    local job = { mode = "reply", uid = tostring(record.uid), player = player, listener = listener, text = text,
        intent = intent, stance = stance, startMs = now, playerKey = playerKey, depth = 0, hostile = true }
    job.sync = true
    M.submit(job)
    job.sync = nil
    if job.failed then return false end
    M.notePlayerLine(player, text)
    if fn(speech, "engineLine") then pcall(speech.engineLine, shell, "...", { 0.75, 0.75, 0.75 }) end
    M.metrics.asked = M.metrics.asked + 1
    M.metrics.hostile = (M.metrics.hostile or 0) + 1
    return true, "...", "ai_pending"
end

-- far fighters: A-Life found nobody in its radius; reach the nearest hostile / fighting NPC by voice
function M.hostileReach(player, text, loud)
    local pa = PA()
    if not M.settings.hostileTalk or not M.worldHere() or not fn(pa.Talk, "listeners") then return false end
    local now = nowMs()
    local r = loud and M.combat.shoutReachTiles or M.combat.reachTiles
    for _, l in ipairs(pa.Talk.listeners(player, r)) do
        local stance = pa.Talk.stance(l.record, player)
        if stance == "hostile" or pa.Talk.busy(l.record, now) then
            local okD, deferred = pcall(M.hostileDefer, player, l, text, now, stance)
            return okD and deferred == true
        end
    end
    return false
end

function M.hostileFightNear(player)
    local pa = PA()
    player = M.you(player)
    if player == nil or not fn(pa and pa.Talk, "listeners") then return false end
    local now = nowMs()
    for _, l in ipairs(pa.Talk.listeners(player, M.combat.tauntTiles)) do
        if pa.Talk.stance(l.record, player) == "hostile" and pa.Talk.busy(l.record, now) then return true end
    end
    return false
end

-- the AI answered a hostile / fighting NPC
function M.finishHostile(p, r, listener)
    local pa = PA()
    local talk, opinion = pa.Talk, pa.NpcOpinion
    local player, record, shell = p.player, listener.record, listener.shell
    local now = nowMs()
    local text = r.text
    if type(text) == "string" and text ~= "" then M.say(shell, player, text, { record = record, combat = true }) end
    local stance = talk.stance(record, player)
    -- v0.3.3: their own "hands up / hand it over" -> A-Life's robbery (only with A-Life Talk Patch, A-Life's rules)
    if M.maybeRob and type(text) == "string" then pcall(M.maybeRob, record, player, text, stance) end
    local uid = tostring(record.uid)
    local low = lower(p.text)
    local plea = (r.d or 0) > 0 or r.tone == "SORRY" or r.tone == "I_AM_FRIENDLY" or hasAny(low, M.combat.pleaWords)
    -- 0.8.11.2 (Miller): only a real insult / threat is rude. A slightly negative score or "go away" tone mid-fight
    -- ("Get outta here!", "Back off!", "Run!") is a warning to someone fighting the dead, not an attack on them.
    local rude = r.tone == "INSULT" or r.tone == "THREATEN" or (r.d or 0) <= (tonumber(M.settings.escalateAt) or -5)
    local warning = stance ~= "hostile" and M.settings.fightWarnTalk ~= false and M.isFightWarning
        and M.isFightWarning(p.text) or false
    if warning then rude = false end
    if rude then plea = false end
    local P = M.patch and M.patch() or nil
    if stance ~= "hostile" and not (M.isPaused and M.isPaused(uid)) then plea = false end -- 0.5.1: a paused enemy hears the plea -- a busy (zombie-fighting) neutral NPC: no plea bookkeeping
    if plea and P ~= nil and type(P.plead) == "function" then
        -- v0.3.3: A-Life Talk Patch's plea (bounded, diminishing, cooldown); the patch then lets them really stop
        -- being hostile once their opinion has climbed past the threshold for a few seconds
        local okP, res = pcall(P.plead, record, shell, player, { strength = (r.d or 0) >= 2 and 1.25 or 1 })
        if okP and type(res) == "table" then
            log("plea via patch: " .. tostring(res.ok) .. " " .. tostring(res.reason or ("+" .. tostring(res.delta) .. " -> " .. tostring(res.opinion)
                .. " (needs " .. tostring(res.need) .. ")")))
        end
    elseif plea and fn(opinion, "adjust") then
        local row = M.pleas[uid] or { n = 0, at = -1e12, first = now }
        if now - row.first > M.combat.pleaWindowMs then row.n, row.first = 0, now end
        if now - row.at >= M.combat.pleaCooldownMs and row.n < M.combat.pleaMax then
            local base = clamp(math.max(1, r.d or 1), 1, 3)
            local delta = math.max(1, math.floor(base * ({ 1, 0.66, 0.34 })[row.n + 1] + 0.5))
            row.n, row.at = row.n + 1, now
            opinion.adjust(record, player, delta, "You tried to talk them down.")
            log("plea to hostile: opinion +" .. delta .. " (" .. row.n .. "/" .. M.combat.pleaMax .. " this encounter)")
        end
        M.pleas[uid] = row
        -- A-Life's own talk-down encounter, only outside a fight and only when they think well enough of you
        local value = fn(opinion, "valueOf") and (opinion.valueOf(record, player) or -100) or -100
        local fighting = fn(talk, "inFight") and talk.inFight(record, now) or talk.busy(record, now)
        local standoff = pa.Standoff
        if stance == "hostile" and not fighting and value >= M.combat.calmAt and fn(standoff, "start")
                and now - (row.calmAt or -1e12) > M.combat.calmCooldownMs then
            row.calmAt = now
            local okS, s, why = pcall(standoff.start, record, shell, player, "surprise", nil, now)
            log("asked A-Life for a talk-down (Standoff.start): " .. (okS and (s and "started" or tostring(why)) or tostring(s)))
        end
    elseif rude and fn(opinion, "adjust") then
        local delta = clamp(math.floor((r.d or -2) * 1.5), -12, -1)
        opinion.adjust(record, player, delta, r.tone == "THREATEN" and "You threatened them in a fight." or "You taunted them in a fight.")
        if stance ~= "hostile" then pcall(M.escalate, record, shell, player, stance, 1, "rude mid-fight (" .. tostring(r.tone) .. ")") end -- neutral NPC busy with zombies
    elseif warning then
        log("fight warning, not a threat: '" .. string.sub(tostring(p.text), 1, 60) .. "'")
    end
    local mem = M.memFor(p.uid)
    local day = 0
    pcall(function() day = getGameTime():getNightsSurvived() end)
    mem.lines[#mem.lines + 1] = { day = day, ms = now, you = string.sub(p.text, 1, 160), me = string.sub(tostring(text or ""), 1, 200) }
    while #mem.lines > M.settings.memLines do table.remove(mem.lines, 1) end
    if M.noteTalkMemory then pcall(M.noteTalkMemory, p, r, nil) end
end

-- hostile fighters yell at you on their own; comrades fighting side by side bond a little
M.tauntNextAt = 0
M.tauntAt = {}
function M.hostileTick()
    local now = nowMs()
    if not M.settings.hostileTalk or now < M.tauntNextAt then return end
    M.tauntNextAt = now + M.combat.tauntEveryMs
    M.eachPlayer(M.hostileTickFor, now) -- pre-1.0 MP (P2b): every player's fights (single player: yours)
end
function M.hostileTickFor(player, now)
    local pa = PA()
    if player == nil or not fn(pa and pa.Talk, "listeners") then return end
    local fighters = {}
    for _, l in ipairs(pa.Talk.listeners(player, M.combat.tauntTiles)) do
        if pa.Talk.busy(l.record, now) then fighters[#fighters + 1] = l end
    end
    if #fighters == 0 then return end
    if M.bondDanger and #fighters >= 2 then -- 0.5.1: a fight survived together
        local ids = {}
        for _, f in ipairs(fighters) do if pa.Talk.stance(f.record, player) ~= "hostile" then ids[#ids + 1] = f.record.uid end end
        if #ids >= 2 then M.bondDanger("fight", ids) end
    end
    -- side by side: same group, both fighting -> pair bond +1 (once a minute)
    if M.pairBump and #fighters >= 2 and now - (M.sideBySideAt or -1e12) > 60000 then
        M.sideBySideAt = now
        for i = 1, #fighters - 1 do
            local a, b = fighters[i].record, fighters[i + 1].record
            local ga = type(a.memory) == "table" and a.memory.groupId or nil
            if ga ~= nil and type(b.memory) == "table" and b.memory.groupId == ga then pcall(M.pairBump, a.uid, b.uid, 1, "fought side by side") end
        end
    end
    local l = fighters[M.roll(#fighters) + 1]
    local uid = tostring(l.record.uid)
    if now - (M.tauntAt[uid] or -1e12) < M.combat.tauntGapMs or M.roll(100) >= M.combat.tauntChance then return end
    local hostile = pa.Talk.stance(l.record, player) == "hostile"
    local v = M.fightView(l.record, l.shell, player, now) or {}
    local what, style
    if hostile and (v.target == nil or string.find(v.target, "you", 1, true)) then
        what = "You're in a fight with the newcomer"
        style = (v.hp and v.hp < 35) and "you're badly hurt: panic, waver, or curse them while backing off"
            or "a combat bark at them: threat, taunt, or order to your people"
    else
        what = "You're fighting " .. tostring(v.target or "zombies") .. " near the newcomer"
        style = "a quick combat call-out (warning, cover me, reloading, they're everywhere)"
    end
    M.tauntAt[uid] = now
    M.react("taunt", l, player, { what = what, style = style, maxWords = 8 },
        { key = "taunt:" .. uid, keyCooldownMs = M.combat.tauntGapMs, modeCooldownMs = 9000, urgent = true,
          face = hostile and "player" or nil })
end

print("[ALifeHostile] ready v0.8.11.2: hostile needs " .. tostring(M.settings.hostileSigns or 2) .. " signs, fight warnings "
    .. (M.settings.fightWarnTalk ~= false and "on" or "off") .. ", foreign lines to the AI, input log "
    .. (M.settings.inputLog ~= false and "on" or "off"))

return M
