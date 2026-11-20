-- A-Life NPC Overhaul: a hidden "where is everyone" log for out-of-game checks. Nothing shows in game.
-- Every in-game 10 minutes it writes Zomboid\Lua\alifeai_where.txt:
--   you=x,y,z  hour=<world hours>
--   near uid|name|faction|lifecycle|x,y,z|distance      (people A-Life has in the world around you, loaded)
--   squad id|name|faction|state|members|x,y|task         (groups simulated off-screen, from A-Life's own squad store)
-- Read-only: it never changes anything.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeTracker") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeTracker]"
ALifeTracker = ALifeTracker or {}
local TR = ALifeTracker
TR.FILE = "alifeai_where.txt"

local function pos(o)
    if o == nil then return nil end
    local ok, x, y, z = pcall(function() return o:getX(), o:getY(), o:getZ() end)
    if ok and x ~= nil then return x, y, z end
    return nil
end
local function clean(s) return (string.gsub(tostring(s or "-"), "[|\r\n]", "/")) end
local function nameOf(record)
    local N = ProjectALife and ProjectALife.Names
    if N ~= nil and type(N.of) == "function" then
        local ok, n = pcall(N.of, record)
        if ok and n ~= nil then return n end
    end
    return record.name or (type(record.memory) == "table" and record.memory.name) or "?"
end

function TR.lines()
    local out = {}
    local player = ALifeSide.campPlayer()
    local px, py, pz = pos(player)
    local okH, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    out[#out + 1] = string.format("you=%s,%s,%s hour=%s", tostring(px and math.floor(px)), tostring(py and math.floor(py)),
        tostring(pz and math.floor(pz)), tostring(okH and math.floor(h * 10) / 10 or "?"))
    -- people A-Life has loaded around you
    local reg = ProjectALife and ProjectALife.ActorRegistry
    local Talk = ProjectALife and ProjectALife.Talk
    if reg ~= nil and type(reg.each) == "function" then
        pcall(reg.each, function(r)
            if type(r) ~= "table" or r.lifecycle == "dead" then return false end
            local shell = Talk and type(Talk.shellFor) == "function" and Talk.shellFor(r.uid) or nil
            local x, y, z = pos(shell)
            if x ~= nil then
                local d = px and math.floor(math.sqrt((x - px) ^ 2 + (y - py) ^ 2)) or -1
                local m = type(r.memory) == "table" and r.memory or {}
                out[#out + 1] = string.format("near %s|%s|%s|%s|%d,%d,%d|%d", clean(r.uid), clean(nameOf(r)),
                    clean(m.factionId or r.factionId), clean(r.lifecycle), math.floor(x), math.floor(y), math.floor(z or 0), d)
            end
            return false
        end)
    end
    -- groups simulated off-screen
    local store = type(ModData) == "table" and type(ModData.get) == "function" and ModData.get("ProjectALife.Squads.v1") or nil
    local squads = type(store) == "table" and store.squads or nil
    if type(squads) == "table" then
        for id, s in pairs(squads) do
            if type(s) == "table" then
                local n = 0
                for _ in pairs(type(s.members) == "table" and s.members or {}) do n = n + 1 end
                out[#out + 1] = string.format("squad %s|%s|%s|%s|%d|%d,%d|%s", clean(id), clean(s.name), clean(s.factionId),
                    clean(s.state), n, math.floor(tonumber(s.x) or 0), math.floor(tonumber(s.y) or 0),
                    clean(type(s.task) == "table" and s.task.label or "-"))
            end
        end
    end
    return out
end

function TR.write()
    local lines = TR.lines()
    local w = getFileWriter(TR.FILE, true, false)
    if w == nil then return false end
    for _, l in ipairs(lines) do w:write(l .. "\r\n") end
    w:close()
    return true
end

local failed = false
local function tick()
    if failed then return end
    local ok, err = pcall(TR.write)
    if not ok then failed = true; print(TAG .. " failed, off for this session: " .. tostring(err)) end
end

if Events ~= nil and type(getFileWriter) == "function" then
    if Events.EveryTenMinutes ~= nil then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTracker", tick) end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(tick) end
end
print(TAG .. " loaded")
