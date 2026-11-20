-- A-Life Talk 0.4.0: nemesis grudges that come back, and NPC feuds that turn into fights.
--
-- Grudge score per NPC toward the player (our ModData bucket "nemesis"): insults/threats/hits that cost opinion,
-- watching you kill someone close. Personality decides how fast it grows and whether they let it go.
--   tier 1 Resentful (score >= 35): wants to hurt you with their fists (no guns)
--   tier 2 Vengeful  (score >= 70): comes armed with a melee weapon
--   tier 3 Murderous (score >= 110): wants you dead, guns first, brings friends
-- 12-36 game hours after a tier is reached the nemesis is sent back through A-Life's own Revenge system (the patch
-- writes a revenge contract on their offline squad: same person, backup by tier). When they find you they open with
-- a line about your history (LLM) and attack through A-Life's combat (patch: attackNow + weapon tiers).
-- Without the patch the grudge still drives dialogue, the panel and hostile reactions, but nobody is sent.
--
-- NPC vs NPC: when one of our pair scores falls to -60 or a pair becomes "nemesis", the patch's per-pair hostile
-- stance makes them really fight (A-Life targeting); it lasts 12 h and is renewed while the score stays that low;
-- low scores slowly recover, so feuds decay.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Nemesis") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Nemesis"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Nemesis") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end

M.nemesisSettings = { tiers = { 35, 70, 110 }, maxScore = 160, dueMin = 12, dueSpread = 24, retryHours = 6,
    revisitMin = 48, revisitSpread = 48, maxVisits = 3, arriveTiles = 35, decayPerDay = 8, letGoBelow = 15,
    feudAt = -60, feudHours = 12, pairRecoverPerTick = 1 }
M.nemesisLabels = { "Resentful", "Vengeful", "Murderous" }
M.nemesisMeaning = { "wants to beat you with their fists", "wants revenge and comes armed", "wants you dead" }

local function bucket(name)
    local data = M.store()
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function rec(uid)
    local pa = PA()
    return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil
end
local function nameOf(r)
    local pa = PA()
    return r and fn(pa.Names, "of") and pa.Names.of(r) or "someone"
end

function M.tierFor(score)
    local t = 0
    for i, at in ipairs(M.nemesisSettings.tiers) do if score >= at then t = i end end
    return t
end

function M.nemesisOf(uid)
    local n = bucket("nemesis")[tostring(uid)]
    if type(n) ~= "table" or (tonumber(n.tier) or 0) < 1 then return nil end
    return { tier = n.tier, score = n.g, why = n.why, label = "Nemesis: " .. M.nemesisLabels[n.tier] .. " (" .. M.nemesisMeaning[n.tier] .. ")",
        visits = n.visits or 0 }
end

-- add to the grudge (amount > 0); personality scales it, forgiving people grow it slower
function M.addGrudge(uid, amount, why, player)
    if M.settings.nemesis == false or not M.worldHere() then return nil end
    uid = tostring(uid)
    local r = rec(uid)
    if r == nil or r.lifecycle == "dead" then return nil end
    local mods = M.personaMods and M.personaMods(uid) or nil
    local mul = 1
    if mods then mul = math.max(0.4, math.min(1.8, (tonumber(mods.neg) or 1) * (1.4 - (tonumber(mods.forgive) or 0.5) * 0.8))) end
    local all = bucket("nemesis")
    local n = all[uid] or { g = 0, tier = 0, visits = 0 }
    all[uid] = n
    local before = n.tier or 0
    n.g = math.min(M.nemesisSettings.maxScore, (tonumber(n.g) or 0) + amount * mul)
    n.lastH = hours()
    if why then n.why = string.sub(tostring(why), 1, 80) end
    local tier = math.max(before, M.tierFor(n.g))
    if tier > before then
        n.tier = tier
        n.dueH = hours() + M.nemesisSettings.dueMin + ZombRand(M.nemesisSettings.dueSpread * 10) / 10
        n.sent, n.arrived = nil, nil
        log("nemesis: " .. nameOf(r) .. " is now " .. M.nemesisLabels[tier] .. " (grudge " .. math.floor(n.g) .. ": " .. tostring(n.why) .. ")")
        if M.logInteraction then M.logInteraction(uid, "Swore a grudge: " .. M.nemesisLabels[tier] .. " (" .. tostring(n.why) .. ")", nil, nil, "nemesis") end
        if tier >= 2 and M.markPlayerNemesis then pcall(M.markPlayerNemesis, uid, n.why) end
        local P = M.patch and M.patch()
        if P and fn(P, "setNemesis") then pcall(P.setNemesis, uid, tier, player or ALifeSide.you(), n.why) end
        if M.newsNote then pcall(M.newsNote, "grudge", "a survivor was heard swearing revenge on a stranger", nil, nil) end
    end
    return n
