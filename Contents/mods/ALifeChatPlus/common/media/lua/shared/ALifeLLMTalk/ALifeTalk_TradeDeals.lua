-- A-Life NPC Overhaul pre-1.0: TRADE, PART 5. STANDING DEALS AND TRADE TALK ON THE RADIO (docs/PLAN-TRADE.md T3 T8).
--  DEALS: "so much of this, every so many days, for so much of that".
--   * you propose one (Trade tab, to a group you know): they say yes if they want what you offer and the deal is fair
--     enough, and they don't hold anything against you.
--   * a group short of something you have plenty of offers one (a letter: accept or decline in the Trade tab).
--   * groups that keep trading with each other settle into deals of their own.
--   * every delivery is a real run: their people carry their side to your trading post and take yours (you or the
--     post have to be there: they wait a while). Short on your side = a missed delivery; three and the deal's off.
--     Kept deals warm them to you.
--  RUMORS: once a day, if you have a radio, you hear trade talk: who's short of what, roads that got robbed, deals
--   that broke. It's what people say, not what's true by the time you get there.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_TradeDeals")
require "ALifeLLMTalk/ALifeTalk_TradeOwn"
local M = ALifeLLMTalk
local T = ALifeTrade
if type(M) ~= "table" or type(T) ~= "table" then return end
local fn, d2, hours, log, event = T.fn, T.d2, T.hours, T.log, T.event

T.defaults({ deals = true, dealFair = 70, dealMissBreak = 3, dealOfferChance = 10, dealWaitH = 24, dealWorth = 20,
    dealRep = 45, npcDeals = true, npcDealAfter = 3, rumors = true, rumorsPerDay = 2, rumorKeepDays = 5 })
T.addRows({
    { "deals", "Trade deals: standing deals with groups (so much every so many days), delivered by real people" },
    { "dealMissBreak", "Trade deals: missed deliveries before a deal is off", { 2, 3, 5 } },
    { "dealOfferChance", "Trade deals: chance a day a group short of something offers you a deal (percent)", { 5, 10, 25 } },
    { "dealWaitH", "Trade deals: hours their people wait at your trading post", { 12, 24, 48 } },
    { "npcDeals", "Trade deals: groups that keep trading with each other make deals of their own" },
    { "rumors", "Trade talk on the radio: who's short of what, robbed roads, broken deals (needs a radio)" },
    { "rumorsPerDay", "Trade talk: most rumors a day", { 1, 2, 4 } },
})
M.trDealStats = M.trDealStats or { proposed = 0, agreed = 0, refused = 0, offered = 0, kept = 0, missed = 0, broken = 0, npc = 0, rumors = 0 }
local S = M.trDealStats

