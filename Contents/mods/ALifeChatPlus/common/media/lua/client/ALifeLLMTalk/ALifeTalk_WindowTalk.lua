-- A-Life NPC Overhaul 0.8.1 (0.8.2: says it through the ALifeCmd channel, aimed by uid; "What can I tell them?"):
-- THE RPG TALK WINDOW (A-Life 1.5's own talk panel, plus your own words).
--   * A-Life's talk window opens exactly as before, on A-Life's own tabs and rows.
--   * A "Say" tab sits next to A-Life's tabs: "Say something..." opens a typing box under the window, and a few
--     lines you can just pick (Knox, what they think of you, their people, how they're holding up; Confess for
--     Father Gabe only; the Oath for someone sworn to you).
--   * Your chat key while the window is open opens the same box, from any tab.
--   * What you say goes through A-Life's own typed-talk path (TalkInput.say -> Talk.onPlayerText -> Talk.respond),
--     aimed at the person in the window, so the AI answers in their own words and the answer shows in the window's
--     caption (A-Life mirrors every NPC line into the open panel). AI helper off: A-Life answers as it always did.
--   * Works while paused (the box is UI; replies are picked up by ALifeTalk_PausedTalk).
-- How: wraps on ProjectALife.UI2Talk.Window (available / choose / close / key handlers), UI2Talk.groupsFor and
-- ProjectALife.TalkInput.open. Each wrap calls the original whenever it isn't one of ours.
-- If anything here throws, that hook switches itself off and A-Life's window carries on untouched.
-- Setting: "windowTalk" (AI and talking, on by default).
require "ALifeNPCOverhaul/AA_Side"
require "ProjectALife/Talk/ALifeTalkInput"
require "ProjectALife/Talk/ALifeTalkMenu"
require "ProjectALife/UI2/ALifeUI2Talk"
require "ProjectALife/UI2/ALifeUI2TalkAsk"
require "ProjectALife/UI2/ALifeUI2TalkPool"
require "ProjectALife/UI2/ALifeUI2TalkTrees"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCmd"
require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

ALifeWindowTalk = ALifeWindowTalk or {}
local L = ALifeWindowTalk
local TAG = "[ALifeWindowTalk]"
L.VERSION = ALifeSide.MOD_VERSION
L.TAB = "ACP_SAY"
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { opened = 0, typed = 0, picked = 0, keyOpened = 0, aiOff = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function M() return ALifeLLMTalk end

function L.on()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.windowTalk == false)
end

function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end

----------------------------------------------------------------------------------------------------------------
-- who the window is talking to
----------------------------------------------------------------------------------------------------------------
function L.window()
    local pa = PA()
    if pa == nil then return nil end
    local surface = pa.TalkSurface
    if fn(surface, "windowOf") then
        local ok, win = pcall(surface.windowOf, nil)
        if ok and win ~= nil then return win end
        return nil
    end
    local menu = pa.TalkMenu
    local win = menu ~= nil and menu.instance or nil
    if win ~= nil and fn(win, "isVisible") and win:isVisible() then return win end
    return nil
end

local function strangerKey(uid)
    local S = ALifeStrangers
    if not fn(S, "of") then return nil end
    local ok, row = pcall(S.of, tostring(uid))
    if ok and type(row) == "table" then return row.cameo end
    return nil
end
local function sworn(uid)
    local O = ALifeOathWatch
    if not fn(O, "isSworn") then return false end
    local ok, yes = pcall(O.isSworn, tostring(uid))
    return ok and yes == true
end

----------------------------------------------------------------------------------------------------------------
-- the rows of the Say tab (shaped like A-Life's own "they asked you" rows, ALifeUI2TalkAsk)
----------------------------------------------------------------------------------------------------------------
L.LINES = {
    { id = "ACP_KNOX", label = "What do you think happened here? In Knox, I mean." },
    { id = "ACP_ME", label = "Be honest with me. What do you think of me?" },
    { id = "ACP_GROUP", label = "Tell me about your people." },
    { id = "ACP_HOLDING", label = "How are you holding up?" },
    { id = "ACP_CONFESS", label = "Father, I need to confess something.", only = "gabe" },
    { id = "ACP_OATH", label = "That oath you swore me. Did you mean it?", only = "sworn" },
    -- 0.8.8 UI: only when someone you know of really wants them dead (ALifeGoals.wantsDead); runs ALifeGoals.warn
    { id = "ACP_WARN", label = "Watch your back. Someone wants you dead.", only = "warn" },
}
L.SAY_ROW = { id = "ACP_SAY_TYPE", label = "Say something..." }
L.HELP_ROW = { id = "ACP_SAY_HELP", label = "(What can I tell them?)" }

local function row(def, typed, help)
    local warn = def.only == "warn"
    return { id = def.id, text = def.label, visitor = true, ui2 = {}, acpLine = (typed ~= true and help ~= true and not warn) and def.label or nil,
        acpType = typed == true, acpHelp = help == true, acpWarn = warn or nil, tone = "normal" }
end
-- someone you know of wants this person dead (0.8.8 stand in the way)
function L.warnable(uid)
    if uid == nil or type(ALifeGoals) ~= "table" or not fn(ALifeGoals, "wantsDead") or not fn(ALifeGoals, "warn") then return false end
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    local ok, giver = pcall(ALifeGoals.wantsDead, tostring(uid), player)
    return ok and giver ~= nil
end

-- 0.8.3 step 3: REPLY SUGGESTIONS. With this window open, AI requests ask the bridge for talkSuggestCount short
-- things you could say next; they show first on the Say tab (pick one = say it). Gone once you say something, after
-- talkSuggestMs, or with the AI off (then only the fixed lines below show). Off: talkSuggest.
L.SUGGEST_DEFAULTS = { talkSuggest = true, talkSuggestCount = 3, talkSuggestMs = 120000 }
L.suggestions = L.suggestions or {} -- [uid] = { lines, at }
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` would turn a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = L.SUGGEST_DEFAULTS[key] end
    return v
end
function L.suggestFor(uid, now)
    if uid == nil or setting("talkSuggest") == false then return nil end
    local s = L.suggestions[tostring(uid)]
    if type(s) ~= "table" then return nil end
    if now < s.at or now - s.at > (tonumber(setting("talkSuggestMs")) or 120000) then
        L.suggestions[tostring(uid)] = nil
        return nil
    end
    return s.lines
end
function L.noteSuggest(uid, lines, now)
    if uid == nil or type(lines) ~= "table" or setting("talkSuggest") == false then return end
    local n = tonumber(setting("talkSuggestCount")) or 3
    local keep = {}
    for _, t in ipairs(lines) do if type(t) == "string" and t ~= "" and #keep < n then keep[#keep + 1] = t end end
    if #keep == 0 then return end
    L.suggestions[tostring(uid)] = { lines = keep, at = now or nowMs() }
    local win = L.window()
    if win ~= nil and tostring(win.uid) == tostring(uid) and win.topic == L.TAB and fn(win, "refreshChoices") then
        pcall(win.refreshChoices, win)
    end
end

function L.rows(win)
    local out = { row(L.SAY_ROW, true) }
    local uid = win ~= nil and win.uid or nil
    local sug = L.suggestFor(uid, nowMs())
    if sug ~= nil then
        for i, t in ipairs(sug) do out[#out + 1] = row({ id = "ACP_SUG_" .. i, label = t }) end
    end
    local cameo = uid ~= nil and strangerKey(uid) or nil
    local isSworn = uid ~= nil and sworn(uid) or false
    for _, def in ipairs(L.LINES) do
        if def.only == nil or (def.only == "gabe" and cameo == "gabe") or (def.only == "sworn" and isSworn) or (def.only == "warn" and L.warnable(uid)) then
            out[#out + 1] = row(def)
        end
    end
    if type(ALifeLLMTalk) == "table" and type(ALifeLLMTalk.hubOpen) == "function" and type(ALifeCommands) == "table" then
        out[#out + 1] = row(L.HELP_ROW, false, true)
    end
    return out
end

-- our tab only shows when the window is in a normal state (no question waiting, no dialogue tree running, no
-- "they asked you" rows, not a door or a visitor)
function L.tabAllowed(win)
    if win == nil or not L.on() then return false end
    if win.pending ~= nil or win.askEmbed ~= nil or type(win.treeRun) == "table" then return false end
    if win.visitor ~= nil or win.doorPeer == true or type(win.giftPicker) == "table" then return false end
    if win.interrupted then return false end
    local state = win.ftState
    if type(state) == "table" and type(state.captive) == "table" then return false end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- saying it: aimed at the window's person, through A-Life's own typed path
----------------------------------------------------------------------------------------------------------------
function L.say(win, text)
    local pa = PA()
    local input = pa ~= nil and pa.TalkInput or nil
    if not fn(input, "say") then return false end
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then return false end
    if win ~= nil and win.uid ~= nil then L.suggestions[tostring(win.uid)] = nil end -- 0.8.3: old suggestions go
    if win ~= nil and fn(win, "append") then pcall(win.append, win, text, "You") end
    local m = M()
    local now = nowMs()
    if type(m) == "table" and fn(m, "bridgeAlive") then
        local ok, alive = pcall(m.bridgeAlive, now)
        if ok and alive ~= true and win ~= nil and not win.acpAiNoted and fn(win, "append") then
            win.acpAiNoted = true
            L.metrics.aiOff = L.metrics.aiOff + 1
            pcall(win.append, win, "The AI helper is off, so A-Life answers in its own words.", "A-LIFE")
        end
    end
    -- 0.8.2: through the command channel, with the person in the window named (a name in the line still wins)
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    if player == nil or not fn(ALifeCmd, "send") then return false end
    return ALifeCmd.send(player, "windowSay", { uid = win ~= nil and win.uid ~= nil and tostring(win.uid) or "", text = text }) == true
end

-- the server side of it: for this one line, the person named is who you're talking to
L.targetFor = L.targetFor or {}
local function keyOf(player)
    local pa = PA()
    if pa ~= nil and pa.Speech ~= nil and type(pa.Speech.playerKey) == "function" then
        local ok, k = pcall(pa.Speech.playerKey, player)
        if ok and k ~= nil then return tostring(k) end
    end
    return "local"
end
function L.serverSay(player, args)
    local text = type(args) == "table" and tostring(args.text or "") or ""
    if text == "" or player == nil then return false end
    local key = keyOf(player)
    local uid = type(args.uid) == "string" and args.uid ~= "" and args.uid or nil
    L.targetFor[key] = uid ~= nil and { uid = uid, untilMs = nowMs() + 3000 } or nil
    local ok, sent = false, false
    if ALifeSide.server() then
        -- multiplayer: A-Life's own server-side typed talk
        local talk = PA() ~= nil and PA().Talk or nil
        if type(talk) == "table" and type(talk.onPlayerText) == "function" then ok, sent = pcall(talk.onPlayerText, player, text, false) end
    else
        local input = PA() ~= nil and PA().TalkInput or nil
        if fn(input, "say") then ok, sent = pcall(input.say, text, false) end
    end
    L.targetFor[key] = nil
    if not ok then log("say failed: " .. tostring(sent)); return false end
    return sent == true
end
if fn(ALifeCmd, "onServer") then ALifeCmd.onServer("windowSay", function(player, args) return L.serverSay(player, args) end) end

-- who hears it: the person named for this line, unless the line names someone else nearby
function L.hookReaddress(m)
    if L.hooked.readdress then return end
    if type(m) ~= "table" or type(m.readdress) ~= "function" then return end
    if m.readdress__WindowTalk ~= nil then L.hooked.readdress = true; return end
    local orig = m.readdress
    m.readdress__WindowTalk = orig
    m.readdress = function(player, listener, text, now, ...)
        local picked = orig(player, listener, text, now, ...)
        if L.off.readdress then return picked end
        local ok, out = L.guard("readdress", function()
            local t = L.targetFor[keyOf(player)]
            if t == nil or nowMs() > t.untilMs then return picked end
            -- a name in the line picked someone else: they win
            if picked ~= nil and picked ~= listener and type(picked.record) == "table" and tostring(picked.record.uid) ~= t.uid then return picked end
            local talk = PA() ~= nil and PA().Talk or nil
            if type(talk) ~= "table" or type(talk.listeners) ~= "function" then return picked end
            local radius = type(talk.settings) == "table" and talk.settings.listenRadius or 12
            for _, l in ipairs(talk.listeners(player, radius) or {}) do
                if type(l.record) == "table" and tostring(l.record.uid) == t.uid then return l end
            end
            return picked
        end)
        if ok and out ~= nil then return out end
        return picked
    end
    L.hooked.readdress = true
end

----------------------------------------------------------------------------------------------------------------
-- the typing box (under the talk window)
----------------------------------------------------------------------------------------------------------------
local Box = ISPanel:derive("ALifeWindowTalkBox")
L.Box = Box

function Box:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.78 }
    o.borderColor = { r = 0.75, g = 0.65, b = 0.4, a = 0.9 }
    o.moveWithMouse = false
    return o
end

function Box:createChildren()
    ISPanel.createChildren(self)
    self.entry = ISTextEntryBox:new("", 6, 4, self.width - 12, self.height - 8)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry.onCommandEntered = function(entry)
        local text = entry:getText()
        local win = L.target
        L.close()
        if text ~= nil and text ~= "" then
            L.metrics.typed = L.metrics.typed + 1
            L.say(win, text)
        end
    end
    self.entry.onOtherKey = function(entry, key)
        if Keyboard ~= nil and key == Keyboard.KEY_ESCAPE then L.close() end
    end
    self.entry:setMaxTextLength(200)
    if fn(self.entry, "setPlaceholderText") then
        self.entry:setPlaceholderText("Say it in your own words. Enter to say it, Esc to cancel.")
    end
    self:addChild(self.entry)
end

function L.typing()
    return L.box ~= nil and L.box:isVisible() == true
end
-- keys stay ours a moment after the box closes, so the Enter/Esc that closed it doesn't also press a row or close
-- the talk window
function L.holdingKeys()
    return L.typing() or nowMs() < (L.keysBackAt or 0)
end

function L.place(win)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local width, height = 460, 30
    local x, y = math.floor((sw - width) / 2), sh - 260
    if win ~= nil then
        local okW, ww = pcall(function() return win:getWidth() end)
        local okX, wx = pcall(function() return win:getX() end)
        local okY, wy = pcall(function() return win:getY() end)
        local okH, wh = pcall(function() return win:getHeight() end)
        if okW and okX and okY and okH then
            width = math.max(300, math.min(560, ww))
            x = wx + math.floor((ww - width) / 2)
            y = wy + wh + 6
        end
    end
    x = math.max(0, math.min(sw - width, x))
    y = math.max(0, math.min(sh - height - 4, y))
    return x, y, width, height
end

function L.open(win)
    if L.typing() then return true end
    local x, y, width, height = L.place(win)
    if L.box == nil then
        L.box = Box:new(x, y, width, height)
        L.box:initialise()
        L.box:addToUIManager()
    else
        L.box:setX(x); L.box:setY(y); L.box:setWidth(width)
        if L.box.entry ~= nil then L.box.entry:setWidth(width - 12) end
    end
    L.target = win
    L.box:setVisible(true)
    L.box:bringToTop()
    L.box.entry:setText("")
    L.box.entry:setEditable(true)
    L.box.entry:focus()
    L.box.entry:ignoreFirstInput()
    L.metrics.opened = L.metrics.opened + 1
    return true
end

function L.close()
    L.keysBackAt = nowMs() + 400
    if L.box == nil then return end
    pcall(function()
        L.box.entry:unfocus()
        L.box.entry:setText("")
        L.box:setVisible(false)
    end)
    L.target = nil
    -- A-Life's own trick after its chat box: game keys off for a moment so Enter doesn't leak into the game.
    -- Its countdown (OnTick, or ALifeTalk_PausedTalk while paused) switches them back on.
    local input = PA() ~= nil and PA().TalkInput or nil
    if type(doKeyPress) == "function" and type(input) == "table" then
        pcall(doKeyPress, false)
        input.keyPressTicks = 20
    end
end

----------------------------------------------------------------------------------------------------------------
-- pausing (0.8.2): Space pauses even with the talk window open; optional "pause while talking"
----------------------------------------------------------------------------------------------------------------
local function setting(key, default)
    local m = M()
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then return default end
    return v
end
-- the game's pause key (your keybinding; Space if it can't be read). Setting "talkPauseKey" (on): off = A-Life's old
-- way (Space advances the text / picks the row).
function L.pauseKeyCode()
    local k = nil
    pcall(function() k = getCore():getKey("Pause") end)
    k = tonumber(k)
    if k == nil or k <= 0 then k = Keyboard ~= nil and Keyboard.KEY_SPACE or nil end
    return k
end
function L.isPauseKey(key)
    if key == nil or setting("talkPauseKey", true) == false then return false end
    return key == L.pauseKeyCode()
end
function L.speedControls()
    local c = nil
    pcall(function() c = UIManager.getSpeedControls() end)
    return c
end
function L.isPaused()
    local p = false
    pcall(function() p = isGamePaused() == true end)
    if p then return true end
    local c = L.speedControls()
    if c ~= nil then pcall(function() p = c:getCurrentGameSpeed() <= 0 end) end
    return p
end
-- "Pause while talking" (talkAutoPause, off by default): the window pauses the game when it opens and unpauses when
-- it closes, only if it was the one that paused it and the game is still paused. Not checked on 42.21 yet:
-- SpeedControls:SetCurrentGameSpeed (guarded: one log line if missing, then the setting does nothing this session).
function L.autoPause(win)
    if setting("talkAutoPause", false) ~= true or L.isPaused() then return false end
    local c = L.speedControls()
    if c == nil then return false end
    local ok = L.guard("autoPause", function() c:SetCurrentGameSpeed(0) end)
    if ok then L.pausedBy = win; L.metrics.autoPaused = (L.metrics.autoPaused or 0) + 1 end
    return ok
end
function L.unpause()
    local win = L.pausedBy
    L.pausedBy = nil
    if win == nil or not L.isPaused() then return end
    local c = L.speedControls()
    if c ~= nil then L.guard("autoPause", function() c:SetCurrentGameSpeed(1) end) end
end

----------------------------------------------------------------------------------------------------------------
-- hooks
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "available", "choose", "groupsFor", "keys", "close", "chatKey", "readdress", "open" }

-- the talk window opening (A-Life's TalkMenu.open, whichever window it picks): "pause while talking"
function L.hookOpen(menu)
    if L.hooked.open then return end
    if type(menu) ~= "table" or type(menu.open) ~= "function" then return end
    if menu.open__WindowTalk ~= nil then L.hooked.open = true; return end
    local orig = menu.open
    menu.open__WindowTalk = orig
    menu.open = function(...)
        local r = orig(...)
        if not L.off.open then
            L.guard("open", function()
                local win = menu.instance
                if win ~= nil and L.pausedBy == nil then L.autoPause(win) end
            end)
        end
        return r
    end
    -- A-Life's older window too: unpause when it closes
    local Base = menu.Window
    if type(Base) == "table" and type(Base.close) == "function" and Base.close__WindowTalk == nil then
        local baseClose = Base.close
        Base.close__WindowTalk = baseClose
        Base.close = function(self, ...)
            if L.pausedBy == self then L.guard("unpause", L.unpause) end
            return baseClose(self, ...)
        end
    end
    L.hooked.open = true
end

function L.hookWindow(Talk2)
    local W = Talk2.Window
    if W == nil then return end
    if not L.hooked.available and type(W.available) == "function" and W.available__WindowTalk == nil then
        local orig = W.available
        W.available__WindowTalk = orig
        function W:available(topic)
            if topic == L.TAB and not L.off.available then
                local ok, rows = L.guard("available", function()
                    if not L.tabAllowed(self) then return {} end
                    if topic == self.topic then self.marks = {} end
                    return L.rows(self)
                end)
                if ok and type(rows) == "table" then return rows end
                return {}
            end
            return orig(self, topic)
        end
        L.hooked.available = true
    elseif W.available__WindowTalk ~= nil then L.hooked.available = true end

    if not L.hooked.choose and type(W.choose) == "function" and W.choose__WindowTalk == nil then
        local orig = W.choose
        W.choose__WindowTalk = orig
        function W:choose(button)
            local choice = button ~= nil and button.choice or nil
            if choice ~= nil and (choice.acpType == true or choice.acpLine ~= nil or choice.acpHelp == true or choice.acpWarn == true) and not L.off.choose then
                local ok = L.guard("choose", function()
                    if choice.acpWarn == true then
                        -- said in the window, then the real thing: ALifeGoals.warn (their answer comes back as a line)
                        if fn(self, "append") then pcall(self.append, self, choice.text, "You") end
                        local player = nil
                        pcall(function() player = ALifeSide.you() end)
                        L.metrics.picked = L.metrics.picked + 1
                        if player ~= nil and self.uid ~= nil then ALifeGoals.warn(player, tostring(self.uid)) end
                        if fn(self, "refreshChoices") then pcall(self.refreshChoices, self) end
                    elseif choice.acpHelp == true then
                        if type(ALifeLLMTalk.helpOpen) == "function" then pcall(ALifeLLMTalk.helpOpen, "commands") else pcall(ALifeLLMTalk.hubOpen, "help") end
                    elseif choice.acpType == true then
                        L.open(self)
                    else
                        L.metrics.picked = L.metrics.picked + 1
                        L.say(self, choice.acpLine)
                    end
                end)
                if ok then return end
            end
            return orig(self, button)
        end
        L.hooked.choose = true
    elseif W.choose__WindowTalk ~= nil then L.hooked.choose = true end

    -- while you type, the talk window leaves the keyboard alone (no number keys picking rows, Esc only closes the box)
    -- 0.8.2: the pause key (Space by default) always goes to the game, so pausing never presses a row (like Leave)
    if not L.hooked.keys and type(W.onKeyPress) == "function" and W.onKeyPress__WindowTalk == nil then
        local press, release, consumed = W.onKeyPress, W.onKeyRelease, W.isKeyConsumed
        W.onKeyPress__WindowTalk = press
        function W:onKeyPress(key)
            if not L.off.keys and (L.holdingKeys() or L.isPauseKey(key)) then return end
            return press(self, key)
        end
        if type(release) == "function" then
            function W:onKeyRelease(key)
                if not L.off.keys and (L.holdingKeys() or L.isPauseKey(key)) then return end
                return release(self, key)
            end
        end
        if type(consumed) == "function" then
            function W:isKeyConsumed(key)
                if not L.off.keys and (L.holdingKeys() or L.isPauseKey(key)) then return false end
                return consumed(self, key)
            end
        end
        L.hooked.keys = true
    elseif W.onKeyPress__WindowTalk ~= nil then L.hooked.keys = true end

    if not L.hooked.close and type(W.close) == "function" and W.close__WindowTalk == nil then
        local orig = W.close
        W.close__WindowTalk = orig
        function W:close()
            if L.target == self then L.guard("close", L.close) end
            if L.pausedBy == self then L.guard("unpause", L.unpause) end
            return orig(self)
        end
        L.hooked.close = true
    elseif W.close__WindowTalk ~= nil then L.hooked.close = true end

    if not L.hooked.groupsFor and type(Talk2.groupsFor) == "function" and Talk2.groupsFor__WindowTalk == nil then
        local orig = Talk2.groupsFor
        Talk2.groupsFor__WindowTalk = orig
        Talk2.groupsFor = function(win)
            local shown = orig(win)
            if L.off.groupsFor or L.off.available or L.off.choose then return shown end
            L.guard("groupsFor", function()
                if not L.tabAllowed(win) or type(shown) ~= "table" or #shown == 0 then return end
                local tab = { topic = L.TAB, label = "Say", count = win.topic == L.TAB and -1 or #L.rows(win) }
                -- right after A-Life's first tab: A-Life's own chat stays what you see first
                table.insert(shown, math.min(2, #shown + 1), tab)
            end)
            return shown
        end
        L.hooked.groupsFor = true
    elseif Talk2.groupsFor__WindowTalk ~= nil then L.hooked.groupsFor = true end
end

-- the chat key opens A-Life's own box (TalkInput.open); with a talk window open, ours opens instead, aimed at
-- the person in the window. Works for A-Life's older window too.
function L.hookChatKey(input)
    if L.hooked.chatKey then return end
    if input.open__WindowTalk ~= nil then L.hooked.chatKey = true; return end
    if not fn(input, "open") then return end
    local orig = input.open
    input.open__WindowTalk = orig
    input.open = function(...)
        if L.on() and not L.off.chatKey then
            local ok, done = L.guard("chatKey", function()
                if L.typing() then return true end
                local win = L.window()
                if win == nil or not L.tabAllowed(win) then return false end
                L.metrics.keyOpened = L.metrics.keyOpened + 1
                return L.open(win)
            end)
            if ok and done == true then return end
        end
        return orig(...)
    end
    L.hooked.chatKey = true
end

function L.install()
    local pa = PA()
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        if m.settings.windowTalk == nil then m.settings.windowTalk = true end
        if m.settings.talkPauseKey == nil then m.settings.talkPauseKey = true end
        if m.settings.talkAutoPause == nil then m.settings.talkAutoPause = false end
    end
    if pa == nil then return 0, L.HOOKS end
    if type(pa.UI2Talk) == "table" then L.hookWindow(pa.UI2Talk) end
    if type(pa.TalkInput) == "table" then L.hookChatKey(pa.TalkInput) end
    L.hookReaddress(m)
    if type(pa.TalkMenu) == "table" then L.hookOpen(pa.TalkMenu) end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end

L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or "")
            .. " (Say tab and typing in the talk window: " .. (L.on() and "on" or "off") .. ")")
        return true
    end
    return false
end

function L.report()
    local t = L.metrics
    return "talk window: box opened " .. t.opened .. " (chat key " .. t.keyOpened .. "), typed " .. t.typed
        .. ", picked " .. t.picked .. ", AI off notes " .. t.aiOff
end

-- 0.8.3 step 3: suggestions - defaults and save keys at load, the request asks for them only when this window is
-- open with that person on a normal state, and the reply hands them back (Main.lua calls M.noteSuggest)
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(L.SUGGEST_DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "talkSuggest", "talkSuggestCount", "talkSuggestMs" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
        m.noteSuggest = function(uid, lines, now) return L.noteSuggest(uid, lines, now) end
        if type(m.requestExtras) == "table" then
            table.insert(m.requestExtras, function(req, player, listener, now)
                if setting("talkSuggest") == false or listener == nil or type(listener.record) ~= "table" then return end
                local win = L.window()
                if win == nil or tostring(win.uid) ~= tostring(listener.record.uid) or not L.tabAllowed(win) then return end
                local n = tonumber(setting("talkSuggestCount")) or 3
                if n > 0 then req.suggest = math.min(3, n) end
            end)
        end
    end
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = nowMs()
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryDays ~= nil then
        Events.EveryDays.Add(function() log(L.report()) end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
