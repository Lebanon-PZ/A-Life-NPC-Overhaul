-- A-Life NPC Overhaul 0.5.6: MOMENTS.
-- Two kinds of popup:
--   * cards  - something you have to decide (a bite, a horde at the gate). Centred, and by default they pause the
--              game, the way vanilla's Survival Guide does (setGameSpeed(0), PAUSED banner hidden). One at a time,
--              the rest queue. With cards off, the camp's standing choice is applied on its own.
--   * toasts - everything else (dinner's served, gear taken, a patrol call). Stacked at the right edge, never pause,
--              fade after a few seconds. Click one to dismiss it.
-- Callers: M.momCard{ id, title, text, choices = { { label, fn } ... }, default = n }   and   M.momToast(text, r, g, b)
-- The UI lives in M.momUI so the logic runs (and is tested) without the game's UI.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local TAG = "[ALifeMoments]"
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function opt(key, def)
    local sv = type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or nil
    local v = sv and sv[key]
    if v == nil then return def end
    return v
end
local function nowMs() return (type(getTimestampMs) == "function" and getTimestampMs()) or 0 end

M.momQueue, M.momOpen = {}, nil
M.momToasts = {}
M.momStats = { cards = 0, auto = 0, toasts = 0, paused = 0 }
function M.momMode() return tonumber(opt("Moments", 1)) or 1 end -- 1 pause, 2 show without pausing, 3 off
function M.momToastsOn() return opt("Toasts", true) ~= false end
function M.momToastMs() return (tonumber(opt("ToastSec", 7)) or 7) * 1000 end

----------------------------------------------------------------------------------------------------------------
-- pause, exactly like vanilla (MainScreen / SurvivalGuide)
----------------------------------------------------------------------------------------------------------------
M.momPaused = false
function M.momPause()
    if M.momPaused then return end
    local ok = pcall(function() setGameSpeed(0); setShowPausedMessage(false) end)
    if ok then M.momPaused = true; M.momStats.paused = M.momStats.paused + 1 end
end
function M.momResume()
    if not M.momPaused then return end
    M.momPaused = false
    pcall(function() setGameSpeed(1); setShowPausedMessage(true) end)
end

----------------------------------------------------------------------------------------------------------------
-- cards
----------------------------------------------------------------------------------------------------------------
local function run(card, i)
    local c = card.choices[i]
    if c and type(c.fn) == "function" then
        local ok, err = pcall(c.fn)
        if not ok then log("choice error (" .. tostring(card.id) .. "): " .. tostring(err)) end
    end
end
local function showNext()
    if M.momOpen or #M.momQueue == 0 then return end
    local card = table.remove(M.momQueue, 1)
    M.momOpen = card
    -- 0.7.0.2: every popup also leaves a red letter, so it's still there after you've answered it
    if card.title and card.title ~= "" and not card.noLetter then pcall(M.momToast, tostring(card.title), 0.95, 0.42, 0.34) end
    if M.momMode() == 1 then M.momPause() end
    local ok, err = pcall(M.momUI.card, card, M.momPick)
    if not ok then
        log("card UI failed, using the default choice: " .. tostring(err))
        M.momOpen = nil
        M.momResume()
        run(card, card.default or 1)
        M.momStats.auto = M.momStats.auto + 1
        return showNext()
    end
end
-- the player picked choice i on the open card
function M.momPick(i)
    local card = M.momOpen
    if card == nil then return end
    M.momOpen = nil
    pcall(M.momUI.closeCard)
    if #M.momQueue == 0 then M.momResume() end
    run(card, i)
    showNext()
end
-- returns true if a card will be shown, false if the default was applied straight away (cards off)
function M.momCard(card)
    if type(card) ~= "table" or type(card.choices) ~= "table" or #card.choices == 0 then return false end
    card.default = card.default or 1
    if M.momMode() == 3 then
        run(card, card.default)
        M.momStats.auto = M.momStats.auto + 1
        if card.after then M.momToast(card.after(card.default)) end
        return false
    end
    -- the same moment twice (e.g. two scans before you answered): keep the first
    if card.id then
        if M.momOpen and M.momOpen.id == card.id then return true end
        for _, q in ipairs(M.momQueue) do if q.id == card.id then return true end end
    end
    M.momStats.cards = M.momStats.cards + 1
    M.momQueue[#M.momQueue + 1] = card
    showNext()
    return true
end

----------------------------------------------------------------------------------------------------------------
-- toasts
----------------------------------------------------------------------------------------------------------------
-- 0.7.0.2: toasts are LETTERS (RimWorld style): they show in full, shrink to a small tab after ToastSec, and stay
-- until you clear them (right-click one, or "Clear all"). Left-click a tab to read it again; hover to peek.
M.momLetterMax = 30
-- pre-1.0: a letter never gives away the name of someone who has not told you (introduced themselves / been named in
-- a line you heard). Their full name in the text becomes "a stranger"; once they are known it is left alone.
function M.hideStrangers(text)
    if type(text) ~= "string" or M.settings.nameDiscovery == false or M.settings.immersive == false then return text end
    local ok, out = pcall(function()
        if type(M.buildNameIndex) ~= "function" or type(M.knowsName) ~= "function" then return text end
        local me = ALifeSide and ALifeSide.you and ALifeSide.you() or nil
        if me == nil then return text end
        local idx = M.buildNameIndex()
        local res = text
        for uid, p in pairs(idx.parts or {}) do
            local forms = {}
            if p.full and #p.full >= 5 then forms[#forms + 1] = p.full end
            if p.first and p.last then forms[#forms + 1] = p.first .. " " .. p.last end
            for _, f in ipairs(forms) do
                if string.find(res, f, 1, true) and not M.knowsName(uid, me) and not (M.fakeNameOf and M.fakeNameOf(uid)) then
                    local a1, b1 = string.find(res, f, 1, true)
                    while a1 do
                        res = string.sub(res, 1, a1 - 1) .. "a stranger" .. string.sub(res, b1 + 1)
                        a1, b1 = string.find(res, f, a1 + 10, true)
                    end
                end
            end
        end
        return res
    end)
    return ok and out or text
end
function M.momToast(text, r, g, b)
    if text == nil or text == "" then return false end
    if not M.momToastsOn() then return false end
    text = M.hideStrangers(tostring(text))
    local t = { text = tostring(text), r = r or 0.95, g = g or 0.85, b = b or 0.65, at = nowMs(), small = false }
    if (r or 0) > 1 or (g or 0) > 1 or (b or 0) > 1 then t.r, t.g, t.b = (r or 242) / 255, (g or 217) / 255, (b or 166) / 255 end
    t.bad = M.momLetterIsBad(t)
    -- the same letter again while the first is still up: bring it back to the top instead of stacking a copy
    for i, o in ipairs(M.momToasts) do
        if o.text == t.text then table.remove(M.momToasts, i); t.n = (o.n or 1) + 1; break end
    end
    table.insert(M.momToasts, 1, t)
    while #M.momToasts > M.momLetterMax do table.remove(M.momToasts) end
    M.momStats.toasts = M.momStats.toasts + 1
    pcall(M.momUI.toasts)
    return true
end
function M.momToastTick()
    local now, life = nowMs(), M.momToastMs()
    for _, t in ipairs(M.momToasts) do
        if not t.small and now - t.at > life then t.small = true end
    end
end
function M.momLetterOpen(i) local t = M.momToasts[i]; if t then t.small = false; t.at = nowMs() end end
function M.momLetterShrink(i) local t = M.momToasts[i]; if t then t.small = true end end
function M.momLetterClear(i) if M.momToasts[i] then table.remove(M.momToasts, i) end; pcall(M.momUI.toasts) end
function M.momLetterClearAll() M.momToasts = {}; pcall(M.momUI.toasts) end
-- 0.8.12 (Rock List 2): letters filter. Important = the red ones (deaths, someone turning on you, AI broken).
-- Show all / important only / the rest only; clear all but the important ones. The choice is kept (ui prefs).
if M.settings.letterClearAllAt == nil then M.settings.letterClearAllAt = 2 end -- "Clear all" shows from this many letters
do
    M.fileKeys = M.fileKeys or {}
    local have = false
    for _, k in ipairs(M.fileKeys) do if k == "letterClearAllAt" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "letterClearAllAt" end
end
function M.momLetterIsBad(t) return type(t) == "table" and (t.r or 0) >= 0.85 and (t.g or 1) <= 0.55 and (t.b or 1) <= 0.5 end
function M.momLetterFilter()
    local f = M.uiPref and M.uiPref("letters.filter", "all") or "all"
    if f ~= "bad" and f ~= "news" then f = "all" end
    return f
end
function M.momLetterSetFilter(f)
    if M.uiSet then M.uiSet("letters.filter", f) end
    pcall(M.momUI.toasts)
end
function M.momLetterShown(t)
    local f = M.momLetterFilter()
    if f == "bad" then return t.bad == true end
    if f == "news" then return t.bad ~= true end
    return true
end
function M.momLetterClearNews()
    for i = #M.momToasts, 1, -1 do if M.momToasts[i].bad ~= true then table.remove(M.momToasts, i) end end
    pcall(M.momUI.toasts)
end
function M.momLetterMenu(x, y)
    local cm = ISContextMenu.get(0, x, y)
    local f = M.momLetterFilter()
    local function tip(o, text) pcall(function() local t = ISInventoryPaneContextMenu.addToolTip(); t.description = text; o.toolTip = t end) end
    tip(cm:addOption(ALifeTr("IGUI_ALCP_Menu_Clear_all", "Clear all"), nil, function() M.momLetterClearAll() end), "Every letter goes, the red ones too.")
    tip(cm:addOption(ALifeTr("IGUI_ALCP_Menu_Clear_all_but_the_important_ones", "Clear all but the important ones"), nil, function() M.momLetterClearNews() end), "Keeps the red letters: deaths, someone turning on you, the AI broken.")
    tip(cm:addOption((f == "all" and "* " or "") .. "Show: all", nil, function() M.momLetterSetFilter("all") end), "Every letter.")
    tip(cm:addOption((f == "bad" and "* " or "") .. "Show: important only", nil, function() M.momLetterSetFilter("bad") end), "Only the red letters. The others stay, just hidden.")
    tip(cm:addOption((f == "news" and "* " or "") .. "Show: news only", nil, function() M.momLetterSetFilter("news") end), "Everything but the red letters.")
    return cm
end

-- 0.7.0.2: PRIMARY news (one of your people died, the alarm went up without you): a card front and centre that
-- pauses the game, the same as a decision, and a red letter that stays. Settings: "Important news pauses the game".
function M.momAlert(title, text, id)
    title, text = tostring(title or ""), tostring(text or "")
    if M.settings and M.settings.alerts == false then return M.momToast(title ~= "" and (title .. ": " .. text) or text, 0.95, 0.42, 0.34) end
    return M.momCard({ id = id or ("alert:" .. title .. text), title = title, text = text,
        choices = { { label = "OK" }, { label = "Open the A-Life window", fn = function() if type(M.hubOpen) == "function" then M.hubOpen("now") end end } },
        default = 1 })
end
-- for callers that used halo notes: a toast if toasts are on, otherwise the old floating text
function M.momNote(text, r, g, b)
    if M.momToast(text, r, g, b) then return true end
    local p = ALifeSide.you()
    if p then pcall(function() p:setHaloNote(tostring(text), r or 230, g or 200, b or 140, 400) end) end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- the game UI (vanilla ISUI classes; built only when they exist)
----------------------------------------------------------------------------------------------------------------
M.momUI = { card = function() error("no UI") end, closeCard = function() end, toasts = function() end }
if type(ISPanelJoypad) == "table" and type(ISButton) == "table" and type(ISRichTextPanel) == "table" and type(ISPanel) == "table" then
    local FONT_S = getTextManager():getFontHeight(UIFont.Small)
    local FONT_M = getTextManager():getFontHeight(UIFont.Medium)
    ALifeMomentCard = ISPanelJoypad:derive("ALifeMomentCard")
    function ALifeMomentCard:createChildren()
        ISPanelJoypad.createChildren(self)
        local pad, btnH = 16, math.max(28, FONT_S + 10)
        local top = pad + FONT_M + 10
        self.body = ISRichTextPanel:new(pad - 2, top, self.width - pad * 2 + 4, 40)
        self.body:initialise()
        self.body.background = false
        self.body.autosetheight = true
        self.body.clip = true
        self.body.text = self.card.text or ""
        self:addChild(self.body)
        self.body:paginate()
        local y = top + self.body:getHeight() + 12
        self.buttons = {}
        for i, c in ipairs(self.card.choices) do
            local b = ISButton:new(pad, y, self.width - pad * 2, btnH, tostring(c.label), self, ALifeMomentCard.onChoice)
            b.internal = i
            b:initialise(); b:instantiate()
            if i == 1 then b:enableAcceptColor() end
            self:addChild(b)
            self.buttons[i] = b
            y = y + btnH + 6
        end
        self:setHeight(y + pad - 6)
        self:setY((getCore():getScreenHeight() - self.height) / 2)
    end
    function ALifeMomentCard:onChoice(button) M.momPick(button.internal) end
    function ALifeMomentCard:prerender()
        self:drawRect(0, 0, self.width, self.height, 0.94, 0.07, 0.065, 0.06)
        self:drawRectBorder(0, 0, self.width, self.height, 1, 0.88, 0.41, 0.18)
        self:drawRect(0, 0, self.width, 3, 1, 0.88, 0.41, 0.18)
        self:drawText(tostring(self.card.title or ""), 16, 14, 0.95, 0.92, 0.86, 1, UIFont.Medium)
    end
    function ALifeMomentCard:onMouseDown() return true end
    function ALifeMomentCard:onGainJoypadFocus(joypadData)
        ISPanelJoypad.onGainJoypadFocus(self, joypadData)
        if self.buttons[1] then self:setISButtonForA(self.buttons[1]) end
        if self.buttons[2] then self:setISButtonForB(self.buttons[#self.buttons]) end
    end
    function ALifeMomentCard:new(card)
        local w = 460
        local o = ISPanelJoypad:new((getCore():getScreenWidth() - w) / 2, getCore():getScreenHeight() / 3, w, 200)
        setmetatable(o, self)
        self.__index = self
        o.card = card
        o.moveWithMouse = true
        return o
    end

    ALifeToastStack = ISPanel:derive("ALifeToastStack")
    local function scale() return math.max(1, FONT_S / 15) end
    local function wrap(text, width)
        local lines, line = {}, ""
        for word in string.gmatch(text, "%S+") do
            local test = line == "" and word or (line .. " " .. word)
            if getTextManager():MeasureStringX(UIFont.Small, test) > width and line ~= "" then lines[#lines + 1] = line; line = word else line = test end
        end
        if line ~= "" then lines[#lines + 1] = line end
        return lines
    end
    local function short(text, width)
        if getTextManager():MeasureStringX(UIFont.Small, text) <= width then return text end
        local s = text
        while #s > 4 and getTextManager():MeasureStringX(UIFont.Small, s .. "...") > width do s = string.sub(s, 1, #s - 2) end
        return s .. "..."
    end
    function ALifeToastStack:prerender()
        local w, sc = self.width, scale()
        local smallW = math.floor(190 * sc)
        local rowH = FONT_S + 8
        local maxY = getCore():getScreenHeight() - self:getY() - 60
        local y = 0
        self.rows = {}
        local count = #M.momToasts
        local filter = M.momLetterFilter()
        local hidden = 0
        for _, t in ipairs(M.momToasts) do if not M.momLetterShown(t) then hidden = hidden + 1 end end
        if count >= (tonumber(M.settings.letterClearAllAt) or 2) or hidden > 0 then
            local label = "Clear all (" .. count .. ")" .. (filter ~= "all" and ("  " .. (filter == "bad" and "important" or "news") .. " only, " .. hidden .. " hidden") or "")
            local lw = getTextManager():MeasureStringX(UIFont.Small, label) + 16
            self:drawRect(w - lw, y, lw, rowH, 0.7, 0.05, 0.05, 0.05)
            self:drawTextRight(label, w - 8, y + 4, 0.75, 0.75, 0.75, 1, UIFont.Small)
            self.rows[#self.rows + 1] = { y1 = y, y2 = y + rowH, x1 = w - lw, clearAll = true }
            y = y + rowH + 4
        end
        local mx, my = self:getMouseX(), self:getMouseY()
        local over = self:isMouseOver()
        local peek = nil
        for i, t in ipairs(M.momToasts) do
            local text = t.text .. ((t.n or 1) > 1 and ("  (x" .. t.n .. ")") or "")
            if not M.momLetterShown(t) then
                -- filtered out (Clear all row: right-click for the filter)
            elseif t.small then
                if y + rowH > maxY then
                    local more = "+" .. (count - i + 1) .. " more"
                    self:drawRect(w - smallW, y, smallW, rowH, 0.6, 0.05, 0.05, 0.05)
                    self:drawTextRight(more, w - 8, y + 4, 0.7, 0.7, 0.7, 1, UIFont.Small)
                    self.rows[#self.rows + 1] = { y1 = y, y2 = y + rowH, x1 = w - smallW, more = true }
                    y = y + rowH + 4
                    break
                end
                self:drawRect(w - smallW, y, smallW, rowH, 0.82, 0.07, 0.065, 0.06)
                self:drawRect(w - smallW, y, 4, rowH, 1, t.r, t.g, t.b)
                self:drawText(short(text, smallW - 16), w - smallW + 10, y + 4, t.r, t.g, t.b, 1, UIFont.Small)
                self.rows[#self.rows + 1] = { y1 = y, y2 = y + rowH, x1 = w - smallW, i = i }
                if over and my >= y and my <= y + rowH and mx >= w - smallW then peek = { t = t, text = text, y = y } end
                y = y + rowH + 4
            else
                local lines = wrap(text, w - 24)
                local h = #lines * (FONT_S + 2) + 12
                if y + h > maxY and i > 1 then t.small = true; y = y else
                    self:drawRect(0, y, w, h, 0.86, 0.07, 0.065, 0.06)
                    self:drawRect(0, y, 4, h, 1, t.r, t.g, t.b)
                    for k, l in ipairs(lines) do self:drawText(l, 12, y + 6 + (k - 1) * (FONT_S + 2), t.r, t.g, t.b, 1, UIFont.Small) end
                    self.rows[#self.rows + 1] = { y1 = y, y2 = y + h, x1 = 0, i = i }
                    y = y + h + 6
                end
            end
        end
        -- hover a tab: the whole letter, to the left of the stack
        if peek then
            local pw = math.floor(300 * sc)
            local lines = wrap(peek.text, pw - 24)
            local h = #lines * (FONT_S + 2) + 12
            local px = w - smallW - pw - 8
            self:drawRect(px, peek.y, pw, h, 0.94, 0.07, 0.065, 0.06)
            self:drawRectBorder(px, peek.y, pw, h, 0.8, peek.t.r, peek.t.g, peek.t.b)
            for k, l in ipairs(lines) do self:drawText(l, px + 12, peek.y + 6 + (k - 1) * (FONT_S + 2), peek.t.r, peek.t.g, peek.t.b, 1, UIFont.Small) end
        end
        -- only as tall as the letters, so it never swallows clicks meant for the world
        if math.abs(self.height - math.max(1, y)) > 0.5 then self:setHeight(math.max(1, y)) end
    end
    function ALifeToastStack:rowAt(x, y)
        for _, r in ipairs(self.rows or {}) do if y >= r.y1 and y <= r.y2 and x >= (r.x1 or 0) then return r end end
        return nil
    end
    -- left-click: a tab opens (shows in full again), a full letter shrinks; "+N more" opens the list
    function ALifeToastStack:onMouseDown(x, y)
        local r = self:rowAt(x, y)
        if r == nil then return false end
        if r.clearAll then M.momLetterClearAll()
        elseif r.more then if type(M.winNotices) == "function" then pcall(M.winNotices) end
        elseif r.i then local t = M.momToasts[r.i]; if t and t.small then M.momLetterOpen(r.i) else M.momLetterShrink(r.i) end end
        return true
    end
    -- right-click: clear it
    function ALifeToastStack:onRightMouseDown(x, y)
        local r = self:rowAt(x, y)
        if r == nil then return false end
        if r.i then M.momLetterClear(r.i)
        elseif r.clearAll then pcall(M.momLetterMenu, getMouseX(), getMouseY()) end -- 0.8.12: clear / filter menu
        return true
    end
    function ALifeToastStack:update()
        ISPanel.update(self)
        M.momToastTick()
        if #M.momToasts == 0 then self:setVisible(false) end
    end

    M.momUI.card = function(card, onPick)
        local ui = ALifeMomentCard:new(card)
        ui:initialise()
        ui:addToUIManager()
        ui:setAlwaysOnTop(true)
        M.momUI.open = ui
        local jp = JoypadState and JoypadState.players and JoypadState.players[1]
        if jp then ui.prevFocus = jp.focus; jp.activeWhilePaused = true; setJoypadFocus(0, ui) end
        pcall(function() getSoundManager():playUISound("UIPauseMenuEnter") end)
    end
    M.momUI.closeCard = function()
        local ui = M.momUI.open
        M.momUI.open = nil
        if ui then
            ui:setVisible(false)
            ui:removeFromUIManager()
            local jp = JoypadState and JoypadState.players and JoypadState.players[1]
            if jp and jp.focus == ui then setJoypadFocus(0, ui.prevFocus) end
        end
    end
    M.momUI.toasts = function()
        local w = math.floor(300 * math.max(1, FONT_S / 15))
        if M.momUI.stack == nil then
            local s = ALifeToastStack:new(getCore():getScreenWidth() - w - 20, getCore():getScreenHeight() * 0.28, w, 1)
            s:initialise()
            s.background = false
            s:addToUIManager()
            M.momUI.stack = s
        end
        M.momUI.stack:setVisible(#M.momToasts > 0)
    end
end

-- never leave the game paused behind a card that's gone (load, main menu)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        M.momQueue, M.momOpen = {}, nil
        if M.momPaused then M.momResume() end
        log("loaded (cards: " .. ({ "pause", "no pause", "off" })[M.momMode()] .. ", letters " .. (M.momToastsOn() and "on" or "off") .. ")")
    end)
end
