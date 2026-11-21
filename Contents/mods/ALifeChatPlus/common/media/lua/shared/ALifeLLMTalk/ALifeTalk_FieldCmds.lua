-- A-Life NPC Overhaul 0.8.9: THE REST OF THE COMMANDS (client side).
--   * Who and where for the jobs in shared/ALifeNPCOverhaul/ALifeFieldJobs.lua: one of yours (named, the one you're
--     talking to, else the nearest), and the other person (the one you're talking to who isn't yours, else the nearest
--     stranger; for a message, someone you know by name in your line). Spots: further ahead (scout), off to the side
--     (lure), the nearest body (search).
--   * What they say when a job ends (cmdDone): rough words, never numbers you'd not get from a person.
--   * Done here (no A-Life order behind them): "fall back to <a place you named>" (the named-place orders from 0.7),
--     "take me to your leader" (asked of anyone: their group's leader walks over and you learn their name).
--   * Lookouts call it: someone of yours told to keep a lookout, guard a spot or take point calls out trouble they see.
--   * Food you drop: someone hungry nearby picks it up (yours put it in their bag; others eat it) and thanks you.
--     Single player only: the drop is seen where the drop action completes (the server in MP; unverified there).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_FieldCmds") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeCommands"
require "ALifeNPCOverhaul/ALifeFieldJobs"
require "ALifeLLMTalk/ALifeTalk_Commands"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeTalkCommands) ~= "table" then return end
local K = ALifeTalkCommands
local L = ALifeCommands
local F = ALifeFieldJobs

