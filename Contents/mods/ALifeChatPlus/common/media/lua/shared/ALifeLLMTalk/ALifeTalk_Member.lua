-- A-Life NPC Overhaul 0.9.2 (Legacy): JOIN AN NPC GROUP, client side (the rules: shared/ALifeMember.lua).
--   * "Can I join you?" / "let me join" / "I want to join your group" to someone near you: their group decides.
--   * The leader's orders come as a card (take it / refuse it). Watch and gate duty count while you're at their
--     haven in the hours; food and medicine count when you hand them to any of them (our Give, M.onGift).
--   * Rank changes come as letters in plain words, never numbers. Kill one of them while you're one of them: out.
--   * "I'm leaving your group" / "I quit" ends it.
--   * 0.9.2 FAST PATH: a big haul handed over at once counts (fastHaul); "<name> is stealing from us" / "<name> can't
--     be trusted" to one of them about another = a rumor (believed, or seen through); "I'm taking over" / "step aside"
--     when you're trusted or their lieutenant = a coup. Caught: the leader's price (rank down, out, or their cell).
-- Single player: straight calls; multiplayer: the server decides (memberJoin / memberAnswer / memberGive).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Member") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeMember"
local M = ALifeLLMTalk
local K = ALifeMember
if type(M) ~= "table" or type(K) ~= "table" then return end
ALifeMemberUI = ALifeMemberUI or {}
local U = ALifeMemberUI
local TAG = "[ALifeMemberUI]"
U.VERSION = ALifeSide.MOD_VERSION
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function isMP() return ALifeSide.client() end
local function toast(t) if fn(M, "momToast") then pcall(M.momToast, t) end end
local function letter(t) if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 200, 200, 160) end end
local function send(name, args) local p = playerOf(); if p and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, p, name, args or {}) end end
U.lastRank = U.lastRank or nil

-- who you're talking to: the nearest A-Life person within 4 tiles
function U.nearest(player)
    if not fn(M, "nearbyNpcs") then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = player:getX(), player:getY(), player:getZ() end)
    if x == nil then return nil end
    local ok, list = pcall(M.nearbyNpcs, x, y, z, 4)
    local best = ok and type(list) == "table" and list[1] or nil
    return best and best.record and tostring(best.record.uid) or nil
end
U.JOIN = { "can i join", "let me join", "want to join your", "take me in", "can i come with you", "join your group", "join you guys", "join your people" }
U.COUP = { "i'm taking over", "im taking over", "step aside", "i'm in charge now", "im in charge now" }
U.RUMOR = { "is stealing", "has been stealing", "can't be trusted", "cant be trusted", "is a rat", "is lying to you" }
U.CAUGHT = { down = "They saw right through you. You've lost their trust, and your place.", out = "They saw right through you. You're out.",
    cell = "They saw right through you. They take you, and lock you up." }
