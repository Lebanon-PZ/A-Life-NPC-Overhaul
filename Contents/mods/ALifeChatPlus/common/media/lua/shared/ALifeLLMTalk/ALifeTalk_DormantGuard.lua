-- ALifeTalk_DormantGuard.lua
-- Drop this into the Talk mod so it survives A-Life updates.
-- It wraps Lifecycle.onShellDeath and ignores death events for dormant actors.

require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_DormantGuard") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local function installGuard()
    local Lifecycle = ProjectALife and ProjectALife.Lifecycle
    if not Lifecycle or type(Lifecycle.onShellDeath) ~= "function" then
        return false
    end

    -- Already patched?
    if Lifecycle._dormantGuardInstalled then
        return true
    end

    local original = Lifecycle.onShellDeath

    Lifecycle.onShellDeath = function(shell)
        if shell == nil then
            return original(shell)
        end

        local ok, uid, generation = pcall(function()
            local data = shell:getModData()
            if type(data) == "table" then
                return data.ProjectALifeUID, tonumber(data.ProjectALifeGeneration)
            end
        end)

        if ok and type(uid) == "string" then
            local Registry = ProjectALife.ActorRegistry
            if Registry and type(Registry.read) == "function" then
                local actor = Registry.read(uid)
                if actor and actor.generation == generation and actor.lifecycle == "dormant" then
                    -- Shell was removed because the NPC went dormant. Ignore the death event.
                    return true, "dormant_ignored"
                end
            end
        end

        return original(shell)
    end

    Lifecycle._dormantGuardInstalled = true
    return true
end

-- Try immediately, then retry a few times in case Lifecycle loads later
if not installGuard() then
    local tries = 0
    local function retry()
        tries = tries + 1
        if installGuard() or tries >= 20 then
            return
        end
        if type(Events) == "table" and Events.OnTick then
            ALifeHealth.tickAdd("ALifeTalk_DormantGuard", retry)
        end
    end
    if type(Events) == "table" and Events.OnTick then
        ALifeHealth.tickAdd("ALifeTalk_DormantGuard", retry)
    end
end
