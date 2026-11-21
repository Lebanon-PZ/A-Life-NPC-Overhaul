-- A-Life NPC Overhaul pre-1.0: AUTOMATIC BUG REPORTS, the game side. Asks once per PC (first boot after this update):
-- "send the author a report when a feature breaks?" Yes / No. The answer goes in Zomboid/Lua/alifeai_report.txt
-- (enabled=, answered=yes); the helper (bridge/alifeai_report.ps1) reads it and sends to the author's Discord.
-- Switch it any time: AI tab > "Bug reports: on/off". The game itself can't reach the internet: the helper sends.
-- Per PC, not per save (MP: each player answers for their own PC). Settings bugReportAsk, bugReportAskSec.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeBugReports") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeBugReports]"
local B = ALifeBugReports or {}
ALifeBugReports = B
B.VERSION = ALifeSide.MOD_VERSION
B.FILE = "alifeai_report.txt"
B.DISCORD = "discord.gg/GvEhMeqN3" -- the mod's Discord invite (lands in #automated-bug-reports), shown in the question (empty = not shown)
B.DEFAULTS = {
    bugReportAsk = true,   -- ask once per PC (first boot) if the player wants automatic bug reports
    bugReportAskSec = 20,  -- real seconds into the game before asking
}
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function tr(k, en, ...)
    local s = en
    if type(getTextOrNull) == "function" then
        local ok, t = pcall(getTextOrNull, "UI_ALifeBug_" .. k)
        if ok and type(t) == "string" and t ~= "" then s = t end
    end
    local args = { ... }
    for i = 1, #args do s = string.gsub(s, "{" .. i .. "}", (string.gsub(tostring(args[i]), "%%", "%%%%"))) end
    return s
end

function B.setting(key)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[key] end
    if v == nil then v = B.DEFAULTS[key] end
    return v
end
-- new keys go in the settings file list at load time (or they reset on restart)
function B.registerSettings()
    if type(M.settings) ~= "table" then return false end
    M.fileKeys = M.fileKeys or {}
    for k, v in pairs(B.DEFAULTS) do
        if M.settings[k] == nil then M.settings[k] = v end
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
    return true
end
B.registerSettings()

