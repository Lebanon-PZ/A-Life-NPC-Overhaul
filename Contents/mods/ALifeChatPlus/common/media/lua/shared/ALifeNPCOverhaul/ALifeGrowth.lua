-- A-Life NPC Overhaul 0.8.8: PEOPLE WHO GET BETTER (server side).
-- The camp roles (ALifeTalk_Camp, client) are sent here once in a while ("campRoles"); the server keeps who does what
-- since when, and does the parts that change the world:
--   * PRACTICE: an A-Life companion in a role practises its skill every day in it (A-Life 1.5.1 companion skills 0-10,
--     record.memory.companion.state.skills, written through Companions.write + Rules.sanitize, the same path A-Life's
--     own teach uses). Level n -> n+1 takes growDays x (n+1) days: about a season (90 days at 6) from 0 to 5, slower past.
--     cook -> cooking, medic -> firstAid, guard -> melee + aiming, builder -> carpentry, farmer / shepherd -> foraging,
--     scout -> stealth + foraging, mechanic -> mechanics (A-Life's repair_car needs 2), teacher -> none of their own.
--   * TEACHER: residents training at a Jeem base (memory.jimmyTraining, Jeem Residents/Manage.lua) learn faster while a
--     teacher lives there: teachBoost % of an extra hour of training credit each game hour they're home.
--   * SCOUT: once a day a scout reports who's really out there: living A-Life people of other groups within scoutReach
--     of the scout, by group, how many and which way, and whether that group is hostile to the camp. Nothing invented.
-- Not built (no real path yet): hunter (no NPC hunting in A-Life or Jeem), trader (no trade path to make better).
require "ALifeNPCOverhaul/ALifeCmd"

ALifeGrowth = ALifeGrowth or {}
local G = ALifeGrowth
local TAG = "[ALifeGrowth]"
G.VERSION = "0.8.8"
G.DEFAULTS = {
    growth = true,        -- people get better at their camp job over time
    growDays = 6,         -- days of practice per skill level (x the level they're going for)
    roleGrowMax = 40,     -- how much better (%) someone gets at their camp role with time in it
    roleSeasonDays = 90,  -- days in a role to reach that
    teachBoost = 50,      -- % faster training at a Jeem base with a teacher living there
    scoutReach = 300,     -- tiles a scout looks around
    scoutReport = true,   -- scouts report once a day
    scoutMarkTiles = 50,  -- 0.8.8 UI: how rough a scout's mark on your map is (tiles, rounded)
}
G.KEYS = {}
for k in pairs(G.DEFAULTS) do G.KEYS[#G.KEYS + 1] = k end
table.sort(G.KEYS)
G.ROLE_SKILLS = { cook = { "cooking" }, medic = { "firstAid" }, guard = { "melee", "aiming" }, builder = { "carpentry" },
    farmer = { "foraging" }, shepherd = { "foraging" }, scout = { "stealth", "foraging" }, mechanic = { "mechanics" }, teacher = {} }
G.metrics = G.metrics or { practised = 0, levels = 0, taught = 0, scouted = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function rec(uid)
    local pa = PA()
    if uid == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function first(r)
    local m = mem(r)
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function posOf(r)
    if type(r) ~= "table" then return nil end
    local x, y = tonumber(r.x), tonumber(r.y)
    if x == nil and type(r.worldPosition) == "table" then x, y = tonumber(r.worldPosition.x), tonumber(r.worldPosition.y) end
    return x, y
end
function G.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end
function G.on() return G.setting("growth") ~= false end
function G.hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return num(h, 0)
end
function G.store()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeGrowth") or (G.tmp or {})
    if type(ModData) ~= "table" then G.tmp = s end
    s.roles = type(s.roles) == "table" and s.roles or {}
    s.prog = type(s.prog) == "table" and s.prog or {}
    return s
end

-- ---------------------------------------------------------------------------------------------- roles from the client
G.KNOWN = { cook = true, medic = true, guard = true, builder = true, farmer = true, shepherd = true, scout = true, mechanic = true, teacher = true }
function G.setRoles(key, list)
    if key == nil or type(list) ~= "table" then return 0 end
    local s, now, n = G.store(), G.hours(), 0
    -- what this player had: dropped unless still listed
    local seen = {}
    for uid, role in pairs(list) do
        uid, role = tostring(uid), tostring(role)
        if n >= 40 then break end
        local r = rec(uid)
        if G.KNOWN[role] and r ~= nil and r.lifecycle ~= "dead" then
            local row = s.roles[uid]
            if type(row) ~= "table" or row.r ~= role then row = { r = role, since = now } end
            row.by = key
            s.roles[uid] = row
            seen[uid] = true
            n = n + 1
        end
    end
    for uid, row in pairs(s.roles) do
        if type(row) == "table" and row.by == key and not seen[uid] then s.roles[uid] = nil end
    end
    return n
end
function G.roleOf(uid)
    local row = G.store().roles[tostring(uid)]
    return type(row) == "table" and row.r or nil
end

-- ---------------------------------------------------------------------------------------------- practice
-- one day in a role for an A-Life companion of the player who gave the role. Returns skills that went up.
function G.practise(uid, row)
    local C = PA().Companions
    local r = rec(uid)
    if not fn(C, "write") or not fn(C, "entry") or r == nil then return {} end
    local entry = C.entry(r)
    if entry == nil or tostring(entry.owner) ~= tostring(row.by) then return {} end
    local Rules = fn(C, "rules") and C.rules() or nil
    local max = Rules and num(Rules.skillMax, 10) or 10
    local s = G.store()
    s.prog[uid] = type(s.prog[uid]) == "table" and s.prog[uid] or {}
    local p = s.prog[uid]
    local up = {}
    for _, skill in ipairs(G.ROLE_SKILLS[row.r] or {}) do
        local state = type(entry.state) == "table" and entry.state or {}
        local level = num(type(state.skills) == "table" and state.skills[skill] or 0, 0)
        if level < max then
            p[skill] = num(p[skill], 0) + 1
            G.metrics.practised = G.metrics.practised + 1
            if p[skill] >= num(G.setting("growDays"), 6) * (level + 1) then
                p[skill] = 0
                C.write(uid, function(x)
                    local e = x.memory.companion
                    if type(e) ~= "table" or tostring(e.owner) ~= tostring(row.by) then return end
                    if Rules ~= nil and fn(Rules, "sanitize") then e.state = Rules.sanitize(e.state) end
                    if type(e.state) ~= "table" or type(e.state.skills) ~= "table" then return end
                    e.state.skills[skill] = math.min(max, num(e.state.skills[skill], 0) + 1)
                end)
                up[#up + 1] = skill
                G.metrics.levels = G.metrics.levels + 1
            end
        end
    end
    return up
end

-- ---------------------------------------------------------------------------------------------- teacher
function G.teach(hours)
    local j = J()
    local R = j and j.Residents or nil
    local reg = PA().ActorRegistry
    if not fn(R, "residents") or not fn(reg, "update") then return 0 end
    local s = G.store()
    local bases = {}
    for uid, row in pairs(s.roles) do
        if type(row) == "table" and row.r == "teacher" then
            local r = rec(uid)
            local res = mem(r).jimmyResident
            if r ~= nil and r.lifecycle ~= "dead" and type(res) == "table" and res.baseId ~= nil and mem(r).jimmyMission == nil then
                bases[res.baseId] = bases[res.baseId] or {}
                bases[res.baseId][tostring(uid)] = true
            end
        end
    end
    local extra, n = num(G.setting("teachBoost"), 50) / 100 * num(hours, 1), 0
    if extra <= 0 then return 0 end
    for baseId, teachers in pairs(bases) do
        for _, r in ipairs(R.residents(baseId) or {}) do
            local m = mem(r)
            if type(m.jimmyTraining) == "table" and not teachers[tostring(r.uid)] and m.jimmyMission == nil then
                local ok = pcall(reg.update, r.uid, r.revision, function(x)
                    local t = type(x.memory) == "table" and x.memory.jimmyTraining or nil
                    if type(t) == "table" then t.done = num(t.done, 0) + extra end
                end)
                if ok then n = n + 1 end
            end
        end
    end
    G.metrics.taught = G.metrics.taught + n
    return n
end

-- ---------------------------------------------------------------------------------------------- scout
G.DIRS = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }
function G.dirOf(dx, dy)
    local a = math.atan2(dy, dx) -- PZ: y grows south
    local i = math.floor((a / (2 * math.pi) * 8) + 0.5) % 8
    return G.DIRS[i + 1]
end
function G.scout(uid)
    local r = rec(uid)
    local x, y = posOf(r)
    local reg = PA().ActorRegistry
    if r == nil or x == nil or not fn(reg, "each") then return nil end
    local reach = num(G.setting("scoutReach"), 300)
    local mine = mem(r).groupId
    local groups = {}
    pcall(reg.each, function(o)
        if o.lifecycle ~= "dead" and o.uid ~= r.uid then
            local g = mem(o).groupId
            local ox, oy = posOf(o)
            if g ~= nil and g ~= mine and ox ~= nil and (ox - x) ^ 2 + (oy - y) ^ 2 <= reach * reach then
                local row = groups[g] or { n = 0, sx = 0, sy = 0, one = o }
                row.n, row.sx, row.sy = row.n + 1, row.sx + ox, row.sy + oy
                groups[g] = row
            end
        end
        return false
    end)
    local Rel = PA().Relations
    local parts = {}
    local rough = math.max(1, num(G.setting("scoutMarkTiles"), 50))
    for _, row in pairs(groups) do
        local hostile = false
        if fn(Rel, "status") then local ok, st = pcall(Rel.status, r, row.one); hostile = ok and st == "hostile" end
        local gx, gy = row.sx / row.n, row.sy / row.n
        local dir = G.dirOf(gx - x, gy - y)
        local many = row.n == 1 and "one person" or (row.n <= 3 and "a few people" or (row.n <= 8 and "a group" or "a lot of people"))
        -- 0.8.8 UI: where, roughly (rounded, never exact), for a mark on your map
        parts[#parts + 1] = { hostile = hostile, n = row.n, text = many .. " to the " .. dir .. (hostile and ", not friendly" or ""),
            many = many, x = math.floor(gx / rough + 0.5) * rough, y = math.floor(gy / rough + 0.5) * rough }
    end
    table.sort(parts, function(a, b) if a.hostile ~= b.hostile then return a.hostile end return a.n > b.n end)
    G.metrics.scouted = G.metrics.scouted + 1
    if #parts == 0 then return first(r) .. " scouted around: nobody out there.", {} end
    local out, marks = {}, {}
    for i = 1, math.min(3, #parts) do
        local p = parts[i]
        out[#out + 1] = p.text
        marks[#marks + 1] = { x = p.x, y = p.y, t = p.many, h = p.hostile }
    end
    return first(r) .. " scouted around: " .. table.concat(out, "; ") .. ".", marks
end

-- ---------------------------------------------------------------------------------------------- the day
function G.playerByKey(key)
    local j = J()
    local Vi = j and j.Traders and j.Traders.visits or nil
    if fn(Vi, "players") then
        local ok, list = pcall(Vi.players)
        if ok and type(list) == "table" then for _, p in ipairs(list) do if tostring(p.key) == tostring(key) then return p.player end end end
    end
    local p = nil
    if type(isServer) ~= "function" or not isServer() then pcall(function() p = getSpecificPlayer(0) end) end -- single player only
    return p
end
function G.day()
    if not G.on() then return 0 end
    local s, n = G.store(), 0
    local news = {}
    for uid, row in pairs(s.roles) do
        if type(row) == "table" then
            local r = rec(uid)
            if r == nil or r.lifecycle == "dead" then s.roles[uid] = nil; s.prog[uid] = nil
            else
                local up = G.practise(uid, row)
                if #up > 0 then
                    news[row.by] = news[row.by] or {}
                    table.insert(news[row.by], { text = first(r) .. " has got better at " .. table.concat(up, " and ") .. ".", kind = "skill", who = first(r) })
                end
                if row.r == "scout" and G.setting("scoutReport") ~= false then
                    local line, marks = G.scout(uid)
                    if line ~= nil then
                        news[row.by] = news[row.by] or {}
                        table.insert(news[row.by], { text = line, kind = "scout", who = first(r), marks = marks })
                    end
                end
                n = n + 1
            end
        end
    end
    for key, lines in pairs(news) do
        local p = G.playerByKey(key)
        if p ~= nil then for _, l in ipairs(lines) do ALifeCmd.reply(p, "campReport", type(l) == "table" and l or { text = l }) end end
    end
    return n
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    -- { roles = { [uid] = role } }
    ALifeCmd.onServer("campRoles", function(player, args)
        if type(args) ~= "table" or type(args.roles) ~= "table" then return "args" end
        local key = nil
        local R = PA().Reputation
        if fn(R, "playerKey") then local ok, k = pcall(R.playerKey, player); if ok then key = k end end
        if key == nil and J() ~= nil and fn(J(), "playerKey") then key = J().playerKey(player) end
        if key == nil then return "key" end
        G.setRoles(tostring(key), args.roles)
        return "ok"
    end)
end

if type(Events) == "table" then
    if Events.EveryHours ~= nil then
        ALifeSide.stagger("EveryHours", function()
            if not G.on() then return end
            if type(isClient) == "function" and isClient() then return end -- MP: the server does it
            local okT, errT = pcall(G.teach, 1)
            if not okT and not G.teachErr then G.teachErr = true; log("teach error (once): " .. tostring(errT)) end
            local d = math.floor(G.hours() / 24)
            local s = G.store()
            if s.lastDay ~= d then
                s.lastDay = d
                local ok, err = pcall(G.day)
                if not ok and not G.dayErr then G.dayErr = true; log("day error (once): " .. tostring(err)) end
            end
        end)
    end
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            log("ready v" .. G.VERSION .. ": people who get better (" .. (G.on() and "on" or "off") .. ", a level every "
                .. tostring(G.setting("growDays")) .. " x level days)")
        end)
    end
end
