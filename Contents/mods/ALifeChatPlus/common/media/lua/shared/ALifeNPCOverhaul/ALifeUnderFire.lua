-- A-Life NPC Overhaul 0.8.11: UNDER FIRE. Rounds cracking past you raise your panic. Vanilla does the rest:
-- CombatManager.getMoodlesPenalty (42.21 jar) takes panic moodle level x (4 + 0.5 x distance) off your gun hit
-- chance, stress moodle the same way, and ISReloadWeaponAction reloads slower with panic. We only add the fear.
-- Near miss = A-Life ModuleGunner.whizz(body, shooter, aim): A-Life calls it for its gunmen's missed rounds that
-- land within 1.5 tiles of you (ghost rounds / grazePlayer), heli door gunners, car gunners, snipers. We wrap it
-- (call the original, keep its result) and judge the near miss ourselves (A-Life's whizz skips when its sound
-- played recently; the round still went past).
-- Pinned: more near misses inside underFirePinnedMs stack (each one hits harder). Capped (underFireMax).
-- Traits as vanilla panic (BodyDamage.IncreasePanic): Cowardly x2, Brave x0.3, Desensitized x0.15 (vanilla wipes a
-- Desensitized player's panic every update, so for them only the stress part stays).
-- Real players only (IsoPlayer; A-Life NPC shells are IsoZombie). Runs where A-Life fires (SP / server).
-- MP: server adds the stats and sends them with syncPlayerStats (as vanilla ISApplyBandage:complete does).
-- 0.8.11.1 dedicated server: A-Life's ghost rounds only graze IsoPlayer.getPlayers() (local players, none on a
-- dedicated server), so whizz never fires there. We also wrap Suppression.noteGhostRound(shell, x, y, z, weapon,
-- ownerUid, now) (called for every ghost round) and check online players within 1.5 tiles of where it landed, same
-- storey, with a clear line (A-Life's own grazePlayer test: Gunner.sameStorey + Gunner.canReach). Server only.
-- Every number is a setting. Off by default.
require "ALifeNPCOverhaul/AA_Side"
ALifeUnderFire = ALifeUnderFire or {}
local U = ALifeUnderFire
local TAG = "[ALifeUnderFire]"
U.VERSION = ALifeSide.MOD_VERSION
U.metrics = U.metrics or { whizz = 0, near = 0, applied = 0, skipped = 0 }
U.recent = U.recent or setmetatable({}, { __mode = "k" }) -- player -> { count, lastMs }

U.DEFAULTS = {
    underFire = false,        -- rounds cracking past you raise your panic (vanilla: panic = worse aim, slower reload)
    underFirePanic = 12,      -- panic added per near miss (0-100; moodle levels at 6 / 30 / 65 / 80)
    underFireStack = 50,      -- % more per near miss already taken inside the pinned window
    underFirePinnedMs = 6000, -- ms: near misses this close together count as pinned
    underFireMax = 70,        -- our near misses never push panic past this (65+ = third moodle level)
    underFireStress = 0.03,   -- stress added per near miss (0-1; moodle levels at 0.25 / 0.5 / 0.75 / 0.9)
    underFireTiles = 3,       -- a round this close to you (tiles, off its line) counts as a near miss
    underFireReach = 40,      -- shooter farther than this (tiles) never counts
    underFireGapMs = 300,     -- ms: at most one near miss per player this often
    underFireTraits = true,   -- Cowardly / Brave / Desensitized change it the way they change vanilla panic
}
U.FILE_KEYS = {}
for k in pairs(U.DEFAULTS) do U.FILE_KEYS[#U.FILE_KEYS + 1] = k end
table.sort(U.FILE_KEYS)

-- 42.21 SyncPlayerStatsPacket.getBitMaskForStat = 1 << index in CharacterStat.ORDERED_STATS (PANIC 12, STRESS 17).
-- (Vanilla's own 0x100 in ISApplyBandage is index 8 = intoxication, a stale mask.) Checked in the 42.21 jar only.
U.SYNC_PANIC = 4096
U.SYNC_STRESS = 131072

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end

U.adapters = U.adapters or {} -- tests: nowMs
function U.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = U.DEFAULTS[key] end
    return v
end
function U.n(key) return num(U.setting(key), num(U.DEFAULTS[key], 0)) end
function U.on() return U.setting("underFire") == true end
function U.nowMs()
    if fn(U.adapters, "nowMs") then return U.adapters.nowMs() end
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return 0
end

local function xy(o)
    local t = type(o)
    if t ~= "table" and t ~= "userdata" then return nil, nil end
    if t == "table" and type(o.x) == "number" and type(o.y) == "number" then return o.x, o.y end
    local x, y = nil, nil
    pcall(function() x, y = o:getX(), o:getY() end)
    return tonumber(x), tonumber(y)
end

-- near miss: shooter within reach, the round's line (shooter -> aim) passes within underFireTiles of the body.
-- No aim = A-Life's own "round landed by you" call (grazePlayer): counts.
function U.nearMiss(body, shooter, aim)
    local bx, by = xy(body)
    local sx, sy = xy(shooter)
    if bx == nil or sx == nil then return false end
    local dx, dy = bx - sx, by - sy
    local reach = U.n("underFireReach")
    if dx * dx + dy * dy > reach * reach then return false end
    local ax, ay = xy(aim)
    if ax == nil then return true end
    local rx, ry = ax - sx, ay - sy
    local len2 = rx * rx + ry * ry
    if len2 < 0.0001 then return true end
    local along = (dx * rx + dy * ry) / len2
    if along < 0 then along = 0 end
    local px, py = sx + rx * along - bx, sy + ry * along - by
    local tiles = U.n("underFireTiles")
    return px * px + py * py <= tiles * tiles
end

function U.isPlayer(body)
    if body == nil or type(instanceof) ~= "function" then return false end
    local ok, yes = pcall(function() return instanceof(body, "IsoPlayer") end)
    if not ok or yes ~= true then return false end
    local dead = false
    pcall(function() dead = body:isDead() == true end)
    return not dead
end

function U.traitMult(body)
    if U.setting("underFireTraits") == false or type(CharacterTrait) == "nil" then return 1 end
    local m = 1
    pcall(function()
        if body:hasTrait(CharacterTrait.COWARDLY) then m = m * 2 end
        if body:hasTrait(CharacterTrait.BRAVE) then m = m * 0.3 end
        if body:hasTrait(CharacterTrait.DESENSITIZED) then m = m * 0.15 end
    end)
    return m
end

-- one near miss on a player: count the pin, add panic (capped) + stress, sync in MP. Returns panic added.
function U.apply(body, now)
    now = num(now, U.nowMs())
    local r = U.recent[body]
    if r == nil then r = { count = 0, lastMs = -1e12 }; U.recent[body] = r end
    if now - r.lastMs < U.n("underFireGapMs") then U.metrics.skipped = U.metrics.skipped + 1; return 0 end
    if now - r.lastMs <= U.n("underFirePinnedMs") then r.count = r.count + 1 else r.count = 1 end
    if r.count > 6 then r.count = 6 end
    r.lastMs = now
    local mult = U.traitMult(body)
    local panic = U.n("underFirePanic") * (1 + U.n("underFireStack") / 100 * (r.count - 1)) * mult
    local stress = U.n("underFireStress") * mult
    local added, mask = 0, 0
    local ok, e = pcall(function()
        local stats = body:getStats()
        local cap = U.n("underFireMax")
        local cur = stats:get(CharacterStat.PANIC)
        if panic > cap - cur then panic = cap - cur end
        if panic > 0 then stats:add(CharacterStat.PANIC, panic); added = panic; mask = mask + U.SYNC_PANIC end
        if stress > 0 then stats:add(CharacterStat.STRESS, stress); mask = mask + U.SYNC_STRESS end
    end)
    if not ok then
        if not U.statsFailLogged then U.statsFailLogged = true; log("stats failed (once): " .. tostring(e)) end
        return 0
    end
    if mask > 0 and ALifeSide.server() and type(syncPlayerStats) == "function" then
        pcall(syncPlayerStats, body, mask)
    end
    U.metrics.applied = U.metrics.applied + 1
    return added
end

function U.onWhizz(body, shooter, aim)
    U.metrics.whizz = U.metrics.whizz + 1
    if not U.on() or not U.isPlayer(body) then return end
    if not U.nearMiss(body, shooter, aim) then return end
    U.metrics.near = U.metrics.near + 1
    U.apply(body)
end

-- wrap A-Life ModuleGunner.whizz (server/ file: loads after shared/, so hook late). Original first, its result kept.
function U.hook()
    if U.hooked then return true end
    local PA = ProjectALife
    local G = type(PA) == "table" and PA.ModuleGunner or nil
    if not fn(G, "whizz") then return false end
    if G.whizz_ALifeUnderFire then U.hooked = true; return true end
    local orig = G.whizz
    G.whizz = function(body, shooter, aim, ...)
        local a, b, c = orig(body, shooter, aim, ...)
        local ok, e = pcall(U.onWhizz, body, shooter, aim)
        if not ok and not U.failLogged then U.failLogged = true; log("near miss failed (once): " .. tostring(e)) end
        return a, b, c
    end
    G.whizz_ALifeUnderFire = orig
    U.hooked = true
    log("hooked ProjectALife.ModuleGunner.whizz")
    return true
end

-- dedicated server: the ghost round landed at x, y, z -> online players within 1.5 tiles (A-Life grazePlayer's test)
U.GHOST_TILES2 = 2.25
function U.onGhost(shell, x, y, z, now)
    if not U.on() or type(getOnlinePlayers) ~= "function" then return 0 end
    x, y, z = tonumber(x), tonumber(y), tonumber(z) or 0
    if x == nil or y == nil then return 0 end
    local G = type(ProjectALife) == "table" and ProjectALife.ModuleGunner or nil
    local list = getOnlinePlayers()
    if list == nil then return 0 end
    local n = 0
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if U.isPlayer(p) then
            local px, py = xy(p)
            local pz = 0
            pcall(function() pz = p:getZ() end)
            if px ~= nil and (px - x) ^ 2 + (py - y) ^ 2 <= U.GHOST_TILES2 and math.floor(tonumber(pz) or 0) == math.floor(z) then
                local clear = true
                if fn(G, "canReach") then
                    local ok, c = pcall(G.canReach, shell, p)
                    clear = ok and c == true
                end
                if clear then
                    U.metrics.near = U.metrics.near + 1
                    U.metrics.ghost = (U.metrics.ghost or 0) + 1
                    if U.apply(p) > 0 then n = n + 1 end
                end
            end
        end
    end
    return n
end
function U.hookGhost()
    if U.ghostHooked then return true end
    if ALifeSide.ui() then return false end -- SP / listen: whizz already covers it
    local S = type(ProjectALife) == "table" and ProjectALife.Suppression or nil
    if not fn(S, "noteGhostRound") then return false end
    if S.noteGhostRound_ALifeUnderFire == nil then
        local orig = S.noteGhostRound
        S.noteGhostRound = function(shell, x, y, z, weapon, ownerUid, now, ...)
            local a, b = orig(shell, x, y, z, weapon, ownerUid, now, ...)
            local ok, e = pcall(U.onGhost, shell, x, y, z, now)
            if not ok and not U.ghostFailLogged then U.ghostFailLogged = true; log("ghost round failed (once): " .. tostring(e)) end
            return a, b
        end
        S.noteGhostRound_ALifeUnderFire = orig
    end
    U.ghostHooked = true
    log("hooked ProjectALife.Suppression.noteGhostRound (dedicated server)")
    return true
end

U.tries = U.tries or 0
function U.tryHook()
    if U.hooked or U.gaveUp then return end
    U.tries = U.tries + 1
    U.hookGhost()
    if U.hook() then return end
    if U.tries >= 600 then
        U.gaveUp = true
        -- an MP client never has A-Life's server files: nothing to hook there, by design
        if ALifeSide.world() then log("A-Life ModuleGunner.whizz not found: under fire off") end
    end
end
U.tryHook()
if type(Events) == "table" and Events.OnTick ~= nil then
    Events.OnTick.Add(function()
        if not U.hooked and not U.gaveUp then U.tryHook() end
        if not U.ghostHooked and num(U.ghostTries, 0) < 600 then U.ghostTries = num(U.ghostTries, 0) + 1; U.hookGhost() end
    end)
end
print(TAG .. " ready v" .. U.VERSION .. ": near misses raise panic (setting underFire), hook " .. (U.hooked and "on" or "waiting"))

return U
