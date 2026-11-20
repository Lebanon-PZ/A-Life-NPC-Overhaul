-- A-Life Talk Patch 1.4.3 - optional runtime patch for Project A-Life (B42).
-- Nothing on disk is edited. After A-Life has loaded, a few of its module-table functions are wrapped in memory:
--   Relations.hostileToPlayer / Relations.playerStance   (1) calm-down: opinion-aware peace with the player
--   Relations.noteAggression                             (1) attacking a calmed NPC breaks the peace
--   Relations.status                                     (2) per-pair NPC-vs-NPC stance overrides
--   Talk.walkWith, ModuleRegistry "stance" evaluate      (3) companion mode for walk-with
--   (no wrap) ModuleRobbery.crewsNear/eligible/start     (4) NPC demand -> A-Life's own robbery
--   (no wrap) DecisionLoop.setOrder, Animations.apply    (6) v1.2 shelter, group-up, leader commands, player orders,
--                                                            gestures - A-Life's own order + animation calls
--   (no wrap) Health / Wounds / ModuleHealing             (7) v1.3 wound care: gifted bandage / splint, medic help,
--                                                            rest, clutch, falls - A-Life's own heal / splint calls
--   Names.shown                                          (8) v1.3 fake names an NPC gave you
--   ActorRegistry.remove / create, Lifecycle.stepTurn    (9) v1.3 keep NPCs you know, same identity, who a zombie was
--   NpcOpinion.noteKill, Revenge.onActorDied,            (10) v1.3 mercy kills of the bitten / infected are not murder
--     HostileAct.noteKill
--   Combat.preferredWeapon, Revenge.owed                 (6) nemesis weapon tiers / personal contracts
--   (no wrap) P.baseSettle / P.unsettle                  (11) v1.3 settlers: A-Life's own home anchor at your base
--   (no wrap) P.baseLeave / baseReturn / baseRehome /     (11b) v1.4.3 settlers on leave (travelling in your party),
--     baseDrop, resident home = A-Life house bounds              back home, following A-Life's base when it moves, death
--   DecisionLoop.think                                   (12) v1.4 behaviour ownership: listening / activity / party /
--                                                            resident NPCs are driven here; A-Life gets them back on danger
--   Lifecycle.onShellDeath                               (13) v1.4 dormant death guard (leftover body of an unloaded NPC)
-- Every wrapper calls the original whenever the patch's own rule does not apply, everything is pcall-guarded,
-- and every new piece of state lives in ModData "ALifeTalkPatch" (plus A-Life's own fields written the way
-- A-Life itself writes them). Disable the mod and A-Life runs exactly as shipped (leftover ModData is ignored).
ALifeTalkPatch = ALifeTalkPatch or {}
local P = ALifeTalkPatch
-- pre-1.0 MP (docs/PLAN-MP.md P3): the one side switch. "world": its ticks run where A-Life's world is (SP or the MP
-- server), never on an MP client (empty registry, double fire). Per-player ticks loop over ALifeSide.each.
if ALifeSide == nil then require "ALifeNPCOverhaul/AA_Side" end
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalkPatch")
if P.loaded then return P end
P.loaded = true
P.VERSION = "1.4.3"

P.settings = {
    calm = {
        enabled = true,
        checkMs = 2000,          -- how often NPCs near you are re-checked
        dwellMs = 6000,          -- opinion must stay over the threshold this long (never instant)
        quietMs = 20000,         -- ...and you must not have hit them for this long
        grudgeAt = -15,          -- threshold when they hold a grudge (you provoked them)
        earnedAt = 0,            -- threshold when A-Life's reputation says "hostile" for this NPC's faction
        factionAt = 20,          -- threshold for naturally hostile factions (bandits, raiders ...)
        hysteresis = 10,         -- calm ends if opinion falls this far below the threshold
        settleHours = 0.5,       -- after this long at peace, the provoked grudge itself is let go (like CalmDown)
        brokenCooldownMs = 300000, -- after you break the peace, no new calm for 5 min
        plea = { cooldownMs = 15000, windowMs = 600000, steps = { 4, 3, 2, 1 }, armedPenalty = 1 },
    },
    pairs = { enabled = true, defaultHours = 24, maxHours = 168 },
    companion = {
        enabled = true, autoAll = true, -- every accepted "walk with me" becomes a companion walk
        renewHours = 0.5, holdTiles = 2.5, runTiles = 7, warpTiles = 30, alwaysWarpTiles = 48, footWarp = false,
        rideTiles = 12, exitMin = 2, exitMax = 4, tickMs = 1000,
    },
    robbery = { enabled = true },
    -- v1.1: hostility that turns into real attacks
    attack = {
        player = true,          -- very low opinion -> A-Life's warning steps -> A-Life's attack state (turnGroup)
        npc = true,             -- NPC enemies / nemeses fight each other (per-pair hostile stance, decaying)
        playerAt = -60,         -- opinion at or below this starts the warning ladder
        rangeTiles = 20,        -- only NPCs this close to you (and on your floor) escalate
        warnMs = 7000,          -- time between warning steps (wariness -> warning -> attack)
        tickMs = 2000,
        cooldownMs = 120000,    -- after a ladder was interrupted (opinion rose), wait before starting again
        npcAt = -60,            -- pair score at or below this (A-Life Talk) means a real feud
        npcHours = 12,          -- feud stance lasts this long unless renewed (decays: never permanent)
    },
    nemesis = { enabled = true, minDueHours = 12, spreadHours = 24, backup = { 0, 1, 2 } },
}

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return math.floor(os.time() * 1000)
end
local function hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return h
end
function P.hasAny(t) -- v1.2: Kahlua has no next()
    if type(t) ~= "table" then return false end
    for _ in pairs(t) do return true end
    return false
end
local function log(msg) print("[ALifeTalkPatch] " .. tostring(msg)) end
P.log = log
local function pos(o)
    if o == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end)
    return x, y, z
end
local function safe(f, ...)
    local ok, a, b, c = pcall(f, ...)
    if not ok then log("error: " .. tostring(a)); return nil end
    return a, b, c
end

-- save data (ModData; created lazily once the world is up)
P.data = nil
function P.store()
    if P.data ~= nil then return P.data end
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeTalkPatch") end)
    if type(d) ~= "table" then d = P.fallbackStore or {}; P.fallbackStore = d else P.data = d end
    d.calm = type(d.calm) == "table" and d.calm or {}
    d.pairs = type(d.pairs) == "table" and d.pairs or {}
    d.companions = type(d.companions) == "table" and d.companions or {}
    d.nemesis = type(d.nemesis) == "table" and d.nemesis or {}   -- v1.1: uid -> { tier, key, why, dueH, sent }
    d.ordered = type(d.ordered) == "table" and d.ordered or {}   -- v1.2: uid -> order we gave (released by us only)
    d.shelter = type(d.shelter) == "table" and d.shelter or {}
    d.shelterRetry = type(d.shelterRetry) == "table" and d.shelterRetry or {}
    return d
end
local function playerKey(player)
    local pa = PA()
    if pa and fn(pa.Reputation, "playerKey") then local ok, k = pcall(pa.Reputation.playerKey, player); if ok and k then return k end end
    if pa and fn(pa.Speech, "playerKey") then local ok, k = pcall(pa.Speech.playerKey, player); if ok then return k end end
    return nil
end
local function speechKey(player)
    local pa = PA()
    if pa and fn(pa.Speech, "playerKey") then local ok, k = pcall(pa.Speech.playerKey, player); if ok then return k end end
    return playerKey(player)
end
P.playerKey = playerKey
local function readRec(uid)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    if not fn(reg, "read") then return nil end
    return (reg.peek or reg.read)(tostring(uid))
end
P.hooks = { calm = {}, calmEnd = {}, robbery = {}, companion = {}, warn = {}, lastWarn = {}, lastWarnHeeded = {}, attack = {}, nemesisArrive = {}, shelter = {}, command = {},
    kept = {}, seedSaved = {}, seedRestored = {}, teleport = {}, companionCaughtUp = {}, reanimating = {}, mercy = {}, settled = {}, removing = {}, removed = {} } -- other mods (A-Life Talk) may listen
local function emit(kind, ...) for _, h in ipairs(P.hooks[kind] or {}) do pcall(h, ...) end end

----------------------------------------------------------------------------------------------------------------
-- 1) CALM-DOWN: a hostile NPC whose opinion of you climbs past a threshold stops being hostile to you
----------------------------------------------------------------------------------------------------------------
P.pending, P.lastHitMs, P.brokenUntil, P.pleas = {}, {}, {}, {}

function P.calmEntry(uid, key)
    local d = P.data or P.store()
    local row = d.calm[tostring(uid)]
    return row ~= nil and key ~= nil and row[key] or nil
end

-- fast path used inside A-Life's hot targeting code: one table lookup for every NPC that was never calmed
local function calmedFor(actor, player)
    if not P.settings.calm.enabled or type(actor) ~= "table" or player == nil then return nil end
    local d = P.data
    if d == nil then return nil end
    local row = d.calm[actor.uid]
    if row == nil then return nil end
    local key = playerKey(player)
    return key ~= nil and row[key] or nil, key
end

function P.underAttack(actor, player, now)
    local pa = PA()
    now = now or nowMs()
    local key = playerKey(player)
    if key and now - (P.lastHitMs[tostring(actor.uid) .. "|" .. key] or -1e12) < P.settings.calm.quietMs then return true end
    if pa and fn(pa.Fairness, "underAttack") then
        local ok, v = pcall(pa.Fairness.underAttack, actor, player, now)
        if ok and v == true then return true end
    end
    return false
end

function P.endCalm(uid, key, why, cooldown)
    local d = P.store()
    local row = d.calm[tostring(uid)]
    if row == nil or row[key] == nil then return false end
    row[key] = nil
    if not P.hasAny(row) then d.calm[tostring(uid)] = nil end
    if cooldown then P.brokenUntil[tostring(uid) .. "|" .. key] = nowMs() + P.settings.calm.brokenCooldownMs end
    log("calm ended for " .. tostring(uid) .. " (" .. tostring(why) .. ")")
    emit("calmEnd", tostring(uid), key, why)
    return true
end

-- which A-Life rule makes them hostile, and how much opinion it takes to talk them down (nil = never)
function P.calmThreshold(record, player)
    local pa = PA()
    local s = P.settings.calm
    local memory = type(record.memory) == "table" and record.memory or {}
    local key = playerKey(player)
    if memory.hostileOverride == true then return nil, "forced" end
    if fn(pa.Relations, "orderedHostile") and pa.Relations.orderedHostile(record, player) then return nil, "ordered" end
    if fn(pa.Checkpoints, "hostileGuard") then
        local ok, g = pcall(pa.Checkpoints.hostileGuard, record)
        if ok and g then return nil, "checkpoint" end
    end
    if memory.hostileAct ~= nil and fn(pa.HostileAct, "live") and pa.HostileAct.live(memory, key) then return nil, "hostile_act" end
    local nem = P.data and P.data.nemesis[tostring(record.uid)]
    if nem and (tonumber(nem.tier) or 0) >= 2 then return nil, "nemesis" end -- they came back to settle it
    local bonus = 0 -- v1.1: A-Life Talk personality (forgiving people calm sooner, grudge-holders later)
    pcall(function()
        local mods = ALifeLLMTalk and ALifeLLMTalk.personaMods and ALifeLLMTalk.personaMods(record.uid)
        if mods and tonumber(mods.forgive) then bonus = math.floor((0.5 - tonumber(mods.forgive)) * 30) end
    end)
    if type(memory.hostileToPlayerKeys) == "table" and key and memory.hostileToPlayerKeys[key] == true then return s.grudgeAt + bonus, "grudge" end
    if fn(pa.Reputation, "recordedStatus") then
        local ok, st = pcall(pa.Reputation.recordedStatus, player, record)
        if ok and st == "hostile" then return s.earnedAt, "reputation" end
    end
    return s.factionAt, "faction"
end

function P.opinion(record, player)
    local pa = PA()
    if not fn(pa and pa.NpcOpinion, "valueOf") then return 0 end
    local ok, v = pcall(pa.NpcOpinion.valueOf, record, player)
    return ok and tonumber(v) or 0
end

function P.grantCalm(record, player, why)
    local key = playerKey(player)
    local d = P.store()
    d.calm[record.uid] = d.calm[record.uid] or {}
    local _, reason = P.calmThreshold(record, player)
    d.calm[record.uid][key] = { atH = hours(), atMs = nowMs(), why = why or reason, reason = reason }
    P.pending[record.uid .. "|" .. key] = nil
    -- wake A-Life's perception so it re-reads the stance now (same calls Relations.provoke makes)
    local pa = PA()
    pcall(function() pa.Perception.forgetIgnored(record.uid) end)
    pcall(function() if pa.DecisionLoop.passiveQuietAtMs then pa.DecisionLoop.passiveQuietAtMs[record.uid] = nil end end)
    log("calm: " .. tostring(record.uid) .. " stops being hostile to " .. tostring(key) .. " (" .. tostring(reason) .. ")")
    emit("calm", record, player, reason)
    return true
end

-- let a provoked grudge go after a while at peace, the same way A-Life's CalmDown.settle does it
function P.settle(record, key, entry)
    local pa = PA()
    local memory = type(record.memory) == "table" and record.memory or {}
    if type(memory.hostileToPlayerKeys) ~= "table" or memory.hostileToPlayerKeys[key] ~= true then entry.settled = true; return end
    local reg = pa.ActorRegistry
    if not fn(reg, "update") then return end
    local h = hours()
    local fresh = reg.read(record.uid)
    if fresh == nil then return end
    reg.update(record.uid, fresh.revision, function(r)
        r.memory = r.memory or {}
        if type(r.memory.hostileToPlayerKeys) == "table" then r.memory.hostileToPlayerKeys[key] = nil end
        r.memory.calmReleased = type(r.memory.calmReleased) == "table" and r.memory.calmReleased or {}
        r.memory.calmReleased[key] = h
    end)
    entry.settled = true
    log("calm: grudge of " .. tostring(record.uid) .. " against " .. tostring(key) .. " let go")
end

function P.calmTick(player)
    local pa = PA()
    if not P.settings.calm.enabled or player == nil or not fn(pa.Talk, "listeners") or P.orig.hostileToPlayer == nil then return end
    local now, key = nowMs(), playerKey(player)
    if key == nil then return end
    local s = P.settings.calm
    for _, l in ipairs(pa.Talk.listeners(player, 45)) do
        local r = l.record
        local entry = P.calmEntry(r.uid, key)
        local v = P.opinion(r, player)
        if entry ~= nil then
            local need = P.calmThreshold(r, player)
            local memory = type(r.memory) == "table" and r.memory or {}
            if need == nil then P.endCalm(r.uid, key, "hard hostility", true)
            elseif v < need - s.hysteresis then P.endCalm(r.uid, key, "opinion fell", false)
            elseif P.underAttack(r, player, now) then P.endCalm(r.uid, key, "attacked", true)
            elseif entry.settled and type(memory.hostileToPlayerKeys) == "table" and memory.hostileToPlayerKeys[key] == true then
                P.endCalm(r.uid, key, "new grudge", true)
            elseif not entry.settled and hours() - (entry.atH or hours()) >= s.settleHours then
                safe(P.settle, r, key, entry)
            end
        else
            local pk = r.uid .. "|" .. key
            local hostile = false
            local ok, hv = pcall(P.orig.hostileToPlayer, r, player)
            hostile = ok and hv == true
            local need = hostile and P.calmThreshold(r, player) or nil
            if need ~= nil and v >= need and now >= (P.brokenUntil[pk] or 0) and not P.underAttack(r, player, now) then
                P.pending[pk] = P.pending[pk] or now
                if now - P.pending[pk] >= s.dwellMs then P.grantCalm(r, player, "opinion " .. v) end
            else
                P.pending[pk] = nil
            end
        end
    end
end

-- a plea (mid-fight too): bounded, diminishing opinion gain through A-Life's own NpcOpinion.adjust
function P.plead(record, shell, player, opts)
    local pa = PA()
    opts = opts or {}
    if type(record) ~= "table" or player == nil then return { ok = false, reason = "invalid" } end
    local now, key = nowMs(), playerKey(player)
    local uid = tostring(record.uid)
    local s = P.settings.calm.plea
    local st = P.pleas[uid .. "|" .. tostring(key)]
    if st == nil or now - st.firstMs > s.windowMs then st = { firstMs = now, n = 0, lastMs = -1e12 }; P.pleas[uid .. "|" .. tostring(key)] = st end
    if now - st.lastMs < s.cooldownMs then return { ok = false, reason = "cooldown", delta = 0 } end
    if P.underAttack(record, player, now) then st.lastMs = now; return { ok = false, reason = "attacked", delta = 0 } end
    local step = s.steps[st.n + 1]
    if step == nil then return { ok = false, reason = "spent", delta = 0 } end
    local delta = step * (tonumber(opts.strength) or 1)
    pcall(function()
        local hand = player:getPrimaryHandItem()
        if hand ~= nil and instanceof(hand, "HandWeapon") and hand:isRanged() then delta = delta - s.armedPenalty end
    end)
    delta = math.max(0, math.floor(delta + 0.5))
    st.n, st.lastMs = st.n + 1, now
    if delta > 0 and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, record, player, delta, "Pleaded for peace.") end
    local need = P.calmThreshold(record, player)
    local v = P.opinion(record, player)
    log("plea to " .. uid .. ": +" .. delta .. " (opinion " .. v .. ", needs " .. tostring(need) .. ")")
    return { ok = true, delta = delta, opinion = v, need = need, pending = need ~= nil and v >= need, left = #s.steps - st.n }
end

----------------------------------------------------------------------------------------------------------------
-- 2) NPC-vs-NPC: per-pair stance overrides (directional), saved, time-limited
----------------------------------------------------------------------------------------------------------------
P.hoursNow = 0
local stances = { hostile = true, careful = true, neutral = true, friendly = true }

function P.setPairStance(sourceUid, targetUid, stance, hrs, why, mutual)
    if not P.settings.pairs.enabled or not stances[stance] then return false end
    local d = P.store()
    local s, t = tostring(sourceUid), tostring(targetUid)
    if s == t then return false end
    hrs = math.max(0.05, math.min(tonumber(hrs) or P.settings.pairs.defaultHours, P.settings.pairs.maxHours))
    d.pairs[s] = d.pairs[s] or {}
    local old = d.pairs[s][t]
    local untilH = hours() + hrs
    if old and old.s == "hostile" and stance == "careful" and (old.untilH or 0) > hours() then
        -- "careful" never softens an active enemy entry (use "friendly" or clearPairStance to make peace)
        if mutual then P.setPairStance(t, s, mutual == true and stance or mutual, hrs, why, nil) end
        return false
    end
    if old and old.s == stance and (old.untilH or 0) > untilH then untilH = old.untilH end -- never shortens
    d.pairs[s][t] = { s = stance, untilH = untilH, setH = hours(), why = why and string.sub(tostring(why), 1, 60) or nil }
    P.hoursNow = hours()
    if stance == "hostile" then
        local pa = PA()
        pcall(function() pa.Perception.forgetIgnored(s) end)
        pcall(function() if pa.DecisionLoop.passiveQuietAtMs then pa.DecisionLoop.passiveQuietAtMs[s] = nil end end)
    end
    log("pair stance " .. s .. " -> " .. t .. " = " .. stance .. " for " .. ALifeFmtDec(hrs, 1) .. " h (" .. tostring(why) .. ")")
    if mutual then P.setPairStance(t, s, mutual == true and stance or mutual, hrs, why, nil) end
    return true
end

function P.pairStance(sourceUid, targetUid)
    local d = P.data or P.store()
    local row = d.pairs[tostring(sourceUid)]
    local o = row and row[tostring(targetUid)]
    if o and (o.untilH or 0) > P.hoursNow then return o.s, o end
    return nil
end

function P.clearPairStance(sourceUid, targetUid, mutual)
    local d = P.store()
    local row = d.pairs[tostring(sourceUid)]
    if row then row[tostring(targetUid)] = nil; if not P.hasAny(row) then d.pairs[tostring(sourceUid)] = nil end end
    if mutual then P.clearPairStance(targetUid, sourceUid, false) end
end

function P.prunePairs()
    local d = P.store()
    local h = hours()
    P.hoursNow = h
    for s, row in pairs(d.pairs) do
        for t, o in pairs(row) do
            local dead = readRec(t)
            if type(o) ~= "table" or (o.untilH or 0) <= h or (dead and dead.lifecycle == "dead") then row[t] = nil end
        end
        if not P.hasAny(row) then d.pairs[s] = nil end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 3) COMPANION: walk-with without the 1 h limit and the 60-tile drop; re-join after car trips
----------------------------------------------------------------------------------------------------------------
function P.companionOf(uid)
    local d = P.data or P.store()
    return d.companions[tostring(uid)]
end

local function walkingWith(record, key)
    local memory = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    return type(memory.walkWith) == "table" and memory.walkWith.key == key
end

function P.startCompanion(player, listener)
    if not P.settings.companion.enabled or type(listener) ~= "table" or type(listener.record) ~= "table" then return false, "off" end
    local key = speechKey(player)
    local fresh = readRec(listener.record.uid) or listener.record
    if not walkingWith(fresh, key) then return false, "not_walking" end
    local x, y = pos(player)
    P.store().companions[tostring(listener.record.uid)] = { key = key, startH = hours(), sx = x and math.floor(x), sy = y and math.floor(y) }
    log("companion: " .. tostring(listener.record.uid) .. " travels with " .. tostring(key))
    emit("companion", "start", tostring(listener.record.uid))
    return true
