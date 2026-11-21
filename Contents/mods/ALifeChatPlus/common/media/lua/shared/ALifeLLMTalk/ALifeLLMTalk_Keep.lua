-- A-Life Talk 0.5.1: the people you know stay in the world.
-- What A-Life does (read from its source): an NPC far from every player (90+ tiles, e.g. after a teleport) is made
-- "dormant" - saved with its uid, memory and body state, frozen in place - and respawns when you come back within
-- ~60 tiles. But a dormant "expendable" NPC is DELETED after Population_DormantTtlHours (default 8 in-game hours),
-- and offline squads delete their members when they leave and re-create them later with a new uid (new name, no
-- memory of you). With ALifeTalkPatch 1.3 the patch refuses those deletions for people you know and gives returning
-- squad members their old uid / name / introductions / opinion back. This file:
--   * tells the patch who counts as "known" on our side (talk memories, nemesis, romance, fake name, strong bond);
--   * remembers where you last saw each person ("last seen near Riverside, 5 h ago" in the Relationships menu while
--     they're away / dormant);
--   * handles teleports (log, drop stale territory / pause / activity state; companions catch up via the patch).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Keep") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Keep"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Keep") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end

if M.settings.keepKnown == nil then M.settings.keepKnown = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "keepKnown" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "keepKnown" end
end
M.keepCfg = { seenTiles = 45, seenEveryMs = 10000 }

-- "known" on our side (the patch adds its own checks: opinion >= 10 either way, introduced, companion, nemesis)
function M.isKnownPerson(uid, record)
    if M.settings.keepKnown == false then return false end
    uid = tostring(uid)
    local km = bucket("keymem")[uid]
    if type(km) == "table" and #km > 0 then return true end
    if M.nemesisOf and M.nemesisOf(uid) ~= nil then return true end
    if M.romanceOf then local ok, ro = pcall(M.romanceOf, uid); if ok and type(ro) == "table" and (ro.stage or 0) >= 1 then return true end end
    local fakes = bucket("fakeNames")[uid]
    if fakes ~= nil then return true end
    -- 0.5.1.3: everyone you actually dealt with (what the menu lists): an interaction row, favorite, party, settler, book
    if M.interactionsOf and #M.interactionsOf(uid) > 0 then return true end
    if bucket("favorites")[uid] == true or bucket("party")[uid] ~= nil or bucket("settlers")[uid] ~= nil then return true end
    local be = bucket("book")[uid]
    if type(be) == "table" and not be.dead then return true end
    return false
end

-- last seen (by you)
function M.noteSeen(now)
    local player = ALifeSide.you()
    if player == nil then return end
    local x, y, z = pos(player)
    local seen = bucket("seen")
    local h = hours()
    for _, l in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z, M.keepCfg.seenTiles) or {}) do
        local sx, sy = pos(l.shell)
        if sx then seen[tostring(l.record.uid)] = { x = math.floor(sx), y = math.floor(sy), h = h } end
        -- 0.5.1.5: a known person loaded near you -> refresh their saved page (queued, at most every 2 min)
        if sx and M.profileWant and type(bucket("book")[tostring(l.record.uid)]) == "table" then
            local e = bucket("book")[tostring(l.record.uid)]
            e.x, e.y, e.h = math.floor(sx), math.floor(sy), h
            M.profileWant(l.record.uid, nil, false)
        end
        if sx and M.lookSave then pcall(M.lookSave, l.record.uid, l.shell, false) end -- 0.5.1.5: their look (Look.lua)
    end
end
local function agoText(dh)
    if dh < 1 then return "less than an hour ago" end
    if dh < 48 then return math.floor(dh + 0.5) .. " h ago" end
    return math.floor(dh / 24 + 0.5) .. " days ago"
