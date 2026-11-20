-- A-Life Talk 0.5.1.3: two square icon buttons in the vanilla left sidebar (ISEquippedItem column - inventory,
-- health, crafting, map, ...): "Relationships" and "Party". Click = open / close that window. The icon turns white
-- while its window is open. Setting sideButtons (default on) hides them; right-click "A-Life: Hide/Show
-- sidebar buttons" toggles it too.
-- Placement is re-checked once a second: below the lowest visible vanilla (or other mod's) button, same x, same size
-- and gap, so it follows the sidebar size option, resolution changes and mods that add their own buttons. If the
-- column can't take children or there is no room, a tiny panel sits right next to / below the column instead.
-- Replaces the user's floating "ALifeLLMTalkSide" panel + J key (0.5.1 user edit).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeLLMTalk_Sidebar") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Sidebar"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Sidebar") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("sideButtons", true)

M.side = M.side or { btns = {}, sig = nil, mode = nil, panel = nil, last = 0, log = {} }
local SB = M.side
SB.defs = {
    { id = "rel", tip = "Relationships", off = "media/ui/ALifeTalk/side_rel_off.png", on = "media/ui/ALifeTalk/side_rel_on.png" },
    { id = "party", tip = "Party", off = "media/ui/ALifeTalk/side_party_off.png", on = "media/ui/ALifeTalk/side_party_on.png" },
}

local function sideLog(msg)
    if SB.log[msg] then return end
    SB.log[msg] = true
    print("[ALifeTalk][Side] " .. tostring(msg))
end
local function visible(w)
    if w == nil then return false end
    local v = false
    pcall(function() v = w:isVisible() == true end)
    return v
end
function M.sideWindowOpen(id)
    if id == "rel" then return visible(M.relationList) end
    return visible(M.partyWindow)
end
function M.sideToggle(id)
    if M.sideWindowOpen(id) then
        if id == "rel" then pcall(function() M.relationList:close() end); M.relationList = nil
        else pcall(function() M.partyWindow:close() end); M.partyWindow = nil end
        return false
    end
    if id == "rel" and M.openRelationList then pcall(M.openRelationList) end
    if id == "party" and M.openParty then pcall(M.openParty) end
    return true
end
local function tex(path) local t = nil; pcall(function() t = getTexture(path) end); return t end

local function makeButton(def, size)
    local b = ISButton:new(0, 0, size, size, "", nil, function() M.sideToggle(def.id); SB.paint() end)
    b:initialise()
    b.alifeTalkSide = def.id
    b.texOff, b.texOn = tex(def.off), tex(def.on)
    if b.texOff then b:setImage(b.texOff) else b:setTitle(def.id == "rel" and "Rel" or "Party") end
    pcall(function() b:forceImageSize(size, size) end)
    pcall(function() b:setDisplayBackground(false) end)
    b.borderColor = { r = 1, g = 1, b = 1, a = 0 }
    b.tipText = def.tip
    return b
end
function SB.paint()
    for _, b in pairs(SB.btns) do
        local on = M.sideWindowOpen(b.alifeTalkSide)
        if b.texOff then pcall(function() b:setImage(on and (b.texOn or b.texOff) or b.texOff) end) end
    end
end
local function tooltip(b, owner)
    if type(AA_Tip) == "table" and type(AA_Tip.own) == "function" then AA_Tip.own(b, b.tipText); return end -- pre-1.0: the delayed hover tip
    if owner ~= nil and type(owner.addMouseOverToolTipItem) == "function" then
        if not b.tipAdded then b.tipAdded = owner; pcall(function() owner:addMouseOverToolTipItem(b, b.tipText) end) end
    else pcall(function() b:setTooltip(b.tipText) end) end
end
local function detach()
    for _, b in pairs(SB.btns) do
        pcall(function() if b.parent ~= nil then b.parent:removeChild(b) end end)
        b.parent = nil
        pcall(function() b:setVisible(false) end)
    end
    if SB.panel then pcall(function() SB.panel:setVisible(false); SB.panel:removeFromUIManager() end); SB.panel = nil end
    SB.mode, SB.sig = nil, nil
    SB.colY, SB.colH, SB.colInst = nil, nil, nil
end
M.sideDetach = detach

-- the vanilla column: lowest visible child (not ours), its x / size / gap
-- 0.5.1.4: `below` = the y where our buttons already sit. Other mods' buttons placed at or below it are ignored
-- (they were put "below the lowest button" = below ours; counting them made both mods leapfrog down the screen
-- every second until ours fell off into the fallback panel). Ones that overlap our buttons still count.
function M.sideLayout(inst, below, ourH)
    local maxB, x, size, gap, n = nil, nil, nil, nil, 0
    local ys = {}
    local kids = inst.children
    if type(kids) ~= "table" and inst.getChildren then pcall(function() kids = inst:getChildren() end) end
    for _, ch in pairs(type(kids) == "table" and kids or {}) do
        if type(ch) == "table" and ch.alifeTalkSide == nil then
            local vis = true
            pcall(function() vis = ch:isVisible() ~= false end)
            local cy, ch_h, cx, cw = nil, nil, nil, nil
            pcall(function() cy, ch_h, cx, cw = ch:getY(), ch:getHeight(), ch:getX(), ch:getWidth() end)
            local skip = false
            if below ~= nil and cy ~= nil and cy >= below - 1 then
                skip = not (ourH ~= nil and ch_h ~= nil and cy < below + ourH and cy + ch_h > below + 1)
            end
            if vis and not skip and cy and ch_h and ch_h > 4 and ch_h < 200 then
                n = n + 1
                ys[#ys + 1] = { y = cy, b = cy + ch_h }
                if maxB == nil or cy + ch_h > maxB then maxB = cy + ch_h end
            end
        end
    end
    local ref = inst.invBtn or inst.healthBtn
    pcall(function() x, size = ref:getX(), ref:getWidth() end)
    table.sort(ys, function(a, b) return a.y < b.y end)
    for i = 2, #ys do
        local g = ys[i].y - ys[i - 1].b
        if g >= 0 and g <= 20 then gap = g; break end
    end
    return { bottom = maxB, x = x or 5, size = size or 40, gap = gap or 5, n = n }
end

-- setX/setY are ISUIElement methods; a stripped-down element (or another mod's replacement) may lack them
local function place(el, x, y)
    if not pcall(function() el:setX(x); el:setY(y) end) then el.x, el.y = x, y end
end

local function fallbackPanel(x, y, size, gap)
    if SB.panel == nil then
        SB.panel = ISPanel:new(x, y, size, size * 2 + gap)
        SB.panel:initialise()
        SB.panel.backgroundColor = { r = 0.06, g = 0.06, b = 0.07, a = 0.55 }
        SB.panel.borderColor = { r = 0.3, g = 0.3, b = 0.32, a = 0.8 }
        SB.panel.alifeTalkSidePanel = true
        SB.panel:addToUIManager()
    end
    place(SB.panel, x, y)
    pcall(function() SB.panel:setWidth(size); SB.panel:setHeight(size * 2 + gap) end)
    pcall(function() SB.panel:setVisible(true) end)
    return SB.panel
end

function M.sideEnsure(force)
    if M.settings.sideButtons == false or M.settings.enabled == false then
        if SB.mode ~= nil then detach(); sideLog("hidden (setting sideButtons off)") end
        return nil
    end
    if type(ISButton) ~= "table" or type(ISButton.new) ~= "function" then return nil end
    local inst = type(ISEquippedItem) == "table" and ISEquippedItem.instance or nil
    local sw, sh = 1920, 1080
    pcall(function() sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight() end)
    local below = (SB.mode == "column" and SB.colY ~= nil and SB.colInst == inst) and SB.colY or nil
    local lay = inst and M.sideLayout(inst, below, below and SB.colH or nil) or nil
    local size = lay and lay.size or 40
    local ih = 0
    pcall(function() ih = inst:getHeight() end)
    local sig = tostring(inst ~= nil) .. "|" .. tostring(ih) .. "|" .. (lay and (tostring(lay.bottom) .. "|" .. lay.x .. "|" .. size .. "|" .. lay.gap .. "|" .. lay.n) or "") .. "|" .. sw .. "x" .. sh
    for _, def in ipairs(SB.defs) do
        local b = SB.btns[def.id]
        if b == nil or b.sizeMade ~= size then
            if b then pcall(function() if b.parent then b.parent:removeChild(b) end end) end
            b = makeButton(def, size); b.sizeMade = size; SB.btns[def.id] = b
            sig = sig .. "|new"
        end
    end
    -- our buttons still attached where we put them? (another mod / the size option may have rebuilt the column)
    if SB.mode == "column" and inst ~= nil then
        local found = 0
        for _, ch in pairs(type(inst.children) == "table" and inst.children or {}) do if type(ch) == "table" and ch.alifeTalkSide then found = found + 1 end end
        if found < 2 then sig = sig .. "|lost" end
    end
    if not force and sig == SB.sig then SB.paint(); return SB.mode end
    -- churn guard: something keeps moving the column; stop following it for a minute (one log line)
    local now = M.nowMs and M.nowMs() or 0
    SB.moves = SB.moves or {}
    local recent = {}
    for _, t in ipairs(SB.moves) do if now - t < 30000 then recent[#recent + 1] = t end end
    SB.moves = recent
    if not force and SB.mode ~= nil and #recent >= 6 then
        if not SB.frozen then SB.frozen = true; sideLog("the sidebar keeps changing (another mod?) - buttons stay where they are") end
        SB.paint(); return SB.mode
    end
    SB.frozen = false
    SB.moves[#SB.moves + 1] = now
    SB.sig = sig
    local rel, party = SB.btns.rel, SB.btns.party
    -- 1) inside the vanilla column, right below the lowest button
    if inst ~= nil and lay.bottom ~= nil then
        local y1 = lay.bottom + lay.gap
        local y2 = y1 + size + lay.gap
        local absY = 0
        pcall(function() absY = inst:getAbsoluteY() end)
        if absY + y2 + size + 4 <= sh then
            local ok = pcall(function()
                for _, b in ipairs({ rel, party }) do
                    if b.parent ~= inst then
                        if b.parent ~= nil then b.parent:removeChild(b) end
                        inst:addChild(b)
                        b.parent = inst
                    end
                end
                place(rel, lay.x, y1); place(party, lay.x, y2)
                rel:setVisible(true); party:setVisible(true)
                if inst:getHeight() < y2 + size + lay.gap then inst:setHeight(y2 + size + lay.gap) end
            end)
            if ok then
                if SB.panel then pcall(function() SB.panel:setVisible(false); SB.panel:removeFromUIManager() end); SB.panel = nil end
                tooltip(rel, inst); tooltip(party, inst)
                SB.mode = "column"
                SB.colY, SB.colH, SB.colInst = y1, (y2 - y1) + size, inst
                sideLog("buttons in the left sidebar below the lowest button (y " .. math.floor(y1) .. ", size " .. size .. ")" .. (below and " - moved: another button overlapped" or ""))
                SB.paint()
                return SB.mode
            end
        end
    end
    -- 2) fallback: a tiny panel just below / next to the column (or left middle when there is no column at all)
    local x, y = 6, math.floor(sh / 2 - size)
    if inst ~= nil then
        local ax, ay, aw = 0, 0, 0
        pcall(function() ax, ay, aw = inst:getAbsoluteX(), inst:getAbsoluteY(), inst:getWidth() end)
        x, y = ax + (lay.x or 5), ay + (lay.bottom or 0) + lay.gap
        if y + size * 2 + lay.gap + 4 > sh then x, y = ax + aw + 4, math.max(0, sh - size * 2 - 40) end
    end
    local p = fallbackPanel(x, y, size, 5)
    for i, b in ipairs({ rel, party }) do
        if b.parent ~= p then
            pcall(function() if b.parent then b.parent:removeChild(b) end end)
            p:addChild(b); b.parent = p
        end
        place(b, 0, (i - 1) * (size + 5)); pcall(function() b:setVisible(true) end)
        tooltip(b, nil)
    end
    SB.mode = "panel"
    SB.colY, SB.colH, SB.colInst = nil, nil, nil
    sideLog("buttons in a small panel at " .. math.floor(x) .. "," .. math.floor(y) .. (inst and " (sidebar had no room)" or " (no vanilla sidebar found)"))
    SB.paint()
    return SB.mode
end

function M.sideSetShown(on)
    M.settings.sideButtons = on and true or false
    if M.saveSettingsFile then pcall(M.saveSettingsFile) end
    M.sideEnsure(true)
end

if type(Events) == "table" then
    if Events.OnTick then
        ALifeHealth.tickAdd("ALifeLLMTalk_Sidebar", function()
            local now = M.nowMs()
            if now - SB.last < 1000 then return end
            SB.last = now
            local ok, e = pcall(M.sideEnsure, false)
            if not ok then sideLog("error: " .. tostring(e)) end
        end)
    end
    if Events.OnResolutionChange then Events.OnResolutionChange.Add(function() SB.sig = nil end) end
    if Events.OnFillWorldObjectContextMenu then
        ALifeRadial.addFiller("sidebar", "windows", function(playerNum, context, worldobjects, test)   -- 0.5.11: radial registry
            if test == true or not M.settings.enabled or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
            local on = M.settings.sideButtons ~= false
            pcall(function() context:addOption(on and "A-Life: Hide sidebar buttons" or "A-Life: Show sidebar buttons", nil, function() M.sideSetShown(not on) end) end)
        end)
    end
end

return M
