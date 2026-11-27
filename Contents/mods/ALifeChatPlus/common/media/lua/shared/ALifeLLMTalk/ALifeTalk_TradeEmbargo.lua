-- A-Life NPC Overhaul pre-1.0: TRADE, PART 3. EMBARGO AND FEUDS (docs/PLAN-TRADE.md T7).
--  * you kill or attack a group's traders (a run on the road, a caravan at your place, Jeem's visitors from a real
--    group): that group won't trade with you, and its friends think less of you; friends who think little enough of
--    you stop trading too. Word only travels if someone lived to carry it (a run where everyone died: they just
--    never came back).
--  * it fades (embargoDays), sooner if you pay back what was taken, in person, at their place.
--  * between groups: robbing another group's run sours them; bad enough and every road between them is closed and
--    their friends take sides.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_TradeEmbargo")
require "ALifeLLMTalk/ALifeTalk_TradeRuns"
local M = ALifeLLMTalk
local T = ALifeTrade
if type(M) ~= "table" or type(T) ~= "table" then return end
local fn, d2, hours, log, event = T.fn, T.d2, T.hours, T.log, T.event

T.defaults({ embargo = true, embargoDays = 21, embargoRep = 40, attackRep = 15, allyTie = 40, allyRepShare = 40,
    allyEmbargoBelow = 30, repayFactor = 100, feudTie = -50, feudAllyTie = 5 })
T.addRows({
    { "embargo", "Embargo: kill or attack a group's traders and they (and maybe their friends) won't trade with you for a while" },
    { "embargoDays", "Embargo: days it lasts unless you pay back", { 7, 21, 45 } },
    { "repayFactor", "Embargo: paying back takes this much of what was taken (percent of worth)", { 50, 100, 150 } },
    { "allyRepShare", "Embargo: how much of it a group's friends take to heart (percent)", { 20, 40, 70 } },
})
M.trEmbStats = M.trEmbStats or { started = 0, allies = 0, ended = 0, repaid = 0, feuds = 0 }
local S = M.trEmbStats

function T.embargoed(groupId, who)
    if not T.on("embargo") then return false end
    local e = T.store().embargo[tostring(groupId)]
    if type(e) ~= "table" then return false end
    local x = e[tostring(who or "you")]
    return type(x) == "table" and (tonumber(x.untilH) or 0) > hours()
end
function T.embargoOf(groupId, who)
    local e = T.store().embargo[tostring(groupId)]
    return type(e) == "table" and e[tostring(who or "you")] or nil
end
local function setEmbargo(b, who, days, why, owed)
    local st = T.store()
    local e = type(st.embargo[b.id]) == "table" and st.embargo[b.id] or {}
    st.embargo[b.id] = e
    local h = hours()
    local x = type(e[who]) == "table" and e[who] or { owed = 0 }
    x.untilH = math.max(tonumber(x.untilH) or 0, h + days * 24)
    x.why = why
    x.owed = (tonumber(x.owed) or 0) + (tonumber(owed) or 0)
    x.fromH = x.fromH or h
    e[who] = x
    return x
end

-- which group a person belongs to while trading (a run, a face-to-face caravan, a Jeem caravan)
function T.traderGroupOf(uid)
    local r = nil
    pcall(function() r = T.PA().ActorRegistry.read(tostring(uid)) end)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or nil
    if m == nil then return nil end
    if m.alcpRun then
        local run = T.store().runs[m.alcpRun]
        if run and run.from ~= "you" then return T.base(run.from), run end
    end
    if type(m.alcpCaravan) == "table" then return T.base(m.alcpCaravan.home), nil end
    if m.alcpOwnVisit and fn(M, "nbStore") then
        local v = (M.nbStore().ovVisits or {})[m.alcpOwnVisit]
        if v then return T.base(v.home), nil end
    end
    return nil
