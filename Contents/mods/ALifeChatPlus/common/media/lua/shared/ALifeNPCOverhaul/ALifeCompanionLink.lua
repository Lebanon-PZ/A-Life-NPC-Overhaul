-- A-Life NPC Overhaul 0.7.3: YOUR PARTY HOOKS INTO A-LIFE'S COMPANIONS (hook in, never replace).
-- A-Life 1.5 has its own companions (order wheel, companion sheet, they board your car, catch up when far behind).
-- Our party keeps everything it does (opinions, memory, grief, leaving when treated badly, the talk window), and:
--   * A-Life companions you own count as your party: they show up everywhere our party does.
--   * A-Life moves them. We never take over their body (our "own" step and walk-with companion mode stay off them),
--     and our car code doesn't board them when A-Life's own boarding is on.
--   * Our orders go through A-Life: "follow" / "hold" / "guard" / "wait" / "fall back" become A-Life orders.
--   * Leaving goes through A-Life: when someone in your party walks out on you (treated badly, starving...), they are
--     dismissed in A-Life too. Dismissed in A-Life (the wheel, the sheet): they leave our party as well.
--   * Recruited in A-Life (the talk window "Come with me", right click, a visitor joining...): they join our party too,
--     and if they were walking with you in our companion mode, that hands over to A-Life.
-- Every hook wraps the original, calls it, and returns its result. A hook that errors logs one line and switches
-- itself off for the session. Setting: "alifeCompanionLink" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeCompanionLink") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeCompanionLink = ALifeCompanionLink or {}
local L = ALifeCompanionLink
local TAG = "[ALifeCompanionLink]"
L.VERSION = "0.7.3"
-- our order words -> A-Life's (Rules.ORDERS in ALifeCompanionRules)
L.ORDER_MAP = { follow = "follow", hold = "hold", guard = "hold", wait = "wait", fall_back = "retreat", cover_me = "cover_me", come = "come" }
L.off = L.off or {}           -- hook name -> true once it failed (off for the session)
L.hooked = L.hooked or {}     -- hook name -> true once installed
L.inDismiss = false
L.metrics = L.metrics or { orders = 0, refusedClaims = 0, joins = 0, leaves = 0, dismissals = 0, handovers = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end

function L.enabled()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.alifeCompanionLink == false)
end

-- one guarded call: an error switches that hook off for the session, logged once
function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end

local function companions()
    local pa = PA()
    local c = pa and pa.Companions
    if fn(c, "entry") and fn(c, "playerKey") then return c end
    return nil
end

function L.keyOf(player)
    local c = companions()
    if c == nil or player == nil then return nil end
    local ok, key = pcall(c.playerKey, player)
    return ok and key or nil
end

-- the A-Life owner key of this NPC's companion entry (nil: not an A-Life companion, or A-Life companions are off)
function L.ownerOf(uid)
    local c, pa = companions(), PA()
    if c == nil or uid == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, record = pcall(pa.ActorRegistry.read, tostring(uid))
    if not ok or type(record) ~= "table" or record.lifecycle == "dead" then return nil end
    local okE, entry = pcall(c.entry, record)
    if okE and type(entry) == "table" then return entry.owner end
    return nil
end

-- an A-Life companion (of this player, when a player is given)
function L.isALife(uid, player)
    if not L.enabled() then return false end
    local owner = L.ownerOf(uid)
    if owner == nil then return false end
    if player == nil then return true end
    return owner == L.keyOf(player)
end

function L.roster(player)
    local c = companions()
    local key = L.keyOf(player)
    if c == nil or key == nil or not fn(c, "roster") then return {} end
    local ok, list = pcall(c.roster, key)
    return ok and type(list) == "table" and list or {}
end

-- A-Life boards this one into your car itself (its companion_autoboard row on, sandbox auto-board not off)
function L.boardsSelf(uid)
    if not L.isALife(uid) then return false end
    local ride = PA() and PA().CompanionRide
    if not fn(ride, "rowOn") or not fn(ride, "autoOn") then return false end
    local ok, on = pcall(function() return ride.rowOn() == true and ride.autoOn() == true end)
    return ok and on == true
end

-- give an A-Life order (our word mapped to theirs); true when A-Life took it
function L.order(player, uid, cmd)
    local c = companions()
    local orderId = L.ORDER_MAP[tostring(cmd)]
    if c == nil or orderId == nil or not fn(c, "order") then return false, "no_such_order" end
    local ok, done, why = pcall(c.order, player, { order = orderId, uid = tostring(uid) })
    if not ok then return false, tostring(done) end
    if done == true then L.metrics.orders = L.metrics.orders + 1 end
    return done == true, why
