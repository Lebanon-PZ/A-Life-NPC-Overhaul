-- A-Life Talk 0.5.2.6 [pt254u] "i dont think its fully registering that mr jorge died off screen while scavenging".
-- People you know can die where you can't see them, and A-Life then never fires ProjectALife_NpcDied for us:
--   * a travelling squad is not loaded: its members have no A-Life record at all (render_out deleted them) and an
--     offline fight just removes them from the squad's roster (ALifeOfflineCombat shed) and queues a body in
--     ModData "ProjectALife.WarDead" (pending { identitySeed, x, y, hours }); a squad that loses everyone is "wiped";
--   * a rendered squad member who died is a "dead" record that A-Life deletes when the squad renders out;
--   * the final-deaths list (ModData "ALifeTalkFinalDeaths", shared with the patch) keeps every uid that died for good;
--   * a squad member that came back under a new uid (patch seedRestored) is the same person: the people book links
--     the old uid to the new one (movedTo) - when the new uid dies the old book row used to come back as "Away".
-- This file makes those records the source of truth: a slow, budgeted scan of the people book (no per-frame work)
-- confirms the death once, everywhere: the book row (dead, merged with its twin), the final-deaths list, grief +
-- key memory for the people tied to them, "late partner" ties, pending last words. It also builds the never-cut
-- "DEAD" facts for prompts and lets telling an NPC about a death register with them.
-- Switches: offDeath (scan + confirm), deathMerge (one row per person), toldDeath (telling an NPC), deathFacts (prompt).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_OffDeath") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "OffDeath"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("OffDeath") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end
local function log(msg) M.log(msg) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function bucket(name) return M.bucket(name) end
local function patch() return M.patch and M.patch() or nil end
local function peek(uid)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    if reg == nil then return nil end
    local f = fn(reg, "peek") and reg.peek or (fn(reg, "read") and reg.read) or nil
    if f == nil then return nil end
    local ok, r = pcall(f, tostring(uid))
    return ok and r or nil
end
local function nameOf(r) local pa = PA(); return (r and pa and fn(pa.Names, "of") and pa.Names.of(r)) or nil end

for _, k in ipairs({ "offDeath", "deathMerge", "toldDeath", "deathFacts", "bridgeVersionWarn" }) do
    if M.settings[k] == nil then M.settings[k] = true end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
M.odCfg = { newsDelayH = 1, newsPerScan = 40, scanMs = 15000, perTick = 25, eventWaitMs = 20000, chainHops = 6, factsMax = 3, toldLightW = 0.3, toldStrangerW = 0.12 }
M.odStats = { scans = 0, confirmed = 0, merged = 0, told = 0 }

local CLOSE = { partner = true, spouse = true, sibling = true, parent = true, child = true, family = true, ["best friend"] = true, crush = true, buddy = true }
M.lateTypes = CLOSE

----------------------------------------------------------------------------------------------------------------
-- who is dead (one answer for every file)
----------------------------------------------------------------------------------------------------------------
function M.deathOf(uid) local d = bucket("deaths")[tostring(uid)]; return type(d) == "table" and d or nil end
-- the uid a book row really stands for now (a squad member who came back under a new uid, a merged twin)
function M.canonUid(uid)
    uid = tostring(uid)
    local b = bucket("book")
    for _ = 1, M.odCfg.chainHops do
        local e = b[uid]
        if type(e) ~= "table" then break end
        local nx = e.mergedInto or e.movedTo
        if nx == nil or tostring(nx) == uid then break end
        uid = tostring(nx)
    end
    return uid
end
-- dead = a dead record, the final-deaths list, our confirmed deaths, the book (also through the uid chain).
-- A walking (or downed) person with a live record is never dead here: down is not dead (0.5.2.5).
function M.isPersonDead(uid, r)
    if uid == nil then return false end
    uid = tostring(uid)
    r = r or peek(uid)
    if type(r) == "table" and not r.ghost then
        if r.lifecycle == "dead" then return true end
        if r.lifecycle == "active" or r.lifecycle == "spawning" then return false end
    end
    if M.isFinalDead and M.isFinalDead(uid) then return true end
    if M.deathOf(uid) then return true end
    local e = bucket("book")[uid]
    if type(e) == "table" and e.dead then return true end
    local c = M.canonUid(uid)
    if c ~= uid then
        local rc = peek(c)
        if type(rc) == "table" and rc.lifecycle == "dead" then return true end
        if type(rc) == "table" and (rc.lifecycle == "active" or rc.lifecycle == "spawning" or rc.lifecycle == "dormant") then return false end
        if M.deathOf(c) or (M.isFinalDead and M.isFinalDead(c)) then return true end
        local ec = bucket("book")[c]
        if type(ec) == "table" and ec.dead then return true end
    end
    return false
