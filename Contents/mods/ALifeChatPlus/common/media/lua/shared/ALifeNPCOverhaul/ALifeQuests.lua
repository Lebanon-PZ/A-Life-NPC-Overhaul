-- A-Life NPC Overhaul 0.8.6: PEOPLE WANT THINGS. A-Life 1.5's own task board, made honest and grown.
-- A-Life's board (30 tasks, ask an NPC "got work?") stays: its talk rows, journal card, tracker arrow, paths and save.
-- What this changes (each part a setting; every hook wraps the original and switches itself off if it errors):
--   * PAY IS REAL: the reward comes out of the giver's own pack, by worth (ALifeWorth), never from a pool. They keep
--     their last food, water, medicine, ammo and weapon, and nothing they wear, hold or have strapped on. Nothing to
--     spare: they say so, like you a bit more, and owe you one (kept in the save for 0.8.7 favours).
--   * NOTHING FROM NOTHING: no items appear in your pack when you reach a place (A-Life's "arrive at the pharmacy, get
--     antibiotics"): you search the place for the real thing. No zombies spawned for a task: clear steps count the
--     real dead. Anything they hand you to carry (matches, a walkie) comes from their pack, or they can't send you.
--   * MADE-UP TASKS OFF: tasks whose premise isn't there (a crate on the road that doesn't exist, a "missing" Marta who
--     was never anyone, a contact at a marker nobody stands at, a traveller who never walks with you) are not offered.
--     Clearing houses off by default too.
--   * NEW, REAL TASKS: people ask for real things they lack (smokes, a drink, coffee, something to read, glasses, soap
--     and a razor, games, an instrument for the fire, a feast); find someone of theirs who's far away, dead or held,
--     and tell them the truth; carry word to a real person of a friendly group. Rarity by tier (settings).
--   * PART 2: company (a settler's run, or a quiet walk: they really walk with you, A-Life's walk-with); bring someone
--     you hold home (A-Life captives: you free them, they walk home with you); found someone with another group ->
--     their people ask you to bring them back (a group quest; they come only if they like you enough); faction jobs
--     against groups the giver is hostile to: settle a score (a real person dies), hit their stash (a real A-Life haven
--     depot loses worth; anyone of theirs nearby saw it), drive them out (their haven is abandoned while you're there).
--     Group jobs pay from the group's own stash (haven depot) when it's loaded. Not real yet, so not built: a captive
--     swap between two groups (A-Life has no NPC-held captives), the person you bring back rejoining their old group
--     in A-Life's records (they walk home; their group membership is A-Life's).
-- Server side (the board runs where A-Life's does); the task, text and row data load on both sides.
-- Engine/A-Life calls used here were read in A-Life 1.5.1 (42.20 folder): TaskBoard.world (W.give/W.spawn/W.event/
-- W.record/W.bump/W.pos), Board.reward/fail, Rows.handlers, Hook.providers, Rules.stepTick/eligible/build/siteFor,
-- ActorRegistry.each, MissionService.shellOf, Relations.status, Captives.heldUid; item moves as A-Life's own trade
-- (FollowBTrade.move: Remove + AddItem + send*ItemFromContainer in MP).
require "ALifeNPCOverhaul/AA_Side"
require "ProjectALife/Missions/ALifeTaskBoardData"
require "ProjectALife/Missions/ALifeTaskBoardRules"
require "ProjectALife/Missions/ALifeTaskBoardText"
require "ProjectALife/Missions/ALifeTaskBoardRows"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeQuests = ALifeQuests or {}
local K = ALifeQuests
local TAG = "[ALifeQuests]"
K.VERSION = ALifeSide.MOD_VERSION -- pre-1.0: real stores
K.metrics = K.metrics or { paid = 0, paidItems = 0, owed = 0, spawnRefused = 0, giveRefused = 0, carried = 0, noCarry = 0,
    fakeHidden = 0, rare = 0, found = 0, met = 0, hints = 0 }

K.DEFAULTS = {
    questsReal = true,        -- master switch for everything below
    questRealPay = true,      -- pay comes out of the giver's own pack
    questPayScale = 1,        -- x how much worth they try to pay
    questNoSpawns = true,     -- no zombies spawned for a task
    questNoGifts = true,      -- no items appear when you reach a place
    questRealPlaces = true,   -- pre-1.0: "go to the store" is a real store (none in reach = no task, never a spot in the woods)
    questFakeOff = true,      -- tasks with a made-up premise are not offered
    questClearHouse = false,  -- A-Life's "clear a house" task
    questWants = true,        -- people ask for real things they lack
    questFindPerson = true,   -- find someone of theirs and tell them the truth
    questDeliver = true,      -- carry word to a real person of a friendly group
    questDeliverMax = 1500,   -- tiles: furthest a word is sent
    questMissingFar = 250,    -- tiles: a groupmate this far away counts as "gone"
    questOddsUncommon = 50,   -- % a giver brings up an uncommon task on a given day
    questOddsRare = 25,       -- % rare
    questOddsVeryRare = 10,   -- % very rare
    questCompany = true,      -- settlers want company on a run, or a quiet walk
    questHandBack = true,     -- their people ask for someone you hold, back
    questChains = true,       -- someone of theirs you found with another group: try to bring them home
    questPersuadeTrust = 25,  -- how much they must like you to come home with you
    questMap = true,          -- your active task's place is marked on the world map (when you open it)
    questFactionJobs = true,  -- groups ask you to hurt groups they hate (a hit, a stash, drive them out)
    questWitnessCost = 8,     -- how much a group likes you less when they saw you rob or attack them
    questStory = true,        -- 0.8.7: their own goal (family, revenge, making it right, getting clean) as tasks
    questCleanDays = 7,       -- 0.8.7: days dry after you held their bottles before they count as off the drink
    storyWarn = true,         -- 0.8.8: you can warn the person someone wants dead ("watch your back")
    storyWarnReach = 6,       -- 0.8.8: tiles: how close you must be to the one you warn
    storyWarnLeak = 30,       -- 0.8.8: % the one who wanted revenge finds out it was you (sure if their people saw)
    storyWarnCost = 12,       -- 0.8.8: how much less they like you when they find out
    storyWarnThanks = 6,      -- 0.8.8: how much more the warned person likes you
    storyTemptCost = 8,       -- 0.8.8: how much less a drinker likes you once sober, after you handed them a drink
    storyLeadDays = 2,        -- 0.9.1: days into a story before a lead turns up (where their person really is)
    storyLeadGap = 3,         -- 0.9.1: days between leads
    storyStallDays = 30,      -- 0.9.1: a story nobody moved this many days ends itself (they let it go, or turn bitter)
    questFirstWave = true,    -- 0.9.1: prodigal, survivor's guilt, second chance, medicine run, winter coming
    questHurtBelow = 60,      -- 0.9.1: medicine run: someone of theirs below this % health
    questHurtReach = 40,      -- 0.9.1: medicine run: that someone is this close to the giver (tiles)
}
K.FILE_KEYS = {}
for k in pairs(K.DEFAULTS) do K.FILE_KEYS[#K.FILE_KEYS + 1] = k end
table.sort(K.FILE_KEYS)

-- A-Life tasks whose premise is made up (nobody / nothing real behind them)
K.FAKE = { recover_crate = true, deliver_message = true, burn_pile = true, medical_aid = true, get_back_stolen = true,
    trade_run = true, find_missing = true, hunt_pack = true, meet_contact = true, restore_power = true,
    silence_alarm = true, check_neighbor = true, rescue_trapped = true, escort_walk = true }

-- display categories they keep at least this many of (their last food, medicine, ammo, weapon)
K.KEEP = { Food = 2, Water = 1, FirstAid = 1, Medical = 1, Ammo = 1, Weapon = 1 }
K.NEVER = { Key = true, Clothing = true, Container = true, Bag = true }
-- what a reward class prefers to pay in
K.PREFER = { food = { Food = true, Water = true }, medical = { FirstAid = true, Medical = true }, ammo = { Ammo = true },
    build = { Material = true, Materials = true, Tool = true, Tools = true }, tools = { Tool = true, Tools = true, Electronics = true } }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(s) return (hash(s) % 10000) / 10000 end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
K.call = call

function K.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
function K.on(key)
    if K.setting("questsReal") == false then return false end
    if key == nil then return true end
    return K.setting(key) ~= false
end

function K.hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return num(h, 0)
end

-- the save: what people owe you, what you told them
function K.store()
    local d = nil
    if type(ModData) == "table" and type(ModData.getOrCreate) == "function" then
        pcall(function() d = ModData.getOrCreate("ALifeQuests") end)
    end
    if type(d) ~= "table" then K.tmp = K.tmp or {}; d = K.tmp end
    d.owed = type(d.owed) == "table" and d.owed or {}
    d.fates = type(d.fates) == "table" and d.fates or {}
    return d
end

-- ---------------------------------------------------------------------------------------------------- items
function K.itemExists(full)
    K.exists = K.exists or {}
    local c = K.exists[full]
    if c ~= nil then return c end
    local ok, it = pcall(function() return getScriptManager():FindItem(full) end)
    c = ok and it ~= nil
    K.exists[full] = c
    return c
end

-- a def's fetch items all exist in this game (a missing ID drops the whole task, once, logged)
function K.itemsOk(def)
    if def.alcpItemsOk ~= nil then return def.alcpItemsOk end
    local ok = true
    for _, path in pairs(def.paths or {}) do
        for _, entry in ipairs(path.turn or {}) do
            local any = false
            for _, t in ipairs(entry.t or {}) do if K.itemExists(t) then any = true end end
            if not any then ok = false end
        end
    end
    def.alcpItemsOk = ok
    if not ok then log("task '" .. tostring(def.id) .. "' off: an item it needs is not in this game") end
    return ok
end

function K.valueOf(item)
    local v = 0
    if type(ALifeWorth) == "table" and fn(ALifeWorth, "item") then
        local ok, w = pcall(ALifeWorth.item, item)
        if ok then v = num(w, 0) end
    else
        local T = PA() and PA().FollowBTrade or nil
        if fn(T, "valueOf") then local ok, w = pcall(T.valueOf, item); if ok then v = num(w, 0) end end
    end
    return v
end

local function sendMove(kind, container, item)
    if not ALifeSide.server() then return end
    local f = kind == "remove" and sendRemoveItemFromContainer or sendAddItemToContainer
    if type(f) == "function" then pcall(f, container, item) end
end

-- the same move A-Life's own trade makes (FollowBTrade.move); puts it back if the other side won't take it
function K.move(item, from, to)
    if item == nil or from == nil or to == nil then return false end
    if type(from.Remove) ~= "function" or type(to.AddItem) ~= "function" then return false end
    if not pcall(from.Remove, from, item) then return false end
    sendMove("remove", from, item)
    local ok, got = pcall(to.AddItem, to, item)
    if ok and got ~= nil then sendMove("add", to, item); return true end
    pcall(from.AddItem, from, item)
    sendMove("add", from, item)
    return false
end

local function itemsOf(inv)
    local out = {}
    local items = call(inv, "getItems")
    local n = num(call(items, "size"), 0)
    if n > 256 then n = 256 end
    for i = 0, n - 1 do
        local it = call(items, "get", i)
        if it ~= nil then out[#out + 1] = it end
    end
    return out
end

local function spareable(item)
    if call(item, "isEquipped") == true or call(item, "isFavorite") == true then return false end
    local slot = call(item, "getAttachedSlot")
    if slot ~= nil and num(slot, -1) > -1 then return false end
    local cat = tostring(call(item, "getDisplayCategory") or "")
    if K.NEVER[cat] then return false end
    return true
end

-- what they can spare, by worth, keeping their last of what keeps them alive
function K.spare(inv)
    local list, counts = {}, {}
    for _, it in ipairs(itemsOf(inv)) do
        local cat = tostring(call(it, "getDisplayCategory") or "")
        counts[cat] = (counts[cat] or 0) + 1
        if spareable(it) then
            local v = K.valueOf(it)
            if v > 0 then list[#list + 1] = { item = it, v = v, cat = cat, full = tostring(call(it, "getFullType") or "?") } end
        end
    end
    local out, left = {}, {}
    for cat, n in pairs(counts) do left[cat] = n - (K.KEEP[cat] or 0) end
    for _, e in ipairs(list) do
        if (left[e.cat] or 0) > 0 then out[#out + 1] = e end
    end
    return out, left
end

function K.payTarget(def, style)
    local path = type(def.paths) == "table" and def.paths[style] or nil
    local mult = path ~= nil and num(path.mult, 1) or 1
    return (4 + 4 * num(def.repMin, 1)) * mult * num(K.setting("questPayScale"), 1)
end

-- choose and move: preferred kinds first, then the most worth that still fits; at most 3 things
function K.pay(shell, player, def, style, fromInv)
    local inv = fromInv or call(shell, "getInventory")
    local pinv = call(player, "getInventory")
    if inv == nil or pinv == nil then return {}, 0 end
    local target = K.payTarget(def, style)
    local list, left = K.spare(inv)
    local pref = K.PREFER[def.reward] or {}
    table.sort(list, function(a, b)
        local pa, pb = pref[a.cat] == true, pref[b.cat] == true
        if pa ~= pb then return pa end
        if a.v ~= b.v then return a.v > b.v end
        return a.full < b.full
    end)
    local got, sum = {}, 0
    for _, e in ipairs(list) do
        if #got >= 3 or sum >= target then break end
        local room = target - sum
        if e.v <= room * 1.5 + 1 and (left[e.cat] or 0) > 0 then
            if K.move(e.item, inv, pinv) then
                left[e.cat] = left[e.cat] - 1
                sum = sum + e.v
                got[#got + 1] = tostring(call(e.item, "getDisplayName") or e.full)
            end
        end
    end
    return got, sum
end

-- ---------------------------------------------------------------------------------------------------- people
function K.record(uid)
    local pa = PA()
    if uid == nil or pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
function K.shellOf(uid)
    local pa = PA()
    if pa == nil or not fn(pa.MissionService, "shellOf") then return nil end
    local ok, s = pcall(pa.MissionService.shellOf, tostring(uid))
    return ok and s or nil
end
function K.nameOf(r)
    local pa = PA()
    if type(r) ~= "table" then return "someone" end
    if pa ~= nil and fn(pa.Names, "of") then
        local ok, n = pcall(pa.Names.of, r)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return tostring(r.name or r.displayName or "someone")
end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function dead(r) return type(r) ~= "table" or r.lifecycle == "dead" end
local function d(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
local function posOf(r)
    local x, y = tonumber(type(r) == "table" and r.x or nil), tonumber(type(r) == "table" and r.y or nil)
    if x == nil or y == nil then return nil end
    return x, y
end
local function shellPos(uid)
    local s = K.shellOf(uid)
    if s == nil or call(s, "isDead") == true then return nil end
    local x, y = num(call(s, "getX"), nil), num(call(s, "getY"), nil)
    if x == nil or y == nil then return nil end
    return x, y, s
end
local function heldUid(uid)
    local C = PA() and PA().Captives or nil
    if not fn(C, "heldUid") then return false end
    local ok, v = pcall(C.heldUid, uid)
    return ok and v == true
end
local function usable(r, giver)
    local m = mem(r)
    if r.uid == giver.uid then return false end
    if m.companion ~= nil or m.visit ~= nil or m.guest ~= nil then return false end
    return true
end

-- someone of the giver's own group who is gone: far away, dead, or held
K.cache = K.cache or {}
function K.scan(kind, giver, extra)
    local key = kind .. ":" .. tostring(giver.uid) .. ":" .. math.floor(K.hours())
    local c = K.cache[key]
    if c ~= nil then return c ~= false and c or nil end
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "each") then return nil end
    local gx, gy = posOf(giver)
    if gx == nil then return nil end
    local gm = mem(giver)
    local best, bk, seen = nil, -1, 0
    pcall(pa.ActorRegistry.each, function(r)
        seen = seen + 1
        if seen > 3000 then return true end
        if type(r) ~= "table" or not usable(r, giver) then return false end
        local x, y = posOf(r)
        if x == nil then return false end
        local ok = false
        if kind == "missing" then
            local m = mem(r)
            if gm.groupId ~= nil and m.groupId == gm.groupId then
                ok = dead(r) or heldUid(r.uid) or d(gx, gy, x, y) >= num(K.setting("questMissingFar"), 250)
            end
        elseif kind == "enemy" and not dead(r) and not heldUid(r.uid) then
            local dist = d(gx, gy, x, y)
            ok = dist >= 60 and dist <= num(K.setting("questDeliverMax"), 1500) and K.hostile(giver, r)
        elseif kind == "receiver" and not dead(r) and not heldUid(r.uid) then
            local m = mem(r)
            local dist = d(gx, gy, x, y)
            if dist >= 120 and dist <= num(K.setting("questDeliverMax"), 1500) and (gm.groupId == nil or m.groupId ~= gm.groupId) then
                local st = "neutral"
                local R = pa.Relations
                if fn(R, "status") then local ok2, v = pcall(R.status, giver, r); if ok2 and type(v) == "string" then st = v end end
                ok = st == "friendly"
            end
        end
        if ok then
            local h = hash(tostring(giver.uid) .. ":" .. tostring(r.uid) .. ":" .. math.floor(K.hours() / 24))
            if h > bk then best, bk = r, h end
        end
        return false
    end)
    K.cache[key] = best or false
    K.cacheN = (K.cacheN or 0) + 1
    if K.cacheN > 200 then K.cache, K.cacheN = {}, 0 end
    return best
end

-- what happened to them, in plain words
function K.fateOf(r, giver)
    if dead(r) then return "dead", "is dead" end
    if heldUid(r.uid) then return "held", "is alive, but held prisoner" end
    local gm, m = mem(giver), mem(r)
    if gm.groupId ~= nil and m.groupId ~= gm.groupId then return "joined", "is alive, with another group now" end
    if giver.factionId ~= nil and r.factionId ~= giver.factionId then return "joined", "is alive, with another group now" end
    return "alive", "is alive and well"
end

function K.hostile(a, b)
    local R = PA() and PA().Relations or nil
    if not fn(R, "status") then return false end
    local ok, v = pcall(R.status, a, b)
    return ok and v == "hostile"
end

-- an active haven (A-Life Havens) of a group the giver is hostile to; nearest within reach
function K.enemyHaven(giver)
    local key = "haven:" .. tostring(giver.uid) .. ":" .. math.floor(K.hours())
    local c = K.cache[key]
    if c ~= nil then return c ~= false and c or nil end
    local pa = PA()
    local Hv = pa and pa.Havens or nil
    local gx, gy = posOf(giver)
    if gx == nil or not fn(Hv, "store") or not fn(pa.ActorRegistry, "each") then return nil end
    local bad, seen = {}, 0
    pcall(pa.ActorRegistry.each, function(r)
        seen = seen + 1
        if seen > 3000 then return true end
        local g = mem(r).groupId
        if g ~= nil and bad[g] == nil and not dead(r) and r.uid ~= giver.uid then bad[g] = K.hostile(giver, r) end
        return false
    end)
    local best, bd = nil, num(K.setting("questDeliverMax"), 1500)
    local ok, store = pcall(Hv.store)
    for _, h in pairs(ok and type(store) == "table" and type(store.byId) == "table" and store.byId or {}) do
        if type(h) == "table" and h.state == "active" and h.groupId ~= nil and bad[h.groupId] == true and tonumber(h.x) then
            local dist = d(gx, gy, h.x, h.y)
            if dist >= 60 and dist <= bd then best, bd = h, dist end
        end
    end
    K.cache[key] = best or false
    return best
end
function K.haven(id)
    local Hv = PA() and PA().Havens or nil
    if not fn(Hv, "of") then return nil end
    local ok, h = pcall(Hv.of, id)
    return ok and type(h) == "table" and h or nil
end

-- pre-1.0: a "store" / "pharmacy" / "house" step is a real building of that kind. A-Life's lookup (POI.search) reads only
-- the first 400 rooms of a 600x600 box in map order (a town store is often never read), its store list has no Zippee,
-- Gigamart, corner or convenience store, and when it finds nothing it drops the step on a random spot 50-120 tiles out
-- (tester: "take them to the store" = the woods, 90 tiles away). We read every room in reach; still none = no task.
K.PLACE_NAMES = { store = { "conveniencestore", "cornerstore", "zippeestore", "gigamart", "liquorstore", "tobaccostore",
    "departmentstore", "generalstorestorage", "grocerystorage" } }
K.ROOM_SCAN_MAX = 8000
function K.realSite(placeKey, spec, anchor, seed, taken)
    if type(spec) ~= "table" or type(spec.names) ~= "table" or type(anchor) ~= "table" or tonumber(anchor.x) == nil then return nil end
    local want = {}
    for _, n in ipairs(spec.names) do want[string.lower(tostring(n))] = true end
    for _, n in ipairs(K.PLACE_NAMES[placeKey] or {}) do want[n] = true end
    local POI = PA() and PA().POI or nil
    local lo, hi = num(spec.min, 0), num(spec.max, 300)
    local ax, ay = math.floor(anchor.x), math.floor(anchor.y)
    local fits = {}
    pcall(function()
        local rooms = ArrayList.new()
        getWorld():getMetaGrid():getRoomsIntersecting(ax - hi, ay - hi, hi * 2, hi * 2, rooms)
        local count = math.min(rooms:size(), K.ROOM_SCAN_MAX)
        for i = 0, count - 1 do
            local def = rooms:get(i)
            if def ~= nil then
                local name = string.lower(tostring(def:getName() or ""))
                local cat = fn(POI, "categoryOf") and POI.categoryOf(name) or nil
                if (want[name] or (cat ~= nil and want[cat])) and (tonumber(def:getZ()) or 0) == 0 then
                    local x = def:getX() + math.floor((def:getW() or 2) / 2)
                    local y = def:getY() + math.floor((def:getH() or 2) / 2)
                    local dist = d(x, y, ax, ay)
                    local apart = true
                    for _, o in ipairs(taken or {}) do
                        if type(o) == "table" and tonumber(o.x) and d(x, y, o.x, o.y) < 25 then apart = false; break end
                    end
                    if apart and dist >= lo and dist <= hi then fits[#fits + 1] = { x = x, y = y, dist = dist } end
                end
            end
        end
    end)
    if #fits == 0 then return nil end
    table.sort(fits, function(a, b) return a.dist < b.dist end)
    local n = math.min(#fits, 6)
    local row = fits[math.floor(roll(tostring(seed) .. ":alcpPoi") * n) + 1] or fits[1]
    return { x = math.floor(row.x), y = math.floor(row.y), z = 0, word = spec.word }
end

-- the siteFor rule for A-Life places: their site if it is real, else ours, else (same place as the step before) that one
K.lastSite, K.lastSiteKey = nil, nil
function K.placeSite(placeKey, spec, site, anchor, seed, prev, taken)
    if not K.on("questRealPlaces") or type(spec) ~= "table" or type(spec.names) ~= "table" then return site end
    if type(site) == "table" and site.fallback ~= true then return site end
    local real = K.realSite(placeKey, spec, anchor, seed, taken)
    if real ~= nil then K.metrics.realSites = (K.metrics.realSites or 0) + 1; return real end
    if prev ~= nil and prev == K.lastSite and K.lastSiteKey == placeKey then
        return { x = prev.x, y = prev.y, z = prev.z or 0, word = prev.word }
    end
    K.metrics.noSite = (K.metrics.noSite or 0) + 1
    return nil
end

-- a captive the player holds (A-Life Captives) who belongs to the giver's people
function K.captiveFor(giver, player)
    local C = PA() and PA().Captives or nil
    if type(C) ~= "table" or type(C.live) ~= "table" or not fn(C, "keyOf") or player == nil then return nil end
    local okk, key = pcall(C.keyOf, player)
    if not okk or key == nil then return nil end
    local gm = mem(giver)
    for uid, held in pairs(C.live) do
        if type(held) == "table" and held.owner == key and tostring(uid) ~= tostring(giver.uid) then
            local r = K.record(uid)
            if r ~= nil and not dead(r) and ((giver.factionId ~= nil and r.factionId == giver.factionId)
                    or (gm.groupId ~= nil and mem(r).groupId == gm.groupId)) then return r end
        end
    end
    return nil
end

-- someone of theirs you found with another group (find_person -> joined): the group quest that follows
function K.chainFor(giver)
    local s = K.store()
    s.chains = type(s.chains) == "table" and s.chains or {}
    local g = tostring(mem(giver).groupId or giver.uid)
    local c = s.chains[g]
    if type(c) ~= "table" then return nil end
    local r = K.record(c.t)
    if r == nil or dead(r) or (mem(giver).groupId ~= nil and mem(r).groupId == mem(giver).groupId) then s.chains[g] = nil; return nil end
    return r
end

function K.opinion(r, player)
    local op = PA() and PA().NpcOpinion or nil
    if not fn(op, "valueOf") then return 0 end
    local ok, v = pcall(op.valueOf, r, player)
    return ok and num(v, 0) or 0
end

-- walk with you (A-Life's own walk-with, 1 hour, renewed while the job runs)
function K.walk(player, r, stop)
    local T = PA() and PA().Talk or nil
    if not fn(T, "walkWith") or type(r) ~= "table" then return false end
    local ok, done = pcall(T.walkWith, player, { record = r }, stop and "WALK_STOP" or "WALK_WITH_ME")
    return ok and done == true
end

-- people of a group who saw it (their loaded bodies within r tiles)
function K.witnesses(groupId, x, y, r)
    local pa = PA()
    local out = {}
    if groupId == nil or not fn(pa.ActorRegistry, "each") then return out end
    pcall(pa.ActorRegistry.each, function(rec)
        if mem(rec).groupId == groupId and not dead(rec) then
            local sx, sy = shellPos(rec.uid)
            if sx ~= nil and d(sx, sy, x, y) <= r then out[#out + 1] = rec end
        end
        return #out >= 6
    end)
    return out
end

function K.worthIn(container)
    local sum = 0
    for _, it in ipairs(itemsOf(container)) do sum = sum + K.valueOf(it) end
    return sum
end

-- the group's real stash (A-Life haven depot), when it is loaded and a real container
function K.groupStash(record)
    local Hv = PA() and PA().Havens or nil
    if not fn(Hv, "havenOfRecord") or not fn(Hv, "containerAt") then return nil end
    local ok, h = pcall(Hv.havenOfRecord, record)
    if not ok or type(h) ~= "table" or type(h.depot) ~= "table" then return nil end
    local ok2, c = pcall(Hv.containerAt, h.depot)
    if ok2 and c ~= nil and call(c, "getItems") ~= nil then return c end
    return nil
end

function K.homeOf(giver)
    local Hv = PA() and PA().Havens or nil
    if fn(Hv, "homeOf") then
        local ok, h = pcall(Hv.homeOf, giver)
        if ok and type(h) == "table" and tonumber(h.x) then return h.x, h.y end
    end
    return posOf(giver)
end

-- ---------------------------------------------------------------------------------------------------- new tasks
local Data, Rules, Text, Rows = nil, nil, nil, nil
local function item(types, count) if type(types) == "string" then types = { types } end return { t = types, n = count } end
local function reach(place, label) return { k = "reach", place = place, label = label } end
local function fetch(items, label) return { k = "fetch", items = items, label = label } end
local function path(rep, mult, steps, o) o = o or {}; return { rep = rep, mult = mult, steps = steps, carry = o.carry, turn = o.turn } end
local function want(id, o)
    local turn = o.turn
    return { id = id, alcp = { kind = "want", tier = o.tier or "common", lack = o.lack }, report = o.report, title = o.title, glyph = "supply",
        family = "want", giver = o.giver or { "civ", "work", "rescue", "law", "mil", "out" }, repMin = o.repMin or 0, hours = o.hours or 48,
        reward = o.reward or "trade", summary = o.summary, ask = o.ask, impact = o.impact,
        paths = {
            soft = path(1, 1.0, { fetch(turn, o.find) }, { turn = turn }),
            hard = path(2, 1.3, { reach(o.place or "store", "Get to the {place}") }, { turn = turn }),
            own = path(2, 0.7, {}, { turn = turn }),
        } }
end
K.SMOKES = { "Base.CigarettePack", "Base.CigaretteCarton", "Base.Cigar", "Base.Cigarillo", "Base.TobaccoLoose" }
K.DRINK = { "Base.Whiskey", "Base.Wine", "Base.Wine2", "Base.WineAged", "Base.BeerBottle", "Base.BeerCan" }
K.COFFEE = { "Base.Coffee2", "Base.Teabag2", "Base.Chocolate" }
K.READING = { "Base.Book", "Base.ComicBook", "Base.Magazine" }
K.GLASSES = { "Base.Glasses_Reading", "Base.Glasses_Prescription", "Base.Glasses_Normal" }
K.MUSIC = { "Base.Harmonica", "Base.GuitarAcoustic", "Base.Banjo", "Base.Violin", "Base.Flute", "Base.Trumpet", "Base.Saxophone" }
K.GAMES = { "Base.CardDeck", "Base.Dice", "Base.ChessBlack", "Base.Football", "Base.Basketball" }
K.SWEETS = { "Base.Chocolate", "Base.CandyCaramels" }
-- 0.9.1 first wave
K.MEDS = { "Base.Antibiotics", "Base.Pills", "Base.Disinfectant", "Base.AlcoholBandage" }
K.BANDAGES = { "Base.Bandage", "Base.AlcoholBandage" }
K.WARM = { "Base.Jacket_Padded", "Base.Jacket_PaddedDOWN", "Base.Jumper_RoundNeck", "Base.Jumper_PoloNeck", "Base.Hat_WinterHat", "Base.Hat_WoolyHat", "Base.Scarf_White" }
K.WOOD = { "Base.Log", "Base.Firewood" }

K.TASKS = {
    want("want_smokes", { title = "Something to smoke", report = "Here, something to smoke", ask = "You look like you're dying for a smoke",
        impact = "Pays for a pack or a cigar", summary = "Bring them a pack of cigarettes, a cigar or loose tobacco",
        find = "Find a pack of smokes", turn = { item(K.SMOKES, 1) }, lack = K.SMOKES, place = "store", reward = "trade" }),
    want("want_drink", { title = "A real drink", report = "Brought you a drink", ask = "Could you use a real drink?",
        impact = "Pays for a bottle", summary = "Bring them whiskey, wine or beer", find = "Find something to drink",
        turn = { item(K.DRINK, 1) }, lack = K.DRINK, place = "store", giver = { "civ", "work", "law", "mil", "out", "raid" } }),
    want("want_coffee", { title = "Coffee", report = "Got you some coffee", ask = "Missing your coffee?",
        impact = "Pays for coffee, tea or chocolate", summary = "Bring them coffee, tea or a bar of chocolate",
        find = "Find coffee, tea or chocolate", turn = { item(K.COFFEE, 1) }, lack = K.COFFEE, place = "store", reward = "food" }),
    want("want_reading", { title = "Something to read", report = "Brought you something to read", ask = "Bored out of your mind?",
        impact = "Pays for books or magazines", summary = "Bring them two books, comics or magazines",
        find = "Find two things to read", turn = { item(K.READING, 2) }, lack = K.READING, place = "house" }),
    want("want_cleanup", { title = "Soap and a razor", report = "Soap and a razor, as asked", ask = "When did you last get a proper wash?",
        impact = "Pays for soap and a razor", summary = "Bring them a bar of soap and a razor", find = "Find soap and a razor",
        turn = { item("Base.Soap2", 1), item("Base.Razor", 1) }, lack = { "Base.Soap2" }, place = "store" }),
    want("want_glasses", { title = "Reading glasses", report = "Try these glasses", ask = "Can you still see straight?",
        impact = "Pays for a pair of glasses", summary = "Their glasses broke. Bring them a pair that works",
        find = "Find a pair of glasses", turn = { item(K.GLASSES, 1) }, lack = K.GLASSES, place = "pharmacy", tier = "uncommon", repMin = 1 }),
    want("want_games", { title = "Games for the evenings", report = "Something for the long evenings", ask = "What do you do with the long evenings?",
        impact = "Pays for cards, dice or a ball", summary = "Bring the group a deck of cards, dice, chess or a ball",
        find = "Find cards, dice, chess or a ball", turn = { item(K.GAMES, 1) }, lack = K.GAMES, place = "house", tier = "uncommon",
        repMin = 1, giver = { "civ", "work", "rescue", "law", "mil" } }),
    want("want_music", { title = "Music for the fire", report = "Something to play at the fire", ask = "Does anyone here play anything?",
        impact = "Pays well for an instrument", summary = "Bring the group an instrument for the evenings at the fire",
        find = "Find an instrument", turn = { item(K.MUSIC, 1) }, lack = K.MUSIC, place = "house", tier = "rare", repMin = 2,
        giver = { "civ", "work", "rescue", "law", "mil" } }),
    want("want_feast", { title = "Something to celebrate with", report = "For the celebration", ask = "Anything worth celebrating here?",
        impact = "Pays well for drink and sweets", summary = "They want a night off from all of it. Bring two bottles and something sweet",
        find = "Find two bottles and something sweet", turn = { item(K.DRINK, 2), item(K.SWEETS, 2) }, place = "store", tier = "veryrare",
        repMin = 3, giver = { "civ", "work", "rescue", "law", "mil" } }),
    { id = "find_person", alcp = { kind = "seek", tier = "rare" }, report = "I found out what happened", title = "Find someone of theirs",
        glyph = "investigate", family = "find", giver = { "civ", "rescue", "law", "work", "mil", "out" }, repMin = 2, hours = 72,
        reward = "favor", unlock = "search_party", summary = "{name} never came back. Find out what happened to them",
        ask = "Has anyone of yours not come back?", impact = "Pays for the truth about someone they lost",
        paths = { soft = path(2, 1.2, { reach("alcp_last", "Go where {name} was last heard of"), { k = "seek", place = "alcp_target", label = "Find {name}" } }) } },
    -- part 2: company, bring them home, faction jobs, chains
    { id = "escort_scavenge", alcp = { kind = "company", tier = "uncommon" }, report = "We made it back", title = "Watch my back",
        glyph = "escort", family = "escort", giver = { "civ", "work", "rescue" }, repMin = 1, hours = 24, reward = "trade",
        summary = "{name} is going on a run and wants someone at their back", ask = "Going out on a run?",
        impact = "Pays for keeping them alive on a run",
        paths = { soft = path(1, 1.0, { { k = "escort", place = "store", label = "Walk with {name} to the {place}" },
            { k = "guard", place = "store", hours = 0.25, label = "Watch their back while they search" },
            { k = "escort", place = "giver", label = "Bring {name} back" } }) } },
    { id = "escort_scenic", alcp = { kind = "company", tier = "rare" }, report = "Glad we went", title = "A quiet walk",
        glyph = "escort", family = "escort", giver = { "civ", "work", "rescue", "law", "mil" }, repMin = 2, hours = 24, reward = "favor",
        summary = "{name} wants to see somewhere quiet, one more time, and not alone", ask = "You look like you need to get away",
        impact = "No pay to speak of. They won't forget it",
        paths = { soft = path(3, 0.5, { { k = "escort", place = "alcp_view", label = "Walk with {name} to the {place}" },
            { k = "guard", place = "alcp_view", hours = 0.2, label = "Sit a while with {name}" },
            { k = "escort", place = "giver", label = "Walk {name} home" } }) } },
    { id = "hand_back", alcp = { kind = "handback", tier = "common" }, report = "They are home", title = "Bring them home",
        glyph = "escort", family = "rescue", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" }, repMin = 0, hours = 48,
        reward = "favor", summary = "You hold {name}. Their people want them back", ask = "You're holding one of ours",
        impact = "Their people will remember you let them go",
        paths = { soft = path(3, 1.0, { { k = "handback", place = "alcp_home", label = "Bring {name} home to their people" } }) } },
    { id = "bring_back", alcp = { kind = "persuade", tier = "rare", group = true }, report = "They came home", title = "Bring them back",
        glyph = "escort", family = "rescue", giver = { "civ", "work", "rescue", "law", "mil" }, repMin = 2, hours = 72, reward = "favor",
        summary = "{name} is with another group now. Talk them into coming home, if they want to",
        ask = "Is there any way to get them back?", impact = "Pays for bringing someone home who wants to come",
        paths = { soft = path(3, 1.3, { { k = "persuade", place = "alcp_target", label = "Find {name} and ask them to come home" },
            { k = "handback", place = "alcp_home", label = "Walk {name} home" } }) } },
    { id = "hit_member", alcp = { kind = "hit", tier = "veryrare", group = true }, report = "It's done", title = "Settle a score",
        glyph = "defend", family = "hunt", giver = { "out", "raid", "mil", "law" }, repMin = 3, hours = 72, reward = "ammo",
        summary = "{name} of a group they hate has to go", ask = "Someone out there you want gone?",
        impact = "Pays well. Their people will want to know who did it",
        paths = { soft = path(2, 1.4, { { k = "kill", place = "alcp_target", label = "Deal with {name}" } }) } },
    { id = "raid_stash", alcp = { kind = "steal", tier = "rare", group = true }, report = "I hit their stash", title = "Hit their stash",
        glyph = "extract", family = "retrieve", giver = { "out", "raid", "mil" }, repMin = 2, hours = 72, reward = "ammo",
        summary = "Take what you can carry from a rival group's stash", ask = "Anyone you'd like to see go hungry?",
        impact = "Pays for the hit. Keep what you take. Don't get seen",
        paths = { soft = path(2, 1.2, { { k = "steal", place = "alcp_depot", label = "Empty their stash at the {place}" } }) } },
    { id = "burn_out", alcp = { kind = "drive", tier = "veryrare", group = true }, report = "They're gone from there", title = "Drive them out",
        glyph = "defend", family = "sabotage", giver = { "raid", "mil", "law" }, repMin = 3, hours = 72, reward = "ammo",
        summary = "A rival group holds a place nearby. Make them leave it, any way you can", ask = "Who's sitting where they shouldn't?",
        impact = "Pays very well. It changes the map",
        paths = { soft = path(3, 1.5, { { k = "drive", place = "alcp_haven", label = "Drive them out of the {place}" } }) } },
    -- 0.8.7 A STORY FOR EVERYONE: their own goal, about real people and real bottles (goals set by ALifeTalk_Story)
    { id = "story_family", alcp = { kind = "reunite", story = "family", tier = "common" }, report = "You found each other",
        title = "Find their family", glyph = "investigate", family = "find", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 1, hours = 72, reward = "favor", summary = "They want to see {name} again. Take them there",
        ask = "Is there anyone you're trying to get back to?", impact = "Nothing they could pay would cover it",
        paths = { soft = path(4, 1.0, { { k = "reunite", place = "alcp_target", label = "Take them to {name}" } }) } },
    { id = "story_amends", alcp = { kind = "reunite", story = "amends", tier = "common" }, report = "They talked it out",
        title = "Make it right", glyph = "signal", family = "deliver", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 2, hours = 72, reward = "favor", summary = "Something went wrong between them and {name}. They want to make it right, face to face",
        ask = "Anything you'd take back if you could?", impact = "They'll remember who walked them there",
        paths = { soft = path(3, 0.8, { { k = "reunite", place = "alcp_target", label = "Walk with them to {name}" } }) } },
    { id = "story_revenge", alcp = { kind = "hit", story = "revenge", tier = "common" }, report = "It is done",
        title = "Their revenge", glyph = "defend", family = "hunt", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 2, hours = 72, reward = "ammo", summary = "{name} took someone from them. They want them dead",
        ask = "Who did this to you?", impact = "They'll be in your debt for good. Or you could talk them out of it",
        paths = { soft = path(3, 1.3, { { k = "kill", place = "alcp_target", label = "Find {name}" } }) } },
    { id = "story_clean", alcp = { kind = "keep", story = "clean", tier = "common" }, report = "You held on. So did I",
        title = "Keep the bottles away", glyph = "supply", family = "want", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 2, hours = 72, reward = "favor", summary = "They're trying to quit drinking. Hold on to their bottles and don't give one back",
        ask = "You've been drinking a lot", impact = "Hold their bottles two days. Give one back and it's over",
        paths = { soft = path(3, 0.6, { { k = "keep", place = "giver", hours = 48, label = "Hold on to their bottles" } }) } },
    -- 0.9.1 FIRST WAVE: real people, real stuff
    want("want_medicine", { title = "Medicine run", report = "Medicine, as promised", ask = "Is someone of yours hurt?",
        impact = "Pays what they can for medicine", summary = "Someone of theirs is hurt and getting worse. Bring medicine and bandages",
        find = "Find medicine and bandages", turn = { item(K.MEDS, 1), item(K.BANDAGES, 2) }, lack = K.MEDS, place = "pharmacy", reward = "medical",
        tier = "common", hours = 24 }),
    want("want_winter", { title = "Winter's coming", report = "For the cold", ask = "Ready for the cold?",
        impact = "Pays for warm clothes and wood", summary = "Winter's close and they've nothing warm. Bring something warm to wear and wood for the fire",
        find = "Find warm clothes and wood", turn = { item(K.WARM, 1), item(K.WOOD, 3) }, lack = K.WARM, place = "store", reward = "trade",
        tier = "uncommon", hours = 72 }),
    { id = "story_prodigal", alcp = { kind = "persuade", story = "prodigal", tier = "common" }, report = "They came home",
        title = "The prodigal", glyph = "escort", family = "rescue", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 2, hours = 96, reward = "favor", summary = "{name} walked out on them, angry, and went with other people. Find them and ask them home",
        ask = "Anyone you wish would come back?", impact = "If {name} comes home, they won't forget who brought them",
        paths = { soft = path(4, 1.0, { { k = "persuade", place = "alcp_target", label = "Find {name} and ask them to come home" },
            { k = "handback", place = "alcp_home", label = "Walk {name} home" } }) } },
    { id = "story_guilt", alcp = { kind = "company", story = "guilt", tier = "common" }, report = "I said what I needed to",
        title = "Survivor's guilt", glyph = "escort", family = "escort", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 1, hours = 48, reward = "favor", summary = "{name} died and they think it should have been them. Walk with them to where it happened",
        ask = "You keep looking at that road", impact = "No pay. Somebody has to walk with them",
        paths = { soft = path(3, 0.5, { { k = "escort", place = "alcp_target", label = "Walk with them to where {name} died" },
            { k = "guard", place = "alcp_target", hours = 0.2, label = "Stay while they say goodbye" },
            { k = "escort", place = "giver", label = "Walk them home" } }) } },
    { id = "story_second", alcp = { kind = "keep", story = "second", tier = "common" }, report = "Still dry. Thank you for trusting me again",
        title = "Second chance", glyph = "supply", family = "want", giver = { "civ", "work", "rescue", "law", "mil", "out", "raid" },
        repMin = 1, hours = 72, reward = "favor", summary = "They slipped. They want to try again, if you'll hold their bottles one more time",
        ask = "Can I ask you for something I don't deserve?", impact = "Hold their bottles two days. One more chance, maybe the last",
        paths = { soft = path(3, 0.6, { { k = "keep", place = "giver", hours = 48, label = "Hold on to their bottles, again" } }) } },
    -- 0.9.3 power plays: the inside man
    { id = "spy_rival", alcp = { kind = "spy", tier = "uncommon", group = true }, report = "I watched them", title = "The inside man",
        glyph = "investigate", family = "find", giver = { "civ", "work", "law", "mil", "out", "raid" }, repMin = 2, hours = 72, reward = "trade",
        summary = "They want to know what a rival group is up to. Get close to their place and watch who comes and goes",
        ask = "Ever wonder what they're planning over there?", impact = "Pays for what you see. Don't get seen",
        paths = { soft = path(2, 1.0, { { k = "reach", place = "alcp_haven", label = "Get close to the {place}" },
            { k = "guard", place = "alcp_haven", hours = 0.25, label = "Watch who comes and goes" } }) } },
    { id = "deliver_word", alcp = { kind = "meet", tier = "uncommon" }, report = "They got your message", title = "Carry word",
        glyph = "signal", family = "deliver", giver = { "civ", "work", "rescue", "law", "mil" }, repMin = 1, hours = 72,
        reward = "trade", unlock = "trader_pass", summary = "Find {name} of a friendly group and pass on their word",
        ask = "Anyone you need a word passed to?", impact = "Pays for carrying a message to a friend",
        paths = { soft = path(1, 1.0, { { k = "meet", place = "alcp_target", label = "Find {name} and pass the word on" } }) } },
}

K.LINES = {
    want_smokes = { pitch = { "I'd kill for a smoke, the last one went a week ago", "Bring me a pack and I'll make it worth your while" },
        yes = { "Bless you, I'll be here, chewing my nails" }, no = { "Yeah, nobody's got any" },
        nudge = { "Still nothing to smoke?", "My hands won't stop shaking" }, done = { "Oh, that's the stuff. Thank you", "You've no idea what this means" },
        lapse = { "Forget it, I'm quitting the hard way" } },
    want_drink = { pitch = { "I could use a real drink, just one night", "Find me a bottle and I'll pay you for it" },
        yes = { "Don't drink it on the way" }, no = { "Fair, keep your head clear" },
        nudge = { "Any luck with that bottle?" }, done = { "Now that's something. Thank you", "I'll save a glass for you" },
        lapse = { "Never mind, dry's probably better" } },
    want_coffee = { pitch = { "I'd give a lot for coffee. Or tea. Anything warm that isn't rain", "Some chocolate, coffee, anything that tastes like before" },
        yes = { "I'll get the water boiling" }, no = { "Yeah, I know, it's all gone" }, nudge = { "Still no coffee?" },
        done = { "Smell that. Thank you", "Like a morning before all this" }, lapse = { "I've got used to going without" } },
    want_reading = { pitch = { "I've read everything here three times. Bring me something new", "Books, comics, anything with words in it" },
        yes = { "Anything, I'm not picky" }, no = { "Back to staring at the wall, then" }, nudge = { "Find anything to read?" },
        done = { "That'll keep me sane a while longer", "Thank you, really" }, lapse = { "I started on the cereal boxes" } },
    want_cleanup = { pitch = { "I'd trade a lot for a bar of soap and a razor", "I can't stand my own smell, bring me soap and a razor" },
        yes = { "Thank you, I mean it" }, no = { "Fine, I'll stay a mess" }, nudge = { "Any soap out there?" },
        done = { "I'm going to feel human again", "Thank you, that's a gift" }, lapse = { "Never mind, nobody looks anyway" } },
    want_glasses = { pitch = { "My glasses broke, I can barely see past my hand", "Bring me a pair of glasses that works, any pair" },
        yes = { "I'll try not to walk into anything meanwhile" }, no = { "Then I'll squint" }, nudge = { "Find any glasses?" },
        done = { "I can see your face. Thank you", "Oh. Oh, that's better" }, lapse = { "I've learned to get by blind" } },
    want_games = { pitch = { "The evenings are long. Cards, dice, anything we could play", "Bring us something to pass the dark hours" },
        yes = { "The others will be glad" }, no = { "Fine, more staring at the fire" }, nudge = { "Any luck finding games?" },
        done = { "Tonight we play. Thank you", "You've no idea what that does for a group" }, lapse = { "We found other ways to pass the time" } },
    want_music = { pitch = { "Some of us used to play. An instrument for the fire would do us good", "Find us something to play, a guitar, a harmonica, anything" },
        yes = { "We'll play you a song when you're back" }, no = { "Yeah, it's a silly thing to want" }, nudge = { "Find anything we could play?" },
        done = { "Music again. Thank you", "Stay tonight, we'll play it for you" }, lapse = { "We'll sing without, then" } },
    want_feast = { pitch = { "We want one night off from all of it. A couple of bottles and something sweet", "Help us throw a little party, we've earned it" },
        yes = { "You're invited, of course" }, no = { "Maybe another time" }, nudge = { "How's that party coming along?" },
        done = { "Tonight we celebrate. Thanks to you", "Stay. You're one of us tonight" }, lapse = { "The moment's passed" } },
    find_person = { pitch = { "{name} went out and never came back. Find out what happened, I need to know", "I keep waiting for {name}. Will you find them? Or what's left" },
        yes = { "Whatever you find, tell me the truth" }, no = { "I understand. I'll keep waiting" },
        nudge = { "Anything about {name}?", "Please, any word at all" }, done = { "Thank you for telling me", "At least now I know" },
        lapse = { "I've stopped hoping" } },
    deliver_word = { pitch = { "{name}'s people are friends of ours. Get word to them for me", "Find {name} and tell them we're alright. They'll want to know" },
        yes = { "Tell {name} it's from me" }, no = { "Another time, then" }, nudge = { "Did {name} get my word?" },
        done = { "Good, now they know", "Thanks for carrying that" }, lapse = { "Too late now, it doesn't matter anymore" } },
    story_family = { pitch = { "{name}. I know where they are now. I just can't make that walk alone", "I need to see {name} again. Will you take me?" },
        yes = { "I've thought about what I'll say a hundred times" }, no = { "Maybe I'm not ready anyway" },
        nudge = { "Can we go see {name}?", "I keep thinking about {name}" },
        done = { "Thank you. I never thought I'd see them again", "I don't have the words. Thank you" }, lapse = { "Maybe it's better this way" } },
    story_amends = { pitch = { "Me and {name}, it went bad. My fault. I want to make it right, face to face", "Walk me to {name}? I owe them an apology" },
        yes = { "Don't let me back out" }, no = { "Yeah. Another day" }, nudge = { "I still need to talk to {name}" },
        done = { "That went better than I deserved", "Feels like I can breathe again" }, lapse = { "I lost my nerve" } },
    story_revenge = { pitch = { "{name} killed someone I loved. I want them dead", "I can't sleep while {name} is breathing" },
        yes = { "Make it count" }, no = { "Then I'll do it myself, one day" }, nudge = { "{name} is still out there" },
        done = { "It's done. It doesn't bring them back. But it's done", "Thank you. I don't feel better. But thank you" },
        lapse = { "Maybe it's for the best I didn't" } },
    want_medicine = { pitch = { "One of ours is hurt bad and we've nothing left to treat it", "Medicine. Bandages. Anything. They're getting worse" },
        yes = { "Hurry. Please" }, no = { "Then we'll pray, I guess" }, nudge = { "Did you find anything? They're worse" },
        done = { "This might save them. Thank you", "You've no idea. Thank you" }, lapse = { "It's too late now" } },
    want_winter = { pitch = { "Winter's close and we've nothing warm. Coats, wood, anything", "We won't make it through the cold like this" },
        yes = { "Before the first snow, if you can" }, no = { "We'll burn the furniture, then" }, nudge = { "It's getting colder every night" },
        done = { "We might see spring after all", "That's the difference between living and not. Thank you" }, lapse = { "We made do. Barely" } },
    story_prodigal = { pitch = { "{name} left after we fought. Went with other people. I want them home", "Find {name}. Tell them I was wrong. Ask them to come home" },
        yes = { "Tell them I'm sorry. Tell them first" }, no = { "Maybe they don't want to come anyway" },
        nudge = { "Any word from {name}?", "I keep the door open for {name}" },
        done = { "They're home. I thought I'd lost them for good", "Thank you. We'll fix it, the two of us" }, lapse = { "They made their choice" } },
    story_guilt = { pitch = { "It should have been me out there, not {name}", "I need to go where {name} died. I can't go alone" },
        yes = { "Just walk with me. You don't have to say anything" }, no = { "Yeah. I'm not ready either" },
        nudge = { "I still can't stop thinking about {name}" }, done = { "I said goodbye. I think I can breathe now", "Thank you for walking with me" },
        lapse = { "I'll carry it. That's all I can do" } },
    story_second = { pitch = { "I slipped. I know. Hold my bottles again? One more chance", "I want to try again. I know I don't deserve your help" },
        yes = { "This time. I swear, this time" }, no = { "I understand. I wouldn't trust me either" },
        nudge = { "How long now?", "Don't give me one. Whatever I say" }, done = { "Still dry. Second chance, and I took it", "Thank you for not giving up on me" },
        lapse = { "I'm sorry. I'm so sorry" } },
    spy_rival = { pitch = { "I want eyes on that lot. How many, how armed, who's in charge", "Go watch their place a while. Tell me what you see" },
        yes = { "Don't get caught. I never sent you" }, no = { "Fine. We'll find out the hard way" }, nudge = { "Seen anything yet?" },
        done = { "That's worth knowing. Here", "Good. Now we know what we're up against" }, lapse = { "Forget it, we found out ourselves" } },
    story_clean = { pitch = { "I need to stop drinking. Take my bottles. Don't give them back, whatever I say", "Hold on to my bottles. I can't be trusted with them" },
        yes = { "Whatever I say, don't give them back" }, no = { "Yeah, I know, it's my problem" },
        nudge = { "Just one. Come on. No, don't. Don't listen to me", "How long has it been?" },
        done = { "Two days. I know it's not much. It's the longest in a year", "I held on. Thank you for holding on with me" },
        lapse = { "I found another bottle. I'm sorry" } },
    escort_scavenge = { pitch = { "I'm going for supplies at the {place} near {where}. Watch my back?", "Nobody goes out alone. Come with me to the {place}" },
        yes = { "Stay close, and if I say run, we run" }, no = { "Then I'll wait till someone's free" },
        nudge = { "Ready to head out?", "We're not done yet, keep your eyes open" }, done = { "We made it. Thanks for having my back", "Here, you earned a share" },
        lapse = { "I went without you. Nearly didn't come back" } },
    escort_scenic = { pitch = { "There's a quiet place near {where}. I want to see it one more time. Not alone", "Walk with me a while? Not for anything. Just to go" },
        yes = { "Thank you. It won't take long" }, no = { "Another day, maybe" }, nudge = { "Still want to go for that walk?" },
        done = { "I needed that more than I knew", "Thank you. Really" }, lapse = { "Never mind. The moment's gone" } },
    hand_back = { pitch = { "You've got {name}. Bring them home and we'll remember it", "{name} is ours. Let them come home" },
        yes = { "Bring them here, unhurt" }, no = { "Then we'll remember that too" }, nudge = { "Where's {name}?" },
        done = { "They're home. We won't forget this", "You kept your word" }, lapse = { "We'll get them back our own way" } },
    bring_back = { pitch = { "{name} is with another group now. If they'd come home, would you bring them?", "Talk to {name}. If they want to come back, bring them" },
        yes = { "Don't force them. Just ask" }, no = { "Maybe it's for the best" }, nudge = { "Did you talk to {name}?" },
        done = { "They're home. Thank you", "I didn't think I'd see them again" }, lapse = { "They made their choice" } },
    hit_member = { pitch = { "{name}. You know who. I want them gone, and nobody tracing it back here", "There's one of them, {name}. Deal with it and you'll be paid" },
        yes = { "Quiet if you can. Loud if you must" }, no = { "Forget I said anything" }, nudge = { "{name} is still breathing" },
        done = { "Good. Here's your pay. We never talked", "That's done, then" }, lapse = { "Forget it, we'll handle it ourselves" } },
    raid_stash = { pitch = { "Their stash at the {place} near {where}. Take what you can carry", "I want them hungry. Hit their stash" },
        yes = { "Keep what you take. Don't get seen" }, no = { "Then keep your nose out of it" }, nudge = { "Their stash still full?" },
        done = { "Good. Let them go hungry a while", "That'll hurt them. Here" }, lapse = { "Too slow. Never mind" } },
    burn_out = { pitch = { "They're holed up at the {place} near {where}. I want them out of there, however it takes", "Make them leave that place. I don't care how" },
        yes = { "Take people with you if you can" }, no = { "Then they stay, for now" }, nudge = { "They're still sitting there" },
        done = { "They're gone. You've no idea what that means to us", "The place is clear of them. Here's what I owe" },
        lapse = { "They dug in. Forget it" } },
}
K.GENERAL = {
    ["TB_GEN.nocarry"] = { any = { "Hold on, I don't have it to give you after all", "Damn, I thought I still had it. Forget it" } },
    ["TB_GEN.dry"] = { any = { "I don't have a drop on me. Good, maybe", "Nothing left to hand you. I drank it" } },
}

function K.tierOk(def, giverUid)
    local tier = type(def.alcp) == "table" and def.alcp.tier or "common"
    if tier == "common" then return true end
    local odds = 100
    if tier == "uncommon" then odds = num(K.setting("questOddsUncommon"), 50)
    elseif tier == "rare" then odds = num(K.setting("questOddsRare"), 25)
    elseif tier == "veryrare" then odds = num(K.setting("questOddsVeryRare"), 10) end
    local ok = roll("tier:" .. tostring(giverUid) .. ":" .. def.id .. ":" .. math.floor(K.hours() / 24)) * 100 < odds
    if not ok then K.metrics.rare = K.metrics.rare + 1 end
    return ok
end

-- does the giver lack what they'd ask for? (only when we can see their pack)
function K.lacks(def, giverUid)
    local lack = type(def.alcp) == "table" and def.alcp.lack or nil
    if lack == nil then return true end
    local s = K.shellOf(giverUid)
    local inv = call(s, "getInventory")
    if inv == nil then return true end
    for _, t in ipairs(lack) do
        local list = call(inv, "getAllTypeRecurse", t)
        if num(call(list, "size"), 0) > 0 then return false end
    end
    return true
end

-- 0.9.1: a want that needs a real reason: someone of theirs hurt (medicine run), the fall (winter's coming)
K.FIRST_WAVE = { want_medicine = "hurt", want_winter = "fall" }
function K.hurtNear(giver)
    local gx, gy = posOf(giver)
    local s0 = K.shellOf(giver.uid)
    if s0 ~= nil then local x, y = num(call(s0, "getX"), nil), num(call(s0, "getY"), nil); if x then gx, gy = x, y end end
    if gx == nil then return nil end
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "each") then return nil end
    local gm = mem(giver)
    local below = num(K.setting("questHurtBelow"), 60)
    local reach = num(K.setting("questHurtReach"), 40)
    local found, seen = nil, 0
    pcall(pa.ActorRegistry.each, function(r)
        seen = seen + 1
        if seen > 3000 then return true end
        if type(r) ~= "table" or dead(r) then return false end
        if not (tostring(r.uid) == tostring(giver.uid) or (gm.groupId ~= nil and mem(r).groupId == gm.groupId)) then return false end
        local sh = K.shellOf(r.uid)
        if sh == nil then return false end
        local x, y = num(call(sh, "getX"), nil), num(call(sh, "getY"), nil)
        if x == nil or d(gx, gy, x, y) > reach then return false end
        local hp = nil
        local bd = call(sh, "getBodyDamage")
        if bd ~= nil then pcall(function() hp = bd:getOverallBodyHealth() end) end
        if tonumber(hp) and hp < below then found = r; return true end
        return false
    end)
    return found
end
function K.month()
    local m = nil
    pcall(function() m = getGameTime():getMonth() end)
    return num(m, 6)
end
function K.needOk(def, record)
    local need = K.FIRST_WAVE[def.id]
    if need == nil then return true end
    if not K.on("questFirstWave") then return false end
    if need == "hurt" then return K.hurtNear(record) ~= nil end
    if need == "fall" then local m = K.month(); return m >= 8 and m <= 10 end -- September to November (0 = January)
    return true
end

-- extra eligibility for a def, with the giver known (set around the provider)
function K.allowed(def, record)
    if not K.on() then return true end
    if K.FAKE[def.id] and K.on("questFakeOff") then K.metrics.fakeHidden = K.metrics.fakeHidden + 1; return false end
    if def.id == "clear_house" and K.setting("questClearHouse") == false then return false end
    local a = def.alcp
    if type(a) ~= "table" then return true end
    if a.kind == "want" and not K.on("questWants") then return false end
    if a.kind == "seek" and not K.on("questFindPerson") then return false end
    if a.kind == "meet" and not K.on("questDeliver") then return false end
    if a.kind == "company" and not K.on("questCompany") then return false end
    if a.story ~= nil then
        if not K.on("questStory") or record == nil then return false end
        local g = K.goalOf(record.uid)
        if g == nil or g.k ~= a.story or g.done ~= nil then return false end
        if not K.on("questFirstWave") and (a.story == "prodigal" or a.story == "guilt" or a.story == "second") then return false end
        if a.story == "clean" or a.story == "second" then
            -- dry since you held their bottles: nothing to ask until they slip
            if g.dryH ~= nil and num(g.relapseH, -1) < num(g.dryH, 0) then return false end
            return true
        end
        local t = K.record(g.t)
        if t == nil then return false end
        -- family: they don't know their kin died; the walk finds out and the truth is told
        if a.story == "guilt" then return dead(t) end -- 0.9.1: guilt is about someone who died
        if dead(t) and a.story ~= "family" then return false end
        return true
    end
    if a.kind == "handback" and not K.on("questHandBack") then return false end
    if a.kind == "persuade" and not K.on("questChains") then return false end
    if (a.kind == "hit" or a.kind == "steal" or a.kind == "drive" or a.kind == "spy") and not K.on("questFactionJobs") then return false end
    if not K.itemsOk(def) then return false end
    if record == nil then return a.kind == "want" end
    if not K.tierOk(def, record.uid) then return false end
    if a.kind == "want" then return K.lacks(def, record.uid) and K.needOk(def, record) end
    if a.kind == "seek" then return K.scan("missing", record) ~= nil end
    if a.kind == "meet" then return K.scan("receiver", record) ~= nil end
    if a.kind == "hit" then return K.scan("enemy", record) ~= nil end
    if a.kind == "steal" or a.kind == "drive" or a.kind == "spy" then return K.enemyHaven(record) ~= nil end
    if a.kind == "handback" then return K.captiveFor(record, K.curPlayer) ~= nil end
    if a.kind == "persuade" then return K.chainFor(record) ~= nil end
    return true
end

-- who/where a task is about, at build time
function K.targetFor(def, giver, player)
    local a = def.alcp
    if a.story ~= nil then
        local g = K.goalOf(giver.uid)
        if g == nil then return nil end
        if a.story == "clean" or a.story == "second" then return { target = giver, giver = giver } end
        return { target = K.record(g.t), giver = giver }
    end
    if a.kind == "seek" then return { target = K.scan("missing", giver) } end
    if a.kind == "meet" then return { target = K.scan("receiver", giver) } end
    if a.kind == "hit" then return { target = K.scan("enemy", giver) } end
    if a.kind == "steal" or a.kind == "drive" or a.kind == "spy" then local h = K.enemyHaven(giver); return h and { haven = h, giver = giver } or nil end
    if a.kind == "handback" then return { target = K.captiveFor(giver, player), giver = giver } end
    if a.kind == "persuade" then return { target = K.chainFor(giver), giver = giver } end
    if a.kind == "company" then return { target = giver, giver = giver, company = true } end
    return nil
end

-- the data, rows and lines go in on both sides at load
function K.addData()
    local pa = PA()
    if pa == nil then return false end
    Data, Rules, Text, Rows = pa.TaskBoardData, pa.TaskBoardRules, pa.TaskBoardText, pa.TaskBoardRows
    if type(Data) ~= "table" or type(Data.tasks) ~= "table" or type(Rules) ~= "table" then return false end
    if K.dataIn then return true end
    Data.places.alcp_target = Data.places.alcp_target or { word = "person", alcp = "target" }
    Data.places.alcp_last = Data.places.alcp_last or { word = "last place they were heard of", alcp = "last" }
    Data.places.alcp_depot = Data.places.alcp_depot or { word = "stash", alcp = "depot" }
    Data.places.alcp_haven = Data.places.alcp_haven or { word = "place they hold", alcp = "haven" }
    Data.places.alcp_home = Data.places.alcp_home or { word = "home", alcp = "home" }
    Data.places.alcp_view = Data.places.alcp_view or { word = "quiet spot they like", ring = { 60, 140 } }
    for _, k in ipairs({ "seek", "meet", "escort", "guard", "handback", "persuade", "kill", "steal", "drive", "reunite", "keep" }) do Rules.stepKinds[k] = true end
    local added = 0
    for _, def in ipairs(K.TASKS) do
        if Data.byId[def.id] == nil then
            Data.tasks[#Data.tasks + 1] = def
            Data.byId[def.id] = def
            Data.order[#Data.order + 1] = def.id
            added = added + 1
        end
    end
    if type(Text) == "table" and type(Text.lines) == "table" then
        for id, set in pairs(K.LINES) do Text.lines[id] = set end
        if type(Text.general) == "table" then for k, v in pairs(K.GENERAL) do Text.general[k] = v end end
        if fn(Text, "merge") then pcall(Text.merge) end
    end
    if type(Rows) == "table" and fn(Rows, "add") then
        for _, task in ipairs(K.TASKS) do K.addRows(task) end
    end
    K.dataIn = true
    K.added = added
    return true
end

function K.addRows(task)
    local Hook = PA().TalkRowHook
    local askId, reportId = Rows.askId(task.id), Rows.reportId(task.id)
    Rows.add({ id = askId, text = task.ask, impact = task.impact, tab = "Personal", priority = 38, experiment = "tasks30_board",
        group = "TB_WORK", cooldownHours = Data.limits.askCooldownHours, stances = Rows.stances, task = task.id,
        gate = function(ctx)
            local facts = Rows.facts(ctx)
            if facts == nil or facts.askId ~= askId then return false, "no_pick" end
            return true
        end,
        handler = function(...) return Rows.dispatch("ask", ...) end })
    Rows.add({ id = reportId, text = task.report, impact = "Collect what you were promised", risk = "Do it before the offer lapses",
        tab = "Personal", priority = 4, experiment = "tasks30_board", group = "TB_REPORT", cooldownHours = 0, tone = "important",
        stances = { friendly = true, neutral = true, careful = true }, task = task.id,
        gate = function(ctx)
            local facts = Rows.facts(ctx)
            if facts == nil or facts.reportId ~= reportId then return false, "no_report" end
            return true
        end,
        handler = function(...) return Rows.dispatch("report", ...) end })
end

-- ---------------------------------------------------------------------------------------------------- hooks (server)
K.hooked, K.off = K.hooked or {}, K.off or {}
local function guard(name, f)
    return function(...)
        if K.off[name] then return nil, "off" end
        local ok, a, b = pcall(f, ...)
        if not ok then
            K.off[name] = true
            log("hook '" .. name .. "' failed, off for this session: " .. tostring(a))
            return nil, "off"
        end
        return a, b
    end
end

-- per-build context: the target person for our tasks
K.build = nil

function K.siteForTarget(spec)
    local b = K.build
    if b == nil then return nil end
    if spec.alcp == "depot" or spec.alcp == "haven" then
        local h = b.haven
        if h == nil then return nil end
        local p = spec.alcp == "depot" and type(h.depot) == "table" and h.depot or h
        if tonumber(p.x) == nil then return nil end
        return { x = math.floor(p.x), y = math.floor(p.y), z = 0, word = spec.alcp == "depot" and "stash" or (h.kind == "camp" and "camp" or "house") }
    end
    if spec.alcp == "home" then
        if b.giver == nil then return nil end
        local x, y = K.homeOf(b.giver)
        if x == nil then return nil end
        return { x = math.floor(x), y = math.floor(y), z = 0, word = "home" }
    end
    if b.target == nil then return nil end
    local r = b.target
    local x, y = posOf(r)
    if x == nil then return nil end
    if spec.alcp == "last" then
        -- the giver only knows roughly: within 40 tiles of where they really were
        local j = roll("last:" .. tostring(r.uid))
        local a = j * 6.283
        x, y = x + math.cos(a) * 40 * j, y + math.sin(a) * 40 * j
        return { x = math.floor(x), y = math.floor(y), z = 0, word = "last place they were heard of" }
    end
    return { x = math.floor(x), y = math.floor(y), z = 0, word = "place " .. K.nameOf(r) .. " was", alcpUid = tostring(r.uid) }
end

function K.install()
    local pa = PA()
    local Board = pa and pa.TaskBoard or nil
    if type(Board) ~= "table" or type(Board.world) ~= "table" then return 0 end
    if not K.addData() then return 0 end
    local W = Board.world
    local n = 0

    -- 1. W.give: nothing appears from nothing (rewards and carried things are paid by us from real packs)
    if not K.hooked.give and fn(W, "give") then
        local orig = W.give
        W.give = function(player, list)
            if K.on("questNoGifts") and not K.letGive then
                K.metrics.giveRefused = K.metrics.giveRefused + 1
                return false
            end
            return orig(player, list)
        end
        K.hooked.give = true
    end
    if K.hooked.give then n = n + 1 end

    -- 2. W.spawn: no zombies made for a task
    if not K.hooked.spawn and fn(W, "spawn") then
        local orig = W.spawn
        W.spawn = function(site, count)
            if K.on("questNoSpawns") then K.metrics.spawnRefused = K.metrics.spawnRefused + (tonumber(count) or 0); return 0 end
            return orig(site, count)
        end
        K.hooked.spawn = true
    end
    if K.hooked.spawn then n = n + 1 end

    -- 3. provider: know the giver while A-Life picks a task
    if not K.hooked.provider and fn(Board, "provider") and type(pa.TalkRowHook) == "table" and fn(pa.TalkRowHook, "provider") then
        local orig = Board.provider
        local wrapped = function(ctx)
            K.giverRec = type(ctx) == "table" and ctx.record or nil
            K.curPlayer = type(ctx) == "table" and ctx.player or nil
            local ok, out = pcall(orig, ctx)
            K.giverRec = nil
            if not ok then error(out) end
            return out
        end
        Board.provider = wrapped
        pa.TalkRowHook.provider("taskboard", wrapped)
        K.hooked.provider = true
    end
    if K.hooked.provider then n = n + 1 end

    -- 4. eligible: made-up tasks off, rarity, real targets, real lacks
    if not K.hooked.eligible and fn(Rules, "eligible") then
        local orig = Rules.eligible
        local check = guard("eligible", function(def, rec) return K.allowed(def, rec) end)
        Rules.eligible = function(def, ctx)
            local ok, why = orig(def, ctx)
            if not ok then return ok, why end
            local allow = check(def, K.giverRec)
            if allow == false then return false, "alcp" end
            return true, nil
        end
        K.hooked.eligible = true
    end
    if K.hooked.eligible then n = n + 1 end

    -- 5. build + siteFor: our tasks get a real target person
    if not K.hooked.build and fn(Rules, "build") and fn(Rules, "siteFor") then
        local origBuild, origSite = Rules.build, Rules.siteFor
        Rules.siteFor = function(placeKey, anchor, seed, world, prev, taken)
            local spec = Data.places[placeKey]
            if type(spec) == "table" and spec.alcp ~= nil then return K.siteForTarget(spec) end
            local site = origSite(placeKey, anchor, seed, world, prev, taken)
            local ok, s = pcall(K.placeSite, placeKey, spec, site, anchor, seed, prev, taken)
            if ok then site = s elseif not K.siteErr then K.siteErr = true; log("place site error (once): " .. tostring(s)) end
            if site ~= nil then K.lastSite, K.lastSiteKey = site, placeKey end
            return site
        end
        Rules.build = function(def, style, ctx)
            local a = type(def) == "table" and def.alcp or nil
            if type(a) ~= "table" or a.kind == "want" then return origBuild(def, style, ctx) end
            local giver = K.record(ctx and ctx.giverUid)
            local b = giver and K.targetFor(def, giver, K.curPlayer) or nil
            if b == nil or (b.target == nil and b.haven == nil) then return nil, "no_target" end
            K.build = b
            local ok, job, why = pcall(origBuild, def, style, ctx)
            K.build = nil
            if not ok then error(job) end
            if type(job) == "table" then
                -- a step at the same place as the one before is the same spot (A-Life spreads steps 25+ tiles apart)
                local steps = type(def.paths[style]) == "table" and def.paths[style].steps or {}
                for i = 2, #steps do
                    if steps[i].place ~= nil and steps[i].place == steps[i - 1].place and job.sites[i - 1] ~= nil then
                        local s = job.sites[i - 1]
                        job.sites[i] = { x = s.x, y = s.y, z = s.z or 0, word = s.word }
                    end
                end
                if b.target ~= nil then
                    job.alcpT = tostring(b.target.uid)
                    job.name = K.nameOf(b.target)
                    job.alcpGroup = mem(b.target).groupId
                end
                if b.haven ~= nil then
                    job.alcpHaven = b.haven.id
                    job.alcpGroup = b.haven.groupId
                    job.name = "them"
                end
            end
            return job, why
        end
        K.hooked.build = true
    end
    if K.hooked.build then n = n + 1 end

    -- 6. stepTick: the "seek" and "meet" steps, against the real person
    if not K.hooked.step and fn(Rules, "stepTick") then
        local orig = Rules.stepTick
        Rules.stepTick = function(job, step, index, pos, world, player, hours, events)
            if type(step) == "table" and K.OUR_STEPS[step.k] then
                local ok, done = pcall(K.stepOurs, job, step, index, pos, hours, player)
                if ok then return done == true end
                if not K.stepErr then K.stepErr = true; log("person step error (once): " .. tostring(done)) end
                return false
            end
            return orig(job, step, index, pos, world, player, hours, events)
        end
        K.hooked.step = true
    end
    if K.hooked.step then n = n + 1 end

    -- 7. failCheck: the person you carry word to died
    if not K.hooked.fail and fn(Rules, "failCheck") then
        local orig = Rules.failCheck
        Rules.failCheck = function(job, ctx)
            local why = orig(job, ctx)
            if why ~= nil then return why end
            if type(job) == "table" and job.state == "active" then
                if job.alcpWhy ~= nil then return "stale" end
                if job.id == "story_clean" then
                    local g = K.goalOf(job.giver)
                    if g ~= nil and (tonumber(g.relapseH) or -1) >= (tonumber(job.startHours) or 0) then
                        job.alcpWhy = "You gave them a drink. It's over, for now"
                        return "stale"
                    end
                end
                local def = Data.byId[job.id]
                local kind = def and def.alcp and def.alcp.kind or nil
                if job.alcpT ~= nil and (kind == "meet" or kind == "handback" or kind == "persuade") and dead(K.record(job.alcpT)) then
                    job.alcpWhy = tostring(job.name) .. (kind == "meet" and " is dead. The word never reached them" or " is dead")
                    return "stale"
                end
            end
            return nil
        end
        if fn(Board, "fail") then
            local origFail = Board.fail
            Board.fail = function(player, entry, job, why, quiet)
                local out = origFail(player, entry, job, why, quiet)
                if type(job) == "table" and job.alcpWhy ~= nil and fn(W, "event") then
                    local def = Data.byId[job.id]
                    pcall(W.event, player, "updated", def and def.title or "Task", job.alcpWhy)
                end
                return out
            end
        end
        K.hooked.fail = true
    end
    if K.hooked.fail then n = n + 1 end

    -- 8. report: real pay from the giver's pack (A-Life's reward runs with an empty pool)
    if not K.hooked.report and type(Rows.handlers) == "table" and fn(Rows.handlers, "report") and fn(Board, "reward") then
        local origReport = Rows.handlers.report
        Rows.handlers.report = function(rowDef, record, shell, player, ctx, now)
            K.payShell = shell
            local ok, a, b = pcall(origReport, rowDef, record, shell, player, ctx, now)
            K.payShell = nil
            if not ok then error(a) end
            return a, b
        end
        local origReward = Board.reward
        Board.reward = function(player, entry, job, def, record)
            if not K.on("questRealPay") then return origReward(player, entry, job, def, record) end
            local style = type(job) == "table" and job.style or "soft"
            if type(job) == "table" then job.reward = {} end
            local out = origReward(player, entry, job, def, record)
            pcall(K.afterReward, player, job, def, record, style)
            return out
        end
        K.hooked.report = true
    end
    if K.hooked.report then n = n + 1 end

    -- 9. path (accept): anything they hand you to carry comes from their pack
    if not K.hooked.path and type(Rows.handlers) == "table" and fn(Rows.handlers, "path") then
        local origPath = Rows.handlers.path
        Rows.handlers.path = function(rowDef, record, shell, player, ctx, now)
            K.curPlayer = player
            local refuse = nil
            if K.on("questNoGifts") then
                local ok, r = pcall(K.carryFromGiver, Board, rowDef, record, shell, player)
                if ok then refuse = r end
            end
            if refuse ~= true and rowDef ~= nil then
                local ok, r = pcall(K.bottlesFromGiver, Board, rowDef, record, shell, player)
                if ok and r == true then
                    local entry = Board.entry(player)
                    if type(entry) == "table" then entry.offer = nil end
                    return Board.say(ctx, "TB_GEN.dry"), "answered"
                end
            end
            if refuse == true then
                local entry = fn(Board, "entry") and Board.entry(player) or nil
                if type(entry) == "table" then entry.offer = nil end
                K.metrics.noCarry = K.metrics.noCarry + 1
                return Board.say(ctx, "TB_GEN.nocarry"), "answered"
            end
            local a, b = origPath(rowDef, record, shell, player, ctx, now)
            -- company: they walk with you (A-Life's own walk-with)
            pcall(function()
                local entry = Board.entry(player)
                local job = type(entry) == "table" and entry.job or nil
                local def = type(job) == "table" and Data.byId[job.id] or nil
                if def and def.alcp and def.alcp.kind == "company" and job.giver == record.uid then K.walk(player, record) end
                if def and def.alcp and def.alcp.kind == "reunite" and job.giver == record.uid then K.walk(player, record) end
                if type(job) == "table" and job.id == "story_clean" and K.lastKeepN ~= nil then job.alcpKeepN = K.lastKeepN; K.lastKeepN = nil end
            end)
            return a, b
        end
        K.hooked.path = true
    end
    if K.hooked.path then n = n + 1 end

    -- 10. ask: know who is asking, for tasks about something they hold (bring them home)
    if not K.hooked.ask and type(Rows.handlers) == "table" and fn(Rows.handlers, "ask") then
        local origAsk = Rows.handlers.ask
        Rows.handlers.ask = function(rowDef, record, shell, player, ctx, now)
            K.curPlayer = player
            return origAsk(rowDef, record, shell, player, ctx, now)
        end
        K.hooked.ask = true
    end
    if K.hooked.ask then n = n + 1 end
    return n
end
K.HOOKS = 10

-- 0.9.x #12: the active task's place on the world map. Text symbol "[Task] <title>" (same proven symbols API v2 as the
-- journal / settlement marks). Idempotent: every map open takes off our old "[Task] " marks, then adds the current one.
K.MAP_TAG = "[Task] "
function K.mapQuest(player)
    local map = ISWorldMap_instance
    if map == nil or map.mapAPI == nil then return 0 end
    local api = map.mapAPI
    local sym = nil
    pcall(function() sym = api.getSymbolsAPIv2 and api:getSymbolsAPIv2() or api:getSymbolsAPI() end)
    if sym == nil then return 0 end
    pcall(function()
        for i = sym:getSymbolCount() - 1, 0, -1 do
            local s = sym:getSymbolByIndex(i)
            if s ~= nil and s:isText() and string.sub(tostring(s:getUntranslatedText()), 1, #K.MAP_TAG) == K.MAP_TAG then sym:removeSymbolByIndex(i) end
        end
    end)
    if not K.on("questMap") then return 0 end
    local pa = PA()
    local Board = pa and pa.TaskBoard or nil
    if player == nil and type(getPlayer) == "function" then player = getPlayer() end
    if type(Board) ~= "table" or not fn(Board, "entry") or player == nil then return 0 end
    local entry = Board.entry(player)
    local job = type(entry) == "table" and entry.job or nil
    if type(job) ~= "table" or job.state ~= "active" or type(job.sites) ~= "table" or type(job.prog) ~= "table" then return 0 end
    local _, site = Rules.currentSite(job)
    if type(site) ~= "table" or tonumber(site.x) == nil or tonumber(site.y) == nil then return 0 end
    local def = Data.byId[job.id]
    local text = K.MAP_TAG .. tostring(def and def.title or job.id or "Task")
    local n = 0
    pcall(function()
        local layer = sym.getDefaultTextLayerID and sym:getDefaultTextLayerID() or nil
        local s = layer and sym:addUntranslatedText(text, layer, math.floor(site.x), math.floor(site.y)) or sym:addUntranslatedText(text, nil, math.floor(site.x), math.floor(site.y))
        if s then
            s:setRGBA(0.6, 0.12, 0.1, 1.0)
            s:setAnchor(0.5, 0.5)
            pcall(function() s:setScale(ISMap.SCALE) end)
            n = 1
        end
    end)
    return n
end
function K.hookMap()
    if type(ISWorldMap) ~= "table" or not fn(ISWorldMap, "ShowWorldMap") or ISWorldMap._alcpQuestMap then return end
    ISWorldMap._alcpQuestMap = true
    local show = ISWorldMap.ShowWorldMap
    ISWorldMap.ShowWorldMap = function(playerNum, ...)
        local r = show(playerNum, ...)
        local ok, err = pcall(function() K.mapQuest(type(getSpecificPlayer) == "function" and tonumber(playerNum) and getSpecificPlayer(playerNum) or nil) end)
        if not ok and not K.mapErr then K.mapErr = true; log("quest map mark failed (once): " .. tostring(err)) end
        return r
    end
end

-- their own goal (0.8.7), set by ALifeTalk_Story from real ties and habits; kept in the save
function K.goalOf(uid)
    if uid == nil then return nil end
    local s = K.store()
    s.goals = type(s.goals) == "table" and s.goals or {}
    local g = s.goals[tostring(uid)]
    return type(g) == "table" and g or nil
end

-- goals cross ALifeCmd (client picks them from its ties / habits, the server keeps them and judges outcomes)
K.STORY_KINDS = { family = true, amends = true, revenge = true, clean = true, prodigal = true, guilt = true, second = true }
local function cleanish(k) return k == "clean" or k == "second" end -- 0.9.1: a second chance is getting clean again
local function goalView(g)
    if type(g) ~= "table" then return nil end
    return { k = g.k, t = g.t, tn = g.tn, h = g.h, done = g.done, outcome = g.outcome, fate = g.fate,
        relapseH = g.relapseH, dryH = g.dryH, held = g.held, leak = g.leak,
        -- 0.9.1 the lead, flat (ALifeCmd drops tables nested deeper than 3: payload > goals > uid > lead)
        leadH = type(g.lead) == "table" and g.lead.h or nil, leadX = type(g.lead) == "table" and g.lead.x or nil,
        leadY = type(g.lead) == "table" and g.lead.y or nil, leadGrp = type(g.lead) == "table" and g.lead.grp or nil,
        leadHow = type(g.lead) == "table" and g.lead.how or nil }
end
K.goalView = goalView
-- one action on one goal: set / relapse / clean (dry long enough) / gone (their person died some other way)
function K.storyAct(args, player)
    if type(args) ~= "table" or not K.on("questStory") then return nil, "off" end
    local uid = args.uid
    if type(uid) ~= "string" and type(uid) ~= "number" then return nil, "uid" end
    uid = tostring(uid)
    if K.record(uid) == nil then return nil, "nobody" end
    local s = K.store()
    s.goals = type(s.goals) == "table" and s.goals or {}
    local g = K.goalOf(uid)
    local act = tostring(args.act or "")
    local now = K.hours()
    if act == "set" then
        local k = tostring(args.k or "")
        if not K.STORY_KINDS[k] then return g, "kind" end
        if g ~= nil and g.done == nil and g.outcome == nil then return g, "has" end -- one story at a time; theirs stays
        local t = nil
        if not cleanish(k) then
            if type(args.t) ~= "string" and type(args.t) ~= "number" then return g, "target" end
            t = tostring(args.t)
            if t == uid or K.record(t) == nil then return g, "target" end
        end
        g = { k = k, t = t, tn = type(args.tn) == "string" and string.sub(args.tn, 1, 60) or nil, h = now }
        s.goals[uid] = g
        return g, "set"
    end
    if g == nil then return nil, "none" end
    if act == "relapse" then
        if not cleanish(g.k) then return g, "kind" end
        g.relapseH = now
        if g.outcome == "clean" then g.outcome, g.done = "relapsed", now
        else g.dryH = nil end
        return g, "relapse"
    end
    if g.done ~= nil or g.outcome ~= nil then return g, "done" end
    if act == "clean" then
        if not cleanish(g.k) or g.dryH == nil or num(g.relapseH, -1) >= num(g.dryH, 0) then return g, "notdry" end
        if now - num(g.dryH, now) < num(K.setting("questCleanDays"), 7) * 24 then return g, "early" end
        g.done, g.outcome = now, "clean"
        return g, "clean"
    end
    if act == "warn" then return K.storyWarn(g, args, player, now) end
    if act == "gone" then
        if g.k ~= "revenge" and g.k ~= "amends" and g.k ~= "family" and g.k ~= "prodigal" then return g, "kind" end
        if not dead(K.record(g.t)) then return g, "alive" end
        g.done, g.outcome = now, (g.k == "family" or g.k == "prodigal") and "grave" or "gone" -- 0.9.1: kin dead = a grave to find
        return g, g.outcome
    end
    if act == "lead" then return K.storyLead(g, uid, now) end
    if act == "stall" then return K.storyStall(g, uid, now) end
    return g, "act"
end
-- 0.9.1 EVERY STORY ENDS. A lead: where their person really is now (their real position and group, from A-Life),
-- heard a believable way (a rumor, a trader, the radio). Only for a living person; storyLeadDays in, storyLeadGap apart.
K.LEAD_HOW = { "a rumor", "a trader passing through", "the radio" }
function K.storyLead(g, uid, now)
    if g.k ~= "family" and g.k ~= "amends" and g.k ~= "revenge" and g.k ~= "prodigal" then return g, "kind" end
    if now - num(g.h, now) < num(K.setting("storyLeadDays"), 2) * 24 then return g, "early" end
    if type(g.lead) == "table" and now - num(g.lead.h, 0) < num(K.setting("storyLeadGap"), 3) * 24 then return g, "early" end
    local tr = K.record(g.t)
    if dead(tr) then return g, "dead" end
    local x, y = shellPos(g.t)
    if x == nil then x, y = posOf(tr) end
    if x == nil then return g, "where" end
    local grp = nil
    local pa = PA()
    pcall(function() local f = pa.Catalog.faction(mem(tr).groupId); grp = type(f) == "table" and type(f.general) == "table" and f.general.name or nil end) -- as FactionRep reads it
    g.lead = { h = now, x = math.floor(x), y = math.floor(y), grp = grp and string.sub(tostring(grp), 1, 40) or nil,
        how = K.LEAD_HOW[(hash(tostring(uid) .. ":" .. math.floor(now)) % #K.LEAD_HOW) + 1], n = num(g.lead and g.lead.n, 0) + 1 }
    return g, "lead"
end
-- nothing moved for storyStallDays: it ends itself. Calm people let it go; hot ones turn bitter (temperament, A-Life Speech).
K.STALL_CALM = { fresh = true, seasoned = true } -- A-Life Speech temperaments: fresh, seasoned, veteran, predator
function K.storyStall(g, uid, now)
    if now - num(g.h, now) < num(K.setting("storyStallDays"), 30) * 24 then return g, "early" end
    if cleanish(g.k) and g.dryH ~= nil then return g, "trying" end
    local t = nil
    pcall(function() t = PA().Speech.contextFor(K.record(uid), nil).temperament end)
    local calm = K.STALL_CALM[tostring(t or "")] == true or (t == nil and hash(uid .. "#stall") % 2 == 0)
    g.done, g.outcome = now, calm and "letgo" or "bitter"
    return g, g.outcome
end

-- 0.8.8 stand in the way: you told the one they want dead. Checked here: their goal is revenge on exactly that person,
-- who is alive and within storyWarnReach of you. Their people near the one you warned saw it (they find out for sure);
-- else a storyWarnLeak % roll (word gets round). The client turns it into feelings and opinions.
function K.storyWarn(g, args, player, now)
    if not K.on("storyWarn") then return g, "off" end
    if g.k ~= "revenge" or g.t == nil then return g, "kind" end
    if tostring(args.to or "") ~= tostring(g.t) then return g, "target" end
    local tr = K.record(g.t)
    if dead(tr) then return g, "alive" end
    local tx, ty = shellPos(g.t)
    if tx == nil then tx, ty = posOf(tr) end
    local px, py = num(call(player, "getX"), nil), num(call(player, "getY"), nil)
    if tx == nil or px == nil then return g, "where" end
    if d(px, py, tx, ty) > num(K.setting("storyWarnReach"), 6) then return g, "far" end
    local giver = K.record(args.uid)
    local seen = #K.witnesses(mem(giver).groupId, tx, ty, 15) > 0
    local leak = seen or (hash(tostring(args.uid) .. ":" .. tostring(g.t) .. ":" .. math.floor(now)) % 100) < num(K.setting("storyWarnLeak"), 30)
    g.done, g.outcome, g.leak = now, "warned", leak or nil
    K.metrics.warned = (K.metrics.warned or 0) + 1
    return g, "warned"
end

function K.storyReply(player, uids)
    local out, n = {}, 0
    for _, uid in ipairs(type(uids) == "table" and uids or {}) do
        if n >= 30 then break end
        if type(uid) == "string" or type(uid) == "number" then
            n = n + 1
            out[tostring(uid)] = goalView(K.goalOf(uid)) or false
        end
    end
    ALifeCmd.reply(player, "storyGoals", { goals = out })
end
if type(ALifeCmd) == "table" and type(ALifeCmd.onServer) == "function" then
    ALifeCmd.onServer("storyGoal", function(player, args)
        local _, why = K.storyAct(args, player)
        K.storyReply(player, { args.uid })
        return why
    end)
    ALifeCmd.onServer("storyPull", function(player, args)
        K.storyReply(player, type(args) == "table" and args.uids or nil)
    end)
end

-- getting clean: they hand you every bottle they carry (real ones); none = nothing to hold
function K.bottlesFromGiver(Board, rowDef, record, shell, player)
    local entry = Board.entry(player)
    local offer = type(entry) == "table" and entry.offer or nil
    if type(offer) ~= "table" or offer.task ~= "story_clean" or type(record) ~= "table" or offer.giver ~= record.uid then return false end
    local inv, pinv = call(shell, "getInventory"), call(player, "getInventory")
    if inv == nil or pinv == nil then return true end
    local picks = {}
    for _, t in ipairs(K.DRINK) do
        local list = call(inv, "getAllTypeRecurse", t)
        for i = 0, num(call(list, "size"), 0) - 1 do picks[#picks + 1] = call(list, "get", i) end
    end
    if #picks == 0 then return true end
    local n = 0
    for _, it in ipairs(picks) do
        if K.move(it, call(it, "getContainer") or inv, pinv) then n = n + 1 end
    end
    if n == 0 then return true end
    K.lastKeepN = n
    return false
end

-- true = they can't give you what the job needs carried
function K.carryFromGiver(Board, rowDef, record, shell, player)
    local entry = Board.entry(player)
    local offer = type(entry) == "table" and entry.offer or nil
    if type(offer) ~= "table" or type(record) ~= "table" or offer.giver ~= record.uid then return false end
    local def = Data.byId[offer.task]
    local style = type(rowDef) == "table" and rowDef.style or nil
    local p = def and style and def.paths[style] or nil
    if p == nil or p.carry == nil then return false end
    local inv, pinv = call(shell, "getInventory"), call(player, "getInventory")
    if inv == nil or pinv == nil then return true end
    local picks = {}
    for _, c in ipairs(p.carry) do
        local list = call(inv, "getAllTypeRecurse", c[1])
        local have = num(call(list, "size"), 0)
        if have < (c[2] or 1) then return true end
        for i = 0, (c[2] or 1) - 1 do picks[#picks + 1] = call(list, "get", i) end
    end
    for _, it in ipairs(picks) do
        local from = call(it, "getContainer") or inv
        if K.move(it, from, pinv) then K.metrics.carried = K.metrics.carried + 1 end
    end
    return false
end

function K.afterReward(player, job, def, record, style)
    local pa = PA()
    local Board = pa.TaskBoard
    local W = Board.world
    local title = def and def.title or "Task"
    -- the truth about someone they lost
    if type(job) == "table" and job.alcpFate ~= nil and record ~= nil then
        local s = K.store()
        s.fates[tostring(record.uid)] = { t = job.alcpT, n = job.name, f = job.alcpFate, h = K.hours() }
        K.metrics.found = K.metrics.found + 1
        if fn(W, "event") then pcall(W.event, player, "updated", title, "You told them: " .. tostring(job.name) .. " " .. tostring(job.alcpFateText or "")) end
        -- found with another group: their people may ask you to bring them back (group quest)
        if job.alcpFate == "joined" and K.on("questChains") then
            s.chains = type(s.chains) == "table" and s.chains or {}
            s.chains[tostring(mem(record).groupId or record.uid)] = { t = job.alcpT, n = job.name, h = K.hours(), from = tostring(record.uid) }
        end
    end
    if type(def) == "table" and type(def.alcp) == "table" and def.alcp.story ~= nil and record ~= nil then
        local g = K.goalOf(record.uid)
        if g ~= nil and g.outcome ~= "warned" then
            g.done, g.outcome, g.fate = K.hours(), "helped", job.alcpFate
            if cleanish(g.k) then g.dryH = K.hours(); g.done = nil; g.held = (tonumber(g.held) or 0) + 1 end
        end
    end
    if type(job) == "table" and job.id == "bring_back" then
        local s = K.store()
        if type(s.chains) == "table" then s.chains[tostring(mem(record or {}).groupId or (record and record.uid))] = nil end
    end
    if type(def) == "table" and type(def.alcp) == "table" and def.alcp.kind == "company" and record ~= nil then K.walk(player, record, true) end
    if job and job.auto == true or record == nil then return end
    local got = {}
    local shell = K.payShell or K.shellOf(record.uid)
    -- group jobs are paid from the group's own stash when it's there; else from the giver's pack
    if type(def) == "table" and type(def.alcp) == "table" and def.alcp.group then
        local c = K.groupStash(record)
        if c ~= nil then got = K.pay(nil, player, def, style, c) end
    end
    if #got == 0 and shell ~= nil then got = K.pay(shell, player, def, style) end
    if #got > 0 then
        K.metrics.paid = K.metrics.paid + 1
        K.metrics.paidItems = K.metrics.paidItems + #got
        if fn(W, "event") then pcall(W.event, player, "updated", title, "They gave you " .. table.concat(got, ", ")) end
        return
    end
    -- nothing to spare: they say so and owe you one
    K.metrics.owed = K.metrics.owed + 1
    local s = K.store()
    local key = "?"
    if fn(W, "playerKey") then local ok, k = pcall(W.playerKey, player); if ok and k ~= nil then key = tostring(k) end end
    local o = s.owed[tostring(record.uid)]
    if type(o) ~= "table" then o = {}; s.owed[tostring(record.uid)] = o end
    o[key] = (tonumber(o[key]) or 0) + 1
    if fn(W, "bump") then pcall(W.bump, record, player, 1, "They had nothing to pay you with") end
    if fn(W, "event") then pcall(W.event, player, "updated", title, "They had nothing to spare. They owe you one") end
end

K.OUR_STEPS = { seek = true, meet = true, escort = true, guard = true, handback = true, persuade = true, kill = true, steal = true, drive = true,
    reunite = true, keep = true }

local function progOf(job, index)
    local p = job.prog[index]
    if type(p) ~= "table" then p = {}; job.prog[index] = p end
    return p
end
-- keep someone walking with you while they're near (A-Life's walk-with lasts an hour)
local function keepWalking(player, uid, px, py, p, hours)
    local x, y = shellPos(uid)
    if x == nil or d(px, py, x, y) > 15 then return x, y end
    if hours >= (tonumber(p.walkAt) or 0) then
        local r = K.record(uid)
        local w = r and mem(r).walkWith or nil
        if type(w) ~= "table" or (tonumber(w.untilHours) or 0) - hours < 0.3 then K.walk(player, r) end
        p.walkAt = hours + 0.1
    end
    return x, y
end
local function bumpAll(list, player, delta, why)
    local W = PA() and PA().TaskBoard and PA().TaskBoard.world or nil
    if not fn(W, "bump") then return end
    for _, r in ipairs(list) do pcall(W.bump, r, player, delta, why) end
end

function K.stepOurs(job, step, index, pos, hours, player)
    local k = step.k
    if k == "seek" or k == "meet" then return K.stepPerson(job, step, index, pos, hours) end
    local site = job.sites[index]
    local px, py = pos.x, pos.y
    local p = progOf(job, index)
    local reachR = 7
    if k == "escort" or k == "guard" then
        local gx, gy = keepWalking(player, job.giver, px, py, p, hours)
        local close = gx ~= nil and d(px, py, gx, gy) <= 12
        if site == nil or not close then return false end
        if k == "escort" then return d(px, py, site.x, site.y) <= reachR end
        if d(px, py, site.x, site.y) > reachR * 2 then return false end
        local gap = hours - (tonumber(job.lastHours) or hours)
        if gap > 0 and gap < 0.2 then p.held = (tonumber(p.held) or 0) + gap end
        return (tonumber(p.held) or 0) >= (tonumber(step.hours) or 0.2)
    end
    if k == "handback" then
        local uid = job.alcpT
        local tx, ty = shellPos(uid)
        if heldUid(uid) and p.freed ~= true then
            if tx ~= nil and d(px, py, tx, ty) <= 6 then
                local C = PA().Captives
                if fn(C, "release") then pcall(C.release, tostring(uid), "handed_back") end
                p.freed = true
                K.walk(player, K.record(uid))
            end
            return false
        end
        p.freed = true
        tx, ty = keepWalking(player, uid, px, py, p, hours)
        if site == nil or tx == nil then return false end
        return d(tx, ty, site.x, site.y) <= 10
    end
    if k == "persuade" then
        local uid = job.alcpT
        local r = K.record(uid)
        local tx, ty = shellPos(uid)
        if r == nil or tx == nil or d(px, py, tx, ty) > 4 then return false end
        if K.opinion(r, player) >= num(K.setting("questPersuadeTrust"), 25) and K.walk(player, r) then return true end
        job.alcpWhy = tostring(job.name) .. " won't leave their new people"
        return false
    end
    if k == "reunite" then
        local uid = job.alcpT
        local r = K.record(uid)
        local gx, gy = keepWalking(player, job.giver, px, py, p, hours)
        if dead(r) then
            local rx, ry = posOf(r)
            if rx ~= nil and d(px, py, rx, ry) <= 10 then job.alcpFate, job.alcpFateText = "dead", "is dead"; return true end
            return false
        end
        local tx, ty = shellPos(uid)
        if tx ~= nil and site ~= nil and d(site.x, site.y, tx, ty) > 30 then site.x, site.y = math.floor(tx), math.floor(ty) end
        if tx == nil or gx == nil then return false end
        if d(gx, gy, tx, ty) <= 8 then job.alcpFate = "met"; return true end
        return false
    end
    if k == "keep" then
        local want = tonumber(job.alcpKeepN) or 1
        local inv = call(player, "getInventory")
        local have = 0
        for _, t in ipairs(K.DRINK) do
            local list = call(inv, "getAllTypeRecurse", t)
            have = have + num(call(list, "size"), 0)
        end
        if have < want then job.alcpWhy = "The bottles are gone. They know where to find more"; return false end
        return hours - (tonumber(job.startHours) or hours) >= (tonumber(step.hours) or 48)
    end
    if k == "kill" then
        local uid = job.alcpT
        local r = K.record(uid)
        local tx, ty = shellPos(uid)
        if tx ~= nil and d(px, py, tx, ty) <= 40 then p.nearAt = hours end
        if dead(r) then
            job.alcpByYou = hours - (tonumber(p.nearAt) or -99) < 0.1
            return true
        end
        if site ~= nil and tx ~= nil and d(site.x, site.y, tx, ty) > 30 then site.x, site.y = math.floor(tx), math.floor(ty) end
        return false
    end
    if k == "steal" then
        if site == nil or d(px, py, site.x, site.y) > 4 then return false end
        local h = K.haven(job.alcpHaven)
        local Hv = PA().Havens
        if h == nil or not fn(Hv, "containerAt") then return false end
        local ok, c = pcall(Hv.containerAt, h.depot)
        if not ok or c == nil then return false end
        local now = K.worthIn(c)
        if p.base == nil then p.base = now; return false end
        local want = math.max(10, K.payTarget(Data.byId[job.id] or {}, job.style or "soft"))
        if p.base - now < want then return false end
        local seen = K.witnesses(job.alcpGroup, px, py, 20)
        job.alcpSeen = #seen
        if #seen > 0 then bumpAll(seen, player, -num(K.setting("questWitnessCost"), 8), "Saw you rob their stash") end
        return true
    end
    if k == "drive" then
        local h = K.haven(job.alcpHaven)
        if site ~= nil and d(px, py, site.x, site.y) <= 40 then p.been = true end
        if h == nil or h.state ~= "active" then
            if p.been == true then return true end
            job.alcpWhy = "Someone else drove them out before you got there"
        end
        return false
    end
    return false
end

-- the person steps: seek (find out what happened) and meet (pass the word on)
function K.stepPerson(job, step, index, pos, hours)
    local uid = job.alcpT
    if uid == nil then return false end
    local r = K.record(uid)
    local site = job.sites[index]
    local px, py = pos.x, pos.y
    local x, y, shell = shellPos(uid)
    if x ~= nil and d(px, py, x, y) <= (step.k == "meet" and 4 or 5) then
        if step.k == "seek" then
            local giver = K.record(job.giver) or {}
            job.alcpFate, job.alcpFateText = K.fateOf(r or {}, giver)
        end
        if step.k == "meet" then K.metrics.met = K.metrics.met + 1 end
        return true
    end
    if step.k == "seek" and dead(r) then
        local rx, ry = posOf(r)
        if rx ~= nil and d(px, py, rx, ry) <= 10 then
            job.alcpFate, job.alcpFateText = "dead", "is dead"
            return true
        end
    end
    -- at the spot and they're not there: people around point you on (at most 4 times, roughly)
    if site ~= nil and d(px, py, site.x, site.y) <= 12 then
        local p = job.prog[index]
        if type(p) ~= "table" then p = {}; job.prog[index] = p end
        local hints = tonumber(p.hints) or 0
        if hints < 4 and hours >= (tonumber(p.hintAt) or 0) then
            local rx, ry = x, y
            if rx == nil then rx, ry = posOf(r) end
            if rx ~= nil and d(site.x, site.y, rx, ry) > 12 then
                local j = roll("hint:" .. tostring(uid) .. ":" .. hints)
                local off = hints < 3 and 20 or 0
                site.x, site.y = math.floor(rx + (j - 0.5) * 2 * off), math.floor(ry + (0.5 - j) * 2 * off)
                p.hints, p.hintAt = hints + 1, hours + 0.25
                K.metrics.hints = K.metrics.hints + 1
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------------- turn-in rows
-- A-Life puts `need = { taskDone = .. }` on the CHOICE of "*_turnin" trees; the engine only hides rows by tree.need.
-- Copy it up so the row shows only when that task is done (fixes turn-in rows shown to strangers with no task).
local function turnInNeed(tree)
    if type(tree) ~= "table" or type(tree.need) == "table" or tree.tab ~= "task" then return false end
    if string.sub(tostring(tree.id), -7) ~= "_turnin" then return false end
    local nodes = tree.nodes
    local start = type(nodes) == "table" and nodes["start"] or nil
    if type(start) ~= "table" then return false end
    for _, c in ipairs(start._choices or start.choices or {}) do
        if type(c) == "table" and type(c.need) == "table" and c.need.taskDone ~= nil then
            tree.need = { taskDone = c.need.taskDone }
            return true
        end
    end
    return false
end
function K.fixTurnIns()
    local pa = PA()
    local R = pa and pa.TreeRegistry
    if type(R) ~= "table" or type(R.trees) ~= "table" then return 0 end
    if type(R.finishIndex) == "function" and not K.turnInWrapped then
        K.turnInWrapped = true
        local old = R.finishIndex
        R.finishIndex = function(...)
            local r = old(...)
            pcall(K.fixTurnIns)
        pcall(K.hookMap)
            return r
        end
    end
    local n = 0
    for _, tree in ipairs(R.trees) do
        if turnInNeed(tree) then n = n + 1 end
    end
    if n > 0 then log("turn-in rows now need their task done: " .. tostring(n) .. " trees") end
    return n
end

-- ---------------------------------------------------------------------------------------------------- load
pcall(K.addData)
if type(Events) == "table" then
    local function start()
        pcall(function() local R = PA() and PA().TreeRegistry; if type(R) == "table" and type(R.ensure) == "function" then R.ensure() end end)
        pcall(K.fixTurnIns)
        local ok, n = pcall(K.install)
        if not ok then log("install failed: " .. tostring(n)); return end
        if K.ready then return end
        K.ready = true
        local fake = 0
        for _ in pairs(K.FAKE) do fake = fake + 1 end
        log("ready v" .. K.VERSION .. ": " .. tostring(n) .. "/" .. K.HOOKS .. " hooks on A-Life's task board (real pay "
            .. (K.on("questRealPay") and "on" or "off") .. ", spawns " .. (K.on("questNoSpawns") and "off" or "on")
            .. ", made-up gifts " .. (K.on("questNoGifts") and "off" or "on")
            .. ", real stores " .. (K.on("questRealPlaces") and "on" or "off") .. ", made-up tasks off: "
            .. (K.on("questFakeOff") and fake or 0) .. ", new tasks " .. tostring(#K.TASKS) .. ")")
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(start) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(start) end
end
return K
