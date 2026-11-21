-- A-Life NPC Overhaul 0.7.10: THE OATH, NIGHT SHIFT, AND PEOPLE YOU CAN SEE DOING THINGS (A-Life 1.5 animations).
--   * ROADMAP, THE OATH: someone of yours (party or camp) whose love for you is at the very top ("Inseparable"), who
--     thinks the world of you, and who has never once seen you break one of your own camp rules, kneels and swears an
--     oath to you (A-Life's kneel, then a bowed head). From then on they never desert you (no walking out, no leaving
--     the party), they never lie to you, and once, when the dead get within reach of you with them at your side, they
--     put themselves in the way: the dead go for them instead.
--   * ROADMAP, NIGHT SHIFT: the same person keeping your night watch 30 nights straight. After that nothing gets past
--     them: they look twice as far, so the alarm comes earlier. On watch at night they stand at the ready.
--   * ANIMATIONS: prisoners you put to work in the garden are seen tending it.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "oathWatch" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeOathWatch") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeOathWatch = ALifeOathWatch or {}
local L = ALifeOathWatch
local TAG = "[ALifeOathWatch]"
L.VERSION = ALifeSide.MOD_VERSION
L.cfg = { oathLove = 5, oathOpinion = 80, swearTiles = 5, guardTiles = 2.5, biteTiles = 1.6, nights = 30, lookMul = 2, poseMs = 30000 }
L.OATH_LINES = { "Whatever comes, I'm with you. I swear it.", "You have my word. I'm not going anywhere. Not ever.",
    "I swear it. As long as I'm breathing, I've got your back." }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { sworn = 0, kept = 0, blocked = 0, nightShift = 0, longLooks = 0, poses = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end
local function xyOf(o) local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
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
local function first(r)
    local pa = PA()
    local n = "Someone"
    if r and pa and fn(pa.Names, "of") then pcall(function() n = tostring(pa.Names.of(r)) end) end
    return string.match(n, "^(%S+)") or n
end
local function anim(shell, id)
    local A = PA() and PA().Animations
    if shell == nil or not fn(A, "apply") then return false end
    local ok, done = pcall(A.apply, shell, id)
    if ok and done == true then L.metrics.poses = L.metrics.poses + 1 end
    return ok and done == true
end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.oathWatch == false)
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
    if tbl[name .. "__OathWatch"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__OathWatch"] = orig
    L.hooked[hookName] = true
    return true
end
function L.store()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "oathWatch")
    if not ok or type(b) ~= "table" then return nil end
    b.sworn = type(b.sworn) == "table" and b.sworn or {}
    b.sawBreak = type(b.sawBreak) == "table" and b.sawBreak or {}
    b.watch = type(b.watch) == "table" and b.watch or {}
    return b
