-- A-Life NPC Overhaul 0.8.12 (Rock List 2): HOVER CUE. Rest the mouse on someone for half a second and one or two
-- short lines show over their head: how they are toward you, and why ("Wary of you. Hand near the knife." /
-- "Out for you. They haven't forgotten." / "Won't come along: doesn't trust you yet."). No box, no numbers.
-- The same words show over whoever the quick wheel is for, and at the top of the talk window.
-- Passing over someone shows nothing. The line stays a moment after the mouse leaves, so a walking NPC doesn't blink.
-- Facts (stance, why hostile, opinion band, what's in their hand) come from the server ("hoverAsk" -> "hoverFacts",
-- ALifeCues); refusals and mood are this client's own (ALifeTalk_QoL whyNot, Psyche moodOf).
-- Settings (ALifeCues.DEFAULTS): hoverCue, hoverKeyOnly (+ Options > Mods key "Hover: read people"), hoverDelayMs,
-- hoverRange, hoverStickMs, hoverPickTiles, hoverAskMs, hoverWhyMin, hoverHeadPx, hoverWheel, hoverTalkTop.
-- Performance: people near you are listed every 500 ms; the mouse is checked every 100 ms; drawing is one or two
-- strings a frame, only while a line is up.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Hover") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCues"
local M = ALifeLLMTalk
local U = ALifeCues
if type(M) ~= "table" or type(U) ~= "table" then return end
local TAG = "[ALifeHover]"
ALifeHover = ALifeHover or {}
local K = ALifeHover
K.VERSION = ALifeSide.MOD_VERSION
K.facts, K.refused, K.near = K.facts or {}, K.refused or {}, K.near or {}
K.metrics = { asks = 0, shown = 0, picks = 0 }
U.registerSettings()

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function num(k) return tonumber(U.setting(k)) or U.DEFAULTS[k] end
local tr = U.tr

----------------------------------------------------------------------------------------------------------------
-- facts: ask the server, keep the answer a few seconds
----------------------------------------------------------------------------------------------------------------
function K.ask(uid, force)
    uid = tostring(uid)
    local t = nowMs()
    local row = K.facts[uid]
    if not force and row and t - row.askedAt < num("hoverAskMs") then return row end
    K.facts[uid] = row or { askedAt = t }
    K.facts[uid].askedAt = t
    local p = playerOf()
    if p and fn(ALifeCmd, "send") then K.metrics.asks = K.metrics.asks + 1; pcall(ALifeCmd.send, p, "hoverAsk", { uid = uid }) end
    return K.facts[uid]
end
function K.onFacts(p)
    if type(p) ~= "table" or p.uid == nil then return end
    local uid = tostring(p.uid)
    local row = K.facts[uid] or { askedAt = nowMs() }
    row.f = (p.none ~= true) and p or nil
    row.gotAt = nowMs()
    K.facts[uid] = row
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("hoverFacts", function(p) pcall(K.onFacts, p) end) end