end

-- grudge from opinion losses (called from the NpcOpinion.adjust wrapper / per conversation turn)
function M.grudgeFromOpinion(uid, before, after, why)
    before, after = tonumber(before), tonumber(after)
    if before == nil or after == nil or after >= before or after > -30 then return end
    M.addGrudge(uid, (before - after) * 0.8, why)
end

-- witness saw the player kill someone close (Events death handler)
function M.grudgeFromKill(witnessUid, victimName, closeness)
    closeness = tonumber(closeness) or 0
    if closeness < 0.3 then return end
    M.addGrudge(witnessUid, 30 + closeness * 70, "you killed " .. tostring(victimName))
end

-- prompt line
table.insert(M.requestExtras, function(req, player, listener, now)
    local n = M.nemesisOf(listener.record.uid)
    if n then req.nemesis = { tier = n.tier, why = n.why } end
end)

----------------------------------------------------------------------------------------------------------------
-- tick: decay, scheduling the visit, arrival, NPC feuds
----------------------------------------------------------------------------------------------------------------
M.nemesisLastDay = nil
function M.nemesisTick()
    if M.settings.nemesis == false or not M.worldHere() then return end
    local pa = PA()
    local player = ALifeSide.you()
    if player == nil and type(ALifeSide) == "table" and ALifeSide.mpServer() and M.homePlayer then player = M.homePlayer() end -- MP: grudges are per NPC (shared); the camp's player is "the stranger" 
    if player == nil then return end
    local h = hours()
    local P = M.patch and M.patch()
    local day = math.floor(h / 24)
    local newDay = M.nemesisLastDay ~= nil and day > M.nemesisLastDay
    M.nemesisLastDay = day
    local px, py = player:getX(), player:getY()
    for uid, n in pairs(bucket("nemesis")) do
        local r = rec(uid)
        if r == nil or r.lifecycle == "dead" then
            bucket("nemesis")[uid] = nil
            if P and fn(P, "setNemesis") then pcall(P.setNemesis, uid, 0) end
        elseif type(n) == "table" then
            if newDay then -- time heals, depending on who they are
                local mods = M.personaMods and M.personaMods(uid) or nil
                local forgive = mods and tonumber(mods.forgive) or 0.5
                n.g = math.max(0, (tonumber(n.g) or 0) - M.nemesisSettings.decayPerDay * forgive * 2)
                if (n.tier or 0) >= 1 and n.g < M.nemesisSettings.letGoBelow then
                    log("nemesis: " .. nameOf(r) .. " let it go")
                    if M.logInteraction then M.logInteraction(uid, "Let the grudge go", nil, nil, "nemesis") end
                    n.tier, n.sent, n.dueH = 0, nil, nil
                    if P and fn(P, "setNemesis") then pcall(P.setNemesis, uid, 0) end
                end
            end
            local tier = tonumber(n.tier) or 0
            if tier >= 1 then
                local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
                local near = false
                if sh ~= nil and r.lifecycle == "active" then
                    local ok, d2 = pcall(function() return (sh:getX() - px) ^ 2 + (sh:getY() - py) ^ 2 end)
                    near = ok and d2 <= M.nemesisSettings.arriveTiles ^ 2
                end
                if near and not n.arrived and (n.sent or tier >= 2 or (n.dueH and h >= n.dueH)) then
                    M.nemesisArrive(uid, r, sh, player, n, tier)
                elseif not near and n.arrived and n.arrivedH and h - n.arrivedH > 6 then
                    -- they left (or you escaped): next visit later, if the grudge still stands
                    n.arrived = nil
                    n.visits = (n.visits or 0) + 1
                    n.sent = nil
                    if M.nemesisEscalate then pcall(M.nemesisEscalate, uid, n) end -- 0.5.0: each return is bigger
                    n.dueH = (n.visits < M.nemesisSettings.maxVisits) and (h + M.nemesisSettings.revisitMin + ZombRand(M.nemesisSettings.revisitSpread)) or nil
                elseif not near and not n.sent and n.dueH and h >= n.dueH and (n.visits or 0) < M.nemesisSettings.maxVisits then
                    local ok, why = false, "no patch"
                    if P and fn(P, "scheduleRevenge") then ok, why = P.scheduleRevenge(uid, player) end
                    if ok then
                        n.sent = true
                        log("nemesis: " .. nameOf(r) .. " is coming for you (" .. M.nemesisLabels[tier] .. ")")
                    else
                        n.dueH = h + M.nemesisSettings.retryHours
                    end
                end
            end
        end
    end
    pcall(M.wrapFeud)
    pcall(M.feudTick, newDay)
