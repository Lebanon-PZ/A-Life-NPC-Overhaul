-- A-Life NPC Overhaul 0.8.8: THE CAMP HAS OPINIONS. One tally, reused by everything that asks the camp (who gets in,
-- who gets thrown out, who leads while you're away; 0.9 democracy builds on it).
--   * Each resident of the base (Jeem residents, R.residents) is for, against or doesn't care, only from real things:
--     the newcomers' group and theirs (A-Life Relations.status: hostile / friendly), the food (Jeem's Food store count
--     and base.hungry), the beds left after (Jeem R.capacity / R.headcount), their temperament (A-Life Speech), and for
--     a person already inside, how the two of them get on (ALifeHousehold pair score).
--   * You never see a number: a cue ("most of them want them in", "the camp is split") and the loudest voice by name.
--   * Going against the camp costs you with the ones who lost the argument (A-Life NpcOpinion); going with them, a little
--     goodwill. Only people who cared enough count.
-- One join flow: Jeem's refugee visit is the door. When a party arrives (Jeem "refugeesArrived") the base's managers get
-- the camp's view as a letter; when you (or your lieutenant) answer (Jeem "refugeesJoined" / "refugeesTurnedAway") the
-- camp reacts. People you already know who move in through our Settle talk go through the same tally ("campVoteDone").
-- Server side (Jeem's residents and A-Life's opinions live there; single player runs it directly). Jeem and A-Life calls
-- read in Jeem (3806944055) and A-Life 1.5.1: J.on / J.emit, J.Residents.residents / capacity / headcount / stores.foodCount,
-- J.BaseAreas.base / baseAt / who / canManage, J.TraderStock.data().visits, Traders.visits.players / managers,
-- ProjectALife.Relations.status(record, record), NpcOpinion.adjust(record, key, delta, why), Speech.contextFor.
require "ALifeNPCOverhaul/ALifeCmd"

