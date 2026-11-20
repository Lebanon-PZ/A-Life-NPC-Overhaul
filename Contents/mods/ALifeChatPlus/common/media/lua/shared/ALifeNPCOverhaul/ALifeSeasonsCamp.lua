-- A-Life NPC Overhaul 0.7.11: SEASONS AND CEREMONIES (roadmap).
-- Your camp keeps the days that matter, in the evening (5 to 9 PM) when you're home with them:
--   * THE DAY IT ALL STARTED: on the anniversary of your game's start date (read from the sandbox start month and day,
--     so it follows your settings), the camp holds a feast.
--   * CHRISTMAS DINNER on December 25.
--   * THE CAMP'S FOUNDING: every 30 days since people first lived at your base (the first evening you're home after), a dinner ("a month since we set up
--     here", "two months"...).
--   * FIRST SNOW: the first time it snows while you're home, everyone stops for it. No food, just the moment.
-- A feast eats real food out of your base's containers: one thing per person at the table. Not enough to go around and
-- there's no feast; people notice that too. A feast eases the camp's mood, everyone remembers it, someone gives a
-- toast, and the toast follows your camp's traditions (0.7.4): "to the ones we stopped for", "to us, nobody else"...
-- Setting: "seasons" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeSeasonsCamp") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeSeasonsCamp = ALifeSeasonsCamp or {}
local L = ALifeSeasonsCamp
local TAG = "[ALifeSeasons]"
L.VERSION = "0.7.11"
L.cfg = { fromHour = 17, toHour = 21, baseReach = 20, scanTiles = 25, maxContainers = 60, maxPlates = 12, unrestEase = 15,
    opinionUp = 3, hungryUnrest = 5, foundEveryDays = 30, yearDays = 300 }
L.TOASTS = {
    help_fallen = { "To the ones we stopped for. And the ones who stopped for us." },
    no_quarter = { "To us. Nobody else. Nobody else ever." },
    keep_walking = { "To getting through another one. That's all any of us can do." },
    none = { "To the ones who aren't at this table.", "To another day. Didn't think we'd get this one.", "To all of you. Eat up." },
}
L.SNOW = { "Would you look at that. Snow.", "First snow. My kid used to wait all year for this.", "Huh. Snow. Feels like a different world.",
    "Snow... the dead won't care, but it's pretty." }
L.off = L.off or {}
L.metrics = L.metrics or { feasts = 0, hungry = 0, snow = 0, plates = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end
local function xyOf(o) local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
local function record(uid)
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function shellOf(uid)
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "shellFor") then return nil end
    local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
    return ok and s or nil
end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.seasons == false)
end
function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("'" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end
function L.store()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "seasons")
    if not ok or type(b) ~= "table" then return nil end
    b.done = type(b.done) == "table" and b.done or {}
    return b
end
function L.clock()
    local sp = PA() and PA().Speech
    if fn(sp, "clock") then local ok, c = pcall(sp.clock); if ok and type(c) == "table" then return c end end
    return nil
end
-- the sandbox start date (players change it)
function L.startDate()
    local sv = type(SandboxVars) == "table" and SandboxVars or {}
    local m, d = tonumber(sv.StartMonth), tonumber(sv.StartDay)
    if m == nil or d == nil then return 7, 9 end -- the game's own default: July 9
    return m, d
end

-- your base right now, and are you home
function L.base(player)
    local m = M()
    if not fn(m, "playerBase") then return nil end
    local ok, b = pcall(m.playerBase, player)
    if not ok or type(b) ~= "table" or not tonumber(b.x1) then return nil end
    return b
end
function L.home(player, b)
    local px, py = xyOf(player)
    local r = L.cfg.baseReach
    return px ~= nil and px >= b.x1 - r and px <= b.x2 + r and py >= b.y1 - r and py <= b.y2 + r
