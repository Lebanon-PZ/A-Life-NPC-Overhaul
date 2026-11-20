-- A-Life NPC Overhaul 0.6.10: ONE WINDOW, TABS.
--
-- Everything you look at lives in one window: People (relationships), Party, Journal (places and groups), Camp (the
-- camp board) and Settings, as tabs in its header. Switching a tab swaps the page in place (same spot on screen), so
-- there's only ever one A-Life window open instead of a pile of them.
-- One way in, everywhere: right-click "A-Life..." (and the A-Life radial), the sidebar buttons, or a key you set in
-- Mod Options ("A-Life window"). It reopens on the tab you used last, where you left it.
-- The separate right-click entries (Places, Party, Relationships) fold into it. Setting "hubWindow" off brings the
-- old separate windows back. A person's own page (from People) still opens on its own.
-- Performance: nothing runs until a window is open; the tabs are a few buttons in the header.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Hub"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Hub") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local T, S = M.Theme, M.UIStyle
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end

if M.settings.hubWindow == nil then M.settings.hubWindow = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, k in ipairs(M.fileKeys) do if k == "hubWindow" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "hubWindow" end
end
-- 0.7.0.3: on in immersive mode too (the default). The 0.7 window is journal style, no numbers; before, immersive
-- (on by default) quietly switched the window, its key and its menu entry off.
function M.hubOn() return M.settings.hubWindow ~= false and M.settings.enabled ~= false end

----------------------------------------------------------------------------------------------------------------
-- the Camp tab: the camp board in a page of the same window
----------------------------------------------------------------------------------------------------------------
local function campPage()
    if ALifeTalkCampPage ~= nil or ALifeLLMTalkWindow == nil then return ALifeTalkCampPage end
    ALifeTalkCampPage = ALifeLLMTalkWindow:derive("ALifeTalkCampPage")
    local CP = ALifeTalkCampPage
    function CP:new()
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        local w, h = 560, 460
        return ALifeLLMTalkWindow.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h, "Camp")
    end
    function CP:createChildren()
        ALifeLLMTalkWindow.createChildren(self)
        local top = self:contentTop()
        self.body = ISRichTextPanel:new(8, top, self.width - 16, self.height - top - 10)
        self.body:initialise()
        self.body.background = false
        self.body.autosetheight = false
        self.body.clip = true
        self.body.marginLeft, self.body.marginRight = 8, 8
        self:addChild(self.body)
        self.body:addScrollBars()
        self:refresh()
    end
    function CP:refresh()
        local ok, txt = false, nil
        if fn(M, "bdText") then ok, txt = pcall(M.bdText, ALifeSide.you()) end
        self.body.text = ok and txt or "No camp yet. Settle people at your base and their day shows up here."
        self.body:paginate()
        self.refreshedAt = getTimestampMs()
    end
    function CP:update()
        ALifeLLMTalkWindow.update(self)
        if getTimestampMs() - (self.refreshedAt or 0) > 3000 then pcall(function() self:refresh() end) end
    end
    function CP:close() ALifeLLMTalkWindow.close(self); if M.hubCampWindow == self then M.hubCampWindow = nil end end
    return CP
end
function M.hubOpenCamp()
    local CP = campPage()
    if CP == nil then return nil end
    if M.hubCampWindow then pcall(function() M.hubCampWindow:close() end) end
    M.hubCampWindow = T.open(CP:new())
    return M.hubCampWindow
end

----------------------------------------------------------------------------------------------------------------
-- the tabs
----------------------------------------------------------------------------------------------------------------
M.hubTabs = {
    { id = "people", label = "People", class = "ALifeTalkRelationList", open = function() return M.openRelationList and M.openRelationList() end,
      ref = function() return M.relationList end },
    { id = "party", label = "Party", class = "ALifeTalkPartyWindow", open = function() return M.openParty and M.openParty() end,
      ref = function() return M.partyWindow end, show = function() return M.settings.party ~= false end },
    { id = "journal", label = "Journal", class = "ALifeTalkPlacesWindow", open = function() return M.openPlaces and M.openPlaces() end,
      ref = function() return M.placesWindow end, show = function() return M.settings.npcBases ~= false end },
    { id = "camp", label = "Camp", class = "ALifeTalkCampPage", open = function() return M.hubOpenCamp() end,
      ref = function() return M.hubCampWindow end, show = function() return fn(M, "bdText") end },
    { id = "settings", label = "Settings", class = "ALifeTalkSettings", open = function() return M.openSettings and M.openSettings() end,
      ref = function() return M.settingsWindow end },
}
local byClass, byId = {}, {}
-- 0.7.0: tabs can be added or replaced later (ALifeTalk_Window.lua); the index is rebuilt each time
function M.hubIndex()
    byClass, byId = {}, {}
    for _, t in ipairs(M.hubTabs) do byClass[t.class] = t; byId[t.id] = t end
