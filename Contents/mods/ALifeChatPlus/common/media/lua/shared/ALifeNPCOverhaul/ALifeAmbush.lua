-- A-Life NPC Overhaul 0.8.11: AMBUSH. A smart group on its own turf that spots you coming (nobody on their side hurt
-- yet, you still out of reach) may go quiet instead of opening up at range: A-Life's own "ambusher" conduct switched
-- on through the fight brain's veto (row "ambush"): they take cover near where they are, hold fire, and spring when
-- you walk within 7 tiles (A-Life's spring distance). Rare (ambushChance, once per fight).
-- The ambush ends when you walk in (they spring: "Now!"), when one of them is hit (they're found), or after ambushMs.
-- 0.8.11.1 spot: A-Life's cover finder (ModuleCover.find, what its ambusher calls) is asked from a point on your way
-- in (their home toward you, ambushAhead tiles out), not from where each one stands: they take hidden cover there,
-- across your path. Same finder, same rules (hidden from you, walkable, no fence-only cover); only its origin moves.
-- When does it start? A-Life opens the SquadTactics contact the moment one of them picks you as a target on sight
-- (Perception pick -> SquadTactics.reportThreat), not only on shots, and the brain's first think follows within a
-- quarter second: the ambush can start before anyone fires. Server / SP. All settings.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeAmbush") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)
require "ALifeNPCOverhaul/ALifeFightBrain"
require "ALifeNPCOverhaul/ALifeFakeRun"

ALifeAmbush = ALifeAmbush or {}
local A = ALifeAmbush
local B = ALifeFightBrain
local TAG = "[ALifeAmbush]"
A.VERSION = "0.8.11.1"
A.metrics = A.metrics or { rolled = 0, set = 0, sprung = 0, found = 0, timedOut = 0 }

A.DEFAULTS = {
    ambush = true,          -- smart groups on their own turf may lie in wait for you
    ambushChance = 20,      -- % once per fight
    ambushWho = 2,          -- 1 military/police, 2 + criminals with their leader up, 3 everyone
    ambushMinTiles = 12,    -- you must still be at least this far off when they spot you (tiles)
    ambushReach = 45,       -- ... and no farther than this (tiles)
    ambushMs = 60000,       -- longest they lie in wait (ms)
    ambushAhead = 10,       -- 0.8.11.1: the spot, this far out from their home toward you (tiles; on your way in)
}
A.FILE_KEYS = {}
for k in pairs(A.DEFAULTS) do A.FILE_KEYS[#A.FILE_KEYS + 1] = k end
table.sort(A.FILE_KEYS)
A.SPRING = 7 -- A-Life ModuleConducts AMBUSH_SPRING (42.20 file)
A.LINES = { "Now!", "Light them up!", "Now, now, now!" }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end

function A.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = A.DEFAULTS[key] end
    return v
end
function A.n(key) return num(A.setting(key), num(A.DEFAULTS[key], 0)) end

function A.smart(st, f)
    local who = math.floor(A.n("ambushWho"))
    if who >= 3 then return true end
    local class = f.class or st.class
    if class == "military" or class == "police" then return true end
    return who >= 2 and class == "criminal" and not f.leaderLost
end

A.spots = A.spots or setmetatable({}, { __mode = "k" }) -- shell -> { x, y, z } while its group lies in wait

local function xyz(o)
    local x, y, z = nil, nil, 0
    pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end)
    return tonumber(x), tonumber(y), tonumber(z) or 0
end
-- their anchor: A-Life home / leash of the first member that has one, else where the group stands (outposts)
function A.anchor(f)
    local sx, sy, n = 0, 0, 0
    for _, m in ipairs(f.list or {}) do
        local mem = type(m.actor) == "table" and m.actor.memory or nil
        for _, k in ipairs({ "home", "leash" }) do
            local p = type(mem) == "table" and mem[k] or nil
            if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then return tonumber(p.x), tonumber(p.y) end
        end
        local x, y = xyz(m.shell)
        if x ~= nil then sx, sy, n = sx + x, sy + y, n + 1 end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end
-- the spot on your way in: anchor -> you, ambushAhead out, never closer to you than spring + 2
function A.spotFor(f, target)
    local hx, hy = A.anchor(f)
    local px, py, pz = xyz(target)
    if hx == nil or px == nil then return nil end
    local dx, dy = px - hx, py - hy
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1 then return nil end
    local d = math.min(A.n("ambushAhead"), l - (A.SPRING + 2))
    if d <= 0 then return nil end
    local z = 0
    for _, m in ipairs(f.list or {}) do local _, _, mz = xyz(m.shell); z = mz; break end
    return { x = hx + dx / l * d, y = hy + dy / l * d, z = math.floor(z) }
end
function A.setSpots(f, spot)
    for _, m in ipairs(f.list or {}) do if m.shell ~= nil then A.spots[m.shell] = spot end end
end
function A.clearSpots(f)
    for _, m in ipairs(f.list or {}) do if m.shell ~= nil then A.spots[m.shell] = nil end end
end

-- the shell as seen from the spot: position (and square) from the spot, everything else the real shell's
function A.proxy(shell, spot)
    local P = {}
    function P.getX() return spot.x end
    function P.getY() return spot.y end
    function P.getZ() return spot.z end
    function P.getSquare()
        local sq = nil
        pcall(function() sq = getCell():getGridSquare(math.floor(spot.x), math.floor(spot.y), spot.z) end)
        return sq
    end
    function P.getCurrentSquare() return P.getSquare() end
    return setmetatable(P, { __index = function(_, k)
        return function(_, ...) local m = shell[k]; return m(shell, ...) end
    end })
end
local function empty(t)
    if type(t) ~= "table" then return true end
    for _ in pairs(t) do return false end
    return true
end
-- wrap A-Life ModuleCover.find (server file: hooked late). Only the ambusher's own call (no options) for a shell whose
-- group lies in wait is moved; everything else goes through untouched.
function A.hookCover()
    if A.coverHooked then return true end
    local C = type(ProjectALife) == "table" and ProjectALife.ModuleCover or nil
    if not fn(C, "find") then return false end
    if C.find_ALifeAmbush == nil then
        local orig = C.find
        C.find = function(shell, target, options, ...)
            local spot = shell ~= nil and A.spots[shell] or nil
            if spot ~= nil and B.nowMs() > num(spot.untilMs, 0) then A.spots[shell] = nil; spot = nil end -- a fight that ended unseen
            if spot ~= nil and empty(options) and A.setting("ambush") ~= false then
                local ok, point = pcall(orig, A.proxy(shell, spot), target, options, ...)
                if ok and point ~= nil then
                    A.metrics.spotted = (A.metrics.spotted or 0) + 1
                    return point
                end
            end
            return orig(shell, target, options, ...)
        end
        C.find_ALifeAmbush = orig
    end
    A.coverHooked = true
    log("hooked ProjectALife.ModuleCover.find (ambush spot on your way in)")
    return true
end

local function hit(f) return num(f.hurt, 0) > 0 or num(f.downed, 0) > 0 or (num(f.startCount, 0) > num(f.alive, 0)) end

function A.maybeStart(gid, st, f, contact, now)
    if st.ambushRolled or st.ambush ~= nil or A.setting("ambush") == false then return false end
    if st.advisory or not st.vsPlayer or st.phase ~= nil or not f.home then return false end
    if st.mood == "fallback" or st.mood == "break" or st.mood == "giveup" then return false end
    if hit(f) or not A.smart(st, f) then return false end
    local gap = ALifeFakeRun.gap(f, contact.target)
    if gap == nil or gap < A.n("ambushMinTiles") or gap > A.n("ambushReach") then return false end
    st.ambushRolled = true
    A.metrics.rolled = A.metrics.rolled + 1
    if roll(100) >= A.n("ambushChance") then return false end
    st.ambush = { untilMs = now + A.n("ambushMs"), startMs = now }
    A.metrics.set = A.metrics.set + 1
    local spot = A.spotFor(f, contact.target)
    if spot ~= nil then spot.untilMs = st.ambush.untilMs; st.ambush.spot = spot; A.setSpots(f, spot) end
    log("group " .. tostring(gid) .. ": lies in wait for you (" .. math.floor(gap + 0.5) .. " tiles"
        .. (spot ~= nil and (", spot " .. math.floor(spot.x) .. "," .. math.floor(spot.y)) or "") .. ")")
    return true
end

function A.step(gid, st, f, contact, now)
    if st.ambush == nil then return false end
    local gap = ALifeFakeRun.gap(f, contact.target)
    local why = nil
    if gap ~= nil and gap <= A.SPRING then why = "sprung"
    elseif hit(f) then why = "found"
    elseif now >= st.ambush.untilMs then why = "timedOut" end
    if why == nil then return false end
    st.ambush = nil
    A.clearSpots(f)
    A.metrics[why] = A.metrics[why] + 1
    log("group " .. tostring(gid) .. ": ambush over (" .. why .. ")")
    if why == "sprung" then
        st.mood, st.sinceMs = "push", now
        local line = A.LINES[roll(#A.LINES) + 1]
        for _, m in ipairs(f.list or {}) do if m.shell ~= nil and B.say(m.shell, line) then break end end
    end
    return true
end

function A.hook()
    if A.hooked then return true end
    if type(B.preThink) ~= "table" then return false end
    -- before the think: start (quiet before the first shout) or end the ambush
    B.preThink[#B.preThink + 1] = function(groupId, st, f, contact, now)
        if not B.on() or type(f) ~= "table" or type(contact) ~= "table" then return end
        if st.ambush ~= nil then A.step(groupId, st, f, contact, now) else A.maybeStart(groupId, st, f, contact, now) end
    end
    A.hooked = true
    return true
end
A.hook()
A.coverTries = A.coverTries or 0
A.hookCover()
if type(Events) == "table" and Events.OnTick ~= nil then
    Events.OnTick.Add(function()
        if A.coverHooked or A.coverTries >= 600 then return end
        A.coverTries = A.coverTries + 1
        A.hookCover()
    end)
end
print(TAG .. " ready v" .. A.VERSION .. ": smart groups at home may lie in wait (A-Life ambusher; hook " .. (A.hooked and "on" or "OFF") .. ")")

return A