ALifeFieldCmds = ALifeFieldCmds or {}
local FC = ALifeFieldCmds
local TAG = "[ALifeFieldCmds]"
FC.VERSION = ALifeSide.MOD_VERSION
FC.off = FC.off or {}
FC.metrics = FC.metrics or { warned = 0, dropsSeen = 0, dropsTaken = 0, leaders = 0, places = 0, noTarget = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function minutes() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return math.floor((tonumber(h) or 0) * 60 + 0.5) end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return r end
local function shellOf(uid) local s = nil; pcall(function() s = PA().Talk.shellFor(tostring(uid)) end); return s end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function xy(o) local x, y, z = nil, nil, 0; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function has(list, uid) for _, u in ipairs(list) do if u == uid then return true end end return false end
local function pick(list) local n = #list; if n == 0 then return nil end; local i = 1; pcall(function() i = ZombRand(n) + 1 end); return list[i] end
local function guard(name, f, ...)
    if FC.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then FC.off[name] = true; log("'" .. name .. "' failed, off for this session: " .. tostring(r[2])); return false, nil end
    return true, r[2], r[3]
end

FC.DEFAULTS = {
    lookoutWarn = true,    -- lookouts call out trouble they see
    lookoutTiles = 25,     -- how far a lookout sees trouble (tiles)
    lookoutGapMin = 10,    -- game minutes before the same lookout calls it again
    dropFood = true,       -- someone hungry near you picks up food you drop
    dropFoodMin = 30,      -- game minutes a drop stays "for them"
    dropReach = 8,         -- how close (tiles) someone has to be to the drop
    dropHunger = 40,       -- how hungry (0-100) before they take it
    leaderTrust = 10,      -- take me to your leader: how much they must like you
    leaderReach = 80,      -- take me to your leader: how far away the leader can be (tiles)
}
function FC.setting(k)
    local v = nil -- explicit nil check (0.9.1 fix: "a and b or nil" turned a false setting back into the default)
    if type(M.settings) == "table" then v = M.settings[k] end
    if v == nil then v = FC.DEFAULTS[k] end
    if v == nil then v = L.setting(k) end
    return v
end
local function num(k) return tonumber(FC.setting(k)) or 0 end

-- settings: defaults in, keys listed at load (they'd reset on restart otherwise), rows in Settings (Party and orders)
FC.KEYS = { "lookoutWarn", "lookoutTiles", "lookoutGapMin", "dropFood", "dropFoodMin", "dropReach", "dropHunger", "leaderTrust", "leaderReach",
    "cmd_take_point", "cmd_scout", "cmd_keep_eye", "cmd_search_body", "cmd_lure", "cmd_message", "cmd_feed_them", "cmd_go_place", "cmd_bring_leader" }
for k in pairs(F.DEFAULTS) do FC.KEYS[#FC.KEYS + 1] = k end
FC.ROWS = {
    { "pointTiles", "Orders: take point - how far ahead of you they walk (tiles)", { 4, 6, 10 } },
    { "pointMinutes", "Orders: take point - game minutes before they drop back", { 30, 60, 120 } },
    { "scoutTiles", "Orders: scout ahead - how far out they go (tiles)", { 15, 25, 40 } },
    { "scoutSee", "Orders: scout ahead - how far they see from there (tiles)", { 10, 20, 30 } },
    { "eyeHours", "Orders: keep an eye on someone - game hours they keep watching", { 1, 2, 6 } },
    { "searchMax", "Orders: search a body - most things they take", { 4, 8, 15 } },
    { "lureTiles", "Orders: lure them off - how far off to the side they run (tiles)", { 15, 25, 40 } },
    { "lureNoise", "Orders: lure them off - how far their noise carries (tiles)", { 20, 30, 50 } },
    { "cmdRiskTrust", "Orders: how much harder it is to agree to risky asks (lure, scout, take point) (%)", { 0, 15, 25, 40 } },
    { "feedKeep", "Orders: give them some food - food they keep for themselves", { 0, 1, 2 } },
    { "feedThanks", "Orders: give them some food - how much better the other side thinks of you", { 0, 3, 6 } },
    { "msgReach", "Orders: carry a message - how far away the person may be (tiles)", { 150, 300, 600 } },
    { "msgTilesPerH", "Orders: carry a message - walking speed out of sight (tiles per game hour)", { 100, 150, 250 } },
    { "lookoutWarn", "Orders: lookouts (keep a lookout, guard a spot, take point) call out trouble they see" },
    { "lookoutTiles", "Orders: how far a lookout sees trouble (tiles)", { 15, 25, 40 } },
    { "dropFood", "Party and orders: someone hungry near you picks up food you drop (single player)" },
    { "dropHunger", "Party and orders: how hungry (0-100) before they take food you dropped", { 20, 40, 60 } },
    { "leaderTrust", "Orders: take me to your leader - how much they must like you", { 0, 10, 30 } },
}
function FC.settingsIn()
    if type(M.settings) == "table" then
        for k, v in pairs(FC.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
        for k, v in pairs(F.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for _, k in ipairs(FC.KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
    end
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(FC.ROWS) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Party and orders" end
        end
    end
end
pcall(FC.settingsIn) -- load time

----------------------------------------------------------------------------------------------------------------
-- the two commands done here
----------------------------------------------------------------------------------------------------------------
FC.CMDS = {
    { id = "go_place", group = "Getting around", client = true, mine = true, place = true, noButton = true, label = "go to a place you named",
      words = { "fall back to", "meet me at", "wait for me at", "regroup at", "head to", "go to", "hold at", "wait at", "meet at" },
      say = { "Fall back to the farmhouse.", "Meet me at the bridge." }, what = "Name a place you've named on the map (right-click a spot: name it). They go there and wait for you." },
    { id = "bring_leader", group = "Help me", client = true, noButton = true, label = "take me to your leader",
      words = { "take me to your leader", "bring me your leader", "get your leader", "bring your leader", "i want to talk to your leader",
          "introduce me to your leader", "let me talk to your boss", "take me to your boss", "i want to see your leader", "who's your leader", "whos your leader" },
      say = { "Take me to your leader.", "I want to talk to your boss." }, what = "Ask anyone: if they like you enough and their leader is around, the leader comes over and you learn their name." },
}
function FC.addRows()
    if FC.rowsAdded then return end
    for _, c in ipairs(FC.CMDS) do
        if L.byId[c.id] == nil then
            local at = #L.CMDS + 1
            for i, row in ipairs(L.CMDS) do if row.hidden then at = i; break end end
            table.insert(L.CMDS, at, c)
            L.byId[c.id] = c
        end
    end
    FC.rowsAdded = true
end
FC.addRows()

----------------------------------------------------------------------------------------------------------------
-- named places in a line
----------------------------------------------------------------------------------------------------------------
function FC.placeIn(text)
    if not fn(M, "plNames") or (type(M.settings) == "table" and M.settings.namedPlaces == false) then return nil end
    local low = " " .. string.lower(tostring(text or "")) .. " "
    local best, bl = nil, 0
    local names = M.plNames()
    for _, n in ipairs(names) do
        local w = string.lower(tostring(n))
        local a = #w >= 3 and string.find(low, w, 1, true) or nil
        if a and #w > bl and string.find(string.sub(low, a - 1, a - 1), "%a") == nil then best, bl = n, #w end
    end
    return best
end
-- the place row for a name (the places list lives in QoL's store: M.nbStore().places)
function FC.placeByName(name)
    if name == nil then return nil end
    local found = nil
    pcall(function()
        local st = fn(M, "nbStore") and M.nbStore() or M._qolMem
        local list = type(st) == "table" and st.places or nil
        if type(list) ~= "table" then return end
        for _, pl in ipairs(list) do if pl.name == name then found = pl; return end end
    end)
    return found
end

-- a "go to" with no named place in it is no command: read the line again without this row
function FC.wrapParse()
    if FC.parseWrapped or not fn(L, "parse") then return end
    local orig = L.parse
    L.parse = function(text, ...)
        local c, noun = orig(text, ...)
        if type(c) == "table" and c.place and FC.placeIn(text) == nil then
            c.hidden = true
            local ok, c2, n2 = pcall(orig, text, ...)
            c.hidden = nil
            if ok then return c2, n2 end
            return nil
        end
        return c, noun
    end
    FC.parseWrapped = true
end

----------------------------------------------------------------------------------------------------------------
-- who: one of yours for a job; the other person
----------------------------------------------------------------------------------------------------------------
local function windowUid()
    local W = ALifeWindowTalk
    if fn(W, "window") then
        local ok, win = pcall(W.window)
        if ok and win ~= nil and win.uid ~= nil then return tostring(win.uid) end
    end
    return nil
end
local function lastTalked(ms)
    local la = M.lastAddressee
    if type(la) == "table" and nowMs() - (tonumber(la.at) or 0) < (ms or 4000) then return tostring(la.uid) end
    return nil
end
function FC.oneOfMine(player, text)
    local mine = K.mineNear(player)
    if #mine == 0 then return nil end
    if fn(M, "partyNamed") then
        local ok, named = pcall(M.partyNamed, player, text)
        if ok and named ~= nil and has(mine, tostring(named)) then return tostring(named) end
    end
    local t = lastTalked()
    if t and has(mine, t) then return t end
    local w = windowUid()
    if w and has(mine, w) then return w end
    local px, py = xy(player)
    local best, bd = nil, 1e12
    for _, uid in ipairs(mine) do
        local x, y = xy(shellOf(uid))
        if x ~= nil and d2(x, y, px, py) < bd then best, bd = uid, d2(x, y, px, py) end
    end
    return best
end
-- the other person: the one you're talking to (not yours), else the nearest stranger within 15 tiles
function FC.otherPerson(player, giver)
    local mine = K.mineNear(player)
    for _, u in ipairs({ windowUid(), lastTalked(10000) }) do
        if u ~= nil and u ~= giver and not has(mine, u) then return u end
    end
    local px, py, pz = xy(player)
    if px == nil or not fn(M, "nearbyNpcs") then return nil end
    local ok, list = pcall(M.nearbyNpcs, px, py, pz, 15, giver)
    if not ok or type(list) ~= "table" then return nil end
    table.sort(list, function(a, b) return (a.d2 or 0) < (b.d2 or 0) end)
    for _, row in ipairs(list) do
        local u = tostring(row.record.uid)
        if not has(mine, u) then return u end
    end
    return nil
end
-- a person you know by name in your line (for a message), and what to tell them
local function firstName(r)
    if fn(M, "nameParts") then local ok, p = pcall(M.nameParts, r); if ok and type(p) == "table" and p.first then return tostring(p.first) end end
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    return m.personFirst and tostring(m.personFirst) or nil
end
function FC.namedPerson(player, text, giver)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    local px, py = xy(player)
    local best, bd, at, len = nil, 1e18, nil, 0
    pcall(function()
        for uid, r in pairs(PA().ActorRegistry.records) do
            if type(r) == "table" and r.lifecycle ~= "dead" and tostring(uid) ~= giver then
                local f = firstName(r)
                local fl = f and string.lower(f) or nil
                if fl and #fl >= 3 then
                    local a = string.find(low, "[^%a]" .. fl .. "[^%a]")
                    if a then
                        local known = true
                        if fn(M, "knowsName") then local okK, k = pcall(M.knowsName, tostring(uid), player); known = okK and k == true end
                        if known then
                            local wp = r.worldPosition
                            local d = (px and type(wp) == "table" and tonumber(wp.x)) and d2(wp.x, wp.y, px, py) or 1e17
                            if d < bd then best, bd, at, len = tostring(uid), d, a, #fl end
                        end
                    end
                end
            end
        end
    end)
    if best == nil then return nil end
    local rest = string.sub(low, at + 1 + len)
    rest = string.gsub(rest, "^[%s,:]*", "")
    rest = string.gsub(rest, "^that%s+", "")
    rest = string.gsub(rest, "%s+$", "")
    if rest == "" then rest = tostring(text) end
    return best, rest
end

----------------------------------------------------------------------------------------------------------------
-- where: further ahead, off to the side, the nearest body
----------------------------------------------------------------------------------------------------------------
function FC.facing(player)
    local dx, dy = nil, nil
    pcall(function() local v = player:getForwardDirection(); dx, dy = v:getX(), v:getY() end) -- unverified on 42.21 (guarded)
    if dx == nil or (dx == 0 and dy == 0) then return nil end
    local l = math.sqrt(dx * dx + dy * dy)
    return dx / l, dy / l
end
function FC.bodyNear(player, reach)
    local px, py, pz = xy(player)
    if px == nil then return nil end
    local best, bd = nil, reach * reach
    pcall(function()
        local cell = getCell()
        for dx = -reach, reach do
            for dy = -reach, reach do
                local sq = cell:getGridSquare(math.floor(px) + dx, math.floor(py) + dy, math.floor(pz))
                local list = sq ~= nil and sq:getDeadBodys() or nil
                if list ~= nil and list:size() > 0 then
                    local dd = dx * dx + dy * dy
                    if dd < bd then best, bd = { x = math.floor(px) + dx, y = math.floor(py) + dy, z = math.floor(pz) }, dd end
                end
            end
        end
    end)
    return best
end
function FC.wrapPoint()
    if FC.pointWrapped or not fn(K, "point") then return end
    local orig = K.point
    K.point = function(player, kind, ...)
        local px, py, pz = xy(player)
        if px ~= nil and kind == "far_ahead" then
            local fx, fy = FC.facing(player)
            local t = num("scoutTiles")
            if fx then return { x = math.floor(px + fx * t), y = math.floor(py + fy * t), z = math.floor(pz) } end
            local th = orig(player, "threat")
            if th then return th end
            return nil
        end
        if px ~= nil and kind == "lure" then
            -- off to the side of the trouble, so it's pulled across and away, not through you
            local th = orig(player, "threat")
            local vx, vy = nil, nil
            if th then vx, vy = th.x - px, th.y - py end
            if vx == nil or (vx == 0 and vy == 0) then vx, vy = FC.facing(player) end
            if vx == nil then return nil end
            local l = math.max(0.001, math.sqrt(vx * vx + vy * vy))
            local sx, sy = -vy / l, vx / l
            local t = num("lureTiles")
            return { x = math.floor(px + sx * t), y = math.floor(py + sy * t), z = math.floor(pz) }
        end
        if kind == "body" then return FC.bodyNear(player, math.floor(num("searchReach"))) end
        return orig(player, kind, ...)
    end
    FC.pointWrapped = true
end

----------------------------------------------------------------------------------------------------------------
-- sending: one of yours; the other person rides along (args.target, args.text)
----------------------------------------------------------------------------------------------------------------
local function sayAs(uid, player, line)
    local sh = shellOf(uid)
    if sh ~= nil and line ~= nil and fn(M, "say") then pcall(M.say, sh, player, line, { record = rec(uid) }) end
end
local function noteOrder(uid, kind, ok, why)
    M.lastOrder = M.lastOrder or {}
    M.lastOrder[tostring(uid)] = { kind = kind, obeyed = ok, at = nowMs(), why = why }
    if fn(M, "feel") then pcall(M.feel, uid, ok and "pride" or "irritation", 0.05) end
end
local function nameOf(uid)
    local r = rec(uid)
    return firstName(r) or "someone"
end
FC.ASK_WHO = { "Who?", "Who do you mean?", "Tell who?" }

function FC.wrapTargets()
    if FC.targetsWrapped or not fn(K, "targets") then return end
    local orig = K.targets
    K.targets = function(player, text, c, ...)
        if type(c) == "table" and c.id == "go_place" then -- everyone of yours near, or the one you named
            local mine = K.mineNear(player)
            if fn(M, "partyNamed") then
                local ok, named = pcall(M.partyNamed, player, text)
                if ok and named ~= nil and has(mine, tostring(named)) then return { tostring(named) } end
            end
            return mine
        end
        if type(c) == "table" and c.job ~= nil then
            local one = FC.oneOfMine(player, text)
            return one and { one } or {}
        end
        return orig(player, text, c, ...)
    end
    FC.targetsWrapped = true
end
function FC.wrapFromLine()
    if FC.lineWrapped or not fn(K, "fromLine") then return end
    local orig = K.fromLine
    K.fromLine = function(player, text, ...)
        FC.lastText = text
        local ok, id = pcall(orig, player, text, ...)
        FC.lastText = nil
        if not ok then error(id) end
        return id
    end
    FC.lineWrapped = true
end
function FC.wrapGive()
    if FC.giveWrapped or not fn(K, "give") then return end
    local orig = K.give
    K.give = function(player, c, uids, noun, agreed, ...)
        if type(c) == "table" and c.id == "go_place" then FC.goPlace(player, uids, FC.lastText or noun); return c.id end
        if type(c) == "table" and c.id == "bring_leader" then FC.bringLeader(player, uids[1]); return c.id end
        if type(c) == "table" and c.target and c.job ~= nil then
            local giver = tostring(uids[1] or "")
            local t, text = nil, nil
            if c.job == "message" then t, text = FC.namedPerson(player, FC.lastText or noun or "", giver)
            else t = FC.otherPerson(player, giver) end
            if t == nil then
                FC.metrics.noTarget = FC.metrics.noTarget + 1
                noteOrder(giver, c.id, false, c.job == "message" and "unknown" or "no_target")
                sayAs(giver, player, pick(FC.ASK_WHO))
                return c.id
            end
            local args = { cmd = c.id, uids = giver, agreed = agreed == true or nil, target = t, text = text }
            K.metrics.sent = K.metrics.sent + 1
            K.pendingWho = { giver }
            FC.pendingTarget = FC.pendingTarget or {}
            FC.pendingTarget[giver] = { target = t, text = text, at = nowMs() }
            ALifeCmd.send(player, "cmd", args)
            return c.id
        end
        return orig(player, c, uids, noun, agreed, ...)
    end
    FC.giveWrapped = true
end

----------------------------------------------------------------------------------------------------------------
-- fall back to a named place (0.7 named-place orders: M.plOrder "meet")
----------------------------------------------------------------------------------------------------------------
FC.PLACE_LINES = { ok = { "On my way.", "See you there.", "I'll be there." }, none = { "Where's that?", "Never heard of it.", "Where?" } }
function FC.goPlace(player, uids, text)
    local pl = FC.placeByName(FC.placeIn(text))
    for _, uid in ipairs(uids or {}) do
        local ok = false
        if pl ~= nil and fn(M, "plOrder") then
            local agreed = true
            local chance = L.chance(uid, player, L.byId.go_place)
            local r = 0
            pcall(function() r = ZombRand(100) end)
            if r >= chance then agreed = false end
            if agreed then local okO, res = pcall(M.plOrder, uid, pl.id, "meet"); ok = okO and res == true end
            if not agreed then noteOrder(uid, "go_place", false, "wont"); sayAs(uid, player, pick({ "Not now.", "No." })) end
        end
        if pl == nil then noteOrder(uid, "go_place", false, "no_spot"); sayAs(uid, player, pick(FC.PLACE_LINES.none))
        elseif ok then noteOrder(uid, "go_place", true, nil); sayAs(uid, player, pick(FC.PLACE_LINES.ok)); FC.metrics.places = FC.metrics.places + 1 end
    end
end

----------------------------------------------------------------------------------------------------------------
-- take me to your leader (anyone; their group's leader: A-Life ModuleLeader via ALifeTalkPatch.leaderOf)
----------------------------------------------------------------------------------------------------------------
FC.LEADER_LINES = {
    self = { "You're looking at them.", "That'd be me." }, alone = { "It's just me.", "No leader. Just me." },
    no = { "They don't see just anyone.", "Not a chance.", "I don't know you well enough for that." },
    away = { "They're not around.", "Not here right now." }, ok = { "Wait here. I'll get them.", "Stay put. I'll bring them over." },
    mine = { "I'm with you. You're the leader." },
    hi_warm = { "Heard you wanted to talk.", "So you're the one asking for me." }, hi_cold = { "You wanted to see me. Make it quick.", "What do you want?" },
}
FC.leaderWait = FC.leaderWait or {}
FC.warned = FC.warned or {}
function FC.bringLeader(player, uid)
    if player == nil or uid == nil then return false end
    uid = tostring(uid)
    local P = ALifeTalkPatch
    local r = rec(uid)
    if has(K.mineNear(player), uid) then sayAs(uid, player, pick(FC.LEADER_LINES.mine)); return false end
    if not fn(P, "leaderOf") or r == nil then return false end
    local okL, leader, members = pcall(P.leaderOf, uid)
    if not okL then return false end
    members = type(members) == "table" and members or {}
    local op = F.opinion(r, player)
    local kind
    if leader == nil or tostring(leader) == uid then kind = #members > 1 and "self" or "alone"
    elseif op < num("leaderTrust") then kind = "no"
    else
        local lsh = shellOf(leader)
        local lx, ly = xy(lsh)
        local px, py = xy(player)
        if lsh == nil or lx == nil or px == nil or d2(lx, ly, px, py) > num("leaderReach") ^ 2 then kind = "away"
        else
            local okC, res = pcall(P.claim, tostring(leader), "approach", { player = player, ms = 60000 })
            kind = (okC and res == true) and "ok" or "away"
            if kind == "ok" then FC.leaderWait[tostring(leader)] = { player = player, from = uid, at = nowMs() } end
        end
    end
    if kind == "self" and fn(M, "markKnown") then pcall(M.markKnown, uid, player, "introduced", uid) end
    noteOrder(uid, "bring_leader", kind == "ok" or kind == "self", kind)
    sayAs(uid, player, pick(FC.LEADER_LINES[kind]))
    FC.metrics.leaders = FC.metrics.leaders + 1
    return kind == "ok"
end
function FC.leaderTick()
    local P = ALifeTalkPatch
    local done = {}
    for leader, w in pairs(FC.leaderWait) do
        local c = P and P.own and P.own.claims and P.own.claims[leader] or nil
        if c ~= nil and c.kind == "approach" and type(c.spec) == "table" and c.spec.arrived then
            done[#done + 1] = leader
            if fn(M, "markKnown") then pcall(M.markKnown, leader, w.player, "introduced", w.from) end
            local warm = F.opinion(rec(leader), w.player) >= 20
            sayAs(leader, w.player, pick(warm and FC.LEADER_LINES.hi_warm or FC.LEADER_LINES.hi_cold))
            if fn(P, "claim") then pcall(P.claim, leader, "listen", { player = w.player, ms = 20000 }) end
            if M.logInteraction then pcall(M.logInteraction, leader, "Came over to meet you; " .. nameOf(w.from) .. " fetched them", nil, nil, "event") end
        elseif c == nil or c.kind ~= "approach" or nowMs() - w.at > 70000 then
            done[#done + 1] = leader
        end
    end
    for _, l in ipairs(done) do FC.leaderWait[l] = nil end
end

----------------------------------------------------------------------------------------------------------------
-- a job ended (cmdDone from ALifeFieldJobs)
----------------------------------------------------------------------------------------------------------------
local function rough(n)
    n = tonumber(n) or 0
    if n <= 0 then return nil end
    if n <= 3 then return "a few dead" end
    if n <= 10 then return "a bunch of dead" end
    if n <= 25 then return "a lot of dead" end
    return "a whole crowd of dead"
end
FC.DONE = {
    point_end = { "I'll drop back.", "Your turn up front." }, gone = { "Couldn't do it." },
    contact_dead = { "Hold up. Dead, %s.", "Stop. Dead up ahead, %s.", "Contact, %s." },
    contact_people = { "Hold up. Someone's there, %s.", "People, %s. Get down." },
    scout_clear = { "Nothing out there. %s's clear.", "Clear. Didn't see a thing %s." },
    eye_lost = { "Lost them. Went %s.", "They slipped off, %s." }, eye_lost_nodir = { "Lost them." },
    eye_turned = { "They're turning on us!", "Watch out, they've turned!" }, eye_ok = { "They behaved.", "Nothing to report on them." },
    search_ok = { "Got some things: %s.", "Took %s." }, empty = { "Nothing worth taking.", "Picked clean." },
    too_heavy = { "Can't carry any of it.", "Too heavy, all of it." }, no_body = { "What body?", "I don't see a body." },
    gave_up = { "Couldn't get there.", "Couldn't get to it." },
    lure_ok = { "Lost them.", "Shook them off." }, lure_some = { "Couldn't shake all of them.", "Some are still on me." },
    feed_ok = { "Here. Eat something.", "Take this. You look like you need it." }, no_food = { "I've got nothing to spare.", "I need what I've got." },
    no_target = { "Who?", "Where'd they go?" },
    msg_glad = { "Told them. They were glad to hear from you.", "Passed it on. They seemed happy about it." },
    msg_cold = { "Told them. They didn't want to hear it.", "Passed it on. Didn't go down well." },
    msg_plain = { "Told them.", "Passed it on. They heard me." }, msg_gone = { "Couldn't find them.", "They weren't there." },
}
function FC.mineCmd(id) return id ~= nil and L.byId[tostring(id)] ~= nil and L.byId[tostring(id)].job ~= nil end
function FC.onDone(p)
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    local uid = tostring(p.uid)
    local id = tostring(p.cmd)
    local line = nil
    if id == "message" and p.phase == "told" then
        -- they heard it: it goes in their memory (the AI hears it next time you meet), quietly
        if M.logInteraction and p.target ~= nil then
            pcall(M.logInteraction, tostring(p.target), nameOf(uid) .. " brought word from you: \"" .. tostring(p.text or "") .. "\"", nil, nil, "event")
        end
        return
    end
    -- take point that ended quietly: they dropped back (no longer on watch); after contact they hold and watch
    noteOrder(uid, (id == "take_point" and p.why ~= "contact") and "dropped_back" or id, p.ok == true, p.why)
    if id == "take_point" then
        if p.why == "contact" then
            FC.warned[uid] = { at = minutes(), on = true } -- they just called it; the lookout check doesn't call it twice
            local list = (tonumber(p.hostile) or 0) > 0 and FC.DONE.contact_people or FC.DONE.contact_dead
            line = string.format(pick(list), tostring(p.dir or "up ahead"))
        elseif p.ok then line = pick(FC.DONE.point_end) end
    elseif id == "scout" and p.ok then
        local parts = {}
        local dead = rough(p.dead)
        if dead then parts[#parts + 1] = dead end
        local people = tonumber(p.people) or 0
        if (tonumber(p.hostile) or 0) > 0 then parts[#parts + 1] = (people > 1 and "people" or "someone") .. ", and they didn't look friendly"
        elseif people > 0 then parts[#parts + 1] = people > 1 and "some people" or "someone" end
        local dir = tostring(p.dir or "up there")
        if #parts == 0 then line = string.format(pick(FC.DONE.scout_clear), dir)
        else line = string.upper(string.sub(dir, 1, 1)) .. string.sub(dir, 2) .. ": " .. table.concat(parts, ", ") .. "." end
    elseif id == "keep_eye" then
        if p.why == "lost" then line = p.dir and string.format(pick(FC.DONE.eye_lost), tostring(p.dir)) or pick(FC.DONE.eye_lost_nodir)
        elseif p.why == "turned" then line = pick(FC.DONE.eye_turned)
        elseif p.ok then line = pick(FC.DONE.eye_ok) end
    elseif id == "search_body" and p.ok then
        local names = {}
        for n in string.gmatch(tostring(p.names or ""), "[^|]+") do names[#names + 1] = n end
        line = string.format(pick(FC.DONE.search_ok), #names > 0 and table.concat(names, ", ") or "a few things")
        if M.logInteraction then pcall(M.logInteraction, uid, "Searched a body for you", nil, nil, "event") end
    elseif id == "lure" and p.ok then
        line = pick((tonumber(p.dead) or 0) > 0 and FC.DONE.lure_some or FC.DONE.lure_ok)
        if fn(M, "feel") then pcall(M.feel, uid, "fear", 0.1) end
    elseif id == "feed_them" and p.ok then
        line = pick(FC.DONE.feed_ok)
        local t = tostring(p.target or "")
        -- the other side ate (rough hunger for anyone, A-Life companions eat it themselves from their bag)
        if fn(M, "lifeOf") then pcall(function() local life = M.lifeOf(t); life.hunger = math.max(0, (tonumber(life.hunger) or 0) - 0.35) end) end
        if fn(M, "feel") then pcall(M.feel, t, "gratitude", 0.15) end
        if M.logInteraction then pcall(M.logInteraction, t, nameOf(uid) .. " gave them " .. tostring(p.name or "food") .. " on your word", nil, nil, "event") end
    elseif id == "message" and p.phase == "back" then
        line = pick(FC.DONE["msg_" .. tostring(p.mood or "plain")] or FC.DONE.msg_plain)
        if p.why == "gave_up" then line = pick(FC.DONE.gave_up) end
    end
    if line == nil and not p.ok then
        local w = tostring(p.why or "")
        line = pick(FC.DONE[w] or K.SAY_WHY[w] or FC.DONE.gone)
    end
    sayAs(uid, player, line)
end
function FC.hookDone()
    if FC.doneHooked or not fn(ALifeCmd, "onClient") then return end
    ALifeCmd.onClient("cmdDone", function(p)
        if type(p) ~= "table" or p.uid == nil then return end
        if FC.mineCmd(p.cmd) then guard("done", FC.onDone, p); return end
        return K.onDone(p)
    end)
    FC.doneHooked = true
end

----------------------------------------------------------------------------------------------------------------
-- lookouts call it
----------------------------------------------------------------------------------------------------------------
FC.WATCHING = { lookout = true, guard_spot = true, take_point = true, wait_dawn = true }
FC.WARN = {
    dead = { "Dead, %s!", "Contact, %s!", "Got dead coming, %s." },
    people = { "Someone's out there, %s.", "People, %s. Heads up." },
}
function FC.lookoutTick()
    if FC.setting("lookoutWarn") == false then return end
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    if player == nil or type(M.lastOrder) ~= "table" then return end
    local now = minutes()
    for _, uid in ipairs(K.mineNear(player)) do
        local o = M.lastOrder[uid]
        if not (type(o) == "table" and o.obeyed and FC.WATCHING[tostring(o.kind)]) then FC.warned[uid] = nil end -- off watch: start fresh
        if type(o) == "table" and o.obeyed and FC.WATCHING[tostring(o.kind)] then
            local sh = shellOf(uid)
            local x, y = xy(sh)
            if x ~= nil then
                local reach = num("lookoutTiles")
                local seen = F.around(x, y, reach, player, uid)
                local any = seen.x ~= nil
                local w = FC.warned[uid]
                if any and (w == nil or (not w.on and now - w.at >= num("lookoutGapMin"))) then
                    local list = seen.hostile > 0 and FC.WARN.people or FC.WARN.dead
                    sayAs(uid, player, string.format(pick(list), F.dirWord(x, y, seen.x, seen.y)))
                    FC.warned[uid] = { at = now, on = true }
                    FC.metrics.warned = FC.metrics.warned + 1
                elseif not any and w ~= nil then
                    w.on = false
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- food you drop: someone hungry nearby takes it (single player: the drop action completes here)
----------------------------------------------------------------------------------------------------------------
FC.drops = FC.drops or {}
local function isMP() return ALifeSide.client() end
local function foodKind(item)
    local food = false
    pcall(function() food = instanceof(item, "Food") end)
    if food then
        local bad = false
        pcall(function() bad = item:isRotten() == true end)
        return not bad and "food" or nil
    end
    local water = false
    pcall(function()
        local fc = item:getFluidContainer()
        water = fc ~= nil and not fc:isEmpty() and fc:contains(Fluid.Water)
    end)
    return water and "water" or nil
end
FC.foodKind = foodKind
function FC.noteDrop(action)
    if isMP() or FC.setting("dropFood") == false or type(action) ~= "table" then return end
    local item = action.item
    local kind = item ~= nil and foodKind(item) or nil
    if kind == nil then return end
    local wi = nil
    pcall(function() wi = item:getWorldItem() end)
    if wi == nil then return end
    local x, y, z = nil, nil, 0
    pcall(function() local sq = wi:getSquare(); x, y, z = sq:getX(), sq:getY(), sq:getZ() end)
    if x == nil then return end
    FC.drops[#FC.drops + 1] = { wi = wi, item = item, kind = kind, x = x, y = y, z = z, player = action.character, at = minutes(), tried = {} }
    FC.metrics.dropsSeen = FC.metrics.dropsSeen + 1
end
function FC.wrapDrop()
    if FC.dropWrapped or type(ISDropWorldItemAction) ~= "table" or type(ISDropWorldItemAction.complete) ~= "function" then return FC.dropWrapped == true end
    local orig = ISDropWorldItemAction.complete
    ISDropWorldItemAction.complete = function(self, ...)
        local r = { orig(self, ...) }
        if not FC.off.drop then guard("drop", FC.noteDrop, self) end
        return unpack(r)
    end
    FC.dropWrapped = true
    return true
end
-- how much they want it (0-100): A-Life companions' own needs, else our rough hunger / thirst
function FC.wants(r, kind)
    local v = nil
    pcall(function()
        local C = PA().Companions
        local e = C.entry(r)
        local needs = e and type(e.state) == "table" and e.state.needs or nil
        if type(needs) == "table" then v = tonumber(kind == "water" and needs.thirst or needs.hunger) end
    end)
    if v == nil and fn(M, "lifeOf") then
        pcall(function() local life = M.lifeOf(tostring(r.uid)); v = (tonumber(kind == "water" and life.thirst or life.hunger) or 0) * 100 end)
    end
    return tonumber(v) or 0
end
local function isCompanion(r)
    local yes = false
    pcall(function() local e = PA().Companions.entry(r); yes = type(e) == "table" end)
    return yes
end
-- take it off the ground (vanilla ISGrabItemAction, the single-player steps)
function FC.pickUp(d)
    local item = nil
    local ok = pcall(function()
        item = d.wi:getItem()
        d.wi:getSquare():transmitRemoveItemFromSquare(d.wi)
        d.wi:removeFromWorld()
        d.wi:removeFromSquare()
        d.wi:setSquare(nil)
        item:setWorldItem(nil)
    end)
    return ok and item or nil
end
function FC.takeIt(d, r, sh)
    local item = FC.pickUp(d)
    if item == nil then return false end
    local uid = tostring(r.uid)
    local info = nil
    if fn(M, "itemInfo") then local okI, i = pcall(M.itemInfo, item, d.player); if okI then info = i end end
    if isCompanion(r) then
        pcall(function() sh:getInventory():AddItem(item) end) -- A-Life eats it from their bag when they're hungry
    else
        -- eaten / drunk on the spot
        if fn(M, "lifeOf") then
            pcall(function()
                local life = M.lifeOf(uid)
                if d.kind == "water" then life.thirst = math.max(0, (tonumber(life.thirst) or 0) - 0.4)
                else life.hunger = math.max(0, (tonumber(life.hunger) or 0) - 0.4) end
            end)
        end
    end
    FC.metrics.dropsTaken = FC.metrics.dropsTaken + 1
    if info ~= nil and fn(M, "onGift") and d.player ~= nil then
        pcall(M.onGift, d.player, { record = r, shell = sh, distance = 1 }, { info }, {})
    end
    return true
end
function FC.dropTick()
    if #FC.drops == 0 then return end
    local now = minutes()
    local P = ALifeTalkPatch
    local keep = {}
    for _, d in ipairs(FC.drops) do
        local still = false
        pcall(function() still = d.wi:getSquare() ~= nil end)
        local live = still and now - d.at <= num("dropFoodMin")
        if live and d.uid ~= nil then
            -- someone is on the way
            local r, sh = rec(d.uid), shellOf(d.uid)
            local x, y = xy(sh)
            if r == nil or x == nil then d.uid = nil
            elseif d2(x, y, d.x + 0.5, d.y + 0.5) <= 2.25 then
                FC.takeIt(d, r, sh)
                if P and fn(P, "release") then pcall(P.release, d.uid, "took the food") end
                live = false
            else
                local c = P and P.own and P.own.claims and P.own.claims[d.uid] or nil
                if c == nil or c.kind ~= "leave" then d.uid = nil end -- lost the claim (danger): someone else may come
            end
        end
        if live and d.uid == nil and fn(M, "nearbyNpcs") then
            local okN, list = pcall(M.nearbyNpcs, d.x, d.y, d.z, num("dropReach"), nil)
            if okN and type(list) == "table" then
                table.sort(list, function(a, b) return (a.d2 or 0) < (b.d2 or 0) end)
                for _, row in ipairs(list) do
                    local r, sh = row.record, row.shell
                    local uid = tostring(r.uid)
                    if not d.tried[uid] and F.opinion(r, d.player) > -41 and FC.wants(r, d.kind) >= num("dropHunger")
                            and not (fn(M, "inCombat") and M.inCombat(sh, r) == true) then
                        d.tried[uid] = true
                        if (row.d2 or 99) <= 2.25 then
                            FC.takeIt(d, r, sh)
                            live = false
                        elseif P and fn(P, "claim") then
                            local okC, res = pcall(P.claim, uid, "leave", { anchor = { x = d.x, y = d.y, z = d.z }, ms = 60000, pace = "walk" })
                            if okC and res == true then d.uid = uid end
                        end
                        break
                    end
                end
            end
        end
        if live then keep[#keep + 1] = d end
    end
    FC.drops = keep
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
function FC.install()
    FC.settingsIn()
    FC.addRows()
    FC.wrapParse(); FC.wrapPoint(); FC.wrapTargets(); FC.wrapFromLine(); FC.wrapGive(); FC.hookDone()
    local dropOk = FC.wrapDrop()
    if type(M.winHelp) == "table" and not FC.helpAdded then
        FC.helpAdded = true
        table.insert(M.winHelp, { "Out ahead", "Take point, scout ahead, keep an eye on him, search that body, lure them off, go tell Sam..., give him some food, fall back to <a place you named>, take me to your leader. Lookouts call out what they see." })
    end
    log("ready v" .. FC.VERSION .. ": " .. (#F.CMDS + #FC.CMDS) .. " new commands, lookouts " .. (FC.setting("lookoutWarn") ~= false and "on" or "off")
        .. ", dropped food " .. ((dropOk and FC.setting("dropFood") ~= false) and "on" or "off") .. " (" .. (FC.giveWrapped and FC.pointWrapped and FC.doneHooked and "5/5" or "some") .. " hooks)")
end
FC.wrapParse(); FC.wrapPoint(); FC.wrapTargets(); FC.wrapFromLine(); FC.wrapGive(); FC.hookDone()
if type(Events) == "table" then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() guard("install", FC.install) end) end
    if Events.EveryOneMinute ~= nil then
        Events.EveryOneMinute.Add(function()
            guard("lookout", FC.lookoutTick)
            guard("drops", FC.dropTick)
            local any = false
            for _ in pairs(FC.leaderWait) do any = true; break end
            if any then guard("leader", FC.leaderTick) end
        end)
    end
end
print(TAG .. " loaded v" .. FC.VERSION)
