-- A-Life Talk v0.3.3: optional integration with the separate mod "A-Life Talk Patch" (ALifeTalkPatch).
-- Without the patch every feature here is a no-op and A-Life Talk behaves exactly like 0.3.2.
-- With it:  pleas -> ALifeTalkPatch.plead (real calm-down);  an NPC's own "hands up / hand it over" line ->
-- ALifeTalkPatch.robPlayer (A-Life's robbery, A-Life's rules);  bitten NPCs / NPC killers -> per-pair A-Life
-- stance;  "Follow me" -> companion mode;  calmed NPCs say a line when they stand down.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Patch") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Patch"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Patch") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end

function M.patch()
    local P = ALifeTalkPatch
    if type(P) == "table" and P.loaded == true then return P end
    return nil
end

M.robWords = { "hands up", "hands where i can see", "drop it", "drop the", "drop your", "hand it over", "hand over",
    "give me your", "gimme your", "empty your", "your stuff", "your bag", "on your knees", "on the ground", "this is a robbery",
    "put it down", "toss it", "toss your", "dont move", "don't move", "freeze" }

-- the NPC demanded it themselves (the player's demands are handled elsewhere and never come through here)
function M.maybeRob(record, player, text, stance)
    local P = M.patch()
    if P == nil or not fn(P, "robPlayer") or (stance ~= "hostile" and stance ~= "careful") then return false end
    local low = string.lower(tostring(text or ""))
    local hit = false
    for _, w in ipairs(M.robWords) do if string.find(low, w, 1, true) then hit = true; break end end
    if not hit then return false end
    local ok, why = P.robPlayer(record, player)
    M.log("NPC demand -> A-Life robbery: " .. tostring(ok) .. (ok and "" or (" (" .. tostring(why) .. ")")))
    return ok
end

-- prompt: can this NPC's crew really rob you right now? (A-Life's own eligibility, dry run)
table.insert(M.requestExtras, function(req, player, listener, now)
    local P = M.patch()
    if P == nil or not fn(P, "canRob") or req.said == nil or req.said == "" then return end
    local stance = PA().Talk.stance(listener.record, player)
    if stance ~= "hostile" and stance ~= "careful" then return end
    local ok = P.canRob(listener.record, player)
    if ok then req.canRob = true end
end)

-- calmed down: a short line
M.eventModes.calm = { request = M.reactRequest, finish = M.reactFinish }
function M.onPatchCalm(record, player, reason)
    local pa = PA()
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(record.uid) or nil
    if shell == nil then return end
    M.react("calm", { record = record, shell = shell }, player, { what = "You decide to stop being hostile to the newcomer"
        .. (reason == "faction" and " (they've earned some respect)" or " (they talked you down)"),
        style = "wary, grudging, lowering your weapon; not friendly yet", maxWords = 12 },
        { key = "calm:" .. tostring(record.uid), keyCooldownMs = 120000, urgent = true, face = "player" })
end

M.patchHooked = M.patchHooked or false -- 0.5.2.4: a second run of this file never hooks the patch twice
function M.hookPatch()
    local P = M.patch()
    if P == nil or M.patchHooked or type(P.hooks) ~= "table" then return end
    table.insert(P.hooks.calm, function(record, player, reason) pcall(M.onPatchCalm, record, player, reason) end)
    M.patchHooked = true
    M.log("A-Life Talk Patch " .. tostring(P.VERSION) .. " found: calm-down, NPC robbery, pair stances, companion mode on")
end
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.hookPatch) end) end
pcall(M.hookPatch)

return M
