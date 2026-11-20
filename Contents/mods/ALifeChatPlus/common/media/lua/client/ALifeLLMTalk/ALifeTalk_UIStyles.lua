-- A-Life NPC Overhaul pre-1.0: WINDOW STYLES. "an option to switch between a cleanui style, the shipped a-life style,
-- and a vanilla ui style". One setting, uiStyle, changed in game (Settings tab, Interface), takes effect at once:
--   1 Overhaul - our own look (the default until pre-1.0)
--   2 A-Life   - (the default since pre-1.0) Project A-Life's own UI2 look, drawn with A-Life's real renderers (ProjectALife.UI2Chrome.window /
--                .button) in A-Life's live colours (ProjectALife.UI2Theme.admin), so it follows A-Life's own UI_Theme
--                sandbox pick (Cyber / Classic / Amber). Square corners like A-Life (UI2Theme.rule.radius = 0).
--   3 CleanUI  - CleanUI's inventory look (colours sampled from its Panel textures: grey title bar 42*0.6, near-black
--                body 229*0.05 at its background opacity, dark 2 px edge, black separator, white text, 4 px corners).
--                When CleanUI is on, its own opacity option is used (global CleanUI_getBackgroundOpacity, CleanUI 2.10.5).
--                Nothing of CleanUI is needed or shipped: shapes are drawn, no textures borrowed.
--   4 Vanilla  - ISCollapsableWindow / ISButton / ISScrollingListBox defaults (42.21 media/lua/client/ISUI): black 0.8
--                body, 0.4 grey frame, Panel_TitleBar.png title bar, centred white title, black buttons with a 0.7 frame.
-- How: every colour our windows read lives in three tables (UIStyle S, Fancy F.C, Page P.C). The style rewrites their
-- r/g/b/a IN PLACE (every file holding a reference sees it), corner radius goes through F.rrect / P.rrect, and the
-- window frame + plain buttons ask M.uiChrome / M.uiButton first (hooks in Theme.lua and UIFancy.lua).
require "ALifeLLMTalk/ALifeLLMTalk_Theme"
require "ALifeLLMTalk/ALifeLLMTalk_UIFancy"
require "ALifeLLMTalk/ALifeLLMTalk_UIPage"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.UIStyle) ~= "table" or type(M.Theme) ~= "table" then return end
local S, T = M.UIStyle, M.Theme
local F = M.Fancy
local P = M.Page

local St = {}
M.UIStyles = St
St.KEYS = { "overhaul", "alife", "cleanui", "vanilla" }
St.NAMES = { "Overhaul", "A-Life", "CleanUI", "Vanilla" }
-- look numbers (defaults; edit here or via M.uiStyleCfg before a window opens)
M.uiStyleCfg = M.uiStyleCfg or {}
local CFG = M.uiStyleCfg
local function cfg(k, v) if CFG[k] == nil then CFG[k] = v end end
cfg("cleanRadius", 4)          -- CleanUI corner radius (px)
cfg("cleanOpacity", 0.65)      -- CleanUI body opacity when CleanUI itself is not on (its own default)
cfg("cleanMinOpacity", 0.5)    -- never thinner than this (text-heavy windows)
cfg("vanillaOpacity", 0.8)     -- ISCollapsableWindow backgroundColor.a

-- setting: default + saved in the settings file (registered at load, before OnGameStart reads the file)
M.settings = M.settings or {}
if M.settings.uiStyle == nil then M.settings.uiStyle = 2 end -- pre-1.0 (Joe): the default look matches A-Life
M.fileKeys = M.fileKeys or {}
do
    local have = false
    for _, k in ipairs(M.fileKeys) do if k == "uiStyle" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "uiStyle" end
end
if type(M.settingRows) == "table" then
    local have = false
    for _, r in ipairs(M.settingRows) do if r[1] == "uiStyle" then have = true end end
    if not have then
        M.settingRows[#M.settingRows + 1] = { "uiStyle",
            "Window style: Overhaul (ours), A-Life (A-Life's own look and colours), CleanUI, or Vanilla", { 1, 2, 3, 4 }, St.NAMES }
    end
