-- A-Life NPC Overhaul pre-1.0: TRADE, PART 7. WHAT THE TRADE TAB SHOWS (docs/PLAN-TRADE.md T9), built where the world
-- runs (SP: right here; MP: on the server, sent to the asking player as flat rows: ALifeCmd carries 3 levels, 40 keys).
-- Words, never numbers (rule 6): fill bars for your own post's real item counts, safety as words / colours, ETAs as words.
--   trPost    your trading post, market day, traders here / coming
--   trGroups  groups you know: where they are (map), mood words, wealth word, road to you, embargo
--   trRuns    runs on the road you'd know about (yours, ones coming to you, ones near your place)
--   trRoutes  roads between groups you know (for the map)
--   trDeals   your deals and offers waiting
--   trWord    trade talk heard, embargoes, feuds
--   trCrew    who'd go on a caravan from your camp, and why not
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeTalk_TradeDeals"
local M = ALifeLLMTalk
local T = ALifeTrade
if type(M) ~= "table" or type(T) ~= "table" then return end
local fn, d2, hours = T.fn, T.d2, T.hours

function T.etaWords(hrs)
    hrs = tonumber(hrs) or 0
    if hrs <= 0.5 then return "any time now" elseif hrs <= 2 then return "within a couple of hours" elseif hrs <= 8 then return "later today" end
    if hrs <= 30 then return "tomorrow" elseif hrs <= 72 then return "in a few days" end
    return "in a week or more"
end
function T.agoWords(hrs)
    hrs = tonumber(hrs) or 0
    if hrs < 6 then return "just now" elseif hrs < 30 then return "yesterday" elseif hrs < 96 then return "a few days ago" end
    return "a while back"
end
function T.fillWord(n) n = tonumber(n) or 0; if n >= 12 then return "plenty" elseif n >= 4 then return "some" elseif n > 0 then return "low" end return "none" end
local function where(run, h)
    local f = math.max(0, math.min(1, (h - run.leave) / math.max(0.01, run.arrive - run.leave)))
    return run.x0 + (run.x1 - run.x0) * f, run.y0 + (run.y1 - run.y0) * f
end
local function placeName(id)
    if id == "you" then return "your place" end
    local b = T.base(id)
    return b and tostring(b.name) or "somewhere"
end
local function knownGroup(b) return type(b) == "table" and (b.knowsYou or b.radioKnown) and not b.road end

