-- A-Life NPC Overhaul pre-1.0: EARSHOT. You only see an NPC's speech bubble when you could hear them.
--   * Closer than earClearTiles: the whole line.
--   * Between earClearTiles and earTiles: you catch part of it, mostly nouns (names, things, places); the verbs,
--     small words and adjectives drop out ("... ... water ... gate ...").
--   * Past earTiles: nothing is drawn (cries of pain and last words carry twice as far).
-- Wraps ProjectALife.Speech.display (client only). Immersion-gated: off with immersive=false, or earshot=false.
-- Settings (all in alifetalk_settings.txt): earshot (true), earTiles (default talkTiles = 14), earClearTiles (default 75% of it).
-- It never touches the NPC's memory or the chat log other NPCs read; only what is drawn for YOU.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Earshot")
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeEarshot]"
ALifeEarshot = ALifeEarshot or {}
local K = ALifeEarshot
K.VERSION = "0.9.6"
K.metrics = { shown = 0, garbled = 0, hidden = 0 }

local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("earshot", true)
setting("earTiles", 0)       -- 0 = use talkTiles
setting("earClearTiles", 0)  -- 0 = 75 % of earTiles

local SKIP = {}
for w in string.gmatch("a an the and or but so if then than that this these those i you he she it we they me him her us them my your his its our their " ..
    "is am are was were be been being do does did done have has had having will would shall should can could may might must " ..
    "to of in on at by for with from up down out off over into onto as not no yes just very really quite too also still " ..
    "get got go going gone went come came let make made take took give gave say said tell told see saw look know knew think " ..
    "want need like hey oh well now here there when where what who why how all some any more most much many few ", "%S+") do SKIP[w] = true end
local PAINKIND = { pain = true, final = true }

function K.range(kind)
    local hear = tonumber(M.settings.earTiles) or 0
    if hear <= 0 then hear = tonumber(M.settings.talkTiles) or 14 end
    local clear = tonumber(M.settings.earClearTiles) or 0
    if clear <= 0 or clear >= hear then clear = math.floor(hear * 0.75) end
    if PAINKIND[kind or ""] then hear = hear * 2; clear = clear * 2 end
    return clear, hear
end

-- keep roughly "keep" (0..1) of the content words; small words never; consecutive gaps collapse to one "..."
function K.garble(text, keep)
    local out, gap = {}, false
    local n = 0
    for word in string.gmatch(tostring(text), "%S+") do
        n = n + 1
        local bare = string.lower(string.gsub(word, "[%p]", ""))
        local content = bare ~= "" and not SKIP[bare] and #bare >= 3
        -- stable pick from the word itself + its place (no flicker, no random state)
        local h = 0
        for i = 1, #bare do h = (h * 31 + string.byte(bare, i)) % 1009 end
        h = (h + n * 7) % 100
        local capital = string.find(word, "^%u") ~= nil and n > 1
        if content and (capital or h < keep * 100) then
            out[#out + 1] = word; gap = false
        elseif not gap then
            out[#out + 1] = "..."; gap = true
        end
    end
    -- past clear range something must always be lost, or short lines come through whole and it looks random
    local lost = false
    for _, w in ipairs(out) do if w == "..." then lost = true end end
    if not lost then
        for i = #out, 1, -1 do
            if #out[i] >= 3 and not SKIP[string.lower((string.gsub(out[i], "[%p]", "")))] then out[i] = "..."; lost = true; break end
        end
        if not lost and #out > 0 then out[#out] = "..." end
    end
    local s = table.concat(out, " ")
    if not string.find(s, "%a") then return nil end
    return s
end

local function distTo(shell)
    local me = nil
    pcall(function() me = ALifeSide.you() end)
    if me == nil or shell == nil or me == shell then return nil end
    local d = nil
    pcall(function()
        local dx, dy = me:getX() - shell:getX(), me:getY() - shell:getY()
        d = math.sqrt(dx * dx + dy * dy)
        if math.floor(me:getZ()) ~= math.floor(shell:getZ()) then d = d + 6 end -- another floor muffles
    end)
    return d
end

-- the earshot rule for one line: returns the text to draw, or false (not heard). Used by the wrapper below and by ALifeBubbles.
function K.apply(shell, text, kind)
    if M.settings.earshot == false or M.settings.immersive == false or type(text) ~= "string" then return text end
    local ok, res = pcall(function()
        local d = distTo(shell)
        if d == nil then return text end
        local clear, hear = K.range(kind)
        if d <= clear then return text end
        if d > hear then return false end
        local keep = 0.85 - (d - clear) / math.max(1, hear - clear) * 0.65
        return K.garble(text, keep) or false
    end)
    if not ok then return text end
    if res == false then K.metrics.hidden = K.metrics.hidden + 1
    elseif res ~= text then K.metrics.garbled = K.metrics.garbled + 1 else K.metrics.shown = K.metrics.shown + 1 end
    return res
end

function K.install()
    if K.installed then return true end
    local pa = type(ProjectALife) == "table" and ProjectALife or nil
    if pa == nil or type(pa.Speech) ~= "table" or type(pa.Speech.display) ~= "function" then return false end
    local orig = pa.Speech.display
    pa.Speech.display = function(shell, text, color, kind, uid)
        if not K.skip then
            local res = K.apply(shell, text, kind)
            if res == false then return true end
            text = res
        end
        return orig(shell, text, color, kind, uid)
    end
    K.installed = true
    print(TAG .. " ready v" .. K.VERSION .. ": speech bubbles follow earshot (clear " .. tostring(select(1, K.range())) .. " / heard " .. tostring(select(2, K.range())) .. " tiles)")
    return true
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function() pcall(K.install) end)
end
if Events and Events.OnTick then
    local tries = 0
    local function again()
        tries = tries + 1
        if K.installed or tries > 600 or pcall(K.install) and K.installed then Events.OnTick.Remove(again) end
    end
    Events.OnTick.Add(again)
end
return K
