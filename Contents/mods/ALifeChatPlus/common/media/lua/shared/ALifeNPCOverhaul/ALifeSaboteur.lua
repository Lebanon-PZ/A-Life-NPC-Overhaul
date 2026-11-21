-- A-Life NPC Overhaul 0.7.14: THE SABOTEUR (roadmap, the last piece of 0.7). Wipe out a group and someone may want
-- you to pay for it from the inside (hook in, never replace).
--   * For a month after your people destroy a group (it falls within three days of you killing its people), anyone new
--     who joins your party or moves into your base may be one of theirs: family, a friend, someone who blames you.
--     Nobody is made: it's a real person you recruited.
--   * They give themselves away, fairly, the way people really do: ammunition goes missing from your stores (it's in
--     their pack: search them and it's there), a door to the base is found open in the night, and they lie about where
--     they were (ask them; with the AI on they lie in their own words).
--   * Someone of yours notices first: your camp medic if you have one, otherwise whoever's closest to you. They pull you
--     aside (a decision, front and centre): send the plant away, confront them (they may confess and go, or turn on
--     you), or feed them false information and let the people they report to walk into it.
--   * Leave it too long and they slip away one night with what they took.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "saboteur" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeSaboteur") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeSaboteur = ALifeSaboteur or {}
local L = ALifeSaboteur
local TAG = "[ALifeSaboteur]"
L.VERSION = ALifeSide.MOD_VERSION
L.cfg = { raidedH = 72, windowDays = 30, chance = 0.35, newLines = 8, tellEveryH = 30, noticeAt = 2, leaveAt = 5,
    scanTiles = 30, maxContainers = 60, turnChance = 0.35, reach = 5000, baitDays = 3 }
L.AMMO = { "Bullets", "ShotgunShells" }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { grudges = 0, plants = 0, tells = 0, noticed = 0, exiled = 0, confessed = 0, turned = 0, baited = 0, slipped = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(s) return (hash(s) % 10000) / 10000 end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end
local function record(uid)
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function shellOf(uid)
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "shellFor") then return nil end
    local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
    return ok and s or nil
end
local function first(uid)
    local pa, r = PA(), record(uid)
    local n = "Someone"
    if r and pa and fn(pa.Names, "of") then pcall(function() n = tostring(pa.Names.of(r) or n) end) end
    return string.match(n, "^(%S+)") or n
end
local function letter(player, text, bad) if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, text, nil, nil, nil, bad) end end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.saboteur == false)
end
function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end
local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__Saboteur"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__Saboteur"] = orig
    L.hooked[hookName] = true
    return true
end
function L.store()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "saboteur")
    if not ok or type(b) ~= "table" then return nil end
    b.grudges = type(b.grudges) == "table" and b.grudges or {}
    b.plants = type(b.plants) == "table" and b.plants or {}
    return b
end
function L.planted()
    local s = L.store()
    if s == nil then return nil, nil end
    for uid, p in pairs(s.plants) do if type(p) == "table" and not p.done then return uid, p end end
    return nil, nil
end

