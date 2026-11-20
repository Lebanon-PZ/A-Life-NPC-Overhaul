-- A-Life Talk 0.5.1.5: FAR-AWAY PROFILES - the Relationships pages of people who are far away stay filled in.
-- Why: A-Life keeps a record for a dormant NPC, but a travelling squad that renders out (or a pruned / culled record)
-- loses its record completely. Our people book (Keep.lua) kept the name / opinion / last seen, but the Personality page
-- was built only from A-Life's live record and came back empty, and ties to such people were dropped.
-- This file keeps a small profile snapshot inside the people book (ModData, bucket "book", field "prof"):
-- role, faction, age, trait chart, traits, quirks, persona summary, opinion, the 5 strongest ties, where / when seen.
-- Memories, interactions, story bits and feelings already live in our own ModData buckets keyed by uid, so they are
-- read from there as before (no copy). Snapshots are taken only from a LIVE A-Life record:
--   * when you talk to someone (at once), when A-Life is about to remove a known person (at once),
--   * when a known person is loaded near you or refreshed in the menu (queued, max 2 per tick, at most every 2 min).
-- The pages use the snapshot only when the live data is missing or partial. Setting "farProfiles" turns it off.
-- Removable: without this file the pages just fall back to the book / "not much known yet" lines.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Profile") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Profile"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Profile") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function small(s, n) if s == nil then return nil end return string.sub(tostring(s), 1, n or 80) end

if M.settings.farProfiles == nil then M.settings.farProfiles = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "farProfiles" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "farProfiles" end
end
M.profileCfg = { everyMs = 120000, perTick = 2, queueMax = 2000 }
M.profileAt = M.profileAt or {}
M.profileQ = M.profileQ or { list = {}, has = {}, head = 1, tail = 0 }
M.profileStats = M.profileStats or { snaps = 0, queued = 0, forced = 0 }

