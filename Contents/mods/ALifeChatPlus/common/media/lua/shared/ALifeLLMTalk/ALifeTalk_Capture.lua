-- A-Life NPC Overhaul 0.8.5: captured, client side (the rules live in shared/ALifeNPCOverhaul/ALifeCapture.lua).
-- What only your own game can do: black out on the march (vanilla sleep: setForceWakeUpTime, setPlayerFallAsleep,
-- FadeOut - the same calls as sleeping on the floor), wake where they hold you (teleportTo), your hands (timed actions
-- other than walking and doors are refused; attacking is banned: IsoPlayer.setBannedAttacking), the walkie's 5 s,
-- being fed, a beating, and the big messages (popup + pause, hard rule 8).
-- Also: talking to a captor ("let me go", "untie me"), and the camp rule (radial > Camp > "If one of us is taken...").
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Capture") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UI" here (client-only file, loads after shared; used at call time only)
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UIBond" here (client-only file, loads after shared; used at call time only)
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeCapture"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Capture"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Capture") end end

local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeCapture) ~= "table" then return end
local C = ALifeCapture

ALifeTalkCapture = ALifeTalkCapture or {}
local K = ALifeTalkCapture
local TAG = "[ALifeTalkCapture]"
K.VERSION = ALifeSide.MOD_VERSION
K.metrics = K.metrics or { blackouts = 0, refused = 0, walkieDelayed = 0, talks = 0 }
K.held, K.handsUntil, K.phase = K.held or false, K.handsUntil, K.phase

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return num(h, 0) end

