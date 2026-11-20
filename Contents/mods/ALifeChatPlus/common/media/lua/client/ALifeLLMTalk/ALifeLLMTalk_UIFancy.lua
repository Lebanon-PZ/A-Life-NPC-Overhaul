-- A-Life Talk 0.5.2.7 [pt255u]: "can we make each window look fancy like this one is" + "sometimes the sentences get
-- clipped out too". One shared style (the Personality page look) for every A-Life Talk window: dark flat card, big
-- title, small uppercase coloured section headers, thin rounded bars, pill tags and pill buttons (dimmed when
-- locked; the tooltip says why), padded card rows, a clean bottom bar. Long text WRAPS to the width (rows grow,
-- max 3 lines, then "..." and the full text on hover) - never cut without an ellipsis. Text widths and wrapped
-- lines are cached (no per-frame measuring), so it stays at 60 FPS. Off: uiFancy (old look) / uiWrap (one line + "...").
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UIFancy"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UIFancy") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local T, S = M.Theme, M.UIStyle
if T == nil or S == nil then return end
local F = {}
M.Fancy = F
local function on() return M.settings.uiFancy ~= false end
local function wrapOn() return M.settings.uiWrap ~= false end
F.on, F.wrapOn = on, wrapOn
local function c255(r, g, b, a) return { r = r / 255, g = g / 255, b = b / 255, a = a or 1 } end
-- the Personality page colours (UIPage P.C) - kept here so every window shares them even before UIPage loads
F.C = { bg = c255(22, 24, 27, 0.97), card = c255(30, 33, 37, 0.92), cardHi = c255(40, 44, 50, 0.95), gold = c255(214, 178, 96),
    txt = c255(222, 224, 228), dim = c255(124, 128, 134), track = c255(38, 41, 46), border = c255(70, 62, 40), divider = c255(44, 47, 52),
    name = c255(238, 238, 238), pos = c255(104, 168, 124), neg = c255(214, 120, 96), blue = c255(120, 170, 190), pink = c255(214, 130, 170) }
local C = F.C

----------------------------------------------------------------------------------------------------------------
-- measuring: cached text widths + wrapped lines (reset when the font height changes, and every few seconds)
----------------------------------------------------------------------------------------------------------------
local origW, origFH = T.textW, T.fontH
F.cache, F.wcache, F.cacheN, F.measures = {}, {}, 0, 0
local cacheFH, cacheAt = nil, 0
local function reset() F.cache, F.wcache, F.cacheN = {}, {}, 0 end
F.reset = reset
function T.fontH(font)
    local h = origFH(font)
    if (font == nil or font == S.font) and h ~= cacheFH then cacheFH = h; reset() end
    return h
end
function T.textW(text, font)
    if not on() and not wrapOn() then return origW(text, font) end
    local now = T.now()
    if now - cacheAt > 5000 then cacheAt = now; reset() end
    local k = tostring(font or S.font) .. "\1" .. tostring(text)
    local v = F.cache[k]
    if v ~= nil then return v end
    v = origW(text, font)
    F.measures = F.measures + 1
    if F.cacheN > 4000 then reset() end
    F.cache[k] = v; F.cacheN = F.cacheN + 1
    return v