end
function L.yourPeople(player)
    local m, seen, out = M(), {}, {}
    local function add(list) for _, u in ipairs(list or {}) do u = tostring(type(u) == "table" and (u.uid or u) or u); if not seen[u] then seen[u] = true; out[#out + 1] = u end end end
    if fn(m, "partyMembers") then local ok, l = pcall(m.partyMembers, player); if ok then add(l) end end
    if fn(m, "cpPeople") then local ok, l = pcall(m.cpPeople, player); if ok then add(l) end end
    return out
end
function L.isSworn(uid) local s = L.store(); return s ~= nil and s.sworn[tostring(uid)] ~= nil end

----------------------------------------------------------------------------------------------------------------
-- THE OATH
----------------------------------------------------------------------------------------------------------------
-- seeing you break your own rule rules them out for good
function L.hookBreak(m)
    return wrap(m, "cpBreak", "cpBreak", function(orig)
        return function(id, player, wx, wy, ...)
            local before = {}
            local okD, d = pcall(m.cpData)
            if okD and type(d) == "table" and type(d.hypo) == "table" then for u, hy in pairs(d.hypo) do before[u] = hy.h end end
            local r = orig(id, player, wx, wy, ...)
            if L.enabled() then
                L.guard("cpBreak", function()
                    local s = L.store()
                    local okA, da = pcall(m.cpData)
                    if s and okA and type(da) == "table" and type(da.hypo) == "table" then
                        for u, hy in pairs(da.hypo) do if hy.h ~= before[u] then s.sawBreak[tostring(u)] = true end end
                    end
                end)
            end
            return r
        end
    end)
end
function L.ready(player, uid)
    local s, B = L.store(), ALifeBonds
    if s == nil or s.sworn[uid] or s.sawBreak[uid] then return false end
    if not fn(B, "keyOf") or not fn(B, "row") or not fn(B, "stageOf") then return false end
    local row = B.row(B.keyOf(player), uid, false)
    if row == nil or B.stageOf(row.l) < L.cfg.oathLove then return false end
    local pa = PA()
    local r = record(uid)
    if r == nil or r.lifecycle ~= "active" then return false end
    if fn(pa.NpcOpinion, "valueOf") then
        local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
        if ok and tonumber(v) and v < L.cfg.oathOpinion then return false end
    end
    return true
end
function L.swear(player, uid)
    local s = L.store()
    local sh = shellOf(uid)
    local px, py = xyOf(player)
    local x, y = xyOf(sh)
    if s == nil or x == nil or px == nil or d2(x, y, px, py) > L.cfg.swearTiles * L.cfg.swearTiles then return false end
    local r = record(uid)
    s.sworn[uid] = { h = hours(), biteUsed = false }
    L.metrics.sworn = L.metrics.sworn + 1
    anim(sh, "ready_kneel")
    local line = L.OATH_LINES[(hash(uid) % #L.OATH_LINES) + 1]
    local m = M()
    if fn(m, "say") then pcall(m.say, sh, player, line, { record = r }) end
    if fn(m, "keyMem") then pcall(m.keyMem, uid, "oath", "Knelt and swore an oath to the newcomer: I'll never leave them") end
    if fn(m, "logInteraction") then pcall(m.logInteraction, uid, "Swore an oath to you", nil, nil, "event") end
    if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, first(r) .. " knelt in front of you and swore an oath.") end
    if fn(m, "addDeed") then pcall(m.addDeed, "oath", "people swear oaths to the stranger", 3, { uid }, x, y) end
    log(first(r) .. " swore the oath")
    return true
end
function L.oathStep()
    local p = playerOf()
    if p == nil then return end
    for _, uid in ipairs(L.yourPeople(p)) do
        if L.ready(p, uid) then L.swear(p, uid) end
    end
end
-- never desert
function L.hookLeaveCheck(m)
    return wrap(m, "partyLeaveCheck", "partyLeaveCheck", function(orig)
        return function(uid, player, now, ...)
            if L.enabled() and L.isSworn(uid) then return nil end
            return orig(uid, player, now, ...)
        end
    end)
end
function L.hookBaseLeave(m)
    return wrap(m, "baseLeave", "baseLeave", function(orig)
        return function(uid, player, why, ...)
            -- only walking out on you ("fed up"); leaving the base to travel with you is fine
            if L.enabled() and L.isSworn(uid) and tostring(why) == "fed up" then
                L.metrics.blocked = L.metrics.blocked + 1
                log("sworn: " .. tostring(uid) .. " won't leave (" .. tostring(why) .. ")")
                return false
            end
            return orig(uid, player, why, ...)
        end
    end)
end
-- and never turn on you
function L.hookGrudge(m)
    return wrap(m, "addGrudge", "addGrudge", function(orig)
        return function(uid, amount, why, player, ...)
            if L.enabled() and L.isSworn(uid) then L.metrics.blocked = L.metrics.blocked + 1; return nil end
            return orig(uid, amount, why, player, ...)
        end
    end)
end
-- never lie: the ask-them answers ("do you trust me?") lie only for the scared or the resentful; someone at the top
-- of love is honest there already
-- once: the dead go for them instead of you
function L.shieldStep()
    local s = L.store()
    local p = playerOf()
    local px, py = xyOf(p)
    if s == nil or px == nil then return end
    local gUid, gO, gShell = nil, nil, nil
    for uid, o in pairs(s.sworn) do
        if not o.biteUsed then
            local sh = shellOf(uid)
            local x, y = xyOf(sh)
            if x and d2(x, y, px, py) <= L.cfg.guardTiles * L.cfg.guardTiles then gUid, gO, gShell = uid, o, sh break end
        end
    end
    if gUid == nil then return end
    local list = nil
    pcall(function() list = getCell():getZombieList() end)
    if list == nil then return end
    local r2 = L.cfg.biteTiles * L.cfg.biteTiles
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        -- cheap test first (no closures per zombie); only a zombie in reach gets the closer look
        local zx, zy = z:getX(), z:getY()
        if (zx - px) * (zx - px) + (zy - py) * (zy - py) <= r2 then
            local npc, dead = false, true
            pcall(function() npc = z:hasModData() and z:getModData().ProjectALifeUID ~= nil; dead = z:isDead() end)
            if not npc and not dead then
                local ok = pcall(function() z:setTarget(gShell) end)
                if ok then
                    gO.biteUsed = true
                    L.metrics.kept = L.metrics.kept + 1
                    local m = M()
                    local r = record(gUid)
                    if fn(m, "keyMem") then pcall(m.keyMem, gUid, "oath", "Put myself between the newcomer and the dead, like I swore") end
                    if type(ALifeLetter) == "function" then pcall(ALifeLetter, p, first(r) .. " threw themselves between you and the dead.") end
                    log(first(r) .. " kept the oath: the dead went for them")
                    return
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- NIGHT SHIFT
----------------------------------------------------------------------------------------------------------------
function L.onWatcher(uid)
    local s = L.store()
    if s == nil or uid == nil then return end
    local night = math.floor((hours() + 2) / 24)
    local w = s.watch
    if w.night == night then return end
    if w.uid == uid and w.night == night - 1 then w.streak = (tonumber(w.streak) or 1) + 1 else w.uid, w.streak = uid, 1 end
    w.night = night
    if w.streak >= L.cfg.nights and not (type(w.vets) == "table" and w.vets[uid]) then
        w.vets = type(w.vets) == "table" and w.vets or {}
        w.vets[uid] = hours()
        L.metrics.nightShift = L.metrics.nightShift + 1
        local r = record(uid)
        local m = M()
        local p = playerOf()
        if type(ALifeLetter) == "function" then pcall(ALifeLetter, p, first(r) .. " has kept the night watch " .. L.cfg.nights .. " nights straight. Nothing gets past them now.") end
        if fn(m, "keyMem") then pcall(m.keyMem, uid, "night_shift", "Kept the night watch " .. L.cfg.nights .. " nights straight; I know every shadow out there") end
        if fn(m, "addDeed") then pcall(m.addDeed, "nightshift", "the stranger's camp has a night watch that never misses a thing", 2, { uid }, nil, nil) end
        log(first(r) .. " earned the night shift")
    end
end
function L.isVet(uid)
    local s = L.store()
    return s ~= nil and type(s.watch.vets) == "table" and s.watch.vets[tostring(uid)] ~= nil
end
function L.hookWatcher(m)
    return wrap(m, "cpWatcher", "cpWatcher", function(orig)
        return function(player, ...)
            local uid = orig(player, ...)
            if uid ~= nil and L.enabled() then L.guard("cpWatcher", L.onWatcher, tostring(uid)) end
            return uid
        end
    end)
end
-- they look twice as far (so the alarm comes earlier), and stand at the ready on watch
function L.hookLook(m)
    return wrap(m, "cpLook", "cpLook", function(orig)
        return function(uid, shell, player, x, y, tiles, night, b, ...)
            if L.enabled() and night and L.isVet(uid) and tonumber(tiles) then
                L.metrics.longLooks = L.metrics.longLooks + 1
                tiles = tiles * L.cfg.lookMul
                local s = L.store()
                local t = nowMs()
                if s and t - (tonumber(s.watch.poseAt) or -1e12) >= L.cfg.poseMs then s.watch.poseAt = t; anim(shell, "ready_cover_rifle") end
            end
            return orig(uid, shell, player, x, y, tiles, night, b, ...)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- prisoners at work are seen working
----------------------------------------------------------------------------------------------------------------
function L.workPoses()
    local Pw = ALifeBondsPower
    if not fn(Pw, "state") then return end
    local ok, st = pcall(Pw.state)
    for uid, c in pairs(ok and type(st) == "table" and type(st.cap) == "table" and st.cap or {}) do
        if type(c) == "table" and c.work then anim(shellOf(uid), "farm_tend") end
    end
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "cpBreak", "partyLeaveCheck", "baseLeave", "addGrudge", "cpWatcher", "cpLook" }
function L.install()
    local m = M()
    if type(m) ~= "table" then return 0, L.HOOKS end
    if type(m.settings) == "table" and m.settings.oathWatch == nil then m.settings.oathWatch = true end
    L.hookBreak(m); L.hookLeaveCheck(m); L.hookBaseLeave(m); L.hookGrudge(m); L.hookWatcher(m); L.hookLook(m)
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
L.lastShield = 0
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
    if Events.EveryTenMinutes ~= nil then
        Events.EveryTenMinutes.Add(function()
            if not L.enabled() then return end
            L.guard("oath", L.oathStep)
            L.guard("work", L.workPoses)
        end)
    end
    if Events.OnTick ~= nil then
        -- a quarter second: is the oath needed right now? (only while someone sworn is at your side)
        Events.OnTick.Add(function()
            local t = nowMs()
            if t - L.lastShield < 250 then return end
            L.lastShield = t
            if L.off.shield or not L.enabled() then return end
            local ok, err = pcall(L.shieldStep) -- no per-tick tables
            if not ok then L.off.shield = true; log("hook 'shield' failed, off for this session: " .. tostring(err)) end
        end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
