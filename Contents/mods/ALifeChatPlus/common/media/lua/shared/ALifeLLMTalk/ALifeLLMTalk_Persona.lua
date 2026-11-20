-- A-Life Talk 0.4.0: distinct personalities, backstories, interaction log, opinion hook.
--
-- Builds on A-Life (read only): DialogueRoles.describe (role label, register, temperament, sex), DialogueRoles.factsFor
-- (title), the faction. On first sight each NPC gets one archetype from the 4556-entry library (0.5.0: + 24 negative / unhinged temperaments)
-- (ALifeLLMTalk_PersonaData.lua), chosen by a uid-seeded weighted roll among entries that fit their register, sex,
-- title and temperament, so it is stable across loads and machines. Saved in our ModData bucket "persona" and sent to
-- the bridge, which keeps the backstory in the NPC's memory file.
--
-- Backstory: 4 bits (life before / who they lost / how they survived / a secret). The bridge writes it once with the
-- model while idle (background model), falling back to the library's template bits; it pushes the bits back through
-- alifetalk_push.txt. NPCs reveal more as opinion rises; the panel shows only what the player has learned.
--
-- Opinion hook: NpcOpinion.adjust is wrapped (the original always runs). For the player only, the delta is scaled by
-- the personality (thin-skinned / forgiving multipliers), the change is logged in the interaction log and shown as a
-- floating +N / -N popup over the NPC.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Persona") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeLLMTalk_PersonaData"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Persona"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Persona") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function D() return type(ALifeLLMTalkPersonaData) == "table" and ALifeLLMTalkPersonaData or nil end

M.personaSettings = { enabled = true, opinionMods = true, popup = true, logInteractions = true, revealAt = { 15, 40, 70 } }

local function bucket(name)
    local data = M.store()
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end

local function hash(s)
    local h = 5381
    s = tostring(s)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return h
end

local function words(s)
    local t = {}
    for w in string.gmatch(string.lower(tostring(s or "")), "[%a_]+") do t[w] = true end
    return t
end

local function rec(uid)
    local pa = PA()
    return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil
end

-- what A-Life knows about them
function M.personaFacts(record)
    local pa = PA()
    local f = { register = "civilian", temper = "seasoned", sex = nil, title = "", faction = "" }
    if fn(pa.DialogueRoles, "describe") then
        local ok, who = pcall(pa.DialogueRoles.describe, record, 0)
        if ok and type(who) == "table" then
            f.register = who.register or f.register
            f.temper = who.temperament or f.temper
            f.sex = who.sex
            f.label = who.label
        end
    end
    if fn(pa.DialogueRoles, "factsFor") then
        local ok, facts = pcall(pa.DialogueRoles.factsFor, record)
        if ok and type(facts) == "table" then f.title = tostring(facts.name or "") end
    end
    if fn(pa.Talk, "shellFor") then
        pcall(function()
            local sh = pa.Talk.shellFor(record.uid)
            if sh ~= nil then f.sex = sh:isFemale() and "f" or "m" end
        end)
    end
    if f.sex == "female" then f.sex = "f" elseif f.sex == "male" then f.sex = "m" end
    if fn(pa.Catalog, "faction") then
        pcall(function()
            local fac = pa.Catalog.faction(record.factionId)
            if type(fac) == "table" and type(fac.general) == "table" then f.faction = tostring(fac.general.name or "") end
        end)
    end
    return f
end

