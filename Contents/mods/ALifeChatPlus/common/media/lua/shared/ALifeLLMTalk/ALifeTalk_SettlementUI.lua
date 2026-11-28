-- A-Life NPC Overhaul 0.8.8: SETTLEMENT, what you see (docs/UI-0.8.8.md). No numbers anywhere: words only.
--   1. THE CAMP'S VIEW AT THE DOOR: right-click a refugee party waiting at a base you run (Jeem's "Take them in" /
--      "Send them away", HandGifts/GiftWindow.lua): a grey line right under Jeem's two options, and the same words as a
--      tooltip on them ("Most of them don't want them here. Vic is dead set against taking them in: ..."). Asked from the
--      server ("campVoteAsk" -> "campVoteCue"), kept per person for a minute. Jeem's file is never touched: our own
--      OnFillWorldObjectContextMenu handler, added at game start so it runs after Jeem's (added when its file loads).
--   2. CAMP STATUS on the camp board: the ration rule, the food in words, who runs things while you're away and who's
--      next ("campStatusAsk" -> "campStatus"; asked when the board is open, at most every 30 s, and right after rations
--      or lieutenants change).
--   3. STAND DOWN: a button per lieutenant on the camp board (and the hub's Camp tab); words in the Commands tab
--      (ALifeTalk_Settlement: K.standDown).
--   4. CAMP LOG: the lieutenant's reports, scouts, skills, the door: the last campLogKeep in the save ("campLog"), shown on
--      the camp board ("What happened") and in the journal ("From your camp"). Scout sightings go on your map, roughly
--      (the server rounds to scoutMarkTiles), and come off after scoutMarkDays.
--   5. GETTING BETTER at a role: a vague cue after the role on the camp board ("Cook, getting the hang of it").
--   6. "Watch your back" in the talk window: ALifeTalk_WindowTalk (row) + ALifeTalk_Story (ALifeGoals.wantsDead).
-- UI only (client). Settings: ALifeTalk_Settlement (K.UI.DEFAULTS, registered at load).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_SettlementUI") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeTalk_Settlement"
require "ALifeLLMTalk/ALifeTalk_CampBoard"
require "ALifeNPCOverhaul/ALifeCmd"
local M = ALifeLLMTalk
local K = ALifeSettlement
if type(M) ~= "table" or type(K) ~= "table" then return end
local TAG = "[ALifeSettlementUI]"
K.UI.VERSION = ALifeSide.MOD_VERSION
K.UI.metrics = K.UI.metrics or { asked = 0, cues = 0, shown = 0, logged = 0, marked = 0, unmarked = 0, status = 0 }
local MX = K.UI.metrics
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return tonumber(n) or 0 end
local function setting(key) return K.setting(key) end
local function first(uid)
    local r = nil
    pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function bucket(name)
    local b = nil
    if fn(M, "bucket") then pcall(function() b = M.bucket(name) end) end
    if type(b) ~= "table" then K.UI.tmp = K.UI.tmp or {}; K.UI.tmp[name] = K.UI.tmp[name] or {}; b = K.UI.tmp[name] end
    return b
end
local function esc(s) return (string.gsub(tostring(s or ""), "<", "(")) end

-- ---------------------------------------------------------------------------------------------- 4. the camp log
function K.logData()
    local b = bucket("campLog")
    b.list = type(b.list) == "table" and b.list or {}
    return b.list
end
function K.logAdd(kind, who, text)
    if type(text) ~= "string" or text == "" then return false end
    local list = K.logData()
    list[#list + 1] = { h = hours(), k = tostring(kind or "report"), who = who ~= nil and tostring(who) or nil, text = string.sub(text, 1, 240) }
    local keep = math.max(1, tonumber(setting("campLogKeep")) or 20)
    while #list > keep do table.remove(list, 1) end
    MX.logged = MX.logged + 1
    return true
end
-- "earlier today", "yesterday", "3 days ago": no clock numbers for a day or less
function K.ago(h)
    local d = (hours() - (tonumber(h) or hours())) / 24
    if d < 0.5 then return "earlier today" end
    if d < 1.5 then return "yesterday" end
    if d < 7 then return math.floor(d + 0.5) .. " days ago" end
    return "a while back"
end
-- rich text, newest first
function K.logText(max)
    local list = K.logData()
    if #list == 0 then return nil end
    local out = {}
    local n = math.min(#list, tonumber(max) or #list)
    for i = #list, #list - n + 1, -1 do
        local e = list[i]
        out[#out + 1] = esc(e.text) .. " <RGB:0.6,0.58,0.52> (" .. K.ago(e.h) .. ") <RGB:0.78,0.76,0.7> <LINE> "
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------------------------- 4. scout marks on your map
function K.marksData()
    local b = bucket("scoutMarks")
    b.list = type(b.list) == "table" and b.list or {}
    return b.list
end
function K.markText(m)
    return "Scout: " .. tostring(m.t or "people") .. (m.h and ", not friendly" or "") .. "?"
end
function K.marksAdd(marks, who)
    if setting("scoutMarks") == false or type(marks) ~= "table" then return 0 end
    local list, n = K.marksData(), 0
    for i = 1, 6 do
        local m = marks[i]
        if type(m) == "table" and tonumber(m.x) and tonumber(m.y) then
            local e = { x = math.floor(tonumber(m.x)), y = math.floor(tonumber(m.y)), t = type(m.t) == "string" and string.sub(m.t, 1, 40) or "people", h = m.h == true, at = hours(), who = who }
            e.text = K.markText(e)
            -- the same sighting at the same spot: just seen again
            local same = nil
            for _, o in ipairs(list) do if o.x == e.x and o.y == e.y and o.text == e.text and not o.gone then same = o end end
            if same then same.at = e.at else list[#list + 1] = e; n = n + 1 end
        end
    end
    while #list > 40 do table.remove(list, 1) end
    pcall(K.mapSync)
    return n
end
-- the world map, when it's open: add new marks, take old ones off (vanilla symbols API v2, read in
-- ISUI/Maps/ISWorldMapSymbols.lua + Editor/WorldMapEditorMode_Annotations.lua: getSymbolCount, getSymbolByIndex,
-- removeSymbolByIndex, isText, getUntranslatedText, getWorldX/Y, addUntranslatedText, getDefaultTextLayerID)
function K.symbols()
    local map = ISWorldMap_instance
    if map == nil or map.mapAPI == nil then return nil end
    local api = map.mapAPI
    local sym = nil
    pcall(function() sym = api.getSymbolsAPIv2 and api:getSymbolsAPIv2() or api:getSymbolsAPI() end)
    return sym
end
function K.mapSync()
    local list = K.marksData()
    local sym = K.symbols()
    local life = math.max(0.1, tonumber(setting("scoutMarkDays")) or 3) * 24
    local now = hours()
    local keep = {}
    for _, e in ipairs(list) do
        local old = now - (tonumber(e.at) or now) >= life or setting("scoutMarks") == false
        if old then
            if e.placed then
                if sym == nil then keep[#keep + 1] = e -- (still on the map: taken off next time it's open)
                else
                    local ok = pcall(function()
                        for i = sym:getSymbolCount() - 1, 0, -1 do
                            local s = sym:getSymbolByIndex(i)
                            if s ~= nil and s:isText() and s:getUntranslatedText() == e.text and math.abs(s:getWorldX() - e.x) < 1 and math.abs(s:getWorldY() - e.y) < 1 then
                                sym:removeSymbolByIndex(i)
                                MX.unmarked = MX.unmarked + 1
                            end
                        end
                    end)
                    if not ok then keep[#keep + 1] = e end
                end
            end
        else
            if not e.placed and sym ~= nil then
                pcall(function()
                    local layer = sym.getDefaultTextLayerID and sym:getDefaultTextLayerID() or nil
                    local s = layer and sym:addUntranslatedText(e.text, layer, e.x, e.y) or sym:addUntranslatedText(e.text, nil, e.x, e.y)
                    if s then
                        if e.h then s:setRGBA(0.6, 0.12, 0.1, 1.0) else s:setRGBA(0.15, 0.15, 0.2, 1.0) end
                        s:setAnchor(0.5, 0.5)
                        pcall(function() s:setScale(ISMap.SCALE) end)
                        e.placed = true
                        MX.marked = MX.marked + 1
                    end
                end)
            end
            keep[#keep + 1] = e
        end
    end
    local b = bucket("scoutMarks")
    b.list = keep
    return #keep
end
function K.hookMap()
    if type(ISWorldMap) ~= "table" or not fn(ISWorldMap, "ShowWorldMap") or ISWorldMap._alcpScoutMarks then return ISWorldMap ~= nil and ISWorldMap._alcpScoutMarks == true end
    ISWorldMap._alcpScoutMarks = true
    local show = ISWorldMap.ShowWorldMap
    ISWorldMap.ShowWorldMap = function(...)
        local r = show(...)
        local ok, err = pcall(K.mapSync)
        if not ok and not K.UI.mapErr then K.UI.mapErr = true; log("map marks failed (once): " .. tostring(err)) end
        return r
    end
    return true
end

-- ---------------------------------------------------------------------------------------------- 2. camp status
K.UI.status = K.UI.status or nil
function K.askStatus(player, force)
    if player == nil or not fn(ALifeCmd, "send") then return false end
    local s = K.UI.status
    if not force and s ~= nil and nowMs() - (s.askedAt or 0) < 30000 and nowMs() >= (s.askedAt or 0) then return false end
    K.UI.status = s or {}
    K.UI.status.askedAt = nowMs()
    MX.asked = MX.asked + 1
    return ALifeCmd.send(player, "campStatusAsk", {})
end
function K.onStatus(p)
    local at = K.UI.status and K.UI.status.askedAt or nowMs()
    K.UI.status = { askedAt = at, none = p.none == true, base = p.base, level = p.level, food = p.food, rations = p.rations ~= false }
    MX.status = MX.status + 1
    if M.bdUI ~= nil and fn(M.bdUI, "refresh") then pcall(M.bdUI.refresh, M.bdUI) end
end
K.LEVEL_WORDS = { full = "Full rations.", short = "Short rations.", half = "Half rations.", guards = "Guards eat first, everyone else on half." }
-- the lines for the top of the camp board (rich text, no numbers)
function K.statusLines(player)
    pcall(K.askStatus, player, false)
    local out = {}
    local s = K.UI.status
    if type(s) == "table" and not s.none and s.level ~= nil then
        local t = {}
        if s.rations and K.LEVEL_WORDS[s.level] then t[#t + 1] = K.LEVEL_WORDS[s.level] end
        if s.food then t[#t + 1] = esc(s.food) end
        if #t > 0 then out[#out + 1] = table.concat(t, " ") end
    end
    if setting("lieutenants") ~= false then
        local lts = K.lieutenants()
        if lts[1] ~= nil then
            out[#out + 1] = esc(first(lts[1])) .. " runs things while you're away." .. (lts[2] ~= nil and (" " .. esc(first(lts[2])) .. " is next in line.") or "")
        end
    end
    return out
end
-- stand-down buttons: { label, uid }
function K.standButtons()
    local out = {}
    if setting("lieutenants") == false then return out end
    for _, uid in ipairs(K.lieutenants()) do out[#out + 1] = { label = first(uid) .. ": dismiss", uid = uid } end
    return out
end
function K.standSig()
    return table.concat(K.lieutenants(), ",") .. (setting("lieutenants") == false and ":off" or "")
end

-- ---------------------------------------------------------------------------------------------- 5. getting better at a role
-- K.grown (time in the role, 0..roleGrowMax) and cpFit (who they were + who they are + time) as words
function K.roleCue(uid, role)
    if role == nil or role == "general" or setting("growth") == false or not fn(K, "grown") then return nil end
    local max = math.max(0.01, (tonumber(setting("roleGrowMax")) or 40) / 100)
    local g = K.grown(uid, role) / max
    local f = 1
    if fn(M, "cpFit") then pcall(function() f = M.cpFit(uid, role) end) end
    if f >= 1.5 then return "born to it" end
    if g >= 0.66 or f >= 1.25 then return "knows the job well" end
    if g > 0.05 then return "getting the hang of it" end
    return "new to it"
end

-- ---------------------------------------------------------------------------------------------- 1. the camp's view at the door
K.UI.cues = K.UI.cues or {} -- [uid] = { text, at }
function K.onVoteCue(p)
    if type(p.uid) ~= "string" then return end
    K.UI.cues[p.uid] = { text = (p.none ~= true and type(p.text) == "string" and p.text ~= "") and p.text or nil, at = nowMs() }
    MX.cues = MX.cues + 1
end
function K.voteCue(uid, player)
    local c = K.UI.cues[uid]
    local fresh = c ~= nil and nowMs() - c.at < 60000 and nowMs() >= c.at
    if not fresh and player ~= nil and fn(ALifeCmd, "send") then
        -- (single player answers at once; MP fills it for the next right-click)
        K.UI.cues[uid] = { text = c and c.text or nil, at = nowMs(), pending = true }
        MX.asked = MX.asked + 1
        ALifeCmd.send(player, "campVoteAsk", { uid = uid })
        c = K.UI.cues[uid]
    end
    return c
end
local function tooltip(text)
    if type(ISToolTip) ~= "table" then return nil end
    local t = ISToolTip:new()
    t:initialise()
    t:setVisible(false)
    t.description = text
    return t
end
-- Jeem's two options in this menu or A-Life's person submenu (where Jeem's Menu.addPersonOption puts them)
function K.jeemMenus(context)
    local out = { context }
    local j = J()
    if j and j.Menu and fn(j.Menu, "alifeSubmenu") then
        local ok, sub = pcall(j.Menu.alifeSubmenu, context)
        if ok and sub ~= nil and sub ~= context then out[#out + 1] = sub end
    end
    return out
end
function K.fillDoor(playerNum, context, worldObjects)
    if setting("voteCueMenu") == false or setting("campVote") == false then return 0 end
    local j = J()
    local RY = j and j.RefugeeStay or nil
    if j == nil or not fn(RY, "askingHere") or not (j.Menu and fn(j.Menu, "shellsNear")) then return 0 end
    if fn(j, "enabled") and not j.enabled("refugee_join") then return 0 end
    local player = getSpecificPlayer(playerNum)
    local object = type(worldObjects) == "table" and worldObjects[1] or nil
    local square = nil
    pcall(function() square = object:getSquare() end)
    if player == nil or square == nil then return 0 end
    local takeIn = fn(j, "t") and j.t("ContextMenu_ALJ_Refugees_TakeIn") or "Take them in"
    local sendAway = fn(j, "t") and j.t("ContextMenu_ALJ_Refugees_SendAway") or "Send them away"
    local n = 0
    local done = {}
    for _, near in ipairs(j.Menu.shellsNear(square, 2, player) or {}) do
        local uid = near.uid ~= nil and tostring(near.uid) or nil
        local rec = nil
        if uid ~= nil then pcall(function() rec = PA().ActorRegistry.read(uid) end) end
        local okA, asking = false, false
        if rec ~= nil then okA, asking = pcall(RY.askingHere, rec, player) end
        if okA and asking == true and not done.one then
            done.one = true -- (one party at the door: one line)
            local c = K.voteCue(uid, player)
            local text = c and c.text or nil
            local line = text and ("The camp: " .. text) or (c and c.pending and "The camp: (you haven't heard what they think yet)" or "The camp: nobody much cares either way.")
            for _, menu in ipairs(K.jeemMenus(context)) do
                local yes = fn(menu, "getOptionFromName") and menu:getOptionFromName(takeIn) or nil
                local no = fn(menu, "getOptionFromName") and menu:getOptionFromName(sendAway) or nil
                if no ~= nil and fn(menu, "insertOptionAfter") then
                    -- the tooltip on Jeem's two options
                    if text then
                        if yes and yes.toolTip == nil then yes.toolTip = tooltip("The camp: " .. text) end
                        if no.toolTip == nil then no.toolTip = tooltip("The camp: " .. text) end
                    end
                    -- the grey line under them (same rank as Jeem's, so A-Life's sorting leaves it there)
                    local opt = menu:insertOptionAfter(sendAway, line, nil, nil)
                    if opt ~= nil then
                        opt.notAvailable = true
                        if no.alifeRank ~= nil then opt.alifeRank = no.alifeRank end
                        if j.Menu.tie and near.shell then pcall(j.Menu.tie, opt, near.shell) end
                        n = n + 1
                        MX.shown = MX.shown + 1
                    end
                    break
                end
            end
        end
    end
    return n
end
function K.hookDoor()
    if K.UI.doorHooked or type(Events) ~= "table" or Events.OnFillWorldObjectContextMenu == nil then return K.UI.doorHooked == true end
    K.UI.doorHooked = true
    Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldObjects, test)
        if test or K.UI.doorOff then return end
        local ok, err = pcall(K.fillDoor, playerNum, context, worldObjects)
        if not ok then K.UI.doorOff = true; log("door line failed, off for this session: " .. tostring(err)) end
    end)
    return true
end

-- ---------------------------------------------------------------------------------------------- the journal: from your camp
function K.openLog()
    local text = K.logText() or "Nothing from your camp yet. Your lieutenant's reports, your scouts and people at the door show up here."
    pcall(function()
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        local w, h = math.min(560, sw - 40), math.min(420, sh - 40)
        local modal = ISModalRichText:new((sw - w) / 2, (sh - h) / 2, w, h, "<SIZE:medium> From your camp <LINE> <SIZE:small> <RGB:0.78,0.76,0.7> " .. text, false)
        modal:initialise(); modal:addToUIManager()
    end)
end

if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local door = K.hookDoor()
        local map = K.hookMap()
        log("ready v" .. K.UI.VERSION .. ": settlement screens (door line " .. (door and "on" or "off") .. ", map marks " .. (map and "on" or "off")
            .. ", camp log " .. #K.logData() .. " kept)")
    end)
end
