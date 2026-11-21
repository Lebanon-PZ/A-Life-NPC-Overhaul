-- A-Life NPC Overhaul 0.5.0: SANDBOX SETTINGS.
-- Everything you can tune is on the sandbox pages "NPC Overhaul: 1..6" (SandboxVars.ALifeChatPlus.*).
-- This file copies the world's sandbox values into the mod's settings when a game loads, right after
-- Zomboid\Lua\alifetalk_settings.txt is read, so the sandbox wins for this world. A key the world doesn't have
-- (a save from before 0.5.0) is left alone: the file / the in-game Settings window still decide it.
-- pre-1.0: a switch saved in the in-game Settings window beats the sandbox for this world (M.sbKeepTouched).
-- Options read straight from SandboxVars elsewhere (work zones WZ*, camp CP*, airport) need no copy here.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Sandbox") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeSandbox]"

M.sandboxMap = {
    { k = "Immersive", set = "immersive", im = true },
    { k = "NameDiscovery", set = "nameDiscovery" },
    { k = "Emotions", set = "emotions" },
    { k = "ChangeOverTime", set = "changeOverTime" },
    { k = "Habits", set = "habits" },
    { k = "LifeTopics", set = "lifeTopics" },
    { k = "Dreams", set = "dreams" },
    { k = "OutfitTalk", set = "outfitTalk" },
    { k = "WeatherTalk", set = "weatherTalk" },
    { k = "WoundTalk", set = "woundTalk" },
    { k = "WoundTalkFreq", set = "woundTalkFreq" },
    { k = "AIWaitSec", set = "fallbackMs", mul = 1000 },
    { k = "NpcLanguage", set = "npcLanguage" }, -- 0.8.12: ALifeLanguage reads the setting (so the AI tab can change it)
    { k = "MemLines", set = "memLines" },
    { k = "TalkTiles", set = "talkTiles" },
    { k = "ShoutTiles", set = "shoutTiles" },
    { k = "ChimeChance", set = "chimeChance" },
    { k = "BackChance", set = "backChance" },
    { k = "MaxChain", set = "maxChain" },
    { k = "Ambient", set = "ambient" },
    { k = "AmbientMinSec", set = "ambientMinSec" },
    { k = "AmbientMaxSec", set = "ambientMaxSec" },
    { k = "AmbientCooldownSec", set = "ambientCooldownSec" },
    { k = "AmbientReplyChance", set = "ambientReplyChance" },
    { k = "BanterChance", set = "banterChance" },
    { k = "Attention", set = "attention" },
    { k = "Voice", set = "voice" },
    { k = "RadioNews", set = "radioNews" },
    { k = "Bonds", set = "bonds" },
    { k = "Romance", set = "romance" },
    { k = "NpcLove", set = "npcLove" },
    { k = "Recruiting", set = "recruiting" },
    { k = "Party", set = "party" },
    { k = "PartyCap", set = "partyCap" },
    { k = "BaseParty", set = "baseParty" },
    { k = "WitnessValues", set = "witnessValues" },
    { k = "Grudges", set = "grudges" },
    { k = "Nemesis", set = "nemesis" },
    { k = "Betrayal", set = "betrayal" },
    { k = "Promises", set = "promises" },
    { k = "LastWords", set = "lastWords" },
    { k = "LossTalk", set = "lossTalk" },
    { k = "PartnerLossTrauma", set = "partnerLossTrauma" },
    { k = "TurnedReact", set = "turnedReact" },
    { k = "DarkPersonas", set = "darkPersonas" },
    { k = "Bands", set = "bands" },
    { k = "Directives", set = "directives" },
    { k = "Politics", set = "politics" },
    { k = "Dynamics", set = "dynamics" },
    { k = "Territory", set = "territory" },
    { k = "ClaimTiles", cfg = "dynCfg", field = "claimTiles", lo = 15, hi = 150 },
    { k = "TributeDays", cfg = "dynCfg", field = "tributeDays", lo = 1, hi = 14 },
    { k = "Threats", set = "threats" },
    { k = "AttackPlayer", set = "attackPlayer" },
    { k = "AttackNpc", set = "attackNpc" },
    { k = "Rumors", set = "rumors" },
    { k = "Notes", set = "notes" },
    { k = "NpcBases", set = "npcBases" },
    { k = "DarkContent", set = "darkContent" }, { k = "Nomads", set = "nomads" }, { k = "Outposts", set = "outposts" }, -- 0.6.4-0.6.6
    { k = "Caravans", set = "caravans" }, { k = "CaravanTiles", set = "caravanTiles" },
    { k = "WalkTilesPerHour", set = "walkTilesPerH" }, { k = "DriveTilesPerHour", set = "driveTilesPerH" },
    { k = "RadioCalls", set = "radioCalls" }, { k = "RadioRangePct", set = "radioRangePct" }, { k = "RadioShare", set = "radioShare" }, -- 0.6.7
    { k = "AllyHelp", set = "allyHelp" }, { k = "Bounties", set = "bounties" },
    { k = "TradingPost", set = "tradingPost" }, { k = "MarketDays", set = "marketDays" }, -- 0.6.8
    { k = "Journal", set = "journal" }, -- 0.6.9
    { k = "NpcVehicles", set = "npcVehicles" }, -- 0.6.11
    { k = "ItemWorth", set = "itemWorth" }, -- 0.6.14
    { k = "MissingPeople", set = "missingPeople" }, -- 0.6.15
    { k = "HealthLog", set = "healthLog" }, -- 0.6.16
    { k = "PeopleLeave", set = "peopleLeave" }, -- 0.6.17
    { k = "OwnCaravans", set = "ownCaravans" }, -- 0.6.18
    { k = "Chokepoints", set = "chokepoints" }, -- 0.6.19
    { k = "WarMap", set = "warMap" }, -- 0.7.0
    { k = "AirportFlights", set = "airportFlights" }, { k = "AirportAbductions", set = "airportAbductions" }, -- 0.6.12
    { k = "NpcBaseRate", set = "npcBaseRate" },
    { k = "NpcBuild", set = "npcBuild" },
    { k = "Settlers", set = "settlers" },
    { k = "WalkOutAt", cfg = "dynCfg", field = "walkOut", lo = 30, hi = 100 },
    { k = "CPHaulers", cfg = "cpCfg", field = "haulers", lo = 1, hi = 4 },
    { k = "CPHaulTrip", cfg = "cpCfg", field = "haulMaxItems", lo = 1, hi = 20 },
    { k = "WZWorkersPerZone", cfg = "wzCfg", field = "workersPerZone", lo = 1, hi = 4 },
    { k = "WZAwayRate", cfg = "wzCfg", field = "awayPerWorkerHour", lo = 1, hi = 20 },
}