end
-- who's home for dinner (camp people who are home right now; the camp module decides "home")
function L.atTable(player, b)
    local m = M()
    local out = {}
    if not fn(m, "cpPeople") then return out end
    local ok, list = pcall(m.cpPeople, player)
    for _, u in ipairs(ok and type(list) == "table" and list or {}) do
        u = tostring(u)
        local r = record(u)
        if r and r.lifecycle ~= "dead" then out[#out + 1] = u end
    end
    return out
end

-- real food out of the base's containers: count, and take n
function L.foodIn(b, take)
    local found, taken = 0, 0
    pcall(function()
        local cell = getCell()
        local cx, cy = math.floor((b.x1 + b.x2) / 2), math.floor((b.y1 + b.y2) / 2)
        local seen = 0
        for x = math.max(b.x1, cx - L.cfg.scanTiles), math.min(b.x2, cx + L.cfg.scanTiles) do
            for y = math.max(b.y1, cy - L.cfg.scanTiles), math.min(b.y2, cy + L.cfg.scanTiles) do
                local sq = cell:getGridSquare(x, y, 0)
                local objs = sq and sq:getObjects() or nil
                for i = 0, (objs and objs:size() or 0) - 1 do
                    local cont = nil
                    pcall(function() cont = objs:get(i):getContainer() end)
                    if cont ~= nil then
                        seen = seen + 1
                        local items = cont:getItems()
                        for j = items:size() - 1, 0, -1 do
                            local it = items:get(j)
                            local food = false
                            pcall(function() food = it:getCategory() == "Food" end)
                            if food then
                                found = found + 1
                                if take and taken < take then cont:DoRemoveItem(it); taken = taken + 1 end
                            end
                        end
                        if seen >= L.cfg.maxContainers then return end
                    end
                end
            end
        end
    end)
    local m = M()
    if take and taken > 0 and type(m) == "table" then m.baseCache = {} end -- the base's food count is stale now
    return found, taken
end

function L.tradition(player)
    local I = ALifeInjuryBridge
    local B = ALifeBonds
    local key = fn(B, "keyOf") and B.keyOf(player) or nil
    if fn(I, "traditionOf") and key then
        for _, id in ipairs({ "help_fallen", "no_quarter", "keep_walking" }) do
            local ok, has = pcall(I.traditionOf, key, id)
            if ok and has then return id end
        end
    end
    return "none"
end
local function remember(uid, text)
    local m = M()
    if fn(m, "keyMem") then pcall(m.keyMem, uid, "occasion", text) end
end
local function ease(uid, player, why)
    local m = M()
    local ok, st = pcall(function() return m.store() end)
    if ok and type(st) == "table" and type(st.unrest) == "table" and type(st.unrest[uid]) == "table" then
        st.unrest[uid].v = math.max(0, (tonumber(st.unrest[uid].v) or 0) - L.cfg.unrestEase)
    end
    local pa, r = PA(), record(uid)
    if r and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, r, player, L.cfg.opinionUp, why) end
end
local function sour(uid)
    local m = M()
    local ok, st = pcall(function() return m.store() end)
    if ok and type(st) == "table" then
        st.unrest = type(st.unrest) == "table" and st.unrest or {}
        local u = st.unrest[uid] or { v = 0 }
        u.v = math.min(100, (tonumber(u.v) or 0) + L.cfg.hungryUnrest)
        st.unrest[uid] = u
    end
end

