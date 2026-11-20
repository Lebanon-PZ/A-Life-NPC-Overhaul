-- A-Life Talk 0.5.1.1: FAVORITES in the Relationships menu.
--   * a clickable star on every row of the list (right edge) and a Favorite button on the list and on each person's page
--   * starred people show a small gold star and stay at the top of the list (whatever the sort)
--   * "Show: Favorites" filter right after "All"
--   * favorites are always protected from deletion (registered with the patch's protectors, like known people)
-- Stored per save in the "favorites" bucket: favorites[uid] = true. Every UI / Java call is guarded.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeLLMTalk_Pairs"
require "ALifeLLMTalk/ALifeLLMTalk_UI"
require "ALifeLLMTalk/ALifeLLMTalk_UIPage"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Favorites"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Favorites") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function log(msg) if M.log then M.log(msg) end end
local function favs() return M.bucket and M.bucket("favorites") or {} end

local GOLD = { r = 0.92, g = 0.76, b = 0.30 }
local DIMSTAR = { r = 0.45, g = 0.45, b = 0.48 }

function M.isFavorite(uid) return uid ~= nil and favs()[tostring(uid)] == true end
function M.setFavorite(uid, on)
    if uid == nil then return end
    local f = favs()
    f[tostring(uid)] = on and true or nil
    if M.logInteraction then pcall(M.logInteraction, tostring(uid), on and "You marked them as a favorite" or "You removed them from favorites", nil, nil, "event") end
    if M.relationList then pcall(function() M.relationList:refresh() end) end
end
function M.toggleFavorite(uid) M.setFavorite(uid, not M.isFavorite(uid)); return M.isFavorite(uid) end

-- five-pointed star (filled when on, outline-ish dim when off); falls back to a "*" if polygons aren't available
function M.drawStar(ui, cx, cy, r, on, a)
    local c = on and GOLD or DIMSTAR
    a = (a or 1) * (on and 1 or 0.7)
    local P = M.Page
    local ri = r * 0.42
    local ok = P and P.quad ~= nil
    if ok then
        for i = 0, 4 do
            local t = -math.pi / 2 + i * 2 * math.pi / 5
            local tl, tr = t - math.pi / 5, t + math.pi / 5
            local drew = P.quad(ui, cx, cy, cx + ri * math.cos(tl), cy + ri * math.sin(tl), cx + r * math.cos(t), cy + r * math.sin(t),
                cx + ri * math.cos(tr), cy + ri * math.sin(tr), c, a)
            if not drew then ok = false; break end
        end
    end
    if not ok then pcall(function() ui:drawTextCentre("*", cx, cy - 8, c.r, c.g, c.b, a, UIFont.Medium) end) end
end

