-- A-Life NPC Overhaul 0.6.9: YOUR FACTION JOURNAL, MARKED ON YOUR MAP BY HAND.
--
-- The Places window used to show every group's real numbers, live, from anywhere: all-seeing. Now it's your journal:
-- what you've learned about each group, who told you, and how long ago. It can be out of date or wrong.
--   * your own visit: what you saw (kept up to date while you're there)
--   * their traders (0.6.6): how many they are, how they're doing, what they had to sell
--   * their fighters (0.6.7): the same, from the ones who came to help
--   * the radio: who they are and roughly where
--   * rumors: traders talk about their neighbors (friends and enemies): one thing per visit, true when said
-- A group that fell or moved away still shows as you last knew it, until someone tells you otherwise.
-- MARK ON MAP writes the place onto your own world map, in your hand: a note you can move or erase like your own. It
-- needs a pen or pencil. Where you've been, it's exact; a place you only know from the radio or a rumor goes down as a
-- rough guess with a "?".
-- Performance: knowledge is written when you learn something (events), never polled; the journal reads it when open.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Journal") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Journal"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Journal") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end

if M.settings.journal == nil then M.settings.journal = true end
M.jnCfg = { logKeep = 10, roughTiles = 100, visitRefreshH = 1 }
M.jnStats = { learned = 0, rumors = 0, marks = 0 }
M.jnSrcWords = { visit = "you saw it yourself", traders = "their traders told you", fighters = "their fighters told you",
    radio = "they told you on the radio", rumor = "a rumor" }

local function statusWords(b)
    if b.status == "active" then
        if b.road then return "on the move" end
        return (M.nbStageWords and M.nbStageWords[b.stage]) or tostring(b.stage or "settled")
    end
    if b.status == "fallen" then return "fallen - everyone there died" end
    if b.endReason == "moved" then return "moved away" end
    return b.status == "overrun" and "overrun" or (b.status == "merged" and "moved in with you" or "abandoned")
end
-- what can be seen of a group right now (a snapshot; the journal keeps it until something newer comes in)
function M.jnSnapshot(b)
    local goods = nil
    if fn(M, "nbGoodsWords") then pcall(function() goods = M.nbGoodsWords(b) end) end
    return { members = tonumber(b.crewN) or 0, morale = M.nbMoraleWord and M.nbMoraleWord(b.morale) or nil, food = M.nbFoodWord and M.nbFoodWord(b) or nil,
        leader = b.leaderName, status = statusWords(b), active = b.status == "active", trade = b.trade, goods = goods,
        living = b.trade and M.dirTradeWords and M.dirTradeWords[b.trade] or nil,
        wealth = type(ALifeWorth) == "table" and b.status == "active" and ALifeWorth.wealthWord(b) or nil }
end
-- you learned something about b. fields: a snapshot (or part of one); text: a line for the notes
function M.jnLearn(b, src, fields, text, by)
    if type(b) ~= "table" or M.settings.journal == false then return end
    local h = hours()
    b.intel = type(b.intel) == "table" and b.intel or {}
    for k, v in pairs(fields or {}) do b.intel[k] = v end
    b.intel.at, b.intel.src, b.intel.by = h, src, by
    if src == "visit" or src == "fighters" or src == "traders" then b.intel.x, b.intel.y, b.intel.exact = b.x, b.y, (src == "visit") or b.intel.exact end
    if b.known == nil then b.known = (src == "radio" and "radio") or (src == "rumor" and "heard") or "told" end
    if text then
        b.intelLog = type(b.intelLog) == "table" and b.intelLog or {}
        b.intelLog[#b.intelLog + 1] = { h = h, t = tostring(text), src = src, by = by }
        while #b.intelLog > M.jnCfg.logKeep do table.remove(b.intelLog, 1) end
    end
    M.jnStats.learned = M.jnStats.learned + 1
end
local function ago(h0)
    local d = hours() - (tonumber(h0) or hours())
    if d < 1 then return "just now" elseif d < 24 then return math.floor(d) .. " hours ago" elseif d < 48 then return "yesterday" end
    return math.floor(d / 24) .. " days ago"
end
M.jnAgo = ago
function M.jnLearnedWords(b)
    local i = type(b) == "table" and b.intel or nil
    if type(i) ~= "table" or i.at == nil then return "you know almost nothing about them" end
    local who = i.src == "rumor" and ("a rumor from " .. tostring(i.by or "someone")) or (M.jnSrcWords[i.src] or tostring(i.src))
    return ago(i.at) .. ", " .. who
end

-- rumors: a group's traders mention one neighbor they care about (a friend or an enemy)
function M.jnRumor(from, h)
    if type(from) ~= "table" or type(from.dir) ~= "table" or type(from.dir.ties) ~= "table" then return nil end
    local st = M.nbStore()
    local best, bt = nil, 0
    for id, tie in pairs(from.dir.ties) do
        local o = st.byId[id]
        local w = math.abs(tonumber(tie) or 0)
        if type(o) == "table" and w >= 15 and w + (ALifeRoll01 and ALifeRoll01(from.id .. id .. math.floor(h / 24)) * 30 or 0) > bt then best, bt = o, w end
    end
    if best == nil then return nil end
    local snap = M.jnSnapshot(best)
    local feel = (tonumber(from.dir.ties[best.id]) or 0) > 0 and "friends of theirs" or "no friends of theirs"
    local what = snap.active and ((snap.members or "?") .. " of them, " .. tostring(snap.food) .. ", " .. tostring(snap.status)) or tostring(snap.status)
    M.jnLearn(best, "rumor", snap, tostring(from.name) .. " says " .. tostring(best.name) .. " (" .. feel .. "): " .. what, from.name)
    M.jnStats.rumors = M.jnStats.rumors + 1
    return best
end

----------------------------------------------------------------------------------------------------------------
-- the journal rows (the Places window): what you know, not what's true
----------------------------------------------------------------------------------------------------------------
function M.jnRows(rows)
    for _, d in ipairs(rows or {}) do
        local b = M.nbOf and M.nbOf(d.id) or (M.nbStore().byId[d.id])
        local i = type(b) == "table" and b.intel or nil
        if type(i) == "table" and i.at then
            d.members = i.members ~= nil and i.members or "?"
            d.morale, d.food = i.morale or "?", (i.food or "?") .. (i.wealth and (", " .. i.wealth) or "")
            d.leader = i.leader or "?"
            d.status = tostring(i.status or (i.src == "radio" and "you've only talked on the radio" or "?"))
            d.active = i.active ~= false
            d.fallen = (i.status or ""):find("^fallen") ~= nil or nil
        else
            d.members, d.morale, d.food, d.leader = "?", "?", "?", "?"
            d.status = "you don't know much about them"
            d.active, d.fallen = true, nil
        end
        d.learned = M.jnLearnedWords(b)
        d.notes = type(b) == "table" and b.intelLog or nil
    end
    table.sort(rows, function(a, b) if a.active ~= b.active then return a.active end return tostring(a.name) < tostring(b.name) end)
    return rows
end

----------------------------------------------------------------------------------------------------------------
-- marking your map by hand
----------------------------------------------------------------------------------------------------------------
local function hasPen(player)
    local found = false
    pcall(function()
        local inv = player:getInventory()
        for _, t in ipairs({ "Base.Pencil", "Base.Pen", "Base.BluePen", "Base.RedPen", "Base.GreenPen", "Base.MarkerBlack", "Base.MarkerBlue", "Base.MarkerRed", "Base.MarkerGreen", "Base.Crayons" }) do
            if inv:containsTypeRecurse(t) then found = true; return end
        end
    end)
    return found
end
M.jnQueue = M.jnQueue or {}
-- returns ok, message
function M.jnMark(id, player)
    local b = M.nbOf and M.nbOf(id) or (M.nbStore().byId[id])
    if type(b) ~= "table" then return false, "Select a place first." end
    if not hasPen(player) then return false, ALifeTr("IGUI_ALCP_JournalNeedPen", "You need a pen or pencil to mark your map.") end
    local i = type(b.intel) == "table" and b.intel or {}
    local exact = i.exact or b.known == "visited"
    local x, y = tonumber(i.x) or b.x, tonumber(i.y) or b.y
    local name = string.gsub(tostring(b.name or "?"), "^the ", "The ")
    if not exact then
        local r = M.jnCfg.roughTiles
        x, y = math.floor(x / r + 0.5) * r, math.floor(y / r + 0.5) * r
        name = name .. "?"
    end
    if ALifeSide.mpServer() then -- MP: the mark goes to that player's map (drawn when they open it), the word with it
        local msg = exact and ("You mark " .. name .. " on your map.") or ("You mark roughly where " .. name .. " should be.")
        ALifeSide.outMark(player, name, x, y)
        ALifeSide.outToast(player, msg)
        return true, msg
    end
    M.jnQueue[#M.jnQueue + 1] = { text = name, x = x, y = y }
    if type(ISWorldMap) == "table" and fn(ISWorldMap, "ShowWorldMap") then
        local okS = pcall(ISWorldMap.ShowWorldMap, player and player:getPlayerNum() or 0, x, y, 14)
        if okS then M.jnFlush() end
        return true, exact and ("You mark " .. name .. " on your map.") or ("You mark roughly where " .. name .. " should be.")
    end
    -- no world map UI: A-Life's own marker
    table.remove(M.jnQueue)
    local ok = M.nbMark and M.nbMark(id, player) or false
    return ok, ok and (name .. " marked on your map.") or "Couldn't mark it."
end
function M.jnFlush()
    if #M.jnQueue == 0 then return 0 end
    local map = ISWorldMap_instance
    if map == nil or map.mapAPI == nil then return 0 end
    local n = 0
    pcall(function()
        local api = map.mapAPI
        local sym = api.getSymbolsAPIv2 and api:getSymbolsAPIv2() or api:getSymbolsAPI()
        local layer = sym.getDefaultTextLayerID and sym:getDefaultTextLayerID() or nil
        for _, q in ipairs(M.jnQueue) do
            local s = layer and sym:addUntranslatedText(q.text, layer, q.x, q.y) or sym:addUntranslatedText(q.text, nil, q.x, q.y)
            if s then
                s:setRGBA(0.1, 0.1, 0.12, 1.0)
                s:setAnchor(0.5, 0.5)
                pcall(function() s:setScale(ISMap.SCALE) end)
                n = n + 1
            end
        end
    end)
    M.jnQueue = {}
    M.jnStats.marks = M.jnStats.marks + n
    return n
end
function M.jnPerf()
    local s = M.jnStats
    return "journal: learned " .. s.learned .. ", rumors " .. s.rumors .. ", marked by hand " .. s.marks
end

----------------------------------------------------------------------------------------------------------------
-- hooks (wrap, never replace; marked)
----------------------------------------------------------------------------------------------------------------
M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeJournal] " .. where .. " failed, journal hooks off for this session: " .. tostring(a)) end
    return ok and a or nil
end
-- saves from before 0.6.9: places you'd been get what you last saw (as of your last visit)
local function migrate()
    local st = M.nbStore()
    if st.jnV then return end
    st.jnV = 1
    for _, b in pairs(st.byId or {}) do
        if type(b) == "table" and b.intel == nil and b.known == "visited" then
            M.jnLearn(b, "visit", M.jnSnapshot(b), nil)
            b.intel.at = tonumber(b.lastVisitH) or b.intel.at
        end
    end
end
function M.jnInstall()
    if M._alcpHooks.journal or type(M.nbPresence) ~= "function" or type(M.nbRows) ~= "function" then return false end
    M._alcpHooks.journal = true
    local presence = M.nbPresence
    M.nbPresence = function(...)
        local r = presence(...)
        guard("visit", function()
            if M.nbAt == nil then return end
            local b = M.nbOf(M.nbAt)
            if b and (b.intel == nil or b.intel.src ~= "visit" or hours() - (tonumber(b.intel.at) or 0) >= M.jnCfg.visitRefreshH) then
                local first = b.intel == nil or b.intel.src ~= "visit"
                M.jnLearn(b, "visit", M.jnSnapshot(b), first and ("You came by. " .. (b.crewN or "?") .. " people, " .. tostring(M.nbFoodWord(b))) or nil)
            end
        end)
        return r
    end
    local rows = M.nbRows
    M.nbRows = function(player, ...)
        local out = rows(player, ...)
        if M.settings.journal == false or M.nbShowAll then return out end
        guard("migrate", migrate)
        return guard("rows", M.jnRows, out) or out
    end
    if fn(M, "nbMark") then M.jnMarkOld = M.nbMark end
    M.cvArriveHooks = M.cvArriveHooks or {}
    table.insert(M.cvArriveHooks, function(visit, b, h)
        guard("traders", function()
            local snap = M.jnSnapshot(b)
            M.jnLearn(b, "traders", snap, "Their traders came: " .. snap.members .. " of them at home, " .. tostring(snap.food) .. ", " .. tostring(snap.morale))
            M.jnRumor(b, h)
        end)
    end)
    if type(ISWorldMap) == "table" and fn(ISWorldMap, "ShowWorldMap") and not ISWorldMap._alcpJournal then
        ISWorldMap._alcpJournal = true
        local show = ISWorldMap.ShowWorldMap
        ISWorldMap.ShowWorldMap = function(...)
            local r = show(...)
            pcall(M.jnFlush)
            return r
        end
    end
    print("[ALifeJournal] loaded v" .. ALifeSide.MOD_VERSION .. " (the Places window is your journal: what you know, who told you, when; marked on your map by hand)")
    return true
end
-- pre-1.0 MP (P5): "mark on my map" from the Places window runs on the server as you (it has the bases)
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then ALifeRemote.expose("jnMark", 1, 2) end
if not M.jnInstall() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.jnInstall() end) end