end
-- you wronged them (kind = "killed" | "attacked"): carried = what the crew had on them (worth)
function T.wronged(b, kind, carried, player, run)
    if not T.on("embargo") or type(b) ~= "table" then return end
    local h = hours()
    local key = b.id .. ":" .. kind
    T.lastWrong = T.lastWrong or {}
    if h - (T.lastWrong[key] or -1e9) < 1 then return end -- one fight = one wrong
    T.lastWrong[key] = h
    -- did anyone live to tell? (a run: the rest of the crew; anything else: assume so)
    if run then
        local alive = 0
        for _, uid in ipairs(run.crew or {}) do
            local r = nil; pcall(function() r = T.PA().ActorRegistry.read(uid) end)
            if r and r.lifecycle ~= "dead" then alive = alive + 1 end
        end
        if alive == 0 then return end
    end
    local repLoss = kind == "killed" and T.num("embargoRep") or T.num("attackRep")
    local why = kind == "killed" and "You killed one of their traders" or "You attacked their traders"
    if fn(M, "nbRep") then pcall(M.nbRep, b, -repLoss, why) end
    local days = T.num("embargoDays") * (kind == "killed" and 1 or 0.5)
    setEmbargo(b, "you", days, why, carried)
    S.started = S.started + 1
    T.letter(player, "Word is out: " .. tostring(b.name) .. " won't trade with you.", true)
    -- their friends hear it
    local share = T.num("allyRepShare") / 100
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and fn(M, "dirTie") and M.dirTie(o, b) >= T.num("allyTie") then
            if fn(M, "nbRep") then pcall(M.nbRep, o, -repLoss * share, "Heard you attacked traders from " .. tostring(b.name)) end
            if (tonumber(o.rep) or 50) < T.num("allyEmbargoBelow") then
                setEmbargo(o, "you", days * 0.5, "Friends of " .. tostring(b.name), 0)
                S.allies = S.allies + 1
                T.letter(player, tostring(o.name) .. " stands with " .. tostring(b.name) .. ": no trade with you either.", true)
            end
        end
    end
    log(tostring(b.name) .. " embargo on you (" .. kind .. ", " .. tostring(math.floor(days + 0.5)) .. " days)")
end

-- pay back: at their place, things from your inventory worth what's owed
function T.repayNeeded(groupId)
    local x = T.embargoOf(groupId, "you")
    if type(x) ~= "table" then return 0 end
    return math.max(5, (tonumber(x.owed) or 0) * T.num("repayFactor") / 100)
