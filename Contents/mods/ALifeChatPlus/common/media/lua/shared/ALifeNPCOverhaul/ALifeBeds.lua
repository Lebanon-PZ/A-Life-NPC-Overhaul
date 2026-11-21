-- A-Life NPC Overhaul pre-1.0: OWN BED (docs/PLAN-RIM.md #7). Everyone at your camp can have a bed of their own.
--   * Camp > Beds on a bed: assign it to someone, or free it. ownBedAuto: in the evening, anyone without one takes the
--     free bed nearest the middle of the base (beds found the way the activity layer finds them: by sprite).
--   * Going to sleep (ALifeLLMTalk_Activity's sleep, M.findBedNear) uses their own bed; nobody lies down in a bed that's
--     someone else's.
--   * Camp mood: no bed of their own = worse (ownBedNone); more than ownBedCrowd owners in one room = a bit worse;
--     a room to themselves = a bit better. Words only: they grumble about sleeping on the floor.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBeds") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeBeds = ALifeBeds or {}
local D = ALifeBeds
local TAG = "[ALifeBeds]"
D.VERSION = ALifeSide.MOD_VERSION
D.DEFAULTS = {
    ownBeds = true,      -- people have beds of their own
    ownBedAuto = true,   -- people without one take a free bed in the evening
    ownBedHour = 20,     -- hour they pick
    ownBedNone = 2,      -- how much no bed of their own drags them down (camp mood)
    ownBedCrowd = 3,     -- more owners than this in one room = a bit worse
    ownBedScan = 3600,   -- most squares looked at for beds (base rectangle)
}
K.reg(D.DEFAULTS, {
    { "ownBeds", "Camp: people have beds of their own (no bed = worse mood)" },
    { "ownBedAuto", "Own bed: people without one take a free bed in the evening" },
    { "ownBedNone", "Own bed: how much no bed drags them down", { 0, 1, 2, 3, 5 } },
    { "ownBedCrowd", "Own bed: more owners than this in one room is crowded", { 2, 3, 4, 6 } },
}, "Your camp and base")
D.stats = { claimed = 0, used = 0, avoided = 0 }
local function set(k) return K.set(D.DEFAULTS, k) end
local function num(k) return K.num(D.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function D.on() return set("ownBeds") ~= false end
function D.store()
    local s = K.bucket("rimBeds")
    s.bedOf = type(s.bedOf) == "table" and s.bedOf or {}   -- uid -> { x, y, z, room }
    return s
end
local function key(p) return math.floor(p.x) .. ":" .. math.floor(p.y) .. ":" .. math.floor(p.z or 0) end
local function sqAt(x, y, z) local s = nil; pcall(function() s = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) end); return s end
function D.isBed(sq)
    if sq == nil then return false end
    local yes = false
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local name = tostring(objs:get(i):getSprite():getName() or "")
            if string.find(name, "bedding", 1, true) or string.find(string.lower(name), "_bed", 1, true) then yes = true; break end
        end
    end)
    return yes
end
function D.roomOf(x, y, z)
    local r = nil
    pcall(function()
        local def = sqAt(x, y, z):getRoom():getRoomDef()
        r = tostring(def:getX()) .. ":" .. tostring(def:getY()) .. ":" .. tostring(z or 0)
    end)
    return r
end
-- whose bed is this square (a bed is two squares: within one tile counts)
function D.ownerAt(x, y, z)
    for uid, b in pairs(D.store().bedOf) do
        if type(b) == "table" and math.floor(b.z or 0) == math.floor(z or 0) and math.abs(b.x - x) <= 1 and math.abs(b.y - y) <= 1 then return uid end
    end
    return nil
end
function D.bedOf(uid) local b = D.store().bedOf[tostring(uid)]; return type(b) == "table" and b or nil end
function D.assign(uid, x, y, z)
    uid = tostring(uid)
    local s = D.store()
    local other = D.ownerAt(x, y, z)
    if other and other ~= uid then s.bedOf[other] = nil end
    s.bedOf[uid] = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), room = D.roomOf(x, y, z) }
    D.stats.claimed = D.stats.claimed + 1
    return true
end
function D.free(uid) D.store().bedOf[tostring(uid)] = nil end

