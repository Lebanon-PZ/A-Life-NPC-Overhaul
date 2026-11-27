-- A-Life NPC Overhaul pre-1.0: TRADE, PART 6. GREED (docs/PLAN-TRADE.md T10, Joe: "it is the apocalypse after all").
-- Groups used to stop once they had "enough": a day's foraging only below 2 days of food a head, the week's stockpiling
-- done at 10 days, scavenging in A-Life's own planner only once supplies ran low. Now they keep piling up:
--  * our base goals: forage / stockpile until well past comfortable (settings greedForageDays, greedStockBelow,
--    greedStockDays, greedSelfDays; Directive reads them).
--  * A-Life's activity planner: activities that bring in supplies (scavenging, foraging, hunting, fishing, water)
--    always carry a pull (greedDrive), not just when a need is urgent.
--  * trade: a group trades away what it has plenty of for anything it isn't well off in (not only what it's out of).
-- Everything still comes out of the real world: more scavenging = more derelict buildings, more walking, more risk.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_TradeGreed")
require "ALifeLLMTalk/ALifeTalk_TradePrice"
require "ALifeLLMTalk/ALifeTalk_Caravans"
local M = ALifeLLMTalk
local T = ALifeTrade
if type(M) ~= "table" or type(T) ~= "table" then return end
local fn = T.fn

T.defaults({ greed = true, greedForageDays = 6, greedStockBelow = 20, greedStockDays = 30, greedSelfDays = 30, greedDrive = 3,
    greedTradeSpare = 150, greedTradeWant = 100 })
T.addRows({
    { "greed", "Greed: NPC groups never think they have enough; they keep scavenging, foraging and trading to pile up more" },
    { "greedStockDays", "Greed: days of food a head before a group calls its stockpiling done", { 10, 30, 60 } },
    { "greedForageDays", "Greed: groups go foraging whenever they have less than this many days of food a head", { 2, 6, 12 } },
    { "greedDrive", "Greed: how hard A-Life's groups are pulled to go out for supplies when they're not short", { 1, 3, 6 } },
})
T.greedStats = { biased = 0 }

-- trade: spare = well over enough; lacks = anything under "well off"
M.cvSpareKind = function(b, counts, kind)
    if not T.on("greed") then return (counts[kind] or 0) >= 12 end
    return (counts[kind] or 0) >= 6 and T.ratio(b, kind) * 100 >= T.num("greedTradeSpare")
end
M.cvLacksKind = function(b, counts, kind)
    if not T.on("greed") then return (counts[kind] or 0) < 3 end
    return T.ratio(b, kind) * 100 < T.num("greedTradeWant")
end

-- A-Life's planner: a standing pull toward supply runs (read from ProjectALife/Activities/ALifeActivityPlanner.lua:
-- Planner.score(id, ctx) -> number or nil; Catalog.activities[id].serves = { food = .., water = .., ammo = .., meds = .. })
function T.greedBias(id, ctx)
    local Cat = T.PA().ActivityCatalog
    local row = type(Cat) == "table" and type(Cat.activities) == "table" and Cat.activities[id] or nil
    if type(row) ~= "table" or type(row.serves) ~= "table" then return 0 end
    local sum = 0
    for _, v in pairs(row.serves) do sum = sum + (tonumber(v) or 0) end
    if sum <= 0 then return 0 end
    if type(ctx) == "table" and ctx.night == true then return 0 end
    return T.num("greedDrive") * math.min(1, sum / 1.5)
end
function T.installGreed()
    local P = T.PA().ActivityPlanner
    if type(P) ~= "table" or type(P.score) ~= "function" or P._alcpGreed then return type(P) == "table" and P._alcpGreed == true end
    P._alcpGreed = true
    local score = P.score
    P.score = function(id, ctx, ...)
        local v = score(id, ctx, ...)
        if v == nil or not T.on("greed") then return v end
        local ok, add = pcall(T.greedBias, id, ctx)
        if ok and tonumber(add) and add > 0 then T.greedStats.biased = T.greedStats.biased + 1; return v + add end
        return v
    end
    return true
end
pcall(T.installGreed)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local ok = pcall(T.installGreed)
        print(T.TAG .. " ready v" .. T.VERSION .. ": greed " .. (T.on("greed") and "on" or "off") .. ", A-Life planner " .. ((T.PA().ActivityPlanner or {})._alcpGreed and "pulled" or "NOT found"))
    end)
end
