-- A-Life Talk v3: ambient NPC-to-NPC conversation (no player trigger) + simple settings file.
--
-- Timer: ALifeLLMTalk.onTick calls M.ambientTick about once a second; it only does real work when the jittered
-- timer (ambientMinSec..ambientMaxSec real seconds) is due. A scene starts only if ALL of these hold:
--   * ambient enabled, singleplayer, bridge alive, no request pending/queued (player lines always go first),
--     you have not typed for ambientQuietSec and no "talk to" target lock is active;
--   * no A-Life ChatterDirector scene is running near you (A-Life's own banter has the floor), and no
--     trade/dialogue window is open (vanilla ISTradingUI, A-Life talk box, anything named *Trade*/*GECK*/*Dialog*);
--   * 2+ A-Life NPCs within A-Life's hearing radius of you (Talk.settings.listenRadius, 12 tiles) that are
--     talkable, not hostile to you, not Talk.busy (combat/fleeing/holding), awake, alive, within
--     ambientPairTiles of each other, and whose group is off cooldown (ambientCooldownSec).
-- Then one NPC says one line to the other (LLM, via A-Life's Speech.say), the other may answer
-- (ambientReplyChance), and a third line may follow (backChance); never more than 3 lines.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Ambient") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Ambient"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Ambient") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end

M.SETTINGS_FILE = "alifetalk_settings.txt"
M.ambientNextAt = nil
M.ambientGroupAt = {}
M.metrics.ambient = 0

----------------------------------------------------------------------------------------------------------------
-- Settings file (Zomboid/Lua/alifetalk_settings.txt): key = value lines, # comments. Written with defaults once.
----------------------------------------------------------------------------------------------------------------
do -- 0.5.1: merge (files that load before this one, e.g. Activity, already added their keys)
    local prev = M.fileKeys or {}
    M.fileKeys = { "enabled", "ambient", "ambientMinSec", "ambientMaxSec", "ambientCooldownSec", "ambientReplyChance",
        "ambientQuietSec", "chimeChance", "backChance", "banterChance", "fallbackMs" }
    for _, k in ipairs(prev) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end

function M.loadSettingsFile()
    local lines = M.readLines(M.SETTINGS_FILE)
    if lines == nil then
        local out = { "# A-Life Talk settings (read when a game loads). true/false or numbers.",
            "# ambient = NPCs start short conversations with each other when you are near (no typing needed)." }
        for _, k in ipairs(M.fileKeys) do out[#out + 1] = k .. " = " .. tostring(M.settings[k]) end
        pcall(function()
            local w = getFileWriter(M.SETTINGS_FILE, true, false)
            w:write(table.concat(out, "\n") .. "\n")
            w:close()
        end)
        return false
    end
    local known = {}
    for _, k in ipairs(M.fileKeys) do known[k] = true end
    for _, line in ipairs(lines) do
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*([^#]-)%s*$")
        if k ~= nil and known[k] then
            if v == "true" then M.settings[k] = true
            elseif v == "false" then M.settings[k] = false
            elseif tonumber(v) ~= nil then M.settings[k] = tonumber(v)
            elseif string.match(v, "^KEY_[%w_]+$") then M.settings[k] = v end -- 0.5.0: key names (pttKey = KEY_GRAVE)
        end
    end
    -- sandbox option override if a server/sandbox preset defines it (optional; absent = file wins)
    pcall(function()
        local sv = SandboxVars and SandboxVars.ALifeTalk
        if type(sv) == "table" and sv.Ambient ~= nil then M.settings.ambient = sv.Ambient == true end
    end)
    M.log("settings: ambient=" .. tostring(M.settings.ambient) .. " every " .. tostring(M.settings.ambientMinSec)
        .. "-" .. tostring(M.settings.ambientMaxSec) .. "s, cooldown " .. tostring(M.settings.ambientCooldownSec) .. "s")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- Guards
----------------------------------------------------------------------------------------------------------------
M.blockingUi = { "Trad", "GECK", "Geck", "Dialog", "ALifeTalkBox", "Barter", "Shop" }

function M.uiBlocking()
    local blocked = false
    pcall(function()
        if ISTradingUI ~= nil and ISTradingUI.instance ~= nil and ISTradingUI.instance:isVisible() then blocked = true end
    end)
    if blocked then return true end
    pcall(function()
        local list = UIManager.getUI()
        for i = 0, list:size() - 1 do
            local el = list:get(i)
            if el:isVisible() then
                local t = el:getTable()
                local name = type(t) == "table" and tostring(t.Type or "") or ""
                for _, pat in ipairs(M.blockingUi) do
                    if name ~= "" and string.find(name, pat, 1, true) then blocked = true; return end
                end
            end
        end
    end)
    return blocked
end

function M.sceneNear(player, radius)
    local pa = PA()
    local director = pa and pa.ChatterDirector or nil
    if type(director) ~= "table" or type(director.scenes) ~= "table" then return false end
    local px, py = player:getX(), player:getY()
    for _, scene in pairs(director.scenes) do
        for _, m in ipairs(type(scene) == "table" and type(scene.members) == "table" and scene.members or {}) do
            local near = false
            pcall(function()
                local sx, sy = m.shell:getX(), m.shell:getY()
                near = (sx - px) ^ 2 + (sy - py) ^ 2 <= radius * radius
            end)
            if near then return true end
        end
    end
    return false
end

local function groupKey(record)
    local mem = type(record.memory) == "table" and record.memory or {}
    return tostring(mem.groupId or mem.outpostId or record.uid)
end

function M.ambientCandidates(player, now)
    local pa = PA()
    local talk = pa.Talk
    local radius = (type(talk.settings) == "table" and tonumber(talk.settings.listenRadius)) or 12
    local out = {}
    for _, l in ipairs(talk.listeners(player, radius)) do
        local ok = true
        if talk.stance(l.record, player) == "hostile" then ok = false end
        if ok and talk.busy(l.record, now) then ok = false end
        if ok and fn(talk, "inCombat") and talk.inCombat(l.record) then ok = false end
        if ok then pcall(function() if l.shell:isAsleep() then ok = false end end) end
        if ok and fn(pa.Speech, "alive") and pa.Speech.alive(l.shell) ~= true then ok = false end
        local act = tostring(l.record.activity or "")
        if ok and (string.find(act, "flee", 1, true) or string.find(act, "combat", 1, true)) then ok = false end
        if ok and now - (M.ambientGroupAt[groupKey(l.record)] or -1e12) < M.settings.ambientCooldownSec * 1000 then ok = false end
        if ok then out[#out + 1] = l end
    end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- Timer
----------------------------------------------------------------------------------------------------------------
function M.scheduleAmbient(now)
    local lo, hi = M.settings.ambientMinSec * 1000, M.settings.ambientMaxSec * 1000
    M.ambientNextAt = now + lo + M.roll(math.max(1, hi - lo))
end

function M.ambientTick()
    local s = M.settings
    if not s.enabled or not s.ambient or not M.worldHere() then return end
    local now = nowMs()
    if M.ambientNextAt == nil then M.scheduleAmbient(now); return end
    if now < M.ambientNextAt then return end
    M.scheduleAmbient(now) -- whatever happens, the next check is a fresh 20-40 s away
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- MP: the first player with two people chatting near them
        local started = false
        M.eachPlayer(function() if not started then M.ambientTry(now); started = M.ambientLast == "started" end end)
        return
    end
    return M.ambientTry(now)
end
function M.ambientTry(now)
    local s = M.settings
    local why = M.ambientBlocked(now)
    if why ~= nil then M.ambientLast = why; return end
    local player = ALifeSide.you()
    local list = M.ambientCandidates(player, now)
    if #list < 2 then M.ambientLast = "fewer than 2 NPCs"; return end
    local pa = PA()
    -- pick a speaker, then the nearest eligible partner within ambientPairTiles
    local speaker = list[M.roll(#list) + 1]
    local best, bestD = nil, 1e12
    for _, l in ipairs(list) do
        if l.record.uid ~= speaker.record.uid then
            local d = 1e12
            pcall(function()
                d = (l.shell:getX() - speaker.shell:getX()) ^ 2 + (l.shell:getY() - speaker.shell:getY()) ^ 2
            end)
            if d < bestD and d <= s.ambientPairTiles ^ 2 then best, bestD = l, d end
        end
    end
    if best == nil then M.ambientLast = "nobody close enough to talk to"; return end
    M.ambientGroupAt[groupKey(speaker.record)] = now
    M.ambientGroupAt[groupKey(best.record)] = now
    M.ambientLast = "started"
    M.metrics.ambient = M.metrics.ambient + 1
    M.submit({ mode = "ambient", uid = tostring(speaker.record.uid), player = player, listener = speaker,
        speakerUid = tostring(best.record.uid), partner = best, depth = 0, startMs = now })
end

function M.ambientBlocked(now)
    if not M.bridgeAlive(now) then return "bridge offline" end
    if M.pending ~= nil or #M.queue > 0 then return "busy with a request" end
    if M.chimeHold ~= nil and now < M.chimeHold then return "NPC lines still playing" end
    if now - (M.lastPlayerLineAt or -1e12) < M.settings.ambientQuietSec * 1000 then return "you spoke recently" end
    if M.lock ~= nil and now < (M.lock.untilMs or 0) then return "you are talking to someone" end
    local player = ALifeSide.you()
    if player == nil then return "no player" end
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "listeners") then return "A-Life not ready" end
    if M.sceneNear(player, 25) then return "A-Life banter scene running" end
    if M.uiBlocking() then return "a trade/dialogue window is open" end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- Request: speaker + partner context
----------------------------------------------------------------------------------------------------------------
function M.personOf(pa, l, other, player)
    local rec = l.record
    local p = { uid = tostring(rec.uid) }
    if fn(pa.Names, "of") then p.name = pa.Names.of(rec) end
    if fn(pa.DialogueRoles, "describe") then
        local day = nil
        pcall(function() day = getGameTime():getNightsSurvived() end)
        local ok, who = pcall(pa.DialogueRoles.describe, rec, day)
        if ok and type(who) == "table" then p.role, p.temper, p.register = who.label, who.temperament, who.register end
    end
    if fn(pa.TalkSocial, "mood") then pcall(function() p.mood = pa.TalkSocial.mood(rec, player) end) end
    p.faction = rec.factionId
    p.activity = rec.activity
    if M.drunkOf then
        local okD, v, label = pcall(M.drunkOf, rec.uid)
        if okD and type(v) == "number" and v > 0 then p.drunk, p.drunkLabel = v, label end
    end
    if other ~= nil and fn(pa.Relations, "status") then
        local okS, st = pcall(pa.Relations.status, rec, other.record)
        if okS then p.toward = st end
        if fn(pa.Relations, "sameSide") then
            pcall(function() p.sameSide = pa.Relations.sameSide(rec, other.record) == true end)
        end
        local mg = type(rec.memory) == "table" and rec.memory.groupId or nil
        local og = type(other.record.memory) == "table" and other.record.memory.groupId or nil
        p.sameGroup = mg ~= nil and mg == og
    end
    return p
end

function M.ambientRequest(job, now)
    local pa = PA()
    local me = M.refresh(job)
    local partner = M.refresh({ uid = job.speakerUid, listener = job.partner })
    if me == nil or partner == nil then return nil end
    if pa.Talk.busy(me.record, now) or pa.Talk.busy(partner.record, now) then return nil end
    local stance = pa.Talk.stance(me.record, job.player)
    local req = M.buildRequest(job.player, me, "", nil, stance, now)
    req.mode = "ambient"
    req.speakerUid = tostring(partner.record.uid)
    req.partner = M.personOf(pa, partner, me, job.player)
    req.me = M.personOf(pa, me, partner, job.player)
    req.line = nil
    req.acts, req.actHints = {}, {}
    if M.ambientGrief then pcall(M.ambientGrief, req, me, partner) end -- v3.2: break news / remember the dead
    if M.pairRow then -- v3.2: how these two feel about each other (ambient talk nudges the bond)
        local okP, row = pcall(M.pairRow, me.record.uid, partner.record.uid)
        if okP and row ~= nil then
            req.pairType = M.typeWord(M.pairTypeFor(row, me.record.uid, partner.record.uid), partner.record)
            req.pairScore = tonumber(row.s) or 0
            if (row.s or 0) > -40 then pcall(M.pairBump, me.record.uid, partner.record.uid, 1, nil) end
        end
    end
    return req
end

function M.noteAmbientLine(job)
    M.lastAmbientAt = nowMs()
end

return M
