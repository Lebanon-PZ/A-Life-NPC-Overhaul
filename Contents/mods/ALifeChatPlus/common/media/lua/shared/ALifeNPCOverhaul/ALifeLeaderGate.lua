-- A-Life NPC Overhaul 0.9.5 (Legacy): THE LEADER GATE (Joe, Nov 14: "if you aren't the leader you shouldn't be able to
-- give orders"). One question every order path asks: does this player lead the people this NPC belongs to?
--   * A STRANGER (ALifeLegacy: you died, legacyStranger on, the camp not handed back yet): your old camp's residents,
--     settlers and the heir are the heir's people now. No orders, no roles, no sending them places, until the heir hands
--     the camp back ("I want the camp back" / the kin claim).
--   * A MEMBER of an NPC group (ALifeMember) below leader: their people take orders from their leader, not you.
-- Leading itself isn't voted on: they follow you for love, need or fear (ALifeBonds / ALifeBondsMind).
-- Setting leaderGate (on). The client wraps the order paths (client/ALifeLLMTalk/ALifeTalk_LeaderGate.lua).
require "ALifeNPCOverhaul/AA_Side"
ALifeLeaderGate = ALifeLeaderGate or {}
local LG = ALifeLeaderGate
LG.VERSION = ALifeSide.MOD_VERSION
LG.DEFAULTS = { leaderGate = true }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
function LG.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = LG.DEFAULTS[key] end
    return v
end
function LG.registerSettings()
    local m = ALifeLLMTalk
    if type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    m.fileKeys = m.fileKeys or {}
    local have = {}
    for _, x in ipairs(m.fileKeys) do have[x] = true end
    for k, v in pairs(LG.DEFAULTS) do
        if m.settings[k] == nil then m.settings[k] = v end
        if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end
    end
    return true
end
LG.registerSettings()

-- the legacy row while you're a stranger to your old camp (nil once handed back / off)
function LG.strangerRow(player)
    local G = ALifeLegacy
    if not fn(G, "of") or not fn(G, "keyOf") then return nil end
    if fn(G, "on") and not G.on() then return nil end
    if fn(G, "setting") and G.setting("legacyStranger") == false then return nil end
    local row = G.of(G.keyOf(player))
    if type(row) ~= "table" or row.back ~= nil then return nil end
    return row
end
-- is uid one of the old camp's people (heir, Jeem residents of that base, or isCamp(uid) from the caller: settlers)
function LG.ofOldCamp(row, uid, isCamp)
    uid = tostring(uid)
    if row.heir and tostring(row.heir) == uid then return true end
    if type(isCamp) == "function" then local ok, yes = pcall(isCamp, uid); if ok and yes then return true end end
    local m = mem(rec(uid))
    if type(m.jimmyResident) == "table" and m.jimmyResident.baseId ~= nil and tostring(m.jimmyResident.baseId) == tostring(row.baseId) then return true end
    local G = ALifeLegacy
    local base = nil
    pcall(function() local j = ProjectALifeJimmy; base = j.BaseAreas.base(row.baseId) end)
    if base and fn(G, "residents") then
        for _, r in ipairs(G.residents(base)) do if tostring(r.uid) == uid then return true end end
    end
    return false
end
-- may this player order uid? returns true, or false + why ("stranger" | "member") + who leads (a first name)
function LG.mayOrder(player, uid, isCamp)
    if LG.setting("leaderGate") == false or uid == nil then return true end
    local row = LG.strangerRow(player)
    if row and LG.ofOldCamp(row, uid, isCamp) then return false, "stranger", row.heirName end
    local K = ALifeMember
    if fn(K, "of") then
        local mrow = K.of(player)
        if type(mrow) == "table" and not mrow.gone and mrow.rank ~= "leader" and mrow.gid ~= nil
            and tostring(mem(rec(uid)).groupId) == tostring(mrow.gid) then
            local lead = nil
            if mrow.leader then pcall(function() local r = rec(mrow.leader); lead = mem(r).personFirst end) end
            return false, "member", lead
        end
    end
    return true
end
-- what they say when you try
function LG.refusal(why, lead)
    if why == "stranger" then
        return lead and ("You don't run this camp. " .. tostring(lead) .. " does.") or "You don't run this camp. Nobody here takes orders from you."
    end
    return lead and ("That's not your call. " .. tostring(lead) .. " gives the orders.") or "That's not your call. You're not the one who leads us."
end
-- ---------------------------------------------------------------------------------------------- 0.9.5: server side
-- The Settlement tab and spoken commands reach the server as ALifeCmd commands. The gate sits there too, so it holds in
-- MP and for every UI path: a stranger can't set the old camp's rations, roles, lieutenants, gate watch or jobs, or
-- vote people in; commands to people ("cmd") drop the ones you don't lead. (Settlers are a client bucket: the client
-- wraps cover them.)
LG.CAMP_WIDE = { rationSet = true, campRoles = "quiet", ltSet = true, campVoteDone = true }
LG.PER_UID = { campWork = "uid", gateSet = "uid", cmd = "uids" }
-- nil = let it through (args may be trimmed), else the refusal text ("" = refuse without a word)
function LG.cmdRefusal(player, name, args)
    if LG.setting("leaderGate") == false or type(name) ~= "string" then return nil end
    local wide = LG.CAMP_WIDE[name]
    if wide then
        local row = LG.strangerRow(player)
        if row == nil then return nil end
        if wide == "quiet" then return "" end
        return LG.refusal("stranger", row.heirName)
    end
    local field = LG.PER_UID[name]
    if field == nil or type(args) ~= "table" or args[field] == nil then return nil end
    local keep, no = {}, nil
    for u in string.gmatch(tostring(args[field]), "[^,]+") do
        local ok, why, lead = LG.mayOrder(player, u, nil)
        if ok then keep[#keep + 1] = u else no = no or LG.refusal(why, lead) end
    end
    if no == nil then return nil end
    if #keep == 0 then return no end
    args[field] = table.concat(keep, ",")
    return nil
end
function LG.hookCmd()
    local C = ALifeCmd
    if type(C) ~= "table" or type(C.handle) ~= "function" or C.handle == LG._handle then return false end
    local orig = C.handle
    LG._handle = function(player, name, args, ...)
        local ok, no = pcall(LG.cmdRefusal, player, name, args)
        if ok and no ~= nil then
            if no ~= "" and type(C.reply) == "function" then pcall(C.reply, player, "leaderGateNo", { text = no }) end
            return false
        end
        return orig(player, name, args, ...)
    end
    C.handle = LG._handle
    return true
end
LG.hookCmd()
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(LG.hookCmd) end) end
if type(Events) == "table" and Events.OnServerStarted then Events.OnServerStarted.Add(function() pcall(LG.hookCmd) end) end
print("[ALifeLeaderGate] ready v" .. LG.VERSION .. ": only the leader gives orders (" .. (LG.setting("leaderGate") ~= false and "on" or "off") .. ")")