end
M.settingCatOf = M.settingCatOf or {}
if M.settingCatOf.uiStyle == nil then M.settingCatOf.uiStyle = "Interface and immersion" end

function St.index()
    local v = math.floor(tonumber(M.settings and M.settings.uiStyle) or 2)
    if v < 1 or v > #St.KEYS then v = 2 end
    return v
end
function St.id() return St.KEYS[St.index()] end

----------------------------------------------------------------------------------------------------------------
-- palettes
----------------------------------------------------------------------------------------------------------------
local function rgba(r, g, b, a) return { r = r, g = g, b = b, a = a } end
local function from(c, a) if type(c) ~= "table" then return nil end return { r = c.r, g = c.g, b = c.b, a = a or c.a } end
local function snap(t)
    local o = {}
    if type(t) ~= "table" then return o end
    for k, v in pairs(t) do
        if type(v) == "table" and type(v.r) == "number" then o[k] = { r = v.r, g = v.g, b = v.b, a = v.a } end
    end
    return o
end
St.orig = { S = snap(S), F = snap(F and F.C), P = snap(P and P.C) }

local function write(t, src, keepA)
    if type(t) ~= "table" then return end
    for k, c in pairs(src) do
        local d = t[k]
        if type(d) == "table" and type(c) == "table" and c.r ~= nil then
            d.r, d.g, d.b = c.r, c.g, c.b
            if not keepA or c.a ~= nil then d.a = c.a end
        end
    end
end

-- one semantic set (b) -> the three tables. Missing entries keep the Overhaul colour.
local function spread(b)
    local s = { bg = b.bg, panel = b.panel, header = b.header, border = b.border, borderDim = b.borderDim, text = b.text,
        dim = b.dim, accent = b.accent, hover = b.hover, select = b.select, rowAlt = b.rowAlt, barBack = b.track,
        green = b.pos, red = b.neg }
    local f = { bg = b.bg, card = b.card, cardHi = b.cardHi, gold = b.accent, txt = b.text, dim = b.dim, track = b.track,
        border = b.border, divider = b.divider, name = b.name, pos = b.pos, neg = b.neg }
    local p = { bg = b.bg, gold = b.accent, txt = b.text, dim = b.dim, track = b.track, border = b.border,
        divider = b.divider, name = b.name, pos = b.pos, neg = b.neg }
    return { S = s, F = f, P = p }
end

local function alifeTheme()
    local PA = ProjectALife
    return type(PA) == "table" and type(PA.UI2Theme) == "table" and type(PA.UI2Theme.admin) == "table" and PA.UI2Theme or nil
end

function St.cleanOpacity()
    local v = nil
    if type(CleanUI_getBackgroundOpacity) == "function" then
        local ok, r = pcall(CleanUI_getBackgroundOpacity)
        if ok then v = tonumber(r) end
    end
    v = v or CFG.cleanOpacity
    return math.max(CFG.cleanMinOpacity, math.min(1, v))
end

St.build = {}
function St.build.alife()
    local th = alifeTheme()
    if th == nil then return nil end
    local A = th.admin
    if A.panel == nil or A.text == nil or A.accent == nil then return nil end
    return spread({
        bg = from(A.panel, 0.96), panel = from(A.card, 0.92), header = from(A.card, 0.98), border = from(A.frame or A.border, 1),
        borderDim = from(A.border, 0.85), text = from(A.text, 1), dim = from(A.muted or A.text, 1), accent = from(A.accent, 1),
        hover = from(A.rowHover or A.card, 0.6), select = from(A.rowOn or A.accent, 0.75), rowAlt = from(A.row or A.card, 0.35),
        track = from(A.control or A.card, 1), card = from(A.card, 0.92), cardHi = from(A.controlOver or A.card, 0.95),
        divider = from(A.border, 1), name = from(A.text, 1), pos = from(A.good, 1), neg = from(A.bad, 1),
    })
