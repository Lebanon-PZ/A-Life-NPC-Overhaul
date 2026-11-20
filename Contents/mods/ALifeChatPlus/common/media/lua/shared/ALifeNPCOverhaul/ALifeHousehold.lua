-- A-Life NPC Overhaul: the people at your base have each other, not just you.
-- Every pair of residents has a relationship that moves day by day:
--   living and working together warms it; going out on the same mission bonds them;
--   clashing temperaments grate (a predator and a fresh kid, two veterans who both want to lead);
--   hard times - people going hungry and thirsty - turn into arguments about rations, and old rivals fight first.
-- What comes of it:
--   friends: if you hurt one, the other remembers and cools on you; they stick together
--   rivals: they argue (a memory for both and the base; you'll overhear it), and won't be sent out together happily
--   leaving: two friends who aren't loyal to you, in a bad stretch, can walk out together (Jeem's own leaving)
-- All of it is told to the AI ("Dale: your closest friend here; Rex: you can't stand him"), so they talk about each
-- other when you ask, and in the talk you overhear.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeHousehold") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeHousehold]"
ALifeHousehold = ALifeHousehold or {}
local HH = ALifeHousehold
HH.STORE = "ALifeChatPlus.Household"
HH.FRIEND, HH.RIVAL = 40, -35
HH.LEAVE_CHANCE = 20            -- percent per bad day for a disloyal pair of friends

local function store()
    local s = type(ModData) == "table" and ModData.getOrCreate(HH.STORE) or {}
    s.rel = s.rel or {}
    return s
end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pairKey(a, b) a, b = tostring(a), tostring(b); if a > b then a, b = b, a end return a .. "|" .. b end
local function nameOf(r)
    local ok, n = pcall(function() return ProjectALife.Names.of(r) end)
    return ok and n and tostring(n) or "someone"
end
local function temper(r)
    local ok, t = pcall(function() return ProjectALife.Speech.contextFor(r, nil).temperament end)
    return ok and tostring(t or "") or ""
end
local function needs(r)
    local ok, n = pcall(function() return ProjectALifeJimmy.Needs.needs(r.memory) end)
    return ok and type(n) == "table" and n or {}
end

function HH.get(a, b) return tonumber(store().rel[pairKey(a, b)]) or 0 end
function HH.add(a, b, d)
    local s = store()
    local k = pairKey(a, b)
    s.rel[k] = math.max(-100, math.min(100, (tonumber(s.rel[k]) or 0) + d))
    return s.rel[k]
end

HH.CLASH = { ["predator|fresh"] = -3, ["fresh|predator"] = -3, ["veteran|veteran"] = -1, ["predator|predator"] = -2,
    ["seasoned|seasoned"] = 1, ["fresh|fresh"] = 1, ["veteran|fresh"] = 1, ["fresh|veteran"] = 1 }

local function residentsByBase()
    local by = {}
    local reg = ProjectALife and ProjectALife.ActorRegistry
    if reg == nil then return by end
    pcall(reg.each, function(r)
        local m = type(r.memory) == "table" and r.memory or {}
        if type(m.jimmyResident) == "table" and m.jimmyResident.baseId and r.lifecycle ~= "dead" then
            local b = m.jimmyResident.baseId
            by[b] = by[b] or {}
            table.insert(by[b], r)
        end
        return false
    end)
    return by
end

local function remember(r, line) if ALifeMemory ~= nil then pcall(ALifeMemory.add, r, line) end end

