-- A-Life Talk v3.2: NPC <-> NPC relationships ("every NPC can have a relationship of any kind").
--
-- Base = what A-Life already knows (read only): same group (memory.groupId), faction (record.factionId),
-- Relations.status / Relations.sameSide between two actors, A-Life names. A-Life has no per-pair score or bond
-- type, so we keep our own layer in the save's ModData (bucket "pairs"; never touches A-Life state):
--   key "uidA|uidB" (sorted) -> { s = -100..100, t = type, p = parent uid (parent/child only), c = uid who has the
--   crush (crush only), fx = true when fixed (family), why = { short reasons, newest last (max 4) } }
-- Types: sibling, parent/child, partner, crush, best friend, buddy, friend, ally, comrade, acquaintance, stranger,
-- rival, distrust, enemy, nemesis. Family links are rare, symmetric (A parent of B = B child of A) and fixed.
-- Nemesis = strong personal lasting enemy (killed a loved one, repeated betrayal, long feud).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Pairs") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Pairs"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Pairs") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end

M.pairSettings = { familyChance = 7, partnerChance = 5, bestChance = 10, rivalChance = 6, crushChance = 4 }

local function bucket(name)
    local data = M.store()
    if type(data) ~= "table" then M.tmpStore = M.tmpStore or {}; data = M.tmpStore end
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
M.bucket = M.bucket or bucket

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
-- deterministic per-pair randomness (same pair -> same roll on every machine / load)
local function hashRoll(str, salt, n)
    local h = 5381
    local s = tostring(str) .. "#" .. tostring(salt)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return h % n
end
M.hashRoll = hashRoll

local function rec(uid)
    local pa = PA()
    if type(uid) == "table" then return uid end
    return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil
