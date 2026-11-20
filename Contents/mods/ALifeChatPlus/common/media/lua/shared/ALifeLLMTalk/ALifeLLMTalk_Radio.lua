-- A-Life Talk v3: key memories for the relationship panel + walkie-talkie contact.
--
-- Radio: while a session is active, what you type in the normal chat box (T) goes to that NPC over the radio.
-- Hook: ProjectALife.Talk.onPlayerText is wrapped (original runs for every line that is not a radio line, and
-- for "/" commands). Replies show as radio lines over your character ([Radio] Name: ...), or as normal A-Life
-- speech if the NPC is loaded and standing within 10 tiles. Works with unloaded NPCs from A-Life's registry data.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Radio") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Radio"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Radio") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end
local function log(msg) M.log(msg) end

local function bucket(name)
    local data = M.store()
    if type(data) ~= "table" then M.tmpStore = M.tmpStore or {}; data = M.tmpStore end
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end

local function clock()
    local day, h, m = 0, 0, 0
    pcall(function() local gt = getGameTime(); day, h, m = gt:getNightsSurvived(), gt:getHour(), gt:getMinutes() end)
    return day, h, m
end

----------------------------------------------------------------------------------------------------------------
-- Key memories (in the save's ModData; capped; shown in the relationship panel)
----------------------------------------------------------------------------------------------------------------
M.keyMemMax = 40
function M.keyMem(uid, kind, text)
    local map = bucket("keymem")
    local list = type(map[tostring(uid)]) == "table" and map[tostring(uid)] or {}
    local day, h, m = clock()
    local wh = nil
    pcall(function() wh = getGameTime():getWorldAgeHours() end)
    list[#list + 1] = { k = kind, t = string.sub(tostring(text), 1, 140), d = day, tm = string.format("%02d:%02d", h, m), h = tonumber(wh) }
    while #list > M.keyMemMax do table.remove(list, 1) end
    map[tostring(uid)] = list
end

function M.keyMemOf(uid)
    local list = bucket("keymem")[tostring(uid)]
    return type(list) == "table" and list or {}
end

M.badTones = { INSULT = "insult", THREATEN = "threat", RUDE = "insult", MOCK = "insult" }
M.goodTones = { THANKS = "kindness", COMPLIMENT = "kindness", OFFER_HELP = "kindness", APOLOGY = "kindness", FRIENDLY = "kindness" }
function M.noteTalkMemory(p, r, act)
    local d = tonumber(r.d) or 0
    local tone = r.tone
    local kind = (tone and M.badTones[tone]) or (d <= -4 and "insult") or (tone and M.goodTones[tone] and d >= 1 and "kindness")
        or (d >= 3 and "kindness") or nil
    if d <= -8 then kind = "threat" end
    -- 0.5.1.3 (user's idea): anyone you talked to stays in the Relationships list - via the people book, not by
    -- writing a "talk" key memory for every ordinary line (that pushed the real key memories out of the 40 cap)
    -- 0.5.1.5: every talk also saves their page (Profile.lua), so it stays filled in when they are far away
    local pa = PA()
    local trec = pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(p.uid)) or nil
    if trec and M.bookSnap then pcall(M.bookSnap, trec, nil) end
    if trec and M.profileWant then pcall(M.profileWant, p.uid, trec, true) end
    if trec and M.lookSave then pcall(M.lookSave, p.uid, nil, false) end
    if kind == nil then return end
    local said = string.sub(tostring(p.text or ""), 1, 80)
    local prefix = (p.mode == "radio") and "Over the radio you said" or "You said"
    M.keyMem(p.uid, kind, prefix .. ": \"" .. said .. "\" (" .. string.format("%+d", d) .. ")")
end

----------------------------------------------------------------------------------------------------------------
-- Known NPCs (for the master list)
----------------------------------------------------------------------------------------------------------------
function M.opinionView(record, player)
    local pa = PA()
    local op = pa and pa.NpcOpinion or nil
    local v, label, why = 0, nil, nil
    if fn(op, "payload") then
        local ok, pl = pcall(op.payload, record, player)
        if ok and type(pl) == "table" then v, label, why = tonumber(pl.value) or 0, pl.label, pl.reason end
    elseif fn(op, "valueOf") then
        v = tonumber((op.valueOf(record, player))) or 0
    end
    return math.floor(v + 0.5), label, why
end

function M.knownNpcs(player)
    local pa = PA()
    local out = {}
    if pa == nil or not fn(pa.ActorRegistry, "each") then return out end
    local key = fn(pa.NpcOpinion, "keyOf") and pa.NpcOpinion.keyOf(player) or nil
    local keymem = bucket("keymem")
    pa.ActorRegistry.each(function(rec)
        local known = (key ~= nil and fn(pa.NpcOpinion, "rowOf") and pa.NpcOpinion.rowOf(rec, key) ~= nil)
            or keymem[tostring(rec.uid)] ~= nil or type(bucket("book")[tostring(rec.uid)]) == "table"
        if known then
            local v, label = M.opinionView(rec, player)
            local name = fn(pa.Names, "shown") and fn(pa.Speech, "playerKey") and pa.Names.shown(rec, pa.Speech.playerKey(player))
                or (fn(pa.Names, "of") and pa.Names.of(rec)) or "Someone"
            local n = { uid = tostring(rec.uid), name = tostring(name), value = v, label = label,
                dead = rec.lifecycle == "dead", away = rec.lifecycle == "dormant", record = rec }
            out[#out + 1] = n
            if M.bookSnap then pcall(M.bookSnap, rec, n) end -- 0.5.1.3: our own copy, for when A-Life drops the record
        end
        return #out >= 1000 -- 0.5.1.3: was 200 (people past the 200th known one silently fell off the list)
    end)
    -- 0.5.1.3: people A-Life no longer has a record for stay listed from the book (away / dead)
    if M.bookGhosts then
        local have = {}
        for _, n in ipairs(out) do have[n.uid] = true end
        local okG, ghosts = pcall(M.bookGhosts, have)
        for _, uid in ipairs(okG and ghosts or {}) do
            local e = bucket("book")[uid]
            local g = M.ghostRecord and M.ghostRecord(uid) or nil
            if type(e) == "table" and g then
                out[#out + 1] = { uid = uid, name = tostring(e.name or "Someone"), value = tonumber(e.value) or 0, label = e.label,
                    dead = e.dead == true, record = g, away = not e.dead, ghost = true }
            end
        end
    end
    -- 0.5.2.6 [pt254u]: one row per person (an "Away" copy of someone whose dead row is listed is folded in), and
    -- a row is dead when any death record says so (off-screen deaths: OffDeath.lua)
    if M.isPersonDead then
        for _, n in ipairs(out) do
            if not n.dead and M.settings.offDeath ~= false and M.isPersonDead(n.uid, (not n.ghost) and n.record or nil) then n.dead, n.away = true, false end
        end
    end
    if M.mergeDupRows then local okM, merged = pcall(M.mergeDupRows, out); if okM and type(merged) == "table" then out = merged end end
    table.sort(out, function(a, b)
        if a.dead ~= b.dead then return not a.dead end
        if (a.away == true) ~= (b.away == true) then return a.away ~= true end -- 0.5.1.3 (user's edit): people near you first
        if a.value ~= b.value then return a.value > b.value end
        return tostring(a.uid) < tostring(b.uid)
    end)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- Walkie-talkie
----------------------------------------------------------------------------------------------------------------
M.radioSettings = { timeoutMs = 120000, defaultRangeTiles = 4000, nearSpeakTiles = 10 }
M.radio = nil
-- pre-1.0 MP (P5): one radio call per player on a server (M.radio = the call of the player being handled, Main's
-- M.perPlayer). Their machine is told when a call starts / ends ("radioState"), so the window shows Call / End.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function mpClient() return type(ALifeSide) == "table" and ALifeSide.mpClient() end
if mpServer() and fn(M, "perPlayer") then M.perPlayer("radio") end
local function radioState(player)
    if not mpServer() or player == nil or type(ALifeCmd) ~= "table" then return end
    local r = M.radio
    ALifeCmd.reply(player, "radioState", { uid = r and r.uid or nil, name = r and r.name or nil })
end
if type(ALifeCmd) == "table" and fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("radioState", function(a)
        if not mpClient() or type(a) ~= "table" then return end
        if a.uid ~= nil then M.radio = { uid = tostring(a.uid), name = tostring(a.name or "?"), startedMs = nowMs(), lastMs = nowMs(), answers = true }
        else M.radio = nil end
    end)
end

local function walk(container, depth, visit)
    if container == nil or depth > 2 or container.getItems == nil then return end
    local items = container:getItems()
    if items == nil then return end
    for i = 0, math.min(items:size(), 400) - 1 do
        local it = items:get(i)
        if visit(it) then return true end
        local isBag = false
        pcall(function() isBag = instanceof(it, "InventoryContainer") end)
        if isBag and it.getInventory ~= nil and walk(it:getInventory(), depth + 1, visit) then return true end
    end
end

-- returns item, usable (bool), reason
function M.findRadio(player)
    local best, bestOk, bestWhy = nil, false, "You need a walkie-talkie"
    pcall(function()
        walk(player:getInventory(), 0, function(it)
            local dd = nil
            -- v0.4.2: only radios have getDeviceData; calling it on other items logged a Java exception each time
            if it ~= nil and it.getDeviceData ~= nil then pcall(function() dd = it:getDeviceData() end) end
            local twoWay = false
            if dd ~= nil then pcall(function() twoWay = dd:getIsTwoWay() == true end) end
            local full = ""
            pcall(function() full = tostring(it:getFullType()) end)
            if not twoWay and string.find(full, "WalkieTalkie", 1, true) then twoWay = true end
            if not twoWay then return false end
            local on, power = true, true
            if dd ~= nil then
                pcall(function() on = dd:getIsTurnedOn() == true end)
                pcall(function()
                    if dd:getIsBatteryPowered() then power = (tonumber((dd:getPower())) or 0) > 0 end
                end)
            end
            local ok = on and power
            if best == nil or (ok and not bestOk) then
                best, bestOk = it, ok
                bestWhy = ok and nil or (not power and "Walkie-talkie battery is dead" or "Turn your walkie-talkie on")
            end
            return ok
        end)
    end)
    return best, bestOk, bestWhy
end

function M.radioRange(item)
    local r = M.radioSettings.defaultRangeTiles
    pcall(function()
        local v = item:getDeviceData():getTransmitRange()
        if type(v) == "number" and v > 0 then r = v end
    end)
    return r
end

function M.npcPos(record, shell)
    local x, y = nil, nil
    if shell ~= nil then pcall(function() x, y = shell:getX(), shell:getY() end) end
    if x == nil and type(record.worldPosition) == "table" then x, y = record.worldPosition.x, record.worldPosition.y end
    return x, y
end

-- can we raise them? returns ok, reason
function M.radioCheck(player, uid)
    local pa = PA()
    local rec = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid) or nil
    if rec == nil then return false, "Unknown person" end
    if rec.lifecycle == "dead" then return false, "They're dead" end
    local item, ok, why = M.findRadio(player)
    if item == nil then return false, "You need a walkie-talkie" end
    if not ok then return false, why end
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
    local nx, ny = M.npcPos(rec, shell)
    local px, py = player:getX(), player:getY()
    if nx ~= nil and (nx - px) ^ 2 + (ny - py) ^ 2 > M.radioRange(item) ^ 2 then return false, "Out of radio range" end
    return true, nil, rec, shell
end

function M.startRadio(uid)
    local player = ALifeSide.you()
    local ok, why, rec, shell = M.radioCheck(player, uid)
    if not ok then pcall(function() player:Say(why) end); return false, why end
    local v = M.opinionView(rec, player)
    local mem = type(rec.memory) == "table" and rec.memory or {}
    -- would they even have a radio on and pick up? group members and people who like you: yes.
    local answers = v >= 16 or (type(mem.walkWith) == "table") or (v > -16 and M.roll(100) < 50)
    local name = fn(PA().Names, "of") and PA().Names.of(rec) or "them"
    M.radio = { uid = tostring(uid), name = tostring(name), startedMs = nowMs(), lastMs = nowMs(), answers = answers }
    radioState(player)
    M.radioLine(nil, "[Radio] Calling " .. tostring(name) .. "...")
    log("radio session with " .. tostring(uid) .. (answers and "" or " (they won't pick up)"))
    if M.showRadioIndicator then pcall(M.showRadioIndicator) end
    return true
end

function M.endRadio(reason)
    if M.radio == nil then return end
    M.radioLine(nil, "[Radio] " .. (reason or "Signing off."))
    M.radio = nil
    radioState(ALifeSide.cur)
    if M.hideRadioIndicator then pcall(M.hideRadioIndicator) end
end

-- show a radio line: NPC speech if loaded and near, else a green radio line over the player (like vanilla radio)
function M.radioLine(shell, text, name)
    local player = ALifeSide.you()
    if shell ~= nil then
        local near = false
        pcall(function()
            near = (shell:getX() - player:getX()) ^ 2 + (shell:getY() - player:getY()) ^ 2 <= M.radioSettings.nearSpeakTiles ^ 2
        end)
        if near then if M.ownSay then return M.ownSay(shell, text, {}) end return PA().Speech.say(shell, text, {}) end
    end
    if M.cleanText then text = M.cleanText(text) end -- 0.5.2.3: no raw markup in the chat log either
    if name ~= nil then text = "[Radio] " .. tostring(name) .. ": " .. text end
    if mpServer() then -- MP: drawn on that player's machine
        if type(ALifeOut) == "table" and player ~= nil then ALifeOut.radio(player, text) end
        return
    end
    local shown = pcall(function() player:addLineChatElement(text, 0.55, 0.9, 0.55) end)
    if not shown then pcall(function() player:Say(text) end) end
    M.radioLog = M.radioLog or {}
    M.radioLog[#M.radioLog + 1] = text
    while #M.radioLog > 30 do table.remove(M.radioLog, 1) end
end

function M.onRadioText(player, text)
    local r = M.radio
    local ok, why, rec, shell = M.radioCheck(player, r.uid)
    if not ok then M.endRadio(why); return end
    r.lastMs = nowMs()
    if not r.answers then
        M.radioLine(nil, "[Radio] *kssht*... no answer.")
        if not M.radioHintShown then -- 0.6.11
            M.radioHintShown = true
            M.radioLine(nil, "[Radio] (Nobody's answering. They'd need a two-way radio of their own, switched on and in range.)")
        end
        return
    end
    M.submit({ mode = "radio", uid = r.uid, player = player, listener = { record = rec, shell = shell }, text = text,
        startMs = nowMs(), depth = 0, record = rec })
end

function M.radioRequest(job, now)
    local pa = PA()
    local rec = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(job.uid) or job.record
    if rec == nil then return nil end
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(job.uid) or nil
    local req
    if shell ~= nil then
        local okB, built = pcall(M.buildRequest, job.player, { record = rec, shell = shell, distance = 1 }, job.text, nil,
            pa.Talk.stance(rec, job.player), now)
        if okB then req = built end
    end
    if req == nil then -- unloaded: A-Life's stored record is enough for who they are and how they feel
        local v, label, why = M.opinionView(rec, job.player)
        local npc = { name = fn(pa.Names, "of") and pa.Names.of(rec) or "someone", op = v, opLabel = label, opWhy = why,
            stance = fn(pa.Talk, "stance") and pa.Talk.stance(rec, job.player) or "neutral",
            activity = rec.activity, faction = rec.factionId, known = true }
        if fn(pa.DialogueRoles, "describe") then
            local day = clock()
            local okR, who = pcall(pa.DialogueRoles.describe, rec, day)
            if okR and type(who) == "table" then npc.role, npc.temper, npc.register, npc.sex = who.label, who.temperament, who.register, who.sex end
        end
        if M.drunkOf then local d, l = M.drunkOf(rec.uid); if d > 0 then npc.drunk, npc.drunkLabel = d, l end end
        local day, h, m = clock()
        M.counter = M.counter + 1
        req = { id = tostring(now) .. "-" .. tostring(M.counter), npc = npc, world = { day = day, hour = h, minute = m },
            said = job.text, uid = tostring(rec.uid), worldId = M.worldId(), heard = {}, mates = {}, acts = {},
            actHints = {}, pos = type(rec.worldPosition) == "table" and { math.floor(rec.worldPosition.x or 0),
            math.floor(rec.worldPosition.y or 0) } or nil }
    end
    req.mode = "radio"
    req.heard = {} -- they can't hear what's said around you
    req.acts, req.actHints = {}, {}
    return req
end

-- relationship change: NpcOpinion when the NPC is loaded; otherwise queued and applied when they load again
function M.radioOpinion(uid, delta, why)
    local pa = PA()
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
    local rec = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid) or nil
    if shell ~= nil and rec ~= nil and fn(pa.NpcOpinion, "adjust") then
        pa.NpcOpinion.adjust(rec, ALifeSide.you(), delta, why)
        return "applied"
    end
    local q = bucket("pendingOpinion")
    local row = type(q[tostring(uid)]) == "table" and q[tostring(uid)] or { d = 0 }
    row.d, row.why = math.max(-30, math.min(30, (row.d or 0) + delta)), why
    q[tostring(uid)] = row
    return "queued"
end

function M.applyPendingOpinion()
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "shellFor") or not fn(pa.ActorRegistry, "read") then return end
    local q = bucket("pendingOpinion")
    for uid, row in pairs(q) do
        local shell = pa.Talk.shellFor(uid)
        local rec = pa.ActorRegistry.read(uid)
        if rec == nil or rec.lifecycle == "dead" then q[uid] = nil
        elseif shell ~= nil and fn(pa.NpcOpinion, "adjust") then
            pa.NpcOpinion.adjust(rec, ALifeSide.you(), row.d, row.why or "Something you said over the radio.")
            log("applied queued radio opinion " .. tostring(row.d) .. " to " .. tostring(uid))
            q[uid] = nil
        end
    end
end

function M.finishRadio(p, r)
    local pa = PA()
    local text = r.text
    if type(text) ~= "string" or text == "" then text = "*kssht*... say again? Over." end
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(p.uid) or nil
    local name = (M.radio and M.radio.uid == p.uid and M.radio.name) or "Radio"
    M.radioLine(shell, text, name)
    local d = math.max(-10, math.min(10, tonumber(r.d) or 0))
    -- human-scaled like face to face, but words over a radio land a bit softer
    local delta = d > 0 and math.floor(d * 0.5 + 0.5) or math.floor(d * 0.7 - 0.5) + 1
    if d < 0 and delta == 0 then delta = -1 end
    if delta ~= 0 then
        local how = M.radioOpinion(p.uid, delta, d < 0 and "What you said over the radio." or "You kept in touch by radio.")
        log("radio opinion " .. tostring(delta) .. " " .. how)
    end
    pcall(M.noteTalkMemory, p, r, nil)
    if r.leave and M.radio and M.radio.uid == p.uid then M.endRadio(name .. " signed off.") end
end

function M.radioFallback(p)
    M.radioLine(nil, "[Radio] *kssht*... (no reply)")
    -- 0.6.11: once a session, say why (realism: they need a radio of their own, on, and in range)
    if not M.radioHintShown then
        M.radioHintShown = true
        M.radioLine(nil, "[Radio] (Nobody's answering. They'd need a two-way radio of their own, switched on and in range.)")
    end
end

function M.radioTick()
    local now = nowMs()
    if now - (M.pendingOpinionAt or -1e12) > 5000 then M.pendingOpinionAt = now; pcall(M.applyPendingOpinion) end
    if mpServer() then M.eachPlayer(function() M.radioTickFor(now) end); return end
    return M.radioTickFor(now)
end
function M.radioTickFor(now)
    local r = M.radio
    if r == nil then return end
    if now - r.lastMs > M.radioSettings.timeoutMs then M.endRadio("Radio quiet too long, signing off."); return end
    local ok, why = M.radioCheck(ALifeSide.you(), r.uid)
    if not ok then M.endRadio(why) end
end

function M.installRadio()
    local pa = PA()
    if M.origOnPlayerText ~= nil or not fn(pa and pa.Talk, "onPlayerText") then return end
    M.origOnPlayerText = pa.Talk.onPlayerText
    pa.Talk.onPlayerText = function(player, text, loud, ...)
        local inCall = false
        if mpServer() then local _, v = ALifeSide.with(player, function() return M.radio ~= nil end); inCall = v == true else inCall = M.radio ~= nil end
        if inCall and type(text) == "string" and not string.match(text, "^%s*/") and not string.match(text, "^%s*$") then
            local ok, err = ALifeSide.with(player, M.onRadioText, player, text) -- MP: that player's call
            if ok then return true, "radio" end
            log("radio error: " .. tostring(err))
        end
        return M.origOnPlayerText(player, text, loud, ...)
    end
    log("wrapped Talk.onPlayerText (radio sessions)")
end

M.eventModes.radio = { request = M.radioRequest, finish = M.finishRadio, fallback = M.radioFallback }
-- pre-1.0 MP (P5): the talk window's Call / End buttons run on the server as that player
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    ALifeRemote.expose("startRadio", 1, 2)
    ALifeRemote.expose("endRadio", 1, 2)
end

return M
