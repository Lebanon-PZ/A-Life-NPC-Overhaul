-- A-Life NPC Overhaul 0.8.5: THE WALKIE. Calling one person by name, the way a real radio works.
--   * They need a two-way radio with charge in it (or a spare battery to swap in). Same for you. People of yours at
--     home can use the base's own set (Jeem's base radio) instead of a walkie of their own.
--   * Range: vanilla per-model TransmitRange; a call reaches if they are within the WEAKER radio's range.
--   * Channel: you must be tuned to their frequency. Your own people listen on "our channel" (set in game from the
--     Radio tab: the channel your walkie is on). Others' channels you learn when they agree to swap channels.
--   * Battery: their walkie drains only during calls (vanilla UseDelta per model, scaled by call length; engine:
--     DeviceData.setUseDelta(f) stores f/60, drained per game minute while on - read in 42.21). Standby drain is a
--     setting (default 0). A dead battery is swapped for a spare they carry (vanilla dd:getBattery / dd:addBattery);
--     no spare = they go silent.
--   * Who you can call by name: your own people (A-Life companions, residents of a base you run) by default; others
--     only after they agree to swap channels in talk (opinion >= walkieSwapTrust).
--   * Calls: check in, news, come here, need help (+ walkieHelpFriends nearby friends), need serious help (up to
--     walkieSeriousCount from their base). Real travel (Jeem's radio escort: real people, real road time). They can
--     refuse (too far, scared, busy).
--   * They call you: base check-ins when you haven't been home for walkieCheckinH game hours; instant alerts (base
--     under attack, someone hurt or bitten). A check-in you miss is remembered (0.8.5 capture: a missed check-in is
--     how your people find out something is wrong).
--   * Overhearing: hostiles with a walkie on your channel and in range hear your calls (the client adds groups that
--     scan the band). Base mentioned -> they learn where it is.
-- Server-authoritative (MP rule 1-6): the client sends { uid, kind, ch, on, power, range }; a multiplayer server's copy
-- of an item in a player's inventory doesn't follow its switch or battery (Jeem's note, Residents/Radio.lua), so
-- there the client's report is used for on / power / channel; range comes from the item type on both sides.
require "ALifeNPCOverhaul/ALifeCmd"

ALifeWalkie = ALifeWalkie or {}
local W = ALifeWalkie
local TAG = "[ALifeWalkie]"
W.VERSION = "0.8.5"
W.metrics = W.metrics or { calls = 0, reached = 0, refused = 0, drained = 0, swapped = 0, silent = 0, overheard = 0,
    checkins = 0, alerts = 0, missed = 0, swaps = 0 }

W.DEFAULTS = {
    walkie = true,              -- calling one person by name over the radio
    walkieNpcRadio = true,      -- they need a two-way radio with charge (or a spare battery) to answer
    walkieBaseSet = true,       -- your people at home can answer on the base's own radio (Jeem's base radio)
    walkieCallMin = 3,          -- game minutes a call lasts (battery drain)
    walkieDrainScale = 1,       -- x vanilla UseDelta during a call (1 = the radio's own drain)
    walkieStandby = 0,          -- x vanilla UseDelta per game hour while they carry it switched on (0 = off)
    walkieOwn = true,           -- your own people can be called by name without swapping channels first
    walkieSwapTrust = 30,       -- how much someone must like you to swap channels
    walkieHelpFriends = 2,      -- "need help": that person plus up to this many friends from home
    walkieSeriousCount = 4,     -- "need serious help": up to this many from their base
    walkieFarTiles = 3000,      -- further than this, people who don't like you much say it's too far
    walkieFarTrust = 60,        -- ... unless they like you this much
    walkieCheckinH = 8,         -- base people call you when you haven't been home this many game hours (0 = never)
    walkieAlerts = true,        -- instant alerts: base under attack, someone hurt or bitten
    walkieOverhear = true,      -- hostiles on your channel and in range can hear your calls
    walkieScanChance = 15,      -- % a hostile group with a radio in range happens to be scanning your channel
    walkieRaidBump = 35,        -- % a hostile group that heard where your base is sends people sooner
    walkieAmbush = 30,          -- % a hostile group that heard "come here" goes for the meetup
}
W.FILE_KEYS = {}
for k in pairs(W.DEFAULTS) do W.FILE_KEYS[#W.FILE_KEYS + 1] = k end
table.sort(W.FILE_KEYS)

W.KINDS = { checkin = true, news = true, come = true, help = true, serious = true, talk = true }
W.BASE_KINDS = { checkin = true, come = true, help = true, serious = true } -- calls that give away where home is

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function RA() local j = J(); return j and j.Residents and j.Residents.radio or nil end

function W.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = W.DEFAULTS[key] end
    return v
end
function W.on() return W.setting("walkie") ~= false end

function W.hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return num(h, 0)
end
function W.isMP() return type(isClient) == "function" and type(isServer) == "function" and (isClient() or isServer()) end

-- ---------------------------------------------------------------------------------------------------- devices
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
W.call = call

-- facts of one inventory item if it is a two-way radio, else nil
function W.factsOf(item)
    if item == nil then return nil end
    local dd = item.getDeviceData ~= nil and call(item, "getDeviceData") or nil
    if dd == nil or call(dd, "getIsTwoWay") ~= true then return nil end
    local range = num(call(dd, "getTransmitRange"), 0)
    if range <= 0 then return nil end
    local battery = call(dd, "getIsBatteryPowered") == true
    local power = battery and num(call(dd, "getPower"), 0) or 1
    if battery and call(dd, "getHasBattery") ~= true then power = 0 end
    return { item = item, dd = dd, t = tostring(call(item, "getFullType") or "?"), r = range, u = num(call(dd, "getUseDelta"), 0),
        p = power, c = num(call(dd, "getChannel"), 0), on = call(dd, "getIsTurnedOn") == true, battery = battery,
        id = call(item, "getID") }
end

-- walk a character's things (hands, belt, inventory, one level of bags): fnv(item) -> true stops
local function eachItem(who, visit)
    local function try(it) if it ~= nil and visit(it) then error("ALCP_STOP") end end
    local ok, err = pcall(function()
        try(call(who, "getPrimaryHandItem"))
        try(call(who, "getSecondaryHandItem"))
        local att = call(who, "getAttachedItems")
        local n = num(call(att, "size"), 0)
        for i = 0, n - 1 do local a = att:get(i); try(call(a, "getItem")) end
        local inv = call(who, "getInventory")
        local items = call(inv, "getItems")
        local m = num(call(items, "size"), 0)
        for i = 0, math.min(m, 400) - 1 do
            local it = items:get(i)
            try(it)
            local sub = it ~= nil and it.getInventory ~= nil and call(it, "getInventory") or nil
            local inner = call(sub, "getItems")
            local k = num(call(inner, "size"), 0)
            for j = 0, math.min(k, 200) - 1 do try(inner:get(j)) end
        end
    end)
    if not ok and not string.find(tostring(err), "ALCP_STOP", 1, true) then return false end
    return true
end

-- their best radio (on and powered first, then the longest range) and their spare batteries ({ item, charge })
function W.scan(who)
    local best, spares = nil, {}
    eachItem(who, function(it)
        local f = W.factsOf(it)
        if f ~= nil then
            local score = (f.p > 0 and 2 or 0) + (f.on and 1 or 0) + f.r / 100000
            if best == nil or score > best.score then f.score = score; best = f end
        elseif tostring(call(it, "getFullType")) == "Base.Battery" then
            spares[#spares + 1] = { item = it, charge = num(call(it, "getCurrentUsesFloat"), 0) }
        end
        return false
    end)
    table.sort(spares, function(a, b) return a.charge > b.charge end)
    return best, spares
end

-- ---------------------------------------------------------------------------------------------------- the ledger
-- Global ModData (server): npc[uid] = { t, r, u (per game minute), p, c, s = { spare charges }, at }, base[pkey] = channel,
-- contacts[pkey][uid] = { c, at }, seen[pkey] = hours you were last home, missed[pkey] = { n, lastH }, told[pkey] = { ... }
function W.store()
    local d = nil
    if ModData ~= nil and fn(ModData, "getOrCreate") then
        local ok, t = pcall(ModData.getOrCreate, "ALifeChatPlus_Walkie")
        if ok then d = t end
    end
    if d == nil then W._mem = W._mem or {}; d = W._mem end
    for _, k in ipairs({ "npc", "base", "contacts", "seen", "missed", "told", "heard" }) do
        if type(d[k]) ~= "table" then d[k] = {} end
    end
    return d
end

function W.keyOf(player)
    local pa = PA()
    if player ~= nil and pa ~= nil and fn(pa.Speech, "playerKey") then
        local ok, k = pcall(pa.Speech.playerKey, player)
        if ok and k ~= nil then return tostring(k) end
    end
    return "local"
end

function W.record(uid)
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    if ok and type(r) == "table" then return r end
    return nil
end
function W.shell(uid)
    local pa = PA()
    if pa == nil then return nil end
    if fn(pa.Talk, "shellFor") then
        local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
        if ok and s ~= nil then return s end
    end
    local wd = pa.Watchdog
    local b = type(wd) == "table" and type(wd.bindings) == "table" and wd.bindings[tostring(uid)] or nil
    return type(b) == "table" and b.shell or nil
end
function W.posOf(uid, record)
    local s = W.shell(uid)
    if s ~= nil then
        local x, y = call(s, "getX"), call(s, "getY")
        if x ~= nil then return num(x, 0), num(y, 0), true end
    end
    record = record or W.record(uid)
    local p = type(record) == "table" and record.worldPosition or nil
    if type(p) == "table" and tonumber(p.x) ~= nil then return num(p.x, 0), num(p.y, 0), false end
    return nil
end
function W.nameOf(record)
    local pa = PA()
    if pa ~= nil and fn(pa.Names, "of") then
        local ok, n = pcall(pa.Names.of, record)
        if ok and n ~= nil then return tostring(n) end
    end
    return "Someone"
end

-- their radio on paper: refreshed from the real item while they are loaded, kept while they are not
function W.npcRow(uid)
    local st = W.store()
    uid = tostring(uid)
    local row = st.npc[uid]
    local shell = W.shell(uid)
    if shell ~= nil then
        local best, spares = W.scan(shell)
        if best == nil then
            st.npc[uid] = nil
            return nil
        end
        row = row or {}
        row.t, row.r, row.u, row.p, row.c, row.at = best.t, best.r, best.u, best.p, best.c, W.hours()
        row.s = {}
        for i = 1, math.min(#spares, 6) do row.s[i] = spares[i].charge end
        st.npc[uid] = row
        return row, best, spares, shell
    end
    return row
end

-- your people follow "our channel": a loaded one's walkie is retuned to it (they know the camp's channel)
function W.retune(uid, best, ch)
    if best == nil or tonumber(ch) == nil or best.c == ch then return false end
    call(best.dd, "setChannel", ch)
    best.c = ch
    local row = W.store().npc[tostring(uid)]
    if row ~= nil then row.c = ch end
    return true
end

-- a call's drain on their radio; a dead battery is swapped for a spare (real items while loaded, on paper while not).
-- returns the power left
function W.drain(uid, minutes)
    uid = tostring(uid)
    local row, best, spares, shell = W.npcRow(uid)
    if row == nil then return 0 end
    local used = num(row.u, 0) * math.max(0, num(minutes, 0)) * math.max(0, num(W.setting("walkieDrainScale"), 1))
    row.p = math.max(0, num(row.p, 0) - used)
    if best ~= nil and best.battery then call(best.dd, "setPower", row.p) end
    W.metrics.drained = W.metrics.drained + 1
    if row.p <= 0 then W.swap(uid, row, best, spares, shell) end
    return row.p
end

function W.swap(uid, row, best, spares, shell)
    if best ~= nil and shell ~= nil and type(spares) == "table" and spares[1] ~= nil and spares[1].charge > 0 then
        local inv = call(shell, "getInventory")
        call(best.dd, "getBattery", inv)          -- the dead one comes out as a real battery item
        call(best.dd, "addBattery", spares[1].item) -- the spare goes in (removed from their bag by the engine)
        row.p = num(call(best.dd, "getPower"), spares[1].charge)
        table.remove(row.s or {}, 1)
        W.metrics.swapped = W.metrics.swapped + 1
        return true
    end
    if best == nil and type(row.s) == "table" and num(row.s[1], 0) > 0 then
        row.p = num(table.remove(row.s, 1), 0)
        W.metrics.swapped = W.metrics.swapped + 1
        return true
    end
    return false
end

-- standby drain while carried switched on (setting; default off)
function W.standby(dtHours)
    local k = num(W.setting("walkieStandby"), 0)
    if k <= 0 then return 0 end
    local n = 0
    for uid, row in pairs(W.store().npc) do
        if type(row) == "table" and num(row.p, 0) > 0 then
            row.p = math.max(0, num(row.p, 0) - num(row.u, 0) * 60 * dtHours * k)
            if row.p <= 0 then W.swap(uid, row, nil, nil, nil) end
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------------- whose people
local function companionOwner(record)
    local pa = PA()
    local C = pa and pa.Companions or nil
    if not fn(C, "entry") then return nil end
    local ok, e = pcall(C.entry, record)
    return ok and type(e) == "table" and e.owner or nil
end
function W.residentBase(record)
    local m = type(record) == "table" and record.memory or nil
    return type(m) == "table" and type(m.jimmyResident) == "table" and m.jimmyResident.baseId or nil
end
-- the Jeem base this player runs that this record lives at (nil if none)
function W.ownBase(player, record)
    local j = J()
    local B = j and j.BaseAreas
    local id = W.residentBase(record)
    if id == nil or not fn(B, "base") or not fn(B, "who") then return nil end
    local base = B.base(id)
    if base == nil then return nil end
    local who = B.who(player)
    if fn(B, "canManage") and not B.canManage(base, who.key, who.faction, who.admin) then return nil end
    return base
end
function W.isOwn(player, uid, record)
    record = record or W.record(uid)
    if record == nil then return false end
    local mine = ALifeCommands
    if fn(mine, "isMine") then
        local ok, yes = pcall(mine.isMine, tostring(uid), player)
        if ok and yes then return true end
    elseif companionOwner(record) ~= nil and companionOwner(record) == W.keyOf(player) then
        return true
    end
    return W.ownBase(player, record) ~= nil
end
function W.atHome(record, base)
    local j = J()
    local R = j and j.Residents
    if base == nil or not fn(R, "atHome") then return false, {} end
    local home = R.atHome(base.id) or {}
    for _, r in ipairs(home) do if tostring(r.uid) == tostring(record.uid) then return true, home end end
    return false, home
end

function W.opinion(record, player)
    local pa = PA()
    local O = pa and pa.NpcOpinion or nil
    if not fn(O, "valueOf") then return 0 end
    local ok, v = pcall(O.valueOf, record, player)
    return ok and num(v, 0) or 0
end

-- the channel they listen on for you, or nil (not a contact)
function W.contactChannel(player, uid, record, row)
    local st, pkey = W.store(), W.keyOf(player)
    if W.setting("walkieOwn") ~= false and W.isOwn(player, uid, record) then return st.base[pkey] or (row and row.c), "own" end
    local c = type(st.contacts[pkey]) == "table" and st.contacts[pkey][tostring(uid)] or nil
    if type(c) == "table" then return (row and row.c) or c.c, "swapped" end
    return nil, "not_contact"
end

-- ---------------------------------------------------------------------------------------------------- can it reach?
-- facts: the client's report of your radio { on, power, ch, range }. Returns ok, why, info
-- why: off / no_power / no_radio (yours) / not_contact / their_none / their_dead / wrong_channel / out_of_range / dead
function W.reach(player, uid, facts)
    facts = type(facts) == "table" and facts or {}
    local record = W.record(uid)
    if record == nil then return false, "unknown" end
    if record.lifecycle == "dead" then return false, "dead" end
    if facts.range == nil or num(facts.range, 0) <= 0 then return false, "no_radio" end
    if facts.on == false then return false, "off" end
    if num(facts.power, 1) <= 0 then return false, "no_power" end
    local row, best, spares, shell = W.npcRow(uid)
    local ch, how = W.contactChannel(player, uid, record, row)
    if ch == nil and how == "not_contact" then return false, "not_contact" end
    local px, py = num(facts.x, nil), num(facts.y, nil)
    if px == nil then px, py = num(call(player, "getX"), 0), num(call(player, "getY"), 0) end
    local nx, ny = W.posOf(uid, record)
    local info = { record = record, row = row, best = best, how = how, ch = ch }
    -- at home, your people answer on the base's own set (Jeem)
    local base = how == "own" and W.setting("walkieBaseSet") ~= false and W.ownBase(player, record) or nil
    if base ~= nil then
        local home, list = W.atHome(record, base)
        local ra = RA()
        if home and ra ~= nil and fn(ra, "link") then
            local ok, d = ra.link(base, num(facts.range, 0), px, py, list)
            info.base, info.home, info.d = base, list, d
            if not ok then return false, "out_of_range", info end
            local bch = W.store().base[W.keyOf(player)] -- the base set listens on "our channel" (unset: the first call sets it)
            info.ch = bch
            if bch ~= nil and num(facts.ch, -1) ~= num(bch, -2) then return false, "wrong_channel", info end
            info.via = "base"
            return true, nil, info
        end
    end
    if W.setting("walkieNpcRadio") ~= false then
        if row == nil then return false, "their_none", info end
        if num(row.p, 0) <= 0 and not W.swap(uid, row, best, spares, shell) then W.metrics.silent = W.metrics.silent + 1; return false, "their_dead", info end
        if how == "own" and info.ch ~= nil and best ~= nil then W.retune(uid, best, info.ch) end
        if info.ch == nil then info.ch = row.c end
    end
    if nx == nil then return false, "out_of_range", info end
    local d = math.sqrt((nx - px) ^ 2 + (ny - py) ^ 2)
    local reach = math.min(num(facts.range, 0), row ~= nil and num(row.r, 0) or num(facts.range, 0))
    info.d, info.reach = d, reach
    if d > reach then return false, "out_of_range", info end
    if info.ch ~= nil and num(facts.ch, -1) ~= num(info.ch, -2) then return false, "wrong_channel", info end
    info.via = "walkie"
    return true, nil, info
end

-- ---------------------------------------------------------------------------------------------------- lines
-- fixed walkie lines (AI off, or the AI is late). The client may re-voice them.
W.LINES = {
    checkin_ok = { "%s here. All quiet. Over.", "%s. Doing fine out here. Over.", "This is %s. Nothing to report. Over." },
    checkin_hurt = { "%s here. I'm hurt, but I'm moving. Over.", "%s. Took a hit. I'll live. Over." },
    news_none = { "%s. Nothing new on my end. Over.", "%s here. Quiet day. Over." },
    news = { "%s. Heard something: %s Over." },
    come = { "%s. Copy. On my way. Over.", "Copy that, %s coming to you. Over." },
    help = { "%s. Copy. Bringing people. Hold on. Over.", "Hang tight, %s's coming with help. Over." },
    serious = { "%s. Copy. Everyone who can carry a gun is coming. Over.", "%s. We're coming in force. Hold out. Over." },
    far = { "%s. That's too far out for me. Sorry. Over.", "%s. I can't make it that far. Over." },
    scared = { "%s. No. Not out there. I'm sorry. Over.", "%s. I can't. Not now. Over." },
    busy = { "%s. Can't, I'm tied up here. Over.", "%s. Negative, I'm busy. Over." },
    cant = { "%s. Can't come right now. Over." },
    swap_yes = { "Sure. I'm on %s. Call if you need me." },
    swap_no = { "I don't know you well enough for that.", "My channel stays mine." },
    swap_none = { "I don't even have a radio.", "Got nothing to call you on." },
}
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
function W.line(key, ...)
    local l = W.LINES[key]
    if type(l) ~= "table" then return nil end
    local ok, s = pcall(string.format, pick(l), ...)
    return ok and s or pick(l)
end

-- ---------------------------------------------------------------------------------------------------- the call
local function refuses(player, record, info, kind)
    if kind ~= "come" and kind ~= "help" and kind ~= "serious" then return nil end
    if record.activity == "combat" then return "busy" end
    if record.activity == "flee" or record.activity == "panic" then return "scared" end
    local O = ALifeOrders
    if fn(O, "willing") then
        local ok, no = pcall(O.willing, record, player)
        if ok and no ~= nil then return (no == "scared" or no == "afraid") and "scared" or "busy" end
    end
    if info.d ~= nil and info.d > num(W.setting("walkieFarTiles"), 3000) and W.opinion(record, player) < num(W.setting("walkieFarTrust"), 60) then
        return "far"
    end
    return nil
end

-- send people: Jeem's radio escort (real people, real road time) for base people; A-Life's follow for your party
local function dispatch(player, record, info, kind)
    local uid = tostring(record.uid)
    local ra = RA()
    if info.base ~= nil and ra ~= nil and fn(ra, "come") then
        local lines, n = {}, 0
        local nowH = W.hours()
        local okA, a = pcall(ra.come, player, info.base, { uid = uid }, info.d, nowH)
        if okA and type(a) == "table" then for _, l in ipairs(a) do lines[#lines + 1] = l end; n = 1 end
        local more = kind == "help" and num(W.setting("walkieHelpFriends"), 2) or (kind == "serious" and num(W.setting("walkieSeriousCount"), 4) - 1 or 0)
        if more > 0 then
            local okB, b = pcall(ra.come, player, info.base, { count = more }, info.d, nowH)
            if okB and type(b) == "table" then for _, l in ipairs(b) do lines[#lines + 1] = l end end
        end
        return n > 0, lines
    end
    local pa = PA()
    local C = pa and pa.Companions
    if fn(C, "order") then
        local px, py, pz = num(call(player, "getX"), 0), num(call(player, "getY"), 0), num(call(player, "getZ"), 0)
        local ok = pcall(C.order, player, { order = "follow", uid = uid, x = px, y = py, z = pz })
        if ok then return true, {} end
    end
    return false, {}
end

-- hostiles on paper who hear it: a walkie on that channel, powered, in range, hostile to you
function W.listeners(player, ch, px, py, range)
    local out = {}
    if W.setting("walkieOverhear") == false or ch == nil then return out end
    local pa = PA()
    local Rel = pa and pa.Relations
    -- people loaded near you: their real radios first (a hostile's walkie is only on paper once we've looked)
    if pa ~= nil and fn(pa.ActorRegistry, "each") then
        local reach2 = num(range, 0) ^ 2
        pa.ActorRegistry.each(function(rec)
            if type(rec) == "table" and rec.lifecycle == "active" and W.shell(rec.uid) ~= nil then
                local nx, ny = W.posOf(rec.uid, rec)
                if nx ~= nil and (nx - px) ^ 2 + (ny - py) ^ 2 <= reach2 then W.npcRow(rec.uid) end
            end
            return false
        end)
    end
    for uid, row in pairs(W.store().npc) do
        if type(row) == "table" and num(row.c, -1) == num(ch, -2) and num(row.p, 0) > 0 then
            local rec = W.record(uid)
            local nx, ny = W.posOf(uid, rec)
            if rec ~= nil and rec.lifecycle ~= "dead" and nx ~= nil and not W.isOwn(player, uid, rec)
                    and (nx - px) ^ 2 + (ny - py) ^ 2 <= math.min(num(range, 0), num(row.r, 0)) ^ 2 then
                local hostile = false
                if fn(Rel, "hostileToPlayer") then local ok, h = pcall(Rel.hostileToPlayer, rec, player); hostile = ok and h == true end
                if hostile then
                    local m = type(rec.memory) == "table" and rec.memory or {}
                    out[#out + 1] = { uid = tostring(uid), home = m.havenId and tostring(m.havenId) or nil }
                end
            end
        end
    end
    return out
end

-- { uid, kind, ch, on, power, range, x, y, text }
function W.serverCall(player, args)
    if type(args) ~= "table" or type(args.uid) ~= "string" or not W.KINDS[args.kind] then return nil end
    W.metrics.calls = W.metrics.calls + 1
    local res = { uid = args.uid, kind = args.kind, ok = false, lines = {} }
    if not W.on() then res.why = "off_setting"; return res end
    local ok, why, info = W.reach(player, args.uid, args)
    info = info or {}
    local record = info.record
    res.name = record and W.nameOf(record) or "Someone"
    if not ok then
        W.metrics.refused = W.metrics.refused + 1
        res.why = why
        return res
    end
    W.metrics.reached = W.metrics.reached + 1
    res.ok, res.via, res.reached = true, info.via, true
    if info.via == "walkie" then W.drain(args.uid, num(W.setting("walkieCallMin"), 3)) end
    -- first call to your own people with no channel set: they take yours
    local st, pkey = W.store(), W.keyOf(player)
    if info.how == "own" and st.base[pkey] == nil and tonumber(args.ch) ~= nil then st.base[pkey] = num(args.ch, 0); res.setChannel = st.base[pkey] end
    local kind = args.kind
    local name = res.name
    if kind == "checkin" then
        local ra = RA()
        if info.base ~= nil and ra ~= nil and fn(ra, "status") then
            local okS, lines = pcall(ra.status, info.base, W.hours())
            if okS and type(lines) == "table" then res.lines = lines end
        else
            local m = type(record.memory) == "table" and record.memory or {}
            local s = type(m.shellState) == "table" and m.shellState or {}
            local hurt = tonumber(s.health) ~= nil and tonumber(s.health) < 0.6 * num(s.maximumHealth, 1)
            res.lines = { W.line(hurt and "checkin_hurt" or "checkin_ok", name) }
            res.hurt = hurt
        end
    elseif kind == "news" then
        local rs = PA() and PA().RadioTalkServer
        local text = nil
        if fn(rs, "rumor") then local okR, t = pcall(rs.rumor); if okR and type(t) == "string" then text = t end end
        res.lines = { text and W.line("news", name, text) or W.line("news_none", name) }
        res.news = text
    elseif kind == "come" or kind == "help" or kind == "serious" then
        local no = refuses(player, record, info, kind)
        if no ~= nil then
            res.ok, res.why = false, no
            res.lines = { W.line(no, name) }
        else
            local sent, lines = dispatch(player, record, info, kind)
            if sent then
                res.lines = { W.line(kind, name) }
                for _, l in ipairs(lines) do res.lines[#res.lines + 1] = l end
                res.coming = true
            else
                res.ok, res.why = false, "cant"
                res.lines = { W.line("cant", name) }
            end
        end
    end
    -- who else heard it (hostiles with a walkie on your channel)
    local px, py = num(args.x, nil), num(args.y, nil)
    if px == nil then px, py = num(call(player, "getX"), 0), num(call(player, "getY"), 0) end
    local heard = W.listeners(player, num(args.ch, nil), px, py, num(args.range, 0))
    if #heard > 0 then
        W.metrics.overheard = W.metrics.overheard + #heard
        res.heardBy = heard
        res.baseMentioned = W.BASE_KINDS[kind] == true or (type(args.text) == "string" and W.mentionsBase(args.text))
    end
    for _, f in ipairs(W.afterCall or {}) do pcall(f, player, args, res) end -- 0.8.5 stand-offs: backup called in earshot
    return res
end

function W.mentionsBase(text)
    local t = " " .. string.lower(tostring(text or "")) .. " "
    for _, w in ipairs({ " base ", " home ", " camp ", " our place ", " the house ", " compound " }) do
        if string.find(t, w, 1, true) then return true end
    end
    return false
end

-- { uid } in talk: will they swap channels with you?
function W.serverSwap(player, args)
    if type(args) ~= "table" or type(args.uid) ~= "string" then return nil end
    local record = W.record(args.uid)
    if record == nil or record.lifecycle == "dead" then return nil end
    local res = { uid = args.uid, name = W.nameOf(record) }
    local row = W.npcRow(args.uid)
    if row == nil then res.why, res.line = "their_none", W.line("swap_none"); return res end
    if not W.isOwn(player, args.uid, record) and W.opinion(record, player) < num(W.setting("walkieSwapTrust"), 30) then
        res.why, res.line = "trust", W.line("swap_no")
        return res
    end
    local st, pkey = W.store(), W.keyOf(player)
    st.contacts[pkey] = type(st.contacts[pkey]) == "table" and st.contacts[pkey] or {}
    st.contacts[pkey][tostring(args.uid)] = { c = row.c, at = W.hours() }
    W.metrics.swaps = W.metrics.swaps + 1
    res.ok, res.ch = true, row.c
    res.line = W.line("swap_yes", W.mhz(row.c))
    return res
end

-- keyed lines (Jeem's { k, a = { ... } }) flattened to { k, a1..a4 } so they survive ALifeCmd's 3-level clean
function W.flat(lines)
    local out = {}
    for i, l in ipairs(type(lines) == "table" and lines or {}) do
        if i > 12 then break end
        if type(l) == "table" then
            local f = { k = tostring(l.k or "") }
            for n = 1, 4 do local a = type(l.a) == "table" and l.a[n] or nil; if a ~= nil then f["a" .. n] = type(a) == "table" and tostring(a.k or "") or a end end
            out[#out + 1] = f
        elseif l ~= nil then
            out[#out + 1] = tostring(l)
        end
    end
    return out
end

function W.mhz(ch)
    ch = math.floor(num(ch, 0) / 100 + 0.5) -- no %.1f: Kahlua's string.format has no precision specs
    return tostring(math.floor(ch / 10)) .. "." .. tostring(ch % 10) .. " MHz"
end

-- { ch }: "our channel" = this one (set in game, Radio tab)
function W.serverBaseChannel(player, args)
    if type(args) ~= "table" or tonumber(args.ch) == nil then return nil end
    W.store().base[W.keyOf(player)] = math.floor(num(args.ch, 0))
    return { ch = W.store().base[W.keyOf(player)] }
end

-- the people you can call by name, for the Radio tab: { uid, name, how, ch, has (a radio), p (power > 0), home }
function W.contacts(player)
    local out, seen = {}, {}
    local st, pkey = W.store(), W.keyOf(player)
    local function add(uid, how)
        uid = tostring(uid)
        if seen[uid] then return end
        local rec = W.record(uid)
        if rec == nil or rec.lifecycle == "dead" then return end
        seen[uid] = true
        local row = W.npcRow(uid)
        local base = how == "own" and W.ownBase(player, rec) or nil
        local home = base ~= nil and W.atHome(rec, base) or false
        out[#out + 1] = { uid = uid, name = W.nameOf(rec), how = how, ch = how == "own" and st.base[pkey] or (row and row.c),
            has = row ~= nil, p = row ~= nil and num(row.p, 0) > 0, home = home and W.setting("walkieBaseSet") ~= false }
    end
    if W.setting("walkieOwn") ~= false then
        local pa = PA()
        if pa ~= nil and fn(pa.ActorRegistry, "each") then
            pa.ActorRegistry.each(function(rec)
                if type(rec) == "table" and rec.lifecycle ~= "dead" and W.isOwn(player, rec.uid, rec) then add(rec.uid, "own") end
                return #out >= 40
            end)
        end
    end
    for uid in pairs(type(st.contacts[pkey]) == "table" and st.contacts[pkey] or {}) do if #out < 40 then add(uid, "swapped") end end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out, st.base[pkey]
end

-- ---------------------------------------------------------------------------------------------------- they call you
-- every ten game minutes (server): who has been home, check-ins when you've been gone long, instant alerts.
-- Returns the incoming calls made (each also sent to that player as "walkieIncoming").
function W.homeOf(player)
    local j = J()
    local B = j and j.BaseAreas
    local ra = RA()
    if not (fn(B, "who") and fn(B, "basesFor")) or ra == nil or not fn(ra, "distance") then return nil end
    local who = B.who(player)
    local px, py = num(call(player, "getX"), nil), num(call(player, "getY"), nil)
    if px == nil then return nil end
    local best, bestD = nil, nil
    for _, b in ipairs(B.basesFor(who.key, who.faction, false) or {}) do
        if b.siteId ~= nil then
            local d = ra.distance(b.id, px, py) or math.huge
            if bestD == nil or d < bestD then best, bestD = b, d end
        end
    end
    return best, bestD
end

function W.tickPlayer(player, h)
    local out = {}
    if not W.on() then return out end
    local st, pkey = W.store(), W.keyOf(player)
    local base, d = W.homeOf(player)
    if base == nil then return out end
    if d ~= nil and d <= 0 then st.seen[pkey] = h end
    if st.seen[pkey] == nil then st.seen[pkey] = h end
    local j = J()
    local R = j and j.Residents
    local home = fn(R, "atHome") and R.atHome(base.id) or {}
    local caller = nil
    for _, r in ipairs(home) do if r.lifecycle ~= "dead" then caller = r; break end end
    if caller == nil then return out end
    local told = type(st.told[pkey]) == "table" and st.told[pkey] or {}
    st.told[pkey] = told
    local ch = st.base[pkey]
    -- alerts
    if W.setting("walkieAlerts") ~= false and d ~= nil and d > 0 then
        local alarm = false
        for _, r in ipairs(home) do
            local m = type(r.memory) == "table" and r.memory or {}
            if num(m.jimmyAlarmUntil, -1e9) > h then alarm = true end
        end
        if alarm and not told.alarm then
            out[#out + 1] = { kind = "attack", uid = tostring(caller.uid), name = W.nameOf(caller), ch = ch, baseId = base.id, d = d }
        end
        told.alarm = alarm
        local ra = RA()
        if ra ~= nil and fn(ra, "status") then
            local okS, lines = pcall(ra.status, base, h)
            local hurt = {}
            for _, l in ipairs(okS and lines or {}) do
                if type(l) == "table" and (l.k == "IGUI_ALJ_Radio_Bitten" or l.k == "IGUI_ALJ_Radio_Hurt") then hurt[#hurt + 1] = l end
            end
            local sig = ""
            for _, l in ipairs(hurt) do sig = sig .. tostring(l.a and l.a[1]) .. ";" end
            if sig ~= "" and sig ~= told.hurt then
                out[#out + 1] = { kind = "hurt", uid = tostring(caller.uid), name = W.nameOf(caller), ch = ch, baseId = base.id, d = d, lines = hurt }
            end
            told.hurt = sig
        end
    end
    -- check-in
    local gap = num(W.setting("walkieCheckinH"), 8)
    if gap > 0 and h - num(st.seen[pkey], h) >= gap and h - num(told.checkinH, -1e9) >= gap then
        told.checkinH = h
        local ra = RA()
        local lines = {}
        if ra ~= nil and fn(ra, "status") then local okS, l = pcall(ra.status, base, h); if okS and type(l) == "table" then lines = l end end
        out[#out + 1] = { kind = "checkin", uid = tostring(caller.uid), name = W.nameOf(caller), ch = ch, baseId = base.id, d = d, lines = lines,
            awayH = math.floor(h - num(st.seen[pkey], h)) }
        W.metrics.checkins = W.metrics.checkins + 1
    end
    for _, c in ipairs(out) do
        if c.kind ~= "checkin" then W.metrics.alerts = W.metrics.alerts + 1 end
        if fn(ALifeCmd, "reply") then
            local send = {}
            for k, v in pairs(c) do send[k] = v end
            send.lines = W.flat(c.lines)
            ALifeCmd.reply(player, "walkieIncoming", send)
        end
    end
    return out
end

-- the client tells us whether a call reached you: { kind, heard = bool }. A missed check-in is remembered.
function W.serverIncomingSeen(player, args)
    if type(args) ~= "table" then return nil end
    local st, pkey = W.store(), W.keyOf(player)
    local m = type(st.missed[pkey]) == "table" and st.missed[pkey] or { n = 0 }
    if args.heard == true then m.n = 0
    elseif args.kind == "checkin" then m.n = num(m.n, 0) + 1; m.lastH = W.hours(); W.metrics.missed = W.metrics.missed + 1 end
    st.missed[pkey] = m
    return m
end
-- how many check-ins in a row this player has missed (0.8.5 capture reads it)
function W.missedCheckins(player) local m = W.store().missed[W.keyOf(player)]; return type(m) == "table" and num(m.n, 0) or 0 end

function W.players()
    local out = {}
    pcall(function()
        if type(isServer) == "function" and isServer() and type(getOnlinePlayers) == "function" then
            local l = getOnlinePlayers()
            for i = 0, l:size() - 1 do out[#out + 1] = l:get(i) end
        else
            local p = getSpecificPlayer(0)
            if p ~= nil then out[1] = p end
        end
    end)
    return out
end

W.lastTickH = W.lastTickH or nil
function W.tick()
    if type(isClient) == "function" and isClient() then return end -- the server (or single player) runs it
    local h = W.hours()
    local dt = W.lastTickH ~= nil and math.max(0, h - W.lastTickH) or 0
    W.lastTickH = h
    if dt > 0 then W.standby(dt) end
    for _, p in ipairs(W.players()) do
        local dead = true
        pcall(function() dead = p:isDead() == true end)
        if not dead then pcall(W.tickPlayer, p, h) end
    end
end

-- ---------------------------------------------------------------------------------------------------- wiring
if fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("walkieCall", function(player, args)
        local res = W.serverCall(player, args)
        if res ~= nil then res.lines = W.flat(res.lines); ALifeCmd.reply(player, "walkieResult", res) end
        return res
    end)
    ALifeCmd.onServer("walkieSwap", function(player, args)
        local res = W.serverSwap(player, args)
        if res ~= nil then ALifeCmd.reply(player, "walkieSwapped", res) end
        return res
    end)
    ALifeCmd.onServer("walkieBaseChannel", function(player, args)
        local res = W.serverBaseChannel(player, args)
        if res ~= nil then ALifeCmd.reply(player, "walkieBaseChannelSet", res) end
        return res
    end)
    ALifeCmd.onServer("walkieContacts", function(player, args)
        local list, ch = W.contacts(player)
        ALifeCmd.reply(player, "walkieContactList", { list = list, ch = ch })
        return list
    end)
    ALifeCmd.onServer("walkieSeen", function(player, args) return W.serverIncomingSeen(player, args) end)
end
if Events ~= nil and Events.EveryTenMinutes ~= nil and not W._ticking then
    W._ticking = true
    Events.EveryTenMinutes.Add(function()
        local ok, err = pcall(W.tick)
        if not ok then log("tick failed: " .. tostring(err)) end
    end)
end
log("ready v" .. W.VERSION .. ": walkie calls by name (battery, range, channels, check-ins, overhearing)")