end

function P.stopCompanion(uid, why)
    local d = P.store()
    if d.companions[tostring(uid)] == nil then return false end
    d.companions[tostring(uid)] = nil
    log("companion: " .. tostring(uid) .. " stopped (" .. tostring(why) .. ")")
    emit("companion", "stop", tostring(uid), why)
    return true
end

-- a free square near (x, y), preferring the side the player isn't facing
function P.findSpot(player, rmin, rmax)
    local px, py, pz = pos(player)
    if px == nil or type(getCell) ~= "function" then return nil end
    local fx, fy = 0, 0
    pcall(function() local f = player:getForwardDirection(); fx, fy = f:getX(), f:getY() end)
    local best = nil
    local cell = getCell()
    for r = rmin, rmax do
        for i = 0, 11 do
            local a = i * math.pi / 6
            local dx, dy = math.cos(a), math.sin(a)
            local x, y = math.floor(px + dx * r), math.floor(py + dy * r)
            local ok, sq = pcall(function() return cell:getGridSquare(x, y, math.floor(pz or 0)) end)
            local free = false
            if ok and sq ~= nil then pcall(function() free = sq:isFree(false) == true end) end
            if free then
                local behind = dx * fx + dy * fy < 0
                if behind then return { x = x + 0.5, y = y + 0.5, z = math.floor(pz or 0) } end
                best = best or { x = x + 0.5, y = y + 0.5, z = math.floor(pz or 0) }
            end
        end
    end
    return best
end

function P.warp(shell, spot, why)
    local pa = PA()
    if shell == nil or spot == nil then return false end
    local ok = false
    if fn(pa.AIFence, "moveBody") then
        -- 0.7.2.1: A-Life 1.5 can refuse a move and returns false; pcall alone said ok
        local okc, moved = pcall(pa.AIFence.moveBody, shell, spot.x, spot.y, "ALifeChatPlus.warp")
        ok = okc and moved ~= false
    end
    if not ok then ok = pcall(function() shell:setX(spot.x); shell:setY(spot.y) end) end
    pcall(function() shell:setZ(spot.z) end)
    pcall(function() shell:setLx(spot.x); shell:setLy(spot.y); shell:setLz(spot.z) end)
    -- 0.7.0.8: warps are 30+ tiles; A-Life's watchdog reads a jump over 20 as a lost body unless told
    if ALifeMove then ALifeMove.rebase(shell) end
    log("companion warp (" .. tostring(why) .. ") to " .. math.floor(spot.x) .. "," .. math.floor(spot.y))
    return ok
end

local function onScreen(shell, player, d)
    local v = nil
    pcall(function() v = shell:isOnScreen() end)
    if v ~= nil then return v == true end
    local seen = false
    pcall(function() seen = player:CanSee(shell) == true end)
    return seen and d < 40
end

-- runs instead of A-Life's walkWith stance handler for companions; anything else goes to the original
function P.companionEvaluate(actor, shell, context)
    local pa = PA()
    local c = P.settings.companion
    local comp = P.companionOf(actor.uid)
    local memory = type(actor.memory) == "table" and actor.memory or {}
    if comp == nil or memory.stance ~= "walkWith" or not walkingWith(actor, comp.key) then return nil, false end
    if not fn(pa.AIFence, "drivesBody") or not pa.AIFence.drivesBody(shell) then return nil, false end
    local player = fn(pa.ModuleStances, "walkTarget") and pa.ModuleStances.walkTarget(comp.key) or nil
    if player == nil then return nil, false end
    local now = tonumber(context and context.now) or nowMs()
    local sx, sy = pos(shell)
    local px, py, pz = pos(player)
    if sx == nil or px == nil then return nil, false end
    local d = math.sqrt((px - sx) ^ 2 + (py - sy) ^ 2)
    local inCar = false
    pcall(function() inCar = player:getVehicle() ~= nil end)
    local function hold(intent)
        if type(context.setActivity) == "function" then pcall(context.setActivity, actor, "idle", intent) end
        return { kind = "idle", intent = intent, cooldownUntilMs = now + 800 }
    end
    -- 0.6.12: in or out of the car, never fight A-Life's riders. Seated by A-Life in your car: leave them be (standing
    -- them back up every tick made them pop in and out of the car). You got out and they're still sitting in a car:
    -- tell them to climb out too (A-Life's own passenger order), then follow as usual.
    local seatedIn = nil
    pcall(function() seatedIn = shell:getVehicle() end)
    -- 0.7.1: party rides: while A-Life is walking them to a car door, seating them or walking them clear after
    -- getting out, A-Life owns them (holding them idle here would stop them halfway to the door)
    local DO = ALifeDriveOrders
    local aLife = DO ~= nil and type(DO.aLifeHasThem) == "function" and DO.aLifeHasThem(actor.uid) == true
    if inCar then
        if seatedIn ~= nil or aLife then return nil, false end
        return hold("companion_wait_car"), true
    end
    -- 0.7.2: riding in the second car, or getting out of a car through A-Life: A-Life's job (a passenger "exit"
    -- order on an NPC-driven car is refused and only fills the log)
    if aLife then return nil, false end
    if seatedIn ~= nil then
        if now >= (tonumber(comp.exitAskMs) or 0) then
            comp.exitAskMs = now + 4000
            pcall(function()
                local C = pa.DrivingDemoClient
                local md = shell:getModData()
                if C and type(C.passengerOrder) == "function" then
                    local okO = pcall(C.passengerOrder, seatedIn:getId(), "exit", md.ProjectALifeUID, md.ProjectALifeGeneration)
                    if not okO and type(C.getOut) == "function" then pcall(C.getOut, seatedIn:getId()) end
                end
            end)
        end
        return hold("companion_leaving_car"), true
    end
    if comp.waitUntilMs ~= nil then -- v1.3: "wait up" - stand still until they're told to come or it runs out
        if now < comp.waitUntilMs then return hold("companion_wait"), true end
        comp.waitUntilMs = nil
    end
    -- v1.2: the player's order ("hold here", "fall back", "take cover"...) beats following until it runs out
    local ord = comp.order
    if type(ord) == "table" and now < (tonumber(ord.untilMs) or 0) and type(context.startMovement) == "function" then
        local od = math.sqrt((ord.x - sx) ^ 2 + (ord.y - sy) ^ 2)
        if od <= 1.2 then return hold("companion_order_" .. tostring(ord.kind)), true end
        local st = context.startMovement(actor, shell, { x = ord.x, y = ord.y, z = ord.z }, "stance",
            { pace = (ord.kind == "fall_back" or ord.kind == "shelter") and "run" or "walk", timeoutMs = 12000, doorsOnly = true })
        if st ~= nil then return st, true end
        return hold("companion_order_" .. tostring(ord.kind)), true
    elseif type(ord) == "table" then comp.order = nil end
    if d <= c.holdTiles then return hold("companion_hold"), true end
    -- pre-1.0: no pop-ins on foot unless the player turns it back on (followCatchUpWarp, ALifeGunSense). Fell behind =
    -- they walk / run to you (andrer: a job companion warped in front of him, next to a horde, in West Point)
    local footWarp = c.footWarp == true
    if type(ALifeGunSense) == "table" and type(ALifeGunSense.footWarp) == "function" then footWarp = ALifeGunSense.footWarp() == true end
    if footWarp and (d > c.alwaysWarpTiles or (d > c.warpTiles and not onScreen(shell, player, d))) then
        local spot = P.findSpot(player, 6, 10)
        if spot and P.warp(shell, spot, "fell behind " .. math.floor(d)) then return hold("companion_caught_up"), true end
    end
    if type(context.startMovement) ~= "function" then return nil, false end
    local target = { x = px - (px - sx) / d * 2, y = py - (py - sy) / d * 2, z = pz }
    local started = context.startMovement(actor, shell, target, "stance",
        { pace = d > c.runTiles and "run" or "walk", timeoutMs = 8000, doorsOnly = true })
    if started ~= nil then return started, true end
    return nil, false
end

P.riding = false
function P.companionTick(player)
    local pa = PA()
    if not P.settings.companion.enabled or player == nil then return end
    local d = P.store()
    local key = speechKey(player)
    local h = hours()
    local inCar = false
    pcall(function() inCar = player:getVehicle() ~= nil end)
    local px, py = pos(player)
    for uid, comp in pairs(d.companions) do
        local r = readRec(uid)
        if r == nil or r.lifecycle == "dead" then P.stopCompanion(uid, "gone")
        elseif comp.key == key then
            if not walkingWith(r, key) then P.stopCompanion(uid, "walk ended")
            else
                local walk = r.memory.walkWith
                if (tonumber(walk.untilHours) or 0) - h < P.settings.companion.renewHours and fn(pa.Talk, "writeMemory") then
                    pa.Talk.writeMemory(uid, function(m)
                        if type(m.walkWith) == "table" then m.walkWith.untilHours = h + 1 end
                        if m.stance == nil then m.stance = "walkWith" end
                    end)
                end
                local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
                local sx, sy = pos(shell)
                if inCar and not P.riding and sx and px and (sx - px) ^ 2 + (sy - py) ^ 2 <= P.settings.companion.rideTiles ^ 2 then
                    comp.riding = true
                end
                if not inCar and P.riding and comp.riding then
                    comp.riding = nil
                    -- 0.7.1: rode along for real (A-Life seat): they get out on their own, no warp
                    local DO = ALifeDriveOrders
                    local real = DO ~= nil and type(DO.aLifeHasThem) == "function" and DO.aLifeHasThem(uid) == true
                    if real then
                    elseif shell ~= nil then P.warp(shell, P.findSpot(player, P.settings.companion.exitMin, P.settings.companion.exitMax), "got out of the car")
                    else comp.lost = true; log("companion " .. uid .. " is unloaded (too far); will catch up when you are near again") end
                end
            end
        end
    end
    P.riding = inCar
end

----------------------------------------------------------------------------------------------------------------
-- 4) ROBBERY: an NPC's demand starts A-Life's own robbery (same eligibility rules; no random roll)
----------------------------------------------------------------------------------------------------------------
function P.robberyCheck(record, player, now)
    local pa = PA()
    local R = pa and pa.ModuleRobbery
    if not P.settings.robbery.enabled or R == nil or not fn(R, "crewsNear") or not fn(R, "eligible") or not fn(R, "start") then
        return false, "robbery_unavailable"
    end
    if type(R.settings) == "table" and R.settings.enabled == false then return false, "robbery_off" end
    local key = fn(pa.Speech, "playerKey") and pa.Speech.playerKey(player) or nil
    if key == nil then return false, "no_player" end
    if fn(R, "activeFor") and R.activeFor(record, key) then return false, "already" end
    if type(R.byPlayer) == "table" and R.byPlayer[key] ~= nil then return false, "already" end
    local count = 0
    for _ in pairs(R.active or {}) do count = count + 1 end
    if count >= ((R.settings or {}).maxActive or 4) then return false, "too_many" end
    if fn(R, "loneAndOnFoot") then
        local presence = pa.ModuleTalkPresence
        local players = presence and fn(presence, "players") and presence.players() or { player }
        if not R.loneAndOnFoot(player, players) then return false, "not_alone_or_in_car" end
    end
    for group, crew in pairs(R.crewsNear(player)) do
        for _, m in ipairs(crew.members) do
            if m.record.uid == record.uid then
                local cd = tostring(group) .. ":" .. key
                if now < ((R.cooldowns or {})[cd] or 0) then return false, "cooldown" end
                local allowed, register = R.eligible(crew, player, key, now)
                if not allowed then return false, register end
                return true, register, crew, key, cd
            end
        end
    end
    return false, "no_crew"
end

function P.canRob(record, player)
    local ok, why = safe(P.robberyCheck, record, player, nowMs())
    return ok == true, why
end

