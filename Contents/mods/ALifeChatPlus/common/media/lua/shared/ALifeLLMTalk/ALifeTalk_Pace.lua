-- A-Life NPC Overhaul 0.8.3 step 5: PACE. People out here talk short.
--   * talkLength: 1 short (one or two sentences, max 15 words; default) / 2 normal (the old 25-word rule) / 3 chatty.
--     Asked for a story or "tell me about" something, they get one level more.
--   * thinkBeatMs: while your reply is on its way, their grey "..." shows again every few seconds (Main.lua poll).
--   * replyPace: a reply faster than a person would answer waits a moment (Main.lua M.paceMs / M.held).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Pace") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifePace = ALifePace or {}
local P = ALifePace
P.VERSION = "0.8.3"
P.DEFAULTS = { talkLength = 1, thinkBeatMs = 3000, replyPace = true }
P.MORE_WORDS = { "story", "tell me about", "what happened", "how did it", "what was it like", "go on" }

local function M() return ALifeLLMTalk end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` turns a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = P.DEFAULTS[key] end
    return v
end

function P.lengthFor(said)
    local n = math.max(1, math.min(3, math.floor(tonumber(setting("talkLength")) or 1)))
    local low = string.lower(tostring(said or ""))
    for _, w in ipairs(P.MORE_WORDS) do
        if string.find(low, w, 1, true) then return math.min(3, n + 1) end
    end
    return n
end

do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(P.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "talkLength", "thinkBeatMs", "replyPace" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
        if type(m.requestExtras) == "table" then
            table.insert(m.requestExtras, function(req, player, listener, now)
                if type(req.said) == "string" then req.length = P.lengthFor(req.said) end
            end)
        end
    end
end
print("[ALifePace] ready v" .. P.VERSION .. ": replies " .. ({ "short", "normal", "chatty" })[P.lengthFor("")] .. " by default")