-- every bed square inside the base (one per bed: the second half is skipped)
function D.bedsIn(b)
    local out = {}
    if b == nil or tonumber(b.x1) == nil then return out end
    local n = 0
    for x = b.x1, b.x2 do
        for y = b.y1, b.y2 do
            n = n + 1
            if n > num("ownBedScan") then return out end
            local sq = sqAt(x, y, b.z or 0)
            if D.isBed(sq) then
                local dup = false
                for _, o in ipairs(out) do if math.abs(o.x - x) <= 1 and math.abs(o.y - y) <= 1 then dup = true; break end end
                if not dup then out[#out + 1] = { x = x, y = y, z = b.z or 0 } end
            end
        end
    end
    return out
end
function D.autoClaim(player)
    local b = K.base(player)
    if b == nil then return 0 end
    local beds = D.bedsIn(b)
    local n = 0
    for _, uid in ipairs(K.people(player)) do
        if D.bedOf(uid) == nil then
            local best, bd = nil, nil
            for _, p in ipairs(beds) do
                if D.ownerAt(p.x, p.y, p.z) == nil then
                    local dd = K.d2(p.x, p.y, b.x, b.y)
                    if bd == nil or dd < bd then best, bd = p, dd end
                end
            end
            if best == nil then break end
            D.assign(uid, best.x, best.y, best.z)
            n = n + 1
        end
    end
    return n
end
function D.hourly(player, h)
    if not D.on() or player == nil then return 0 end
    if set("ownBedAuto") ~= false and K.hourOfDay() == num("ownBedHour") then return D.autoClaim(player) end
    return 0
end
-- camp mood
function D.mood(uid)
    if not D.on() then return 0 end
    local mine = D.bedOf(uid)
    if mine == nil then return num("ownBedNone") end
    if mine.room == nil then return 0 end
    local n = 0
    for _, b in pairs(D.store().bedOf) do if type(b) == "table" and b.room == mine.room then n = n + 1 end end
    if n > num("ownBedCrowd") then return 1 end
    if n == 1 then return -1 end
    return 0
end
-- sleeping: their own bed; never someone else's
function D.hook()
    local M = K.M()
    if M == nil then return 0 end
    return K.wrap(M, "findBedNear", "beds:findBedNear", function(orig)
        return function(l, ...)
            if not D.on() or type(l) ~= "table" or type(l.record) ~= "table" then return orig(l, ...) end
            local uid = tostring(l.record.uid)
            local mine = D.bedOf(uid)
            local x, y = K.pos(l.shell)
            if mine and x and K.d2(mine.x, mine.y, x, y) <= 40 * 40 then D.stats.used = D.stats.used + 1; return { x = mine.x, y = mine.y, z = mine.z } end
            local found = orig(l, ...)
            if type(found) == "table" then
                local who = D.ownerAt(found.x, found.y, found.z)
                if who ~= nil and who ~= uid then D.stats.avoided = D.stats.avoided + 1; return nil end
            end
            return found
        end
    end) and 1 or 0
end
-- menu: Camp > Beds (on a bed)
function D.menu(child, off, player, x, y, z, inRange, why)
    if not D.on() then return end
    local sq = sqAt(x, y, z)
    local isBed = D.isBed(sq)
    local people = K.people(player)
    local m = child("Beds")
    if isBed then
        local owner = D.ownerAt(x, y, z)
        local am = ISContextMenu:getNew(m)
        m:addSubMenu(m:addOption(owner and ("This is " .. K.first(owner) .. "'s bed. Give it to...") or "Give this bed to..."), am)
        for _, uid in ipairs(people) do
            local o = am:addOption(K.first(uid), nil, function() K.run("bedGive", player, uid, x, y, z) end)
            if owner == uid then off(o, "Already theirs.") end
        end
        if owner then m:addOption("Free this bed", nil, function() K.run("bedFree", player, owner) end) end
    else
        local o = m:addOption("(right-click a bed to give it to someone)")
        off(o, "Right-click a bed square.")
    end
    local mo = m:addOption("Everyone without a bed: pick one now", nil, function() K.run("bedAuto", player) end)
    if #people == 0 then off(mo, "Nobody lives at your base (or they're all out).") end
end
-- pre-1.0 MP (P4): this menu's writes (SP directly; MP on the server as the sender, values checked)
K.act("bedGive", function(player, uid, x, y, z)
    x, y, z = K.cnum(x), K.cnum(y), K.cnum(z) or 0
    if uid == nil or x == nil or y == nil or not D.isBed(sqAt(x, y, z)) then return false end
    uid = tostring(uid)
    D.assign(uid, x, y, z)
    K.say(uid, ({ "A bed of my own? Thanks.", "Finally. A real bed.", "This one's mine? Good." })[(K.hash(uid) % 3) + 1])
end)
K.act("bedFree", function(player, owner) if owner == nil then return false end; D.free(tostring(owner)) end)
K.act("bedAuto", function(player)
    local n = D.autoClaim(player)
    K.letter(n > 0 and (n == 1 and "One of your people picked a bed." or (n .. " of your people picked beds.")) or "No free beds at the base.", 200, 200, 170)
end)
function D.extra(req, player, listener)
    if not D.on() then return nil end
    local uid = listener and listener.record and tostring(listener.record.uid) or nil
    if uid == nil then return nil end
    if D.bedOf(uid) == nil then return "You have no bed of your own here; you sleep wherever you can and it bothers you." end
    return nil
end
function D.install()
    local n = D.hook()
    if not D._mood then K.addMood(function(uid) return D.mood(uid) end); D._mood = true end
    if not D._menu then K.addMenu(function(...) return D.menu(...) end); D._menu = true end
    if not D._extra then K.addExtra(D.extra); D._extra = true end
    if not D._hourly then K.hourly(TAG, D.hourly); D._hourly = true end
    return n
end
pcall(D.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(D.install)
        log("ready v" .. D.VERSION .. ": own beds " .. (D.on() and "on" or "off") .. " (" .. tostring(ok and n or 0) .. "/1 sleep hook)")
    end)
end
return D
