-- A-Life NPC Overhaul 0.7.0.2: TALK WHILE PAUSED.
-- A-Life's chat box, our AI reply check, and the "keys back on" timer after you send a line all run on the game tick,
-- which stops while the game is paused. Here, ONLY while paused, the same three run on OnTickEvenPaused:
--   * the chat key opens A-Life's box (A-Life's own box and rules: single player, not with the MP chat)
--   * the AI helper's answer is picked up and shown
--   * A-Life switches game keys off for a moment after you send a line; its timer to switch them back on counts down
--     here too, so the keys never stay off while paused (you can always unpause)
-- Unpaused, nothing here runs. Setting: talkWhilePaused (Settings window).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_PausedTalk") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end

M.ptStats = M.ptStats or { opened = 0, polls = 0, keysBack = 0 }
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function paused()
    local ok, p = pcall(function()
        local sc = UIManager.getSpeedControls()
        if sc ~= nil then return sc:getCurrentGameSpeed() == 0 end
        return getGameSpeed() == 0
    end)
    return ok and p == true
end
local function chatKeys()
    local out, seen = {}, {}
    local function add(k) k = tonumber(k); if k and k > 0 and not seen[k] then seen[k] = true; out[#out + 1] = k end end
    pcall(function() add(getCore():getKey("Toggle chat")) end)
    pcall(function() add(getCore():getKey("Alt toggle chat")) end)
    pcall(function() if type(KeybindId) == "table" and KeybindId.TOGGLE_CHAT then add(getCore():getKey(KeybindId.TOGGLE_CHAT)) end end)
    pcall(function() add(Keyboard.KEY_T) end)
    return out
end
M.ptDown = M.ptDown or {}
function M.ptKey(Input)
    if Input.box ~= nil and Input.box:isVisible() then return false end
    if type(ISChat) == "table" and ISChat.instance ~= nil then return false end
    if Input.settings and (Input.settings.enabled ~= true or Input.settings.singlePlayerChat ~= true) then return false end
    local opened = false
    for _, k in ipairs(chatKeys()) do
        local down = false
        pcall(function() down = isKeyDown(k) == true end)
        if down and not M.ptDown[k] then
            local isChat = true
            if type(Input.chatKey) == "function" then local ok, yes = pcall(Input.chatKey, k); isChat = ok and yes == true end
            if isChat and not opened then
                local p = ALifeSide.you()
                if p ~= nil and not p:isDead() and pcall(Input.open) then opened = true; M.ptStats.opened = M.ptStats.opened + 1 end
            end
        end
        M.ptDown[k] = down
    end
    return opened
end
function M.ptTick()
    if M.settings and M.settings.talkWhilePaused == false then return end
    if not paused() then M.ptDown = {}; return end
    local Input = PA().TalkInput or PA().Input or (PA().Talk and PA().Talk.Input) or nil
    if type(Input) == "table" then
        pcall(M.ptKey, Input)
        -- A-Life's keys-back-on countdown (its own copy runs on OnTick, which is stopped)
        if (tonumber(Input.keyPressTicks) or 0) > 0 then
            Input.keyPressTicks = Input.keyPressTicks - 1
            if Input.keyPressTicks == 0 and type(doKeyPress) == "function" then pcall(doKeyPress, true); M.ptStats.keysBack = M.ptStats.keysBack + 1 end
        end
    end
    -- the AI helper's answer
    M.ptFrame = (M.ptFrame or 0) + 1
    if M.ptFrame % 2 == 0 and type(M.poll) == "function" and (M.pending ~= nil or M.late ~= nil or #(M.queue or {}) > 0) then
        local ok = pcall(M.poll)
        if ok then M.ptStats.polls = M.ptStats.polls + 1 end
    end
end
if not M._ptHooked and type(Events) == "table" and Events.OnTickEvenPaused then
    M._ptHooked = true
    local broken = false
    local function tick()
        if broken then return end
        local ok, err = pcall(M.ptTick)
        if not ok then broken = true; print("[ALifePausedTalk] failed, talking while paused off for this session: " .. tostring(err)) end
    end
    if type(ALifeHealth) == "table" then ALifeHealth.add(Events.OnTickEvenPaused, "ALifeTalk_PausedTalk", tick) else Events.OnTickEvenPaused.Add(tick) end
end
print("[ALifePausedTalk] loaded v" .. ALifeSide.MOD_VERSION .. " (talk while paused)")
