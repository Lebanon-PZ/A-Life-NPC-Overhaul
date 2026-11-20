-- A-Life Talk 0.5.0: optional voice (all the audio work happens in the bridge; nothing here needs it).
--   * Push-to-talk: hold the voice key in game (default: the ` key, change "pttKey" in the settings file) - the game
--     writes Zomboid/Lua/alifetalk_ptt.txt ("down"/"up"), the bridge records your microphone meanwhile, transcribes it
--     with faster-whisper and pushes the text back; it is said through A-Life's own chat path (TalkInput.say), exactly
--     as if you had typed it. The bridge can also use its own global hotkey (--ptt-key) instead.
--   * NPC voices: the bridge speaks NPC lines with Piper, one stable voice per NPC picked by sex and age (sent here as
--     req.voice). The game itself cannot play generated audio, so the bridge plays it on your speakers.
-- With the bridge started without --voice, the key just does nothing.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeLLMTalk_Voice") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Voice"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Voice") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end

M.voiceState = { down = false, at = 0, heardAt = 0 }

local function writePtt(state)
    pcall(function()
        local w = getFileWriter("alifetalk_ptt.txt", true, false)
        w:write(state .. " " .. tostring(nowMs()) .. "\n")
        w:close()
    end)
end
function M.pttKey()
    local k = M.settings.pttKey
    if type(k) == "number" then return k end
    if type(k) == "string" and type(Keyboard) == "table" and type(Keyboard[k]) == "number" then return Keyboard[k] end
    return type(Keyboard) == "table" and Keyboard.KEY_GRAVE or 41
end
local function typing()
    -- don't trigger while a text box (chat, A-Life talk box) has focus
    local ok, busy = pcall(function()
        return type(ISChat) == "table" and ISChat.instance ~= nil and ISChat.instance.focused == true
    end)
    if ok and busy then return true end
    local input = PA() and PA().TalkInput
    if input and input.box and type(input.box.isVisible) == "function" then
        local okV, vis = pcall(function() return input.box:isVisible() end)
        if okV and vis then return true end
    end
    return false
end
function M.onPttDown(key)
    if M.settings.voice == false or key ~= M.pttKey() or M.voiceState.down or typing() then return end
    M.voiceState.down, M.voiceState.at = true, nowMs()
    writePtt("down")
    local p = ALifeSide.you()
    if p then pcall(function() p:setHaloNote("Listening...", 120, 200, 140, 120) end) end
end
function M.onPttUp(key)
    if key ~= M.pttKey() or not M.voiceState.down then return end
    M.voiceState.down = false
    writePtt("up")
end

-- bridge -> game: the transcript ("voice" push: time ms || text)
M.pushHandlers = M.pushHandlers or {}
M.pushHandlers.voice = function(uid, rest)
    local ts, text = string.match(rest or "", "^(%d+)||(.*)$")
    ts = tonumber(ts)
    if ts == nil or text == nil or text == "" then return end
    if math.abs(nowMs() - ts) > 30000 then return end -- old line from an earlier session
    M.voiceState.heardAt = nowMs()
    local input = PA() and PA().TalkInput
    log("voice: \"" .. text .. "\"")
    if input and type(input.say) == "function" then
        pcall(input.say, text, false)
    else
        local p = ALifeSide.you()
        if p then pcall(function() p:Say(text) end) end
        local talk = PA() and PA().Talk
        if talk and type(talk.onPlayerText) == "function" then pcall(talk.onPlayerText, p, text, false) end
    end
end

-- which voice the bridge should use for this NPC
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.voice == false or not (listener and listener.record) then return end
    local age = M.ageOf and M.ageOf(listener.record.uid) or nil
    req.voice = { age = age, sex = req.npc and req.npc.sex or nil }
end)

if M.settings.voice == nil then M.settings.voice = true end
if M.settings.pttKey == nil then M.settings.pttKey = "KEY_GRAVE" end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "voice", "pttKey" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
if type(Events) == "table" then
    if Events.OnKeyStartPressed then Events.OnKeyStartPressed.Add(function(k) pcall(M.onPttDown, k) end) end
    if Events.OnKeyPressed then ALifeHealth.add(Events.OnKeyPressed, "ALifeLLMTalk_Voice", function(k) pcall(M.onPttUp, k) end) end
end
return M