-- weighted, uid-seeded pick among the entries that match who they are
function M.pickPersona(uid, facts)
    local d = D()
    if d == nil then return nil end
    local reg, sex, temper = facts.register or "civilian", facts.sex, facts.temper or "seasoned"
    local tw = words(facts.title .. " " .. (facts.label or ""))
    local cands, total = {}, 0
    for i, e in ipairs(d.entries) do
        local b, c = d.backgrounds[e.b], d.cores[e.c]
        if b and c and words(b.regs)[reg] and (b.sex == nil or sex == nil or b.sex == sex) then
            local w = 10
            if string.find(" " .. c.temper .. " ", " " .. temper .. " ", 1, true) then w = w * 3 end
            if c.regs ~= "*" then w = w * 2 end
            if type(c.mods) == "table" and tonumber(c.mods.weight) then w = w * tonumber(c.mods.weight) end -- 0.5.0 rarer dark/unhinged
            for t in pairs(words(b.titles)) do if tw[t] then w = w * 4; break end end
            w = math.max(1, math.floor(w + 0.5))
            if M.settings == nil or M.settings.darkPersonas ~= false or not (type(c.mods) == "table" and c.mods.nohostile) then
                cands[#cands + 1] = { i, w }
                total = total + w
            end
        end
    end
    if #cands == 0 then -- unknown register: any entry
        for i = 1, #d.entries do cands[#cands + 1] = { i, 1 } end
        total = #d.entries
    end
    local roll = hash(tostring(uid) .. "#persona") % total
    for _, c in ipairs(cands) do
        roll = roll - c[2]
        if roll < 0 then return c[1] end
    end
    return cands[#cands][1]
end

local function groupOf(reg)
    local d = D()
    if d.rough[reg] then return "rough" elseif d.uniform[reg] then return "uniform" end
    return "*"
end

local function pickFrom(list, seed)
    if type(list) ~= "table" or #list == 0 then return "" end
    return list[hash(seed) % #list + 1]
end

-- persona row in ModData: { i = entry index, reg, sex, learned = n bits learned, story = { bits }, src, talks }
function M.personaOf(uid, record)
    if not M.personaSettings.enabled or D() == nil then return nil end
    uid = tostring(uid)
    local all = bucket("persona")
    local row = all[uid]
    if type(row) == "table" and row.i and D().entries[row.i] then return row end
    record = record or rec(uid)
    if type(record) ~= "table" then return nil end
    if record.ghost then return nil end -- 0.5.1.5: never pick a persona from the people book's thin stand-in record
    local facts = M.personaFacts(record)
    local i = M.pickPersona(uid, facts)
    if i == nil then return nil end
    local d, e = D(), D().entries[i]
    local b = d.backgrounds[e.b]
    local g = groupOf(facts.register)
    local place = pickFrom(d.places, uid .. "#place")
    local before = string.gsub(b.before, "{place}", place)
    local fallback = {
        "Before all this they " .. before .. ".",
        "They " .. pickFrom(d.losses[g] or d.losses["*"], uid .. "#loss") .. ".",
        "They " .. pickFrom(d.survivals[g] or d.survivals["*"], uid .. "#surv") .. ".",
        "Their secret: " .. pickFrom(d.secrets[g] or d.secrets["*"], uid .. "#secret") .. ".",
    }
    row = { i = i, reg = facts.register, sex = facts.sex, learned = 0, talks = 0, fallback = fallback, story = nil, src = nil }
    all[uid] = row
    log("persona: " .. tostring(fn(PA().Names, "of") and PA().Names.of(record) or uid) .. " is " .. tostring(e.label))
    return row
end

function M.personaParts(row)
    local d = D()
    if row == nil or d == nil then return nil end
    local e = d.entries[row.i]
    local c, b = d.cores[e.c], d.backgrounds[e.b]
    local sp, sp2 = d.speech[e.s], d.speech[e.s2]
    local quirk = e.qk == "fear" and ("afraid of " .. tostring(d.fears[e.q])) or ("into " .. tostring(d.hobbies[e.q]))
    return { entry = e, core = c, bg = b, speech = sp, speech2 = sp2, phrase = d.phrases[e.p], quirk = quirk, mods = c.mods }
end

-- one compact prompt line
function M.personaLine(row)
    local p = M.personaParts(row)
    if p == nil then return nil end
    local m = p.mods
    local quirk = string.upper(string.sub(p.quirk, 1, 1)) .. string.sub(p.quirk, 2)
    local speech = p.speech[1] .. (p.speech2 and p.speech2[1] ~= p.speech[1] and (", a bit " .. p.speech2[1]) or "")
    return string.format("%s (%s). Speech: %s - %s. Catchphrase %s - use it rarely, never in two lines in a row. %s. Values %s; can't stand %s. "
            .. "Drunk: %s; grief: %s; in a fight: %s.",
        p.entry.label, table.concat(p.core.traits, ", "), speech, p.speech[2], tostring(p.phrase), quirk,
        p.core.values, p.core.dislikes, tostring(m.drunk), tostring(m.grief), tostring(m.bark))
end

function M.personaMods(uid)
    local row = M.personaOf(uid)
    local p = row and M.personaParts(row)
    return p and p.mods or nil
end

-- how much they'll share: 0 nothing, 1 life before, 2 + loss and survival, 3 + secret
function M.revealLevel(uid, op)
    local at = M.personaSettings.revealAt
    op = tonumber(op) or 0
    if op >= at[3] then return 3 elseif op >= at[2] then return 2 elseif op >= at[1] then return 1 end
    return 0
end

function M.storyBits(row)
    if row == nil then return {} end
    return type(row.story) == "table" and #row.story > 0 and row.story or row.fallback or {}
end

-- what the player has learned (bits shown in the panel)
function M.learnedStory(uid)
    local row = M.personaOf(uid)
    local out = {}
    if row == nil then return out end
    local bits = M.storyBits(row)
    local n = math.min(tonumber(row.learned) or 0, #bits)
    for i = 1, n do out[#out + 1] = bits[i] end
    return out
end

-- after a real conversation: they let slip the next bit if the trust is there
function M.noteTalked(uid, op)
    local row = M.personaOf(uid)
    if row == nil then return end
    row.talks = (tonumber(row.talks) or 0) + 1
    local lvl = M.revealLevel(uid, op)
    local can = ({ [0] = 0, [1] = 1, [2] = 3, [3] = 4 })[lvl] or 0
    if row.talks >= 2 and (tonumber(row.learned) or 0) < can and row.talks % 2 == 0 then
        row.learned = (tonumber(row.learned) or 0) + 1
    end
end

-- prompt extra
table.insert(M.requestExtras, function(req, player, listener, now)
    if not M.personaSettings.enabled then return end
    local row = M.personaOf(listener.record.uid, listener.record)
    if row == nil then return end
    local line = M.personaLine(row)
    local op = req.npc and req.npc.op or 0
    local lvl = M.revealLevel(listener.record.uid, op)
    local bits = M.storyBits(row)
    local share = {}
    for i = 1, math.min(#bits, ({ [0] = 1, [1] = 1, [2] = 3, [3] = 4 })[lvl] or 1) do share[#share + 1] = bits[i] end
    req.persona = { id = row.i, line = line, reveal = lvl, story = table.concat(share, " "),
        needStory = (row.story == nil) or nil, fallback = row.story == nil and row.fallback or nil }
end)

----------------------------------------------------------------------------------------------------------------
-- bridge -> game pushes (backstories)
----------------------------------------------------------------------------------------------------------------
M.pushSeq = 0
function M.readPushes()
    local lines = M.readLines and M.readLines("alifetalk_push.txt") or nil
    if type(lines) ~= "table" then return end
    for _, line in ipairs(lines) do
        local seq, kind, uid, rest = string.match(line, "^(%d+)|([%w_]+)|([^|]*)|(.*)$")
        seq = tonumber(seq)
        if seq and seq > M.pushSeq then
            M.pushSeq = seq
            if kind == "story" and uid ~= "" then
                local parts = {}
                for bit in string.gmatch(rest .. "||", "(.-)||") do if bit ~= "" then parts[#parts + 1] = bit end end
                local src = table.remove(parts, 1)
                local row = M.personaOf(uid)
                if row ~= nil and #parts > 0 then row.story, row.src = parts, src end
            elseif type(M.pushHandlers) == "table" and type(M.pushHandlers[kind]) == "function" then
                pcall(M.pushHandlers[kind], uid, rest) -- 0.5.0: voice transcripts etc.
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- Interaction log (per NPC, last 100, in-save for the panel + sent to the bridge for the memory file)
----------------------------------------------------------------------------------------------------------------
M.ilogOut = {}
function M.moodWord(op)
    op = tonumber(op) or 0
    if op >= 60 then return "warm" elseif op >= 25 then return "friendly" elseif op > -15 then return "neutral"
    elseif op > -40 then return "wary" elseif op > -70 then return "angry" end
    return "hateful"
end

function M.gameStamp()
    local pa = PA()
    local c = pa and fn(pa.Speech, "clock") and pa.Speech.clock() or {}
    local mi = 0
    pcall(function() mi = getGameTime():getMinutes() end)
    return string.format("day %d %02d:%02d", math.floor(tonumber(c.daysSurvived) or 0), math.floor(tonumber(c.hour) or 0),
        math.floor(tonumber(mi) or 0))
end

function M.logInteraction(uid, what, before, after, kind)
    if not M.personaSettings.logInteractions then return end
    uid = tostring(uid)
    local all = bucket("ilog")
    local list = type(all[uid]) == "table" and all[uid] or {}
    all[uid] = list
    local wh = nil
    pcall(function() wh = getGameTime():getWorldAgeHours() end)
    local row = { t = M.gameStamp(), h = tonumber(wh), w = string.sub(tostring(what or "?"), 1, 120), a = before and math.floor(before + 0.5) or nil,
        b = after and math.floor(after + 0.5) or nil, k = kind }
    if before and after then row.m1, row.m2 = M.moodWord(before), M.moodWord(after) end
    -- merge rapid repeats of the same thing (a burst of hits) into one row
    local last = list[#list]
    if last and last.w == row.w and last.t == row.t then last.b, last.m2 = row.b, row.m2
    else
        list[#list + 1] = row
        while #list > 100 do table.remove(list, 1) end
    end
    local q = M.ilogOut[uid] or {}
    q[#q + 1] = row
    M.ilogOut[uid] = q
end

function M.interactionsOf(uid) return bucket("ilog")[tostring(uid)] or {} end

-- piggy-backed on the next request of any kind
function M.drainILog()
    local out, n = {}, 0
    local pa = PA()
    for uid, rows in pairs(M.ilogOut) do
        local r = rec(uid)
        out[#out + 1] = { uid = uid, name = r and fn(pa.Names, "of") and pa.Names.of(r) or nil, rows = rows }
        n = n + 1
        if n >= 20 then break end
    end
    for _, o in ipairs(out) do M.ilogOut[o.uid] = nil end
    -- 0.5.2.5: rows removed by a save clean-up -> the bridge memory forgets them too ({ uid, forget = { w, ... } })
    if type(M.ilogForget) == "table" then
        local sent = {}
        for uid, ws in pairs(M.ilogForget) do
            if n >= 20 then break end
            local o = nil
            for _, x in ipairs(out) do if x.uid == uid then o = x end end
            if o == nil then o = { uid = uid, rows = {} }; out[#out + 1] = o; n = n + 1 end
            o.forget = ws
            sent[#sent + 1] = uid
        end
        for _, uid in ipairs(sent) do M.ilogForget[uid] = nil end
    end
    return #out > 0 and out or nil
end

----------------------------------------------------------------------------------------------------------------
-- NpcOpinion.adjust wrapper (original always runs)
----------------------------------------------------------------------------------------------------------------
M.opinionWhy = nil -- set by our own code around a call so the log says what happened ("You said: ...")
function M.installOpinionHook()
    local pa = PA()
    local op = pa and pa.NpcOpinion
    if not fn(op, "adjust") or op.adjust == M.wrappedAdjust then return false end
    local orig = op.adjust
    M.origAdjust = orig
    M.wrappedAdjust = function(record, player, delta, why, extra)
        local isPlayer, before = false, nil
        pcall(function()
            isPlayer = player ~= nil and type(record) == "table" and record.uid ~= nil and type(delta) == "number"
                and op.keyOf(player) ~= nil
            if isPlayer then before = op.valueOf(record, player) end
        end)
        local d = delta
        if isPlayer and M.personaSettings.opinionMods and type(delta) == "number" and delta ~= 0 then
            pcall(function()
                local mods = M.personaMods(record.uid)
                if mods then
                    local mul = delta < 0 and (tonumber(mods.neg) or 1) or (tonumber(mods.pos) or 1)
                    mul = math.max(0.5, math.min(1.6, mul))
                    if M.opinionMul then -- 0.5.0: current emotions / stress
                        local okE, em = pcall(M.opinionMul, record.uid, delta)
                        if okE and type(em) == "number" then mul = math.max(0.4, math.min(1.9, mul * em)) end
                    end
                    local scaled = delta * mul
                    d = scaled >= 0 and math.floor(scaled + 0.5) or -math.floor(-scaled + 0.5)
                    if d == 0 then d = delta > 0 and 1 or -1 end
                end
            end)
        end
        local r1, r2 = orig(record, player, d, why, extra)
        if isPlayer and M.turn ~= nil and tostring(M.turn.uid) == tostring(record.uid) then return r1, r2 end -- logged per turn
        if isPlayer and before ~= nil then
            pcall(function()
                local after = op.valueOf(rec(record.uid) or record, player) -- registry reads are snapshots: re-read
                if after ~= nil and math.floor(after + 0.5) ~= math.floor(before + 0.5) then
                    local what = M.opinionWhy or why or "Something you did"
                    M.logInteraction(record.uid, what, before, after, "opinion")
                    if M.showOpinionPopup then M.showOpinionPopup(record.uid, after - before, after, player) end
                    if M.grudgeFromOpinion then M.grudgeFromOpinion(record.uid, before, after, what) end
                    if M.onOpinionChanged then pcall(M.onOpinionChanged, record.uid, before, after, what) end
                end
            end)
        end
        return r1, r2
    end
    op.adjust = M.wrappedAdjust
    log("wrapped NpcOpinion.adjust (personality multipliers, interaction log, opinion popup)")
    return true
end

-- one log row + one popup per conversation turn (A-Life's own change and our human-scale change are summed)
function M.wrapTurn(name, label)
    local orig = M[name]
    if type(orig) ~= "function" or M["_turnWrapped_" .. name] == orig then return end
    local wrapped = function(p, r, ...)
        local pa = PA()
        local op = pa and pa.NpcOpinion
        local record = type(p) == "table" and p.uid and rec(p.uid) or nil
        local player = type(p) == "table" and p.player or nil
        local before = nil
        if record and player and fn(op, "valueOf") then pcall(function() before = op.valueOf(record, player) end) end
        M.turn = { uid = type(p) == "table" and p.uid or nil }
        local ok, a, b = pcall(orig, p, r, ...)
        M.turn = nil
        pcall(function()
            if record == nil or before == nil then return end
            local after = op.valueOf(rec(p.uid) or record, player) or before
            local you = string.sub(tostring(p.text or p.said or ""), 1, 50)
            local they = string.sub(tostring(type(r) == "table" and r.text or ""), 1, 50)
            local what = label .. (you ~= "" and (': you "' .. you .. '"') or "") .. (they ~= "" and (' - "' .. they .. '"') or "")
            M.logInteraction(p.uid, what, before, after, "talk")
            if math.floor(after + 0.5) ~= math.floor(before + 0.5) and M.showOpinionPopup then
                M.showOpinionPopup(p.uid, after - before, after, player)
            end
            if M.grudgeFromOpinion then M.grudgeFromOpinion(p.uid, before, after, you ~= "" and ('you said "' .. you .. '"') or label) end
            if M.onOpinionChanged and math.floor(after + 0.5) ~= math.floor(before + 0.5) then pcall(M.onOpinionChanged, p.uid, before, after, what) end
            M.noteTalked(p.uid, after)
        end)
        if not ok then error(a) end
        return a, b
    end
    M[name] = wrapped
    M["_turnWrapped_" .. name] = wrapped
end
M.wrapTurn("finish", "Talked")
M.wrapTurn("finishHostile", "Words in a fight")
pcall(M.installOpinionHook) -- A-Life (shared) is loaded before client files; the tick retries otherwise

local tickN = 0
-- pre-1.0 MP (P3): the server has no popup window (ALifeLLMTalk_Popup is client-only). An opinion change becomes the
-- same vague cue as single player's immersive mode ("Rae seems to warm up to you."), sent to that player as a letter
-- (ALifeOut). Never numbers (immersion rule). Off when the server has both immersive and opinionPopup off.
M.vibeLinesServer = {
    up = { "%s seems to warm up to you.", "%s relaxes a little.", "%s seems less wary of you." },
    upBig = { "%s seems to really appreciate that.", "Something in %s's face softens." },
    down = { "%s doesn't seem to like that.", "%s eyes you warily.", "%s seems put off." },
    downBig = { "%s looks at you with open dislike.", "%s doesn't trust you at all now." },
}
M.vibeAtServer = M.vibeAtServer or {}
function M.serverOpinionCue(uid, delta, value, player)
    if type(ALifeSide) ~= "table" or not ALifeSide.mpServer() or type(ALifeOut) ~= "table" then return false end
    if M.settings.immersive == false and M.settings.opinionPopup == false then return false end
    player = ALifeSide.you(player)
    delta = tonumber(delta) or 0
    if player == nil or math.abs(delta) < 2 then return false end
    local key = tostring(ALifeSide.keyOf(player)) .. "|" .. tostring(uid)
    local now = nowMs()
    if now - (M.vibeAtServer[key] or -1e12) < 20000 then return false end
    local pa = PA()
    local shell = pa and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil
    if shell == nil then return false end
    local near = false
    pcall(function() near = (shell:getX() - player:getX()) ^ 2 + (shell:getY() - player:getY()) ^ 2 <= 15 * 15 end)
    if not near then return false end
    local name = "They"
    pcall(function() local r = pa.ActorRegistry.read(tostring(uid)); local n = r and pa.Names.of(r); if n and n ~= "" then name = tostring(n) end end)
    local L = M.vibeLinesServer
    local list = delta >= 8 and L.upBig or delta > 0 and L.up or delta <= -8 and L.downBig or L.down
    M.vibeAtServer[key] = now
    local line = string.format(list[(type(ZombRand) == "function" and ZombRand(#list) or 0) + 1], name)
    ALifeOut.letter(player, line, delta > 0 and 170 or 220, delta > 0 and 210 or 150, delta > 0 and 170 or 140)
    return true
end
if type(ALifeSide) == "table" and ALifeSide.mpServer() and M.showOpinionPopup == nil then
    M.showOpinionPopup = function(uid, delta, value, player) return M.serverOpinionCue(uid, delta, value, player) end
end

function M.personaTick()
    tickN = tickN + 1
    pcall(M.installOpinionHook)
    if tickN % 2 == 0 then pcall(M.readPushes) end
end



----------------------------------------------------------------------------------------------------------------
-- 0.4.0 settings (also in Zomboid/Lua/alifetalk_settings.txt and the themed Settings window)
----------------------------------------------------------------------------------------------------------------
for k, v in pairs({ opinionPopup = true, personaMods = true, interactionLog = true, nemesis = true, radioNews = true,
    attackPlayer = true, attackNpc = true }) do
    if M.settings[k] == nil then M.settings[k] = v end
end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "opinionPopup", "personaMods", "interactionLog", "nemesis", "radioNews", "attackPlayer", "attackNpc" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end

function M.applySettings()
    M.personaSettings.opinionMods = M.settings.personaMods ~= false
    M.personaSettings.logInteractions = M.settings.interactionLog ~= false
    local P = type(ALifeTalkPatch) == "table" and ALifeTalkPatch or nil
    if P and type(P.settings) == "table" and type(P.settings.attack) == "table" then
        P.settings.attack.player = M.settings.attackPlayer ~= false
        P.settings.attack.npc = M.settings.attackNpc ~= false
    end
end

function M.saveSettingsFile()
    if type(M.sbKeepTouched) == "function" then pcall(M.sbKeepTouched) end -- pre-1.0: switches saved in game stay for this world
    local out ={ "# A-Life Talk settings (read when a game loads). true/false or numbers." }
    for _, k in ipairs(M.fileKeys or {}) do out[#out + 1] = k .. " = " .. tostring(M.settings[k]) end
    local w = getFileWriter(M.SETTINGS_FILE, true, false)
    w:write(table.concat(out, "\n") .. "\n")
    w:close()
    M.log("settings saved")
end

if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.applySettings) end) end

return M
