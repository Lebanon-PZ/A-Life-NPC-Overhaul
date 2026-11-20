-- A-Life Talk 0.5.1.6: REAL DEATHS ARE FINAL.
-- Why: an old leftover file in the A-Life Talk folder (ALifeTalk_RespawnGuard.lua - not part of A-Life Talk, not
-- part of A-Life) turned every dead NPC's record back to "dormant" and asked A-Life to spawn them again at the body
-- ("talkrespawn:" spawns): the same person died and came back over and over. Its sister files
-- (ALifeTalk_PermanentNPCs.lua, ALifeTalk_DormantGuard.lua) also undid deaths / swallowed every dormant death.
-- This file (loads BEFORE those files, the folder is loaded alphabetically):
--   * switches their death hooks off (sets the "already installed" flags they check) and keeps their copies of
--     dead people from reviving them
--   * keeps a saved "final deaths" list (ModData "ALifeTalkFinalDeaths", the same list A-Life Talk Patch 1.4.2 keeps);
--     without the patch it also refuses A-Life respawns of a final uid and every "talkrespawn:" spawn
--   * one death = one death event for us: each of our death listeners runs once per person (no double grief,
--     last words or "killed by" lines when A-Life reports the same death twice)
--   * the people book marks them dead (memories kept)
-- Settings: deathFinal, deathDedupeMin, blockForeignRespawn (alifetalk_settings.txt).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Death") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Death"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Death") end end -- 0.5.1.6 perf label
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function nowMs() return M.nowMs() end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function patch() return M.patch and M.patch() or nil end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); local n = nil; pcall(function() n = pa.Names.of(r) end); return n or (type(r) == "table" and tostring(r.uid)) or "someone" end
local function dlog(msg) print("[ALifeTalk][Death] " .. tostring(msg)) end
M.deathLog = dlog
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    M.fileKeys = M.fileKeys or {}
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = key end
end
setting("deathFinal", true)
setting("deathDedupeMin", 10)
setting("blockForeignRespawn", true)
setting("perfLog", false)
setting("eventAddGuard", true)
setting("eventAddMax", 2)

M.FOREIGN_DEATH_FILES = { "ALifeTalk_RespawnGuard.lua", "ALifeTalk_PermanentNPCs.lua", "ALifeTalk_DormantGuard.lua", "ALifeTalkPatch.lua (a stale copy in the client folder)" }

-- 1) switch the leftover files' death hooks off before they load (they check these flags and then skip)
function M.blockForeignDeathHooks()
    if M.settings.blockForeignRespawn == false then return false end
    local pa = PA()
    local L = pa and pa.Lifecycle
    if type(L) ~= "table" then return false end
    L._respawnHooked = true
    L._permDeathHooked = true
    L._dormantGuardInstalled = true
    M.foreignBlocked = true
    return true
end
M.blockForeignDeathHooks()

-- 2) the final-deaths list (shared with the patch)
function M.finalStore()
    local P = patch()
    if P and fn(P, "finalStore") then return P.finalStore() end
    if M.fdData ~= nil then return M.fdData end
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeTalkFinalDeaths") end)
    if type(d) ~= "table" then d = M.fdFallback or {}; M.fdFallback = d else M.fdData = d end
    d.uids = type(d.uids) == "table" and d.uids or {}
    return d
end
function M.isFinalDead(uid)
    if uid == nil or M.settings.deathFinal == false then return false end
    local P = patch()
    if P and fn(P, "isFinalDead") then return P.isFinalDead(uid) end
    return M.finalStore().uids[tostring(uid)] ~= nil
end
-- leftover PermanentNPCs keeps living "copies" and revives them; drop the copy of someone who died for good
function M.dropForeignCopy(uid)
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeTalk_NPCCopies") end)
    if type(d) == "table" and type(d.npcs) == "table" and d.npcs[tostring(uid)] ~= nil then
        d.npcs[tostring(uid)] = nil
        M.foreignCopiesDropped = (M.foreignCopiesDropped or 0) + 1
        return true
    end
    return false
end
function M.markFinalDead(uid, why, r)
    if M.settings.deathFinal == false or uid == nil then return false end
    uid = tostring(uid)
    r = r or rec(uid)
    local P = patch()
    local done = false
    if P and fn(P, "markFinalDead") then done = P.markFinalDead(uid, why, r)
    else
        local d = M.finalStore()
        if d.uids[uid] == nil then
            d.uids[uid] = { h = hours(), why = tostring(why or "died"), name = nameOf(r) }
            dlog(nameOf(r) .. " (" .. uid .. ") died for good (" .. tostring(why or "died") .. ")")
            done = true
        end
    end
    M.dropForeignCopy(uid)
    -- our own "keep them" lists never hold the dead
    pcall(function() M.bucket("keepMarks")[uid] = nil end)
    if M.bookMarkDead then pcall(M.bookMarkDead, uid, r, why) end
    return done
end
-- people book: dead, memories kept
function M.bookMarkDead(uid, r, why)
    local b = M.bucket("book")
    local e = b[tostring(uid)]
    if type(e) ~= "table" then
        if M.bookSnap and type(r) == "table" then pcall(M.bookSnap, r); e = b[tostring(uid)] end
    end
    if type(e) == "table" then e.dead = true; e.diedH = e.diedH or hours(); e.diedWhy = e.diedWhy or tostring(why or "died") end
end

