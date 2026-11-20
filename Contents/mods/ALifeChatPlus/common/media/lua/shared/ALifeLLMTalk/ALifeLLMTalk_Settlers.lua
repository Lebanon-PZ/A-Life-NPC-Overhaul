-- A-Life Talk 0.5.1.8: BASE MEMBERS ON THE ROAD + A-LIFE'S OWN BASE. (0.5.2.9: load repair + Jeem People list note)
-- (1) A settler (someone who lives at your base) can be asked to come along ("come with me", "you're with me",
--     "let's go", the Bond tab / Party window button). They keep living at the base while they travel (a leave):
--     the roster entry and A-Life's home anchor stay; the party owns them while they're with you. Yes / no depends on
--     standing, your bond tier, personality, their base duties (guard, the base left empty, lots of people counting
--     on them), safety and family at the base - a refusal is explained and costs nothing. The party cap applies.
--     "Go to base" / Dismiss send them home to their settler life and routine. Dying while away removes them from
--     the roster and the base's morale takes the hit. Nothing here is distance based (no leaving / falling out when
--     you're far apart) and nobody is ever deleted.
-- (2) A-Life's base is the source of truth: the house A-Life's SafehouseDirector uses for you (a base mark, a vanilla
--     safehouse you own / belong to, or BaseHeat's flagged base - A-Life's own order). Recruiting registers through
--     Director.houseFor (A-Life's own entry point); the settler's home (A-Life's memory.home) is a spot in that house
--     and "home" is the whole house (+ a few tiles), not an 8-tile circle. If the base moves, homes follow. Only
--     without an A-Life base the old anchor (the building you're in) is used.
-- Settings: baseParty, alifeBase. No per-frame work: one 30 s check (only when there are settlers), the rest runs
-- on words, buttons and events.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Settlers") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Settlers"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Settlers") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function shellFor(uid) local pa = PA(); return fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil end
local function listenerOf(uid) local r = rec(uid); if r == nil then return nil end; return { record = r, shell = shellFor(uid) } end
local function opinion(r, player) local v = nil; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end); return v end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("baseParty", true)
setting("alifeBase", true)
setting("jeemAware", true)   -- 0.5.2.9 [pt266u]: say honestly whether Jeem's "Your people" list knows a settler
setting("jeemBase", true)    -- 0.5.11: a Jeem-only base counts as your base (Camp, work zones, settlers)
setting("baseRepair", true)  -- 0.5.2.9 [pt266u]: on load, re-register settlers A-Life / the patch lost
-- (settings rows: ALifeLLMTalk_UIBond)
M.baseCfg = { askGapH = 2, memoMs = 20000, hesitate = 30, cacheMs = 30000, tickMs = 30000, lossKeepH = 72, lossMorale = 15,
    pad = 3, many = 4, few = 1, unsafe = 50 }
M.baseJoinWords = { "come with me", "come along", "you're with me", "you are with me", "youre with me", "let's go", "lets go",
    "come on the road", "tag along", "join my party", "join the party", "join me", "roll with me", "travel with me",
    "head out with me", "come out with me", "walk with me" }
M.baseHomeWords = { "go home", "go back to base", "go to the base", "go to base", "head home", "back to base", "head to the base" }

----------------------------------------------------------------------------------------------------------------
-- roster helpers
----------------------------------------------------------------------------------------------------------------
function M.settlerOf(uid) local s = bucket("settlers")[tostring(uid)]; return type(s) == "table" and s or nil end
function M.settlerAway(uid) local s = M.settlerOf(uid); return s ~= nil and s.away ~= nil end
function M.settlerHome(uid) local s = M.settlerOf(uid); return s ~= nil and s.away == nil end
-- "At base" / "Travelling with you" (nil = not a settler, not in the party)
function M.baseWhere(uid, player)
    uid = tostring(uid)
    local s = M.settlerOf(uid)
    local inParty = M.partyIsMember and M.partyIsMember(uid, player) or bucket("party")[uid] ~= nil
    local note = s and M.jeemNote and M.jeemNote(uid) or nil
    if s and s.away then return "Travelling with you", "lives at your base" .. (note and ("; " .. note) or "") end
    if inParty then return "Travelling with you", nil end
    if s then return "At base", note end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- 0.5.2.9 [pt266u] "its not registering she lives there": the "Your people" window (People / Schedule / Bases /
-- Missions, AutoSchedule, rooms) is NOT A-Life's - it is the Jeem Extension's (mod ProjectALifeJimmy). Jeem lists
-- only people IT moved in (its own "Come live at our base" invite of a whole Allied crew); it marks them on A-Life's
-- record as memory.jimmyResident (A-Life's own JeemResidents adapter checks exactly that). Our settlers live at the
-- base in A-Life's terms (memory.home = the base house, the patch's settler roster, keepMark) and in ours - but Jeem
-- has no public API to add a resident, so we never fake its record. We say it honestly instead, and log the Jeem
-- functions we can see once so it can be wired when Jeem offers one.
----------------------------------------------------------------------------------------------------------------
function M.jeemOn()
    if M.jeemOnCache ~= nil then return M.jeemOnCache end
    local on = false
    local pa = PA()
    if type(pa.JeemResidentsAdapter) == "table" and pa.JeemResidentsAdapter.installed == true then on = true end
    if not on and M.activeModIds then
        for _, id in ipairs(M.activeModIds()) do
            local x = tostring(id)
            if string.sub(x, 1, 1) == "\\" then x = string.sub(x, 2) end
            if x == "ProjectALifeJimmy" then on = true end
        end
    end
    M.jeemOnCache = on
    return on
end
-- the same test as A-Life's own JeemResidents adapter (read only)
function M.jeemResident(uid)
    local r = rec(uid)
    return type(r) == "table" and type(r.memory) == "table" and type(r.memory.jimmyResident) == "table" and r.lifecycle ~= "dead"
end
function M.jeemNote(uid)
    if M.settings.jeemAware == false or not M.jeemOn() then return nil end
    if M.jeemResident(uid) then return nil end
    return "not on Jeem's People list"
end
M.jeemHint = "Jeem Extension's People window only lists people Jeem moved in itself (its \"Come live at our base\" invite, crew must be Allied). A-Life and this mod both count them as living at your base."
-- what Jeem exposes (once per session, console only): global tables named *jimmy* / *jeem* and their resident-ish functions
function M.jeemProbe()
    if M.jeemProbed or M.settings.jeemAware == false or not M.jeemOn() then return M.jeemProbed end
    local seen = {}
    pcall(function()
        for k, v in pairs(_G) do
            local lk = type(k) == "string" and string.lower(k) or ""
            if type(v) == "table" and (string.find(lk, "jimmy", 1, true) or string.find(lk, "jeem", 1, true)) then
                local fns = {}
                for fk, fv in pairs(v) do
                    local lf = type(fk) == "string" and string.lower(fk) or ""
                    if type(fv) == "function" and (string.find(lf, "resid") or string.find(lf, "invite") or string.find(lf, "people")
                            or string.find(lf, "roster") or string.find(lf, "movein") or string.find(lf, "recruit")) and #fns < 20 then fns[#fns + 1] = fk end
                end
                table.sort(fns)
                seen[#seen + 1] = k .. "{" .. table.concat(fns, ",") .. "}"
                if #seen >= 12 then break end
            end
        end
    end)
    table.sort(seen)
    M.jeemProbed = seen
    log("Jeem Extension found: its People list is its own (memory.jimmyResident); API seen: " .. (#seen > 0 and table.concat(seen, " ") or "none"))
    return seen
end
-- (c) load repair: a settler in our roster whose A-Life / patch side went missing or out of step is registered again
-- (the patch's settler roster + A-Life's memory.home at the base; on leave = the leave is re-applied, nobody is moved)
function M.baseRepair(player)
    if M.settings.baseRepair == false then return 0 end
    local P = patch()
    if P == nil or not fn(P, "settlerOf") then return 0 end
    local n = 0
    for uid, e in pairs(bucket("settlers")) do
        uid = tostring(uid)
        local r = rec(uid)
        if type(e) == "table" and r and r.lifecycle ~= "dead" and tonumber(e.x) and tonumber(e.y) then
            local pe = P.settlerOf(uid)
            local m = type(r.memory) == "table" and r.memory or {}
            local home = type(m.home) == "table" and m.home or nil
            local fixed = nil
            if pe == nil and fn(P, "baseSettle") then
                local ok, res = pcall(P.baseSettle, uid, e.x, e.y, e.z or 0, 600000, { key = e.key, src = e.src, bounds = e.bounds or false })
                if ok and res == true then
                    fixed = "registered at the base again"
                    if e.away and fn(P, "baseLeave") then pcall(P.baseLeave, uid, "repair: still travelling with you") end
                end
            elseif pe ~= nil then
                if home == nil or math.floor(tonumber(home.x) or -1) ~= math.floor(e.x) or math.floor(tonumber(home.y) or -1) ~= math.floor(e.y) then
                    if fn(P, "baseRehome") then
                        local ok, res = pcall(P.baseRehome, uid, e.x, e.y, e.z or 0, { key = e.key, src = e.src })
                        if ok and res == true then fixed = "home at the base restored" end
                    end
                end
                if e.away and pe.away == nil and fn(P, "baseLeave") then pcall(P.baseLeave, uid, "repair: travelling with you"); fixed = fixed or "leave re-applied"
                elseif e.away == nil and pe.away ~= nil and fn(P, "baseReturn") then pcall(P.baseReturn, uid); fixed = fixed or "routine at the base restored" end
            end
            if fixed then
                n = n + 1
                e.repairH = hours()
                if M.histAdd then pcall(M.histAdd, uid, "party", "Still lives at the base (" .. fixed .. ")") end
                log("base repair: " .. uid .. " " .. fixed)
            end
        end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- (2) A-Life's base for the player: the same providers, in the same order, as SafehouseDirector.houseFor
-- (mark -> vanilla safehouse claim -> BaseHeat). Read-only unless adopt (then A-Life's own houseFor is called,
-- which registers the player as a resident of that house in A-Life's store - what A-Life does every director pass).
----------------------------------------------------------------------------------------------------------------
M.alifeBaseCache = nil
-- 0.5.11: a base made only with the Jeem Extension (its Bases tool) counts too. Asked last, so an A-Life base still
-- wins. Read only (Jeem's BaseAreas store: basesFor / areasOf / who / canManage). Of the bases you manage: the one
-- you're standing in (or next to), else the nearest. Its grounds are the outline; no grounds = all its areas.
local function jeemAreasBox(areas)
    local g, x1, y1, x2, y2, z = nil, nil, nil, nil, nil, 0
    for _, a in ipairs(areas) do if type(a) == "table" and a.role == "grounds" and tonumber(a.x1) then g = a; break end end
    local use = g and { g } or areas
    for _, a in ipairs(use) do
        if type(a) == "table" and tonumber(a.x1) and tonumber(a.y1) and tonumber(a.x2) and tonumber(a.y2) then
            x1 = x1 and math.min(x1, a.x1) or a.x1; y1 = y1 and math.min(y1, a.y1) or a.y1
            x2 = x2 and math.max(x2, a.x2) or a.x2; y2 = y2 and math.max(y2, a.y2) or a.y2
            if a.roomId == nil and tonumber(a.z) then z = math.floor(a.z) end
        end
    end
    if x1 == nil then return nil end
    return math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), z
end
M.jeemBaseSeen = nil
function M.jeemBaseHouse(player)
    local J = type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil
    local B = J and J.BaseAreas or nil
    if not (fn(B, "basesFor") and fn(B, "areasOf") and fn(B, "who")) then return nil end
    local okW, who = pcall(B.who, player)
    if not okW or type(who) ~= "table" then return nil end
    local okL, list = pcall(B.basesFor, who.key, who.faction, who.admin)
    if not okL or type(list) ~= "table" or #list == 0 then return nil end
    local px, py = pos(player)
    px, py = tonumber(px) or 0, tonumber(py) or 0
    local best, bestD, bx1, by1, bx2, by2, bz = nil, nil, nil, nil, nil, nil, 0
    for _, base in ipairs(list) do
        local okA, areas = pcall(B.areasOf, base.id)
        if okA and type(areas) == "table" then
            local x1, y1, x2, y2, z = jeemAreasBox(areas)
            if x1 then
                local cx, cy = clamp(px, x1, x2), clamp(py, y1, y2)
                local d = (cx - px) * (cx - px) + (cy - py) * (cy - py)
                if bestD == nil or d < bestD then best, bestD, bx1, by1, bx2, by2, bz = base, d, x1, y1, x2, y2, z end
            end
        end
    end
    if best == nil then return nil end
    local h = { key = "jeem:" .. tostring(best.id), x1 = bx1, y1 = by1, x2 = bx2, y2 = by2, z = bz, source = "jeem", name = best.name }
    local p1 = type(best.posts) == "table" and best.posts[1] or nil
    if type(p1) == "table" and tonumber(p1.x) and tonumber(p1.y) then h.mark = { x = tonumber(p1.x), y = tonumber(p1.y) } end
    if M.jeemBaseSeen ~= h.key then
        M.jeemBaseSeen = h.key
        log("camp base from Jeem: " .. tostring(best.name) .. " (" .. tostring(best.id) .. ") " .. bx1 .. "," .. by1 .. " to " .. bx2 .. "," .. by2)
    end
    return h, "jeem"
end
function M.alifeBase(player, adopt)
    if M.settings.alifeBase == false or player == nil then return nil end
    local now = nowMs()
    local c = M.alifeBaseCache
    if not adopt and c ~= nil and c.player == player and now - c.at < M.baseCfg.cacheMs then return c.base end
    local D = PA().SafehouseDirector
    local house, src = nil, nil
    if type(D) == "table" then
        if adopt and fn(D, "houseFor") then
            local ok, h, s = pcall(D.houseFor, player)
            if ok and type(h) == "table" then house, src = h, s end
        end
        if house == nil and fn(D, "markOf") and fn(D, "playerKey") then
            local okK, key = pcall(D.playerKey, player)
            if okK and key ~= nil then local ok, h = pcall(D.markOf, key); if ok and type(h) == "table" then house, src = h, "mark" end end
        end
        if house == nil and fn(D, "claimOf") then local ok, h = pcall(D.claimOf, player); if ok and type(h) == "table" then house, src = h, "safehouse" end end
        if house == nil and fn(D, "baseOf") then local ok, h = pcall(D.baseOf, player); if ok and type(h) == "table" then house, src = h, "baseheat" end end
    end
    if house == nil and M.settings.jeemBase ~= false then house, src = M.jeemBaseHouse(player) end   -- 0.5.11
    local base = nil
    if house ~= nil and tonumber(house.x1) and tonumber(house.y1) and tonumber(house.x2) and tonumber(house.y2) then
        local x1, y1, x2, y2 = math.floor(house.x1), math.floor(house.y1), math.floor(house.x2), math.floor(house.y2)
        local z = math.floor(tonumber(house.z) or 0)
        local sx, sy = tonumber(house.cx) or (x1 + x2) / 2, tonumber(house.cy) or (y1 + y2) / 2
        if type(house.mark) == "table" and tonumber(house.mark.x) then sx, sy = tonumber(house.mark.x), tonumber(house.mark.y) end
        base = { key = tostring(house.key or (x1 .. ":" .. y1 .. ":" .. x2 .. ":" .. y2)), source = tostring(src or house.source or "alife"),
            x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z, x = math.floor(sx), y = math.floor(sy), alife = true }
    end
    M.alifeBaseCache = { at = now, player = player, base = base }
    return base
end
function M.baseOpts(b)
    if b == nil then return { src = "own", bounds = false } end
    return { key = b.key, src = "alife:" .. b.source, bounds = { x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z } }
end

----------------------------------------------------------------------------------------------------------------
-- (1) asking a settler to come along
----------------------------------------------------------------------------------------------------------------
local FAMILY = { partner = true, sibling = true, child = true, parent = true, family = true, spouse = true }
-- who else lives at the base (at home right now, alive)
function M.settlersHome(except)
    local n, list = 0, {}
    for uid, s in pairs(bucket("settlers")) do
        if type(s) == "table" and s.away == nil and tostring(uid) ~= tostring(except) then
            local r = rec(uid)
            if r and r.lifecycle ~= "dead" then n = n + 1; list[#list + 1] = tostring(uid) end
        end
    end
    return n, list
end
function M.baseDuty(uid)
    local s = M.settlerOf(uid) or {}
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if s.role == "guard" or m.stance == "guard" or m.stance == "sentry" or m.garrisonPost ~= nil then return "guard" end
    return s.role
end
-- the decision for a settler (on top of the normal join verdict: standing, cap, personality, A-Life's walk-with)
function M.basePartyVerdict(l, player, inner)
    local uid = tostring(l.record.uid)
    local ok, why, need, v = true, nil, nil, nil
    if type(inner) == "function" then ok, why, need, v = inner(l, player) end
    v = v or opinion(l.record, player) or 0
    if not ok then return false, why, need, v, { kind = "standing" } end
    local lens = M.lens and M.lens(uid) or {}
    local key = ""
    if M.personaKind then local okK, k = pcall(M.personaKind, uid); if okK and type(k) == "string" then key = k end end
    local tier = M.bondTier and M.bondTier(uid) or 1
    local reasons = {}
    local function add(score, kind, text) reasons[#reasons + 1] = { s = score, kind = kind, text = text } end
    -- base duties
    local duty = M.baseDuty(uid)
    if duty == "guard" then add(40 + math.floor((lens.disciplined or 0) * 15), "guard", "you keep watch at the base - somebody has to") end
    local others, list = M.settlersHome(uid)
    local base = M.baseState and M.baseState(player) or nil
    if others <= M.baseCfg.few and #list >= 0 then
        add(15 + ((base and base.safety < 60) and 10 or 0), "empty", others == 0 and "the base would be left empty" or "there'd be hardly anyone left at the base")
    elseif others >= M.baseCfg.many then
        local dutyful = (lens.loyal or 0) + (lens.disciplined or 0) + (lens.kind or 0)
        if dutyful >= 0.4 then add(math.floor(10 + dutyful * 15), "many", "a lot of people at the base count on you") end
    end
    if base and base.safety < M.baseCfg.unsafe then add(15, "unsafe", "the base isn't safe enough to leave right now") end
    -- family at the base
    local fam = nil
    pcall(function()
        for _, t in ipairs(M.tiesOf and M.tiesOf(uid, nil, 8, true) or {}) do
            if not t.dead and FAMILY[t.type] and t.uid and M.settlerHome(t.uid) then fam = t; break end
        end
    end)
    if fam then add(45 + math.floor((lens.loyal or 0) * 15), "family", "you won't leave your " .. tostring(fam.type) .. " " .. tostring(fam.name or "family") .. " at the base") end
    -- the road itself, and temper
    local fear = (lens.fearful or 0) + (lens.paranoid or 0) * 0.5
    if fear > 0.2 then add(math.floor(fear * 40 + 10), "fear", "it's dangerous out there and the walls feel safer") end
    local bold = (lens.brave or 0) + (lens.curious or 0) * 0.7 + (lens.volatile or 0) * 0.3
    local BOLD = { drifter = true, thrill = true, curious = true, mercenary_soul = true, survivalist = true, drifter_bg = true, hunter = true }
    local HOME = { homemaker = true, shy = true, withdrawn = true, nurturing = true, granny = true, grandpa = true, lonely = true, broken = true }
    if BOLD[key] then bold = bold + 0.5 end
    if HOME[key] then add(15, "home", "you finally have a home and you like staying put") end
    -- what pulls them along: the bond and how they feel about you
    local pull = ({ 0, 10, 20, 30, 40 })[clamp(tier, 1, 5)] + math.floor(bold * 20) + math.floor(clamp(v - (tonumber(need) or 30), 0, 60) / 4)
    local push = 0
    for _, r in ipairs(reasons) do push = push + r.s end
    table.sort(reasons, function(a, b) return a.s > b.s end)
    local top = reasons[1]
    M.baseLastScore = { uid = uid, push = push, pull = pull, top = top and top.kind, tier = tier, key = key }
    if push - pull > M.baseCfg.hesitate and top then
        return false, top.text, need, v, { kind = top.kind, push = push, pull = pull }
    end
    local yes
    if tier >= 5 then yes = "you'd go anywhere with them"
    elseif top and top.kind == "family" then yes = "your family will be alright at the base for a while"
    elseif bold > 0.4 then yes = "you've been itching to get out of the base"
    elseif tier >= 3 then yes = "they're a close friend - the base can spare you for a bit"
    else yes = why or "the base can spare you for a while" end
    return true, yes, need, v, { kind = "yes", push = push, pull = pull }
end
-- memo: one answer per ask (the words hook and the chat's own recruit step ask the same question)
M.baseAsks = M.baseAsks or {}
function M.baseAskVerdict(l, player, inner)
    local uid = tostring(l.record.uid)
    local a = M.baseAsks[uid]
    local now = nowMs()
    if a and now - (a.atMs or -1e12) < M.baseCfg.memoMs then return a.ok, a.why, a.need, a.v end
    if a and not a.ok and hours() - (a.h or -1e9) < M.baseCfg.askGapH then
        local r = { ok = false, why = "you asked already - still no (" .. tostring(a.why) .. ")", need = a.need, v = a.v, h = a.h, atMs = now, again = true }
        M.baseAsks[uid] = r
        return false, r.why, r.need, r.v
    end
    local ok, why, need, v, info = M.basePartyVerdict(l, player, inner)
    M.baseAsks[uid] = { ok = ok, why = why, need = need, v = v, h = hours(), atMs = now, kind = info and info.kind }
    M.baseAskLast = { uid = uid, ok = ok, why = why, at = now }
    if M.partyLog then M.partyLog("settler asked to come along: " .. nameOf(l.record) .. " (" .. uid .. ") -> " .. (ok and "yes" or "no") .. " (" .. tostring(why) .. ")") end
    if M.logInteraction then pcall(M.logInteraction, uid, (ok and "Agreed" or "Declined") .. " to leave the base and travel with you (" .. tostring(why) .. ")", nil, nil, "recruit") end
    return ok, why, need, v
end
-- ask through words or a button: the normal recruit path (A-Life walk-with / patch follow order) does the joining
function M.baseAsk(uid, player, how)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    if M.settings.baseParty == false or M.settings.party == false then return false, "off" end
    if not M.settlerHome(uid) then return false, "not at the base" end
    local l = listenerOf(uid)
    if l == nil or l.shell == nil then return false, "not around" end
    local ok, why = M.recruitVerdict(l, player)
    if M.rpPending then M.rpPending[uid] = nil end
    if ok then
        local joined = M.recruitApply and M.recruitApply(l, player) == true
        if joined and not M.settlerAway(uid) then M.baseLeave(uid, player, how or "asked") end
        if joined then
            M.baseVoice(l, player, true, why)
            return true, why
        end
        return false, "couldn't get moving (A-Life refused the follow)"
    end
    M.baseVoice(l, player, false, why)
    return false, why
end
function M.baseVoice(l, player, ok, why)
    local uid = tostring(l.record.uid)
    local fb
    if ok then fb = pick({ "Alright, I'll come. The base can manage without me for a bit.", "Let me grab my things. Let's go.", "About time I got out of here. Lead the way." }, uid .. hours())
    else fb = "Not this time. " .. string.upper(string.sub(tostring(why), 1, 1)) .. string.sub(tostring(why), 2) .. "." end
    fb = string.gsub(fb, "you won't", "I won't"); fb = string.gsub(fb, "you keep", "I keep"); fb = string.gsub(fb, "you finally", "I finally")
    fb = string.gsub(fb, "you like", "I like"); fb = string.gsub(fb, "count on you", "count on me"); fb = string.gsub(fb, "your ", "my ")
    fb = string.gsub(fb, "you've been", "I've been"); fb = string.gsub(fb, "you asked already", "You asked already")
    local what = ok and ("You live at the newcomer's base. They asked you to come travel with them and you agreed (" .. tostring(why) .. "); you still live at the base. Say yes, in your own words")
        or ("You live at the newcomer's base. They asked you to come travel with them and you won't (" .. tostring(why) .. "). Say no kindly and explain; you're still friends")
    local said = false
    if M.react and player then
        said = M.react("baseParty", l, player, { what = what, style = "short, in character, out loud", maxWords = 22, fallback = fb },
            { key = "baseask:" .. uid, keyCooldownMs = 0, modeCooldownMs = 0, urgent = true }) == true
    end
    if not said and M.say and l.shell then M.say(l.shell, player, fb, { record = l.record }) end
    return fb
end
-- on leave: still a settler, the party owns them
function M.baseLeave(uid, player, why)
    uid = tostring(uid)
    local s = M.settlerOf(uid)
    if s == nil or s.away then return false end
    s.away = { h = hours(), why = tostring(why or "party") }
    local P = patch()
    if P and fn(P, "baseLeave") then pcall(P.baseLeave, uid, why)
    elseif P then -- patch 1.4.2: drop the hold order + resident claim by hand
        if fn(P, "releaseOrder") then pcall(P.releaseOrder, uid, "settle") end
        if fn(P, "owner") and P.owner(uid) == "resident" then pcall(P.release, uid, "left the base with the player") end
    end
    if M.keyMem then pcall(M.keyMem, uid, "party", "Left the base for a while to travel with the newcomer") end
    if M.histAdd then pcall(M.histAdd, uid, "party", "Left the base to travel with you (still lives there)") end
    log("settler " .. uid .. " on leave from the base (" .. tostring(why) .. ")")
    return true
end
-- back home: settler life and the daily routine resume (the resident claim comes back on the next own tick)
function M.baseReturn(uid, player, why)
    uid = tostring(uid)
    local s = M.settlerOf(uid)
    if s == nil or s.away == nil then return false end
    s.away = nil
    s.backH = hours()
    local P = patch()
    if P and fn(P, "baseReturn") then pcall(P.baseReturn, uid)
    elseif P and fn(P, "order") then pcall(P.order, uid, "hold", { x = s.x, y = s.y, z = s.z or 0 }, 600000, "settle") end
    if M.histAdd then pcall(M.histAdd, uid, "party", "Went back to the base (" .. tostring(why or "home") .. ")") end
    if M.logInteraction then pcall(M.logInteraction, uid, "Went home to the base (" .. tostring(why or "home") .. ")", nil, nil, "event") end
    log("settler " .. uid .. " back to the base (" .. tostring(why) .. ")")
    return true
end
-- the button state (Bond tab / Party window)
function M.baseAskState(uid, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    if M.settings.baseParty == false then return { label = "Come with me", enabled = false, hint = "Off in the settings (baseParty)." } end
    local s = M.settlerOf(uid)
    if s == nil then return nil end
    local jn = M.jeemNote and M.jeemNote(uid) or nil
    if s.away then return { label = "Go back to base", enabled = true, hint = "Send them home - they pick up their life at the base again." .. (jn and (" " .. M.jeemHint) or ""), home = true } end
    local cap = (M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6)
    local n = M.partyMembers and #M.partyMembers(player) or 0
    if n >= cap then return { label = "Come with me", enabled = false, hint = "Your party is full (" .. n .. "/" .. cap .. ")." } end
    local a = M.baseAsks[uid]
    if a and not a.ok and hours() - (a.h or -1e9) < M.baseCfg.askGapH then
        local left = math.max(1, math.floor((M.baseCfg.askGapH - (hours() - a.h)) * 60 + 0.5))
        return { label = "Come with me", enabled = false, hint = "They said no (" .. tostring(a.why) .. "). Give it " .. left .. " min." }
    end
    if shellFor(uid) == nil then return { label = "Come with me", enabled = false, hint = "They're not around - ask them at the base." } end
    return { label = "Come with me", enabled = true, hint = "Ask them to leave the base for a while and travel with you. They still live there." }
end
function M.baseButton(uid, player)
    local st = M.baseAskState(uid, player)
    if st == nil or not st.enabled then return false, st and st.hint or "not a settler" end
    if st.home then
        if M.partyCommand then return M.partyCommand(uid, "base", player), "sent home" end
        return M.baseReturn(uid, player, "sent home"), "sent home"
    end
    return M.baseAsk(uid, player, "button")
end

----------------------------------------------------------------------------------------------------------------
-- words: "come with me" to a settler at home; "go home" is the party's own command
----------------------------------------------------------------------------------------------------------------
function M.baseOnWords(player, text, loud, hearers)
    if M.settings.baseParty == false or M.settings.party == false or type(text) ~= "string" then return end
    local l = hearers and hearers[1] or nil
    if l == nil or l.record == nil then return end
    local uid = tostring(l.record.uid)
    if not M.settlerHome(uid) then return end
    local low = " " .. string.lower(text) .. " "
    for _, w in ipairs(M.baseHomeWords) do if string.find(low, w, 1, true) then return end end
    local asked = false
    for _, w in ipairs(M.baseJoinWords) do if string.find(low, w, 1, true) then asked = true; break end end
    if not asked then return end
    -- the chat's own recruit step answers "come with me" through the AI (same verdict); only the other words, or no
    -- bridge, are answered here
    local rp = M.rpIntent and M.rpIntent(text) or {}
    if rp.recruit and M.settings.recruiting ~= false and M.bridgeAlive and M.bridgeAlive(nowMs()) then return end
    M.baseLastWords = { uid = uid, at = nowMs() }
    pcall(M.baseAsk, uid, player, "asked")
end

----------------------------------------------------------------------------------------------------------------
-- death while away (or at home): off the roster, the base mourns
----------------------------------------------------------------------------------------------------------------
function M.baseOnDeath(body, uid, killer)
    uid = tostring(uid)
    local s = M.settlerOf(uid)
    if s == nil then return end
    local r = rec(uid)
    local name = r and firstOf(r) or uid
    bucket("settlers")[uid] = nil
    local P = patch()
    if P and fn(P, "baseDrop") then pcall(P.baseDrop, uid, "died")
    elseif P and fn(P, "unsettle") then pcall(P.unsettle, uid) end
    local lost = bucket("baseLost")
    lost[#lost + 1] = { uid = uid, name = name, h = hours(), away = s.away ~= nil }
    while #lost > 12 do table.remove(lost, 1) end
    M.alifeBaseCache = nil
    for o, os in pairs(bucket("settlers")) do
        if type(os) == "table" then
            if M.feel then pcall(M.feel, o, "grief", 0.3, "lost " .. name .. " from the base") end
            if M.keyMem then pcall(M.keyMem, o, "loss", name .. " from the base died" .. (s.away and " out on the road" or "")) end
        end
    end
    log("settler " .. uid .. " died" .. (s.away and " while travelling" or "") .. " - off the base roster, base morale hit")
end
-- recent losses weigh on the base's morale (fading over lossKeepH)
function M.baseLossMorale()
    local hit, h = 0, hours()
    for _, e in ipairs(bucket("baseLost")) do
        local age = h - (tonumber(e.h) or -1e9)
        if age >= 0 and age < M.baseCfg.lossKeepH then hit = hit + M.baseCfg.lossMorale * (1 - age / M.baseCfg.lossKeepH) end
    end
    return math.floor(hit + 0.5)
end

----------------------------------------------------------------------------------------------------------------
-- slow check (30 s, only with settlers): homes follow A-Life's base; settlers left "away" without a party go home
----------------------------------------------------------------------------------------------------------------
function M.baseTick(now)
    local s = bucket("settlers")
    local any = false
    for _ in pairs(s) do any = true; break end
    if not any then return 0 end
    local player = M.homePlayer and M.homePlayer() or ALifeSide.you() -- pre-1.0 MP: settlers are the one shared camp's
    if player == nil then return 0 end
    local n = 0
    local P = patch()
    if not M.baseRepaired then -- 0.5.2.9 [pt266u]: once per session (first check after load)
        M.baseRepaired = true
        local okR, k = pcall(M.baseRepair, player)
        if okR and tonumber(k) then n = n + k end
        pcall(M.jeemProbe)
    end
    -- away but not travelling with you any more (the party dropped them some other way): home
    for uid, e in pairs(s) do
        if type(e) == "table" and e.away and bucket("party")[tostring(uid)] == nil and not (M.partyIsMember and M.partyIsMember(uid, player))
            and not (M.bdInParty and M.bdInParty(uid)) then -- MP: travelling with ANY player counts
            local r = rec(uid)
            if r and r.lifecycle ~= "dead" then M.baseReturn(uid, player, "not travelling any more"); n = n + 1 end
        end
    end
    -- A-Life's base is the home
    if M.settings.alifeBase ~= false and M.settings.settlers ~= false then
        local b = M.alifeBase(player)
        if b ~= nil then
            for uid, e in pairs(s) do
                if type(e) == "table" and e.key ~= b.key then
                    local r = rec(uid)
                    if r and r.lifecycle ~= "dead" then
                        local moved = e.key ~= nil
                        local opts = M.baseOpts(b)
                        local ok = false
                        if P and fn(P, "baseRehome") then ok = select(1, pcall(P.baseRehome, uid, b.x, b.y, b.z, opts)) and true
                        elseif P and fn(P, "baseSettle") and e.away == nil then
                            if fn(P, "unsettle") then pcall(P.unsettle, uid) end
                            ok = select(2, pcall(P.baseSettle, uid, b.x, b.y, b.z, 600000)) == true
                        end
                        if ok then
                            e.x, e.y, e.z, e.key, e.src, e.bounds = b.x, b.y, b.z, b.key, "alife:" .. b.source, opts.bounds
                            n = n + 1
                            if moved and M.histAdd then pcall(M.histAdd, uid, "party", "Moved with the base") end
                        end
                    end
                end
            end
        end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- install (wrappers on functions from other files; idempotent)
----------------------------------------------------------------------------------------------------------------
M._w518 = M._w518 or {}
local function wrapOnce(name, maker)
    if M._w518[name] or type(M[name]) ~= "function" then return end
    M._w518[name] = true
    M[name] = maker(M[name])
end
function M.baseLifeInstall()
    -- the join verdict: settlers at home get the base-aware answer, on top of the party's own verdict (standing,
    -- personality, cap, A-Life's walk-with or the patch's follow order) - wrapped at the party core so it is the last word
    if M.partyInstall then pcall(M.partyInstall) end
    wrapOnce("partyVerdictCore", function(orig) return function(origV, listener, player)
        if M.settings.baseParty ~= false and M.settings.party ~= false and type(listener) == "table" and type(listener.record) == "table"
                and M.settlerHome(listener.record.uid) then
            return M.baseAskVerdict(listener, player, function(l, p) return orig(origV, l, p) end)
        end
        return orig(origV, listener, player)
    end end)
    -- joined the party (any path): a settler goes on leave
    wrapOnce("partyJoin", function(orig) return function(uid, player, why)
        local r = orig(uid, player, why)
        if r and M.settings.baseParty ~= false and M.settlerHome(uid) then pcall(M.baseLeave, uid, player, why) end
        return r
    end end)
    -- left the party (dismissed, sent home, or left on their own): back to the base
    wrapOnce("partyLeave", function(orig) return function(uid, player, why, line)
        if M.settlerAway(uid) and line ~= nil and why == "dismissed" then line = pick({ "Alright. I'll head back to the base.", "Heading home then. See you at the base." }, tostring(uid) .. hours()) end
        local r = orig(uid, player, why, line)
        if M.settlerAway(uid) then pcall(M.baseReturn, uid, player, why) end
        return r
    end end)
    -- "go to base" for a settler on leave: just go home (no re-settling, the original home is kept)
    wrapOnce("partyCommand", function(orig) return function(uid, cmd, player)
        if cmd == "base" and M.settlerOf(uid) ~= nil then
            if M.settlerAway(uid) then return M.partyLeave(tostring(uid), player, "sent home to the base", "Alright. I'll be at the base.") end
            return true
        end
        return orig(uid, cmd, player)
    end end)
    -- settling: A-Life's base is the home (registered through A-Life's houseFor); our anchor only without one
    wrapOnce("settleApply", function(orig) return function(l, player, base, bring)
        local ab = (M.settings.alifeBase ~= false) and M.alifeBase(player, true) or nil
        if ab and type(base) == "table" then -- a copy: never change the caller's base table
            local b2 = {}
            for k, v in pairs(base) do b2[k] = v end
            b2.x, b2.y, b2.z = ab.x, ab.y, ab.z
            base = b2
        end
        local ok = orig(l, player, base, bring)
        if ok then
            local opts = M.baseOpts(ab)
            local P = patch()
            local list = { tostring(l.record.uid) }
            for _, b in ipairs(bring or {}) do list[#list + 1] = tostring(b.uid) end
            for _, u in ipairs(list) do
                local e = M.settlerOf(u)
                if e then e.key, e.src, e.bounds = opts.key, opts.src, (ab and opts.bounds) or nil end
                local pe = P and fn(P, "settlerOf") and P.settlerOf(u) or nil
                if pe and P.settlerOpts then pcall(P.settlerOpts, pe, opts) end
            end
        end
        return ok
    end end)
    -- recent deaths weigh on the base's morale
    -- (the base itself: ALifeLLMTalk_Territory.playerBase already asks A-Life first - mark / safehouse / BaseHeat)
    wrapOnce("baseState", function(orig) return function(player)
        local st = orig(player)
        if type(st) == "table" then
            local hit = M.baseLossMorale()
            if hit > 0 then st.morale = clamp((st.morale or 50) - hit, 0, 100); st.lossHit = hit end
        end
        return st
    end end)
    -- the Party window / LLM: where each member lives
    wrapOnce("partyData", function(orig) return function(player)
        local out = orig(player)
        for _, d in ipairs(out or {}) do
            local w, extra = M.baseWhere(d.uid, player)
            d.where = w and (w .. (extra and (" - " .. extra) or "")) or "Travelling with you"
        end
        return out
    end end)
    if M.baseUIInstall then pcall(M.baseUIInstall) end
end
-- the rows of the Party window: members (with where they live) + settlers at home ("At base")
function M.partyRows(player)
    local out = M.partyData and M.partyData(player) or {}
    if M.settings.baseParty == false then return out end
    local _, list = M.settlersHome(nil)
    table.sort(list)
    for _, uid in ipairs(list) do
        local r = rec(uid)
        if r and not (M.partyIsMember and M.partyIsMember(uid, player)) then
            local act = M.activityLine and select(2, pcall(M.activityLine, uid)) or nil
            out[#out + 1] = { uid = uid, name = nameOf(r), atBase = true, where = "At base", here = shellFor(uid) ~= nil, hp = 100, hurt = "",
                mood = "", opinion = opinion(r, player) or 0, weapon = "", stance = "", order = "", activity = type(act) == "string" and act or nil,
                ask = M.baseAskState(uid, player) }
        end
    end
    return out
end
-- LLM: where they live, the answer to the ask
table.insert(M.requestExtras, function(req, player, listener, now)
    local uid = tostring(listener.record.uid)
    if M.settlerAway(uid) then req.settlerAway = true end
    local a = M.baseAskLast
    if a and a.uid == uid and now - a.at < 15000 then req.baseParty = { ok = a.ok, why = a.why } end
end)
if type(M.playerWordHooks) == "table" then table.insert(M.playerWordHooks, M.baseOnWords) end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
if type(M.eventModes) == "table" and M.reactRequest then M.eventModes.baseParty = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Settlers", function(body, uid, killer) pcall(M.baseOnDeath, body, uid, killer) end)
end
if type(Events) == "table" and type(Events.OnTick) == "table" and type(Events.OnTick.Add) == "function" then
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Settlers", function()
        local now = nowMs()
        if now - last < M.baseCfg.tickMs then return end
        last = now
        local ok, e = pcall(M.baseTick, now)
        if not ok then log("base tick error: " .. tostring(e)) end
    end)
end
if type(Events) == "table" and type(Events.OnGameStart) == "table" and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function() pcall(M.baseLifeInstall) end)
end
pcall(M.baseLifeInstall)
return M