----------------------------------------------------------------------------------------------------------------
-- deals
----------------------------------------------------------------------------------------------------------------
function T.dealsWith(id)
    local out = {}
    for _, d in pairs(T.store().deals) do if d.a == id or d.b == id then out[#out + 1] = d end end
    table.sort(out, function(x, y) return tostring(x.id) < tostring(y.id) end)
    return out
end
function T.dealHealth(d)
    if (tonumber(d.missed) or 0) == 0 then return (tonumber(d.kept) or 0) > 0 and "going well" or "just agreed" end
    if d.missed >= T.num("dealMissBreak") - 1 then return "about to break" end
    return "slipping"
end
local function newDeal(a, b, give, want, every, by)
    local d = { id = T.newId("deal"), a = a, b = b, give = give, want = want, every = math.max(1, tonumber(every) or 7),
        nextH = hours() + 24, kept = 0, missed = 0, by = by, fromH = hours() }
    T.store().deals[d.id] = d
    return d
end
-- would group o take this deal from you? (they send theirKind, you send yourKind)
function T.dealYes(o, yourKind, theirKind)
    if o == nil then return false, "gone" end
    if T.embargoed and T.embargoed(o.id, "you") then return false, "embargo" end
    if (tonumber(o.rep) or 50) < T.num("dealRep") then return false, "trust" end
    if T.need(o, yourKind) < 1 then return false, "dont_need" end
    if T.ratio(o, theirKind) < 1 then return false, "cant_spare" end
    -- fair enough: what they give against what they get, both as it's worth to them
    local fair = T.need(o, yourKind) / math.max(0.3, T.need(o, theirKind))
    if fair * 100 < T.num("dealFair") then return false, "unfair" end
    return true
end
T.DEAL_NO = { gone = "That group is gone.", embargo = "They won't deal with you.", trust = "They don't trust you enough for a standing deal.",
    dont_need = "They don't need that.", cant_spare = "They can't spare that.", unfair = "They don't think that's fair.", far = "That's too far for a standing deal." }
-- you propose (window button, exposed): theirKind = what they bring, yourKind = what they take from your post
function M.trDealPropose(groupId, yourKind, theirKind, every, player)
    player = ALifeSide.you(player)
    if not T.on("deals") then return false end
    S.proposed = S.proposed + 1
    local o = T.base(tostring(groupId or ""))
    local ok, why = T.dealYes(o, tostring(yourKind or ""), tostring(theirKind or ""))
    if not ok then S.refused = S.refused + 1; T.letter(player, tostring(o and o.name or "They") .. ": no deal. " .. (T.DEAL_NO[why] or ""), true); return false end
    local d = newDeal(o.id, "you", tostring(theirKind), tostring(yourKind), every, "you")
    S.agreed = S.agreed + 1
    T.letter(player, "Deal with " .. tostring(o.name) .. ": their " .. (T.KIND_WORDS[d.give] or d.give) .. " for your " .. (T.KIND_WORDS[d.want] or d.want)
        .. " every " .. d.every .. " days, at your trading post.", false)
    event(o, "Made a standing deal with you", "trade")
    return true
end
function M.trDealEnd(dealId, player)
    local d = T.store().deals[tostring(dealId or "")]
    if type(d) ~= "table" or d.b ~= "you" then return false end
    T.store().deals[d.id] = nil
    local o = T.base(d.a)
    if o and fn(M, "nbRep") then pcall(M.nbRep, o, -3, "You called off your deal") end
    T.letter(ALifeSide.you(player), "You called off the deal with " .. tostring(o and o.name or "them") .. ".", false)
    return true
end
-- an offer from a group (letter); accepted / declined in the Trade tab
function T.offerDay(o, h)
    if not T.on("deals") or o.airport or o.road or not o.knowsYou then return end
    if T.embargoed and T.embargoed(o.id, "you") or (tonumber(o.rep) or 50) < T.num("dealRep") + 5 then return end
    local st = T.store()
    for _, off in pairs(st.offers) do if off.from == o.id then return end end
    for _, d in pairs(st.deals) do if d.a == o.id and d.b == "you" then return end end
    if T.roll(o.id .. ":offer:" .. math.floor(h / 24)) * 100 >= T.num("dealOfferChance") then return end
    local seen = type(st.postSeen) == "table" and st.postSeen or {}
    local short = T.shortages(o, 3)
    local want, give
    for _, s in ipairs(short) do if (tonumber(seen[s.kind]) or 0) >= 6 then want = s.kind; break end end
    if want == nil then return end
    local plenty = T.plenty(o)
    for _, k in ipairs(plenty) do if k ~= want then give = k; break end end
    if give == nil then return end
    local off = { id = T.newId("offer"), from = o.id, name = o.name, give = give, want = want, every = 7, h = h }
    st.offers[off.id] = off
    S.offered = S.offered + 1
    T.letter(nil, tostring(o.name) .. " offers a deal: their " .. (T.KIND_WORDS[give] or give) .. " for your " .. (T.KIND_WORDS[want] or want) .. " every week. Answer in the Trade tab.", false)
end
function M.trDealAnswer(offerId, yes, player)
    player = ALifeSide.you(player)
    local st = T.store()
    local off = st.offers[tostring(offerId or "")]
    if type(off) ~= "table" then return false end
    st.offers[off.id] = nil
    local o = T.base(off.from)
    if o == nil then return false end
    if yes == true or yes == "true" or yes == 1 then
        newDeal(o.id, "you", off.give, off.want, off.every, o.id)
        S.agreed = S.agreed + 1
        if fn(M, "nbRep") then pcall(M.nbRep, o, 2, "You took their deal") end
        T.letter(player, "Deal with " .. tostring(o.name) .. " is on.", false)
    else
        T.letter(player, "You turned down " .. tostring(o.name) .. "'s offer.", false)
    end
    return true
end

-- deliveries: due deals send a run (the first group carries its side)
function T.dealsDue(h)
    if not T.on("deals") then return end
    local st = T.store()
    local list = {}
    for _, d in pairs(st.deals) do list[#list + 1] = d end
    table.sort(list, function(x, y) return tostring(x.id) < tostring(y.id) end)
    for _, d in ipairs(list) do
        if h >= (tonumber(d.nextH) or 0) and not d.running then
            local a = T.base(d.a)
            if a == nil or (d.b ~= "you" and T.base(d.b) == nil) then
                st.deals[d.id] = nil
            else
                local run, why = T.startRun(a, { { to = d.b, give = d.give, want = d.want, worth = T.num("dealWorth") } }, h, { kind = "deal", deal = d.id })
                d.nextH = h + d.every * 24
                if run then d.running = run.id
                elseif why ~= "road_bad" and why ~= "nobody_spare" then T.dealMiss(d, "they had nothing to send") end
            end
        end
    end
end
function T.dealMiss(d, why)
    d.missed = (tonumber(d.missed) or 0) + 1
    S.missed = S.missed + 1
    local a = T.base(d.a)
    if d.b == "you" and a then T.letter(nil, "Missed delivery on your deal with " .. tostring(a.name) .. " (" .. tostring(why) .. ").", true) end
    if d.missed >= T.num("dealMissBreak") then
        T.store().deals[d.id] = nil
        S.broken = S.broken + 1
        if d.b == "you" and a then
            if fn(M, "nbRep") then pcall(M.nbRep, a, -8, "The deal with you fell apart") end
            T.letter(nil, "The deal with " .. tostring(a.name) .. " is off.", true)
        else
            local b = T.base(d.b)
            if a and b and fn(M, "dirTieAdd") then pcall(M.dirTieAdd, a, b, -8) end
        end
        T.rumorAdd("The deal between " .. tostring(a and a.name or "two groups") .. " and " .. (d.b == "you" and "you" or tostring((T.base(d.b) or {}).name or "another group")) .. " fell apart")
    end
end
function T.dealKept(d)
    d.kept = (tonumber(d.kept) or 0) + 1
    d.missed = math.max(0, (tonumber(d.missed) or 0) - 1)
    S.kept = S.kept + 1
    local a = T.base(d.a)
    if d.b == "you" and a and fn(M, "nbRep") then pcall(M.nbRep, a, 2, nil)
    elseif a and T.base(d.b) and fn(M, "dirTieAdd") then pcall(M.dirTieAdd, a, T.base(d.b), 2) end
end
-- a deal run at your trading post: hand over theirs, take yours
function T.tradeWithYou(run, leg, h)
    local box = T.postBox()
    local gave = {}
    for _, uid in ipairs(run.crew) do for _, t in ipairs(run.packs[uid] or {}) do gave[#gave + 1] = t end end
    if box == nil then
        if run.state ~= "wait" then run.state, run.waitFrom, run.waitH = "wait", h, T.num("dealWaitH") end
        if not run.giveUp then return nil, nil, "wait" end
        run.state = "out"
        return {}, gave, "nobody"
    end
    run.state = "out"
    T.postPut(gave)
    local sent = T.worthOfList(gave)
    local a = T.base(run.from)
    local fair = sent * ((a and leg.want) and (1 / math.max(0.5, T.need(a, leg.want))) or 1)
    local got = T.postTake(leg.want, fair)
    local name = tostring(a and a.name or "Traders")
    T.letter(nil, "Traders from " .. name .. " left " .. #gave .. " " .. (T.KIND_WORDS[leg.give] or "things") .. " at your trading post and took " .. #got .. " " .. (T.KIND_WORDS[leg.want] or "things") .. ".", false)
    if T.worthOfList(got) < fair * 0.5 then return gave, got, "short" end
    return gave, got, nil
end
T.onLeg[#T.onLeg + 1] = function(run, leg, gave, got, why)
    if run.deal == nil then return end
    local d = T.store().deals[run.deal]
    if type(d) ~= "table" then return end
    d.running = nil
    if why == nil then T.dealKept(d)
    else T.dealMiss(d, why == "short" and "not enough in your trading post" or (why == "nobody" and "nobody was there" or tostring(why))) end
end
T.onRunDone[#T.onRunDone + 1] = function(run, why)
    if run.deal == nil then return end
    local d = T.store().deals[run.deal]
    if type(d) == "table" and d.running == run.id then d.running = nil; if why == "lost" then T.dealMiss(d, "their people never got there") end end
end
-- groups that keep swapping settle into a deal
T.onLeg[#T.onLeg + 1] = function(run, leg, gave, got, why)
    if not T.on("npcDeals") or run.kind ~= "swap" or why ~= nil or run.from == "you" or leg.to == "you" then return end
    local st = T.store()
    st.pairs = type(st.pairs) == "table" and st.pairs or {}
    local k = tostring(run.from) .. ">" .. tostring(leg.to) .. ":" .. tostring(leg.give) .. ">" .. tostring(leg.want)
    st.pairs[k] = (tonumber(st.pairs[k]) or 0) + 1
    if st.pairs[k] >= T.num("npcDealAfter") then
        st.pairs[k] = nil
        for _, d in pairs(st.deals) do if d.a == run.from and d.b == leg.to then return end end
        newDeal(run.from, leg.to, leg.give, leg.want, 7, run.from)
        S.npc = S.npc + 1
        local a, b = T.base(run.from), T.base(leg.to)
        event(a, "Settled into a weekly deal with " .. tostring(b and b.name), "trade")
        event(b, "Settled into a weekly deal with " .. tostring(a and a.name), "trade")
    end
end
-- the post's contents as last seen (offers need to know what you have)
function T.postSeenTick()
    local kinds, loaded = T.postKinds()
    if loaded then T.store().postSeen = kinds end
end

----------------------------------------------------------------------------------------------------------------
-- T8: trade talk on the radio
----------------------------------------------------------------------------------------------------------------
function T.rumorAdd(text)
    local st = T.store()
    local h = hours()
    for _, r in ipairs(st.rumors) do if r.text == text and h - r.h < 24 then return end end
    table.insert(st.rumors, 1, { text = text, h = h })
    while #st.rumors > 16 do table.remove(st.rumors) end
end
local function hasRadio(player) return fn(M, "rcRadio") and select(2, pcall(M.rcRadio, player)) ~= nil end
function T.rumorDay(h)
    if not T.on("rumors") then return end
    local st = T.store()
    -- old talk fades
    for i = #st.rumors, 1, -1 do if h - (tonumber(st.rumors[i].h) or h) > T.num("rumorKeepDays") * 24 then table.remove(st.rumors, i) end end
    local player = fn(M, "homePlayer") and M.homePlayer() or ALifeSide.you()
    if player == nil or not hasRadio(player) then return end
    local cands = {}
    for _, b in ipairs(M.nbActive()) do
        if not b.airport and (b.knowsYou or b.radioKnown) then
            local s = T.shortages(b, 1)[1]
            if s then cands[#cands + 1] = { w = s.need, text = "Heard the folks at " .. tostring(b.name) .. " are " .. (T.moodWord(b, s.kind) or ("short on " .. (T.KIND_WORDS[s.kind] or s.kind))) } end
            if b.trade == "traders" and type(ALifeWorth) == "table" and ALifeWorth.wealthWord(b) == "rich" then
                cands[#cands + 1] = { w = 1.2, text = tostring(b.name) .. " has a lot to trade, they say" }
            end
        end
    end
    for _, r in pairs(st.routes) do
        if h - (tonumber(r.lastRob) or -1e9) < 24 then
            local a, b = T.base(r.a), T.base(r.b)
            if a and b then cands[#cands + 1] = { w = 1.5, text = "The road between " .. tostring(a.name) .. " and " .. tostring(b.name) .. " got hit. Traders beware" } end
        end
    end
    table.sort(cands, function(x, y) if x.w ~= y.w then return x.w > y.w end return x.text < y.text end)
    local n = 0
    for i, c in ipairs(cands) do
        if n >= T.num("rumorsPerDay") then break end
        if n == 0 or T.roll(c.text .. math.floor(h / 24)) < 0.7 then
            n = n + 1
            T.rumorAdd(c.text)
            S.rumors = S.rumors + 1
            if fn(M, "radioLine") then pcall(M.radioLine, player, c.text) end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- hooks
----------------------------------------------------------------------------------------------------------------
T.onBaseDay[#T.onBaseDay + 1] = function(b, h)
    local day = math.floor(h / 24)
    if b.trOfferDay == day then return end
    b.trOfferDay = day
    pcall(T.offerDay, b, h)
end
local lastDay = -1
local function tenMin()
    local h = hours()
    pcall(T.dealsDue, h)
    pcall(T.postSeenTick)
    local day = math.floor(h / 24)
    if day ~= lastDay and (h % 24) >= 8 then lastDay = day; pcall(T.rumorDay, h) end
end
if type(Events) == "table" and Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_TradeDeals", tenMin) end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "expose") then
    ALifeRemote.expose("trDealPropose", 4, 5)
    ALifeRemote.expose("trDealEnd", 1, 2)
    ALifeRemote.expose("trDealAnswer", 2, 3)
    ALifeRemote.expose("trRepay", 1, 2)
end
function M.trRepay(groupId, player)
    player = ALifeSide.you(player)
    local ok, why = T.repay(player, tostring(groupId or ""))
    if not ok then
        T.letter(player, ({ not_there = "You have to go to their place to pay them back.", not_enough = "You don't have enough on you to pay them back.",
            no_embargo = "They have nothing against you." })[why] or "They won't take it.", true)
    end
    return ok
end
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local n = 0
        for _ in pairs(T.store().deals) do n = n + 1 end
        print(T.TAG .. " ready v" .. T.VERSION .. ": deals " .. (T.on("deals") and "on" or "off") .. " (" .. n .. "), rumors " .. (T.on("rumors") and "on" or "off"))
    end)
end
