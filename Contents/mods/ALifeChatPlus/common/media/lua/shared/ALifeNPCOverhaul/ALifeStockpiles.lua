-- A-Life NPC Overhaul pre-1.0: STOCKPILE PRIORITY (docs/PLAN-RIM.md #5). Haul & sort already has drop points per
-- category (that's the filter). This adds a priority per drop point: High / Normal / Low (Camp > Drop point priority,
-- on a drop point's container).
--   * Every load goes to the highest priority drop point of its kind with room; among the same priority, the old rule
--     (food that spoils: cold storage first, then the nearest).
--   * Shelving (pileShelve): when a higher one has room and a lower one holds things of that kind, a hauler carries them
--     up. Real trips, real items, the same carrying limits as hauling. Never a loop: only toward higher priority.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeStockpiles") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeStockpiles = ALifeStockpiles or {}
local P = ALifeStockpiles
local TAG = "[ALifeStockpiles]"
P.VERSION = ALifeSide.MOD_VERSION
P.DEFAULTS = {
    pilePrio = true,     -- drop points have a priority (High / Normal / Low)
    pileShelve = true,   -- haulers move things up from low to high priority drop points
}
K.reg(P.DEFAULTS, {
    { "pilePrio", "Haul & sort: drop points have a priority (High / Normal / Low)" },
    { "pileShelve", "Haul & sort: haulers move things up to higher priority drop points" },
}, "Your camp and base")
P.LABEL = { [3] = "High", [2] = "Normal", [1] = "Low" }
P.stats = { picked = 0, shelved = 0 }
local function set(k) return K.set(P.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function P.on() return set("pilePrio") ~= false end
local function H() local M = K.M(); return M and M.cpH or nil end
function P.prioOf(p) local v = type(p) == "table" and tonumber(p.prio) or nil; if v == nil or v < 1 or v > 3 then return 2 end; return v end
local function containerAt(p)
    local h = H()
    if h == nil then return nil end
    local sq = h.sqAt(p.x, p.y, p.z)
    return sq and h.containerOn(sq) or nil
end

-- the drop point for this load: highest priority with room; then cold first (food that spoils); then nearest
function P.bestDrop(cat, x, y, w)
    local M = K.M()
    local h = H()
    if M == nil or h == nil then return nil end
    local list = M.cpData().drops[cat] or {}
    local best, bk = nil, nil
    for _, p in ipairs(list) do
        local c = containerAt(p)
        if c and h.hasRoom(c, w) then
            local cold = (cat == "fresh" and h.isCold(c)) and 1 or 0
            local dd = h.d2(p.x, p.y, x or p.x, y or p.y)
            -- bigger wins: priority, then cold, then closer
            local key = P.prioOf(p) * 1e12 + cold * 1e11 - math.min(dd, 1e10)
            if bk == nil or key > bk then best, bk = p, key end
        end
    end
    return best
end
-- what a container holds of one category (up to n), items list
local function itemsOf(c, cat, n)
    local M = K.M()
    local out = {}
    pcall(function()
        local items = c:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if #out < n and M.cpCatOf(it) == cat then out[#out + 1] = it end
        end
    end)
    return out
end
-- a shelving move: { cat, from = lower drop with things, to = higher drop with room } or nil
function P.findMove()
    local M = K.M()
    local h = H()
    if M == nil or h == nil then return nil end
    for cat, list in pairs(M.cpData().drops or {}) do
        if type(list) == "table" and #list >= 2 then
            local hi, hip = nil, 0
            for _, p in ipairs(list) do
                local c = containerAt(p)
                if c and h.hasRoom(c, 0.5) and P.prioOf(p) > hip then hi, hip = p, P.prioOf(p) end
            end
            if hi then
                for _, p in ipairs(list) do
                    if P.prioOf(p) < hip then
                        local c = containerAt(p)
                        if c and #itemsOf(c, cat, 1) > 0 then return { cat = cat, from = p, to = hi } end
                    end
                end
            end
        end
    end
    return nil
end
P.JOB = {
    kind = "rim_shelve", order = 7, -- after meals (5) and the armory (6), before the evening fire (8); hauling is after these
    pick = function(uid, shell, player, b, now)
        if not P.on() or set("pileShelve") == false then return nil end
        local M = K.M()
        local d = M.cpData()
        if not d.haulOn then return nil end
        if K.roleOf(uid) == "guard" then return nil end
        for _, j in pairs(M.cpJobs or {}) do if j.kind == "rim_shelve" then return nil end end -- one shelver at a time
        local mv = P.findMove()
        if mv == nil then return nil end
        local key = "shelve:" .. mv.cat
        if M.cpClaims[key] ~= nil and M.cpClaims[key] ~= uid then return nil end
        M.cpClaims[key] = uid
        return { key = key, cat = mv.cat, from = mv.from, to = mv.to, step = "take", items = {}, anim = "search_mid" }
    end,
    spot = function(j) return j.step == "take" and j.from or j.to end,
    ms = function(j) return 2500 end,
    run = function(j, uid, shell, player)
        local M = K.M()
        local h = H()
        if j.step == "take" then
            local c = containerAt(j.from)
            local inv = h.invOf(shell)
            if c == nil or inv == nil then return "fail" end
            local cfg = M.cpCfg
            local w = 0
            for _, it in ipairs(itemsOf(c, j.cat, cfg.haulMaxItems)) do
                local iw = 0
                pcall(function() iw = it:getActualWeight() end)
                if w + iw <= cfg.haulMaxWeight and pcall(function() c:DoRemoveItem(it); inv:AddItem(it) end) then
                    w = w + iw
                    j.items[#j.items + 1] = it
                end
            end
            if #j.items == 0 then return "done" end
            j.step = "put"
            return "next"
        end
        local res = h.putDown(j, shell, uid)
        if res == "done" then P.stats.shelved = P.stats.shelved + 1 end
        return res
    end,
}

function P.menu(child, off, player, x, y, z, inRange, why)
    if not P.on() then return end
    local M = K.M()
    local cat, i = M.cpDropAt(x, y, z)
    if cat == nil then return end
    local p = M.cpData().drops[cat][i]
    local m = child("Drop point priority (" .. P.LABEL[P.prioOf(p)] .. ")")
    for _, v in ipairs({ 3, 2, 1 }) do
        local o = m:addOption(P.LABEL[v], nil, function() K.run("pilePrio", player, x, y, z, v) end)
        if P.prioOf(p) == v then off(o, "Already this.") end
    end
end
-- pre-1.0 MP (P4): this menu's write (SP directly; MP on the server as the sender, values checked)
K.act("pilePrio", function(player, x, y, z, v)
    local M = K.M()
    v = tonumber(v)
    if M == nil or v == nil or P.LABEL[v] == nil then return false end
    local cat, i = M.cpDropAt(K.cnum(x), K.cnum(y), K.cnum(z) or 0)
    if cat == nil then return false end
    M.cpData().drops[cat][i].prio = v
    M.cpScan = nil
    K.letter("Drop point priority: " .. string.lower(P.LABEL[v]) .. ". " .. (v == 3 and "Things go here first." or (v == 1 and "Things go here last." or "")), 200, 200, 170)
end)
function P.hook()
    local M = K.M()
    if M == nil then return 0 end
    return K.wrap(M, "cpBestDrop", "piles:cpBestDrop", function(orig)
        return function(cat, x, y, w, ...)
            if not P.on() then return orig(cat, x, y, w, ...) end
            P.stats.picked = P.stats.picked + 1
            return P.bestDrop(cat, x, y, w)
        end
    end) and 1 or 0
end
function P.install()
    local n = P.hook()
    K.addJob(P.JOB)
    if not P._menu then K.addMenu(function(...) return P.menu(...) end); P._menu = true end
    return n
end
pcall(P.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(P.install)
        log("ready v" .. P.VERSION .. ": drop point priority " .. (P.on() and "on" or "off") .. ", shelving " .. (set("pileShelve") ~= false and "on" or "off") .. " (" .. tostring(ok and n or 0) .. "/1 camp hook)")
    end)
end
return P