end
function St.build.cleanui()
    local op = St.cleanOpacity()
    return spread({
        bg = rgba(0.045, 0.045, 0.045, op), panel = rgba(0.08, 0.08, 0.08, 0.85), header = rgba(0.10, 0.10, 0.10, 0.95),
        border = rgba(0.12, 0.12, 0.12, 1), borderDim = rgba(0.40, 0.40, 0.40, 0.7), text = rgba(1, 1, 1, 1),
        dim = rgba(0.62, 0.62, 0.62, 1), accent = rgba(0.88, 0.88, 0.88, 1), hover = rgba(1, 1, 1, 0.10),
        select = rgba(1, 1, 1, 0.16), rowAlt = rgba(1, 1, 1, 0.03), track = rgba(0.16, 0.16, 0.16, 1),
        card = rgba(0.09, 0.09, 0.09, 0.80), cardHi = rgba(0.16, 0.16, 0.16, 0.90), divider = rgba(0, 0, 0, 1),
        name = rgba(1, 1, 1, 1),
    })
end
function St.build.vanilla()
    local op = CFG.vanillaOpacity
    return spread({
        bg = rgba(0, 0, 0, op), panel = rgba(0, 0, 0, op), header = rgba(0, 0, 0, op), border = rgba(0.4, 0.4, 0.4, 1),
        borderDim = rgba(0.4, 0.4, 0.4, 0.9), text = rgba(1, 1, 1, 1), dim = rgba(0.7, 0.7, 0.7, 1), accent = rgba(1, 1, 1, 1),
        hover = rgba(1, 1, 1, 0.1), select = rgba(0.7, 0.35, 0.15, 0.3), rowAlt = rgba(0.2, 0.3, 0.2, 0.1),
        track = rgba(0.15, 0.15, 0.15, 1), card = rgba(0, 0, 0, 0.6), cardHi = rgba(0.3, 0.3, 0.3, 1),
        divider = rgba(0.4, 0.4, 0.4, 1), name = rgba(1, 1, 1, 1),
    })
end

St.applied, St.alifeId, St.cleanOp = nil, nil, nil
function St.apply(id)
    id = id or St.id()
    write(S, St.orig.S, false)
    if F and F.C then write(F.C, St.orig.F, false) end
    if P and P.C then write(P.C, St.orig.P, false) end
    local b = St.build[id]
    local pal = b and b() or nil
    if pal then
        write(S, pal.S, true)
        if F and F.C then write(F.C, pal.F, true) end
        if P and P.C then write(P.C, pal.P, true) end
    elseif id ~= "overhaul" then
        id = "overhaul" -- A-Life theme missing: our look, not a broken one
    end
    St.applied = id
    local th = alifeTheme()
    St.alifeId = th and th.id or nil
    St.cleanOp = id == "cleanui" and St.cleanOpacity() or nil
    return id
end
-- cheap per-frame check: setting changed, A-Life switched its theme, CleanUI opacity moved
St.checkedAt = 0
function St.sync()
    local want = St.id()
    if St.applied ~= want and not (St.applied == "overhaul" and St.failedFor == want) then
        local got = St.apply(want)
        St.failedFor = got ~= want and want or nil
        return St.applied
    end
    local now = T.now()
    if now - St.checkedAt < 1000 and now >= St.checkedAt then return St.applied end -- outside checks once a second
    St.checkedAt = now
    if want == "alife" and St.applied == "alife" then
        local th = alifeTheme()
        if th and th.id ~= St.alifeId then St.apply("alife") end
    elseif want == "cleanui" and St.cleanOp ~= St.cleanOpacity() then
        St.apply("cleanui")
    end
    return St.applied
end

----------------------------------------------------------------------------------------------------------------
-- shape: corner radius per style
----------------------------------------------------------------------------------------------------------------
function St.radius(r)
    local id = St.applied or "overhaul"
    if id == "overhaul" then return r end
    if id == "cleanui" then return math.min(r or 4, CFG.cleanRadius) end
    return 0
end
local function wrapRR(tbl)
    if type(tbl) ~= "table" or type(tbl.rrect) ~= "function" or tbl._uiStyleRR then return end
    local o = tbl.rrect
    tbl.rrect = function(ui, x, y, w, h, r, c, a) return o(ui, x, y, w, h, St.radius(r), c, a) end
    tbl._uiStyleRR = true
end
wrapRR(F)
wrapRR(P)

