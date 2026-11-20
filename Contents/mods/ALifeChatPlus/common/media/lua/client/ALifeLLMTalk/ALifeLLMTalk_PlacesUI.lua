-- A-Life Talk 0.5.2: PLACES WINDOW: the NPC bases you know (visited, told about, heard of): name, faction, leader,
-- members, status, mood and food, your last visit and your standing there; "Mark on map" uses A-Life's own marker.
-- Right-click world -> "A-Life: Places...". Every Java / A-Life call guarded.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "PlacesUI"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("PlacesUI") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
require "ALifeLLMTalk/ALifeLLMTalk_Theme"
local T = M.Theme
if T == nil or ALifeLLMTalkWindow == nil then return M end
local S = M.UIStyle
ALifeTalkPlacesWindow = ALifeLLMTalkWindow:derive("ALifeTalkPlacesWindow")
local PW = ALifeTalkPlacesWindow
PW.rowH = 78 -- 0.6.9: + what you know and who told you
function PW:new()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = 680, 440
    w, h = tonumber(M.uiPref("places.w", w)) or w, tonumber(M.uiPref("places.h", h)) or h
    local o = ALifeLLMTalkWindow.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h, M.jnRows and M.settings.journal ~= false and ALifeTr("IGUI_ALCP_Tab_journal", "Journal") or "Places")
    o.rsKey, o.minW, o.minH = "places", 560, 340
    return o
end
function PW:onResized()
    local top = self:contentTop()
    if self.list then
        self.list:setWidth(self.width - S.pad * 2); self.list:setHeight(self.height - top - 80)
        if self.list.vscroll then self.list.vscroll:setHeight(self.list:getHeight()) end
    end
    for _, b in ipairs(self.cmdBtns or {}) do b:setY(self.height - 66) end
end