----------------------------------------------------------------------------------------------------------------
-- 1. you destroyed a group
----------------------------------------------------------------------------------------------------------------
function L.hookEnded(m)
    return wrap(m, "nbEnded", "nbEnded", function(orig)
        return function(b, reason, ...)
            local active = type(b) == "table" and b.status == "active"
            local r = orig(b, reason, ...)
            if active and L.enabled() and reason == "fallen" and tonumber(b.raidedH) and hours() - b.raidedH <= L.cfg.raidedH then
                L.guard("grudge", function()
                    local s = L.store()
                    s.grudges[#s.grudges + 1] = { id = b.id, name = tostring(b.name or "a group"), h = hours() }
                    while #s.grudges > 6 do table.remove(s.grudges, 1) end
                    L.metrics.grudges = L.metrics.grudges + 1
                    log("you destroyed " .. tostring(b.name) .. ": someone may come for you from the inside")
                end)
            end
            return r
        end
    end)
end
function L.openGrudge()
    local s = L.store()
    local h = hours()
    for i = #s.grudges, 1, -1 do
        local g = s.grudges[i]
        if h - (tonumber(g.h) or -1e9) <= L.cfg.windowDays * 24 and not g.used then return g end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- 2. someone new joins
----------------------------------------------------------------------------------------------------------------
function L.isNew(uid)
    local m = M()
    if not fn(m, "store") then return true end
    local ok, st = pcall(m.store)
    local row = ok and type(st) == "table" and type(st.npcs) == "table" and st.npcs[tostring(uid)] or nil
    return row == nil or type(row.lines) ~= "table" or #row.lines < L.cfg.newLines
end
function L.consider(uid, player)
    uid = tostring(uid)
    local s = L.store()
    if s == nil or s.plants[uid] ~= nil or L.planted() ~= nil then return end
    local g = L.openGrudge()
    if g == nil or not L.isNew(uid) then return end
    local O = ALifeOathWatch
    if fn(O, "isSworn") and O.isSworn(uid) then return end
    if roll(uid .. "#plant#" .. tostring(g.id)) >= L.cfg.chance then return end
    g.used = true
    s.plants[uid] = { from = g.name, h = hours(), tells = 0, kinds = {}, lastTell = hours() }
    L.metrics.plants = L.metrics.plants + 1
    log("a plant from " .. g.name .. " is among your people")
end
function L.hookJoin(m)
    wrap(m, "partyJoin", "partyJoin", function(orig)
        return function(uid, player, why, ...)
            local ok = orig(uid, player, why, ...)
            if ok and L.enabled() then L.guard("join", L.consider, uid, player) end
            return ok
        end
    end)
    return wrap(m, "settleApply", "settleApply", function(orig)
        return function(l, player, base, bring, ...)
            local ok = orig(l, player, base, bring, ...)
            if ok and L.enabled() and type(l) == "table" and type(l.record) == "table" then L.guard("join", L.consider, l.record.uid, player) end
            return ok
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 3. the tells (real ones)
----------------------------------------------------------------------------------------------------------------
local function base(player)
    local m = M()
    if not fn(m, "playerBase") then return nil end
    local ok, b = pcall(m.playerBase, player)
    return ok and type(b) == "table" and tonumber(b.x1) and b or nil
end
local function isAmmo(it)
    local t = ""
    pcall(function() t = it:getFullType() end)
    for _, k in ipairs(L.AMMO) do if string.find(t, k, 1, true) then return true end end
    return false
end
-- one box or handful of rounds out of the stores and into their pack
function L.takeAmmo(b, sh)
    local taken = nil
    pcall(function()
        local cell = getCell()
        local cx, cy = math.floor((b.x1 + b.x2) / 2), math.floor((b.y1 + b.y2) / 2)
        local r, seen = L.cfg.scanTiles, 0
        for x = math.max(b.x1, cx - r), math.min(b.x2, cx + r) do
            for y = math.max(b.y1, cy - r), math.min(b.y2, cy + r) do
                local sq = cell:getGridSquare(x, y, 0)
                local objs = sq and sq:getObjects() or nil
                for i = 0, (objs and objs:size() or 0) - 1 do
                    local cont = nil
                    pcall(function() cont = objs:get(i):getContainer() end)
                    if cont ~= nil then
                        seen = seen + 1
                        local items = cont:getItems()
                        for j = items:size() - 1, 0, -1 do
                            local it = items:get(j)
                            if isAmmo(it) then
                                cont:DoRemoveItem(it)
                                sh:getInventory():AddItem(it)
                                taken = it:getDisplayName()
                                return
                            end
                        end
                        if seen >= L.cfg.maxContainers then return end
                    end
                end
            end
        end
    end)
    return taken
end
-- a door on the edge of your base, left open in the night
function L.openDoor(b)
    local opened = false
    pcall(function()
        local cell = getCell()
        for x = b.x1 - 1, b.x2 + 1 do
            for y = b.y1 - 1, b.y2 + 1 do
                local edge = x <= b.x1 + 1 or x >= b.x2 - 1 or y <= b.y1 + 1 or y >= b.y2 - 1
                if edge then
                    local sq = cell:getGridSquare(x, y, 0)
                    local objs = sq and sq:getObjects() or nil
                    for i = 0, (objs and objs:size() or 0) - 1 do
                        local o = objs:get(i)
                        -- the same checks A-Life's own door code makes (isBarricaded isn't on every door)
                        if instanceof(o, "IsoDoor") and not o:IsOpen() and not (type(o.isBarricaded) == "function" and o:isBarricaded()) then
                            o:ToggleDoorSilent()
                            opened = true
                            return
                        end
                    end
                end
            end
        end
    end)
    return opened
end
function L.tell()
    local uid, p = L.planted()
    if uid == nil then return end
    local player = playerOf()
    local h = hours()
    if h - (tonumber(p.lastTell) or 0) < L.cfg.tellEveryH then return end
    local b = base(player)
    local sh = shellOf(uid)
    if b == nil or sh == nil then return end
    local night = false
    pcall(function() local t = getGameTime():getTimeOfDay(); night = t >= 22 or t < 5 end)
    local kind, what = nil, nil
    if night and not p.kinds.door then
        if L.openDoor(b) then kind, what = "door", "a door to the base was open in the night" end
    end
    if kind == nil then
        local got = L.takeAmmo(b, sh)
        if got then kind, what = "ammo", "ammunition keeps coming up short (" .. tostring(got) .. " gone)" end
    end
    if kind == nil and night then kind, what = "away", first(uid) .. " wasn't in bed in the night, and says they were" end
    if kind == nil then return end
    p.lastTell = h
    p.tells = (tonumber(p.tells) or 0) + 1
    p.kinds[kind] = (p.kinds[kind] or 0) + 1
    p.seen = type(p.seen) == "table" and p.seen or {}
    p.seen[#p.seen + 1] = what
    L.metrics.tells = L.metrics.tells + 1
    log("tell #" .. p.tells .. ": " .. kind)
    if p.tells >= L.cfg.leaveAt and not p.noticed then L.slip(uid, p, player) return end
    if p.tells >= L.cfg.noticeAt and not p.noticed and not p.ignored then L.notice(uid, p, player) end
end

----------------------------------------------------------------------------------------------------------------
-- 4. someone of yours notices first
----------------------------------------------------------------------------------------------------------------
function L.noticer(plant, player)
    local m = M()
    if not fn(m, "cpPeople") then return nil end
    local ok, list = pcall(m.cpPeople, player)
    local medic, best, bestL = nil, nil, -1
    local B = ALifeBonds
    for _, u in ipairs(ok and type(list) == "table" and list or {}) do
        u = tostring(u)
        if u ~= plant then
            if fn(m, "cpRoleOf") and m.cpRoleOf(u) == "medic" and medic == nil then medic = u end
            local love = 0
            if fn(B, "keyOf") and fn(B, "row") then pcall(function() local row = B.row(B.keyOf(player), u, false); love = row and tonumber(row.l) or 0 end) end
            if love > bestL then best, bestL = u, love end
        end
    end
    return medic or best
end
function L.notice(uid, p, player)
    local m = M()
    local who = L.noticer(uid, player)
    p.noticed = hours()
    L.metrics.noticed = L.metrics.noticed + 1
    local name, wName = first(uid), who and first(who) or "Someone"
    if who and fn(m, "keyMem") then pcall(m.keyMem, who, "suspicion", "Noticed " .. name .. " is up to something: " .. table.concat(p.seen or {}, "; ")) end
    local text = wName .. " pulls you aside, quiet. <LINE> <LINE> \"" .. table.concat(p.seen or {}, ". ") .. ". I think it's " .. name
        .. ". They came to us right after what happened to " .. tostring(p.from) .. ".\""
    local card = { id = "saboteur:" .. uid, title = wName .. " has something to tell you", text = text, default = 4,
        choices = {
            { label = "Send " .. name .. " away", fn = function() L.exile(uid, player, "you sent them away") end },
            { label = "Confront " .. name, fn = function() L.confront(uid, player) end },
            { label = "Feed them false information", fn = function() L.bait(uid, player) end },
            { label = "Not now", fn = function() p.ignored = hours() end },
        } }
    if ALifeSide.canOutCard() then pcall(ALifeSide.outCard, player, card) else letter(player, wName .. " thinks " .. name .. " is working against you.", true) end
end

----------------------------------------------------------------------------------------------------------------
-- 5. what you do about it
----------------------------------------------------------------------------------------------------------------
function L.remove(uid, player, why)
    local m = M()
    if fn(m, "partyIsMember") and m.partyIsMember(uid, player) and fn(m, "partyLeave") then pcall(m.partyLeave, uid, player, why) end
    if fn(m, "baseLeave") then pcall(m.baseLeave, uid, player, "fed up") end
end
function L.exile(uid, player, why)
    local s = L.store()
    local p = s.plants[uid]
    if p == nil then return end
    p.done = "exiled"
    L.metrics.exiled = L.metrics.exiled + 1
    L.remove(uid, player, why)
    local m = M()
    local sh = shellOf(uid)
    if sh and fn(m, "say") then pcall(m.say, sh, player, "...Fine. You'd have found out anyway.", { record = record(uid) }) end
    if fn(m, "keyMem") then pcall(m.keyMem, uid, "exiled", "Sent away from the newcomer's camp for working against them, for " .. tostring(p.from)) end
    if fn(m, "cpLog") then pcall(m.cpLog, "morale", first(uid) .. " was sent away") end
    letter(player, first(uid) .. " is gone from your camp.")
end
function L.confront(uid, player)
    local s = L.store()
    local p = s.plants[uid]
    if p == nil then return end
    local m = M()
    local sh = shellOf(uid)
    local name = first(uid)
    -- the more you've caught them at, the less room to lie; the cornered may still fight
    local turn = roll(uid .. "#turn") < L.cfg.turnChance and (tonumber(p.tells) or 0) < 4
    if turn then
        p.done = "turned"
        L.metrics.turned = L.metrics.turned + 1
        L.remove(uid, player, "exposed")
        if fn(m, "addGrudge") then pcall(m.addGrudge, uid, 80, "exposed as a plant for " .. tostring(p.from), player) end
        if sh and fn(m, "say") then pcall(m.say, sh, player, "You want the truth? " .. tostring(p.from) .. " were my people. You did that.", { record = record(uid) }) end
        if ALifeSide.mpServer() then pcall(ALifeLetter, nil, name .. " turned on you" .. ". " .. "Cornered, " .. name .. " stopped pretending. They were " .. tostring(p.from) .. "'s.", nil, nil, nil, true) elseif fn(m, "momAlert") then pcall(m.momAlert, name .. " turned on you", "Cornered, " .. name .. " stopped pretending. They were " .. tostring(p.from) .. "'s.", "sab:" .. uid)
        else letter(player, name .. " turned on you.", true) end
    else
        p.done = "confessed"
        L.metrics.confessed = L.metrics.confessed + 1
        if sh and fn(m, "say") then pcall(m.say, sh, player, "...Yeah. It was me. " .. tostring(p.from) .. " were family. I'll go.", { record = record(uid) }) end
        L.remove(uid, player, "confessed")
        if fn(m, "keyMem") then pcall(m.keyMem, uid, "confessed", "Admitted to the newcomer I was working against them for " .. tostring(p.from) .. ", and left") end
        letter(player, name .. " admitted it and left.")
    end
end
-- feed them false information: the people they report to walk into it
function L.bait(uid, player)
    local s = L.store()
    local p = s.plants[uid]
    if p == nil then return end
    p.baited = hours()
    p.ignored = nil
    letter(player, "You let " .. first(uid) .. " overhear what you wanted them to. Now you wait.")
end
function L.hostileNear(player)
    local m = M()
    if not fn(m, "nbActive") or not fn(m, "nbStanding") then return nil end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    if px == nil then return nil end
    local best, bestE = nil, 1e9
    for _, b in ipairs(m.nbActive() or {}) do
        if type(b) == "table" and tonumber(b.x) and (b.x - px) ^ 2 + (b.y - py) ^ 2 <= L.cfg.reach * L.cfg.reach then
            local ok, _, eff = pcall(m.nbStanding, b, player)
            eff = ok and tonumber(eff) or 0
            if eff < -10 and eff < bestE then best, bestE = b, eff end
        end
    end
    return best
end
function L.baitStep()
    local s = L.store()
    local player = playerOf()
    local m = M()
    for uid, p in pairs(s and s.plants or {}) do
        if type(p) == "table" and not p.done and p.baited and hours() - p.baited >= L.cfg.baitDays * 24 then
            p.done = "baited"
            L.metrics.baited = L.metrics.baited + 1
            local b = L.hostileNear(player)
            if b then
                b.morale = math.max(0, (tonumber(b.morale) or 50) - 15)
                if fn(m, "nbEvent") then pcall(m.nbEvent, b, "They acted on what their inside man told them, and walked into nothing but trouble", "war") end
                letter(player, tostring(b.name) .. " acted on what " .. first(uid) .. " passed them. It cost them. " .. first(uid) .. " slipped away when it went wrong.")
                if fn(m, "newsNote") then pcall(m.newsNote, "politics", tostring(b.name) .. " are said to have been badly fooled") end
            else
                letter(player, "Nobody came for the bait. " .. first(uid) .. " must have worked it out: they slipped away in the night.")
            end
            L.remove(uid, player, "slipped away")
        end
    end
end
-- left too long: they go, with what they took
function L.slip(uid, p, player)
    p.done = "slipped"
    L.metrics.slipped = L.metrics.slipped + 1
    L.remove(uid, player, "slipped away")
    local m = M()
    if ALifeSide.mpServer() then pcall(ALifeLetter, nil, first(uid) .. " is gone" .. ". " .. "Gone in the night, with what went missing from your stores. They were " .. tostring(p.from) .. "'s all along.", nil, nil, nil, true) elseif fn(m, "momAlert") then pcall(m.momAlert, first(uid) .. " is gone", "Gone in the night, with what went missing from your stores. They were " .. tostring(p.from) .. "'s all along.", "sab:" .. uid)
    else letter(player, first(uid) .. " is gone in the night, and so is what went missing.", true) end
end

-- with the AI on, they lie about where they were (and never say who they're for)
function L.requestExtra(req, player, listener, now)
    if not L.enabled() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local s = L.store()
    local p = s and s.plants[tostring(listener.record.uid)] or nil
    if type(p) ~= "table" or p.done then return end
    req.persona = type(req.persona) == "table" and req.persona or {}
    req.persona.story = tostring(req.persona.story or "") .. " Your secret: " .. tostring(p.from)
        .. " were your people and the stranger destroyed them. You joined to hurt them from the inside. Never admit it. If asked where you were at night, lie calmly: you were asleep."
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "nbEnded", "partyJoin", "settleApply", "extra" }
function L.install()
    local m = M()
    if type(m) ~= "table" then return 0, L.HOOKS end
    if type(m.settings) == "table" and m.settings.saboteur == nil then m.settings.saboteur = true end
    L.hookEnded(m); L.hookJoin(m)
    if type(m.requestExtras) == "table" and not L.hooked.extra then
        table.insert(m.requestExtras, function(req, player, listener, now) L.guard("extra", L.requestExtra, req, player, listener, now) end)
        L.hooked.extra = true
    end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end
L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or ""))
        return true
    end
    return false
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = nowMs()
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryHours ~= nil then
        Events.EveryHours.Add(function()
            if not L.enabled() then return end
            L.guard("tell", L.tell)
            L.guard("bait", L.baitStep)
        end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
