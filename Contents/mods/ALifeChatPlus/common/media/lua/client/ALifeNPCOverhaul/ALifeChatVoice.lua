-- A-Life NPC Overhaul: voice input. The voice helper (bridge\alifeai_voice.ps1) writes what you said to
-- Zomboid\Lua\alifeai_say.txt; this reads it and says it exactly as if you'd typed it in A-Life's chat line
-- (ProjectALife.TalkInput.say), so the nearest NPC answers. Sleeps unless the helper's heartbeat is fresh.

local TAG = "[ALifeChatVoice]"
local SAY, ALIVE = "alifeai_say.txt", "alifeai_voice_alive.txt"
local CHECK_EVERY = 15                  -- ticks between reads while the helper runs
local ALIVE_EVERY_MS, ALIVE_MAX_AGE = 3000, 10000

ALifeChatVoice = ALifeChatVoice or {}
local VO = ALifeChatVoice

-- Shouting on purpose only.
-- Voice: Whisper adds "!" whenever you sound excited, so voice never shouts from punctuation. Start with "yell" or
--   "shout" ("Yell, Dale, get back here") to shout; the word itself isn't said.
-- Typed: "!" at the start (A-Life's own) or at the end ("Get back here!") shouts. Anything else is normal talk.
VO.YELL_WORDS = { "yell", "yelling", "shout", "shouting", "holler" }

function VO.voiceRule(text)
    local t = string.gsub(tostring(text or ""), "!", ".")
    t = string.gsub(t, "^%s+", "")
    local first, rest = string.match(t, "^([%a]+)[%s,%.:;%-]+(.*)$")
    if first ~= nil then
        local w = string.lower(first)
        for _, y in ipairs(VO.YELL_WORDS) do
            if w == y then
                rest = string.gsub(rest, "^%s+", "")
                if rest == "" then return nil end
                return rest, true
            end
        end
    end
    if string.match(t, "^%s*$") then return nil end
    return t, false
end

function VO.typedRule(text, loud)
    text = tostring(text or "")
    if loud ~= true and string.match(text, "!%s*$") and not string.match(text, "^%s*!") then
        text = string.gsub(text, "!+%s*$", "!")
        return text, true
    end
    return text, loud
end

-- typed lines ending in "!" shout (A-Life already handles a leading "!")
function VO.installTyped()
    local input = ProjectALife and ProjectALife.TalkInput
    if input == nil or type(input.say) ~= "function" or VO.__typed then return false end
    VO.__typed = true
    local original = input.say
    input.say = function(text, loud)
        local t, l = VO.typedRule(text, loud)
        return original(t, l)
    end
    print(TAG .. " typed: '!' at the start or end shouts; voice: start with 'yell' to shout")
    return true
end
if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function() pcall(VO.installTyped) end)
end

local disabled = false
local pending, pendingAt = nil, 0           -- what you said, held until you finish
local tick, lastSeq, alive, aliveAt = 0, nil, false, -1e18

local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

local function readLines(name)
    local reader = getFileReader(name, false)
    if reader == nil then return nil end
    local out = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        out[#out + 1] = tostring(line)
    end
    reader:close()
    return out
end

local function helperAlive()
    local t = now()
    if t - aliveAt < ALIVE_EVERY_MS then return alive end
    aliveAt = t
    alive = false
    local lines = readLines(ALIVE)
    local beat = lines and lines[1] and tonumber(string.match(lines[1], "(%d+)")) or nil
    if beat ~= nil and math.abs(t - beat) < ALIVE_MAX_AGE then alive = true end
    return alive
end

local function check()
    if not helperAlive() then return end
    local lines = readLines(SAY)
    if lines == nil then
        if lastSeq == nil then lastSeq = -1 end                 -- primed: nothing left over, next line is new
        return
    end
    local seq, text = nil, nil
    for _, l in ipairs(lines) do
        seq = seq or tonumber(string.match(l, "^seq=(%d+)"))
        text = text or string.match(l, "^text=(.*)$")
    end
    if seq == nil or text == nil then return end
    if lastSeq == nil then lastSeq = seq return end          -- don't replay whatever was left from last session
    if seq == lastSeq then return end
    lastSeq = seq
    -- don't answer half a sentence: hold it, and join whatever you say next if it comes quickly
    pending = pending and (pending .. " " .. text) or text
    pendingAt = now()
end

-- how long to wait for the rest: longer when you trailed off ("...", ",", no full stop)
VO.WAIT_DONE_MS, VO.WAIT_MORE_MS = 1200, 3000
function VO.waitFor(text)
    local t = string.gsub(tostring(text or ""), "%s+$", "")
    if string.match(t, "%.%.%.$") or string.match(t, "[,;:%-]$") or not string.match(t, "[%.%?!]$") then return VO.WAIT_MORE_MS end
    return VO.WAIT_DONE_MS
end

local function flush()
    if pending == nil or now() - (pendingAt or 0) < VO.waitFor(pending) then return end
    local text = string.gsub(pending, "%.%.%.%s+", " ")
    pending = nil
    local input = ProjectALife and ProjectALife.TalkInput
    local spoken, loud = VO.voiceRule(text)
    if spoken ~= nil and input ~= nil and type(input.say) == "function" then input.say(spoken, loud) end
end

local function onTick()
    if disabled then return end
    tick = tick + 1
    if tick < CHECK_EVERY then return end
    tick = 0
    local ok, err = pcall(function() check(); flush() end)
    if not ok then
        disabled = true
        print(TAG .. " failed, voice input disabled for this session: " .. tostring(err))
    end
end

if Events ~= nil and Events.OnTick ~= nil and type(getFileReader) == "function" then
    ALifeHealth.add(Events.OnTick, "ALifeChatVoice", onTick)
end
print(TAG .. " loaded")