-- alifeai_report.txt -> { key = value } (nil = no file)
function B.read()
    local lines = type(M.readLines) == "function" and M.readLines(B.FILE) or nil
    if lines == nil then return nil end
    local kv = {}
    for _, l in ipairs(lines) do
        local k, v = string.match(l, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and string.sub(l, 1, 1) ~= "#" then kv[string.lower(k)] = v end
    end
    return kv
end
local function truthy(v) v = string.lower(tostring(v or "")); return v == "true" or v == "yes" or v == "1" or v == "on" end
function B.isOn() local kv = B.read(); return kv ~= nil and truthy(kv.enabled) end
function B.answered()
    local kv = B.read()
    if kv ~= nil and truthy(kv.answered) then return true end
    local seen = false
    if type(M.uiPref) == "function" then pcall(function() seen = M.uiPref("bugReports.asked", false) == true end) end
    return seen
end
-- writes the whole file; keeps the player's own url / console_lines / max_per_day
function B.write(on)
    local kv = B.read() or {}
    local num = function(v, d) v = tonumber(v); if v == nil or v < 0 then return d end; return math.floor(v) end
    local text = "# A-Life NPC Overhaul - AUTOMATIC BUG REPORTS (you chose this in game; switch it on the AI tab)\r\n"
        .. "# When one of the mod's features switches itself off after an error, the mod's helper sends the author's Discord\r\n"
        .. "# the health report (Zomboid/Lua/ALifeChatPlus_health.txt) and the end of console.txt.\r\n"
        .. "# Your Windows user name and home folder are replaced with <user> / <home> first.\r\n\r\n"
        .. "enabled=" .. (on and "true" or "false") .. "\r\n"
        .. "answered=yes\r\n\r\n"
        .. "# Where reports go. Empty = the mod author's Discord (bridge/report_url.txt).\r\n"
        .. "url=" .. tostring(kv.url or "") .. "\r\n\r\n"
        .. "# Lines from the end of console.txt to include (0 = none).\r\n"
        .. "console_lines=" .. num(kv.console_lines, 300) .. "\r\n\r\n"
        .. "# At most this many reports a day.\r\n"
        .. "max_per_day=" .. num(kv.max_per_day, 3) .. "\r\n"
    local ok = type(M.writeFile) == "function" and M.writeFile(B.FILE, text) or false
    if type(M.uiSet) == "function" then pcall(M.uiSet, "bugReports.asked", true) end
    return ok
end
-- the helper running on this PC (it does the sending)
function B.helperUp()
    local A = ALifeAISetup
    if type(A) ~= "table" or type(A.state) ~= "function" then return false end
    local ok, s = pcall(A.state, playerOf())
    return ok and type(s) == "table" and s.helper == "up"
end

function B.questionText()
    -- ISModalDialog draws plain centred text (no wrapping, no rich tags): lines broken by hand
    return tr("Ask", "Help fix bugs?\n\n"
        .. "When one of this mod's features switches itself off after an error,\n"
        .. "your PC can send the mod author a short report on its own:\n"
        .. "which feature broke, the error, and the end of console.txt.\n"
        .. "Your Windows name and folders are removed first. Nothing else, at most 3 a day.\n\n"
        .. "It goes out through the mod's small helper program (bridge\\Setup.cmd,\n"
        .. "the same one the AI uses; it works with the AI off too).\n\n"
        .. "Change it any time: A-Life window > AI tab > Bug reports.\n\n"
        .. (B.DISCORD ~= "" and ("Reports go to the mod's Discord: " .. B.DISCORD .. "\n\n") or "")
        .. "Send bug reports?")
end
function B.answer(yes)
    B.write(yes == true)
    print(TAG .. " player chose: bug reports " .. (yes and "on" or "off"))
    if yes and not B.helperUp() then
        local p = playerOf()
        if p and type(ALifeLetter) == "function" then
            pcall(ALifeLetter, p, tr("NeedHelper", "Bug reports are on, but the mod's helper isn't running on this PC, so nothing can be sent yet. A-Life window > AI tab > Open the AI folder > Setup.cmd (once). The AI can stay off."), 150, 200, 240)
        end
    end
end
function B.onClick(_, button)
    B.dialog = nil
    B.answer(button ~= nil and button.internal == "YES")
end
function B.ask()
    if B.dialog ~= nil then return false end
    local p = playerOf()
    local ok = pcall(function()
        local w, h = 560, 260
        local x = getCore():getScreenWidth() / 2 - w / 2
        local y = getCore():getScreenHeight() / 2 - h / 2
        local dlg = ISModalDialog:new(x, y, w, h, B.questionText(), true, B, B.onClick, p and p:getPlayerNum() or 0)
        dlg:initialise()
        dlg:addToUIManager()
        B.dialog = dlg
    end)
    -- primary message: pause in single player (the player can still read and answer)
    if ok and type(M.isSP) == "function" and M.isSP() then
        pcall(function() local sc = UIManager.getSpeedControls(); if sc ~= nil and sc:getCurrentGameSpeed() > 0 then sc:SetCurrentGameSpeed(0) end end)
    end
    return ok
end
function B.due()
    if B.setting("bugReportAsk") == false then return false end
    return not B.answered()
end
function B.tick()
    if B.done then return end
    local t = nowMs()
    B.startedAt = B.startedAt or t
    if t - B.startedAt < (tonumber(B.setting("bugReportAskSec")) or 20) * 1000 then return end
    B.done = true
    if playerOf() == nil or not B.due() then return end
    B.ask()
end
-- the AI tab's button (shown to everyone: each PC answers for itself)
function B.button()
    local on = B.isOn()
    return { label = on and tr("BtnOn", "Bug reports: on") or tr("BtnOff", "Bug reports: off"),
        tip = tr("Tip", "On: when one of this mod's features switches itself off after an error, the helper sends the mod author a short report (which feature, the error, the end of console.txt; your Windows name removed; at most 3 a day). Needs the helper (Setup.cmd), not the AI. Click to switch."),
        fn = function(win) B.write(not on); if win then win.sig = nil; pcall(function() win:refresh() end) end end }
end

----------------------------------------------------------------------------------------------------------------
-- MANUAL report: "Report a bug" (right-click / radial, Help, AI tab). Not every error switches a feature off, so the
-- player can send one any time: a note + health report + end of console.txt. Works with automatic reports off (the
-- click is the consent). Game writes alifeai_report_send.txt; the helper sends and answers in alifeai_report_result.txt.
----------------------------------------------------------------------------------------------------------------
B.REQ = "alifeai_report_send.txt"
B.RES = "alifeai_report_result.txt"
B.WAIT_MS = 45000
local function letter(text, bad)
    local p = playerOf()
    if p and type(ALifeLetter) == "function" then pcall(ALifeLetter, p, text, 150, 200, 240, bad) end
end
local function discordTail() return B.DISCORD ~= "" and (" " .. tr("OrDiscord", "Or post Zomboid\\console.txt on the mod's Discord: {1}", B.DISCORD)) or "" end
-- one line, no control characters, at most 1000 characters (it goes in a key=value file)
function B.cleanNote(s)
    s = tostring(s or "")
    s = string.gsub(s, "\r\n", " / "); s = string.gsub(s, "[\r\n]", " / ")
    s = string.gsub(s, "%c", " ")
    s = string.gsub(s, "^%s+", ""); s = string.gsub(s, "%s+$", "")
    if #s > 1000 then s = string.sub(s, 1, 1000) end
    return s
end
function B.sendManual(note)
    if B.pending ~= nil then letter(tr("Busy", "Still sending your last bug report.")); return false end
    -- a fresh health report first (what turned off, costs)
    local HL = rawget(_G, "ALifeHealth")
    if type(HL) == "table" and type(HL.writeFile) == "function" then pcall(HL.writeFile) end
    local hours = 0
    pcall(function() hours = math.floor(getGameTime():getWorldAgeHours() * 10) / 10 end)
    local id = "g" .. tostring(math.floor(nowMs()))
    local text = "id=" .. id .. "\r\nver=" .. tostring(B.VERSION or "?") .. "\r\nhours=" .. tostring(hours)
        .. "\r\nnote=" .. B.cleanNote(note) .. "\r\n"
    if not (type(M.writeFile) == "function" and M.writeFile(B.REQ, text)) then
        letter(tr("NoWrite", "Couldn't write the bug report file.") .. discordTail(), true); return false
    end
    B.pending = { id = id, at = nowMs(), lastCheck = 0 }
    letter(tr("Sending", "Sending your bug report..."))
    print(TAG .. " manual report queued " .. id)
    return true
end
B.RESULT_TEXT = {
    sent = "Bug report sent. Thanks!",
    limit = "Bug report not sent: today's limit is reached (manual_per_day in Zomboid\\Lua\\alifeai_report.txt).",
    nourl = "Bug report not sent: no report address (bridge\\report_url.txt is empty).",
    failed = "Bug report couldn't be sent ({1}).",
}
function B.poll()
    local pd = B.pending
    if pd == nil then return end
    local t = nowMs()
    if t - pd.lastCheck < 1000 then return end
    pd.lastCheck = t
    local lines = type(M.readLines) == "function" and M.readLines(B.RES) or nil
    local kv = {}
    for _, l in ipairs(lines or {}) do local k, v = string.match(l, "^([%w_]+)=(.*)$"); if k then kv[k] = v end end
    if kv.id == pd.id then
        B.pending = nil
        local st = kv.state or "failed"
        local msg = tr("Res_" .. st, B.RESULT_TEXT[st] or B.RESULT_TEXT.failed, kv.msg or "?")
        if st == "sent" then
            if B.DISCORD ~= "" then msg = msg .. " " .. tr("Follow", "Follow it on {1}", B.DISCORD) end
            letter(msg)
        else
            letter(msg .. discordTail(), true)
        end
        print(TAG .. " manual report " .. pd.id .. ": " .. st)
        return st
    end
    if t - pd.at > B.WAIT_MS then
        B.pending = nil
        letter(tr("NoAnswer", "No answer from the mod's helper, so the bug report wasn't sent. Is it running? A-Life window > AI tab.") .. discordTail(), true)
        return "timeout"
    end
end
-- the helper isn't running: say how to start it (and the by-hand way)
function B.helperMissing()
    local text = " <SIZE:medium> " .. tr("RepT", "Report a bug") .. " <LINE> <SIZE:small> "
        .. tr("RepNoHelper", "Bug reports go out through the mod's small helper program, and it isn't running on this PC. The game can't reach the internet itself. <LINE> <LINE> Start it: A-Life window > AI tab > Open the AI folder > Setup.cmd (first time) or \"Restart AI helper.cmd\". The AI can stay off. <LINE> <LINE> Or by hand: post Zomboid\\console.txt and Zomboid\\Lua\\ALifeChatPlus_health.txt on the mod's Discord{1}. Do it before you restart the game: console.txt starts over every launch.",
            B.DISCORD ~= "" and (": " .. B.DISCORD) or "")
    pcall(function()
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        local w, h = math.min(620, sw - 40), math.min(320, sh - 40)
        local modal = ISModalRichText:new((sw - w) / 2, (sh - h) / 2, w, h, text, false)
        modal:initialise(); modal:addToUIManager()
    end)
end
-- the button: helper down -> how to start it; up -> a box for a note, then send
function B.openManual()
    if not B.helperUp() then B.helperMissing(); return "nohelper" end
    local p = playerOf()
    local ok = pcall(function()
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        local w, h = math.min(560, sw - 40), math.min(280, sh - 40)
        local box = ISTextBox:new((sw - w) / 2, (sh - h) / 2, w, h,
            tr("RepAsk", "Report a bug: what went wrong? (optional)\nSent to the mod author with the end of console.txt. Send it right after it happens."),
            "", B, function(_, button)
                if button == nil or button.internal ~= "OK" then return end
                local txt = ""
                pcall(function() txt = button.parent.entry:getText() end)
                B.sendManual(txt)
            end, p and p:getPlayerNum() or 0)
        box:setMultipleLine(true)
        box:setNumberOfLines(5)
        box:initialise(); box:addToUIManager()
    end)
    return ok and "box" or "error"
end
function B.sendButton()
    return { label = tr("BtnSend", "Report a bug"), accent = true,
        tip = tr("TipSend", "Something broke or acted strange? Send the mod author a report now: your note, the health report and the end of console.txt (your Windows name removed). Works with automatic reports off. Needs the helper (Setup.cmd), not the AI."),
        fn = function() B.openManual() end }
end
-- right-click menu (or the A-Life radial): "Report a bug (A-Life)". Setting bugReportMenu.
B.DEFAULTS.bugReportMenu = true
B.registerSettings()
if type(ALifeRadial) ~= "table" then pcall(require, "ALifeNPCOverhaul/AA_Radial") end
if type(ALifeRadial) == "table" and type(ALifeRadial.addFiller) == "function" and ALifeSide.ui and ALifeSide.ui() then
    ALifeRadial.addFiller("bugreport", "windows", function(playerNum, context, worldobjects, test)
        if test == true or B.setting("bugReportMenu") == false or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        context:addOption(tr("Menu", "Report a bug (A-Life)"), nil, function() B.openManual() end)
    end)
end

if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        B.registerSettings()
        print(TAG .. " ready v" .. tostring(B.VERSION) .. ": bug reports " .. (B.isOn() and "on" or "off")
            .. (B.answered() and "" or " (will ask once)") .. ", Report a bug button")
    end)
end
if type(Events) == "table" and Events.OnTick ~= nil and ALifeHealth and ALifeHealth.add then
    ALifeHealth.add(Events.OnTick, "ALifeBugReportsAsk", function()
        if not B.done then pcall(B.tick) end
        if B.pending ~= nil then pcall(B.poll) end
    end)
end
return B
