-- A-Life NPC Overhaul pre-1.0: "I CAN HANDLE THIS" / "FUCK THIS, I'M OUT" (Joe Nov 27: companions aren't smart in a
-- fight with the dead, they get bitten easily).
-- Each of your A-Life companions reads the dead around them about once a second:
--   threat = the dead close by, weighted by distance (within 2 tiles x3, within 5 x1.5, within 9 x1)
--   can take = their weapon (gun with rounds > melee > bare hands) x their health, + friends standing with them
--   (you and your other companions within zedFriendTiles).
-- More threat than they can take: they break away through A-Life's own go_to, to a spot zedFleeTiles away from the
-- middle of the dead, and say so. When the threat falls under half of what they can take for zedCalmMs, they go back
-- to what they were doing (A-Life's own follow / hold_there at their old spot). Never moves anyone raw.
-- A-Life NPCs are zombie bodies too: anything A-Life knows as a person (Perception.activeActorForShell) is not counted.
-- World side (server in MP). Settings: zedOdds, zedTickMs, zedFleeTiles, zedCalmMs, zedFriendTiles, zedNerve.
-- Unverified on 42.21: getCell():getZombieList() covering a dedicated server's loaded area (guarded; no list = no read).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeZedOdds")
ALifeZedOdds = ALifeZedOdds or {}
local Z = ALifeZedOdds
local TAG = "[ALifeZedOdds]"
Z.state = Z.state or {}   -- uid -> { out = true, since, back = { order, x, y, z }, calmAt }
Z.said = Z.said or {}
Z.metrics = Z.metrics or { reads = 0, out = 0, back = 0, held = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

Z.DEFAULTS = {
    zedOdds = true,       -- companions weigh up the dead around them and break away when it's too much
    zedTickMs = 1000,     -- how often they look (ms)
    zedFleeTiles = 10,    -- how far they break away (tiles)
    zedCalmMs = 5000,     -- quiet this long before they go back to what they were doing (ms)
    zedFriendTiles = 6,   -- friends this close count on their side (tiles)
    zedNerve = 100,       -- percent: higher = they stand their ground longer, lower = they bail sooner
}
do
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, k in ipairs(M.fileKeys) do have[k] = true end
        for k, v in pairs(Z.DEFAULTS) do
            if M.settings[k] == nil then M.settings[k] = v end
            if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end
function Z.set(k)
    local M = ALifeLLMTalk
    local v = type(M) == "table" and type(M.settings) == "table" and M.settings[k] or nil
    if v == nil then v = Z.DEFAULTS[k] end
    return v
end
function Z.num(k) return tonumber(Z.set(k)) or tonumber(Z.DEFAULTS[k]) or 0 end

-- pure: the dead around a spot -> threat score + the middle of them. zs = list of { x, y }
function Z.threat(x, y, zs)
    local t, cx, cy, n = 0, 0, 0, 0
    for _, p in ipairs(zs) do
        local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
        local w = d <= 2 and 3 or (d <= 5 and 1.5 or (d <= 9 and 1 or 0))
        if w > 0 then t = t + w; cx = cx + p.x; cy = cy + p.y; n = n + 1 end
    end
    if n == 0 then return 0, nil, nil end
    return t, cx / n, cy / n
end
-- pure: what one person can take. gear = { weapon, gun, ammo }, hp 0..100, friends = count
function Z.capacity(gear, hp, friends, nerve)
    local base = 1.5
    if type(gear) == "table" and gear.weapon ~= nil then
        base = 4
        if gear.gun and (tonumber(gear.ammo) or 0) > 0 then base = 6 + math.min(4, (tonumber(gear.ammo) or 0) / 10) end
    end
    local c = base * math.max(0.2, math.min(100, tonumber(hp) or 100) / 100) + 2 * (tonumber(friends) or 0)
    return c * (tonumber(nerve) or 100) / 100
end
-- pure: the call. returns "out", "back", or nil (no change)
function Z.decide(st, threat, cap, t, calmMs)
    if not (st and st.out) then
        if threat > cap and threat > 0 then return "out" end
        return nil
    end
    if threat < cap * 0.5 then
        if st.calmAt == nil then st.calmAt = t end
        if t - st.calmAt >= calmMs then return "back" end
    else
        st.calmAt = nil
    end
    return nil
end
-- pure: the spot to break away to (away from the middle of the dead)
function Z.fleePoint(x, y, cx, cy, tiles)
    local dx, dy = x - cx, y - cy
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then dx, dy, l = 1, 0, 1 end
    return { x = math.floor(x + dx / l * tiles), y = math.floor(y + dy / l * tiles) }
end

-- the dead near a spot (not A-Life people)
function Z.deadNear(x, y, z, tiles)
    local out = {}
    pcall(function()
        local list = getCell():getZombieList()
        local Perc = PA().Perception
        for i = 0, list:size() - 1 do
            local zb = list:get(i)
            if zb ~= nil and not zb:isDead() and math.floor(zb:getZ()) == math.floor(z)
                    and math.abs(zb:getX() - x) <= tiles and math.abs(zb:getY() - y) <= tiles then
                local person = false
                if fn(Perc, "activeActorForShell") then pcall(function() person = Perc.activeActorForShell(zb) ~= nil end) end
                if not person then out[#out + 1] = { x = zb:getX(), y = zb:getY() } end
            end
        end
    end)
    return out
end

local LINES_OUT = { "Too many! I'm out!", "Nope. Falling back!", "Can't hold this, moving!", "Screw this, back off!" }
local LINES_OK = { "I got this.", "I can handle these.", "Just a few. Easy." }
local function say(uid, shell, player, list, key)
    local M = ALifeLLMTalk
    local t = now()
    if t - (Z.said[uid] or -1e12) < 20000 then return end
    Z.said[uid] = t
    local line = list[((math.floor(t / 1000) + #tostring(uid)) % #list) + 1]
    if type(M) == "table" and fn(M, "say") then pcall(M.say, shell, player, line, { record = PA().ActorRegistry.read(uid) }) end
end

function Z.readOne(player, uid, C)
    local shell = PA().Talk and fn(PA().Talk, "shellFor") and PA().Talk.shellFor(uid) or nil
    if shell == nil then return end
    local x, y, z = shell:getX(), shell:getY(), shell:getZ()
    local zs = Z.deadNear(x, y, z, 9)
    local st = Z.state[uid]
    if #zs == 0 and not (st and st.out) then return end
    Z.metrics.reads = Z.metrics.reads + 1
    local threat, cx, cy = Z.threat(x, y, zs)
    local M = ALifeLLMTalk
    local hp = 100
    if type(M) == "table" and fn(M, "woundState") then
        local ok, w = pcall(M.woundState, uid, shell, PA().ActorRegistry.read(uid))
        if ok and type(w) == "table" and tonumber(w.hp) then hp = tonumber(w.hp) end
    end
    local gear = nil
    if type(ALifeCues) == "table" and fn(ALifeCues, "gearOf") then local ok, g = pcall(ALifeCues.gearOf, shell); if ok then gear = g end end
    local friends, ft = 0, Z.num("zedFriendTiles")
    pcall(function() if (player:getX() - x) ^ 2 + (player:getY() - y) ^ 2 <= ft * ft then friends = friends + 1 end end)
    for _, other in ipairs(C.roster(C.playerKey(player)) or {}) do
        if other ~= uid then
            local os = PA().Talk.shellFor(other)
            if os ~= nil and (os:getX() - x) ^ 2 + (os:getY() - y) ^ 2 <= ft * ft then friends = friends + 1 end
        end
    end
    local cap = Z.capacity(gear, hp, friends, Z.num("zedNerve"))
    st = st or {}
    local call = Z.decide(st, threat, cap, now(), Z.num("zedCalmMs"))
    if call == "out" and cx ~= nil then
        -- remember what they were doing (A-Life's own companion state)
        local r = PA().ActorRegistry.read(uid)
        local cs = type(r) == "table" and type(r.memory) == "table" and type(r.memory.companion) == "table" and r.memory.companion.state or {}
        local back = { order = "follow" }
        if type(cs) == "table" and (cs.move == "hold" or cs.move == "wait" or cs.move == "cover") and type(cs.anchor) == "table" then
            back = { order = "hold_there", x = cs.anchor.x, y = cs.anchor.y, z = cs.anchor.z }
        end
        local p = Z.fleePoint(x, y, cx, cy, Z.num("zedFleeTiles"))
        local ok, done = pcall(C.order, player, { order = "go_to", uid = uid, x = p.x, y = p.y, z = math.floor(z) })
        if ok and done == true then
            Z.state[uid] = { out = true, since = now(), back = back }
            Z.metrics.out = Z.metrics.out + 1
            say(uid, shell, player, LINES_OUT)
        end
    elseif call == "back" then
        local b = st.back or { order = "follow" }
        pcall(C.order, player, { order = b.order, uid = uid, x = b.x, y = b.y, z = b.z })
        Z.state[uid] = nil
        Z.metrics.back = Z.metrics.back + 1
    elseif not st.out and threat > 0 and threat <= cap * 0.5 and #zs >= 2 then
        Z.metrics.held = Z.metrics.held + 1
        say(uid, shell, player, LINES_OK)
    end
end

function Z.tick()
    if Z.set("zedOdds") == false then return end
    local C = PA().Companions
    if not (fn(C, "roster") and fn(C, "playerKey") and fn(C, "order")) then return end
    for _, player in ipairs(ALifeSide.online()) do
        local okK, key = pcall(C.playerKey, player)
        local okR, list = pcall(C.roster, okK and key or nil)
        for _, uid in ipairs(okR and type(list) == "table" and list or {}) do
            local ok, e = pcall(Z.readOne, player, uid, C)
            if not ok and not Z.warned then Z.warned = true; print(TAG .. " read failed (once): " .. tostring(e)) end
        end
    end
end

if type(Events) == "table" and Events.OnTick then
    local last = -1e12
    Events.OnTick.Add(function()
        local t = now()
        if t - last < Z.num("zedTickMs") then return end
        last = t
        pcall(Z.tick)
    end)
end
print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": your companions weigh up the dead (hold or break away)")
return Z