-- ---------------------------------------------------------------------------------------------------- settings
function K.settings()
    if type(M.settings) ~= "table" then return end
    for k, v in pairs(C.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, k in ipairs(M.fileKeys) do have[k] = true end
        for _, k in ipairs(C.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
    end
end
K.settings()
K.ROWS = {
    { "capture", "You can be taken alive: surrender in a stand-off, or go down to people who'd want you (never zombies)" },
    { "captureSurrender", "Captured: chance people who want captives take you when you surrender (%)", { 0, 15, 35, 60 } },
    { "lastStand", "Last stand: people who'd want you alive drop you instead of killing you" },
    { "lastStandHealth", "Last stand: you go down at this much health", { 5, 10, 15, 25 } },
    { "lastStandChance", "Last stand: chance they take you instead of finishing you (%)", { 25, 60, 90 } },
    { "captureWalkTiles", "Captured: how fast they march you (tiles per game hour; the time that passes)", { 150, 300, 600 } },
    { "captureMarchMax", "Captured: longest march (game hours)", { 4, 8, 16 } },
    { "captureLeash", "Captured: a guard who sees you this far out drags you back (tiles)", { 8, 12, 20 } },
    { "captureEscape", "Captured: this far away and unseen, you're out (tiles)", { 30, 45, 80 } },
    { "captureWatchStep", "Captured: each time they catch you they watch this much further (tiles)", { 0, 6, 12 } },
    { "captureBeat", "Captured: rough crews may beat you when they catch you running (real injury, nothing shown)" },
    { "captureFeedH", "Captured: fed and watered every (game hours)", { 6, 8, 12 } },
    { "captureTalkOut", "Captured: base chance talking your way out works (%; + how much they like you)", { 0, 5, 10, 20 } },
    { "captureHelpTrust", "Captured: how much a captor must like you to help with your hands", { 20, 40, 60 } },
    { "captureRescue", "Captured: your people come for you (camp rule, how they feel about you, the Oath)" },
    { "captureFindOutH", "Captured: game hours after they learn of it before your people set out", { 1, 2, 6 } },
    { "captureRansomItems", "Captured: things your people hand over for you (camp rule a)", { 2, 4, 6 } },
    { "captureOathDead", "The Oath: chance everyone in the camp is dead when they come (%)", { 0, 10, 20, 30 } },
    { "captureOathGun", "The Oath: chance they wake you and hand you a gun (%)", { 30, 50, 70 } },
    { "captureWorkDays", "Captured by the army: days of work before they let you go", { 3, 7, 14 } },
    { "captureFightMin", "Captured, camp rule b: game minutes before the fight is settled by the odds", { 5, 10, 30 } },
    { "prisonerAnywhere", "Prisoners: take a surrendered person prisoner where they stand (off = only inside your base)" },
    { "prisonerLeashTiles", "Prisoners: held while you stay this close when outside your base (tiles)", { 15, 30, 60 } },
    { "prisonerRope", "Prisoners: taking one costs rope (they are tied up and cannot work until you untie them at your base)" },
    { "prisonerLead", "Prisoners: one taken outside your base walks after you (off = they stand until you lead them)" },
    { "prisonerFeed", "Prisoners: a confined one eats and drinks what you leave in containers in their cell" },
    { "prisonerEatAt", "Prisoners: how hungry or thirsty before they eat or drink (0-100)", { 40, 60, 80 } },
    { "prisonerFullAt", "Prisoners: they eat or drink until hunger or thirst is down to this (0-100)", { 10, 20, 40 } },
    { "prisonerNeglectEscape", "Prisoners: extra % a day to run after going hungry or dry half a day", { 0, 15, 30 } },
    { "prisonerRopeCount", "Prisoners: rope used to tie one up", { 1, 2, 3 } },
    { "prisonerTiedEscape", "Prisoners: % per day a tied prisoner gets loose", { 0, 2, 5, 10 } },
    { "prisonerCodeOrange", "Prisoners: an escape pops a priority 'Code Orange' message" },
    { "prisonerFindH", "Prisoners: game hours you have to find someone who ran", { 6, 24, 48 } },
    { "prisonerTellChance", "Prisoners: % someone who got away tells their people about you", { 0, 30, 60, 100 } },
    { "prisonerAwayMin", "Prisoners: game minutes you can be away before they slip off", { 10, 30, 60 } },
}
function K.addRows()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(K.ROWS) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
        if type(ALifeTalkSettings) == "table" and tonumber(ALifeTalkSettings.PER_COL) then
            ALifeTalkSettings.PER_COL = math.max(ALifeTalkSettings.PER_COL, math.ceil(#M.settingRows / 3))
        end
    end
    if type(M.settingCatOf) == "table" then for _, r in ipairs(K.ROWS) do M.settingCatOf[r[1]] = "Injury, death and prisoners" end end
end
K.addRows()

-- ---------------------------------------------------------------------------------------------------- big messages
-- primary message: popup + pause (SP), the player can still type
function K.popup(text)
    local player = playerOf()
    pcall(function()
        local w, h = 420, 160
        local x = getCore():getScreenWidth() / 2 - w / 2
        local y = getCore():getScreenHeight() / 2 - h / 2
        local dlg = ISModalDialog:new(x, y, w, h, text, false, nil, nil, player and player:getPlayerNum() or 0)
        dlg:initialise()
        dlg:addToUIManager()
    end)
    if fn(M, "isSP") and M.isSP() then
        pcall(function() local sc = UIManager.getSpeedControls(); if sc ~= nil and sc:getCurrentGameSpeed() > 0 then sc:SetCurrentGameSpeed(0) end end)
    end
    if fn(M, "logInteraction") then pcall(M.logInteraction, nil, text, nil, nil, "event") end
end
function K.line(text) if fn(M, "radioLine") then pcall(M.radioLine, nil, text) else print(text) end end

-- ---------------------------------------------------------------------------------------------------- your body
function K.hands(player, tied)
    pcall(function() player:setBannedAttacking(tied == true) end)
end
-- black out: vanilla's sleep on the floor, woken when the march is done; you wake where they hold you
function K.blackout(player, x, y, z, h)
    K.metrics.blackouts = K.metrics.blackouts + 1
    pcall(function() player:teleportTo(num(x, 0) + 0.5, num(y, 0) + 0.5, num(z, 0)) end)
    pcall(function()
        local wake = getGameTime():getTimeOfDay() + math.max(0.5, num(h, 1))
        if wake >= 24 then wake = wake - 24 end
        player:setBedType("floor")
        player:setForceWakeUpTime(wake)
        player:setAsleepTime(0.0)
        player:setAsleep(true)
        UIManager.setFadeBeforeUI(player:getPlayerNum(), true)
        UIManager.FadeOut(player:getPlayerNum(), 1)
        if ALifeSide.world() then
            getSleepingEvent():setPlayerFallAsleep(player, math.max(1, math.floor(num(h, 1) + 0.5)))
            if IsoPlayer.allPlayersAsleep() then UIManager.getSpeedControls():SetCurrentGameSpeed(3) end
        end
    end)
end
function K.feed(player)
    pcall(function()
        local st = player:getStats()
        st:set(CharacterStat.HUNGER, math.max(0, st:get(CharacterStat.HUNGER) - 0.4))
        st:set(CharacterStat.THIRST, math.max(0, st:get(CharacterStat.THIRST) - 0.5))
    end)
end

K.WHY = {
    escaped = "You got away.", talked = "They let you go.", ransom = "Your people paid for you. You're free.",
    rescued = "Your people came for you. You're free.", oath = "They came for you. Everyone in that camp is dead.",
    worked = "Your work's done. The army lets you go.", captors_dead = "Nobody's left holding you. You're free.",
}
function K.onState(p)
    if type(p) ~= "table" then return end
    local player = playerOf()
    if player == nil then return end
    K.phase = p.phase
    if p.phase == "march" then
        K.held = true
        K.hands(player, true)
        local who = tostring(p.name or "They")
        local took = num(p.taken, 0) > 0 and " They took your radio and your guns." or ""
        K.popup((p.why == "surrender" and "You put your hands up. " or "You go down. ") .. who .. "'s people tie your hands and march you off." .. took)
        K.blackout(player, p.x, p.y, p.z, p.hours)
    elseif p.phase == "held" then
        K.held = true
        K.hands(player, true)
        local what = p.kind == "work" and "The army puts you to work. You'll go when the work's done."
            or (p.kind == "slaves" and "They mean to sell you." or "They want a ransom for you.")
        K.popup("You come to where they're holding you. " .. what .. " You can walk; your hands are tied.")
    elseif p.phase == "dragged" then
        pcall(function() player:teleportTo(num(p.x, 0) + 0.5, num(p.y, 0) + 0.5, num(p.z, 0)) end)
        if num(p.beat, 0) > 0 then pcall(function() player:getBodyDamage():ReduceGeneralHealth(num(p.beat, 0)) end) end
        pcall(function() HaloTextHelper.addBadText(player, tostring(p.name or "They") .. " dragged you back.") end)
    elseif p.phase == "fed" then
        K.feed(player)
        pcall(function() HaloTextHelper.addGoodText(player, "They give you something to eat and drink.") end)
    elseif p.phase == "breakout" then
        K.hands(player, false)
        K.popup(tostring(p.name or "Someone") .. " wakes you, cuts you loose" .. (p.gun and " and puts a gun in your hand" or "") .. ". Fight your way out.")
    elseif p.phase == "ransom" then
        K.line("Your people hand over " .. tostring(num(p.given, 0)) .. " things for you.")
    elseif p.phase == "rescue_failed" then
        K.popup("Your people came for you. " .. tostring(p.name or "One of them") .. " didn't make it. The rest pulled back.")
    elseif p.phase == "oath" then
        -- the free message follows
    elseif p.phase == "free" then
        K.held, K.handsUntil = false, nil
        K.hands(player, false)
        K.popup(K.WHY[p.why] or "You're free.")
    end
end
function K.onPrisonerCode(p)
    if type(p) ~= "table" or type(p.text) ~= "string" then return end
    K.popup(p.text)
end
function K.onNotice(p)
    if type(p) ~= "table" then return end
    K.popup(tostring(p.name or "One of yours") .. " has been taken by " .. tostring(p.by or "someone") .. "'s people.")
end
function K.onTalked(p)
    if type(p) ~= "table" then return end
    local sh = fn(PA().Talk, "shellFor") and PA().Talk.shellFor(p.uid) or nil
    if sh ~= nil and fn(M, "say") and p.line then pcall(M.say, sh, playerOf(), p.line, {}) end
    if p.ask == "hands" and p.ok then K.handsUntil = num(p.untilH, hours() + 0.5); K.hands(playerOf(), false) end
end

-- ---------------------------------------------------------------------------------------------------- your hands
K.ALLOWED = { ISWalkToTimedAction = true, ISPathFindAction = true, ISOpenCloseDoor = true, ISOpenCloseWindow = true,
    ISClimbThroughWindow = true, ISGetOnBedAction = true }
function K.handsFree() return K.handsUntil ~= nil and hours() < K.handsUntil end
function K.allowed(action)
    if not K.held or K.phase == "breakout" or K.handsFree() then return true end
    local t = type(action) == "table" and tostring(action.Type or "") or ""
    if K.ALLOWED[t] then return true end
    if string.find(t, "Walk", 1, true) or string.find(t, "Door", 1, true) or string.find(t, "Path", 1, true) then return true end
    return false
end
function K.wrapQueue()
    if K._queue or type(ISTimedActionQueue) ~= "table" or type(ISTimedActionQueue.add) ~= "function" then return false end
    K._queue = true
    local orig = ISTimedActionQueue.add
    ISTimedActionQueue.add = function(action, ...)
        local ok, yes = pcall(K.allowed, action)
        if ok and not yes then
            K.metrics.refused = K.metrics.refused + 1
            pcall(function() HaloTextHelper.addBadText(action.character, "Your hands are tied.") end)
            return
        end
        return orig(action, ...)
    end
    return true
end
-- the walkie: 5 s to get the button down with your hands tied
function K.wrapWalkie()
    if K._walkie or type(ALifeTalkWalkie) ~= "table" or not fn(ALifeTalkWalkie, "call") then return false end
    K._walkie = true
    local orig = ALifeTalkWalkie.call
    ALifeTalkWalkie.call = function(player, uid, kind, ...)
        if not K.held or K.handsFree() or K.phase == "breakout" then return orig(player, uid, kind, ...) end
        K.metrics.walkieDelayed = K.metrics.walkieDelayed + 1
        pcall(function() HaloTextHelper.addText(player, "You fumble for the button...") end)
        K.later = { at = (getTimestampMs and getTimestampMs() or 0) + 5000, f = function() orig(player, uid, kind) end }
        return true
    end
    return true
end
function K.tick()
    if K.later ~= nil and (getTimestampMs and getTimestampMs() or 0) >= K.later.at then
        local f = K.later.f
        K.later = nil
        pcall(f)
    end
    if K.held and K.handsUntil ~= nil and hours() >= K.handsUntil then K.handsUntil = nil; K.hands(playerOf(), true) end
end

-- ---------------------------------------------------------------------------------------------------- talking to them
K.FREE_WORDS = { "let me go", "release me", "set me free", "let me out", "untie me and let me", "i won't tell anyone", "please let me" }
K.HAND_WORDS = { "untie my hands", "untie me", "cut me loose", "help me with", "loosen these", "my hands" }
function K.onWords(player, text, loud, hearers)
    if not K.held or type(hearers) ~= "table" or hearers[1] == nil or type(hearers[1].record) ~= "table" then return end
    local low = string.lower(tostring(text or ""))
    local ask = nil
    for _, w in ipairs(K.FREE_WORDS) do if string.find(low, w, 1, true) then ask = "free" end end
    if ask == nil then for _, w in ipairs(K.HAND_WORDS) do if string.find(low, w, 1, true) then ask = "hands" end end end
    if ask == nil then return end
    K.metrics.talks = K.metrics.talks + 1
    ALifeCmd.send(player, "captureTalk", { uid = tostring(hearers[1].record.uid), ask = ask })
end
if type(M.playerWordHooks) == "table" and not K._words then K._words = true; table.insert(M.playerWordHooks, function(...) pcall(K.onWords, ...) end) end

-- ---------------------------------------------------------------------------------------------------- the camp rule
function K.ruleMenu(context, player)
    local opt = context:addOption(ALifeTr("IGUI_ALCP_Menu_If_one_of_us_is_taken", "If one of us is taken..."), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(opt, sub)
    for _, r in ipairs({ "a", "b", "c" }) do
        local o = sub:addOption(C.RULES[r] .. (K.rule == r and "  (our rule)" or ""), nil, function() ALifeCmd.send(player, "captureRule", { rule = r }) end)
        if K.rule == r then o.notAvailable = true end
    end
end
function K.onRule(p) if type(p) == "table" then K.rule = p.rule; if p.text then K.line("Camp rule: " .. tostring(p.text)) end end end
function K.radial()
    if K._radial or type(ALifeRadial) ~= "table" or not fn(ALifeRadial, "addFiller") then return false end
    K._radial = true
    ALifeRadial.addFiller("capturerule", "camp", function(playerNum, context, worldobjects, test)
        if test == true or not C.on() or C.setting("captureRescue") == false or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        local player = getSpecificPlayer(playerNum or 0)
        if player ~= nil then pcall(K.ruleMenu, context, player) end
    end)
    return true
end

if fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("captureState", function(p) return K.onState(p) end)
    ALifeCmd.onClient("captureNotice", function(p) return K.onNotice(p) end)
    ALifeCmd.onClient("prisonerCode", function(p) return K.onPrisonerCode(p) end)
    ALifeCmd.onClient("captureTalked", function(p) return K.onTalked(p) end)
    ALifeCmd.onClient("captureRuleSet", function(p) return K.onRule(p) end)
end
function K.install()
    K.settings()
    K.addRows()
    local q = K.wrapQueue()
    local w = K.wrapWalkie()
    local r = K.radial()
    local player = playerOf()
    if player ~= nil then ALifeCmd.send(player, "captureGetRule", {}) end
    -- a save loaded while held: hands stay tied
    local s = player and C.stateOf(player) or nil
    if type(s) == "table" and s.phase ~= "free" then K.held, K.phase = true, s.phase; K.hands(player, s.phase ~= "breakout") end
    log("ready v" .. K.VERSION .. ": hands " .. (q and "on" or "OFF") .. ", walkie delay " .. (w and "on" or "OFF") .. ", camp rule menu " .. (r and "on" or "OFF"))
end
if type(Events) == "table" then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
    if Events.OnTick ~= nil then Events.OnTick.Add(function() if K.held or K.later then pcall(K.tick) end end) end
end