end
-- wrap to maxW, at most maxLines (the last one gets "..." when there is more) -> lines, cut
function F.wrap(text, maxW, font, maxLines)
    text = tostring(text or "")
    maxLines = maxLines or 3
    local k = tostring(maxW) .. "\1" .. tostring(font or S.font) .. "\1" .. maxLines .. "\1" .. text
    local hit = F.wcache[k]
    if hit then return hit[1], hit[2] end
    local lines, cur, cut = {}, "", false
    for word in string.gmatch(text, "%S+") do
        if #lines >= maxLines then cut = true; break end
        local t = cur == "" and word or (cur .. " " .. word)
        if T.textW(t, font) > maxW and cur ~= "" then
            lines[#lines + 1] = cur; cur = word
            if #lines >= maxLines then cut = true; cur = ""; break end
        else cur = t end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    for i, ln in ipairs(lines) do if T.textW(ln, font) > maxW then lines[i] = T.fit(ln, maxW, font); cut = true end end -- one huge word
    if cut and #lines > 0 then
        local last = lines[#lines]
        if string.sub(last, -3) ~= "..." then lines[#lines] = T.fit(last .. " ...", maxW, font); if string.sub(lines[#lines], -3) ~= "..." then lines[#lines] = T.fit(last, maxW - T.textW("...", font), font) .. "..." end end
    end
    if #lines == 0 then lines[1] = "" end
    F.wcache[k] = { lines, cut }
    return lines, cut
end

----------------------------------------------------------------------------------------------------------------
-- primitives: rounded rect (radius capped so a pill is ~2r+1 rects), pill tag, thin bar, card, section header
----------------------------------------------------------------------------------------------------------------
function F.rrect(ui, x, y, w, h, r, c, a)
    a = (c.a or 1) * (a or 1)
    r = math.min(r or 4, 6, math.floor(h / 2), math.floor(w / 2))
    if r <= 1 then ui:drawRect(x, y, w, h, a, c.r, c.g, c.b); return end
    for dy = 0, r - 1 do
        local yy = r - dy - 0.5
        local i0 = math.floor(r - math.sqrt(math.max(0, r * r - yy * yy)) + 0.5)
        ui:drawRect(x + i0, y + dy, w - 2 * i0, 1, a, c.r, c.g, c.b)
        ui:drawRect(x + i0, y + h - 1 - dy, w - 2 * i0, 1, a, c.r, c.g, c.b)
    end
    if h - 2 * r > 0 then ui:drawRect(x, y + r, w, h - 2 * r, a, c.r, c.g, c.b) end
end
local function mix(c, k, a) return { r = c.r * k, g = c.g * k, b = c.b * k, a = a or 1 } end
F.mix = mix
function F.pillW(text) return T.textW(text) + 16 end
function F.pill(ui, x, y, text, c, a, h)
    c = c or C.gold
    h = h or (T.fontH() + 4)
    local w = F.pillW(text)
    F.rrect(ui, x, y, w, h, math.floor(h / 2), mix(c, 0.75, 0.9), a)
    F.rrect(ui, x + 1, y + 1, w - 2, h - 2, math.floor(h / 2) - 1, mix(c, 0.22, 0.95), a)
    ui:drawText(tostring(text), x + 8, y + math.floor((h - T.fontH()) / 2), c.r, c.g, c.b, a or 1, S.font)
    return w
end
function F.bar(ui, x, y, w, frac, c, a, h)
    h = h or 6
    F.rrect(ui, x, y, w, h, math.floor(h / 2), C.track, a)
    if frac and frac > 0 then F.rrect(ui, x, y, math.max(h, math.floor(w * math.min(1, frac))), h, math.floor(h / 2), c, a) end
end
function F.card(ui, x, y, w, h, a, selected, hover)
    if selected then F.rrect(ui, x, y, w, h, 5, mix(C.gold, 0.8, 0.9), a); F.rrect(ui, x + 1, y + 1, w - 2, h - 2, 4, C.cardHi, a)
    else F.rrect(ui, x, y, w, h, 5, hover and C.cardHi or C.card, a) end
end
function F.header(ui, x, y, text, c, a)
    c = c or C.gold
    ui:drawText(string.upper(tostring(text)), x, y, c.r, c.g, c.b, a or 1, S.font)
end

----------------------------------------------------------------------------------------------------------------
-- Theme overrides (every window: Relationships, the list, Party, Places, settings, confirm)
----------------------------------------------------------------------------------------------------------------
local oRowBack, oBadge, oRelBar, oStyle, oDrawTabs, oList = T.rowBack, T.badge, T.relBar, T.styleButton, T.drawTabs, T.list
function T.rowBack(list, y, item, alt)
    if not on() then return oRowBack(list, y, item, alt) end
    local h = item.height or list.itemheight
    F.card(list, 4, y + 2, list:getWidth() - 8 - (list.vscroll and list.vscroll:isVisible() and 14 or 0), h - 4, 1,
        list.selected == item.index, list.mouseoverselected == item.index)
end
function T.badge(ui, x, y, text, color, alpha)
    if not on() then return oBadge(ui, x, y, text, color, alpha) end
    return F.pill(ui, x, y, tostring(text), color or C.gold, alpha)
end
function T.relBar(ui, x, y, w, h, value, alpha)
    if not on() then return oRelBar(ui, x, y, w, h, value, alpha) end
    value = math.max(-100, math.min(100, tonumber(value) or 0))
    local hh = math.min(h or 6, 6)
    local yy = y + math.floor(((h or 6) - hh) / 2)
    F.rrect(ui, x, yy, w, hh, math.floor(hh / 2), C.track, alpha)
    local mid = x + math.floor(w / 2)
    local len = math.floor(math.abs(value) / 100 * (w / 2))
    local c = value >= 0 and C.pos or C.neg
    if len > 0 then F.rrect(ui, value >= 0 and mid or (mid - len), yy, math.max(hh, len), hh, math.floor(hh / 2), c, alpha) end
    ui:drawRect(mid, yy - 2, 1, hh + 4, 0.7 * (alpha or 1), C.dim.r, C.dim.g, C.dim.b)
end
local function btnPreDraw(self)
    if not self.fancyTab and M.uiButton and M.uiButton(self) then return end -- pre-1.0: window style (ALifeTalk_UIStyles.lua)
    if not on() then
        local f = ISButton and ISButton.prerender
        if f then return f(self) end
        return
    end
    local en = self.enable ~= false
    local w, h = self:getWidth(), self:getHeight()
    local a = (self.parent and self.parent.fade) or 1
    if self.fancyTab then
        local act = self.parent and self.parent.activeTab == self.tabIndex
        self.textColor = act and { r = C.gold.r, g = C.gold.g, b = C.gold.b, a = 1 } or { r = C.dim.r, g = C.dim.g, b = C.dim.b, a = 1 }
        if self:isMouseOver() and not act then self:drawRect(2, h - 2, w - 4, 1, 0.6 * a, C.dim.r, C.dim.g, C.dim.b) end
        return
    end
    local c = self.fancyAccent or C.gold
    local hover = en and self:isMouseOver()
    F.rrect(self, 0, 0, w, h, math.floor(h / 2), en and mix(c, 0.8, 0.95) or mix(C.dim, 0.5, 0.6), a)
    F.rrect(self, 1, 1, w - 2, h - 2, math.floor(h / 2) - 1, hover and mix(c, 0.38, 1) or (en and C.card or mix(C.track, 0.8, 0.9)), a)
    self.textColor = en and { r = C.txt.r, g = C.txt.g, b = C.txt.b, a = 1 } or { r = C.dim.r, g = C.dim.g, b = C.dim.b, a = 0.8 }
end
-- pre-1.0: vanilla ISButton shows its tooltip from the END of its own prerender (self:updateTooltip()). Every styled
-- button replaced that prerender and returned early, so hover tips only came up by luck. Run it after every style.
local function btnPre(self)
    btnPreDraw(self)
    if self.tooltip ~= nil and type(self.updateTooltip) == "function" then pcall(self.updateTooltip, self) end
end
F.btnPre = btnPre
function T.styleButton(b, accent)
    local r = oStyle(b, accent)
    if b ~= nil then
        b.fancyAccent = accent
        b.prerender = btnPre
    end
    return r
end
function T.drawTabs(win)
    if not on() then return oDrawTabs(win) end
    local btns = win.tabButtons or {}
    if #btns == 0 then return end
    local a = win.fade or 1
    local b1, bn = btns[1], btns[#btns]
    local yb = b1:getY() + b1:getHeight()
    win:drawRect(b1:getX(), yb + 1, (win.width - 12) - b1:getX(), 1, a, C.divider.r, C.divider.g, C.divider.b)
    for i, b in ipairs(btns) do
        b.fancyTab = true
        if i == win.activeTab then win:drawRect(b:getX() + 4, yb - 1, b:getWidth() - 8, 2, a, C.gold.r, C.gold.g, C.gold.b) end
    end
end
-- lists: no box (rows are cards), the hover tooltip for cut rows (vanilla shows item.tooltip when it can)
function F.drawTip(list)
    if not on() and not wrapOn() then return end
    local idx = list.mouseoverselected
    local it = idx and list.items and list.items[idx] or nil
    if it == nil or it.tooltip == nil or not list:isMouseOver() then return end
    local mx, my = list:getMouseX(), list:getMouseY()
    local ys = 0
    pcall(function() ys = list:getYScroll() or 0 end)
    local maxW = math.min(460, list:getWidth() - 24)
    local lines = F.wrap(it.tooltip, maxW - 16, S.font, 8)
    local fh = T.fontH()
    local bw, bh = 0, #lines * fh + 12
    for _, ln in ipairs(lines) do bw = math.max(bw, T.textW(ln)) end
    bw = bw + 16
    local x = math.max(2, math.min(mx + 14, list:getWidth() - bw - 4))
    local y = my + 18
    if y + bh > list:getHeight() then y = math.max(2, my - bh - 6) end
    y = y - ys
    F.rrect(list, x, y, bw, bh, 5, mix(C.gold, 0.7, 0.95), 1)
    F.rrect(list, x + 1, y + 1, bw - 2, bh - 2, 4, { r = 0.07, g = 0.075, b = 0.085, a = 0.98 }, 1)
    for i, ln in ipairs(lines) do list:drawText(ln, x + 8, y + 6 + (i - 1) * fh, C.txt.r, C.txt.g, C.txt.b, 1, S.font) end
end
local function listRender(self)
    local base = ISScrollingListBox and ISScrollingListBox.render
    if base then base(self) end
    if ISScrollingListBox == nil or ISScrollingListBox.updateTooltip == nil then pcall(F.drawTip, self) end
end
function T.list(parent, x, y, w, h, itemH, draw)
    local l = oList(parent, x, y, w, h, itemH, draw)
    if l and on() then
        l.backgroundColor = { a = 0, r = 0, g = 0, b = 0 }
        l.borderColor = { a = 0, r = 0, g = 0, b = 0 }
        l.drawBorder = false
    end
    if l then l.render = listRender end
    return l
end

-- window body: the dark flat card + title + divider (all ALifeLLMTalkWindow windows)
local Win = ALifeLLMTalkWindow
if Win then
    local oPre = Win.prerender
    function Win:prerender()
        if not on() then return oPre(self) end
        local t = T.now() - (self.openedAt or 0)
        self.fade = math.max(0, math.min(1, t / S.fadeMs))
        local a = self.fade
        if self.rsKey then self:drawGrip() end
        if not (M.uiChrome and M.uiChrome(self, a)) then -- pre-1.0: window style (ALifeTalk_UIStyles.lua)
            F.rrect(self, 0, 0, self.width, self.height, 8, mix(C.border, 1, 0.95), a)
            F.rrect(self, 1, 1, self.width - 2, self.height - 2, 7, C.bg, a)
            local hh = S.headerH
            self:drawRect(10, math.floor(hh / 2) - 3, 6, 6, a, C.gold.r, C.gold.g, C.gold.b)
            self:drawText(T.fit(tostring(self.title or ""), self.width - 60, S.fontTitle), 24, math.floor((hh - T.fontH(S.fontTitle)) / 2) + 1,
                C.name.r, C.name.g, C.name.b, a, S.fontTitle)
            self:drawRect(10, hh, self.width - 20, 1, a, C.divider.r, C.divider.g, C.divider.b)
        end
        if self.fancyBody then pcall(self.fancyBody, self, a) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- Relationships window: body card, bottom bar, and the list tabs as wrapped card rows
----------------------------------------------------------------------------------------------------------------
local W = ALifeTalkRelationWindow
if W then
    function W:fancyBody(a)
        if self.pageMode then return end
        local L = self.lay
        if L == nil then return end
        local cx = self.cx or 176
        local top = (L.tabY or 0) + (L.tabH or 22) + 4
        local barY = self.height - (L.bottom or 46)
        if barY - top > 20 then F.rrect(self, cx - 8, top, self.width - cx - 4, barY - top - 2, 6, mix(C.card, 0.75, 0.55), a) end
        self:drawRect(12, barY, self.width - 24, 1, a, C.divider.r, C.divider.g, C.divider.b)
    end
    local function rowLines(list, item, text, w, maxLines)
        if item._fw == w and item._ft == text then return item._lines, item._cut end
        local lines, cut
        if wrapOn() then lines, cut = F.wrap(text, w, S.font, maxLines or 3)
        else local s = T.fit(text, w); lines, cut = { s }, s ~= tostring(text or "") end
        item._fw, item._ft, item._lines, item._cut = w, text, lines, cut
        item.tooltip = cut and tostring(text or "") or nil
        return lines, cut
    end
    F.rowLines = rowLines
    local function sbw(list) return 20 end
    local oMem, oTie, oInt = W.drawMemory, W.drawTie, W.drawInteraction
    function W.drawMemory(list, y, item, alt)
        if not on() and not wrapOn() then return oMem(list, y, item, alt) end
        local row = item.item
        local fh, lw = T.fontH(), list:getWidth() - sbw(list)
        local lines = rowLines(list, item, tostring(row.text or ""), lw - 26, 3)
        item.height = math.max(list.itemheight, 8 + fh + 4 + #lines * fh + 8)
        T.rowBack(list, y, item, alt)
        local c = S.kindColor[row.kind] or S.text
        local chip = S.kinds[row.kind] or tostring(row.kind or "")
        if on() then F.pill(list, 14, y + 6, string.upper(chip), c, 1)
        else list:drawText(chip, 14, y + 6, c.r, c.g, c.b, 1, S.font) end
        list:drawTextRight(T.fit(tostring(row.when or ""), math.floor(lw * 0.45)), lw - 6, y + 8, C.dim.r, C.dim.g, C.dim.b, 1, S.font)
        for i, ln in ipairs(lines) do list:drawText(ln, 16, y + 8 + fh + 6 + (i - 1) * fh, C.txt.r, C.txt.g, C.txt.b, 1, S.font) end
        return y + item.height
    end
    function W.drawTie(list, y, item, alt)
        if not on() and not wrapOn() then return oTie(list, y, item, alt) end
        local t = item.item
        local fh, lw = T.fontH(), list:getWidth() - sbw(list)
        local a = t.dead and 0.5 or 1
        if t.none then item.height = list.itemheight; T.rowBack(list, y, item, alt); list:drawText(t.name, 14, y + 7, C.dim.r, C.dim.g, C.dim.b, 1, S.font); return y + item.height end
        local why = t.why and tostring(t.why) or nil
        local lines = why and rowLines(list, item, why, lw - 30, 3) or {}
        item.height = math.max(list.itemheight, 8 + fh + 6 + #lines * fh + 6)
        T.rowBack(list, y, item, alt)
        local c1 = math.floor(lw * 0.30)
        list:drawText(T.fit(t.name .. (t.dead and " (dead)" or ""), c1 - 18), 14, y + 7, C.name.r, C.name.g, C.name.b, a, S.font)
        local _, tc = M.bandOf(t.score)
        local tag = (M.Page and M.Page.TAG and M.Page.TAG[t.type or ""]) or tc
        local bw = T.badge(list, c1, y + 5, T.fit(tostring(t.word), math.floor(lw * 0.26)), tag, a)
        local num = (t.score > 0 and "+" or "") .. tostring(t.score)
        local nx = lw - 8
        local bx = c1 + bw + 12
        local barW = nx - T.textW(num) - 10 - bx
        if barW >= 30 then
            if on() then F.bar(list, bx, y + 7 + math.floor(fh / 2) - 3, barW, math.abs(t.score) / 100, t.score >= 0 and C.pos or C.neg, a, 6)
            else T.relBar(list, bx, y + 9, barW, 7, t.score, a) end
        end
        list:drawTextRight(num, nx, y + 7, tc.r, tc.g, tc.b, a, S.font)
        for i, ln in ipairs(lines) do list:drawText(ln, 16, y + 7 + fh + 6 + (i - 1) * fh, C.dim.r, C.dim.g, C.dim.b, a, S.font) end
        return y + item.height
    end
    function W.drawInteraction(list, y, item, alt)
        if not on() and not wrapOn() then return oInt(list, y, item, alt) end
        local r = item.item
        local fh, lw = T.fontH(), list:getWidth() - sbw(list)
        local lines = rowLines(list, item, tostring(r.w or ""), lw - 26, 3)
        item.height = math.max(list.itemheight, 8 + fh + 6 + #lines * fh + 8)
        T.rowBack(list, y, item, alt)
        list:drawText(T.fit(M.whenText and M.whenText(r) or tostring(r.t or ""), math.floor(lw * 0.4)), 14, y + 7, C.dim.r, C.dim.g, C.dim.b, 1, S.font)
        if r.a and r.b then
            local d = r.b - r.a
            local c = d > 0 and C.pos or (d < 0 and C.neg or C.dim)
            local txt = (d > 0 and "+" or "") .. tostring(d) .. "  " .. tostring(r.a) .. " > " .. tostring(r.b)
            local pw = F.pillW(txt)
            local px = lw - 8 - pw
            if on() then F.pill(list, px, y + 5, txt, c, 1) else list:drawTextRight(txt, lw - 8, y + 7, c.r, c.g, c.b, 1, S.font) end
            if r.m1 and r.m2 and r.m1 ~= r.m2 then
                local mood = T.fit(tostring(r.m1) .. " > " .. tostring(r.m2), math.max(0, px - 14 - math.floor(lw * 0.4) - 10))
                if mood ~= "" then list:drawTextRight(mood, px - 8, y + 7, S.amber.r, S.amber.g, S.amber.b, 1, S.font) end
            end
        end
        for i, ln in ipairs(lines) do list:drawText(ln, 16, y + 7 + fh + 6 + (i - 1) * fh, C.txt.r, C.txt.g, C.txt.b, 1, S.font) end
        return y + item.height
    end
    -- Bond timeline: card rows, date column, wrapped text
    local oHist = W.drawHist
    function W.drawHistFancy(list, y, item, alt)
        local r = item.item
        local fh, lw = T.fontH(), list:getWidth() - sbw(list)
        local dw = math.max(T.textW("Dec 30, 23:59"), T.textW("Day 999, 23:59")) + 26
        local tw = lw - dw - 12
        local c = ({ betray = S.red, fight = S.red, grudge = S.red, death = C.dim, save = C.pos, gift = C.pos, heal = C.pos, tier = C.gold,
            apology = C.blue, change = S.amber, likes = C.blue, danger = S.amber, party = C.blue })[r.kind or ""] or C.txt
        if tw < 40 then return oHist(list, y, item, alt) end
        local lines = rowLines(list, item, tostring(r.text or ""), tw, 3)
        item.height = math.max(list.itemheight, 10 + #lines * fh)
        T.rowBack(list, y, item, alt)
        list:drawRect(12, y + 5 + math.floor(fh / 2) - 2, 4, 4, 1, c.r, c.g, c.b)
        list:drawText(T.fit(tostring(r.when or ""), dw - 26), 22, y + 5, C.dim.r, C.dim.g, C.dim.b, 1, S.font)
        for i, ln in ipairs(lines) do list:drawText(ln, dw + 4, y + 5 + (i - 1) * fh, c.r, c.g, c.b, 1, S.font) end
        return y + item.height
    end
end

----------------------------------------------------------------------------------------------------------------
-- Bond tab: tier ladder, quote card, likes / dislikes as pills (offsets from UIBond fitCompute, uiFancy branch)
----------------------------------------------------------------------------------------------------------------
if W then
    local oHist2 = W.drawHist
    W.drawHist = function(list, y, item, alt)
        if on() or wrapOn() then return W.drawHistFancy(list, y, item, alt) end
        return oHist2(list, y, item, alt)
    end
    local oBond = W.drawBond
    -- pills in one row up to maxW, then "+N more" (returns the number drawn)
    local function pillRow(ui, x, y, maxW, items, c, a)
        local px, n = x, 0
        for i, it in ipairs(items) do
            local s = tostring(it.label or it)
            local pw = F.pillW(s)
            local rest = #items - i
            local moreW = rest > 0 and (T.textW("+" .. rest .. " more") + 8) or 0
            if px + pw + moreW > x + maxW then
                ui:drawText("+" .. (#items - n) .. " more", px + 2, y + 2, C.dim.r, C.dim.g, C.dim.b, a, S.font)
                return n
            end
            F.pill(ui, px, y, s, c, a)
            px = px + pw + 6; n = n + 1
        end
        if #items == 0 then ui:drawText("???", x, y + 2, C.dim.r, C.dim.g, C.dim.b, a, S.font) end
        return n
    end
    F.pillRow = pillRow
    function W:drawBond()
        if not on() or W.drawBondOld then return oBond(self) end
        local v = self.bondView
        local a = self.fade or 1
        local L = self.lay or self:fitLayout(true)
        local x, w = self.cx, self.width - self.cx - 12
        local y0 = L.y0
        local fh = T.fontH()
        local B = L.b
        if B.ladder == nil then return oBond(self) end -- layout from before the switch was flipped
        local tc = v.tier >= 4 and C.pos or (v.tier >= 2 and C.gold or C.dim)
        if M.settings.bondTiers ~= false then
            local pill = "Bond: " .. (v.tier == 1 and "acquaintances" or (v.tierWord .. "s"))
            local tw = T.badge(self, x, y0 - 2, T.fit(pill, math.floor(w / 2)), tc, a)
            local need = v.state and v.state.ask and v.state.ask.need or nil
            local num = tostring(v.standing) .. (need and (" / " .. tostring(need)) or "")
            local lab = "Standing"
            local bx = x + tw + 14 + T.textW(lab) + 8
            local barW = w - (bx - x) - T.textW(num) - 12
            if barW >= 30 then
                self:drawText(lab, x + tw + 14, y0, C.dim.r, C.dim.g, C.dim.b, a, S.font)
                F.bar(self, bx, y0 + math.floor(fh / 2) - 3, barW, (tonumber(v.standing) or 0) / 100, tc, a, 6)
            end
            self:drawTextRight(num, x + w, y0, tc.r, tc.g, tc.b, a, S.font)
            -- the ladder: acquaintance > friend > close friend > best friend > partner (where they are now in gold)
            local ly = y0 + B.ladder
            local names = {}
            local sum = 0
            for i = 1, 5 do names[i] = M.tierWord and M.tierWord(i) or tostring(i); sum = sum + T.textW(names[i]) + 16 end
            local gap = math.floor((w - sum) / 4)
            local short = gap < 10
            local segW = math.floor((w - 4 * 6) / 5)
            local px = x
            for i = 1, 5 do
                local s = names[i]
                local cw = short and segW or (T.textW(s) + 16)
                if short then s = T.fit(s, cw - 12) end
                local cc = i == v.tier and C.gold or (i < v.tier and mix(C.gold, 0.6) or C.dim)
                local hh = fh + 4
                if i == v.tier then F.rrect(self, px, ly, cw, hh, math.floor(hh / 2), mix(C.gold, 0.3, 0.95), a) end
                F.rrect(self, px, ly, cw, 1, 0, i <= v.tier and cc or C.track, a)
                self:drawText(s, px + math.floor((cw - T.textW(s)) / 2), ly + 2, cc.r, cc.g, cc.b, a, S.font)
                if i < 5 then
                    local nx = px + cw + (short and 6 or gap)
                    self:drawRect(px + cw + 2, ly + math.floor(hh / 2), math.max(1, nx - px - cw - 4), 1, a, (i < v.tier and C.gold or C.track).r,
                        (i < v.tier and C.gold or C.track).g, (i < v.tier and C.gold or C.track).b)
                    px = nx
                end
            end
            if v.hint then self:drawText(T.fit(v.hint, w), x, y0 + B.hint, C.dim.r, C.dim.g, C.dim.b, a * 0.9, S.font) end
        end
        if v.now then
            local maxW = (v.baseBtn and L.baseW) and (w - L.baseW - 8) or w
            self:drawText(T.fit(v.now, maxW), x, y0 + B.now, C.blue.r, C.blue.g, C.blue.b, a, S.font)
        end
        if v.thought then -- quote card
            local cy = y0 + B.thought
            local ch = fh * 2 + 10
            F.rrect(self, x, cy, w, ch, 5, C.card, a)
            self:drawRect(x + 6, cy + 5, 2, ch - 10, a, C.gold.r, C.gold.g, C.gold.b)
            local lines = F.wrap("\"" .. v.thought .. "\"", w - 26, S.font, 2)
            for i, ln in ipairs(lines) do self:drawText(ln, x + 16, cy + 5 + (i - 1) * fh, C.txt.r, C.txt.g, C.txt.b, a, S.font) end
        end
        if v.likes then
            local ly = y0 + B.likes
            local lab1, lab2 = "LIKES", "CAN'T STAND"
            local lw = math.max(T.textW(lab1), T.textW(lab2)) + 10
            F.header(self, x, ly + 2, lab1, C.pos, a)
            pillRow(self, x + lw, ly, w - lw, v.likes.likes or {}, C.pos, a)
            F.header(self, x, ly + fh + 8, lab2, C.neg, a)
            pillRow(self, x + lw, ly + fh + 6, w - lw, v.likes.dislikes or {}, C.neg, a)
        end
        local extra = {}
        if v.grudge then extra[#extra + 1] = { "Grudge: " .. v.grudge, S.red } end
        if v.change then extra[#extra + 1] = { "Changed: " .. v.change, S.amber } end
        if #extra > 0 then
            local s = extra[1][1]
            if #extra > 1 then s = s .. "   |   " .. extra[2][1] end
            self:drawText(T.fit(s, w), x, y0 + B.extra, extra[1][2].r, extra[1][2].g, extra[1][2].b, a, S.font)
        end
        if self.bondMsg and T.now() - (self.bondMsgAt or 0) < 15000 then
            self:drawText(T.fit(self.bondMsg, w), x, y0 + B.msg, S.amber.r, S.amber.g, S.amber.b, a, S.font)
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- the Relationships list: status pill, the dead dimmed, columns from the width
----------------------------------------------------------------------------------------------------------------
local LW = ALifeTalkRelationList
if LW and LW.drawRow then
    local oRow = LW.drawRow
    function LW.drawRow(list, y, item, alt)
        if not on() then return oRow(list, y, item, alt) end
        local n = item.item
        item.height = math.max(list.itemheight, 12 + 2 * T.fontH() + 4)
        T.rowBack(list, y, item, alt)
        local band, c = M.bandOf(n.value)
        local a = n.dead and 0.45 or 1
        local fh, lw = T.fontH(), list:getWidth() - 20
        local seen = (not n.dead and M.lastSeenOf and not n.ghost) and M.lastSeenOf(n.uid, n.record) or nil
        local away = n.ghost or (seen and seen.away)
        local st, sc = "Here", C.pos
        if n.dead then st, sc = "Dead", C.dim elseif n.nem then st, sc = "Nemesis", C.neg elseif away then st, sc = "Away", C.blue end
        if not n.dead and M.biteInfo and M.settings.biteCore ~= false then -- 0.5.2.10 [pt270u]: red "Bitten" (looked up every 2 s)
            local now = T.now()
            if now - (n._biteAt or -1e9) > 2000 then n._biteAt = now; local okB, bi = pcall(M.biteInfo, n.uid); n._bitten = okB and bi ~= nil end
            if n._bitten then st, sc = "Bitten", { r = 0.9, g = 0.25, b = 0.22 } end
        end
        local stW = F.pillW(st)
        local c1 = math.floor(lw * 0.36)
        list:drawText(T.fit(n.name, c1 - stW - 22), 14, y + 5, C.name.r, C.name.g, C.name.b, a, S.font)
        F.pill(list, math.min(14 + T.textW(T.fit(n.name, c1 - stW - 22)) + 8, c1 - stW - 4), y + 3, st, sc, a)
        local num = (n.value > 0 and "+" or "") .. tostring(n.value)
        local barX, barW = c1 + 4, math.max(40, math.floor(lw * 0.22))
        T.relBar(list, barX, y + 5 + math.floor(fh / 2) - 3, barW, 6, n.value, a)
        list:drawText(num, barX + barW + 8, y + 5, c.r, c.g, c.b, a, S.font)
        local tx = barX + barW + 16 + T.textW("+100")
        if n.tie and lw - tx > 40 then T.badge(list, tx, y + 3, T.fit(tostring(n.tie), lw - tx - 20), n.nem and C.neg or C.blue, a) end
        local ghostText = (n.ghost and not n.dead and M.bookAwayText) and M.bookAwayText(n.uid) or nil
        local sub = n.nem and n.nem.label or ghostText or (seen and seen.away and seen.text and ("Away - " .. seen.text)) or n.close or (n.last and ("Last: " .. n.last)) or band
        local subS = T.fit(tostring(sub), lw - 20)
        if subS ~= tostring(sub) then item.tooltip = tostring(sub) else item.tooltip = nil end
        local sc2 = n.nem and C.neg or C.dim
        list:drawText(subS, 14, y + 5 + fh + 4, sc2.r, sc2.g, sc2.b, a, S.font)
        return y + item.height
    end
end
