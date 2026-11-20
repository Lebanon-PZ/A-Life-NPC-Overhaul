-- A-Life Talk 0.4.0: shared dark "GECK-like" theme for every window we add (vanilla ISUI only, pcall-safe).
-- ALifeLLMTalkWindow = draggable ISPanel with a rounded-ish translucent body, thin accent border, header bar with title and
-- close button, fade-in, plus helpers for buttons, lists, tabs, badges and the gradient relationship bar.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Theme"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Theme") end end -- 0.5.1.6 perf label
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

M.UIStyle = M.UIStyle or {}
local S = M.UIStyle
local function put(k, v) if S[k] == nil then S[k] = v end end
put("font", UIFont and UIFont.Small)
put("fontTitle", UIFont and UIFont.Medium)
put("fontBig", UIFont and UIFont.Large)
S.bg = { a = 0.88, r = 0.055, g = 0.06, b = 0.065 }
S.panel = { a = 0.80, r = 0.10, g = 0.105, b = 0.115 }
S.header = { a = 0.95, r = 0.13, g = 0.12, b = 0.10 }
S.border = { a = 0.85, r = 0.62, g = 0.50, b = 0.26 }
S.borderDim = { a = 0.55, r = 0.36, g = 0.33, b = 0.27 }
S.text = { a = 1, r = 0.92, g = 0.90, b = 0.84 }
S.dim = { a = 1, r = 0.62, g = 0.60, b = 0.56 }
S.accent = { a = 1, r = 0.92, g = 0.72, b = 0.34 }
S.green = { a = 1, r = 0.42, g = 0.85, b = 0.45 }
S.red = { a = 1, r = 0.90, g = 0.32, b = 0.27 }
S.amber = { a = 1, r = 0.95, g = 0.70, b = 0.25 }
S.blue = { a = 1, r = 0.45, g = 0.70, b = 0.95 }
S.hover = { a = 0.18, r = 0.92, g = 0.72, b = 0.34 }
S.select = { a = 0.30, r = 0.92, g = 0.72, b = 0.34 }
S.rowAlt = { a = 0.22, r = 0.20, g = 0.20, b = 0.22 }
S.barBack = { a = 1, r = 0.16, g = 0.16, b = 0.17 }
S.pad = 10
S.headerH = 26
S.fadeMs = 180
S.icons = { talk = "media/ui/ALifeTalk/talk.png", heart = "media/ui/ALifeTalk/heart.png", gift = "media/ui/ALifeTalk/gift.png",
    radio = "media/ui/ALifeTalk/radio.png", follow = "media/ui/ALifeTalk/follow.png", gear = "media/ui/ALifeTalk/gear.png" }

local Theme = {}
M.Theme = Theme

function Theme.now()
    local ok, t = pcall(getTimestampMs)
    return ok and t or 0
end

function Theme.icon(name)
    local path = S.icons[name]
    if path == nil or type(getTexture) ~= "function" then return nil end
    local ok, tex = pcall(getTexture, path)
    return ok and tex or nil
end

-- context-menu option with our icon (vanilla ISContextMenu draws option.iconTexture)
function Theme.menuOption(context, label, target, fn_, icon, ...)
    local opt = context:addOption(label, target, fn_, ...)
    if opt ~= nil and icon then pcall(function() opt.iconTexture = Theme.icon(icon) end) end
    return opt
end