----------------------------------------------------------------------------------------------------------------
-- master list: Favorites filter, favorites first, star column, Favorite button
----------------------------------------------------------------------------------------------------------------
local L = ALifeTalkRelationList
if type(L) == "table" and not L._favInstalled then
    L._favInstalled = true
    L.FILTERS = { "All", "Favorites", "Friends", "Enemies", "Dead" }
    local baseFilterSort = M.filterSortNpcs
    -- filterBy: 1 all, 2 favorites, 3 friends, 4 enemies, 5 dead (old code: 1 all, 2 friends, 3 enemies, 4 dead)
    function M.filterSortNpcs(list, sortBy, filterBy, query)
        local old = filterBy
        if filterBy == 2 then old = 1 elseif type(filterBy) == "number" and filterBy > 2 then old = filterBy - 1 end
        local out = baseFilterSort(list, sortBy, old, query)
        local fav, rest = {}, {}
        for _, n in ipairs(out) do
            if M.isFavorite(n.uid) then n.fav = true; fav[#fav + 1] = n else n.fav = false; rest[#rest + 1] = n end
        end
        if filterBy == 2 then return fav end
        for _, n in ipairs(rest) do fav[#fav + 1] = n end
        return fav
    end

    local baseNew = L.new
    function L:new()
        local o = baseNew(self)
        o.width = math.max(o.width or 480, 590)
        return o
    end

    local baseCreate = L.createChildren
    function L:createChildren()
        baseCreate(self)
        local T = M.Theme
        local by = self.height - 36
        pcall(function()
            self.favBtn = T.button(self, 380, by, 110, 26, ALifeTr("IGUI_ALCP_Btn_Favorite", "Favorite"), self, L.onFavSelected)
            self.favBtn:setTooltip("Star or unstar the selected person (or click the star on their row)")
        end)
        pcall(function()
            local l = self.list
            local baseDown = l.onMouseDown
            local win = self
            l.onMouseDown = function(list, x, y)
                if x >= list:getWidth() - 40 then
                    local row = nil
                    pcall(function() row = list:rowAt(x, y) end)
                    local it = row and list.items[row] or nil
                    if it and it.item and it.item.uid then
                        M.toggleFavorite(it.item.uid)
                        pcall(function() win:refresh() end)
                        return true
                    end
                end
                return baseDown(list, x, y)
            end
        end)
    end

    local baseRefresh = L.refresh
    function L:refresh()
        baseRefresh(self)
        if self.favBtn then
            local n = self:selectedNpc()
            self.favBtn.enable = n ~= nil
            self.favBtn:setTitle(n and M.isFavorite(n.uid) and "Unfavorite" or "Favorite")
        end
    end

    function L:onFavSelected()
        local n = self:selectedNpc()
        if n then M.toggleFavorite(n.uid); self:refresh() end
    end

    local basePre = L.prerender
    function L:prerender()
        basePre(self)
        if self.favBtn then
            local n = self:selectedNpc()
            local want = n and M.isFavorite(n.uid) and "Unfavorite" or "Favorite"
            if self.favBtn:getTitle() ~= want then self.favBtn:setTitle(want) end
            self.favBtn.enable = n ~= nil
        end
    end

    local baseRow = L.drawRow
    function L.drawRow(list, y, item, alt)
        local ny = baseRow(list, y, item, alt)
        local n = item and item.item
        if n then
            local over = false
            pcall(function() over = list:isMouseOver() and list:getMouseX() >= list:getWidth() - 40 and list.mouseoverselected == item.index end)
            if n.fav or over then
                pcall(M.drawStar, list, list:getWidth() - 22, y + list.itemheight / 2, 8, n.fav, n.dead and 0.6 or 1)
            end
        end
        return ny
    end
    pcall(function() if M.relationList and M.relationList.list then M.relationList.list.doDrawItem = L.drawRow end end)
end

----------------------------------------------------------------------------------------------------------------
-- a person's page: Favorite button on the bottom bar (both small and wide page modes) + star by the title
----------------------------------------------------------------------------------------------------------------
local W = ALifeTalkRelationWindow
if type(W) == "table" and not W._favInstalled then
    W._favInstalled = true
    local function place(win)
        if win.favBtn then -- 0.5.2.5: the place the window layout gave it (font aware), else the old spot
            win.favBtn:setX(win.favX or (win.width - 92 - 126))
            win.favBtn:setY((win.lay and win.lay.btnH) and (win.height - win.lay.btnH - 10) or (win.height - 36))
        end
    end
    local baseCreate = W.createChildren
    function W:createChildren()
        baseCreate(self)
        pcall(function()
            self.favBtn = M.Theme.button(self, self.width - 92 - 126, self.height - 36, 120, 26,
                M.isFavorite(self.uid) and "Unfavorite" or "Favorite", self, W.onFav)
            self.favBtn:setTooltip("Favorites stay at the top of the Relationships list and are never removed from the world")
        end)
    end
    function W:onFav()
        M.toggleFavorite(self.uid)
        if self.favBtn then self.favBtn:setTitle(M.isFavorite(self.uid) and "Unfavorite" or "Favorite") end
    end
    local baseMode = W.setPageMode
    if baseMode then
        function W:setPageMode(on) baseMode(self, on); place(self) end
    end
    local basePre = W.prerender
    function W:prerender()
        basePre(self)
        place(self)
        if M.isFavorite(self.uid) then
            local fx = self.favX or (self.width - 92 - 126)
            local by = (self.lay and self.lay.btnH) and (self.height - self.lay.btnH - 10) or (self.height - 36)
            if fx - 14 >= 8 then pcall(M.drawStar, self, fx - 14, by + 13, 7, true, self.fade or 1) end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- protection: favorites are never deleted (same patch hook Keep.lua uses for known people)
----------------------------------------------------------------------------------------------------------------
function M.favInstall()
    local P = M.patch and M.patch() or nil
    if P == nil or M.favHooked then return end
    M.favHooked = true
    P.protectors = P.protectors or {}
    table.insert(P.protectors, function(uid) return M.isFavorite(uid) end)
    log("favorites: registered with the patch (favorites are never removed)")
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.favInstall) end) end
    if Events.OnTick then
        local tries = 0
        local function tick()
            if M.favHooked or tries > 600 then return end
            tries = tries + 1
            pcall(M.favInstall)
        end
        ALifeHealth.tickAdd("ALifeLLMTalk_Favorites", tick)
    end
end

return M
