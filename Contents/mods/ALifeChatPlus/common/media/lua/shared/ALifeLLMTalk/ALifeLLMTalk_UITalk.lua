-- A-Life Talk 0.5.2.10 [pt270u]: THE INTERACTIONS TAB SHOWS WHAT THEY SAID TO EACH OTHER (Dialogue.lua keeps the lines).
-- A filter row on top: All / With you / With others / Person (a list of their ties and everyone they have lines with).
-- NPC lines are rows like the others (date, "Viola > Josh", a TALK / COMFORT / ARGUMENT / CONFESSION chip, the line
-- wrapped); lines you did not hear yourself are dim with "heard about (from X)". Clicking a name on the Web tab opens
-- this tab filtered to that pair. The list is rebuilt only when the lines / filter change (a short key every refresh),
-- the rows cache their wrapped text. Setting: npcDialog.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeLLMTalk_UITalk") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UITalk"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UITalk") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function firstOf(name) return string.match(tostring(name), "^(%S+)") or tostring(name) end

M.dlgChip = { talk = { r = 0.45, g = 0.7, b = 0.95 }, comfort = { r = 0.45, g = 0.78, b = 0.5 },
    argument = { r = 0.88, g = 0.3, b = 0.26 }, confession = { r = 0.92, g = 0.68, b = 0.3 } }

-- an ilog row's game hour (for merging with the NPC lines)
function M.dlgRowHour(r)
    if type(r) ~= "table" then return 0 end
    if tonumber(r.h) then return tonumber(r.h) end
    if type(r.t) == "string" and M.legacyHour then
        local n, hh, mm = string.match(r.t, "^[Dd]ay (%d+),? (%d+):(%d+)")
        local h = n and M.legacyHour(n, hh, mm) or nil
        if h then return h end
    end
    return 0
end