function PW:createChildren()
    ALifeLLMTalkWindow.createChildren(self)
    local top = self:contentTop()
    local win = self
    self.list = T.list(self, S.pad, top, self.width - S.pad * 2, self.height - top - 80, PW.rowH, function(list, y, item, alt) return win:drawRow(list, y, item, alt) end)
    local bx, by = S.pad, self.height - 66
    self.cmdBtns = {}
    local btns = { { ALifeTr("IGUI_ALCP_JournalMark", "Mark on map"), "mark" }, { ALifeTr("IGUI_ALCP_JournalNotes", "Notes"), "notes" },
        { ALifeTr("IGUI_ALCP_JournalMyNote", "Write a note"), "mynote" }, { ALifeTr("IGUI_ALCP_JournalRefresh", "Refresh"), "refresh" } }
    -- 0.8.8 UI: your lieutenant's reports, scouts, the door (ALifeTalk_SettlementUI)
    if type(ALifeSettlement) == "table" and type(ALifeSettlement.openLog) == "function" then btns[#btns + 1] = { ALifeTr("IGUI_ALCP_JournalCamp", "From your camp"), "camplog" } end
    for _, c in ipairs(btns) do
        local w = T.textW(c[1]) + 20
        self.cmdBtns[#self.cmdBtns + 1] = T.button(self, bx, by, w, 24, c[1], self, function() self:command(c[2]) end)
        bx = bx + w + 6
    end
    self.status = ""
    self:refresh()
end
function PW:selectedRow()
    local it = self.list and self.list.items and self.list.items[self.list.selected or 0] or nil
    return it and it.item or nil
end
function PW:command(cmd)
    if cmd == "refresh" then self:refresh(); self.status = ""; return end
    if cmd == "camplog" then pcall(ALifeSettlement.openLog); return end
    local d = self:selectedRow()
    if d == nil then self.status = "Select a place first."; return end
    if cmd == "mark" then
        if M.jnMark and M.settings.journal ~= false then -- 0.6.9: by hand, on your own map
            local ok, msg = M.jnMark(d.id, ALifeSide.you())
            self.status = tostring(msg or "")
            return
        end
        local ok = M.nbMark and M.nbMark(d.id, ALifeSide.you()) or false
        self.status = ok and (tostring(d.name) .. " marked on your map.") or "Couldn't mark it (A-Life's map marker isn't available)."
    elseif cmd == "mynote" then -- 0.7.0.7: your own notes on a group, kept with this world
        local cur = M.myNote(d.id) or ""
        pcall(function()
            local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
            local w, h = math.min(520, sw - 40), math.min(260, sh - 40)
            local box = ISTextBox:new((sw - w) / 2, (sh - h) / 2, w, h, "Your note on " .. tostring(d.name) .. " (leave empty to delete it)", cur, self, function(win, button)
                if button.internal ~= "OK" then return end
                local txt = button.parent.entry:getText()
                M.setMyNote(d.id, txt)
                win.status = (txt ~= nil and string.gsub(txt, "%s", "") ~= "") and ("Note on " .. tostring(d.name) .. " saved.") or ("Note on " .. tostring(d.name) .. " deleted.")
            end)
            box:setMultipleLine(true)
            box:setNumberOfLines(6)
            box:initialise(); box:addToUIManager()
        end)
    elseif cmd == "notes" then -- 0.6.9: everything you've learned about them, newest first
        local lines = {}
        local mine = M.myNote(d.id)
        if mine then lines[#lines + 1] = "<RGB:0.84,0.7,0.38> Your note: <RGB:1,1,1> " .. string.gsub(string.gsub(mine, "<", "("), "\n", " <LINE> ") .. " <LINE> " end
        for i = #(d.notes or {}), 1, -1 do
            local n = d.notes[i]
            lines[#lines + 1] = "- " .. tostring(n.t) .. " (" .. (M.jnAgo and M.jnAgo(n.h) or "") .. ")"
        end
        local text = tostring(d.name) .. " <LINE> <LINE> " .. (#lines > 0 and table.concat(lines, " <LINE> ") or "Nothing written down yet.")
        pcall(function()
            local modal = ISModalRichText:new(getCore():getScreenWidth() / 2 - 260, getCore():getScreenHeight() / 2 - 180, 520, 360, text, false)
            modal:initialise(); modal:addToUIManager()
        end)
    end
end
-- 0.7.0.7: your own notes, by group id, kept with this world (saved with the groups)
function M.myNote(id)
    local st = M.nbStore and M.nbStore() or nil
    local n = st and type(st.myNotes) == "table" and st.myNotes[tostring(id)] or nil
    if type(n) ~= "string" or string.gsub(n, "%s", "") == "" then return nil end
    return n
end
function M.setMyNote(id, text)
    local st = M.nbStore and M.nbStore() or nil
    if st == nil then return false end
    st.myNotes = type(st.myNotes) == "table" and st.myNotes or {}
    text = tostring(text or "")
    if string.gsub(text, "%s", "") == "" then st.myNotes[tostring(id)] = nil else st.myNotes[tostring(id)] = string.sub(text, 1, 2000) end
    return true
end
function PW:refresh()
    if self.list == nil then return end
    local sel = self.list.selected
    self.list:clear()
    local data = nil
    if ALifeSide.mpClient() and type(ALifeRemote) == "table" then data = ALifeRemote.get("nbRows") end -- pre-1.0 MP: the server's list
    data = data or (M.nbRows and M.nbRows(ALifeSide.you())) or {}
    for _, d in ipairs(data) do self.list:addItem(d.name, d) end
    if sel and sel <= #data then self.list.selected = sel end
    self.count = #data
end
local TIER_C = { welcome = "green", tolerate = "green", neutral = "dim", disliked = "amber", enemy = "red" }
function PW:drawRow(list, y, item, alt)
    local d = item.item
    T.rowBack(list, y, item, alt)
    local a = self.fade or 1
    local c = d.active and S.text or S.dim
    local title = tostring(d.name)
    list:drawText(title, 10, y + 4, c.r, c.g, c.b, a, S.fontTitle)
    list:drawText("(" .. tostring(d.faction) .. ")", 10 + T.textW(title) + 30, y + 6, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    local sc = d.active and S.amber or S.red
    list:drawText(tostring(d.status), 10, y + 24, sc.r, sc.g, sc.b, a, S.font)
    local line = "Leader: " .. tostring(d.leader) .. "   Members: " .. tostring(d.members) .. (d.active and ("   " .. tostring(d.morale) .. ", " .. tostring(d.food)) or "")
    if d.fallen then -- 0.5.2.1: kept as history - who lived there and who was lost
        local lost = type(d.dead) == "table" and table.concat(d.dead, ", ") or ""
        if #lost > 60 then lost = string.sub(lost, 1, 57) .. "..." end
        line = "Lived here: " .. tostring(d.lastMembers or "?") .. (lost ~= "" and ("   Lost: " .. lost) or "")
    end
    list:drawText(line, 10, y + 40, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    local rx = math.floor(list:getWidth() * 0.62)
    local tc = S[TIER_C[d.standing] or "dim"] or S.dim
    list:drawText("Standing: " .. tostring(d.standing) .. (d.guest and " (guest)" or ""), rx, y + 4, tc.r, tc.g, tc.b, a, S.font)
    T.relBar(list, rx, y + 22, 150, 8, (tonumber(d.rep) or 50) * 2 - 100, a)
    list:drawText("Last visit: " .. tostring(d.lastVisit) .. (d.known == "heard" and " (heard of)" or (d.known == "told" and " (they told you)" or (d.known == "radio" and " (radio)" or ""))),
        rx, y + 36, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    if d.learned then list:drawText("What you know: " .. tostring(d.learned), 10, y + 56, S.dim.r, S.dim.g, S.dim.b, a * 0.85, S.font) end -- 0.6.9
    local mine = M.myNote and M.myNote(d.id) -- 0.7.0.7: your own note, first line
    if mine then
        local first = string.match(mine, "^[^\n]*") or ""
        local maxW = list:getWidth() - rx - 10
        local shown = "Your note: " .. first
        if T.textW(shown) > maxW then
            while #shown > 14 and T.textW(shown .. "...") > maxW do shown = string.sub(shown, 1, #shown - 1) end
            shown = shown .. "..."
        end
        list:drawText(shown, rx, y + 56, S.accent.r, S.accent.g, S.accent.b, a, S.font)
    end
    return y + list.itemheight
end
function PW:prerender()
    ALifeLLMTalkWindow.prerender(self)
    self:drawText(tostring(self.status or ""), S.pad, self.height - 34, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, S.font)
    if (self.count or 0) == 0 then
        self:drawTextCentre("You don't know any places yet. Survivors settle in houses - visit them, or ask where people live.",
            self.width / 2, self.height / 2 - 20, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, S.font)
    end
end
function PW:update()
    ALifeLLMTalkWindow.update(self)
    local now = T.now()
    if now - (self.refreshedAt or 0) > 3000 then self.refreshedAt = now; pcall(function() self:refresh() end) end
end
function M.openPlaces()
    if M.placesWindow then pcall(function() M.placesWindow:close() end) end
    M.placesWindow = T.open(PW:new())
    return M.placesWindow
end
if type(Events) == "table" and Events.OnFillWorldObjectContextMenu then
    ALifeRadial.addFiller("places", "windows", function(playerNum, context, worldobjects, test)   -- 0.5.11: radial registry
        if test == true or not M.settings.enabled or M.settings.npcBases == false or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        if M.settings.immersive ~= true then pcall(function() T.menuOption(context, "A-Life: Places...", nil, function() pcall(M.openPlaces) end, "follow") end) end
    end)
end
return M
