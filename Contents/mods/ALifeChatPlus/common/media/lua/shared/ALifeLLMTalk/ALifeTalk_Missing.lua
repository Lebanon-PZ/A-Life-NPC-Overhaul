-- A-Life NPC Overhaul 0.6.15: MISSING PEOPLE. When one of yours dies where nobody saw it, nobody knows yet.
--
-- No X on the map. One of your people (a settler) dies out of sight: on a run, on the road, at an outpost, anywhere you
-- weren't. For a while, nothing. Then, about half a day later, someone at camp comes to you: "Nobody's seen Jorge since
-- yesterday. He was heading northeast, toward Muldraugh." (Your only basemate? Then it's your own memory of where they
-- went.) Never exact: a direction and the town nearest to where they were. You decide:
--   * I'll go look: you jot the rough area on your map (needs a pen or pencil). Get within 15 tiles of them and you
--     find them.
--   * Send someone to look (if someone else is at camp): they're gone for the real road time there and back, plus a
--     few hours searching. If they find them, they tell you exactly where (and you can mark it).
--   * They're gone: you don't search.
-- Close friends don't grieve "word reached you" until they're found or given up on: the camp doesn't know either.
-- Every card says how it works in one line, so nobody has to guess.
-- Performance: one check every ten minutes over open cases (a handful at most); nothing when there are none.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Missing") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Missing"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Missing") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("missing: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function tr(k, e, ...) return ALifeTr and ALifeTr("IGUI_ALCP_" .. k, e, ...) or e end

if M.settings.missingPeople == nil then M.settings.missingPeople = true end
M.msCfg = { noticeH = 12, findTiles = 15, searchH = 4, findChance = 0.75, guardBonus = 0.1, fuzz = 150 }
M.msStats = { cases = 0, noticed = 0, found = 0, foundBySearch = 0, missed = 0, gone = 0 }

local function store()
    local b = M.bucket("missing")
    return b
