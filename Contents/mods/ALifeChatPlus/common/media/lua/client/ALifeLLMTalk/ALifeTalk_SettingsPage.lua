-- A-Life NPC Overhaul 0.7.0.6: THE SETTINGS PAGE, REBUILT.
-- Before: a fixed grid (420 px columns, 18 rows each) that ran off the screen once there were 150 switches, with
-- labels running into the next column. Now: one list that fits the window and scrolls, labels wrap instead of
-- overlapping, two columns when the window is wide enough, a search box at the top, Save / Close always on screen.
-- Same rows (M.settingRows), same switching (M.settingNext + applySettings), same class (the Settings tab).
require "ALifeLLMTalk/ALifeLLMTalk_UI"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeTalkSettings) ~= "table" or type(ISPanel) ~= "table" then return end
local T, S = M.Theme, M.UIStyle
local Base = ALifeLLMTalkWindow
local ST = ALifeTalkSettings

local function fontH(f) local h = 16; pcall(function() h = getTextManager():getFontHeight(f) end); return h end
local function textW(t, f) local w = 8 * #tostring(t); pcall(function() w = getTextManager():MeasureStringX(f, tostring(t)) end); return w end
local function font() return (M.qolFont and M.qolFont("auto")) or S.font or UIFont.Small end
local function wrap(text, maxW, f)
    local lines, line = {}, ""
    for word in string.gmatch(tostring(text), "%S+") do
        local test = line == "" and word or (line .. " " .. word)
        if textW(test, f) > maxW and line ~= "" then lines[#lines + 1] = line; line = word else line = test end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "" end
    return lines
end
-- 0.7.11: CATEGORIES. Every switch sits under a heading (click a heading to fold it; a search opens them all).
-- Known switches are placed by name; anything newer falls back on words in its name and label, else "Other".
M.settingCats = M.settingCats or { "AI and talking", "Interface and immersion", "Relationships and feelings", "Party and orders",
    "Your camp and base", "Groups, trade and the world", "Radio and news", "Injury, death and prisoners", "Secrets and roadmap",
    "Fixes, safety and debug", "Other" }
M.settingCatOf = M.settingCatOf or {}
do
    local C = M.settingCatOf
    local function put(cat, keys) for _, k in ipairs(keys) do if C[k] == nil then C[k] = cat end end end
    put("AI and talking", { "ambient", "voice", "attention", "listenWindowSec", "pauseListen", "lifeTopics", "talkThread", "talkVisit", "visitGapSec", "visitTurns", "visitChars", "talkEndClose", "talkEndRefuse", "talkPushCost", "talkPushMax", "talkSuggest", "talkSuggestCount", "talkSuggestMs", "talkAskBack", "askWaitSec", "askNudge", "aiRows", "stockState", "talkLength", "thinkBeatMs", "replyPace", "talkRemember", "rememberDays", "talkGestures", "talkWants", "askThanks", "askDays", "askForgotCost", "talkApproach", "approachGapH", "approachPerNpcH", "approachTiles", "talkGroup", "groupChime", "orderRule",
        "fastReplyPoll", "replyFirst", "preemptStock", "speechOnce", "reshowDedupe", "yieldBusy", "cleanMarkup", "bridgeVersionWarn", "whyNot",
        "talkWhilePaused", "windowTalk", "talkPauseKey", "talkAutoPause", "nameDiscovery", "outfitTalk", "weatherTalk", "weirdFear", "threats" })
    put("Interface and immersion", { "opinionPopup", "pairPopup", "pageFirst", "sideButtons", "farProfiles", "farLook", "hubWindow",
        "journal", "uiFixedSize", "uiFancy", "uiWrap", "peopleGroups", "peopleFoldAt", "peopleFriendAt", "peopleFoeAt", "uiWeb", "unifiedDates", "pronounFix", "radialMenu", "radialPad", "radialQuick",
        "firstTips", "noticeLog", "immersive", "alerts", "interactionLog", "npcDialog", "deathMerge", "bondHistory", "bondThought" })
    put("Relationships and feelings", { "personaMods", "emotions", "darkPersonas", "bonds", "romance", "npcLove", "betrayal", "nemesis",
        "grudges", "changeOverTime", "habits", "bondTiers", "bondLikes", "reputation", "repNewLife", "rumors", "promises", "dreams", "sharedPast",
        "likesSaidOnly", "fixApology", "keepKnown", "offscreenLives", "worldReactions", "activity", "notes" })
    put("Party and orders", { "party", "partyCap", "partyMax", "partyFree", "capBeds", "capFood", "capWater", "capTrust", "capSeats", "commands", "aiCommands", "cmdBaseReach", "cmdMapTrust", "thirstPerH", "wakeReach", "wakeHours", "teachHours", "teachXp", "teachReach", "teachGapH", "siphonMinutes", "siphonGiveUpMin", "keepEngineMin", "guardTiles", "playerOrders", "partyOwn", "ownBehaviour", "partyWordsStrict", "partyRides",
        "partySecondCar", "alifeCompanionLink", "recruiting" })
    put("Your camp and base", { "settlers", "baseParty", "alifeBase", "residentHold", "baseRepair", "jeemAware", "jeemBase", "eventLog",
        "seasons", "foodScanRadius", "foodScanFloors", "foodScanMax" })
    put("Groups, trade and the world", { "npcBases", "npcBasesMax", "npcBaseRate", "npcBaseDanger", "honestScavenge", "npcForage",
        "peopleLeave", "ownCaravans", "chokepoints", "warMap", "itemWorth", "npcVehicles", "tradingPost", "marketDays", "caravans",
        "outposts", "nomads", "darkContent", "seededBases", "seededBasesCount", "seededSpawn", "politics", "factionMemory", "territory",
        "attackNpc", "attackPlayer", "quests", "fuelRoads", "paperCars", "skyPower", "namedPlaces", "guardOnlySky", "alifeCarsOff", "realCars", "realCarsReach", "realCarsChance", "realCarsTrips",
        "realCarsPlayerHours", "realCarsKeys", "realCarsSiphonKit", "realCarsPumpReach", "realCarsBaseMargin" })
    put("Radio and news", { "radioNews", "radioCalls", "allyHelp", "bounties", "radioKnox" })
    put("Injury, death and prisoners", { "wounds", "woundTalk", "woundTalkFreq", "lastWords", "lastWordsConfirm", "turnedReact",
        "offDeath", "toldDeath", "deathFacts", "missingPeople", "partnerLossTrauma", "lossTalk", "biteCore", "biteSpread", "injuryBridge",
        "interrogation" })
    put("Secrets and roadmap", { "tasksLetters", "oathWatch", "strangers", "kingmaker", "saboteur" })
    put("Fixes, safety and debug", { "listenDebug", "activityLog", "derelictDebug", "healthLog", "storeTidy", "hookOnce", "stopReAdders" })
end
M.settingCatWords = M.settingCatWords or {
    { "debug", "Fixes, safety and debug" }, { "log", "Fixes, safety and debug" }, { "radio", "Radio and news" },
    { "news", "Radio and news" }, { "party", "Party and orders" }, { "order", "Party and orders" }, { "camp", "Your camp and base" },
    { "base", "Your camp and base" }, { "wound", "Injury, death and prisoners" }, { "death", "Injury, death and prisoners" },
    { "prisoner", "Injury, death and prisoners" }, { "caravan", "Groups, trade and the world" }, { "group", "Groups, trade and the world" },
    { "trade", "Groups, trade and the world" }, { "window", "Interface and immersion" }, { "ui", "Interface and immersion" },
    { "love", "Relationships and feelings" }, { "bond", "Relationships and feelings" }, { "talk", "AI and talking" },
}
function M.settingCategory(row)
    local key = tostring(row[1])
    local c = M.settingCatOf[key]
    if c then return c end
    local hay = string.lower(key .. " " .. tostring(row[2]))
    for _, w in ipairs(M.settingCatWords) do if string.find(hay, w[1], 1, true) then return w[2] end end
    return "Other"
end
-- pre-1.0 (trip-ups): "Most used" sits open at the top; the full categories start folded (click a heading).
M.settingCommon = M.settingCommon or { "immersive", "firstTips", "alerts", "opinionPopup", "talkWhilePaused", "talkAutoPause",
    "voice", "ambient", "partyCap", "romance", "darkPersonas", "darkContent", "attackPlayer", "quests", "settlers", "capture",
    "bounties", "radialMenu", "hoverKeyOnly" }
local COMMON = "Most used"
local function trx(key, default) if type(ALifeTr) == "function" then return ALifeTr(key, default) end return default end
local function valueOf(row)
    if type(row[3]) == "table" then
        local v = tonumber(M.settings[row[1]]) or row[3][1]
        if type(row[4]) == "table" then -- pre-1.0: named choices { key, label, { 1, 2, 3 }, { "A", "B", "C" } }
            for i, x in ipairs(row[3]) do if x == v and row[4][i] ~= nil then return tostring(row[4][i]), true end end
        end
        return tostring(v), v > 0
    end
    local on = M.settings[row[1]] ~= false
    return on and "ON" or "OFF", on
end

----------------------------------------------------------------------------------------------------------------
-- the list
----------------------------------------------------------------------------------------------------------------
ALifeSettingsList = ISPanel:derive("ALifeSettingsList")
local L = ALifeSettingsList
function L:new(x, y, w, h, owner)
    local o = ISPanel.new(self, x, y, w, h)
    o.owner = owner
    o.background = false
    o.rows, o.filter = {}, nil
    return o
end
function L:createChildren()
    ISPanel.createChildren(self)
    self:addScrollBars()
    self:setScrollChildren(true)
end
function L:layout()
    local f = font()
    local fh = fontH(f)
    local sbW = 18
    local cols = self.width >= 980 and 2 or 1
    local colW = math.floor((self.width - sbW - 8) / cols)
    local boxW = math.max(56, textW("OFF", f) + 24)
    for _, r in ipairs(M.settingRows or {}) do -- pre-1.0: room for named choices
        if type(r[4]) == "table" then for _, n in ipairs(r[4]) do boxW = math.max(boxW, textW(tostring(n), f) + 16) end end
    end
    local boxH = fh + 6
    local q = self.filter and string.lower(self.filter) or ""
    -- 0.7.11: sorted into their categories
    local byCat, total = {}, 0
    if q == "" then -- pre-1.0: the most used switches first (they also stay in their own category)
        local have = {}
        for _, row in ipairs(M.settingRows or {}) do have[tostring(row[1])] = row end
        for _, k in ipairs(M.settingCommon) do
            if have[k] then byCat[COMMON] = byCat[COMMON] or {}; byCat[COMMON][#byCat[COMMON] + 1] = have[k] end
        end
    end
    for _, row in ipairs(M.settingRows or {}) do
        if q == "" or (M.settingMatch and M.settingMatch(row, q)) or (M.settingMatch == nil and (string.find(string.lower(tostring(row[2])), q, 1, true) or string.find(string.lower(tostring(row[1])), q, 1, true))) then -- 0.8.12: every word, + headings
            local cat = M.settingCategory(row)
            byCat[cat] = byCat[cat] or {}
            byCat[cat][#byCat[cat] + 1] = row
            total = total + 1
        end
    end
    self.rows, self.heads = {}, {}
    self.collapsed = self.collapsed or {}
    local y = 4
    local headH = fh + 10
    local cats = { COMMON }
    for _, c in ipairs(M.settingCats) do cats[#cats + 1] = c end
    for _, cat in ipairs(cats) do
      local shown = byCat[cat]
      if shown and #shown > 0 then
        local folded = false -- pre-1.0: "Most used" open, the rest folded until clicked; a search opens them all
        if q == "" then
            if cat == COMMON then folded = self.collapsed[cat] == true else folded = self.collapsed[cat] ~= false end
        end
        self.heads[#self.heads + 1] = { cat = cat, y = y, h = headH, n = #shown, folded = folded }
        y = y + headH + 4
        if not folded then
    for i = 1, #shown, cols do
        local h = boxH
        local cells = {}
        for c = 1, cols do
            local row = shown[i + c - 1]
            if row then
                local x = (c - 1) * colW + 4
                local label = M.settingLabel and M.settingLabel(row) or row[2]
                if M.sbIsKept and M.sbIsKept(tostring(row[1])) then label = tostring(label) .. "  " .. trx("IGUI_ALCP_Set_KeptWorld", "(kept for this world)") end
                local lines = wrap(label, colW - boxW - 22, f) -- 0.8.12: translated (IGUI_ALCP_Set_<key>)
                h = math.max(h, #lines * fh + 4)
                cells[#cells + 1] = { row = row, x = x, lines = lines }
            end
        end
        for _, cell in ipairs(cells) do
            self.rows[#self.rows + 1] = { row = cell.row, x = cell.x, y = y, w = colW - 8, h = h, lines = cell.lines, boxW = boxW, boxH = boxH }
        end
        y = y + h + 6
    end
        end
        y = y + 4
      end
    end
    self.contentH = y
    self.shownN = total
    self.font, self.fh = f, fh
    pcall(function() self:setScrollHeight(math.max(self.height, y)) end)
    if -self:getYScroll() > math.max(0, y - self.height) then pcall(function() self:setYScroll(-math.max(0, y - self.height)) end) end
end
function L:prerender()
    local text = ""
    pcall(function() text = self.owner.search:getText() end)
    if type(text) ~= "string" then text = "" end
    if text ~= self.filter or self.lastW ~= self.width then self.filter = text; self.lastW = self.width; self:layout() end
    self:setStencilRect(0, 0, self.width, self.height)
    local top, bottom = -self:getYScroll(), -self:getYScroll() + self.height
    local mx, my = self:getMouseX(), self:getMouseY()
    local over = self:isMouseOver()
    local a = self.owner and self.owner.fade or 1
    for _, hd in ipairs(self.heads or {}) do
        if hd.y + hd.h >= top and hd.y <= bottom then
            local hot = over and my >= hd.y and my <= hd.y + hd.h
            if hot and type(AA_Tip) == "table" then AA_Tip.over(hd, hd.folded and "Click to open this group of settings." or "Click to close this group.") end
            self:drawRect(2, hd.y, self.width - 22, hd.h, (hot and 0.45 or 0.3) * a, S.accent.r * 0.5, S.accent.g * 0.5, S.accent.b * 0.5)
            self:drawText((hd.folded and "+  " or "-  ") .. (M.settingCatLabel and M.settingCatLabel(hd.cat) or hd.cat) .. "  (" .. hd.n .. ")", 10, hd.y + 5, 1, 0.95, 0.85, a, self.font)
        end
    end
    for _, r in ipairs(self.rows) do
        if r.y + r.h >= top and r.y <= bottom then
            if over and mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
                self:drawRect(r.x - 2, r.y - 2, r.w + 4, r.h + 4, 0.18 * a, S.accent.r, S.accent.g, S.accent.b)
                if type(AA_Tip) == "table" and M.settingTip then AA_Tip.over(r.row, function() return M.settingTip(r.row) end) end -- pre-1.0: what it does, its range
            end
            local label, on = valueOf(r.row)
            local c = on and S.green or S.red
            self:drawRect(r.x, r.y, r.boxW, r.boxH, 0.85 * a, c.r * 0.35, c.g * 0.35, c.b * 0.35)
            self:drawRectBorder(r.x, r.y, r.boxW, r.boxH, a, c.r, c.g, c.b)
            self:drawTextCentre(label, r.x + r.boxW / 2, r.y + 3, 1, 1, 1, a, self.font)
            for k, line in ipairs(r.lines) do
                self:drawText(line, r.x + r.boxW + 12, r.y + 2 + (k - 1) * self.fh, S.text.r, S.text.g, S.text.b, a, self.font)
            end
        end
    end
    if self.shownN == 0 then self:drawText("No setting matches \"" .. tostring(self.filter) .. "\".", 8, 8, 0.7, 0.7, 0.7, a, self.font) end
end
function L:render()
    ISPanel.render(self)
    self:clearStencilRect()
end
function L:onMouseWheel(del)
    local maxScroll = math.max(0, (self.contentH or 0) - self.height)
    local y = -self:getYScroll() + del * 48
    y = math.max(0, math.min(maxScroll, y))
    self:setYScroll(-y)
    return true
end
function L:onMouseDown(x, y)
    for _, hd in ipairs(self.heads or {}) do
        if y >= hd.y and y <= hd.y + hd.h then
            self.collapsed[hd.cat] = not hd.folded
            self:layout()
            pcall(function() getSoundManager():playUISound("UISelectListItem") end)
            return true
        end
    end
    for _, r in ipairs(self.rows) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            M.settingNext(r.row)
            if M.applySettings then pcall(M.applySettings) end
            pcall(function() getSoundManager():playUISound("UISelectListItem") end)
            return true
        end
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- the window
----------------------------------------------------------------------------------------------------------------
function ST:new()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.floor(math.min(sw - 40, math.max(560, (M.uiPref and M.uiPref("hub.w", math.floor(sw * 0.55))) or 900)))
    local h = math.floor(math.min(sh - 60, math.max(360, (M.uiPref and M.uiPref("hub.h", math.floor(sh * 0.7))) or 620)))
    return Base.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h, "A-Life settings")
end
function ST:createChildren()
    Base.createChildren(self)
    local f = font()
    local fh = fontH(f)
    local top = self:contentTop()
    local eh = fh + 10
    self.search = ISTextEntryBox:new("", 12, top, math.min(300, self.width - 24), eh)
    self.search:initialise(); self.search:instantiate()
    self.search.font = f
    pcall(function() self.search:setPlaceholderText("Search (e.g. camp food, warning)") end)
    self:addChild(self.search)
    local bh = fh + 10
    self.btnY = self.height - bh - 12
    self.list = ALifeSettingsList:new(10, top + eh + 8, self.width - 20, self.btnY - (top + eh + 8) - 8, self)
    self.list:initialise(); self.list:instantiate()
    self:addChild(self.list)
    local saveW, closeW = textW("Save", f) + 30, textW("Close", f) + 30
    self.saveBtn = T.button(self, self.width - saveW - closeW - 22, self.btnY, saveW, bh, ALifeTr("IGUI_ALCP_Btn_Save", "Save"), self, function() pcall(M.saveSettingsFile); self:close() end, S.green)
    local resetW = textW(trx("IGUI_ALCP_Btn_SandboxBack", "Back to sandbox values"), f) + 30 -- pre-1.0
    self.resetBtn = T.button(self, self.width - saveW - closeW - resetW - 32, self.btnY, resetW, bh, trx("IGUI_ALCP_Btn_SandboxBack", "Back to sandbox values"), self, ST.askReset)
    pcall(function() self.resetBtn.font = f; self.resetBtn:setTooltip(trx("IGUI_ALCP_Tip_SandboxBack", "Forget every switch you saved here for this world. The world's sandbox options decide again.")) end)
    self.closeBtn = T.button(self, self.width - closeW - 12, self.btnY, closeW, bh, ALifeTr("IGUI_ALCP_Btn_Close", "Close"), self, ST.close)
    pcall(function() self.saveBtn.font = f; self.closeBtn.font = f end)
end
-- pre-1.0: "Back to sandbox values", asks first
function ST:askReset()
    local win = self
    pcall(function()
        local w, h = 420, 150
        local x, y = getCore():getScreenWidth() / 2 - w / 2, getCore():getScreenHeight() / 2 - h / 2
        local text = trx("IGUI_ALCP_Ask_SandboxBack", "Forget the switches you saved in game for this world and go back to its sandbox options?")
        local dlg = ISModalDialog:new(x, y, w, h, text, true, win, function(target, button)
            if button and button.internal == "YES" then
                if type(ALifeSettingsNet) == "table" and type(ALifeSettingsNet.reset) == "function" then pcall(ALifeSettingsNet.reset)
                elseif M.sbClearAll then pcall(M.sbClearAll); pcall(M.saveSettingsFile) end
                if target and target.list then target.list.lastW = nil end
            end
        end, 0)
        dlg:initialise()
        dlg:addToUIManager()
    end)
end
function ST:sync() end -- the list draws the current values every frame
function ST:prerender()
    Base.prerender(self)
    if self.list and self.list.shownN then
        local f = font()
        local n = self.list.shownN
        local txt = n .. " of " .. #(M.settingRows or {}) .. " settings  (click a row to switch it, a heading to open it; Save keeps it for this world)"
        self:drawText(txt, 12, self.btnY + 4, 0.6, 0.6, 0.62, self.fade or 1, f)
    end
end
print("[ALifeSettings] ready pre-1.0: settings in categories, Most used on top, kept per world, back to sandbox")