end
M.hubIndex()
-- add a tab (before the tab with id `before`, else at the end), or replace the one with the same id
function M.hubAddTab(def, before)
    for i, t in ipairs(M.hubTabs) do
        if t.id == def.id then M.hubTabs[i] = def; M.hubIndex(); return def end
    end
    local at = #M.hubTabs + 1
    for i, t in ipairs(M.hubTabs) do if t.id == before then at = i; break end end
    table.insert(M.hubTabs, at, def)
    M.hubIndex()
    return def
end
M.hubState = M.hubState or { last = "people", x = nil, y = nil }
local function visible(w) local v = false; pcall(function() v = w ~= nil and w:isVisible() == true end); return v end
local function shown(t) return t.show == nil or t.show() == true end

-- the open A-Life window (one of the tabs), or nil
function M.hubCurrent()
    for _, t in ipairs(M.hubTabs) do local w = t.ref(); if visible(w) then return w, t end end
    return nil
end
-- open a tab (or the last one used) in place of whatever A-Life window is open
function M.hubOpen(id)
    local t = byId[id or M.hubState.last] or byId.people
    if not shown(t) then t = byId.people end
    local cur, ct = M.hubCurrent()
    local x, y = M.hubState.x, M.hubState.y
    if cur then x, y = cur:getX(), cur:getY(); if ct ~= t then pcall(function() cur:close() end) end end
    local w = nil
    local ok, res = pcall(t.open)
    if ok then w = res or t.ref()
    else
        -- 0.7.0.3: never fail silently; say why once, and fall back to another tab
        M.hubFaults = M.hubFaults or {}
        if not M.hubFaults[t.id] then M.hubFaults[t.id] = true; print("[ALifeHub] the " .. tostring(t.id) .. " tab failed to open (logged once): " .. tostring(res)) end
        if t.id ~= "people" and byId.people then
            local ok2, res2 = pcall(byId.people.open)
            if ok2 then w = res2 or byId.people.ref(); t = byId.people end
        end
    end
    if w and x and y then
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        pcall(function()
            w:setX(math.max(0, math.min(x, sw - w:getWidth())))
            w:setY(math.max(0, math.min(y, sh - 60)))
        end)
    end
    M.hubState.last = t.id
    return w
