-- A-Life NPC Overhaul 0.8.8: YOUR SECOND-IN-COMMAND (server side).
-- You name lieutenants (client: ALifeTalk_Settlement, "you're in charge while I'm gone"), ranked 1st, 2nd. The 1st
-- runs the camp while you're away; the 2nd only when the 1st is gone (dead, or away from the base themselves).
-- While you're away (no player of yours within ltAwayTiles of the base, real hours), they decide, in their own way,
-- only through real calls, and every decision is written down:
--   * people at the door (a Jeem refugee party waiting): they ask the camp (ALifeCampVote) and answer through Jeem's own
--     RefugeeJoin.answer with your key. Cautious people (A-Life temperament veteran / predator) want a clear yes;
--     the rest go with the camp. UNVERIFIED in game: Jeem's answer with a player key instead of a player object
--     (read in source: BaseAreas.who / J.playerKey take a string; notices to a key may not reach anyone). Guarded.
--   * the food (ALifeRations): stores running out -> short rations (a hard one: guards first; a soft one: short);
--     plenty again -> full.
-- When you come back, the one who ran things tells you what happened (ALifeCmd "ltReport": a letter per decision).
-- Jeem's own auto-roster already runs the shifts while you're away; we don't touch it.
require "ALifeNPCOverhaul/ALifeCmd"

