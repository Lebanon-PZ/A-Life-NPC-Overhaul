-- A-Life NPC Overhaul: people remember what happened, and talk about it.
-- A-Life scores your deeds (gifts, medicine, fighting beside them, saving lives, trades, robbery, hits, killing one of
-- theirs, broken deals). This keeps them as memories instead:
--   the person it happened to remembers it ("day 31, evening: you shared food with me")
--   anyone of theirs close enough saw it          ("I saw you hit Dale")
--   their whole group hears about it soon after   ("Laura says you patched her up")
--   big things travel to other groups by word of mouth over the following days ("word is you killed one of the
--   Kettle crew") - robbery, killings, broken deals, and lives saved
--   and things you tell them that matter (your name, where your base is, what you want) - the AI notes those
-- Every AI line gets "what you remember about this stranger", so they bring it up, hold grudges, owe you, or have
-- heard of you before you've ever met.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeMemory") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeMemory]"
ALifeMemory = ALifeMemory or {}
local M = ALifeMemory
M.STORE = "ALifeChatPlus.Memory"
M.PERSON_CAP, M.GROUP_CAP, M.WORLD_CAP = 14, 12, 16
M.WITNESS_TILES = 15
M.SPREAD_CHANCE = 35            -- percent per day a big story reaches each other group
M.BIG = { slur = true, robbery = true, killed_mate = true, killed = true, betrayal = true, saved = true, hit = true }
M.TEXT = {
    gift = "shared food or water with %s", medicine = "patched up %s", help_fight = "fought beside %s",
    saved = "saved %s's life", trade = "traded fairly with %s", promise = "kept their word to %s",
    door_kind = "treated %s well at the door", walk = "walked the road with %s",
    threat_failed = "threatened %s and backed down", rude = "was rude to %s", robbery = "robbed %s",
    hit = "attacked %s", killed_mate = "killed one of %s's people", killed = "killed %s", betrayal = "broke a deal with %s",
    party_task = "came through for %s's group", party_fail = "let %s's group down", party_desert = "abandoned %s's group",
    flirt = "flirted with %s", slur = "called %s a hateful slur", flirt_after_no = "kept pushing %s after being told no",
}

local function store()
    local s = type(ModData) == "table" and ModData.getOrCreate(M.STORE) or {}
    s.people, s.groups, s.world, s.pending = s.people or {}, s.groups or {}, s.world or {}, s.pending or {}
    return s
end
local function push(list, line, cap)
    if list[#list] == line then return end
    list[#list + 1] = line
    while #list > cap do table.remove(list, 1) end
end
local function stamp()
    local ok, day, hour = pcall(function()
        local gt = getGameTime()
        return math.floor(gt:getWorldAgeHours() / 24) + 1, math.floor(gt:getTimeOfDay())
    end)
    if not ok then return "earlier" end
    local part = (hour < 5 and "night") or (hour < 12 and "morning") or (hour < 17 and "afternoon") or (hour < 21 and "evening") or "night"
    return "day " .. tostring(day) .. " " .. part
end
local function nameOf(record)
    local N = ProjectALife and ProjectALife.Names
    if N ~= nil and type(N.of) == "function" then
        local ok, n = pcall(N.of, record)
        if ok and n ~= nil then return tostring(n) end
    end
    return "someone"
end
local function personKey(record)
    if ALifeStory ~= nil then return ALifeStory.keyOf(record) end
    return type(record) == "table" and record.uid and ("u:" .. tostring(record.uid)) or nil
end
local function groupOf(record)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    return m.groupId, record and record.factionId or m.factionId
end
local function pos(o)
    if o == nil then return nil end       -- dead or unloaded: no shell (pcall still logs an error, so check first)
    local ok, x, y = pcall(function() return o:getX(), o:getY() end)
    if ok then return x, y end
    return nil
end

function M.add(record, line)
    local k = personKey(record)
    if k == nil or line == nil then return end
    if ALifeUpkeep ~= nil then pcall(ALifeUpkeep.saw, record) end
    local s = store()
    s.people[k] = s.people[k] or {}
    push(s.people[k], stamp() .. ": " .. line, M.PERSON_CAP)
end

-- a deed: the one it happened to, witnesses, their group now, other groups later
function M.deed(kind, record, player)
    local fmt = M.TEXT[kind]
    if fmt == nil or type(record) ~= "table" then return end
    local who = nameOf(record)
    if kind ~= "killed" then
        M.add(record, "the stranger " .. (kind == "killed_mate" and "killed one of your people" or string.format(fmt, "you")))
    end
    local s = store()
    local gid, fid = groupOf(record)
    -- witnesses: people near the victim who saw it
    local reg, Talk = ProjectALife.ActorRegistry, ProjectALife.Talk
    local vx, vy = pos(Talk and Talk.shellFor and Talk.shellFor(record.uid))
    if reg ~= nil and vx ~= nil then
        pcall(reg.each, function(r)
            if r.uid ~= record.uid and r.lifecycle == "active" then
                local x, y = pos(Talk.shellFor(r.uid))
                if x ~= nil and (x - vx) ^ 2 + (y - vy) ^ 2 <= M.WITNESS_TILES ^ 2 then
                    M.add(r, "you saw the stranger " .. string.format(fmt, who))
                end
            end
            return false
        end)
    end
    -- their group hears it
    local g = gid or fid
    if g ~= nil then
        s.groups[g] = s.groups[g] or {}
        local line = (kind == "killed" and ("the stranger killed " .. who))
            or (kind == "killed_mate" and "the stranger killed one of ours")
            or (who .. " says the stranger " .. string.format(fmt, "them"))
        push(s.groups[g], stamp() .. ": " .. line, M.GROUP_CAP)
    end
    -- big news travels
    if M.BIG[kind] and kind ~= "killed_mate" then
        s.pending[#s.pending + 1] = { text = "the stranger " .. string.format(fmt, who) .. (fid and (" (" .. tostring(fid) .. ")") or ""),
            from = fid, at = stamp() }
        while #s.pending > 20 do table.remove(s.pending, 1) end
    end
end

-- once a day: word of mouth carries big stories to other groups
function M.spread()
    local s = store()
    local keep = {}
    for _, p in ipairs(s.pending) do
        local reached = (type(ZombRand) == "function" and ZombRand(100) or 0) < M.SPREAD_CHANCE
        if reached then push(s.world, "word going around (" .. tostring(p.at) .. "): " .. p.text, M.WORLD_CAP)
        else keep[#keep + 1] = p end
    end
    s.pending = keep
end

-- what this person knows about the stranger: theirs, their group's, and what's going around
function M.about(record)
    local s = store()
    local out = {}
    local k = personKey(record)
    for _, l in ipairs(k and s.people[k] or {}) do out[#out + 1] = l end
    local gid, fid = groupOf(record)
    for _, l in ipairs((gid or fid) and s.groups[gid or fid] or {}) do out[#out + 1] = l end
    local w = s.world
    for i = math.max(1, #w - 3), #w do
        local l = w[i]
        if l ~= nil and not (fid and string.find(l, "(" .. tostring(fid) .. ")", 1, true)) then out[#out + 1] = l end
    end
    while #out > 12 do table.remove(out, 1) end
    if ALifeHousehold ~= nil then
        local ok, h = pcall(ALifeHousehold.describe, record)
        if ok and h ~= nil and h ~= "" then out[#out + 1] = "the others at the base: " .. h end
    end
    return table.concat(out, " | ")
end

function M.install()
    if M.__installed then return true end
    local Op = ProjectALife and ProjectALife.NpcOpinion
    if Op == nil or type(Op.note) ~= "function" then return false end
    M.__installed = true
    local orig = Op.note
    Op.note = function(kind, ref, player, options)
        local result = orig(kind, ref, player, options)
        pcall(function()
            local record = type(Op.recordOf) == "function" and Op.recordOf(ref) or (type(ref) == "table" and ref or nil)
            if record ~= nil then M.deed(kind, record, player) end
        end)
        return result
    end
    if type(Op.noteKill) == "function" then
        local origKill = Op.noteKill
        Op.noteKill = function(victim, killerKey, killer)
            pcall(M.deed, "killed", victim, killer)
            return origKill(victim, killerKey, killer)
        end
    end
    print(TAG .. " ready (deeds remembered, witnessed and passed on)")
    return true
end

local lastDay
if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            local ok, err = pcall(M.install)
            if not ok then print(TAG .. " install failed: " .. tostring(err)) end
        end)
    end
    if Events.EveryHours ~= nil then
        ALifeHealth.add(Events.EveryHours, "ALifeMemory", function()
            local ok, d = pcall(function() return math.floor(getGameTime():getWorldAgeHours() / 24) end)
            if not ok then return end
            if lastDay ~= nil and d ~= lastDay then pcall(M.spread) end
            lastDay = d
        end)
    end
end
print(TAG .. " loaded")
