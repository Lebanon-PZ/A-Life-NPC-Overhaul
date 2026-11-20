-- A-Life NPC Overhaul: keeping the save lean, and remembering who you've met.
-- Every list Chat Plus keeps is capped, but the number of PEOPLE in them only grew: the dead kept their memories,
-- strangers you met once on day 3 kept a life story forever. Once a game day this clears out:
--   people A-Life marks dead (after a month, so their bodies can still be recognized)
--   people nobody has seen or spoken of in 120 days: memories, life story, a bond with nothing in it
--   relationships at a base between people who no longer live there
-- Never pruned: partners, prisoners, residents, anyone with a real bond to you (love, fear, need or loyalty).
-- It also notes each group you actually meet (talk to, or deal with), for the Groups page.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeUpkeep") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeUpkeep]"
ALifeUpkeep = ALifeUpkeep or {}
local U = ALifeUpkeep
U.STORE = "ALifeChatPlus.Upkeep"
U.FORGET_DAYS, U.DEAD_DAYS = 120, 30

local function store()
    local s = type(ModData) == "table" and ModData.getOrCreate(U.STORE) or {}
    s.seen, s.dead, s.met, s.uidOf = s.seen or {}, s.dead or {}, s.met or {}, s.uidOf or {}
    return s
end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end
local function reg() return ProjectALife and ProjectALife.ActorRegistry end

-- someone was involved in something: seen now, and their group is one you've met
function U.saw(record)
    if type(record) ~= "table" or record.uid == nil then return end
    local s = store()
    s.seen[tostring(record.uid)] = hours()
    if ALifeStory ~= nil then
        local k = ALifeStory.keyOf(record)
        if k then s.seen[k] = hours(); s.uidOf[k] = tostring(record.uid) end
    end
    local fid = record.factionId or (type(record.memory) == "table" and record.memory.factionId) or nil
    if fid ~= nil and s.met[fid] == nil then s.met[fid] = { day = math.floor(hours() / 24) + 1 } end
    if record.lifecycle == "dead" then s.dead[tostring(record.uid)] = s.dead[tostring(record.uid)] or hours() end
end

local function protected(uid)
    local B = ALifeBonds
    local rec = reg() and reg().read and reg().read(uid) or nil
    if type(rec) == "table" and type(rec.memory) == "table" and type(rec.memory.jimmyResident) == "table" then return true end
    if B ~= nil then
        local ok, st = pcall(B.store)
        if ok and type(st) == "table" then
            for _, rows in pairs(st.p or {}) do
                local r = rows[uid]
                if type(r) == "table" and (r.partner or (B.stageOf(r.l or 0) + B.stageOf(r.f or 0) + B.stageOf(r.n or 0) + B.stageOf(r.d or 0)) > 0) then
                    return true
                end
            end
        end
    end
    local P = ALifeBondsPower
    if P ~= nil then
        local ok, ps = pcall(P.state)
        if ok and type(ps) == "table" and type(ps.cap) == "table" and ps.cap[uid] ~= nil then return true end
    end
    return false
end

function U.prune()
    local s = store()
    local now = hours()
    local forget, deadAfter = U.FORGET_DAYS * 24, U.DEAD_DAYS * 24
    local gone = {}
    -- dead, a month on
    for uid, at in pairs(s.dead) do if now - at > deadAfter and not protected(uid) then gone[uid] = true end end
    -- not seen in a long time
    for k, at in pairs(s.seen) do
        if now - at > forget then
            local uid = string.match(k, "^u:(.+)$") or s.uidOf[k] or k
            if not protected(uid) then gone[k] = true end
        end
    end
    local n = 0
    local mem = type(ModData) == "table" and ModData.getOrCreate("ALifeChatPlus.Memory") or {}
    local stories = type(ModData) == "table" and ModData.getOrCreate("ALifeChatPlus.Stories") or {}
    for k in pairs(gone) do
        for _, key in ipairs({ k, "u:" .. k }) do
            if mem.people and mem.people[key] then mem.people[key] = nil; n = n + 1 end
            if stories[key] then stories[key] = nil; n = n + 1 end
        end
        s.seen[k], s.dead[k], s.uidOf[k] = nil, nil, nil
    end
    -- empty bonds rows for people who are gone
    local B = ALifeBonds
    if B ~= nil then
        local ok, st = pcall(B.store)
        if ok and type(st) == "table" then
            for _, rows in pairs(st.p or {}) do
                for uid, r in pairs(rows) do
                    if gone[uid] and type(r) == "table" and not r.partner then rows[uid] = nil; n = n + 1 end
                end
            end
        end
    end
    -- base relationships between people who no longer live there
    local hh = type(ModData) == "table" and ModData.getOrCreate("ALifeChatPlus.Household") or {}
    if type(hh.rel) == "table" and reg() ~= nil then
        local residents = {}
        pcall(reg().each, function(r)
            if type(r.memory) == "table" and type(r.memory.jimmyResident) == "table" and r.lifecycle ~= "dead" then residents[tostring(r.uid)] = true end
            return false
        end)
        for k in pairs(hh.rel) do
            local a, b = string.match(k, "^(.-)|(.+)$")
            if a and b and not (residents[a] and residents[b]) then hh.rel[k] = nil; n = n + 1 end
        end
    end
    if n > 0 then print(TAG .. " cleared " .. n .. " old entries") end
    return n
end

function U.install()
    if U.__installed then return true end
    local Talk, Op = ProjectALife and ProjectALife.Talk, ProjectALife and ProjectALife.NpcOpinion
    if Talk == nil or type(Talk.respond) ~= "function" then return false end
    U.__installed = true
    local origRespond = Talk.respond
    Talk.respond = function(player, listener, text, nowArg, choiceIntent)
        if listener ~= nil then pcall(U.saw, listener.record) end
        return origRespond(player, listener, text, nowArg, choiceIntent)
    end
    if Op ~= nil and type(Op.note) == "function" then
        local origNote = Op.note
        Op.note = function(kind, ref, player, options)
            pcall(function() U.saw(type(Op.recordOf) == "function" and Op.recordOf(ref) or ref) end)
            return origNote(kind, ref, player, options)
        end
    end
    if Op ~= nil and type(Op.noteKill) == "function" then
        local origKill = Op.noteKill
        Op.noteKill = function(victim, killerKey, killer)
            pcall(function() if type(victim) == "table" and victim.uid then store().dead[tostring(victim.uid)] = hours() end end)
            return origKill(victim, killerKey, killer)
        end
    end
    print(TAG .. " ready (save cleanup daily; groups you meet are remembered)")
    return true
end

local lastDay
if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(U.install) end) end
    if Events.EveryHours ~= nil then
        ALifeHealth.add(Events.EveryHours, "ALifeUpkeep", function()
            local d = math.floor(hours() / 24)
            if lastDay ~= nil and d ~= lastDay then
                local ok, err = pcall(U.prune)
                if not ok then print(TAG .. " cleanup failed: " .. tostring(err)) end
            end
            lastDay = d
        end)
    end
end
print(TAG .. " loaded")
