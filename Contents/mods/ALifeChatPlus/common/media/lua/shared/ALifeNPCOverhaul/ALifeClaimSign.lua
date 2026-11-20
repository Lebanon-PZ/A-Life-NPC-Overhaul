-- A-Life NPC Overhaul pre-1.0: CLAIM SIGNS. A group's ground is where its signs stand (docs/SIGNS.md).
--   * Claimed ground = every square within claimSignRadius of a standing claim sign. No sign, no claim (the old
--     "45 tiles around the house" box is only used with claimSigns off).
--   * Signs are made, never spawned: 1 Iron Band + 3 Planks + 1 Long Stick + 6 Nails, and a hammer, out of the
--     group's real stockpile / unseen ledger (ALifeTalk_Build: bdHave / bdSpend). Short of parts = on the want list.
--   * Four kinds by how the group treats people: hostile, neutral, friendly, slaver (dark content). The painted art
--     follows the kind; a group that changes its ways repaints. Floating words = the group's own sign text.
--   * Planted at the edge of the house (road side first), never inside another sign's ground, never in front of you
--     (Build's playerSafeTiles). Unseen: the sign is up (claim counts) and the tile goes in when you come by.
--   * A sign that's gone (pulled up, smashed) = claim gone. You close by when it went = they blame you (rep, and a
--     leader grudge for hostile / slaver groups). Then they make a new one when they have the parts.
--   * You: craft one (recipe MakeClaimSign) and plant it from the inventory menu. It marks your ground: groups won't
--     claim over it.
-- Side: "legacy", like Bases / Build / Dynamics it reads (0.9 world logic runs client-side in MP until P2b).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeClaimSign")
require "ALifeNPCOverhaul/ALifeNotes"

ALifeClaimSign = ALifeClaimSign or {}
local CS = ALifeClaimSign
local TAG = "[ALifeClaimSign]"
CS.VERSION = "pre-1.0"
CS.STORE = "ALifeNPCOverhaul.ClaimSigns"
CS.ITEM = "ALifeChatPlus.ClaimSign"
CS.DEFAULTS = { claimSigns = true, claimSignRadius = 45, claimSignsPerBase = 1, claimSignPad = 3, claimSignBlame = 30,
    claimSignGrudge = 10 }