----------------------------------------------------------------------------------------------------------------
-- window frame (ALifeLLMTalkWindow and everything derived). Returns true when it drew the frame.
----------------------------------------------------------------------------------------------------------------
local function rr(ui, x, y, w, h, r, c, a)
    if F and F.rrect then return F.rrect(ui, x, y, w, h, r, c, a) end
    ui:drawRect(x, y, w, h, (c.a or 1) * (a or 1), c.r, c.g, c.b)
end
local function fontH(f) return T.fontH(f) end
local titleTex = nil
local function vanillaTitleTex()
    if titleTex == nil then
        titleTex = false
        pcall(function() titleTex = getTexture("media/ui/Panel_TitleBar.png") or false end)
    end
    return titleTex or nil
end

St.chrome = {}
function St.chrome.alife(win, a)
    local PA = ProjectALife
    local Ch = PA and PA.UI2Chrome
    local th = alifeTheme()
    if Ch == nil or type(Ch.window) ~= "function" or th == nil then return false end
    local ok = pcall(Ch.window, win, 0, 0, win.width, win.height, a)
    if not ok then return false end
    local hh = S.headerH
    local K = nil
    pcall(function() K = th.skin("chrome") end)
    local tc = (K and K.optLight) or S.text
    local title = tostring(win.title or "")
    pcall(function() title = th.caseText(title) end)
    win:drawText(T.fit(title, win.width - 60, S.fontTitle), 14, math.floor((hh - fontH(S.fontTitle)) / 2) + 2, tc.r, tc.g, tc.b, a, S.fontTitle)
    local ln = (K and K.line) or S.borderDim
    win:drawRect(10, hh, win.width - 20, 1, a, ln.r, ln.g, ln.b)
    return true
end
function St.chrome.cleanui(win, a)
    local w, h, hh = win.width, win.height, S.headerH
    local r = CFG.cleanRadius
    rr(win, 0, 0, w, h, r, { r = S.border.r, g = S.border.g, b = S.border.b, a = math.max(S.bg.a or 1, 0.9) }, a)
    rr(win, 2, 2, w - 4, h - 4, math.max(0, r - 1), S.bg, a)
    rr(win, 0, 0, w, hh, r, S.header, a)                                         -- title bar: round top
    win:drawRect(0, hh - r, w, r, (S.header.a or 1) * a, S.header.r, S.header.g, S.header.b) -- square bottom
    win:drawRect(r, 0, w - 2 * r, 1, 0.5 * a, 0.18, 0.18, 0.18)                  -- top highlight (75*0.6)
    win:drawRect(0, hh, w, 1, a, 0, 0, 0)                                         -- black separator
    win:drawText(T.fit(tostring(win.title or ""), w - 60, S.font), 10, math.floor((hh - fontH(S.font)) / 2), 1, 1, 1, a, S.font)
    return true
end
function St.chrome.vanilla(win, a)
    local w, h, hh = win.width, win.height, S.headerH
    local bg, bd = S.bg, S.border
    win:drawRect(0, 0, w, h, (bg.a or 1) * a, bg.r, bg.g, bg.b)
    local tex = vanillaTitleTex()
    if tex then win:drawTextureScaled(tex, 2, 1, w - 4, hh - 2, a, 1, 1, 1) end
    win:drawRectBorder(0, 0, w, hh, (bd.a or 1) * a, bd.r, bd.g, bd.b)
    win:drawRectBorder(0, 0, w, h, (bd.a or 1) * a, bd.r, bd.g, bd.b)
    win:drawTextCentre(T.fit(tostring(win.title or ""), w - 60, S.font), w / 2, math.floor((hh - fontH(S.font)) / 2), 1, 1, 1, a, S.font)
    return true
end
function M.uiChrome(win, a)
    local id = St.sync()
    local f = id and St.chrome[id]
    if f == nil then return false end
    local ok, drew = pcall(f, win, a or 1)
    return ok and drew == true
end

