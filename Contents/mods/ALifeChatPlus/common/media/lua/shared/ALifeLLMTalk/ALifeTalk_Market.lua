-- A-Life NPC Overhaul 0.6.8: YOUR NAME IN THE WORLD, THE TRADING POST, MARKET DAYS.
--
-- Caravans (0.6.6) come from groups that know your place. A group knows it when it's close enough to have seen it,
-- you've raised it on the radio, its traders have been to you, you've visited it, or a group it trades with told it.
-- Word spreads along the trade runs and between friends.
-- TRADING POST: right-click a container at your base > "Make this our trading post". What's in it is your visible
-- stockpile: groups that know you send caravans on their own (traders most often), more often the better it's
-- stocked. Every caravan still walks the real road time.
-- MARKET DAY: on the radio (0.6.7), "Announce a market day": every group in range that knows you and has goods to spare
-- sets out to arrive tomorrow morning. They come one after another (one visit at a time at a base) and keep it short
-- while others wait their turn.
-- Your settlers trade with caravans too: a visit while your people are home lifts camp morale for a day, and that group
-- warms to you a little.
-- Performance: one roll a day per group that knows you (only with a post); the post is recounted when its square is
-- loaded, at most every ten minutes.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Market") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Market"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Market") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("market: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "trade") end end
local function line(text) if fn(M, "radioLine") then pcall(M.radioLine, nil, text) else print(text) end end
local function JM() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end

for k, v in pairs({ tradingPost = true, marketDays = true }) do if M.settings[k] == nil then M.settings[k] = v end end
M.tpCfg = { seenTiles = 400, perDay = { traders = 0.30, other = 0.10 }, stockFull = 40, marketHour = 9, marketStay = 2,
    marketEveryH = 72, spreadPerDay = 0.10, maxQueued = 2 }
M.tpStats = { posts = 0, sent = 0, markets = 0, coming = 0, spread = 0, settlerTrades = 0 }

local function store()
    local st = M.nbStore()
    st.tp = type(st.tp) == "table" and st.tp or { plans = {} }
    st.tp.plans = type(st.tp.plans) == "table" and st.tp.plans or {}
    return st.tp
end
M.tpStore = store

-- does this group know your place? (the Jeem base at x, y)
function M.tpKnows(b, x, y, h)
    if type(b) ~= "table" then return false end
    if b.knowsYou then return true end
    if b.radioKnown or b.known == "visited" then b.knowsYou = h or hours(); return true end
    if tonumber(b.x) and x and d2(b.x, b.y, x, y) <= M.tpCfg.seenTiles ^ 2 then b.knowsYou = h or hours(); return true end
    return false
end

-- your Jeem base (the one caravans walk to)
function M.tpJeemBase(player)
    local J = JM()
    if J == nil or not fn(M, "jeemBaseHouse") then return nil end
    local base = nil -- (Jeem only; see below)
    pcall(function()
        local house = M.jeemBaseHouse(player)
        local id = house and house.key and string.match(tostring(house.key), "^jeem:(.+)$")
        if id and J.BaseAreas and fn(J.BaseAreas, "base") then base = J.BaseAreas.base(id) end
    end)
    return base
end
-- 0.6.18: no Jeem base: our own (your trading post, else your A-Life base)
local tpJeemOnly = M.tpJeemBase
function M.tpJeemBase(player)
    local b = tpJeemOnly(player)
    if b == nil and fn(M, "ovBase") then b = M.ovBase(player) end
    return b
end
local function baseXY(base)
    if type(base) == "table" and base.own then return tonumber(base.x), tonumber(base.y) end
    local V = JM() and JM().Traders and JM().Traders.visits
    local box = V and fn(V, "box") and V.box(base.id) or nil
    if type(box) ~= "table" then return nil end
    return (box.x1 + box.x2) / 2, (box.y1 + box.y2) / 2
end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end

----------------------------------------------------------------------------------------------------------------
-- the trading post
----------------------------------------------------------------------------------------------------------------
local function containerOf(o) local c = nil; pcall(function() c = o:getContainer() end); return c end
function M.tpSetPost(obj)
    local tp = store()
    local sq = nil
    pcall(function() sq = obj:getSquare() end)
    if sq == nil then return false end
    tp.post = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), items = 0, countedH = -1 }
    M.tpStats.posts = M.tpStats.posts + 1
    M.tpCount(true)
    return true
end
function M.tpClearPost() store().post = nil end
-- how stocked it is (counted when its square is loaded; otherwise the last count)
function M.tpCount(force)
    local p = store().post
    if p == nil then return 0 end
    local h = hours()
    if not force and h - (tonumber(p.countedH) or -1) < 1 / 6 then return p.items or 0 end
    pcall(function()
        local sq = getCell():getGridSquare(p.x, p.y, p.z)
        if sq == nil then return end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local c = containerOf(objs:get(i))
            if c then p.items = c:getItems():size(); p.countedH = h; return end
        end
        p.items, p.countedH = 0, h -- the container's gone
    end)
    return p.items or 0
