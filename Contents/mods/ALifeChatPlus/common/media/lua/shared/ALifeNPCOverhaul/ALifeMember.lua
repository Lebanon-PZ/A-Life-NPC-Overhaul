-- A-Life NPC Overhaul 0.9.2 (Legacy): JOIN AN NPC GROUP. The mirror of what you do to NPCs: you can join their
-- people and climb: guest (watched), member, trusted, lieutenant, leader. A-Life has no way to put a player into an
-- NPC faction, so this is our own membership layer on top (A-Life's groups, leaders and havens, read only).
--   * JOINING: ask one of them ("can I join you?"). The group decides: each member by what they think of you (A-Life
--     NpcOpinion), the leader by temperament (a predator wants a clear yes). Hostile to you = no.
--   * TRUST, from real things only: orders done or refused, what the members think of you day by day, betrayal.
--     No numbers: you're told by what changes ("they gave you a bunk", "a key to the storeroom", "the leader asks what
--     you think before deciding"). Leader: you're their lieutenant when the leader dies, or (0.9.2 fast path) you take it.
--   * ORDERS from the leader (memberOrderDays apart, a card: take it or refuse it): night watch / gate duty (be at
--     their haven for the hours), bring food for the pot, bring medicine when one of them is really hurt. Refusing
--     or failing costs trust, the price by the leader's temperament (disappointed ... kicked out). You keep free will.
--   * BETRAYAL: kill one of them while you're one of them -> thrown out, their group hates you (and the witnesses'
--     grudges as always).
-- Store: global ModData "ALifeChatPlus_Member": [playerKey] = { gid, gname, rank, trust, h, leader, order, ... }.
-- Commands (ALifeCmd): memberJoin { uid }, memberAnswer { yes }, memberGive { kind, n }, memberPull -> memberState.
require "ALifeNPCOverhaul/ALifeCmd"

ALifeMember = ALifeMember or {}
local K = ALifeMember
local TAG = "[ALifeMember]"
K.VERSION = "0.9.2"
K.MODDATA = "ALifeChatPlus_Member"
K.DEFAULTS = {
    memberJoin = true,       -- you can join an NPC group and climb its ranks
    memberOrderDays = 2,     -- days between the leader's orders
    memberOrderHours = 24,   -- game hours to carry an order out
    memberDutyHours = 2,     -- hours a watch / gate duty lasts
    memberHavenTiles = 40,   -- how close to their haven counts as "there"
    -- 0.9.2 fast path
    fastPath = true,         -- climb faster: big deeds, or dirty ones (rumors, a coup)
    fastCatch = 25,          -- % a dirty move is seen through even when nobody close to them heard it
    fastHaul = 10,           -- things handed over at once that count as a big haul
}
K.RANKS = { "guest", "member", "trusted", "lt", "leader" }
K.RANK_AT = { member = { trust = 20, h = 48 }, trusted = { trust = 45, h = 168 }, lt = { trust = 70, h = 336, leader = 50 } }
K.RANK_CUE = {
    member = "They gave you a bunk and a share of the pot. You're one of them now.",
    trusted = "Someone pressed a key to the storeroom into your hand. They trust you.",
    lt = "The leader asks what you think before deciding now. You're their second.",
    leader = "They look to you now. You lead them.",
}
-- the price of refusing, by the leader's temperament (A-Life: fresh, seasoned, veteran, predator)
K.PRICE = { fresh = { 4, "Disappointed in you." }, seasoned = { 8, "They'll remember that." },
    veteran = { 12, "I won't forget that. Neither will they." }, predator = { 20, "Nobody refuses me twice." } }