end

function M.nemesisArrive(uid, r, sh, player, n, tier)
    n.arrived, n.arrivedH = true, hours()
    local P = M.patch and M.patch()
    log("nemesis: " .. nameOf(r) .. " found you (" .. M.nemesisLabels[tier] .. ")")
    if M.logInteraction then M.logInteraction(uid, "Came back for revenge (" .. M.nemesisLabels[tier] .. ")", nil, nil, "nemesis") end
    if P and fn(P, "armNemesis") then pcall(P.armNemesis, sh, tier) end
    local listener = { record = r, shell = sh }
    local style = ({ "cold fury, you want a fistfight", "you came armed for revenge", "murderous, you came to kill them" })[tier]
    M.react("nemesis", listener, player, { what = "You tracked down the newcomer who " .. tostring(n.why or "wronged you")
        .. ". Confront them before you attack - remind them what they did", style = style, maxWords = 14 },
        { key = "nemesis:" .. uid, keyCooldownMs = 600000, urgent = true, face = "player",
          onDone = function() if P and fn(P, "attackNow") then pcall(P.attackNow, uid, player, "nemesis") end end })
    -- if the AI is offline the attack still happens
    if not M.bridgeAlive(M.nowMs()) and P and fn(P, "attackNow") then pcall(P.attackNow, uid, player, "nemesis") end
    if M.newsNote then pcall(M.newsNote, "revenge", "someone with a grudge was seen hunting a stranger", sh:getX(), sh:getY()) end
end

-- NPC feuds: real fights for pairs at -60 or nemesis; scores recover slowly so feuds fade
function M.feudTick(newDay)
    local P = M.patch and M.patch()
    if M.settings.attackNpc == false then return end
    local pairs_ = bucket("pairs")
    for key, row in pairs(pairs_) do
        if type(row) == "table" then
            local s = tonumber(row.s) or 0
            local a, b = string.match(key, "^(.-)|(.+)$")
            if a and b and (s <= M.nemesisSettings.feudAt or row.t == "nemesis") and P and fn(P, "npcFeud") then
                local ra, rb = rec(a), rec(b)
                if ra and rb and ra.lifecycle == "active" and rb.lifecycle == "active" and fn(P, "pairStance")
                        and P.pairStance(a, b) ~= "hostile" then
                    pcall(P.npcFeud, a, b, row.t == "nemesis" and "nemesis" or "bitter enemies", M.nemesisSettings.feudHours, true)
                end
            end
            if newDay and s < -20 and row.t ~= "nemesis" and not row.fx then row.s = s + M.nemesisSettings.pairRecoverPerTick * 3 end
        end
    end
end

-- wrap pairBump: crossing the feud line starts the fight right away (Pairs.lua loads after this file)
function M.wrapFeud()
    if type(M.pairBump) ~= "function" or M._feudWrapped then return end
    local orig = M.pairBump
    M.pairBump = function(a, b, delta, why, newType)
        local row = orig(a, b, delta, why, newType)
        pcall(function()
            if row and ((tonumber(row.s) or 0) <= M.nemesisSettings.feudAt or row.t == "nemesis") and M.settings.attackNpc ~= false then
                local P = M.patch and M.patch()
                if P and fn(P, "npcFeud") then P.npcFeud(a, b, why or "feud", M.nemesisSettings.feudHours, true) end
            end
        end)
        return row
    end
    M._feudWrapped = true
end

-- patch warning ladder: the NPC's own words (LLM) for "back off" / "last warning"
function M.onPatchWarn(record, shell, player, step, value)
    if not M.bridgeAlive(M.nowMs()) then return false end
    return M.react("warn", { record = record, shell = shell }, player, {
        what = step == 1 and "The newcomer you can't stand is too close. Warn them off" or "They're still here. Give them a last warning before you attack",
        style = step == 1 and "hostile, a clear warning" or "furious, final warning", maxWords = 10 },
        { key = "warn" .. tostring(step) .. ":" .. tostring(record.uid), keyCooldownMs = 60000, urgent = true, face = "player" }) == true
end

function M.hookPatchV11()
    local P = M.patch and M.patch()
    if P == nil or M.patchV11Hooked or type(P.hooks) ~= "table" or P.hooks.warn == nil then return end
    table.insert(P.hooks.warn, function(...) local ok, r = pcall(M.onPatchWarn, ...); return ok and r end)
    M.patchV11Hooked = true
    pcall(M.applySettings)
    log("A-Life Talk Patch " .. tostring(P.VERSION) .. ": opinion attacks, NPC feuds and nemesis visits on")
end
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.wrapFeud); pcall(M.hookPatchV11) end) end
pcall(M.hookPatchV11)

return M
