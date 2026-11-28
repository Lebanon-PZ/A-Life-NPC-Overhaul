-- A-Life NPC Overhaul pre-1.0: PARTY OVERLAY. A small on-screen card list of the people travelling with you, with the
-- main orders one click away (Follow / Wait / Guard / Base / Talk / Stance per person; everyone follow / wait), so
-- nobody digs through menus. Auto-hide (toggle "A" on the panel): shrinks to a slim tab when all is well, comes back
-- on hover or when someone is hurt, starving or downed. Words, not numbers (immersive). Screen side only: orders go
-- through M.partyCommand / M.qoRun, which already route through ALifeCmd in multiplayer.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) if M.log then M.log("partyhud: " .. tostring(msg)) end end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function you() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function tr(k, en) if ALifeTr then return ALifeTr("IGUI_ALCP_" .. k, en) end return en end

-- settings (load time, so they survive a restart)
local function setting(key, default)
    if type(M.settings) ~= "table" then return end
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("partyHud", true)          -- show the overlay while someone travels with you
setting("partyHudHideSec", 6)      -- auto-hide: seconds after the mouse leaves before it tucks away
setting("partyHudMaxRows", 8)      -- most cards shown at once

local function pref(k, d) if fn(M, "uiPref") then local v = M.uiPref("phud." .. k, d); if v == nil then return d end return v end return d end
local function setPref(k, v) if fn(M, "uiSet") then M.uiSet("phud." .. k, v) end end

-- pure helpers (testable without the screen)
local H = {}
M.partyHud = H
function H.alert(d)
    if type(d) ~= "table" then return false end
    if (tonumber(d.hp) or 100) < 35 then return true end
    if type(d.hurt) == "string" and (d.hurt:find("bitten") or d.hurt:find("bleeding") or d.hurt:find("downed")) then return true end
    local U = ALifeCues
    if fn(U, "needWord") then
        local _, ht = U.needWord("hunger", d.hunger); local _, tt = U.needWord("thirst", d.thirst)
        if ht == "red" or tt == "red" then return true end
    end
    return false