end
function M.lastSeenOf(uid, record)
    local pa = PA()
    record = record or (fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil)
    if record == nil then return nil end
    local away = record.lifecycle == "dormant"
    local s = bucket("seen")[tostring(uid)]
    local x, y, h = nil, nil, nil
    if type(s) == "table" then x, y, h = s.x, s.y, s.h end
    local m = type(record.memory) == "table" and record.memory or {}
    if away and h == nil then
        h = tonumber(m.dormantSinceHours)
        if type(record.worldPosition) == "table" then x, y = math.floor(record.worldPosition.x), math.floor(record.worldPosition.y) end
    end
    if x == nil or h == nil then return { away = away } end
    local town = M.townAt and M.townAt(x, y) or nil
    local where = town and ("near " .. town .. " (" .. x .. ", " .. y .. ")") or ("at " .. x .. ", " .. y)
    return { away = away, x = x, y = y, h = h, text = "Last seen " .. where .. ", " .. agoText(math.max(0, hours() - h)) }
end

-- teleports (the patch detects them: a jump of 150+ tiles outside a car)
function M.onTeleport(player, ox, oy, nx, ny)
    local d = math.floor(math.sqrt((nx - ox) ^ 2 + (ny - oy) ^ 2))
    log("teleport: " .. d .. " tiles - known people nearby stay where they were (A-Life parks them; the patch keeps them)")
    M.terr = nil
    if type(M.paused) == "table" then for k in pairs(M.paused) do M.paused[k] = nil end end
    local P = patch()
    if P and type(M.activities) == "table" and fn(P, "activityStop") then
        for uid in pairs(M.activities) do pcall(P.activityStop, uid, "teleport") end
        M.activities = {}
    end
    M.teleportedAt = nowMs()
end

function M.keepInstall()
    local P = patch()
    if P == nil or M.keepHooked then return end
    M.keepHooked = true
    P.protectors = P.protectors or {}
    table.insert(P.protectors, function(uid, record) return M.isKnownPerson(uid, record) end)
    if type(P.hooks) == "table" then
        if type(P.hooks.teleport) == "table" then table.insert(P.hooks.teleport, function(...) pcall(M.onTeleport, ...) end) end
        if type(P.hooks.kept) == "table" then
            table.insert(P.hooks.kept, function(uid, reason)
                if M.logInteraction then pcall(M.logInteraction, uid, "Stayed in the world while you were away (A-Life wanted to remove them: " .. tostring(reason) .. ")", nil, nil, "event") end
            end)
        end
        if type(P.hooks.seedRestored) == "table" then
            table.insert(P.hooks.seedRestored, function(oldUid, newUid)
                if M.logInteraction then pcall(M.logInteraction, newUid, "Came back with their squad", nil, nil, "event") end
            end)
        end
        if type(P.hooks.companionCaughtUp) == "table" then
            table.insert(P.hooks.companionCaughtUp, function(uid)
                if M.logInteraction then pcall(M.logInteraction, uid, "Caught up with you after you travelled", nil, nil, "event") end
            end)
        end
    end
    log("keep: registered with the patch (known people are not culled)")
end

if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.keepInstall) end) end
    if Events.OnTick then
        local last = -1e12
        ALifeHealth.tickAdd("ALifeLLMTalk_Keep", function()
            local now = nowMs()
            if not M.keepHooked then pcall(M.keepInstall) end
            if now - last < M.keepCfg.seenEveryMs then return end
            last = now
            M.eachPlayer(function() pcall(M.noteSeen, now) end) -- pre-1.0 MP: seen near any player (SP: you)
        end)
    end
end
pcall(M.keepInstall)


----------------------------------------------------------------------------------------------------------------
-- 0.5.1.3: THE PEOPLE BOOK - our own saved copy of everyone in the Relationships menu (name, opinion, introduced,
-- dead, where / when last seen). A-Life may still delete a record we can't protect (a travelling squad renders out,
-- dead records are pruned past 256, the patch is off, a catalog entry was removed): the menu then shows the person
-- from this book as "Away - whereabouts unknown, last seen ..." instead of silently dropping them.
----------------------------------------------------------------------------------------------------------------
function M.keepLog(msg, key, gapMs)
    if key ~= nil then
        M.keepLogAt = M.keepLogAt or {}
        local now = nowMs()
        if now - (M.keepLogAt[key] or -1e12) < (gapMs or 600000) then return end
        M.keepLogAt[key] = now
    end
    ALifeHealth.note("[ALifeTalk][Keep]", msg)