ALifeLieutenant = ALifeLieutenant or {}
local L = ALifeLieutenant
local TAG = "[ALifeLieutenant]"
L.VERSION = "0.9.2"
L.DEFAULTS = {
    lieutenants = true,   -- you can leave someone in charge
    ltAwayTiles = 150,    -- you're "away" past this far from the base
    ltAwayHours = 6,      -- hours away before they start deciding
    ltDoor = true,        -- they answer people at the door while you're away
    ltFood = true,        -- they set rations while you're away
    ltPassedCost = 10,    -- how much less a sworn person likes you when passed over for first
    ltStandCost = 8,      -- 0.8.8 UI: most it costs (before who they are and how you get on) to make a lieutenant stand down
    ltStandDays = 7,      -- days in charge before standing down costs all of that
}
L.KEYS = {}
for k in pairs(L.DEFAULTS) do L.KEYS[#L.KEYS + 1] = k end
table.sort(L.KEYS)
L.CAUTIOUS = { veteran = true, predator = true }
L.HARD = { predator = true, veteran = true }
L.metrics = L.metrics or { decisions = 0, reports = 0, door = 0, food = 0 }

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
function L.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = L.DEFAULTS[key] end
    return v
end
function L.on() return L.setting("lieutenants") ~= false end
function L.hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return num(h, 0)
end
function L.store()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeLieutenant") or (L.tmp or {})
    if type(ModData) ~= "table" then L.tmp = s end
    s.by = type(s.by) == "table" and s.by or {}
    return s
end
function L.rowOf(key)
    local s = L.store()
    local row = s.by[tostring(key)]
    if type(row) ~= "table" then row = { lts = {}, log = {} }; s.by[tostring(key)] = row end
    row.lts = type(row.lts) == "table" and row.lts or {}
    row.log = type(row.log) == "table" and row.log or {}
    return row
end

-- ---------------------------------------------------------------------------------------------- who
function L.baseOf(r)
    local res = mem(r).jimmyResident
    if type(res) ~= "table" or res.baseId == nil then return nil end
    local j = J()
    if j == nil or not fn(j.BaseAreas, "base") then return nil end
    local ok, b = pcall(j.BaseAreas.base, res.baseId)
    return ok and type(b) == "table" and b or nil
end
-- the one in charge now: the 1st, else the 2nd (alive, living at a base, home)
function L.inCharge(row)
    for i, uid in ipairs(row.lts) do
        local r = rec(uid)
        if r ~= nil and r.lifecycle ~= "dead" and mem(r).jimmyMission == nil then
            local b = L.baseOf(r)
            if b ~= nil then return r, b, i end
        end
    end
    return nil
end
function L.setLts(key, uids)
    if key == nil or type(uids) ~= "table" then return nil end
    local row, out = L.rowOf(key), {}
    for i, uid in ipairs(uids) do
        if i > 3 then break end
        local r = rec(uid)
        if r ~= nil and r.lifecycle ~= "dead" then out[#out + 1] = tostring(uid) end
    end
    row.lts = out
    return out
end

-- ---------------------------------------------------------------------------------------------- away?
function L.players()
    local j = J()
    local Vi = j and j.Traders and j.Traders.visits or nil
    if fn(Vi, "players") then local ok, l = pcall(Vi.players); if ok and type(l) == "table" then return l end end
    return {}
end
function L.centre(base)
    if type(base) ~= "table" then return nil end
    if tonumber(base.x1) and tonumber(base.x2) then return (base.x1 + base.x2) / 2, (base.y1 + base.y2) / 2 end
    local j = J()
    if j ~= nil and fn(j.BaseAreas, "areasOf") then
        local ok, areas = pcall(j.BaseAreas.areasOf, base.id)
        if ok and type(areas) == "table" and areas[1] ~= nil then
            local a = areas[1]
            return (num(a.x1, 0) + num(a.x2, 0)) / 2, (num(a.y1, 0) + num(a.y2, 0)) / 2
        end
    end
    return nil
end
-- the player of this key near the base (nil = away)
function L.near(key, base)
    local cx, cy = L.centre(base)
    if cx == nil then return nil end
    local far = num(L.setting("ltAwayTiles"), 150)
    for _, p in ipairs(L.players()) do
        if tostring(p.key) == tostring(key) and (p.x - cx) ^ 2 + (p.y - cy) ^ 2 <= far * far then return p.player end
    end
    return nil
end
function L.online(key)
    for _, p in ipairs(L.players()) do if tostring(p.key) == tostring(key) then return p.player end end
    return nil
end

-- ---------------------------------------------------------------------------------------------- deciding
function L.note(row, r, text)
    row.log[#row.log + 1] = { h = L.hours(), who = first(r), text = text }
    while #row.log > 12 do table.remove(row.log, 1) end
    L.metrics.decisions = L.metrics.decisions + 1
    log(first(r) .. ": " .. text)
end
function L.waiting(baseId)
    local j = J()
    local S = j and j.TraderStock or nil
    local out = {}
    if not fn(S, "data") then return out end
    pcall(function()
        for _, visit in pairs(S.data().visits or {}) do
            if visit.kind == "refugees" and visit.phase == "waiting" and tostring(visit.baseId) == tostring(baseId) then out[#out + 1] = visit end
        end
    end)
    return out
end
function L.door(row, key, r, base)
    if L.setting("ltDoor") == false or not fn(ALifeCampVote, "tally") then return 0 end
    local j = J()
    local RJ = j and j.RefugeeJoin or nil
    if not fn(RJ, "answer") then return 0 end
    local n = 0
    for _, visit in ipairs(L.waiting(base.id)) do
        local uids = {}
        for _, m in ipairs(type(visit.members) == "table" and visit.members or {}) do
            if not m.dead and not m.gone and not m.stayed and m.uid ~= nil then uids[#uids + 1] = tostring(m.uid) end
        end
        if #uids > 0 then
            local t = ALifeCampVote.tally(base.id, { k = "admit", uids = uids })
            local cautious = L.CAUTIOUS[temper(r) or ""] == true
            local yes = t ~= nil and (cautious and t.yes > t.no * 2 or (not cautious and t.yes >= t.no))
            -- 0.9.5: who decided, for the gate's Chronicle line (Jeem emits refugeesJoined / TurnedAway inside answer,
            -- so the gate line names the lieutenant and the lieutenant's own "took in" line isn't written twice)
            L.doorBy = { who = first(r) }
            local ok, done = pcall(RJ.answer, L.online(key) or key, uids[1], yes) -- (the player object when they're on)
            local who = #uids == 1 and "someone at the door" or (#uids .. " people at the door")
            if ok and done then
                L.note(row, r, (yes and "took in " or "turned away ") .. who .. (yes and (t.no > 0 and ", not everyone liked it" or "") or (cautious and ", didn't like the look of them" or ", the camp didn't want them")))
                n = n + 1
                L.metrics.door = L.metrics.door + 1
            end
            L.doorBy = nil
        end
    end
    return n
end
function L.food(row, r, base)
    if L.setting("ltFood") == false or not fn(ALifeRations, "daysLeft") or not fn(ALifeRations, "set") then return 0 end
    local days = ALifeRations.daysLeft(base)
    if days == nil then return 0 end
    local level = ALifeRations.levelOf(base.id)
    local hard = L.HARD[temper(r) or ""] == true
    if days < 3 and level == "full" then
        local to = hard and "guards" or "short"
        ALifeRations.set(base, to, "lieutenant")
        L.note(row, r, hard and "put everyone but the guards on half rations, the food was running out" or "cut the rations, the food was running out")
        L.metrics.food = L.metrics.food + 1
        return 1
    end
    if days >= 10 and level ~= "full" then
        ALifeRations.set(base, "full", "lieutenant")
        L.note(row, r, "put everyone back on full rations, there's enough now")
        L.metrics.food = L.metrics.food + 1
        return 1
    end
    return 0
end

-- every game hour, per player who named lieutenants
function L.tick()
    if not L.on() then return 0 end
    local s, now, n = L.store(), L.hours(), 0
    for key, row in pairs(s.by) do
        if type(row) == "table" and type(row.lts) == "table" and #row.lts > 0 then
            local r, base = L.inCharge(row)
            if r ~= nil then
                local here = nil
                if not row.heir then here = L.near(key, base) end -- 0.9.2: an heir (you died) runs it even with the new you there
                if here ~= nil then
                    if row.awaySince ~= nil and #row.log > 0 then L.report(here, row, r) end
                    row.awaySince = nil
                else
                    row.awaySince = row.awaySince or now
                    if now - row.awaySince >= num(L.setting("ltAwayHours"), 6) then
                        n = n + L.door(row, key, r, base) + L.food(row, r, base)
                    end
                end
            end
        end
    end
    return n
end
function L.report(player, row, r)
    local lines = {}
    for _, e in ipairs(row.log) do lines[#lines + 1] = e.text end
    row.log = {}
    if #lines == 0 then return 0 end
    ALifeCmd.reply(player, "ltReport", { who = first(r), uid = tostring(r.uid), lines = lines })
    L.metrics.reports = L.metrics.reports + 1
    return #lines
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    -- { uids = "first,second" }
    ALifeCmd.onServer("ltSet", function(player, args)
        if not L.on() or type(args) ~= "table" or type(args.uids) ~= "string" then return "args" end
        local key = nil
        local R = PA().Reputation
        if fn(R, "playerKey") then local ok, k = pcall(R.playerKey, player); if ok then key = k end end
        if key == nil then return "key" end
        local uids = {}
        for u in string.gmatch(args.uids, "[^,]+") do uids[#uids + 1] = u end
        local before = L.rowOf(tostring(key)).lts[1]
        local now = L.setLts(tostring(key), uids)
        -- 0.8.8: a new 1st (named, or a 2nd moving up) goes past the camp (ALifeCampVote "lead"); the same 1st again doesn't
        if type(now) == "table" and now[1] ~= nil and now[1] ~= before and fn(ALifeCampVote, "newLead") then
            pcall(ALifeCampVote.newLead, player, now[1])
        end
        return "ok"
    end)
end

if type(Events) == "table" then
    if Events.EveryHours ~= nil then
        ALifeSide.stagger("EveryHours", function()
            if type(isClient) == "function" and isClient() then return end -- MP: the server does it
            local ok, err = pcall(L.tick)
            if not ok and not L.tickErr then L.tickErr = true; log("tick error (once): " .. tostring(err)) end
        end)
    end
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function() log("ready v" .. L.VERSION .. ": second-in-command (" .. (L.on() and "on" or "off") .. ")") end)
    end
end