ALifeCampVote = ALifeCampVote or {}
local V = ALifeCampVote
local TAG = "[ALifeCampVote]"
V.VERSION = "0.8.8"
V.DEFAULTS = {
    campVote = true,       -- residents have a say in who gets in (and later who leads, who goes)
    voteLoseCost = 4,      -- how much less someone who cared likes you when you go against them
    voteWinGain = 2,       -- how much more when you go with them
    voteFoodDays = 3,      -- days of food left below which newcomers worry people
    voteCareAt = 15,       -- how strongly someone must feel to hold your choice against you
    voteExile = true,      -- 0.8.8: sending a resident away (Jeem's faction page) goes past the camp too
    voteLead = true,       -- 0.8.8: naming a first lieutenant goes past the camp too
}
V.KEYS = {}
for k in pairs(V.DEFAULTS) do V.KEYS[#V.KEYS + 1] = k end
table.sort(V.KEYS)
V.TEMPER = { predator = -8, veteran = -4, seasoned = 2, fresh = 6 }
V.metrics = V.metrics or { tallies = 0, told = 0, reacted = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function rec(uid)
    local pa = PA()
    if uid == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function first(r)
    local m = mem(r)
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    if type(n) == "string" and n ~= "" then return string.match(n, "^(%S+)") or n end
    return "Someone"
end
function V.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = V.DEFAULTS[key] end
    return v
end
function V.on() return V.setting("campVote") ~= false end
function V.store()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeCampVote") or (V.tmp or {})
    if type(ModData) ~= "table" then V.tmp = s end
    s.asked = type(s.asked) == "table" and s.asked or {}
    return s
end

-- ---------------------------------------------------------------------------------------------- the base
function V.base(baseId)
    local j = J()
    if j == nil or not fn(j.BaseAreas, "base") then return nil end
    local ok, b = pcall(j.BaseAreas.base, baseId)
    return ok and type(b) == "table" and b or nil
end
function V.residents(baseId)
    local j = J()
    local R = j and j.Residents or nil
    if not fn(R, "residents") then return {} end
    local ok, list = pcall(R.residents, baseId)
    return ok and type(list) == "table" and list or {}
end
-- days of food in the Food store for everyone there; nil when Jeem can't tell (no Food store, not counted yet)
function V.foodDays(base, people)
    local j = J()
    local St = j and j.Residents and j.Residents.stores or nil
    if base == nil or not fn(St, "foodCount") then return nil end
    local ok, c = pcall(St.foodCount, base)
    if not ok or type(c) ~= "table" or c.items == nil then return nil end
    local eat = num(St.eatPerDay, 1) * math.max(1, people)
    return num(c.items, 0) / eat
end
function V.bedsLeft(base)
    local j = J()
    local R = j and j.Residents or nil
    if base == nil or not fn(R, "capacity") or not fn(R, "headcount") then return nil end
    local ok1, cap = pcall(R.capacity, base)
    local ok2, head = pcall(R.headcount, base.id)
    if not ok1 or not ok2 or tonumber(cap) == nil then return nil end
    return num(cap, 0) - num(head, 0)
end
local function temper(r)
    local t = nil
    pcall(function() t = PA().Speech.contextFor(r, nil).temperament end)
    return type(t) == "string" and t or nil
end
local function relation(a, b)
    local R = PA().Relations
    if not fn(R, "status") or a == nil or b == nil then return nil end
    local ok, s = pcall(R.status, a, b)
    return ok and s or nil
end
local function pair(a, b)
    if not fn(ALifeHousehold, "get") then return 0 end
    local ok, v = pcall(ALifeHousehold.get, a, b)
    return ok and num(v, 0) or 0
end

-- ---------------------------------------------------------------------------------------------- one voice
-- q = { k = "admit", uids = {...} } | { k = "exile", uid } | { k = "lead", uid }; ctx = facts about the base read once
-- returns score (+ for, - against), why (their reason in plain words)
function V.voice(r, q, ctx)
    local score, why, strongest = 0, nil, 0
    local function add(d, w) score = score + d; if math.abs(d) > strongest then strongest, why = math.abs(d), w end end
    if q.k == "admit" then
        for _, u in ipairs(q.uids or {}) do
            local nr = rec(u)
            local st = relation(r, nr)
            if st == "hostile" then add(-40, "one of them runs with a crowd they hate")
            elseif st == "friendly" then add(12, "they know their people") end
        end
        if ctx.hungry then add(-30, "there isn't enough food as it is")
        elseif ctx.days ~= nil and ctx.days < num(V.setting("voteFoodDays"), 3) then add(-12, "the food is running low") end
        if ctx.bedsAfter ~= nil and ctx.bedsAfter < 1 then add(-6, "it's getting crowded") end
        local t = temper(r)
        if t ~= nil and V.TEMPER[t] ~= nil then
            add(V.TEMPER[t], V.TEMPER[t] < 0 and "they don't trust strangers" or "more hands help")
        end
    elseif q.k == "exile" or q.k == "lead" then
        if tostring(r.uid) == tostring(q.uid) then return 0, nil end
        local p = pair(r.uid, q.uid)
        local d = q.k == "exile" and -p or p
        if p >= 40 then add(q.k == "exile" and -35 or 30, q.k == "exile" and "they're friends" or "they trust them")
        elseif p <= -35 then add(q.k == "exile" and 30 or -35, q.k == "exile" and "they can't stand them" or "they can't stand them")
        elseif d ~= 0 then add(d / 2, d > 0 and "they get on" or "they don't get on") end
    end
    return score, why
end

-- ---------------------------------------------------------------------------------------------- the tally
function V.tally(baseId, q)
    if type(q) ~= "table" then return nil end
    local base = V.base(baseId)
    local people = V.residents(baseId)
    local n = 0
    if q.k == "admit" then n = #(q.uids or {}) end
    local beds = V.bedsLeft(base)
    local ctx = { hungry = type(base) == "table" and base.hungry == true, days = V.foodDays(base, #people + n),
        bedsAfter = beds ~= nil and (beds - n) or nil }
    local t = { yes = 0, no = 0, meh = 0, voices = {}, k = q.k, baseId = baseId }
    for _, r in ipairs(people) do
        if r.lifecycle ~= "dead" then
            local s, why = V.voice(r, q, ctx)
            local side = s >= 8 and 1 or (s <= -8 and -1 or 0)
            if side > 0 then t.yes = t.yes + 1 elseif side < 0 then t.no = t.no + 1 else t.meh = t.meh + 1 end
            t.voices[#t.voices + 1] = { uid = tostring(r.uid), s = s, why = why, name = first(r) }
        end
    end
    V.metrics.tallies = V.metrics.tallies + 1
    return t
end

V.SUBJECT = {
    admit = { yes = "want them in", no = "don't want them here", loudNo = "is dead set against taking them in", loudYes = "speaks up for them" },
    exile = { yes = "want them gone", no = "want them to stay", loudNo = "won't hear of throwing them out", loudYes = "wants them out" },
    lead = { yes = "would follow them", no = "wouldn't follow them", loudNo = "won't take orders from them", loudYes = "backs them" },
}
-- the cue: never a number
function V.cue(t)
    if type(t) ~= "table" then return nil end
    local sub = V.SUBJECT[t.k] or V.SUBJECT.admit
    local line
    if t.yes + t.no == 0 then line = #t.voices == 0 and "Nobody here to ask." or "Nobody much cares either way."
    elseif t.yes > t.no * 2 then line = (t.no == 0 and "They all " or "Most of them ") .. sub.yes .. "."
    elseif t.no > t.yes * 2 then line = (t.yes == 0 and "They all " or "Most of them ") .. sub.no .. "."
    else line = "The camp is split." end
    local lo, hi = nil, nil
    for _, v in ipairs(t.voices) do
        if v.s <= -15 and (lo == nil or v.s < lo.s) then lo = v end
        if v.s >= 15 and (hi == nil or v.s > hi.s) then hi = v end
    end
    if lo ~= nil then line = line .. " " .. lo.name .. " " .. sub.loudNo .. (lo.why and (": " .. lo.why) or "") .. "." end
    if hi ~= nil and t.no > 0 then line = line .. " " .. hi.name .. " " .. sub.loudYes .. "." end
    return line
end

-- you (or your lieutenant, for you) chose: yes = took them in / threw them out / made them lead
function V.react(t, yes, key)
    if type(t) ~= "table" or key == nil then return 0 end
    local O = PA().NpcOpinion
    if not fn(O, "adjust") then return 0 end
    local care, n = num(V.setting("voteCareAt"), 15), 0
    local lose, gain = num(V.setting("voteLoseCost"), 4), num(V.setting("voteWinGain"), 2)
    local what = t.k == "exile" and "throwing them out" or (t.k == "lead" and "who leads" or "taking them in")
    for _, v in ipairs(t.voices) do
        if math.abs(v.s) >= care then
            local r = rec(v.uid)
            local won = (v.s > 0) == (yes == true)
            if r ~= nil then
                local d = won and gain or -lose
                if d ~= 0 and pcall(O.adjust, r, key, d, won and ("You listened to them about " .. what .. ".") or ("You went against them about " .. what .. ".")) then n = n + 1 end
            end
        end
    end
    V.metrics.reacted = V.metrics.reacted + n
    return n
end

-- ---------------------------------------------------------------------------------------------- telling the base's people
function V.managersOf(base)
    local j = J()
    local Vi = j and j.Traders and j.Traders.visits or nil
    if base == nil or not fn(Vi, "players") or not fn(Vi, "managers") then return {} end
    local ok, list = pcall(function() return Vi.managers(base, Vi.players()) end)
    return ok and type(list) == "table" and list or {}
end
function V.tell(base, text)
    if text == nil then return 0 end
    local n = 0
    for _, p in ipairs(V.managersOf(base)) do
        if p.player ~= nil then ALifeCmd.reply(p.player, "campVote", { text = text, base = type(base) == "table" and base.name or nil }); n = n + 1 end
    end
    V.metrics.told = V.metrics.told + n
    return n
end

-- the members of a refugee visit still at the door
function V.visitUids(visitId)
    local j = J()
    local S = j and j.TraderStock or nil
    if not fn(S, "data") then return {} end
    local out = {}
    pcall(function()
        for id, visit in pairs(S.data().visits or {}) do
            if tostring(visit.id or id) == tostring(visitId) then
                for _, m in ipairs(type(visit.members) == "table" and visit.members or {}) do
                    if not m.dead and not m.gone and not m.stayed and m.uid ~= nil then out[#out + 1] = tostring(m.uid) end
                end
            end
        end
    end)
    return out
end

function V.onArrived(ev)
    if not V.on() or type(ev) ~= "table" then return end
    local uids = V.visitUids(ev.visitId)
    if #uids == 0 then return end
    local t = V.tally(ev.baseId, { k = "admit", uids = uids })
    V.store().asked[tostring(ev.visitId)] = { t = t, h = V.hours() }
    -- 0.8.8: a gate guard posted there tells you instead (ALifeGateGuard, with the camp's view in it)
    local guarded = false
    if type(ALifeGateGuard) == "table" and fn(ALifeGateGuard, "guardOf") and ALifeGateGuard.on() then
        local okG, g = pcall(ALifeGateGuard.guardOf, ev.baseId)
        guarded = okG and g ~= nil
    end
    if t ~= nil and #t.voices > 0 and not guarded then
        local base = V.base(ev.baseId)
        V.tell(base, "People at the door" .. (base and base.name and (" of " .. tostring(base.name)) or "") .. ". " .. tostring(V.cue(t)))
    end
end
function V.onAnswered(ev, yes)
    if not V.on() or type(ev) ~= "table" then return end
    local s = V.store()
    local row = s.asked[tostring(ev.visitId)]
    local t = type(row) == "table" and row.t or V.tally(ev.baseId, { k = "admit", uids = ev.uids })
    s.asked[tostring(ev.visitId)] = nil
    -- the newcomers themselves don't vote on their own arrival
    if type(t) == "table" and yes then
        local skip = {}
        for _, u in ipairs(type(ev.uids) == "table" and ev.uids or {}) do skip[tostring(u)] = true end
        local keep = {}
        for _, v in ipairs(t.voices) do if not skip[v.uid] then keep[#keep + 1] = v end end
        t.voices = keep
    end
    V.react(t, yes, ev.by)
    -- 0.8.8: whoever came in through the door is new to the base (the client's saboteur check: ALifeTalk_Settlement)
    if yes and type(ev.uids) == "table" and #ev.uids > 0 and ev.baseId ~= nil then
        local list = {}
        for i, u in ipairs(ev.uids) do if i <= 12 then list[#list + 1] = tostring(u) end end
        for _, p in ipairs(V.managersOf(V.base(ev.baseId))) do
            if p.player ~= nil then ALifeCmd.reply(p.player, "campJoined", { uids = table.concat(list, ",") }) end
        end
    end
end
function V.hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return num(h, 0)
end

-- ask from anywhere on the server (the lieutenant, 0.9): baseId + q -> tally, cue
function V.ask(baseId, q)
    local t = V.tally(baseId, q)
    return t, V.cue(t)
end

-- people you already know moving in through our Settle talk (client): the same tally and reaction
function V.baseFor(player)
    local j = J()
    if j == nil or not fn(j.BaseAreas, "baseAt") then return nil end
    local x, y = nil, nil
    pcall(function() x, y = player:getX(), player:getY() end)
    if x == nil then return nil end
    local ok, b = pcall(j.BaseAreas.baseAt, x, y, 30)
    return ok and type(b) == "table" and b or nil
end
function V.keyOf(player)
    local j = J()
    if j ~= nil and fn(j, "playerKey") then local ok, k = pcall(j.playerKey, player); if ok and k ~= nil then return k end end
    local R = PA().Reputation
    if fn(R, "playerKey") then local ok, k = pcall(R.playerKey, player); if ok then return k end end
    return nil
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    -- { uids = "a,b" or {..}, yes = bool }: you let people in (or sent them off) through our Settle talk
    ALifeCmd.onServer("campVoteDone", function(player, args)
        if not V.on() or type(args) ~= "table" then return "off" end
        local uids = {}
        if type(args.uids) == "table" then for _, u in ipairs(args.uids) do uids[#uids + 1] = tostring(u) end
        elseif type(args.uids) == "string" then for u in string.gmatch(args.uids, "[^,]+") do uids[#uids + 1] = u end end
        if #uids == 0 or #uids > 12 then return "uids" end
        local base = V.baseFor(player)
        if base == nil then return "nobase" end
        local t = V.tally(base.id, { k = "admit", uids = uids })
        local cue = V.cue(t)
        V.onAnswered({ baseId = base.id, uids = uids, by = V.keyOf(player) }, args.yes == true)
        if cue ~= nil and t ~= nil and #t.voices > 0 then ALifeCmd.reply(player, "campVote", { text = cue, base = base.name }) end
        return "ok"
    end)
    -- 0.8.8 UI: { uid } = one of a refugee party waiting at your door (Jeem's right-click "Take them in"): the camp's view
    -- now, for the menu. Only to someone who runs that base (Jeem's own check). Answer: "campVoteCue" { uid, text | none }.
    ALifeCmd.onServer("campVoteAsk", function(player, args)
        if not V.on() or type(args) ~= "table" or type(args.uid) ~= "string" then return "args" end
        local j = J()
        local S = j and j.TraderStock or nil
        if not fn(S, "visitOf") or j.BaseAreas == nil then return "nojeem" end
        local ok, visit = pcall(S.visitOf, args.uid)
        if not ok or type(visit) ~= "table" or visit.kind ~= "refugees" or visit.phase ~= "waiting" then return "notwaiting" end
        local base = V.base(visit.baseId)
        if base == nil then return "nobase" end
        local who = fn(j.BaseAreas, "who") and j.BaseAreas.who(player) or {}
        if not fn(j.BaseAreas, "canManage") or j.BaseAreas.canManage(base, who.key, who.faction, who.admin) ~= true then return "notyours" end
        local uids = {}
        for _, m in ipairs(type(visit.members) == "table" and visit.members or {}) do
            if not m.dead and not m.gone and not m.stayed and m.uid ~= nil then uids[#uids + 1] = tostring(m.uid) end
        end
        local t = V.tally(base.id, { k = "admit", uids = uids })
        local cue = (t ~= nil and #t.voices > 0) and V.cue(t) or nil
        ALifeCmd.reply(player, "campVoteCue", { uid = args.uid, text = cue, none = cue == nil })
        return "ok"
    end)
end

-- ---------------------------------------------------------------------------------------------- 0.8.8: exile and lead
-- Sending someone away is Jeem's (faction page "leave" -> R.leaveOne(player, uid); read in Jeem Residents/Server.lua
-- and FactionPage.lua, which looks R.leaveOne up through the table each call). We wrap it: the camp is asked first
-- (who the person is to each of them), and once they're really gone the camp reacts, with a letter in plain words.
function V.residentBase(r)
    local res = mem(r).jimmyResident
    if type(res) ~= "table" or res.baseId == nil then return nil end
    return V.base(res.baseId)
end
function V.exiled(player, uid, t)
    if type(t) ~= "table" then return 0 end
    local key = V.keyOf(player)
    local n = V.react(t, true, key)
    if #t.voices > 0 and player ~= nil then
        local r = rec(uid)
        ALifeCmd.reply(player, "campVote", { text = "You sent " .. (r and first(r) or "them") .. " away. " .. tostring(V.cue(t)), base = t.baseName })
    end
    return n
end
function V.wrapLeave()
    local j = J()
    local R = j and j.Residents or nil
    if not fn(R, "leaveOne") or R.acpLeaveWrapped then return R ~= nil and R.acpLeaveWrapped == true end
    local orig = R.leaveOne
    R.leaveOne = function(player, uid, ...)
        local t = nil
        if V.on() and V.setting("voteExile") ~= false then
            pcall(function()
                local base = V.residentBase(rec(uid))
                if base ~= nil then t = V.tally(base.id, { k = "exile", uid = tostring(uid) }); t.baseName = base.name end
            end)
        end
        local ok, why = orig(player, uid, ...)
        if ok and t ~= nil then pcall(V.exiled, player, uid, t) end
        return ok, why
    end
    R.acpLeaveWrapped = true
    return true
end
-- A new first lieutenant (ALifeLieutenant ltSet): the camp at their base has a view on taking orders from them.
function V.newLead(player, uid)
    if not V.on() or V.setting("voteLead") == false then return nil end
    local r = rec(uid)
    local base = V.residentBase(r)
    if base == nil then return nil end
    local t = V.tally(base.id, { k = "lead", uid = tostring(uid) })
    if t == nil then return nil end
    V.react(t, true, V.keyOf(player))
    if #t.voices > 0 and player ~= nil then
        ALifeCmd.reply(player, "campVote", { text = first(r) .. " is in charge while you're away. " .. tostring(V.cue(t)), base = base.name })
    end
    return t
end

function V.install()
    local j = J()
    if j == nil or not fn(j, "on") then return false end
    pcall(V.wrapLeave) -- (server only: R.leaveOne lives in Jeem's server file; harmless to retry)
    if V.installed then return true end
    j.on("refugeesArrived", function(ev) V.onArrived(ev) end)
    j.on("refugeesJoined", function(ev) V.onAnswered(ev, true) end)
    j.on("refugeesTurnedAway", function(ev) V.onAnswered(ev, false) end)
    V.installed = true
    return true
end

if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok = pcall(V.install)
        log("ready v" .. V.VERSION .. ": the camp has opinions (" .. ((ok and V.installed) and "on Jeem's refugee door" or "Jeem not found: Settle only")
            .. ", " .. (V.on() and "on" or "off") .. ")")
    end)
end
if type(Events) == "table" and Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(V.install) end) end