-- one sandbox option into the settings (true = applied)
function M.sandboxApplyOne(e, v)
    if v == nil then return false end
    if e.set then
        if type(v) == "number" and e.mul then v = v * e.mul end
        M.settings[e.set] = v
        if e.im and type(ALifeImmersion) == "table" then ALifeImmersion.enabled = v ~= false end
        return true
    elseif e.cfg and type(M[e.cfg]) == "table" and tonumber(v) then
        local x = math.floor(tonumber(v))
        if x < e.lo then x = e.lo elseif x > e.hi then x = e.hi end
        M[e.cfg][e.field] = x
        return true
    end
    return false
end
local function sandboxVars()
    return type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or nil
end
M._sbSeen = M._sbSeen or {}
-- 0.8.12: IN-GAME CHOICES BEAT THE SANDBOX for this world (rule: in-game choices are set in game). The AI tab's
-- "In this game" buttons (AI wait, voice, NPC language) keep their choice in this world's mod data, like Immersive.
-- An admin changing that sandbox option mid-game clears the choice (sandboxWatch): the newest change wins.
local function overStore()
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeChatPlus_Settings") end)
    if d and type(d.over) ~= "table" then d.over = {} end
    return d
end
function M.sbEntry(k) for _, e in ipairs(M.sandboxMap) do if e.k == k then return e end end return nil end
function M.sbOverride(k) local d = overStore(); if d == nil then return nil end; return d.over[k] end
-- v = a sandbox-style value (AIWaitSec in seconds, Voice true/false, NpcLanguage 1-14); nil = back to the sandbox
function M.sbSetOverride(k, v)
    local e = M.sbEntry(k)
    if e == nil then return false end
    local d = overStore()
    if d then d.over[k] = v end
    local sv = sandboxVars()
    local use = v
    if use == nil and sv ~= nil then use = sv[k] end -- 0.9.1: explicit (a false sandbox value stays false)
    M.sandboxApplyOne(e, use)
    if type(M.applySettings) == "function" then pcall(M.applySettings) end
    ALifeHealth.note(TAG, k .. " set in game: " .. tostring(v) .. " (kept with this world)")
    return true
