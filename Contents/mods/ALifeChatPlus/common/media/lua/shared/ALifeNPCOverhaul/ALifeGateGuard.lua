-- A-Life NPC Overhaul 0.8.8: THE GATE GUARD (server side).
-- Put one of your base's people on the gate ("you're on the gate"). When people come to the door (Jeem's refugee visit,
-- "refugeesArrived"), the guard meets them first:
--   * anyone among them who runs with a crowd the guard's people are at war with (A-Life Relations.status "hostile"):
--     the guard sends them off on their own (gateTurnHostile), through Jeem's own RefugeeJoin.answer, and tells you.
--   * everyone else: the guard sizes them up (how many, who they run with, what the camp thinks: ALifeCampVote) and
--     tells you. Near the base: in person (a letter). Away: over the radio, under the walkie rules (your radio on, charge,
--     on the base channel, in range: the client checks, as for check-ins). You answer at Jeem's prompt as always.
--   * nobody answers in gateWaitH hours (you're away, no lieutenant decided): the guard decides, the way the camp leans;
--     a cautious guard (veteran / predator) wants a clear yes.
--   * a would-be plant (0.7.14 saboteur: a grudge from a group you wiped) is noticed by the client's side of this
--     (ALifeTalk_Settlement), only when that visitor really would be one.
-- One guard per base, kept by base (ModData "ALifeGateGuard"). Never someone else's base (Jeem canManage).
-- Jeem calls read in 3806944055: J.on("refugeesArrived", {visitId, baseId}), J.TraderStock.data().visits / visitOf,
-- J.RefugeeJoin.answer(player|key, uid, yes) (also used by ALifeLieutenant; with a key only it's UNVERIFIED in game),
-- J.BaseAreas.base / who / canManage, J.Traders.visits.players / managers.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeGateGuard = ALifeGateGuard or {}
local G = ALifeGateGuard
local TAG = "[ALifeGateGuard]"
G.VERSION = ALifeSide.MOD_VERSION
G.DEFAULTS = {
    gateGuard = true,       -- you can put someone on the gate
    gateTurnHostile = true, -- the guard sends off people who run with your enemies, without asking you
    gateWaitH = 4,          -- hours the guard waits for your answer before deciding (0 = never decides)
    gateSpyChance = 50,     -- % the guard notices a would-be plant among people at the door
}
G.KEYS = { "gateGuard", "gateSpyChance", "gateTurnHostile", "gateWaitH" }
G.CAUTIOUS = { veteran = true, predator = true }
G.metrics = G.metrics or { met = 0, turned = 0, told = 0, decided = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
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
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function temper(r)
    local t = nil
    pcall(function() t = PA().Speech.contextFor(r, nil).temperament end)
    return type(t) == "string" and t or nil
end
function G.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end
function G.on() return G.setting("gateGuard") ~= false end
function G.hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return num(h, 0)
end
function G.store()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeGateGuard") or (G.tmp or {})
    if type(ModData) ~= "table" then G.tmp = s end
    s.by = type(s.by) == "table" and s.by or {}           -- [baseId] = { uid, key, h }
    s.pending = type(s.pending) == "table" and s.pending or {} -- [visitId] = { baseId, h, uids }
    return s
end
function G.base(baseId)
    local j = J()
    if j == nil or not fn(j.BaseAreas, "base") then return nil end
    local ok, b = pcall(j.BaseAreas.base, baseId)
    return ok and type(b) == "table" and b or nil
end
function G.keyOf(player)
    if fn(ALifeCampVote, "keyOf") then return ALifeCampVote.keyOf(player) end
    return nil
end

-- ---------------------------------------------------------------------------------------------- who's on the gate
-- the guard, if still alive, still living there and home (not away on a Jeem mission)
function G.guardOf(baseId)
    local row = G.store().by[tostring(baseId)]
    if type(row) ~= "table" then return nil end
    local r = rec(row.uid)
    if r == nil or r.lifecycle == "dead" then return nil, row end
    local res = mem(r).jimmyResident
    if type(res) ~= "table" or tostring(res.baseId) ~= tostring(baseId) then return nil, row end
    if mem(r).jimmyMission ~= nil then return nil, row end
    return r, row
end
-- { uid } puts them on the gate of the base they live at (yours); { uid, off = true } takes them off
function G.set(player, args)
    if not G.on() then return nil, "off" end
    if type(args) ~= "table" or type(args.uid) ~= "string" then return nil, "args" end
    local j = J()
    if j == nil or j.BaseAreas == nil then return nil, "nojeem" end
    local r = rec(args.uid)
    local res = mem(r).jimmyResident
    if r == nil or type(res) ~= "table" then return nil, "not_resident" end
    local base = G.base(res.baseId)
    if base == nil then return nil, "not_resident" end
    local who = fn(j.BaseAreas, "who") and j.BaseAreas.who(player) or {}
    if not fn(j.BaseAreas, "canManage") or j.BaseAreas.canManage(base, who.key, who.faction, who.admin) ~= true then return nil, "not_yours" end
    local s = G.store()
    local cur = s.by[tostring(base.id)]
    if args.off == true then
        if type(cur) == "table" and tostring(cur.uid) == args.uid then s.by[tostring(base.id)] = nil; return true, nil, base end
        return nil, "not_on_gate"
    end
    s.by[tostring(base.id)] = { uid = args.uid, key = who.key or G.keyOf(player), h = G.hours() }
    return true, nil, base, type(cur) == "table" and cur.uid ~= args.uid and cur.uid or nil
end

-- ---------------------------------------------------------------------------------------------- at the door
function G.visitUids(visitId)
    if fn(ALifeCampVote, "visitUids") then return ALifeCampVote.visitUids(visitId) end
    return {}
end
function G.sizeUp(guard, uids)
    local R = PA().Relations
    local out = { n = #uids, hostile = {}, friendly = {}, names = {} }
    for _, u in ipairs(uids) do
        local m = rec(u)
        if m ~= nil then
            out.names[#out.names + 1] = first(m)
            local st = nil
            if fn(R, "status") then local ok, s = pcall(R.status, guard, m); if ok then st = s end end
            if st == "hostile" then out.hostile[#out.hostile + 1] = first(m)
            elseif st == "friendly" then out.friendly[#out.friendly + 1] = first(m) end
        end
    end
    return out
end
local function count(n) return n == 1 and "one" or (n == 2 and "two" or (n <= 4 and "a few" or "a lot of them")) end
function G.summary(guard, look, cue)
    local s = "People at the gate, " .. count(look.n) .. "."
    if #look.friendly > 0 then s = s .. " " .. look.friendly[1] .. " runs with people we get on with." end
    if cue ~= nil then s = s .. " " .. cue end
    return s
end
-- the owner near the base: (player, 0); online and away: (player, distance); offline: nil
function G.ownerWhere(key, base)
    local L = ALifeLieutenant
    if not fn(L, "players") or not fn(L, "centre") then return nil end
    local cx, cy = L.centre(base)
    for _, p in ipairs(L.players()) do
        if tostring(p.key) == tostring(key) then
            if cx == nil then return p.player, nil end
            local d = math.sqrt((num(p.x, 0) - cx) ^ 2 + (num(p.y, 0) - cy) ^ 2)
            local near = num(L.setting and L.setting("ltAwayTiles") or 150, 150)
            return p.player, d <= near and 0 or d
        end
    end
    return nil
end
-- tell the owner: in person near the base, over the radio away from it (client checks the walkie)
function G.tell(row, base, guard, text, extra)
    local player, d = G.ownerWhere(row.key, base)
    if player == nil then return false end
    local payload = { text = text, who = first(guard), uid = tostring(guard.uid), base = base.name, baseId = base.id }
    for k, v in pairs(extra or {}) do payload[k] = v end
    if d == nil or d <= 0 then
        payload.how = "here"
        ALifeCmd.reply(player, "gateReport", payload)
    else
        local ch = nil
        pcall(function() ch = ALifeWalkie.store().base[tostring(row.key)] end)
        ALifeCmd.reply(player, "walkieIncoming", { kind = "gate", uid = tostring(guard.uid), name = first(guard), ch = ch, baseId = base.id, d = d, lines = { text } })
        payload.how = "radio"
        ALifeCmd.reply(player, "gateReport", payload) -- (the client only keeps it if the call was heard)
    end
    G.metrics.told = G.metrics.told + 1
    return true
end
function G.answer(row, uids, yes)
    local j = J()
    local RJ = j and j.RefugeeJoin or nil
    if not fn(RJ, "answer") or uids[1] == nil then return false end
    local who = (fn(ALifeLieutenant, "online") and ALifeLieutenant.online(row.key)) or row.key
    local ok, done = pcall(RJ.answer, who, uids[1], yes)
    return ok and done ~= nil and done ~= false
end

function G.onArrived(ev)
    if not G.on() or type(ev) ~= "table" then return end
    local guard, row = G.guardOf(ev.baseId)
    if guard == nil then return end
    local base = G.base(ev.baseId)
    local uids = G.visitUids(ev.visitId)
    if base == nil or #uids == 0 then return end
    G.metrics.met = G.metrics.met + 1
    local look = G.sizeUp(guard, uids)
    if #look.hostile > 0 and G.setting("gateTurnHostile") ~= false then
        if G.answer(row, uids, false) then
            G.metrics.turned = G.metrics.turned + 1
            local text = first(guard) .. " sent people away from the gate: " .. look.hostile[1] .. " runs with people we're at war with."
            G.tell(row, base, guard, text, { kind = "turned" })
            if fn(ALifeLieutenant, "rowOf") then -- (in the lieutenant's report too, if you were away)
                pcall(function() ALifeLieutenant.note(ALifeLieutenant.rowOf(row.key), guard, "sent people away at the gate, one of them ran with our enemies") end)
            end
            return
        end
    end
    local cue = nil
    if fn(ALifeCampVote, "ask") then local ok, _, c = pcall(ALifeCampVote.ask, ev.baseId, { k = "admit", uids = uids }); if ok then cue = c end end
    G.store().pending[tostring(ev.visitId)] = { baseId = tostring(ev.baseId), h = G.hours(), uids = uids }
    G.tell(row, base, guard, G.summary(guard, look, cue), { kind = "door", uids = table.concat(uids, ",") })
end

-- every hour: a party still waiting past gateWaitH -> the guard decides (the lieutenant may have already)
function G.tick()
    if not G.on() then return 0 end
    local wait = num(G.setting("gateWaitH"), 4)
    local s, now, n = G.store(), G.hours(), 0
    local done = {}
    for visitId, p in pairs(s.pending) do
        if type(p) ~= "table" then done[#done + 1] = visitId
        else
            local still = G.visitUids(visitId)
            if #still == 0 then done[#done + 1] = visitId
            elseif wait > 0 and now - num(p.h, now) >= wait then
                done[#done + 1] = visitId
                local guard, row = G.guardOf(p.baseId)
                local base = G.base(p.baseId)
                if guard ~= nil and base ~= nil and fn(ALifeCampVote, "tally") then
                    local t = ALifeCampVote.tally(p.baseId, { k = "admit", uids = still })
                    local cautious = G.CAUTIOUS[temper(guard) or ""] == true
                    local yes = t ~= nil and (cautious and t.yes > t.no * 2 or (not cautious and t.yes >= t.no))
                    if G.answer(row, still, yes) then
                        n = n + 1
                        G.metrics.decided = G.metrics.decided + 1
                        local text = first(guard) .. (yes and " let the people at the gate in" or " sent the people at the gate away") .. ", nobody answered."
                        if not G.tell(row, base, guard, text, { kind = "decided" }) and fn(ALifeLieutenant, "rowOf") then
                            pcall(function() ALifeLieutenant.note(ALifeLieutenant.rowOf(row.key), guard, (yes and "let the people at the gate in" or "sent the people at the gate away") .. ", nobody answered") end)
                        end
                    end
                end
            end
        end
    end
    for _, id in ipairs(done) do s.pending[id] = nil end
    return n
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("gateSet", function(player, args)
        local ok, why, base, was = G.set(player, args)
        ALifeCmd.reply(player, "gateSetDone", { uid = type(args) == "table" and args.uid or nil, ok = ok == true, why = why,
            off = type(args) == "table" and args.off == true or nil, base = base and base.name or nil, was = was })
        return ok and "ok" or tostring(why)
    end)
end

function G.install()
    local j = J()
    if j == nil or not fn(j, "on") then return false end
    if G.installed then return true end
    j.on("refugeesArrived", function(ev) local ok, err = pcall(G.onArrived, ev); if not ok then log("arrival error: " .. tostring(err)) end end)
    G.installed = true
    return true
end

if type(Events) == "table" then
    if Events.EveryHours ~= nil then
        ALifeSide.stagger("EveryHours", function()
            if ALifeSide.client() then return end
            local ok, err = pcall(G.tick)
            if not ok and not G.tickErr then G.tickErr = true; log("tick error (once): " .. tostring(err)) end
        end)
    end
    local function start()
        if ALifeSide.client() then return end
        local ok = pcall(G.install)
        if not G.said then
            G.said = true
            log("ready v" .. G.VERSION .. ": the gate guard (" .. ((ok and G.installed) and "on Jeem's refugee door" or "Jeem not found") .. ", " .. (G.on() and "on" or "off") .. ")")
        end
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(start) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(start) end
end
