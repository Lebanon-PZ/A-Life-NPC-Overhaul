-- A-Life NPC Overhaul pre-1.0: BRAIN 4, S4 THE WORLD CHRONICLE (docs/PLAN-BRAIN-4.md). One bounded log of the big
-- things that happen between NPC groups: splits, who leads after a death, groups coming back together, moving away
-- from the dead, merges, takeovers, bases falling. Nothing is made up: every line comes from a call that really ran.
--   * radio: each line goes to the news pool (M.outNews), so Knox County Radio can tell it
--   * hearsay: when it happens within radio range (knowRadioTiles) of a player, your camp's Chronicle gets
--     "Word came: ..." (ALifeChronicle, kind "other")
--   * the AI: a group's own past is in the AI's picture of them (BR.why), so they talk about it
-- Store: global ModData "ALifeChatPlus_World" (world side; in MP the server). Nothing new crosses the network.
require "ALifeNPCOverhaul/ALifeBrain"
pcall(require, "ALifeNPCOverhaul/ALifeBrainWords")
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn, hours = BR.fn, BR.hours
local TAG = "[ALifeBrainHistory]"

BR.defaults({
    worldChronicle = true,  -- keep the world's history (splits, leaders, merges, falls)
    worldMax = 200,         -- lines kept
    worldRadio = true,      -- the radio tells it
    worldHearsay = true,    -- your camp's Chronicle hears of what happens nearby
    worldPastDays = 30,     -- days a group still talks about its own past
})
BR.addRows({
    { "worldChronicle", "World chronicle: keep the history of NPC groups (splits, leaders, merges, falls)" },
    { "worldMax", "World chronicle: lines kept", { 100, 200, 500 } },
    { "worldRadio", "World chronicle: the radio tells it" },
    { "worldHearsay", "World chronicle: your camp's Chronicle hears what happens nearby" },
    { "worldPastDays", "World chronicle: days a group still talks about its own past", { 14, 30, 90 } },
})
BR.worldStats = BR.worldStats or { added = 0, hearsay = 0, radio = 0 }
local WS = BR.worldStats

function BR.worldStore()
    local d = nil
    if type(ModData) == "table" and fn(ModData, "getOrCreate") then d = ModData.getOrCreate("ALifeChatPlus_World") end
    if type(d) ~= "table" then BR._worldMem = BR._worldMem or {}; d = BR._worldMem end
    if type(d.list) ~= "table" then d.list = {} end
    d.seq = tonumber(d.seq) or 0
    return d
end
-- ev = { k, text, x, y, ids = { baseId, ... } }
function BR.worldAdd(ev)
    if not BR.flag("worldChronicle") or type(ev) ~= "table" or type(ev.text) ~= "string" or ev.text == "" then return nil end
    local d = BR.worldStore()
    local h = hours()
    for i = #d.list, math.max(1, #d.list - 8), -1 do
        local o = d.list[i]
        if o.t == ev.text and h - (tonumber(o.h) or 0) < 24 then return nil end
    end
    d.seq = d.seq + 1
    local ids = {}
    for _, id in ipairs(type(ev.ids) == "table" and ev.ids or {}) do ids[#ids + 1] = tostring(id) end
    local e = { id = d.seq, h = h, k = tostring(ev.k or "other"), t = ev.text, x = tonumber(ev.x), y = tonumber(ev.y), ids = ids }
    d.list[#d.list + 1] = e
    while #d.list > math.max(20, BR.num("worldMax")) do table.remove(d.list, 1) end
    WS.added = WS.added + 1
    for _, id in ipairs(ids) do
        local b = M.nbOf and M.nbOf(id) or nil
        if type(b) == "table" then
            local past = type(b.past) == "table" and b.past or {}
            past[#past + 1] = { h = h, t = ev.text }
            while #past > 6 do table.remove(past, 1) end
            b.past = past
        end
    end
    if BR.flag("worldRadio") and fn(M, "outNews") then pcall(M.outNews, "politics", ev.text, e.x, e.y); WS.radio = WS.radio + 1 end
    if BR.flag("worldHearsay") and e.x and e.y and type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then
        local near = ALifeSide.nearest(e.x, e.y, BR.num("knowRadioTiles")) ~= nil
        if near then
            local ok, res = pcall(ALifeChronicle.add, { k = "other", what = "Word came: " .. ev.text })
            if ok and res then WS.hearsay = WS.hearsay + 1 end
        end
    end
    return e
end
-- the last n lines (newest last), optionally only near a spot
function BR.worldRecent(n, x, y, tiles)
    local out = {}
    local list = BR.worldStore().list
    for i = #list, 1, -1 do
        local e = list[i]
        if x == nil or (e.x and BR.d2(e.x, e.y, x, y) <= (tiles or 1500) ^ 2) then table.insert(out, 1, e) end
        if #out >= (n or 10) then break end
    end
    return out
end
-- a group's own past, for the AI (newest first, within worldPastDays)
function BR.pastLine(b, h)
    if type(b) ~= "table" or type(b.past) ~= "table" then return nil end
    h = h or hours()
    for i = #b.past, 1, -1 do
        local p = b.past[i]
        if h - (tonumber(p.h) or -1e9) <= BR.num("worldPastDays") * 24 then return p.t end
    end
    return nil
end

local function install()
    -- bases falling, takeovers: the world's own big moments
    K.wrap(M, "nbFall", "BrainHistoryFall", function(orig) return function(b, h, ...)
        local active = type(b) == "table" and b.status == "active"
        local r1, r2 = orig(b, h, ...)
        if active and type(b) == "table" and b.status ~= "active" and not b.isCamp then
            pcall(BR.worldAdd, { k = "fall", text = tostring(b.name or "A group") .. " is gone - nobody left at their place", x = b.x, y = b.y, ids = { b.id } })
        end
        return r1, r2
    end end)
    K.wrap(M, "nbAbsorb", "BrainHistoryAbsorb", function(orig) return function(w, l, h, ...)
        local ok, moved = orig(w, l, h, ...)
        if ok and type(w) == "table" and type(l) == "table" and not BR._worldQuiet and l.outpostOf ~= w.id then
            pcall(BR.worldAdd, { k = "merge", text = tostring(l.name or "A group") .. " are part of " .. tostring(w.name or "another group") .. " now", x = w.x, y = w.y, ids = { w.id, l.id } })
        end
        return ok, moved
    end end)
    -- the AI's picture: their own past
    K.wrap(BR, "why", "BrainHistoryWhy", function(orig) return function(b, h, ...)
        local w = orig(b, h, ...)
        local p = BR.pastLine(b, h)
        if w and p then w = w .. "; not long ago: " .. p end
        return w
    end end)
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
do
    local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrainHistory")
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": world chronicle " .. (BR.flag("worldChronicle") and "on" or "off") .. ", "
                .. #BR.worldStore().list .. " lines, radio " .. (BR.flag("worldRadio") and "on" or "off") .. ", hearsay " .. (BR.flag("worldHearsay") and "on" or "off"))
        end)
    end
end
