-- A-Life NPC Overhaul 0.7.0.8: moving an NPC's body without A-Life losing them.
-- A-Life's watchdog checks every bound NPC 4x a second; a jump of more than 20 tiles between checks is read as
-- "shell_displaced": the body is dropped and the NPC respawns back where A-Life last had them (that broke pickups:
-- the NPC reached the car door, then vanished home). A-Life's own driving code moves riders by updating the
-- watchdog's lastPosition (ALifeDrivingLifecycle.transportPosition); we do the same after every long move.
ALifeMove = ALifeMove or {}
local M = ALifeMove

local function uidOf(shell)
    local uid
    pcall(function() if shell:hasModData() then uid = shell:getModData().ProjectALifeUID end end)
    return uid
end

-- tell the watchdog the body is where it is now (only for the binding that really is this body)
function M.rebase(shell)
    local W = ProjectALife and ProjectALife.Watchdog
    if shell == nil or type(W) ~= "table" or type(W.bindings) ~= "table" then return false end
    local uid = uidOf(shell)
    local b = uid and W.bindings[uid]
    if type(b) ~= "table" or b.shell ~= shell then return false end
    local ok, x, y, z = pcall(function() return shell:getX(), shell:getY(), shell:getZ() end)
    if not ok or x == nil then return false end
    b.lastPosition = { x = x, y = y, z = z }
    b.drivingTransport = nil
    return true
end

-- move the body (A-Life's own AIFence.moveBody when there), then rebase
function M.body(shell, x, y, z)
    if shell == nil or x == nil or y == nil then return false end
    local F = ProjectALife and ProjectALife.AIFence
    local ok = false
    -- 0.7.2.1: A-Life 1.5 can refuse a move (one body writer per frame) and returns false; pcall alone said ok
    if type(F) == "table" and type(F.moveBody) == "function" then
        local okc, moved = pcall(F.moveBody, shell, x, y, "ALifeChatPlus.move")
        ok = okc and moved ~= false
    end
    if not ok then ok = pcall(function() shell:setX(x); shell:setY(y) end) end
    if z ~= nil then pcall(function() shell:setZ(z) end) end
    pcall(function() shell:setLx(x); shell:setLy(y); if z ~= nil then shell:setLz(z) end end)
    M.rebase(shell)
    return ok
end

print("[ALifeMove] loaded v" .. tostring(type(ALifeSide) == "table" and ALifeSide.MOD_VERSION or "?") .. " (long NPC moves tell A-Life's watchdog)")
