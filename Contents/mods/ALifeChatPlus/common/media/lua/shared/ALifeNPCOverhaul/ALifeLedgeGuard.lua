-- A-Life NPC Overhaul pre-1.0: LEDGE GUARD ("my dudes keep falling off platforms, 30 broken legs").
-- Source read (42.21 jar): IsoGameCharacter.updateFalling drops anyone standing on a square with no floor, and DoLand
-- rolls the leg damage. zombie.pathfind never plans a drop, so the falls are NPCs leaving the planned path (straight
-- steer after a path failure, a repath, a position write) and stepping onto open air on an upper level.
-- This looks one stride ahead of every moving A-Life NPC above ground. If the square ahead has no floor (and is not
-- stairs), the move is cancelled the same way A-Life cancels its own (PathFindBehavior2 cancel + setPath2(nil) + not moving),
-- BEFORE the step off. A-Life then gives them a new order as usual. Deliberate climbs (isClimbing) are left alone.
-- Verified calls: IsoGridSquare:TreatAsSolidFloor / HasStairs (vanilla DebugChunkState + PolygonalMap2), getGridSquare,
-- IsoGameCharacter getForwardDirectionX/Y, isMoving, isClimbing, isDead, getPathFindBehavior2, setPath2, setMoving.
-- All numbers are player settings (ledgeGuard, ledgeLookTiles, ledgeCheckMs).
require "ALifeNPCOverhaul/AA_Side"
-- world logic (moves NPCs): the one side switch. Tick only where the world runs (SP / server), never on an MP client.
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLedgeGuard")
ALifeLedgeGuard = ALifeLedgeGuard or {}
local L = ALifeLedgeGuard
local TAG = "[ALifeLedgeGuard]"
L.VERSION = ALifeSide.MOD_VERSION
L.DEFAULTS = {
    ledgeGuard = true,     -- stop NPCs before they step onto a square with no floor
    ledgeLookTiles = 1.0,  -- how far ahead (tiles) they look
    ledgeCheckMs = 150,    -- how often (ms) the guard looks
}
L.KEYS = { "ledgeGuard", "ledgeLookTiles", "ledgeCheckMs" }
L.metrics = L.metrics or { checks = 0, stops = 0, errors = 0 }
L.holdUntil = L.holdUntil or {}

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

-- settings: keys go in fileKeys at LOAD time or they reset on restart
pcall(function() require "ALifeLLMTalk/ALifeLLMTalk_Main" end)
local function register()
    local m = ALifeLLMTalk
    if type(m) ~= "table" then return end
    m.settings = type(m.settings) == "table" and m.settings or {}
    m.fileKeys = type(m.fileKeys) == "table" and m.fileKeys or nil
    for _, k in ipairs(L.KEYS) do
        if m.settings[k] == nil then m.settings[k] = L.DEFAULTS[k] end
        if m.fileKeys ~= nil then
            local have = false
            for _, x in ipairs(m.fileKeys) do if x == k then have = true end end
            if not have then m.fileKeys[#m.fileKeys + 1] = k end
        end
    end
end
register()

function L.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = L.DEFAULTS[key] end
    return v
end
function L.on() return L.setting("ledgeGuard") ~= false end

local function openAir(sq)
    if sq == nil then return false end
    if type(sq.TreatAsSolidFloor) ~= "function" then return false end
    if sq:TreatAsSolidFloor() then return false end
    if type(sq.HasStairs) == "function" and sq:HasStairs() then return false end
    return true
end

-- true when the square one stride ahead of the NPC (same level) is open air
function L.ledgeAhead(shell)
    local z = math.floor(num(shell:getZ(), 0) + 0.05)
    if z <= 0 then return false end
    local cell = getCell()
    if cell == nil then return false end
    local x, y = shell:getX(), shell:getY()
    local here = cell:getGridSquare(math.floor(x), math.floor(y), z)
    if here == nil or openAir(here) then return false end -- not on a floor: already falling or unloaded, not ours to stop
    local fx, fy = num(shell:getForwardDirectionX(), 0), num(shell:getForwardDirectionY(), 0)
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.01 then return false end
    fx, fy = fx / len, fy / len
    local look = math.max(0.3, num(L.setting("ledgeLookTiles"), 1.0))
    for _, d in ipairs({ look * 0.5, look }) do
        local sq = cell:getGridSquare(math.floor(x + fx * d), math.floor(y + fy * d), z)
        if sq ~= nil and openAir(sq) then return true, sq end
    end
    return false
end

function L.stop(shell)
    pcall(function()
        local behavior = shell:getPathFindBehavior2()
        if behavior ~= nil then behavior:cancel() end
    end)
    pcall(function() shell:setPath2(nil) end)
    pcall(function() shell:setMoving(false) end)
    pcall(function() shell:setVariable("bMoving", false) end)
    pcall(function() shell:setVariable("bPathfind", false) end)
    pcall(function()
        local data = shell:getModData()
        if type(data) == "table" then data.ProjectALifePathActive = nil end
    end)
end

function L.tick()
    if not L.on() then return end
    if ALifeSide.client() then return end
    local now = nowMs()
    if now < num(L.nextMs, 0) then return end
    L.nextMs = now + math.max(50, num(L.setting("ledgeCheckMs"), 150))
    local cell = getCell()
    local list = cell ~= nil and cell.getZombieList ~= nil and cell:getZombieList() or nil
    if list == nil then return end
    for i = 0, list:size() - 1 do
        local shell = list:get(i)
        local ok, err = pcall(function()
            if shell == nil or shell:isDead() then return end
            local data = shell:getModData()
            if type(data) ~= "table" or type(data.ProjectALifeUID) ~= "string" then return end -- A-Life people only
            if shell:getZ() < 0.95 then return end
            if shell:isClimbing() or not shell:isMoving() then return end
            local uid = data.ProjectALifeUID
            L.metrics.checks = L.metrics.checks + 1
            local ledge, sq = L.ledgeAhead(shell)
            if ledge then
                L.stop(shell)
                L.metrics.stops = L.metrics.stops + 1
                if L.metrics.stops <= 20 or L.metrics.stops % 50 == 0 then
                    log(string.format("stopped %s at the edge (%s,%s,z%d) #%d", uid, ALifeFmtDec(shell:getX(), 1), ALifeFmtDec(shell:getY(), 1), -- pre-1.0: no %.1f (Kahlua throws)
                        math.floor(shell:getZ() + 0.05), L.metrics.stops))
                end
            end
        end)
        if not ok then
            L.metrics.errors = L.metrics.errors + 1
            if not L.errLogged then L.errLogged = true; log("check error (once): " .. tostring(err)) end
        end
    end
end

if type(Events) == "table" then
    ALifeHealth.tickAdd("ledgeGuard", L.tick) -- side switch: skipped on an MP client (was added there, then bailed each tick)
    local function start()
        register()
        if not L.said then
            L.said = true
            log("ready v" .. L.VERSION .. ": ledge guard (" .. (L.on() and "on" or "off") .. ")")
        end
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(start) end -- world mode: OnServerStarted on a server
end