end
-- once a day per group that knows you: send a caravan on their own (only with a trading post)
function M.tpDaily(b, h)
    if M.settings.tradingPost == false or type(b) ~= "table" or b.status ~= "active" or b.road or b.airport or b.outpostOf then return end
    local tp = store()
    if tp.post == nil then return end
    local day = math.floor(h / 24)
    if b.tpDay == day then return end
    b.tpDay = day
    local player = playerOf()
    local base = player and M.tpJeemBase(player) or nil
    if base == nil then return end
    local x, y = baseXY(base)
    if x == nil or not M.tpKnows(b, x, y, h) then return end
    if fn(M, "cvTripFor") and M.cvTripFor(base.id, b.id) then return end
    local queued = 0
    for _, t in pairs(select(1, M.cvTrips())) do if t.baseId == base.id then queued = queued + 1 end end
    if queued >= M.tpCfg.maxQueued then return end
    local chance = (b.trade == "traders" and M.tpCfg.perDay.traders or M.tpCfg.perDay.other) * (0.5 + math.min(1.5, (tonumber(tp.post.items) or 0) / M.tpCfg.stockFull))
    if ALifeRoll01(b.id .. "#tp#" .. day) >= chance then return end
    local why = M.cvSetOut(base, h, b.id)
    if why == "on_the_way" then M.tpStats.sent = M.tpStats.sent + 1; log(tostring(b.name) .. " set out on their own for your trading post") end
end
-- word spreads between friends (once a day per group that knows you)
function M.tpSpread(b, h)
    if not b.knowsYou or type(b.dir) ~= "table" or type(b.dir.ties) ~= "table" then return end
    local day = math.floor(h / 24)
    if b.tpSpreadDay == day then return end
    b.tpSpreadDay = day
    local st = M.nbStore()
    for id, tie in pairs(b.dir.ties) do
        local o = st.byId[id]
        if type(o) == "table" and o.status == "active" and not o.knowsYou and (tonumber(tie) or 0) >= 15
                and ALifeRoll01(b.id .. id .. day) < M.tpCfg.spreadPerDay then
            o.knowsYou = h
            M.tpStats.spread = M.tpStats.spread + 1
            event(o, "Heard about your place from " .. tostring(b.name), "heard")
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- market day
----------------------------------------------------------------------------------------------------------------
-- world hours of the clock time `hour` (0-23), `days` days from today (days = 1: tomorrow)
local function clockAt(h, days, hour)
    local hourNow, minNow = 0, 0
    pcall(function() local gt = getGameTime(); hourNow, minNow = gt:getHour(), gt:getMinutes() end)
    return h - hourNow - minNow / 60 + 24 * days + hour