U.QUIT = { "leaving your group", "i quit your", "i'm done with your group", "im done with your group" }
U.SAY = {
    yes = "They talk it over. \"Alright. You're in. Watch yourself, we'll be watching you.\"",
    no = "They talk it over. \"No. Not now.\"",
    hostile = "\"Join us? After what you've done?\"",
    member = "You're already one of someone's people.",
    nobody = "There's nobody here to ask.",
}
function U.onWords(player, text)
    if not K.on() then return false end
    local low = string.lower(tostring(text or ""))
    for _, w in ipairs(U.JOIN) do
        if string.find(low, w, 1, true) then
            local uid = U.nearest(player)
            if uid == nil then toast(U.SAY.nobody); return true end
            if isMP() then send("memberJoin", { uid = uid }); return true end
            local ok, why = K.join(player, uid)
            toast(U.SAY[tostring(why)] or "They say no.")
            if ok then U.lastRank = "guest" end
            return true
        end
    end
    local row = K.of(player)
    if row and not row.gone and K.setting("fastPath") ~= false then
        for _, w in ipairs(U.COUP) do
            if string.find(low, w, 1, true) then
                local r, x = K.coup(player)
                if r == "leader" then letter(K.RANK_CUE.leader .. " The old leader steps aside. They won't forget it."); U.lastRank = "leader"
                elseif r == "caught" then letter(U.CAUGHT[tostring(x)] or "They saw it coming.")
                elseif x == "rank" then toast("Nobody would follow you. Not yet.") end
                U.rankCheck(player)
                return true
            end
        end
        for _, w in ipairs(U.RUMOR) do
            local nm = string.match(low, "^%s*(%a+) " .. w)
            if nm then
                local to = U.nearest(player)
                local about = nil
                for _, m in ipairs(K.members(row.gid)) do
                    local f = nil
                    pcall(function() f = string.lower(tostring(ProjectALife.Names.of(m))) end)
                    if f and (f == nm or string.match(f, "^(%S+)") == nm) then about = tostring(m.uid) end
                end
                if to and about then
                    local r, x = K.rumor(player, about, to)
                    if r == "believed" then toast("They look over at them. They believe you.")
                    elseif r == "caught" then letter(U.CAUGHT[tostring(x)] or "They saw through it.") end
                    U.rankCheck(player)
                    return true
                end
            end
        end
    end
    if row and not row.gone then
        for _, w in ipairs(U.QUIT) do
            if string.find(low, w, 1, true) then
                if isMP() then send("memberLeave", {}) else K.leave(player, "left") end
                toast("You leave " .. tostring(row.gname) .. ". They watch you go.")
                return true
            end
        end
    end
    return false
end

-- a rank change: told in plain words
function U.rankCheck(player)
    local row = K.of(player)
    if row == nil then return nil end
    if row.gone then
        if U.lastRank ~= "gone" then
            U.lastRank = "gone"
            if row.goneWhy == "kicked out" then letter("You're out. " .. tostring(row.gname) .. " don't want you any more.")
            elseif row.goneWhy == "betrayal" then letter("You killed one of your own. " .. tostring(row.gname) .. " will never forget it.") end
        end
        return nil
    end
    if U.lastRank ~= nil and U.lastRank ~= row.rank and K.RANK_CUE[row.rank] then letter(K.RANK_CUE[row.rank]) end
    U.lastRank = row.rank
    return row.rank
end

-- the order card
function U.offer(player, order, text)
    local o = K.ORDERS[order.id]
    local leaderName = "The leader"
    pcall(function() local r = ProjectALife.ActorRegistry.read(K.of(player).leader); leaderName = ProjectALife.Names.of(r) end)
    local card = { id = "memberorder:" .. tostring(order.h), title = tostring(o.title), default = 1,
        text = tostring(leaderName) .. ": \"" .. tostring(text) .. "\"",
        choices = {
            { label = "I'll do it", fn = function() if isMP() then send("memberAnswer", { yes = true }) else K.answer(player, true) end end },
            { label = "Refuse", fn = function()
                if isMP() then send("memberAnswer", { yes = false }); return end
                local r, cue = K.answer(player, false)
                if cue then toast(tostring(leaderName) .. ": \"" .. cue .. "\"") end
                U.rankCheck(player)
            end },
        } }
    if fn(M, "momCard") then pcall(M.momCard, card) end
    return card
end
function U.hourly(player)
    if player == nil or isMP() then return end
    local order, text = K.issue(player)
    if order then U.offer(player, order, text) end
    local r, cue = K.expire(player)
    if r then toast("You didn't do what " .. tostring((K.of(player) or {}).gname or "they") .. " asked." .. (cue and (" \"" .. cue .. "\"") or "")) end
    local h = K.hours()
    if math.floor(h / 24) ~= U.lastDay then U.lastDay = math.floor(h / 24); K.daily(player) end
    U.rankCheck(player)