end
local function copyT(t, depth)
    if type(t) ~= "table" or (depth or 0) > 3 then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copyT(v, (depth or 0) + 1) end
    return o
end
-- n: the menu row ({ uid, name, value, label, dead }) when we have one
function M.bookSnap(rec, n)
    if type(rec) ~= "table" or rec.uid == nil or rec.ghost then return nil end
    local uid = tostring(rec.uid)
    local b = bucket("book")
    local e = type(b[uid]) == "table" and b[uid] or {}
    local m = type(rec.memory) == "table" and rec.memory or {}
    if e.name == nil then M.keepLog("book: added " .. tostring(n and n.name or m.personName or uid) .. " (" .. uid .. ")", "add|" .. uid, 1e12) end
    e.name = (n and n.name) or e.name or m.personName or "Someone"
    e.real, e.first, e.last = m.personName or e.real, m.personFirst or e.first, m.personLast or e.last
    if n then e.value, e.label = n.value, n.label end
    -- 0.5.2.6: a row folded into a dead namesake (no record back then) whose own record walks again was someone else
    if e.mergedInto ~= nil and (rec.lifecycle == "active" or rec.lifecycle == "dormant") then
        local d = bucket("deaths")[uid]
        if type(d) == "table" and d.src == "twin" then bucket("deaths")[uid] = nil; e.dead = nil; e.diedH = nil; e.diedWhy = nil end
        e.mergedInto = nil
    end
    e.dead = rec.lifecycle == "dead" or e.dead == true
    e.fac = rec.factionId or e.fac
    e.seed = m.identitySeed or e.seed -- 0.5.2.6: matches A-Life's off-screen casualties (WarDead) to this person
    e.grp = m.squadId or m.groupId or e.grp
    if type(m.introducedTo) == "table" then e.intro = copyT(m.introducedTo) end
    if type(m.opinion) == "table" then e.op = copyT(m.opinion) end
    e.squad = m.squadId or e.squad
    local s = bucket("seen")[uid]
    if type(s) == "table" then e.x, e.y, e.h = s.x, s.y, s.h
    elseif type(rec.worldPosition) == "table" and e.x == nil then
        e.x, e.y, e.h = math.floor(rec.worldPosition.x), math.floor(rec.worldPosition.y), tonumber(m.dormantSinceHours) or hours()
    end
    if e.mx == nil and e.x ~= nil then e.mx, e.my, e.mh = e.x, e.y, e.h end -- pre-1.0: where you first came across them (People groups)
    e.gone, e.goneH = nil, nil
    b[uid] = e
    if M.profileWant then M.profileWant(uid, nil, false) end -- 0.5.1.5: queued page snapshot (Profile.lua)
    return e
end
-- a read-only stand-in record built from the book (never written to A-Life)
function M.ghostRecord(uid)
    uid = tostring(uid)
    local e = bucket("book")[uid]
    if type(e) ~= "table" then return nil end
    return { uid = uid, ghost = true, lifecycle = e.dead and "dead" or "dormant", factionId = e.fac or "unknown",
        memory = { personName = e.real, personFirst = e.first, personLast = e.last, introducedTo = copyT(e.intro),
            opinion = copyT(e.op), dormantSinceHours = e.h, squadId = e.squad },
        worldPosition = e.x and { x = e.x, y = e.y, z = 0 } or nil }
end
function M.bookAwayText(uid)
    local e = bucket("book")[tostring(uid)]
    if type(e) ~= "table" then return nil end
    local where = ""
    if e.x and e.y then
        local town = M.townAt and M.townAt(e.x, e.y) or nil
        where = " near " .. (town and (town .. " ") or "") .. "(" .. e.x .. ", " .. e.y .. ")"
    end
    local ago = e.h and (", " .. agoText(math.max(0, hours() - e.h))) or ""
    local why = e.squad and "travelling with their group" or "whereabouts unknown"
    return "Away - " .. why .. ". Last seen" .. where .. ago
