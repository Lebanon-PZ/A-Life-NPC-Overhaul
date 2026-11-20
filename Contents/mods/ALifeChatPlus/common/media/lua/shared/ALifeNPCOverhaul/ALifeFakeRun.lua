-- A-Life NPC Overhaul 0.8.11: FAKE RUN. A smart group that is NOT beaten (fighting steady or careful) may fake a
-- retreat to pull you out of cover: the same "Run!" shout as a real run, they pull back (A-Life withdraw / flee, in
-- order: no panic, no car, no dropped loot), and when you chase in close (or time's up) they turn and push.
-- Your own people are fooled too ("They're running!"). Once per fight, never at home (they hold there).
-- Smart = fakeRunWho: 1 military / police only, 2 + criminals whose leader is still up, 3 everyone.
-- Fight brain pieces: st.fake (veto row "fakerun" in ALifeFightBrain), B.thinkGroup wrapped. Server / SP. All settings.
require "ALifeNPCOverhaul/ALifeFightBrain"

ALifeFakeRun = ALifeFakeRun or {}
local R = ALifeFakeRun
local B = ALifeFightBrain
local TAG = "[ALifeFakeRun]"
R.VERSION = "0.8.11"
R.metrics = R.metrics or { rolled = 0, faked = 0, turned = 0, turnedClose = 0 }

R.DEFAULTS = {
    fakeRun = true,          -- smart groups may fake a run to draw you out
    fakeRunChance = 25,      -- % once per fight
    fakeRunWho = 2,          -- 1 military/police, 2 + criminals with their leader up, 3 everyone
    fakeRunReach = 30,       -- you must be this close (tiles) for it to be worth it
    fakeRunMs = 10000,       -- longest they keep the act up (ms)
    fakeRunTurnTiles = 10,   -- you chase in this close: they turn on you (tiles)
}
R.FILE_KEYS = {}
for k in pairs(R.DEFAULTS) do R.FILE_KEYS[#R.FILE_KEYS + 1] = k end
table.sort(R.FILE_KEYS)
R.TURN_LINES = { "Now! Turn around!", "Now, get them!", "Got you! Hit them!" }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end
local function pick(list) return list[roll(#list) + 1] end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
local function xy(o) return num(call(o, "getX"), nil), num(call(o, "getY"), nil) end

function R.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = R.DEFAULTS[key] end
    return v
end
function R.n(key) return num(R.setting(key), num(R.DEFAULTS[key], 0)) end

function R.smart(st, f)
    local who = math.floor(R.n("fakeRunWho"))
    if who >= 3 then return true end
    local class = f.class or st.class
    if class == "military" or class == "police" then return true end
    if who >= 2 and class == "criminal" and not f.leaderLost then return true end
    return false
end

-- nearest standing member to the player (tiles), or nil
function R.gap(f, target)
    local px, py = xy(target)
    if px == nil then return nil end
    local best = nil
    for _, m in ipairs(f.list or {}) do
        local mem = type(m.actor) == "table" and m.actor.memory or nil
        local down = type(mem) == "table" and type(mem.injury) == "table" and mem.injury.s == "down"
        local x, y = xy(m.shell)
        if x ~= nil and not down then
            local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
            if best == nil or d < best then best = d end
        end
    end
    return best
end

local function shout(f, line)
    for _, m in ipairs(f.list or {}) do
        local mem = type(m.actor) == "table" and m.actor.memory or nil
        local down = type(mem) == "table" and type(mem.injury) == "table" and mem.injury.s == "down"
        if not down and m.shell ~= nil and B.say(m.shell, line) then return true end
    end
    return false
end

-- maybe start the act (rolled once per fight)
function R.maybeStart(gid, st, f, contact, now)
    if st.fakeRolled or st.fake ~= nil or R.setting("fakeRun") == false then return false end
    if st.advisory or not st.vsPlayer or st.phase ~= nil or f.home then return false end
    if st.mood ~= "steady" and st.mood ~= "careful" then return false end
    if not R.smart(st, f) then return false end
    local gap = R.gap(f, contact.target)
    if gap == nil or gap > R.n("fakeRunReach") then return false end
    st.fakeRolled = true
    R.metrics.rolled = R.metrics.rolled + 1
    if roll(100) >= R.n("fakeRunChance") then return false end
    st.fake = { untilMs = now + R.n("fakeRunMs"), startMs = now }
    R.metrics.faked = R.metrics.faked + 1
    log("group " .. tostring(gid) .. ": fakes a run to draw you out (" .. tostring(st.mood) .. ")")
    shout(f, pick(B.BARKS["break"]))
    local fx, fy = xy(f.firstShell or (f.list and f.list[1] and f.list[1].shell))
    if fx ~= nil then B.advise("break", { x = fx, y = fy }) end -- your people are fooled too
    return true
end

-- the act runs: you closed in -> turn; time up -> turn
function R.step(gid, st, f, contact, now)
    if st.fake == nil then return false end
    -- really beaten during the act: no trick left, the brain's real mood takes over
    if st.mood == "fallback" or st.mood == "break" or st.mood == "giveup" then
        st.fake = nil
        log("group " .. tostring(gid) .. ": the fake run turned real (" .. tostring(st.mood) .. ")")
        return false
    end
    local gap = R.gap(f, contact.target)
    local close = gap ~= nil and gap <= R.n("fakeRunTurnTiles")
    if not close and now < st.fake.untilMs then return false end
    st.fake = nil
    st.faked = true
    st.mood, st.sinceMs = "push", now
    R.metrics.turned = R.metrics.turned + 1
    if close then R.metrics.turnedClose = R.metrics.turnedClose + 1 end
    log("group " .. tostring(gid) .. ": the run was a trick, they turn on you" .. (close and " (you chased in)" or ""))
    shout(f, pick(R.TURN_LINES))
    return true
end

function R.hook()
    if R.hooked then return true end
    if not fn(B, "thinkGroup") then return false end
    local orig = B.thinkGroup
    B.thinkGroup = function(groupId, contact, now, ...)
        local st, f = orig(groupId, contact, now, ...)
        if B.on() and type(st) == "table" and type(f) == "table" and type(contact) == "table" then
            if st.fake ~= nil then pcall(R.step, groupId, st, f, contact, now)
            else pcall(R.maybeStart, groupId, st, f, contact, now) end
        end
        return st, f
    end
    R.hooked = true
    return true
end
R.hook()
print(TAG .. " ready v" .. R.VERSION .. ": smart groups may fake a run and turn on you (hook " .. (R.hooked and "on" or "OFF") .. ")")

return R