function P.robPlayer(record, player)
    local pa = PA()
    local now = nowMs()
    local okc, ok, register, crew, key, cd = pcall(P.robberyCheck, record, player, now)
    if not okc then log("robbery check error: " .. tostring(ok)); return false, "error" end
    if not ok then log("robbery refused for " .. tostring(record.uid) .. ": " .. tostring(register)); return false, register end
    local R = pa.ModuleRobbery
    if type(R.cooldowns) == "table" then R.cooldowns[cd] = now + ((R.settings or {}).cooldownMs or 1200000) end
    local oks, state = pcall(R.start, crew, player, key, register, now)
    if not oks or state == nil then log("robbery start error: " .. tostring(state)); return false, "error" end
    log("robbery started by " .. tostring(record.uid) .. " (" .. tostring(register) .. ", crew of " .. #crew.members .. ")")
    emit("robbery", record, player, state)
    return true, state
end

----------------------------------------------------------------------------------------------------------------
-- install (idempotent; retried until A-Life's tables exist)
----------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------
-- 5) ATTACK: very low opinion -> A-Life's own warning steps -> A-Life's attack state
----------------------------------------------------------------------------------------------------------------
-- A-Life only turns an NPC hostile to you through its Careful ladder (shouting at them, robbery, hits). Opinion on its
-- own never did, so an NPC at -90 just taunted. Now: wariness (Talk.escalate -> careful) -> spoken warning ->
-- Careful.turnGroup (A-Life's real hostile state; the group members who saw it join, as in vanilla).
-- Witnessing you kill a close tie can skip the warnings (P.attackNow).
P.ladder = {}      -- uid|key -> { step, atMs }
P.ladderCool = {}
P.warnLines = { "Back off. I mean it.", "Last warning - walk away!", "That's it!" }

function P.attackBlocked(record, shell, player)
    local pa = PA()
    if type(record) ~= "table" or record.lifecycle ~= "active" or shell == nil then return "inactive" end
    if fn(pa.Speech, "alive") and pa.Speech.alive(shell) ~= true then return "dead" end
    if calmedFor(record, player) ~= nil then return "calmed" end
    if fn(pa.Party, "friendly") and pa.Party.friendly(record, player) == true then return "party" end
    if P.data and P.data.companions[tostring(record.uid)] then return "companion" end
    local fair = pa.ModuleCareful
    if fair and fn(fair, "escalationAllowed") and not fair.escalationAllowed(nowMs()) then return "fairness" end
    local memory = type(record.memory) == "table" and record.memory or {}
    if type(memory.robbery) == "table" then return "robbery" end
    if fn(pa.Relations, "isSelfDefence") then
        local ok, sd = pcall(pa.Relations.isSelfDefence, player, record)
        if ok and sd == true then return "self-defence" end
    end
    return nil
end

local function turnOn(record, shell, player, why)
    local pa = PA()
    local careful = pa.ModuleCareful
    if not fn(careful, "turnGroup") then return false end
    local ok, res = pcall(careful.turnGroup, record, shell, player)
    if ok and res ~= false then
        log("attack: " .. tostring(record.uid) .. " turned hostile (" .. tostring(why) .. ")")
        emit("attack", record, shell, player, why)
        return true
    end
    return false
end

-- straight to attacking (witnessed you kill a close tie, a nemesis arriving)
-- 0.8.12 (Rock List 2): a LAST WARNING first, when a real person would give one (trespassing, told to leave,
-- threatened...): they say it, you get a cue, and you have attackLastWarnSec to walk off (attackLastWarnLeave tiles
-- further away). No warning when nobody would give one: they saw you kill a friend, a nemesis came back for you, a
-- betrayal, a stand-off you already lost (P.lastWarnSkip, matched on the start of `why`). opts.noWarn skips it too.
P.lastWarnSkip = { "saw you kill", "killed ", "nemesis", "betrayal", "called out", "attacked" }
P.lastWarnLines = { "Last warning. Walk away.", "Last chance. Turn around and go.", "I won't say it again. Leave." }
P.lastWarnPending = {}
local function cueSetting(key, default)
    local U = ALifeCues
    local v = nil
    if type(U) == "table" and type(U.setting) == "function" then v = U.setting(key) end
    if v == nil then return default end
    return v
end
function P.lastWarnWanted(why)
    if cueSetting("attackLastWarn", true) == false then return false end
    why = string.lower(tostring(why or ""))
    for _, w in ipairs(P.lastWarnSkip) do if string.sub(why, 1, #w) == w then return false end end
    return true
end
local function flatDist(a, b)
    local ax, ay, bx, by = nil, nil, nil, nil
    pcall(function() ax, ay, bx, by = a:getX(), a:getY(), b:getX(), b:getY() end)
    if ax == nil or bx == nil then return nil end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end
local function sayLine(shell, text)
    local pa = PA() or {}
    if fn(pa.Speech, "say") then
        local ok, shown = pcall(pa.Speech.say, shell, text, { chat = true })
        if ok and shown then return true end
    end
    pcall(function() shell:Say(text) end)
end
-- the cue: everyone's hooks (A-Life Talk's AI line), else the stock line; the player gets a red note (ALifeCmd)
function P.lastWarnCue(record, shell, player, why)
    local handled = false
    for _, h in ipairs(P.hooks.lastWarn or {}) do
        local ok, r = pcall(h, record, shell, player, why)
        if ok and r == true then handled = true end
    end
    if not handled then sayLine(shell, P.lastWarnLines[(math.floor(nowMs() / 1000) % #P.lastWarnLines) + 1]) end
    if type(ALifeCmd) == "table" and fn(ALifeCmd, "reply") then
        local name = nil
        pcall(function() name = PA().Names.of(record) end)
        pcall(ALifeCmd.reply, player, "lastWarn", { uid = tostring(record.uid), name = name and tostring(name) or nil,
            why = string.sub(tostring(why or ""), 1, 60), sec = tonumber(cueSetting("attackLastWarnSec", 5)) or 5 })
    end
end
function P.attackNow(uid, player, why, opts)
    if not P.settings.attack.player then return false end
    local pa = PA()
    local record = readRec(uid)
    local shell = record and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(record.uid) or nil
    if record == nil or shell == nil or player == nil then return false end
    local blocked = P.attackBlocked(record, shell, player)
    if blocked and blocked ~= "calmed" then return false, blocked end
    local lk = tostring(record.uid) .. "|" .. tostring(playerKey(player))
    local fromWarn = type(opts) == "table" and opts.fromWarn
    if P.lastWarnPending[lk] ~= nil and not fromWarn then return false, "warned" end
    if not fromWarn and not (type(opts) == "table" and opts.noWarn) and P.lastWarnWanted(why) then
        P.lastWarnPending[lk] = { uid = tostring(record.uid), player = player, why = why, atMs = nowMs(), dist = flatDist(shell, player) }
        P.lastWarnCue(record, shell, player, why)
        log("last warning: " .. tostring(record.uid) .. " (" .. tostring(why) .. "), " .. tostring(cueSetting("attackLastWarnSec", 5)) .. " s to walk away")
        return false, "warned"
    end
    if blocked == "calmed" then P.endCalm(record.uid, playerKey(player), why or "attack", true) end
    return turnOn(record, shell, player, why or "attack now")
end
-- the warning runs out: they walked off (called off), they calmed / died / went home (dropped), or it happens
function P.lastWarnTick()
    local now = nowMs()
    local sec = tonumber(cueSetting("attackLastWarnSec", 5)) or 5
    local leave = tonumber(cueSetting("attackLastWarnLeave", 6)) or 6
    -- the clock stops while the game is paused (vanilla isGamePaused, client-side; nil on a server = never paused)
    local paused = false
    pcall(function() paused = type(isGamePaused) == "function" and isGamePaused() == true end)
    local gap = now - (P.lastWarnTickAt or now)
    P.lastWarnTickAt = now
    local done = {}
    for lk, w in pairs(P.lastWarnPending) do done[#done + 1] = { lk = lk, w = w }; if paused then w.atMs = w.atMs + gap end end
    if paused then return end
    for _, e in ipairs(done) do
        local lk, w = e.lk, e.w
        local pa = PA() or {}
        local record = readRec(w.uid)
        local shell = record and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(record.uid) or nil
        local d = shell and flatDist(shell, w.player) or nil
        local dead = false
        pcall(function() dead = w.player:isDead() == true end)
        local blocked = "gone"
        if record ~= nil and shell ~= nil then blocked = P.attackBlocked(record, shell, w.player) end
        if dead or (blocked ~= nil and blocked ~= "calmed") then
            P.lastWarnPending[lk] = nil
        elseif d and w.dist and d >= w.dist + leave then
            P.lastWarnPending[lk] = nil
            P.ladderCool[lk] = now + P.settings.attack.cooldownMs
            emit("lastWarnHeeded", record, shell, w.player, w.why)
            if type(ALifeCmd) == "table" and fn(ALifeCmd, "reply") then pcall(ALifeCmd.reply, w.player, "lastWarnOff", { uid = w.uid, heeded = true }) end
            log("last warning heeded: " .. w.uid .. " (you walked away)")
        elseif now - w.atMs >= sec * 1000 then
            P.lastWarnPending[lk] = nil
            P.attackNow(w.uid, w.player, w.why, { fromWarn = true })
        end
    end
end
function P.lastWarnOn(uid, player)
    return P.lastWarnPending[tostring(uid) .. "|" .. tostring(playerKey(player))] ~= nil
end

local function say(shell, text)
    local pa = PA()
    if fn(pa.Speech, "say") then
        local ok, shown = pcall(pa.Speech.say, shell, text, { chat = true })
        if ok and shown then return true end
    end
    pcall(function() shell:Say(text) end)
end

function P.attackTick(player)
    local s = P.settings.attack
    if not s.player or player == nil then return end
    local pa = PA()
    local talk, op = pa.Talk, pa.NpcOpinion
    if not (fn(talk, "listeners") and fn(op, "valueOf") and fn(pa.Relations, "playerStance")) then return end
    local key = playerKey(player)
    if key == nil then return end
    local now = nowMs()
    local seen = {}
    for _, l in ipairs(talk.listeners(player, s.rangeTiles)) do
        local record, shell = l.record, l.shell
        local uid = tostring(record.uid)
        local lk = uid .. "|" .. key
        seen[lk] = true
        local v = op.valueOf(record, player) or 0
        local stance = pa.Relations.playerStance(record, player)
        local st = P.ladder[lk]
        if stance == "hostile" then
            P.ladder[lk] = nil
        elseif v > s.playerAt then
            if st ~= nil then P.ladder[lk] = nil; P.ladderCool[lk] = now + s.cooldownMs end
        elseif (P.ladderCool[lk] or 0) <= now and P.attackBlocked(record, shell, player) == nil then
            if st == nil then
                st = { step = 0, atMs = now - s.warnMs }
                P.ladder[lk] = st
            end
            if now - st.atMs >= s.warnMs then
                st.step, st.atMs = st.step + 1, now
                if st.step == 1 then
                    pcall(talk.escalate, record, shell, player, { stance = stance }, now) -- A-Life: wary of you
                end
                if st.step < 3 then
                    local handled = false
                    for _, h in ipairs(P.hooks.warn) do
                        local ok, r = pcall(h, record, shell, player, st.step, v)
                        if ok and r == true then handled = true end
                    end
                    if not handled then say(shell, P.warnLines[st.step]) end
                    if st.step == 2 and type(ALifeCmd) == "table" and fn(ALifeCmd, "reply") then -- 0.8.12: the last one, on screen too
                        local name = nil
                        pcall(function() name = pa.Names.of(record) end)
                        pcall(ALifeCmd.reply, player, "lastWarn", { uid = uid, name = name and tostring(name) or nil, why = "opinion", sec = math.floor(s.warnMs / 1000) })
                    end
                    log("attack ladder: " .. uid .. " warning " .. st.step .. " (opinion " .. tostring(v) .. ")")
                else
                    P.ladder[lk] = nil
                    turnOn(record, shell, player, "opinion " .. tostring(v))
                end
            end
        end
    end
    for lk in pairs(P.ladder) do if not seen[lk] then P.ladder[lk] = nil end end
end

-- NPC vs NPC feud (A-Life Talk calls this when a pair score drops to npcAt or a nemesis forms)
function P.npcFeud(aUid, bUid, why, hrs, mutual)
    if not P.settings.attack.npc then return false end
    return P.setPairStance(aUid, bUid, "hostile", hrs or P.settings.attack.npcHours, why or "feud", mutual and "hostile" or nil)
end

----------------------------------------------------------------------------------------------------------------
-- 6) NEMESIS: a grudge that comes back (A-Life Talk keeps the grudge score; this file moves the person)
----------------------------------------------------------------------------------------------------------------
-- Tiers: 1 Resentful (no guns - fists or whatever melee they carry), 2 Vengeful (melee weapon; given a bat if they
-- have none), 3 Murderous (anything, guns first). The return trip uses A-Life's own Revenge system: a revenge
-- contract on the nemesis' offline squad (same record, same face) with backup by tier; A-Life's Revenge.tick sends
-- them to your last known position. Revenge.owed is wrapped so A-Life does not "forgive" a personal nemesis just
-- because their faction's reputation with you isn't hostile.
function P.nemesisTier(uid)
    local d = P.data
    local n = d and d.nemesis[tostring(uid)]
    return n and tonumber(n.tier) or 0, n
end

function P.setNemesis(uid, tier, player, why)
    if not P.settings.nemesis.enabled then return false end
    local d = P.store()
    uid = tostring(uid)
    if tier == nil or tier <= 0 then d.nemesis[uid] = nil; return true end
    local n = d.nemesis[uid] or {}
    local key = player and playerKey(player) or n.key
    n.tier, n.key, n.why = math.max(1, math.min(3, tier)), key, why and string.sub(tostring(why), 1, 80) or n.why
    n.setH = hours()
    d.nemesis[uid] = n
    return true
end

-- schedule the visit: works when the nemesis is in an offline A-Life squad
function P.scheduleRevenge(uid, player)
    local pa = PA()
    local d = P.store()
    local n = d.nemesis[tostring(uid)]
    local record = readRec(uid)
    local ledger = pa and pa.SquadLedger
    if n == nil or record == nil or record.lifecycle == "dead" or not (fn(ledger, "read") and fn(ledger, "update")) then return false, "no squad api" end
    local memory = type(record.memory) == "table" and record.memory or {}
    if memory.squadId == nil then return false, "not in a squad" end
    local q = ledger.read(memory.squadId)
    if type(q) ~= "table" or q.state ~= "offline" then return false, "squad not offline" end
    if type(q.revenge) == "table" then return true, "already sworn" end
    local px, py = pos(player)
    local h = hours()
    local due = h + 0.25 -- the grudge already waited (A-Life Talk schedules the visit 12-36 h later); go soon
    local contract = { playerKey = n.key or playerKey(player), dueHours = due, lastKnown = { x = px or q.x, y = py or q.y },
        backupSize = math.min(4, (P.settings.nemesis.backup[n.tier] or 0) + (tonumber(n.visits) or 0)), casualties = 1,
        wave = 1 + (tonumber(n.visits) or 0), nemesis = tostring(uid) } -- v1.2: escalating returns
    local ok = pcall(ledger.update, q.id, q.revision, function(row) row.revenge = contract end, true)
    if ok then
        n.sent, n.sentH = true, h
        P.owedFactions[tostring(q.factionId) .. "|" .. tostring(contract.playerKey)] = h + 72
        log("nemesis: revenge contract for " .. tostring(uid) .. " (tier " .. tostring(n.tier) .. ", backup " .. tostring(contract.backupSize) .. ")")
        return true
    end
    return false, "ledger update failed"
end
P.owedFactions = {}

-- v1.2: a lie that sets a real ambush. An offline A-Life squad of the liar's faction (else any offline squad hostile to
-- the player within 1500 tiles) gets A-Life's own revenge contract with lastKnown = the false spot, due in ~2 hours,
-- so a real crew is waiting / hunting there. Uses the same SquadLedger contract the nemesis visits use.
function P.ambushAt(uid, x, y, player)
    local pa = PA()
    local ledger = pa and pa.SquadLedger
    local record = readRec(uid)
    if record == nil or x == nil or not (fn(ledger, "read") and fn(ledger, "update")) then return false end
    local d = P.store()
    d.ambush = type(d.ambush) == "table" and d.ambush or {}
    if d.ambush[tostring(uid)] and hours() - (d.ambush[tostring(uid)].h or 0) < 48 then return true end
    local fid = record.factionId
    local best, bd = nil, 1500 * 1500
    local function consider(q)
        if type(q) ~= "table" or q.state ~= "offline" or type(q.revenge) == "table" then return end
        local dd = ((tonumber(q.x) or 1e9) - x) ^ 2 + ((tonumber(q.y) or 1e9) - y) ^ 2
        local mine = fid ~= nil and q.factionId == fid
        if mine then dd = dd / 4 end
        if (mine or q.hostile == true or q.raider == true) and dd < bd then best, bd = q, dd end
    end
    pcall(function()
        if fn(ledger, "eachLive") then ledger.eachLive(consider)
        elseif fn(ledger, "list") then for _, q in ipairs(ledger.list()) do consider(q) end end
    end)
    if best == nil then
        local memory = type(record.memory) == "table" and record.memory or {}
        if memory.squadId then consider(ledger.read(memory.squadId)) end
    end
    if best == nil then return false end
    local q = ledger.read(best.id) or best
    local contract = { playerKey = playerKey(player), dueHours = hours() + 2, lastKnown = { x = x, y = y }, backupSize = 1,
        casualties = 1, wave = 1, ambush = tostring(uid) }
    local ok = pcall(ledger.update, q.id, q.revision, function(row) row.revenge = contract end, true)
    if ok then
        d.ambush[tostring(uid)] = { h = hours(), x = x, y = y, squad = q.id }
        log("ambush: squad " .. tostring(q.id) .. " waits at " .. tostring(math.floor(x)) .. "," .. tostring(math.floor(y)) .. " (lie by " .. tostring(uid) .. ")")
    end
    return ok
end

-- weapon tiers: wrap Combat.preferredWeapon (A-Life's weapon choice each combat step)
function P.weaponFor(shell, weapon, target, wanted)
    local pa = PA()
    if target == nil or not (type(instanceof) == "function" and instanceof(target, "IsoPlayer")) then return nil, false end
    local uid = nil
    pcall(function() uid = pa.Speech.variable(shell, "ALifeUID") end)
    local tier = uid and P.nemesisTier(uid) or 0
    if tier == 0 or tier >= 3 then return nil, false end
    local C, Wp = pa.Combat, pa.Weapons
    local isRanged = function(w) return w ~= nil and fn(C, "isRanged") and C.isRanged(w) end
    if isRanged(wanted) or isRanged(weapon) then
        local melee = fn(Wp, "bestMelee") and Wp.bestMelee(shell) or nil
        if melee ~= nil and melee ~= weapon then return melee, true end
        return nil, true -- keep what they hold rather than draw a gun
    end
    return nil, false
end

function P.armNemesis(shell, tier)
    if tier ~= 2 or shell == nil then return end
    local pa = PA()
    local has = fn(pa.Weapons, "bestMelee") and pa.Weapons.bestMelee(shell) or nil
    if has == nil then pcall(function() shell:getInventory():AddItem("Base.BaseballBat") end) end
end

----------------------------------------------------------------------------------------------------------------
-- 6) v1.2: SHELTER, GROUP-UP, LEADER COMMANDS, PLAYER ORDERS, GESTURES
-- Every movement goes through A-Life's own DecisionLoop.setOrder (hold / follow orders, the same call A-Life's
-- squad leader uses), so A-Life's pathing, door handling, combat rules and order expiry all apply unchanged.
-- Gestures are A-Life's own animation presets (Animations.apply). Orders we gave are tracked and released by us.
----------------------------------------------------------------------------------------------------------------
P.settings.shelter = { enabled = true, tickMs = 3000, radius = 26, playerTiles = 70, night = true, storm = true, cold = true,
    horde = true, coldC = -8, hordeN = 12, hordeTiles = 22, holdMs = 90000, retryMs = 120000, perTick = 6 }
P.settings.orders = { enabled = true, holdMs = 120000, fallBackTiles = 12, moveUpTiles = 9, coverTiles = 3, regroupTiles = 3,
    groupUpTiles = 8, commandGapMs = 25000, dangerTiles = 18 }
P.settings.gestures = { enabled = true, gapMs = 5000 }
P.shelterBias = nil  -- optional hook (A-Life Talk): function(uid, why) -> multiplier (0 = never, 1 = normal, 2 = eager)
P.obeyChance = nil   -- optional hook: function(memberUid, leaderUid|"player", kind) -> 0..100
P.gestureAt = {}

local function decisions() local pa = PA(); return pa and pa.DecisionLoop or nil end
local function shellOf(uid) local pa = PA(); return fn(pa and pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil end
local function engaged(uid)
    local d = decisions()
    local st = d and type(d.states) == "table" and d.states[tostring(uid)] or nil
    return st ~= nil and (st.kind == "combat" or st.kind == "retreat" or st.kind == "recovering")
end
local function outdoors(shell)
    local out = true
    pcall(function() local sq = shell:getCurrentSquare(); if sq ~= nil then out = sq:isOutside() == true end end)
    return out
end
local function busyStance(record)
    local st = type(record) == "table" and type(record.memory) == "table" and record.memory.stance or nil
    return st == "blockade" or st == "garrison" or st == "holdout" or st == "occupy_high" or st == "shelter" or st == "visit"
        or st == "walkWith"
end
P.busyStance = busyStance

-- A-Life order (hold at anchor / follow the player); 'source' leader = A-Life walks them to the anchor
function P.order(uid, kind, anchor, ms, tag, player)
    local d, rec = decisions(), readRec(uid)
    if d == nil or not fn(d, "setOrder") or rec == nil then return false, "no_decisions" end
    local order = { kind = kind, anchor = anchor, untilMs = ms and (nowMs() + ms) or nil, quiet = true,
        source = kind == "follow" and "player" or "leader", player = player }
    local ok, accepted, why = pcall(d.setOrder, tostring(uid), rec.generation, order)
    if not ok then return false, tostring(accepted) end
    if accepted == true then
        local store = P.store()
        store.ordered[tostring(uid)] = { tag = tag or kind, kind = kind, untilMs = order.untilMs, ax = anchor and anchor.x, ay = anchor and anchor.y }
        return true
    end
    return false, why
end
-- release only an order we gave (never one from A-Life, an admin or the player's own A-Life commands)
function P.releaseOrder(uid, tag)
    local d = decisions()
    local mine = P.store().ordered[tostring(uid)]
    if mine == nil or (tag ~= nil and mine.tag ~= tag) then return false end
    P.store().ordered[tostring(uid)] = nil
    local cur = d and type(d.orders) == "table" and d.orders[tostring(uid)] or nil
    if cur ~= nil and (cur.kind == mine.kind) and (mine.ax == nil or (cur.anchor and cur.anchor.x == mine.ax and cur.anchor.y == mine.ay)) then
        d.orders[tostring(uid)] = nil
    end
    return true
end
function P.orderedBy(uid) local o = P.store().ordered[tostring(uid)]; return o and o.tag or nil end

-- A-Life's own animation presets; skipped mid-fight and rate-limited
function P.gesture(uid, id)
    if not P.settings.gestures.enabled then return false end
    local pa = PA()
    local shell = shellOf(uid)
    if shell == nil or engaged(uid) or not fn(pa and pa.Animations, "apply") then return false end
    local now = nowMs()
    if now - (P.gestureAt[tostring(uid)] or -1e12) < P.settings.gestures.gapMs then return false end
    if fn(pa.Animations, "presetOf") and pa.Animations.presetOf(id) == nil then return false end
    local ok, applied = pcall(pa.Animations.apply, shell, id)
    if ok and applied ~= false then P.gestureAt[tostring(uid)] = now; return true end
    return false
end

-- a free indoor square near (x, y) on the ground floor: rings outward, the actor's own haven first
function P.indoorSpot(x, y, z, radius, record)
    local pa = PA()
    local cell = type(getCell) == "function" and getCell() or nil
    if cell == nil or x == nil then return nil end
    pcall(function()
        if record and fn(pa.Havens, "homeOf") then
            local home = pa.Havens.homeOf(record)
            if type(home) == "table" and home.x and home.y and (home.x - x) ^ 2 + (home.y - y) ^ 2 <= (radius * 2) ^ 2 then
                local sq = cell:getGridSquare(math.floor(home.x), math.floor(home.y), math.floor(home.z or 0))
                if sq ~= nil and not sq:isOutside() then x, y = home.x, home.y end
            end
        end
    end)
    for r = 0, radius, 2 do
        local steps = r == 0 and 1 or math.max(8, math.floor(r * 1.5))
        for i = 0, steps - 1 do
            local a = i * 2 * math.pi / steps
            local sx, sy = math.floor(x + math.cos(a) * r), math.floor(y + math.sin(a) * r)
            local spot = nil
            pcall(function()
                local sq = cell:getGridSquare(sx, sy, math.floor(z or 0))
                if sq ~= nil and not sq:isOutside() and sq:isFree(false) and sq:getRoom() ~= nil then
                    spot = { x = sx + 0.5, y = sy + 0.5, z = math.floor(z or 0) }
                end
            end)
            if spot then return spot end
        end
    end
    return nil
end

function P.weatherNow()
    local w = { rain = 0, snow = 0, wind = 0, storm = false, temp = 15, dark = false }
    local pa = PA()
    pcall(function() if fn(pa.ActivityPlanner, "weather") then local x = pa.ActivityPlanner.weather(); for k, v in pairs(x) do w[k] = v end end end)
    pcall(function() local c = getClimateManager(); if c and c.getTemperature then w.temp = tonumber((c:getTemperature())) or w.temp end end)
    pcall(function() local c = getClimateManager(); if c and c.getDayLightStrength then w.dark = (tonumber((c:getDayLightStrength())) or 1) < 0.25 end end)
    return w
end
function P.zombiesNear(x, y, tiles)
    local n, cx, cy = 0, 0, 0
    pcall(function()
        local zs = getCell():getZombieList()
        for i = 0, math.min(zs:size(), 600) - 1 do
            local zb = zs:get(i)
            if zb ~= nil and not zb:isDead() then
                local zx, zy = zb:getX(), zb:getY()
                if math.abs(zx - x) <= tiles and math.abs(zy - y) <= tiles then
                    -- v1.3: A-Life's NPCs are IsoZombies too - don't count living people as the dead
                    local person = false
                    local pa = PA()
                    if pa and fn(pa.Speech, "variable") then
                        local v = pa.Speech.variable(zb, "ALifeUID")
                        person = v ~= nil and tostring(v) ~= ""
                    end
                    if not person then n, cx, cy = n + 1, cx + zx, cy + zy end
                end
            end
        end
    end)
    if n > 0 then return n, cx / n, cy / n end
    return 0, nil, nil
end

-- why this actor should get inside now (nil = no reason)
function P.shelterReason(record, shell, w, hod)
    local s = P.settings.shelter
    local x, y = pos(shell)
    if s.horde then
        local n = P.zombiesNear(x, y, s.hordeTiles)
        if n >= s.hordeN then return "horde" end
    end
    if s.storm and (w.storm or (tonumber(w.rain) or 0) > 0.75) then return "storm" end
    if s.cold and ((tonumber(w.snow) or 0) > 0.6 and (tonumber(w.wind) or 0) > 0.5) then return "blizzard" end
    if s.cold and (tonumber(w.temp) or 15) <= s.coldC then return "cold" end
    if s.night and (hod >= 22 or hod < 5) and w.dark then return "night" end
    return nil
end

function P.shelterTick(player)
    local s = P.settings.shelter
    if not s.enabled or player == nil then return end
    local pa = PA()
    local watchdog = pa and pa.Watchdog
    if watchdog == nil or type(watchdog.bindings) ~= "table" then return end
    local store = P.store()
    local w = P.weatherNow()
    local hod = 12
    pcall(function() hod = getGameTime():getHour() end)
    local px, py = pos(player)
    local now = nowMs()
    local n = 0
    for uid, b in pairs(watchdog.bindings) do
        local shell = b and b.shell
        local sh = store.shelter[uid]
        local rec = shell and readRec(uid) or nil
        if rec ~= nil and rec.lifecycle == "active" and px then
            local sx, sy, sz = pos(shell)
            local near = sx and (sx - px) ^ 2 + (sy - py) ^ 2 <= s.playerTiles ^ 2
            local why = near and not engaged(uid) and not busyStance(rec) and P.companionOf(uid) == nil
                and (P.orderedBy(uid) == nil or P.orderedBy(uid) == "shelter") and P.shelterReason(rec, shell, w, hod) or nil
            if why and P.shelterBias then
                local okB, mul = pcall(P.shelterBias, uid, why)
                if okB and tonumber(mul) == 0 then why = nil end
            end
            if sh ~= nil and (why == nil or now >= (sh.untilMs or 0)) then
                if why == nil then
                    P.releaseOrder(uid, "shelter")
                    store.shelter[uid] = nil
                    emit("shelter", "end", uid, sh.why)
                else sh.untilMs = now + s.holdMs; P.order(uid, "hold", { x = sh.x, y = sh.y, z = sh.z }, s.holdMs + 5000, "shelter") end
            elseif sh == nil and why ~= nil and n < s.perTick and outdoors(shell) and now >= (store.shelterRetry[uid] or 0) then
                n = n + 1
                local spot = P.indoorSpot(sx, sy, sz, s.radius, rec)
                if spot and P.order(uid, "hold", spot, s.holdMs + 5000, "shelter") then
                    store.shelter[uid] = { why = why, x = spot.x, y = spot.y, z = spot.z, untilMs = now + s.holdMs }
                    log("shelter: " .. uid .. " heads inside (" .. why .. ")")
                    emit("shelter", "start", uid, why)
                else
                    store.shelterRetry[uid] = now + s.retryMs
                end
            end
        elseif sh ~= nil and (rec == nil or rec.lifecycle ~= "active") then
            store.shelter[uid] = nil
        end
    end
end

-- leader commands: kind = fall_back | cover_me | hold | regroup | move_up; members obey by P.obeyChance
P.commandAt = {}
function P.commandAnchor(kind, leaderShell, memberShell, threatX, threatY, index)
    local o = P.settings.orders
    local lx, ly, lz = pos(leaderShell)
    if lx == nil then return nil end
    local ang = (index or 0) * 1.3
    local function ring(cx, cy, r) return { x = cx + math.cos(ang) * r, y = cy + math.sin(ang) * r, z = math.floor(lz) } end
    if kind == "regroup" or kind == "cover_me" then return ring(lx, ly, kind == "cover_me" and o.coverTiles or o.regroupTiles) end
    if kind == "hold" then local mx, my, mz = pos(memberShell); return mx and { x = mx, y = my, z = math.floor(mz) } or nil end
    local dx, dy = 0, 0
    if threatX then dx, dy = lx - threatX, ly - threatY end
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then dx, dy, d = 1, 0, 1 end
    local t = kind == "fall_back" and o.fallBackTiles or -o.moveUpTiles
    return ring(lx + dx / d * t, ly + dy / d * t, 2)
end
function P.command(leaderUid, kind, members, threatX, threatY)
    if not P.settings.orders.enabled then return {} end
    local leaderShell = shellOf(leaderUid)
    if leaderShell == nil then return {} end
    local out = {}
    for i, uid in ipairs(members or {}) do
        local sh = shellOf(uid)
        if sh ~= nil and tostring(uid) ~= tostring(leaderUid) then
            local chance = 75
            if P.obeyChance then local okC, c = pcall(P.obeyChance, uid, leaderUid, kind); if okC and tonumber(c) then chance = tonumber(c) end end
            local roll = (ZombRand and ZombRand(100)) or math.random(0, 99)
            local obeyed = roll < chance
            if obeyed then
                local anchor = P.commandAnchor(kind, leaderShell, sh, threatX, threatY, i)
                obeyed = anchor ~= nil and P.order(uid, "hold", anchor, kind == "hold" and 45000 or 30000, "cmd:" .. kind) or false
            end
            out[#out + 1] = { uid = tostring(uid), obeyed = obeyed, chance = chance }
        end
    end
    emit("command", tostring(leaderUid), kind, out)
    return out
end

-- group members (loaded) of an actor
function P.groupOf(uid)
    local pa = PA()
    local rec = readRec(uid)
    local gid = rec and type(rec.memory) == "table" and rec.memory.groupId or nil
    local out = {}
    if gid == nil or pa.Watchdog == nil then return out, nil end
    for u, b in pairs(pa.Watchdog.bindings or {}) do
        local r = b and b.shell and readRec(u) or nil
        if r and r.lifecycle == "active" and type(r.memory) == "table" and r.memory.groupId == gid then out[#out + 1] = u end
    end
    table.sort(out)
    return out, gid
end
function P.leaderOf(uid)
    local pa = PA()
    local members, gid = P.groupOf(uid)
    local g = pa.ModuleLeader and type(pa.ModuleLeader.groups) == "table" and gid and pa.ModuleLeader.groups[gid] or nil
    if g and g.leaderUid then return tostring(g.leaderUid), members end
    return members[1], members -- no A-Life leader: the steadiest (first by uid) speaks for the group
end

-- danger -> the group closes up around its leader and the leader calls a command (A-Life's own leader still runs)
function P.groupTick(player)
    if not P.settings.orders.enabled or player == nil then return end
    local pa = PA()
    if pa.Watchdog == nil then return end
    local px, py = pos(player)
    local seen = {}
    local now = nowMs()
    for uid, b in pairs(pa.Watchdog.bindings or {}) do
        local rec = b and b.shell and readRec(uid) or nil
        local gid = rec and type(rec.memory) == "table" and rec.memory.groupId or nil
        if gid and not seen[gid] and px then
            seen[gid] = true
            local leader, members = P.leaderOf(uid)
            local lsh = leader and shellOf(leader)
            local lx, ly = pos(lsh)
            if lx and #members >= 2 and (lx - px) ^ 2 + (ly - py) ^ 2 <= 60 ^ 2 and now >= (P.commandAt[gid] or 0) then
                local n, zx, zy = P.zombiesNear(lx, ly, P.settings.orders.dangerTiles)
                local kind = nil
                if n >= P.settings.shelter.hordeN then kind = "fall_back"
                elseif n >= 4 and engaged(leader) then kind = "cover_me"
                elseif n >= 4 then kind = "hold"
                elseif n == 0 and (P.lastDanger or {})[gid] and now - P.lastDanger[gid] < 60000 then kind = "regroup"; P.lastDanger[gid] = nil
                elseif n > 0 and n < 4 and engaged(leader) then kind = "move_up" end
                if n > 0 then P.lastDanger = P.lastDanger or {}; P.lastDanger[gid] = now end
                -- spread-out group in danger: everyone more than groupUpTiles away is called in
                if kind ~= nil then
                    local list = {}
                    for _, m in ipairs(members) do
                        if m ~= leader and not engaged(m) and P.companionOf(m) == nil and P.orderedBy(m) ~= "player" then list[#list + 1] = m end
                    end
                    if #list > 0 then
                        P.commandAt[gid] = now + P.settings.orders.commandGapMs
                        P.command(leader, kind, list, zx, zy)
                    end
                end
            end
        end
    end
end

-- the player's orders to their recruits / companions (A-Life Talk parses the words)
function P.playerOrder(uid, kind, player)
    local comp = P.companionOf(uid)
    local sh = shellOf(uid)
    if sh == nil then return false, "not_here" end
    local px, py, pz = pos(player)
    local o = P.settings.orders
    if kind == "follow" then
        P.releaseOrder(uid)
        if comp then comp.order = nil; return true end
        return P.order(uid, "follow", nil, o.holdMs, "player", player)
    end
    local anchor = nil
    if kind == "hold" or kind == "guard" then local x, y, z = pos(sh); anchor = { x = x, y = y, z = math.floor(z) }
    elseif kind == "regroup" or kind == "cover_me" then anchor = { x = px + 1, y = py + 1, z = math.floor(pz) }
    elseif kind == "fall_back" then
        local fx, fy = 0, 1
        pcall(function() local f = player:getForwardDirection(); fx, fy = f:getX(), f:getY() end)
        anchor = { x = px - fx * o.fallBackTiles, y = py - fy * o.fallBackTiles, z = math.floor(pz) }
    elseif kind == "move_up" then
        local fx, fy = 0, 1
        pcall(function() local f = player:getForwardDirection(); fx, fy = f:getX(), f:getY() end)
        anchor = { x = px + fx * o.moveUpTiles, y = py + fy * o.moveUpTiles, z = math.floor(pz) }
    elseif kind == "shelter" then
        local x, y, z = pos(sh)
        anchor = P.indoorSpot(x, y, z, P.settings.shelter.radius, readRec(uid))
        if anchor == nil then return false, "no_shelter" end
    end
    if anchor == nil then return false, "unknown" end
    if comp then
        comp.order = { kind = kind, x = anchor.x, y = anchor.y, z = anchor.z, untilMs = nowMs() + o.holdMs }
        return true
    end
    return P.order(uid, "hold", anchor, o.holdMs, "player")
end


----------------------------------------------------------------------------------------------------------------
-- 7) v1.3: WOUND CARE
-- Uses A-Life's own wound system (Health / Wounds / ModuleHealing) exactly the way A-Life itself does:
--   * treatWithItem: an NPC dresses its wound with a bandage / rags the player gave it (A-Life's Dress Wounds flow:
--     HealToFraction + HealDoneAtMs + the heal pose; Health.tick then runs Health.heal, which bandages bleeding wounds
--     and splints fractures). A Splint is applied like A-Life's own "Splint" menu (Wounds.splint + applyInjuries +
--     persistInjuries). A downed NPC is treated at once, like A-Life's "Treat wounds" by another person.
--   * treatOther: a medic gives a comrade one of their own dressings and treats them (same heal as above).
--   * woundRest: sit down for a few minutes (A-Life hold order where they stand + the sit_ground preset).
--   * woundGesture: clutch the hurt part (A-Life's heal_arm / heal_head / heal_body / heal_bandage presets).
--   * addFallWound: A-Life knows "fall" wounds but nothing records them; a fall becomes Health.addInjury(.., "fall", "limb").
----------------------------------------------------------------------------------------------------------------
P.settings.wounds = { enabled = true, retryMs = 120000, finishGraceMs = 3000 }
P.treatKitFraction = { ["Base.AlcoholBandage"] = 0.7, ["Base.Bandage"] = 0.65, ["Base.AlcoholRippedSheets"] = 0.55, ["Base.RippedSheets"] = 0.5 }
P.dressing = {} -- uid -> { t = item type, doneAt = ms }
P.pendingTreat = {} -- uid -> { t, untilMs }

local function health() local pa = PA(); return pa and pa.Health or nil end
local function woundList(shell, data)
    local H = health()
    if H == nil or not fn(H, "injuriesOf") then return nil end
    local ok, list = pcall(H.injuriesOf, shell, data)
    return ok and list or nil
end
local function openBleeding(list)
    local pa, n = PA(), 0
    for _, injury in ipairs(list or {}) do
        local kind = pa.Wounds and pa.Wounds.kinds and pa.Wounds.kinds[injury.k] or nil
        if kind ~= nil and kind.bleed ~= nil and injury.b ~= true then n = n + 1 end
    end
    return n
end
local function unsplinted(list)
    for _, injury in ipairs(list or {}) do if injury.k == "fracture" and injury.sp ~= true then return true end end
    return false
end
local function takeItem(shell, fullType)
    local item = nil
    pcall(function() item = shell:getInventory():getFirstTypeRecurse(fullType) end)
    return item
end
local function dropItem(shell, item)
    if item == nil then return end
    pcall(function() local c = item:getContainer() or shell:getInventory(); c:Remove(item) end)
end

-- returns ok, how ("dressing" | "treated" | "splinted" | "later" | "not_needed" | "no_item" | "no_health")
function P.treatWithItem(uid, fullType, by)
    if not P.settings.wounds.enabled then return false, "off" end
    local pa, H = PA(), health()
    local shell = shellOf(uid)
    if shell == nil then return false, "not_here" end
    if H == nil or H.enabled ~= true or not fn(H, "heal") then return false, "no_health" end
    local data = shell:getModData()
    local list = woundList(shell, data) or {}
    -- 0.7.2.1: A-Life 1.5 downed NPCs bleed out unless A-Life marks them aided; Health.heal alone left them down
    -- (a splint keeps the old path: A-Life's own splint on a downed NPC doesn't get them up either)
    if data.ProjectALifeInjured == "down" and P.treatKitFraction[fullType] ~= nil
            and pa.Injury ~= nil and fn(pa.Injury, "recover") then
        local fraction = P.treatKitFraction[fullType]
        local R = pa.InjuryRules
        if R ~= nil and fn(R, "settings") then -- same floor A-Life's "Stop the bleeding" uses
            local okR, rs = pcall(R.settings)
            if okR and type(rs) == "table" and tonumber(rs.aidFraction) then fraction = math.max(fraction, tonumber(rs.aidFraction)) end
        end
        fraction = math.min(0.9, fraction)
        local item = takeItem(shell, fullType)
        if item == nil then return false, "no_item" end
        dropItem(shell, item)
        pcall(H.heal, shell, data)
        local ok, err = pcall(pa.Injury.recover, shell, data, nowMs(), "aided", fraction, true)
        if not ok then
            if not P._recoverFailLogged then P._recoverFailLogged = true; log("wounds: A-Life Injury.recover failed: " .. tostring(err)) end
            return true, "treated"
        end
        log("wounds: " .. tostring(uid) .. " (down) aided with " .. fullType .. " through A-Life")
        return true, "treated"
    end
    local item = takeItem(shell, fullType)
    if item == nil then return false, "no_item" end
    local now = nowMs()
    if fullType == "Base.Splint" then
        if not unsplinted(list) then return false, "not_needed" end
        pa.Wounds.splint(list)
        pcall(H.applyInjuries, data, list, H.worldHours())
        pcall(H.persistInjuries, data)
        dropItem(shell, item)
        P.gesture(uid, "heal_bandage")
        log("wounds: " .. tostring(uid) .. " splinted a fracture")
        return true, "splinted"
    end
    local fraction = P.treatKitFraction[fullType]
    if fraction == nil then return false, "not_a_dressing" end
    if openBleeding(list) == 0 and data.ProjectALifeBleedOutAtMs == nil then return false, "not_needed" end
    if fn(H, "downedHolds") and H.downedHolds(data.ProjectALifeDownedUntilMs, now) then
        data.ProjectALifeHealToFraction = fraction -- A-Life's "Treat wounds" by someone else
        dropItem(shell, item)
        H.heal(shell, data)
        log("wounds: " .. tostring(uid) .. " (down) treated with " .. fullType)
        return true, "treated"
    end
    local healing = pa.ModuleHealing
    if data.ProjectALifeHealDoneAtMs ~= nil or (healing and fn(healing, "engaged") and healing.engaged(data, now)) then
        P.pendingTreat[tostring(uid)] = { t = fullType, untilMs = now + P.settings.wounds.retryMs }
        return true, "later"
    end
    local base = (fullType == "Base.RippedSheets" or fullType == "Base.AlcoholRippedSheets") and "Base.RippedSheets" or "Base.Bandage"
    local duration = (healing and fn(healing, "durationFor") and healing.durationFor(base)) or 4200
    data.ProjectALifeHealToFraction = fraction
    data.ProjectALifeHealDoneAtMs = now + duration
    data.ProjectALifeHandsBusyUntilMs = now + duration + 1000
    pcall(function() shell:setPrimaryHandItem(item) end)
    pcall(function()
        local pose = (healing and fn(healing, "poseFor") and healing.poseFor(data)) or "heal_arm"
        pa.Animations.apply(shell, pose)
    end)
    pcall(function() shell:setMoving(false) end)
    P.dressing[tostring(uid)] = { t = fullType, doneAt = now + duration }
    log("wounds: " .. tostring(uid) .. " dresses the wound with " .. fullType .. " (" .. duration .. " ms)")
    return true, "dressing"
end

-- a medic patches up a comrade with one of the medic's own dressings
function P.treatOther(medicUid, patientUid)
    if not P.settings.wounds.enabled then return false end
    local pa, H = PA(), health()
    local ms, ps = shellOf(medicUid), shellOf(patientUid)
    if ms == nil or ps == nil or H == nil or H.enabled ~= true or not fn(H, "heal") then return false end
    if engaged(medicUid) then return false end
    local mx, my = pos(ms)
    local qx, qy = pos(ps)
    if mx == nil or qx == nil or (mx - qx) ^ 2 + (my - qy) ^ 2 > 16 * 16 then return false end
    local data = ps:getModData()
    local list = woundList(ps, data) or {}
    local item, kind = nil, nil
    if unsplinted(list) then item = takeItem(ms, "Base.Splint"); kind = item and "Base.Splint" or nil end
    if item == nil and (openBleeding(list) > 0 or data.ProjectALifeBleedOutAtMs ~= nil) then
        for _, t in ipairs({ "Base.AlcoholBandage", "Base.Bandage", "Base.AlcoholRippedSheets", "Base.RippedSheets" }) do
            item = takeItem(ms, t)
            if item then kind = t; break end
        end
    end
    if item == nil then return false end
    dropItem(ms, item)
    if kind == "Base.Splint" then
        pa.Wounds.splint(list)
        pcall(H.applyInjuries, data, list, H.worldHours())
        pcall(H.persistInjuries, data)
    else
        data.ProjectALifeHealToFraction = P.treatKitFraction[kind]
        H.heal(ps, data)
    end
    pcall(function() ms:faceThisObject(ps) end)
    P.gestureAt[tostring(medicUid)] = nil
    P.gesture(medicUid, "heal_bandage")
    log("wounds: medic " .. tostring(medicUid) .. " treated " .. tostring(patientUid) .. " with " .. kind)
    return true, kind
end

function P.woundRest(uid, ms, why)
    if not P.settings.wounds.enabled then return false end
    local sh = shellOf(uid)
    local r = readRec(uid)
    if sh == nil or r == nil or engaged(uid) or P.companionOf(uid) or busyStance(r) or P.orderedBy(uid) ~= nil then return false end
    local x, y, z = pos(sh)
    local ok = P.order(uid, "hold", { x = x, y = y, z = math.floor(z or 0) }, ms or 240000, "rest")
    if ok then P.gestureAt[tostring(uid)] = nil; P.gesture(uid, "sit_ground") end
    return ok
end

P.clutchFor = { arm = "heal_arm", head = "heal_head", torso = "heal_body", leg = "heal_bandage" }
function P.woundGesture(uid, region)
    return P.gesture(uid, P.clutchFor[region or ""] or "breathe")
end

function P.addFallWound(uid)
    local H = health()
    local sh = shellOf(uid)
    if sh == nil or H == nil or H.enabled ~= true or not fn(H, "addInjury") then return nil end
    local ok, part, kind, sev = pcall(H.addInjury, sh, sh:getModData(), "fall", "limb")
    if ok then return part, kind, sev end
    return nil
end

function P.woundTick()
    if not P.settings.wounds.enabled then return end
    local H = health()
    if H == nil then return end
    local now = nowMs()
    for uid, d in pairs(P.dressing) do
        local sh = shellOf(uid)
        if sh == nil then P.dressing[uid] = nil
        elseif now >= d.doneAt + P.settings.wounds.finishGraceMs then
            local data = sh:getModData()
            if data.ProjectALifeHealDoneAtMs ~= nil then -- A-Life's tick did not run for this shell: finish it the same way
                data.ProjectALifeHealDoneAtMs = nil
                pcall(H.heal, sh, data)
            end
            local held = nil
            pcall(function() held = sh:getPrimaryHandItem() end)
            if held ~= nil then
                local t = ""
                pcall(function() t = tostring(held:getFullType()) end)
                if t == d.t then pcall(function() sh:setPrimaryHandItem(nil) end); dropItem(sh, held) end
            end
            P.dressing[uid] = nil
        end
    end
    for uid, q in pairs(P.pendingTreat) do
        if now > q.untilMs then P.pendingTreat[uid] = nil
        else
            local ok, done, how = pcall(P.treatWithItem, uid, q.t)
            if not ok or how ~= "later" then P.pendingTreat[uid] = nil end
        end
    end
end


----------------------------------------------------------------------------------------------------------------
-- 8) v1.3: PAUSE AND LISTEN, LEAVE, FAKE NAMES, ACTIVITIES, SHELTER CARE
--   * pauseHostile: "Wait! Don't shoot!" - a hostile NPC halts for a few seconds: Relations.hostileToPlayer answers
--     false (playerStance "careful") while the pause lasts, A-Life's DecisionLoop is put in a short idle (its own
--     stopForTalk + an "idle_alert" state, the same shape A-Life uses for a startled stop) and faces you. Hitting
--     them ends it at once; when it runs out A-Life's hostility simply applies again (unless calmed meanwhile).
--   * holdFriendly / resumeFriendly: A-Life's own Talk.hold / Talk.releaseHold (stop, face the player) + our
--     companions wait instead of following.
--   * leaveArea: A-Life hold order at a spot outside a building / area (A-Life walks them there).
--   * fake names: wraps Names.shown - while an NPC lied about its name to you, the overhead name is the lie.
--   * activities: A-Life hold order at the activity spot + A-Life animation presets; released the moment anything
--     more important happens (combat, zombies, hostility, other orders, companion, shelter, talk-pause).
--   * shelter care: close / lock outside doors, close curtains (A-Life's OutpostBuilder.closeSheet), lights off at
--     night, board windows with A-Life's Fortify.board when the NPC carries planks + nails + a hammer.
----------------------------------------------------------------------------------------------------------------
P.settings.pause = { enabled = true, maxMs = 12000 }
P.settings.activity = { enabled = true, zombieTiles = 12, tickMs = 1500, reapplyMs = 14000 }
P.settings.shelterCare = { enabled = true, boardMax = 2 }
P.pauses = {}      -- uid|key -> { untilMs, atMs }
P.acts = {}        -- uid -> { kind, untilMs, preset, x, y, z, lastPoseAt, seat }

function P.pausedFor(actor, player)
    if not P.settings.pause.enabled or type(actor) ~= "table" or player == nil then return nil end
    local key = playerKey(player)
    if key == nil then return nil end
    local e = P.pauses[tostring(actor.uid) .. "|" .. key]
    if e == nil then return nil end
    local now = nowMs()
    if now >= e.untilMs then P.pauses[tostring(actor.uid) .. "|" .. key] = nil; return nil end
    if (P.lastHitMs[tostring(actor.uid) .. "|" .. key] or -1e12) > e.atMs then
        P.pauses[tostring(actor.uid) .. "|" .. key] = nil
        log("pause: " .. tostring(actor.uid) .. " - you hit them, pause over")
        return nil
    end
    return e
end

local function stopBody(uid, shell, ms, intent)
    local pa, d = PA(), decisions()
    local now = nowMs()
    local actor = readRec(uid)
    if d ~= nil and actor ~= nil and fn(d, "stopForTalk") and type(d.states) == "table" then
        pcall(function()
            local st = d.stopForTalk(actor, shell, d.states[tostring(uid)], now)
            if type(st) == "table" then st.intent, st.cooldownUntilMs = intent or "idle_alert", now + ms; d.states[tostring(uid)] = st end
        end)
    end
    pcall(function() shell:setMoving(false) end)
end

function P.pauseHostile(uid, player, ms)
    if not P.settings.pause.enabled or not P.installed.relations then return false, "off" end
    local pa = PA()
    local shell, actor = shellOf(uid), readRec(uid)
    local key = playerKey(player)
    if shell == nil or actor == nil or key == nil then return false, "not_here" end
    ms = math.min(P.settings.pause.maxMs, math.max(1000, tonumber(ms) or 4000))
    local now = nowMs()
    P.pauses[tostring(uid) .. "|" .. key] = { untilMs = now + ms, atMs = now }
    pcall(function() pa.Perception.forgetIgnored(tostring(uid)) end)
    pcall(function() if pa.DecisionLoop.passiveQuietAtMs then pa.DecisionLoop.passiveQuietAtMs[tostring(uid)] = nil end end)
    stopBody(uid, shell, ms, "idle_alert")
    pcall(function() pa.Speech.face(shell, player) end)
    log("pause: " .. tostring(uid) .. " holds fire for " .. ms .. " ms")
    emit("pause", tostring(uid), player, ms)
    return true
end
function P.endPause(uid, player, why)
    local key = playerKey(player)
    if key == nil then return false end
    local had = P.pauses[tostring(uid) .. "|" .. key] ~= nil
    P.pauses[tostring(uid) .. "|" .. key] = nil
    if had then log("pause: " .. tostring(uid) .. " ended (" .. tostring(why) .. ")") end
    return had
end

function P.holdFriendly(uid, player, ms)
    local pa = PA()
    local shell, actor = shellOf(uid), readRec(uid)
    if shell == nil or actor == nil then return false end
    local now = nowMs()
    local comp = P.companionOf(uid)
    if comp then comp.waitUntilMs = now + ms end
    if P.acts[tostring(uid)] then P.activityStop(uid, "asked to wait") end
    local ok = false
    if fn(pa.Talk, "hold") then ok = pcall(pa.Talk.hold, actor, shell, player, now, ms) end
    if not ok then stopBody(uid, shell, ms, "idle_alert") end -- vanilla-ish fallback: a brief stop
    pcall(function() pa.Speech.face(shell, player) end)
    if P.claim then pcall(P.claim, uid, "listen", { player = player, ms = ms + 1000 }) end -- v1.4.0: A-Life won't walk them off
    return true
end
function P.resumeFriendly(uid, player)
    local pa = PA()
    local comp = P.companionOf(uid)
    if comp then comp.waitUntilMs = nil end
    if P.owner and P.owner(uid) == "listen" then P.release(uid, "listening over") end
    if fn(pa.Talk, "releaseHold") then pcall(pa.Talk.releaseHold, tostring(uid), speechKey(player)) end
    local d = decisions()
    pcall(function()
        local st = d.states[tostring(uid)]
        if type(st) == "table" and st.intent == "idle_alert" then st.cooldownUntilMs = 0 end
    end)
    return true
end

-- walk out of an area (bounds) to a spot ~12 tiles beyond its edge, away from 'from'
function P.leaveArea(uid, bounds, from, ms)
    local sh = shellOf(uid)
    if sh == nil or type(bounds) ~= "table" then return false, "not_here" end
    local x, y, z = pos(sh)
    local cx, cy = (bounds.x1 + bounds.x2) / 2, (bounds.y1 + bounds.y2) / 2
    local dx, dy = x - cx, y - cy
    if from ~= nil then local fx, fy = pos(from); if fx then dx, dy = x - fx, y - fy end end
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then dx, dy, len = 1, 0, 1 end
    local half = math.max(bounds.x2 - bounds.x1, bounds.y2 - bounds.y1) / 2
    local reach = half + 12
    local anchor = { x = math.floor(cx + dx / len * reach), y = math.floor(cy + dy / len * reach), z = 0 }
    if P.acts[tostring(uid)] then P.activityStop(uid, "told to leave") end
    if P.orderedBy(uid) ~= nil then P.releaseOrder(uid) end
    local ok, why = P.order(uid, "hold", anchor, ms or 300000, "leave")
    if ok then log("leave: " .. tostring(uid) .. " walks out to " .. anchor.x .. "," .. anchor.y) end
    return ok, why, anchor
end

-- fake names (shown overhead / in A-Life's talk menu while the lie holds)
function P.setFakeName(uid, player, name)
    local key = speechKey(player) or playerKey(player)
    if key == nil or type(name) ~= "string" or name == "" then return false end
    local d = P.store()
    d.fakeNames = type(d.fakeNames) == "table" and d.fakeNames or {}
    d.fakeNames[tostring(uid)] = d.fakeNames[tostring(uid)] or {}
    d.fakeNames[tostring(uid)][tostring(key)] = name
    return true
end
function P.clearFakeName(uid, player)
    local key = speechKey(player) or playerKey(player)
    local d = P.store()
    if key == nil or type(d.fakeNames) ~= "table" or d.fakeNames[tostring(uid)] == nil then return false end
    d.fakeNames[tostring(uid)][tostring(key)] = nil
    return true
end
function P.fakeNameOf(uid, key)
    local d = P.data or P.store()
    local row = type(d.fakeNames) == "table" and d.fakeNames[tostring(uid)] or nil
    return row and key ~= nil and row[tostring(key)] or nil
end

-- activities ------------------------------------------------------------------------------------------------
function P.activityStart(uid, spec)
    if not P.settings.activity.enabled or type(spec) ~= "table" then return false, "off" end
    local sh, r = shellOf(uid), readRec(uid)
    if sh == nil or r == nil then return false, "not_here" end
    if engaged(uid) or P.companionOf(uid) or busyStance(r) then return false, "busy" end
    local mine = P.orderedBy(uid)
    if mine ~= nil and mine ~= "activity" then return false, "ordered" end
    local x, y, z = pos(sh)
    local anchor = spec.anchor or { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }
    local a = { kind = spec.kind, preset = spec.preset, untilMs = nowMs() + (spec.ms or 600000), x = anchor.x, y = anchor.y,
        z = anchor.z, lastPoseAt = -1e12, seat = spec.seat, care = spec.care, face = spec.face }
    -- v1.4.0: owned - A-Life's decision step is skipped while the activity runs, so they really stay and do it
    if P.settings.own.enabled ~= false and P.settings.own.kinds.activity and P.installed.own then
        a.owned = true
        P.acts[tostring(uid)] = a
        local ok, why = P.claim(uid, "activity", { ms = spec.ms or 600000, player = spec.player })
        if not ok then P.acts[tostring(uid)] = nil; return false, why end
        a.claimedOnce = true
        return true, "owned"
    end
    local ok, why = P.order(uid, "hold", anchor, spec.ms or 600000, "activity") -- fallback: an A-Life hold order (1.3 behaviour)
    if not ok then return false, why end
    P.acts[tostring(uid)] = a
    return true, "order"
end
function P.activityStop(uid, why)
    local a = P.acts[tostring(uid)]
    if a == nil then return false end
    P.acts[tostring(uid)] = nil
    if a.owned then
        local k = P.owner(uid)
        if k == "activity" then P.release(uid, "activity ended: " .. tostring(why)) end
    else
        P.releaseOrder(uid, "activity")
    end
    local sh = shellOf(uid)
    if sh ~= nil then
        local pa = PA()
        if a.seat and fn(pa.SeatApi, "release") then pcall(pa.SeatApi.release, a.seat, sh) end
        pcall(function()
            local cur = pa.Animations.current and pa.Animations.current[sh]
            if cur ~= nil and fn(pa.Animations, "clear") then pa.Animations.clear(sh) end
        end)
    end
    emit("activityEnd", tostring(uid), a.kind, why)
    return true
end
function P.activityYield(uid, a, player)
    local pa = PA()
    local r = readRec(uid)
    local sh = shellOf(uid)
    if r == nil or sh == nil or r.lifecycle ~= "active" then return "gone" end
    if engaged(uid) then return "danger" end
    if P.companionOf(uid) then return "following" end
    if busyStance(r) then return "stance" end
    if a.owned then
        if P.owner(uid) ~= "activity" then return "taken over" end
    elseif P.orderedBy(uid) ~= "activity" then return "order" end
    local x, y = pos(sh)
    if P.zombiesNear and P.zombiesNear(x, y, P.settings.activity.zombieTiles) > 0 then return "zombies" end
    if player ~= nil and fn(pa.Relations, "playerStance") then
        local ok, st = pcall(pa.Relations.playerStance, r, player)
        if ok and st == "hostile" then return "hostile" end
    end
    local m = type(r.memory) == "table" and r.memory or {}
    if (tonumber(m.talkHoldUntilMs) or 0) > nowMs() then return "talk" end
    if nowMs() > a.untilMs then return "done" end
    return nil
end
function P.activityTick(player)
    local pa = PA()
    local now = nowMs()
    for uid, a in pairs(P.acts) do
        -- pre-1.0 MP: hostility is checked against the player nearest the spot (single player: you)
        local player = player
        if ALifeSide.mpServer() then player = ALifeSide.nearest(a.x, a.y) end
        local why = (not a.owned) and P.activityYield(uid, a, player) or nil
        if a.owned and P.owner(uid) ~= "activity" then why = P.activityYield(uid, a, player) end
        if why ~= nil then P.activityStop(uid, why)
        elseif a.owned then -- the ownership controller (DecisionLoop.think) drives this one
        else
            local sh = shellOf(uid)
            local x, y = pos(sh)
            local near = x and (x - (a.x + 0.5)) ^ 2 + (y - (a.y + 0.5)) ^ 2 <= 2.3
            if near and a.seat and not a.snapped and fn(pa.SeatApi, "snap") then
                a.snapped = pcall(pa.SeatApi.snap, sh, a.seat)
                pcall(pa.SeatApi.face, sh, a.seat)
            end
            if near and a.care and not a.cared then a.cared = true; safe(P.shelterCare, uid, a.care) end
            if near and a.preset and now - a.lastPoseAt >= P.settings.activity.reapplyMs then
                a.lastPoseAt = now
                if fn(pa.Animations, "presetOf") and pa.Animations.presetOf(a.preset) ~= nil then
                    pcall(pa.Animations.apply, sh, a.preset)
                end
            end
        end
    end
end

-- shelter care: doors, curtains, lights, boards (only what A-Life / vanilla expose; every call guarded)
local function hasKit(sh)
    local ok = false
    pcall(function()
        local inv = sh:getInventory()
        ok = inv:containsTypeRecurse("Base.Hammer") and inv:containsTypeRecurse("Base.Nails")
    end)
    return ok
end
function P.shelterCare(uid, opts)
    if not P.settings.shelterCare.enabled then return nil end
    opts = opts or {}
    local pa = PA()
    local sh = shellOf(uid)
    if sh == nil then return nil end
    local building = nil
    pcall(function() local sq = sh:getCurrentSquare(); if sq ~= nil then building = sq:getBuilding() end end)
    if building == nil or not fn(pa.OutpostBuilder, "probeBuilding") then return nil end
    local okP, probe = pcall(pa.OutpostBuilder.probeBuilding, building)
    if not okP or type(probe) ~= "table" then return nil end
    local out = { doors = 0, locked = 0, curtains = 0, lights = 0, boarded = 0 }
    local doors = type(probe.doors) == "function" and probe.doors() or probe.doors
    local windows = type(probe.windows) == "function" and probe.windows() or probe.windows
    for _, o in ipairs(type(doors) == "table" and doors or {}) do
        pcall(function()
            local door = o.object
            if door == nil or (instanceof ~= nil and not instanceof(door, "IsoDoor")) then return end
            if door:IsOpen() then door:ToggleDoor(sh); out.doors = out.doors + 1 end
            if not door:IsOpen() and not door:isLocked() then door:setIsLocked(true); out.locked = out.locked + 1 end
        end)
    end
    for _, o in ipairs(type(windows) == "table" and windows or {}) do
        pcall(function()
            if fn(pa.OutpostBuilder, "closeSheet") then
                local ready, changed = pa.OutpostBuilder.closeSheet(o.object)
                if changed then out.curtains = out.curtains + 1 end
            end
        end)
    end
    if opts.night then
        pcall(function()
            local sq = sh:getCurrentSquare()
            local room = sq and sq:getRoom()
            local list = room and room:getLightSwitches()
            if list ~= nil then
                for i = 0, list:size() - 1 do
                    local sw = list:get(i)
                    if sw ~= nil and sw:isActivated() then sw:setActive(false); out.lights = out.lights + 1 end
                end
            end
        end)
    end
    local fort = pa.ModuleFortify
    if opts.board and hasKit(sh) and fn(fort, "board") and fn(pa.Planks, "held") and pa.Planks.held({ sh }) > 0 then
        local n = 0
        for _, o in ipairs(type(windows) == "table" and windows or {}) do
            if n >= P.settings.shelterCare.boardMax then break end
            if o.barricaded ~= true then
                local ok, done = pcall(fort.board, sh, o, 2)
                if ok and done then n = n + 1 end
            end
        end
        out.boarded = n
        if n > 0 then pcall(pa.Animations.apply, sh, "board_up") end
    end
    log("shelter care by " .. tostring(uid) .. ": doors " .. out.doors .. ", locked " .. out.locked .. ", curtains " .. out.curtains
        .. ", lights " .. out.lights .. ", boarded " .. out.boarded)
    emit("shelterCare", tostring(uid), out)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- 9) v1.3: KEEP THE PEOPLE YOU KNOW (A-Life culling), SQUAD MEMBERS COME BACK AS THEMSELVES, TELEPORTS
-- A-Life deletes a dormant "expendable" actor after Population_DormantTtlHours (8 h) away from every player
-- (Population.lua: Registry.remove(..., "dormant_ttl")) and retires encounter NPCs parked inside a player base
-- ("inside_player_base"). Offline squads delete their rendered members ("render_out") and re-create them later
-- with a NEW uid (so a new name, no introductions, no opinion). The patch:
--   * wraps ActorRegistry.remove: "dormant_ttl" / "inside_player_base" are refused for protected people (an
--     opinion row with you, introduced to you, a companion, a nemesis, or anything A-Life Talk marks as known);
--     every other reason (admin purge, render_out, dead pruning) goes straight to the original;
--   * on "render_out" of a protected member: remembers uid + name + introductions + opinion by A-Life's own
--     appearance seed (memory.identitySeed, which the squad ledger keeps), then calls the original;
--   * wraps ActorRegistry.create: a new record with a remembered identitySeed gets its old uid back (when free -
--     A-Life does the same for expedition squads) and its old name / introductions / opinion, then the original
--     creates it. All A-Life Talk data is keyed by uid, so it reattaches by itself;
--   * teleport: a companion left dormant far behind is moved (Registry.update of the dormant position, the same
--     call Population.keptOut uses) next to the player, so A-Life respawns it beside you.
----------------------------------------------------------------------------------------------------------------
P.settings.keep = { enabled = true, reasons = { dormant_ttl = true, inside_player_base = true, outpost_expired = true }, seedKeep = 200,
    teleportTiles = 150, companionCatchTiles = 100, opinionAt = 10 }
P.protectors = P.protectors or {} -- function(uid, record) -> true (A-Life Talk registers one)
function P.isProtected(record)
    if type(record) ~= "table" then return false end
    local uid = tostring(record.uid)
    if P.isFinalDead and P.isFinalDead(uid) then return false end -- 1.4.2: the dead are never "protected"
    local d = P.data or P.store()
    if d.companions[uid] ~= nil or d.nemesis[uid] ~= nil or (d.keep and d.keep[uid]) then return true end
    local m = type(record.memory) == "table" and record.memory or {}
    if m.persistent == true then return true end
    if type(m.opinion) == "table" then -- a real relationship, not just a stranger who once saw you (keeps the population bounded)
        for _, row in pairs(m.opinion) do
            if type(row) == "table" and math.abs(tonumber(row.v) or 0) >= P.settings.keep.opinionAt then return true end
        end
    end
    if type(m.introducedTo) == "table" and P.hasAny(m.introducedTo) then return true end
    if type(m.orderedTo) == "table" and m.orderedTo.kind == "follow" then return true end
    for _, f in ipairs(P.protectors) do
        local ok, yes = pcall(f, uid, record)
        if ok and yes == true then return true end
    end
    return false
end
function P.keepMark(uid, on) local d = P.store(); d.keep = d.keep or {}; d.keep[tostring(uid)] = on and true or nil end

local function seedOf(record)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or nil
    return m and type(m.identitySeed) == "string" and m.identitySeed or nil
end
local function copyT(t, depth)
    if type(t) ~= "table" or (depth or 0) > 4 then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copyT(v, (depth or 0) + 1) end
    return o
end
function P.rememberSeed(record)
    local seed = seedOf(record)
    if seed == nil then return false end
    if P.isFinalDead and P.isFinalDead(record.uid) then return false end
    local d = P.store()
    d.seeds = d.seeds or {}
    local m = record.memory
    d.seeds[seed] = { uid = tostring(record.uid), name = m.personName, first = m.personFirst, last = m.personLast,
        intro = copyT(m.introducedTo), opinion = copyT(m.opinion), h = hours(),
        x = record.worldPosition and record.worldPosition.x, y = record.worldPosition and record.worldPosition.y }
    local n, oldest, oldKey = 0, nil, nil
    for k, s in pairs(d.seeds) do
        n = n + 1
        if oldest == nil or (s.h or 0) < oldest then oldest, oldKey = s.h or 0, k end
    end
    if n > P.settings.keep.seedKeep and oldKey then d.seeds[oldKey] = nil end
    log("remembered " .. tostring(m.personName) .. " (" .. tostring(record.uid) .. ") by appearance seed for when the squad comes back")
    emit("seedSaved", tostring(record.uid), seed)
    return true
end

-- 1.3.1: diagnostics for the "they disappear from the Relationships menu" reports
local function keepLog(msg) print("[ALifeTalk][Keep] " .. tostring(msg)) end
P.keepLogAt = {}
local function anyOpinionRow(record)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or nil
    return m ~= nil and type(m.opinion) == "table" and P.hasAny(m.opinion)
end
function P.keepRemove(orig, uid, expectedRevision, reason, ...)
    local s = P.settings.keep
    local record = nil
    if s.enabled then
        record = readRec(uid)
        if record ~= nil and record.lifecycle ~= "dead" then
            if s.reasons[tostring(reason)] and P.isProtected(record) then
                local name = tostring(record.memory and record.memory.personName or uid)
                local now = nowMs()
                if now - (P.keepLogAt[tostring(uid)] or -1e12) >= 600000 then
                    P.keepLogAt[tostring(uid)] = now
                    keepLog("blocked deletion of " .. name .. " (" .. tostring(uid) .. ") - A-Life path: " .. tostring(reason))
                    log("kept " .. name .. " (A-Life wanted to remove: " .. tostring(reason) .. ")")
                end
                P.keepBlocked = (P.keepBlocked or 0) + 1
                emit("kept", tostring(uid), tostring(reason))
                return false, "alifetalk_protected"
            end
            if tostring(reason) == "render_out" and P.isProtected(record) then pcall(P.rememberSeed, record) end
        end
    end
    -- everything else goes to A-Life; A-Life Talk snapshots a person it knows first (its menu keeps showing them)
    local known = record ~= nil and (anyOpinionRow(record) or P.isProtected(record))
    if known then emit("removing", tostring(uid), tostring(reason), record) end
    local a, b = orig(uid, expectedRevision, reason, ...)
    if known and a == true then
        keepLog("A-Life removed known " .. tostring(record.memory and record.memory.personName or uid) .. " (" .. tostring(uid) .. ") - path: "
            .. tostring(reason) .. (tostring(reason) == "render_out" and " (travelling squad; comes back as themselves when it renders again)" or ""))
        emit("removed", tostring(uid), tostring(reason))
    end
    return a, b
end
function P.keepSummary()
    local reg = PA().ActorRegistry
    local total, prot, dead = 0, 0, 0
    if fn(reg, "each") then
        reg.each(function(r)
            total = total + 1
            if r.lifecycle == "dead" then dead = dead + 1 elseif P.isProtected(r) then prot = prot + 1 end
            return false
        end)
    end
    local marks, seeds = 0, 0
    local d = P.store()
    for _ in pairs(d.keep or {}) do marks = marks + 1 end
    for _ in pairs(d.seeds or {}) do seeds = seeds + 1 end
    keepLog("patch " .. P.VERSION .. " keep active: " .. prot .. " protected of " .. total .. " A-Life actors (" .. dead .. " dead), "
        .. marks .. " keep marks, " .. seeds .. " squad members remembered; guarded paths: dormant_ttl, inside_player_base, outpost_expired")
    return prot, total, marks, seeds
end

function P.keepCreate(orig, spec, ...)
    local d = P.data
    if P.settings.keep.enabled and d and type(d.seeds) == "table" and type(spec) == "table" and type(spec.memory) == "table" then
        local seed = spec.memory.identitySeed
        local saved = type(seed) == "string" and d.seeds[seed] or nil
        if saved ~= nil and P.isFinalDead and P.isFinalDead(saved.uid) then d.seeds[seed] = nil; saved = nil end
        if saved ~= nil then
            local reg = PA().ActorRegistry
            local free = saved.uid ~= nil and (reg.peek or reg.read)(saved.uid) == nil
            local s2 = {}
            for k, v in pairs(spec) do s2[k] = v end
            s2.memory = {}
            for k, v in pairs(spec.memory) do s2.memory[k] = v end
            if free and s2.uid == nil then s2.uid = saved.uid end
            if saved.name then s2.memory.personName, s2.memory.personFirst, s2.memory.personLast = saved.name, saved.first, saved.last end
            if type(saved.intro) == "table" then s2.memory.introducedTo = copyT(saved.intro) end
            if type(saved.opinion) == "table" then s2.memory.opinion = copyT(saved.opinion) end
            local rec, flag = orig(s2, ...)
            if type(rec) == "table" then
                d.seeds[seed] = nil
                log("squad member came back as themselves: " .. tostring(saved.name) .. " (" .. tostring(rec.uid) .. (rec.uid == saved.uid and ", same uid" or ", new uid") .. ")")
                emit("seedRestored", saved.uid, tostring(rec.uid))
                return rec, flag
            end
            return orig(spec, ...)
        end
    end
    return orig(spec, ...)
end

-- teleport: player moved more than teleportTiles between two checks
P.lastPos = nil
function P.teleportCheck(player)
    local x, y = pos(player)
    if x == nil then return end
    -- pre-1.0 MP: each player's own last spot (single player: P.lastPos, as before)
    local pk = ALifeSide.mpServer() and tostring(ALifeSide.keyOf(player)) or nil
    P.lastPosBy = P.lastPosBy or {}
    local lp = pk and P.lastPosBy[pk] or (pk == nil and P.lastPos or nil)
    if pk then P.lastPosBy[pk] = { x = x, y = y } else P.lastPos = { x = x, y = y } end
    if lp == nil then return end
    local inCar = false
    pcall(function() inCar = player:getVehicle() ~= nil end)
    local d2 = (x - lp.x) ^ 2 + (y - lp.y) ^ 2
    if d2 >= P.settings.keep.teleportTiles ^ 2 and not inCar then
        log("teleport detected (" .. math.floor(math.sqrt(d2)) .. " tiles)")
        P.teleportedAtMs = nowMs()
        emit("teleport", player, lp.x, lp.y, x, y)
    end
end
-- companions left behind (dormant, far away) are moved next to you so A-Life respawns them here
function P.companionCatchUp(player)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    if not fn(reg, "update") or player == nil then return end
    local d = P.store()
    local key = speechKey(player)
    local px, py, pz = pos(player)
    if px == nil then return end
    for uid, comp in pairs(d.companions) do
        local r = readRec(uid)
        if r ~= nil and comp.key == key and r.lifecycle == "dormant" and type(r.worldPosition) == "table" then
            local dx, dy = r.worldPosition.x - px, r.worldPosition.y - py
            if dx * dx + dy * dy >= P.settings.keep.companionCatchTiles ^ 2 then
                local spot = P.findSpot and P.findSpot(player, 3, 6) or nil
                local sx, sy = px + 3, py + 3
                if type(spot) == "table" then sx, sy = spot.x or sx, spot.y or sy end
                local ok, res = pcall(reg.update, uid, r.revision, function(rec)
                    rec.worldPosition = { x = sx, y = sy, z = pz or 0 }
                end)
                if ok and res ~= nil then
                    comp.lost = nil
                    log("companion " .. tostring(uid) .. " caught up after the teleport (respawns beside you)")
                    emit("companionCaughtUp", tostring(uid))
                end
            end
        end
    end
end

-- reanimation: A-Life's Lifecycle.stepTurn scrubs the corpse's A-Life ModData and calls reanimateLater - the zombie
-- that gets up carries no identity. Wrapper: remember who it was (uid, spot, sex) right before, then the original.
P.reanimating = {} -- uid -> { x, y, z, atMs, female }
function P.reanimatingNear(x, y, z, tiles, maxAgeMs)
    local now = nowMs()
    local best, bd = nil, (tiles or 2) ^ 2
    for uid, e in pairs(P.reanimating) do
        if now - e.atMs > (maxAgeMs or 600000) then P.reanimating[uid] = nil
        elseif math.floor(e.z or 0) == math.floor(z or 0) then
            local d = (e.x - x) ^ 2 + (e.y - y) ^ 2
            if d <= bd then best, bd = uid, d end
        end
    end
    return best, best and P.reanimating[best] or nil
end


-- 10) MERCY KILLS (1.3.0): killing someone who is bitten / infected is not murder. A-Life's own kill consequences
-- (group opinion hit, revenge squads, hostile-act record) are skipped for such a victim; A-Life Talk applies its own
-- softer reactions (grief, gratitude, a sad argument; anger only in extreme cases). P.mercyCheck(actor, shell) can be
-- set by A-Life Talk; built-in check: A-Life's own infection marks (memory.infectedTurnAtHours / ProjectALifeTurnAtHours).
P.settings.mercy = { enabled = true }
P.mercyCheck = nil
function P.isMercy(actor, shell)
    if not P.settings.mercy.enabled or type(actor) ~= "table" then return false end
    local m = type(actor.memory) == "table" and actor.memory or {}
    if m.infectedTurnAtHours ~= nil then return true end
    local yes = false
    pcall(function() local d = shell and shell:getModData(); if type(d) == "table" and d.ProjectALifeTurnAtHours ~= nil then yes = true end end)
    if yes then return true end
    if type(P.mercyCheck) == "function" then
        local ok, r = pcall(P.mercyCheck, actor, shell)
        if ok and r == true then return true end
    end
    return false
end


-- 11) SETTLERS (1.3.0): an NPC who agreed to live at the player's base. A-Life's own home anchor (memory.home, used by
-- roam / patrol / stance / havens) is pointed at the base through ActorRegistry.update; the old value is kept and
-- restored by P.unsettle. A hold order walks them there first; P.keepMark protects them from culling.
function P.baseSettle(uid, x, y, z, walkMs, opts)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    local r = readRec(uid)
    if r == nil or not fn(reg, "update") then return false, "no_actor" end
    local d = P.store()
    d.settlers = d.settlers or {}
    local m = type(r.memory) == "table" and r.memory or {}
    local prev = type(m.home) == "table" and { x = m.home.x, y = m.home.y, z = m.home.z } or false
    local ok, res = pcall(reg.update, tostring(uid), r.revision, function(rec)
        rec.memory = type(rec.memory) == "table" and rec.memory or {}
        rec.memory.home = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }
        rec.memory.alifetalkSettled = true
    end)
    if not ok or res == nil then return false, "update_failed" end
    local keepPrev = d.settlers[tostring(uid)] -- 1.4.3: re-settling keeps the ORIGINAL home (never the base itself)
    if type(keepPrev) == "table" and keepPrev.prev ~= nil then prev = keepPrev.prev end
    d.settlers[tostring(uid)] = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), prev = prev, at = nowMs() }
    if P.settlerOpts then P.settlerOpts(d.settlers[tostring(uid)], opts) end
    P.keepMark(uid, true)
    if P.orderedBy(uid) ~= nil then P.releaseOrder(uid) end
    P.order(uid, "hold", { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }, walkMs or 600000, "settle")
    log("settle: " .. tostring(uid) .. " now lives at " .. math.floor(x) .. "," .. math.floor(y))
    emit("settled", tostring(uid), d.settlers[tostring(uid)])
    return true
end
function P.unsettle(uid)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    local d = P.store()
    local e = d.settlers and d.settlers[tostring(uid)]
    if e == nil then return false end
    local r = readRec(uid)
    if r and fn(reg, "update") then
        pcall(reg.update, tostring(uid), r.revision, function(rec)
            rec.memory = type(rec.memory) == "table" and rec.memory or {}
            rec.memory.home = e.prev or nil
            rec.memory.alifetalkSettled = nil
        end)
    end
    d.settlers[tostring(uid)] = nil
    P.keepMark(uid, false)
    P.releaseOrder(uid, "settle")
    return true
end
function P.settlersOf() return P.store().settlers or {} end

-- 11b) v1.4.3: SETTLERS ON LEAVE + A-LIFE'S BASE. A settler can travel in the player's party and still live at the base:
-- the roster entry and A-Life's home anchor (memory.home) stay, only the patch's "settle" hold order and the resident
-- claim are dropped (the party owns them now). baseReturn walks them home again; baseRehome re-points memory.home when
-- A-Life's base for the player moved (prev kept, so unsettle still restores the original); baseDrop removes a dead
-- settler from the roster without writing to the dead record. opts (key / bounds / src) = which A-Life house it is.
P.settings.settlers = { leave = true }
local function settlerOpts(e, opts)
    if type(e) ~= "table" or type(opts) ~= "table" then return end
    if opts.key ~= nil then e.key = tostring(opts.key) end
    if opts.src ~= nil then e.src = tostring(opts.src) end
    local b = opts.bounds
    if type(b) == "table" and tonumber(b.x1) and tonumber(b.y1) and tonumber(b.x2) and tonumber(b.y2) then
        e.bounds = { x1 = math.floor(b.x1), y1 = math.floor(b.y1), x2 = math.floor(b.x2), y2 = math.floor(b.y2), z = math.floor(tonumber(b.z) or 0) }
    elseif opts.bounds == false then e.bounds = nil end
end
P.settlerOpts = settlerOpts
function P.settlerOf(uid) local d = P.store(); return d.settlers and d.settlers[tostring(uid)] or nil end
function P.baseLeave(uid, why)
    if P.settings.settlers.leave == false then return false, "off" end
    local e = P.settlerOf(uid)
    if e == nil then return false, "not_settler" end
    e.away = { at = nowMs(), why = tostring(why or "party") }
    P.releaseOrder(uid, "settle")
    if P.owner and P.owner(uid) == "resident" then pcall(P.release, uid, "left the base with the player") end
    P.keepMark(uid, true)
    log("settle: " .. tostring(uid) .. " leaves the base for a while (" .. tostring(why or "party") .. ") - still lives there")
    emit("baseLeave", tostring(uid), e)
    return true
end
function P.baseReturn(uid, walkMs)
    local e = P.settlerOf(uid)
    if e == nil then return false, "not_settler" end
    e.away = nil
    P.keepMark(uid, true)
    if P.orderedBy(uid) ~= nil and P.orderedBy(uid) ~= "settle" then P.releaseOrder(uid) end
    P.order(uid, "hold", { x = e.x, y = e.y, z = e.z or 0 }, walkMs or 600000, "settle")
    log("settle: " .. tostring(uid) .. " heads home to the base at " .. tostring(e.x) .. "," .. tostring(e.y))
    emit("baseReturn", tostring(uid), e)
    return true
end
function P.baseRehome(uid, x, y, z, opts)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    local e = P.settlerOf(uid)
    local r = readRec(uid)
    if e == nil or r == nil or not fn(reg, "update") or x == nil or y == nil then return false, "no_settler" end
    if r.lifecycle == "dead" then return false, "dead" end
    local ok, res = pcall(reg.update, tostring(uid), r.revision, function(rec)
        rec.memory = type(rec.memory) == "table" and rec.memory or {}
        rec.memory.home = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }
        rec.memory.alifetalkSettled = true
    end)
    if not ok or res == nil then return false, "update_failed" end
    e.x, e.y, e.z = math.floor(x), math.floor(y), math.floor(z or 0)
    settlerOpts(e, opts)
    if e.away == nil then
        P.releaseOrder(uid, "settle")
        P.order(uid, "hold", { x = e.x, y = e.y, z = e.z }, 600000, "settle")
    end
    log("settle: " .. tostring(uid) .. " home follows the base to " .. e.x .. "," .. e.y .. (e.key and (" (" .. e.key .. ")") or ""))
    return true
