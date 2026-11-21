-- A-Life NPC Overhaul pre-1.0: the People list (A-Life's Contacts tab) GROUPED. Kind headers (Your people, Hostile to
-- you, Raiders, Friendly, Traders, Faithful, Keep to themselves, Can't tell yet, Dead), and under each the group you
-- suspect them of running with ("the Riverside Wolves", or "Met near Muldraugh" while you don't know their group).
-- Click a header to fold / unfold it. Big groups start folded (setting peopleFoldAt); a name search opens everything.
-- Starred people get their own section on top. Sort / Show / search still work inside the groups.
-- Who goes where: M.suspectOf (shared/ALifeLLMTalk/ALifeTalk_Suspect.lua). Setting peopleGroups=false = the old flat list.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeLLMTalk_UI"
require "ALifeLLMTalk/ALifeLLMTalk_UIFancy"
require "ALifeLLMTalk/ALifeLLMTalk_Favorites"
require "ALifeLLMTalk/ALifeTalk_Suspect"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "PeopleGroups"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("PeopleGroups") end end

local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.suspectOf) ~= "function" then return end
local L = ALifeTalkRelationList
if type(L) ~= "table" or L._groupsInstalled then return end
L._groupsInstalled = true

local function on() return M.settings.peopleGroups ~= false end
M.peopleFold = M.peopleFold or {} -- fold key -> true folded / false open (this session; default from the size)

-- rows (already filtered + sorted, favorites first) -> header items + people, in kind order
function M.peopleGroupRows(rows, player, opts)
    opts = opts or {}
    local ctx = M.suspectContext(rows, player)
    local cats, catList = {}, {}
    for _, n in ipairs(rows) do
        local s = n.fav and { cat = "starred", group = "starred" } or M.suspectOf(n, ctx)
        local c = cats[s.cat]
        if c == nil then c = { id = s.cat, groups = {}, order = {}, n = 0 }; cats[s.cat] = c; catList[#catList + 1] = c end
        local g = c.groups[s.group]
        if g == nil then g = { key = s.cat .. "|" .. s.group, label = s.label, people = {} }; c.groups[s.group] = g; c.order[#c.order + 1] = g end
        g.people[#g.people + 1] = n
        c.n = c.n + 1
    end
    table.sort(catList, function(a, b) return (M.suspectCatOrder[a.id] or 99) < (M.suspectCatOrder[b.id] or 99) end)
    local foldAt = tonumber(M.settings.peopleFoldAt) or 3
    local out = {}
    for _, c in ipairs(catList) do
        local label = c.id
        for _, d in ipairs(M.suspectCats) do if d.id == c.id then label = d.label end end
        local ckey = "cat|" .. c.id
        local cFold = M.peopleFold[ckey]
        if cFold == nil then cFold = (c.id == "dead") end
        if opts.openAll then cFold = false end
        out[#out + 1] = { header = 1, key = ckey, label = label, count = c.n, folded = cFold }
        if not cFold then
            for _, g in ipairs(c.order) do
                local inner = g.people
                if g.label ~= nil then
                    local gFold = M.peopleFold[g.key]
                    if gFold == nil then gFold = #g.people >= foldAt end
                    if opts.openAll then gFold = false end
                    out[#out + 1] = { header = 2, key = g.key, label = g.label, count = #g.people, folded = gFold }
                    if gFold then inner = {} end
                end
                for _, n in ipairs(inner) do n.indent = g.label ~= nil and 2 or 1; out[#out + 1] = n end
            end
        end
    end
    return out
end

local baseRefresh = L.refresh
function L:refresh()
    baseRefresh(self)
    if not on() or self.list == nil then return end
    local selUid = nil
    local cur = self:selectedNpc()
    if cur then selUid = cur.uid end
    local rows = {}
    for _, it in ipairs(self.list.items) do if type(it.item) == "table" and not it.item.header then rows[#rows + 1] = it.item end end
    local openAll = (self.query ~= nil and self.query ~= "") or (self.filterBy ~= nil and self.filterBy ~= 1)
    local okG, items = pcall(M.peopleGroupRows, rows, ALifeSide.you(), { openAll = openAll })
    if not okG or type(items) ~= "table" then return end
    self.list:clear()
    local hh = (M.Theme and M.Theme.fontH and M.Theme.fontH() or 16) + 10
    for i, n in ipairs(items) do
        local it = self.list:addItem(n.header and n.label or n.name, n)
        if n.header and it then it.height = hh end
        if not n.header and n.uid == selUid then self.list.selected = i end
    end
    if self.list.items[self.list.selected] and self.list.items[self.list.selected].item.header then
        for i, it in ipairs(self.list.items) do if not it.item.header then self.list.selected = i; break end end
    end
end

function L:peopleToggle(h)
    if type(h) ~= "table" or not h.header then return end
    M.peopleFold[h.key] = not h.folded
    pcall(function() self:refresh() end)
end

local baseSel = L.selectedNpc
function L:selectedNpc()
    local n = baseSel(self)
    if type(n) == "table" and n.header then return nil end
    return n
end
local baseOpen = L.onOpen
function L:onOpen(n)
    if type(n) == "table" and n.header then return self:peopleToggle(n) end
    return baseOpen(self, n)
end

local baseCreate = L.createChildren
function L:createChildren()
    baseCreate(self)
    pcall(function()
        local l, win = self.list, self
        local down = l.onMouseDown
        l.onMouseDown = function(list, x, y)
            local row = -1
            pcall(function() row = list:rowAt(x, y) end)
            local it = row and list.items[row] or nil
            if on() and it and type(it.item) == "table" and it.item.header then win:peopleToggle(it.item); return true end
            return down(list, x, y)
        end
    end)
end

local baseRow = L.drawRow
function L.drawRow(list, y, item, alt)
    local n = item and item.item
    if type(n) ~= "table" or not n.header then return baseRow(list, y, item, alt) end
    local T, S = M.Theme, M.UIStyle
    local h = item.height or list.itemheight
    local top = n.header == 1
    local x = top and 6 or 22
    local tc = top and ((M.Fancy and M.Fancy.C and M.Fancy.C.gold) or { r = 0.84, g = 0.70, b = 0.38 }) or S.text
    pcall(function() list:drawRect(x - 2, y + 1, list:getWidth() - x - 4, h - 2, top and 0.35 or 0.18, 0.2, 0.22, 0.25) end)
    local txt = (n.folded and "+ " or "- ") .. tostring(n.label) .. "  (" .. tostring(n.count) .. ")"
    list:drawText(txt, x + 4, y + math.floor((h - (T.fontH and T.fontH() or 16)) / 2), tc.r, tc.g, tc.b, 1, S.font)
    return y + h
end
pcall(function() if M.relationList and M.relationList.list then M.relationList.list.doDrawItem = L.drawRow end end)

print("[ALifeTalk_PeopleGroups] ready pre-1.0: People list folds by kind and suspected group")
return M
