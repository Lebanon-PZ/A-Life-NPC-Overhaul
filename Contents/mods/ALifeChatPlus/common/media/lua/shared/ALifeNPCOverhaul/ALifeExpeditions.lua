-- A-Life NPC Overhaul 0.6.2: EXPEDITIONS, made honest.
-- Your residents already go on real scavenging trips through the Jeem Extension's missions (its faction window:
-- they walk out, become an off-screen A-Life squad, can be hurt or killed, and come back as the same people).
-- What they brought back was made up: supplies (at least 3 each), 0-10 rounds each, a 1-in-10 pistol each, and 2-4
-- items each from a fixed list. And the real things they carried (A-Life's scavenging, made honest in 0.6.0, takes
-- them out of real buildings) were thrown away when they were rebuilt from their snapshot.
-- Now (wrapping Jeem's Missions.returnHome / returnAbstract, the original always runs):
--  * a squad trip brings home exactly what its people carry: the items they took out of real buildings.
--  * a trip without a squad (A-Life's squad list was full) loots real buildings around the base, one per person who
--    came back, and those buildings become derelict (ALifeDerelict).
--  * no made-up supplies, rounds or guns. The haul goes into your stores the way Jeem delivers loot (by kind, into
--    the marked containers once they're loaded), and the faction window says what they brought.
-- Nothing per frame: runs only when a trip comes home. Off: setting honestScavenge (same switch as 0.6.0).
require "ALifeNPCOverhaul/AA_Side"
ALifeExpeditions = ALifeExpeditions or {}
local E = ALifeExpeditions
local TAG = "[ALifeExpeditions]"
local VERSION = ALifeSide.MOD_VERSION
E.cfg = { abstractRadii = { 40, 80, 130, 190, 260 }, abstractAngles = 12 }
E.stats = { trips = 0, carried = 0, abstract = 0, looted = 0, empty = 0 }
local function log(m) print(TAG .. " " .. tostring(m)) end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function on()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.honestScavenge == false)
end
local function missions()
    local J = ProjectALifeJimmy
    return type(J) == "table" and type(J.Residents) == "table" and type(J.Residents.missions) == "table" and J.Residents.missions or nil
end

-- what the squad's people carry (A-Life keeps it per member: shellState.carried); taken out of the squad
function E.carriedOf(q)
    local out = {}
    for _, member in ipairs(type(q) == "table" and type(q.members) == "table" and q.members or {}) do
        local st = type(member) == "table" and type(member.shellState) == "table" and member.shellState or nil
        local carried = st and type(st.carried) == "table" and st.carried or nil
        if carried then
            for i = #carried, 1, -1 do
                local e = carried[i]
                local t = type(e) == "table" and e.type or e
                if type(t) == "string" and t ~= "" then out[#out + 1] = t end
                table.remove(carried, i)
            end
        end
    end
    return out
end
-- a trip without a squad: real buildings around the base, one per person back
function E.abstractHaul(m, back)
    local D, Ms = ALifeDerelict, missions()
    if back <= 0 or not fn(D, "lootNear") or Ms == nil then return {} end
    local J = ProjectALifeJimmy
    local R = J and J.Residents
    local b = R and fn(R, "bounds") and R.bounds(m.baseId) or nil
    if b == nil then return {} end
    local types, got = D.lootNear((b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2, back, "player", E.cfg.abstractRadii, E.cfg.abstractAngles)
    E.stats.looted = E.stats.looted + got
    return types
end
-- drop the "scavenged 0 supplies, 0 rounds" part of the news line (there are none any more)
local function cleanLine(Ms, baseId)
    local ok = pcall(function()
        local line = Ms.data().recent[baseId]
        if type(line) ~= "table" then return end
        for i = #line, 1, -1 do
            local part = line[i]
            if type(part) == "table" and (part.k == "IGUI_ALJ_Missions_Scavenged" or part.k == "IGUI_ALJ_Missions_GunsSuffix") then table.remove(line, i) end
        end
    end)
    return ok
end

function E.returnHome(orig, m, q, hours)
    local Ms = missions()
    if not on() or type(m) ~= "table" or m.kind ~= "scavenge" or Ms == nil then return orig(m, q, hours) end
    E.stats.trips = E.stats.trips + 1
    local back = type(q) == "table" and type(q.members) == "table" and #q.members or 0
    local haul
    if m.alcpAbstract then
        haul = E.abstractHaul(m, back)
        E.stats.abstract = E.stats.abstract + 1
    else
        haul = E.carriedOf(q)
        E.stats.carried = E.stats.carried + #haul
    end
    if #haul == 0 then E.stats.empty = E.stats.empty + 1 end
    -- run Jeem's own return with every made-up reward at zero and the haul as its "loot"
    local saved = { rounds = Ms.roundsEach, gun = Ms.gunChanceEach, minSup = Ms.minSuppliesEach, roll = Ms.rollLoot }
    Ms.roundsEach, Ms.gunChanceEach, Ms.minSuppliesEach = { 0, 0 }, 0, 0
    Ms.rollLoot = function() return haul end
    if type(q) == "table" then q.supplies = tonumber(m.startSupplies) or 0 end
    local ok, res = pcall(orig, m, q, hours)
    Ms.roundsEach, Ms.gunChanceEach, Ms.minSuppliesEach, Ms.rollLoot = saved.rounds, saved.gun, saved.minSup, saved.roll
    if not ok then E.origFailed = true; error(res, 0) end -- Jeem's own failure: never run it a second time
    cleanLine(Ms, m.baseId)
    return res
end
function E.returnAbstract(orig, m, hours)
    local Ms = missions()
    if not on() or type(m) ~= "table" or m.kind ~= "scavenge" or Ms == nil then return orig(m, hours) end
    local savedEach = Ms.suppliesEach
    Ms.suppliesEach = { 0, 0 }
    m.alcpAbstract = true
    local ok, res = pcall(orig, m, hours)
    Ms.suppliesEach = savedEach
    m.alcpAbstract = nil
    if not ok then E.origFailed = true; error(res, 0) end -- Jeem's own failure: never run it a second time
    return res
end

-- wrap once, the original kept (a second copy of this file reuses it)
local function wrap(Ms, name, make)
    local marks = rawget(Ms, "_alcpHooks")
    if type(marks) ~= "table" then marks = {}; rawset(Ms, "_alcpHooks", marks) end
    local mark = marks[name]
    if type(mark) == "table" and Ms[name] == mark.wrapper then return true end
    local orig = (type(mark) == "table" and mark.orig) or Ms[name]
    if type(orig) ~= "function" then return false end
    local w = make(orig)
    Ms[name] = w
    marks[name] = { orig = orig, wrapper = w }
    return true
end
function E.install()
    if ALifeSide.client() then return end
    local Ms = missions()
    if Ms == nil then log("loaded v" .. VERSION .. " (Jeem missions not found: nothing to do)"); return end
    local a = wrap(Ms, "returnHome", function(orig)
        return function(m, q, hours)
            if E.dead then return orig(m, q, hours) end
            E.origFailed = false
            local ok, res = pcall(E.returnHome, orig, m, q, hours)
            if ok then return res end
            if E.origFailed then error(res, 0) end -- Jeem's return itself failed (and may have half-run): as without us
            E.dead = true
            log("trip return failed, Jeem's own return restored for this session: " .. tostring(res))
            return orig(m, q, hours)
        end
    end)
    local b = wrap(Ms, "returnAbstract", function(orig)
        return function(m, hours)
            if E.dead then return orig(m, hours) end
            E.origFailed = false
            local ok, res = pcall(E.returnAbstract, orig, m, hours)
            if ok then return res end
            if E.origFailed then error(res, 0) end -- Jeem's return itself failed (and may have half-run): as without us
            E.dead = true
            log("trip return failed, Jeem's own return restored for this session: " .. tostring(res))
            return orig(m, hours)
        end
    end)
    log("loaded v" .. VERSION .. " (Jeem scavenging trips " .. ((a and b) and "bring home what they really carry" or "NOT hooked") .. (on() and "" or "; switched off in settings") .. ")")
end
function E.perf()
    local s = E.stats
    return "trips " .. s.trips .. ", items carried home " .. s.carried .. ", trips without a squad " .. s.abstract .. " (buildings " .. s.looted .. "), empty-handed " .. s.empty
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() local ok, e = pcall(E.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(function() local ok, e = pcall(E.install); if not ok then log("install failed: " .. tostring(e)) end end) end
end