end
M.tpWhenWords = { [9] = "morning", [12] = "noon", [15] = "afternoon" }
local function dayWords(days) return days == 1 and "tomorrow" or (days == 7 and "a week from today" or ("in " .. days .. " days")) end
-- settable: which day (1 = tomorrow ... 7), what time (9 / 12 / 15), and weekly = a standing market every 7 days
function M.tpMarket(player, days, hour, weekly)
    if M.settings.marketDays == false then return 0 end
    local tp = store()
    local h = hours()
    days, hour = math.max(1, math.min(14, math.floor(tonumber(days) or 1))), tonumber(hour) or M.tpCfg.marketHour
    if not weekly and (tonumber(tp.marketH) or -1e9) > h - M.tpCfg.marketEveryH then line("[Radio] You announced a market day not long ago. Give it a few days."); return 0 end
    local range, why = (fn(M, "rcRadio") and M.rcRadio(player))
    if range == nil then line("[Radio] " .. tostring(why or "You need a radio.")); return 0 end
    local base = M.tpJeemBase(player)
    local x, y = nil, nil; if base then x, y = baseXY(base) end
    if x == nil then line("[Radio] You call it out... but you have no base for anyone to come to."); return 0 end
    local at = clockAt(h, days, hour)
    line("[Radio] You announce a market day at your place, " .. dayWords(days) .. " " .. (hour == 12 and "at noon" or ("in the " .. (M.tpWhenWords[hour] or "morning")))
        .. (weekly and ", and every week after." or "."))
    local n = 0
    for _, b in ipairs(M.rcInRange(player, range)) do
        if (tonumber(b.rep) or 50) > 20 and M.tpKnows(b, x, y, h) and not (fn(M, "cvTripFor") and M.cvTripFor(base.id, b.id)) then
            local okP, src = pcall(M.cvPick, x, y, h, b.id)
            if okP and src then
                local th = M.travelH(b.x, b.y, x, y, b)
                tp.plans[#tp.plans + 1] = { group = b.id, baseId = base.id, at = math.max(h, at - th), marketAt = at }
                b.cvAwayUntil = math.max(tonumber(b.cvAwayUntil) or 0, h) -- held for the market
                n = n + 1
                line("[Radio] " .. tostring(b.name) .. ": We'll be there.")
            end
        end
    end
    if n == 0 then line("[Radio] *kssht*... nobody says they'll come.") end
    tp.marketH = h
    tp.next = { at = at, hour = hour }
    if weekly then
        -- a standing market: the groups that said yes keep coming every week (no new call needed) until you cancel it
        local who = {}
        for _, pl in ipairs(tp.plans) do if pl.marketAt == at then who[#who + 1] = pl.group end end
        tp.standing = { baseId = base.id, hour = hour, nextAt = at + 24 * 7, groups = who }
    end
    M.tpStats.markets = M.tpStats.markets + 1
    M.tpStats.coming = M.tpStats.coming + n
    return n
end
function M.tpCancelStanding()
    local tp = store()
    tp.standing = nil
    line("[Radio] You call off the weekly market.")
end
function M.tpTick()
    local tp = store()
    local h = hours()
    local J = JM()
    -- a standing weekly market: a day ahead, the regulars plan their walk (whoever can still come)
    local sd = tp.standing
    if type(sd) == "table" and h >= (tonumber(sd.nextAt) or 0) - 24 then
        local base = J and J.BaseAreas and fn(J.BaseAreas, "base") and J.BaseAreas.base(sd.baseId) or nil
        local x, y = nil, nil; if base then x, y = baseXY(base) end
        if x == nil then tp.standing = nil
        else
            local keep = {}
            for _, gid in ipairs(sd.groups or {}) do
                local b = M.nbOf and M.nbOf(gid) or nil
                if b and b.status == "active" and (tonumber(b.rep) or 50) > 20 then
                    keep[#keep + 1] = gid
                    local okP, src = pcall(M.cvPick, x, y, h, b.id)
                    if okP and src and not (fn(M, "cvTripFor") and M.cvTripFor(base.id, b.id)) then
                        local th = M.travelH(b.x, b.y, x, y, b)
                        tp.plans[#tp.plans + 1] = { group = b.id, baseId = base.id, at = math.max(h, sd.nextAt - th), marketAt = sd.nextAt }
                    end
                end
            end
            sd.groups = keep
            tp.next = { at = sd.nextAt, hour = sd.hour }
            sd.nextAt = sd.nextAt + 24 * 7
            if #keep == 0 then tp.standing = nil end
        end
    end
    -- planned departures (market day)
    for i = #tp.plans, 1, -1 do
        local pl = tp.plans[i]
        if h >= (tonumber(pl.at) or 0) then
            table.remove(tp.plans, i)
            local base = J and J.BaseAreas and fn(J.BaseAreas, "base") and J.BaseAreas.base(pl.baseId) or nil
            local b = M.nbOf and M.nbOf(pl.group) or nil
            if base and b then b.cvAwayUntil = nil; pcall(M.cvSetOut, base, h, b.id, { market = true }) end
        end
    end
    -- market visits keep it short while others wait their turn
    local S = J and J.TraderStock
    if S and fn(S, "data") then
        local okD, data = pcall(S.data)
        for _, visit in pairs(okD and type(data) == "table" and data.visits or {}) do
            if type(visit.alcp) == "table" and visit.alcp.market and visit.phase == "waiting" then
                local waiting = false
                for _, t in pairs(select(1, M.cvTrips())) do if t.baseId == visit.baseId and t.market and h >= (tonumber(t.at) or 0) then waiting = true end end
                if waiting and tonumber(visit.arrivedHours) then
                    visit.untilHours = math.min(tonumber(visit.untilHours) or h, visit.arrivedHours + M.tpCfg.marketStay)
                end
            end
        end
    end
    M.tpCount(false)
end

----------------------------------------------------------------------------------------------------------------
-- your settlers trade too
----------------------------------------------------------------------------------------------------------------
M.cvArriveHooks = M.cvArriveHooks or {}
table.insert(M.cvArriveHooks, function(visit, b, h)
    local settlers = 0
    pcall(function() for _ in pairs(M.bucket("settlers")) do settlers = settlers + 1 end end)
    if settlers == 0 then return end
    store().settlerTradeH = h
    M.tpStats.settlerTrades = M.tpStats.settlerTrades + 1
    if fn(M, "nbRep") then pcall(M.nbRep, b, 3, "Their traders dealt with your people") end
end)
M.cpMoraleHooks = M.cpMoraleHooks or {}
table.insert(M.cpMoraleHooks, function(uid)
    local at = tonumber(store().settlerTradeH)
    if at and hours() - at < 24 then return -2 end -- a good trading day lifts the camp
    return 0
end)

----------------------------------------------------------------------------------------------------------------
-- menus
----------------------------------------------------------------------------------------------------------------
function M.tpFill(playerNum, context, worldobjects, test)
    if test == true or M.settings.tradingPost == false or not M.settings.enabled or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
    local player = getSpecificPlayer(playerNum or 0)
    if player == nil or M.tpJeemBase(player) == nil then return end
    local post = store().post
    for _, o in ipairs(worldobjects or {}) do
        local c = containerOf(o)
        if c then
            local sq = nil
            pcall(function() sq = o:getSquare() end)
            if sq and post and post.x == sq:getX() and post.y == sq:getY() and post.z == sq:getZ() then
                context:addOption(ALifeTr("IGUI_ALCP_PostStop", "Stop using this as our trading post"), nil, function() M.tpClearPost() end)
            else
                context:addOption(ALifeTr("IGUI_ALCP_PostMake", "Make this our trading post"), o, function(obj) M.tpSetPost(obj) end)
            end
            return
        end
    end
end
function M.tpPerf()
    local s = M.tpStats
    local p = store().post
    return "market: post " .. (p and (p.items .. " items") or "none") .. ", sent on their own " .. s.sent .. ", market days " .. s.markets
        .. " (" .. s.coming .. " coming), word spread " .. s.spread .. ", settler trades " .. s.settlerTrades
end

M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeMarket] " .. where .. " failed, trading post / market days off for this session: " .. tostring(a)) end
    return ok and a or nil
end
-- the radio menu gets "Announce a market day" (RadioCalls loads after this file: hooked once the game starts)
function M.tpInstallRadio()
    if M._alcpHooks.marketRadio or not fn(M, "rcFill") then return false end
    M._alcpHooks.marketRadio = true
        local fill = M.rcFill
        M.rcFill = function(playerNum, context, worldobjects, test, ...)
            local r = fill(playerNum, context, worldobjects, test, ...)
            if test ~= true and M.settings.marketDays ~= false and type(context) == "table" then
                pcall(function()
                    local player = getSpecificPlayer(playerNum or 0)
                    if player == nil or M.tpJeemBase(player) == nil then return end
                    for _, opt in ipairs(context.options or {}) do
                        if opt.name == ALifeTr("IGUI_ALCP_Radio", "Radio") and opt.subOption then
                            local sub = context:getSubMenu(opt.subOption)
                            if sub then
                                local mo = sub:addOption(ALifeTr("IGUI_ALCP_MarketAnnounce", "Announce a market day"), nil, nil)
                                local ms = ISContextMenu:getNew(sub)
                                sub:addSubMenu(mo, ms)
                                for _, d in ipairs({ 1, 2, 3, 7 }) do
                                    local dopt = ms:addOption((dayWords(d):gsub("^%l", string.upper)), nil, nil)
                                    local ts = ISContextMenu:getNew(ms)
                                    ms:addSubMenu(dopt, ts)
                                    for _, hr in ipairs({ 9, 12, 15 }) do
                                        ts:addOption((M.tpWhenWords[hr]:gsub("^%l", string.upper)), player, function(p) M.tpMarket(p, d, hr, false) end)
                                        ts:addOption(ALifeTr("IGUI_ALCP_MarketWeekly", "%1, every week", (M.tpWhenWords[hr]:gsub("^%l", string.upper))), player, function(p) M.tpMarket(p, d, hr, true) end)
                                    end
                                end
                                if store().standing then ms:addOption(ALifeTr("IGUI_ALCP_MarketCallOff", "Call off the weekly market"), nil, function() M.tpCancelStanding() end) end
                            end
                        end
                    end
                end)
            end
            return r
        end
    return true
end
function M.tpInstall()
    if M._alcpHooks.market or type(M.nbStep) ~= "function" or not fn(M, "cvSetOut") then return false end
    M._alcpHooks.market = true
    local step = M.nbStep
    M.nbStep = function(b, haven, crew, home, dt, h, far, scan, ...)
        local r = step(b, haven, crew, home, dt, h, far, scan, ...)
        if type(b) == "table" and b.status == "active" and not broken then
            guard("post", M.tpDaily, b, h)
            guard("spread", M.tpSpread, b, h)
        end
        return r
    end
    if type(ALifeRadial) == "table" and fn(ALifeRadial, "addFiller") then
        ALifeRadial.addFiller("tradingpost", "camp", function(...) guard("menu", M.tpFill, ...) end)
    end
    M.tpInstallRadio()
    if type(Events) == "table" and Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_Market", function() guard("tick", M.tpTick) end) end
    print("[ALifeMarket] loaded v" .. ALifeSide.MOD_VERSION .. " (word of your place spreads; trading post; market days)")
    return true
end
M.tpInstall()
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.tpInstall(); pcall(M.tpInstallRadio) end) end
