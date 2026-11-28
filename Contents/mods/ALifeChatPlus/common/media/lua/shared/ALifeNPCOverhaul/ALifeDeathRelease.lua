-- A-Life NPC Overhaul pre-1.0: WHEN YOU DIE, YOUR PARTY LETS GO (Joe Nov 27: died, new character with the same name in
-- another town, and one of the people who had turned on him appeared right on top of him, hostile).
-- Why: A-Life keys a companion's owner by username (Companions.playerKey -> Speech.playerKey) and its catch-up places
-- a companion beside the owner when far and unseen (Rules.catchUp / Companions ~1362, 42.20 source). The new
-- character has the same key, so the old party, even someone who had turned hostile, was "caught up" to it.
-- Now, on your death: every A-Life companion of yours is dismissed through A-Life's own C.dismiss (it keeps
-- memory.companionKept, as a normal dismiss does), and our party list lets them go (M.partyLeave). They stay where
-- they were. Camp residents are not touched (Legacy: the camp outlives you).
-- SP: OnPlayerDeath. MP server: OnCharacterDeath for an online player (OnPlayerDeath fires only on the dying client).
-- Setting deathReleaseParty (true).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeDeathRelease")
ALifeDeathRelease = ALifeDeathRelease or {}
local D = ALifeDeathRelease
local TAG = "[ALifeDeathRelease]"
D.metrics = D.metrics or { deaths = 0, released = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end

do
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" then
        if M.settings.deathReleaseParty == nil then M.settings.deathReleaseParty = true end
        M.fileKeys = M.fileKeys or {}
        local have = false
        for _, k in ipairs(M.fileKeys) do if k == "deathReleaseParty" then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = "deathReleaseParty" end
    end
end

function D.on()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.deathReleaseParty == false)
end

-- returns how many were let go
function D.release(player)
    if player == nil or not D.on() then return 0 end
    D.metrics.deaths = D.metrics.deaths + 1
    local n, seen = 0, {}
    local PA = type(ProjectALife) == "table" and ProjectALife or {}
    local C = PA.Companions
    if fn(C, "playerKey") and fn(C, "roster") and fn(C, "dismiss") then
        local okK, key = pcall(C.playerKey, player)
        local okR, list = pcall(C.roster, okK and key or nil)
        for _, uid in ipairs(okR and type(list) == "table" and list or {}) do
            local ok, done = pcall(C.dismiss, player, uid, "owner_died")
            if ok and done == true then n = n + 1 end
            seen[tostring(uid)] = true
        end
    end
    local M = ALifeLLMTalk
    if type(M) == "table" and fn(M, "partyMembers") and fn(M, "partyLeave") then
        local ok, list = pcall(M.partyMembers, player)
        for _, uid in ipairs(ok and type(list) == "table" and list or {}) do
            local okL = pcall(M.partyLeave, uid, player, "you died")
            if okL and not seen[tostring(uid)] then n = n + 1 end
        end
    end
    D.metrics.released = D.metrics.released + n
    print(TAG .. " you died: " .. tostring(n) .. " of your party let go (they stay where they were)")
    return n
end

-- someone who turned on you is no companion of yours: a hostile companion (A-Life opinion <= deathHostileAt) is let
-- go too, checked every minute for each online player (also cleans saves where the old party already caught up)
function D.dropTurned(player)
    if player == nil or not D.on() then return 0 end
    local PA = type(ProjectALife) == "table" and ProjectALife or {}
    local C, Op, R = PA.Companions, PA.NpcOpinion, PA.ActorRegistry
    if not (fn(C, "playerKey") and fn(C, "roster") and fn(C, "dismiss") and fn(Op, "valueOf") and fn(R, "read")) then return 0 end
    local M = ALifeLLMTalk
    local at = type(M) == "table" and type(M.settings) == "table" and tonumber(M.settings.deathHostileAt) or -41
    local okK, key = pcall(C.playerKey, player)
    local okR, list = pcall(C.roster, okK and key or nil)
    local n = 0
    for _, uid in ipairs(okR and type(list) == "table" and list or {}) do
        local okV, v = pcall(function() return tonumber((Op.valueOf(R.read(uid), player))) end)
        if okV and v ~= nil and v <= at then
            local ok, done = pcall(C.dismiss, player, uid, "turned")
            if type(M) == "table" and fn(M, "partyLeave") then pcall(M.partyLeave, uid, player, "turned on you") end
            if ok and done == true then n = n + 1 end
        end
    end
    if n > 0 then print(TAG .. " " .. tostring(n) .. " who turned on you no longer follow you") end
    return n
end
do
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" then
        if M.settings.deathHostileAt == nil then M.settings.deathHostileAt = -41 end
        M.fileKeys = M.fileKeys or {}
        local have = false
        for _, k in ipairs(M.fileKeys) do if k == "deathHostileAt" then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = "deathHostileAt" end
    end
end

if type(Events) == "table" then
    if Events.EveryOneMinute then
        Events.EveryOneMinute.Add(function()
            if type(ALifeSide) == "table" and ALifeSide.mpClient() then return end
            for _, p in ipairs(ALifeSide.online()) do pcall(D.dropTurned, p) end
        end)
    end
    if Events.OnPlayerDeath then
        Events.OnPlayerDeath.Add(function(p)
            if type(ALifeSide) == "table" and ALifeSide.mpClient() then return end -- MP: the server does it
            pcall(D.release, p)
        end)
    end
    if Events.OnCharacterDeath then
        Events.OnCharacterDeath.Add(function(c)
            if type(ALifeSide) ~= "table" or not ALifeSide.mpServer() then return end -- SP: OnPlayerDeath above
            if ALifeSide.isOnlinePlayer(c) then pcall(ALifeSide.with, c, D.release, c) end
        end)
    end
end
print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": your party lets go when you die (no catch-up to your next character)")
return D