end
function P.baseDrop(uid, why)
    local d = P.store()
    local e = d.settlers and d.settlers[tostring(uid)]
    if e == nil then return nil end
    d.settlers[tostring(uid)] = nil
    P.releaseOrder(uid, "settle")
    if P.owner and P.owner(uid) ~= nil then pcall(P.release, uid, "left the base roster") end
    P.keepMark(uid, false)
    log("settle: " .. tostring(uid) .. " removed from the base roster (" .. tostring(why or "?") .. ")")
    return e
end

----------------------------------------------------------------------------------------------------------------
-- 12) v1.4.0: BEHAVIOUR OWNERSHIP - while A-Life Talk "owns" an NPC (listening to you, a daily activity, a party
--     member, a resident of your base), A-Life's decision / movement step for that NPC is skipped and a small
--     controller here drives the body instead. A-Life keeps running for everybody else, keeps its bookkeeping
--     (endurance, wardrobe) for owned NPCs, and gets the NPC back the moment there is danger (fight, flee, zombies,
--     getting hurt, being targeted), when the claim runs out, or if a controller ever errors (fail-safe).
--     Wrap: DecisionLoop.think (one function; the original runs whenever the NPC is not owned).
--     Master switch: P.settings.own.enabled (false = A-Life drives everybody exactly as before).
----------------------------------------------------------------------------------------------------------------
P.settings.own = { enabled = true, log = true, dangerTiles = 6, hurtDrop = 0.03, coolMs = 8000, maxMs = 1800000,
    kinds = { listen = true, activity = true, party = true, resident = true, leave = true, approach = true },
    followNear = 2.2, followFar = 4.0, runTiles = 9, lostTiles = 45, retargetMs = 1500, faceMs = 700, pathFails = 3,
    moveTimeoutMs = 25000, holdRadius = 1.6, residentRadius = 8, reassertMs = 4000, arriveTiles2 = 2.3 }