-- 3) without the patch: refuse respawns of the dead and "talkrespawn:" spawns (the patch does the same and more)
function M.installDeathFallback()
    if M.deathFallbackOn then return true end
    local P = patch()
    if P and type(P.installed) == "table" and P.installed.finalDeaths then return true end
    local pa = PA()
    local SS = pa and pa.SpawnService
    if not fn(SS, "request") then return false end
    local orig = SS.request
    SS.request = function(uid, op, ...)
        local o = tostring(op or "")
        if M.isFinalDead(uid) or (M.settings.blockForeignRespawn ~= false and string.sub(o, 1, 12) == "talkrespawn:") then
            local now = nowMs()
            M.refuseLogAt = M.refuseLogAt or {}
            if now - (M.refuseLogAt[tostring(uid)] or -1e12) >= 60000 then
                M.refuseLogAt[tostring(uid)] = now
                dlog("refused to respawn " .. nameOf(rec(uid)) .. " (" .. tostring(uid) .. "): " .. (M.isFinalDead(uid) and "died for good" or "respawn ordered by a leftover file") .. " (op " .. o .. ")")
            end
            return nil, "alifetalk_final_death"
        end
        return orig(uid, op, ...)
    end
    M.deathFallbackOn = true
    return true
end
-- something revived a final uid while it is not walking around -> back to dead (fallback for no patch)
function M.deathWatch()
    if M.settings.deathFinal == false then return end
    local P = patch()
    for uid in pairs(M.finalStore().uids) do
        M.dropForeignCopy(uid)
        if not (P and type(P.installed) == "table" and P.installed.finalDeaths) then
            local r = rec(uid)
            local pa = PA()
            if type(r) == "table" and r.lifecycle ~= "dead" and r.lifecycle ~= "active" and r.lifecycle ~= "spawning" and fn(pa.ActorRegistry, "update") then
                local okU, res = pcall(pa.ActorRegistry.update, uid, r.revision, function(x) x.lifecycle = "dead"; x.activity = "dead"; x.intent = "none" end)
                if okU and res ~= nil then dlog(nameOf(r) .. " (" .. uid .. ") was brought back by something else - put back to dead") end
            end
        end
    end
end

-- 4) one death = one event for each of our listeners
M.deathSeen = {}
function M.deathRecent(uid)
    local t = M.deathSeen[tostring(uid)]
    return t ~= nil and nowMs() - t < (tonumber(M.settings.deathDedupeMin) or 10) * 60000
end
M.deathDupes = 0
function M.deathGateWrap(f, label)
    local done = {}
    return function(body, uid, killer, ...)
        local u = tostring(uid)
        local now = nowMs()
        local win = (tonumber(M.settings.deathDedupeMin) or 10) * 60000
        if uid ~= nil and done[u] ~= nil and now - done[u] < win then
            M.deathDupes = M.deathDupes + 1
            if M.deathDupeLogged ~= u then
                M.deathDupeLogged = u
                dlog("ignored a second death report for " .. nameOf(rec(u)) .. " (" .. u .. ") - one death, one reaction")
            end
            return nil
        end
        if uid ~= nil then done[u] = now end
        return f(body, uid, killer, ...)
    end
end
function M.onNpcDiedFirst(body, uid, killer)
    if uid == nil then return end
    local u = tostring(uid)
    M.deathSeen[u] = nowMs()
    local r = rec(u)
    if type(r) == "table" and r.lifecycle == "dead" then M.markFinalDead(u, "killed", r)
    elseif M.bookMarkDead then pcall(M.bookMarkDead, u, r, "killed") end
end
function M.installDeathGate()
    if type(Events) ~= "table" or type(Events.ProjectALife_NpcDied) ~= "table" or M.deathGateOn then return false end
    local ev = Events.ProjectALife_NpcDied
    if type(ev.Add) ~= "function" then return false end
    local add = ev.Add
    M.deathGateOn = true
    -- our own first listener: final mark + book (runs before every other listener we add)
    add(M.deathGateWrap(function(body, uid, killer) pcall(M.onNpcDiedFirst, body, uid, killer) end, "first"))
    ev.Add = function(f, ...)
        if type(f) == "function" then return add(M.deathGateWrap(f), ...) end
        return add(f, ...)
    end
    return true
end
M.installDeathGate()

local nextAt = 0
function M.deathTick()
    local now = nowMs()
    if now < nextAt then return end
    nextAt = now + 5000
    M.blockForeignDeathHooks()
    pcall(M.installDeathFallback)
    pcall(M.deathWatch)
    if M.perfReport then pcall(M.perfReport, now) end
end
function M.deathOnStart()
    M.blockForeignDeathHooks()
    local found = {}
    if M._permWrapped then found[#found + 1] = "ALifeTalk_PermanentNPCs.lua" end
    pcall(function() local d = ModData.getOrCreate("ALifeTalk_NPCCopies"); if type(d) == "table" and type(d.npcs) == "table" and #found == 0 then for _ in pairs(d.npcs) do found[#found + 1] = "ALifeTalk_PermanentNPCs.lua (its saved copies)"; break end end end)
    dlog("final deaths on (" .. (function() local n = 0; for _ in pairs(M.finalStore().uids) do n = n + 1 end; return n end)()
        .. " people died for good). Old death files are switched off" .. (#found > 0 and (" - found " .. table.concat(found, ", ") .. "") or "")
        .. ". If you still have them, delete from mods/ALifeTalk/42/media/lua/client/ALifeLLMTalk/: " .. table.concat(M.FOREIGN_DEATH_FILES, ", "))
end
if type(Events) == "table" then
    if Events.OnTick then ALifeHealth.tickAdd("ALifeLLMTalk_Death", M.deathTick) end
    if Events.OnGameStart then Events.OnGameStart.Add(M.deathOnStart) end
end