end
-- the key / sidebar: open it, or close it if it's open
function M.hubToggle(id)
    local cur, ct = M.hubCurrent()
    if cur and (id == nil or ct.id == id) then
        M.hubState.x, M.hubState.y = cur:getX(), cur:getY()
        pcall(function() cur:close() end)
        return false
    end
    M.hubOpen(id)
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the header: tabs in place of the title (any of our windows that is a tab page)
----------------------------------------------------------------------------------------------------------------
local W = ALifeLLMTalkWindow
function M.hubInstallHeader()
    if W == nil or W._alcpHub then return W ~= nil end
    W._alcpHub = true
    local create, prerender, close = W.createChildren, W.prerender, W.close
    W.createChildren = function(self, ...)
        local r = create(self, ...)
        local t = byClass[self.Type or ""]
        if t and M.hubOn() then
            pcall(function()
                self.hubTab = t.id
                self.hubTitle = self.title
                self.title = ""
                self.hubButtons = {}
                local x, hh = 12, S.headerH
                -- 0.7.0: tabs that don't fit go under "More" (narrow windows, big fonts)
                local moreW = T.textW(ALifeTr("IGUI_ALCP_Tab_More", "More")) + 18
                local list, extra = {}, {}
                for _, tab in ipairs(M.hubTabs) do if shown(tab) then list[#list + 1] = tab end end
                for i, tab in ipairs(list) do
                    local label = ALifeTr("IGUI_ALCP_Tab_" .. tab.id, tab.label)
                    local wdt = T.textW(label) + 18
                    local room = self.width - hh - 4 - (i < #list and (moreW + 4) or 0)
                    if #extra > 0 or x + wdt > room then
                        extra[#extra + 1] = tab
                    else
                        local b = ISButton:new(x, 3, wdt, hh - 6, label, self, function() M.hubOpen(tab.id) end)
                        b:initialise(); b:instantiate()
                        T.styleButton(b, tab.id == t.id and S.accent or nil)
                        b.hubId = tab.id
                        if type(AA_Tip) == "table" then b.alcpTip = AA_Tip.tabTip(tab.id) end -- pre-1.0: what the tab is (hover)
                        self:addChild(b)
                        self.hubButtons[#self.hubButtons + 1] = b
                        x = x + wdt + 4
                    end
                end
                if #extra > 0 then
                    local cur = false
                    for _, tab in ipairs(extra) do if tab.id == t.id then cur = true end end
                    local b = ISButton:new(x, 3, moreW, hh - 6, ALifeTr("IGUI_ALCP_Tab_More", "More"), self, function(win, btn)
                        local cm = ISContextMenu.get(0, win:getAbsoluteX() + btn:getX(), win:getAbsoluteY() + btn:getY() + btn:getHeight())
                        for _, tab in ipairs(extra) do
                            cm:addOption(ALifeTr("IGUI_ALCP_Tab_" .. tab.id, tab.label), nil, function() M.hubOpen(tab.id) end)
                        end
                    end)
                    b:initialise(); b:instantiate()
                    T.styleButton(b, cur and S.accent or nil)
                    b.hubId = cur and t.id or "_more"
                    if type(AA_Tip) == "table" then b.alcpTip = AA_Tip.tabTip("_more") end
                    self:addChild(b)
                    self.hubButtons[#self.hubButtons + 1] = b
                end
            end)
        end
        return r
    end
    W.prerender = function(self, ...)
        local r = prerender(self, ...)
        if self.hubButtons then
            for _, b in ipairs(self.hubButtons) do
                if b.hubId == self.hubTab then
                    self:drawRect(b:getX() + 2, b:getY() + b:getHeight(), b:getWidth() - 4, 2, self.fade or 1, S.accent.r, S.accent.g, S.accent.b)
                end
            end
        end
        return r
    end
    W.close = function(self, ...)
        if self.hubTab then M.hubState.x, M.hubState.y, M.hubState.last = self:getX(), self:getY(), self.hubTab end
        return close(self, ...)
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the ways in: one right-click entry, the sidebar, a key
----------------------------------------------------------------------------------------------------------------
local FOLD = { places = true, party = true, relationships = true }
function M.hubInstallMenus()
    if type(ALifeRadial) ~= "table" or not fn(ALifeRadial, "addFiller") or M._alcpHubMenus then return false end
    M._alcpHubMenus = true
    -- the separate entries fold into the window (they come back with hubWindow off)
    for _, e in ipairs(ALifeRadial.fillers or {}) do
        if FOLD[e.id] and type(e.fn) == "function" and not e.hubWrapped then
            local old = e.fn
            e.fn = function(...) if M.hubOn() then return end; return old(...) end
            e.hubWrapped = true
        end
    end
    ALifeRadial.addFiller("hub", "windows", function(playerNum, context, worldobjects, test)
        if test == true or not M.hubOn() or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        pcall(function() T.menuOption(context, ALifeTr("IGUI_ALCP_HubOpen", "A-Life..."), nil, function() M.hubOpen() end, "heart") end)
        -- 0.6.19 debug only: put every chokepoint on your map (to check them against the real map)
        local dbg = false
        pcall(function() dbg = getDebug() == true end)
        if dbg and fn(M, "chkMarkMap") then
            pcall(function() context:addOption(ALifeTr("IGUI_ALCP_Menu_A_Life_debug_mark_chokepoints_on_map", "A-Life (debug): mark chokepoints on map"), nil, function() local n = M.chkMarkMap(); print("[ALifeChokepoints] marked " .. tostring(n)) end) end)
        end
    end)
    if fn(M, "sideToggle") then
        local toggle = M.sideToggle
        M.sideToggle = function(id, ...)
            if M.hubOn() then return M.hubToggle(id == "rel" and "people" or "party") end
            return toggle(id, ...)
        end
    end
    if type(Events) == "table" and Events.OnKeyPressed then
        ALifeHealth.add(Events.OnKeyPressed, "ALifeTalk_Hub", function(key)
            local opt = ALifeRadial.hubKeyOpt
            local k = nil
            pcall(function() k = opt and opt:getValue() end)
            if k and k ~= 0 and key == k and M.hubOn() then pcall(M.hubToggle) end
        end)
    end
    return true
end

local function install()
    local a = M.hubInstallHeader()
    local b = M.hubInstallMenus()
    if a and b then print("[ALifeHub] loaded v0.6.10 (one A-Life window: People, Party, Journal, Camp, Settings as tabs)") end
    return a and b
end
if not install() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(install) end