function T.viewPost(player)
    local rows = {}
    local tp = fn(M, "tpStore") and M.tpStore() or {}
    local post = type(tp.post) == "table" and tp.post or nil
    local kinds, loaded = T.postKinds()
    if not loaded then kinds = type(T.store().postSeen) == "table" and T.store().postSeen or {} end
    rows[#rows + 1] = { k = "post", set = post ~= nil, loaded = loaded == true, items = post and tonumber(post.items) or 0 }
    for _, kind in ipairs({ "food", "water", "meds", "ammo", "tools", "materials", "fuel", "other" }) do
        rows[#rows + 1] = { k = "kind", kind = kind, word = T.KIND_WORDS[kind] or kind, n = tonumber(kinds[kind]) or 0, fill = T.fillWord(kinds[kind]) }
    end
    local h = hours()
    if type(tp.next) == "table" and tonumber(tp.next.at) and tp.next.at > h - 12 then
        rows[#rows + 1] = { k = "market", when = T.etaWords(tp.next.at - h), weekly = type(tp.standing) == "table" }
    end
    for _, v in pairs((fn(M, "nbStore") and M.nbStore().ovVisits) or {}) do rows[#rows + 1] = { k = "trader", name = tostring(v.name or "Traders"), where = "at your place" } end
    local trips = fn(M, "cvTrips") and select(1, M.cvTrips()) or {}
    for _, trip in pairs(trips) do
        if type(trip) == "table" then
            local b = T.base(trip.home)
            rows[#rows + 1] = { k = "trader", name = tostring(b and b.name or "Traders"), where = "on the road to you, " .. T.etaWords((tonumber(trip.at) or h) - h) }
        end
    end
    for _, run in pairs(T.store().runs) do
        local leg = run.legs and run.legs[run.leg]
        if leg and leg.to == "you" and run.state ~= "home" then
            rows[#rows + 1] = { k = "trader", name = tostring(run.fromName or "Traders"), where = (run.state == "wait" and "waiting at your trading post" or ("bringing a deal delivery, " .. T.etaWords(run.arrive - h))) }
        end
    end
    while #rows > 40 do table.remove(rows) end
    return rows
end
function T.viewGroups(player)
    local rows = {}
    local px, py = T.placeXY("you")
    if px == nil and player then pcall(function() px, py = player:getX(), player:getY() end) end
    rows[1] = { k = "you", x = px or 0, y = py or 0 }
    for _, b in ipairs(M.nbActive()) do
        if #rows >= 40 then break end
        if knownGroup(b) and tonumber(b.x) then
            local moods = {}
            for _, s in ipairs(T.shortages(b, 2)) do moods[#moods + 1] = T.moodWord(b, s.kind) or ("short on " .. (T.KIND_WORDS[s.kind] or s.kind)) end
            for _, k in ipairs(T.plenty(b)) do if #moods < 4 then moods[#moods + 1] = "plenty of " .. (T.KIND_WORDS[k] or k) end end
            local emb = T.embargoed and T.embargoed(b.id, "you") or false
            local e = emb and T.embargoOf(b.id, "you") or nil
            rows[#rows + 1] = { k = "g", id = b.id, name = tostring(b.name), x = b.x, y = b.y, known = b.knowsYou ~= nil and b.knowsYou ~= false,
                mood = table.concat(moods, ", "), wealth = type(ALifeWorth) == "table" and ALifeWorth.wealthWord(b) or "",
                road = px and T.routeWord(T.routeSafe("you", b.id)) or "", safe = px and T.routeSafe("you", b.id) or 50,
                feel = fn(M, "nbRepWord") and M.nbRepWord(b.rep) or "", trader = b.trade == "traders",
                emb = emb, embLeft = e and T.etaWords((tonumber(e.untilH) or 0) - hours()) or "", hrs = px and T.etaWords(M.travelH(px, py, b.x, b.y, nil)) or "" }
        end
    end
    return rows
end
function T.viewRuns(player)
    local rows = {}
    local h = hours()
    local px, py = T.placeXY("you")
    local list = {}
    for _, run in pairs(T.store().runs) do list[#list + 1] = run end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _, run in ipairs(list) do
        if #rows >= 40 then break end
        local x, y = where(run, h)
        local leg = run.legs and run.legs[run.leg]
        local mine = run.from == "you"
        local toYou = leg and leg.to == "you"
        local near = px and d2(x, y, px, py) <= 600 ^ 2
        local fromB = T.base(run.from)
        if mine or toYou or near or (fromB and fromB.knowsYou) then
            local names = {}
            if mine then for _, uid in ipairs(run.crew or {}) do
                local n = nil
                if type(ALifeCampKit) == "table" and fn(ALifeCampKit, "first") then pcall(function() n = ALifeCampKit.first(uid) end) end
                names[#names + 1] = n or "someone"
            end end
            local items = {}
            for _, uid in ipairs(run.crew or {}) do for _, t in ipairs((run.packs or {})[uid] or {}) do items[#items + 1] = t end end
            local cargo = T.mainKind(items)
            local state = run.state == "home" and "coming home" or (run.state == "wait" and "waiting" or ("on the way to " .. placeName(leg and leg.to)))
            rows[#rows + 1] = { k = "r", id = run.id, from = placeName(run.from), to = placeName(leg and leg.to or run.from), x = x, y = y,
                tx = run.x1, ty = run.y1, mine = mine, toYou = toYou == true, kind = tostring(run.kind or "swap"), state = state,
                cargo = cargo and (T.KIND_WORDS[cargo] or cargo) or "nothing", crew = #(run.crew or {}), names = table.concat(names, ", "),
                eta = T.etaWords(run.arrive - h), overdue = h > run.arrive + 6, escorted = (tonumber(run.escorts) or 0) > 0 }
        end
    end
    return rows
end
function T.viewRoutes(player)
    local rows = {}
    for _, r in pairs(T.store().routes) do
        if #rows >= 40 then break end
        local a, b = T.base(r.a), T.base(r.b)
        local ax, ay, bx, by
        if r.a == "you" then ax, ay = T.placeXY("you") elseif a and knownGroup(a) then ax, ay = a.x, a.y end
        if r.b == "you" then bx, by = T.placeXY("you") elseif b and knownGroup(b) then bx, by = b.x, b.y end
        if ax and bx then
            T.routeFade(r, hours())
            rows[#rows + 1] = { ax = ax, ay = ay, bx = bx, by = by, safe = r.safe, word = T.routeWord(r.safe), runs = (tonumber(r.runs) or 0) > 0 }
        end
    end
    return rows
end
function T.viewDeals(player)
    local rows = {}
    for _, d in pairs(T.store().deals) do
        if d.b == "you" and #rows < 30 then
            rows[#rows + 1] = { k = "deal", id = d.id, name = placeName(d.a), give = T.KIND_WORDS[d.give] or d.give, want = T.KIND_WORDS[d.want] or d.want,
                every = d.every, health = T.dealHealth(d), next = T.etaWords((tonumber(d.nextH) or 0) - hours()) }
        end
    end
    for _, off in pairs(T.store().offers) do
        if #rows < 40 then rows[#rows + 1] = { k = "offer", id = off.id, name = tostring(off.name), give = T.KIND_WORDS[off.give] or off.give, want = T.KIND_WORDS[off.want] or off.want, every = off.every } end
    end
    table.sort(rows, function(a, b) if a.k ~= b.k then return a.k == "offer" end return tostring(a.id) < tostring(b.id) end)
    return rows
end
function T.viewWord(player)
    local rows = {}
    local h = hours()
    for _, r in ipairs(T.store().rumors) do if #rows < 16 then rows[#rows + 1] = { k = "rumor", text = r.text, ago = T.agoWords(h - (tonumber(r.h) or h)) } end end
    for gid, e in pairs(T.store().embargo) do
        local x = type(e) == "table" and e.you or nil
        local b = T.base(gid)
        if b and type(x) == "table" and (tonumber(x.untilH) or 0) > h and #rows < 32 then
            rows[#rows + 1] = { k = "emb", id = b.id, name = tostring(b.name), left = T.etaWords(x.untilH - h), why = tostring(x.why or "") }
        end
    end
    local seen = {}
    for _, a in ipairs(M.nbActive()) do
        if knownGroup(a) and type(a.dir) == "table" and type(a.dir.ties) == "table" then
            for oid, v in pairs(a.dir.ties) do
                local o = T.base(oid)
                local key = tostring(a.id) < tostring(oid) and (a.id .. oid) or (oid .. a.id)
                if o and knownGroup(o) and not seen[key] and (tonumber(v) or 0) <= T.num("feudTie") and #rows < 40 then
                    seen[key] = true
                    rows[#rows + 1] = { k = "feud", text = tostring(a.name) .. " and " .. tostring(o.name) .. " are feuding: no trade on that road" }
                end
            end
        end
    end
    return rows
end
function T.viewCrew(player)
    local rows = {}
    for _, c in ipairs(T.ownCandidates(player)) do
        if #rows >= 40 then break end
        rows[#rows + 1] = { uid = c.uid, name = c.name, why = c.why and (string.gsub(T.REFUSE[c.why] or "%1 won't go.", "%%1 ", "")) or "" }
    end
    return rows
end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "view") then
    ALifeRemote.view("trPost", T.viewPost, {})
    ALifeRemote.view("trGroups", T.viewGroups, {})
    ALifeRemote.view("trRuns", T.viewRuns, {})
    ALifeRemote.view("trRoutes", T.viewRoutes, {})
    ALifeRemote.view("trDeals", T.viewDeals, {})
    ALifeRemote.view("trWord", T.viewWord, {})
    ALifeRemote.view("trCrew", T.viewCrew, {})
end
