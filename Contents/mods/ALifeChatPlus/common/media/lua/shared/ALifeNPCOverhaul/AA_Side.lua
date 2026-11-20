-- A-Life NPC Overhaul 0.9.5 (MP groundwork, docs/PLAN-MP.md P1): WHICH SIDE AM I ON. One answer for every file (docs/PLAN-MP.md).
--   world() : the one place world logic runs. Single player, or the server in multiplayer. Never an MP client (A-Life's
--             registry lives on the server: a client would act on nothing and fire everything twice).
--   ui()    : a machine with a local player and a screen. Single player, or an MP client. Never a dedicated server.
--   worldEvent / uiEvent : add a listener only on the right side.
--   keyOf(player), online(), byKey(key), isAdmin(player), localPlayer().
-- No game calls at load: safe in shared, loads first (AA_ prefix).
-- pre-1.0: the other AA_ base files load with this one. They used to load first only because their folder
-- (ALifeChatPlus) sorted before ALifeLLMTalk; the folder is ALifeNPCOverhaul now and sorts after it, so the order is
-- made real here instead of relying on folder names. None of them requires anything (no loop). One that is already
-- there (its global exists: loaded, or stood in for by a test) is left alone.
if ALifeHealth == nil then require "ALifeNPCOverhaul/AA_Health" end
if ALifeTick == nil then require "ALifeNPCOverhaul/AA_Tick" end
if ALifeTr == nil then require "ALifeNPCOverhaul/AA_Tr" end
if ALifeLetter == nil then require "ALifeNPCOverhaul/AA_Letter" end
if ALifeFmtDec == nil then require "ALifeNPCOverhaul/AA_Num" end
if ALifeMerge == nil then require "ALifeNPCOverhaul/AA_Merge" end
if ALifeMove == nil then require "ALifeNPCOverhaul/AA_Move" end
if ALifeRadial == nil then require "ALifeNPCOverhaul/AA_Radial" end
ALifeSide = ALifeSide or {}
local S = ALifeSide
S.VERSION = "pre-1.0"
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function client() return type(isClient) == "function" and isClient() == true end
local function server() return type(isServer) == "function" and isServer() == true end
function S.sp() return not client() and not server() end
function S.mpServer() return server() end
function S.mpClient() return client() and not server() end
function S.world() return not client() end
function S.ui() return not server() end
local function add(name, f)
    if type(Events) ~= "table" or type(f) ~= "function" then return false end
    local ev = Events[name]
    if type(ev) ~= "table" or type(ev.Add) ~= "function" then return false end
    ev.Add(f)
    return true
end
function S.worldEvent(name, f) if not S.world() then return false end return add(name, f) end
function S.uiEvent(name, f) if not S.ui() then return false end return add(name, f) end

-- pre-1.0 (P2): THE ONE SIDE SWITCH for a whole file. Top of every ALifeLLMTalk file:
--   local Events, ALifeHealth = ALifeSide.hooks("world" | "ui" | "legacy", "FileName")
-- The file keeps writing Events.X.Add / ALifeHealth.add / ALifeHealth.tickAdd as before; the side rule lives here.
--   "world"  : ported world logic. World ticks (S.WORLD_EVENTS, ALifeHealth.tickAdd) only where world() runs (never on
--              an MP client: empty registry + double fire). OnGameStart also goes on OnServerStarted on a server
--              (GameServer never fires OnGameStart; read in the 42.21 jar: IngameState fires it, GameServer fires
--              OnGameBoot + OnServerStarted). Everything else as asked.
--   "ui"     : UI only. Every listener only where ui() (SP or MP client).
--   "legacy" : not ported yet. Exactly as it was in client/: listeners only where ui(), nothing on a server.
-- Every Events name exists on both sides (LuaEventManager.AddEvents registers all of them), so this never
-- adds to a missing event; a name the game doesn't have is skipped quietly.
S.WORLD_EVENTS = { OnTick = true, OnTickEvenPaused = true, EveryOneMinute = true, EveryTenMinutes = true, EveryHours = true,
    EveryDays = true, OnZombieDead = true, OnWeaponHitCharacter = true, OnHitZombie = true, OnWeaponSwing = true,
    OnWorldSound = true, OnPlayerDeath = true, OnCharacterDeath = true, OnCreatePlayer = true, OnPlayerUpdate = true,
    ProjectALife_NpcDied = true, ProjectALife_NpcHit = true, ProjectALife_NpcSpawned = true }
