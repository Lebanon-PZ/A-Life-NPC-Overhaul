-- A-Life NPC Overhaul 0.8.3 step 7: BODY LANGUAGE. A-Life 1.5 already moves people while they talk: TalkGesture
-- reads the words of a line, picks a mood (neutral / friendly / emphatic / question / nervous / angry) and plays a
-- gesture plan for it (Speech.say -> Speech.gesture -> TalkGesture.onLine). Keyword guessing gets AI lines wrong, so
-- the AI now says the mood (bridge JSON "gesture") and the plan A-Life has for THAT mood is played instead.
-- A-Life still decides how often a line gets a gesture (its own chance per mood), when it fits (not moving, not in
-- a fight, close enough) and its cooldowns. Off: talkGestures (then A-Life guesses from the words, as before).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Gesture") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifeGestureAI = ALifeGestureAI or {}
local G = ALifeGestureAI
G.VERSION = ALifeSide.MOD_VERSION
G.MOODS = { neutral = true, friendly = true, emphatic = true, question = true, nervous = true, angry = true }
G.DEFAULTS = { talkGestures = true }
G.metrics = G.metrics or { asked = 0, planned = 0, none = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function M() return ALifeLLMTalk end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return math.random(0, n - 1) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` turns a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end

-- play A-Life's gesture plan for this mood on the line just said (replaces the plan A-Life guessed from the words)
function G.apply(shell, player, text, mood)
    if setting("talkGestures") == false or shell == nil or player == nil or not G.MOODS[tostring(mood)] then return false end
    if mood == "neutral" then return false end
    local T = type(ProjectALife) == "table" and ProjectALife.TalkGesture or nil
    if not (fn(T, "plan") and fn(T, "armedOf") and type(T.plans) == "table") then return false end
    if fn(T, "enabled") and not T.enabled() then return false end
    if fn(T, "targetOk") and not T.targetOk(player) then return false end
    -- same rule as A-Life's onLine: animations run where the NPC lives (SP / host), not on an MP client
    local clientOnly = ALifeSide.mpClient()
    if clientOnly then return false end
    G.metrics.asked = G.metrics.asked + 1
    local steps = T.plan(text, mood, T.armedOf(shell), { chance = roll(100), pick = roll(1000) })
    if type(steps) ~= "table" or #steps == 0 then G.metrics.none = G.metrics.none + 1; return false end
    local now = nowMs()
    for _, step in ipairs(steps) do step.atMs = now + (tonumber(step.atMs) or 0) end
    T.plans[shell] = { steps = steps, target = player, mood = mood }
    G.metrics.planned = G.metrics.planned + 1
    return true
end

do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(G.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            local have = false
            for _, x in ipairs(m.fileKeys) do if x == "talkGestures" then have = true end end
            if not have then m.fileKeys[#m.fileKeys + 1] = "talkGestures" end
        end
        m.applyGesture = function(shell, player, text, mood) return G.apply(shell, player, text, mood) end
        if type(m.requestExtras) == "table" then
            table.insert(m.requestExtras, function(req) if setting("talkGestures") ~= false then req.gestures = true end end)
        end
    end
end
print("[ALifeGestureAI] ready v" .. G.VERSION .. ": the AI picks the mood, A-Life plays the gesture")