end
function U.tenMin(player)
    if player == nil or isMP() then return end
    local r = K.dutyTick(player, 10 / 60)
    if r == "done" then toast("Duty's done. They noticed."); U.rankCheck(player) end
end

-- handing things over (our Give / trade watcher: M.onGift)
function U.hook()
    if U.hooked or not fn(M, "onGift") then return U.hooked == true end
    local orig = M.onGift
    M.onGift = function(player, listener, items, opts, ...)
        pcall(function()
            local food, meds = 0, 0
            for _, info in ipairs(type(items) == "table" and items or {}) do
                if type(info) == "table" then
                    if info.kind == "food" or info.kind == "water" then food = food + 1 elseif info.kind == "medicine" then meds = meds + 1 end
                end
            end
            local to = listener and listener.record and tostring(listener.record.uid) or nil
            local all = type(items) == "table" and #items or 0
            if not isMP() and all >= (tonumber(K.setting("fastHaul")) or 10) then
                local row = K.of(player)
                local r = to and ProjectALife.ActorRegistry.read(to) or nil
                if row and not row.gone and r and type(r.memory) == "table" and r.memory.groupId == row.gid then K.bigHaul(player, all); U.rankCheck(player) end
            end
            for _, pair in ipairs({ { "food", food }, { "medicine", meds } }) do
                if pair[2] > 0 then
                    if isMP() then send("memberGive", { kind = pair[1], n = pair[2], to = to })
                    else local r = K.gave(player, pair[1], pair[2], to); if r == "done" then toast("That's what they asked for. They noticed."); U.rankCheck(player) end end
                end
            end
        end)
        return orig(player, listener, items, opts, ...)
    end
    U.hooked = true
    return true
end
function U.onDied(body, uid, killer)
    local player = playerOf()
    if player == nil or isMP() then return end
    local row = K.of(player)
    if row == nil or row.gone then return end
    if killer ~= nil and killer == player then K.betrayal(player, uid) end
    local r = K.leaderDied(player, uid)
    if r == "leader" then letter(K.RANK_CUE.leader); U.lastRank = "leader" end
    U.rankCheck(player)
end
function U.onState(a)
    if type(a) ~= "table" then return end
    if a.ev == "join" then toast(U.SAY[tostring(a.why)] or "They say no.") end
    if a.ev == "answer" and a.cue then toast("\"" .. tostring(a.cue) .. "\"") end
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("memberState", function(a) pcall(U.onState, a) end) end
if type(M.playerWordHooks) == "table" and not U.wordsHooked then
    U.wordsHooked = true
    table.insert(M.playerWordHooks, function(player, text) pcall(U.onWords, player, text) end)
end
function U.install()
    pcall(U.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "memberJoin", "Groups: you can join an NPC group and climb its ranks (\"can I join you?\")" },
            { "memberOrderDays", "Groups: days between the leader's orders", { 1, 2, 4, 7 } },
            { "memberDutyHours", "Groups: hours a watch or gate duty lasts", { 1, 2, 4 } },
            { "fastPath", "Groups: climb faster with big deeds or dirty ones (rumors, a coup)" },
            { "fastCatch", "Groups: chance a dirty move is seen through anyway (%)", { 10, 25, 50 } },
            { "fastHaul", "Groups: things handed over at once that count as a big haul", { 5, 10, 20 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. U.VERSION .. ": join words, order cards, duty, gifts " .. (U.hooked and "hooked" or "NOT hooked"))
end
pcall(U.hook)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(U.install) end) end
    if Events.EveryHours then Events.EveryHours.Add(function() pcall(U.hourly, playerOf()) end) end
    if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(function() pcall(U.tenMin, playerOf()) end) end
    if type(Events.ProjectALife_NpcDied) == "table" and fn(Events.ProjectALife_NpcDied, "Add") then
        Events.ProjectALife_NpcDied.Add(function(body, uid, killer) pcall(U.onDied, body, uid, killer) end)
    end
end
return U