-- the rows for one window: newest first. filter { mode = all | you | others | person, uid }
function M.dlgRows(uid, inter, filter, player)
    filter = filter or { mode = "all" }
    local mode = filter.mode or "all"
    local rows = {}
    if mode == "all" or mode == "you" then
        for i, r in ipairs(inter or {}) do rows[#rows + 1] = { item = r, h = M.dlgRowHour(r), i = i } end
    end
    if M.settings.npcDialog ~= false and M.dlgOf and (mode == "all" or mode == "others" or mode == "person") then
        local list = M.dlgOf(uid, mode == "person" and filter.uid or nil)
        local names = {}
        local function shown(u, stored)
            if names[u] == nil then
                local n = stored
                if player ~= nil and M.shownName and M.settings.nameDiscovery ~= false then
                    local ok, s, known = pcall(M.shownName, u, player)
                    if ok and s then n = known and s or "Stranger" end
                end
                names[u] = tostring(n or "someone")
            end
            return names[u]
        end
        for i, e in ipairs(list) do
            rows[#rows + 1] = { item = { dlg = true, e = e, fn = shown(e.f, e.fn), tn = shown(e.to, e.tn), h = e.h }, h = tonumber(e.h) or 0, i = 1000 + i }
        end
    end
    table.sort(rows, function(a, b) if a.h ~= b.h then return a.h > b.h end return a.i > b.i end)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.item end
    return out
end

function M.dlgUIInstall()
    local W = ALifeTalkRelationWindow
    if W == nil or W._dlgUI then return end
    local T, S = M.Theme, M.UIStyle
    if T == nil or S == nil or W.TAB == nil or W.TAB.interactions == nil then return end
    W._dlgUI = true
    local F = M.Fancy

    local MODES = { { "all", "All" }, { "you", "With you" }, { "others", "With others" } }
    function W:dlgEnsure()
        if self.dlgBtns ~= nil or M.settings.npcDialog == false then return end
        self.dlgBtns = {}
        self.dlgFilter = self.dlgFilter or { mode = "all" }
        local fh = T.fontH()
        for i, m in ipairs(MODES) do
            local key = m[1]
            local b = T.button(self, self.cx or 176, 0, T.textW(m[2]) + 20, fh + 6, m[2], self, function(win) win:dlgSetFilter(key) end)
            b.dlgMode = key
            self.dlgBtns[i] = b
        end
        self.dlgBtns.person = T.button(self, self.cx or 176, 0, 160, fh + 6, ALifeTr("IGUI_ALCP_Btn_Person", "Person..."), self, function(win, btn) win:dlgPersonMenu(btn) end)
        if self.fitLayout then self:fitLayout(true) else self:dlgPlace() end
        self:dlgVisible(self.activeTab == W.TAB.interactions and not self.pageMode)
    end
    function W:dlgPlace()
        local b = self.dlgBtns
        if b == nil or self.intList == nil then return end
        local fh = T.fontH()
        local bh = fh + 6
        local x, y = self.intList:getX(), self.intList:getY()
        for i = 1, #MODES do b[i]:setX(x); b[i]:setY(y); b[i]:setHeight(bh); x = x + b[i].width + 4 end
        local pw = math.max(120, math.min(220, self.width - x - 14))
        b.person:setX(x + 8); b.person:setY(y); b.person:setWidth(pw); b.person:setHeight(bh)
        self.intList:setY(y + bh + 6)
        local h = math.max(40, self.intList.height - bh - 6)
        self.intList:setHeight(h)
        if self.intList.vscroll then pcall(function() self.intList.vscroll:setHeight(h) end) end
    end
    function W:dlgVisible(on)
        if self.dlgBtns == nil then return end
        for i = 1, #MODES do self.dlgBtns[i]:setVisible(on) end
        self.dlgBtns.person:setVisible(on)
    end
    function W:dlgTitles()
        local b, f = self.dlgBtns, self.dlgFilter or { mode = "all" }
        if b == nil then return end
        for i = 1, #MODES do
            local sel = b[i].dlgMode == f.mode
            if T.styleButton then pcall(T.styleButton, b[i], sel and ((F and F.C and F.C.gold) or S.accent) or nil) end
            b[i].dlgSelected = sel
        end
        local t = (f.mode == "person" and f.name) and ("With " .. firstOf(f.name)) or "Person..."
        b.person:setTitle(T.fit(t, b.person.width - 12))
        b.person.dlgSelected = f.mode == "person"
    end
    function W:dlgSetFilter(mode, uid, name)
        self:dlgEnsure()
        if mode == "person" and uid == nil then mode = "all" end
        self.dlgFilter = { mode = mode or "all", uid = uid and tostring(uid) or nil, name = name }
        self:dlgTitles()
        self.dlgKey = nil
        self:dlgFill()
    end
    -- the people to pick: their ties + anyone they have lines with
    function W:dlgPeopleList()
        local out, seen = {}, {}
        for _, p in ipairs(M.dlgPeople and M.dlgPeople(self.uid) or {}) do
            if not seen[p.uid] then seen[p.uid] = true; out[#out + 1] = { uid = p.uid, name = p.name, n = p.n } end
        end
        for _, t in ipairs((self.data and self.data.ties) or {}) do
            local u = tostring(t.uid)
            if not seen[u] then seen[u] = true; out[#out + 1] = { uid = u, name = t.name, n = 0 } end
        end
        return out
    end
    function W:dlgPersonMenu(btn)
        local list = self:dlgPeopleList()
        if #list == 0 then return end
        local okMenu = false
        if ISContextMenu ~= nil and type(ISContextMenu.get) == "function" then
            okMenu = pcall(function()
                local ctx = ISContextMenu.get(0, getMouseX(), getMouseY())
                for _, p in ipairs(list) do
                    local label = tostring(p.name) .. ((p.n or 0) > 0 and ("  (" .. tostring(p.n) .. ")") or "")
                    ctx:addOption(label, self, function(win) win:dlgSetFilter("person", p.uid, p.name) end)
                end
            end)
        end
        if not okMenu then -- no menu: the next person in the list
            local f, at = self.dlgFilter or {}, 1
            for i, p in ipairs(list) do if f.mode == "person" and p.uid == f.uid then at = (i % #list) + 1 end end
            self:dlgSetFilter("person", list[at].uid, list[at].name)
        end
    end
    function W:dlgFill()
        if self.intList == nil or M.settings.npcDialog == false then return end
        local d = self.data or {}
        local f = self.dlgFilter or { mode = "all" }
        local inter = d.interactions or {}
        local nDlg = 0
        if M.dlgOf then
            local idx = M.bucket("dlgIdx")[tostring(self.uid)]
            for k in pairs(type(idx) == "table" and idx or {}) do local l = M.bucket("dlg")[k]; nDlg = nDlg + (type(l) == "table" and #l or 0) * 7 + (type(l) == "table" and #l > 0 and math.floor((tonumber(l[#l].h) or 0) * 10) % 997 or 0) end
        end
        local key = table.concat({ tostring(f.mode), tostring(f.uid), #inter, tostring(inter[#inter] and inter[#inter].w), nDlg }, "|")
        if key == self.dlgKey then return end
        self.dlgKey = key
        local rows = M.dlgRows(self.uid, inter, f, ALifeSide.you())
        self.intList:clear()
        if #rows == 0 then
            local msg = (f.mode == "you" and "No interactions logged yet.") or (f.mode == "person" and ("Nothing heard between them and " .. firstOf(f.name or "them") .. " yet."))
                or (f.mode == "others" and "You haven't heard them talk with anyone yet.") or "No interactions logged yet."
            self.intList:addItem("none", { w = msg, t = "" })
        end
        for _, r in ipairs(rows) do self.intList:addItem(r.dlg and tostring(r.e.x) or tostring(r.w or ""), r) end
        self.dlgRowsN = #rows
    end

    local baseRefresh, baseShow, baseFit, baseDraw = W.refresh, W.showTab, W.fitLayout, W.drawInteraction
    function W:refresh()
        baseRefresh(self)
        if M.settings.npcDialog ~= false and self.intList then
            -- base refresh refilled the list with your rows: put the merged rows back (rebuilt only when changed)
            self.dlgKey = nil
            pcall(function() self:dlgFill() end)
        end
    end
    function W:showTab(i)
        baseShow(self, i)
        if i == W.TAB.interactions and not self.pageMode and M.settings.npcDialog ~= false then pcall(function() self:dlgEnsure(); self:dlgTitles() end) end
        self:dlgVisible(i == W.TAB.interactions and not self.pageMode and M.settings.npcDialog ~= false)
    end
    if baseFit then
        function W:fitLayout(force)
            local before = self.layoutCount
            local L = baseFit(self, force)
            if self.dlgBtns and (self.layoutCount ~= before) then pcall(function() self:dlgPlace() end) end
            return L
        end
    end
    function W.drawInteraction(list, y, item, alt)
        local r = item.item
        if type(r) ~= "table" or not r.dlg then return baseDraw(list, y, item, alt) end
        local e = r.e
        local fh = T.fontH()
        local lw = list:getWidth() - 20
        local heard = not e.s
        local a = heard and 0.6 or 1
        local text = "\"" .. tostring(e.x) .. "\""
        local lines
        if F and F.rowLines then lines = F.rowLines(list, item, text, lw - 26, 3) else lines = { T.fit(text, lw - 26) } end
        item.height = math.max(list.itemheight or 36, 8 + fh + 6 + #lines * fh + 8)
        T.rowBack(list, y, item, alt)
        local C = (F and F.C) or {}
        local dim, txt, nameC = C.dim or S.dim, C.txt or S.text, C.name or S.accent
        local when = M.whenText and M.whenText(e) or ""
        list:drawText(T.fit(when, math.floor(lw * 0.3)), 14, y + 7, dim.r, dim.g, dim.b, 1, S.font)
        local kc = M.dlgChip[e.k] or M.dlgChip.talk
        local chip = M.dlgKinds and M.dlgKinds[e.k] or string.upper(tostring(e.k or "talk"))
        local cw = (F and F.pillW) and F.pillW(chip) or (T.textW(chip) + 16)
        local cx = lw - 8 - cw
        if F and F.pill then F.pill(list, cx, y + 5, chip, kc, a) else T.badge(list, cx, y + 5, chip, kc, a) end
        local nx = 14 + math.floor(lw * 0.3) + 8
        local who = firstOf(r.fn) .. "  >  " .. firstOf(r.tn)
        local tail = heard and ("  heard about" .. (e.src and (" (from " .. firstOf(e.src) .. ")") or "")) or ""
        local room = math.max(0, cx - 8 - nx)
        local whoFit = T.fit(who, room)
        list:drawText(whoFit, nx, y + 7, nameC.r, nameC.g, nameC.b, a, S.font)
        if tail ~= "" and T.textW(whoFit) + 10 < room then
            list:drawText(T.fit(tail, room - T.textW(whoFit) - 4), nx + T.textW(whoFit) + 4, y + 7, dim.r, dim.g, dim.b, 0.9, S.font)
        end
        for i, ln in ipairs(lines) do list:drawText(ln, 16, y + 7 + fh + 6 + (i - 1) * fh, txt.r, txt.g, txt.b, a, S.font) end
        return y + item.height
    end
end

M.dlgUIInstall()
return M
