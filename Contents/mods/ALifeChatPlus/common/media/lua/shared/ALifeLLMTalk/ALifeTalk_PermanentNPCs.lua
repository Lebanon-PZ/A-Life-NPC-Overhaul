-- ALifeTalk_PermanentNPCs.lua (v3 - performance fix)
-- Drop into the Talk mod.
-- Much lighter: no full registry scans every tick, heavy work only every few seconds.

require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_PermanentNPCs") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local TAG = "ALifeTalk_NPCCopies"
local Copies = {
    data = nil,
    pendingRespawn = {},
    lastHeavy = 0,
    heavyIntervalMs = 4000,     -- full protect + capture only every 4s
    respawnCheckMs = 2500,
    lastRespawnCheck = 0,
    respawnRadius = 45,
    maxRespawnTries = 6,
}

local function nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return math.floor(os.time() * 1000)
end

local function getData()
    if Copies.data then return Copies.data end
    local d
    pcall(function() d = ModData.getOrCreate(TAG) end)
    if type(d) ~= "table" then d = {} end
    if type(d.npcs) ~= "table" then d.npcs = {} end
    Copies.data = d
    return d
end

local function save()
    pcall(function()
        if ModData.add then ModData.add(TAG, getData()) end
    end)
end

local function deepCopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local r = {}
    seen[t] = r
    for k, v in pairs(t) do
        r[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return r
end

local function snapshot(actor)
    if type(actor) ~= "table" or type(actor.uid) ~= "string" then return nil end
    return {
        uid = actor.uid,
        generation = actor.generation or 0,
        profileId = actor.profileId,
        factionId = actor.factionId,
        worldPosition = actor.worldPosition and {
            x = actor.worldPosition.x,
            y = actor.worldPosition.y,
            z = actor.worldPosition.z or 0,
        } or nil,
        memory = deepCopy(actor.memory or {}),
        lifecycle = actor.lifecycle,
        savedAtMs = nowMs(),
    }
end

local function store(actor)
    local snap = snapshot(actor)
    if not snap then return end
    local d = getData()
    local old = d.npcs[snap.uid]
    if old == nil or (snap.lifecycle ~= "dead" and (old.lifecycle == "dead" or snap.savedAtMs > (old.savedAtMs or 0))) then
        d.npcs[snap.uid] = snap
        save()
    end
end

local function getStored(uid)
    return getData().npcs[tostring(uid)]
end

-- Relationship tab fallback (light)
local function wrapRelationshipData()
    local M = ALifeLLMTalk
    if type(M) ~= "table" or type(M.relationshipData) ~= "function" or M._permWrapped then return end
    local original = M.relationshipData
    M.relationshipData = function(uid, player)
        local result = original(uid, player)
        if result ~= nil then return result end
        local snap = getStored(uid)
        if not snap then return nil end
        local name = "Someone"
        pcall(function()
            local pa = ProjectALife
            if pa and pa.Names and type(pa.Names.of) == "function" then
                name = pa.Names.of(snap) or name
            end
        end)
        return {
            uid = uid,
            name = name,
            value = 0,
            label = "Away",
            band = "neutral",
            role = snap.profileId or "Survivor",
            rows = {},
            ties = {},
            dead = false,
            away = true,
            stored = true,
            lastPosition = snap.worldPosition,
        }
    end
    M._permWrapped = true
end

local function playerNear(pos, radius)
    if ALifeSide.mpServer() then return type(pos) == "table" and ALifeSide.nearest(pos.x or 0, pos.y or 0, radius) ~= nil end -- MP: any player
    local p = ALifeSide.you()
    if p == nil or type(pos) ~= "table" then return false end
    local dx = p:getX() - (pos.x or 0)
    local dy = p:getY() - (pos.y or 0)
    return (dx * dx + dy * dy) <= (radius * radius)
end

local function tryRespawn(uid, snap)
    local Registry = ProjectALife and ProjectALife.ActorRegistry
    local SpawnService = ProjectALife and ProjectALife.SpawnService
    if not Registry or not SpawnService or type(SpawnService.request) ~= "function" then return false end

    local current = Registry.read(uid)
    if current and (current.lifecycle == "active" or current.lifecycle == "spawning") then
        return true
    end

    local pos = snap.worldPosition
    if not pos then return false end

    pcall(function()
        if current then
            Registry.update(uid, current.revision, function(record)
                record.lifecycle = "dormant"
                record.activity = "idle"
                record.intent = "hold"
                record.worldPosition = { x = pos.x, y = pos.y, z = pos.z or 0 }
                record.memory = deepCopy(snap.memory or {})
                record.profileId = snap.profileId or record.profileId
                record.factionId = snap.factionId or record.factionId
            end)
        end
    end)

    local opId = "perm:" .. uid .. ":" .. tostring(nowMs())
    local fp = uid .. ":" .. tostring(snap.generation or 0)
    local ok, res = pcall(SpawnService.request, uid, opId, fp, 4000)
    return ok and res ~= nil
end

-- Heavy work only every few seconds
local function heavyTick()
    local now = nowMs()
    if now - Copies.lastHeavy < Copies.heavyIntervalMs then return end
    Copies.lastHeavy = now

    -- Capture nearby (only when Talk mod is ready)
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.nearbyNpcs) == "function" then
        for _, p in ipairs(ALifeSide.mpServer() and ALifeSide.online() or { ALifeSide.you() }) do -- MP: near every player
            local list = M.nearbyNpcs(p:getX(), p:getY(), p:getZ(), 50) or {}
            for _, entry in ipairs(list) do
                if entry.record then store(entry.record) end
            end
        end
    end

    -- Light protect: only look at NPCs we already have copies of
    local Registry = ProjectALife and ProjectALife.ActorRegistry
    if Registry and type(Registry.read) == "function" then
        local d = getData()
        for uid, snap in pairs(d.npcs) do
            if snap.lifecycle ~= "dead" then
                local actor = Registry.read(uid)
                if actor and actor.lifecycle == "dead" then
                    pcall(function()
                        Registry.update(uid, actor.revision, function(record)
                            record.lifecycle = "dormant"
                            record.activity = "idle"
                            record.intent = "hold"
                            record.worldPosition = snap.worldPosition or record.worldPosition
                            if type(snap.memory) == "table" then
                                record.memory = deepCopy(snap.memory)
                            end
                        end)
                    end)
                elseif actor and actor.lifecycle ~= "dead" then
                    store(actor) -- refresh copy
                end
            end
        end
    end
