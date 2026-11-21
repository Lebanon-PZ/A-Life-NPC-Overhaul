-- A-Life NPC Overhaul 0.7.7: HELICOPTERS, JUGGERNAUTS AND THE LOUISVILLE NATIONAL GUARD (hook in, never replace).
--   * THE GUARD FLIES: the Louisville National Guard (the faction at the airport) has a real fleet: two Hueys. A
--     supply flight you call on the restricted channel is a real A-Life helicopter, flown by Guard people in their own
--     colours, circling over your drop point while the crates go up and down. Most of the routine helicopters seen
--     near Louisville are theirs too. Every helicopter of theirs that's shot down is gone: two lost, no more flights.
--   * AIR POWER COUNTS: a group's strength (what decides off-screen fights, tribute, who rules) counts its helicopters.
--   * A HELICOPTER DOWN: news on the radio, the spot gets a name ("Rotor Hill"), and the groups around race you to the
--     crash crate: leave it lying too long and the nearest group that wants it gets there first (what's in it goes into
--     their real stash; nothing is made).
--   * JUGGERNAUTS: dropping one is talked about. Everyone who saw it remembers, people who know you fear you a little
--     more, it's on the radio, and it's counted for the hidden achievements to come.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "skyPower" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeSkyPower") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeSkyPower = ALifeSkyPower or {}
local L = ALifeSkyPower
local TAG = "[ALifeSkyPower]"
L.VERSION = ALifeSide.MOD_VERSION
L.cfg = {
    fleetStart = 2,          -- Hueys the Guard has
    patrolTiles = 1500,      -- routine helicopters near the airport (this far from it) are the Guard's...
    patrolShare = 0.7,       -- ...this often
    heliPower = 0.15,        -- +15% strength per helicopter
    lostRep = -20,           -- you shot down one of theirs
    raceMinH = 2, raceTilesPerH = 900, raceReach = 2500, raceKeep = 12, raceNearTiles = 30,
    witnessTiles = 25, juggFear = 3,
}
L.CRASH_NAMES = { "Rotor Hill", "Chopper Down", "Broken Blade Field", "Black Smoke Lot", "Huey's Rest", "Tail Rotor Bend" }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { supplyHelis = 0, patrols = 0, crashes = 0, guardLost = 0, raced = 0, juggernauts = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.skyPower == false)
end
function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end
local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__SkyPower"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__SkyPower"] = orig
    L.hooked[hookName] = true
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the Guard and its fleet
----------------------------------------------------------------------------------------------------------------
function L.guardStore()
    local m = M()
    if not fn(m, "apStore") then return nil end
    local ok, s = pcall(m.apStore)
    if not ok or type(s) ~= "table" then return nil end
    if s.helis == nil then s.helis = L.cfg.fleetStart end
    return s
end
function L.guardActive()
    local s = L.guardStore()
    return s ~= nil and s.state == "active" and s.factionId ~= nil, s
end
function L.guardBase()
    local m = M()
    return fn(m, "apBase") and m.apBase() or nil
end
function L.fleet() local s = L.guardStore(); return s and tonumber(s.helis) or 0 end

-- a real A-Life helicopter over the player, flown by the Guard
function L.launchGuard(player, kind)
    local on, s = L.guardActive()
    local arrival = PA() and PA().HeliArrival
    if not on or L.fleet() <= 0 or player == nil or not fn(arrival, "launch") then return false, "unavailable" end
    local ok, why = arrival.launch(player, kind or "orbit", nil, false, s.factionId)
    return ok == true, why
end

-- the supply flight: the helicopter comes for real when the crates change hands
function L.hookTrade(m)
    return wrap(m, "alTrade", "alTrade", function(orig)
        return function(box, ...)
            if L.enabled() then
                local ok, launched, why = L.guard("alTrade", L.launchGuard, playerOf(), "orbit")
                if ok and launched then L.metrics.supplyHelis = L.metrics.supplyHelis + 1; log("supply flight: a Guard helicopter is over your drop point")
                elseif ok then log("supply flight without a helicopter body (" .. tostring(why) .. ")") end
            end
            return orig(box, ...)
        end
    end)
