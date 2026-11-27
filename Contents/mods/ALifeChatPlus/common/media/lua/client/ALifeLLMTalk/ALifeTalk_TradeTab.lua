-- A-Life NPC Overhaul pre-1.0: THE TRADE TAB (docs/PLAN-TRADE.md T9). Replaces the old one-page Trade tab (same hub id
-- "trade", so it sits in A-Life's Journal like before). A row of views at the top:
--   Post      your trading post (what's in it, as fill words), market day, traders here and on the way
--   Roads     a drawn map: groups you know, the roads between them coloured by how safe they are, runs moving on them
--   Caravans  your own caravans on the road; send one, turn one back; who at home would go
--   Deals     standing deals and offers waiting; propose one, answer one, call one off
--   Word      trade talk heard on the radio, who won't trade with you (pay back), feuds
-- Client only draws: data comes from the world side as flat rows (ALifeRemote views trPost ... trCrew); buttons call
-- the exposed world functions (trOwnSend, trOwnRecall, trDealPropose, trDealAnswer, trDealEnd, trRepay).
-- No numbers but your own post's item fill (rule 6).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeTalk_Window"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.winKit) ~= "table" then return end
local K = M.winKit
local Th, S = M.Theme, M.UIStyle
local esc, head, tr = K.esc, K.head, K.tr
local GOLD, TXT, DIM, RED = K.GOLD, K.TXT, K.DIM, K.RED
local GREEN, AMBER, BLUE = " <RGB:0.5,0.78,0.45> ", " <RGB:0.88,0.72,0.32> ", " <RGB:0.5,0.7,0.95> "
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function view(name) if type(ALifeRemote) ~= "table" then return {} end; local v = ALifeRemote.get(name, playerOf()); return type(v) == "table" and v or {} end
local function font() return M.qolFont and M.qolFont("auto") or UIFont.Small end
local function fontH(f) local h = 16; pcall(function() h = getTextManager():getFontHeight(f) end); return h end
local function textW(t, f) local w = 8 * #tostring(t); pcall(function() w = getTextManager():MeasureStringX(f, tostring(t)) end); return w end
local KINDS = { { "food", "food" }, { "water", "water" }, { "meds", "medicine" }, { "ammo", "ammo" }, { "tools", "tools" }, { "materials", "building materials" }, { "fuel", "fuel" } }
local function safeRGB(safe)
    safe = tonumber(safe) or 50
    if safe >= 70 then return 0.5, 0.78, 0.45 elseif safe >= 45 then return 0.75, 0.75, 0.6 elseif safe >= 25 then return 0.88, 0.72, 0.32 end
    return 0.9, 0.38, 0.3
end
local function roadColor(word) return ({ safe = GREEN, quiet = TXT, risky = AMBER, bad = RED })[word] or TXT end
local function fillBar(fill) return ({ plenty = GREEN .. "||||||", some = AMBER .. "|||" .. DIM .. "|||", low = RED .. "|" .. DIM .. "|||||", none = DIM .. "||||||" })[fill] or DIM .. "||||||" end

local TP = K.page("ALifeTalkTradeTab", "Trade", "trade2",
    tr("TipTrade2", "<SIZE:medium> Trade <LINE> <SIZE:small> Your trading post, the roads between groups and who's on them, your own caravans, standing deals, and the trade talk on the radio. Pick a view along the top. Everyone you see on the map is a real person carrying real goods."))
ALifeTalkTradeTab = TP
TP.VIEWS = { { "post", "Post" }, { "roads", "Roads" }, { "caravans", "Caravans" }, { "deals", "Deals" }, { "word", "Word" } }
function TP.current()
    local v = M.uiPref and M.uiPref("trade.view", "post") or "post"
    for _, e in ipairs(TP.VIEWS) do if e[1] == v then return v end end
    return "post"
end

----------------------------------------------------------------------------------------------------------------
-- the map (Roads)
----------------------------------------------------------------------------------------------------------------
ALifeTradeMap = ISPanel:derive("ALifeTradeMap")
local MapP = ALifeTradeMap
function MapP:new(x, y, w, h, owner)
    local o = ISPanel.new(self, x, y, w, h)
    o.owner = owner
    o.background = false
    o.groups, o.runs, o.routes, o.you = {}, {}, {}, nil
    return o
end
function MapP:setData(groups, runs, routes)
    self.groups, self.runs, self.routes, self.you = {}, runs or {}, routes or {}, nil
    for _, g in ipairs(groups or {}) do if g.k == "you" then self.you = g elseif g.k == "g" then self.groups[#self.groups + 1] = g end end
    -- the frame: everything we know of, with a margin
    local x1, y1, x2, y2 = nil, nil, nil, nil
    local function grow(x, y) if tonumber(x) then x1 = math.min(x1 or x, x); y1 = math.min(y1 or y, y); x2 = math.max(x2 or x, x); y2 = math.max(y2 or y, y) end end
    if self.you and tonumber(self.you.x) and self.you.x ~= 0 then grow(self.you.x, self.you.y) end
    for _, g in ipairs(self.groups) do grow(g.x, g.y) end
    for _, r in ipairs(self.runs) do grow(r.x, r.y) end
    if x1 == nil then self.frame = nil; return end
    local span = math.max(300, x2 - x1, y2 - y1) * 1.15
    local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    self.frame = { cx = cx, cy = cy, span = span }
end
function MapP:toPanel(x, y)
    local f = self.frame
    local side = math.min(self.width, self.height) - 30
    local s = side / f.span
    return self.width / 2 + (x - f.cx) * s, self.height / 2 + (y - f.cy) * s
end
local function line(self, ax, ay, bx, by, a, r, g, b, thick)
    self:drawLine2(ax, ay, bx, by, a, r, g, b)
    if thick then self:drawLine2(ax + 1, ay, bx + 1, by, a, r, g, b); self:drawLine2(ax, ay + 1, bx, by + 1, a, r, g, b) end
end
function MapP:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.55, 0.07, 0.08, 0.09)
    self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.84, 0.7, 0.38)
    -- a faint grid, like a paper map
    for i = 1, 7 do
        local gx, gy = self.width * i / 8, self.height * i / 8
        self:drawRect(gx, 2, 1, self.height - 4, 0.06, 0.84, 0.7, 0.38)
        self:drawRect(2, gy, self.width - 4, 1, 0.06, 0.84, 0.7, 0.38)
    end
end
function MapP:render()
    local f = font()
    if self.frame == nil then
        self:drawTextCentre("No groups you know of yet. Talk to people, use the radio, set a trading post.", self.width / 2, self.height / 2 - 8, 0.6, 0.6, 0.62, 1, f)
        return
    end
    -- roads
    for _, r in ipairs(self.routes) do
        local ax, ay = self:toPanel(r.ax, r.ay)
        local bx, by = self:toPanel(r.bx, r.by)
        local cr, cg, cb = safeRGB(r.safe)
        line(self, ax, ay, bx, by, r.runs and 0.75 or 0.35, cr, cg, cb, r.runs)
    end
    -- runs: where they are, a thin line to where they're headed
    for _, r in ipairs(self.runs) do
        local x, y = self:toPanel(r.x, r.y)
        local tx, ty = self:toPanel(r.tx or r.x, r.ty or r.y)
        local cr, cg, cb = 0.92, 0.88, 0.75
        if r.mine then cr, cg, cb = 0.5, 0.7, 0.95 elseif r.toYou then cr, cg, cb = 0.84, 0.7, 0.38 end
        line(self, x, y, tx, ty, 0.25, cr, cg, cb)
        local sel = self.owner and self.owner.selRun == r.id
        self:drawRect(x - 3, y - 3, 7, 7, 1, cr, cg, cb)
        if r.escorted then self:drawRectBorder(x - 5, y - 5, 11, 11, 0.9, 0.9, 0.38, 0.3) end
        if sel then self:drawRectBorder(x - 7, y - 7, 15, 15, 1, 1, 1, 1) end
    end
    -- groups
    for _, g in ipairs(self.groups) do
        local x, y = self:toPanel(g.x, g.y)
        local sel = self.owner and self.owner.selGroup == g.id
        local hot = self.hot == g.id
        local cr, cg, cb = 0.78, 0.78, 0.8
        if g.trader then cr, cg, cb = 0.84, 0.7, 0.38 end
        self:drawRect(x - 5, y - 5, 11, 11, 1, cr, cg, cb)
        if g.emb then self:drawRectBorder(x - 7, y - 7, 15, 15, 1, 0.9, 0.3, 0.25) end
        if sel or hot then self:drawRectBorder(x - 9, y - 9, 19, 19, 1, 1, 1, 1) end
        self:drawText(tostring(g.name), x + 9, y - 7, 0.9, 0.9, 0.9, (sel or hot) and 1 or 0.75, UIFont.Small)
    end
    -- you
    if self.you and tonumber(self.you.x) and self.you.x ~= 0 then
        local x, y = self:toPanel(self.you.x, self.you.y)
        self:drawRect(x - 4, y - 4, 9, 9, 1, 1, 1, 1)
        self:drawRectBorder(x - 7, y - 7, 15, 15, 0.8, 0.5, 0.7, 0.95)
        self:drawText("you", x + 9, y - 7, 0.6, 0.78, 1, 1, UIFont.Small)
    end
    -- legend
    local lx, ly = 8, self.height - fontH(UIFont.Small) - 6
    local items = { { "safe road", 0.5, 0.78, 0.45 }, { "risky", 0.88, 0.72, 0.32 }, { "bad", 0.9, 0.38, 0.3 }, { "your people", 0.5, 0.7, 0.95 }, { "coming to you", 0.84, 0.7, 0.38 } }
    for _, e in ipairs(items) do
        self:drawRect(lx, ly + 4, 8, 8, 1, e[2], e[3], e[4])
        self:drawText(e[1], lx + 12, ly, 0.75, 0.75, 0.78, 1, UIFont.Small)
        lx = lx + textW(e[1], UIFont.Small) + 26
    end
end
function MapP:pick(mx, my)
    if self.frame == nil then return nil end
    local best, bd = nil, 14 * 14
    for _, g in ipairs(self.groups) do
        local x, y = self:toPanel(g.x, g.y)
        local d = (x - mx) ^ 2 + (y - my) ^ 2
        if d < bd then best, bd = { group = g.id }, d end
    end
    for _, r in ipairs(self.runs) do
        local x, y = self:toPanel(r.x, r.y)
        local d = (x - mx) ^ 2 + (y - my) ^ 2
        if d < bd then best, bd = { run = r.id }, d end
    end
    return best
end
function MapP:onMouseMove(dx, dy)
    local p = self:pick(self:getMouseX(), self:getMouseY())
    self.hot = p and p.group or nil
    return true
end
function MapP:onMouseMoveOutside() self.hot = nil end
function MapP:onMouseUp(x, y)
    local p = self:pick(x, y)
    if self.owner then
        self.owner.selGroup = p and p.group or nil
        self.owner.selRun = p and p.run or nil
        pcall(self.owner.refresh, self.owner)
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the page
----------------------------------------------------------------------------------------------------------------
function TP:createChildren()
    self.viewBtns = {}
    self.map = MapP:new(10, 40, 100, 100, self)
    self.map:initialise()
    ALifeTalkHubPage.createChildren(self)
    self:addChild(self.map)
    self:buildViewButtons()
    self:layout()
    self:refresh()
end
function TP:buildViewButtons()
    for _, b in ipairs(self.viewBtns or {}) do pcall(function() self:removeChild(b) end) end
    self.viewBtns = {}
    local f = self.font or font()
    local cur = TP.current()
    for _, e in ipairs(TP.VIEWS) do
        local id = e[1]
        local b = ISButton:new(0, 0, textW(e[2], f) + 24, fontH(f) + 8, e[2], self, function(win)
            if M.uiSet then M.uiSet("trade.view", id) end
            win.selGroup, win.selRun = nil, nil
            win:buildViewButtons(); win:buildButtons(); win:layout(); win:refresh()
        end)
        b:initialise(); b:instantiate()
        b.font = f
        Th.styleButton(b, id == cur and S.accent or nil)
        self:addChild(b)
        self.viewBtns[#self.viewBtns + 1] = b
    end
end
function TP:layoutMore(top, by)
    local x = 10
    local bh = fontH(self.font or font()) + 8
    for _, b in ipairs(self.viewBtns or {}) do b:setX(x); b:setY(top); x = x + b:getWidth() + 4 end
    local y0 = top + bh + 6
    local h = math.max(40, by - y0 - 6)
    if TP.current() == "roads" and self.map then
        local mh = math.floor(h * 0.62)
        self.map:setVisible(true)
        self.map:setX(10); self.map:setY(y0); self.map:setWidth(self.width - 20); self.map:setHeight(mh)
        self.body:setY(y0 + mh + 6); self.body:setHeight(math.max(30, h - mh - 6))
    else
        if self.map then self.map:setVisible(false) end
        self.body:setY(y0); self.body:setHeight(h)
    end
    pcall(function() self.body:updateScrollbars() end)
end
function TP:refresh()
    if TP.current() == "roads" and self.map then
        self.map:setData(view("trGroups"), view("trRuns"), view("trRoutes"))
    end
    return ALifeTalkHubPage.refresh(self)
end

local function groupCard(g)
    local out = {}
    out[#out + 1] = head(g.name)
    if g.emb then out[#out + 1] = RED .. "Won't trade with you (" .. esc(g.embLeft) .. ")." .. TXT .. " <LINE> " end
    out[#out + 1] = DIM .. "How they are: " .. TXT .. esc(g.wealth ~= "" and g.wealth or "hard to say") .. (g.trader and ", traders" or "") .. " <LINE> "
    if g.mood ~= "" then out[#out + 1] = DIM .. "Word is: " .. TXT .. esc(g.mood) .. " <LINE> " end
    if g.feel ~= "" then out[#out + 1] = DIM .. "Toward you: " .. TXT .. esc(g.feel) .. " <LINE> " end
    if type(g.brain) == "string" and g.brain ~= "" then out[#out + 1] = DIM .. "Brain (dev): " .. TXT .. esc(g.brain) .. " <LINE> " end -- setting brainDebug only
    if g.road ~= "" then out[#out + 1] = DIM .. "The road from you: " .. roadColor(g.road) .. esc(g.road) .. TXT .. (g.hrs ~= "" and (DIM .. ", a walk there gets you there " .. TXT .. esc(g.hrs)) or "") .. " <LINE> " end
    return table.concat(out)
end
local function runLine(r)
    local who = r.mine and (r.names ~= "" and esc(r.names) or "Your people") or ("Traders from " .. esc(r.from))
    local col = r.mine and BLUE or (r.toYou and GOLD or TXT)
    return col .. who .. TXT .. ": " .. esc(r.state) .. DIM .. " (" .. esc(r.cargo) .. ", " .. (r.overdue and (RED .. "overdue" .. DIM) or esc(r.eta)) .. (r.escorted and ", armed escort" or "") .. ")" .. TXT .. " <LINE> "
end

function TP:text()
    local v = TP.current()
    local out = {}
    if v == "post" then
        local rows = view("trPost")
        local post, kinds, traders, market = nil, {}, {}, nil
        for _, r in ipairs(rows) do
            if r.k == "post" then post = r elseif r.k == "kind" then kinds[#kinds + 1] = r elseif r.k == "trader" then traders[#traders + 1] = r elseif r.k == "market" then market = r end
        end
        out[#out + 1] = head(tr("TradePost", "Your trading post"))
        if post == nil or not post.set then
            out[#out + 1] = tr("TradePostNone", "None yet. Right-click a container at your base: Camp > Trading post.") .. " <LINE> "
        else
            out[#out + 1] = DIM .. (post.loaded and "What's in it now:" or "What was in it when you last looked:") .. TXT .. " <LINE> "
            for _, k in ipairs(kinds) do
                if k.n > 0 or k.kind ~= "other" then out[#out + 1] = fillBar(k.fill) .. TXT .. "  " .. esc(k.word) .. DIM .. " - " .. esc(k.fill) .. TXT .. " <LINE> " end
            end
        end
        if market then out[#out + 1] = head("Market day") .. esc(market.when) .. (market.weekly and DIM .. ", every week" .. TXT or "") .. " <LINE> " end
        out[#out + 1] = head(tr("TradeComing", "Traders"))
        if #traders == 0 then out[#out + 1] = DIM .. "Nobody on the way." .. TXT .. " <LINE> " end
        for _, t in ipairs(traders) do out[#out + 1] = GOLD .. esc(t.name) .. TXT .. ": " .. esc(t.where) .. " <LINE> " end
        local p = playerOf()
        local it = nil
        pcall(function() it = p:getPrimaryHandItem() end)
        if it and type(ALifeWorth) == "table" then
            local w = nil
            pcall(function() w = ALifeWorth.item(it) end)
            out[#out + 1] = head(tr("TradeHolding", "What you're holding"))
            out[#out + 1] = esc(it:getDisplayName()) .. ": " .. esc(w and (w >= 20 and "worth a lot" or (w >= 5 and "worth something" or "not worth much")) or "hard to say") .. " <LINE> "
        end
    elseif v == "roads" then
        local groups, runs = view("trGroups"), view("trRuns")
        local g = nil
        for _, x in ipairs(groups) do if x.k == "g" and x.id == self.selGroup then g = x end end
        local r = nil
        for _, x in ipairs(runs) do if x.id == self.selRun then r = x end end
        if g then out[#out + 1] = groupCard(g)
        elseif r then out[#out + 1] = head("On the road") .. runLine(r) .. DIM .. "From " .. esc(r.from) .. " to " .. esc(r.to) .. ". " .. (r.crew == 1 and "One person." or (r.crew .. " people.")) .. TXT .. " <LINE> "
        else
            out[#out + 1] = DIM .. "Click a group or a run on the map." .. TXT .. " <LINE> "
            local n = 0
            for _, x in ipairs(runs) do n = n + 1; out[#out + 1] = runLine(x) end
            if n == 0 then out[#out + 1] = DIM .. "Nobody you know of is on the road right now." .. TXT .. " <LINE> " end
        end
    elseif v == "caravans" then
        out[#out + 1] = head("Your caravans")
        local n = 0
        for _, r in ipairs(view("trRuns")) do if r.mine then n = n + 1; out[#out + 1] = runLine(r) end end
        if n == 0 then out[#out + 1] = DIM .. "None out. Send people with goods from your trading post to trade at a group you know." .. TXT .. " <LINE> " end
        out[#out + 1] = head("At home")
        local crew = view("trCrew")
        if #crew == 0 then out[#out + 1] = DIM .. "Nobody at home to send." .. TXT .. " <LINE> " end
        for _, c in ipairs(crew) do out[#out + 1] = (c.why == "" and (GREEN .. esc(c.name) .. TXT .. ": would go") or (DIM .. esc(c.name) .. ": " .. esc(c.why) .. TXT)) .. " <LINE> " end
    elseif v == "deals" then
        local rows = view("trDeals")
        local offers, deals = {}, {}
        for _, r in ipairs(rows) do if r.k == "offer" then offers[#offers + 1] = r else deals[#deals + 1] = r end end
        if #offers > 0 then
            out[#out + 1] = head("Offers waiting")
            for _, o in ipairs(offers) do out[#out + 1] = GOLD .. esc(o.name) .. TXT .. ": their " .. esc(o.give) .. " for your " .. esc(o.want) .. DIM .. ", every week" .. TXT .. " <LINE> " end
        end
        out[#out + 1] = head("Your deals")
        if #deals == 0 then out[#out + 1] = DIM .. "No standing deals. Propose one to a group you know, or wait for an offer." .. TXT .. " <LINE> " end
        for _, d in ipairs(deals) do
            local hc = ({ ["going well"] = GREEN, ["just agreed"] = TXT, slipping = AMBER, ["about to break"] = RED })[d.health] or TXT
            out[#out + 1] = esc(d.name) .. ": their " .. esc(d.give) .. " for your " .. esc(d.want) .. DIM .. ", every " .. tostring(d.every) .. " days, next " .. esc(d.next) .. TXT .. " - " .. hc .. esc(d.health) .. TXT .. " <LINE> "
        end
    elseif v == "word" then
        local rows = view("trWord")
        local rum, emb, feud = {}, {}, {}
        for _, r in ipairs(rows) do if r.k == "rumor" then rum[#rum + 1] = r elseif r.k == "emb" then emb[#emb + 1] = r else feud[#feud + 1] = r end end
        out[#out + 1] = head("Trade talk")
        if #rum == 0 then out[#out + 1] = DIM .. "Nothing heard. Trade talk comes over the radio, if you have one." .. TXT .. " <LINE> " end
        for _, r in ipairs(rum) do out[#out + 1] = TXT .. esc(r.text) .. DIM .. " (" .. esc(r.ago) .. ")" .. TXT .. " <LINE> " end
        if #emb > 0 then
            out[#out + 1] = head("Won't trade with you")
            for _, e in ipairs(emb) do out[#out + 1] = RED .. esc(e.name) .. TXT .. DIM .. ": " .. esc(e.why) .. ", " .. esc(e.left) .. TXT .. " <LINE> " end
        end
        if #feud > 0 then
            out[#out + 1] = head("Feuds")
            for _, r in ipairs(feud) do out[#out + 1] = AMBER .. esc(r.text) .. TXT .. " <LINE> " end
        end
    end
    return table.concat(out)
end

----------------------------------------------------------------------------------------------------------------
-- buttons (pickers are context menus at the button)
----------------------------------------------------------------------------------------------------------------
local function call(name, ...) if fn(M, name) then pcall(M[name], ...) end end
local function knownGroups()
    local out = {}
    for _, g in ipairs(view("trGroups")) do if g.k == "g" and g.known then out[#out + 1] = g end end
    return out
end
local function kindMenu(cm, title, f, filter)
    local opt = cm:addOption(title)
    local sub = ISContextMenu:getNew(cm)
    cm:addSubMenu(opt, sub)
    for _, k in ipairs(KINDS) do if filter == nil or filter(k[1]) then f(sub, k[1], k[2]) end end
    return sub
end
local function postHas()
    local has = {}
    for _, r in ipairs(view("trPost")) do if r.k == "kind" and (tonumber(r.n) or 0) > 0 then has[r.kind] = true end end
    return has
end
function TP:actions()
    local v = TP.current()
    local win = self
    local a = {}
    if v == "post" then
        a[#a + 1] = { label = tr("BtnPostMenu", "Trading post (here)"), accent = true, fn = function(w, btn) M.winFill(K.menuAt(w, btn), { "tradingpost" }) end }
        a[#a + 1] = { label = tr("BtnRadioTrade", "Radio: traders and market day"), fn = function(w, btn) M.winFill(K.menuAt(w, btn), { "radio" }) end }
    elseif v == "caravans" then
        a[#a + 1] = { label = "Send a caravan", accent = true, fn = function(w, btn)
            local cm = K.menuAt(w, btn)
            local groups = knownGroups()
            local has = postHas()
            if #groups == 0 then cm:addOption("No group knows your place yet"); return end
            for _, g in ipairs(groups) do
                local opt = cm:addOption(tostring(g.name) .. (g.emb and "  (won't trade with you)" or ("  (" .. tostring(g.road) .. " road)")))
                local sub = ISContextMenu:getNew(cm)
                cm:addSubMenu(opt, sub)
                for _, give in ipairs(KINDS) do
                    if has[give[1]] then
                        local o2 = sub:addOption("Take " .. give[2])
                        local sub2 = ISContextMenu:getNew(sub)
                        sub:addSubMenu(o2, sub2)
                        for _, want in ipairs(KINDS) do
                            if want[1] ~= give[1] then sub2:addOption("Bring back " .. want[2], nil, function() call("trOwnSend", g.id, give[1], want[1]); win:refresh() end) end
                        end
                    end
                end
            end
        end }
        a[#a + 1] = { label = "Turn one back", fn = function(w, btn)
            local cm = K.menuAt(w, btn)
            local n = 0
            for _, r in ipairs(view("trRuns")) do
                if r.mine and r.state ~= "coming home" then n = n + 1; cm:addOption((r.names ~= "" and r.names or "Your people") .. ": " .. r.state, nil, function() call("trOwnRecall", r.id); win:refresh() end) end
            end
            if n == 0 then cm:addOption("None on the way out") end
        end }
    elseif v == "deals" then
        a[#a + 1] = { label = "Propose a deal", accent = true, fn = function(w, btn)
            local cm = K.menuAt(w, btn)
            local groups = knownGroups()
            if #groups == 0 then cm:addOption("No group knows your place yet"); return end
            for _, g in ipairs(groups) do
                local opt = cm:addOption(tostring(g.name))
                local sub = ISContextMenu:getNew(cm)
                cm:addSubMenu(opt, sub)
                for _, theirs in ipairs(KINDS) do
                    local o2 = sub:addOption("They bring " .. theirs[2])
                    local sub2 = ISContextMenu:getNew(sub)
                    sub:addSubMenu(o2, sub2)
                    for _, yours in ipairs(KINDS) do
                        if yours[1] ~= theirs[1] then
                            local o3 = sub2:addOption("For your " .. yours[2])
                            local sub3 = ISContextMenu:getNew(sub2)
                            sub2:addSubMenu(o3, sub3)
                            for _, every in ipairs({ 3, 7, 14 }) do
                                sub3:addOption("Every " .. every .. " days", nil, function() call("trDealPropose", g.id, yours[1], theirs[1], every); win:refresh() end)
                            end
                        end
                    end
                end
            end
        end }
        a[#a + 1] = { label = "Answer an offer", fn = function(w, btn)
            local cm = K.menuAt(w, btn)
            local n = 0
            for _, r in ipairs(view("trDeals")) do
                if r.k == "offer" then
                    n = n + 1
                    local opt = cm:addOption(tostring(r.name) .. ": their " .. r.give .. " for your " .. r.want)
                    local sub = ISContextMenu:getNew(cm)
                    cm:addSubMenu(opt, sub)
                    sub:addOption("Accept", nil, function() call("trDealAnswer", r.id, true); win:refresh() end)
                    sub:addOption("Decline", nil, function() call("trDealAnswer", r.id, false); win:refresh() end)
                end
            end
            if n == 0 then cm:addOption("No offers waiting") end
        end }
        a[#a + 1] = { label = "Call off a deal", fn = function(w, btn)
            local cm = K.menuAt(w, btn)
            local n = 0
            for _, r in ipairs(view("trDeals")) do
                if r.k == "deal" then n = n + 1; cm:addOption(tostring(r.name) .. ": their " .. r.give .. " for your " .. r.want, nil, function() call("trDealEnd", r.id); win:refresh() end) end
            end
            if n == 0 then cm:addOption("No deals") end
        end }
    elseif v == "word" then
        a[#a + 1] = { label = "Pay back", accent = true, fn = function(w, btn)
            local cm = K.menuAt(w, btn)
            local n = 0
            for _, r in ipairs(view("trWord")) do
                if r.k == "emb" then n = n + 1; cm:addOption(tostring(r.name) .. " (you have to be at their place)", nil, function() call("trRepay", r.id); win:refresh() end) end
            end
            if n == 0 then cm:addOption("Nobody holds anything against you") end
        end }
        a[#a + 1] = { label = tr("BtnRadio", "Radio"), fn = function(w, btn) M.winFill(K.menuAt(w, btn), { "radio" }) end }
    end
    return a
end

----------------------------------------------------------------------------------------------------------------
-- install: our page takes the "trade" tab (journal tab and hub alike)
----------------------------------------------------------------------------------------------------------------
function TP.install()
    if not fn(M, "hubAddTab") then return false end
    M.hubAddTab({ id = "trade", label = "Trade", class = "ALifeTalkTradeTab", open = function() return K.openPage(TP, "winTrade") end, ref = function() return M.winTrade end }, "journal")
    for _, e in ipairs(M.winHelp or {}) do
        if e[1] == "Trade" then e[2] = "Real people carry real goods on real roads. Trading post, market days, your own caravans, standing deals, trade talk on the radio, and a map of the roads in the Trade tab. Rob traders and word gets out." end
    end
    return true
end
local function tryInstall()
    if M._winInstalled then pcall(TP.install); return end
    if fn(M, "winInstall") and not M._tradeTabWrap then
        M._tradeTabWrap = true
        local inst = M.winInstall
        M.winInstall = function(...) local r = inst(...); pcall(TP.install); return r end
    end
end
tryInstall()
local UIEv = rawget(_G, "Events")
if type(UIEv) == "table" and UIEv.OnGameStart then UIEv.OnGameStart.Add(function() tryInstall(); if M._winInstalled then pcall(TP.install) end end) end
