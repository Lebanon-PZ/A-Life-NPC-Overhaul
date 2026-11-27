-- A-Life NPC Overhaul pre-1.0: THE WORK TAB (docs/PLAN-WORK.md). A grid: your people down the side, every kind of camp
-- work across the top (camp roles, then Jeem base jobs). Click a cell to set a priority (1 first .. 4 last, then
-- "never", then unset; right-click goes back). Click a name: "do this now" (they're locked on it till you let them
-- choose) or "let them choose". A button switches the camp brain on / off. Orders only reach people within the
-- workRange tiles of their base's edge (greyed rows say why). Client only draws: rows come from the "wkRows" view,
-- clicks call the exposed world functions (wkPrio, wkOrder, wkFree, wkDial). One Brain: the dial button (Off / Advisor
-- / Run it) and a "What we know" page (the camp's beliefs about every group, what was said, ideas waiting: view byKnow).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeTalk_Window"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.winKit) ~= "table" then return end
local K = M.winKit
local Th, S = M.Theme, M.UIStyle
local tr = K.tr
ALifeWorkTab = ALifeWorkTab or {}
local WT = ALifeWorkTab
WT.VERSION = ALifeSide.MOD_VERSION

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function rows() if type(ALifeRemote) ~= "table" then return {} end; local v = ALifeRemote.get("wkRows", playerOf()); return type(v) == "table" and v or {} end
local function knowRows() if type(ALifeRemote) ~= "table" then return {} end; local v = ALifeRemote.get("byKnow", playerOf()); return type(v) == "table" and v or {} end
local function orderRows() if type(ALifeRemote) ~= "table" then return {} end; local v = ALifeRemote.get("byOrders", playerOf()); return type(v) == "table" and v or {} end
local function font() return M.qolFont and M.qolFont("auto") or UIFont.Small end
local function fontH(f) local h = 16; pcall(function() h = getTextManager():getFontHeight(f) end); return h end
local function textW(t, f) local w = 8 * #tostring(t); pcall(function() w = getTextManager():MeasureStringX(f, tostring(t)) end); return w end
local function split(s) local out = {}; for part in string.gmatch(tostring(s or ""), "[^|]+") do out[#out + 1] = part end; return out end
local function call(name, ...) if fn(M, name) then local ok, err = pcall(M[name], ...); if not ok then print("[ALifeWorkTab] " .. name .. " failed: " .. tostring(err)) end end end
local function toast(t) if fn(M, "momToast") then pcall(M.momToast, t) end end
-- the cycle a left click walks (right click: backwards). -1 = unset
WT.CYCLE = { -1, 1, 2, 3, 4, 0 }
local function nextLevel(cur, back)
    local at = 1
    for i, v in ipairs(WT.CYCLE) do if v == cur then at = i end end
    at = at + (back and -1 or 1)
    if at < 1 then at = #WT.CYCLE elseif at > #WT.CYCLE then at = 1 end
    return WT.CYCLE[at]
end
-- shift cells: Day / Evening / Night, a click walks Sleep > Work > Guard > Free
WT.SHIFTS = { "day", "evening", "night" }
WT.SHIFT_LABEL = { "Day", "Eve", "Night" }
WT.SCYCLE = { "S", "W", "G", "F" }
WT.SKIND = { S = "sleep", W = "work", G = "guard", F = "free" }
WT.SWORD = { S = "Sleep", W = "Work", G = "Guard", F = "Free", ["-"] = "-" }
local function nextShift(ch, back)
    local at = 0
    for i, v in ipairs(WT.SCYCLE) do if v == ch then at = i end end
    at = at + (back and -1 or 1)
    if at < 1 then at = #WT.SCYCLE elseif at > #WT.SCYCLE then at = 1 end
    return WT.SCYCLE[at]
end
local function levelOf(ch) if ch == "-" or ch == "." then return -1 end; return tonumber(ch) or -1 end

----------------------------------------------------------------------------------------------------------------
-- the grid
----------------------------------------------------------------------------------------------------------------
ALifeWorkGrid = ISPanel:derive("ALifeWorkGrid")
local G = ALifeWorkGrid
function G:new(x, y, w, h, owner)
    local o = ISPanel.new(self, x, y, w, h)
    o.owner = owner
    o.background = false
    o.scroll = 0
    o.head, o.people, o.works, o.labels = nil, {}, {}, {}
    return o
end
function G:setData(list)
    self.head, self.people = nil, {}
    for _, r in ipairs(list or {}) do
        if r.k == "head" then self.head = r elseif r.k == "p" then self.people[#self.people + 1] = r end
    end
    self.works = self.head and split(self.head.works) or {}
    self.labels = self.head and split(self.head.labels) or {}
end
function G:metrics()
    local f = self.owner and self.owner.font or font()
    local rh = fontH(f) + 8
    local nameW = 120
    for _, p in ipairs(self.people) do nameW = math.max(nameW, textW(p.name, f) + 16) end
    nameW = math.min(nameW, 200)
    local n = math.max(1, #self.works)
    local sw = math.max(44, textW("Guard", f) + 10)
    local cw = math.max(34, math.floor((self.width - nameW - 120 - 3 * sw - 10) / n))
    return f, rh, nameW, cw, sw
end
function G:labelOf(id)
    for i, w in ipairs(self.works) do if w == id then return self.labels[i] or id end end
    if id == "general" then return "General" end
    return id
end
function G:render()
    local f, rh, nameW, cw, sw = self:metrics()
    local sx = nameW + #self.works * cw + 10
    -- header: work names (shortened to the column)
    local y = 0
    self:drawRect(0, 0, self.width, rh + 4, 0.35, 0.1, 0.1, 0.1)
    self:drawText(tr("IGUI_ALCP_Work_Who", "Who"), 6, 4, 0.9, 0.8, 0.5, 1, f)
    for i, lab in ipairs(self.labels) do
        local x = nameW + (i - 1) * cw
        local s = lab
        while #s > 2 and textW(s, f) > cw - 4 do s = string.sub(s, 1, #s - 1) end
        self:drawTextCentre(s, x + cw / 2, 4, 0.9, 0.8, 0.5, 1, f)
    end
    for i, lab in ipairs(WT.SHIFT_LABEL) do self:drawTextCentre(lab, sx + (i - 1) * sw + sw / 2, 4, 0.55, 0.75, 0.95, 1, f) end
    self:drawText(tr("IGUI_ALCP_Work_Doing", "Doing now"), sx + 3 * sw + 6, 4, 0.9, 0.8, 0.5, 1, f)
    y = rh + 6
    self:setStencilRect(0, y, self.width, self.height - y)
    local hx, hy = self:getMouseX(), self:getMouseY()
    for idx, p in ipairs(self.people) do
        local ry = y + (idx - 1) * rh - self.scroll
        if ry + rh >= y and ry <= self.height then
            local a = p.near and 1 or 0.45
            if idx % 2 == 0 then self:drawRect(0, ry, self.width, rh, 0.12, 1, 1, 1) end
            if hy >= ry and hy < ry + rh and hy >= y then self:drawRect(0, ry, self.width, rh, 0.1, 0.9, 0.8, 0.5) end
            local nm = p.name .. (p.lock and " *" or "")
            self:drawText(nm, 6, ry + 4, 0.95, 0.95, 0.95, a, f)
            for i = 1, #self.works do
                local ch = string.sub(p.prio or "", i, i)
                local x = nameW + (i - 1) * cw
                local r, g, b, txt = 0.6, 0.6, 0.6, ch
                if ch == "1" then r, g, b = 0.4, 0.9, 0.4 elseif ch == "2" then r, g, b = 0.75, 0.85, 0.4 elseif ch == "3" then r, g, b = 0.9, 0.75, 0.35
                elseif ch == "4" then r, g, b = 0.85, 0.55, 0.35 elseif ch == "0" then r, g, b, txt = 0.8, 0.3, 0.3, "x"
                elseif ch == "x" then r, g, b, txt = 0.35, 0.35, 0.35, "" elseif ch == "." then txt = "." else txt = "-" end
                if self.works[i] == p.cur then self:drawRectBorder(x + 2, ry + 1, cw - 4, rh - 2, 0.8 * a, 0.95, 0.85, 0.4) end
                self:drawTextCentre(txt, x + cw / 2, ry + 4, r, g, b, a, f)
            end
            for i = 1, 3 do
                local ch = string.sub(p.shifts or "---", i, i)
                local r, g, b = 0.6, 0.6, 0.6
                if ch == "W" then r, g, b = 0.4, 0.9, 0.4 elseif ch == "G" then r, g, b = 0.9, 0.6, 0.35 elseif ch == "S" then r, g, b = 0.55, 0.7, 0.95 end
                self:drawTextCentre(WT.SWORD[ch] or "-", sx + (i - 1) * sw + sw / 2, ry + 4, r, g, b, a, f)
            end
            local doing = self:labelOf(p.cur)
            if not p.near and p.why then doing = doing .. "  (" .. p.why .. ")" end
            self:drawText(doing, sx + 3 * sw + 6, ry + 4, 0.85, 0.85, 0.85, a, f)
        end
    end
    self:clearStencilRect()
    if #self.people == 0 then
        self:drawText(tr("IGUI_ALCP_Work_Nobody", "Nobody lives at your base yet."), 6, y + 4, 0.7, 0.7, 0.7, 1, f)
    end
end
function G:onMouseWheel(del)
    local _, rh = self:metrics()
    local maxS = math.max(0, #self.people * rh - (self.height - rh - 6))
    self.scroll = math.max(0, math.min(maxS, self.scroll + del * rh))
    return true
end
-- which person / column is under (x, y)
function G:hit(x, y)
    local _, rh, nameW, cw, sw = self:metrics()
    local top = rh + 6
    if y < top then return nil end
    local idx = math.floor((y - top + self.scroll) / rh) + 1
    local p = self.people[idx]
    if p == nil then return nil end
    if x < nameW then return p, "name" end
    local col = math.floor((x - nameW) / cw) + 1
    if col >= 1 and col <= #self.works then return p, col end
    local sx = nameW + #self.works * cw + 10
    local si = math.floor((x - sx) / sw) + 1
    if x >= sx and si >= 1 and si <= 3 then return p, "s" .. si end
    return p, "doing"
end
function G:click(x, y, back)
    local p, col = self:hit(x, y)
    if p == nil then return end
    if not p.near then toast((p.name or "") .. ": " .. tostring(p.why or tr("IGUI_ALCP_Work_Far", "Too far from the base to hear you."))); return end
    if type(col) == "string" and string.sub(col, 1, 1) == "s" then
        local i = tonumber(string.sub(col, 2))
        local ch = nextShift(string.sub(p.shifts or "---", i, i), back)
        call("wkShift", p.uid, WT.SHIFTS[i], WT.SKIND[ch], playerOf())
        local s = p.shifts or "---"
        p.shifts = string.sub(s, 1, i - 1) .. ch .. string.sub(s, i + 1)
        if self.owner then self.owner.dirtyAt = 0 end
        return
    end
    if type(col) == "number" then
        local ch = string.sub(p.prio or "", col, col)
        if ch == "x" then toast(tr("IGUI_ALCP_Work_Cant", "They can't do that here (the base is missing what it needs, or it's a base job and they don't live at a Jeem base).")); return end
        local lv = nextLevel(levelOf(ch), back)
        call("wkPrio", p.uid, self.works[col], lv, playerOf())
        -- show it at once (the view catches up)
        local s = p.prio or ""
        p.prio = string.sub(s, 1, col - 1) .. (lv < 0 and "-" or tostring(lv)) .. string.sub(s, col + 1)
        if self.owner then self.owner.dirtyAt = 0 end
        return
    end
    self:personMenu(p)
end
function G:onMouseUp(x, y) self:click(x, y, false); return true end
function G:onRightMouseUp(x, y) self:click(x, y, true); return true end
function G:personMenu(p)
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    cm:addOption(tr("IGUI_ALCP_Work_DoNow", "Do this now:"), nil, nil)
    for i, id in ipairs(self.works) do
        if string.sub(p.prio or "", i, i) ~= "x" then
            cm:addOption("   " .. (self.labels[i] or id), p, function(pp) call("wkOrder", pp.uid, id, playerOf()) end)
        end
    end
    cm:addOption("   " .. tr("IGUI_ALCP_Work_General", "Whatever needs doing (General)"), p, function(pp) call("wkOrder", pp.uid, "general", playerOf()) end)
    if p.lock then cm:addOption(tr("IGUI_ALCP_Work_Free", "Let them choose by priority again"), p, function(pp) call("wkFree", pp.uid, playerOf()) end) end
end

----------------------------------------------------------------------------------------------------------------
-- the page
----------------------------------------------------------------------------------------------------------------
function WT.addTab()
    if WT.tabAdded then return true end
    if not fn(M, "hubAddTab") or ALifeTalkHubPage == nil then return false end
    local P = K.page("ALifeTalkWorkPage", "Work", "work",
        tr("IGUI_ALCP_Work_Tip", "<SIZE:medium> Work <LINE> <SIZE:small> Who does what at camp, without walking over to ask. Click a box: 1 is what they do first, 4 last, x never (right-click goes back). Day, Eve and Night are their shifts (Sleep, Work, Guard, Free): click to change. Click a name to give an order now. Orders only reach people near the base. The camp brain thinks like any group: Off, Advisor (your people bring you ideas, anything that sends people out asks first) or Run it (trade, scouts and peace talks go, you're told after; fights always ask). What we know: everything your people saw or heard about the groups around you."))
    WT.P = P
    function P:createChildren()
        self.grid = ALifeWorkGrid:new(10, 40, 100, 100, self)
        self.grid:initialise()
        ALifeTalkHubPage.createChildren(self)
        self:addChild(self.grid)
        self:layout()
        self:refresh()
    end
    function P:layoutMore(top, by)
        local lines = 3
        local bodyH = (fontH(self.font or font()) + 2) * lines + 8
        if self.know or self.orders then bodyH = math.max(40, by - top - 6) end
        if self.grid then self.grid:setVisible(not (self.know or self.orders)) end
        self.body:setY(top); self.body:setHeight(bodyH)
        if self.grid then
            self.grid:setX(10); self.grid:setY(top + bodyH + 4)
            self.grid:setWidth(self.width - 20); self.grid:setHeight(math.max(40, by - top - bodyH - 10))
        end
        pcall(function() self.body:updateScrollbars() end)
    end
    function P:knowText()
        local list = knowRows()
        local head = nil
        for _, r in ipairs(list) do if r.k == "head" then head = r end end
        if head == nil then return K.DIM .. tr("IGUI_ALCP_Work_Wait", "Asking around...") end
        local out = { K.GOLD .. tr("IGUI_ALCP_Know_Title", "What we know") .. " <LINE> " }
        if head.line and head.line ~= "" then out[#out + 1] = K.TXT .. tostring(head.line) .. " <LINE> " end
        out[#out + 1] = " <LINE> "
        local any = false
        for _, r in ipairs(list) do
            if r.k == "g" then
                any = true
                out[#out + 1] = K.GOLD .. tostring(r.name) .. K.TXT .. ": " .. (r.what ~= "" and tostring(r.what) or tr("IGUI_ALCP_Know_Little", "not much to go on"))
                    .. (r.grudge and tr("IGUI_ALCP_Know_Grudge", ". We owe them one") or "") .. " <LINE> "
                    .. K.DIM .. "   " .. tostring(r.src) .. ", " .. tostring(r.age) .. " (" .. tostring(r.sure) .. ") <LINE> "
            end
        end
        if not any then out[#out + 1] = K.DIM .. tr("IGUI_ALCP_Know_None", "Nothing yet. Scouts, traders and the radio bring news.") .. " <LINE> " end
        local asks, said = {}, {}
        for _, r in ipairs(list) do if r.k == "ask" then asks[#asks + 1] = r.t elseif r.k == "said" then said[#said + 1] = r.t end end
        if #asks > 0 then
            out[#out + 1] = " <LINE> " .. K.GOLD .. tr("IGUI_ALCP_Know_Asks", "Waiting on your answer") .. " <LINE> "
            for _, t in ipairs(asks) do out[#out + 1] = K.TXT .. tostring(t) .. " <LINE> " end
        end
        if #said > 0 then
            out[#out + 1] = " <LINE> " .. K.GOLD .. tr("IGUI_ALCP_Know_Said", "Lately") .. " <LINE> "
            for _, t in ipairs(said) do out[#out + 1] = K.DIM .. tostring(t) .. " <LINE> " end
        end
        return table.concat(out)
    end
    -- Brain 2: standing orders + lieutenants (view byOrders; calls byOrder / byLt)
    function P:ordersText()
        local list = orderRows()
        if #list == 0 then return K.DIM .. tr("IGUI_ALCP_Work_Wait", "Asking around...") end
        local out = { K.GOLD .. tr("IGUI_ALCP_Orders_Title", "Standing orders") .. " <LINE> " .. K.DIM .. tr("IGUI_ALCP_Orders_Hint", "Ideas that break an order never reach you. Ones an order allows go without asking (fights still ask).") .. " <LINE> <LINE> " }
        local heads = { trade = tr("IGUI_ALCP_Orders_Trade", "Trade"), people = tr("IGUI_ALCP_Orders_People", "People"), diplomacy = tr("IGUI_ALCP_Orders_Diplo", "Diplomacy"), war = tr("IGUI_ALCP_Orders_War", "War") }
        local lastG = nil
        for _, r in ipairs(list) do
            if r.k == "order" then
                if r.group ~= lastG then lastG = r.group; out[#out + 1] = K.GOLD .. tostring(heads[r.group] or r.group) .. " <LINE> " end
                local val = r.on == true and tr("IGUI_ALCP_Orders_Yes", "yes") or (r.on == nil and tostring(r.word) or tr("IGUI_ALCP_Orders_No", "no"))
                out[#out + 1] = (r.on == false and K.DIM or K.TXT) .. "   " .. tostring(r.label) .. ": " .. val .. " <LINE> "
            end
        end
        out[#out + 1] = " <LINE> " .. K.GOLD .. tr("IGUI_ALCP_Lt_Title", "Lieutenants") .. " <LINE> "
        for _, r in ipairs(list) do
            if r.k == "lt" then
                local who = r.name and (tostring(r.name) .. " (" .. tostring(r.trust) .. ")") or (r.unsure and tr("IGUI_ALCP_Lt_Unsure", "nobody: still sorting out who") or tr("IGUI_ALCP_Lt_You", "you"))
                out[#out + 1] = K.TXT .. "   " .. tostring(r.label) .. ": " .. who .. " <LINE> "
            end
        end
        return table.concat(out)
    end
    function P:orderMenu()
        local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
        for _, r in ipairs(orderRows()) do
            if r.k == "order" then
                local val = r.on == true and "yes" or (r.on == nil and tostring(r.word) or "no")
                cm:addOption(tostring(r.label) .. ": " .. val, r, function(rr) call("byOrder", rr.key, nil, playerOf()); self.dirtyAt = 0 end)
            end
        end
    end
    function P:ltMenu()
        local list = orderRows()
        local who = {}
        for _, r in ipairs(list) do if r.k == "who" then who[#who + 1] = r end end
        local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
        for _, r in ipairs(list) do
            if r.k == "lt" then
                local opt = cm:addOption(tostring(r.label) .. ": " .. tostring(r.name or tr("IGUI_ALCP_Lt_You", "you")), nil, nil)
                local sub = cm:getNew(cm)
                cm:addSubMenu(opt, sub)
                sub:addOption(tr("IGUI_ALCP_Lt_Me", "I'll run it myself"), r, function(rr) call("byLt", rr.branch, "none", playerOf()); self.dirtyAt = 0 end)
                for _, w in ipairs(who) do
                    sub:addOption(tostring(w.name), { b = r.branch, u = w.uid }, function(x) call("byLt", x.b, x.u, playerOf()); self.dirtyAt = 0 end)
                end
            end
        end
    end
    function P:text()
        if self.orders then return self:ordersText() end
        if self.know then return self:knowText() end
        local list = rows()
        local head = nil
        for _, r in ipairs(list) do if r.k == "head" then head = r end end
        if self.grid then self.grid:setData(list) end
        if head == nil then return K.DIM .. tr("IGUI_ALCP_Work_Wait", "Asking around...") end
        local dial = tonumber(head.dial) or 0
        local dw = ({ [0] = tr("IGUI_ALCP_Work_DialOff", "Off"), [1] = tr("IGUI_ALCP_Work_DialAdvisor", "Advisor"), [2] = tr("IGUI_ALCP_Work_DialRun", "Run it") })[dial] or "?"
        return K.GOLD .. tr("IGUI_ALCP_Work_Brain", "Camp brain: ") .. dw .. " <LINE> "
            .. K.TXT .. tostring(head.words or "") .. " <LINE> "
            .. K.DIM .. tr("IGUI_ALCP_Work_Range", "Orders reach people up to {1} tiles from the base. * = on your order.", tostring(head.range or 100))
    end
    function P:prerender()
        ALifeTalkHubPage.prerender(self)
        local t = type(getTimestampMs) == "function" and getTimestampMs() or 0
        if t - (self.dirtyAt or 0) > 2500 then self.dirtyAt = t; self:refresh() end
    end
    function P:actions()
        local dial = 0
        for _, r in ipairs(rows()) do if r.k == "head" then dial = tonumber(r.dial) or 0 end end
        local nextD = (dial + 1) % 3
        local names = { [0] = tr("IGUI_ALCP_Work_DialOff", "Off"), [1] = tr("IGUI_ALCP_Work_DialAdvisor", "Advisor"), [2] = tr("IGUI_ALCP_Work_DialRun", "Run it") }
        return {
            { label = tr("IGUI_ALCP_Work_Dial", "Camp brain: {1}", names[dial] or "?"), accent = dial == 0,
              tip = tr("IGUI_ALCP_Work_DialTip", "Click for {1}. Off: nothing happens unless you start it. Advisor: the camp sorts out who does what within your priorities, and your people bring you ideas (trade runs, scouts, raids) to say yes or no to. Run it: trade runs, scouts and peace talks go without asking, you're told after. Raids, wars and tribute always ask.", names[nextD] or "?"),
              fn = function(win) call("wkDial", nextD, playerOf()); win.dirtyAt = 0; win:buildButtons(); win:layout() end },
            { label = self.know and tr("IGUI_ALCP_Work_People", "Back to people") or tr("IGUI_ALCP_Work_Know", "What we know"),
              tip = tr("IGUI_ALCP_Work_KnowTip", "Everything your people saw or heard about the groups around you: how strong next to us, fed or hungry, hostile, how sure and how old the news is."),
              fn = function(win) win.know = not win.know; win.orders = false; win.dirtyAt = 0; win:buildButtons(); win:layout(); pcall(function() win:refresh() end) end },
            { label = self.orders and tr("IGUI_ALCP_Work_People", "Back to people") or tr("IGUI_ALCP_Work_Orders", "Orders"),
              tip = tr("IGUI_ALCP_Work_OrdersTip", "Standing orders (what the camp may and may not do without you) and lieutenants (members who run a branch for you)."),
              fn = function(win) win.orders = not win.orders; win.know = false; win.dirtyAt = 0; win:buildButtons(); win:layout(); pcall(function() win:refresh() end) end },
            self.orders and { label = tr("IGUI_ALCP_Orders_Change", "Change an order"), tip = tr("IGUI_ALCP_Orders_ChangeTip", "Click an order to flip it (or step to the next choice)."),
              fn = function(win) win:orderMenu() end } or nil,
            self.orders and { label = tr("IGUI_ALCP_Lt_Pick", "Pick lieutenants"), tip = tr("IGUI_ALCP_Lt_PickTip", "Put someone in charge of Trade, War, Scouting, Diplomacy or Home. Their nature runs it; they make the small calls and bring you the big ones."),
              fn = function(win) win:ltMenu() end } or nil,
        }
    end
    function P:refresh()
        local r = ALifeTalkHubPage.refresh(self)
        local dial = 0
        for _, x in ipairs(rows()) do if x.k == "head" then dial = tonumber(x.dial) or 0 end end
        if self._dialShown ~= dial then self._dialShown = dial; self:buildButtons(); self:layout() end
        return r
    end
    M.hubAddTab({ id = "work", label = "Work", class = "ALifeTalkWorkPage", open = function() return K.openPage(P, "winWork") end,
        ref = function() return M.winWork end, show = function() return M.settings.workTab ~= false end }, "trade")
    WT.tabAdded = true
    return true
end
-- the journal shows it next to Camp
if type(ALifeJournalTabs) == "table" and type(ALifeJournalTabs.order) == "table" then
    local have = false
    for _, id in ipairs(ALifeJournalTabs.order) do if id == "work" then have = true end end
    if not have then
        for i, id in ipairs(ALifeJournalTabs.order) do if id == "camp" then table.insert(ALifeJournalTabs.order, i + 1, "work"); have = true; break end end
        if not have then ALifeJournalTabs.order[#ALifeJournalTabs.order + 1] = "work" end
    end
end

local function tryInstall()
    if M._winInstalled then pcall(WT.addTab); return end
    if fn(M, "winInstall") and not M._workTabWrap then
        M._workTabWrap = true
        local inst = M.winInstall
        M.winInstall = function(...) local r = inst(...); pcall(WT.addTab); return r end
    end
end
tryInstall()
local UIEv = rawget(_G, "Events")
if type(UIEv) == "table" and UIEv.OnGameStart then
    UIEv.OnGameStart.Add(function()
        tryInstall()
        if M._winInstalled then pcall(WT.addTab) end
        print("[ALifeWorkTab] ready v" .. WT.VERSION .. ": Work tab " .. (WT.tabAdded and "in" or "not in yet"))
    end)
end