end
-- pre-1.0 (trip-ups): EVERY SWITCH YOU SAVE IN GAME STAYS. Before, only the AI tab's buttons and Immersive were kept;
-- the other ~80 sandbox-backed switches flipped back to the sandbox value on the next load. Now a row clicked in the
-- Settings window is "touched" (M.sbTouch); Save (M.saveSettingsFile) keeps each touched one in this world's mod data
-- (d.over), the same store the AI tab uses. Set it back to the sandbox value and the keep is dropped.
M.sbTouched = M.sbTouched or {}
function M.sbEntryBySet(key)
    for _, e in ipairs(M.sandboxMap) do if e.set == key then return e end end
    return nil
end
function M.sbTouch(key) if type(key) == "string" then M.sbTouched[key] = true end end
-- touched settings -> kept with this world; returns how many were kept / dropped
function M.sbKeepTouched()
    local d = overStore()
    local n = 0
    local sv = sandboxVars()
    for key, _ in pairs(M.sbTouched) do
        local e = M.sbEntryBySet(key)
        if e and not e.im and d then -- Immersive keeps itself (setImmersive)
            local v = M.settings[key]
            if type(v) == "number" and e.mul then v = v / e.mul end
            local sbv = nil
            if sv ~= nil then sbv = sv[e.k] end
            if sbv ~= nil and v == sbv then d.over[e.k] = nil else d.over[e.k] = v end
            n = n + 1
        end
    end
    M.sbTouched = {}
    if n > 0 then print(TAG .. " " .. n .. " setting(s) from the Settings window kept with this world") end
    return n
end
-- the Settings window marks rows this world remembers
function M.sbIsKept(key)
    if key == "immersive" then return M.immersiveOverride() ~= nil end
    local e = M.sbEntryBySet(key)
    if e == nil then return false end
    return M.sbOverride(e.k) ~= nil
end
-- "Back to sandbox values": forget every in-game keep for this world and load the sandbox again
function M.sbClearAll()
    local d = overStore()
    local n = 0
    if d then
        for _, _ in pairs(d.over) do n = n + 1 end
        d.over = {}
        if d.immersive ~= nil then d.immersive = nil; n = n + 1 end
    end
    M.sbTouched = {}
    pcall(M.sandboxApply)
    ALifeHealth.note(TAG, "back to sandbox values (" .. n .. " in-game choice(s) dropped)")
    return n
end
function M.sandboxApply()
    local sv = sandboxVars()
    if sv == nil or type(M.settings) ~= "table" then return 0 end
    local n = 0
    for _, e in ipairs(M.sandboxMap) do
        local v = sv[e.k]
        M._sbSeen[e.k] = v
        local o = M.sbOverride(e.k)
        if o ~= nil then v = o end
        if M.sandboxApplyOne(e, v) then n = n + 1 end
    end
    local lo, hi = tonumber(M.settings.ambientMinSec), tonumber(M.settings.ambientMaxSec)
    if lo and hi and lo > hi then M.settings.ambientMinSec, M.settings.ambientMaxSec = hi, lo end
    -- 0.7.0.4: immersive switched in game (Settings window) wins over the sandbox, for this world
    local ov = M.immersiveOverride()
    if ov ~= nil then M.settings.immersive = ov; if type(ALifeImmersion) == "table" then ALifeImmersion.enabled = ov end end
    M._sbApplying = true
    if type(M.applySettings) == "function" then pcall(M.applySettings) end
    M._sbApplying = false
    return n
end