end
function T.repay(player, groupId)
    local b = T.base(groupId)
    if b == nil or not T.embargoed(groupId, "you") then return false, "no_embargo" end
    local at = fn(M, "nbAtPlayer") and M.nbAtPlayer(player) or nil
    if at == nil or at.id ~= b.id then return false, "not_there" end
    local need = T.repayNeeded(groupId)
    -- pick from your inventory, most valuable first, never what you wear or hold
    local items = {}
    pcall(function()
        local list = player:getInventory():getItems()
        for i = 0, list:size() - 1 do
            local it = list:get(i)
            local skip = false
            pcall(function() if player:isEquipped(it) or player:isEquippedClothing(it) then skip = true end end)
            if not skip then items[#items + 1] = { it = it, v = type(ALifeWorth) == "table" and ALifeWorth.item(it) or 1 } end
        end
    end)
    table.sort(items, function(a, c) return a.v > c.v end)
    local got, take = 0, {}
    for _, e in ipairs(items) do if got >= need then break end; take[#take + 1] = e; got = got + e.v end
    if got < need then return false, "not_enough" end
    local types = {}
    for _, e in ipairs(take) do
        local t = nil; pcall(function() t = e.it:getFullType() end)
        if t then pcall(function() player:getInventory():Remove(e.it) end); types[#types + 1] = t end
    end
    T.putIn(b, types)
    T.store().embargo[b.id]["you"] = nil
    if fn(M, "nbRep") then pcall(M.nbRep, b, 10, "You paid back what was taken") end
    S.repaid = S.repaid + 1
    T.letter(player, tostring(b.name) .. " took your payment. They'll trade with you again.", false)
    return true, #types
end

-- between groups: robber took from victim's run
function T.feudRobbed(robber, victim)
    if type(robber) ~= "table" or type(victim) ~= "table" or not fn(M, "dirTieAdd") then return end
    M.dirTieAdd(victim, robber, -10)
    if M.dirTie(victim, robber) <= T.num("feudTie") then
        S.feuds = S.feuds + 1
        for _, o in ipairs(M.nbActive()) do
            if o.id ~= victim.id and o.id ~= robber.id and M.dirTie(o, victim) >= T.num("allyTie") then M.dirTieAdd(o, robber, -T.num("feudAllyTie")) end
        end
    end
end
function T.feuding(a, b) return fn(M, "dirTie") and type(a) == "table" and type(b) == "table" and M.dirTie(a, b) <= T.num("feudTie") end

-- daily: embargoes run out
function T.embargoDaily()
    local h = hours()
    for gid, e in pairs(T.store().embargo) do
        if type(e) == "table" then
            for who, x in pairs(e) do
                if type(x) ~= "table" or (tonumber(x.untilH) or 0) <= h then
                    e[who] = nil
                    S.ended = S.ended + 1
                    local b = T.base(gid)
                    if b and who == "you" then T.letter(nil, tostring(b.name) .. " will trade with you again.", false) end
                end
            end
        end
    end
end

-- hooks: deaths and hits on traders; caravans don't come from a group that won't trade with you
function T.onNpcDied(body, uid, killer)
    if not T.on("embargo") then return end
    local b, run = T.traderGroupOf(uid)
    if b == nil then return end
    local player = ALifeSide.you()
    local kid = nil
    if fn(M, "killerOf") then local _; _, kid = M.killerOf(killer, player, body) end
    if kid ~= "player" then return end
    local carried = 0
    if run then for _, t in ipairs((run.packs or {})[tostring(uid)] or {}) do carried = carried + (type(ALifeWorth) == "table" and ALifeWorth.of(t) or 1) end end
    T.wronged(b, "killed", carried, player, run)
end
function T.onHit(wielder, target)
    if not T.on("embargo") or wielder == nil or target == nil then return end
    local isPlayer = false
    pcall(function() isPlayer = instanceof(wielder, "IsoPlayer") and ALifeSide.isOnlinePlayer(wielder) end)
    if not isPlayer then pcall(function() isPlayer = wielder == ALifeSide.you() end) end
    if not isPlayer then return end
    local uid = nil
    pcall(function() uid = T.PA().Speech.variable(target, "ALifeUID") end)
    if uid == nil or tostring(uid) == "" then return end
    local b, run = T.traderGroupOf(uid)
    if b then T.wronged(b, "attacked", 0, wielder, run) end
end
function T.installEmbargo()
    M._alcpHooks = M._alcpHooks or {}
    if M._alcpHooks.tradeEmbargo then return true end
    if not fn(M, "tpKnows") then return false end
    M._alcpHooks.tradeEmbargo = true
    local knows = M.tpKnows
    M.tpKnows = function(b, ...)
        if type(b) == "table" and T.embargoed(b.id, "you") then return false end
        return knows(b, ...)
    end
    return true
end
pcall(T.installEmbargo)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function()
        pcall(T.installEmbargo)
        print(T.TAG .. " ready v" .. T.VERSION .. ": embargo and feuds " .. (T.on("embargo") and "on" or "off"))
    end) end
    if Events.EveryDays then ALifeHealth.add(Events.EveryDays, "ALifeTalk_TradeEmbargo", function() pcall(T.embargoDaily) end) end
    if Events.ProjectALife_NpcDied then ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeTalk_TradeEmbargo", function(a, b, c) pcall(T.onNpcDied, a, b, c) end) end
    if Events.OnWeaponHitCharacter then ALifeHealth.add(Events.OnWeaponHitCharacter, "ALifeTalk_TradeEmbargo", function(a, b) pcall(T.onHit, a, b) end) end
end