P.own = { claims = {}, cool = {}, logAt = {}, stats = { claims = 0, releases = 0, danger = 0, errors = 0, steps = 0, refused = 0 } }
P.ownPrio = { resident = 1, activity = 2, leave = 2.5, party = 3, approach = 3.5, listen = 4 }
for _, k in ipairs({ "own", "unown", "activityStep", "activityEnd", "pause", "shelterCare", "dormantDeathIgnored" }) do P.hooks[k] = P.hooks[k] or {} end

local function ownLog(msg, key, gapMs)
    if P.settings.own.log == false then return end
    if key ~= nil then
        local now = nowMs()
        if now < (P.own.logAt[key] or -1e12) then return end
        P.own.logAt[key] = now + (gapMs or 30000)
    end
    print("[ALifeTalkPatch][Own] " .. tostring(msg))
end
P.ownLog = ownLog
local function nameOfRec(r)
    local n = nil
    pcall(function() local pa = PA(); n = pa.Names.of(r) end)
    if type(n) ~= "string" or n == "" then n = type(r) == "table" and tostring(r.name or r.uid) or "?" end
    return n
end
local function who(uid, r) return nameOfRec(r or readRec(uid)) .. " (" .. tostring(uid) .. ")" end
local function healthOf(sh) local h = nil; pcall(function() h = tonumber((sh:getHealth())) end); return h end