K.ORDERS = {
    watch = { title = "Night watch", text = "Take the night watch at our place. From ten to six, {h} hours of it.", from = 22, to = 6, duty = true, big = false },
    gate = { title = "Gate duty", text = "Stand at the gate today. {h} hours, between eight and six.", from = 8, to = 18, duty = true, big = false },
    food = { title = "Food for the pot", text = "The pot's getting thin. Bring {n} things to eat and hand them to any of us.", give = "food", n = 3 },
    medicine = { title = "Medicine", text = "{who} is hurt bad. Bring medicine, hand it to any of us.", give = "medicine", n = 1, big = true },
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(r)
    local m = mem(r)
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function temper(r) local t = nil; pcall(function() t = PA().Speech.contextFor(r, nil).temperament end); return type(t) == "string" and t or nil end
function K.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
do
    local m = ALifeLLMTalk
    if type(m) == "table" and type(m.settings) == "table" then
        m.fileKeys = m.fileKeys or {}
        local have = {}
        for _, x in ipairs(m.fileKeys) do have[x] = true end
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end; if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end end
    end
end
function K.on() return K.setting("memberJoin") ~= false end
function K.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return num(h, 0) end
function K.hourOfDay() return math.floor(K.hours() % 24) end
function K.store()
    local d = nil
    pcall(function() d = ModData.getOrCreate(K.MODDATA) end)
    if type(d) ~= "table" then K._mem = K._mem or {}; d = K._mem end
    d.by = type(d.by) == "table" and d.by or {}
    return d
end
local function transmit() if type(ModData) == "table" and fn(ModData, "transmit") and type(isServer) == "function" and isServer() then pcall(ModData.transmit, K.MODDATA) end end
function K.keyOf(player)
    if type(player) == "string" then return player end
    local R = PA().Reputation
    if fn(R, "playerKey") then local ok, k = pcall(R.playerKey, player); if ok and k then return tostring(k) end end
    local u = nil
    pcall(function() u = player:getUsername() end)
    return u and tostring(u) or nil
end
function K.of(player) local r = K.store().by[tostring(K.keyOf(player) or "")]; return type(r) == "table" and r or nil end
function K.rankIndex(rank) for i, r in ipairs(K.RANKS) do if r == rank then return i end end return 1 end

-- ---------------------------------------------------------------------------------------------- the group
function K.members(gid)
    local out = {}
    if gid == nil then return out end
    pcall(function()
        PA().ActorRegistry.each(function(r)
            if type(r) == "table" and r.lifecycle ~= "dead" and mem(r).groupId == gid then out[#out + 1] = r end
            return false
        end)
    end)
    return out
end
function K.leaderOf(gid, anyUid)
    local P = ALifeTalkPatch
    if anyUid and fn(P, "leaderOf") then local ok, l = pcall(P.leaderOf, anyUid); if ok and l then return tostring(l) end end
    local ms = K.members(gid)
    return ms[1] and tostring(ms[1].uid) or nil
end
function K.groupName(gid)
    local n = nil
    pcall(function() local f = PA().Catalog.faction(gid); n = type(f) == "table" and type(f.general) == "table" and f.general.name or nil end)
    return n and tostring(n) or "their group"
end
function K.haven(row)
    local x, y = nil, nil
    pcall(function() local h = PA().Havens.homeOf(rec(row.leader)); if type(h) == "table" then x, y = tonumber(h.x), tonumber(h.y) end end)
    if x == nil then local r = rec(row.leader); if r and tonumber(r.x) then x, y = tonumber(r.x), tonumber(r.y) end end
    return x, y
end
local function opinion(r, player) local v = 0; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end); return v end
local function hostile(r, player)
    local h = false -- A-Life's own check (server/ProjectALife/Decisions/ALifeRelations.lua: hostileToPlayer(actor, player))
    pcall(function() h = PA().Relations.hostileToPlayer(r, player) == true end)
    return h
end

-- ---------------------------------------------------------------------------------------------- joining
-- returns ok, why ("yes" | "no" | "hostile" | "member" | "off" | "nobody"), and the tally { yes, no }
function K.join(player, uid)
    if not K.on() then return false, "off" end
    local key = K.keyOf(player)
    if key == nil then return false, "key" end
    local cur = K.of(player)
    if cur and not cur.gone then return false, "member" end
    local r = rec(uid)
    if r == nil or r.lifecycle == "dead" or mem(r).groupId == nil then return false, "nobody" end
    local gid = mem(r).groupId
    if hostile(r, player) then return false, "hostile" end
    local yes, no = 0, 0
    for _, m in ipairs(K.members(gid)) do
        local v = opinion(m, player)
        if v >= 20 then yes = yes + 1 elseif v <= -10 then no = no + 1 end
    end
    local leader = K.leaderOf(gid, uid)
    local t = temper(rec(leader))
    local ok
    if t == "predator" then ok = yes > no * 2 and yes >= 1
    elseif t == "veteran" then ok = yes > no
    else ok = yes >= no and yes >= 1 end
    if not ok then return false, "no", { yes = yes, no = no } end
    K.store().by[key] = { gid = gid, gname = K.groupName(gid), rank = "guest", trust = 0, h = K.hours(), leader = leader, lastOrderH = K.hours(), done = 0, refused = 0 }
    transmit()
    log(tostring(key) .. " joined " .. K.groupName(gid))
    return true, "yes", { yes = yes, no = no }
end
function K.leave(player, why)
    local row = K.of(player)
    if row == nil then return false end
    row.gone, row.goneWhy, row.goneH = true, why or "left", K.hours()
    row.order = nil
    transmit()
    return true
end

-- ---------------------------------------------------------------------------------------------- trust and rank
function K.addTrust(player, d, why)
    local row = K.of(player)
    if row == nil or row.gone then return nil end
    row.trust = math.max(-100, math.min(100, num(row.trust, 0) + d))
    row.lastWhy = why
    if row.trust <= -20 and row.rank ~= "leader" then
        K.leave(player, "kicked out")
        return "kicked"
    end
    return K.promote(player)
end
-- climb when trust and time allow (and for lieutenant, the leader likes you); returns the new rank or nil
function K.promote(player)
    local row = K.of(player)
    if row == nil or row.gone then return nil end
    local i = K.rankIndex(row.rank)
    local nextRank = K.RANKS[i + 1]
    local need = nextRank and K.RANK_AT[nextRank] or nil
    if need == nil then return nil end
    if num(row.trust, 0) < need.trust or K.hours() - num(row.h, 0) < need.h then return nil end
    if need.leader and opinion(rec(row.leader), player) < need.leader then return nil end
    row.rank = nextRank
    row.rankH = K.hours()
    transmit()
    return nextRank
end
-- once a day: trust drifts toward what the members think of you
function K.daily(player)
    local row = K.of(player)
    if row == nil or row.gone then return nil end
    local sum, n = 0, 0
    for _, m in ipairs(K.members(row.gid)) do sum = sum + opinion(m, player); n = n + 1 end
    if n == 0 then return nil end
    local d = math.max(-3, math.min(3, (sum / n) / 10))
    return K.addTrust(player, d, "how they see you")
end
-- their leader died: their lieutenant (you) takes over
function K.leaderDied(player, uid)
    local row = K.of(player)
    if row == nil or row.gone or tostring(row.leader) ~= tostring(uid) then return nil end
    if row.rank == "lt" then
        row.rank, row.leader, row.rankH = "leader", nil, K.hours()
        transmit()
        return "leader"
    end
    if K.setting("fastPath") ~= false and K.election(player, uid) == "leader" then return "leader" end
    local ms = K.members(row.gid)
    row.leader = ms[1] and tostring(ms[1].uid) or nil
    if ms[1] then row.leader = K.leaderOf(row.gid, ms[1].uid) end
    transmit()
    return "new"
end
-- you killed one of them while you're one of them
function K.betrayal(player, deadUid)
    local row = K.of(player)
    if row == nil or row.gone then return false end
    local r = rec(deadUid)
    if r == nil or mem(r).groupId ~= row.gid then return false end
    K.leave(player, "betrayal")
    for _, m in ipairs(K.members(row.gid)) do pcall(function() PA().NpcOpinion.adjust(m, player, -30, "killed one of their own while they were one of us") end) end
    return true
end

-- ---------------------------------------------------------------------------------------------- orders
-- the leader's next order, from what the group really needs now (hurt member -> medicine)
function K.pickOrder(row, rollN)
    local hurt = nil
    if type(ALifeQuests) == "table" and fn(ALifeQuests, "hurtNear") and row.leader then
        local ok, h = pcall(ALifeQuests.hurtNear, rec(row.leader))
        if ok and h then hurt = h end
    end
    if hurt then return "medicine", first(hurt) end
    local list = { "watch", "gate", "food" }
    local i = ((rollN or 0) % #list) + 1
    return list[i], nil
end
function K.issue(player, rollN)
    local row = K.of(player)
    if row == nil or row.gone or row.rank == "leader" or row.order ~= nil then return nil end
    if K.hours() - num(row.lastOrderH, 0) < num(K.setting("memberOrderDays"), 2) * 24 then return nil end
    local id, who = K.pickOrder(row, rollN or math.floor(K.hours()))
    local o = K.ORDERS[id]
    row.order = { id = id, h = K.hours(), who = who, accepted = nil, got = 0, duty = 0 }
    row.lastOrderH = K.hours()
    transmit()
    return row.order, (string.gsub(string.gsub(string.gsub(o.text, "{h}", tostring(K.setting("memberDutyHours"))), "{n}", tostring(o.n or 0)), "{who}", tostring(who or "One of ours")))
end
function K.price(row)
    local t = temper(rec(row.leader))
    return K.PRICE[t or "seasoned"] or K.PRICE.seasoned
end
function K.answer(player, yes)
    local row = K.of(player)
    if row == nil or row.order == nil or row.order.accepted ~= nil then return nil end
    if yes then row.order.accepted = K.hours(); transmit(); return "accepted" end
    local p = K.price(row)
    row.order = nil
    row.refused = num(row.refused, 0) + 1
    local r = K.addTrust(player, -p[1], "refused an order")
    transmit()
    return r == "kicked" and "kicked" or "refused", p[2]
end
-- presence: on watch / at the gate within the hours
function K.inWindow(o, hod)
    if o.from < o.to then return hod >= o.from and hod < o.to end
    return hod >= o.from or hod < o.to
end
function K.dutyTick(player, stepH)
    local row = K.of(player)
    if row == nil or row.order == nil or not row.order.accepted then return nil end
    local o = K.ORDERS[row.order.id]
    if o == nil or not o.duty then return nil end
    if not K.inWindow(o, K.hourOfDay()) then return nil end
    local hx, hy = K.haven(row)
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    local r = num(K.setting("memberHavenTiles"), 40)
    if hx == nil or px == nil or (px - hx) ^ 2 + (py - hy) ^ 2 > r * r then return nil end
    row.order.duty = num(row.order.duty, 0) + (stepH or (10 / 60))
    if row.order.duty >= num(K.setting("memberDutyHours"), 2) then return K.complete(player) end
    return "on duty"
end
-- something handed to one of them (food / medicine)
function K.gave(player, kind, n, toUid)
    local row = K.of(player)
    if row == nil or row.order == nil or not row.order.accepted then return nil end
    local o = K.ORDERS[row.order.id]
    if o == nil or o.give ~= kind then return nil end
    if toUid then local r = rec(toUid); if r == nil or mem(r).groupId ~= row.gid then return nil end end
    row.order.got = num(row.order.got, 0) + num(n, 1)
    if row.order.got >= num(o.n, 1) then return K.complete(player) end
    transmit()
    return "more"
end
function K.complete(player)
    local row = K.of(player)
    if row == nil or row.order == nil then return nil end
    local o = K.ORDERS[row.order.id] or {}
    row.order = nil
    row.done = num(row.done, 0) + 1
    local r = K.addTrust(player, o.big and 12 or 8, "carried out an order")
    transmit()
    return "done", r
end
-- an order past its time
function K.expire(player)
    local row = K.of(player)
    if row == nil or row.order == nil then return nil end
    if K.hours() - num(row.order.h, 0) < num(K.setting("memberOrderHours"), 24) then return nil end
    row.order = nil
    local p = K.price(row)
    local r = K.addTrust(player, -p[1], "didn't carry out an order")
    transmit()
    return r == "kicked" and "kicked" or "failed", p[2]
end
-- ---------------------------------------------------------------------------------------------- 0.9.2 FAST PATH
-- good: a big haul into their hands (fastHaul things at once)
function K.bigHaul(player, n)
    if K.setting("fastPath") == false then return nil end
    local row = K.of(player)
    if row == nil or row.gone or num(n, 0) < num(K.setting("fastHaul"), 10) then return nil end
    return K.addTrust(player, 6, "a big haul for the group")
end
local function roll(rollFn) if rollFn then return rollFn() end local r = 99; pcall(function() r = ZombRand(100) end); return r end
local function lm() return ALifeLLMTalk end
local function closeness(a, b)
    local m = lm()
    if fn(m, "closeness") then local ok, v = pcall(m.closeness, tostring(a), tostring(b)); if ok and tonumber(v) then return v end end
    return 0
end
-- caught: the price by the leader's temperament (rank down / out / taken: their cell, ALifeCapture)
K.CAUGHT = { fresh = "down", seasoned = "down", veteran = "out", predator = "cell" }
function K.caught(player, row, what)
    local t = temper(rec(row.leader))
    local how = K.CAUGHT[t or "seasoned"] or "down"
    row.caught = num(row.caught, 0) + 1
    if how == "down" then
        row.rank = K.RANKS[math.max(1, K.rankIndex(row.rank) - 1)]
        K.addTrust(player, -20, "caught: " .. tostring(what))
    else
        K.leave(player, "caught")
        if how == "cell" and type(ALifeCapture) == "table" and fn(ALifeCapture, "take") then
            local L = rec(row.leader)
            if L then pcall(ALifeCapture.take, player, { L }, "theirs", "caught") end
        end
    end
    local m = lm()
    if fn(m, "addGrudge") and row.leader then pcall(m.addGrudge, row.leader, 40, "caught you " .. tostring(what), player) end
    transmit()
    return how
end
-- dirty: a rumor about one of them to another ("Bo's been stealing from us"). Believed by how the listener sees you;
-- seen through when the listener is close to the one it's about, or by plain bad luck (fastCatch).
function K.rumor(player, aboutUid, toUid, rollFn)
    if K.setting("fastPath") == false then return nil, "off" end
    local row = K.of(player)
    if row == nil or row.gone then return nil, "none" end
    local about, to = rec(aboutUid), rec(toUid)
    if about == nil or to == nil or mem(about).groupId ~= row.gid or mem(to).groupId ~= row.gid or tostring(aboutUid) == tostring(toUid) then return nil, "who" end
    local close = closeness(toUid, aboutUid)
    local catch = num(K.setting("fastCatch"), 25) + close * 60
    if roll(rollFn) < catch then return "caught", K.caught(player, row, "spreading lies about " .. first(about)) end
    row.standing = type(row.standing) == "table" and row.standing or {}
    row.standing[tostring(aboutUid)] = num(row.standing[tostring(aboutUid)], 0) - 15
    local m = lm()
    if fn(m, "pairBump") then pcall(m.pairBump, tostring(toUid), tostring(aboutUid), -12, "heard they were stealing") end
    transmit()
    return "believed"
end
-- support for you among them (leaving out who you're up against): by what each thinks of you and of them
function K.support(player, row, against)
    local yes, no = 0, 0
    for _, m in ipairs(K.members(row.gid)) do
        if tostring(m.uid) ~= tostring(against) then
            local v = opinion(m, player) + num(row.standing and row.standing[tostring(against)], 0) * -1
            local tie = closeness(m.uid, against)
            if v - tie * 50 >= 30 then yes = yes + 1 elseif v - tie * 50 <= 0 then no = no + 1 end
        end
    end
    return yes, no
end
-- a coup: trusted or their lieutenant, "I'm taking over". Most of them behind you: you lead, the old leader steps
-- aside (and hates you). Not enough: you're caught (the leader's price).
function K.coup(player, rollFn)
    if K.setting("fastPath") == false then return nil, "off" end
    local row = K.of(player)
    if row == nil or row.gone then return nil, "none" end
    if K.rankIndex(row.rank) < 3 then return nil, "rank" end
    if row.rank == "leader" then return nil, "leader" end
    local yes, no = K.support(player, row, row.leader)
    local feared = temper(rec(row.leader)) == "predator" and 1 or 0
    if yes > no + feared and yes >= 2 then
        local old = row.leader
        row.rank, row.rankH, row.leader, row.oldLeader = "leader", K.hours(), nil, old
        local m = lm()
        if old and fn(m, "addGrudge") then pcall(m.addGrudge, old, 60, "took their people from them", player) end
        pcall(function() PA().NpcOpinion.adjust(rec(old), player, -40, "took the group from them") end)
        transmit()
        return "leader", { yes = yes, no = no }
    end
    return "caught", K.caught(player, row, "trying to take over")
end
-- the leader died and you're not their lieutenant: they pick, you're in the running if you're trusted
function K.election(player, deadUid)
    local row = K.of(player)
    if row == nil or row.gone or row.rank == "lt" or row.rank == "leader" then return nil end
    if K.rankIndex(row.rank) < 3 then return nil end
    local yes, no = K.support(player, row, deadUid)
    if yes > no and yes >= 2 then row.rank, row.leader, row.rankH = "leader", nil, K.hours(); transmit(); return "leader" end
    return nil
end

function K.view(row)
    if type(row) ~= "table" then return nil end
    local o = row.order
    return { gid = row.gid, gname = row.gname, rank = row.rank, gone = row.gone, goneWhy = row.goneWhy, leader = row.leader,
        orderId = o and o.id or nil, orderWho = o and o.who or nil, orderAccepted = o and o.accepted or nil }
end

function K.install()
    if K.installed or not fn(ALifeCmd, "onServer") then return K.installed == true end
    local function state(player, extra)
        local v = K.view(K.of(player)) or {}
        for k2, x in pairs(extra or {}) do v[k2] = x end
        ALifeCmd.reply(player, "memberState", v)
    end
    ALifeCmd.onServer("memberJoin", function(player, a) local ok, why = K.join(player, type(a) == "table" and a.uid or nil); state(player, { ev = "join", ok = ok, why = why }) end)
    ALifeCmd.onServer("memberAnswer", function(player, a) local r, cue = K.answer(player, type(a) == "table" and a.yes == true); state(player, { ev = "answer", res = r, cue = cue }) end)
    ALifeCmd.onServer("memberGive", function(player, a) if type(a) == "table" then local r = K.gave(player, tostring(a.kind), num(a.n, 1), a.to); state(player, { ev = "give", res = r }) end end)
    ALifeCmd.onServer("memberLeave", function(player, a) K.leave(player, "left"); state(player, { ev = "leave" }) end)
    ALifeCmd.onServer("memberPull", function(player, a) state(player, { ev = "pull" }) end)
    K.installed = true
    return true
end
K.install()
print(TAG .. " ready v" .. K.VERSION .. ": join NPC groups (" .. (K.on() and "on" or "off") .. "), ranks guest > member > trusted > lt > leader, orders every " .. tostring(K.setting("memberOrderDays")) .. " days")
return K