----------------------------------------------------------------------------------------------------------------
-- plain buttons (Theme.styleButton ones; the fancy tab strip keeps its own text-only look)
----------------------------------------------------------------------------------------------------------------
local function tint(c, k) return { r = c.r * k, g = c.g * k, b = c.b * k, a = 1 } end
St.button = {}
function St.button.alife(b, a, hot, en)
    local Ch = ProjectALife and ProjectALife.UI2Chrome
    local th = alifeTheme()
    if Ch == nil or type(Ch.button) ~= "function" or th == nil then return false end
    local w, h = b:getWidth(), b:getHeight()
    if not pcall(Ch.button, b, 0, 0, w, h, "", nil, hot, a, b.font, not en) then return false end -- frame only; ISButton:render writes the title
    local K = nil
    pcall(function() K = th.skin("chrome") end)
    local c = K and (hot and K.optLight or K.optCyan) or S.text
    b.textColor = { r = c.r, g = c.g, b = c.b, a = en and 1 or 0.45 }
    return true
end
function St.button.cleanui(b, a, hot, en)
    local w, h = b:getWidth(), b:getHeight()
    local br = hot and 0.24 or 0.13
    local edge = b.fancyAccent and tint(b.fancyAccent, 0.75) or { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    rr(b, 0, 0, w, h, 3, edge, a * (en and 1 or 0.5))
    rr(b, 1, 1, w - 2, h - 2, 2, { r = br, g = br, b = br, a = 0.95 }, a)
    b.textColor = en and { r = 1, g = 1, b = 1, a = 1 } or { r = 0.6, g = 0.6, b = 0.6, a = 0.8 }
    return true
end
local VB = { bg = { r = 0, g = 0, b = 0, a = 1.0 }, over = { r = 0.3, g = 0.3, b = 0.3, a = 1.0 }, edge = { r = 0.7, g = 0.7, b = 0.7, a = 1 },
    txt = { r = 1, g = 1, b = 1, a = 1 }, off = { r = 0.6, g = 0.6, b = 0.6, a = 1 } } -- ISButton:new defaults (42.21)
function St.button.vanilla(b, a, hot, en)
    -- the real ISButton look: its own prerender with the stock colours
    if b._uiVanilla == nil then -- keep the button's own colours (back when the style changes) + its own copies
        b._uiVanilla = { b.backgroundColor, b.backgroundColorMouseOver, b.borderColor,
            { r = 0, g = 0, b = 0, a = 1 }, { r = 0.3, g = 0.3, b = 0.3, a = 1 }, { r = 0.7, g = 0.7, b = 0.7, a = 1 } }
    end
    local v = b._uiVanilla
    v[4].r, v[4].g, v[4].b, v[4].a = VB.bg.r, VB.bg.g, VB.bg.b, VB.bg.a
    v[5].r, v[5].g, v[5].b, v[5].a = VB.over.r, VB.over.g, VB.over.b, VB.over.a
    v[6].r, v[6].g, v[6].b, v[6].a = VB.edge.r, VB.edge.g, VB.edge.b, VB.edge.a
    b.backgroundColor, b.backgroundColorMouseOver, b.borderColor = v[4], v[5], v[6]
    b.textColor = en and VB.txt or VB.off
    if ISButton and ISButton.prerender then ISButton.prerender(b) end
    return true
end
function M.uiButton(b)
    local id = St.sync()
    if id ~= "vanilla" and b._uiVanilla ~= nil then -- left Vanilla: the button's own colours again
        b.backgroundColor, b.backgroundColorMouseOver, b.borderColor = b._uiVanilla[1], b._uiVanilla[2], b._uiVanilla[3]
        b._uiVanilla = nil
    end
    local f = id and St.button[id]
    if f == nil then
        if b._uiTxt ~= nil then b.textColor = b._uiTxt or b.textColor; b._uiTxt = nil end
        return false
    end
    if b._uiTxt == nil then b._uiTxt = b.textColor or false end
    local en = b.enable ~= false
    local hot = false
    pcall(function() hot = en and b:isMouseOver() == true end)
    local a = (b.parent and b.parent.fade) or 1
    local ok, drew = pcall(f, b, a, hot, en)
    return ok and drew == true
end

St.apply(St.id())
print("[ALifeUIStyles] ready pre-1.0: window styles " .. table.concat(St.NAMES, " / ") .. " (uiStyle=" .. tostring(St.id()) .. ")")
return St
