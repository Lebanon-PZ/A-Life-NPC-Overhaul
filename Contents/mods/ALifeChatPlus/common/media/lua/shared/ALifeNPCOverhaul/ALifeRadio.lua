-- A-Life NPC Overhaul: how far your voice carries, and the walkie when it doesn't.
--   Up close (A-Life's own 12 / 25 tiles): normal talk, unchanged.
--   Out to 100 tiles, only when you shout ("!" typed at the start or end, or "yell ..." by voice): your own people
--     (residents of a base you belong to) hear you and answer. Past 25 tiles the dead hear it too.
--     Normal talk never carries past A-Life's 12 tiles, so you can't yell by accident.
--   Crouched (sneaking), normal talk is a whisper: only people within 4 tiles hear it. Yelling while crouched is still a yell.
--   Past that: nothing, unless you carry a two-way radio that's on and powered. Then what you say goes over the air to
--     your nearest base, through Jeem's real radio call (RadioCalls.lua): its range is the smaller of your walkie's
--     in-game transmit range and the base's own set (doubled with a radioman at home). Out of range: static.
--   Saying "base", "come in", "on the radio", "over" or "do you copy" goes straight to the radio, even with people near.
-- Over the radio:  status / check in / anyone there   -> each base reports who's home, hurt, out
--                  come to me / I need backup        -> people walk out to you (Jeem's escort), "send two" etc.
--                  hold the base / lock it down      -> everyone at home up and alert
--                  sound the alarm                   -> alarm
--                  stand down / all clear            -> stand down
--                  come home / head back             -> those out head home (radio calls and missions)
--                  we need to scavenge / patrol / go after them -> a mission, if someone at home is willing to go
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeRadio") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeRadio]"
ALifeRadio = ALifeRadio or {}
local RD = ALifeRadio

RD.SPOKEN = 100                 -- tiles your own people can hear you call
RD.NEAR = 25                    -- past this it's a yell (A-Life's loud radius)
RD.WHISPER = 4                  -- crouched, normal talk is a whisper: this far (A-Life's normal is 12)

function RD.crouched(player)
    local ok, s = pcall(function() return player:isSneaking() end)
    return ok and s == true
end

RD.OPS = {
    { op = "standDown", p = { "stand down", "all clear", "false alarm", "relax everyone", "were clear", "we are clear" } },
    { op = "alarm", p = { "sound the alarm", "raise the alarm", "hit the alarm", "everyone up", "wake everyone", "wake everybody" } },
    { op = "hold", p = { "hold the base", "hold the fort", "hold position", "hold your positions", "lock it down", "lock the place down",
        "stay alert", "stay sharp", "keep watch", "dig in", "hold the line" } },
    { op = "home", p = { "come home", "come back", "head home", "head back", "everyone head home", "return to base", "get back to base",
        "get back home", "call them back", "abort the mission", "pull back", "fall back to base", "rtb" } },
    { op = "come", p = { "come to me", "come get me", "need backup", "need back up", "send backup", "send help", "need help",
        "send someone", "send somebody", "get over here", "meet me", "come find me", "i need you here", "come help",
        "need a hand", "send people", "send a couple", "send two", "send everyone", "send everybody" } },
    { op = "status", p = { "status", "report", "check in", "anyone there", "anybody there", "anyone home", "how is everyone",
        "hows everyone", "how are things", "everyone okay", "everyone ok", "everybody okay", "you guys okay", "whats going on",
        "sitrep", "how is the base", "hows the base", "come in", "do you copy", "you there" } },
}
RD.CUES = { "come in", "do you copy", "you copy", "on the radio", "over the radio", "on the walkie", "over the walkie",
    "anyone on this channel", "anybody on this channel" }
RD.OPENERS = { "base", "radio", "home base", "walkie" }      -- only when you START with them: "Base, status."

RD.LINES = {
    static = { "Only static.", "Static. Nothing comes through.", "Just hiss on the line." },
    off = { "The walkie's dead in your hand. It's off." },
    no_power = { "The walkie's dead. Batteries." },
    nobody = { "Nobody answers.", "Silence on the other end." },
    go = { "Copy. %s heading out.", "Copy that. %s going." },
}

local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
local function J() return ProjectALifeJimmy end
local function RA() return J() and J().Residents and J().Residents.radio end
local function Talk() return ProjectALife and ProjectALife.Talk end

local function clean(text)
    local t = " " .. string.lower(tostring(text or "")) .. " "
    t = string.gsub(t, "'", "")
    t = string.gsub(t, "[^%w]", " ")
    t = string.gsub(t, "%s+", " ")
    return t
end
local function has(t, phrase) return string.find(t, " " .. phrase .. " ", 1, true) ~= nil end

function RD.cued(text)
    local t = clean(text)
    for _, c in ipairs(RD.CUES) do if has(t, c) then return true end end
    for _, o in ipairs(RD.OPENERS) do if string.sub(t, 1, #o + 2) == " " .. o .. " " then return true end end
    local raw = string.lower(tostring(text or ""))
    if string.find(raw, "[,;%.]%s*over[%.!]*%s*$") then return true end     -- "...send two, over."
    return false
end

-- what you asked for over the air: an op for Jeem's radio, or an order kind for a mission; nil if neither
function RD.classify(text)
    local t = clean(text)
    local O = ALifeOrders
    if O ~= nil then
        for _, def in ipairs(O.ORDERS or {}) do
            if def.kind ~= "recall" then
                for alt in string.gmatch(def.patterns, "[^|]+") do
                    if has(t, clean(alt):sub(2, -2)) then return nil, def end
                end
            end
        end
    end
    for _, o in ipairs(RD.OPS) do
        for _, p in ipairs(o.p) do if has(t, p) then return o.op end end
    end
    return nil
end

local function position(o)
    if o == nil then return nil end
    local ok, x, y, z = pcall(function() return o:getX(), o:getY(), o:getZ() end)
    if ok then return x, y, z end
    return nil
end

-- ---------------------------------------------------------------- spoken, to 100 tiles
local function residentBase(record)
    local m = type(record) == "table" and record.memory or nil
    return type(m) == "table" and type(m.jimmyResident) == "table" and m.jimmyResident.baseId or nil
end

-- the nearest of your own people who can hear you call (same floor, alive, talkable), or nil
function RD.within(player, radius)
    local T = Talk()
    local Rs = J() and J().Residents
    if T == nil or Rs == nil or type(Rs.isMember) ~= "function" then return nil end
    local best
    for _, l in ipairs(T.listeners(player, radius or RD.SPOKEN)) do
        local baseId = residentBase(l.record)
        if baseId ~= nil and Rs.isMember(baseId, player) == true and (best == nil or l.distance < best.distance) then best = l end
    end
    return best
end

-- yelling that far: the dead hear it as far as you threw your voice
function RD.yell(player, distance)
    if distance == nil or distance <= RD.NEAR then return end
    local x, y, z = position(player)
    if x == nil or type(addSound) ~= "function" then return end
    local r = math.floor(math.min(RD.SPOKEN, distance + 10))
    pcall(addSound, player, math.floor(x), math.floor(y), math.floor(z or 0), r, r)
end

-- ---------------------------------------------------------------- the walkie
local function eachItem(player, fn)
    local function try(item) if item ~= nil and fn(item) then return true end return false end
    local ok = pcall(function()
        if try(player:getPrimaryHandItem()) or try(player:getSecondaryHandItem()) then error("found") end
        local att = player:getAttachedItems()
        if att ~= nil then for i = 0, att:size() - 1 do if try(att:get(i):getItem()) then error("found") end end end
        local items = player:getInventory():getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if try(it) then error("found") end
            local inv = type(it.getInventory) == "function" and it:getInventory() or nil
            if inv ~= nil then
                local inner = inv:getItems()
                for k = 0, inner:size() - 1 do if try(inner:get(k)) then error("found") end end
            end
        end
    end)
    return ok
end

-- your two-way radio: its itemId and range, or nil and why ("no_radio", "off", "no_power")
function RD.walkie(player)
    local ra = RA()
    if ra == nil then return nil, nil, "no_radio" end
    local foundId, foundRange, why = nil, nil, "no_radio"
    eachItem(player, function(item)
        local dd = ra.itemDevice(item)
        if dd == nil then return false end
        local range, w = ra.device(dd, true)
        if range ~= nil then
            local ok, id = pcall(function() return item:getID() end)
            if ok and id ~= nil then foundId, foundRange = id, range; return true end
        elseif w == "off" or w == "no_power" then why = w end
        return false
    end)
    if foundId == nil then return nil, nil, why end
    return foundId, foundRange
end

-- your nearest base with people in it you can run
function RD.nearestBase(player)
    local Jm = J()
    local B = Jm and Jm.BaseAreas
    local ra = RA()
    if B == nil or ra == nil then return nil end
    local who = B.who(player)
    local px, py = position(player)
    local best, bestD
    for _, base in ipairs(B.basesFor(who.key, who.faction, false)) do
        if base.siteId ~= nil and (type(B.canManage) ~= "function" or B.canManage(base, who.key, who.faction, who.admin)) then
            local d = ra.distance(base.id, px, py) or math.huge
            if bestD == nil or d < bestD then best, bestD = base, d end
        end
    end
    return best
end

-- Jeem's own lines, minus the numbers (immersion): "only static" instead of "the base is 412 tiles away"
local function tidy(lines)
    local out = {}
    for _, l in ipairs(lines or {}) do
        if type(l) == "table" and l.k == "IGUI_ALJ_Radio_OutOfRange" then
            out[#out + 1] = (ALifeImmersion and ALifeImmersion.enabled == false)
                and l or ((type(l.a) == "table" and l.a[1] and (tostring(l.a[1]) .. ": ") or "") .. pick(RD.LINES.static))
        else
            out[#out + 1] = l
        end
    end
    return out
end

local function chatter(player, lines, people)
    local ra = RA()
    if ra ~= nil and type(ra.reply) == "function" then pcall(ra.reply, player, lines, people) end
end

local function countFrom(text)
    local O = ALifeOrders
    local n = O and O.partySize and O.partySize(text) or 1
    if n == 4 then return 4 end
    return n
end

-- a mission over the air: someone at home who's willing goes, with mates if you asked
function RD.mission(player, base, range, def, text)
    local Jm, ra, O = J(), RA(), ALifeOrders
    local Rs = Jm.Residents
    local px, py = position(player)
    local home = Rs.atHome(base.id)
    local ok = ra.link(base, range, px, py, home)
    if not ok then return { base.name .. ": " .. pick(RD.LINES.static) } end
    local leader, why
    for _, r in ipairs(home) do
        if r.lifecycle ~= "dead" then
            local no = O.willing(r, player)
            if no == nil then leader = r; break end
            why = why or no
        end
    end
    if leader == nil then return { base.name .. ": " .. pick(O.LINES[why or "refuse"] or RD.LINES.nobody) } end
    local uids = { leader.uid }
    local want = O.partySize(text) - 1
    if want > 0 then for _, u in ipairs(O.freeMatesOf(leader, player, want)) do uids[#uids + 1] = u end end
    local okS, id, whyS = pcall(Rs.missions.start, player, def.kind, uids, {})
    if not okS or id == nil then
        if whyS == "no_grudge" then return { base.name .. ": " .. pick(O.LINES.no_grudge) } end
        return { base.name .. ": " .. pick(O.LINES.cant) }
    end
    local name = (ProjectALife.Names and ProjectALife.Names.of and ProjectALife.Names.of(leader)) or "Someone"
    local who = #uids > 1 and (name .. " and " .. (#uids - 1 == 1 and "one more" or tostring(#uids - 1) .. " more")) or name
    print(TAG .. " " .. def.kind .. " by radio (" .. #uids .. " people): " .. tostring(id))
    return { base.name .. ": " .. string.format(pick(RD.LINES.go), who) }
end

-- the call. true if the walkie was used (whatever came back), false if you have none or nothing radio-like was said
function RD.call(player, text)
    local ra = RA()
    if ra == nil or type(ra.on) ~= "function" or not ra.on() then return false end
    local op, def = RD.classify(text)
    if op == nil and def == nil then
        if not RD.cued(text) then return false end
        op = "status"                    -- "Base, come in" / "anyone on this channel?"
    end
    local itemId, range, why = RD.walkie(player)
    if itemId == nil then
        if why == "off" or why == "no_power" then chatter(player, { pick(RD.LINES[why]) }); return true end
        return false
    end
    local base = RD.nearestBase(player)
    if base == nil then chatter(player, { pick(RD.LINES.nobody) }); return true end
    if def ~= nil then
        chatter(player, RD.mission(player, base, range, def, text))
        return true
    end
    local args = { op = op, src = "item", itemId = itemId }
    if op ~= "status" then args.baseId = base.id end
    if op == "come" then args.count = countFrom(text) end
    local okC, lines, people = pcall(ra.call, player, args)
    if not okC then print(TAG .. " call failed: " .. tostring(lines)); return true end
    -- "come home" also brings back the missions you sent them on, if the call reached the base
    if op == "home" then
        local px, py = position(player)
        local inRange = ra.link(base, range, px, py)
        local M = J().Residents.missions
        if inRange and M ~= nil then
            local n = 0
            pcall(function()
                for id, m in pairs(M.data().list) do
                    if m.baseId == base.id and m.radio == nil and M.recall(player, id) then n = n + 1 end
                end
            end)
            if n > 0 then lines = { base.name .. ": copy, calling everyone in." } end
        end
    end
    chatter(player, tidy(lines), people)
    return true
end

-- ---------------------------------------------------------------- the hook
function RD.install()
    if ALifeMerge and ALifeMerge.skip("radio") then return true end
    if RD.__installed then return true end
    local T = Talk()
    if T == nil or type(T.onPlayerText) ~= "function" then return false end
    RD.__installed = true
    local original = T.onPlayerText
    T.onPlayerText = function(player, text, loud)
        -- talking into the walkie on purpose
        if player ~= nil and RD.cued(text) then
            local ok, used = pcall(RD.call, player, text)
            if ok and used then return true, "radio" end
        end
        -- crouched and not yelling: a whisper, only people right next to you hear it
        local said, reason
        if loud ~= true and RD.crouched(player) and T.settings ~= nil then
            local normal = T.settings.listenRadius
            T.settings.listenRadius = RD.WHISPER
            local ok, s, r = pcall(original, player, text, loud)
            T.settings.listenRadius = normal
            if not ok then print(TAG .. " whisper failed: " .. tostring(s)); return false, "error" end
            said, reason = s, r
        else
            said, reason = original(player, text, loud)
        end
        if reason ~= "nobody" or player == nil then return said, reason end
        -- nobody close: if you shouted, your own people out to 100 tiles hear it (and so do the dead)
        local okW, far = false, nil
        if loud == true then okW, far = pcall(RD.within, player, RD.SPOKEN) end
        if okW and far ~= nil then
            RD.yell(player, far.distance)
            local nowMs = type(getTimestampMs) == "function" and getTimestampMs() or 0
            local okR, line, why = pcall(T.respond, player, far, text, nowMs)
            if okR and line ~= nil then return true, why end
        end
        -- nobody in earshot: the walkie, if you have one
        local okC, used = pcall(RD.call, player, text)
        if okC and used then return true, "radio" end
        return said, reason
    end
    print(TAG .. " ready (spoken to " .. RD.SPOKEN .. " tiles, walkie beyond" .. (RA() and "" or " - Jeem radio NOT found") .. ")")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(RD.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
