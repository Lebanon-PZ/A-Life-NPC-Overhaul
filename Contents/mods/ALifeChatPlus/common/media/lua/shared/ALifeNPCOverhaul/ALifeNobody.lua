-- A-Life NPC Overhaul: say so when nobody can hear you.
-- A-Life silently drops typed or spoken text when no NPC is in earshot (it only logs "why=nobody").
-- This shows a short on-screen note instead, so it doesn't feel like the chat is broken.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeNobody") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeNobody]"
ALifeNobody = ALifeNobody or {}
local N = ALifeNobody
N.TEXT = "Nobody is close enough to hear you. Walk up to someone (about 12 tiles), or shout with ! if it's one of your people."
N.lastAt = -1e18

local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

function N.show()
    local t = nowMs()
    if t - N.lastAt < 3000 then return end
    N.lastAt = t
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    local Party = ProjectALife and ProjectALife.Party
    local ok = Party and type(Party.notice) == "function" and pcall(Party.notice, player, N.TEXT)
    if not ok then pcall(function() player:setHaloNote(N.TEXT, 255, 200, 120, 300) end) end
end

function N.install()
    if N.__installed then return true end
    local Talk = ProjectALife and ProjectALife.Talk
    if Talk == nil or type(Talk.typedLog) ~= "function" then return false end
    N.__installed = true
    local orig = Talk.typedLog
    Talk.typedLog = function(reason, uid, now)
        if tostring(reason) == "nobody" then pcall(N.show) end
        return orig(reason, uid, now)
    end
    print(TAG .. " ready (a note shows when nobody can hear you)")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(N.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