function Theme.textW(text, font)
    local ok, w = pcall(function() return getTextManager():MeasureStringX(font or S.font, tostring(text)) end)
    return ok and w or (#tostring(text) * 7)
end
-- 0.5.2.5 [pt252u]: cut a string to a pixel width (font aware) - nothing drawn past a window edge
function Theme.fit(text, maxW, font)
    local s = tostring(text or "")
    if maxW == nil or maxW <= 0 then return "" end
    if Theme.textW(s, font) <= maxW then return s end
    local n = #s
    while n > 1 and Theme.textW(string.sub(s, 1, n) .. "...", font) > maxW do n = n - math.max(1, math.floor(n / 12)) end
    if n <= 1 then return "" end
    return string.sub(s, 1, n) .. "..."
end
function Theme.fontH(font)
    local ok, h = pcall(function() return getTextManager():getFontHeight(font or S.font) end)
    return ok and h or 14
end

-- 0..1 gradient red -> amber -> green
function Theme.gradient(t)
    t = math.max(0, math.min(1, t))
    if t < 0.5 then
        local k = t / 0.5
        return S.red.r + (S.amber.r - S.red.r) * k, S.red.g + (S.amber.g - S.red.g) * k, S.red.b + (S.amber.b - S.red.b) * k
    end
    local k = (t - 0.5) / 0.5
    return S.amber.r + (S.green.r - S.amber.r) * k, S.amber.g + (S.green.g - S.amber.g) * k, S.amber.b + (S.green.b - S.amber.b) * k
end

-- rounded-ish box: body + 1px trimmed corners
function Theme.box(ui, x, y, w, h, fill, border, alpha)
    alpha = alpha or 1
    if fill then
        ui:drawRect(x + 1, y, w - 2, h, fill.a * alpha, fill.r, fill.g, fill.b)
        ui:drawRect(x, y + 1, 1, h - 2, fill.a * alpha, fill.r, fill.g, fill.b)
        ui:drawRect(x + w - 1, y + 1, 1, h - 2, fill.a * alpha, fill.r, fill.g, fill.b)
    end
    if border then
        local a = border.a * alpha
        ui:drawRect(x + 2, y, w - 4, 1, a, border.r, border.g, border.b)
        ui:drawRect(x + 2, y + h - 1, w - 4, 1, a, border.r, border.g, border.b)
        ui:drawRect(x, y + 2, 1, h - 4, a, border.r, border.g, border.b)
        ui:drawRect(x + w - 1, y + 2, 1, h - 4, a, border.r, border.g, border.b)
        ui:drawRect(x + 1, y + 1, 1, 1, a, border.r, border.g, border.b)
        ui:drawRect(x + w - 2, y + 1, 1, 1, a, border.r, border.g, border.b)
        ui:drawRect(x + 1, y + h - 2, 1, 1, a, border.r, border.g, border.b)
        ui:drawRect(x + w - 2, y + h - 2, 1, 1, a, border.r, border.g, border.b)
    end
end

-- gradient relationship bar -100..100 with a marker at the value
function Theme.relBar(ui, x, y, w, h, value, alpha)
    alpha = alpha or 1
    value = math.max(-100, math.min(100, tonumber(value) or 0))
    ui:drawRect(x, y, w, h, S.barBack.a * alpha, S.barBack.r, S.barBack.g, S.barBack.b)
    local steps = math.max(8, math.floor(w / 6))
    local sw = w / steps
    local fillTo = (value + 100) / 200
    for i = 0, steps - 1 do
        local t = (i + 0.5) / steps
        local r, g, b = Theme.gradient(t)
        local a = (t <= fillTo) and 0.95 or 0.18
        ui:drawRect(x + math.floor(i * sw), y, math.ceil(sw), h, a * alpha, r, g, b)
    end
    local mx = x + math.floor(fillTo * (w - 2))
    ui:drawRect(mx - 1, y - 3, 3, h + 6, alpha, S.text.r, S.text.g, S.text.b)
    ui:drawRect(x + math.floor(w / 2), y, 1, h, 0.6 * alpha, 0, 0, 0)
    Theme.box(ui, x - 1, y - 1, w + 2, h + 2, nil, S.borderDim, alpha)
end

function Theme.badge(ui, x, y, text, color, alpha)
    alpha = alpha or 1
    color = color or S.accent
    local w = Theme.textW(text) + 12
    local h = Theme.fontH() + 4
    Theme.box(ui, x, y, w, h, { a = 0.25, r = color.r, g = color.g, b = color.b }, { a = 0.9, r = color.r, g = color.g, b = color.b }, alpha)
    ui:drawText(tostring(text), x + 6, y + 2, color.r, color.g, color.b, alpha, S.font)
    return w
end

-- small up / down triangle (trend arrow) made of rects
function Theme.arrow(ui, x, y, up, color, alpha)
    for i = 0, 4 do
        local row = up and i or (4 - i)
        ui:drawRect(x + 4 - row, y + i * 2, row * 2 + 1, 2, alpha or 1, color.r, color.g, color.b)
    end
end

function Theme.styleButton(b, accent)
    if b == nil then return b end
    local c = accent or S.accent
    b.backgroundColor = { a = 0.75, r = 0.14, g = 0.14, b = 0.15 }
    b.backgroundColorMouseOver = { a = 0.9, r = c.r * 0.45, g = c.g * 0.45, b = c.b * 0.45 }
    b.borderColor = { a = 0.9, r = c.r * 0.8, g = c.g * 0.8, b = c.b * 0.8 }
    pcall(function() b.textColor = { a = 1, r = S.text.r, g = S.text.g, b = S.text.b } end)
    return b
end

function Theme.button(parent, x, y, w, h, title, target, onClick, accent)
    local b = ISButton:new(x, y, w, h, title, target, onClick)
    b:initialise()
    b:instantiate()
    Theme.styleButton(b, accent)
    parent:addChild(b)
    return b
end

function Theme.list(parent, x, y, w, h, itemH, draw)
    local l = ISScrollingListBox:new(x, y, w, h)
    l:initialise()
    l:instantiate()
    l.itemheight = itemH
    l.font = S.font
    l.backgroundColor = { a = 0.55, r = 0.07, g = 0.07, b = 0.08 }
    l.borderColor = S.borderDim
    l.drawBorder = true
    l.doDrawItem = draw
    parent:addChild(l)
    return l
end

-- standard row background: alt stripe, hover highlight, selection
function Theme.rowBack(list, y, item, alt)
    local w = list:getWidth()
    if list.selected == item.index then list:drawRect(0, y, w, list.itemheight, S.select.a, S.select.r, S.select.g, S.select.b)
    elseif list.mouseoverselected == item.index then list:drawRect(0, y, w, list.itemheight, S.hover.a, S.hover.r, S.hover.g, S.hover.b)
    elseif alt then list:drawRect(0, y, w, list.itemheight, S.rowAlt.a, S.rowAlt.r, S.rowAlt.g, S.rowAlt.b) end
    list:drawRect(6, y + list.itemheight - 1, w - 12, 1, 0.25, S.borderDim.r, S.borderDim.g, S.borderDim.b)
end

----------------------------------------------------------------------------------------------------------------
-- ALifeLLMTalkWindow: base for all our windows
----------------------------------------------------------------------------------------------------------------
ALifeLLMTalkWindow = ISPanel:derive("ALifeLLMTalkWindow")
local W = ALifeLLMTalkWindow

function W:new(x, y, w, h, title)
    -- 0.7.0: every window fits the screen (small screens, big UI scale): never wider or taller than it, never off it
    pcall(function()
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        w = math.min(w, sw - 20); h = math.min(h, sh - 40)
        x = math.max(0, math.min(x, sw - w)); y = math.max(0, math.min(y, sh - h))
    end)
    local o = ISPanel.new(self, x, y, w, h)
    o.title = title or "A-Life"
    o.moveWithMouse = true
    o.backgroundColor = { a = 0, r = 0, g = 0, b = 0 }
    o.borderColor = { a = 0, r = 0, g = 0, b = 0 }
    o.openedAt = Theme.now()
    o.fade = 0
    return o
end

function W:createChildren()
    ISPanel.createChildren(self)
    local hh = S.headerH
    self.closeX = ISButton:new(self.width - hh + 3, 3, hh - 6, hh - 6, "x", self, W.onCloseX)
    self.closeX:initialise()
    self.closeX:instantiate()
    Theme.styleButton(self.closeX, S.red)
    self:addChild(self.closeX)
end

function W:onCloseX() self:close() end

-- pre-1.0: corner resize + remembered size for any window that sets rsKey (saved as <rsKey>.w / <rsKey>.h in
-- alifeai_ui.txt). The window then re-places its children in onResized().
W.GRIP = 16
function W:savedSize(defW, defH)
    local w, h = defW, defH
    if self.userW then return self.userW, self.userH end
    if self.rsKey and M.uiPref then
        w = tonumber(M.uiPref(self.rsKey .. ".w", nil)) or w
        h = tonumber(M.uiPref(self.rsKey .. ".h", nil)) or h
    end
    return w, h
end
function W:onMouseDown(x, y)
    if self.rsKey and x >= self.width - W.GRIP and y >= self.height - W.GRIP then
        self.resizing = true; self:setCapture(true); return true
    end
    return ISPanel.onMouseDown(self, x, y)
end
function W:resizeBy(dx, dy)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local nw = math.max(self.minW or 480, math.min(sw - self:getX(), self.width + dx))
    local nh = math.max(self.minH or 320, math.min(sh - self:getY(), self.height + dy))
    self:setWidth(nw); self:setHeight(nh)
    self.userW, self.userH = nw, nh
    if self.closeX then self.closeX:setX(nw - S.headerH + 3) end
    if self.onResized then pcall(self.onResized, self) end
end
function W:onMouseMove(dx, dy) if self.resizing then self:resizeBy(dx, dy); return true end; return ISPanel.onMouseMove(self, dx, dy) end
function W:onMouseMoveOutside(dx, dy) if self.resizing then self:resizeBy(dx, dy); return true end; return ISPanel.onMouseMoveOutside(self, dx, dy) end
function W:stopResize()
    if not self.resizing then return end
    self.resizing = false
    self:setCapture(false)
    if self.rsKey and M.uiSet then M.uiSet(self.rsKey .. ".w", math.floor(self.width)); M.uiSet(self.rsKey .. ".h", math.floor(self.height)) end
end
function W:onMouseUp(x, y) if self.resizing then self:stopResize(); return true end; return ISPanel.onMouseUp(self, x, y) end
function W:onMouseUpOutside(x, y) if self.resizing then self:stopResize(); return true end; return ISPanel.onMouseUpOutside(self, x, y) end
function W:drawGrip()
    if not self.rsKey then return end
    for i = 1, 3 do
        self:drawRect(self.width - 4 - i * 4, self.height - 4, 2, 2, 0.6, 0.84, 0.7, 0.38)
        self:drawRect(self.width - 4, self.height - 4 - i * 4, 2, 2, 0.6, 0.84, 0.7, 0.38)
    end
end

function W:contentTop() return S.headerH + S.pad end

function W:prerender()
    local t = Theme.now() - (self.openedAt or 0)
    self.fade = math.max(0, math.min(1, t / S.fadeMs))
    local a = self.fade
    if self.rsKey then self:drawGrip() end
    if M.uiChrome and M.uiChrome(self, a) then return end -- pre-1.0: window style (ALifeTalk_UIStyles.lua)
    Theme.box(self, 0, 0, self.width, self.height, S.bg, S.border, a)
    Theme.box(self, 1, 1, self.width - 2, S.headerH, S.header, nil, a)
    self:drawRect(1, S.headerH, self.width - 2, 1, 0.8 * a, S.border.r, S.border.g, S.border.b)
    self:drawRect(8, 7, 3, S.headerH - 14, a, S.accent.r, S.accent.g, S.accent.b)
    self:drawText(tostring(self.title or ""), 18, math.floor((S.headerH - Theme.fontH(S.fontTitle)) / 2) + 1,
        S.accent.r, S.accent.g, S.accent.b, a, S.fontTitle)
end

function W:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if self.onClosed then pcall(self.onClosed, self) end
end

function W:onKeyRelease(key)
    if Keyboard and key == Keyboard.KEY_ESCAPE then self:close() return true end
end

function Theme.open(win)
    win:initialise()
    win:addToUIManager()
    pcall(function() win:bringToTop() end)
    return win
end

-- tabs: a row of styled buttons; the active one gets an accent underline
function Theme.tabs(win, x, y, names, onSelect)
    win.tabButtons = {}
    local cx = x
    for i, name in ipairs(names) do
        local w = Theme.textW(name) + 24
        local b = Theme.button(win, cx, y, w, 22, name, win, function() win.activeTab = i; if onSelect then onSelect(win, i) end end)
        b.tabIndex = i
        win.tabButtons[i] = b
        cx = cx + w + 4
    end
    win.activeTab = win.activeTab or 1
end
function Theme.drawTabs(win)
    for i, b in ipairs(win.tabButtons or {}) do
        if i == win.activeTab then
            win:drawRect(b:getX() + 2, b:getY() + b:getHeight(), b:getWidth() - 4, 2, win.fade or 1, S.accent.r, S.accent.g, S.accent.b)
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- Confirmation popup (themed)
----------------------------------------------------------------------------------------------------------------
ALifeTalkConfirm = W:derive("ALifeTalkConfirm")
local C = ALifeTalkConfirm
-- pre-1.0: long questions wrap (preset explanations); " <LINE> " starts a new line
local function confirmLines(text, maxW)
    local out = {}
    text = string.gsub(tostring(text or ""), "%s*<LINE>%s*", "\n")
    for para in string.gmatch(text .. "\n", "(.-)\n") do
        local line = ""
        for word in string.gmatch(para, "%S+") do
            local try = line == "" and word or (line .. " " .. word)
            if line ~= "" and Theme.textW(try) > maxW then out[#out + 1] = line; line = word else line = try end
        end
        out[#out + 1] = line
    end
    return out
end
function C:new(text, onYes)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local maxW = math.max(260, math.min(620, sw - 120))
    local lines = confirmLines(text, maxW)
    local tw = 0
    for _, l in ipairs(lines) do tw = math.max(tw, Theme.textW(l)) end
    local lh = 16
    pcall(function() lh = getTextManager():getFontHeight(S.font) end)
    local w = math.max(300, tw + 40)
    local h = math.min(sh - 40, 44 + #lines * lh + 50)
    local o = W.new(self, (sw - w) / 2, math.max(20, (sh - h) / 2), w, h, "A-Life")
    o.text, o.onYes, o.lines, o.lh = text, onYes, lines, lh
    return o
end
function C:createChildren()
    W.createChildren(self)
    local by = self.height - 38
    Theme.button(self, self.width / 2 - 110, by, 100, 26, "Yes", self, function() pcall(self.onYes); self:close() end, S.green)
    Theme.button(self, self.width / 2 + 10, by, 100, 26, "No", self, function() self:close() end, S.red)
end
function C:prerender()
    W.prerender(self)
    for i, l in ipairs(self.lines or { tostring(self.text) }) do
        self:drawTextCentre(l, self.width / 2, 36 + (i - 1) * (self.lh or 16), S.text.r, S.text.g, S.text.b, self.fade, S.font)
    end
end
function Theme.confirm(text, onYes) return Theme.open(C:new(text, onYes)) end

return M