-- one day at a base
function HH.day(baseId, people)
    if #people < 2 then return end
    local hungry = 0
    for _, r in ipairs(people) do
        local n = needs(r)
        if (tonumber(n.hunger) or 0) >= 60 or (tonumber(n.thirst) or 0) >= 60 then hungry = hungry + 1 end
    end
    local hard = hungry * 2 >= #people
    local together = {}
    pcall(function()
        for _, m in pairs(ProjectALifeJimmy.Residents.missions.data().list) do
            for _, u in ipairs(m.uids or {}) do together[u] = m end
        end
    end)
    local worst, worstScore = nil, 1e9
    for i = 1, #people do
        for j = i + 1, #people do
            local a, b = people[i], people[j]
            local d = 1 + (HH.CLASH[temper(a) .. "|" .. temper(b)] or 0) + roll(3) - 1
            if together[a.uid] ~= nil and together[a.uid] == together[b.uid] then d = d + 4 end
            if hard then d = d - 2 end
            local v = HH.add(a.uid, b.uid, d)
            if v < worstScore then worst, worstScore = { a, b }, v end
        end
    end
    -- hard times: the worst pair argues
    if hard and worst ~= nil and (worstScore < 0 or roll(100) < 40) then
        local a, b = worst[1], worst[2]
        HH.add(a.uid, b.uid, -6)
        remember(a, "you had a shouting match with " .. nameOf(b) .. " about rations")
        remember(b, "you had a shouting match with " .. nameOf(a) .. " about rations")
    end
    -- a bad stretch: friends who don't owe you anything walk out together
    if hard and ALifeBonds ~= nil and roll(100) < HH.LEAVE_CHANCE then
        local B = ALifeBonds
        local key
        pcall(function() key = B.keyOf(ALifeSide.campPlayer()) end)
        for i = 1, #people do
            for j = i + 1, #people do
                local a, b = people[i], people[j]
                if HH.get(a.uid, b.uid) >= HH.FRIEND then
                    local function loose(r)
                        local row = key and B.row(key, r.uid, false) or nil
                        return row == nil or (B.stageOf(row.l) < 1 and B.stageOf(row.d or 0) < 1 and B.stageOf(B.effectiveFear(key, r.uid, row)) < 2)
                    end
                    if loose(a) and loose(b) then
                        local R = ProjectALifeJimmy and ProjectALifeJimmy.Residents
                        if R ~= nil and type(R.leaveOnTheirOwn) == "function" then
                            pcall(R.leaveOnTheirOwn, a, "left with a friend")
                            pcall(R.leaveOnTheirOwn, b, "left with a friend")
                            print(TAG .. " " .. nameOf(a) .. " and " .. nameOf(b) .. " left base " .. tostring(baseId) .. " together")
                            return
                        end
                    end
                end
            end
        end
    end
end

-- how this person feels about the others at the base, for the AI
function HH.describe(record)
    local m = type(record.memory) == "table" and record.memory or {}
    local res = type(m.jimmyResident) == "table" and m.jimmyResident or nil
    if res == nil then return "" end
    local parts = {}
    for _, other in ipairs(residentsByBase()[res.baseId] or {}) do
        if other.uid ~= record.uid then
            local v = HH.get(record.uid, other.uid)
            local f = (v >= 70 and "your closest friend here") or (v >= HH.FRIEND and "a friend") or (v <= -60 and "you can't stand them")
                or (v <= HH.RIVAL and "you don't get along") or nil
            if f ~= nil then parts[#parts + 1] = nameOf(other) .. ": " .. f end
        end
    end
    return table.concat(parts, "; ")
end

-- hurting someone: their friends at the base cool on you too
function HH.onDeed(kind, record, player)
    if kind ~= "hit" and kind ~= "robbery" and kind ~= "killed_mate" then return end
    local m = type(record.memory) == "table" and record.memory or {}
    local res = type(m.jimmyResident) == "table" and m.jimmyResident or nil
    if res == nil or ALifeBonds == nil then return end
    local B = ALifeBonds
    local key = B.keyOf(player)
    for _, other in ipairs(residentsByBase()[res.baseId] or {}) do
        if other.uid ~= record.uid and HH.get(record.uid, other.uid) >= HH.FRIEND then
            pcall(B.change, key, other.uid, -4, 2, 0, { player = player, record = other })
            remember(other, "the stranger hurt " .. nameOf(record) .. ", your friend")
        end
    end
end

function HH.install()
    if ALifeMerge and ALifeMerge.skip("household") then return true end
    if HH.__installed then return true end
    local Op = ProjectALife and ProjectALife.NpcOpinion
    if Op == nil or type(Op.note) ~= "function" then return false end
    HH.__installed = true
    local orig = Op.note
    Op.note = function(kind, ref, player, options)
        local r = orig(kind, ref, player, options)
        pcall(function()
            local record = type(Op.recordOf) == "function" and Op.recordOf(ref) or ref
            if type(record) == "table" then HH.onDeed(kind, record, player) end
        end)
        return r
    end
    print(TAG .. " ready (residents form friendships and rivalries)")
    return true
end

local lastDay
if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(HH.install) end) end
    if Events.EveryHours ~= nil then
        ALifeHealth.add(Events.EveryHours, "ALifeHousehold", function()
            local ok, d = pcall(function() return math.floor(getGameTime():getWorldAgeHours() / 24) end)
            if not ok then return end
            if lastDay ~= nil and d ~= lastDay then
                for baseId, people in pairs(residentsByBase()) do
                    local okD, err = pcall(HH.day, baseId, people)
                    if not okD then print(TAG .. " day failed: " .. tostring(err)) end
                end
            end
            lastDay = d
        end)
    end
end
print(TAG .. " loaded")