S.MODES = { world = true, ui = true, legacy = true }
S.files = S.files or {}
S.hookStats = S.hookStats or { added = 0, skipped = 0 }
function S.allowed(mode, name)
    if mode == "world" then
        if S.WORLD_EVENTS[name] then return S.world() end
        return true
    end
    return S.ui() -- "ui" and "legacy"
end
local function realEv(name) return type(Events) == "table" and type(Events[name]) == "table" and Events[name] or nil end
-- pre-1.0 perf: STAGGER. ~20 of our modules listen to EveryHours; they all fired in the same frame (profiler: one
-- 45 ms frame an in-game hour). Now each listener is queued and the queue runs a few ms per frame (FIFO, same order
-- as before, each listener at most once in the queue). Setting staggerMs (default 4): ms of listener work per frame;
-- 0 = off (all at once, as before). Other mods' listeners are untouched.
S.STAGGER = { EveryHours = true }
S.stag = S.stag or { lists = {}, jobs = {}, head = 1, tail = 0, queued = {}, hooked = false, errs = {}, worstFrames = 0 }
local function stagMs()
    local m = ALifeLLMTalk
    local v = type(m) == "table" and type(m.settings) == "table" and tonumber(m.settings.staggerMs) or nil
    if v == nil then v = 4 end
    return v
end
local function stagNow() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function stagRun(f)
    local ok, e = pcall(f)
    if not ok and not S.stag.errs[f] then
        S.stag.errs[f] = true
        print("[ALifeSide] staggered listener error (shown once): " .. tostring(e))
    end
end
function S.staggerDrain()
    local st = S.stag
    local budget, t0, frames = stagMs(), stagNow(), 0
    while st.head <= st.tail do
        local f = st.jobs[st.head]
        st.jobs[st.head] = nil
        st.head = st.head + 1
        st.queued[f] = nil
        stagRun(f)
        if stagNow() - t0 >= budget then break end
    end
    if st.head > st.tail then st.head, st.tail = 1, 0 end
end
function S.staggerFire(name)
    local st = S.stag
    local list = st.lists[name]
    if list == nil then return end
    if stagMs() <= 0 then
        for i = 1, #list do stagRun(list[i]) end
        return
    end
    for i = 1, #list do
        local f = list[i]
        if not st.queued[f] then
            st.queued[f] = true
            st.tail = st.tail + 1
            st.jobs[st.tail] = f
        end
    end