-- what a group spends on one sign (keys of ALifeTalk_Build's bdItems); the player's recipe is in ALifeChatPlus_sign.txt
CS.PARTS = { ironband = 1, plank = 3, longstick = 1, nails = 6 }
CS.PART_ITEMS = { ironband = "Base.IronBand", longstick = "Base.LongStick" }
CS.PART_WORDS = { ironband = "an iron band (for a sign)", longstick = "a long stick (for a sign)" }
CS.KINDS = { hostile = true, neutral = true, friendly = true, slaver = true }
CS.metrics = CS.metrics or { made = 0, placed = 0, gone = 0, blamed = 0, repainted = 0, planted = 0, short = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function M() return type(ALifeLLMTalk) == "table" and ALifeLLMTalk or nil end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end

-- settings: keys in M.fileKeys at LOAD time (CLAUDE.md rule 2)
do
    local m = M()
    if m and type(m.settings) == "table" then
        m.fileKeys = m.fileKeys or {}
        local have = {}
        for _, x in ipairs(m.fileKeys) do have[x] = true end
        for k, v in pairs(CS.DEFAULTS) do
            if m.settings[k] == nil then m.settings[k] = v end
            if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end
        end
    end
end
function CS.setting(k)
    local m = M()
    local v = nil
    if m and type(m.settings) == "table" then v = m.settings[k] end
    if v == nil then v = CS.DEFAULTS[k] end
    return v
end
function CS.num(k) return tonumber(CS.setting(k)) or CS.DEFAULTS[k] end
function CS.on() return CS.setting("claimSigns") ~= false end

function CS.store()
    local s = nil
    if type(ModData) == "table" and fn(ModData, "getOrCreate") then s = ModData.getOrCreate(CS.STORE) end
    s = type(s) == "table" and s or (CS._mem or {})
    CS._mem = s
    s.seq = tonumber(s.seq) or 0
    s.signs = type(s.signs) == "table" and s.signs or {}
    return s
end

----------------------------------------------------------------------------------------------------------------
-- kind: how the group treats people overall
----------------------------------------------------------------------------------------------------------------
function CS.kindOf(b)
    if type(b) ~= "table" then return "neutral" end
    if b.trade == "slavers" then return "slaver" end
    local creed = type(b.dir) == "table" and b.dir.creed or nil
    if creed == "raiders" or creed == "closed" or b.trade == "warband" then return "hostile" end
    if creed == "open" or creed == "faithful" then return "friendly" end
    return "neutral"
end

----------------------------------------------------------------------------------------------------------------
-- who owns (x, y)
----------------------------------------------------------------------------------------------------------------
local function baseOf(rec)
    local m = M()
    if rec.owner ~= "base" or m == nil or not fn(m, "nbOf") then return nil end
    local b = m.nbOf(rec.baseId)
    if b == nil or (b.status ~= nil and b.status ~= "active") then return nil end
    return b
end
-- the sign whose ground (x, y) is on: the nearest one in range that still has a living owner
function CS.signAt(x, y, skipId)
    if x == nil or y == nil then return nil end
    local r2 = CS.num("claimSignRadius") ^ 2
    local best, bestD = nil, nil
    for id, rec in pairs(CS.store().signs) do
        if id ~= skipId and type(rec) == "table" and tonumber(rec.x) then
            local d = d2(rec.x, rec.y, x, y)
            if d <= r2 and (bestD == nil or d < bestD) and (rec.owner == "player" or baseOf(rec) ~= nil) then best, bestD = rec, d end
        end
    end
    return best
end
function CS.baseAt(x, y)
    local rec = CS.signAt(x, y)
    if rec == nil then return nil end
    return baseOf(rec)
end
function CS.playerAt(x, y)
    local rec = CS.signAt(x, y)
    return rec ~= nil and rec.owner == "player" and rec or nil
end
function CS.signsOf(baseId)
    local out = {}
    for _, rec in pairs(CS.store().signs) do
        if type(rec) == "table" and rec.owner == "base" and rec.baseId == baseId then out[#out + 1] = rec end
    end
    table.sort(out, function(a, b) return (tonumber(a.n) or 0) < (tonumber(b.n) or 0) end)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- the world side: find / put / take the sign object
----------------------------------------------------------------------------------------------------------------
local function squareAt(x, y, z)
    local sq = nil
    pcall(function() sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(tonumber(z) or 0)) end)
    return sq
end
local function eachOf(coll, f)
    if coll == nil then return end
    pcall(function() for i = 0, coll:size() - 1 do if f(coll:get(i)) then return end end end)
end
-- the object (tile) or world item carrying ALifeClaim == id on its square; nil, "unloaded" when the square isn't loaded
function CS.find(rec)
    local sq = squareAt(rec.x, rec.y, rec.z)
    if sq == nil then return nil, "unloaded" end
    local found, kind = nil, nil
    eachOf(sq:getObjects(), function(o)
        local has = false
        pcall(function() has = o:hasModData() end)
        if has then
            local md = nil
            pcall(function() md = o:getModData() end)
            if type(md) == "table" and md.ALifeClaim == rec.id then found, kind = o, "tile"; return true end
        end
        return false
    end)
    if found == nil then
        eachOf(sq:getWorldObjects(), function(wo)
            local md = nil
            pcall(function() md = wo:getItem():getModData() end)
            if type(md) == "table" and md.ALifeClaim == rec.id then found, kind = wo, "item"; return true end
            return false
        end)
    end
    return found, kind, sq
end
function CS.removeObj(obj, kind, sq)
    if obj == nil or sq == nil then return false end
    if kind == "item" then
        return pcall(function() sq:transmitRemoveItemFromSquare(obj) end) or pcall(function() sq:removeWorldObject(obj) end)
    end
    return pcall(function() sq:transmitRemoveItemFromSquare(obj) end)
end
-- put the sign object down for a record (words first: the group's own, AI if running)
function CS.put(rec, sq)
    local N = ALifeNotes
    if N == nil or sq == nil then return false end
    local function deliver(text)
        if rec.placed then return end
        rec.text = text
        local ok = N.putSign(sq, text, rec.facing or "S", rec.kind, { ALifeClaim = rec.id })
        if ok then rec.placed = true; rec.placedH = hours(); CS.metrics.placed = CS.metrics.placed + 1 end
    end
    if type(rec.text) == "string" and rec.text ~= "" then deliver(rec.text); return rec.placed == true end
    if fn(N, "write") then N.write("sign", { group = rec.name or "OUR", tone = rec.kind }, deliver) end
    return rec.placed == true
end

----------------------------------------------------------------------------------------------------------------
-- where a group plants its sign: just outside the house, road side first
----------------------------------------------------------------------------------------------------------------
function CS.spots(b)
    local bb = type(b) == "table" and type(b.bounds) == "table" and b.bounds or nil
    local pad = CS.num("claimSignPad")
    if bb == nil then
        if not tonumber(b and b.x) then return {} end
        bb = { x1 = b.x, x2 = b.x, y1 = b.y, y2 = b.y }
    end
    -- words face out, away from the house (back of the board toward home)
    local cx, cy = math.floor((bb.x1 + bb.x2) / 2), math.floor((bb.y1 + bb.y2) / 2)
    local south = { x = cx, y = bb.y2 + pad, facing = "S" }
    local north = { x = cx, y = bb.y1 - pad, facing = "N" }
    local east = { x = bb.x2 + pad, y = cy, facing = "E" }
    local west = { x = bb.x1 - pad, y = cy, facing = "W" }
    if b.roadSide == "N" then return { north, east, west, south } end
    return { south, east, west, north }
end

----------------------------------------------------------------------------------------------------------------
-- making one: real parts from the group's stockpile / ledger (ALifeTalk_Build)
----------------------------------------------------------------------------------------------------------------
function CS.installParts()
    local m = M()
    if m == nil or type(m.bdItems) ~= "table" then return false end
    for k, full in pairs(CS.PART_ITEMS) do if m.bdItems[k] == nil then m.bdItems[k] = full end end
    if type(m.bdWantWords) == "table" then for k, w in pairs(CS.PART_WORDS) do if m.bdWantWords[k] == nil then m.bdWantWords[k] = w end end end
    return true
end
-- missing parts (key -> n), and whether there's a hammer to drive the nails
function CS.short(b, c)
    local m = M()
    local short, any = {}, false
    if m == nil or not fn(m, "bdHave") then return { all = 1 }, true end
    for k, n in pairs(CS.PARTS) do
        local have = m.bdHave(b, k, c)
        if have < n then short[k] = n - have; any = true end
    end
    local hammer = false
    if fn(m, "bdHasTool") and c ~= nil then hammer = m.bdHasTool("hammer", nil, c) end
    if not hammer and fn(m, "bdRec") then hammer = m.bdRec(b).tools.hammer ~= false end
    if not hammer then short.hammer = 1; any = true end
    return short, any
end
function CS.make(b, c)
    local m = M()
    if m == nil or not fn(m, "bdSpend") then return false end
    for k, n in pairs(CS.PARTS) do if m.bdHave(b, k, c) < n then return false end end
    for k, n in pairs(CS.PARTS) do if not m.bdSpend(b, k, n, c) then log("spend failed for " .. k .. " at " .. tostring(b.name)); return false end end
    CS.metrics.made = CS.metrics.made + 1
    return true
end
function CS.newRec(t)
    local s = CS.store()
    s.seq = s.seq + 1
    t.id = "cs" .. tostring(s.seq)
    t.h = hours()
    t.placed = false
    s.signs[t.id] = t
    return t
end

----------------------------------------------------------------------------------------------------------------
-- a sign went missing
----------------------------------------------------------------------------------------------------------------
function CS.blameCost(b)
    local creed = type(b.dir) == "table" and b.dir.creed or "wary"
    return ({ closed = 8, raiders = 7, wary = 4, open = 2, traders = 3, faithful = 2 })[creed] or 4
end
function CS.gone(rec, player)
    CS.store().signs[rec.id] = nil
    CS.metrics.gone = CS.metrics.gone + 1
    local b = baseOf(rec)
    if b == nil then return "dropped" end
    local px, py = nil, nil
    if player then pcall(function() px, py = player:getX(), player:getY() end) end
    if px == nil or d2(px, py, rec.x, rec.y) > CS.num("claimSignBlame") ^ 2 then
        log(tostring(b.name) .. " lost their sign (no one saw who)")
        return "gone"
    end
    CS.metrics.blamed = CS.metrics.blamed + 1
    local m = M()
    if m and fn(m, "nbRep") then pcall(m.nbRep, b, -CS.blameCost(b), "Their claim sign was torn down - they think it was the newcomer") end
    local kind = CS.kindOf(b)
    if (kind == "hostile" or kind == "slaver") and b.leader and m and fn(m, "addGrudge") then
        pcall(m.addGrudge, b.leader, CS.num("claimSignGrudge"), "tore down our sign", player)
    end
    log(tostring(b.name) .. " lost their sign - blamed on you")
    return "blamed"
end

----------------------------------------------------------------------------------------------------------------
-- the hourly pass
----------------------------------------------------------------------------------------------------------------
local function farFromYou(x, y, px, py)
    local m = M()
    local safe = (m and type(m.bdCfg) == "table" and tonumber(m.bdCfg.playerSafeTiles)) or 25
    return px == nil or d2(x, y, px, py) > safe * safe
end
-- one sign record: settle the world against it. Returns what happened (for tests).
function CS.check(rec, player, px, py)
    local b = baseOf(rec)
    if rec.owner == "base" and b == nil then CS.store().signs[rec.id] = nil; return "lapsed" end -- group gone: the claim lapses, the board stays
    local obj, kind, sq = CS.find(rec)
    if kind == "unloaded" then return "unloaded" end
    if rec.placed then
        if obj == nil then return CS.gone(rec, player) end
        if b and rec.kind ~= CS.kindOf(b) and farFromYou(rec.x, rec.y, px, py) then
            CS.removeObj(obj, kind, sq)
            rec.kind, rec.text, rec.placed = CS.kindOf(b), nil, false
            CS.metrics.repainted = CS.metrics.repainted + 1
            CS.put(rec, sq)
            return "repainted"
        end
        return "standing"
    end
    if farFromYou(rec.x, rec.y, px, py) then
        local spot = sq
        if fn(ALifeNotes, "outdoorSquare") then spot = ALifeNotes.outdoorSquare(rec.x, rec.y, rec.z) or sq end
        pcall(function() rec.x, rec.y = spot:getX(), spot:getY() end)
        if CS.put(rec, spot) then return "placed" end
    end
    return "waiting"
end
-- one group: keep its signs up
function CS.baseStep(b, player, px, py)
    if type(b) ~= "table" or b.id == nil then return nil end
    local mine = CS.signsOf(b.id)
    if #mine >= CS.num("claimSignsPerBase") then b.csShort = nil; return "enough" end
    -- a free spot: not on anyone else's ground
    local pick = nil
    for _, sp in ipairs(CS.spots(b)) do
        local taken = false
        for _, r in ipairs(mine) do if d2(r.x, r.y, sp.x, sp.y) < 4 then taken = true end end
        local other = CS.signAt(sp.x, sp.y)
        if not taken and (other == nil or (other.owner == "base" and other.baseId == b.id)) then pick = sp; break end
    end
    if pick == nil then return "nospot" end
    local m = M()
    local c = (m and fn(m, "bdContainer")) and m.bdContainer(b) or nil
    local short, any = CS.short(b, c)
    if any then b.csShort = short; CS.metrics.short = CS.metrics.short + 1; return "short" end
    if not CS.make(b, c) then return "short" end
    b.csShort = nil
    local rec = CS.newRec({ owner = "base", baseId = b.id, name = b.name, kind = CS.kindOf(b), x = pick.x, y = pick.y, z = 0,
        facing = pick.facing, n = #mine + 1 })
    log(tostring(b.name) .. " made a " .. rec.kind .. " claim sign")
    CS.check(rec, player, px, py)
    return "made"
end
function CS.tick(player)
    if not CS.on() then return end
    CS.installParts()
    player = player or (fn(ALifeSide, "campPlayer") and ALifeSide.campPlayer()) or nil -- pre-1.0 MP: the camp's player
    local px, py = nil, nil
    if player then pcall(function() px, py = player:getX(), player:getY() end) end
    local list = {}
    for _, rec in pairs(CS.store().signs) do if type(rec) == "table" then list[#list + 1] = rec end end
    local function near(x, y) -- pre-1.0 MP: whoever is nearest that spot is "you" for it
        if not ALifeSide.mpServer() or tonumber(x) == nil then return player, px, py end
        local p = ALifeSide.nearest(tonumber(x), tonumber(y))
        local qx, qy = nil, nil
        if p then pcall(function() qx, qy = p:getX(), p:getY() end) end
        return p, qx, qy
    end
    for _, rec in ipairs(list) do local p2, x2, y2 = near(rec.x, rec.y); pcall(CS.check, rec, p2, x2, y2) end
    local m = M()
    if m and fn(m, "nbActive") and fn(m, "bdOn") and m.bdOn() then
        for _, b in ipairs(m.nbActive()) do local p2, x2, y2 = near(b.x, b.y); pcall(CS.baseStep, b, p2, x2, y2) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the want list: missing sign parts join what the group talks about being short of
----------------------------------------------------------------------------------------------------------------
function CS.hookWants()
    local m = M()
    if m == nil or not fn(m, "bdUpdateWants") or m._csWants == m.bdUpdateWants then return false end
    local orig = m.bdUpdateWants
    m.bdUpdateWants = function(b, shortList, toolMissing)
        orig(b, shortList, toolMissing)
        if not CS.on() or type(b) ~= "table" or type(b.csShort) ~= "table" then return end
        local r = m.bdRec(b)
        local have = {}
        for _, k in ipairs(r.want) do have[k] = true end
        for _, k in ipairs({ "ironband", "longstick", "plank", "nails", "hammer" }) do
            if b.csShort[k] and not have[k] then r.want[#r.want + 1] = k; have[k] = true end
        end
    end
    m._csWants = m.bdUpdateWants
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the player plants one (client menu calls this; legacy side, same machine)
----------------------------------------------------------------------------------------------------------------
function CS.kindsFor(player)
    local out = { "hostile", "neutral", "friendly" }
    local m = M()
    if m and type(m.settings) == "table" and m.settings.darkContent == true then out[#out + 1] = "slaver" end
    return out
end
-- args { kind, x, y, z }. Returns ok, why
function CS.plant(player, args)
    if not CS.on() then return nil, "off" end
    if player == nil or type(args) ~= "table" or not CS.KINDS[args.kind] then return nil, "args" end
    local allowed = false
    for _, k in ipairs(CS.kindsFor(player)) do if k == args.kind then allowed = true end end
    if not allowed then return nil, "kind" end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z) or 0
    if x == nil or y == nil then return nil, "args" end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    if px == nil or d2(x, y, px, py) > 9 then return nil, "far" end
    local other = CS.signAt(x, y)
    if other and other.owner ~= "player" then return nil, "claimed", other.name end
    local sq = squareAt(x, y, z)
    if sq == nil then return nil, "square" end
    local free = false
    pcall(function() free = sq:isFree(false) end)
    if not free then return nil, "blocked" end
    local inv, item = nil, nil
    pcall(function() inv = player:getInventory(); item = inv:getFirstTypeRecurse(CS.ITEM) end)
    if item == nil then return nil, "noitem" end
    if not pcall(function() item:getContainer():DoRemoveItem(item) end) then return nil, "noitem" end
    local who = nil
    pcall(function() who = player:getUsername() end)
    -- you stand behind it: the words face out, away from you
    local facing = (fn(ALifeNotes, "signFacingAway") and ALifeNotes.signFacingAway(sq, px, py)) or "S"
    local rec = CS.newRec({ owner = "player", playerKey = who and tostring(who) or "player", name = "OUR", kind = args.kind,
        x = math.floor(x), y = math.floor(y), z = math.floor(z), facing = facing })
    rec.text = nil
    CS.put(rec, sq)
    CS.metrics.planted = CS.metrics.planted + 1
    return true, rec.id
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
function CS.install()
    CS.installParts()
    CS.hookWants()
    local m = M()
    if m and type(m.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(m.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "claimSigns", "Claim signs: a group's ground is a radius around signs it makes from real parts (off = the old box around the house)" },
            { "claimSignRadius", "Claim signs: tiles of ground around each sign", { 25, 45, 70, 100 } },
            { "claimSignsPerBase", "Claim signs: signs each group keeps up", { 1, 2 } },
            { "claimSignBlame", "Claim signs: you get the blame for a missing sign within this many tiles", { 15, 30, 60 } },
        }) do
            if not have[r[1]] then m.settingRows[#m.settingRows + 1] = r end
            if type(m.settingCatOf) == "table" then m.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. CS.VERSION .. ": claim signs (" .. (CS.on() and "on" or "off") .. ", radius " .. tostring(CS.num("claimSignRadius"))
        .. ", build parts " .. ((m and type(m.bdItems) == "table") and "found" or "not found") .. ")")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(CS.install) end) end
    if Events.EveryHours then Events.EveryHours.Add(function() local ok, e = pcall(CS.tick); if not ok and not CS._err then CS._err = true; log("tick error (logged once): " .. tostring(e)) end end) end
end
return CS
