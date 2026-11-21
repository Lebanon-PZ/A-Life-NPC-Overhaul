-- A-Life NPC Overhaul pre-1.0: HOVER TIPS. "every tab, every setting, anything clickable that can cause confusion has
-- a short tooltip, 0.5 s to show, 0.25 s to go after the mouse leaves" (Joe).
-- One tooltip for all of our UI:
--   * every ISButton inside one of our windows (ALifeLLMTalkWindow and everything derived from it, the moment card,
--     the letters, the camp widget, the camp board): vanilla's instant tooltip is replaced by this delayed one. Text:
--     the button's own tooltip/alcpTip, else the tip for its title from AA_Tip.list below (translatable:
--     IGUI_ALCP_Tip_<key>).
--   * tabs (Hub.lua sets alcpTip from AA_Tip.tabs), setting rows (SettingsPage.lua calls AA_Tip.over per row),
--     anything else drawn by hand: AA_Tip.over(key, text) every frame the mouse is on it.
-- Timing: tipShowMs (default 500) of resting before it shows, tipHideMs (default 250) after the mouse leaves before it
-- goes. A tip nobody hovers any more (window closed) goes the same way: no over() for tipHideMs = gone.
-- Settings (in game, Settings > Interface): tipsOn, tipShowMs, tipHideMs.
-- Performance: one table check per button per frame; the tooltip panel exists only while a tip is on screen.
-- Vanilla's own sandbox screen and right-click menus keep vanilla's tooltips (vanilla UI, every mod shares it).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
AA_Tip = AA_Tip or {}
local A = AA_Tip
A.VERSION = ALifeSide.MOD_VERSION
local M = ALifeLLMTalk
if type(M) ~= "table" then M = {} end

local function now() local t = 0; pcall(function() t = getTimestampMs() end); return tonumber(t) or 0 end
local function tr(k, en) if type(ALifeTr) == "function" then return ALifeTr(k, en) end return en end

-- settings (keys registered at load, so the saved file keeps them)
A.DEFAULTS = { tipsOn = true, tipShowMs = 500, tipHideMs = 250 }
A.ROWS = {
    { "tipsOn", "Hover tips on buttons, tabs and settings" },
    { "tipShowMs", "Hover tips: how long the mouse rests before a tip shows (ms)", { 0, 250, 500, 800, 1200 } },
    { "tipHideMs", "Hover tips: how long a tip stays after the mouse leaves (ms)", { 0, 250, 500, 1000 } },
}
A.ROW_TIPS = {
    tipsOn = "A short note about what a button, tab or setting does when you rest the mouse on it. Off: no notes.",
    tipShowMs = "Lower: 0 = tips show at once (they can get in the way). Higher: 1200 = only when you really stop on something.",
    tipHideMs = "Lower: 0 = gone the moment the mouse moves off. Higher: 1000 = stays a second, easier to finish reading.",
}
if type(M) == "table" then
    M.settings = M.settings or {}
    M.fileKeys = M.fileKeys or {}
    for k, v in pairs(A.DEFAULTS) do
        if M.settings[k] == nil then M.settings[k] = v end
        local have = false
        for _, f in ipairs(M.fileKeys) do if f == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
    M.settingCatOf = M.settingCatOf or {}
    for _, r in ipairs(A.ROWS) do if M.settingCatOf[r[1]] == nil then M.settingCatOf[r[1]] = "Interface and immersion" end end
end
local function opt(k)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[k] end -- not `a and b or nil`: a false switch must stay false
    if v == nil then return A.DEFAULTS[k] end
    return v
end
function A.on() return opt("tipsOn") ~= false end
function A.showMs() return tonumber(opt("tipShowMs")) or 500 end
function A.hideMs() return tonumber(opt("tipHideMs")) or 250 end

