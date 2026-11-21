-- A-Life NPC Overhaul 0.6.18: CARAVANS WITHOUT JEEM.
-- Without a Jeem base (Jeem not installed, or you don't have one) caravans still come: the same real people from a
-- real group, with goods out of their real stash, after the real walk (or drive). They come to your trading post, or
-- to your A-Life base if you have no post. They come in daylight and wait about half a day (longer on market day).
-- Trade face to face: talk to them ("want to trade?") and bargain. The goods are real items in their packs, so
-- whatever you buy is theirs to sell and whatever you pay goes home with them. Rob them and they drop what they
-- carry (and their group hears of it). When they leave they walk off down the road and everything they carry back
-- lands in their stash once they're home. Nothing is ever made from nothing.
-- Performance: one pass a second while a caravan is at your place (2-6 people); inventories are checked every 5 s.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_OwnCaravans") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
M.ovCfg = M.ovCfg or { stayH = 10, marketStayH = 16, dayFrom = 6, dayTo = 19, spot = 5, tickMs = 1000, packMs = 5000, holdMs = 60000,
    killedRep = -25, tradedRep = 3 }
M.ovStats = M.ovStats or { came = 0, left = 0, loaded = 0, traded = 0, killed = 0 }
if M.settings and M.settings.ownCaravans == nil then M.settings.ownCaravans = true end

local function log(msg) if M.log then M.log("owncaravans: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hourOfDay() local h = 12; pcall(function() h = getGameTime():getHour() end); return tonumber(h) or 12 end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
-- pre-1.0 MP (P5): traders come to the one shared camp: "you" = the camp's player (Main's M.homePlayer)
local function playerOf()
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function tr(k, en, ...) return ALifeTr and ALifeTr("IGUI_ALCP_" .. k, en, ...) or en end
local function store()
    local st = M.nbStore()
    st.ovVisits = type(st.ovVisits) == "table" and st.ovVisits or {}
    return st
end
local function homeOf(id)
    local st = M.nbStore()
    local b = st.byId and st.byId[id] or nil
    local n = 0
    while type(b) == "table" and b.status ~= "active" and b.movedTo and n < 5 do n = n + 1; b = st.byId[b.movedTo] end
    return type(b) == "table" and b.status == "active" and b or nil
end
local function shellOf(uid) local sh = nil; pcall(function() sh = PA().Talk.shellFor(uid) end); return sh end
local function update(uid, f)
    local reg = PA().ActorRegistry
    local r = reg.read(uid)
    if r == nil then return false end
    local ok, res = pcall(reg.update, r.uid, r.revision, function(e) e.memory = type(e.memory) == "table" and e.memory or {}; f(e) end)
    return ok and res ~= false
end

-- where caravans come when there's no Jeem base: your trading post, else your A-Life base
function M.ovBase(player)
    if M.settings.ownCaravans == false then return nil end
    local post = fn(M, "tpStore") and M.tpStore().post or nil
    if type(post) == "table" and tonumber(post.x) then
        return { id = "own:post", own = true, x = post.x, y = post.y, z = post.z or 0, name = "your trading post" }
    end
    local b = nil
    if fn(M, "alifeBase") then pcall(function() b = M.alifeBase(player or playerOf()) end) end
    if type(b) == "table" and tonumber(b.x) then
        return { id = "own:" .. tostring(b.key or "base"), own = true, x = b.x, y = b.y, z = b.z or 0, name = "your base" }
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- items in a shell
----------------------------------------------------------------------------------------------------------------
local function itemsOf(sh)
    local out = {}
    pcall(function()
        local list = sh:getInventory():getItems()
        for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    end)
    return out
end
local function worn(sh, it)
    local yes = false
    pcall(function() if sh:isEquipped(it) then yes = true end end)
    pcall(function() if sh:isEquippedClothing(it) then yes = true end end)
    pcall(function() if it:isEquipped() then yes = true end end)
    return yes
end
local function idOf(it) local id = nil; pcall(function() id = it:getID() end); return id and tostring(id) or tostring(it) end
local function typeOfItem(it) local t = nil; pcall(function() t = it:getFullType() end); return t end
-- what they carry for the caravan (not their own gear): types
local function packOf(v, uid, sh)
    local orig = v.orig[uid] or {}
    local out = {}
    for _, it in ipairs(itemsOf(sh)) do
        -- weapons are left out: A-Life itself keeps a person's weapons when they unload (counting them here too
        -- would give them a second copy)
        local weapon = false
        pcall(function() weapon = instanceof(it, "HandWeapon") end)
        if not weapon and not orig[idOf(it)] and not worn(sh, it) then local t = typeOfItem(it); if t then out[#out + 1] = t end end
    end
    return out
end
local function unpack(v, uid, sh)
    local orig = {}
    for _, it in ipairs(itemsOf(sh)) do orig[idOf(it)] = true end
    v.orig[uid] = orig
    local n = 0
    pcall(function()
        local inv = sh:getInventory()
        for _, t in ipairs(v.packs[uid] or {}) do if inv:AddItem(t) then n = n + 1 end end
    end)
    v.loaded[uid] = true
    M.ovStats.loaded = M.ovStats.loaded + n
    return n
end
local function takeAll(v, uid, sh)
    local orig = v.orig[uid] or {}
    local out = {}
    pcall(function()
        local inv = sh:getInventory()
        for _, it in ipairs(itemsOf(sh)) do
            if not orig[idOf(it)] and not worn(sh, it) then
                local t = typeOfItem(it)
                if t then out[#out + 1] = t; pcall(function() inv:Remove(it) end) end
            end
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- arriving
----------------------------------------------------------------------------------------------------------------
function M.ovArrive(trip, h)
    local hod = hourOfDay()
    if hod < M.ovCfg.dayFrom or hod >= M.ovCfg.dayTo then return nil, "night" end
    for _, v in pairs(store().ovVisits) do if v.home == trip.home then return nil, "visiting" end end
    local src = fn(M, "cvTripSource") and M.cvTripSource(trip) or nil
    if src == nil then return nil, "busy" end
    local b = src.b
    local x, y, z = tonumber(trip.x), tonumber(trip.y), 0
    if x == nil then return nil, "base_gone" end
    -- they stop a few tiles short, on the side they came from
    local dx, dy = (tonumber(b.x) or x) - x, (tonumber(b.y) or y) - y
    local len = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local cx, cy = x + dx / len * M.ovCfg.spot, y + dy / len * M.ovCfg.spot
    local vid = "ov:" .. tostring(trip.home) .. ":" .. math.floor(h * 10)
    local v = { id = vid, home = trip.home, name = b.name, baseId = trip.baseId, x = x, y = y, z = z, arrivedH = h,
        leaveH = h + (trip.market and M.ovCfg.marketStayH or M.ovCfg.stayH), uids = {}, spots = {}, packs = {}, orig = {}, loaded = {},
        rowsWorth = 0, holdAt = {} }
    local n = #src.who
    for i, r in ipairs(src.who) do
        local uid = tostring(r.uid)
        local a = (i - 1) / math.max(1, n) * 6.283
        local spot = { x = math.floor(cx + math.cos(a) * 1.5), y = math.floor(cy + math.sin(a) * 1.5), z = z }
        if update(uid, function(e)
            e.memory.alcpOwnVisit = vid
            e.worldPosition = { x = spot.x + 0.5, y = spot.y + 0.5, z = spot.z }
        end) then
            v.uids[#v.uids + 1] = uid
            v.spots[uid] = spot
            v.packs[uid] = {}
            if fn(M, "lvCancel") then M.lvCancel(uid) end
        end
    end
    if #v.uids == 0 then return nil, "busy" end
    -- the goods, split between them as they were loaded at home
    for _, row in ipairs(trip.rows or {}) do
        local k = ((tonumber(row.carrier) or 1) - 1) % #v.uids + 1
        local pack = v.packs[v.uids[k]]
        for _ = 1, math.max(0, tonumber(row.count) or 0) do pack[#pack + 1] = row.fullType end
        v.rowsWorth = v.rowsWorth + (tonumber(row.value) or 1) * (tonumber(row.count) or 0)
    end
    store().ovVisits[vid] = v
    M.ovStats.came = M.ovStats.came + 1
    for _, f in ipairs(M.cvArriveHooks or {}) do pcall(f, v, b, h) end -- 0.6.21: they talk (journal, rumours, the road)
    if fn(M, "nbEvent") then pcall(M.nbEvent, b, "Their traders reached " .. tostring(trip.baseName or "your place") .. " to trade face to face", "trade") end
    pcall(ALifeSide.outToast, playerOf(), tr("OwnCaravanHere", "Traders from %1 have come to your place. Talk to them to trade.", tostring(b.name)))
    log(tostring(b.name) .. ": " .. #v.uids .. " traders at " .. math.floor(x) .. "," .. math.floor(y) .. " until hour " .. math.floor(v.leaveH))
    return v
end

----------------------------------------------------------------------------------------------------------------
-- while they're here
----------------------------------------------------------------------------------------------------------------
local function patch() return type(ALifeTalkPatch) == "table" and ALifeTalkPatch or nil end
local function hold(v, uid, t)
    if t - (v.holdAt[uid] or -1e12) < 15000 then return end
    v.holdAt[uid] = t
    local P = patch()
    if P and fn(P, "claim") then pcall(P.claim, uid, "party", { mode = "hold", anchor = v.spots[uid], radius = 2.5, ms = M.ovCfg.holdMs, player = playerOf() }) end
end
local function unhold(uid)
    local P = patch()
    local c = P and P.own and P.own.claims and P.own.claims[uid] or nil
    if c and c.kind == "party" and fn(P, "release") then pcall(P.release, uid, "caravan leaving") end
end

function M.ovLeave(v, h, why)
    local reg = PA().ActorRegistry
    local back, killed = {}, 0
    for _, uid in ipairs(v.uids) do
        local r = reg.read(uid)
        if r == nil or r.lifecycle == "dead" then
            killed = killed + 1
        else
            local sh = r.lifecycle == "active" and shellOf(uid) or nil
            local carried = (sh and v.loaded[uid]) and takeAll(v, uid, sh) or (v.packs[uid] or {})
            for _, t in ipairs(carried) do back[#back + 1] = t end
            v.packs[uid] = {}
            unhold(uid)
            update(uid, function(e) e.memory.alcpOwnVisit = nil end)
            local hb = homeOf(v.home)
            local hv = hb and fn(M, "nbHavenOf") and M.nbHavenOf(hb) or nil
            local dp = hv and type(hv.depot) == "table" and hv.depot or (hb and { x = hb.x, y = hb.y, z = 0 }) or nil
            if dp and fn(M, "lvSend") then
                local th = 6
                pcall(function() th = M.travelH(v.x, v.y, dp.x, dp.y, hb) end)
                pcall(M.lvSend, uid, { tx = dp.x, ty = dp.y, untilH = h + (tonumber(th) or 6), tag = "caravan_home",
                    final = { x = dp.x + (hash(uid) % 3) - 1, y = dp.y + (hash(uid .. "y") % 3) - 1, z = dp.z or 0 } })
            end
        end
    end
    -- what they bring home: the goods they didn't sell and what you paid
    local worth = 0
    for _, t in ipairs(back) do worth = worth + (type(ALifeWorth) == "table" and math.max(0.1, ALifeWorth.of(t)) or 1) end
    local traded = math.abs(worth - v.rowsWorth) > 0.5
    local repD, repWhy = nil, nil
    if killed > 0 then repD, repWhy = M.ovCfg.killedRep, "Their traders were killed at your place"; M.ovStats.killed = M.ovStats.killed + killed
    elseif traded then repD, repWhy = M.ovCfg.tradedRep, "Traded with you face to face"; M.ovStats.traded = M.ovStats.traded + 1 end
    if fn(M, "cvSendBack") then pcall(M.cvSendBack, v.home, back, v.x, v.y, h, traded and "Their traders came home from trading with you" or "Their traders came home", repD, repWhy) end
    store().ovVisits[v.id] = nil
    M.ovStats.left = M.ovStats.left + 1
    log(tostring(v.name) .. " left (" .. tostring(why or "time") .. "): " .. #back .. " items home, killed " .. killed .. (traded and ", traded" or ""))
end

function M.ovStep(v, h, t)
    local reg = PA().ActorRegistry
    local alive = 0
    for _, uid in ipairs(v.uids) do
        local r = reg.read(uid)
        if r and r.lifecycle ~= "dead" then
            alive = alive + 1
            if r.lifecycle == "active" then
                local sh = shellOf(uid)
                if sh then
                    if not v.loaded[uid] then unpack(v, uid, sh)
                    elseif t - (tonumber(v.packAt) or -1e12) >= M.ovCfg.packMs then v.packs[uid] = packOf(v, uid, sh) end
                    hold(v, uid, t)
                end
            elseif v.loaded[uid] then
                v.loaded[uid] = false -- unloaded: their pack (last look) is what they carry
            end
        end
    end
    if t - (tonumber(v.packAt) or -1e12) >= M.ovCfg.packMs then v.packAt = t end
    if alive == 0 then return M.ovLeave(v, h, "all dead") end
    if h >= v.leaveH then return M.ovLeave(v, h, "time") end
end

local lastMs = -1e12
function M.ovTick()
    local t = now()
    if t - lastMs < M.ovCfg.tickMs then return end
    lastMs = t
    local st = store()
    local list = {}
    for _, v in pairs(st.ovVisits) do list[#list + 1] = v end
    if #list == 0 then return end
    local h = hours()
    for _, v in ipairs(list) do M.ovStep(v, h, t) end
end
local broken = false
local function guarded()
    if broken then return end
    local ok, err = pcall(M.ovTick)
    if not ok then broken = true; print("[ALifeOwnCaravans] tick failed, own caravans off for this session: " .. tostring(err)) end
end
if not M._ovHooked then
    M._ovHooked = true
    if type(ALifeHealth) == "table" then ALifeHealth.tickAdd("ALifeTalk_OwnCaravans", guarded)
    elseif type(ALifeTick) == "table" then ALifeTick.add(guarded) end
end
print("[ALifeOwnCaravans] loaded v" .. ALifeSide.MOD_VERSION .. " (caravans without Jeem: face-to-face trade at your post or base)")