end

local function respawnTick()
    local now = nowMs()
    if now - Copies.lastRespawnCheck < Copies.respawnCheckMs then return end
    Copies.lastRespawnCheck = now

    local d = getData()
    for uid, snap in pairs(d.npcs) do
        if snap.worldPosition and playerNear(snap.worldPosition, Copies.respawnRadius) then
            local entry = Copies.pendingRespawn[uid] or { tries = 0 }
            entry.tries = entry.tries + 1
            if entry.tries <= Copies.maxRespawnTries then
                if tryRespawn(uid, snap) then
                    Copies.pendingRespawn[uid] = nil
                else
                    Copies.pendingRespawn[uid] = entry
                end
            end
        else
            Copies.pendingRespawn[uid] = nil
        end
    end
end

local function hookDeath()
    local Lifecycle = ProjectALife and ProjectALife.Lifecycle
    if Lifecycle == nil or Lifecycle._permDeathHooked then return end
    local original = Lifecycle.onShellDeath
    Lifecycle.onShellDeath = function(shell)
        pcall(function()
            local data = shell and shell:getModData()
            local uid = type(data) == "table" and data.ProjectALifeUID
            if uid then
                local actor = ProjectALife.ActorRegistry and ProjectALife.ActorRegistry.read(uid)
                if actor then store(actor) end
            end
        end)
        return original(shell)
    end
    Lifecycle._permDeathHooked = true
end

local installed = false
local function install()
    if installed then return end
    wrapRelationshipData()
    hookDeath()
    if type(Events) == "table" and Events.OnTick then
        ALifeHealth.tickAdd("ALifeTalk_PermanentNPCs", function()
            heavyTick()
            respawnTick()
        end)
    end
    installed = true
end

-- Single delayed install, no stacking listeners
if type(Events) == "table" and Events.OnTick then
    local function once()
        install()
        ALifeHealth.tickRemove(once)
    end
    ALifeHealth.tickAdd("ALifeTalk_PermanentNPCs", once)
else
    install()
end
