-- A-Life NPC Overhaul 0.8.3 step 4b: A-LIFE'S STOCK REPLIES, MADE BETTER (Joe: AI on "replace them dynamically",
-- AI off "make them more better").
--   * AI on: a row you pick in A-Life's talk window that is only talk goes to the AI (Main.lua M.respond/tryDefer,
--     setting aiRows). Rows that DO something stay A-Life's.
--   * AI off (or the AI too slow): A-Life answers with its own lines - those already avoid repeats (A-Life keeps the
--     last 40 lines per person, 400 per player) and already fit their role, stance and mood. What A-Life can't know
--     is what we track: grief, a bite, hunger. Asked how they are (or what they miss, about family, told to hang in
--     there), they answer about THAT instead of a stock line. Setting stockState.
-- How: ProjectALife.Talk.speak (the call that picks and says A-Life's reply) is wrapped; only while A-Life is
-- answering you (Main.lua counts M.inStockRespond), only for those rows, never when hostile. Original runs otherwise.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_StockLines") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifeStockLines = ALifeStockLines or {}
local K = ALifeStockLines
local TAG = "[ALifeStockLines]"
K.VERSION = ALifeSide.MOD_VERSION
K.metrics = K.metrics or { swapped = 0, grief = 0, bite = 0, hungry = 0 }
K.DEFAULTS = { aiRows = true, stockState = true }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function M() return ALifeLLMTalk end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` turns a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
local function first(name) return string.match(tostring(name or "someone"), "^(%S+)") or tostring(name or "someone") end

-- which rows get a real-state answer, and what kind
K.ROWS = { HOW_ARE_YOU = "how", ASK_OKAY = "how", ENCOURAGE = "how", ASK_MISS = "miss", ASK_FAMILY = "family" }

K.LINES = {
    grief = {
        how = { "Honestly? Not good. I keep thinking about {n}.", "{n}'s gone. Still doesn't feel real.",
            "I'm standing. That's about all. We lost {n}.", "Don't ask me that right now. {n}...",
            "Every time it gets quiet I think about {n}." },
        miss = { "{n}. I miss {n}.", "Easy. {n}. Every minute of the day.", "Used to be a lot of things. Now it's just {n}." },
        family = { "I had {n}. Not anymore.", "Had. {n}. Don't make me talk about it.", "There was {n}. That's over now." },
    },
    biteTold = {
        how = { "Got bit. So you tell me how I'm doing.", "I'm bit. Not much else to say about it.",
            "Bitten. I'm trying not to think about what comes next." },
    },
    biteHidden = {
        how = { "Fine. Why? Do I look sick to you?", "I'm fine. Stop looking at me like that.", "Just tired. That's all it is." },
    },
    starving = {
        how = { "Hungry. Haven't eaten right in days.", "I'd kill for a can of beans, honestly.",
            "Stomach's been empty so long it quit complaining." },
    },
    parched = { -- 0.8.2 part 2
        how = { "Thirsty. Real thirsty.", "Mouth's like sand. You got water?", "Haven't had a drink since yesterday." },
    },
}

local function pick(list, uid)
    if type(list) ~= "table" or #list == 0 then return nil end
    K.turn = (K.turn or 0) + 1
    local h = 0
    for i = 1, #tostring(uid) do h = h + string.byte(tostring(uid), i) end
    return list[(h + K.turn) % #list + 1]
end

-- the line about how they really are, or nil (A-Life's own line stays)
function K.stateLine(uid, intent)
    local kind = K.ROWS[intent]
    if kind == nil then return nil end
    local m = M()
    uid = tostring(uid)
    -- a bite beats everything; whether they admit it is who they are (Bite.lua biteMode: hide / partner / all)
    if kind == "how" and fn(m, "biteInfo") then
        local ok, b = pcall(m.biteInfo, uid)
        if ok and type(b) == "table" then
            local mode = "all"
            if fn(m, "biteMode") then local okM, x = pcall(m.biteMode, uid); if okM and x then mode = x end end
            K.metrics.bite = K.metrics.bite + 1
            return pick(mode == "all" and K.LINES.biteTold.how or K.LINES.biteHidden.how, uid)
        end
    end
    -- grief that still weighs on them (Loss.lua: g >= 0.2 = more than an old scar)
    if fn(m, "lossNow") then
        local ok, L = pcall(m.lossNow, uid)
        if ok and type(L) == "table" and (tonumber(L.g) or 0) >= 0.2 and L.name ~= nil then
            local list = K.LINES.grief[kind]
            local line = pick(list, uid)
            if line ~= nil then
                K.metrics.grief = K.metrics.grief + 1
                return (string.gsub(line, "{n}", first(L.name)))
            end
        end
    end
    -- really hungry (Psyche.lua off-screen needs, hunger 0..1)
    if kind == "how" and fn(m, "lifeOf") then
        local ok, life = pcall(m.lifeOf, uid)
        if ok and type(life) == "table" and (tonumber(life.thirst) or 0) >= 0.8 then -- thirst first: it kills faster
            K.metrics.hungry = K.metrics.hungry + 1
            return pick(K.LINES.parched.how, uid)
        end
        if ok and type(life) == "table" and (tonumber(life.hunger) or 0) >= 0.8 then
            K.metrics.hungry = K.metrics.hungry + 1
            return pick(K.LINES.starving.how, uid)
        end
    end
    return nil
end

-- which of our rows a pool of A-Life replies belongs to (Talk.speak gets the pool, not the row id)
function K.intentOf(records)
    local data = PA() and PA().DialogueData or nil
    if type(data) ~= "table" or type(data.replies) ~= "table" or type(records) ~= "table" then return nil end
    for intent, _ in pairs(K.ROWS) do
        local ok, pool = pcall(function() return data.replies[intent] end)
        if ok and pool == records then return intent end
    end
    return nil
end

function K.wrapSpeak(talk)
    if not fn(talk, "speak") or talk.speak__StockLines ~= nil then return talk ~= nil and talk.speak__StockLines ~= nil end
    local orig = talk.speak
    talk.speak__StockLines = orig
    talk.speak = function(record, shell, player, records, context, vars, allowShortRepeat)
        local m = M()
        if not K.off and type(m) == "table" and (m.inStockRespond or 0) > 0 and setting("stockState") ~= false
                and type(record) == "table" and shell ~= nil and not (type(context) == "table" and context.stance == "hostile") then
            local ok, line = pcall(function()
                local intent = K.intentOf(records)
                return intent and K.stateLine(record.uid, intent) or nil
            end)
            if not ok then
                K.off = true
                log("swap failed, off for this session: " .. tostring(line))
            elseif line ~= nil then
                local speech = PA().Speech
                local said = fn(speech, "say") and speech.say(shell, line, { face = player }) or false
                if said then
                    if fn(speech, "remember") and fn(speech, "playerKey") then
                        pcall(speech.remember, record.uid, speech.playerKey(player), line)
                    end
                    K.metrics.swapped = K.metrics.swapped + 1
                    return line, { t = line }
                end
            end
        end
        return orig(record, shell, player, records, context, vars, allowShortRepeat)
    end
    return true
end

-- load time: defaults + save keys; Talk.speak is wrapped once A-Life's Talk exists
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "aiRows", "stockState" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
    end
end

function K.tryInstall()
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "speak") then return false end
    local ok = K.wrapSpeak(pa.Talk)
    if ok then log("ready v" .. K.VERSION .. ": A-Life rows -> AI " .. (setting("aiRows") ~= false and "on" or "off")
        .. ", real-state answers " .. (setting("stockState") ~= false and "on" or "off")) end
    return ok
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        if K.tryInstall() or Events.OnTick == nil then return end
        local tries = 0
        local function retry()
            tries = tries + 1
            if K.tryInstall() or tries > 600 then Events.OnTick.Remove(retry) end
        end
        Events.OnTick.Add(retry)
    end)
end