-- a feast for an occasion: true if it happened (or was called off for lack of food)
function L.feast(player, b, people, id, title, memText)
    local s = L.store()
    if s == nil or s.done[id] then return false end
    s.done[id] = hours()
    local plates = math.min(#people + 1, L.cfg.maxPlates)
    local have = L.foodIn(b, nil)
    local m = M()
    if have < plates then
        L.metrics.hungry = L.metrics.hungry + 1
        for _, u in ipairs(people) do sour(u); remember(u, "No " .. title .. " this year - there wasn't enough food to go around") end
        if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, "No " .. title .. " tonight: there isn't enough food in the base for everyone.", nil, nil, nil, true) end
        log(title .. ": not enough food (" .. have .. " for " .. plates .. ")")
        return true
    end
    local _, taken = L.foodIn(b, plates)
    L.metrics.feasts = L.metrics.feasts + 1
    L.metrics.plates = L.metrics.plates + taken
    for _, u in ipairs(people) do
        ease(u, player, title)
        remember(u, memText)
        local A = PA() and PA().Animations
        if fn(A, "apply") then pcall(A.apply, shellOf(u), "eat") end
    end
    local toaster = people[(hash(id) % #people) + 1]
    local pool = L.TOASTS[L.tradition(player)] or L.TOASTS.none
    local toast = pool[(hash(id .. "t") % #pool) + 1]
    if toaster and fn(m, "say") then pcall(m.say, shellOf(toaster), player, toast, { record = record(toaster) }) end
    if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, "Your people held " .. title .. ". " .. taken .. " things came out of the stores for it.") end
    if fn(m, "addDeed") then pcall(m.addDeed, "feast", "the stranger's camp still keeps " .. title, 1, people, nil, nil) end
    log(title .. ": " .. #people .. " at the table, " .. taken .. " food used, toast: " .. toast)
    return true
end

function L.firstSnow(player, people)
    local s = L.store()
    if s == nil or s.firstSnow then return false end
    local Se = PA() and PA().Seasons
    if not fn(Se, "weather") then return false end
    local ok, w = pcall(Se.weather)
    if not ok or type(w) ~= "table" or w.snowing ~= true then return false end
    s.firstSnow = hours()
    L.metrics.snow = L.metrics.snow + 1
    local m = M()
    for i, u in ipairs(people) do
        remember(u, "Watched the first snow come down at the base with everyone")
        local A = PA() and PA().Animations
        if fn(A, "apply") then pcall(A.apply, shellOf(u), "warm_hands") end
        if i == 1 and fn(m, "say") then pcall(m.say, shellOf(u), player, L.SNOW[(hash(u) % #L.SNOW) + 1], { record = record(u) }) end
    end
    if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, "First snow. Everyone stopped to watch it.") end
    log("first snow (" .. #people .. " watched)")
    return true
end

-- every hour: is today a day that matters?
function L.step()
    local player = playerOf()
    local c = L.clock()
    if player == nil or c == nil then return end
    local b = L.base(player)
    if b == nil or not L.home(player, b) then return end
    local people = L.atTable(player, b)
    local s = L.store()
    if s == nil then return end
    if #people > 0 and s.foundH == nil then s.foundH = hours() end
    if #people == 0 then return end
    L.firstSnow(player, people)
    local h = tonumber(c.hour) or 12
    if h < L.cfg.fromHour or h >= L.cfg.toHour then return end
    local sm, sd = L.startDate()
    local days = tonumber(c.daysSurvived) or 0
    if c.month == sm and c.day == sd and days >= L.cfg.yearDays then
        return L.feast(player, b, people, "start:" .. tostring(c.year), "a feast for the day it all started",
            "We held a feast on the anniversary of the day it all started")
    end
    if c.month == 12 and c.day == 25 then
        return L.feast(player, b, people, "xmas:" .. tostring(c.year), "Christmas dinner", "Christmas dinner at the base, all of us together")
    end
    local since = math.floor((hours() - s.foundH) / 24)
    local n = math.floor(since / L.cfg.foundEveryDays)
    if n >= 1 then
        local words = n == 1 and "a month" or (n .. " months")
        return L.feast(player, b, people, "found:" .. n, "a dinner for " .. words .. " since we set up here",
            "Dinner for " .. words .. " since we set up at this base")
    end
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            local m = M()
            if type(m) == "table" and type(m.settings) == "table" and m.settings.seasons == nil then m.settings.seasons = true end
            local sm, sd = L.startDate()
            log("ready v" .. L.VERSION .. " (start date " .. sm .. "/" .. sd .. ")")
        end)
    end
    if Events.EveryHours ~= nil then Events.EveryHours.Add(function() if L.enabled() then L.guard("step", L.step) end end) end
end
print(TAG .. " loaded v" .. L.VERSION)
