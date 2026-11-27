-- A-Life NPC Overhaul 0.7.0: THE A-LIFE WINDOW. One window, tabs, for everything (ours, Jeem's and A-Life's):
--   Now     what needs you and what changed: decisions waiting, who's away, traders at your place, the camp's notes
--   People  a journal of everyone you know: only what you've learned over time (their name once they told you, what
--           they said and did, how they seem toward you, when and where you last saw them, where they said they were
--           going). Their avatar: live when they're near, otherwise as you remember them. Orders from their page, and
--           orders to many at once (tick them in the list).
--   Party, Camp (the camp board, the camp menus, Jeem's base and residents), Trade, World (journal, war map),
--   Radio (ours and Jeem's walkies), Settings, Help (every feature in short).
-- The right-click and radial menus stay as shortcuts. Menus are not copied: the buttons open the very same menus
-- (ours, and Jeem's own entries in the same order Jeem shows them), so the window can never disagree with them.
-- Every page fits the screen, scrolls, can be resized from its bottom-right corner, and uses a bigger font on big
-- screens. The first time you open a tab you get a short tip (Help > "Show the tips again").
-- Performance: a page refreshes only while it's open (every 2 s); one 3D avatar at a time.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local T, S = M.Theme, M.UIStyle
if T == nil or ALifeLLMTalkWindow == nil then return end

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
local function esc(s) s = tostring(s or ""); s = string.gsub(s, "<", "("); s = string.gsub(s, ">", ")"); return s end
local GOLD, TXT, DIM, RED = " <RGB:0.84,0.7,0.38> ", " <RGB:0.87,0.88,0.9> ", " <RGB:0.55,0.56,0.6> ", " <RGB:0.92,0.45,0.35> "
local function head(t) return " <LINE> " .. GOLD .. esc(string.upper(t)) .. TXT .. " <LINE> " end
local function font() return M.qolFont and M.qolFont("auto") or UIFont.Small end
local function fontH(f) local h = 16; pcall(function() h = getTextManager():getFontHeight(f) end); return h end
local function textW(t, f) local w = 8 * #tostring(t); pcall(function() w = getTextManager():MeasureStringX(f, tostring(t)) end); return w end

----------------------------------------------------------------------------------------------------------------
-- menus: open the same menus the right-click shows (ours and Jeem's), at a button
----------------------------------------------------------------------------------------------------------------
local function squareObjects(player)
    local list = {}
    pcall(function()
        local objs = player:getCurrentSquare():getObjects()
        for i = 0, objs:size() - 1 do list[#list + 1] = objs:get(i) end
    end)
    return list
end
local function menuAt(win, btn)
    local x, y = getMouseX(), getMouseY()
    pcall(function() x, y = win:getAbsoluteX() + btn:getX(), win:getAbsoluteY() + btn:getY() + btn:getHeight() end)
    return ISContextMenu.get(0, x, y)
end
-- our right-click parts by id (camp, workzones, radio, tradingpost, namedplaces, ...)
function M.winFill(cm, ids)
    local p = playerOf()
    if p == nil or type(ALifeRadial) ~= "table" then return 0 end
    local objs = squareObjects(p)
    local n = 0
    for _, e in ipairs(ALifeRadial.fillers or {}) do
        for _, id in ipairs(ids) do
            if e.id == id and type(e.fn) == "function" then pcall(e.fn, 0, cm, objs, false); n = n + 1 end
        end
    end
    return n
end
-- Jeem's own entries (its menu providers), the ones in `orders`, in Jeem's order
function M.winJeem(cm, orders)
    local j = J()
    local menu = j and j.Menu
    if type(menu) ~= "table" or type(menu.providers) ~= "table" then return 0 end
    local p = playerOf()
    local want = {}
    for _, o in ipairs(orders) do want[o] = true end
    local ctx = { menu = cm, player = p, playerNum = 0, worldObjects = squareObjects(p), square = p and p:getCurrentSquare() or nil }
    function ctx.debug() return nil end
    local list = {}
    for _, pr in ipairs(menu.providers) do if want[pr.order] then list[#list + 1] = pr end end
    table.sort(list, function(a, b) return a.order < b.order end)
    local n = 0
    for _, pr in ipairs(list) do if pcall(pr.fn, ctx) then n = n + 1 end end
    return n
end
local function hasJeem() local j = J(); return j ~= nil and type(j.Menu) == "table" and type(j.Menu.providers) == "table" end

----------------------------------------------------------------------------------------------------------------
-- the page: a window that fits the screen, resizes from its corner, scrolls, buttons that wrap
----------------------------------------------------------------------------------------------------------------
ALifeTalkHubPage = ALifeLLMTalkWindow:derive("ALifeTalkHubPage")
local HP = ALifeTalkHubPage
HP.grip = 14
function HP:new(title)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.floor(math.min(sw - 40, math.max(520, M.uiPref and M.uiPref("hub.w", math.floor(sw * 0.55)) or 820)))
    local h = math.floor(math.min(sh - 60, math.max(380, M.uiPref and M.uiPref("hub.h", math.floor(sh * 0.7)) or 620)))
    local o = ALifeLLMTalkWindow.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h, title)
    return o
end
function HP:createChildren()
    ALifeLLMTalkWindow.createChildren(self)
    self.font = font()
    self.body = ISRichTextPanel:new(10, self:contentTop(), self.width - 20, 100)
    self.body:initialise()
    self.body.background = false
    self.body.autosetheight = false
    self.body.clip = true
    self.body.defaultFont = self.font
    self.body.marginLeft, self.body.marginRight = 8, 14
    self:addChild(self.body)
    self.body:addScrollBars()
    -- pre-1.0: a click on the body hands the text of the line under the mouse to win:onBodyClick (fold headings)
    self.body.onMouseUp = function(panel, x, y)
        local win = panel.parent
        if win and win.onBodyClick then
            local line = HP.lineAt(panel, y)
            if line then local ok, err = pcall(win.onBodyClick, win, line); if not ok then print("[ALifeWindow] body click failed: " .. tostring(err)) end end
        end
        return ISRichTextPanel.onMouseUp(panel, x, y)
    end
    self.buttons = {}
    self:buildButtons()
    self:layout()
    self:refresh()
    self:firstTip()
end
-- the whole text of the rich-text line at panel y (ISRichTextPanel keeps lines[] + lineY[] after paginate), or nil
function HP.lineAt(panel, y)
    if type(panel.lines) ~= "table" or type(panel.lineY) ~= "table" then return nil end
    local sc = 0
    pcall(function() sc = panel:getYScroll() end)
    local cy = y - (panel.marginTop or 0) - sc
    local hitY = nil
    for c = 1, #panel.lines do
        local ly = panel.lineY[c]
        if type(ly) == "number" and ly <= cy and (hitY == nil or ly > hitY) then hitY = ly end
    end
    if hitY == nil then return nil end
    local parts = {}
    for c = 1, #panel.lines do
        if panel.lineY[c] == hitY then
            local s = string.gsub(tostring(panel.lines[c] or ""), "^%s+", "")
            s = string.gsub(s, "%s+$", "")
            if s ~= "" then parts[#parts + 1] = s end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end
-- override: { { label, fn(win, btn), show? } }
function HP:actions() return {} end
function HP:buildButtons()
    for _, b in ipairs(self.buttons or {}) do pcall(function() self:removeChild(b) end) end
    self.buttons = {}
    for _, a in ipairs(self:actions()) do
        if a.show == nil or a.show() then
            local b = ISButton:new(0, 0, textW(a.label, self.font) + 20, fontH(self.font) + 10, a.label, self, function(win, btn) local ok, err = pcall(a.fn, win, btn); if not ok then print("[ALifeWindow] button failed: " .. tostring(err)) end end)
            b:initialise(); b:instantiate()
            b.font = self.font
            if a.tip then b.tooltip = a.tip end
            T.styleButton(b, a.accent and S.accent or nil)
            self:addChild(b)
            self.buttons[#self.buttons + 1] = b
        end
    end
end
-- buttons wrap into rows at the bottom; the body fills the rest
function HP:layoutButtons(x0, x1, bottom)
    local rows, row, x = {}, {}, x0
    for _, b in ipairs(self.buttons) do
        if x + b:getWidth() > x1 and #row > 0 then rows[#rows + 1] = row; row = {}; x = x0 end
        row[#row + 1] = b; x = x + b:getWidth() + 6
    end
    if #row > 0 then rows[#rows + 1] = row end
    local bh = fontH(self.font) + 10
    local y = bottom - #rows * (bh + 6)
    for i, r in ipairs(rows) do
        local xx = x0
        for _, b in ipairs(r) do b:setX(xx); b:setY(y + (i - 1) * (bh + 6)); xx = xx + b:getWidth() + 6 end
    end
    return y
end
function HP:layout()
    local top = self:contentTop()
    local by = self:layoutButtons(10, self.width - 10, self.height - HP.grip)
    self.body:setX(10); self.body:setY(top)
    self.body:setWidth(self.width - 20); self.body:setHeight(math.max(40, by - top - 6))
    pcall(function() self.body:updateScrollbars() end)
    if self.layoutMore then self:layoutMore(top, by) end
end
function HP:text() return "" end
function HP:refresh()
    local y = 0
    pcall(function() y = self.body:getYScroll() end)
    local ok, txt = pcall(self.text, self)
    self.body.text = ok and txt or (RED .. "Couldn't read this page: " .. esc(txt))
    self.body:paginate()
    pcall(function() self.body:setYScroll(y) end)
    self.refreshedAt = now()
end
function HP:update()
    ALifeLLMTalkWindow.update(self)
    if now() - (self.refreshedAt or 0) > 2000 then pcall(self.refresh, self) end
end
-- resize from the bottom-right corner
function HP:onMouseDown(x, y)
    if x >= self.width - HP.grip and y >= self.height - HP.grip then self.resizing = true; self:setCapture(true); return true end
    return ALifeLLMTalkWindow.onMouseDown(self, x, y)
end
function HP:resizeBy(dx, dy)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self:setWidth(math.max(480, math.min(sw - self:getX(), self.width + dx)))
    self:setHeight(math.max(320, math.min(sh - self:getY(), self.height + dy)))
    self:layout()
end
function HP:onMouseMove(dx, dy) if self.resizing then self:resizeBy(dx, dy); return true end; return ALifeLLMTalkWindow.onMouseMove(self, dx, dy) end
function HP:onMouseMoveOutside(dx, dy) if self.resizing then self:resizeBy(dx, dy); return true end; return ALifeLLMTalkWindow.onMouseMoveOutside(self, dx, dy) end
function HP:stopResize()
    if not self.resizing then return end
    self.resizing = false
    self:setCapture(false)
    if M.uiSet then M.uiSet("hub.w", math.floor(self.width)); M.uiSet("hub.h", math.floor(self.height)) end
    self:buildButtons(); self:layout()
    pcall(function() self.body:paginate() end)
end
function HP:onMouseUp(x, y) if self.resizing then self:stopResize(); return true end; return ALifeLLMTalkWindow.onMouseUp(self, x, y) end
function HP:onMouseUpOutside(x, y) if self.resizing then self:stopResize(); return true end; return ALifeLLMTalkWindow.onMouseUpOutside(self, x, y) end
function HP:render()
    ALifeLLMTalkWindow.render(self)
    local g = HP.grip
    for i = 1, 3 do self:drawRect(self.width - 4 - i * 4, self.height - 4, 2, 2, 0.6, 0.84, 0.7, 0.38); self:drawRect(self.width - 4, self.height - 4 - i * 4, 2, 2, 0.6, 0.84, 0.7, 0.38) end
end
-- the first time a tab is opened: a short tip
HP.tipText = nil
function HP:firstTip()
    if self.tipId == nil or self.tipText == nil or M.uiPref == nil then return end
    if M.settings.firstTips == false or M.uiPref("tip." .. self.tipId, false) then return end
    M.uiSet("tip." .. self.tipId, true)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = math.min(560, sw - 40), math.min(260, sh - 40)
    local modal = ISModalRichText:new((sw - w) / 2, (sh - h) / 2, w, h, self.tipText, false)
    modal:initialise(); modal:addToUIManager()
end
function HP:close()
    if self.onPageClose then pcall(self.onPageClose, self) end
    ALifeLLMTalkWindow.close(self)
end
local function page(className, title, tipId, tipText)
    local P = HP:derive(className)
    P.tipId, P.tipText = tipId, tipText
    P.pageTitle = title
    function P:new() return HP.new(self, title) end
    return P
end
local function openPage(P, key)
    if M[key] then pcall(function() M[key]:close() end) end
    local w = P:new()
    T.open(w)
    M[key] = w
    local old = w.close
    w.onPageClose = function() if M[key] == w then M[key] = nil end end
    return w
end

----------------------------------------------------------------------------------------------------------------
-- NOW
----------------------------------------------------------------------------------------------------------------
local NowPage = page("ALifeTalkNowPage", "Now", "now",
    tr("TipNow", "<SIZE:medium> Now <LINE> <SIZE:small> What needs you and what changed: decisions waiting for you, who's away, traders at your place, and the camp's own notes. Nothing here is a live readout: it's what you'd know."))
local function tagWord(tag)
    return ({ search = "out searching", trip = "on the way back home", caravan = "on the road", caravan_home = "on the road home",
        caravan_out = "on a trade run", nomads = "moving on", place = "on their way to a place you named" })[tag] or "away"
end
NowPage.SORTS = { "name", "doing" }
function NowPage.sortMode()
    local m = M.uiPref and M.uiPref("now.sort", "name") or "name"
    if m ~= "doing" then m = "name" end
    return m
end
function NowPage:text()
    local p = playerOf()
    local out = {}
    -- decisions waiting
    local q = (M.momQueue and #M.momQueue or 0) + (M.momOpen and 1 or 0)
    if q > 0 then out[#out + 1] = head(tr("NowDecisions", "Waiting on you")) .. RED .. (q == 1 and "A decision is waiting for you." or (q .. " decisions are waiting for you.")) .. TXT .. " <LINE> " end
    -- your people away
    local rows = {}
    local leavers = M.lvMem and M.lvMem.leavers or {}
    for uid, L in pairs(leavers) do
        if fn(M, "cpIsHome") and M.cpIsHome(uid, p) then rows[#rows + 1] = { name = tostring(M.qolName(uid)), what = tagWord(L.tag) } end
    end
    for uid, o in pairs(M.qolStore and M.qolStore().plOrders or {}) do
        local pl = M.plGet(o.place)
        if pl then rows[#rows + 1] = { name = tostring(M.qolName(uid)), what = (o.mode == "hold" and "holding " or "waiting for you at ") .. tostring(pl.name) } end
    end
    -- pre-1.0: sortable (long games: a long list). Button "Sort" cycles name / doing; kept between sessions.
    local mode = NowPage.sortMode()
    table.sort(rows, function(a, b)
        local ka, kb = a.name, b.name
        if mode == "doing" and a.what ~= b.what then ka, kb = a.what, b.what end
        ka, kb = string.lower(ka), string.lower(kb)
        if ka == kb then return string.lower(a.name) < string.lower(b.name) end
        return ka < kb
    end)
    local away = {}
    for _, r in ipairs(rows) do away[#away + 1] = esc(r.name) .. ": " .. esc(r.what) end
    if #away > 0 then out[#out + 1] = head(tr("NowAway", "Away")) .. table.concat(away, " <LINE> ") .. " <LINE> " end
    -- traders here
    local here = {}
    for _, v in pairs((M.nbStore and M.nbStore().ovVisits) or {}) do
        here[#here + 1] = esc(tostring(v.name or "Traders")) .. " are at your place (" .. #(v.uids or {}) .. " of them)"
    end
    pcall(function()
        local data = J() and J().TraderStock and J().TraderStock.data()
        for _, vv in pairs((data and data.visits) or {}) do if type(vv) == "table" and vv.state ~= "gone" then here[#here + 1] = "A trader is visiting your base" end end
    end)
    if #here > 0 then out[#out + 1] = head(tr("NowHere", "At your place")) .. table.concat(here, " <LINE> ") .. " <LINE> " end
    -- what switched off
    if type(ALifeHealth) == "table" and #(ALifeHealth.offs or {}) > 0 then
        out[#out + 1] = head(tr("NowHealth", "Switched off after an error")) .. DIM .. tr("NowHealthHow", "Send console.txt and Zomboid/Lua/ALifeChatPlus_health.txt to the mod author.") .. TXT .. " <LINE> "
        local seen = {}
        for _, o in ipairs(ALifeHealth.offs) do if not seen[o.feature] then seen[o.feature] = true; out[#out + 1] = esc(o.feature) .. " <LINE> " end end
    end
    -- 0.7.0.1: what popped up on screen (gone too fast to read? it's here)
    local nts = M.ntRows and M.ntRows(6) or {}
    if #nts > 0 then
        out[#out + 1] = head(tr("NowNotices", "On screen lately"))
        for _, n in ipairs(nts) do out[#out + 1] = DIM .. esc(n.when) .. TXT .. "  " .. (n.bad and RED or "") .. esc(n.text) .. TXT .. " <LINE> " end
    end
    -- the camp's notes
    out[#out + 1] = head(tr("NowLately", "Lately"))
    out[#out + 1] = M.elText and M.elText(8) or ""
    return table.concat(out)
end
function NowPage:actions()
    local out = {}
    -- 0.7.0.1: the quick orders (the same as the quick wheel and the quick-order bar)
    for _, q in ipairs(M.qoOrders or {}) do
        if q.who ~= "person" then
            out[#out + 1] = { label = tr("Order_" .. q.id, q.label), accent = true,
                show = function() local ok, res = pcall(function() return q.ok == nil or q.ok() end); return ok and res == true end,
                fn = function() local ok = M.qoRun(q.id); if M.momToast then M.momToast(ok and tr("Order_" .. q.id, q.label) or tr("OrderNot", "Nobody took that order.")) end end }
        end
    end
    if fn(M, "plAsk") then
        out[#out + 1] = { label = tr("BtnNameSpot", "Name this spot"), fn = function()
            local p = playerOf(); if p then M.plAsk(math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())) end end }
    end
    out[#out + 1] = { label = tr("BtnSort", "Sort: ") .. (NowPage.sortMode() == "doing" and tr("SortDoing", "what they do") or tr("SortName", "name")),
        tip = tr("TipSort", "Sort the Away list by name, or by what they are doing."),
        fn = function(win)
            if M.uiSet then M.uiSet("now.sort", NowPage.sortMode() == "name" and "doing" or "name") end
            win:buildButtons(); win:layout(); win:refresh()
        end }
    for _, a in ipairs(NowPage.moreActions()) do out[#out + 1] = a end
    return out
end
function NowPage.moreActions()
    return {
        { label = tr("BtnNotices", "Missed something?"), fn = function() M.winNotices() end },
        { label = tr("BtnLog", "The camp's notes"), fn = function() M.winLog() end },
        { label = tr("BtnWidget", "Camp widget on/off"), fn = function() if M.wgShown("widget") then M.wgClose("widget") else M.wgOpen("widget") end end },
        { label = tr("BtnQuick", "Quick orders on/off"), fn = function() if M.wgShown("quick") then M.wgClose("quick") else M.wgOpen("quick") end end },
        { label = tr("BtnJeemStatus", "Jeem status"), show = hasJeem, fn = function(win, btn) local cm = menuAt(win, btn); M.winJeem(cm, { 10 }) end },
    }
end
function M.winNotices()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = math.min(620, sw - 40), math.min(560, sh - 60)
    local lines = {}
    for _, n in ipairs(M.ntRows and M.ntRows() or {}) do lines[#lines + 1] = DIM .. esc(n.when) .. TXT .. "  " .. (n.bad and RED or "") .. esc(n.text) .. TXT end
    if #lines == 0 then lines[1] = DIM .. tr("NoticesNone", "Nothing has popped up on screen yet this session.") .. TXT end
    local modal = ISModalRichText:new((sw - w) / 2, (sh - h) / 2, w, h, "<SIZE:medium> " .. tr("NoticesTitle", "What you might have missed") .. " <LINE> <SIZE:small> "
        .. table.concat(lines, " <LINE> "), false)
    modal:initialise(); modal:addToUIManager()
    return modal
end
-- 0.7.0.1: open the People tab on someone
function M.winPeopleAt(uid)
    if not fn(M, "hubOpen") then return nil end
    M.hubOpen("people")
    local w = M.winPeople
    if w == nil then return nil end
    w.cur = tostring(uid); w.listSig = nil
    pcall(function() w:refresh() end)
    return w
end
function M.winLog()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = math.min(620, sw - 40), math.min(560, sh - 60)
    local modal = ISModalRichText:new((sw - w) / 2, (sh - h) / 2, w, h, "<SIZE:medium> " .. tr("LogTitle", "The camp's notes") .. " <LINE> <SIZE:small> " .. (M.elText and M.elText() or ""), false)
    modal:initialise(); modal:addToUIManager()
    return modal
end

----------------------------------------------------------------------------------------------------------------
-- PEOPLE: the journal
----------------------------------------------------------------------------------------------------------------
local PeoplePage = page("ALifeTalkPeoplePage", "People", "people",
    tr("TipPeople", "<SIZE:medium> People <LINE> <SIZE:small> Your journal of everyone you've met. Only what you've learned: names they told you, what they said and did, how they seem toward you, when and where you last saw them. <LINE> <LINE> Tick the box at the left of a name to give several people the same order."))
PeoplePage.filters = { "all", "camp", "party", "lost" }
local function bookOf(uid) return fn(M, "pb") and M.pb(tostring(uid), false) or nil end
local function statusOf(uid, e)
    local p = playerOf()
    if type(e) == "table" and e.dead then return "dead" end
    if fn(M, "partyIsMember") and M.partyIsMember(uid, p) then return "party" end
    if fn(M, "cpIsHome") and M.cpIsHome(uid, p) then return "camp" end
    if type(e) == "table" and e.gone then return "lost" end
    return "known"
end
function PeoplePage:rows()
    local out, seen = {}, {}
    local book = (M.bucket and M.bucket("book")) or {}
    local function add(uid)
        uid = tostring(uid)
        if seen[uid] then return end
        seen[uid] = true
        local e = book[uid]
        local st = statusOf(uid, e)
        local f = self.filter or "all"
        if f == "camp" and st ~= "camp" then return end
        if f == "party" and st ~= "party" then return end
        if f == "lost" and st ~= "dead" and st ~= "lost" then return end
        out[#out + 1] = { uid = uid, name = M.qolName(uid), status = st, h = type(e) == "table" and tonumber(e.h) or 0 }
    end
    for uid in pairs(book) do add(uid) end
    for _, uid in ipairs(fn(M, "partyMembers") and M.partyMembers(playerOf()) or {}) do add(uid) end
    for _, r in ipairs(fn(M, "cpPeople") and (M.cpPeople(playerOf()) or {}) or {}) do add(type(r) == "table" and (r.uid or (r.record and r.record.uid)) or r) end
    local order = { party = 1, camp = 2, known = 3, lost = 4, dead = 5 }
    table.sort(out, function(a, b)
        if order[a.status] ~= order[b.status] then return (order[a.status] or 9) < (order[b.status] or 9) end
        return a.name < b.name
    end)
    return out
end
function PeoplePage:createChildren()
    self.sel = self.sel or {}
    self.filter = self.filter or "all"
    HP.createChildren(self)
end
function PeoplePage:layoutMore(top, by)
    local f = self.font
    local fh = fontH(f)
    local lw = math.max(180, math.min(320, math.floor(self.width * 0.32)))
    if self.list == nil then
        self.list = ISScrollingListBox:new(10, top + fh + 14, lw, 100)
        self.list:initialise(); self.list:instantiate()
        self.list.font = f
        self.list.itemheight = fh + 10
        self.list.drawBorder = true
        self.list.backgroundColor = { r = 0.08, g = 0.08, b = 0.09, a = 0.8 }
        local win = self
        self.list.doDrawItem = function(list, y, item, alt)
            local r = item.item
            local h = list.itemheight
            if list.selected == item.index then list:drawRect(0, y, list:getWidth(), h, 0.35, 0.55, 0.45, 0.25) end
            local on = win.sel[r.uid] == true
            list:drawRectBorder(6, y + math.floor((h - 12) / 2), 12, 12, 0.9, 0.84, 0.7, 0.38)
            if on then list:drawRect(8, y + math.floor((h - 12) / 2) + 2, 8, 8, 1, 0.84, 0.7, 0.38) end
            local c = ({ dead = { 0.5, 0.5, 0.52 }, lost = { 0.6, 0.6, 0.62 }, party = { 0.6, 0.85, 0.5 }, camp = { 0.95, 0.85, 0.6 } })[r.status] or { 0.87, 0.88, 0.9 }
            list:drawText(r.name, 26, y + 5, c[1], c[2], c[3], 1, list.font)
            return y + h
        end
        self.list.onMouseDown = function(list, x, y)
            local row = list:rowAt(x, y)
            if row and row > 0 and list.items[row] then
                local r = list.items[row].item
                if x < 22 then win.sel[r.uid] = not win.sel[r.uid] or nil
                else list.selected = row; win.cur = r.uid; win:refresh() end
            end
            return true
        end
        self:addChild(self.list)
        -- the filters above the list
        self.fbtns = {}
        for _, id in ipairs(PeoplePage.filters) do
            local label = tr("Filter_" .. id, ({ all = "All", camp = "Camp", party = "With me", lost = "Gone" })[id])
            local b = ISButton:new(0, 0, textW(label, f) + 14, fh + 6, label, self, function() self.filter = id; self.listSig = nil; self:refresh() end)
            b:initialise(); b:instantiate(); b.font = f
            T.styleButton(b)
            self:addChild(b)
            self.fbtns[#self.fbtns + 1] = { b = b, id = id }
        end
    end
    local x = 10
    for _, fb in ipairs(self.fbtns) do fb.b:setX(x); fb.b:setY(top); x = x + fb.b:getWidth() + 4 end
    self.list:setX(10); self.list:setY(top + fh + 12)
    self.list:setWidth(lw); self.list:setHeight(math.max(60, by - top - fh - 18))
    -- the page: avatar at the left of the text
    local px = 10 + lw + 10
    local aw = math.max(90, math.min(170, math.floor((self.width - px) * 0.3)))
    self.avatarBox = { x = px, y = top, w = aw, h = math.max(120, math.min(by - top - 6, math.floor(aw * 2))) }
    self.body:setX(px + aw + 8); self.body:setY(top)
    self.body:setWidth(math.max(120, self.width - px - aw - 18)); self.body:setHeight(math.max(40, by - top - 6))
    pcall(function() self.body:updateScrollbars() end)
    if self.avatar then pcall(function() self.avatar:setX(self.avatarBox.x + 2); self.avatar:setY(self.avatarBox.y + 2); self.avatar:setWidth(self.avatarBox.w - 4); self.avatar:setHeight(self.avatarBox.h - 4) end) end
end
-- the avatar: live when they're here; when not, as A-Life remembers how they look; never seen: a silhouette
function PeoplePage:showAvatar(uid)
    local box = self.avatarBox
    if box == nil then return end
    if self.avatar == nil then
        local ok, mdl = pcall(function()
            local m = ISUI3DModel:new(box.x + 2, box.y + 2, box.w - 4, box.h - 4)
            m:initialise()
            self:addChild(m)
            m:setIsometric(false)
            m:setDirection(IsoDirections.S)
            m:setDoRandomExtAnimations(false)
            m:setState("idle")
            return m
        end)
        if not ok then self.avatarDead = true; return end
        self.avatar = mdl
    end
    if self.avatarUid == uid and now() - (self.avatarAt or 0) < 5000 then return end
    self.avatarUid, self.avatarAt = uid, now()
    local shell = nil
    pcall(function() shell = PA().Talk.shellFor(uid) end)
    local shown = false
    if shell then shown = pcall(function() self.avatar:setCharacter(shell) end) end
    if not shown then
        pcall(function() self.avatar:setCharacter(nil) end)
        local desc = M.winDescOf and M.winDescOf(uid)
        if desc then shown = pcall(function() self.avatar:setSurvivorDesc(desc) end) end
    end
    self.avatarShown = shown
    pcall(function() self.avatar:setVisible(shown) end)
end
-- how they look, from A-Life's own appearance plan (cached; nil if A-Life can't say)
M.winDescCache = M.winDescCache or {}
function M.winDescOf(uid)
    uid = tostring(uid)
    local c = M.winDescCache[uid]
    if c ~= nil then return c or nil end
    local desc = nil
    pcall(function()
        local reg, H = PA().ActorRegistry, PA().ProfileHydrator
        local r = reg.read(uid)
        if r == nil or not fn(H, "plan") then return end
        local plan = H.plan(r)
        if type(plan) ~= "table" then return end
        desc = SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, plan.female == true)
        local v = desc:getHumanVisual()
        pcall(function() v:setSkinTextureIndex(plan.skin) end)
        pcall(function() if plan.skinTexture then v:setSkinTextureName(plan.skinTexture) end end)
        pcall(function() v:setHairModel(plan.hairStyle) end)
        pcall(function() v:setBeardModel(plan.beardStyle) end)
        for _, entry in ipairs(type(plan.clothing) == "table" and plan.clothing or {}) do
            pcall(function()
                local item = instanceItem(type(entry) == "table" and entry.itemType or entry)
                if item and item:getBodyLocation() then desc:setWornItem(item:getBodyLocation(), item) end
            end)
        end
    end)
    M.winDescCache[uid] = desc or false
    return desc
end
function PeoplePage:render()
    HP.render(self)
    local box = self.avatarBox
    if box then
        self:drawRect(box.x, box.y, box.w, box.h, 0.55, 0.06, 0.06, 0.07)
        self:drawRectBorder(box.x, box.y, box.w, box.h, 0.7, 0.45, 0.4, 0.28)
        if not self.avatarShown then
            local f = self.font
            self:drawTextCentre(self.cur and tr("AvatarNone", "Not seen up close") or tr("AvatarPick", "Pick someone"), box.x + box.w / 2, box.y + box.h / 2 - fontH(f) / 2, 0.55, 0.56, 0.6, 1, f)
        end
    end
end
local function seenText(e)
    if type(e) ~= "table" or not tonumber(e.h) then return nil end
    local town = (e.x and fn(M, "townAt")) and M.townAt(e.x, e.y) or nil
    local d = math.floor((hours() - e.h) / 24)
    local ago = d <= 0 and "today" or (d == 1 and "yesterday" or (d .. " days ago"))
    return "Last seen " .. (town and ("near " .. town .. ", ") or "") .. ago .. "."
end
function PeoplePage:text()
    -- the list (rebuilt when it changes)
    local rows = self:rows()
    local sig = {}
    for _, r in ipairs(rows) do sig[#sig + 1] = r.uid .. r.status .. r.name end
    sig = table.concat(sig, "|") .. (self.filter or "")
    if sig ~= self.listSig and self.list then
        self.listSig = sig
        local keep = self.cur
        self.list:clear()
        for i, r in ipairs(rows) do self.list:addItem(r.name, r); if r.uid == keep then self.list.selected = i end end
    end
    if self.cur == nil then return DIM .. tr("PeoplePick", "Pick someone on the left. Everyone you've met is here, with what you know about them.") end
    local uid = self.cur
    pcall(self.showAvatar, self, uid)
    local e = bookOf(uid) or {}
    local p = playerOf()
    local out = { " <SIZE:medium> " .. GOLD .. esc(M.qolName(uid)) .. TXT .. " <SIZE:" .. ((self.font == UIFont.Medium) and "medium" or "small") .. "> <LINE> " }
    local st = statusOf(uid, e)
    local stWord = ({ dead = "Dead.", lost = "Gone. You don't know where.", party = "With you.", camp = "Lives at your camp.", known = "Someone you know." })[st]
    if st == "camp" and fn(M, "cpRoleOf") then local role = M.cpRoleOf(uid); if role and role ~= "general" then stWord = "Lives at your camp: the " .. string.lower(M.cpRoleLabel[role] or role) .. "." end end
    out[#out + 1] = stWord .. " <LINE> "
    if e.label and st ~= "dead" then out[#out + 1] = DIM .. "How they seem toward you: " .. TXT .. esc(string.lower(tostring(e.label))) .. ". <LINE> " end
    -- where: last seen, where they said they'd go, your orders
    local o = M.plOrderOf and M.plOrderOf(uid)
    if o then local pl = M.plGet(o.place); if pl then out[#out + 1] = (o.mode == "hold" and "You sent them to hold " or "You told them to meet you at ") .. esc(pl.name) .. ". <LINE> " end end
    local L = M.lvMem and M.lvMem.leavers and M.lvMem.leavers[uid]
    if L and st ~= "dead" then out[#out + 1] = "Last you knew, " .. tagWord(L.tag) .. ". <LINE> " end
    local seen = seenText(e)
    if seen and st ~= "party" then out[#out + 1] = DIM .. esc(seen) .. TXT .. " <LINE> " end
    -- what you know: their story with you, newest first
    local hist = fn(M, "histRows") and M.histRows(uid) or {}
    if #hist > 0 then
        out[#out + 1] = head(tr("PeopleKnown", "What you know"))
        for i = #hist, math.max(1, #hist - 40), -1 do
            local r = hist[i]
            out[#out + 1] = DIM .. esc(r.when or "") .. TXT .. "  " .. esc(r.text or "") .. " <LINE> "
        end
    end
    return table.concat(out)
end
local function orderMenu(cm, uids, win)
    local places = M.qolStore and M.qolStore().places or {}
    for _, id in ipairs({ "follow", "wait", "guard", "home", "recall" }) do
        local o = M.qoById[id]
        cm:addOption(tr("Order_" .. id, o.label), nil, function()
            local n = M.bulkOrder(uids, id)
            if M.momToast and n ~= nil then M.momToast(n == 0 and tr("OrderNot", "Nobody took that order.") or tr("OrderTook", "{1} took the order.", n == 1 and M.qolName(uids[1]) or (n .. " people"))) end
        end)
    end
    if fn(M, "cpSetRole") and M.cpRoleLabel then
        local ro = cm:addOption(tr("OrderRole", "Give a job"), nil, nil)
        local rs = ISContextMenu:getNew(cm); cm:addSubMenu(ro, rs)
        for id, label in pairs(M.cpRoleLabel) do rs:addOption(label, nil, function() M.bulkOrder(uids, "role", id) end) end
    end
    if #places > 0 then
        for _, mode in ipairs({ "meet", "hold" }) do
            local po = cm:addOption(mode == "meet" and tr("OrderMeet", "Meet me at") or tr("OrderHold", "Hold"), nil, nil)
            local ps = ISContextMenu:getNew(cm); cm:addSubMenu(po, ps)
            for _, pl in ipairs(places) do ps:addOption(pl.name, nil, function() M.bulkOrder(uids, mode, pl.id) end) end
        end
    end
end
function PeoplePage:selected()
    local out = {}
    for uid, on in pairs(self.sel or {}) do if on then out[#out + 1] = uid end end
    table.sort(out)
    return out
end
function PeoplePage:actions()
    return {
        { label = tr("BtnTalk", "Talk"), fn = function(win) if win.cur and fn(M, "partyCommand") then M.partyCommand(win.cur, "talk", playerOf()) end end },
        { label = tr("BtnOrders", "Orders"), fn = function(win, btn) if win.cur then orderMenu(menuAt(win, btn), { win.cur }, win) end end },
        { label = tr("BtnSelected", "Order the ticked"), fn = function(win, btn)
            local list = win:selected()
            if #list == 0 then if M.momToast then M.momToast(tr("NoneTicked", "Tick the box next to a few names first.")) end; return end
            orderMenu(menuAt(win, btn), list, win) end },
        { label = tr("BtnFullPage", "Their page"), fn = function(win) if win.cur and fn(M, "openRelationship") then M.openRelationship(win.cur) end end },
        { label = tr("BtnJeemPeople", "Jeem: my people"), show = hasJeem, fn = function(win, btn) M.winJeem(menuAt(win, btn), { 20, 45 }) end },
    }
end
function PeoplePage:onPageClose() pcall(function() if self.avatar then self.avatar:setCharacter(nil) end end) end

----------------------------------------------------------------------------------------------------------------
-- CAMP
----------------------------------------------------------------------------------------------------------------
local CampPage = page("ALifeTalkCampHub", "Camp", "camp",
    tr("TipCamp", "<SIZE:medium> Camp <LINE> <SIZE:small> The camp board, and every camp menu in one place: roles, rules, patrol, alarm, kitchen, farm and the rest, work zones, and Jeem's base and residents if you use Jeem. <LINE> <LINE> Name a spot ('the north gate') and you can send people there to meet you or to hold it. <LINE> <LINE> With Jeem: camp roles are done in a person's free time on Jeem's schedule, so give them Free shifts for it. Our Farmer and Jeem's farmer job are the same job."))
function CampPage:text()
    local ok, txt = false, nil
    if fn(M, "bdText") then ok, txt = pcall(M.bdText, playerOf()) end
    local out = { ok and txt or DIM .. tr("CampNone", "No camp yet. Settle people at your base and their day shows up here.") .. TXT }
    local places = M.qolStore and M.qolStore().places or {}
    if #places > 0 then
        out[#out + 1] = head(tr("CampPlaces", "Places you named"))
        for _, pl in ipairs(places) do
            local who = {}
            for uid, o in pairs(M.qolStore().plOrders) do if o.place == pl.id then who[#who + 1] = esc(M.qolName(uid)) end end
            out[#out + 1] = esc(pl.name) .. (#who > 0 and (DIM .. "  (" .. table.concat(who, ", ") .. ")" .. TXT) or "") .. " <LINE> "
        end
    end
    return table.concat(out)
end
function CampPage:actions()
    local out = {
        { label = tr("BtnCampMenu", "Camp menu"), accent = true, fn = function(win, btn) M.winFill(menuAt(win, btn), { "camp" }) end },
        { label = tr("BtnZones", "Work zones"), fn = function(win, btn) M.winFill(menuAt(win, btn), { "workzones" }) end },
        { label = tr("BtnNamePlace", "Name this spot"), fn = function()
            local p = playerOf(); if p and M.plAsk then M.plAsk(math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())) end end },
        { label = tr("BtnPlaces", "Named places"), fn = function(win, btn)
            local cm = menuAt(win, btn)
            local places = M.qolStore().places
            if #places == 0 then cm:addOption(tr("PlacesNone", "(none yet: stand somewhere and 'Name this spot')"), nil, nil) end
            for _, pl in ipairs(places) do
                local o = cm:addOption(pl.name, nil, nil); local sub = ISContextMenu:getNew(cm); cm:addSubMenu(o, sub)
                sub:addOption(tr("PlaceShow", "Show on map"), nil, function() pcall(function() ISWorldMap.ShowWorldMap(0, pl.x, pl.y, 18) end) end)
                sub:addOption(tr("PlaceForget", "Forget this name"), nil, function() M.plRemove(pl.id) end)
            end end },
        { label = tr("BtnCampMove", "Move camp"), show = function() return fn(ALifeCampMove, "on") and ALifeCampMove.on() end, fn = function(win, btn)
            local cm = menuAt(win, btn)
            cm:addOption(tr("CampMoveHere", "Make this building our camp"), nil, function() ALifeCampMove.ask(playerOf()) end)
            cm:addOption(tr("CampMoveAuto", "Let the camp follow where we sleep"), nil, function() ALifeCampMove.ask(playerOf(), true) end) end },
        { label = tr("BtnJeemBase", "Jeem: base and residents"), show = hasJeem, fn = function(win, btn) M.winJeem(menuAt(win, btn), { 20, 30, 31, 40 }) end },
        { label = tr("BtnCampLog", "From your camp"), show = function() return fn(ALifeSettlement, "openLog") end, fn = function() ALifeSettlement.openLog() end },
    }
    -- 0.8.8 UI: stand down, one per lieutenant (camp board's own buttons, M.bdActions)
    if fn(M, "bdActions") then
        for _, a in ipairs(M.bdActions(playerOf())) do out[#out + 1] = { label = a.label, fn = function(win) a.fn(); pcall(win.refresh, win) end } end
    end
    return out
end
-- the lieutenants changed: rebuild the buttons
function CampPage:refresh()
    HP.refresh(self)
    local sig = fn(M, "bdActionSig") and M.bdActionSig() or ""
    if self.actSig == nil then self.actSig = sig
    elseif sig ~= self.actSig then self.actSig = sig; pcall(function() self:buildButtons(); self:layout() end) end
end

----------------------------------------------------------------------------------------------------------------
-- TRADE
----------------------------------------------------------------------------------------------------------------
local TradePage = page("ALifeTalkTradePage", "Trade", "trade",
    tr("TipTrade", "<SIZE:medium> Trade <LINE> <SIZE:small> Your trading post, market days and the traders on their way or at your place. Hold something and ask what it's worth to people out there: every item has its own worth, and groups pay more for what they lack."))
function TradePage:text()
    local out = {}
    local st = M.tpStore and M.tpStore() or {}
    out[#out + 1] = head(tr("TradePost", "Your trading post"))
    out[#out + 1] = (type(st.post) == "table" and tr("TradePostSet", "Set. Traders who know your place come to it.") or tr("TradePostNone", "None yet. Right-click a container at your base: Camp > Trading post.")) .. " <LINE> "
    if type(st.next) == "table" and tonumber(st.next.at) and st.next.at > hours() - 12 then
        local d = math.floor((st.next.at - hours()) / 24)
        out[#out + 1] = tr("TradeMarket", "Market day: {1}.", d <= 0 and "today" or (d == 1 and "tomorrow" or ("in " .. d .. " days"))) .. (type(st.standing) == "table" and " Every week." or "") .. " <LINE> "
    end
    local here = {}
    for _, v in pairs((M.nbStore and M.nbStore().ovVisits) or {}) do here[#here + 1] = esc(tostring(v.name or "Traders")) .. ": at your place" end
    local trips = fn(M, "cvTrips") and select(1, M.cvTrips()) or {}
    for _, trip in pairs(trips) do
        if type(trip) == "table" then
            local b = M.nbStore().byId and M.nbStore().byId[trip.home]
            here[#here + 1] = esc(tostring(b and b.name or "Traders")) .. ": on the road to you"
        end
    end
    if #here > 0 then out[#out + 1] = head(tr("TradeComing", "Traders")) .. table.concat(here, " <LINE> ") .. " <LINE> " end
    -- what you're holding
    local p = playerOf()
    local it = nil
    pcall(function() it = p:getPrimaryHandItem() end)
    if it and type(ALifeWorth) == "table" then
        local ft = nil
        pcall(function() ft = it:getFullType() end)
        local w = ft and ALifeWorth.of(ft) or nil
        local word = (w and fn(ALifeWorth, "wealthWord")) and ALifeWorth.wealthWord(w) or nil
        out[#out + 1] = head(tr("TradeHolding", "What you're holding"))
        out[#out + 1] = esc(it:getDisplayName()) .. ": " .. esc(word or (w and (w >= 20 and "worth a lot" or (w >= 5 and "worth something" or "not worth much")) or "hard to say")) .. " <LINE> "
    end
    return table.concat(out)
end
function TradePage:actions()
    return {
        { label = tr("BtnRadioTrade", "Radio: traders and market day"), accent = true, fn = function(win, btn) M.winFill(menuAt(win, btn), { "radio" }) end },
        { label = tr("BtnPostMenu", "Trading post (here)"), fn = function(win, btn) M.winFill(menuAt(win, btn), { "tradingpost" }) end },
    }
end

----------------------------------------------------------------------------------------------------------------
-- RADIO
----------------------------------------------------------------------------------------------------------------
local RadioPage = page("ALifeTalkRadioPage", "Radio", "radio",
    tr("TipRadio", "<SIZE:medium> Radio <LINE> <SIZE:small> Who can hear you depends on the radio you have with you or stand next to. Call out to find people, ask friends for traders or help, and (with Jeem) call your own base on the walkie."))
function RadioPage:text()
    local p = playerOf()
    local out = {}
    local range = fn(M, "rcRadio") and M.rcRadio(p) or nil
    out[#out + 1] = head(tr("RadioReach", "Your radio"))
    if range == nil then
        out[#out + 1] = tr("RadioNone", "No radio with you or next to you. Hold a walkie, or stand by a ham radio.") .. " <LINE> "
    else
        local list = fn(M, "rcInRange") and M.rcInRange(p, range) or {}
        if ALifeSide.mpClient() and type(ALifeRemote) == "table" then -- pre-1.0 MP: the groups in range, as the server sees them
            list = {}
            for _, row in ipairs(ALifeRemote.get("rcBases", p) or {}) do if type(row) == "table" then list[#list + 1] = { name = row.name, radioKnown = row.known == true } end end
        end
        local known = {}
        for _, b in ipairs(list) do if b.radioKnown then known[#known + 1] = esc(tostring(b.name)) end end
        out[#out + 1] = tr("RadioRange", "Reaches about {1} tiles.", math.floor(range)) .. " <LINE> "
        out[#out + 1] = (#known > 0 and (tr("RadioWho", "Groups you've talked to who can hear you: ") .. table.concat(known, ", ")) or tr("RadioNobody", "Nobody you've talked to is in range. Call out on the open channels.")) .. " <LINE> "
    end
    return table.concat(out)
end
function RadioPage:actions()
    return {
        { label = tr("BtnRadio", "Radio"), accent = true, fn = function(win, btn) M.winFill(menuAt(win, btn), { "radio" }) end },
        { label = tr("BtnJeemRadio", "Jeem: walkie to your base"), show = hasJeem, fn = function(win, btn) M.winJeem(menuAt(win, btn), { 42 }) end },
    }
end

----------------------------------------------------------------------------------------------------------------
-- HELP
----------------------------------------------------------------------------------------------------------------
local HelpPage = page("ALifeTalkHelpPage", "Help", nil, nil)
M.winHelp = M.winHelp or {
    { "Talking", "Type in chat like you'd talk (with or without /say). Start or end with ! to shout. With the AI helper they understand anything and answer in their own voice; without it, plain commands work." },
    { "People", "Everyone you've met, journal style: only what you've learned. Tick names to give several people one order." },
    { "Your camp", "Give people jobs (cook, medic, guard, builder, farmer), set rules, patrols and the alarm, fortify, mark work zones. The camp board shows everyone's day." },
    { "Orders", "Follow me, wait here, guard here, go back to the base, meet me at / hold a place you named. The quick-order bar (Now tab) keeps your favourites on screen." },
    { "Quick wheel", "Point at someone and open the wheel (your hotkey, D-pad up, the vehicle menu): talk, follow, wait, guard, orders, their page. Point at nothing: your quick orders, name this spot, radio, this window. The full list is under right-click > A-Life, and on these tabs." },
    { "Letters", "News that isn't a decision shows at the right edge, shrinks to a small tab, and stays until you clear it: left-click a tab to read it again, hover to peek, right-click to clear. Right-click \"Clear all\" to clear all but the red ones, or show only the important (red) ones or only the news. Important news (a death, someone turning on you) pops up in the middle and pauses the game; it leaves a red letter too." },
    { "Immersive", "On (the default): no numbers. You read people by how they act and by asking them (\"do you trust me?\"), and they can lie. Off: the bond numbers, the bond notes and the Factions overview come back. Switch it in Settings any time; it's kept with this world." },
    { "Talking while paused", "Pause, press the chat key and type. They answer while the game stays paused." },
    { "Missed something?", "Letters and notes go by fast. Now tab > Missed something? keeps the last ones, red for the bad ones." },
    { "Why not", "When someone refuses, you're told why in plain words, and it goes in their journal." },
    { "Named places", "Stand somewhere and pick Name this spot: on the quick wheel (point at the ground), on the Camp tab, or right-click the ground. It goes on your map; send people there to meet you or to hold it." },
    { "The camp's notes", "Stores getting thin, new faces, losses, groups warming or cooling toward you. Now > The camp's notes." },
    { "Camp widget", "A small panel you can drag anywhere. Right-click it to pick what it shows, its size, how see-through it is, lock it, or hide it while all is well." },
    { "Groups out there", "Real groups with real stashes: they farm, craft, trade, raid, move on, hold outposts at police stations, bridges and the only road into town. Nothing spawns loot." },
    { "Trade", "Real people bring real goods after the real walk or drive. Set a trading post, pick a market day on the radio. Every item has its own worth." },
    { "Radio", "Range depends on your radio. Call out to find people; ask friends for traders or for help in a fight." },
    { "World", "Your journal of groups and places: what you were told, by whom, when. The war map shows the wars you know of." },
    { "When something breaks", "A feature that hits an error switches itself off and you get a note. Send console.txt (in your Zomboid folder) and Zomboid/Lua/ALifeChatPlus_health.txt. AI trouble: AI tab > Doctor check, then send Zomboid/Lua/alifeai_doctor.txt." },
}
-- pre-1.0 (trip-ups): other files fold their page INTO Help instead of adding a tab (Joe: Commands folds onto Help).
-- M.helpSections[i] = { id, label, text = fn() -> rich text, actions = fn() -> buttons, click = fn(lineText) -> changed? }. The buttons at the bottom
-- switch the view: Help (the short guide) or a section (Commands). M.helpOpen(id) opens Help on that view.
M.helpSections = M.helpSections or {}
local function helpSection(id) for _, s in ipairs(M.helpSections) do if s.id == id then return s end end return nil end
function M.helpOpen(view)
    M.helpView = view
    if fn(M, "hubOpen") then M.hubOpen("help") end
    local w = M.winHelp2
    if w and w.setView then pcall(w.setView, w, view) end
    return w
end
function HelpPage:setView(view)
    if view ~= nil and helpSection(view) == nil then view = nil end
    self.view = view
    M.helpView = view
    pcall(self.buildButtons, self)
    pcall(self.layout, self)
    pcall(self.refresh, self)
end
-- a section's click(lineText) returns true when it changed (a heading opened / closed): redraw
function HelpPage:onBodyClick(line)
    local sec = self.view and helpSection(self.view) or nil
    if sec and type(sec.click) == "function" and sec.click(line) == true then self:refresh() end
end
function HelpPage:text()
    if self.view == nil and M.helpView ~= nil and helpSection(M.helpView) then self.view = M.helpView end
    local sec = self.view and helpSection(self.view) or nil
    if sec and type(sec.text) == "function" then
        local ok, t = pcall(sec.text)
        if ok and type(t) == "string" then return t end
        return RED .. esc(tostring(sec.label)) .. ": " .. esc(tostring(t)) .. TXT
    end
    local out = { " <SIZE:medium> " .. GOLD .. tr("HelpTitle", "A-Life NPC Overhaul in short") .. TXT .. " <SIZE:" .. ((self.font == UIFont.Medium) and "medium" or "small") .. "> <LINE> " }
    for _, h in ipairs(M.winHelp) do -- 0.8.12: translated (IGUI_ALCP_Help_<title> / IGUI_ALCP_HelpText_<title>)
        local k = string.gsub(tostring(h[1]), "[^%w]+", "_")
        out[#out + 1] = head(tr("Help_" .. k, h[1])) .. esc(tr("HelpText_" .. k, h[2])) .. " <LINE> "
    end
    return table.concat(out)
end
function HelpPage:actions()
    local out = {}
    if self.view == nil and M.helpView ~= nil and helpSection(M.helpView) then self.view = M.helpView end
    if #M.helpSections > 0 then
        out[#out + 1] = { label = tr("BtnHelpGuide", "Help"), accent = self.view == nil, fn = function(win) win:setView(nil) end }
        for _, s in ipairs(M.helpSections) do
            out[#out + 1] = { label = tr("BtnHelp_" .. tostring(s.id), s.label), accent = self.view == s.id, fn = function(win) win:setView(s.id) end }
        end
    end
    local sec = self.view and helpSection(self.view) or nil
    if sec then
        if type(sec.actions) == "function" then
            local ok, list = pcall(sec.actions)
            if ok and type(list) == "table" then for _, a in ipairs(list) do a.accent = false; out[#out + 1] = a end end
        end
        return out
    end
    for _, a in ipairs(HelpPage.guideActions(self)) do out[#out + 1] = a end
    return out
end
function HelpPage.guideActions()
    local out = {}
    -- pre-1.0: "Report a bug" up front (ALifeBugReports)
    if type(ALifeBugReports) == "table" and fn(ALifeBugReports, "sendButton") then
        pcall(function() out[#out + 1] = ALifeBugReports.sendButton() end)
    end
    for _, a in ipairs(HelpPage.guideBase()) do out[#out + 1] = a end
    return out
end
function HelpPage.guideBase()
    return {
        { label = tr("BtnTips", "Show the tips again"), fn = function() for _, id in ipairs({ "now", "people", "camp", "trade", "radio", "welcome", "hoverkey", "noai" }) do M.uiSet("tip." .. id, false) end; if M.momToast then M.momToast(tr("TipsBack", "Each tab shows its tip again the next time you open it.")) end end },
    }
end

----------------------------------------------------------------------------------------------------------------
-- the tabs (Now, People, Party, Camp, Trade, World, Radio, Settings, Help)
----------------------------------------------------------------------------------------------------------------
-- 0.8.2: the page kit, for pages added from other files (Commands, folded into Help since pre-1.0)
M.winKit = { page = page, openPage = openPage, menuAt = menuAt, esc = esc, head = head, tr = tr,
    GOLD = GOLD, TXT = TXT, DIM = DIM, RED = RED }
function M.winInstall()
    if M._winInstalled or not fn(M, "hubAddTab") then return M._winInstalled == true end
    M._winInstalled = true
    M.hubAddTab({ id = "now", label = "Now", class = "ALifeTalkNowPage", open = function() return openPage(NowPage, "winNow") end, ref = function() return M.winNow end }, "people")
    M.hubAddTab({ id = "people", label = "People", class = "ALifeTalkPeoplePage", open = function() return openPage(PeoplePage, "winPeople") end, ref = function() return M.winPeople end })
    M.hubAddTab({ id = "camp", label = "Camp", class = "ALifeTalkCampHub", open = function() return openPage(CampPage, "winCamp") end, ref = function() return M.winCamp end })
    M.hubAddTab({ id = "trade", label = "Trade", class = "ALifeTalkTradePage", open = function() return openPage(TradePage, "winTrade") end, ref = function() return M.winTrade end }, "journal")
    for _, t in ipairs(M.hubTabs) do if t.id == "journal" then t.label = "World" end end
    M.hubAddTab({ id = "radio", label = "Radio", class = "ALifeTalkRadioPage", open = function() return openPage(RadioPage, "winRadio") end, ref = function() return M.winRadio end }, "settings")
    M.hubAddTab({ id = "help", label = "Help", class = "ALifeTalkHelpPage", open = function() return openPage(HelpPage, "winHelp2") end, ref = function() return M.winHelp2 end })
    if M.hubState and M.hubState.last == "commands" then M.hubState.last = "help" end -- pre-1.0: the Commands tab is on Help now
    if M.hubState and (M.hubState.last == nil or M.hubState.last == "people") then M.hubState.last = "now" end
    -- the settings window: the new switches
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({ { "eventLog", "The camp's notes (event log)" }, { "whyNot", "Say why when someone refuses" },
            { "namedPlaces", "Named places (right-click the ground: Name this spot)" }, { "firstTips", "A tip the first time you open each tab" },
            { "radialQuick", "Radial: the quick wheel (off: everything on the wheel)" }, { "noticeLog", "Keep what pops up on screen (Now tab)" },
            { "immersive", "Immersive: no numbers, read people (off: numbers and bond notes)" },
            { "alerts", "Important news pauses the game (a popup)" }, { "talkWhilePaused", "Talk while the game is paused" } }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if M.settings[r[1]] == nil then M.settings[r[1]] = true end
            if type(M.fileKeys) == "table" and r[1] ~= "immersive" then -- immersive is kept with the world, not the file
                local k = false
                for _, f in ipairs(M.fileKeys) do if f == r[1] then k = true end end
                if not k then M.fileKeys[#M.fileKeys + 1] = r[1] end
            end
        end
    end
    print("[ALifeWindow] loaded v" .. ALifeSide.MOD_VERSION .. " (one A-Life window: Now, People, Party, Camp, Trade, World, Radio, Settings, Help)")
    return true
end
if not M.winInstall() and Events and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.winInstall) end) end
