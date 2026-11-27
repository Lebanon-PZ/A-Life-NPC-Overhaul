-- A-Life NPC Overhaul pre-1.0: TRADE, PART 1. SHARED TRADE STATE + PRICES FROM SCARCITY (docs/PLAN-TRADE.md T4).
--  * ALifeTrade: the one trade namespace (settings, store, helpers) the other Trade files build on.
--  * what a thing is worth to a group now follows how short they really are of it, for every kind of goods
--    (food in days a head, the rest in items a head), not only food / meds / ammo. It replaces ALifeWorth.need, so
--    everything that already asks (Jeem's trade window wants, the runs between groups, haggling) follows it.
--  * no numbers to the player: cue words ("they want that badly" ... "they've plenty of those") (rule 6).
-- Settings: tradePrices (on), priceSwing, priceMin, priceMax, and how much a head counts as "enough" of each kind.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_TradePrice")
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeTrade = ALifeTrade or {}
local T = ALifeTrade
T.VERSION = ALifeSide.MOD_VERSION
T.TAG = "[ALifeTrade]"
T.DEFAULTS = T.DEFAULTS or {}
-- each Trade file adds its defaults here; keys go into fileKeys at LOAD (CLAUDE.md rule 2)
function T.defaults(t)
    for k, v in pairs(t) do T.DEFAULTS[k] = v end
    if type(M.settings) ~= "table" then return end
    M.fileKeys = M.fileKeys or {}
    local have = {}
    for _, x in ipairs(M.fileKeys) do have[x] = true end
    for k, v in pairs(t) do
        if M.settings[k] == nil then M.settings[k] = v end
        if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
function T.setting(k)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[k] end
    if v == nil then v = T.DEFAULTS[k] end
    return v
end
function T.num(k) return tonumber(T.setting(k)) or tonumber(T.DEFAULTS[k]) or 0 end
function T.on(k) return T.setting(k) ~= false end
-- settings window rows (added at OnGameStart, when the client's list exists)
T.rows = T.rows or {}
function T.addRows(list) for _, r in ipairs(list) do T.rows[#T.rows + 1] = r end end
function T.installRows()
    if type(M.settingRows) ~= "table" then return end
    local have = {}
    for _, r in ipairs(M.settingRows) do have[r[1]] = true end
    for _, r in ipairs(T.rows) do
        if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r; have[r[1]] = true end
        if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
    end
end
function T.fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
function T.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
function T.d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
function T.hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
function T.roll(key) if type(ALifeRoll01) == "function" then return ALifeRoll01(key) end return (T.hash(key) % 10000) / 10000 end
function T.log(msg) if M.log then M.log("trade: " .. tostring(msg)) else print(T.TAG .. " " .. tostring(msg)) end end
function T.PA() return type(ProjectALife) == "table" and ProjectALife or {} end
function T.event(b, text, kind) if T.fn(M, "nbEvent") and type(b) == "table" then pcall(M.nbEvent, b, text, kind or "trade") end end
function T.base(id)
    if id == nil or not T.fn(M, "nbStore") then return nil end
    local st = M.nbStore()
    local b, n = st.byId and st.byId[id] or nil, 0
    while type(b) == "table" and b.status ~= "active" and b.movedTo and n < 5 do n = n + 1; b = st.byId[b.movedTo] end
    return type(b) == "table" and b.status == "active" and b or nil
end
-- shared state (in the world's saved data, server side in MP)
function T.store()
    local st = T.fn(M, "nbStore") and M.nbStore() or (T.mem or {})
    T.mem = st
    st.trade = type(st.trade) == "table" and st.trade or {}
    local t = st.trade
    for _, k in ipairs({ "runs", "deals", "routes", "embargo", "offers", "rumors", "own" }) do t[k] = type(t[k]) == "table" and t[k] or {} end
    t.seq = tonumber(t.seq) or 0
    return t
end
function T.newId(prefix) local t = T.store(); t.seq = t.seq + 1; return tostring(prefix) .. tostring(t.seq) end
-- a letter on the right (bad = red); player nil = the camp's player
function T.letter(player, text, bad)
    player = player or (T.fn(M, "homePlayer") and M.homePlayer()) or nil
    if type(ALifeSide.outLetter) == "function" then pcall(ALifeSide.outLetter, player, text, nil, nil, nil, bad == true); return end
    if type(ALifeSide.outToast) == "function" then pcall(ALifeSide.outToast, player, text) end
end
T.KINDS = { "food", "water", "meds", "ammo", "tools", "materials", "fuel" }
T.KIND_WORDS = { food = "food", water = "water", meds = "medicine", ammo = "ammo", tools = "tools", materials = "building materials", fuel = "fuel", other = "odds and ends" }

----------------------------------------------------------------------------------------------------------------
-- T4: scarcity
----------------------------------------------------------------------------------------------------------------
T.defaults({ tradePrices = true, priceSwing = 100, priceMin = 60, priceMax = 200,
    enoughFoodDays = 5, enoughMeds = 3, enoughAmmo = 4, enoughTools = 2, enoughMaterials = 10, enoughWater = 4, enoughFuel = 1 })
T.addRows({
    { "tradePrices", "Trade: what a thing is worth to a group follows how short they are of it (all goods)" },
    { "priceSwing", "Trade: how hard shortage and plenty move worth (percent)", { 50, 100, 150 } },
    { "priceMin", "Trade: least a group pays for something it has plenty of (percent of worth)", { 40, 60, 80 } },
    { "priceMax", "Trade: most a group pays for something it badly lacks (percent of worth)", { 150, 200, 300 } },
    { "enoughFoodDays", "Trade: days of food a head a group counts as enough", { 3, 5, 10 } },
})
local ENOUGH = { meds = "enoughMeds", ammo = "enoughAmmo", tools = "enoughTools", materials = "enoughMaterials", water = "enoughWater", fuel = "enoughFuel" }
-- how much of a kind they have against what's enough: 0 = none, 1 = enough, 2+ = plenty
function T.ratio(b, kind)
    if type(b) ~= "table" then return 1 end
    local n = math.max(1, tonumber(b.crewN) or 1)
    if kind == "food" then
        return ((tonumber(b.food) or 0) / n) / math.max(0.5, T.num("enoughFoodDays"))
    end
    local key = ENOUGH[kind]
    if key == nil then return 1 end
    local g = type(b.goods) == "table" and b.goods or {}
    local have = tonumber(g[kind]) or 0
    if kind == "fuel" then
        if type(b.vehicle) ~= "table" then return 1 end -- no car: fuel is just worth what it's worth
        have = have + (tonumber(b.vehicle.fuel) or 0) / 10
    end
    return have / math.max(0.25, T.num(key) * n)
end
-- what a kind is worth to them against its plain worth (1 = plain)
function T.need(b, kind)
    local r = T.ratio(b, kind)
    local swing = T.num("priceSwing") / 100
    local lo, hi = T.num("priceMin") / 100, T.num("priceMax") / 100
    local v
    if r < 1 then v = 1 + (hi - 1) * (1 - r) * swing
    else v = 1 - (1 - lo) * math.min(1, (r - 1) / 2) * swing end
    return math.max(math.min(lo, hi), math.min(math.max(lo, hi), v))
end
-- cue words, never numbers
function T.cue(b, kind)
    local v = T.need(b, kind)
    if v >= 1.6 then return "want that badly"
    elseif v >= 1.15 then return "would be glad of it"
    elseif v > 0.85 then return "would take it"
    end
    return "have plenty of those"
end
function T.moodWord(b, kind)
    local r = T.ratio(b, kind)
    if r < 0.34 then return "short on " .. (T.KIND_WORDS[kind] or kind)
    elseif r >= 2 then return "plenty of " .. (T.KIND_WORDS[kind] or kind) end
    return nil
end
-- the sharpest shortages of a group, worst first: { { kind, need } }
function T.shortages(b, n)
    local out = {}
    for _, k in ipairs(T.KINDS) do
        local v = T.need(b, k)
        if v >= 1.15 then out[#out + 1] = { kind = k, need = v } end
    end
    table.sort(out, function(a, c) if a.need ~= c.need then return a.need > c.need end return a.kind < c.kind end)
    while n and #out > n do table.remove(out) end
    return out
end
function T.plenty(b)
    local out = {}
    for _, k in ipairs(T.KINDS) do if T.ratio(b, k) >= 2 then out[#out + 1] = k end end
    return out
end

-- ALifeWorth.need now asks us (the old one stays for tradePrices off)
function T.installPrice()
    if type(ALifeWorth) ~= "table" or type(ALifeWorth.need) ~= "function" or ALifeWorth._tradeNeed then return type(ALifeWorth) == "table" and ALifeWorth._tradeNeed == true end
    local old = ALifeWorth.need
    ALifeWorth._tradeNeed = true
    T.oldNeed = old
    ALifeWorth.need = function(b, kind, ...)
        if not T.on("tradePrices") or type(b) ~= "table" then return old(b, kind, ...) end
        local ok, v = pcall(T.need, b, kind)
        if ok and tonumber(v) then return v end
        return old(b, kind, ...)
    end
    return true
end
pcall(require, "ALifeNPCOverhaul/ALifeWorth") -- loads after this folder otherwise (guarded: the game start retry covers it)
pcall(T.installPrice)
-- rows are UI (every side with a window): the real Events, not this file's world-only proxy
local UIEv = rawget(_G, "Events")
if type(UIEv) == "table" and UIEv.OnGameStart then UIEv.OnGameStart.Add(function() pcall(T.installRows) end) end
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(T.installPrice)
        print(T.TAG .. " ready v" .. T.VERSION .. ": prices from scarcity " .. (T.on("tradePrices") and "on" or "off"))
    end)
end