function P.owner(uid)
    local c = P.own.claims[tostring(uid)]
    if c == nil then return nil, nil end
    return c.kind, c
end
function P.ownCount()
    local n = 0
    for _ in pairs(P.own.claims) do n = n + 1 end
    return n
end

-- who is currently targeting this shell (built at most every 500 ms from A-Life's own decision states)
local targetedCache = { atMs = -1e12, set = {} }
local function targetedSet(now)
    if now - targetedCache.atMs < 500 then return targetedCache.set end
    local set = {}
    local d = decisions()
    if d and type(d.states) == "table" then
        for uid, st in pairs(d.states) do
            if type(st) == "table" and st.threat ~= nil and (st.kind == "combat" or st.kind == "approach_threat") then
                set[st.threat] = tostring(uid)
            end
        end
    end
    targetedCache.atMs, targetedCache.set = now, set
    return set
end

-- nil = safe; otherwise a short reason (A-Life takes over again)
function P.ownDanger(uid, actor, shell, c, now)
    uid = tostring(uid)
    local pa, d = PA(), decisions()
    local st = d and type(d.states) == "table" and d.states[uid] or nil
    if type(st) == "table" and (st.kind == "combat" or st.kind == "retreat" or st.kind == "recovering" or st.kind == "flee") then
        return "A-Life state " .. tostring(st.kind)
    end
    if pa and fn(pa.Talk, "busy") then
        local ok, busy = pcall(pa.Talk.busy, actor, now)
        if ok and busy then return "fighting / fleeing" end
    end
    local x, y = pos(shell)
    if x and P.zombiesNear and P.zombiesNear(x, y, P.settings.own.dangerTiles) > 0 then return "zombies within " .. P.settings.own.dangerTiles .. " tiles" end
    local h = healthOf(shell)
    if h and c and c.hp then
        if h < c.hp - P.settings.own.hurtDrop then return "got hurt" end
        if h > c.hp then c.hp = h end
    end
    local by = targetedSet(now)[shell]
    if by ~= nil then return "targeted by " .. tostring(by) end
    return nil
end

local function parkState(uid, actor, shell, now, stop)
    local d = decisions()
    if d == nil or type(d.states) ~= "table" then return end
    if stop and fn(d, "stopForTalk") then
        pcall(function() d.states[uid] = d.stopForTalk(actor, shell, d.states[uid], now) end)
    end
    local st = d.states[uid]
    if type(st) ~= "table" then st = { kind = "idle" }; d.states[uid] = st end
    st.kind, st.intent, st.cooldownUntilMs = "idle", "alifetalk_owned", now + 2000
end
local function cancelMove(uid, c, actor)
    if c == nil or c.move == nil then return end
    local pa = PA()
    if c.move.status == "running" and pa and fn(pa.ActionLedger, "cancelActor") and actor ~= nil then
        pcall(pa.ActionLedger.cancelActor, uid, actor.generation, "alifetalk_own")
    end
    c.move, c.goal = nil, nil
end
local function haltBody(shell)
    pcall(function()
        if shell:isMoving() then
            local pf = shell:getPathFindBehavior2()
            if pf ~= nil then pf:cancel() end
            shell:setMoving(false)
        end
    end)
end

-- claim an NPC for one of the kinds; spec: { ms, player, anchor{x,y,z}, mode ("follow"/"hold"/"guard"), radius, slot }
function P.claim(uid, kind, spec)
    local s = P.settings.own
    uid = tostring(uid)
    spec = type(spec) == "table" and spec or {}
    if s.enabled == false then return false, "setting 'own' is off" end
    if not s.kinds[kind] then return false, "kind '" .. tostring(kind) .. "' is off" end
    if not P.installed.own then return false, "not installed (no DecisionLoop.think)" end
    local actor, shell = readRec(uid), shellOf(uid)
    if actor == nil or shell == nil then return false, "not here" end
    if actor.lifecycle ~= nil and actor.lifecycle ~= "active" then return false, "not active" end
    local now = nowMs()
    local old = P.own.claims[uid]
    if old ~= nil and old.kind ~= kind and (P.ownPrio[old.kind] or 0) > (P.ownPrio[kind] or 0) then
        return false, "owned by " .. old.kind
    end
    if (P.own.cool[uid] or -1e12) > now then
        P.own.stats.refused = P.own.stats.refused + 1
        ownLog("refused " .. kind .. " for " .. who(uid, actor) .. ": cooling down after danger", "cool|" .. uid, 10000)
        return false, "cooling down after danger"
    end
    local danger = P.ownDanger(uid, actor, shell, nil, now)
    if danger ~= nil then
        P.own.stats.refused = P.own.stats.refused + 1
        ownLog("refused " .. kind .. " for " .. who(uid, actor) .. ": " .. danger, "danger|" .. uid, 10000)
        return false, "danger: " .. danger
    end
    if old ~= nil and old.kind == kind then -- renew / update in place
        for k, v in pairs(spec) do old.spec[k] = v end
        old.untilMs = now + math.min(s.maxMs, tonumber(spec.ms) or s.maxMs)
        return true, "renewed"
    end
    if old ~= nil then cancelMove(uid, old, actor) end
    local c = { kind = kind, spec = spec, atMs = now, untilMs = now + math.min(s.maxMs, tonumber(spec.ms) or s.maxMs),
        hp = healthOf(shell), fails = 0, faceAt = -1e12, phase = "start" }
    P.own.claims[uid] = c
    parkState(uid, actor, shell, now, true)
    P.own.stats.claims = P.own.stats.claims + 1
    ownLog("claim " .. who(uid, actor) .. " for " .. kind .. (spec.mode and (" / " .. tostring(spec.mode)) or "")
        .. (old and (" (was " .. old.kind .. ")") or ""))
    emit("own", uid, kind, old and old.kind or nil)
    return true
end

function P.release(uid, why, cool)
    uid = tostring(uid)
    local c = P.own.claims[uid]
    if c == nil then return false end
    P.own.claims[uid] = nil
    local actor = readRec(uid)
    cancelMove(uid, c, actor)
    local now = nowMs()
    local d = decisions()
    pcall(function()
        local st = d.states[uid]
        if type(st) ~= "table" or st.intent == "alifetalk_owned" or st.intent == "talk_hold" then
            d.states[uid] = { kind = "idle", intent = "scan", cooldownUntilMs = 0 }
        end
    end)
    if cool then P.own.cool[uid] = now + P.settings.own.coolMs end
    P.own.stats.releases = P.own.stats.releases + 1
    ownLog("release " .. who(uid, actor) .. " from " .. c.kind .. ": " .. tostring(why) .. " (after "
        .. math.floor((now - c.atMs) / 1000) .. " s)")
    if c.kind == "activity" and P.acts[uid] ~= nil then P.activityStop(uid, why) end
    emit("unown", uid, c.kind, why)
    return true
end
function P.releaseAll(why) for uid in pairs(P.own.claims) do P.release(uid, why or "release all") end end

-- walk somewhere with A-Life's own Movement (returns "moving" / "here" / "stuck")
local function moveTo(uid, c, actor, shell, tx, ty, tz, pace, tol, now)
    local x, y = pos(shell)
    if x == nil then return "stuck" end
    local dx, dy = (tx + 0.5) - x, (ty + 0.5) - y
    if dx * dx + dy * dy <= (tol or 1.5) ^ 2 then cancelMove(uid, c, actor); return "here" end
    local same = c.goal and math.abs(c.goal.x - tx) <= 1 and math.abs(c.goal.y - ty) <= 1 and c.goal.pace == pace
    if c.move ~= nil and c.move.status == "running" and (same or now - (c.goal and c.goal.atMs or 0) < P.settings.own.retargetMs) then
        return "moving"
    end
    local pa = PA()
    if not (pa and pa.Movement and fn(pa.Movement, "begin")) then return "stuck" end
    if c.move ~= nil and c.move.status == "running" then cancelMove(uid, c, actor) end
    local ok, action = pcall(pa.Movement.begin, actor, shell, { x = tx, y = ty, z = tz or 0 },
        { pace = pace, tolerance = tol or 1.5, timeoutMs = P.settings.own.moveTimeoutMs })
    if ok and type(action) == "table" then
        c.move, c.goal, c.fails = action, { x = tx, y = ty, pace = pace, atMs = now }, 0
        return "moving"
    end
    c.fails = (c.fails or 0) + 1
    c.goal = { x = tx, y = ty, pace = pace, atMs = now }
    if c.fails >= P.settings.own.pathFails then return "stuck" end
    return "moving"
end
local function faceSometimes(c, shell, target, now)
    if target == nil or now - (c.faceAt or -1e12) < P.settings.own.faceMs then return end
    c.faceAt = now
    local pa = PA()
    pcall(function() pa.Speech.face(shell, target) end)
end

P.ownCtl = {}
-- listening to you: stand still, face you
function P.ownCtl.listen(uid, c, actor, shell, now)
    cancelMove(uid, c, actor)
    haltBody(shell)
    faceSometimes(c, shell, c.spec.player, now)
    return nil
end
-- party: follow the player, or hold / guard at an anchor
function P.ownCtl.party(uid, c, actor, shell, now)
    local mode = c.spec.mode or "follow"
    local s = P.settings.own
    if mode == "follow" then
        local pl = c.spec.player or ALifeSide.you()
        if pl == nil then return "release", "no player" end
        local inCar = false
        pcall(function() inCar = pl:getVehicle() ~= nil end)
        if inCar then return "release", "player in a vehicle (A-Life handles riding along)" end
        local px, py, pz = pos(pl)
        local x, y = pos(shell)
        if px == nil or x == nil then return "release", "no position" end
        local dist = math.sqrt((px - x) ^ 2 + (py - y) ^ 2)
        if dist > s.lostTiles then return "release", "too far behind (" .. math.floor(dist) .. " tiles)" end
        if dist <= s.followNear then cancelMove(uid, c, actor); haltBody(shell); faceSometimes(c, shell, pl, now); return nil end
        if dist > s.followFar or c.move ~= nil then
            local slot = tonumber(c.spec.slot) or 0
            local ang = slot * 2.1
            local tx, ty = math.floor(px + math.cos(ang) * 1.5), math.floor(py + math.sin(ang) * 1.5)
            local r = moveTo(uid, c, actor, shell, tx, ty, math.floor(pz or 0), dist > s.runTiles and "run" or "walk", 1.5, now)
            if r == "stuck" then return "release", "can't find a path to you" end
        end
        return nil
    end
    local a = c.spec.anchor
    if type(a) ~= "table" then local x, y, z = pos(shell); a = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }; c.spec.anchor = a end
    local r = moveTo(uid, c, actor, shell, a.x, a.y, a.z, "walk", tonumber(c.spec.radius) or s.holdRadius, now)
    if r == "stuck" then return "release", "can't reach the " .. mode .. " spot" end
    if r == "here" then haltBody(shell); if c.spec.faceTo then faceSometimes(c, shell, c.spec.faceTo, now) end end
    return nil
