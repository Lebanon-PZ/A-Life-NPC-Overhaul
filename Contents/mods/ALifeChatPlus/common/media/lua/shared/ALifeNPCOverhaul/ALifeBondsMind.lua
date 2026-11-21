-- A-Life Bonds, phase 3: minds.  (Single player.)
--
--   Archetypes  Every NPC gets one, from A-Life's own temperament (fresh / seasoned / veteran / predator):
--               Pragmatist  survival is a transaction: need holds them, but cut the need and fear turns to betrayal
--               Dependent   fear + need, treated decently, turns into loyalty quickly
--               Martyr      love holds them through anything; too much fear breaks them instead of bending them
--               Opportunist here for the supplies; walks when you stop providing, fear or not
--   Loyalty     A fourth bond, separate from love and never romantic: grows when someone fears and needs you and
--               you don't hurt them (or loves you deeply). Loyal people obey more, don't desert, don't plot.
--   Subversion  Residents held by fear without love, need or loyalty build a hidden grudge, daily:
--                 3+  they steal from your base stores
--                 6+  they tip off a faction that hates you (A-Life's real raid warning follows)
--                 8+  if two or more feel this way and you're hurt, asleep, or it's night: they turn on you
--   Loved ones  Hold someone prisoner and anyone from their old crew fears you far more ("Afraid").
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeBondsMind") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeBondsMind]"
local VERSION = ALifeSide.MOD_VERSION

ALifeBondsMind = ALifeBondsMind or {}
local M = ALifeBondsMind
M.version = VERSION
M.ARCH = { "Pragmatist", "Dependent", "Martyr", "Opportunist" }
M.BY_TEMPERAMENT = {
    predator = { "Opportunist", "Pragmatist", "Opportunist" },
    veteran = { "Pragmatist", "Martyr", "Pragmatist" },
    fresh = { "Dependent", "Martyr", "Dependent" },
    seasoned = { "Pragmatist", "Dependent", "Martyr", "Opportunist" },
}
M.LOYAL_NAMES = { "None", "Compliant", "Loyal", "Devout", "Zealous", "Fanatic" }
M.LOVED_ONE_FEAR = 70          -- "Afraid"
M.ACT_GAP_DAYS = 3
M.metrics = { thefts = 0, tipoffs = 0, coups = 0, opportunists = 0 }

local disabled = {}
local function tryOnce(id, fn, ...)
    if disabled[id] then return false, nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return true, a, b end
    disabled[id] = true
    print(TAG .. " " .. id .. " failed, disabled for this session: " .. tostring(a))
    return false, nil
end
local function B() return ALifeBonds end
local function P() return ALifeBondsPower end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and h or 0
end
local function today() return math.floor(hours() / 24) end
local function roll100() return type(ZombRand) == "function" and ZombRand(100) or 50 end
local function registry() return ProjectALife and ProjectALife.ActorRegistry end
local function readRecord(uid)
    local reg = registry()
    if reg == nil or uid == nil then return nil end
    local ok, r = pcall(reg.read, uid)
    return ok and r or nil
end
local function notify(player, text, good)
    if ALifeImmersion ~= nil and ALifeImmersion.enabled then return end   -- immersion: read it from people, not pop-ups
    pcall(function()
        if HaloTextHelper == nil or player == nil then return end
        if type(ALifeLetter) == "function" then ALifeLetter(player, text, 170, 210, 170, good == false)
        elseif good == false and type(HaloTextHelper.addBadText) == "function" then HaloTextHelper.addBadText(player, text)
        elseif type(HaloTextHelper.addText) == "function" then HaloTextHelper.addText(player, text) end
    end)
end
local function nameOf(record)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    return (type(m.personName) == "string" and m.personName ~= "") and m.personName or tostring(record and record.uid)
end

-- --------------------------------------------------------------- archetype ---
local function hash(s)
    local h = 0
    s = tostring(s or "")
    for i = 1, #s do h = (h * 31 + string.byte(s, i)) % 1000003 end
    return h
end

function M.archetypeOf(record, r)
    if r ~= nil and r.arch ~= nil then return r.arch end
    local temperament = "seasoned"
    pcall(function()
        local who = ProjectALife.DialogueRoles.describe(record, 0)
        if type(who) == "table" and who.temperament then temperament = tostring(who.temperament) end
    end)
    local list = M.BY_TEMPERAMENT[temperament] or M.BY_TEMPERAMENT.seasoned
    local arch = list[(hash(record and record.uid) % #list) + 1]
    if r ~= nil then r.arch = arch end
    return arch
end

local function st(points) return B().stageOf(points or 0) end

-- ---------------------------------------------------------------- loyalty ---
local function grow(key, uid, r, record)
    local fearS = st(B().effectiveFear(key, uid, r))
    local needS, loveS = st(r.n), st(r.l)
    local arch = M.archetypeOf(record, r)
    local harmedRecently = r.harm ~= nil and hours() - r.harm < 72
    local gain = 0
    if fearS >= 2 and needS >= 2 and not harmedRecently then gain = gain + (arch == "Dependent" and 6 or 3) end
    if loveS >= 3 then gain = gain + (arch == "Martyr" and 3 or 1) end
    if arch == "Opportunist" then gain = math.floor(gain / 2) end
    if harmedRecently then gain = gain - 3 end
    r.d = math.max(0, (r.d or 0) + gain)
end

-- ------------------------------------------------------------- subversion ---
local function subvert(key, uid, r, record)
    local fearS = st(B().effectiveFear(key, uid, r))
    local needS, loveS, loyS = st(r.n), st(r.l), st(r.d)
    local arch = M.archetypeOf(record, r)
    local gain = fearS - needS * 0.5 - loveS - loyS
    if arch == "Pragmatist" and needS >= 2 then gain = gain - 2 end
    if arch == "Pragmatist" and needS <= 1 and fearS >= 2 then gain = gain + 2 end
    if arch == "Opportunist" then gain = gain + 1 end
    if arch == "Martyr" and loveS >= 2 then gain = -2 end
    if arch == "Dependent" then gain = gain - 1 end
    r.sv = math.max(0, (r.sv or 0) + gain)
end

-- base stores: take a couple of items from a food or ammo store (only if that part of the map is loaded)
local function steal(record)
    local j = ProjectALifeJimmy
    local res = type(record.memory) == "table" and record.memory.jimmyResident or nil
    if j == nil or j.BaseAreas == nil or type(res) ~= "table" then return 0 end
    local base = j.BaseAreas.base(res.baseId)
    if base == nil or type(getCell) ~= "function" then return 0 end
    local taken = 0
    for _, kind in ipairs({ "food", "ammo", "medical" }) do
        for _, s in ipairs(j.BaseAreas.storesOf(base, kind)) do
            if taken >= 2 then return taken end
            pcall(function()
                local sq = getCell():getGridSquare(s.x, s.y, s.z or 0)
                if sq == nil then return end
                local objects = sq:getObjects()
                for i = 0, objects:size() - 1 do
                    local c = objects:get(i):getContainer()
                    if c ~= nil then
                        local items = c:getItems()
                        while taken < 2 and items:size() > 0 do
                            local item = items:get(ZombRand(items:size()))
                            c:Remove(item)
                            taken = taken + 1
                        end
                    end
                end
            end)
        end
    end
    return taken
end

local function enemyFaction(key)
    local s = P() and P().state() or nil
    local lost = s and s.lost and s.lost[key] or nil
    if lost == nil then return nil end
    local best, at = nil, -1
    for fid, h in pairs(lost) do if h > at then best, at = fid, h end end
    return best
end

local function playerVulnerable(player)
    local asleep, health, night = false, 100, false
    pcall(function() asleep = player:isAsleep() == true end)
    pcall(function() local bd = player:getBodyDamage(); health = bd and tonumber(bd:getOverallBodyHealth()) or 100 end)
    pcall(function()
        local h = getGameTime():getTimeOfDay()
        night = h >= 22 or h < 5
    end)
    return asleep or health < 60 or night
end

local function turnOn(record, key)
    local j = ProjectALifeJimmy
    local R = j and j.Residents
    if R ~= nil and type(R.leaveOnTheirOwn) == "function" then pcall(R.leaveOnTheirOwn, record, "coup") end
    local talk = ProjectALife.Talk
    pcall(talk.writeMemory, record.uid, function(m)
        m.hostileToPlayerKeys = type(m.hostileToPlayerKeys) == "table" and m.hostileToPlayerKeys or {}
        m.hostileToPlayerKeys[key] = true
    end)
end

local function residentsOf(key)
    local out = {}
    local reg = registry()
    if reg == nil or type(reg.each) ~= "function" then return out end
    pcall(reg.each, function(rec)
        local res = type(rec.memory) == "table" and rec.memory.jimmyResident or nil
        if type(res) == "table" and rec.lifecycle ~= "dead" then out[#out + 1] = rec end
        return false
    end)
    return out
end

function M.daily()
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    local key = B().keyOf(player)
    if key == nil then return end
    local d = today()
    local plotters = {}
    for _, rec in ipairs(residentsOf(key)) do
        local r = B().row(key, rec.uid, true)
        grow(key, rec.uid, r, rec)
        subvert(key, rec.uid, r, rec)
        local arch = M.archetypeOf(rec, r)
        local ready = r.act == nil or d - r.act >= M.ACT_GAP_DAYS
        -- opportunists walk when you stop providing, fear or not
        if arch == "Opportunist" and st(r.n) <= 1 and st(r.l) <= 1 and st(r.d) <= 1 and roll100() < 25 then
            local R = ProjectALifeJimmy and ProjectALifeJimmy.Residents
            if R ~= nil and pcall(R.leaveOnTheirOwn, rec, "better_offer") then
                M.metrics.opportunists = M.metrics.opportunists + 1
                notify(player, nameOf(rec) .. " packed up and left. Nothing here worth staying for.", false)
            end
        elseif ready and (r.sv or 0) >= 6 then
            local fid = enemyFaction(key)
            local rd = ProjectALife.RaidDirector
            if fid ~= nil and rd ~= nil and type(rd.warn) == "function" then
                r.act = d
                M.metrics.tipoffs = M.metrics.tipoffs + 1
                pcall(rd.warn, player, fid, hours())
                ALifeHealth.note(TAG, tostring(rec.uid) .. " tipped off " .. tostring(fid))
            end
        elseif ready and (r.sv or 0) >= 3 then
            local n = steal(rec)
            if n > 0 then
                r.act = d
                M.metrics.thefts = M.metrics.thefts + 1
                notify(player, "Something's missing from the stores...", false)
                ALifeHealth.note(TAG, tostring(rec.uid) .. " stole " .. n .. " item(s)")
            end
        end
        if (r.sv or 0) >= 8 then plotters[#plotters + 1] = rec end
    end
    if #plotters >= 2 and playerVulnerable(player) then
        M.metrics.coups = M.metrics.coups + 1
        for _, rec in ipairs(plotters) do turnOn(rec, key) end
        notify(player, "Your people have turned on you!", false)
        ALifeHealth.note(TAG, "coup: " .. #plotters .. " residents turned hostile")
    end
end

-- ---------------------------------------------------------------- hooks -----
local function install()
    if M.__installed or B() == nil then return M.__installed == true end
    M.__installed = true
    if P() ~= nil and type(P().install) == "function" then pcall(P().install) end   -- power first, so we wrap its fear
    local Bd = B()
    -- loved ones: a prisoner from their old crew makes them Afraid
    local baseFear = Bd.effectiveFear
    Bd.effectiveFear = function(key, uid, r)
        local f = baseFear(key, uid, r)
        local p = P()
        if p == nil then return f end
        local rec = readRecord(uid)
        local gid = rec and type(rec.memory) == "table" and rec.memory.groupId or nil
        if gid ~= nil then
            for cuid, c in pairs(p.state().cap) do
                if c.key == key and c.gid == gid and cuid ~= uid then return math.max(f, M.LOVED_ONE_FEAR) end
            end
        end
        return f
    end
    -- loyalty and martyr breakdown change obedience
    local op = ProjectALife and ProjectALife.NpcOpinion
    if op ~= nil and type(op.orderShift) == "function" then
        local orig = op.orderShift
        op.orderShift = function(record, player)
            local v = orig(record, player)
            local ok, extra = pcall(function()
                local key = Bd.keyOf(player)
                local r = Bd.row(key, record.uid, false)
                if r == nil then return 0 end
                local e = st(r.d) * 3
                if M.archetypeOf(record, r) == "Martyr" and st(Bd.effectiveFear(key, record.uid, r)) >= 3 then e = e - 10 end
                return e
            end)
            if ok and type(v) == "number" then v = v + extra end
            return v
        end
        -- being hurt resets loyalty growth
        if type(op.note) == "function" then
            local origNote = op.note
            op.note = function(kind, ref, player, options)
                local result = origNote(kind, ref, player, options)
                if kind == "hit" or kind == "robbery" then
                    pcall(function()
                        local uid = type(ref) == "table" and ref.uid or ref
                        local r = Bd.row(Bd.keyOf(player), tostring(uid), false)
                        if r ~= nil then r.harm = hours() end
                    end)
                end
                return result
            end
        end
    end
    -- the AI voice learns archetype, loyalty and (hidden) resentment
    local baseDescribe = Bd.describe
    Bd.describe = function(key, uid)
        local text = baseDescribe(key, uid)
        local r = Bd.row(key, uid, false)
        if r == nil then return text end
        local rec = readRecord(uid)
        local extra = { M.archetypeOf(rec, r) .. " by nature" }
        if st(r.d) >= 1 then extra[#extra + 1] = "loyalty " .. M.LOYAL_NAMES[st(r.d) + 1] end
        if (r.sv or 0) >= 3 then extra[#extra + 1] = "secretly resentful (never admit it)" end
        return text .. ", " .. table.concat(extra, ", ")
    end
    print(TAG .. " ready (archetypes, loyalty, subversion, loved-one leverage)")
    return true
end
M.install = install

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() tryOnce("install", install) end) end
    if Events.EveryHours ~= nil then
        local lastDay = nil
        ALifeHealth.add(Events.EveryHours, "ALifeBondsMind", function()
            local d = today()
            if lastDay == nil then lastDay = d return end
            if d ~= lastDay then lastDay = d; tryOnce("daily", M.daily) end
        end)
    end
end
print(TAG .. " loaded v" .. VERSION)