end
function H.rows(player)
    local get = M.partyRows or M.partyData
    if type(get) ~= "function" then return {} end
    local ok, data = pcall(get, player)
    if not ok or type(data) ~= "table" then return {} end
    local out = {}
    for _, d in ipairs(data) do if type(d) == "table" and not d.atBase then out[#out + 1] = d end end
    return out
end
-- should the full panel show? (autoHide off: always; on: hover, recent touch, or trouble)
function H.wantOpen(autoHide, hover, lastTouchMs, nowMs, hideSec, rows)
    if not autoHide or hover then return true end
    if nowMs - (lastTouchMs or -1e12) < (tonumber(hideSec) or 6) * 1000 then return true end
    for _, d in ipairs(rows or {}) do if H.alert(d) then return true end end
    return false
end
function H.nextStance(cur)
    local list = M.partyStances or { "aggressive", "defensive", "passive" }
    for i, s in ipairs(list) do if s == cur then return list[(i % #list) + 1] end end
    return "defensive"
end

if ISPanel == nil or getCore == nil then return M end

local C = {
    bg = { 0.07, 0.07, 0.08 }, edge = { 0.55, 0.47, 0.30 }, gold = { 0.86, 0.72, 0.40 }, text = { 0.90, 0.90, 0.88 },
    dim = { 0.60, 0.60, 0.58 }, green = { 0.45, 0.78, 0.42 }, amber = { 0.92, 0.70, 0.30 }, red = { 0.90, 0.32, 0.27 },
    blue = { 0.45, 0.65, 0.90 }, sel = { 0.86, 0.72, 0.40 },
}
local function tone(t) return C[t or ""] or C.text end
local function fontH(f) local h = 14; pcall(function() h = getTextManager():getFontHeight(f) end); return h end
local function textW(s, f) local w = 8 * #tostring(s); pcall(function() w = getTextManager():MeasureStringX(f, tostring(s)) end); return w end

ALifePartyHUD = ISPanel:derive("ALifePartyHUD")
local P = ALifePartyHUD
local W, HEAD, CARD, BTN = 250, 22, 38, 20
local GRIP = 10
local SCALES = { small = "Small", normal = "Medium", large = "Large" }
-- size follows the chosen text size (scale) and the dragged width (resize)
local function metrics(self)
    local name = SCALES[pref("scale", "small")] or "Small"
    self.font = UIFont[name] or UIFont.Small
    self.small = self.font
    local fh = fontH(self.font)
    HEAD, BTN = fh + 8, fh + 6
    CARD = fh * 2 + 10
    W = math.max(fh * 13, math.min(900, tonumber(pref("w", 0)) or 0))
    if (tonumber(pref("w", 0)) or 0) <= 0 then W = math.max(250, fh * 17) end
end
local PERSON = { { "Follow", "follow" }, { "Wait", "hold" }, { "Guard", "guard" }, { "Base", "base" }, { "Talk", "talk" }, { "Stance", "stance" } }
local GROUP = { { "All follow", "g:party" }, { "All wait", "g:partywait" }, { "Party...", "g:window" } }

function P:new()
    local o = ISPanel.new(self, tonumber(pref("x", 20)) or 20, tonumber(pref("y", 300)) or 300, W, 120)
    o.backgroundColor = { a = 0, r = 0, g = 0, b = 0 }
    o.borderColor = { a = 0, r = 0, g = 0, b = 0 }
    o.moveWithMouse = false
    o.rows, o.readAt, o.touchAt, o.fade = {}, -1e12, now(), 1
    o.hits = {}
    return o
end
function P:touch() self.touchAt = now() end
function P:selectedRow()
    for _, d in ipairs(self.rows) do if tostring(d.uid) == tostring(self.sel) then return d end end
    return nil
end
function P:read()
    self.rows = H.rows(you())
    local max = tonumber(M.settings.partyHudMaxRows) or 8
    while #self.rows > max do table.remove(self.rows) end
    if self.sel and self:selectedRow() == nil then self.sel = nil end
    if self.sel == nil and #self.rows == 1 then self.sel = self.rows[1].uid end
end
function P:layout()
    metrics(self)
    if #self.rows == 0 then self:setWidth(1); self:setHeight(1); return end -- nobody along: out of the way
    local h = HEAD
    if self.open then
        h = h + #self.rows * CARD + 6
        if not pref("collapsed", false) then h = h + 3 * (BTN + 3) + 6 + fontH(self.small) end
    end
    self:setWidth(W); self:setHeight(h)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self:setX(math.max(0, math.min(self:getX(), sw - self.width)))
    self:setY(math.max(0, math.min(self:getY(), sh - self.height)))
end
function P:update()
    ISPanel.update(self)
    local t = now()
    if t - self.readAt > 1500 then self.readAt = t; local ok, e = pcall(self.read, self); if not ok then log(e) end end
    local hover = self:isMouseOver()
    if hover then self:touch() end
    local was = self.open
    self.open = H.wantOpen(pref("autoHide", false), hover, self.touchAt, t, M.settings.partyHudHideSec, self.rows)
    self.empty = #self.rows == 0
    local target = self.open and 1 or 0.35
    self.fade = self.fade + (target - self.fade) * 0.15
    if was ~= self.open or self.lastN ~= #self.rows then self.lastN = #self.rows; self:layout() end
end

-- drawing
local function rect(self, x, y, w, h, a, c) self:drawRect(x, y, w, h, a, c[1], c[2], c[3]) end
local function edge(self, x, y, w, h, a, c) self:drawRectBorder(x, y, w, h, a, c[1], c[2], c[3]) end
local function txt(self, s, x, y, c, a, f) self:drawText(tostring(s), x, y, c[1], c[2], c[3], a, f) end
function P:button(id, label, x, y, w, enabled, lit)
    local a = self.fade
    local mx, my = self:getMouseX(), self:getMouseY()
    local over = enabled and mx >= x and mx < x + w and my >= y and my < y + BTN
    rect(self, x, y, w, BTN, (over and 0.55 or 0.35) * a, lit and C.gold or (over and C.edge or { 0.18, 0.18, 0.2 }))
    edge(self, x, y, w, BTN, 0.8 * a, enabled and C.edge or { 0.3, 0.3, 0.3 })
    local c = not enabled and C.dim or (lit and C.bg or C.text)
    self:drawTextCentre(label, x + w / 2, y + (BTN - fontH(self.small)) / 2, c[1], c[2], c[3], a, self.small)
    if enabled then self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = BTN, id = id } end
end
function P:prerender()
    self.hits = {}
    if self.empty then return end
    local a = self.fade
    rect(self, 0, 0, self.width, self.height, 0.78 * a, C.bg)
    edge(self, 0, 0, self.width, self.height, 0.9 * a, C.edge)
    rect(self, 1, 1, self.width - 2, HEAD - 1, 0.6 * a, { 0.14, 0.12, 0.09 })
end
function P:render()
    if self.empty then return end
    local a = self.fade
    local cap = (fn(M, "partyCapNow") and select(2, pcall(M.partyCapNow, you()))) or tonumber(M.settings.partyCap) or 6
    txt(self, tr("HudParty", "PARTY") .. "  " .. #self.rows .. " / " .. tostring(cap), 8, 4, C.gold, a, self.font)
    -- header toggles: auto-hide, collapse buttons, close
    local hb = BTN
    local bx = self.width - 3 * (hb + 2) - 4
    self:button("autohide", "A", bx, (HEAD - BTN) / 2, hb, true, pref("autoHide", false)); bx = bx + hb + 2
    self:button("collapse", pref("collapsed", false) and "+" or "-", bx, (HEAD - BTN) / 2, hb, true, false); bx = bx + hb + 2
    self:button("close", "x", bx, (HEAD - BTN) / 2, hb, true, false)
    self.hits[#self.hits + 1] = { x = 0, y = 0, w = self.width - 3 * (hb + 2) - 6, h = HEAD, id = "drag" }
    if not self.open then return end
    local U = ALifeCues
    local fh = fontH(self.small)
    local y = HEAD + 3
    for _, d in ipairs(self.rows) do
        local isSel = tostring(d.uid) == tostring(self.sel)
        if isSel then rect(self, 3, y, self.width - 6, CARD - 2, 0.22 * a, C.sel) end
        local hp = tonumber(d.hp) or 100
        local hpT = hp >= 65 and "green" or (hp >= 35 and "amber" or "red")
        if H.alert(d) then hpT = "red" end
        rect(self, 3, y, 3, CARD - 2, a, tone(hpT))
        txt(self, d.name, 11, y + 2, d.here == false and C.dim or C.text, a, self.font)
        -- health bar, no number
        local barW = math.floor(self.width * 0.26)
        local barX = self.width - barW - 10
        rect(self, barX, y + 6, barW, 5, 0.6 * a, { 0.2, 0.2, 0.2 })
        rect(self, barX, y + 6, math.floor(barW * math.max(0, math.min(100, hp)) / 100), 5, a, tone(hpT))
        -- line 2: hurt / needs, else the order
        local bits = {}
        if type(d.hurt) == "string" and d.hurt ~= "" then bits[#bits + 1] = { d.hurt, C.red } end
        if fn(U, "needWord") then
            local hw, ht = U.needWord("hunger", d.hunger); local tw, tt = U.needWord("thirst", d.thirst)
            if hw then bits[#bits + 1] = { hw, tone(ht) } end
            if tw then bits[#bits + 1] = { tw, tone(tt) } end
        end
        local x = 11
        if #bits == 0 then
            txt(self, tostring(d.orderText or d.order or "") .. " - " .. tostring(d.stance or ""), x, y + 3 + fh, C.dim, a, self.small)
        else
            for i, b in ipairs(bits) do
                local s = (i > 1 and ", " or "") .. b[1]
                txt(self, s, x, y + 3 + fh, b[2], a, self.small); x = x + textW(s, self.small)
            end
        end
        self.hits[#self.hits + 1] = { x = 0, y = y, w = self.width, h = CARD - 2, id = "row", uid = d.uid }
        y = y + CARD
    end
    if pref("collapsed", false) then return end
    y = y + 3
    local sel = self:selectedRow()
    local bw = math.floor((self.width - 8 - 2 * 5) / 3)
    for i, b in ipairs(PERSON) do
        local col, rowN = (i - 1) % 3, math.floor((i - 1) / 3)
        self:button(b[2], tr("Hud_" .. b[2], b[1]), 4 + col * (bw + 5), y + rowN * (BTN + 3), bw, sel ~= nil, false)
    end
    y = y + 2 * (BTN + 3) + 1
    for i, b in ipairs(GROUP) do self:button(b[2], tr("Hud_" .. b[2], b[1]), 4 + (i - 1) * (bw + 5), y, bw, true, false) end
    y = y + BTN + 2
    if self.status then txt(self, self.status, 6, y, C.dim, a * 0.9, self.small) end
    -- resize grip (bottom right): drag to change the width
    local gx, gy = self.width - GRIP, self.height - GRIP
    for i = 0, 2 do rect(self, gx + i * 3, gy + 6 - i * 3, 3 * (i + 1) - i * 3 + 2, 2, 0.8 * a, C.edge) end
    self.hits[#self.hits + 1] = { x = gx - 2, y = gy - 2, w = GRIP + 2, h = GRIP + 2, id = "grip" }
end

-- input
function P:hitAt(x, y)
    for i = #self.hits, 1, -1 do local h = self.hits[i]; if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then return h end end
    return nil
end
function P:onMouseDown(x, y)
    self:touch()
    local h = self:hitAt(x, y)
    if h and h.id == "grip" then self.resizing = true; return true end
    if h == nil or h.id == "drag" then
        if not pref("lock", false) then self.dragging, self.dx, self.dy = true, x, y end
        return true
    end
    self.pressed = h
    return true
end
function P:onMouseMove(dx, dy)
    if self.dragging then self:setX(self:getX() + dx); self:setY(self:getY() + dy) end
    if self.resizing then
        local fh = fontH(self.font)
        local w = math.max(fh * 13, math.min(900, self:getMouseX() + 4))
        setPref("w", math.floor(w)); self:layout()
    end
end
function P:onMouseMoveOutside(dx, dy) if self.dragging or self.resizing then self:onMouseMove(dx, dy) end end -- fast moves leave the panel: keep following
function P:onMouseUp(x, y)
    if self.resizing then self.resizing = false; return true end
    if self.dragging then
        self.dragging = false
        setPref("x", math.floor(self:getX())); setPref("y", math.floor(self:getY()))
        return true
    end
    local h = self.pressed; self.pressed = nil
    local up = self:hitAt(x, y) -- hits are rebuilt every frame: match by what was pressed, not the table
    if h and up and up.id == h.id and tostring(up.uid) == tostring(h.uid) then local ok, e = pcall(self.click, self, h); if not ok then log(e) end end
    return true
end
function P:onMouseUpOutside() if self.resizing then self.resizing = false; return true end; if self.dragging then self:onMouseUp(-1, -1) end end
function P:onRightMouseUp()
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    local function toggle(k, d, label) local v = pref(k, d); cm:addOption((v and "[x] " or "[ ] ") .. label, nil, function() setPref(k, not v); self:layout() end) end
    toggle("autoHide", false, tr("HudAutoHide", "Auto-hide when all is well"))
    toggle("collapsed", false, tr("HudCollapse", "Hide the order buttons"))
    toggle("lock", false, tr("WidgetLock", "Lock in place"))
    local so = cm:addOption(tr("WidgetSize", "Size"), nil, nil)
    local ss = ISContextMenu:getNew(cm); cm:addSubMenu(so, ss)
    for _, k in ipairs({ "small", "normal", "large" }) do
        ss:addOption((pref("scale", "small") == k and "> " or "") .. tr("HudScale_" .. k, k), nil, function() setPref("scale", k); setPref("w", 0); self:layout() end)
    end
    cm:addOption(tr("HudResetSize", "Reset size"), nil, function() setPref("scale", "small"); setPref("w", 0); self:layout() end)
    cm:addOption(tr("HudOff", "Turn off (back on in the A-Life window)"), nil, function() M.phudClose() end)
    return true
end
function P:click(h)
    local player = you()
    if h.id == "autohide" then setPref("autoHide", not pref("autoHide", false)); self.status = pref("autoHide", false) and tr("HudAutoOn", "Auto-hide on") or tr("HudAutoOff", "Auto-hide off")
    elseif h.id == "collapse" then setPref("collapsed", not pref("collapsed", false))
    elseif h.id == "close" then M.phudClose(); return
    elseif h.id == "row" then self.sel = (tostring(self.sel) == tostring(h.uid)) and nil or h.uid
    elseif h.id == "g:window" then if fn(M, "openParty") then M.openParty() end
    elseif h.id:sub(1, 2) == "g:" then
        local ok = fn(M, "qoRun") and M.qoRun(h.id:sub(3)) or false
        self.status = ok and tr("HudSent", "Order given.") or tr("OrderNot", "Nobody took that order.")
    else
        local d = self:selectedRow()
        if d == nil or not fn(M, "partyCommand") then return end
        local cmd = h.id
        if cmd == "stance" then
            local b = (fn(M, "bucket") and M.bucket("party")[d.uid]) or (fn(M, "partyRowOf") and M.partyRowOf(d.uid)) or {}
            cmd = H.nextStance(b.stance or d.stance)
            M.partyCommand(d.uid, cmd, player)
            self.status = tr("HudStance", "Stance: ") .. cmd
        else
            local ok = M.partyCommand(d.uid, cmd, player)
            self.status = ok == false and (tostring(d.name) .. tr("HudDidnt", " didn't.")) or (tostring(d.name) .. ": " .. tr("Hud_" .. cmd, cmd))
        end
    end
    self.readAt = -1e12
    self:layout()
end

-- open / close
function M.phudOpen()
    if M.phudPanel then pcall(function() M.phudPanel:setVisible(true); M.phudPanel:addToUIManager() end); return M.phudPanel end
    local p = P:new()
    p:initialise(); p:addToUIManager()
    p:read(); p.open = true; p:layout()
    M.phudPanel = p
    setPref("on", true)
    return p
end
function M.phudClose()
    local p = M.phudPanel
    if p then pcall(function() p:setVisible(false); p:removeFromUIManager() end) end
    M.phudPanel = nil
    setPref("on", false)
end
function M.phudShown() return M.phudPanel ~= nil end
function M.phudToggle() if M.phudShown() then M.phudClose() else M.phudOpen() end end

local function typing()
    local ok, busy = pcall(function() return type(ISChat) == "table" and ISChat.instance ~= nil and ISChat.instance.focused == true end)
    return ok and busy
end
-- keybind (Options > Mods > A-Life NPC Overhaul > "Party overlay show / hide"; unbound by default)
function M.phudKeyPressed(key)
    local opt = type(ALifeRadial) == "table" and ALifeRadial.partyHudKeyOpt or nil
    local k = nil
    pcall(function() k = opt and opt:getValue() end)
    if not k or k == 0 or key ~= k or typing() then return false end
    M.phudToggle()
    return true
end
if Events and Events.OnKeyPressed and not M._phudKeyHooked then
    M._phudKeyHooked = true
    Events.OnKeyPressed.Add(function(key) local ok, e = pcall(M.phudKeyPressed, key); if not ok then log(e) end end)
end
if Events and Events.OnGameStart and not M._phudHooked then
    M._phudHooked = true
    Events.OnGameStart.Add(function()
        if M.settings.partyHud == false or not pref("on", true) then return end
        local ok, e = pcall(M.phudOpen)
        if not ok then print("[ALifePartyHUD] overlay failed, off for this session: " .. tostring(e)) end
    end)
end
print("[ALifePartyHUD] ready pre-1.0: party overlay, auto-hide toggle, one-click orders, keybind, resize + size")
return M
