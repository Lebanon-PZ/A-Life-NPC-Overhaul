-- A-Life NPC Overhaul pre-1.0: QUIET BUBBLES + SHORT-TERM CHAT.
--  1. plainBubbles (default on): an NPC's line floats over their head as plain text, the vanilla overhead line (no
--     card behind it). At most bubbleMax (3) lines are drawn over heads within bubbleWindowSec (6 s); the rest still
--     go to the chat window, so a crowd is readable there instead of a pile of text on screen. Lines from far-off
--     "ambient" chatter are not drawn overhead at all (chat window only).
--  2. recentChat (default on): NPC lines always land in the chat window (even with A-Life's NpcChatLog off), and each
--     one is removed again recentChatMin (5) minutes later: a short memory, nothing to scroll back to.
-- Wraps ProjectALife.Speech.display (client), ProjectALife.NpcChat.intoVanilla and ProjectALife.TalkUi.chatMode.
-- Nothing in the other mod is edited; every call is guarded. Immersion does not change any of it.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Bubbles")
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeBubbles]"
ALifeBubbles = ALifeBubbles or {}
local K = ALifeBubbles
K.VERSION = "0.9.6"
K.keep, K.shown = {}, {}
K.metrics = { plain = 0, capped = 0, pruned = 0 }

local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("plainBubbles", true)
setting("bubbleMax", 3)
setting("bubbleWindowSec", 6)
setting("recentChat", true)
setting("recentChatMin", 5)

local function nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return 0
end

-- the plain overhead line (instead of A-Life's bubble card). Returns true when handled.
function K.plain(shell, text, color, kind, uid)
    local pa = ProjectALife
    local sp = pa.Speech
    if type(sp.engineLine) ~= "function" then return nil end
    local now = nowMs()
    local win = (tonumber(M.settings.bubbleWindowSec) or 6) * 1000
    local live = {}
    for _, t in ipairs(K.shown) do if now - t < win then live[#live + 1] = t end end
    K.shown = live
    local ambient = kind == "ambient"
    local draw = (not ambient) and #live < (tonumber(M.settings.bubbleMax) or 3)
    if draw then
        local r, g, b = 1, 1, 1
        local B = pa.SpeechBubbles
        if type(B) == "table" and type(B.colorOf) == "function" then
            local ok, rr, gg, bb = pcall(B.colorOf, color, uid)
            if ok and rr then
                r, g, b = rr, gg, bb
                if type(B.textColor) == "function" then
                    local ok2, tr, tg, tb = pcall(B.textColor, rr, gg, bb, color)
                    if ok2 and tr then r, g, b = tr, tg, tb end
                end
            end
        end
        local ok = pcall(sp.engineLine, shell, text, { r, g, b })
        if not ok then return nil end
        K.shown[#K.shown + 1] = now
        K.metrics.plain = K.metrics.plain + 1
    else
        K.metrics.capped = K.metrics.capped + 1
    end
    if type(sp.mirror) == "function" then pcall(sp.mirror, shell, text, color, kind, uid) end -- the chat window still gets it
    return true
end

function K.prune()
    local mins = tonumber(M.settings.recentChatMin) or 5
    if mins <= 0 or #K.keep == 0 then return end
    local chat = ProjectALife and ProjectALife.NpcChat
    if type(chat) ~= "table" or type(chat.vanillaTab) ~= "function" then return end
    local now = nowMs()
    local old = {}
    while #K.keep > 0 and now - K.keep[1].at > mins * 60000 do old[#old + 1] = table.remove(K.keep, 1) end
    if #old == 0 then return end
    local tab = chat.vanillaTab()
    if tab == nil then return end
    for _, e in ipairs(old) do
        for i, v in ipairs(tab.chatTextLines) do if v == e.line then table.remove(tab.chatTextLines, i); break end end
        for i, m in ipairs(tab.chatMessages) do if type(m) == "table" and rawget(m, "line") == e.msgLine then table.remove(tab.chatMessages, i); break end end
        K.metrics.pruned = K.metrics.pruned + 1
    end
    local scrolled = true
    pcall(function() scrolled = tab:getScrollHeight() <= tab:getHeight() or (tab.vscroll and tab.vscroll.pos == 1) end)
    local text = ""
    for i, v in ipairs(tab.chatTextLines) do
        if i == #tab.chatTextLines then v = string.gsub(v, " <LINE> $", "") end
        text = text .. v
    end
    tab.text = text
    pcall(function() tab:paginate() end)
    if scrolled then pcall(function() tab:setYScroll(-10000) end) end
end

function K.install()
    if K.installed then return true end
    local pa = type(ProjectALife) == "table" and ProjectALife or nil
    if pa == nil or type(pa.Speech) ~= "table" or type(pa.Speech.display) ~= "function" then return false end
    -- Speech.display: plain overhead text (outermost: after Earshot has cut / garbled the line)
    local origDisplay = pa.Speech.display
    pa.Speech.display = function(shell, text, color, kind, uid)
        -- earshot first (ALifeTalk_Earshot): cut / garbled by distance; then plain text, else A-Life's own bubble
        local E = ALifeEarshot
        local skip = false
        if type(E) == "table" and type(E.apply) == "function" and not E.skip and type(text) == "string" then
            local res = E.apply(shell, text, kind)
            if res == false then return true end
            text = res
            skip = true
        end
        if M.settings.plainBubbles ~= false and type(text) == "string" and type(pa.Speech.aboardHeli) == "function" and pa.Speech.aboardHeli(shell) ~= true then
            local ok, res = pcall(K.plain, shell, text, color, kind, uid)
            if ok and res == true then return true end
        end
        if skip then E.skip = true end
        local ok, res = pcall(origDisplay, shell, text, color, kind, uid)
        if skip then E.skip = false end
        if not ok then error(res, 0) end
        return res
    end
    local chat = pa.NpcChat
    if type(chat) == "table" and type(chat.intoVanilla) == "function" then
        local orig = chat.intoVanilla
        chat.intoVanilla = function(line)
            local ok = orig(line)
            if ok == true and M.settings.recentChat ~= false then
                K.keep[#K.keep + 1] = { line = tostring(line) .. " <LINE> ", msgLine = line, at = nowMs() }
            end
            return ok
        end
    end
    local ui = pa.TalkUi
    if M.settings.recentChat ~= false and type(ui) == "table" and type(ui.chatMode) == "function" then
        local origMode = ui.chatMode
        ui.chatMode = function(...)
            local m = origMode(...)
            if m == nil or m < 1 then return 1 end -- NPC talk always reaches the chat window (not ambient chatter)
            return m
        end
    end
    K.installed = true
    print(TAG .. " ready v" .. K.VERSION .. ": plain overhead text (max " .. tostring(M.settings.bubbleMax) .. " per " .. tostring(M.settings.bubbleWindowSec)
        .. " s), NPC chat forgotten after " .. tostring(M.settings.recentChatMin) .. " min")
    return true
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function() K.keep, K.shown = {}, {}; pcall(K.install) end)
end
if Events and Events.OnTick then
    local tries, last = 0, 0
    local function tick()
        if not K.installed then
            tries = tries + 1
            if tries % 30 == 0 then pcall(K.install) end
            return
        end
        local now = nowMs()
        if now - last >= 5000 then last = now; pcall(K.prune) end
    end
    Events.OnTick.Add(tick)
end
return K