end
-- resident of your base: inside the home radius A-Life's own base life runs ("pass"); once they drift out of it they
-- are walked home by the patch (A-Life's step skipped meanwhile). Daily activities (higher priority) take over when chosen.
function P.ownCtl.resident(uid, c, actor, shell, now)
    local a = c.spec.anchor
    if type(a) ~= "table" then return "release", "no home spot" end
    local radius = tonumber(c.spec.radius) or P.settings.own.residentRadius
    local b = c.spec.bounds -- 1.4.3: A-Life's own house bounds (+ pad) are "home" when known; else the radius
    local hasB = type(b) == "table" and tonumber(b.x1) ~= nil and tonumber(b.y1) ~= nil and tonumber(b.x2) ~= nil and tonumber(b.y2) ~= nil
    local pad = hasB and (tonumber(c.spec.pad) or 3) or 0
    if c.move == nil then
        local x, y = pos(shell)
        if x and hasB then
            if x >= b.x1 - pad and x <= b.x2 + 1 + pad and y >= b.y1 - pad and y <= b.y2 + 1 + pad then c.home = true; return "pass" end
        elseif x and (x - (a.x + 0.5)) ^ 2 + (y - (a.y + 0.5)) ^ 2 <= radius * radius then c.home = true; return "pass" end
    end
    local r = moveTo(uid, c, actor, shell, a.x, a.y, a.z, "walk", hasB and 2.5 or math.max(1.5, radius - 3), now)
    if r == "stuck" then return "release", "can't reach home" end
    if r == "here" then c.home = true; return "pass" end
    if c.home ~= false then c.home = false; ownLog("resident " .. who(uid, actor) .. " drifted from the base - walking home", "home|" .. uid, 30000) end
    return nil
end
-- 0.6.17 leaving: walk away toward spec.anchor (the client moves the anchor on as they go); "here" = waiting for the
-- next point. Stuck: handed back (the client lets them go out of sight another way).
function P.ownCtl.leave(uid, c, actor, shell, now)
    local a = c.spec.anchor
    if type(a) ~= "table" then return "release", "nowhere to go" end
    local r = moveTo(uid, c, actor, shell, a.x, a.y, a.z or 0, c.spec.pace or "walk", 2.0, now)
    if r == "stuck" then c.spec.stuck = true; return "release", "can't find a way out" end
    if r == "here" then c.spec.arrived = true end
    return nil
end
-- 0.8.3 step 8: they come to you with something to say. Walk up to the player (spec.player), stop a step away,
-- face them and wait (spec.arrived = true; the client says the line). Lost / no path: handed back to A-Life.
function P.ownCtl.approach(uid, c, actor, shell, now)
    local pl = c.spec.player
    if pl == nil then return "release", "no player" end
    local inCar = false
    pcall(function() inCar = pl:getVehicle() ~= nil end)
    if inCar then return "release", "player in a vehicle" end
    local px, py, pz = pos(pl)
    local x, y = pos(shell)
    if px == nil or x == nil then return "release", "no position" end
    local dist = math.sqrt((px - x) ^ 2 + (py - y) ^ 2)
    if dist > P.settings.own.lostTiles then return "release", "you went too far" end
    if dist <= 2.0 then
        cancelMove(uid, c, actor)
        haltBody(shell)
        faceSometimes(c, shell, pl, now)
        c.spec.arrived = true
        return nil
    end
    local ang = math.atan2(y - py, x - px) -- stop on their side of you, not behind you
    local tx, ty = math.floor(px + math.cos(ang) * 1.5), math.floor(py + math.sin(ang) * 1.5)
    local r = moveTo(uid, c, actor, shell, tx, ty, math.floor(pz or 0), "walk", 1.5, now)
    if r == "stuck" then return "release", "can't find a path to you" end
    return nil
end
-- daily activity: walk to the spot, sit / pose there, keep the pose (reassert when something else replaced it)
function P.ownCtl.activity(uid, c, actor, shell, now)
    local a = P.acts[uid]
    if a == nil then return "release", "activity gone" end
    local why = P.activityYield(uid, a, c.spec.player)
    if why ~= nil then return "release", why end
    local pa = PA()
    local x, y = pos(shell)
    local near = x and (x - (a.x + 0.5)) ^ 2 + (y - (a.y + 0.5)) ^ 2 <= P.settings.own.arriveTiles2
    if not near then
        local r = moveTo(uid, c, actor, shell, a.x, a.y, a.z, "walk", 1.0, now)
        if r == "stuck" then return "release", "can't reach the spot" end
        if not a.walking then a.walking = true; emit("activityStep", uid, "walking", a.kind, "to " .. a.x .. "," .. a.y) end
        return nil
    end
    cancelMove(uid, c, actor)
    if not a.arrived then
        a.arrived = true
        haltBody(shell)
        emit("activityStep", uid, "arrived", a.kind, a.seat and "seat" or "spot")
    end
    if a.seat and not a.snapped and fn(pa.SeatApi, "snap") then
        a.snapped = pcall(pa.SeatApi.snap, shell, a.seat)
        pcall(pa.SeatApi.face, shell, a.seat)
    end
    if a.care and not a.cared then a.cared = true; safe(P.shelterCare, uid, a.care) end
    if a.face then faceSometimes(c, shell, a.face, now) end
    if a.preset and pa.Animations and fn(pa.Animations, "presetOf") and pa.Animations.presetOf(a.preset) ~= nil then
        local cur = pa.Animations.current and pa.Animations.current[shell] or nil
        local want = pa.Animations.presetOf(a.preset)
        local posed = cur ~= nil and pa.Animations.presetOf(cur) == want
        if not a.posed then
            if now - (a.lastPoseAt or -1e12) >= 1500 then
                a.lastPoseAt = now
                local ok, res, why = pcall(pa.Animations.apply, shell, a.preset)
                if ok and res ~= false then a.posed = true; emit("activityStep", uid, "posed", a.kind, a.preset)
                else
                    a.poseFails = (a.poseFails or 0) + 1
                    if a.poseFails >= 4 then
                        emit("activityStep", uid, "noPose", a.kind, "animation " .. tostring(a.preset) .. " refused: " .. tostring(ok and (why or "no reason") or res))
                        a.preset = nil
                    end
                end
            end
        elseif not posed and now - (a.lastPoseAt or -1e12) >= P.settings.own.reassertMs then
            a.lastPoseAt = now
            pcall(pa.Animations.apply, shell, a.preset)
            a.reasserts = (a.reasserts or 0) + 1
            emit("activityStep", uid, "reasserted", a.kind, "pose was " .. tostring(cur or "none"))
        end
    end
    return nil
end

-- one owned step, in place of A-Life's update(); returns true when handled (else the original think runs)
function P.ownThink(uid, now, c)
    uid = tostring(uid)
    local d = decisions()
    if type(d.lanes) == "table" and type(d.lanes.thoughtAtMs) == "table" then d.lanes.thoughtAtMs[uid] = now end
    local actor, shell = readRec(uid), shellOf(uid)
    if actor == nil or shell == nil or (actor.lifecycle ~= nil and actor.lifecycle ~= "active") then P.release(uid, "gone"); return false end
    if now > c.untilMs then P.release(uid, "time up"); return false end
    local danger = P.ownDanger(uid, actor, shell, c, now)
    if danger ~= nil then
        P.own.stats.danger = P.own.stats.danger + 1
        P.release(uid, "danger - " .. danger .. " (A-Life takes over)", true)
        return false
    end
    local ctl = P.ownCtl[c.kind] or P.ownCtl.listen
    local res, why = ctl(uid, c, actor, shell, now)
    if res == "release" then P.release(uid, why or "done"); return false end
    if res == "pass" then -- still owned, but A-Life's own step runs this time (e.g. a resident at home)
        if type(d.states) == "table" and type(d.states[uid]) == "table" and d.states[uid].intent == "alifetalk_owned" then
            d.states[uid].cooldownUntilMs = 0
        end
        return false
    end
    -- A-Life bookkeeping that must not stop while we drive the body
    local pa = PA()
    local ownSt = type(d.states) == "table" and d.states[uid] or nil
    if type(ownSt) == "table" then
        if pa.ProfileHydrator and fn(pa.ProfileHydrator, "wardrobeTick") then pcall(pa.ProfileHydrator.wardrobeTick, actor, shell, ownSt, now) end
        if fn(d, "tickEndurance") then pcall(d.tickEndurance, actor, shell, ownSt, now) end
    end
    parkState(uid, actor, shell, now, false)
    P.own.stats.steps = P.own.stats.steps + 1
    return true
end

function P.installOwn()
    if P.installed.own then return true end
    local d = decisions()
    if not fn(d, "think") then return false end
    P.orig.think = d.think
    d.think = function(uid, now, ...)
        local c = P.own.claims[tostring(uid)]
        if c == nil or P.settings.own.enabled == false then
            if c ~= nil then P.release(uid, "setting 'own' turned off") end
            return P.orig.think(uid, now, ...)
        end
        local ok, handled = pcall(P.ownThink, uid, now, c)
        if ok and handled == true then return nil end
        if not ok then
            P.own.stats.errors = P.own.stats.errors + 1
            ownLog("controller error for " .. tostring(uid) .. " (" .. tostring(c.kind) .. "): " .. tostring(handled) .. " - handed back to A-Life")
            pcall(P.release, uid, "controller error", true)
            P.own.claims[tostring(uid)] = nil
        end
        return P.orig.think(uid, now, ...)
    end
    P.installed.own = true
    log("wrapped DecisionLoop.think (v1.4 behaviour ownership: listen / activity / party / resident; setting own.enabled)")
    return true
end
function P.uninstallOwn()
    local d = decisions()
    if not P.installed.own or d == nil or P.orig.think == nil then return false end
    P.releaseAll("uninstall")
    d.think = P.orig.think
    P.installed.own = nil
    log("DecisionLoop.think restored")
    return true
end
function P.ownSummary()
    local kinds = {}
    for _, c in pairs(P.own.claims) do kinds[c.kind] = (kinds[c.kind] or 0) + 1 end
    local parts = {}
    for _, k in ipairs({ "listen", "party", "activity", "resident", "leave" }) do if kinds[k] then parts[#parts + 1] = k .. " " .. kinds[k] end end
    local st = P.own.stats
    return "owned " .. P.ownCount() .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "") .. "; claims " .. st.claims
        .. ", releases " .. st.releases .. ", danger hand-backs " .. st.danger .. ", refused " .. st.refused .. ", errors " .. st.errors
end

----------------------------------------------------------------------------------------------------------------
-- 13) v1.4.0 / v1.4.2: DORMANT DEATH GUARD - protects NPCs from "dying from getting too far": when an old leftover
--     body of an NPC who is already dormant (unloaded) dies far away with no cause, A-Life's Lifecycle.onShellDeath
--     would mark the PERSON dead (the "vanishing NPC" bug). 1.4.2 narrows it - a death is only reversed when ALL hold:
--       * the record is dormant (unloaded) and the generation matches (a leftover of THIS life)
--       * the uid is not on the final-deaths list (section 14)
--       * no real damage: no attacker / killer (player, NPC, zombie), not killed by zombies, not burning, no bite
--       * the body is outside the player's loaded range (P.settings.keep.dormantGuardSafeTiles, default 70 tiles)
--       * the loop breaker has not fired (the same uid did not already "die" within death.loopWindowMin minutes)
--     Anything else is a real death and goes to A-Life untouched. Setting: P.settings.keep.dormantDeathGuard.
----------------------------------------------------------------------------------------------------------------
P.settings.keep.dormantDeathGuard = true
P.settings.keep.dormantGuardTiles = 30      -- (1.4.0 setting, kept for old configs; 1.4.2 uses dormantGuardSafeTiles)
P.settings.keep.dormantGuardSafeTiles = 70  -- inside this many tiles of the player a death is always real
local function deathLog(msg) print("[ALifeTalk][Death] " .. tostring(msg)) end
P.deathLog = deathLog
-- what really killed this body (nil = no damage cause found)
function P.damageCause(shell)
    if shell == nil then return nil end
    local killer = nil
    pcall(function() killer = shell:getAttackedBy() end)
    if killer == nil then
        pcall(function() local H = PA().Health; if type(H) == "table" and type(H.lastAttacker) == "table" then killer = H.lastAttacker[shell] end end)
    end
    if killer ~= nil and killer ~= shell then
        local pl = ALifeSide.you()
        if killer == pl or ALifeSide.isOnlinePlayer(killer) then return "player" end -- pre-1.0 MP: any player
        local kuid = nil
        pcall(function() local md = killer:getModData(); kuid = type(md) == "table" and md.ProjectALifeUID or nil end)
        if kuid ~= nil then return "npc" end
        local isP, isZ = false, false
        pcall(function() isP = instanceof(killer, "IsoPlayer") == true; isZ = instanceof(killer, "IsoZombie") == true end)
        if isP then return "player" end
        if isZ then return "zombie" end
        return "attacker"
    end
    local byZ = false
    pcall(function() byZ = PA().Lifecycle.killedByZombie(shell) == true end)
    if byZ then return "zombie" end
    local fire = false
    pcall(function() fire = shell:isOnFire() == true end)
    if fire then return "fire" end
    local bitten = false
    local bd = shell and shell:getBodyDamage()
    if bd then
        pcall(function() bitten = (tonumber(bd:getNumPartsBitten()) or 0) > 0 end)
    end
    if bitten then return "bite" end
    local kind = nil
    pcall(function() local KA = PA().KillAttribution; kind = KA.peek(shell) end)
    if kind ~= nil then return tostring(kind) end
    return nil
end
function P.dormantShellDeath(shell)
    if P.settings.keep.dormantDeathGuard == false or shell == nil then return false end
    local uid, gen = nil, nil
    pcall(function() local md = shell:getModData(); uid = md.ProjectALifeUID; gen = tonumber(md.ProjectALifeGeneration) end)
    if uid == nil then return false end
    uid = tostring(uid)
    local r = readRec(uid)
    if type(r) ~= "table" or r.lifecycle ~= "dormant" then return false end
    if gen ~= nil and tonumber(r.generation) ~= nil and tonumber(r.generation) ~= gen then return false end
    if P.isFinalDead and P.isFinalDead(uid) then return false end
    local cause = P.damageCause(shell)
    if cause ~= nil then
        deathLog(who(uid, r) .. " died while dormant from real damage (" .. cause .. ") - the guard does not undo it, the death is final")
        return false
    end
    local pl = ALifeSide.nearestTo(shell) or ALifeSide.you() -- pre-1.0 MP: the player nearest them
    local x, y = pos(shell)
    local px, py = pos(pl)
    local safe = tonumber(P.settings.keep.dormantGuardSafeTiles) or 70
    if x == nil or px == nil or (x - px) ^ 2 + (y - py) ^ 2 <= safe * safe then
        deathLog(who(uid, r) .. " died inside your loaded range - real death, not reversed")
        return false
    end
    if P.noteDeath and P.noteDeath(uid, "guard") >= 2 then
        deathLog("loop breaker: " .. who(uid, r) .. " 'died' again within " .. tostring(P.settings.death.loopWindowMin)
            .. " min - the guard stops protecting them, the death is final")
        return false
    end
    pcall(function() shell:setReanimate(false); shell:setFakeDead(false) end)
    log("[Keep] ignored the death of a leftover body of dormant " .. who(uid, r) .. " - they stay alive (A-Life would have marked them dead)")
    emit("dormantDeathIgnored", uid)
    return true
end
function P.installDormantGuard()
    if P.installed.dormantGuard then return true end
    local pa = PA()
    local Life = pa and pa.Lifecycle
    if not fn(Life, "onShellDeath") then return false end
    P.orig.onShellDeath = Life.onShellDeath
    Life.onShellDeath = function(shell, ...)
        local ok, skip = pcall(P.dormantShellDeath, shell)
        if ok and skip == true then return false, "alifetalk_dormant_guard" end
        local t0 = nowMs()
        local a, b = P.orig.onShellDeath(shell, ...)
        pcall(P.afterShellDeath, shell, a, b)
        if P.perfAdd then P.perfAdd("death", nowMs() - t0) end
        return a, b
    end
    P.installed.dormantGuard = true
    log("wrapped Lifecycle.onShellDeath (dormant death guard 1.4.2: only cause-less deaths of unloaded NPCs far away are undone; real deaths are final)")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- 14) v1.4.2: FINAL DEATHS + DEATH-LOOP BREAKER. Once A-Life marks a person dead the uid goes on a saved list
--     (ModData "ALifeTalkFinalDeaths", shared with A-Life Talk). Nothing brings that uid back: the dormant guard,
--     Keep (protection / seeds / companions / keep marks), and every A-Life respawn under the same uid
--     (SpawnService.request is refused). A record that something else flips back to dormant is put back to dead.
--     Respawns ordered by the leftover files ALifeTalk_RespawnGuard.lua ("talkrespawn:") are always refused.
--     Settings: P.settings.death.final (master), loopWindowMin, blockForeignRespawn, watchMs.
----------------------------------------------------------------------------------------------------------------
P.settings.death = { final = true, loopWindowMin = 10, blockForeignRespawn = true, watchMs = 5000 }
P.hooks.finalDeath = P.hooks.finalDeath or {}
P.deathTimes = {}
P.fdData = nil
function P.finalStore()
    if P.fdData ~= nil then return P.fdData end
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeTalkFinalDeaths") end)
    if type(d) ~= "table" then d = P.fdFallback or {}; P.fdFallback = d else P.fdData = d end
    d.uids = type(d.uids) == "table" and d.uids or {}
    return d
end
function P.isFinalDead(uid)
    if uid == nil or P.settings.death.final == false then return false end
    return P.finalStore().uids[tostring(uid)] ~= nil
