-- A-Life Talk 0.5.1: NPCs talk about their wounds on their own (ambient overhead lines).
-- Every few seconds one hurt NPC near you may say something about the exact wound ("Ah, my left leg... I think it's
-- broken", "Shit, I'm bleeding bad", "It bit me... oh god, it bit me", "This burn won't stop stinging") or about a
-- hurt friend nearby ("You're limping, man, sit down"). Chance per check x pain / severity x personality (stoic ones
-- rarely, dramatic / anxious ones often) x the "Wound talk" frequency setting; a per-NPC and a global cooldown keep
-- it from getting spammy. Fresh hits get an instant grunt / wince. The AI writes the line (mode "wound_talk") with a
-- canned fallback; with voice on, the bridge speaks it with Piper (canned lines too, through the "speak" mode).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_WoundTalk") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "WoundTalk"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("WoundTalk") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

for k, v in pairs({ woundTalk = true, woundTalkFreq = 100 }) do if M.settings[k] == nil then M.settings[k] = v end end
if type(M.fileKeys) == "table" then
    for _, key in ipairs({ "woundTalk", "woundTalkFreq" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
M.woundTalkCfg = { tickMs = 4000, tiles = 22, baseChance = 6, npcGapMs = 150000, globalGapMs = 18000, otherTiles = 6, gruntGapMs = 2500 }
M.woundSelfAt = { any = -1e12, npc = {} }
M.woundTalkRoll = nil -- tests: fixed roll 0..99

-- how talkative about pain: stoic 0.2 .. dramatic 2.0
function M.woundTalkPersona(uid)
    local p = M.partsOf and M.partsOf(uid) or nil
    local k = p and p.core and p.core.key or ""
    local lens = M.lens and M.lens(uid) or {}
    local m = 1 + (lens.fearful or 0) * 0.8 + (lens.unhinged or 0) * 0.4 + (lens.cheerful or 0) * 0.2 - (lens.disciplined or 0) * 0.5 - (lens.calm or 0) * 0.4
    if k == "stoic" or k == "hardass" or k == "cold" or k == "survivalist" or k == "withdrawn" then m = m * 0.25 end
    if k == "coward" or k == "jokester" or k == "braggart" or k == "hedonist" or k == "gossip" or k == "paranoid" or k == "thrill" then m = m * 1.8 end
    return clamp(m, 0.15, 2.2), k
end

M.woundSelf = {
    fracture = { "Ah, my {p}... I think it's broken.", "Can't put weight on my {p}. It's broken, I know it.", "My {p}... something snapped." },
    bite = { "It bit me... oh god, it bit me.", "My {p}... it bit me. I'm done, aren't I?", "Don't look at me like that. It's just a bite... right?" },
    bullet = { "Took a bullet in the {p}. Hurts like hell.", "There's still a slug in my {p}, I swear.", "Getting shot is overrated." },
    burn = { "This burn won't stop stinging.", "My {p}'s on fire still, feels like.", "Damn burn. Can't stop touching it." },
    deep = { "This cut on my {p} is deep. Real deep.", "I can see... no, I don't want to look at my {p}." },
    laceration = { "My {p}'s cut up bad.", "Ugh, this gash on my {p}." },
    scratch = { "Just a scratch. Just a scratch...", "Stings, this scratch on my {p}." },
    sprain = { "Twisted my {p}. Stupid.", "My {p}'s swollen up like a balloon." },
    bruise = { "My {p}'s all black and blue.", "Everything aches." },
    amputation = { "I keep feeling my {p}. It's not there.", "Phantom itch again..." },
    maimed = { "I can't stand up. I can't stand up!", "My legs won't work..." },
    bleeding = { "Shit, I'm bleeding bad.", "I need a bandage. Now.", "Why won't it stop bleeding?" },
    dark = { "Hurts. Whatever.", "Figures I'd get hurt.", "Pain's the only thing that's real anymore." },
}
M.woundOther = {
    limp = { "You're limping, {n}. Sit down a minute.", "{n}, take a load off that leg.", "Slow down, {n}, you're limping." },
    bleeding = { "{n}, you're bleeding - get that wrapped!", "Hey, {n}, you're dripping blood." },
    bite = { "{n}... let me see that bite.", "Is that a bite, {n}? Tell me it isn't." },
    generic = { "You okay, {n}? You look rough.", "{n}, you need to rest." },
}
M.woundGrunts = { "Agh!", "Ngh-!", "Ow!", "Hnn...", "Argh!", "Ah - damn!", "Ugh!" }

local function worst(list)
    local best, bs = nil, -1
    for _, w in ipairs(list or {}) do
        local s = (w.sev or 0) + (w.bleeding and 30 or 0) + (w.kind == "bite" and 40 or 0) + (w.kind == "fracture" and 25 or 0) - ((w.ageH or 0) > 48 and 20 or 0)
        if s > bs then best, bs = w, s end
    end
    return best
end
function M.woundSelfLine(uid, s, seed)
    local w = worst(s.list)
    if w == nil then return nil, nil end
    local kind = w.kind
    if s.bleeding > 0 and kind ~= "bite" and (hash(seed .. "b") % 2 == 0) then kind = "bleeding" end
    local style = M.personaKind and select(1, M.personaKind(uid)) or nil
    local pool = M.woundSelf[kind] or M.woundSelf.bruise
    if style == "dark" and kind ~= "bite" and hash(seed .. "d") % 3 == 0 then pool = M.woundSelf.dark end
    local part = tostring(w.part or "leg")
    return (string.gsub(pick(pool, seed), "{p}", part)), w
end

function M.woundTalkChance(uid, s)
    local persona = M.woundTalkPersona(uid)
    local sev = math.max(s.pain or 0, s.bleeding > 0 and 0.5 or 0, s.bitten and 0.6 or 0, s.fracture and 0.5 or 0)
    local freq = clamp(tonumber(M.settings.woundTalkFreq) or 100, 0, 300) / 100
    return M.woundTalkCfg.baseChance * (0.3 + sev * 2.2) * persona * freq, persona
end

local function sayLine(l, player, mode, what, fallback)
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = "a short line to yourself or the people around, out loud, in character",
        maxWords = 12, fallback = fallback }, { key = "woundtalk:" .. tostring(l.record.uid), keyCooldownMs = 60000, modeCooldownMs = 12000 })
    if not ok then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return ok
end

function M.woundTalkTick(now)
    if M.settings.woundTalk == false or M.settings.wounds == false or not M.worldHere() then return end
    if now - M.woundSelfAt.any < M.woundTalkCfg.globalGapMs then return end
    M.eachPlayer(M.woundTalkTickFor, now) -- pre-1.0 MP: near every player (SP: you)
end
function M.woundTalkTickFor(player, now)
    if now - M.woundSelfAt.any < M.woundTalkCfg.globalGapMs then return end
    if player == nil or not M.woundState then return end
    local x, y, z = pos(player)
    local near = M.nearbyNpcs and M.nearbyNpcs(x, y, z, M.woundTalkCfg.tiles) or {}
    local pa = PA()
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        if now - (M.woundSelfAt.npc[uid] or -1e12) >= M.woundTalkCfg.npcGapMs and not (fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now))
                and not (M.inCombat and M.inCombat(l.shell, l.record)) then
            local ok, s = pcall(M.woundState, uid, l.shell, l.record)
            if ok and s and s.hurt then
                local chance, persona = M.woundTalkChance(uid, s)
                local r = M.woundTalkRoll or (hash(uid .. "#wt#" .. math.floor(now / M.woundTalkCfg.tickMs)) % 100)
                if r < chance then
                    local text, w = M.woundSelfLine(uid, s, uid .. math.floor(now / 60000))
                    if text then
                        M.woundSelfAt.any, M.woundSelfAt.npc[uid] = now, now + math.floor(M.woundTalkCfg.npcGapMs * (1 / persona - 1) * 0.5)
                        sayLine(l, player, "wound_talk", "Your " .. (M.woundText and M.woundText(w, { short = true }) or "wound") .. " hurts (pain "
                            .. math.floor((s.pain or 0) * 100) .. "%). Say something about it unprompted", text)
                        log("wound talk: " .. uid .. " (" .. tostring(w.kind) .. ", chance " .. ALifeFmtDec(chance, 1) .. ")")
                        return true
                    end
                end
            end
        end
    end
    -- someone notices a hurt friend
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        if now - (M.woundSelfAt.npc[uid] or -1e12) >= M.woundTalkCfg.npcGapMs then
            local lx, ly, lz = pos(l.shell)
            for _, o in ipairs(M.nearbyNpcs and lx and M.nearbyNpcs(lx, ly, lz, M.woundTalkCfg.otherTiles, uid) or {}) do
                local ou = tostring(o.record.uid)
                local w = M.closeness and select(1, M.closeness(uid, ou)) or 0
                if w >= 0.3 then
                    local ok, s = pcall(M.woundState, ou, o.shell, o.record)
                    if ok and s and s.hurt and (s.limp or s.bleeding > 0 or s.bitten) then
                        local r = M.woundTalkRoll or (hash(uid .. ou .. math.floor(now / M.woundTalkCfg.tickMs)) % 100)
                        local freq = clamp(tonumber(M.settings.woundTalkFreq) or 100, 0, 300) / 100
                        if r < M.woundTalkCfg.baseChance * 1.5 * freq then
                            local kind = s.bitten and "bite" or (s.bleeding > 0 and "bleeding") or (s.limp and "limp") or "generic"
                            local n = M.nameParts and (M.nameParts(o.record) or {}).first or "man"
                            local text = (string.gsub(pick(M.woundOther[kind], uid .. ou), "{n}", n))
                            M.woundSelfAt.any, M.woundSelfAt.npc[uid] = now, now
                            sayLine(l, player, "wound_talk", "Your friend " .. tostring(n) .. " is hurt (" .. kind .. "). Say something to them", text)
                            log("wound talk (other): " .. uid .. " -> " .. ou .. " (" .. kind .. ")")
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- fresh hits: an instant grunt / wince (no AI; the injury_self AI line may follow)
M.gruntAt = {}
function M.woundGrunt(body, attacker, damage)
    if M.settings.woundTalk == false or not M.worldHere() then return end
    local uid = M.uidOf and M.uidOf(body) or nil
    if uid == nil then return end
    local now = nowMs()
    if now - (M.gruntAt[uid] or -1e12) < M.woundTalkCfg.gruntGapMs then return end
    M.gruntAt[uid] = now
    local persona = M.woundTalkPersona(uid)
    if persona < 0.3 and hash(uid .. now) % 3 ~= 0 then return end -- stoic: mostly silent
    local txt = pick(M.woundGrunts, uid .. now)
    if M.ownSay then pcall(M.ownSay, body, txt, {}, true) else pcall(function() PA().Speech.say(body, txt, {}) end) end -- 0.5.2.3: ours, keeps the guard