local function liveRec(uid)
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    return pa.ActorRegistry.read(tostring(uid))
end
local function listCopy(t, n)
    local o = {}
    if type(t) ~= "table" then return o end
    for i, v in ipairs(t) do
        if n and i > n then break end
        o[#o + 1] = type(v) == "table" and v or small(v, 100)
    end
    return o
end

function M.profileOf(uid)
    local e = M.bucket("book")[tostring(uid)]
    return (type(e) == "table" and type(e.prof) == "table") and e.prof or nil
end

-- take the snapshot now (only people already in the book; only from a live record)
function M.profileSnap(uid, rec)
    if M.settings.farProfiles == false then return nil end
    uid = tostring(uid)
    rec = rec or liveRec(uid)
    if type(rec) ~= "table" or rec.ghost then return nil end
    local e = M.bucket("book")[uid]
    if type(e) ~= "table" then return nil end
    local pa = PA()
    local player = ALifeSide.you()
    local pf = type(e.prof) == "table" and e.prof or {}
    if pa and fn(pa.DialogueRoles, "describe") then
        local ok, who = pcall(pa.DialogueRoles.describe, rec, 0)
        if ok and type(who) == "table" then pf.role, pf.sex = small(who.label, 60) or pf.role, who.sex or pf.sex end
    end
    if pa and fn(pa.Catalog, "faction") then
        pcall(function()
            local f = pa.Catalog.faction(rec.factionId)
            if type(f) == "table" and type(f.general) == "table" and f.general.name then pf.fac = small(f.general.name, 60) end
        end)
    end
    pf.fac = pf.fac or (rec.factionId and small(rec.factionId, 60)) or nil
    -- the persona row is picked from the LIVE record here, so it is never guessed later from thin saved data
    if M.personaOf and M.personaParts then
        pcall(function()
            local row = M.personaOf(uid, rec)
            local p = row and M.personaParts(row)
            if p then
                pf.pi = row.i
                pf.persona = { label = small(p.entry.label, 60), traits = listCopy(p.core.traits, 4), speech = small(p.speech and p.speech[1], 40),
                    speechHint = small(p.speech and p.speech[2], 80), quirk = small(p.quirk, 80), values = small(p.core.values, 100),
                    dislikes = small(p.core.dislikes, 100), phrase = small(p.phrase, 80) }
            end
        end)
    end
    if M.ageOf then local ok, a = pcall(M.ageOf, uid); if ok and tonumber(a) then pf.age = tonumber(a) end end
    if M.traitChart then
        local ok, ch = pcall(M.traitChart, uid, 5)
        if ok and type(ch) == "table" and #ch > 0 then
            pf.chart = {}
            for i, c in ipairs(ch) do
                pf.chart[i] = { key = c.key, label = small(c.label, 30), pct = c.pct, tip = small(c.tip, 100),
                    rgb = type(c.rgb) == "table" and { c.rgb[1], c.rgb[2], c.rgb[3] } or nil }
            end
        end
    end
    if M.traitLines then
        local ok, t, q = pcall(M.traitLines, uid)
        if ok and type(t) == "table" and #t > 0 then pf.traits = listCopy(t, 3) end
        if ok and type(q) == "table" and #q > 0 then pf.quirks = listCopy(q, 2) end
    end
    if M.opinionView then
        local ok, v, label = pcall(M.opinionView, rec, player)
        if ok and tonumber(v) then
            pf.v, pf.label = tonumber(v), label
            e.value, e.label = tonumber(v), label or e.label
        end
    end
    if M.tiesOf then
        local ok, list = pcall(M.tiesOf, uid, player, 5)
        if ok and type(list) == "table" and #list > 0 then
            pf.ties = {}
            for i, t in ipairs(list) do
                if i > 5 then break end
                pf.ties[i] = { uid = t.uid, name = small(t.name, 40), type = t.type, word = small(t.word, 30), score = t.score, dead = t.dead }
            end
        end
    end
    pf.h = hours()
    if pf.first == nil then
        M.keepLog("profile: saved " .. tostring(e.name or uid) .. "'s page (shown when they are far away)", "prof|" .. uid, 1e12)
    end
    pf.first = pf.first or pf.h
    e.prof = pf
    M.profileAt[uid] = M.nowMs()
    M.profileStats.snaps = M.profileStats.snaps + 1
    return pf
end

-- force = now (talk, removal); otherwise queued and spread over ticks
function M.profileWant(uid, rec, force)
    if M.settings.farProfiles == false or uid == nil then return end
    uid = tostring(uid)
    if force then
        if M.profileOf(uid) ~= nil and (M.nowMs() - (M.profileAt[uid] or -1e12)) < 5000 then return M.profileOf(uid) end
        M.profileStats.forced = M.profileStats.forced + 1
        return M.profileSnap(uid, rec)
    end
    local due = M.profileOf(uid) == nil or (M.nowMs() - (M.profileAt[uid] or -1e12)) >= M.profileCfg.everyMs
    local q = M.profileQ
    if not due or q.has[uid] or (q.tail - q.head + 1) >= M.profileCfg.queueMax then return end
    q.has[uid] = true
    q.tail = q.tail + 1
    q.list[q.tail] = uid
    M.profileStats.queued = M.profileStats.queued + 1
end

function M.profileDrain(n)
    local q = M.profileQ
    local done = 0
    n = n or M.profileCfg.perTick
    while done < n and q.head <= q.tail do
        local uid = q.list[q.head]
        q.list[q.head] = nil
        q.head = q.head + 1
        q.has[uid] = nil
        pcall(M.profileSnap, uid, nil)
        done = done + 1
    end
    if q.head > q.tail then M.profileQ = { list = {}, has = {}, head = 1, tail = 0 } end
    return done
end

if type(Events) == "table" and Events.OnTick then
    ALifeHealth.tickAdd("ALifeLLMTalk_Profile", function()
        local q = M.profileQ
        if q.head <= q.tail then pcall(M.profileDrain) end
    end)
end

return M