end

-- no helicopters left: no flights
function L.hookCallFlight(m)
    return wrap(m, "alCallFlight", "alCallFlight", function(orig)
        return function(player, ...)
            if L.enabled() and L.guardActive() and L.fleet() <= 0 then
                if fn(m, "radioLine") then pcall(m.radioLine, nil, "[Radio] " .. tostring(m.apName or "Louisville National Guard") .. ": Negative. We've got nothing left that flies.") end
                return false
            end
            return orig(player, ...)
        end
    end)
end

-- routine helicopters near the airport are the Guard's
function L.patrolFaction()
    local on, s = L.guardActive()
    if not on or L.fleet() <= 0 then return nil end
    local b = L.guardBase()
    local p = playerOf()
    if b == nil or p == nil then return nil end
    local px, py = nil, nil
    pcall(function() px, py = p:getX(), p:getY() end)
    if px == nil or d2(px, py, b.x, b.y) > L.cfg.patrolTiles * L.cfg.patrolTiles then return nil end
    return s.factionId
end
function L.hookCrewFaction(HC)
    return wrap(HC, "crewFaction", "crewFaction", function(orig)
        return function(variant, roll, ...)
            local fid = orig(variant, roll, ...)
            if fid == nil or not L.enabled() or (tonumber(roll) or 1) >= L.cfg.patrolShare then return fid end
            local ok, guardFid = L.guard("crewFaction", L.patrolFaction)
            if ok and guardFid ~= nil then L.metrics.patrols = L.metrics.patrols + 1; return guardFid end
            return fid
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- air power in a group's strength
----------------------------------------------------------------------------------------------------------------
function L.hookStrength(m)
    return wrap(m, "nbStrength", "nbStrength", function(orig)
        return function(b, ...)
            local v = orig(b, ...)
            if not L.enabled() or type(b) ~= "table" or not b.airport or not tonumber(v) then return v end
            return v * (1 + L.cfg.heliPower * math.max(0, L.fleet()))
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- a helicopter down
----------------------------------------------------------------------------------------------------------------
local function wrecks()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "heliWrecks")
    if not ok or type(b) ~= "table" then return nil end
    b.list = type(b.list) == "table" and b.list or {}
    return b
end

function L.onCrash(flight)
    local combat = type(flight.combat) == "table" and flight.combat or {}
    local x, y = tonumber(flight.x), tonumber(flight.y)
    if x == nil then return end
    L.metrics.crashes = L.metrics.crashes + 1
    local m = M()
    local shotByYou = false
    if type(flight.shooters) == "table" then for _ in pairs(flight.shooters) do shotByYou = true; break end end -- 0.7.11.1: no next() in Kahlua
    local on, s = L.guardActive()
    local guards = on and combat.factionId ~= nil and combat.factionId == s.factionId
    -- the Guard loses one for good
    if guards then
        s.helis = math.max(0, (tonumber(s.helis) or 0) - 1)
        L.metrics.guardLost = L.metrics.guardLost + 1
        local b = L.guardBase()
        if b and fn(m, "nbEvent") then pcall(m.nbEvent, b, "Lost a helicopter" .. (shotByYou and " to your guns" or "") .. " (" .. s.helis .. " left)", "war") end
        if shotByYou then s.rep = (tonumber(s.rep) or 0) + L.cfg.lostRep end
        log("the Guard lost a helicopter (" .. s.helis .. " left)" .. (shotByYou and ", shot down by you" or ""))
    end
    -- news, and a name for the spot
    if fn(m, "newsNote") then
        pcall(m.newsNote, "helicopter", (guards and "A National Guard helicopter" or "A helicopter") .. " came down in flames" .. (shotByYou and ", shot out of the sky" or ""), x, y)
    end
    local F = ALifeFuelRoads
    if fn(F, "namePlace") then pcall(F.namePlace, x, y, "a helicopter came down there", "heli:" .. tostring(flight.id), nil, L.CRASH_NAMES) end
    -- the race to the crate starts now
    local w = wrecks()
    if w then
        w.list[#w.list + 1] = { id = tostring(flight.id), x = math.floor(x), y = math.floor(y), h = hours() }
        while #w.list > L.cfg.raceKeep do table.remove(w.list, 1) end
    end
end

function L.hookImpact(D)
    return wrap(D, "impact", "impact", function(orig)
        return function(flight, now, ...)
            local done = orig(flight, now, ...)
            if done == true and L.enabled() and type(flight) == "table" then L.guard("impact", L.onCrash, flight) end
            return done
        end
    end)
end

-- the nearest group that would go for it, and when they'd get there
function L.racer(w)
    local m = M()
    if not fn(m, "nbActive") then return nil end
    local best, bestH = nil, math.huge
    for _, b in ipairs(m.nbActive() or {}) do
        if type(b) == "table" and b.status == "active" and not b.road and (tonumber(b.crewN) or 0) >= 2 then
            local dd = d2(b.x, b.y, w.x, w.y)
            if dd <= L.cfg.raceReach * L.cfg.raceReach then
                local th = math.sqrt(dd) / L.cfg.raceTilesPerH
                if fn(m, "travelH") then pcall(function() th = m.travelH(b.x, b.y, w.x, w.y, b) end) end
                th = math.max(L.cfg.raceMinH, tonumber(th) or th)
                if th < bestH then best, bestH = b, th end
            end
        end
    end
    return best, bestH
end
-- the crash crate (A-Life marks it), near the wreck
local function crateAt(w)
    local found = nil
    pcall(function()
        local cell = getCell()
        for dx = -8, 8 do
            for dy = -8, 8 do
                local sq = cell:getGridSquare(w.x + dx, w.y + dy, 0)
                if sq ~= nil then
                    local objs = sq:getSpecialObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        local md = o:getModData()
                        if md and md.ProjectALifeHeliCrate == w.id then found = o end
                    end
                end
            end
        end
    end)
    return found
end
function L.raceStep()
    local w = wrecks()
    if w == nil or #w.list == 0 then return 0 end
    local h = hours()
    local p = playerOf()
    local px, py = nil, nil
    pcall(function() px, py = p:getX(), p:getY() end)
    local m = M()
    local n = 0
    for i = #w.list, 1, -1 do
        local wr = w.list[i]
        local near = px ~= nil and d2(px, py, wr.x, wr.y) <= L.cfg.raceNearTiles * L.cfg.raceNearTiles
        if not near then
            if wr.by == nil then
                local b, th = L.racer(wr)
                if b ~= nil and h - wr.h >= th then wr.by, wr.byName = b.id, b.name end
            end
            if wr.by ~= nil then
                local crate = crateAt(wr)
                local b = fn(m, "nbOf") and m.nbOf(wr.by) or nil
                if crate ~= nil and b ~= nil then
                    local list = (fn(m, "nbHavenOf") and fn(m, "nbStashList")) and m.nbStashList(m.nbHavenOf(b), true) or nil
                    local got = 0
                    pcall(function()
                        local c = crate:getContainer()
                        local items = c:getItems()
                        for k = items:size() - 1, 0, -1 do
                            local it = items:get(k)
                            if list then list[#list + 1] = { type = it:getFullType() } end
                            c:DoRemoveItem(it)
                            got = got + 1
                        end
                    end)
                    if fn(m, "nbEvent") then pcall(m.nbEvent, b, "Got to a helicopter wreck first and hauled off " .. got .. " things", "loot") end
                    log(tostring(b.name) .. " got to the wreck first (" .. got .. " things)")
                    table.remove(w.list, i)
                    L.metrics.raced = L.metrics.raced + 1
                    n = n + 1
                elseif h - wr.h > 72 then
                    table.remove(w.list, i) -- nothing to find any more (crate never placed, or long gone)
                end
            end
        end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- Juggernauts
----------------------------------------------------------------------------------------------------------------
function L.onDead(z)
    local J = PA() and PA().Juggernaut
    if not fn(J, "heavyBody") or not J.heavyBody(z) then return end
    local killer = nil
    pcall(function() killer = z:getAttackedBy() end)
    if killer == nil or not instanceof(killer, "IsoPlayer") then return end
    L.metrics.juggernauts = L.metrics.juggernauts + 1
    local m, B = M(), ALifeBonds
    local x, y = nil, nil
    pcall(function() x, y = z:getX(), z:getY() end)
    local name = "the newcomer"
    pcall(function() local n = killer:getDescriptor():getForename(); if n and n ~= "" then name = n end end)
    local key = fn(B, "keyOf") and B.keyOf(killer) or nil
    local wd = PA() and PA().Watchdog
    local seen = 0
    if wd and type(wd.bindings) == "table" and x ~= nil then
        for uid, bind in pairs(wd.bindings) do
            local sx, sy, dead = nil, nil, false
            pcall(function() sx, sy = bind.shell:getX(), bind.shell:getY(); dead = bind.shell:isDead() end)
            if sx ~= nil and not dead and bind.shell ~= z and d2(sx, sy, x, y) <= L.cfg.witnessTiles * L.cfg.witnessTiles then
                if fn(m, "keyMem") then pcall(m.keyMem, tostring(uid), "saw_juggernaut", "Saw " .. name .. " bring down a Juggernaut") end
                if key and fn(B, "row") and B.row(key, tostring(uid), false) ~= nil then pcall(B.change, key, tostring(uid), 0, L.cfg.juggFear, 0, { player = killer }) end
                seen = seen + 1
            end
        end
    end
    if fn(m, "newsNote") then pcall(m.newsNote, "fight", "Somebody brought down one of those armored raiders, the walking tanks", x, y) end
    if fn(m, "bucket") then
        local ok, b = pcall(m.bucket, "feats")
        if ok and type(b) == "table" and key then
            b[key] = type(b[key]) == "table" and b[key] or {}
            b[key].juggernauts = (tonumber(b[key].juggernauts) or 0) + 1
        end
    end
    log("a Juggernaut fell to " .. name .. " (" .. seen .. " saw it)")
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
-- saves from before 0.7.7: the faction gets its name
function L.migrateName()
    local m = M()
    local b = L.guardBase()
    local name = type(m) == "table" and m.apName or nil
    if b == nil or name == nil then return end
    if b.name == "the airport" then b.name = name; log("the airport faction is now called " .. name) end
    local ledger = PA() and PA().SquadLedger
    local s = L.guardStore()
    if s and type(s.squads) == "table" and fn(ledger, "peek") and fn(ledger, "update") then
        for _, id in ipairs(s.squads) do
            local sid = type(id) == "table" and id.id or id
            local q = ledger.peek(sid)
            if q and type(q.name) == "string" and string.sub(q.name, 1, 8) == "Airport " then
                pcall(ledger.update, q.id, q.revision, function(r) r.name = name .. " " .. string.sub(r.name, 9) end)
            end
        end
    end
end

L.HOOKS = { "alTrade", "alCallFlight", "crewFaction", "nbStrength", "impact" }
function L.install()
    local m, pa = M(), PA()
    if type(m) == "table" and type(m.settings) == "table" and m.settings.skyPower == nil then m.settings.skyPower = true end
    if type(m) == "table" then L.hookTrade(m); L.hookCallFlight(m); L.hookStrength(m) end
    if pa ~= nil then
        if type(pa.HeliCombat) == "table" then L.hookCrewFaction(pa.HeliCombat) end
        if type(pa.HeliDamage) == "table" then L.hookImpact(pa.HeliDamage) end
    end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end
L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        L.guard("migrate", L.migrateName)
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or "")
            .. " (Guard fleet: " .. L.fleet() .. ")")
        return true
    end
    return false
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = 0
                pcall(function() now = getTimestampMs() end)
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryHours ~= nil then Events.EveryHours.Add(function() if L.enabled() then L.guard("race", L.raceStep) end end) end
    if Events.OnZombieDead ~= nil then Events.OnZombieDead.Add(function(z) if L.enabled() then L.guard("juggernaut", L.onDead, z) end end) end
end
print(TAG .. " loaded v" .. L.VERSION)