end
M.msStore = store
-- pre-1.0 MP (P5): the missing are the shared camp's: cards go to the camp's player (Main's M.homePlayer), the
-- answers (toasts, map marks) to whoever picked; "you found them" = any online player close. SP: unchanged.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function playerOf()
    if mpServer() and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function pxy(p) local x, y = nil, nil; pcall(function() x, y = p:getX(), p:getY() end); return x, y end
local function nameOf(uid)
    local e = M.bucket("book")[tostring(uid)]
    local n = type(e) == "table" and (e.real or e.name) or nil
    if n == nil then local d = M.deathOf and M.deathOf(uid); n = d and d.n end
    n = tostring(n or "Someone")
    return (string.match(n, "^(%S+)") or n), n
end
local DIRS = { "east", "southeast", "south", "southwest", "west", "northwest", "north", "northeast" }
local function dirWord(ax, ay, bx, by)
    local ang = math.atan2(by - ay, bx - ax)
    return DIRS[(math.floor(((ang / (2 * math.pi)) * 8 + 0.5)) % 8) + 1]
end
-- your base (where they'd have set out from)
local function baseXY(player)
    local x, y = nil, nil
    if fn(M, "alifeBase") then
        pcall(function()
            local b = M.alifeBase(player, false)
            local bb = type(b) == "table" and (type(b.bounds) == "table" and b.bounds or b) or nil
            if bb and tonumber(bb.x1) then x, y = (bb.x1 + bb.x2) / 2, (bb.y1 + bb.y2) / 2
            elseif type(b) == "table" and tonumber(b.x) then x, y = b.x, b.y end
        end)
    end
    if x == nil then x, y = pxy(player) end
    return x, y
end
-- is this one of yours? (a settler: someone who lives at your base)
function M.msIsOurs(uid)
    return fn(M, "settlerOf") and M.settlerOf(uid) ~= nil
end

-- an off-screen death of one of yours opens a case (nobody knows yet)
function M.msOpen(uid, info)
    if M.settings.missingPeople == false then return nil end
    uid = tostring(uid)
    local st = store()
    if st[uid] then return st[uid] end
    local h = tonumber(info and info.h) or hours()
    local x, y = tonumber(info and info.x), tonumber(info and info.y)
    if x == nil and fn(M, "ghostRecord") then
        pcall(function() local g = M.ghostRecord(uid); local wp = g and g.worldPosition; if type(wp) == "table" then x, y = tonumber(wp.x), tonumber(wp.y) end end)
    end
    local player = playerOf()
    local bx, by = baseXY(player)
    local first, full = nameOf(uid)
    local c = { uid = uid, n = first, full = full, h = h, x = x, y = y, hx = bx, hy = by, state = "unnoticed", noticeAt = h + M.msCfg.noticeH }
    if x and bx then
        c.dir = dirWord(bx, by, x, y)
        c.town = M.townAt and M.townAt(x, y) or nil
    end
    st[uid] = c
    M.msStats.cases = M.msStats.cases + 1
    log(full .. " died out of sight; nobody knows yet (" .. tostring(c.dir) .. ", toward " .. tostring(c.town) .. ")")
    return c
end
-- found or given up on: the news can reach the people close to them (see the newsReach hook below)
local function release(c, how)
    c.state, c.closedH = how, hours()
end
-- still missing (nobody knows yet)?
function M.msUnknown(uid)
    local c = store()[tostring(uid)]
    return type(c) == "table" and c.state ~= "found" and c.state ~= "gone"
end

local function whereWords(c)
    if c.dir and c.town then return tr("MissingWhereTown", "heading %1, toward %2", c.dir, c.town) end
    if c.dir then return tr("MissingWhereDir", "heading %1", c.dir) end
    return tr("MissingWhereNone", "nobody saw which way")
end
local function rough(c)
    if c.x == nil then return nil end
    local r = M.msCfg.fuzz
    local jx = ((ALifeRoll01 and ALifeRoll01(c.uid .. "#mx") or 0.5) - 0.5) * 2 * r
    local jy = ((ALifeRoll01 and ALifeRoll01(c.uid .. "#my") or 0.5) - 0.5) * 2 * r
    return math.floor(c.x + jx), math.floor(c.y + jy)
end
local function markMap(text, x, y)
    if x == nil or not fn(M, "jnMark") then return false end
    M.jnQueue = M.jnQueue or {}
    local player = playerOf()
    local pen = false
    pcall(function()
        local inv = player:getInventory()
        for _, t in ipairs({ "Base.Pencil", "Base.Pen", "Base.BluePen", "Base.RedPen", "Base.GreenPen", "Base.MarkerBlack", "Base.Crayons" }) do
            if inv:containsTypeRecurse(t) then pen = true; return end
        end
    end)
    if not pen then return false end
    ALifeSide.outMark(player, text, x, y)
    return true
end

-- someone who can go look (at camp, not the missing one); guards / hunters first
local function searcher(except)
    if not fn(M, "settlersHome") then return nil end
    local _, list = M.settlersHome(except)
    local guards = M.cpRoleBg and M.cpRoleBg.guard or {}
    local best, bs = nil, -1
    for _, uid in ipairs(list or {}) do
        local s = M.settlerOf(uid)
        if s and not s.searching then
            local bg = nil
            pcall(function() local p = M.partsOf(tostring(uid)); bg = p and p.bg and (p.bg.key or p.bg.k) end)
            local sc = (guards[bg] or 0) + ((s.role == "guard") and 0.5 or 0)
            if sc > bs then best, bs = uid, sc end
        end
    end
    return best, bs
end

-- the card: someone comes to you
function M.msNotice(c)
    if c.state ~= "unnoticed" then return end
    c.state = "noticed"
    M.msStats.noticed = M.msStats.noticed + 1
    local teller = searcher(c.uid)
    local tellerName = teller and (nameOf(teller)) or nil
    local alone = teller == nil
    local where = whereWords(c)
    local text
    if alone then
        text = tr("MissingAlone", "%1 hasn't come back. The last you saw, %1 was %2.", c.n, where)
    else
        text = tr("MissingTold", "%1: \"Nobody's seen %2 since yesterday. Last we saw, %2 was %3.\"", tellerName, c.n, where)
    end
    text = text .. " <LINE> <LINE> " .. tr("MissingHow", "(If something happened, the body is out there%1. Look yourself, or send someone: whoever finds them can tell you exactly where.)",
        c.town and tr("MissingHowTown", " somewhere near %1", c.town) or "")
    local choices = {
        { tr("MissingLook", "I'll go look"), function() M.msLook(c) end },
    }
    if not alone then choices[#choices + 1] = { tr("MissingSend", "Send %1 to look", tellerName), function() M.msSend(c, teller) end } end
    choices[#choices + 1] = { tr("MissingGone", "They're gone"), function() M.msGiveUp(c) end }
    if ALifeSide.canOutCard() then
        ALifeSide.outCard(playerOf(), { id = "missing:" .. c.uid, title = tr("MissingTitle", "%1 is missing", c.n), text = text, choices = choices, default = 1 })
    end
    log(c.full .. " noticed missing (" .. (alone and "you" or tostring(tellerName)) .. " told you)")
end
function M.msLook(c)
    c.state = "looking"
    local x, y = rough(c)
    if x and markMap(tr("MissingMapRough", "%1? (last seen)", c.n), x, y) then
        ALifeSide.outToast(nil, tr("MissingMarked", "You mark roughly where %1 was headed.", c.n))
    else
        ALifeSide.outToast(nil, tr("MissingRemember", "%1 was %2. (No pen or pencil to mark your map.)", c.n, whereWords(c)))
    end
end
function M.msSend(c, who)
    local s = M.settlerOf(who)
    if s == nil then return M.msLook(c) end
    local h = hours()
    local th = 6
    if c.x and c.hx and fn(M, "travelH") then local ok, t = pcall(M.travelH, c.hx, c.hy, c.x, c.y, nil); if ok and tonumber(t) then th = t end end
    local _, sc = searcher(c.uid)
    c.state, c.by = "searching", tostring(who)
    c.back = h + th * 2 + M.msCfg.searchH
    s.searching = c.back
    -- 0.6.17: they really go: walk out of the camp, out there on the road, back by the time they said
    if c.x and fn(M, "lvSend") then
        local home = nil
        pcall(function() local r = PA().ActorRegistry.read(tostring(who)); local wp = r and r.worldPosition
            if type(wp) == "table" then home = { x = wp.x, y = wp.y, z = wp.z or 0 } end end)
        if home then pcall(M.lvSend, tostring(who), { tx = c.x, ty = c.y, untilH = c.back, round = true, final = home, tag = "search" }) end
    end
    ALifeSide.outToast(nil, tr("MissingSent", "%1 heads out to look for %2. Back in about %3 hours.", nameOf(who), c.n, math.floor(c.back - h + 0.5)))
end
function M.msGiveUp(c)
    release(c, "gone")
    M.msStats.gone = M.msStats.gone + 1
end
-- you found them (you got close to where they died)
local function foundByYou(c)
    release(c, "found")
    M.msStats.found = M.msStats.found + 1
    ALifeSide.outToast(nil, tr("MissingFound", "You found %1.", c.n))
    if fn(M, "logInteraction") then pcall(M.logInteraction, c.uid, "You found them, where they fell", nil, nil, "event") end
end
-- the searcher is back
local function searchBack(c, h)
    local s = M.settlerOf(c.by)
    if s then s.searching = nil end
    local who = nameOf(c.by)
    local bonus = 0
    pcall(function() local guards = M.cpRoleBg and M.cpRoleBg.guard or {}; local p = M.partsOf(tostring(c.by)); local bg = p and p.bg and (p.bg.key or p.bg.k); bonus = (guards[bg] or 0) * M.msCfg.guardBonus end)
    local found = c.x ~= nil and (ALifeRoll01 and ALifeRoll01(c.uid .. "#search" .. math.floor(h)) or 0) < M.msCfg.findChance + bonus
    if found then
        release(c, "found")
        M.msStats.foundBySearch = M.msStats.foundBySearch + 1
        local place = c.town and tr("MissingNear", "near %1", c.town) or ""
        local choices = { { tr("MissingOk", "OK"), function() end } }
        table.insert(choices, 1, { tr("MissingMarkExact", "Mark it on my map"), function()
            if not markMap(tr("MissingMapExact", "%1 (body)", c.n), math.floor(c.x), math.floor(c.y)) then
                ALifeSide.outToast(nil, tr("JournalNeedPen", "You need a pen or pencil to mark your map."))
            end
        end })
        if ALifeSide.canOutCard() then
            ALifeSide.outCard(playerOf(), { id = "found:" .. c.uid, title = tr("MissingFoundTitle", "%1 found", c.n),
                text = tr("MissingFoundBy", "%1 is back. \"I found %2. %3 I can show you exactly where.\"", who, c.n, place), choices = choices, default = 1 })
        end
    else
        c.state = "looking"
        M.msStats.missed = M.msStats.missed + 1
        ALifeSide.outToast(playerOf(), tr("MissingNotFound", "%1 is back. No sign of %2. Still out there somewhere %3.", who, c.n, whereWords(c)))
    end
end
function M.msTick()
    local st = store()
    local any = false
    for _ in pairs(st) do any = true; break end -- PZ's Kahlua has no next()
    if not any then return end
    local h = hours()
    local px, py = pxy(playerOf())
    for uid, c in pairs(st) do
        if type(c) ~= "table" then st[uid] = nil
        elseif c.state == "unnoticed" and h >= (tonumber(c.noticeAt) or 0) then M.msNotice(c)
        elseif (c.state == "looking" or c.state == "noticed" or c.state == "searching") and c.x
            and ((not mpServer() and px and d2(px, py, c.x, c.y) <= M.msCfg.findTiles ^ 2) or (mpServer() and ALifeSide.nearest(c.x, c.y, M.msCfg.findTiles) ~= nil)) then
            if c.state == "searching" then local s = M.settlerOf(c.by); if s then s.searching = nil end end
            foundByYou(c)
        elseif c.state == "searching" and h >= (tonumber(c.back) or 0) then searchBack(c, h)
        elseif (c.state == "found" or c.state == "gone") and h - (tonumber(c.closedH) or h) > 24 * 30 then st[uid] = nil end
    end
end
-- busy searching: no camp job pulls them away (they're out there)
function M.msSearching(uid)
    local s = fn(M, "settlerOf") and M.settlerOf(uid) or nil
    return s ~= nil and s.searching ~= nil and hours() < (tonumber(s.searching) or 0)
end
function M.msPerf()
    local s = M.msStats
    return "missing: cases " .. s.cases .. ", noticed " .. s.noticed .. ", found by you " .. s.found .. ", found by a search " .. s.foundBySearch
        .. ", searches with nothing " .. s.missed .. ", given up " .. s.gone
end

M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeMissing] " .. where .. " failed, missing people off for this session: " .. tostring(a)) end
    return ok and a or nil
end
function M.msInstall()
    if M._alcpHooks.missing or not fn(M, "confirmDeath") then return false end
    M._alcpHooks.missing = true
    local confirm = M.confirmDeath
    M.confirmDeath = function(uid, src, info, ...)
        local r = confirm(uid, src, info, ...)
        if r == true and src ~= "event" and src ~= "twin" and not broken and M.msIsOurs(uid) then guard("open", M.msOpen, uid, info) end
        return r
    end
    -- close friends don't hear "word reached you" while they're still missing: the camp doesn't know either
    if fn(M, "newsReach") and fn(M, "isPersonDead") then
        local news, dead = M.newsReach, M.isPersonDead
        M.newsReach = function(...)
            M.isPersonDead = function(uid, ...) if M.msUnknown(uid) then return false end; return dead(uid, ...) end
            local ok, r = pcall(news, ...)
            M.isPersonDead = dead
            if not ok then error(r) end
            return r
        end
    end
    -- someone out searching isn't given chores
    if fn(M, "withPlayer") then
        local wp = M.withPlayer
        M.withPlayer = function(uid, player, ...)
            if M.msSearching(uid) then return true end
            return wp(uid, player, ...)
        end
    end
    if type(Events) == "table" and Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_Missing", function() guard("tick", M.msTick) end) end
    print("[ALifeMissing] loaded v0.6.15 (your people who die out of sight go missing first)")
    return true
end
if not M.msInstall() and type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.msInstall() end) end
