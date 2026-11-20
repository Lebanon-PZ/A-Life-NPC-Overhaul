-- A-Life Talk 0.5.1.3: glue for ALifeTalkPatch 1.4 "behaviour ownership".
-- While the patch owns an NPC, A-Life's own decision / movement step is skipped for that NPC and the patch drives the
-- body (listening to you, a daily activity, a party member, a resident of your base). A-Life keeps everybody else and
-- gets the NPC back the moment there is danger. This file:
--   * mirrors the settings ownBehaviour (master) / residentHold into the patch;
--   * claims settlers near you as "resident": inside ~8 tiles of the base A-Life's own base life runs, if they drift
--     out of it the patch walks them home (no more settlers wandering off).
-- Party claims live in ALifeLLMTalk_Party (partyOwnStep), listen claims in the patch's holdFriendly (Attention).
-- Everything is optional: no patch / old patch = nothing happens.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Own") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Own"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Own") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("ownBehaviour", true)
setting("partyOwn", true)
setting("residentHold", true)

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end

M.ownCfg = { tickMs = 5000, residentTiles = 70, residentRadius = 8, residentMs = 60000 }

function M.ownSync()
    local P = patch()
    if P == nil or type(P.settings) ~= "table" or type(P.settings.own) ~= "table" then return false end
    P.settings.own.enabled = M.settings.ownBehaviour ~= false
    P.settings.own.kinds.resident = M.settings.residentHold ~= false
    P.settings.own.kinds.party = M.settings.partyOwn ~= false
    P.settings.own.kinds.activity = M.settings.activity ~= false
    P.settings.own.kinds.listen = M.settings.attention ~= false
    return true
end

function M.ownResidentTick(now)
    local P = patch()
    if P == nil or not fn(P, "claim") then return 0 end
    local settlers = M.bucket and M.bucket("settlers") or {}
    local player = ALifeSide.you()
    if player == nil and ALifeSide.mpServer() and M.homePlayer then player = M.homePlayer() end -- pre-1.0 MP: the camp's player
    local px, py = pos(player)
    if px == nil then return 0 end
    local n = 0
    local pa = PA()
    for uid, s in pairs(settlers) do
        if type(s) == "table" and tonumber(s.x) and tonumber(s.y) then
            local k = P.owner(uid)
            if M.settings.residentHold == false or M.settings.ownBehaviour == false then
                if k == "resident" then P.release(uid, "setting off") end
            elseif s.away ~= nil then -- 0.5.1.8: on leave (travelling in your party): the party owns them, never the base
                if k == "resident" then P.release(uid, "travelling with the player") end
            elseif k == nil or k == "resident" then
                local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil
                local x, y = pos(sh)
                if x and ALifeSide.mpServer() then px, py = pos(ALifeSide.nearest(x, y)); px = px or -1e9; py = py or -1e9 end -- MP: any player near
                if x and (x - px) ^ 2 + (y - py) ^ 2 <= M.ownCfg.residentTiles ^ 2 then
                    local ok = P.claim(uid, "resident", { anchor = { x = math.floor(s.x), y = math.floor(s.y), z = math.floor(tonumber(s.z) or 0) },
                        radius = M.ownCfg.residentRadius, ms = M.ownCfg.residentMs,
                        bounds = type(s.bounds) == "table" and s.bounds or nil, pad = M.baseCfg and M.baseCfg.pad or 3 }) -- 0.5.1.8: A-Life's house = home
                    if ok then n = n + 1 end
                elseif k == "resident" then P.release(uid, "out of range") end
            end
        end
    end
    return n
end

function M.ownTick(now)
    if not M.ownSync() then return end
    pcall(M.ownResidentTick, now)
end

if Events and Events.OnTick then
    local last = 0
    ALifeHealth.tickAdd("ALifeLLMTalk_Own", function()
        local now = M.nowMs()
        if now - last < M.ownCfg.tickMs then return end
        last = now
        local ok, e = pcall(M.ownTick, now)
        if not ok then M.log("own error: " .. tostring(e)) end
    end)
end

return M