-- 0.8.12 (Rock List 2): LAST WARNING before they attack (ALifeTalkPatch.attackNow / the opinion ladder's last step):
-- a red note over you, a red letter, and the hover line over them ("About to attack you. Walk away.") until it ends.
K.lastWarn = K.lastWarn or {}
function K.onLastWarn(p)
    if type(p) ~= "table" or p.uid == nil then return end
    local uid = tostring(p.uid)
    local sec = tonumber(p.sec) or num("attackLastWarnSec")
    K.lastWarn[uid] = nowMs() + (sec + 2) * 1000
    local sh = nil
    for _, e in ipairs(K.near or {}) do if e.uid == uid then sh = e.shell end end
    if sh == nil then sh = U.shellOf(uid) end
    if sh and U.setting("hoverCue") ~= false then K.pinned = { uid = uid, shell = sh, at = nowMs(), untilMs = K.lastWarn[uid], warn = true } end
    if U.setting("attackLastWarnNote") == false then return end
    local who = (type(p.name) == "string" and p.name ~= "") and p.name or tr("Someone", "Someone")
    local text = U.tr("LastWarnNote", "{1}: last warning. Walk away now.", who)
    local pl = playerOf()
    if pl then pcall(function() pl:setHaloNote(text, 235, 90, 70, 300) end) end
    if type(ALifeLetter) == "function" and pl then pcall(ALifeLetter, pl, text, 242, 107, 87, true) end
end
function K.onLastWarnOff(p)
    if type(p) ~= "table" or p.uid == nil then return end
    K.lastWarn[tostring(p.uid)] = nil
    if K.pinned and K.pinned.warn and K.pinned.uid == tostring(p.uid) then K.pinned = nil end
    if p.heeded and U.setting("attackLastWarnNote") ~= false then
        local pl = playerOf()
        if pl then pcall(function() pl:setHaloNote(U.tr("LastWarnHeeded", "They let you go."), 200, 200, 190, 200) end) end
    end
end
if fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("lastWarn", function(p) pcall(K.onLastWarn, p) end)
    ALifeCmd.onClient("lastWarnOff", function(p) pcall(K.onLastWarnOff, p) end)
end

-- refusals: ALifeTalk_QoL's whyNot tells us (wrapped at game start: QoL loads after this file)
function K.noteRefusal(uid, what, reason)
    reason = tostring(reason or "")
    reason = string.gsub(reason, ";.*$", "")          -- never the numbers (same cleaning as whyNot)
    reason = string.gsub(reason, "%s*%(.-%d.-%)", "")
    K.refused[tostring(uid)] = { what = tostring(what or "do that"), why = reason, at = nowMs() }
end
function K.hookWhyNot()
    if K.whyHooked or not fn(M, "whyNot") then return K.whyHooked == true end
    local orig = M.whyNot
    M.whyNot = function(uid, what, reason, ...)
        pcall(K.noteRefusal, uid, what, reason)
        return orig(uid, what, reason, ...)
    end
    K.whyHooked = true
    return true
end

local function inParty(uid, p)
    if fn(M, "partyIsMember") then local ok, v = pcall(M.partyIsMember, uid, p); if ok and v then return true end end
    local cc = PA().CompanionClient
    if type(cc) == "table" and type(cc.rows) == "table" then
        for _, row in ipairs(cc.rows) do if type(row) == "table" and tostring(row.uid) == uid then return true end end
    end
    return false
end
local function moodOf(uid)
    if not fn(M, "moodOf") then return nil end
    local ok, m = pcall(M.moodOf, uid, 1)
    if ok and type(m) == "table" and type(m[1]) == "table" and type(m[1].adj) == "string" then return m[1].adj end
    return nil
end
-- the lines for someone (nil = nothing worth saying yet)
function K.linesFor(uid)
    uid = tostring(uid)
    local p = playerOf()
    local row = K.ask(uid)
    local f = {}
    if type(row) == "table" and type(row.f) == "table" then for k, v in pairs(row.f) do f[k] = v end end
    f.party = inParty(uid, p)
    local r = K.refused[uid]
    if r and nowMs() - r.at <= num("hoverWhyMin") * 60000 then f.refused = r end
    f.mood = moodOf(uid)
    if K.lastWarn[uid] and nowMs() < K.lastWarn[uid] then f.lastWarn = true end
    if f.stance == nil and not f.party and f.refused == nil and not f.lastWarn then return nil end -- the server hasn't answered yet
    local lines, tone = U.lines(f)
    if #lines == 0 then return nil end
    return lines, tone
end

----------------------------------------------------------------------------------------------------------------
-- who is under the mouse
----------------------------------------------------------------------------------------------------------------
local function uidOf(sh)
    local sp = PA().Speech
    if not fn(sp, "variable") then return nil end
    local ok, uid = pcall(sp.variable, sh, "ALifeUID")
    if ok and uid ~= nil and uid ~= "" then return tostring(uid) end
    return nil
end
-- people near you: A-Life shells (the zombie list, read by their ALifeUID; works in single player and multiplayer)
function K.scan(p)
    local out = {}
    local px, py, pz = p:getX(), p:getY(), p:getZ()
    local r2 = num("hoverRange") ^ 2
    pcall(function()
        local list = getCell():getZombieList()
        for i = 0, math.min(list:size(), 800) - 1 do
            local sh = list:get(i)
            local dead = false
            pcall(function() dead = sh:isDead() == true end)
            if not dead then
                local x, y, z = sh:getX(), sh:getY(), sh:getZ()
                if math.abs(math.floor(z) - math.floor(pz)) == 0 and (x - px) ^ 2 + (y - py) ^ 2 <= r2 then
                    local uid = uidOf(sh)
                    if uid then out[#out + 1] = { uid = uid, shell = sh } end
                end
            end
        end
    end)
    K.near = out
    return out
end
-- mouse -> world (vanilla ISCoordConversion.ToWorld with the scaled mouse, as the debug brush tools do)
function K.mouseWorld(p)
    local ok, x, y = pcall(function() return ISCoordConversion.ToWorld(getMouseXScaled(), getMouseYScaled(), p:getZ()) end)
    if ok and tonumber(x) and tonumber(y) then return x, y end
    return nil
end
-- the body stands up from the feet: on screen that is toward lower x and y, so the mouse on someone's chest lands
-- about half a tile up-left of their feet. Score = the closer of feet and chest.
function K.pick(mx, my, list)
    local best, bd = nil, num("hoverPickTiles") ^ 2
    for _, e in ipairs(list or {}) do
        local x, y = nil, nil
        pcall(function() x, y = e.shell:getX(), e.shell:getY() end)
        if x then
            local d = math.min((mx - x) ^ 2 + (my - y) ^ 2, (mx - (x - 0.7)) ^ 2 + (my - (y - 0.7)) ^ 2)
            if d <= bd then best, bd = e, d end
        end
    end
    return best
end

-- state: cand (under the mouse, since), shown (uid, shell, until), pinned (wheel)
K.cand, K.shown, K.pinned = nil, nil, nil
local function keyHeld()
    local opt = type(ALifeRadial) == "table" and ALifeRadial.hoverKeyOpt or nil
    if opt == nil or not fn(opt, "getValue") then return false end
    local ok, k = pcall(opt.getValue, opt)
    if not ok or k == nil or k == 0 then return false end
    local down = false
    pcall(function() down = isKeyDown(k) == true end)
    return down
end
function K.step(t)
    local p = playerOf()
    if p == nil or U.setting("hoverCue") == false then K.shown = nil; return end
    if t - (K.scanAt or -1e12) >= 500 then K.scanAt = t; K.scan(p) end
    local keyOnly = U.setting("hoverKeyOnly") == true
    local held = keyOnly and keyHeld()
    local e = nil
    if not keyOnly or held then
        local mx, my = K.mouseWorld(p)
        if mx then e = K.pick(mx, my, K.near) end
    end
    if e then
        if K.cand == nil or K.cand.uid ~= e.uid then K.cand = { uid = e.uid, shell = e.shell, since = t }; K.ask(e.uid) end
        if held or t - K.cand.since >= num("hoverDelayMs") then
            if K.shown == nil or K.shown.uid ~= e.uid then K.metrics.shown = K.metrics.shown + 1 end
            K.shown = { uid = e.uid, shell = e.shell, untilMs = t + num("hoverStickMs") }
        end
    else
        K.cand = nil
    end
    if K.shown and (t > K.shown.untilMs or (keyOnly and not held)) then K.shown = nil end
    if K.pinned and t > K.pinned.untilMs then K.pinned = nil end
    -- the wheel closed: the pinned line goes with it (after a short grace, the wheel takes a frame to show)
    if K.pinned and not K.pinned.warn and t - K.pinned.at > 400 then
        local up = true
        pcall(function() local m = getPlayerRadialMenu(p:getPlayerNum()); up = m ~= nil and m:isReallyVisible() == true end)
        if not up then K.pinned = nil end
    end
end
-- the quick wheel: show the line over whoever it's for while it's open
function K.pin(uid, shell, ms)
    if uid == nil or U.setting("hoverCue") == false or U.setting("hoverWheel") == false then return end
    K.ask(uid, true)
    K.pinned = { uid = tostring(uid), shell = shell, at = nowMs(), untilMs = nowMs() + (tonumber(ms) or 30000) }
end

----------------------------------------------------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------------------------------------------------
local function toScreen(x, y, z, pn)
    local ok, sx, sy, zoom = pcall(function()
        local zm = getCore():getZoom(pn)
        local wx = IsoUtils.XToScreen(x, y, z, 0) - IsoCamera.getOffX()
        local wy = IsoUtils.YToScreen(x, y, z, 0) - IsoCamera.getOffY()
        return wx / zm, wy / zm, zm
    end)
    if ok and sx and sy then return sx, sy, zoom end
    return nil
end
local function drawOver(e, p)
    if e == nil or e.shell == nil then return end
    local lines, tone = K.linesFor(e.uid)
    if lines == nil then return end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = e.shell:getX(), e.shell:getY(), e.shell:getZ() end)
    if x == nil then return end
    local sx, sy, zoom = toScreen(x, y, z, p:getPlayerNum())
    if sx == nil then return end
    local tm = getTextManager()
    local fh = 16
    pcall(function() fh = tm:getFontHeight(UIFont.Small) end)
    local c = U.TONES[tone] or U.TONES.plain
    local top = sy - num("hoverHeadPx") / (zoom or 1) - #lines * (fh + 1)
    for i, line in ipairs(lines) do
        local ly = top + (i - 1) * (fh + 1)
        local a = i == 1 and 0.95 or 0.85
        local r, g, b = c[1], c[2], c[3]
        if i > 1 then r, g, b = U.TONES.plain[1], U.TONES.plain[2], U.TONES.plain[3] end
        tm:DrawStringCentre(UIFont.Small, sx + 1, ly + 1, line, 0, 0, 0, a * 0.8)
        tm:DrawStringCentre(UIFont.Small, sx, ly, line, r, g, b, a)
    end
end
-- the top of the talk window: the same words, one line, above the AI light
function K.drawTalkTop()
    if U.setting("hoverCue") == false or U.setting("hoverTalkTop") == false then return end
    local WT = ALifeWindowTalk
    if not fn(WT, "window") then return end
    local ok, win = pcall(WT.window)
    if not ok or win == nil or win.uid == nil then return end
    local lines, tone = K.linesFor(win.uid)
    if lines == nil then return end
    local x, y = 0, 0
    pcall(function() x, y = win:getAbsoluteX(), win:getAbsoluteY() end)
    local tm = getTextManager()
    local fh = 16
    pcall(function() fh = tm:getFontHeight(UIFont.Small) end)
    local c = U.TONES[tone] or U.TONES.plain
    local text = table.concat(lines, "  ")
    local ly = math.max(0, y - 2 * fh - 4)                    -- the AI light sits at y - fh - 2
    tm:DrawString(UIFont.Small, x + 7, ly + 1, text, 0, 0, 0, 0.8)
    tm:DrawString(UIFont.Small, x + 6, ly, text, c[1], c[2], c[3], 0.95)
end
function K.draw()
    local t = nowMs()
    if t - (K.stepAt or -1e12) >= 100 then K.stepAt = t; K.step(t) end
    local p = playerOf()
    if p == nil then return end
    if K.shown then drawOver(K.shown, p) end
    if K.pinned and (K.shown == nil or K.shown.uid ~= K.pinned.uid) then drawOver(K.pinned, p) end
    K.drawTalkTop()
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
function K.install()
    K.hookWhyNot()
    -- the quick wheel: R.open finds the shell under the mouse; pin the line on it while the wheel is up
    local R = ALifeRadial
    if not K.wheelHooked and fn(R, "personRing") then
        local orig = R.personRing
        R.personRing = function(groups, uid, playerObj, ...)
            if uid ~= nil then
                local sh = nil
                for _, e in ipairs(K.near or {}) do if e.uid == tostring(uid) then sh = e.shell end end
                if sh == nil then sh = U.shellOf(tostring(uid)) end
                pcall(K.pin, uid, sh, 30000)
            end
            return orig(groups, uid, playerObj, ...)
        end
        K.wheelHooked = true
    end
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "hoverCue", "Hover someone: a short line over their head (how they are toward you, and why)" },
            { "hoverKeyOnly", "Hover line only while the hover key is held (Options > Mods)" },
            { "hoverDelayMs", "Hover: how long the mouse rests on them first (ms)", { 250, 500, 800, 1200 } },
            { "hoverRange", "Hover: only people this close (tiles)", { 8, 15, 25 } },
            { "hoverStickMs", "Hover: the line stays this long after the mouse leaves (ms)", { 800, 1500, 3000 } },
            { "hoverWheel", "Hover line over whoever the quick wheel is for" },
            { "hoverTalkTop", "Hover line at the top of the talk window" },
            { "attackLastWarn", "A last warning before someone attacks you (not after a betrayal, a nemesis, or a killing they saw)" },
            { "attackLastWarnSec", "Last warning: seconds to walk away", { 3, 5, 8, 12 } },
            { "attackLastWarnLeave", "Last warning: tiles further away that count as walking away", { 4, 6, 10 } },
            { "attackLastWarnNote", "Last warning on screen too (red note + letter)" },
            { "partyNeedLow", "Party tab: hunger / thirst (0-100) that counts as peckish / dry", { 15, 25, 35 } },
            { "partyNeedBad", "Party tab: hunger / thirst that counts as hungry / thirsty", { 45, 55, 65 } },
            { "partyNeedUrgent", "Party tab: hunger / thirst that counts as starving / parched", { 70, 80, 90 } },
            { "partyAmmoLow", "Party tab: rounds left that count as low on ammo", { 3, 6, 12 } },
        }) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
    end
    if type(M.settingCatOf) == "table" then
        for _, k in ipairs({ "attackLastWarn", "attackLastWarnSec", "attackLastWarnLeave", "attackLastWarnNote" }) do
            if M.settingCatOf[k] == nil then M.settingCatOf[k] = "Groups, trade and the world" end
        end
        for _, k in ipairs({ "hoverCue", "hoverKeyOnly", "hoverDelayMs", "hoverRange", "hoverStickMs", "hoverWheel", "hoverTalkTop" }) do
            if M.settingCatOf[k] == nil then M.settingCatOf[k] = "Interface and immersion" end
        end
        for _, k in ipairs({ "partyNeedLow", "partyNeedBad", "partyNeedUrgent", "partyAmmoLow" }) do
            if M.settingCatOf[k] == nil then M.settingCatOf[k] = "Party and orders" end
        end
    end
    if type(M.winHelp) == "table" then
        table.insert(M.winHelp, { "Reading people", "Rest the mouse on someone for half a second: a line over their head says how they are toward you and why (wary, out for you, won't come along and why). Same words on the quick wheel and at the top of the talk window. Settings: off, hold-a-key only, delay, range." })
    end
    print(TAG .. " ready v" .. K.VERSION .. ": hover cue " .. (U.setting("hoverCue") == false and "OFF" or "on")
        .. (U.setting("hoverKeyOnly") == true and " (key only)" or "") .. ", " .. tostring(num("hoverDelayMs")) .. " ms, "
        .. tostring(num("hoverRange")) .. " tiles; wheel " .. (K.wheelHooked and "yes" or "no") .. ", refusals " .. (K.whyHooked and "yes" or "no"))
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
if type(Events) == "table" and Events.OnPostUIDraw ~= nil and ALifeHealth and ALifeHealth.add then
    ALifeHealth.add(Events.OnPostUIDraw, "ALifeHover", function() local ok, err = pcall(K.draw); if not ok and not K.warned then K.warned = true; print(TAG .. " draw failed: " .. tostring(err)) end end)
end
return K