end
-- book entries whose A-Life record is gone (and who didn't come back under a new uid)
function M.bookGhosts(have)
    local out = {}
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    for uid, e in pairs(bucket("book")) do
        if type(e) == "table" and not have[uid] then
            local live = fn(reg, "read") and reg.read(uid) or nil
            local moved = e.movedTo and fn(reg, "read") and reg.read(e.movedTo) or nil
            -- 0.5.2.6 [pt254u]: the newer uid has its own book row (A-Life dropped its record too) -> that row
            -- stands for them; a row folded into a twin (same person) is hidden as well
            local b = bucket("book")
            if moved == nil and e.movedTo ~= nil and type(b[tostring(e.movedTo)]) == "table" then moved = true end
            if e.mergedInto ~= nil and M.settings.deathMerge ~= false and (type(b[tostring(e.mergedInto)]) == "table"
                    or (fn(reg, "read") and reg.read(tostring(e.mergedInto)) ~= nil)) then moved = true end
            if live == nil and moved == nil then out[#out + 1] = uid end
        end
    end
    return out
end
function M.keepHooksInstall()
    local P = patch()
    if P == nil or type(P.hooks) ~= "table" or M.keepBookHooked then return end
    if type(P.hooks.removing) ~= "table" then return end -- patch < 1.3.1
    M.keepBookHooked = true
    table.insert(P.hooks.removing, function(uid, reason, record)
        local had = record and type(bucket("book")[tostring(record.uid)]) == "table"
        local e = M.bookSnap(record)
        -- 0.5.1.5: last chance to save their page from the live record (only people you know)
        if e and had and M.profileWant then pcall(M.profileWant, record.uid, record, true) end
        if e and had and M.lookSave then pcall(M.lookSave, record.uid, nil, true) end
        if e then e.gone, e.goneH = tostring(reason), hours() end
    end)
    table.insert(P.hooks.removed, function(uid, reason)
        local e = bucket("book")[tostring(uid)]
        if e then e.gone, e.goneH = tostring(reason), hours() end
        M.keepLog("A-Life removed " .. tostring(e and e.name or uid) .. " (" .. tostring(uid) .. ", " .. tostring(reason)
            .. ") - still in your Relationships menu from saved data (away)")
    end)
    if type(P.hooks.seedRestored) == "table" then
        table.insert(P.hooks.seedRestored, function(oldUid, newUid)
            oldUid, newUid = tostring(oldUid), tostring(newUid)
            local b = bucket("book")
            if oldUid ~= newUid and type(b[oldUid]) == "table" then
                b[oldUid].movedTo = newUid
                M.keepLog("book: " .. tostring(b[oldUid].name) .. " came back as " .. newUid .. " - old entry " .. oldUid .. " hidden (merged)")
            end
        end)
    end
end
function M.keepLoadSummary()
    local n, dead, away = 0, 0, 0
    local pa = PA()
    for uid, e in pairs(bucket("book")) do
        if type(e) == "table" then
            n = n + 1
            if e.dead then dead = dead + 1
            elseif not (pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid)) then away = away + 1 end
        end
    end
    local P = patch()
    M.keepLog("load: " .. n .. " people in the book (" .. dead .. " dead, " .. away .. " without an A-Life record -> shown as away); keepKnown="
        .. tostring(M.settings.keepKnown ~= false) .. " patch=" .. tostring(P ~= nil and P.VERSION or "off")
        .. ((P and type(P.hooks) == "table" and type(P.hooks.removing) == "table") and "" or " (patch < 1.3.1: no removal snapshots)"))
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.keepHooksInstall) end) end
    if Events.OnTick then
        local last, summary, t0 = -1e12, false, nil
        ALifeHealth.tickAdd("ALifeLLMTalk_Keep", function()
            local now = nowMs()
            t0 = t0 or now
            if not M.keepBookHooked then pcall(M.keepHooksInstall) end
            if not summary and now - t0 >= 8000 then summary = true; pcall(M.keepLoadSummary) end
            if now - last < 120000 then return end -- every 2 min: refresh the book from A-Life's records
            last = now
            if M.knownNpcs then M.eachPlayer(function(p) pcall(M.knownNpcs, p) end) end -- pre-1.0 MP: every player's known people
        end)
    end
end
pcall(M.keepHooksInstall)

return M