----------------------------------------------------------------------------------------------------------------
-- the tips (English; IGUI_ALCP_Tip_<key> translates). { key, title as shown in English, tip [, prefix = true] }
----------------------------------------------------------------------------------------------------------------
A.tabs = {
    now = "What needs you right now: decisions waiting, who's away, traders at your place, your quick orders and the camp's latest notes.",
    people = "Everyone you've met, as you remember them: what they told you, how they seem toward you, where you last saw them. Pick someone to talk or give orders; tick several to order them at once.",
    party = "The people travelling with you: hunger, thirst, ammo and how they're doing, with orders for each.",
    camp = "Your base: the camp board, roles, rules, patrol, alarm, kitchen, farm, work zones and the places you named.",
    trade = "Trading: what your things are worth, traders at your place, market day and traders on the radio.",
    journal = "The world as you know it: groups and their bases, places you've heard of, and the war map.",
    radio = "Your radio: who can hear you, calling people and groups, walkie channels.",
    settings = "Every switch of the mod. Click a row to change it, Save to keep it for this world. Presets and the window style are at the top.",
    help = "A short guide to every feature, the full command list, and Show the tips again.",
    ai = "The optional AI for real conversations: set it up, pick a model, test it, fix it. The mod plays fine without it.",
    chronicle = "The story of your world so far, written as it happens. Write it in a notebook or save it to a file.",
    build = "Ghost build: plan walls, floors and furniture, and your people build them with real materials.",
    _more = "Tabs that don't fit in the window. Make the window wider (drag its bottom-right corner) to see them all.",
}
A.list = {
    -- Now
    { "BtnNameSpot", "Name this spot", "Give the place you're standing a name ('the north gate'). It goes on your map, and you can send people there to meet you or to hold it." },
    { "BtnNotices", "Missed something?", "The last letters, notes and popups, in case one went by too fast. Red ones are the bad news." },
    { "BtnLog", "The camp's notes", "What happened at your camp lately: meals, patrols, arguments, who did what." },
    { "BtnWidget", "Camp widget on/off", "Show or hide the small camp box on screen (food, people, mood, alarm, who's away)." },
    { "BtnQuick", "Quick orders on/off", "Show or hide the quick-order bar: your favourite orders as buttons on screen." },
    { "BtnJeemStatus", "Jeem status", "Jeem's own status menu for your base and people (only with the Jeem extension)." },
    { "Order_posts", "To your posts!", "Raise the camp alarm: everyone who can fight takes their post, the rest get inside." },
    { "Order_clear", "All clear", "End the alarm: people go back to what they were doing." },
    { "Order_lights", "Lights out", "Everyone in camp turns their lights off (so nothing sees the base at night)." },
    { "Order_party", "Everyone with me: follow", "Everyone travelling with you follows you." },
    { "Order_partywait", "Everyone with me: wait here", "Everyone travelling with you stops and waits where they are." },
    { "Order_follow", "Follow me", "They follow you." },
    { "Order_wait", "Wait here", "They stay where they are until you come back or call them." },
    { "Order_guard", "Guard here", "They hold this spot and fight anything that comes." },
    { "Order_home", "Go back to the base", "They walk back to your base on their own." },
    { "Order_recall", "Stand down (forget the place order)", "They forget the place you sent them to and go back to normal." },
    -- People
    { "Filter_all", "All", "Show everyone you've met." },
    { "Filter_camp", "Camp", "Only the people living at your base." },
    { "Filter_party", "With me", "Only the people travelling with you." },
    { "Filter_lost", "Gone", "People who are dead, missing or left." },
    { "BtnTalk", "Talk", "Start talking to the selected person (they must be close, or on the radio)." },
    { "BtnOrders", "Orders", "Every order you can give the selected person: follow, wait, guard, go somewhere, jobs." },
    { "BtnSelected", "Order the ticked", "Give one order to everyone you ticked in the list at once." },
    { "BtnFullPage", "Their page", "Everything you know about them: what they told you, how they feel about you, your history together." },
    { "BtnJeemPeople", "Jeem: my people", "Jeem's own menus for your people (only with the Jeem extension)." },
    -- Camp
    { "BtnCampMenu", "Camp menu", "Every camp menu: roles, rules, patrol, alarm, kitchen, farm, armory and the rest." },
    { "BtnZones", "Work zones", "Mark areas for your people to clear bodies from, and where to take them." },
    { "BtnNamePlace", "Name this spot", "Give the place you're standing a name. It goes on your map, and you can send people there." },
    { "BtnPlaces", "Named places", "The places you named: show one on the map or forget it." },
    { "BtnJeemBase", "Jeem: base and residents", "Jeem's own base and resident menus (only with the Jeem extension)." },
    { "BtnCampLog", "From your camp", "Reports your camp sent while you were away." },
    -- Trade
    { "BtnRadioTrade", "Radio: traders and market day", "Call traders over the radio, ask friends for help, set your market day." },
    { "BtnPostMenu", "Trading post (here)", "Set up or run a trading post where you're standing, so traders know where to come." },
    -- Radio
    { "BtnRadio", "Radio", "Call out on the radio: find people, talk to groups, ask for traders or help. Who hears you depends on your radio." },
    { "BtnJeemRadio", "Jeem: walkie to your base", "Call your own base on the walkie (only with the Jeem extension)." },
    { "WalkieCall", "Call someone", "Call one of your people or a group on the walkie. Each call drains the battery." },
    { "WalkieSwap", "Swap channels", "Trade walkie channels with someone near you so you can call them later." },
    { "WalkieMine", "Use my channel as ours", "Make the channel your walkie is on the one your people listen to." },
    { "WalkieRefresh", "Refresh", "Look again for who's in range." },
    -- Party
    { "Btn_follow", "Follow", "The selected person follows you." },
    { "Btn_hold", "Wait", "The selected person waits where they are." },
    { "Btn_guard", "Guard here", "The selected person holds this spot and fights anything that comes." },
    { "Btn_base", "Go to base", "The selected person walks back to your base." },
    { "Btn_talk", "Talk", "Talk to the selected person." },
    { "Btn_stance", "Stance", "How they fight: hold fire, defend, attack on sight, stay close." },
    { "Btn_dismiss", "Part ways", "They stop travelling with you. Asks first." },
    -- Help
    { "BtnHelpGuide", "Help", "The short guide to every feature." },
    { "BtnHelp_commands", "Commands", "Every order and question people understand, in groups. Click a heading to open it." },
    { "CmdOpenAll", "Open all", "Open every group in the list." },
    { "CmdCloseAll", "Close all", "Close every group in the list." },
    { "BtnTips", "Show the tips again", "Each tab shows its first-time tip again the next time you open it." },
    -- Build
    { "Up", "Up", "Move the selected plan earlier in the build order." },
    { "Down", "Down", "Move the selected plan later in the build order." },
    -- Settings window
    { "Btn_Save", "Save", "Keep these settings for this world. Close without saving forgets the changes." },
    { "Btn_Close", "Close", "Close this window." },
    { "Btn_Settings", "Settings", "Open the mod's settings." },
    { "Btn_Open", "Open", "Open the selected person's page." },
    { "Btn_Contact_by_radio", "Contact by radio", "Call the selected person on the radio (you need a radio they can hear)." },
    { "Btn_Person", "Person...", "Pick who you're talking to." },
    { "Btn_End", "End", "End the radio call." },
    { "Btn_Come_with_me", "Come with me", "Ask them to travel with you. They say yes only if they trust you enough." },
    { "Btn_Sort", "Sort:", "Change the order of the list.", prefix = true },
    { "Btn_Show", "Show:", "Change who is shown in the list.", prefix = true },
    -- world / journal
    { "WarMapButton", "War map", "Show or hide the wars you know of on the map: who holds what, and where they fight." },
    { "WarListButton", "Wars", "A list of the wars you know of between groups." },
    -- cards, letters, frames
    { "MomOpen", "Open the A-Life window", "Open the A-Life window on the page this is about." },
    { "MomClear", "Clear all", "Clear every letter except the red (important) ones.", prefix = true },
    { "CloseX", "x", "Close this window." },
}
-- title (lower case, in English and in the player's language) -> tip; built the first time it's needed
local byTitle, byPrefix = nil, nil
local function norm(s) s = string.lower(tostring(s or "")); s = string.gsub(s, "^%s+", ""); s = string.gsub(s, "%s+$", ""); return s end
local function build()
    byTitle, byPrefix = {}, {}
    for _, e in ipairs(A.list) do
        local tip = tr("IGUI_ALCP_Tip_" .. e[1], e[3])
        local names = { e[2], tr("IGUI_ALCP_" .. e[1], e[2]), tr("IGUI_ALCP_Btn" .. string.gsub(e[1], "^Btn", ""), e[2]) }
        for _, n in ipairs(names) do
            local k = norm(n)
            if k ~= "" then
                if e.prefix then byPrefix[#byPrefix + 1] = { k, tip } elseif byTitle[k] == nil then byTitle[k] = tip end
            end
        end
    end
end
function A.lookup(title)
    if title == nil or title == "" then return nil end
    if byTitle == nil then build() end
    local k = norm(title)
    if byTitle[k] then return byTitle[k] end
    for _, p in ipairs(byPrefix) do if string.sub(k, 1, #p[1]) == p[1] then return p[2] end end
    return nil
end
function A.tabTip(id) local t = A.tabs[tostring(id)]; return t and tr("IGUI_ALCP_TipTab_" .. tostring(id), t) or nil end

----------------------------------------------------------------------------------------------------------------
-- the tooltip itself
----------------------------------------------------------------------------------------------------------------
local st = { key = nil, since = 0, seen = 0, shown = nil, shownSeen = 0, text = nil }
A.state = st
local UI = nil
local function makeUI()
    if UI ~= nil or type(ISToolTip) ~= "table" then return UI end
    ALifeTipUI = ISToolTip:derive("ALifeTipUI")
    function ALifeTipUI:prerender()
        if st.shown == nil or now() - st.shownSeen > A.hideMs() then A.hide(); return end
        ISToolTip.prerender(self)
    end
    function ALifeTipUI:render()
        -- below-right of the mouse, kept on screen
        local sw, sh = 1920, 1080
        pcall(function() sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight() end)
        local x, y = getMouseX() + 18, getMouseY() + 22
        if x + self.width > sw - 4 then x = math.max(4, getMouseX() - self.width - 8) end
        if y + self.height > sh - 4 then y = math.max(4, getMouseY() - self.height - 8) end
        self.desiredX, self.desiredY = x, y
        ISToolTip.render(self)
    end
    local ok, o = pcall(function()
        local t = ALifeTipUI:new()
        t:initialise()
        t:setAlwaysOnTop(true)
        t:setVisible(false)
        t.maxLineWidth = 340
        return t
    end)
    if ok then UI = o end
    return UI
end
local function fmt(text)
    text = tostring(text or "")
    text = string.gsub(text, "\r?\n", " <LINE> ")
    return text
end
function A.hide()
    st.shown = nil
    if UI == nil then return end
    pcall(function() UI:setVisible(false); UI:removeFromUIManager() end)
end
local function show(key, text)
    local u = makeUI()
    if u == nil then return end
    u.description = fmt(text)
    if st.shown == nil then pcall(function() u:addToUIManager(); u:setVisible(true) end) end
    st.shown, st.shownSeen, st.text = key, now(), text
end
-- call every frame the mouse is on `key` (any table or string). text: string or function() -> string
function A.over(key, text)
    if key == nil or not A.on() then return end
    if type(text) == "function" then local ok, t = pcall(text); text = ok and t or nil end
    if type(text) ~= "string" or text == "" then return end
    local t = now()
    if st.key ~= key or t - st.seen > 400 then st.key = key; st.since = t end -- a new thing, or the mouse came back (400: low fps safe)
    st.seen = t
    if st.shown == key then
        st.shownSeen = t
        if st.text ~= text and UI then UI.description = fmt(text); st.text = text end
        return
    end
    if t - st.since >= A.showMs() then show(key, text) end
end

----------------------------------------------------------------------------------------------------------------
-- buttons: ours get the delayed tip, everyone else's stay vanilla
----------------------------------------------------------------------------------------------------------------
A.classes = { "ALifeLLMTalkWindow", "ALifeMomentCard", "ALifeToastStack", "ALifeTalkWidget", "ALifeCampBoard", "ALifeSettingsList" }
function A.markClasses()
    for _, n in ipairs(A.classes) do
        local c = _G[n]
        if type(c) == "table" then c._alcpWin = true end
    end
end
-- is this element inside one of our windows? (cached once it has a parent)
function A.owns(el)
    if el._alcpTipOwn ~= nil then return el._alcpTipOwn end
    if el.alcpTip ~= nil then el._alcpTipOwn = true; return true end
    local p, d = el.parent, 0
    if p == nil then return false end
    while p ~= nil and d < 10 do
        if p._alcpWin then el._alcpTipOwn = true; return true end
        p = p.parent; d = d + 1
    end
    el._alcpTipOwn = false
    return false
end
function A.textFor(el)
    local t = el.alcpTip
    if t == nil then t = el.tooltip end
    if t == nil or t == "" then t = A.lookup(el.title) end
    return t
end
-- own a single element that lives outside our windows (the world map, the sidebar)
function A.own(el, text) if el ~= nil then el._alcpTipOwn = true; if text ~= nil then el.alcpTip = text end end; return el end

function A.installButtons()
    if A._btnHooked or type(ISButton) ~= "table" or type(ISButton.updateTooltip) ~= "function" then return A._btnHooked == true end
    local orig = ISButton.updateTooltip
    ISButton.updateTooltip = function(self, ...)
        local mine = false
        pcall(function() mine = A.owns(self) end)
        if not mine then return orig(self, ...) end
        if self.tooltipUI and self.tooltipUI:getIsVisible() then pcall(function() self.tooltipUI:setVisible(false); self.tooltipUI:removeFromUIManager() end) end
        local over = false
        pcall(function() over = self:isMouseOver() == true or self.joypadFocused == true end)
        if over then A.over(self, A.textFor(self)) end
    end
    A._btnHooked = true
    return true
end
-- a combo box: its own instant tip off, ours on (text: string or function)
function A.combo(cb, text)
    if cb == nil then return cb end
    cb.alcpTip = text
    local pre = cb.prerender
    cb.prerender = function(self, ...)
        local r = pre(self, ...)
        local over = false
        pcall(function() over = self:isMouseOver() == true and not self.expanded end)
        if over then A.over(self, self.alcpTip) end
        return r
    end
    return cb
end

----------------------------------------------------------------------------------------------------------------
-- settings rows: the row's own tip, the sandbox option's tip, and the range for numbers
----------------------------------------------------------------------------------------------------------------
M.settingTips = M.settingTips or {}
for k, v in pairs(A.ROW_TIPS) do if M.settingTips[k] == nil then M.settingTips[k] = v end end
local sbByKey = nil
local function sandboxTip(key)
    if sbByKey == nil then
        sbByKey = {}
        for _, e in ipairs(type(M.sandboxMap) == "table" and M.sandboxMap or {}) do if e.set and e.k then sbByKey[e.set] = e.k end end
    end
    local k = sbByKey[key] or (string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2))
    local id = "Sandbox_ALifeChatPlus_" .. k .. "_tooltip"
    local t = nil
    pcall(function() if type(getTextOrNull) == "function" then t = getTextOrNull(id) else t = getText(id); if t == id then t = nil end end end)
    return t
end
function M.settingTip(row)
    if type(row) ~= "table" then return nil end
    local key = tostring(row[1])
    local base = M.settingTips[key]
    if base ~= nil then base = tr("IGUI_ALCP_SetTip_" .. key, base) else base = sandboxTip(key) end
    local vals, names = row[3], row[4]
    local extra
    if type(vals) ~= "table" then
        extra = tr("IGUI_ALCP_Tip_RowSwitch", "Click to switch it on or off.")
    elseif type(names) == "table" then
        extra = tr("IGUI_ALCP_Tip_RowChoices", "Click for the next choice:") .. " " .. table.concat(names, ", ") .. "."
    else
        local lo, hi = nil, nil
        for _, v in ipairs(vals) do
            if type(v) == "number" then lo = (lo == nil or v < lo) and v or lo; hi = (hi == nil or v > hi) and v or hi end
        end
        local strs = {}
        for _, v in ipairs(vals) do strs[#strs + 1] = tostring(v) end
        extra = tr("IGUI_ALCP_Tip_RowMin", "Lowest") .. " " .. tostring(lo) .. ", " .. tr("IGUI_ALCP_Tip_RowMax", "highest") .. " " .. tostring(hi)
            .. ". " .. tr("IGUI_ALCP_Tip_RowSteps", "Click to step through:") .. " " .. table.concat(strs, ", ") .. "."
    end
    if base == nil or base == "" then return extra end
    return base .. " <LINE> " .. extra
end

function A.install()
    A.markClasses()
    A.installButtons()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(A.ROWS) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
    end
    print("[AA_Tip] ready " .. A.VERSION .. ": hover tips on tabs, buttons and settings (" .. A.showMs() .. " ms in, " .. A.hideMs() .. " ms out)")
end
A.markClasses()
A.installButtons()
if Events and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(A.install) end) end
return A
