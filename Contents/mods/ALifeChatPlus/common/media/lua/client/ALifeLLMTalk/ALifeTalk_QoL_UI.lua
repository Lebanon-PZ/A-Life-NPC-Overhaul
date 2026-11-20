-- A-Life NPC Overhaul pre-1.0 (MP port P2): QUALITY OF LIFE, THE SCREEN SIDE (split from ALifeTalk_QoL.lua).
-- The notice log (what popped up on YOUR screen), the camp widget, the quick-order bar and the "Name this place"
-- right-click. The logic they call (M.plAdd, M.uiPref, M.qolStore, ...) is in shared ALifeTalk_QoL.lua.
require "ALifeLLMTalk/ALifeTalk_QoL"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local T, S = M.Theme, M.UIStyle
local function log(msg) if M.log then M.log("qol: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
local function store() return M.qolStore() end
local function foodBand(per) per = tonumber(per) or 0; if per >= 10 then return 4 elseif per >= 5 then return 3 elseif per >= 2 then return 2 end return 1 end
local function camp(uid) return fn(M, "cpIsHome") and M.cpIsHome(tostring(uid), playerOf()) end

----------------------------------------------------------------------------------------------------------------
-- 0.7.0.1: WHAT POPPED UP. Halo notes, red warnings and toasts go by in a few seconds (in a hot bath during an
-- alert, faster). The last 40 are kept for this session and shown on the Now tab. Only the local player's own
-- notices; the originals are never changed or held up.
----------------------------------------------------------------------------------------------------------------
M.ntList = M.ntList or {}
M.ntStats = M.ntStats or { kept = 0, hooks = 0 }
local function ntOn() return M.settings == nil or M.settings.noticeLog ~= false end
local function clockText()
    local t = ""
    pcall(function() local gt = getGameTime(); local function two(n) n = math.floor(tonumber(n) or 0); return (n < 10 and "0" or "") .. n end
        t = "Day " .. (gt:getNightsSurvived() + 1) .. ", " .. two(gt:getHour()) .. ":" .. two(gt:getMinutes()) end)
    return t
end
function M.ntAdd(text, bad)
    if not ntOn() or type(text) ~= "string" then return false end
    text = string.gsub(text, "<[^>]*>", "")
    text = string.gsub(text, "^%s+", ""); text = string.gsub(text, "%s+$", "")
    if #text < 3 then return false end
    local last = M.ntList[1]
    if last and last.text == text and now() - (last.real or 0) < 10000 then return false end
    table.insert(M.ntList, 1, { text = string.sub(text, 1, 200), bad = bad == true, when = clockText(), real = now() })
    while #M.ntList > 40 do table.remove(M.ntList) end
    M.ntStats.kept = M.ntStats.kept + 1
    return true
end
function M.ntRows(n)
    local out = {}
    for i = 1, math.min(n or #M.ntList, #M.ntList) do out[#out + 1] = M.ntList[i] end
    return out
end
local function mine(pl)
    local ok, yes = pcall(function() return pl ~= nil and pl == ALifeSide.you() end)
    return ok and yes
end
local function wrapJava(cls, name, rec)
    local ok = pcall(function()
        local mt = __classmetatables[cls.class].__index
        local orig = mt[name]
        if type(orig) ~= "function" or mt["_alcp_" .. name] then return end
        mt["_alcp_" .. name] = orig
        mt[name] = function(self, ...)
            if mine(self) then pcall(rec, ...) end
            return orig(self, ...)
        end
        M.ntStats.hooks = M.ntStats.hooks + 1
    end)
    return ok
end
function M.ntInstall()
    if M._ntInstalled then return true end
    M._ntInstalled = true
    -- halo text helpers (Lua)
    if type(HaloTextHelper) == "table" then
        for _, k in ipairs({ "addText", "addBadText", "addGoodText" }) do
            local orig = HaloTextHelper[k]
            if type(orig) == "function" then
                HaloTextHelper[k] = function(pl, text, ...)
                    if mine(pl) then pcall(M.ntAdd, text, k == "addBadText") end
                    return orig(pl, text, ...)
                end
                M.ntStats.hooks = M.ntStats.hooks + 1
            end
        end
    end
    -- the player's own halo note and lines over their head (Java, reached through the class table)
    if type(__classmetatables) == "table" and type(IsoPlayer) ~= "nil" then
        wrapJava(IsoPlayer, "setHaloNote", function(text, r, g, b)
            r, g = tonumber(r), tonumber(g)
            M.ntAdd(text, r ~= nil and g ~= nil and r >= 200 and g <= 140)
        end)
        wrapJava(IsoPlayer, "addLineChatElement", function(text, r, g, b)
            r, g = tonumber(r), tonumber(g)
            M.ntAdd(text, r ~= nil and g ~= nil and r >= 0.8 and g <= 0.55)
        end)
    end
    -- our own toasts
    if fn(M, "momToast") and not M._ntToast then
        M._ntToast = true
        local orig = M.momToast
        M.momToast = function(text, r, g, b, ...)
            local res = orig(text, r, g, b, ...)
            local rr, gg = tonumber(r), tonumber(g)
            if rr and rr > 1 then rr, gg = rr / 255, (gg or 0) / 255 end
            pcall(M.ntAdd, text, rr ~= nil and gg ~= nil and rr >= 0.8 and gg <= 0.55)
            return res
        end
    end
    log("notices: " .. M.ntStats.hooks .. " hooks")
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the camp widget and the quick-order bar: small panels, drag anywhere, right-click for settings
----------------------------------------------------------------------------------------------------------------
local function uiFont(size)
    if size == "large" then return UIFont.Medium end
    if size == "small" then return UIFont.Small end
    local sh = 1080
    pcall(function() sh = getCore():getScreenHeight() end)
    return sh >= 1400 and UIFont.Medium or UIFont.Small
end
M.qolFont = uiFont
local function fontH(f) local h = 16; pcall(function() h = getTextManager():getFontHeight(f) end); return h end
local function textW(t, f) local w = 8 * #tostring(t); pcall(function() w = getTextManager():MeasureStringX(f, tostring(t)) end); return w end

-- what the widget can show (each a line, each switchable)
M.wgLines = {
    { id = "food", label = "Food", get = function(bs) return bs and M.qolFoodWord(bs.foodPer) end, bad = function(bs) return bs and foodBand(bs.foodPer) <= 2 end },
    { id = "people", label = "People", get = function(bs) return bs and (tostring(bs.settlers or 0) .. (bs.settlers == 1 and " person" or " people")) end },
    { id = "safety", label = "Around us", get = function(bs)
        if not bs then return nil end
        local s = tonumber(bs.safety) or 100
        return s >= 80 and "quiet" or (s >= 50 and "some dead about" or "dead everywhere") end, bad = function(bs) return bs and (tonumber(bs.safety) or 100) < 50 end },
    { id = "mood", label = "Mood", get = function(bs)
        if not bs then return nil end
        local m = tonumber(bs.morale) or 50
        return m >= 70 and "good" or (m >= 45 and "holding up" or (m >= 25 and "low" or "close to breaking")) end, bad = function(bs) return bs and (tonumber(bs.morale) or 50) < 30 end },
    { id = "alarm", label = "Alarm", get = function() return (fn(M, "alOn") and M.alOn()) and "RAISED" or "quiet" end, bad = function() return fn(M, "alOn") and M.alOn() end },
    { id = "away", label = "Away", get = function()
        local n = 0
        for uid in pairs((fn(M, "lvIsAway") and M.lvMem and M.lvMem.leavers) or {}) do if camp(uid) then n = n + 1 end end
        for _ in pairs(store().plOrders) do n = n + 1 end
        return n == 0 and "nobody" or (n == 1 and "one of us" or (n .. " of us")) end },
}

ALifeTalkWidget = ISPanel:derive("ALifeTalkWidget")
local WG = ALifeTalkWidget
function WG:new(kind)
    local x = M.uiPref(kind .. ".x", 20)
    local y = M.uiPref(kind .. ".y", 220)
    local o = ISPanel.new(self, x, y, 200, 80)
    o.kind = kind
    o.moveWithMouse = true
    o.backgroundColor = { a = 0, r = 0, g = 0, b = 0 }
    o.borderColor = { a = 0, r = 0, g = 0, b = 0 }
    o.rows, o.readAt = {}, -1e12
    return o
end
function WG:pref(k, d) return M.uiPref(self.kind .. "." .. k, d) end
function WG:setPref(k, v) M.uiSet(self.kind .. "." .. k, v); self.readAt = -1e12; self:relayout() end
function WG:onMouseDown(x, y)
    if self:pref("lock", false) then return true end
    return ISPanel.onMouseDown(self, x, y)
end
function WG:onMouseUp(x, y)
    local r = ISPanel.onMouseUp(self, x, y)
    M.uiSet(self.kind .. ".x", math.floor(self:getX())); M.uiSet(self.kind .. ".y", math.floor(self:getY()))
    return r
end
function WG:onMouseMove(dx, dy)
    if self:pref("lock", false) then return end
    return ISPanel.onMouseMove(self, dx, dy)
end
function WG:clampToScreen()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self:setX(math.max(0, math.min(self:getX(), sw - self.width)))
    self:setY(math.max(0, math.min(self:getY(), sh - self.height)))
end
function WG:font() return uiFont(self:pref("size", "auto")) end
function WG:alpha() return tonumber(self:pref("opacity", 0.75)) or 0.75 end

-- the camp widget
function WG:readCamp()
    local p = playerOf()
    local bs = nil
    if fn(M, "baseState") and p then local ok, r = pcall(M.baseState, p); if ok then bs = r end end
    -- 0.7.0.5: count the camp the way the camp board does (your settlers and Jeem's residents at home), not only the
    -- old settler list (empty without the talk patch: "0 people" with 16 at the base); food per head follows
    if bs and fn(M, "cpPeople") then
        local okP, list = pcall(M.cpPeople, p)
        if okP and type(list) == "table" then
            bs.settlers = #list
            bs.foodPer = (tonumber(bs.food) or 0) / math.max(1, #list + 1)
        end
    end
    local rows, bad = {}, false
    for _, L in ipairs(M.wgLines) do
        if self:pref("show." .. L.id, L.id ~= "safety") then
            local okG, v = pcall(L.get, bs)
            if okG and v then
                local isBad = L.bad and select(2, pcall(L.bad, bs)) == true
                bad = bad or isBad
                rows[#rows + 1] = { label = tr("Widget_" .. L.id, L.label), value = tostring(v), bad = isBad }
            end
        end
    end
    if bs == nil and #rows > 0 then
        rows = { { label = tr("Widget_camp", "Camp"), value = tr("WidgetNoBase", "no base yet"), bad = false } }
    end
    self.rows, self.allWell = rows, not bad
end
function WG:relayout()
    local f = self:font()
    local fh = fontH(f)
    if self.kind == "widget" then
        local w = 0
        for _, r in ipairs(self.rows) do w = math.max(w, textW(r.label .. ":  " .. r.value, f)) end
        self:setWidth(math.max(120, w + 20)); self:setHeight(math.max(fh + 12, #self.rows * (fh + 2) + 10))
    else
        self:layoutBar()
    end
    self:clampToScreen()
end
function WG:update()
    ISPanel.update(self)
    if self.kind ~= "widget" then return end
    local t = now()
    if t - self.readAt > 10000 then
        self.readAt = t
        pcall(self.readCamp, self)
        self:relayout()
        local hideWell = self:pref("autoHide", false)
        self.hiddenNow = hideWell and self.allWell
    end
end
function WG:prerender()
    if self.hiddenNow then return end
    local a = self:alpha()
    self:drawRect(0, 0, self.width, self.height, a, 0.09, 0.09, 0.1)
    self:drawRectBorder(0, 0, self.width, self.height, math.min(1, a + 0.15), 0.55, 0.47, 0.3)
end
function WG:render()
    if self.hiddenNow then return end
    if self.kind ~= "widget" then return end
    local f = self:font()
    local fh = fontH(f)
    for i, r in ipairs(self.rows) do
        local y = 5 + (i - 1) * (fh + 2)
        self:drawText(r.label .. ":", 10, y, 0.84, 0.7, 0.38, 1, f)
        local c = r.bad and { 0.95, 0.45, 0.35 } or { 0.88, 0.89, 0.9 }
        self:drawText(r.value, 10 + textW(r.label .. ":  ", f), y, c[1], c[2], c[3], 1, f)
    end
end
function WG:onRightMouseUp(x, y)
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    local function toggle(k, d, label)
        local v = self:pref(k, d)
        cm:addOption((v and "[x] " or "[ ] ") .. label, nil, function() self:setPref(k, not v) end)
    end
    if self.kind == "widget" then
        local o = cm:addOption(tr("WidgetShow", "Show"), nil, nil)
        local sub = ISContextMenu:getNew(cm); cm:addSubMenu(o, sub)
        for _, L in ipairs(M.wgLines) do
            local v = self:pref("show." .. L.id, L.id ~= "safety")
            sub:addOption((v and "[x] " or "[ ] ") .. tr("Widget_" .. L.id, L.label), nil, function() self:setPref("show." .. L.id, not v) end)
        end
        toggle("autoHide", false, tr("WidgetAutoHide", "Hide while everything is fine"))
    else
        local o = cm:addOption(tr("QuickPick", "Buttons"), nil, nil)
        local sub = ISContextMenu:getNew(cm); cm:addSubMenu(o, sub)
        for _, q in ipairs(M.qoOrders) do
            if q.who ~= "person" then
                local v = self:pref("show." .. q.id, true)
                sub:addOption((v and "[x] " or "[ ] ") .. tr("Order_" .. q.id, q.label), nil, function() self:setPref("show." .. q.id, not v); self:buildBar() end)
            end
        end
        toggle("vertical", false, tr("QuickVertical", "Stack the buttons"))
    end
    local so = cm:addOption(tr("WidgetSize", "Size"), nil, nil)
    local ss = ISContextMenu:getNew(cm); cm:addSubMenu(so, ss)
    for _, sz in ipairs({ "auto", "small", "large" }) do ss:addOption(tr("Size_" .. sz, sz), nil, function() self:setPref("size", sz); if self.buildBar then self:buildBar() end end) end
    local oo = cm:addOption(tr("WidgetOpacity", "See-through"), nil, nil)
    local os = ISContextMenu:getNew(cm); cm:addSubMenu(oo, os)
    for _, a in ipairs({ 0.35, 0.55, 0.75, 0.95 }) do os:addOption(tostring(math.floor((1 - a) * 100 + 0.5)) .. " percent", nil, function() self:setPref("opacity", a) end) end
    toggle("lock", false, tr("WidgetLock", "Lock in place"))
    cm:addOption(tr("WidgetHide", "Hide (turn back on in the A-Life window)"), nil, function() M.uiSet(self.kind .. ".on", false); self:setVisible(false); self:removeFromUIManager() end)
    return true
end

-- the quick-order bar
function WG:buildBar()
    for _, b in ipairs(self.buttons or {}) do pcall(function() self:removeChild(b) end) end
    self.buttons = {}
    local f = self:font()
    for _, q in ipairs(M.qoOrders) do
        if q.who ~= "person" and self:pref("show." .. q.id, true) and (q.ok == nil or q.ok()) then
            local label = tr("Order_" .. q.id, q.label)
            local b = ISButton:new(0, 0, textW(label, f) + 16, fontH(f) + 8, label, self, function() local ok = M.qoRun(q.id); if fn(M, "momToast") then pcall(M.momToast, ok and label or tr("OrderNot", "Nobody took that order.")) end end)
            b:initialise(); b:instantiate()
            b.font = f
            if T and T.styleButton then pcall(T.styleButton, b) end
            self:addChild(b)
            self.buttons[#self.buttons + 1] = b
        end
    end
    self:layoutBar()
end
function WG:layoutBar()
    local x, y, w, h = 6, 6, 0, 0
    local vertical = self:pref("vertical", false)
    for _, b in ipairs(self.buttons or {}) do
        b:setX(x); b:setY(y)
        if vertical then y = y + b:getHeight() + 4; w = math.max(w, b:getWidth())
        else x = x + b:getWidth() + 4; h = math.max(h, b:getHeight()) end
    end
    if vertical then self:setWidth(math.max(60, w + 12)); self:setHeight(math.max(20, y + 2))
    else self:setWidth(math.max(60, x + 2)); self:setHeight(math.max(20, h + 12)) end
end

function M.wgOpen(kind)
    M.qolPanels = M.qolPanels or {}
    local cur = M.qolPanels[kind]
    if cur then pcall(function() cur:setVisible(true); cur:addToUIManager() end); return cur end
    local w = WG:new(kind)
    w:initialise(); w:addToUIManager()
    if kind == "quick" then w:buildBar() else w:readCamp(); w:relayout() end
    M.qolPanels[kind] = w
    M.uiSet(kind .. ".on", true)
    return w
end
function M.wgClose(kind)
    local cur = M.qolPanels and M.qolPanels[kind]
    if cur then pcall(function() cur:setVisible(false); cur:removeFromUIManager() end); M.qolPanels[kind] = nil end
    M.uiSet(kind .. ".on", false)
end
function M.wgShown(kind) return M.qolPanels ~= nil and M.qolPanels[kind] ~= nil end

----------------------------------------------------------------------------------------------------------------
-- right-click: name this place / the places you named
----------------------------------------------------------------------------------------------------------------
function M.plAsk(x, y, z)
    local modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 150, getCore():getScreenHeight() / 2 - 60, 300, 120,
        tr("PlaceAsk", "What do you call this place?"), "", nil, function(_, button)
            if button.internal == "OK" then
                local txt = button.parent.entry:getText()
                local pl = M.plAdd(txt, x, y, z)
                if pl and fn(M, "momToast") then pcall(M.momToast, tr("PlaceNamed", "Marked \"{1}\" on your map.", pl.name)) end
            end
        end)
    modal:initialise(); modal:addToUIManager()
    return modal
end
function M.plFill(playerNum, context, worldobjects, test)
    if test == true or M.settings.namedPlaces == false or type(context) ~= "table" then return end
    local sq = nil
    for _, o in ipairs(worldobjects or {}) do pcall(function() sq = sq or o:getSquare() end) end
    if sq == nil then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local near = M.plNear(x, y, 6)
    if near then
        local o = context:addOption(tr("PlaceHere", "Place: {1}", near.name), nil, nil)
        local sub = ISContextMenu:getNew(context); context:addSubMenu(o, sub)
        sub:addOption(tr("PlaceForget", "Forget this name"), nil, function() M.plRemove(near.id) end)
    else
        context:addOption(tr("PlaceName", "Name this spot..."), nil, function() M.plAsk(x, y, z) end)
    end
end

----------------------------------------------------------------------------------------------------------------
-- install (screen side): the place menu, the panels, the notice log
----------------------------------------------------------------------------------------------------------------
function M.qolInstallUI()
    if M._qolUIHooked then return true end
    M._qolUIHooked = true
    if type(ALifeRadial) == "table" and fn(ALifeRadial, "addFiller") then
        ALifeRadial.addFiller("namedplaces", "camp", function(...) local ok, err = pcall(M.plFill, ...); if not ok then log("place menu: " .. tostring(err)) end end)
    end
    if M.uiPref("widget.on", false) then pcall(M.wgOpen, "widget") end
    if M.uiPref("quick.on", false) then pcall(M.wgOpen, "quick") end
    return true
end
if not M._qolUITick and Events and Events.OnGameStart then
    M._qolUITick = true
    Events.OnGameStart.Add(function() local ok, err = pcall(M.qolInstallUI); if not ok then print("[ALifeQoL] screen side failed, widget / place menu off for this session: " .. tostring(err)) end end)
    Events.OnGameStart.Add(function() local ok, err = pcall(M.ntInstall); if not ok then print("[ALifeQoL] notice log failed, kept notices off for this session: " .. tostring(err)) end end)
end
print("[ALifeQoL] screen side loaded (pre-1.0): notices, widget, quick-order bar, place menu")
