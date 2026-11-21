-- A-Life NPC Overhaul pre-1.0: GUN SENSE. Everyone alive by now knows a shot pulls in every dead thing for blocks.
-- A-Life 1.5.1 (server/ProjectALife/Combat/ALifeCombatFire.lua, Combat.preferredWeapon) puts the blade away and draws a
-- gun on the dead when it is "outnumbered" - its withdraw plan, or ModuleHordeRetreat.alarmed (a horde near, see
-- ALifeCombat.lua currentEngagementFacts: facts.outnumbered = ... or facts.horde). That is the worst time to shoot:
-- the whole town comes (andrer's County Sheriff, West Point). Here: on the dead, blades first; a gun only when
-- outnumbered AND cornered (G.emergency). The living: untouched - A-Life already goes gun-first on people (any loaded
-- or reloadable gun in the pack, and Combat.drawsOnHuman skips the swap wait), so a blade picked for the dead turns
-- into the gun the moment a person is the target.
-- Who (gunSenseWho): 1 = people walking with you (companions, job company), 2 = everyone. Never your A-Life party
-- (its order wheel "Weapons" rule decides, A-Life's Companions.preferredWeapon), never juggernauts (A-Life's gun-first
-- doctrine). Fights with the living are untouched. No blade in their pack: A-Life's choice stands (nothing made up).
-- Wraps Combat.preferredWeapon (chained over any earlier wrap, e.g. ALifeTalkPatch nemesis tiers). Server / SP.
-- Also holds followCatchUpWarp (read by ALifeTalkPatch.companionEvaluate): off = someone walking with you who falls
-- behind walks / runs to you; they never pop in beside you.
require "ALifeNPCOverhaul/AA_Side"
ALifeGunSense = ALifeGunSense or {}
local G = ALifeGunSense
local TAG = "[ALifeGunSense]"
G.VERSION = ALifeSide.MOD_VERSION
G.metrics = G.metrics or { checked = 0, held = 0, emergency = 0, noBlade = 0 }

G.DEFAULTS = {
    gunSense = true,          -- on the dead: blades first, guns only in an emergency
    gunSenseWho = 2,          -- 1 people walking with you, 2 everyone (never your A-Life party: its order wheel decides)
    gunSenseCrowdN = 6,       -- outnumbered: this many dead ... (or A-Life's own "outnumbered" / horde alarm)
    gunSenseCrowdTiles = 8,   -- ... within this many tiles
    gunSenseCloseN = 3,       -- cornered: this many dead ...
    gunSenseCloseTiles = 2,   -- ... this close (tiles), or one that close and:
    gunSenseExits = 2,        -- ... this many open squares around them or fewer (back to a wall), or
    gunSenseHurt = 40,        -- ... hurt to this much health (pct) or less (can't outrun them)
    followCatchUpWarp = false, -- someone walking with you who falls far behind pops in beside you (old way; off = they walk)
}
G.FILE_KEYS = {}
for k in pairs(G.DEFAULTS) do G.FILE_KEYS[#G.FILE_KEYS + 1] = k end
table.sort(G.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end

function G.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end
function G.n(key) return num(G.setting(key), num(G.DEFAULTS[key], 0)) end
function G.on() return G.setting("gunSense") ~= false end
function G.footWarp() return G.setting("followCatchUpWarp") == true end

G.adapters = G.adapters or {} -- tests: nowMs, deadNear(shell, closeT, crowdT) -> close, crowd; exits(shell) -> n
local function nowMs()
    if fn(G.adapters, "nowMs") then return G.adapters.nowMs() end
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return 0
end

local function uidOf(shell)
    local uid = nil
    pcall(function() local md = shell:getModData(); uid = md and md.ProjectALifeUID end)
    return uid
end
local function recordOf(actor, shell)
    if type(actor) == "table" then return actor end
    local uid = uidOf(shell)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    if uid == nil or type(reg) ~= "table" then return nil end
    local r = nil
    pcall(function() r = (reg.peek or reg.read)(tostring(uid)) end)
    return type(r) == "table" and r or nil
end

-- someone walking with a player: A-Life's walk-with (stance / memory.walkWith) or a patch companion
function G.walkingWithPlayer(rec)
    if type(rec) ~= "table" then return false end
    local m = type(rec.memory) == "table" and rec.memory or {}
    if m.stance == "walkWith" or type(m.walkWith) == "table" or m.walkWithPlayer ~= nil then return true end
    local P = ALifeTalkPatch
    if fn(P, "companionOf") then
        local ok, c = pcall(P.companionOf, rec.uid)
        if ok and c ~= nil then return true end
    end
    return false
end

function G.covers(actor, shell)
    local pa = PA()
    if pa == nil then return false end
    local C = pa.Companions
    if type(actor) == "table" and fn(C, "owns") then
        local ok, owned = pcall(C.owns, actor)
        if ok and owned then return false end -- your A-Life party: the order wheel's weapons rule
    end
    local D = pa.JuggernautDoctrine
    if fn(D, "gunFirst") then
        local ok, first = pcall(D.gunFirst, shell)
        if ok and first then return false end
    end
    if math.floor(G.n("gunSenseWho")) >= 2 then return true end
    return G.walkingWithPlayer(recordOf(actor, shell))
end

-- the dead around them (A-Life NPC bodies are zombie shells with a ProjectALifeUID: not counted). One pass over the
-- cell's zombie list (the same list A-Life's Companions.crowdNear reads), cached per shell for 500 ms.
G.deadCache = G.deadCache or {}
function G.deadNear(shell)
    local closeT, crowdT = G.n("gunSenseCloseTiles"), G.n("gunSenseCrowdTiles")
    if fn(G.adapters, "deadNear") then return G.adapters.deadNear(shell, closeT, crowdT) end
    local key = tostring(uidOf(shell) or shell)
    local now = nowMs()
    local c = G.deadCache[key]
    if c ~= nil and now < c.untilMs then return c.close, c.crowd end
    local close, crowd = 0, 0
    pcall(function()
        local sx, sy, sz = shell:getX(), shell:getY(), shell:getZ()
        local list = getCell():getZombieList()
        local c2, r2 = closeT * closeT, crowdT * crowdT
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            if z ~= shell and math.abs(z:getZ() - sz) < 0.5 and z:isDead() ~= true then
                local d = (z:getX() - sx) ^ 2 + (z:getY() - sy) ^ 2
                if d <= r2 then
                    local md = z:getModData()
                    if not (type(md) == "table" and md.ProjectALifeUID ~= nil) then
                        crowd = crowd + 1
                        if d <= c2 then close = close + 1 end
                    end
                end
            end
        end
    end)
    G.deadCache[key] = { close = close, crowd = crowd, untilMs = now + 500 }
    return close, crowd
end

-- open squares around them (free floor, none of the dead on it): few = back to a wall, no way out
function G.exits(shell)
    if fn(G.adapters, "exits") then return G.adapters.exits(shell) end
    local n = 0
    pcall(function()
        local cell = getCell()
        local sx, sy, sz = math.floor(shell:getX()), math.floor(shell:getY()), math.floor(shell:getZ())
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local sq = cell:getGridSquare(sx + dx, sy + dy, sz)
                    local open = false
                    if sq ~= nil then pcall(function() open = sq:isFree(false) == true end) end
                    if open then
                        local list = sq:getMovingObjects()
                        for i = 0, list:size() - 1 do
                            local o = list:get(i)
                            if instanceof(o, "IsoZombie") and o:isDead() ~= true then open = false end
                        end
                    end
                    if open then n = n + 1 end
                end
            end
        end
    end)
    return n
end

-- Joe: a gun on the dead = outnumbered AND cornered, never just outnumbered.
--   outnumbered: A-Life says so (withdraw plan / horde alarm: facts.outnumbered) or gunSenseCrowdN dead within
--                gunSenseCrowdTiles
--   cornered:    gunSenseCloseN dead within gunSenseCloseTiles (surrounded), or one of them that close and no way to
--                back off (gunSenseExits open squares or fewer around them, or hurt to gunSenseHurt pct: can't outrun)
function G.emergency(shell, facts)
    local close, crowd = G.deadNear(shell)
    local outnumbered = (type(facts) == "table" and facts.outnumbered == true) or crowd >= G.n("gunSenseCrowdN")
    if not outnumbered then return false, "not outnumbered" end
    if close >= G.n("gunSenseCloseN") then return true, "surrounded" end
    if close < 1 then return false, "not cornered" end
    if G.exits(shell) <= G.n("gunSenseExits") then return true, "back to the wall" end
    local pa = PA()
    local C = pa and pa.Companions
    if fn(C, "hpFraction") then
        local ok, f = pcall(C.hpFraction, shell)
        if ok and tonumber(f) and tonumber(f) * 100 <= G.n("gunSenseHurt") then return true, "hurt" end
    end
    return false, "not cornered"
end

-- returns weapon, handled. handled = true: use the returned weapon (nil = keep the blade in hand)
function G.decide(shell, weapon, target, facts, actor, wanted)
    if not G.on() or shell == nil then return nil, false end
    local pa = PA()
    local Cb, W = pa and pa.Combat, pa and pa.Weapons
    if not fn(Cb, "isRanged") or not fn(W, "bestMelee") then return nil, false end
    local kind = type(facts) == "table" and facts.targetKind or nil
    if kind == nil and fn(Cb, "kindOf") then pcall(function() kind = Cb.kindOf(target) end) end
    if kind ~= "zombie" then return nil, false end
    local final = wanted or weapon
    if final == nil or Cb.isRanged(final) ~= true then return nil, false end
    if not G.covers(actor, shell) then return nil, false end
    G.metrics.checked = G.metrics.checked + 1
    local hot, why = G.emergency(shell, facts)
    if hot then G.metrics.emergency = G.metrics.emergency + 1; return nil, false end
    local melee = nil
    pcall(function() melee = W.bestMelee(shell) end)
    if melee == nil then G.metrics.noBlade = G.metrics.noBlade + 1; return nil, false end
    G.metrics.held = G.metrics.held + 1
    if melee == weapon then return nil, true end
    return melee, true
end

function G.install()
    if G.installed then return true end
    local pa = PA()
    if pa == nil or not fn(pa.Combat, "preferredWeapon") then return false end
    G.installed = true
    local orig = pa.Combat.preferredWeapon
    G.orig = orig
    pa.Combat.preferredWeapon = function(shell, weapon, target, distance, facts, actor, ...)
        local wanted = orig(shell, weapon, target, distance, facts, actor, ...)
        local ok, w, handled = pcall(G.decide, shell, weapon, target, facts, actor, wanted)
        if ok and handled then return w end
        if not ok then log("decide error: " .. tostring(w)) end
        return wanted
    end
    log("ready v" .. G.VERSION .. ": " .. (G.on() and "on" or "off") .. ", who " .. tostring(math.floor(G.n("gunSenseWho")))
        .. " (guns on the dead only when outnumbered AND cornered; the living untouched), follower catch-up warp "
        .. (G.footWarp() and "on" or "off"))
    return true
end

function G.qaLine()
    local m = G.metrics
    return "[ALIFE-QA] GunSense: checked=" .. m.checked .. " held=" .. m.held .. " emergency=" .. m.emergency .. " noBlade=" .. m.noBlade
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() local ok, e = pcall(G.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(G.install) end) end
end

return G
