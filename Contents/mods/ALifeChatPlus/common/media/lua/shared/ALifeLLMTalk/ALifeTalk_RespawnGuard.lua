-- ALifeTalk_RespawnGuard.lua
-- Put this in the Talk mod. Survives A-Life updates.
-- When a known NPC goes dormant and gets killed/reanimated by the engine,
-- this records them and forces a clean respawn nearby.

require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_RespawnGuard") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local Respawn = {
    pending = {},          -- uid -> { record snapshot, atMs, tries }
    checkIntervalMs = 2000,
    lastCheck = 0,
    maxTries = 5,
    respawnRadius = 25,
}

local function nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return math.floor(os.time() * 1000)
end

local function getPlayerPos()
    local p = ALifeSide.you()
    if p == nil and ALifeSide.mpServer() and type(ALifeLLMTalk) == "table" and type(ALifeLLMTalk.homePlayer) == "function" then p = ALifeLLMTalk.homePlayer() end
    if p == nil then return nil end
    return { x = p:getX(), y = p:getY(), z = p:getZ() }
end

local function snapshotActor(actor)
    if type(actor) ~= "table" then return nil end
    return {
        uid = actor.uid,
        generation = actor.generation,
        profileId = actor.profileId,
        factionId = actor.factionId,
        worldPosition = actor.worldPosition and {
            x = actor.worldPosition.x,
            y = actor.worldPosition.y,
            z = actor.worldPosition.z,
        } or nil,
        memory = actor.memory,
    }
end

local function tryRespawn(uid, snap)
    local SpawnService = ProjectALife and ProjectALife.SpawnService
    local Registry = ProjectALife and ProjectALife.ActorRegistry
    if SpawnService == nil or type(SpawnService.request) ~= "function" then return false end
    if Registry == nil or type(Registry.read) ~= "function" then return false end

    local current = Registry.read(uid)
    if current == nil then return false end

    -- Already active or spawning? Don't interfere.
    if current.lifecycle == "active" or current.lifecycle == "spawning" then
        return true
    end

    local pos = snap.worldPosition or getPlayerPos()
    if pos == nil then return false end

    -- Nudge position a bit so it doesn't land exactly on the corpse
    local ox = (ZombRand and ZombRand(10) or 5) - 5
    local oy = (ZombRand and ZombRand(10) or 5) - 5
    local spawnPos = {
        x = pos.x + ox,
        y = pos.y + oy,
        z = pos.z or 0,
    }

    -- Force the record back to dormant so the spawn system will accept it
    if current.lifecycle == "dead" then
        Registry.update(uid, current.revision, function(record)
            record.lifecycle = "dormant"
            record.activity = "idle"
            record.intent = "hold"
            record.worldPosition = spawnPos
            if type(record.memory) == "table" then
                record.memory.forceRespawn = true
                record.memory.reanimate = false
            end
        end)
    end

    local opId = "talkrespawn:" .. uid .. ":" .. tostring(nowMs())
    local fingerprint = uid .. ":" .. tostring(current.generation or 0)
    local ok, result = pcall(SpawnService.request, uid, opId, fingerprint, 3000)
    return ok and result ~= nil
end

local function onShellDeathHook(shell)
    local Lifecycle = ProjectALife and ProjectALife.Lifecycle
    if Lifecycle == nil or Lifecycle._respawnHooked then return end

    local original = Lifecycle.onShellDeath
    Lifecycle.onShellDeath = function(shell)
        local result = original(shell)

        -- After the original runs, check if this was a known actor that should be saved
        pcall(function()
            local data = shell and shell:getModData()
            if type(data) ~= "table" then return end
            local uid = data.ProjectALifeUID
            if type(uid) ~= "string" then return end

            local Registry = ProjectALife.ActorRegistry
            if Registry == nil then return end
            local actor = Registry.read(uid)
            if actor == nil then return end

            -- Only care about ones that were dormant or just got forced dead by unload
            if actor.lifecycle == "dormant" or actor.lifecycle == "dead" then
                local snap = snapshotActor(actor)
                if snap then
                    Respawn.pending[uid] = {
                        snap = snap,
                        atMs = nowMs(),
                        tries = 0,
                    }
                end
            end
        end)

        return result
    end
    Lifecycle._respawnHooked = true
end

local function tick()
    local now = nowMs()
    if now - Respawn.lastCheck < Respawn.checkIntervalMs then return end
    Respawn.lastCheck = now

    local toRemove = {}
    for uid, entry in pairs(Respawn.pending) do
        entry.tries = entry.tries + 1
        if entry.tries > Respawn.maxTries then
            toRemove[#toRemove + 1] = uid
        else
            local success = tryRespawn(uid, entry.snap)
            if success then
                toRemove[#toRemove + 1] = uid
            end
        end
    end
    for _, uid in ipairs(toRemove) do
        Respawn.pending[uid] = nil
    end
end

-- Install
local function install()
    onShellDeathHook()
    if type(Events) == "table" and Events.OnTick then
        ALifeHealth.tickAdd("ALifeTalk_RespawnGuard", tick)
    end
end

-- Retry install a few times in case Lifecycle isn't ready yet
local installTries = 0
local function tryInstall()
    installTries = installTries + 1
    install()
    if installTries < 30 and (not ProjectALife or not ProjectALife.Lifecycle or not ProjectALife.Lifecycle._respawnHooked) then
        if type(Events) == "table" and Events.OnTick then
            ALifeHealth.tickAdd("ALifeTalk_RespawnGuard", tryInstall)
        end
    end
end

if type(Events) == "table" and Events.OnTick then
    ALifeHealth.tickAdd("ALifeTalk_RespawnGuard", tryInstall)
else
    install()
end