----------------------------------------------------------------------------------------------------------------
-- 0.7.0.4: IMMERSIVE, SWITCHABLE IN GAME. Settings window > "Immersive". Kept with this world (global mod data), so
-- it outlasts a reload and beats the world's sandbox value; numbers, bond notes and the Factions overview come and go
-- at once (everything reads the switch when it's used).
----------------------------------------------------------------------------------------------------------------
local function store()
    local d = nil
    pcall(function() d = ModData.getOrCreate("ALifeChatPlus_Settings") end)
    return d
end
function M.immersiveOverride()
    local d = store()
    if d == nil or d.immersive == nil then return nil end
    return d.immersive == true
end
function M.setImmersive(on)
    on = on ~= false
    M.settings.immersive = on
    if type(ALifeImmersion) == "table" then ALifeImmersion.enabled = on end
    local d = store()
    if d then d.immersive = on end
    ALifeHealth.note(TAG, "immersive " .. (on and "on" or "off") .. " (switched in game, kept with this world)")
    return on
end
-- the Settings window flips M.settings.immersive and calls applySettings: keep the rest in step
local function wrapApply()
    if M._imApplyWrapped or type(M.applySettings) ~= "function" then return M._imApplyWrapped == true end
    M._imApplyWrapped = true
    local orig = M.applySettings
    M.applySettings = function(...)
        local res = orig(...)
        if not M._sbApplying then
            local want = M.settings.immersive ~= false
            local cur = type(ALifeImmersion) == "table" and ALifeImmersion.enabled ~= false
            if want ~= cur then pcall(M.setImmersive, want) end
        end
        return res
    end
    return true
end
if not wrapApply() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() wrapApply() end) end

-- 0.8.12 (Rock List 2): LIVE. The copy above ran only when the game loaded, so a sandbox option changed mid-game
-- (admin panel in MP, debug in SP) never landed. Every sandboxLiveSec seconds, options whose sandbox value CHANGED
-- since the last look are applied again; untouched ones are left alone, so a change made in the Settings window
-- still holds. Setting sandboxLiveSec (10; 0 = off).
if M.settings.sandboxLiveSec == nil then M.settings.sandboxLiveSec = 10 end
do
    M.fileKeys = M.fileKeys or {}
    local have = false
    for _, k in ipairs(M.fileKeys) do if k == "sandboxLiveSec" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "sandboxLiveSec" end
end
function M.sandboxWatch()
    local sv = sandboxVars()
    if sv == nil or not M._sandboxApplied then return 0 end
    local n = 0
    for _, e in ipairs(M.sandboxMap) do
        local v = sv[e.k]
        if v ~= M._sbSeen[e.k] then
            M._sbSeen[e.k] = v
            local d = overStore()
            if d and d.over[e.k] ~= nil then d.over[e.k] = nil end -- an admin change wins over the in-game choice
            if M.sandboxApplyOne(e, v) then
                n = n + 1
                ALifeHealth.note(TAG, "sandbox " .. e.k .. " changed in game -> " .. tostring(v))
            end
        end
    end
    if n > 0 then
        M._sbApplying = true
        if type(M.applySettings) == "function" then pcall(M.applySettings) end
        M._sbApplying = false
    end
    return n
end
if type(ALifeHealth) == "table" and type(ALifeHealth.tickAdd) == "function" then
    local last = 0
    ALifeHealth.tickAdd("ALifeSandboxLive", function()
        local sec = tonumber(M.settings.sandboxLiveSec) or 10
        if sec <= 0 then return end
        local now = M.nowMs and M.nowMs() or 0
        if now - last < sec * 1000 then return end
        last = now
        M.sandboxWatch()
    end)
end

-- after the settings file is read (Main's OnGameStart calls M.loadSettingsFile)
local function wrap()
    if M._sandboxWrapped or type(M.loadSettingsFile) ~= "function" then return false end
    local orig = M.loadSettingsFile
    M.loadSettingsFile = function(...)
        local res = orig(...)
        M._sandboxApplied = true
        local ok, n = pcall(M.sandboxApply)
        if ok then print(TAG .. " applied " .. tostring(n) .. " settings from this world's sandbox options")
        else print(TAG .. " could not apply sandbox options: " .. tostring(n)) end
        return res
    end
    M._sandboxWrapped = true
    return true
end
if not wrap() and type(Events) == "table" and Events.OnGameBoot then Events.OnGameBoot.Add(function() wrap() end) end
-- safety net: if the file loader never ran (or loaded first), apply once at game start too
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        wrap()
        if not M._sandboxApplied then M._sandboxApplied = true; pcall(M.sandboxApply) end
    end)
end
-- 0.5.1: the NPC language goes with every request to the chat engine (Python bridge)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        if M._langExtra or type(M.requestExtras) ~= "table" then return end
        table.insert(M.requestExtras, function(req)
            if type(ALifeLanguage) ~= "table" then return end
            local ok, code, name = pcall(ALifeLanguage.code)
            if ok and code and code ~= "en" then req.lang, req.langName = code, name end
        end)
        M._langExtra = true
    end)
end
print(TAG .. " ready pre-1.0: " .. #M.sandboxMap .. " sandbox options mapped, switches saved in game kept per world")
