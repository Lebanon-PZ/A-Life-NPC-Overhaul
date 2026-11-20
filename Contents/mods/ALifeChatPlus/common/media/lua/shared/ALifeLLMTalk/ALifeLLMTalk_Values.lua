-- A-Life Chat Plus (merged with A-Life Talk): YOU CAN'T PLEASE EVERYONE.
-- A-Life already changes how the person you helped / hurt (and their group) feels about you. This adds the people
-- who WATCHED: everyone close enough to see it judges what you did by who they are. Shoot a raider and the hard
-- ones nod while the gentle ones flinch; hand out food and the kind warm up while the greedy think you're a fool;
-- put a prisoner to work and the cruel approve while the devout turn cold. Each witness also remembers it, so the
-- AI can bring it up ("I saw what you did to that man"). In immersive mode you only see it in how they react
-- (the over-the-head reads), never as numbers.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Values") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Values"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Values") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) if M.log then M.log("values: " .. tostring(msg)) end end

if M.settings.witnessValues == nil then M.settings.witnessValues = true end
M.valCfg = { seeTiles = 18, maxDelta = 9, cooldownMs = 4000 }

-- how each kind of person weighs each kind of deed (personality categories from A-Life Talk's trait chart, 0..1)
-- base = what almost everyone feels; the rest pushes it up or down by who they are
M.valDeeds = {
    gift       = { base = 1,  kind = 6,  greedy = -3, mean = -2, paranoid = -2, cheerful = 2,  text = "saw you share food with someone" },
    medicine   = { base = 2,  kind = 6,  devout = 3,  mean = -2, calm = 1,                     text = "saw you patch someone up" },
    help_fight = { base = 2,  brave = 6, loyal = 4,   fearful = 2, kind = 1, disciplined = 2,  text = "saw you fight beside people" },
    saved      = { base = 5,  kind = 5,  brave = 3,   devout = 2, loyal = 3,                  text = "saw you save a life" },
    trade      = { base = 0,  greedy = 3, disciplined = 1,                                     text = "saw you deal fairly" },
    robbery    = { base = -3, kind = -7, disciplined = -4, devout = -4, fearful = -3, loyal = -2, mean = 4, greedy = 3, text = "saw you rob someone" },
    hit        = { base = -2, kind = -5, fearful = -4, devout = -3, calm = -2, mean = 2, volatile = 2, text = "saw you beat someone" },
    justified  = { base = 0,  brave = 4, disciplined = 3, mean = 2, loyal = 2, kind = -3, devout = -3, fearful = -4, gentle = -3, text = "saw you kill someone who came at you" },
    murder     = { base = -5, kind = -8, devout = -7, disciplined = -6, fearful = -6, loyal = -4, calm = -3, mean = 3, text = "saw you kill someone who wasn't a threat" },
    threat_failed = { base = -1, fearful = -3, brave = -2, mean = 1, sarcastic = 1,            text = "saw you make an empty threat" },
    rude       = { base = -1, proud = -3, kind = -2, sarcastic = 2, mean = 1,                  text = "heard you mouth off" },
    prisoner   = { base = -1, disciplined = 3, mean = 3, brave = 1, kind = -4, fearful = -3, devout = -2, text = "saw you take a prisoner" },
    forced_labor = { base = -1, mean = 4, greedy = 2, disciplined = 1, kind = -6, devout = -4, loyal = -1, text = "saw you put a prisoner to work" },
    spared     = { base = 1,  kind = 5,  devout = 4,  mean = -4, brave = -1, paranoid = -3,   text = "saw you let a prisoner go" },
}

local function lens(uid) local ok, l = pcall(function() return M.lens(tostring(uid)) end); return ok and type(l) == "table" and l or {} end

function M.valReaction(uid, deed)
    local d = M.valDeeds[deed]
    if d == nil then return 0 end
    local l = lens(uid)
    local v = d.base or 0
    for cat, w in pairs(d) do
        if type(w) == "number" and cat ~= "base" then v = v + (tonumber(l[cat]) or 0) * w * 2 end
    end
    v = math.max(-M.valCfg.maxDelta, math.min(M.valCfg.maxDelta, v))
    if v > 0 then return math.floor(v + 0.5) end
    return -math.floor(-v + 0.5)
end

local last = {}
-- everyone who could see it (not the person it happened to; A-Life handles them and their group)
function M.valWitnessed(deed, player, exclude, at)
    if M.settings.witnessValues == false or player == nil or M.valDeeds[deed] == nil then return 0 end
    local now = M.nowMs and M.nowMs() or 0
    local key = deed .. ":" .. tostring(exclude and exclude.uid or "")
    if now - (last[key] or -1e12) < M.valCfg.cooldownMs then return 0 end
    last[key] = now
    local px, py, pz = nil, nil, nil
    pcall(function() px, py, pz = player:getX(), player:getY(), player:getZ() end)
    if at then px, py, pz = at.x or px, at.y or py, at.z or pz end
    if px == nil then return 0 end
    local pa = PA()
    local O, reg, talk = pa.NpcOpinion, pa.ActorRegistry, pa.Talk
    if not (fn(O, "adjust") and fn(reg, "each") and fn(talk, "shellFor")) then return 0 end
    local exGroup = exclude and type(exclude.memory) == "table" and exclude.memory.groupId or nil
    local count = 0
    local d = M.valDeeds[deed]
    pcall(reg.each, function(r)
        if r.lifecycle == "active" and r.uid and (exclude == nil or r.uid ~= exclude.uid) then
            local mg = type(r.memory) == "table" and r.memory.groupId or nil
            if exGroup == nil or mg ~= exGroup then -- their own group already reacted through A-Life
                local shell = talk.shellFor(tostring(r.uid))
                local ok, x, y, z = pcall(function() return shell:getX(), shell:getY(), shell:getZ() end)
                if ok and x and math.abs((z or 0) - (pz or 0)) < 1 and (x - px) ^ 2 + (y - py) ^ 2 <= M.valCfg.seeTiles ^ 2 then
                    local delta = M.valReaction(r.uid, deed)
                    if delta ~= 0 then
                        pcall(O.adjust, r, player, delta, (delta > 0 and "Liked it when they " or "Didn't like it when they ") .. string.gsub(d.text, "^saw you ", ""):gsub("^heard you ", ""))
                        if M.keyMem then pcall(M.keyMem, tostring(r.uid), "deed", "You " .. d.text .. (delta > 0 and " (it raised them in your eyes)" or " (it lowered them in your eyes)")) end
                        count = count + 1
                    end
                end
            end
        end
        return false
    end)
    if count > 0 then log(deed .. ": " .. count .. " witnesses reacted") end
    return count
end

-- killing: was it someone who meant you harm, or not?
local function wasThreat(victim, player)
    local st = nil
    pcall(function() st = PA().Talk.stance(victim, player) end)
    if st == "hostile" then return true end
    local m = type(victim.memory) == "table" and victim.memory or {}
    if m.combatTargetPlayerKey ~= nil or victim.activity == "combat" or victim.activity == "attacking" then return true end
    return false
end

local function install()
    local O = PA().NpcOpinion
    if M.__valInstalled or not fn(O, "note") then return false end
    M.__valInstalled = true
    local note, noteKill = O.note, O.noteKill
    O.note = function(kind, ref, player, options, ...)
        local r = note(kind, ref, player, options, ...)
        pcall(function()
            if type(options) == "table" and options.door == true then return end
            local rec = fn(O, "recordOf") and O.recordOf(ref) or nil
            M.valWitnessed(kind, player, rec)
        end)
        return r
    end
    if fn(O, "noteKill") then
        O.noteKill = function(victim, killerKey, killer, ...)
            local r = noteKill(victim, killerKey, killer, ...)
            pcall(function()
                local player = (type(killer) == "userdata" and killer) or ALifeSide.you()
                if player == nil or type(victim) ~= "table" then return end
                local isPlayer = killer == player or killerKey == "player" or (PA().Speech and PA().Speech.playerKey and PA().Speech.playerKey(player) == killerKey)
                if not isPlayer then return end
                M.valWitnessed(wasThreat(victim, player) and "justified" or "murder", player, victim)
            end)
            return r
        end
    end
    -- our own prisoner system (Chat Plus) reports its deeds here
    M.valPrisoner = function(deed, player, captiveRecord) pcall(M.valWitnessed, deed, player, captiveRecord) end
    log("ready (witnesses judge what you do by who they are)")
    return true
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(install) end) end
if not install() then end
