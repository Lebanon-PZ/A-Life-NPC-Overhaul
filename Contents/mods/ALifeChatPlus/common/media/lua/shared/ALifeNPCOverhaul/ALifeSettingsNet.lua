-- A-Life NPC Overhaul 0.9.5 (MP groundwork, docs/PLAN-MP.md P1): ONE SET OF RULES PER SERVER (docs/PLAN-MP.md).
-- In multiplayer the server's settings are the rules: its world logic reads them. A joining client asks for them
-- ("settingsGet") and gets them in pages ("settingsPush", ALifeCmd caps a table at 40 keys) so its menus show the
-- real values. Changing one from a client ("settingsSet") needs an admin (ALifeSide.isAdmin); the server checks the
-- key and the type, saves its own settings file and pushes the new value to everyone online.
-- Keys that belong to each player's own machine (popups, letters, hotkeys, windows, perf logging, bridge polling)
-- are never pushed or set across: ALifeSettingsNet.CLIENT (exact) and CLIENT_PREFIX (start of the key). AI setup lives
-- in the bridge's own files on each player's machine, not in these settings.
-- Single player: nothing crosses; set() returns false and the settings page saves locally as before.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"
ALifeSettingsNet = ALifeSettingsNet or {}
local N = ALifeSettingsNet
N.VERSION = ALifeSide.MOD_VERSION
N.PAGE = 30
N.CLIENT = { opinionPopup = true, pairPopup = true, sideButtons = true, perfLog = true, perfHooks = true,
    hookOnce = true, stopReAdders = true, eventAddGuard = true, eventAddMax = true, pollTicks = true, fastReplyPoll = true,
    inputLog = true, talkAutoPause = true, fallbackMs = true, lateReplyMs = true, statusCheckMs = true, offlineAfterSec = true }