end
-- add f to the staggered listeners of an event (EveryHours). Returns true when it was taken.
function S.stagger(name, f)
    if type(f) ~= "function" or S.STAGGER[name] ~= true then return false end
    local st = S.stag
    local list = st.lists[name]
    if list == nil then
        local ev = type(Events) == "table" and type(Events[name]) == "table" and Events[name] or nil
        if ev == nil or type(ev.Add) ~= "function" then return false end
        list = {}
        st.lists[name] = list
        ev.Add(function() S.staggerFire(name) end)
        local tick = type(Events) == "table" and type(Events.OnTick) == "table" and Events.OnTick or nil
        if not st.hooked and tick ~= nil and type(tick.Add) == "function" then
            st.hooked = true
            tick.Add(function() if st.head <= st.tail then S.staggerDrain() end end)
        end
    end
    list[#list + 1] = f
    return true
end
function S.staggerRemove(name, f)
    local list = S.stag.lists[name]
    if list == nil then return false end
    for i = #list, 1, -1 do
        if list[i] == f then table.remove(list, i); return true end
    end
    return false
end

local function evProxy(mode, name)
    local p = {}
    p.Add = function(f, ...)
        if S.STAGGER[name] == true and S.allowed(mode, name) and S.stagger(name, f) then
            S.hookStats.added = S.hookStats.added + 1
            return nil
        end
        local list = { name }
        if mode == "world" and name == "OnGameStart" and server() then list = { "OnServerStarted" } end
        local done = false
        for _, n in ipairs(list) do
            local ev = realEv(n)
            if ev ~= nil and type(ev.Add) == "function" and S.allowed(mode, n == "OnServerStarted" and "OnGameStart" or n) then
                ev.Add(f, ...)
                done = true
            end
        end
        if done then S.hookStats.added = S.hookStats.added + 1 else S.hookStats.skipped = S.hookStats.skipped + 1 end
        return nil
    end
    p.Remove = function(f, ...)
        if S.STAGGER[name] == true and S.staggerRemove(name, f) then return nil end
        local list = { name }
        if mode == "world" and name == "OnGameStart" and server() then list = { "OnServerStarted" } end
        for _, n in ipairs(list) do
            local ev = realEv(n)
            if ev ~= nil and type(ev.Remove) == "function" then pcall(ev.Remove, f, ...) end
        end
        return nil
    end
    return p
end
function S.hooks(mode, file)
    if not S.MODES[mode] then mode = "legacy" end
    if file ~= nil then S.files[tostring(file)] = mode end
    local cache = {}
    local ev = setmetatable({}, { __index = function(_, name)
        if type(name) ~= "string" then return nil end
        if realEv(name) == nil then return nil end
        local p = cache[name]
        if p == nil then p = evProxy(mode, name); cache[name] = p end
        return p
    end })
    local tickOk = function() return mode == "world" and S.world() or (mode ~= "world" and S.ui()) end
    local hl = setmetatable({}, { __index = function(_, k)
        local real = ALifeHealth
        if k == "tickAdd" then
            return function(label, f)
                if not tickOk() then S.hookStats.skipped = S.hookStats.skipped + 1; return nil end
                if type(real) == "table" and type(real.tickAdd) == "function" then return real.tickAdd(label, f) end
                if type(ALifeTick) == "table" then return ALifeTick.add(f) end
            end
        end
        if k == "add" then
            -- ALifeHealth.add(ev, label, fn) -> ev.Add(wrapped): ev is this file's proxy, so its rule applies
            return function(e, label, f)
                if type(real) == "table" and type(real.add) == "function" then return real.add(e, label, f) end
                if type(e) == "table" and type(e.Add) == "function" then return e.Add(f) end
            end
        end
        if type(real) == "table" then return real[k] end
        return nil
    end })
    return ev, hl
end
-- a file's mode (tests, console): "world" | "ui" | "legacy" | nil
function S.modeOf(file) return S.files[tostring(file)] end

-- pre-1.0 (P2): ALifeLLMTalk exists from the first shared file on. Shared modules (LeaderGate, Legacy, Chronicle,
-- Member, Democracy, AISetup) register their setting keys at load; they load before ALifeLLMTalk_Main, so before
-- this their keys never reached fileKeys in game (not saved, reset on restart). Main keeps what's here.
ALifeLLMTalk = ALifeLLMTalk or {}
if type(ALifeLLMTalk.settings) ~= "table" then ALifeLLMTalk.settings = {} end
if type(ALifeLLMTalk.fileKeys) ~= "table" then ALifeLLMTalk.fileKeys = {} end
-- the settings page rows: files that load before the UI (all of shared/) add theirs here; ALifeLLMTalk_UI keeps them
if type(ALifeLLMTalk.settingRows) ~= "table" then ALifeLLMTalk.settingRows = {} end
if type(ALifeLLMTalk.settingCatOf) ~= "table" then ALifeLLMTalk.settingCatOf = {} end
-- pre-1.0 perf: staggerMs (ms of hourly-listener work per frame, 0 = all at once). Key at LOAD time (CLAUDE.md rule 2).
if ALifeLLMTalk.settings.staggerMs == nil then ALifeLLMTalk.settings.staggerMs = 4 end
do
    local have = false
    for _, k in ipairs(ALifeLLMTalk.fileKeys) do if k == "staggerMs" then have = true end end
    if not have then ALifeLLMTalk.fileKeys[#ALifeLLMTalk.fileKeys + 1] = "staggerMs" end
end

-- the player on this screen (nil on a dedicated server)
function S.localPlayer()
    if server() then return nil end
    local p = nil
    pcall(function() p = getSpecificPlayer(0) end)
    if p == nil then pcall(function() p = getPlayer() end) end
    return p
end
-- pre-1.0 (P2b): "YOU" IN WORLD LOGIC. Old code asked getPlayer() for "the" player; on a server there is none.
--   S.you(p)      = p, else the player being handled right now (S.cur: a per-player loop, a talk job, a typed line),
--                   else the local player (nil on a dedicated server outside a loop). Single player: always the same
--                   answer as getPlayer(), so SP behaviour is unchanged.
--   S.with(p, f, ...) runs f with S.cur = p (pcall; returns ok, a, b, c).
--   S.each(f, ...)    runs f(player, ...) once per living online player (SP: the one player), S.cur set each time.
--   S.nearest(x, y, tiles) the online player nearest to a spot (nil if none within tiles).
S.cur = nil
function S.you(p)
    if p ~= nil then return p end
    if S.cur ~= nil then return S.cur end
    return S.localPlayer()
end
function S.with(p, f, ...)
    local prev = S.cur
    S.cur = p
    local ok, a, b, c = pcall(f, ...)
    S.cur = prev
    return ok, a, b, c
end
local function alive(p)
    local dead = false
    pcall(function() dead = p:isDead() == true end)
    return not dead
end
S.eachErrors = S.eachErrors or 0
function S.each(f, ...)
    local n = 0
    for _, p in ipairs(S.online()) do
        if alive(p) then
            local ok, e = S.with(p, f, p, ...)
            if not ok then
                S.eachErrors = S.eachErrors + 1
                print("[ALifeSide] per-player run error: " .. tostring(e))
            end
            n = n + 1
        end
    end
    return n
end
function S.nearest(x, y, tiles)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return nil end
    local best, bd = nil, (tonumber(tiles) or 1e9) ^ 2
    for _, p in ipairs(S.online()) do
        local px, py = nil, nil
        pcall(function() px, py = p:getX(), p:getY() end)
        if px ~= nil and alive(p) then
            local d = (px - x) ^ 2 + (py - y) ^ 2
            if d <= bd then best, bd = p, d end
        end
    end
    return best
end
-- pre-1.0 (P5/P6): "THE PLAYER" FOR WORLD MODULES that have no player at hand (camp-wide work, world events): the
-- player being handled, else on a server the camp's player (ALifeLLMTalk.homePlayer: the one whose base it is), else
-- the first online player; single player / MP client: the local player (same as getSpecificPlayer(0)).
function S.campPlayer()
    if S.cur ~= nil then return S.cur end
    if server() then
        local M = ALifeLLMTalk
        if type(M) == "table" and type(M.homePlayer) == "function" then local ok, p = pcall(M.homePlayer); if ok and p ~= nil then return p end end
        return S.online()[1]
    end
    return S.localPlayer()
end
-- pre-1.0 (P4/P5): THE SCREEN FROM WORLD LOGIC, one call each, safe in every file (ALifeSide always loads first).
-- Single player / MP client: exactly the old direct call (ALifeLLMTalk.momCard / momToast / momNote, ALifeLetter,
-- the journal map). MP server: ALifeOut to that player (nil = the player being handled, S.cur; cards: else the camp's
-- player; letters / notes / toasts with nobody handled: everyone online).
local function LT() return type(ALifeLLMTalk) == "table" and ALifeLLMTalk or {} end
function S.canOutCard()
    if server() then return type(ALifeOut) == "table" and type(ALifeOut.card) == "function" end
    return fn(LT(), "momCard")
end
function S.outCard(player, card)
    if server() then
        if type(ALifeOut) ~= "table" then return false end
        player = player or S.cur or S.campPlayer()
        if player == nil then return false end
        return ALifeOut.card(player, card)
    end
    local m = LT()
    if fn(m, "momCard") then return m.momCard(card) end
    return false
end
local function outTo(player) if player ~= nil then return player end; return S.cur end
function S.outToast(player, text, r, g, b)
    if server() then if type(ALifeOut) == "table" then return ALifeOut.toast(outTo(player), text, r, g, b) end; return 0 end
    local m = LT()
    if fn(m, "momToast") then return m.momToast(text, r, g, b) end
end
function S.outNote(player, text, r, g, b)
    if server() then if type(ALifeOut) == "table" then return ALifeOut.note(outTo(player), text, r, g, b) end; return 0 end
    local m = LT()
    if fn(m, "momNote") then return m.momNote(text, r, g, b) end
end
function S.outLetter(player, text, r, g, b, bad)
    if server() then if type(ALifeOut) == "table" then return ALifeOut.letter(outTo(player), text, r, g, b, bad) end; return 0 end
    local p = player or S.localPlayer()
    if type(ALifeLetter) == "function" and p ~= nil then return pcall(ALifeLetter, p, tostring(text), r, g, b, bad) end
end
-- a mark on the player's paper map (the journal's queue). MP: sent to that player's machine, drawn there.
function S.outMark(player, text, x, y)
    if server() then if type(ALifeOut) == "table" and type(ALifeOut.mark) == "function" then return ALifeOut.mark(outTo(player), text, x, y) end; return 0 end
    local m = LT()
    m.jnQueue = m.jnQueue or {}
    m.jnQueue[#m.jnQueue + 1] = { text = text, x = x, y = y }
    if fn(m, "jnFlush") then pcall(m.jnFlush) end
    return 1
end
-- the online player nearest an object (shell / zombie / body: anything with getX / getY)
function S.nearestTo(o, tiles)
    if o == nil then return nil end
    local x, y = nil, nil
    pcall(function() x, y = o:getX(), o:getY() end)
    return S.nearest(x, y, tiles)
end
-- is this character one of the online players? (OnCharacterDeath / hit events hand any character)
function S.isOnlinePlayer(c)
    if c == nil then return false end
    for _, p in ipairs(S.online()) do if p == c then return true end end
    return false
end
-- a player's key: Jeem's, else A-Life Reputation's (the same keys our shared modules already use), else the username
function S.keyOf(player)
    if player == nil then return nil end
    local j = ProjectALifeJimmy
    if fn(j, "playerKey") then local ok, k = pcall(j.playerKey, player); if ok and k ~= nil then return tostring(k) end end
    local pa = ProjectALife
    if type(pa) == "table" and fn(pa.Reputation, "playerKey") then
        local ok, k = pcall(pa.Reputation.playerKey, player); if ok and k ~= nil then return tostring(k) end
    end
    local u = nil
    pcall(function() u = player:getUsername() end)
    if u ~= nil and u ~= "" then return "u:" .. tostring(u) end
    return "sp:0"
end
-- everyone who can get a message: online players on the server (vanilla getOnlinePlayers, server/ClientCommands.lua),
-- else the local player
function S.online()
    local out = {}
    if server() then
        pcall(function()
            local list = getOnlinePlayers()
            for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
        end)
        return out
    end
    local p = S.localPlayer()
    if p ~= nil then out[1] = p end
    return out
end
function S.byKey(key)
    if key == nil then return nil end
    for _, p in ipairs(S.online()) do if S.keyOf(p) == tostring(key) then return p end end
    return nil
end
-- single player: you're the host. MP: admin power (vanilla B42 getRole():hasAdminPower(); 42.21 server side
-- unverified, guarded) or any access level above "None"
function S.isAdmin(player)
    if S.sp() then return true end
    if player == nil then return false end
    local ok, yes = pcall(function() return player:getRole():hasAdminPower() end)
    if ok and yes == true then return true end
    local ok2, lvl = pcall(function() return player:getAccessLevel() end)
    return ok2 and type(lvl) == "string" and lvl ~= "" and string.lower(lvl) ~= "none"
end
print("[ALifeSide] ready " .. S.VERSION .. ": world logic " .. (S.world() and "here" or "on the server") .. ", UI " .. (S.ui() and "here" or "none") .. ", one side switch per file (ALifeSide.hooks)")
return S