end
-- remembers a death time; returns how many deaths of this uid fall inside the loop window
function P.noteDeath(uid, kind)
    uid = tostring(uid)
    local now = nowMs()
    local win = (tonumber(P.settings.death.loopWindowMin) or 10) * 60000
    local list = P.deathTimes[uid] or {}
    local keep = {}
    for _, t in ipairs(list) do if now - t <= win then keep[#keep + 1] = t end end
    keep[#keep + 1] = now
    P.deathTimes[uid] = keep
    return #keep
end
function P.markFinalDead(uid, why, r)
    if P.settings.death.final == false or uid == nil then return false end
    uid = tostring(uid)
    local d = P.finalStore()
    if d.uids[uid] ~= nil then return false end
    r = r or readRec(uid)
    d.uids[uid] = { h = hours(), why = tostring(why or "died"), name = nameOfRec(r) }
    -- drop everything that could bring them back
    local pd = P.store()
    if type(pd.keep) == "table" then pd.keep[uid] = nil end
    pd.companions[uid] = nil
    pd.ordered[uid] = nil
    if type(pd.seeds) == "table" then
        local drop = {}
        for k, s in pairs(pd.seeds) do if type(s) == "table" and tostring(s.uid) == uid then drop[#drop + 1] = k end end
        for _, k in ipairs(drop) do pd.seeds[k] = nil end
    end
    deathLog(who(uid, r) .. " died for good (" .. tostring(why or "died") .. ") - final: no guard, keep or respawn brings them back")
    emit("finalDeath", uid, tostring(why or "died"))
    return true
end
-- force a record back to dead (used when something else revived a final uid while it is not walking around)
function P.putBackDead(uid, why)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    local r = readRec(uid)
    if not fn(reg, "update") or type(r) ~= "table" or r.lifecycle == "dead" or r.lifecycle == "active" or r.lifecycle == "spawning" then return false end
    local okC, res = pcall(reg.update, tostring(uid), r.revision, function(rec)
        rec.lifecycle = "dead"; rec.activity = "dead"; rec.intent = "none"
        if type(rec.memory) == "table" then rec.memory.forceRespawn = nil end
    end)
    local ok = okC and res ~= nil and res ~= false
    if ok then deathLog(who(uid, r) .. " was brought back by something else (" .. tostring(why) .. ") - put back to dead") end
    return ok
end
-- after A-Life handled a shell death: a dead record = final; repeated deaths = loop breaker
function P.afterShellDeath(shell, a, b)
    local uid = nil
    pcall(function() uid = shell:getModData().ProjectALifeUID end)
    if uid == nil then return end
    uid = tostring(uid)
    local r = readRec(uid)
    -- only a death A-Life really recorded counts (a stale body A-Life rejected is not a death of the person)
    if type(r) ~= "table" or r.lifecycle ~= "dead" then return end
    local n = P.noteDeath(uid, "death")
    if n >= 2 then
        deathLog("loop breaker: " .. who(uid, r) .. " died " .. n .. " times within " .. tostring(P.settings.death.loopWindowMin) .. " min - dead permanently")
        P.deathStats.breaker = (P.deathStats.breaker or 0) + 1
    end
    P.markFinalDead(uid, n >= 2 and "death loop" or ("killed (" .. tostring(P.damageCause(shell) or "unknown cause") .. ")"), r)
end
local function isForeignOp(op)
    op = tostring(op or "")
    return string.sub(op, 1, 12) == "talkrespawn:"
end
P.refusedLogAt = {}
function P.installFinalDeaths()
    if P.installed.finalDeaths then return true end
    local pa = PA()
    local SS = pa and pa.SpawnService
    if not fn(SS, "request") then return false end
    P.orig.spawnRequest = SS.request
    SS.request = function(uid, operationId, ...)
        local u = tostring(uid)
        local refuse = nil
        if P.isFinalDead(u) then refuse = "died for good"
        elseif P.settings.death.blockForeignRespawn ~= false and isForeignOp(operationId) then refuse = "respawn ordered by the leftover file ALifeTalk_RespawnGuard.lua (delete it)" end
        if refuse ~= nil then
            local now = nowMs()
            if now - (P.refusedLogAt[u] or -1e12) >= 60000 then
                P.refusedLogAt[u] = now
                deathLog("refused to respawn " .. who(u) .. ": " .. refuse .. " (op " .. tostring(operationId) .. ")")
            end
            P.deathStats.refused = P.deathStats.refused + 1
            return nil, "alifetalk_final_death"
        end
        return P.orig.spawnRequest(uid, operationId, ...)
    end
    P.installed.finalDeaths = true
    log("wrapped SpawnService.request (final deaths: dead people are never respawned under the same uid)")
    safe(P.finalRepair)
    return true
end
P.deathStats = { refused = 0, putBack = 0, repaired = 0 }
-- on load: records the leftover RespawnGuard revived (memory.forceRespawn) were really dead -> final + dead again
function P.finalRepair()
    local reg = PA() and PA().ActorRegistry
    if not fn(reg, "each") then return 0 end
    local found = {}
    reg.each(function(r)
        if type(r) == "table" and type(r.memory) == "table" and r.memory.forceRespawn == true and r.lifecycle ~= "dead" then found[#found + 1] = r end
        return false
    end)
    for _, r in ipairs(found) do
        P.markFinalDead(r.uid, "revived by ALifeTalk_RespawnGuard.lua after a real death (repaired on load)", r)
        if P.putBackDead(r.uid, "repair on load") then P.deathStats.repaired = P.deathStats.repaired + 1 end
    end
    if #found > 0 then deathLog("repair: " .. #found .. " person(s) a leftover file had brought back from the dead are dead again (they stay in your people book)") end
    return #found
end
function P.finalWatch()
    if P.settings.death.final == false then return end
    for uid in pairs(P.finalStore().uids) do
        local r = readRec(uid)
        if type(r) == "table" and r.lifecycle ~= "dead" and P.putBackDead(uid, "watch") then P.deathStats.putBack = P.deathStats.putBack + 1 end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 15) v1.4.2: DISTANCE IS NOT DESERTION. A-Life's Party.service ends your group as "desert" ("The group moved on
--     without you" + a left-behind bark, and -8 opinion when it happens in danger) once you have been more than
--     45 tiles from every member for 10 minutes - so going home ended the group. Refused here: the group stays,
--     the away clock restarts. Leaving / kicking / hostility / your death still end it as before.
--     Setting: P.settings.party.keepWhenAway. On load, -8 "You left them when it mattered." opinion hits that are
--     still the last word are refunded once.
----------------------------------------------------------------------------------------------------------------
P.settings.party = P.settings.party or {}
P.settings.party.keepWhenAway = true
P.desertText = "You left them when it mattered."
function P.installPartyAway()
    if P.installed.partyAway then return true end
    local pa = PA()
    local Party = pa and pa.Party
    if not fn(Party, "finish") then return false end
    P.orig.partyFinish = Party.finish
    Party.finish = function(key, reason, ...)
        if reason == "desert" and P.settings.party.keepWhenAway ~= false then
            pcall(function()
                local st = Party.state and Party.state.players and Party.state.players[key]
                if type(st) == "table" then st.lastNearMs = nowMs() end
            end)
            local now = nowMs()
            if now - (P.partyAwayLogAt or -1e12) >= 600000 then
                P.partyAwayLogAt = now
                print("[ALifeTalk][Party] kept your A-Life group: you were only far away (A-Life would have ended it as 'desert')")
            end
            return false
        end
        return P.orig.partyFinish(key, reason, ...)
    end
    P.installed.partyAway = true
    log("wrapped Party.finish (being far away / going home no longer ends your group)")
    safe(P.partyDesertRefund)
    return true
end
function P.partyDesertRefund()
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    local Op = pa and pa.NpcOpinion
    local pl = ALifeSide.you()
    if not fn(reg, "each") or not fn(Op, "adjust") or pl == nil then return 0 end
    local key = playerKey(pl)
    if key == nil then return 0 end
    local d = P.store()
    d.desertRefund = type(d.desertRefund) == "table" and d.desertRefund or {}
    local list = {}
    reg.each(function(r)
        local m = type(r) == "table" and r.memory or nil
        local row = type(m) == "table" and type(m.opinion) == "table" and m.opinion[key] or nil
        if type(row) == "table" and row.why == P.desertText and r.lifecycle ~= "dead" and not d.desertRefund[tostring(r.uid)] then list[#list + 1] = r end
        return false
    end)
    for _, r in ipairs(list) do
        d.desertRefund[tostring(r.uid)] = hours()
        -- the exact -8 back (A-Life's own row write; no personality scaling on the way back)
        local back = 8
        pcall(function() back = Op.rounded(8 * Op.scale()) end)
        local okW = false
        if fn(Op, "write") then
            okW = pcall(Op.write, r.uid, function(memory)
                local row = type(memory.opinion) == "table" and memory.opinion[key] or nil
                if type(row) == "table" then
                    row.v = fn(Op, "clamp") and Op.clamp((tonumber(row.v) or 0) + back) or ((tonumber(row.v) or 0) + back)
                    row.why = "You were only away; no hard feelings."
                end
            end)
        end
        if not okW then pcall(Op.adjust, r, pl, back, "You were only away; no hard feelings.") end
        print("[ALifeTalk][Party] restored " .. who(r.uid, r) .. "'s opinion: the -8 for 'leaving them' came from being far away")
    end
    return #list
end

-- 1.4.2: perf counters (only while A-Life Talk's perfLog setting is on; A-Life Talk prints them every 30 s)
P.perf = {}
function P.perfOn() return type(ALifeLLMTalk) == "table" and type(ALifeLLMTalk.settings) == "table" and ALifeLLMTalk.settings.perfLog == true end
function P.perfAdd(name, ms)
    if not P.perfOn() then return end
    local h = P.perf[name] or { ms = 0, calls = 0 }
    P.perf[name] = h
    h.ms = h.ms + (tonumber(ms) or 0); h.calls = h.calls + 1
end
function P.perfTake(sec)
    local parts = {}
    for name, h in pairs(P.perf) do
        if h.calls > 0 then parts[#parts + 1] = "patch:" .. name .. "=" .. ALifeFmtDec(h.ms / math.max(1, sec), 2) .. "ms/s(" .. h.calls .. ")" end
        h.ms, h.calls = 0, 0
    end
    if #parts > 0 then print("[ALifeTalk][Perf] " .. table.concat(parts, " ")) end
end
P.orig = {}
P.installed = {}
function P.install()
    local pa = PA()
    if pa == nil then return false end
    local Rel = pa.Relations
    if not P.installed.relations and type(Rel) == "table" and fn(Rel, "hostileToPlayer") and fn(Rel, "playerStance") and fn(Rel, "status") then
        P.orig.hostileToPlayer, P.orig.playerStance, P.orig.status = Rel.hostileToPlayer, Rel.playerStance, Rel.status
        P.orig.noteAggression = Rel.noteAggression
        Rel.hostileToPlayer = function(actor, player, ...)
            local okp, paused = pcall(P.pausedFor, actor, player) -- v1.3: "wait!" - listening for a few seconds
            if okp and paused ~= nil then return false end
            local okc, entry = pcall(calmedFor, actor, player)
            if okc and entry ~= nil then
                local oka, attacked = pcall(P.underAttack, actor, player)
                if oka and not attacked then return false end
            end
            return P.orig.hostileToPlayer(actor, player, ...)
        end
        Rel.playerStance = function(actor, player, ...)
            local stance = P.orig.playerStance(actor, player, ...)
            if stance == "hostile" then
                local okp, paused = pcall(P.pausedFor, actor, player)
                if okp and paused ~= nil then return "careful" end
                local okc, entry = pcall(calmedFor, actor, player)
                if okc and entry ~= nil then
                    local oka, attacked = pcall(P.underAttack, actor, player)
                    if oka and not attacked then return "careful" end
                end
            end
            return stance
        end
        Rel.status = function(source, target, ...)
            local d = P.data
            if d ~= nil and type(source) == "table" and type(target) == "table" and source.uid ~= nil then
                local row = d.pairs[source.uid]
                local o = row and row[target.uid]
                if o ~= nil and (o.untilH or 0) > P.hoursNow and Rel.warfare ~= false then return o.s end
            end
            return P.orig.status(source, target, ...)
        end
        if fn(Rel, "noteAggression") then
            Rel.noteAggression = function(aggressor, victim, now, ...)
                local result = P.orig.noteAggression(aggressor, victim, now, ...)
                pcall(function()
                    if type(instanceof) == "function" and instanceof(aggressor, "IsoPlayer") then
                        local rec = Rel.actorRecord(victim)
                        local key = playerKey(aggressor)
                        if rec and key then
                            P.lastHitMs[tostring(rec.uid) .. "|" .. key] = nowMs()
                            if P.calmEntry(rec.uid, key) then P.endCalm(rec.uid, key, "you attacked them", true) end
                        end
                    end
                end)
                return result
            end
        end
        if Rel.setPairStance == nil then Rel.setPairStance = P.setPairStance end -- extension (never replaces A-Life's own)
        if Rel.pairStance == nil then Rel.pairStance = P.pairStance end
        P.installed.relations = true
        log("wrapped Relations.hostileToPlayer, playerStance, status, noteAggression")
    end
    if not P.installed.calmdown and type(pa.CalmDown) == "table" then
        if pa.CalmDown.plead == nil then pa.CalmDown.plead = P.plead end
        P.installed.calmdown = true
    end
    local Talk = pa.Talk
    if not P.installed.walk and fn(Talk, "walkWith") then
        P.orig.walkWith = Talk.walkWith
        Talk.walkWith = function(player, listener, intent, ...)
            local ok, words = P.orig.walkWith(player, listener, intent, ...)
            pcall(function()
                if ok and P.settings.companion.enabled and P.settings.companion.autoAll and intent == "WALK_WITH_ME"
                        and P.companionOf(listener.record.uid) == nil then P.startCompanion(player, listener)
                elseif ok and intent == "WALK_STOP" then P.stopCompanion(listener.record.uid, "stop") end
            end)
            return ok, words
        end
        P.installed.walk = true
        log("wrapped Talk.walkWith (companion mode)")
    end
    local Reg = pa.ModuleRegistry
    if not P.installed.stance and fn(Reg, "get") then
        local module = Reg.get("stance")
        if type(module) == "table" and type(module.evaluate) == "function" then
            P.orig.stanceEvaluate = module.evaluate
            module.evaluate = function(actor, shell, context, ...)
                if P.settings.companion.enabled and type(actor) == "table" and P.data ~= nil and P.data.companions[actor.uid] ~= nil then
                    local ok, result, handled = pcall(P.companionEvaluate, actor, shell, context)
                    if ok and handled then return result end
                    if not ok then log("companion evaluate error: " .. tostring(result)) end
                end
                return P.orig.stanceEvaluate(actor, shell, context, ...)
            end
            P.installed.stance = true
            log("wrapped stance module evaluate (companion movement)")
        end
    end
    if not P.installed.weapons and fn(pa.Combat, "preferredWeapon") then
        P.orig.preferredWeapon = pa.Combat.preferredWeapon
        pa.Combat.preferredWeapon = function(shell, weapon, target, distance, facts, actor, ...)
            local wanted = P.orig.preferredWeapon(shell, weapon, target, distance, facts, actor, ...)
            if P.settings.nemesis.enabled and P.data ~= nil and P.hasAny(P.data.nemesis) then
                local ok, w, handled = pcall(P.weaponFor, shell, weapon, target, wanted)
                if ok and handled then return w end
            end
            return wanted
        end
        P.installed.weapons = true
        log("wrapped Combat.preferredWeapon (nemesis weapon tiers)")
    end
    if not P.installed.revenge and fn(pa.Revenge, "owed") then
        P.orig.owed = pa.Revenge.owed
        pa.Revenge.owed = function(factionId, key, ...)
            local untilH = P.owedFactions[tostring(factionId) .. "|" .. tostring(key)]
            if untilH and untilH > hours() then return true end
            return P.orig.owed(factionId, key, ...)
        end
        P.installed.revenge = true
        log("wrapped Revenge.owed (personal nemesis contracts are not forgiven by faction reputation)")
    end
    if not P.installed.names and fn(pa.Names, "shown") then -- v1.3: a fake name they gave you shows until exposed
        P.orig.namesShown = pa.Names.shown
        pa.Names.shown = function(record, key, ...)
            local name, known = P.orig.namesShown(record, key, ...)
            if type(record) == "table" and key ~= nil then
                local okF, fake = pcall(P.fakeNameOf, record.uid, key)
                if okF and type(fake) == "string" then return fake, true end
            end
            return name, known
        end
        P.installed.names = true
        log("wrapped Names.shown (fake names)")
    end
    local Reg2 = pa.ActorRegistry -- v1.3: keep the people you know; squad members come back as themselves
    if not P.installed.keep and fn(Reg2, "remove") and fn(Reg2, "create") then
        P.orig.regRemove, P.orig.regCreate = Reg2.remove, Reg2.create
        Reg2.remove = function(uid, expectedRevision, reason, ...)
            local ok, a, b = pcall(P.keepRemove, P.orig.regRemove, uid, expectedRevision, reason, ...)
            if ok then return a, b end
            log("keep error: " .. tostring(a))
            return P.orig.regRemove(uid, expectedRevision, reason, ...)
        end
        Reg2.create = function(spec, ...)
            local ok, a, b = pcall(P.keepCreate, P.orig.regCreate, spec, ...)
            if ok then return a, b end
            log("keep error: " .. tostring(a))
            return P.orig.regCreate(spec, ...)
        end
        P.installed.keep = true
        log("wrapped ActorRegistry.remove / create (known NPCs are not culled; squad members keep their identity)")
    end
    local Life = pa.Lifecycle
    if not P.installed.turn and fn(Life, "stepTurn") then
        P.orig.stepTurn = Life.stepTurn
        Life.stepTurn = function(entry, body, now, ...)
            local info = nil
            pcall(function()
                local x, y, z = pos(body)
                local female = false
                pcall(function() female = body:isFemale() == true end)
                info = { x = x, y = y, z = z, female = female }
            end)
            local done = P.orig.stepTurn(entry, body, now, ...)
            if done == true and info and info.x and type(entry) == "table" and entry.uid then
                info.atMs = nowMs()
                P.reanimating[tostring(entry.uid)] = info
                log("reanimating: " .. tostring(entry.uid))
                emit("reanimating", tostring(entry.uid), info)
            end
            return done
        end
        P.installed.turn = true
        log("wrapped Lifecycle.stepTurn (who a reanimated zombie was)")
    end
    if not P.installed.mercy then
        local Op, Rev, Act = pa.NpcOpinion, pa.Revenge, pa.HostileAct
        if fn(Op, "noteKill") then
            P.orig.noteKill = Op.noteKill
            Op.noteKill = function(victim, killerKey, killer, ...)
                if P.isMercy(victim, nil) then log("mercy: A-Life group opinion hit skipped (victim was infected)"); emit("mercy", victim, "noteKill"); return nil end
                return P.orig.noteKill(victim, killerKey, killer, ...)
            end
        end
        if fn(Rev, "onActorDied") then
            P.orig.revengeDied = Rev.onActorDied
            Rev.onActorDied = function(actor, shell, kind, key, x, y, ...)
                if P.isMercy(actor, shell) then log("mercy: no revenge for an infected victim"); return nil end
                return P.orig.revengeDied(actor, shell, kind, key, x, y, ...)
            end
        end
        if fn(Act, "noteKill") then
            P.orig.actNoteKill = Act.noteKill
            Act.noteKill = function(player, record, now, ...)
                if P.isMercy(record, nil) then return nil end
                return P.orig.actNoteKill(player, record, now, ...)
            end
        end
        P.installed.mercy = true
        log("wrapped NpcOpinion.noteKill / Revenge.onActorDied / HostileAct.noteKill (mercy kills of the infected)")
    end
    safe(P.installOwn)          -- v1.4.0
    safe(P.installDormantGuard) -- v1.4.0
    safe(P.installFinalDeaths)  -- v1.4.2
    safe(P.installPartyAway)    -- v1.4.2
    return P.installed.relations and P.installed.walk and P.installed.stance
end

P.nextCalmAt, P.nextCompAt, P.nextPruneAt, P.nextAttackAt, P.nextShelterAt, P.nextGroupAt = 0, 0, 0, 0, 0, 0
function P.onTick()
    if not (P.installed.relations and P.installed.walk and P.installed.stance) then safe(P.install) end
    P.store()
    local now = nowMs()
    if not (P.installed.own and P.installed.dormantGuard and P.installed.finalDeaths and P.installed.partyAway) and now >= (P.nextOwnInstallAt or 0) then
        P.nextOwnInstallAt = now + 5000; safe(P.installOwn); safe(P.installDormantGuard); safe(P.installFinalDeaths); safe(P.installPartyAway)
    end
    if now >= (P.nextFinalAt or 0) then P.nextFinalAt = now + (tonumber(P.settings.death.watchMs) or 5000); safe(P.finalWatch) end
    local player = ALifeSide.you()
    -- pre-1.0 MP (P3): player ticks run once per living online player (single player: you, as before)
    local function each(f) if ALifeSide.mpServer() then ALifeSide.each(function(p) safe(f, p) end) else safe(f, player) end end
    if now >= P.nextPruneAt then P.nextPruneAt = now + 10000; safe(P.prunePairs) end
    if now >= P.nextCalmAt then P.nextCalmAt = now + P.settings.calm.checkMs; each(P.calmTick) end
    if now >= P.nextCompAt then P.nextCompAt = now + P.settings.companion.tickMs; each(P.companionTick) end
    if now >= P.nextAttackAt then P.nextAttackAt = now + P.settings.attack.tickMs; each(P.attackTick) end
    if now >= (P.nextLastWarnAt or 0) then P.nextLastWarnAt = now + 500; safe(P.lastWarnTick) end -- 0.8.12
    if now >= P.nextShelterAt then P.nextShelterAt = now + P.settings.shelter.tickMs; each(P.shelterTick) end
    if now >= P.nextGroupAt then P.nextGroupAt = now + 4000; each(P.groupTick) end
    if now >= (P.nextWoundAt or 0) then P.nextWoundAt = now + 1000; safe(P.woundTick) end
    if now >= (P.nextKeepAt or 0) then P.nextKeepAt = now + 1000; each(P.teleportCheck) end
    if now >= (P.nextCatchAt or 0) then P.nextCatchAt = now + 5000; each(P.companionCatchUp) end
    if now >= (P.nextActAt or 0) then P.nextActAt = now + P.settings.activity.tickMs; safe(P.activityTick, player) end
end

safe(P.install)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() safe(P.install); P.data = nil; P.store() end) end
    if Events.OnTick then -- 1.3.1: one keep summary ~10 s into the session (after A-Life Talk registered its protectors)
        local t0, done = nil, false
        ALifeHealth.add(Events.OnTick, "ALifeTalkPatch", function()
            if done then return end
            local now = nowMs()
            t0 = t0 or now
            if now - t0 >= 10000 then done = true; if P.installed.keep then pcall(P.keepSummary) end end
        end)
    end
    if Events.OnTick then ALifeHealth.add(Events.OnTick, "ALifeTalkPatch", function()
        local t0 = P.perfOn() and nowMs() or nil
        local ok, e = pcall(P.onTick); if not ok then log("tick error: " .. tostring(e)) end
        if t0 ~= nil then P.perfAdd("onTick", nowMs() - t0) end
    end) end
end
log("v" .. P.VERSION .. " loaded")
return P