N.CLIENT_PREFIX = { "ui", "popup", "perf", "hotkey", "hk", "mom", "toast", "letter", "window", "win", "font", "radial", "tab", "bridge" }
N.metrics = N.metrics or { pushed = 0, got = 0, set = 0, refused = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function M() return ALifeLLMTalk end
function N.clientOwned(k)
    k = tostring(k or "")
    if N.CLIENT[k] == true then return true end
    local low = string.lower(k)
    for _, p in ipairs(N.CLIENT_PREFIX) do
        if string.sub(low, 1, #p) == p then
            -- a word on its own or the start of a camelCase name ("winX" yes, "winter" no)
            local nxt = string.sub(k, #p + 1, #p + 1)
            if nxt == "" or nxt == string.upper(nxt) then return true end
        end
    end
    return false
end
-- the server's values, in pages of N.PAGE keys
function N.pages()
    local m = M()
    local out, cur, n = {}, {}, 0
    if type(m) ~= "table" or type(m.settings) ~= "table" then return out end
    for _, k in ipairs(type(m.fileKeys) == "table" and m.fileKeys or {}) do
        local v = m.settings[k]
        local t = type(v)
        if not N.clientOwned(k) and (t == "boolean" or t == "number" or t == "string") then
            cur[k] = v
            n = n + 1
            if n >= N.PAGE then out[#out + 1] = cur; cur, n = {}, 0 end
        end
    end
    if n > 0 then out[#out + 1] = cur end
    return out
end
function N.push(player)
    local pages = N.pages()
    for i, page in ipairs(pages) do
        ALifeCmd.reply(player, "settingsPush", { page = i, of = #pages, v = page })
        N.metrics.pushed = N.metrics.pushed + 1
    end
    return #pages
end
-- client: the server's values arrive
function N.receive(p)
    local m = M()
    if type(p) ~= "table" or type(p.v) ~= "table" or type(m) ~= "table" or type(m.settings) ~= "table" then return 0 end
    local n = 0
    for k, v in pairs(p.v) do
        if type(k) == "string" and not N.clientOwned(k) then m.settings[k] = v; n = n + 1 end
    end
    N.metrics.got = N.metrics.got + n
    if tonumber(p.page) ~= nil and tonumber(p.page) == tonumber(p.of) then N.synced = true end
    return n
end
-- server: an admin changed one
function N.apply(player, args)
    local m = M()
    if type(args) ~= "table" or type(args.k) ~= "string" or type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    local k, v = args.k, args.v
    local why = nil
    if not ALifeSide.isAdmin(player) then why = "Only an admin can change the server's settings."
    elseif N.clientOwned(k) then why = "That one is yours to set, on your own machine."
    else
        local known = false
        for _, x in ipairs(type(m.fileKeys) == "table" and m.fileKeys or {}) do if x == k then known = true end end
        local old = m.settings[k]
        if not known then why = "No such setting."
        elseif old ~= nil and type(old) ~= type(v) then why = "That setting takes a " .. type(old) .. "." end
    end
    if why then
        N.metrics.refused = N.metrics.refused + 1
        if type(ALifeOut) == "table" and fn(ALifeOut, "note") then ALifeOut.note(player, why) end
        -- pre-1.0: the client already flipped it on screen; send the server's real value back
        local real = m.settings[k]
        local t = type(real)
        if not N.clientOwned(k) and (t == "boolean" or t == "number" or t == "string") then
            ALifeCmd.reply(player, "settingsPush", { page = 1, of = 1, v = { [k] = real } })
        end
        return false
    end
    m.settings[k] = v
    N.metrics.set = N.metrics.set + 1
    if fn(m, "sbTouch") then m.sbTouch(k) end -- pre-1.0: kept with the server's world, beats the sandbox on reload
    if fn(m, "saveSettingsFile") then pcall(m.saveSettingsFile) end
    for _, p in ipairs(ALifeSide.online()) do ALifeCmd.reply(p, "settingsPush", { page = 1, of = 1, v = { [k] = v } }) end
    return true
end
-- client API for the settings page: true = sent to the server (MP, a server rule), false = set it here as before
function N.set(player, k, v)
    if not ALifeSide.mpClient() or N.clientOwned(k) then return false end
    player = player or ALifeSide.localPlayer()
    if player == nil then return false end
    ALifeCmd.send(player, "settingsSet", { k = tostring(k), v = v })
    return true
end
-- pre-1.0: "Back to sandbox values" (Settings window). Single player / host: here. MP client: asks the server (admin).
function N.applyReset(player)
    local m = M()
    if type(m) ~= "table" or not fn(m, "sbClearAll") then return false end
    if not ALifeSide.isAdmin(player) then
        if type(ALifeOut) == "table" and fn(ALifeOut, "note") then ALifeOut.note(player, "Only an admin can change the server's settings.") end
        return false
    end
    m.sbClearAll()
    if fn(m, "saveSettingsFile") then pcall(m.saveSettingsFile) end
    for _, p in ipairs(ALifeSide.online()) do N.push(p) end
    return true
end
function N.reset()
    local m = M()
    if not ALifeSide.mpClient() then
        if type(m) == "table" and fn(m, "sbClearAll") then
            local n = m.sbClearAll()
            if fn(m, "saveSettingsFile") then pcall(m.saveSettingsFile) end
            return n
        end
        return 0
    end
    local p = ALifeSide.localPlayer()
    if p == nil then return 0 end
    ALifeCmd.send(p, "settingsReset", {})
    return -1
end
function N.ask()
    if not ALifeSide.mpClient() then return false end
    local p = ALifeSide.localPlayer()
    if p == nil then return false end
    return ALifeCmd.send(p, "settingsGet", {})
end

ALifeCmd.onServer("settingsGet", function(player) N.push(player) end)
ALifeCmd.onServer("settingsSet", N.apply)
ALifeCmd.onServer("settingsReset", N.applyReset)
ALifeCmd.onClient("settingsPush", N.receive)
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(N.ask) end) end
print("[ALifeSettingsNet] ready v" .. N.VERSION .. ": the server's settings are the rules in multiplayer")
return N