end

function L.dismiss(player, uid, why)
    local c = companions()
    if c == nil or not fn(c, "dismiss") then return false end
    L.inDismiss = true
    local ok, done = pcall(c.dismiss, player, tostring(uid), "overhaul:" .. tostring(why or "left"))
    L.inDismiss = false
    if ok and done == true then L.metrics.dismissals = L.metrics.dismissals + 1 end
    return ok and done == true
end

local function playerByKey(key)
    local c = companions()
    if c ~= nil and fn(c, "playerByKey") then
        local ok, p = pcall(c.playerByKey, key)
        if ok and p ~= nil then return p end
    end
    local p = nil
    p = ALifeSide.campPlayer()
    return p
end

----------------------------------------------------------------------------------------------------------------
-- the hooks
----------------------------------------------------------------------------------------------------------------
local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__CompanionLink"] then L.hooked[hookName] = true; return true end -- never wrap twice
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__CompanionLink"] = orig
    L.hooked[hookName] = true
    return true
end

-- our party list: + the A-Life companions you own
function L.hookPartyMembers(M)
    return wrap(M, "partyMembers", "partyMembers", function(orig)
        return function(player, ...)
            local list = orig(player, ...)
            if not L.enabled() or L.off.partyMembers or type(list) ~= "table" then return list end
            local ok, roster = L.guard("partyMembers", L.roster, player)
            if not ok or #roster == 0 then return list end
            local seen = {}
            for _, uid in ipairs(list) do seen[tostring(uid)] = true end
            local added = false
            for _, uid in ipairs(roster) do
                if not seen[tostring(uid)] then list[#list + 1] = tostring(uid); seen[tostring(uid)] = true; added = true end
            end
            if added then table.sort(list) end
            return list
        end
    end)
end

-- still with you: an A-Life companion is with you for as long as A-Life says so
function L.hookMemberLive(M)
    return wrap(M, "partyIsMemberLive", "partyIsMemberLive", function(orig)
        return function(uid, player, ...)
            if L.enabled() and not L.off.partyIsMemberLive then
                local ok, yes = L.guard("partyIsMemberLive", L.isALife, uid, player)
                if ok and yes then return true end
            end
            return orig(uid, player, ...)
        end
    end)
end

-- walking out on you (or "dismissed" by voice): dismissed in A-Life too
function L.hookPartyLeave(M)
    return wrap(M, "partyLeave", "partyLeave", function(orig)
        return function(uid, player, why, line, ...)
            if L.enabled() and not L.inDismiss and not L.off.partyLeave then
                local ok, yes = L.guard("partyLeave", L.isALife, uid, player)
                if ok and yes then
                    L.metrics.leaves = L.metrics.leaves + 1
                    L.guard("partyLeave", L.dismiss, player, uid, why)
                end
            end
            return orig(uid, player, why, line, ...)
        end
    end)
end

-- our stance step gives orders on its own when zombies are near; for A-Life companions the orders you gave on the
-- wheel stand (we don't override them)
function L.hookStanceStep(M)
    return wrap(M, "partyStanceStep", "partyStanceStep", function(orig)
        return function(uid, player, ...)
            if L.enabled() and not L.off.partyStanceStep then
                local ok, yes = L.guard("partyStanceStep", L.isALife, uid, player)
                if ok and yes then return nil end
            end
            return orig(uid, player, ...)
        end
    end)
end

-- orders you give in words / our menus: A-Life companions get them as A-Life orders
function L.hookPlayerOrder(P)
    return wrap(P, "playerOrder", "playerOrder", function(orig)
        return function(uid, kind, player, ...)
            if L.enabled() and not L.off.playerOrder then
                local ok, yes = L.guard("playerOrder", L.isALife, uid, player)
                if ok and yes and L.ORDER_MAP[tostring(kind)] ~= nil then
                    local okO, done, why = L.guard("playerOrder", L.order, player, uid, kind)
                    if okO then return done, why end
                end
            end
            return orig(uid, kind, player, ...)
        end
    end)
end

-- we never take over an A-Life companion's body
function L.hookClaim(P)
    return wrap(P, "claim", "claim", function(orig)
        return function(uid, kind, spec, ...)
            if L.enabled() and not L.off.claim then
                local ok, yes = L.guard("claim", L.isALife, uid)
                if ok and yes then
                    L.metrics.refusedClaims = L.metrics.refusedClaims + 1
                    return false, "A-Life companion (A-Life moves them)"
                end
            end
            return orig(uid, kind, spec, ...)
        end
    end)
end

-- our walk-with companion mode stays off A-Life companions (A-Life's follow already does that, two would fight)
function L.hookStartCompanion(P)
    return wrap(P, "startCompanion", "startCompanion", function(orig)
        return function(player, listener, ...)
            if L.enabled() and not L.off.startCompanion and type(listener) == "table" and type(listener.record) == "table" then
                local ok, yes = L.guard("startCompanion", L.isALife, listener.record.uid, player)
                if ok and yes then return false, "alife_companion" end
            end
            return orig(player, listener, ...)
        end
    end)
end

-- recruited in A-Life: joins our party; our walk-with / ownership hands over to A-Life
function L.onRecruited(player, uid)
    uid = tostring(uid)
    local P = ALifeTalkPatch
    if fn(P, "companionOf") and P.companionOf(uid) ~= nil and fn(P, "stopCompanion") then
        P.stopCompanion(uid, "now an A-Life companion")
        L.metrics.handovers = L.metrics.handovers + 1
    end
    if fn(P, "owner") and P.owner(uid) ~= nil and fn(P, "release") then P.release(uid, "now an A-Life companion") end
    local M = ALifeLLMTalk
    if fn(M, "partyJoin") then
        local joined = M.partyJoin(uid, player, "alife")
        if joined then L.metrics.joins = L.metrics.joins + 1 end
    end
    log("joined your party through A-Life: " .. uid)
end

function L.hookRecruit(C)
    return wrap(C, "recruit", "recruit", function(orig)
        return function(player, uid, opts, ...)
            local r = { orig(player, uid, opts, ...) }
            if r[1] == true and L.enabled() then L.guard("recruit", L.onRecruited, player, uid) end
            return unpack(r)
        end
    end)
end

-- dismissed in A-Life (wheel, sheet, owner death): leaves our party too
function L.onDismissed(player, uid, reason)
    local M = ALifeLLMTalk
    if not fn(M, "partyLeave") or type(M.bucket) ~= "function" then return end
    local ok, b = pcall(M.bucket, "party")
    if not ok or type(b) ~= "table" or b[tostring(uid)] == nil then return end
    L.inDismiss = true
    local okL, err = pcall(M.partyLeave, tostring(uid), player, "dismissed in A-Life (" .. tostring(reason or "order") .. ")", nil)
    L.inDismiss = false
    if not okL then error(err) end
end

function L.hookDismiss(C)
    return wrap(C, "dismiss", "dismiss", function(orig)
        return function(player, uid, reason, ...)
            local r = { orig(player, uid, reason, ...) }
            if r[1] == true and L.enabled() and not L.inDismiss then L.guard("dismiss", L.onDismissed, player, uid, reason) end
            return unpack(r)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- install: at game start, then retried for a while (A-Life and our client files load at different times)
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "partyMembers", "partyIsMemberLive", "partyLeave", "partyStanceStep", "playerOrder", "claim", "startCompanion", "recruit", "dismiss" }

function L.install()
    local M, P, C = ALifeLLMTalk, ALifeTalkPatch, companions()
    if type(M) == "table" and type(M.settings) == "table" and M.settings.alifeCompanionLink == nil then M.settings.alifeCompanionLink = true end
    if type(M) == "table" then
        L.hookPartyMembers(M); L.hookMemberLive(M); L.hookPartyLeave(M); L.hookStanceStep(M)
    end
    if type(P) == "table" then L.hookPlayerOrder(P); L.hookClaim(P); L.hookStartCompanion(P) end
    if C ~= nil then L.hookRecruit(C); L.hookDismiss(C) end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end

L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then
        log("install failed: " .. tostring(n))
        return true
    end
    if #missing == 0 then
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks (A-Life companions are your party; A-Life moves them)")
        return true
    end
    if L.tries >= 20 then
        log("ready v" .. L.VERSION .. " with " .. n .. "/" .. #L.HOOKS .. " hooks; missing: " .. table.concat(missing, ", "))
        return true
    end
    return false
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        if L.tryInstall() then return end
        if Events.OnTick == nil then return end
        local last = 0
        local function retry()
            local now = 0
            pcall(function() now = getTimestampMs() end)
            if now - last < 500 then return end
            last = now
            if L.tryInstall() then Events.OnTick.Remove(retry) end
        end
        Events.OnTick.Add(retry)
    end)
end
print(TAG .. " loaded v" .. L.VERSION)