end
local function memOf(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function roleOf(r)
    local pa = PA()
    if fn(pa and pa.DialogueRoles, "describe") then
        local ok, who = pcall(pa.DialogueRoles.describe, r, 0)
        if ok and type(who) == "table" then return tostring(who.label or ""), tostring(who.temperament or "") end
    end
    return "", ""
end
local function ageRank(r) -- rough age from A-Life's role labels ("Family - Elder", "Young Adult")
    local label = string.lower((roleOf(r)))
    if string.find(label, "elder", 1, true) then return 3 end
    if string.find(label, "young", 1, true) or string.find(label, "youth", 1, true) then return 1 end
    return 2
end

function M.pairKey(a, b)
    a, b = tostring(a), tostring(b)
    if a < b then return a .. "|" .. b, a, b end
    return b .. "|" .. a, b, a
end

M.pairTypeScore = { sibling = 65, parent = 70, partner = 70, crush = 35, ["best friend"] = 65, buddy = 40, friend = 25,
    ally = 20, comrade = 30, acquaintance = 8, stranger = 0, rival = -20, distrust = -25, enemy = -55, nemesis = -85, respect = 10, ex = -5 }

-- seed from A-Life data + a little deterministic variety
function M.seedPair(ra, rb, key)
    local pa = PA()
    local ma, mb = memOf(ra), memOf(rb)
    local sameGroup = ma.groupId ~= nil and ma.groupId == mb.groupId
    local sameFaction = ra.factionId ~= nil and ra.factionId == rb.factionId
    local status = nil
    if fn(pa.Relations, "status") then
        local ok, st = pcall(pa.Relations.status, ra, rb)
        if ok then status = st end
    end
    local side = false
    if fn(pa.Relations, "sameSide") then pcall(function() side = pa.Relations.sameSide(ra, rb) == true end) end
    local row = { s = 0, t = "stranger", why = {} }
    local st = M.pairSettings
    local r100 = hashRoll(key, "type", 100)
    if status == "hostile" then
        row.t, row.why[1] = "enemy", "on opposite sides"
    elseif sameGroup then
        row.t, row.why[1] = "comrade", "same group"
        local lastA, lastB = ma.personLast, mb.personLast
        if type(lastA) == "string" and lastA ~= "" and lastA == lastB and r100 < 60 then
            local ga, gb = ageRank(ra), ageRank(rb)
            if ga ~= gb and math.abs(ga - gb) >= 1 and hashRoll(key, "gen", 100) < 50 then
                row.t, row.p = "parent", tostring(ga > gb and ra.uid or rb.uid)
            else row.t = "sibling" end
            row.fx, row.why[1] = true, "family (same name)"
        elseif r100 < st.familyChance then
            local ga, gb = ageRank(ra), ageRank(rb)
            if ga ~= gb then row.t, row.p = "parent", tostring(ga > gb and ra.uid or rb.uid) else row.t = "sibling" end
            row.fx, row.why[1] = true, "family"
        elseif r100 < st.familyChance + st.partnerChance then row.t, row.why[1] = "partner", "together since before"
        elseif r100 < st.familyChance + st.partnerChance + st.bestChance then row.t, row.why[1] = "best friend", "been through a lot"
        elseif r100 < st.familyChance + st.partnerChance + st.bestChance + st.rivalChance then row.t, row.why[1] = "rival", "they clash"
        elseif r100 < st.familyChance + st.partnerChance + st.bestChance + st.rivalChance + st.crushChance then
            row.t, row.c, row.why[1] = "crush", tostring(hashRoll(key, "who", 2) == 0 and ra.uid or rb.uid), "has a soft spot"
        elseif r100 < 45 then row.t = "buddy" end
    elseif sameFaction or side then
        row.t, row.why[1] = (status == "friendly" or sameFaction) and "ally" or "acquaintance", sameFaction and "same faction" or "same side"
    elseif status == "friendly" then row.t = "acquaintance" end
    row.s = clamp((M.pairTypeScore[row.t] or 0) + hashRoll(key, "score", 21) - 10, -100, 100)
    return row
end

function M.pairRow(a, b, create)
    if a == nil or b == nil or tostring(a) == tostring(b) then return nil end
    local key = M.pairKey(a, b)
    local map = bucket("pairs")
    local row = map[key]
    if row == nil and create ~= false then
        local ra, rb = rec(a), rec(b)
        if ra == nil or rb == nil then return nil end
        local ok, seeded = pcall(M.seedPair, ra, rb, key)
        if not ok or type(seeded) ~= "table" then return nil end
        row = seeded
        map[key] = row
    end
    return row, key
end

-- type as seen from 'viewer' (parent/child and crush are directional)
function M.pairTypeFor(row, viewer, other)
    if row == nil then return "stranger" end
    if row.t == "parent" then return row.p == tostring(viewer) and "child" or "parent" end -- other is my parent / child
    if row.t == "crush" then return row.c == tostring(viewer) and "crush" or "admirer" end
    return row.t
end

-- natural wording: "Troy is your brother/sister" needs sex; keep it simple and neutral
M.typeWords = { sibling = "sibling", parent = "parent", child = "child", partner = "partner", crush = "someone you have a crush on",
    admirer = "someone who has a crush on you", ["best friend"] = "best friend", buddy = "buddy", friend = "friend",
    ally = "ally", comrade = "comrade", acquaintance = "acquaintance", stranger = "stranger", rival = "rival",
    distrust = "someone you distrust", enemy = "enemy", nemesis = "nemesis", respect = "someone you've come to grudgingly respect",
    ex = "ex" }

function M.typeWord(t, otherRec)
    local female = nil
    pcall(function()
        local sh = PA().Talk.shellFor(otherRec.uid)
        if sh ~= nil then female = sh:isFemale() end
    end)
    if female ~= nil then
        if t == "sibling" then return female and "sister" or "brother" end
        if t == "parent" then return female and "mother" or "father" end
        if t == "child" then return female and "daughter" or "son" end
    end
    return M.typeWords[t] or t
end

-- evolve: score change (+ reason); the type follows the score unless fixed (family) or nemesis
function M.pairBump(a, b, delta, why, newType)
    local row = M.pairRow(a, b)
    if row == nil then return nil end
    row.s = clamp((tonumber(row.s) or 0) + (tonumber(delta) or 0), -100, 100)
    if type(why) == "string" and why ~= "" then
        row.why = type(row.why) == "table" and row.why or {}
        row.why[#row.why + 1] = string.sub(why, 1, 60)
        while #row.why > 4 do table.remove(row.why, 1) end
    end
    local old = row.t
    if (tonumber(delta) or 0) < 0 then row.nb = M.pairHours and M.pairHours() or row.nb end -- 0.5.1: grudge reinforced
    if newType == "nemesis" then row.t = "nemesis"
    elseif M.bondRetype then -- 0.5.1: thresholds with hysteresis, rival / respect / romance paths (PairsLife.lua)
        pcall(M.bondRetype, row, a, b, why, delta)
    elseif not row.fx and row.t ~= "nemesis" and row.t ~= "partner" then
        local s = row.s
        if s <= -70 then row.t = "enemy"
        elseif s <= -40 and (row.t == "rival" or row.t == "distrust" or row.t == "enemy") then row.t = "enemy"
        elseif s <= -15 and (row.t ~= "rival") then row.t = "distrust"
        elseif s >= 60 and (row.t == "buddy" or row.t == "friend" or row.t == "comrade") then row.t = "best friend"
        elseif s >= 35 and (row.t == "comrade" or row.t == "acquaintance" or row.t == "friend" or row.t == "ally") then row.t = "buddy"
        elseif s >= 15 and (row.t == "stranger" or row.t == "acquaintance") then row.t = "friend" end
    end
    if row.t ~= old and M.bondChanged then pcall(M.bondChanged, a, b, old, row.t, why, row) end
    return row
end

-- closeness 0..1 for grief / protection
function M.closeness(a, b)
    local row = M.pairRow(a, b)
    if row == nil then return 0, "stranger" end
    local t = M.pairTypeFor(row, a, b)
    local base = ({ child = 1.0, parent = 1.0, sibling = 0.95, partner = 1.0, ["best friend"] = 0.85, crush = 0.6,
        admirer = 0.35, buddy = 0.6, friend = 0.45, comrade = 0.5, ally = 0.3, acquaintance = 0.15, stranger = 0.05,
        rival = 0.1, distrust = 0.03, enemy = 0, nemesis = 0, respect = 0.3, ex = 0.15 })[t] or 0.1
    local w = base + (tonumber(row.s) or 0) / 400
    return clamp(w, 0, 1), t, row
end

-- does the player know this NPC (talked, met, A-Life introduced)?
function M.playerKnows(uid, player)
    local pa = PA()
    local r = rec(uid)
    if r == nil then return false end
    local key = fn(pa.Speech, "playerKey") and player and pa.Speech.playerKey(player) or nil
    if key ~= nil and fn(pa.Names, "knows") and pa.Names.knows(r, key) then return true end
    if key ~= nil and fn(pa.NpcOpinion, "rowOf") and fn(pa.NpcOpinion, "keyOf") and pa.NpcOpinion.rowOf(r, pa.NpcOpinion.keyOf(player)) ~= nil then return true end
    if M.keyMemOf and #M.keyMemOf(uid) > 0 then return true end
    return false
end

-- ties of one NPC, strongest first: { uid, name, type, word, score, dead, known }
function M.tiesOf(uid, player, limit, includeAll)
    local pa = PA()
    local out = {}
    local map = bucket("pairs")
    local me = tostring(uid)
    for key, row in pairs(map) do
        local a, b = string.match(key, "^(.-)|(.*)$")
        local other = (a == me and b) or (b == me and a) or nil
        if other ~= nil and type(row) == "table" then
            local orec = rec(other)
            local ghost = nil
            if orec == nil and M.ghostRecord then -- 0.5.1.5: A-Life dropped their record (far away) -> the people book
                ghost = M.ghostRecord(other)
                orec = ghost
            end
            local t = M.pairTypeFor(row, me, other)
            local strong = math.abs(tonumber(row.s) or 0) >= 20 or row.fx or t == "nemesis" or t == "partner" or t == "crush" or t == "respect" or t == "rival" or t == "ex"
            if orec ~= nil and (strong or includeAll) then
                local known = player == nil or M.playerKnows(other, player)
                local name = known and fn(pa.Names, "of") and pa.Names.of(orec) or "someone"
                if player ~= nil and M.shownName and M.settings.nameDiscovery ~= false then -- 0.5.1: Stranger / fake / real, as in game
                    local shown, isKnown = M.shownName(other, player)
                    name, known = shown, known and isKnown
                    if not isKnown then name = "Stranger" end
                end
                if ghost ~= nil then
                    local e = bucket("book")[other]
                    name, known = tostring(e and e.name or "Someone"), true
                end
                -- 0.5.2.6 [pt254u]: dead by any record (off-screen deaths too); a dead partner / family is "late partner"
                local dead = orec.lifecycle == "dead"
                if not dead and M.isPersonDead and M.settings.offDeath ~= false then dead = M.isPersonDead(other, (not ghost) and orec or nil) end
                local word = M.typeWord(t, orec)
                if dead and M.lateTypes and M.lateTypes[t] then word = "late " .. tostring(word) end
                out[#out + 1] = { uid = other, name = tostring(name), type = t, word = word, score = tonumber(row.s) or 0,
                    dead = dead, late = dead and M.lateTypes and M.lateTypes[t] or nil, known = known, why = type(row.why) == "table" and row.why[#row.why] or nil }
            end
        end
    end
    table.sort(out, function(x, y) return math.abs(x.score) > math.abs(y.score) end)
    while limit and #out > limit do table.remove(out) end
    return out
end

-- make sure pairs exist for NPCs that share a place (cheap; called for people present in a prompt)
function M.ensurePairs(uid, others)
    for _, o in ipairs(others or {}) do if tostring(o) ~= tostring(uid) then M.pairRow(uid, o) end end
end

-- the player <-> NPC bond word (A-Life opinion drives it; our events add family-grade grudges like nemesis)
function M.playerTie(r, player)
    local pa = PA()
    local v = 0
    if fn(pa.NpcOpinion, "valueOf") then v = pa.NpcOpinion.valueOf(r, player) or 0 end
    local ally = fn(pa.Party, "friendly") and pa.Party.friendly(r, player) == true
    local nem = bucket("playerNemesis")[tostring(r.uid)]
    if nem then return "nemesis", v end
    if ally then return v >= 60 and "best friend" or "ally", v end
    if v >= 71 then return "best friend", v elseif v >= 41 then return "buddy", v elseif v >= 16 then return "friend", v
    elseif v > -16 then return (M.playerKnows(r.uid, player) and "acquaintance" or "stranger"), v
    elseif v > -41 then return "distrust", v elseif v > -71 then return "enemy", v end
    return "enemy", v
end
function M.markPlayerNemesis(uid, why)
    bucket("playerNemesis")[tostring(uid)] = string.sub(tostring(why or "personal grudge"), 1, 60)
end

-- prompt: relationships with the people present (+ the player bond)
table.insert(M.requestExtras, function(req, player, listener, now)
    local me = tostring(listener.record.uid)
    local seen, list = {}, {}
    local function add(other)
        other = tostring(other)
        if other == me or seen[other] or #list >= 5 then return end
        seen[other] = true
        local row = M.pairRow(me, other)
        local orec = rec(other)
        local ghost = false
        if orec == nil and M.ghostRecord and M.settings.offDeath ~= false then orec = M.ghostRecord(other); ghost = orec ~= nil end -- 0.5.2.6
        if row ~= nil and orec ~= nil then
            local t = M.pairTypeFor(row, me, other)
            local name = fn(PA().Names, "of") and PA().Names.of(orec) or "someone"
            if ghost then local be = bucket("book")[tostring(other)]; name = (type(be) == "table" and be.name) or name end
            -- 0.5.2.6 [pt254u]: dead by any record, unless this listener hasn't been told yet (grief entry not known)
            local dead = orec.lifecycle == "dead" or (M.isPersonDead ~= nil and M.settings.offDeath ~= false and M.isPersonDead(other, (not ghost) and orec or nil))
            if dead and orec.lifecycle ~= "dead" and M.griefOf then
                local g = M.griefOf(me)[tostring(other)]
                if type(g) == "table" and not g.known then dead = false end
            end
            local word = M.typeWord(t, orec)
            if dead and M.lateTypes and M.lateTypes[t] then word = "late " .. tostring(word) end
            list[#list + 1] = { tostring(name), word, tonumber(row.s) or 0, dead and 1 or 0,
                type(row.why) == "table" and row.why[#row.why] or nil }
        end
    end
    for _, u in ipairs(req.presentUids or {}) do add(u) end
    if req.speakerUid then add(req.speakerUid) end
    -- strongest ties even when they aren't here (family, partner, nemesis): they matter for mood and grief
    for _, t in ipairs(M.tiesOf(me, nil, 3)) do
        if t.type == "sibling" or t.type == "parent" or t.type == "child" or t.type == "partner" or t.type == "nemesis"
                or t.type == "best friend" then add(t.uid) end
    end
    if #list > 0 then req.pairs = list end
    local okT, tie = pcall(M.playerTie, listener.record, player)
    if okT and tie then req.youTie = tie end
end)

return M