end

-- voice for a canned line (bridge "speak" mode: no model call, just Piper)
function M.voiceOnly(l, player, text)
    if M.settings.voice == false or not (M.bridgeAlive and M.bridgeAlive(nowMs())) then return false end
    for _, q in ipairs(M.queue or {}) do if q.mode == "speak" then return false end end
    table.insert(M.queue, { mode = "speak", uid = tostring(l.record.uid), player = player, listener = l, text = text, startMs = nowMs(), depth = 0 })
    if M.pump then M.pump(nowMs()) end
    return true
end
M.eventModes.speak = {
    request = function(job, now)
        local listener = (M.refresh and M.refresh(job)) or job.listener
        if listener == nil then return nil end
        local req = M.buildRequest(job.player, listener, "", nil, "neutral", now)
        req.mode, req.text = "speak", job.text
        req.acts, req.actHints = {}, {}
        return req
    end,
    finish = function() end,
}
M.eventModes.wound_talk = { request = M.reactRequest, finish = M.reactFinish }

if type(Events) == "table" then
    if type(Events.ProjectALife_NpcHit) == "table" and type(Events.ProjectALife_NpcHit.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcHit, "ALifeLLMTalk_WoundTalk", function(body, attacker, damage) pcall(M.woundGrunt, body, attacker, damage) end)
    end
    if Events.OnTick then
        local last = -1e12
        ALifeHealth.tickAdd("ALifeLLMTalk_WoundTalk", function()
            local now = nowMs()
            if now - last < M.woundTalkCfg.tickMs then return end
            last = now
            local ok, e = pcall(M.woundTalkTick, now)
            if not ok then log("wound talk error: " .. tostring(e)) end
        end)
    end
end

return M
