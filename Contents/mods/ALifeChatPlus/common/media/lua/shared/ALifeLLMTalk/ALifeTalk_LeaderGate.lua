-- A-Life NPC Overhaul 0.9.5 (Legacy): THE LEADER GATE, client side (the rule: shared/ALifeLeaderGate.lua).
-- Only the leader gives orders. Every order path asks ALifeLeaderGate.mayOrder first:
--   camp orders (M.cpOrder), work orders (M.wzOrder), jobs / roles (M.cpSetRole), party commands (M.partyCommand:
--   follow, wait, guard, go home, dismiss; talking is always fine), send to a place (M.plOrder), orders to many
--   (M.bulkOrder: the ones who aren't yours to order are left out), and (0.9.5) spoken / hotkey / field commands
--   (ALifeTalkCommands.give) and spoken orders to companions (ALifeTalkPatch.playerOrder).
-- Wrapped at load and again at OnGameStart (after every module that chains these functions has loaded).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_LeaderGate") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeLeaderGate"

ALifeLeaderGateUI = ALifeLeaderGateUI or {}
local U = ALifeLeaderGateUI
local M = ALifeLLMTalk
local LG = ALifeLeaderGate
U.VERSION = ALifeSide.MOD_VERSION
U.wrapped = U.wrapped or {}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function thePlayer(p)
    if p ~= nil then return p end
    local q = nil
    pcall(function() q = ALifeSide.you() end)
    return q
end
-- settlers count as the old camp's people too (they live at the base you ran)
local function isSettler(uid)
    if not fn(M, "bucket") then return false end
    local s = M.bucket("settlers")
    return type(s) == "table" and s[tostring(uid)] ~= nil
end
function U.check(player, uid)
    local ok, why, lead = LG.mayOrder(thePlayer(player), uid, isSettler)
    if ok then return nil end
    return LG.refusal(why, lead)
end
function U.tell(text)
    if text == nil then return end
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outNote, ALifeSide.cur, text, 230, 200, 140) end; return end -- MP: the one who gave the order
    if fn(M, "momNote") then pcall(M.momNote, text, 230, 200, 140); return end
    local p = thePlayer(nil)
    if p and type(ALifeLetter) == "function" then pcall(ALifeLetter, p, tostring(text)) end
end

local WRAPS = {
    cpOrder = function(orig) return function(kind, record, player, ...)
        local no = type(record) == "table" and U.check(player, record.uid) or nil
        if no then return no end
        return orig(kind, record, player, ...)
    end end,
    wzOrder = function(orig) return function(record, player, ...)
        local no = type(record) == "table" and U.check(player, record.uid) or nil
        if no then return no end
        return orig(record, player, ...)
    end end,
    cpSetRole = function(orig) return function(uid, role, player, ...)
        local no = U.check(player, uid)
        if no then return no, false end
        return orig(uid, role, player, ...)
    end end,
    partyCommand = function(orig) return function(uid, cmd, player, ...)
        local no = cmd ~= "talk" and U.check(player, uid) or nil
        if no then U.tell(no); return false end
        return orig(uid, cmd, player, ...)
    end end,
    plOrder = function(orig) return function(uid, placeId, mode, ...)
        local no = U.check(nil, uid)
        if no then U.tell(no); return false end
        return orig(uid, placeId, mode, ...)
    end end,
    bulkOrder = function(orig) return function(uids, id, arg, ...)
        local keep, no = {}, nil
        for _, uid in ipairs(type(uids) == "table" and uids or {}) do
            local r = U.check(nil, uid)
            if r then no = no or r else keep[#keep + 1] = uid end
        end
        if no then U.tell(no) end
        if #keep == 0 then return 0 end
        return orig(keep, id, arg, ...)
    end end,
}
-- 0.9.5: the other order paths. Spoken / hotkey / field commands all end in ALifeTalkCommands.give (field orders
-- and hotkeys chain it); spoken orders to companions ("follow", "hold") end in ALifeTalkPatch.playerOrder per person.
-- Things done right here that aren't orders (check bites, show the map, wake / teach me, warn them) stay open.
local OTHER = {
    { key = "cmd.give", tbl = function() return ALifeTalkCommands end, name = "give", make = function(orig) return function(player, c, uids, noun, agreed, ...)
        if type(c) == "table" and c.client and c.camp == nil then return orig(player, c, uids, noun, agreed, ...) end
        local keep, no = {}, nil
        for _, uid in ipairs(type(uids) == "table" and uids or {}) do
            local r = U.check(player, uid)
            if r then no = no or r else keep[#keep + 1] = uid end
        end
        if no then U.tell(no) end
        if no and #keep == 0 then return nil end
        return orig(player, c, keep, noun, agreed, ...)
    end end },
    { key = "patch.playerOrder", tbl = function() return ALifeTalkPatch end, name = "playerOrder", make = function(orig) return function(uid, kind, player, ...)
        if U.check(player, uid) then return false end
        return orig(uid, kind, player, ...)
    end end },
}
-- wrap whatever is there now (once per function object: a module that re-chains it later gets wrapped again)
function U.hook()
    local n = 0
    for name, make in pairs(WRAPS) do
        local cur = M[name]
        if type(cur) == "function" and U.wrapped[name] ~= cur then
            local w = make(cur)
            M[name] = w
            U.wrapped[name] = w
            n = n + 1
        end
    end
    for _, o in ipairs(OTHER) do
        local t = o.tbl()
        local cur = type(t) == "table" and t[o.name] or nil
        if type(cur) == "function" and U.wrapped[o.key] ~= cur then
            local w = o.make(cur)
            t[o.name] = w
            U.wrapped[o.key] = w
            n = n + 1
        end
    end
    return n
end
function U.install()
    U.hook()
    if type(M.settingRows) == "table" then
        local have = false
        for _, r in ipairs(M.settingRows) do if r[1] == "leaderGate" then have = true end end
        if not have then M.settingRows[#M.settingRows + 1] = { "leaderGate", "Only the leader gives orders (a stranger or a member below leader can't order that camp's people)" } end
        if type(M.settingCatOf) == "table" then M.settingCatOf.leaderGate = "Your camp and base" end
    end
    print("[ALifeLeaderGateUI] ready v" .. U.VERSION .. ": order paths gated")
end
U.hook()
-- the server refused a camp order (shared gate on ALifeCmd): say why
if type(ALifeCmd) == "table" and fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("leaderGateNo", function(p) if type(p) == "table" and type(p.text) == "string" then U.tell(p.text) end end)
end
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(U.install) end) end