end

local function howText(src, info)
    info = info or {}
    if src == "offline_fight" then return "killed in a fight while away with their group" end
    if src == "squad_wiped" then return "their whole group was wiped out while away" end
    if src == "expedition" then return "died while out scavenging, away from base" end
    if src == "record" then return "died while you weren't around" end
    if src == "final" then return "died while you weren't around" end
    if src == "moved" or src == "twin" then return tostring(info.how or "died while away") end
    if src == "event" then return tostring(info.how or "died") end
    return "died while away"
end
local function dayOf(h)
    local d = 0
    pcall(function()
        local pa = PA()
        local c = pa and fn(pa.Speech, "clock") and pa.Speech.clock() or nil
        if type(c) == "table" and tonumber(c.daysSurvived) then d = math.floor(tonumber(c.daysSurvived) - (hours() - (tonumber(h) or hours())) / 24) end
    end)
    return math.max(0, d)
end

----------------------------------------------------------------------------------------------------------------
-- one confirmed death, everywhere
----------------------------------------------------------------------------------------------------------------
local function sameFac(a, b) return a == nil or b == nil or tostring(a) == tostring(b) end
local function lowName(s) return string.lower(tostring(s or "")) end
-- book rows that are the same person: the uid chain both ways, and an "Away" row (no A-Life record) with the same
-- name and group as the dead one
function M.twinsOf(uid)
    uid = tostring(uid)
    local b = bucket("book")
    local me = b[uid]
    local out = {}
    local myName = type(me) == "table" and lowName(me.real or me.name) or lowName(nameOf(peek(uid)))
    local r0 = peek(uid)
    local myFac = (type(me) == "table" and me.fac) or (r0 and r0.factionId) or nil
    for k, e in pairs(b) do
        if k ~= uid and type(e) == "table" then
            local linked = M.canonUid(k) == uid or (type(me) == "table" and M.canonUid(uid) == tostring(k))
            if not linked and myName ~= "" and myName ~= "someone" and lowName(e.real or e.name) == myName and sameFac(e.fac, myFac) then
                local rk = peek(k)
                linked = rk == nil -- only rows A-Life has no record for (never a living person who just shares a name)
            end
            if linked then out[#out + 1] = k end
        end
    end
    return out
end

function M.confirmDeath(uid, src, info)
    if uid == nil then return false end
    uid = tostring(uid)
    info = type(info) == "table" and info or {}
    local deaths = bucket("deaths")
    if deaths[uid] ~= nil then return false end
    local r = peek(uid)
    if type(r) == "table" and (r.lifecycle == "active" or r.lifecycle == "spawning") then return false end -- alive (or only down)
    local b = bucket("book")
    local e = b[uid]
    if type(e) ~= "table" and type(r) == "table" and M.bookSnap then pcall(M.bookSnap, r); e = b[uid] end
    local name = (type(e) == "table" and e.name) or nameOf(r) or "Someone"
    local how = howText(src, info)
    local h = tonumber(info.h) or hours()
    deaths[uid] = { n = name, h = h, src = tostring(src), how = how, day = dayOf(h) }
    if type(e) == "table" then e.dead = true; e.diedH = e.diedH or h; e.diedWhy = e.diedWhy or how end
    -- the same person under other uids: dead too, folded into one row (the newest uid of the chain stays)
    local twins = M.settings.deathMerge ~= false and M.twinsOf(uid) or {}
    local primary = M.canonUid(uid)
    if type(b[primary]) ~= "table" and peek(primary) == nil then primary = uid end
    if primary ~= uid and type(e) == "table" and e.movedTo == nil then e.mergedInto = primary end
    for _, k in ipairs(twins) do
        local t = b[k]
        if type(t) == "table" then
            if not t.dead then M.odStats.merged = M.odStats.merged + 1 end
            t.dead = true; t.diedH = t.diedH or h; t.diedWhy = t.diedWhy or how
            if k ~= primary and M.canonUid(k) ~= primary and t.movedTo == nil then t.mergedInto = primary end
            deaths[k] = deaths[k] or { n = name, h = h, src = "twin", how = how, day = dayOf(h), of = uid }
        end
    end
    if src ~= "event" and M.markFinalDead and not (M.isFinalDead and M.isFinalDead(uid)) then
        pcall(M.markFinalDead, uid, "off-screen: " .. tostring(src), r or (M.ghostRecord and M.ghostRecord(uid)) or nil)
    end
    -- grief + "died - they don't know yet" for the people tied to them (the event path already did it on-screen)
    if src ~= "event" and not info.noGrief and M.griefOnDeath then
        local victim = r or (M.ghostRecord and M.ghostRecord(uid)) or nil
        if victim ~= nil then
            local ok, err = pcall(M.griefOnDeath, nil, uid, nil, { victim = victim, kn = how, at = h, skipName = true })
            if not ok then log("off-screen death grief error: " .. tostring(err)) end
        end
    end
    -- last words said while down, before they were carried off-screen: the death is confirmed now
    if M.lastWordsDone and type(M.lastWordsDone[uid]) == "table" and M.lastWordsDone[uid].pending and M.lastWordsOnDeath then
        pcall(M.lastWordsOnDeath, nil, uid, nil)
    end
    if src ~= "event" and M.logInteraction then pcall(M.logInteraction, uid, "Died while you weren't there (" .. how .. ")", nil, nil, "event") end
    M.odStats.confirmed = M.odStats.confirmed + 1
    ALifeHealth.note("[ALifeTalk][Death]", (src == "event" and "death" or "off-screen death") .. " confirmed: " .. tostring(name) .. " (" .. uid .. ") - " .. tostring(src)
        .. (#twins > 0 and (" - merged " .. #twins .. " older row(s) of the same person") or ""))
    return true
end

-- on-screen deaths go through here too (after the death gate): one row, late ties, twins folded in
function M.offDeathOnEvent(body, uid, killer)
    if uid == nil or M.settings.offDeath == false then return end
    pcall(M.confirmDeath, uid, "event", { noGrief = true })
end

----------------------------------------------------------------------------------------------------------------
-- the scan (every 15 s a list of book uids; at most 25 checked per tick)
----------------------------------------------------------------------------------------------------------------
local function warDeadSeeds()
    local out = {}
    pcall(function()
        local wd = PA() and PA().WarDead
        local data = wd and fn(wd, "data") and wd.data() or nil
        if type(data) ~= "table" then pcall(function() data = ModData.getOrCreate("ProjectALife.WarDead") end) end
        for _, d in ipairs(type(data) == "table" and type(data.pending) == "table" and data.pending or {}) do
            if type(d) == "table" and d.identitySeed ~= nil then out[tostring(d.identitySeed)] = d end
        end
    end)
    return out
end
local function patchSeedUids(seeds)
    local out = {}
    pcall(function()
        local P = patch()
        local pd = P and fn(P, "store") and P.store() or nil
        for seed, s in pairs(type(pd) == "table" and type(pd.seeds) == "table" and pd.seeds or {}) do
            if type(s) == "table" and s.uid ~= nil and seeds[tostring(seed)] ~= nil then out[tostring(s.uid)] = seeds[tostring(seed)] end
        end
    end)
    return out
end
local function expeditionDeath(uid)
    local hit = false
    pcall(function()
        -- A-Life keeps expeditions (scavenging runs) in the squad ledger: missions[id].deaths[uid] = true
        local L = PA() and PA().SquadLedger
        local data = L and fn(L, "expeditionData") and L.expeditionData() or nil
        if type(data) ~= "table" then
            local ex = PA() and PA().OutpostExpeditions
            data = ex and fn(ex, "data") and ex.data() or nil
        end
        for _, m in pairs(type(data) == "table" and type(data.missions) == "table" and data.missions or {}) do
            if type(m) == "table" and type(m.deaths) == "table" and m.deaths[uid] then hit = true end
        end
    end)
    return hit
end

-- returns src, info when this book row's person is dead (nil = alive or can't tell)
function M.offDeathCheck(uid, e, ctx)
    uid = tostring(uid)
    local r = peek(uid)
    if type(r) == "table" then
        if r.lifecycle == "dead" then
            -- the event normally comes with it; wait a little before confirming it ourselves
            if M.deathRecent and M.deathRecent(uid) then return "event", {} end
            M.odFirst = M.odFirst or {}
            local t = M.odFirst[uid]
            if t == nil then M.odFirst[uid] = ctx.now; return nil end
            if ctx.now - t >= M.odCfg.eventWaitMs then return "record", {} end
            return nil
        end
        return nil -- active / spawning / dormant: alive (dormant people are frozen, not dead)
    end
    if M.isFinalDead and M.isFinalDead(uid) then return "final", {} end
    local c = M.canonUid(uid)
    if c ~= uid and M.isPersonDead(c) then
        local dc = M.deathOf(c)
        return "moved", { how = dc and dc.how or nil, h = dc and dc.h or nil, of = c }
    end
    local seed = e.seed and tostring(e.seed) or nil
    local wd = (seed and ctx.war[seed]) or ctx.warUid[uid]
    if wd ~= nil then return "offline_fight", { h = tonumber(wd.hours), x = wd.x, y = wd.y } end
    local sq = e.squad or e.grp
    if sq ~= nil and string.find(tostring(sq), "squad:", 1, true) == 1 then
        local L = PA() and PA().SquadLedger
        local q = L and fn(L, "peek") and L.peek(sq) or nil
        if type(q) == "table" and q.state == "wiped" then return "squad_wiped", { h = tonumber(q.wipedHours) } end
    end
    if expeditionDeath(uid) then return "expedition", {} end
    -- the same person (same name and group) is dead under another uid
    if M.settings.deathMerge ~= false and ctx.deadNames[lowName(e.real or e.name)] ~= nil then
        local other = ctx.deadNames[lowName(e.real or e.name)]
        local oe = bucket("book")[other]
        if other ~= uid and sameFac(type(oe) == "table" and oe.fac or nil, e.fac) then
            local dc = M.deathOf(other)
            return "twin", { how = dc and dc.how or (type(oe) == "table" and oe.diedWhy) or nil, of = other }
        end
    end
    return nil
end

-- 0.5.2.6 [pt254u]: the news reaches everyone close to them. A partner / family member / best friend who wasn't
-- there ("died - they don't know yet") hears it within the hour (word travels through the group / radio); the
-- "doesn't know yet" key memory becomes "Learned X died (word reached you)". Others still learn it by being told.
function M.newsReach(now)
    if M.settings.offDeath == false then return 0 end
    local h = hours()
    local closeW = (M.griefCfg and M.griefCfg.closeW) or 0.6
    local n = 0
    for mourner, g in pairs(bucket("grief")) do
        if type(g) == "table" then
            for deadUid, e in pairs(g) do
                if n < M.odCfg.newsPerScan and type(e) == "table" and not e.known and (tonumber(e.w) or 0) >= closeW
                        and h - (tonumber(e.at) or h) >= M.odCfg.newsDelayH and M.isPersonDead(deadUid) then
                    n = n + 1
                    e.known, e.src, e.learnedMs, e.learnedH, e.reacted = true, "word reached you", now, h, false
                    local fixed = false
                    for _, km in ipairs(M.keyMemOf and M.keyMemOf(mourner) or {}) do
                        if type(km) == "table" and string.find(tostring(km.t), tostring(e.n), 1, true)
                                and string.find(tostring(km.t), "don't know yet", 1, true) then
                            km.t = "Learned " .. tostring(e.n) .. " died (word reached you)"; fixed = true
                        end
                    end
                    if not fixed and M.keyMem then pcall(M.keyMem, mourner, "death", "Learned " .. tostring(e.n) .. " died (word reached you)") end
                    if M.histAdd then pcall(M.histAdd, mourner, "death", "Learned " .. tostring(e.n) .. " died") end
                    log("grief news: " .. tostring(mourner) .. " learned about " .. tostring(e.n) .. " (word reached them)")
                end
            end
        end
    end
    M.odStats.news = (M.odStats.news or 0) + n
    return n
end

M.odQueue, M.odNextAt, M.odCtx = {}, 0, nil
function M.offDeathTick(now)
    if M.settings.offDeath == false then return end
    now = now or nowMs()
    if #M.odQueue == 0 then
        if now < M.odNextAt then return end
        M.odNextAt = now + M.odCfg.scanMs
        pcall(M.newsReach, now)
        local q, deadNames = {}, {}
        for uid, e in pairs(bucket("book")) do
            if type(e) == "table" then
                if e.dead then
                    local nm = lowName(e.real or e.name)
                    if nm ~= "" and nm ~= "someone" then deadNames[nm] = tostring(uid) end
                elseif e.mergedInto == nil then q[#q + 1] = tostring(uid) end
            end
        end
        if #q == 0 then return end
        local war = warDeadSeeds()
        M.odCtx = { war = war, warUid = patchSeedUids(war), deadNames = deadNames, now = now }
        M.odQueue = q
        M.odStats.scans = M.odStats.scans + 1
    end
    local ctx = M.odCtx or { war = {}, warUid = {}, deadNames = {}, now = now }
    ctx.now = now
    local n = 0
    while #M.odQueue > 0 and n < M.odCfg.perTick do
        local uid = table.remove(M.odQueue)
        n = n + 1
        local e = bucket("book")[uid]
        if type(e) == "table" and not e.dead and M.deathOf(uid) == nil then
            local ok, src, info = pcall(M.offDeathCheck, uid, e, ctx)
            if ok and src ~= nil and src ~= "event" then M.confirmDeath(uid, src, info) end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the Relationships list: one row per person
----------------------------------------------------------------------------------------------------------------
function M.mergeDupRows(out)
    if M.settings.deathMerge == false or type(out) ~= "table" then return out end
    local b = bucket("book")
    local byUid, byName = {}, {}
    for _, n in ipairs(out) do byUid[n.uid] = n end
    for _, n in ipairs(out) do
        local nm = lowName((type(b[n.uid]) == "table" and (b[n.uid].real or b[n.uid].name)) or n.name)
        if nm ~= "" and nm ~= "someone" and nm ~= "stranger" then
            byName[nm] = byName[nm] or {}
            local l = byName[nm]
            l[#l + 1] = n
        end
    end
    local drop = {}
    for _, n in ipairs(out) do
        local c = M.canonUid(n.uid)
        if c ~= n.uid and byUid[c] ~= nil then drop[n.uid] = c end
    end
    for _, list in pairs(byName) do
        if #list > 1 then
            -- keep the real record (dead first), fold in rows A-Life has no record for
            local keep = nil
            for _, n in ipairs(list) do if not n.ghost and n.dead then keep = n end end
            if keep == nil then for _, n in ipairs(list) do if not n.ghost then keep = keep or n end end end
            if keep == nil then for _, n in ipairs(list) do if n.dead then keep = keep or n end end end
            if keep ~= nil then
                local kf = (type(keep.record) == "table" and keep.record.factionId) or (type(b[keep.uid]) == "table" and b[keep.uid].fac) or nil
                for _, n in ipairs(list) do
                    local nf = type(b[n.uid]) == "table" and b[n.uid].fac or nil
                    if n ~= keep and n.ghost and sameFac(nf, kf) then drop[n.uid] = keep.uid end
                end
            end
        end
    end
    local res = {}
    for _, n in ipairs(out) do
        local into = drop[n.uid]
        if into ~= nil then
            local e = b[n.uid]
            local k = byUid[into]
            if type(e) == "table" then
                if e.mergedInto == nil and e.movedTo == nil then e.mergedInto = into end
                if k and k.dead and not e.dead then e.dead = true; e.diedH = e.diedH or hours() end
            end
            if k and n.value ~= nil and (k.value == nil or (k.dead and k.value == 0)) then k.value = n.value end
            M.odStats.merged = M.odStats.merged + 1
            if M.keepLog then pcall(M.keepLog, "list: " .. tostring(n.name) .. " (" .. tostring(n.uid) .. ") is the same person as " .. tostring(into) .. " - one row", "merge|" .. tostring(n.uid), 1e12) end
        else
            res[#res + 1] = n
        end
    end
    return res
end

----------------------------------------------------------------------------------------------------------------
-- telling an NPC: "jorge is dead" to someone who had no grief entry
----------------------------------------------------------------------------------------------------------------
local function deadPeople()
    local out, seen = {}, {}
    for uid, d in pairs(bucket("deaths")) do
        if type(d) == "table" and d.of == nil and not seen[lowName(d.n)] then seen[lowName(d.n)] = true; out[#out + 1] = { uid = tostring(uid), n = d.n, how = d.how, h = d.h } end
    end
    for uid, e in pairs(bucket("book")) do
        if type(e) == "table" and e.dead and e.mergedInto == nil and not seen[lowName(e.name)] then
            seen[lowName(e.name)] = true
            out[#out + 1] = { uid = tostring(uid), n = e.name, how = e.diedWhy, h = e.diedH }
        end
    end
    return out
end
function M.learnUnlisted(mournerUid, low, src, onlyRelated)
    mournerUid = tostring(mournerUid)
    local mr = peek(mournerUid)
    if type(mr) ~= "table" or mr.lifecycle ~= "active" then return nil end
    local learned = nil
    for _, d in ipairs(deadPeople()) do
        local first = string.match(tostring(d.n), "^(%S+)")
        if d.uid ~= mournerUid and first and #first > 2 and string.find(low, string.lower(first), 1, true)
                and not (M.griefHasName and M.griefHasName(mournerUid, d.n)) then
            local w, t = 0, "stranger"
            local ids = { d.uid }
            for _, k in ipairs(M.twinsOf(d.uid)) do ids[#ids + 1] = k end
            for _, k in ipairs(ids) do
                local w2, t2 = M.closeness(mournerUid, k)
                if w2 > w then w, t = w2, t2 end
            end
            local e = bucket("book")[d.uid]
            local vm = peek(d.uid)
            local related = w > 0.05 or (e and e.fac ~= nil and tostring(e.fac) == tostring(mr.factionId))
                or (vm and vm.factionId ~= nil and tostring(vm.factionId) == tostring(mr.factionId))
            if related or not onlyRelated then
                local h = hours()
                local ww = math.max(w, related and M.odCfg.toldLightW or M.odCfg.toldStrangerW)
                M.griefOf(mournerUid)[d.uid] = { n = d.n, t = (t ~= "stranger" and t) or (related and "comrade" or "acquaintance"), w = ww,
                    at = tonumber(d.h) or h, saw = false, known = true, src = src, kn = d.how or "died", learnedMs = nowMs(), learnedH = h,
                    reacted = false, told = true }
                if M.keyMem then pcall(M.keyMem, mournerUid, "death", "Learned " .. tostring(d.n) .. " died (" .. tostring(src) .. ")") end
                if M.histAdd then pcall(M.histAdd, mournerUid, "death", "Learned " .. tostring(d.n) .. " died") end
                M.odStats.told = M.odStats.told + 1
                log("grief news: " .. mournerUid .. " learned about " .. tostring(d.n) .. " (" .. tostring(src) .. ", no earlier entry)")
                learned = M.griefOf(mournerUid)[d.uid]
            end
        end
    end
    return learned
end

----------------------------------------------------------------------------------------------------------------
-- prompt: the dead they know about (the bridge never cuts this block)
----------------------------------------------------------------------------------------------------------------
function M.deadFactsFor(uid)
    if uid == nil or M.settings.deathFacts == false then return nil end
    uid = tostring(uid)
    local out, seen = {}, {}
    local now = nowMs()
    for deadUid, e in pairs(M.griefOf and M.griefOf(uid) or {}) do
        if type(e) == "table" and e.known and not seen[lowName(e.n)] then
            seen[lowName(e.n)] = true
            local t = tostring(e.t or "comrade")
            local word = (CLOSE[t] and "late " or "") .. ((M.typeWords and M.typeWords[t]) or t)
            local d = M.deathOf(deadUid)
            local how = (d and d.how) or (e.kn and e.kn ~= "?" and ((e.kn == "something unseen") and "died" or ("killed by " .. tostring(e.kn)))) or "died"
            if e.kn == "player" then how = "killed by the newcomer" elseif e.kn == "zombies" or e.kn == "zombie" then how = "killed by zombies" end
            if d and d.how and d.src ~= "event" then how = d.how end
            local fresh = e.learnedMs ~= nil and now - e.learnedMs < 120000
            out[#out + 1] = { e.n, word, how, dayOf(e.at), fresh and 1 or 0, tonumber(e.w) or 0 }
        end
    end
    table.sort(out, function(a, b) if a[5] ~= b[5] then return a[5] > b[5] end return a[6] > b[6] end)
    while #out > M.odCfg.factsMax do table.remove(out) end
    for _, x in ipairs(out) do table.remove(x, 6) end
    return #out > 0 and out or nil
end

if type(Events) == "table" then
    if Events.OnTick then ALifeHealth.tickAdd("ALifeLLMTalk_OffDeath", function() pcall(M.offDeathTick) end) end
    if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_OffDeath", function(body, uid, killer) pcall(M.offDeathOnEvent, body, uid, killer) end)
    end
end

return M
