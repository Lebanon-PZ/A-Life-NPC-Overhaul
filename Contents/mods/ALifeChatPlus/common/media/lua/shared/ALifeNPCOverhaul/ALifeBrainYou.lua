-- A-Life NPC Overhaul pre-1.0: ONE BRAIN (docs/PLAN-ONE-BRAIN.md). Your camp is a group on the real brain, the same
-- mind every NPC group runs (ALifeBrain*): it knows only what its people saw or heard (fog of war), it picks a stance,
-- splits its people into jobs and makes plans. You're the leader, so the big calls are yours.
--   * the camp record: group id "you" (the id every NPC group already uses for your camp), rebuilt each hour from what
--     is really there: Jeem residents at camp (ALifeWork.people), the Food store, the trading post, your strength.
--     Saved in global ModData (bucket "brainYou"); never in the NPC base list, so no NPC loop ever sees it.
--   * home jobs (guard, food, build, rest): the allocator's counts are the Work tab's targets (ALifeWork.pass moves
--     people inside your priorities; the small camp brain that used to live there is gone).
--   * away jobs need your people to walk out (trade run = your caravan, scout, envoy, war party). A member brings the
--     idea to you as a priority card in their own voice (persona lens): yes / no / later. No = they trust you less
--     (proud and brave ones mind more); ignored too long = a little less; later = asked again in a few hours.
--   * the dial (Work tab): 0 Off (nothing unless you start it), 1 Advisor (default: everything that sends people out
--     asks first), 2 Run it (trade runs, scouts, peace talks go; you're told after). Raids, wars and tribute always
--     ask, even on Run it (setting campBrainWarAsk).
--   * reports: what the brain does and learns comes as letters on the right, in "we" words. Members whose nature
--     fights the stance grumble now and then. A refusal is real: people who won't go (hurt, scared, don't trust you)
--     stay home (same rule as your caravans).
--   * what we know: the camp's beliefs about every group (strength next to ours, food, mood, how sure, how old) as a
--     page in the Work tab. Fog of war for you too: scouts, your traders, traders at your post, radio, neighbours.
-- MP: world side (server). One shared camp; cards go to the camp's player (K.player / M.homePlayer).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeBrainYou")
for _, f in ipairs({ "ALifeBrain", "ALifeBrainAlloc", "ALifeBrainCommand", "ALifeBrainKnow", "ALifeBrainManagers", "ALifeBrainMind",
        "ALifeBrainPlans", "ALifeBrainWar", "ALifeBrainWords" }) do pcall(require, "ALifeNPCOverhaul/" .. f) end
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local K = ALifeCampKit
if type(BR) ~= "table" or type(BR.M) ~= "table" or type(K) ~= "table" then return end
local M = BR.M
local fn, hours, d2, clamp = BR.fn, BR.hours, BR.d2, BR.clamp
local TAG = "[ALifeBrainYou]"
BR.YOU_VERSION = ALifeSide.MOD_VERSION
local function log(m) print(TAG .. " " .. tostring(m)) end
local function T() return ALifeTrade end
local function W() return type(ALifeWork) == "table" and ALifeWork or nil end

BR.YOU_DEFAULTS = {
    campBrainWarAsk = true,  -- raids, wars and tribute always need your yes, even on Run it
    campAskHours = 12,       -- game hours an idea waits for your answer before they take silence as no
    campLaterHours = 6,      -- "later": asked again after this many game hours
    campAskCooldown = 48,    -- game hours before the same idea comes up again after a no
    campOverruleTrust = 3,   -- trust lost by the one whose idea you turn down (proud / brave ones lose more)
    campIgnoreTrust = 1,     -- trust lost when you leave their idea unanswered
    campYesTrust = 1,        -- trust gained when you go with their idea
    campReports = 4,         -- most letters a day about what the camp did and learned
}
K.reg(BR.YOU_DEFAULTS, {
    { "campBrainWarAsk", "Camp brain: raids, wars and tribute always need your yes, even on Run it" },
    { "campAskHours", "Camp brain: hours an idea waits for your answer", { 6, 12, 24, 48 } },
    { "campLaterHours", "Camp brain: hours before \"later\" comes back", { 2, 6, 12 } },
    { "campAskCooldown", "Camp brain: hours before a turned-down idea comes up again", { 24, 48, 96 } },
    { "campOverruleTrust", "Camp brain: trust lost when you turn down someone's idea", { 0, 1, 3, 6 } },
    { "campIgnoreTrust", "Camp brain: trust lost when you leave an idea unanswered", { 0, 1, 2 } },
    { "campYesTrust", "Camp brain: trust gained when you go with someone's idea", { 0, 1, 2 } },
    { "campReports", "Camp brain: most letters a day about what the camp did and learned", { 0, 2, 4, 8 } },
}, "Your camp and base")
local function num(k) return K.num(BR.YOU_DEFAULTS, k) end
local function set(k) return K.set(BR.YOU_DEFAULTS, k) end
BR.youStats = BR.youStats or { ticks = 0, asks = 0, yes = 0, no = 0, later = 0, ignored = 0, went = 0, refused = 0, reports = 0, learned = 0 }
local ST = BR.youStats

----------------------------------------------------------------------------------------------------------------
-- saved state + the dial
----------------------------------------------------------------------------------------------------------------
function BR.youData()
    local d = K.bucket("brainYou")
    for _, k in ipairs({ "rec", "asks", "cool", "said" }) do if type(d[k]) ~= "table" then d[k] = {} end end
    if d.dial == nil then d.dial = 1 end -- Advisor (Joe's pick)
    return d
end
function BR.youDial() return math.floor(tonumber(BR.youData().dial) or 1) end
function BR.youSetDial(level)
    level = math.floor(tonumber(level) or 1)
    if level < 0 then level = 0 elseif level > 2 then level = 2 end
    BR.youData().dial = level
    return level
end
BR.DIAL_WORDS = { [0] = "Off", [1] = "Advisor", [2] = "Run it" }

----------------------------------------------------------------------------------------------------------------
-- the camp record (a group, id "you")
----------------------------------------------------------------------------------------------------------------
function BR.isYou(b) return type(b) == "table" and b.isCamp == true end
function BR.youRec()
    local d = BR.youData()
    local cb = d.rec
    cb.id, cb.name, cb.isCamp, cb.status = "you", "your camp", true, "active"
    cb.dir = type(cb.dir) == "table" and cb.dir or {}
    cb.dir.creed, cb.dir.rule = "camp", "vote" -- no creed: the members' natures set the mind (everyone's voice counts)
    cb.dir.goals = type(cb.dir.goals) == "table" and cb.dir.goals or {}
    cb.stage = cb.stage or "camp"
    cb.morale = tonumber(cb.morale) or 50
    return cb
end
local function peopleOf(player)
    local w = W()
    if w and fn(w, "people") then local ok, list = pcall(w.people, player); if ok and type(list) == "table" then return list end end
    return {}
end
-- food days in the Food store (Jeem), summed over your bases; nil = can't tell
local function foodDays(player, n)
    if not (fn(ALifeCamp, "bases") and fn(ALifeCampVote, "foodDays")) then return nil end
    local days = nil
    for _, b in ipairs(ALifeCamp.bases(player)) do
        local ok, v = pcall(ALifeCampVote.foodDays, b, n)
        if ok and tonumber(v) then days = (days or 0) + v end
    end
    return days
end
function BR.youRefresh(player)
    local cb = BR.youRec()
    local x, y = BR.youXY()
    cb.x, cb.y = x, y
    local list = peopleOf(player)
    cb.crewN = #list
    cb.roster = {}
    for i, uid in ipairs(list) do cb.roster[i] = { u = uid } end
    local days = foodDays(player, math.max(1, #list))
    if days ~= nil then cb.food = days * math.max(1, #list); cb.foodKnown = true
    elseif not cb.foodKnown then cb.food = 4 * math.max(1, #list) end -- can't count yet: nobody panics
    -- goods by kind from the trading post (real items, only while its square is loaded; else the last count)
    local t = T()
    if fn(t, "postKinds") then
        local ok, kinds, loaded = pcall(t.postKinds)
        if ok and loaded and type(kinds) == "table" then
            cb.goods = { food = kinds.food or 0, water = kinds.water or 0, meds = kinds.meds or 0, ammo = kinds.ammo or 0, tools = kinds.tools or 0, materials = kinds.materials or 0 }
        end
    end
    cb.goods = type(cb.goods) == "table" and cb.goods or {}
    return cb
end

----------------------------------------------------------------------------------------------------------------
-- the brain's helpers, taught about the camp (wraps: NPC groups pass straight through)
----------------------------------------------------------------------------------------------------------------
BR.YOU_TOOLS = { tradeRun = true, scoutRun = true, envoy = true, warParty = true } -- no outposts, recruiting, nomad moves
BR.YOU_MANAGERS = { economy = true, defense = true, scouting = true, military = true }
-- how hard the camp is: ALifeKingmaker (your people x armed x fed), else the NPC formula on the record
local function youStr(cb)
    if fn(ALifeKingmaker, "mine") then
        local ok, s = pcall(ALifeKingmaker.mine, K.player())
        if ok and tonumber(s) and s > 0 then return s end
    end
    if fn(M, "nbStrength") then local ok, s = pcall(M.nbStrength, cb); if ok and tonumber(s) then return s end end
    return math.max(1, tonumber(cb.crewN) or 1)
end
-- people at camp and where each stands (away on a run / mission, hurt). Never stamped (the Work tab is their job)
local function youPeople(cb)
    local out = {}
    local runs = fn(T(), "store") and T().store().runs or {}
    for _, uid in ipairs(peopleOf(K.player())) do
        local r = K.rec(uid)
        if r and r.lifecycle ~= "dead" then
            local m = type(r.memory) == "table" and r.memory or {}
            local p = { uid = tostring(uid), r = r, leader = false, loaded = false, dormant = true, camp = true, job0 = nil }
            if m.alcpRun ~= nil then p.away = BR.jobOfRun(runs[m.alcpRun]); p.run = m.alcpRun
            elseif m.jimmyMission ~= nil then p.away = "economy"
            elseif fn(M, "lvIsAway") and M.lvIsAway(uid) then p.away = "trade" end
            if not p.away then
                local sh = K.shell(uid)
                local hp = nil
                if sh then pcall(function() hp = sh:getHealth() end) end
                if tonumber(hp) and hp * 100 < BR.num("brainHurtPct") then p.hurt = true end
            end
            out[#out + 1] = p
        end
    end
    table.sort(out, function(a, c) return a.uid < c.uid end)
    return out, 0
end
-- how a group stands with the camp: their standing with you (rep 0..100) as a tie (-100..100)
local function youTie(o) return ((tonumber(o and o.rep) or 50) - 50) * 2 end

-- "we" words for a letter (the brain's events are written about NPC groups: "They raided Ridge")
BR.YOU_SWAPS = {
    { "They've made up their minds to ", "Some of our people want to " },
    { "They did what they set out to: ", "We did what we set out to: " },
    { " %- they ", " ~THEYX~ " },
    { "^They're ", "We're " }, { "^They've ", "We've " }, { "^They ", "We " }, { "^Their ", "Our " },
    { "^Armed, they ", "Armed, we " }, { " they ", " we " }, { " their ", " our " }, { " them$", " us" }, { " them ", " us " },
    { " ~THEYX~ ", " - they " },
}
function BR.youWords(text)
    local s = tostring(text or "")
    for _, p in ipairs(BR.YOU_SWAPS) do s = string.gsub(s, p[1], (string.gsub(p[2], "%%", "%%%%"))) end
    return s
end
function BR.youReport(text, kind, bad)
    if text == nil or text == "" then return false end
    local d = BR.youData()
    local day = K.day()
    if d.repDay ~= day then d.repDay, d.repN = day, 0 end
    local line = BR.youWords(text)
    d.said[#d.said + 1] = { h = hours(), t = line }
    while #d.said > 12 do table.remove(d.said, 1) end
    if (tonumber(d.repN) or 0) >= num("campReports") then return false end
    d.repN = (tonumber(d.repN) or 0) + 1
    ST.reports = ST.reports + 1
    BR.campLetter(line .. ".", bad == true or kind == "war") -- MP: the whole camp (co-op: everyone with a base)
    return true
end

----------------------------------------------------------------------------------------------------------------
-- who speaks for an idea (their nature fits it), who objects, and what it costs to turn them down
----------------------------------------------------------------------------------------------------------------
BR.YOU_LEANS = {
    war = { brave = 1, proud = 1, mean = 1, unhinged = 0.6, volatile = 0.4 },
    trade = { greedy = 1, calm = 0.6, kind = 0.3 },
    scout = { paranoid = 1, brave = 0.6, disciplined = 0.4 },
    peace = { kind = 1, fearful = 0.8, calm = 0.5 },
    ally = { kind = 0.8, calm = 0.6, loyal = 0.6 },
    tribute = { proud = 1, mean = 0.8, greedy = 0.8 },
}
BR.YOU_LINES = {
    war = { brave = "%s is weaker than they look. Give me a few people and we hit them.", proud = "%s thinks we're soft. Time we showed them we're not.",
        mean = "%s is sitting on what we need. Let's go take it.", default = "I think we should hit %s." },
    trade = { greedy = "We've got more %s than we can use, and %s would pay for it.", default = "We could take some %s over to %s and trade." },
    scout = { paranoid = "I don't like not knowing what %s is up to. Let me go have a look.", default = "Someone should go and take a look at %s." },
    peace = { kind = "This trouble with %s is bleeding us. Let me go and talk to them.", fearful = "We can't keep this up with %s. We need to make peace.",
        default = "Maybe it's time we made peace with %s." },
    ally = { default = "%s could stand with us. Let me go and ask them." },
    tribute = { proud = "%s should be paying us to leave them be.", default = "%s is weak. We could make them pay." },
}
BR.YOU_OBJECT = {
    war = { { trait = "kind", line = "This is going to get people killed. Ours." }, { trait = "fearful", line = "We pick this fight, we don't get to pick how it ends." } },
    trade = { { trait = "paranoid", line = "Sending people out with our stuff? Somebody's going to take it off them." } },
    tribute = { { trait = "kind", line = "Squeezing people who've got nothing. That's not who we are." } },
}
local function actOf(x)
    if x.tool == "warParty" then return "war" end
    if x.tool == "tradeRun" then return "trade" end
    if x.tool == "scoutRun" then return "scout" end
    if x.tool == "envoy" then local g = type(x.target) == "table" and x.target.goal or "peace"; return (g == "tribute" or g == "ally") and g or "peace" end
    return "scout"
end
local function homeUids(cb)
    local out = {}
    for _, p in ipairs((youPeople(cb))) do if not p.away and not p.hurt then out[#out + 1] = p.uid end end
    return out
end
local function lean(uid, act)
    local l = K.lens(uid)
    local v, top, tv = 0, nil, 0
    for trait, wgt in pairs(BR.YOU_LEANS[act] or {}) do
        local x = (tonumber(l[trait]) or 0) * wgt
        v = v + x
        if x > tv or (x == tv and top ~= nil and trait < top) then top, tv = trait, x end
    end
    return v, top
end
function BR.youSpeaker(cb, act, skip)
    local best, bv, btrait = nil, -1, nil
    for _, uid in ipairs(homeUids(cb)) do
        if uid ~= skip then
            local v, trait = lean(uid, act)
            if v > bv or (v == bv and best ~= nil and uid < best) then best, bv, btrait = uid, v, trait end
        end
    end
    return best, btrait
end
local function objector(cb, act, by, sit)
    for _, uid in ipairs(homeUids(cb)) do
        if uid ~= by then
            local l = K.lens(uid)
            if act == "war" and sit and (tonumber(sit.food) or 9) < 2 then return uid, "We're starving and you want a raid?" end
            for _, o in ipairs(BR.YOU_OBJECT[act] or {}) do if (tonumber(l[o.trait]) or 0) >= 0.25 then return uid, o.line end end
        end
    end
    return nil
end
local function nameOf(uid) return (uid and K.first(uid)) or "Someone" end
local function placeOf(id) if id == "you" then return "our place" end local o = BR.base(id); return o and tostring(o.name) or "them" end
local function trust(uid, player, d, why) if uid and d ~= 0 then K.opinion(uid, player, d, why) end end
-- Brain 2 (ALifeBrainCommandYou: orders, lieutenants) reads these
BR.youHomeUids, BR.youStrOf, BR.youActOf, BR.youNameOf, BR.youPeopleOf, BR.youPlaceOf = homeUids, youStr, actOf, nameOf, youPeople, placeOf
-- the cost of turning someone down: proud and brave ones mind more
function BR.youOverruleCost(uid)
    local l = K.lens(uid)
    local base = num("campOverruleTrust")
    if base <= 0 then return 0 end
    return math.floor(base * (1 + (tonumber(l.proud) or 0) + (tonumber(l.brave) or 0) * 0.5) + 0.5)
end

----------------------------------------------------------------------------------------------------------------
-- asking you (priority cards: yes / no / later)
----------------------------------------------------------------------------------------------------------------
function BR.youNeedsAsk(x)
    local dial = BR.youDial()
    local act = actOf(x)
    if act == "war" or act == "tribute" then return set("campBrainWarAsk") ~= false or dial < 2 end
    return dial < 2
end
local function askKey(x)
    local to = type(x.target) == "table" and x.target.to or nil
    return tostring(x.tool) .. ":" .. tostring(to) .. ":" .. tostring(type(x.target) == "table" and x.target.goal or "")
end
local function copy(t) if type(t) ~= "table" then return t end local o = {}; for k, v in pairs(t) do if type(v) ~= "function" and type(v) ~= "table" then o[k] = v end end; return o end
local function pending()
    local n = 0
    for _ in pairs(BR.youData().asks) do n = n + 1 end
    return n
end
function BR.youWhy(cb, x, sit)
    local act = actOf(x)
    local to = type(x.target) == "table" and x.target.to or nil
    local k = to and BR.belief(cb, to, hours()) or nil
    local mine = math.max(0.1, youStr(cb))
    local parts = {}
    if act == "war" then
        if k and tonumber(k.str) then parts[#parts + 1] = (k.str < mine * 0.6 and "They look a lot weaker than us" or (k.str < mine and "They look weaker than us" or "It won't be easy")) end
        local goal = type(x.target) == "table" and x.target.goal or "raid"
        parts[#parts + 1] = ({ raid = "a raid: grab what we can carry and get out", assault = "an all-out attack", siege = "a siege: sit outside till they give in" })[goal] or "a raid"
        local g = BR.grudgeV(cb, to, hours())
        if g >= 20 then local gr = BR.of(cb).grudges[tostring(to)]; parts[#parts + 1] = "they " .. tostring(type(gr) == "table" and gr.why or "have it coming") end
    elseif act == "trade" then
        local t = type(x.target) == "table" and x.target or {}
        parts[#parts + 1] = "Take " .. tostring((T() and T().KIND_WORDS[t.give]) or t.give or "goods") .. ", bring back " .. tostring((T() and T().KIND_WORDS[t.want]) or t.want or "what we need")
    elseif act == "scout" then
        parts[#parts + 1] = k and "What we know about them is getting old" or "We don't really know what they've got"
    elseif act == "peace" then parts[#parts + 1] = "This fight is costing us"
    elseif act == "tribute" then parts[#parts + 1] = "They're weak enough to pay"
    elseif act == "ally" then parts[#parts + 1] = "We could use friends" end
    local n = math.max(1, math.floor(tonumber(x.n) or 1))
    if act ~= "trade" then parts[#parts + 1] = n == 1 and "one of us goes" or (n .. " of us go") end
    return table.concat(parts, ". ") .. "."
end
function BR.youAsk(cb, x, sit, h)
    local d = BR.youData()
    local key = askKey(x)
    if (tonumber(d.cool[key]) or -1e9) > h then return false end
    for _, a in pairs(d.asks) do if a.key == key then return false end end
    if pending() >= 2 then return false end
    local act = actOf(x)
    local by, trait = BR.youSpeaker(cb, act)
    if by == nil then return false end -- nobody home to bring it up
    local lines = BR.YOU_LINES[act] or {}
    local fmt = (trait and lines[trait]) or lines.default or "%s"
    local to = type(x.target) == "table" and x.target.to or nil
    local line
    if act == "trade" then
        local t = x.target or {}
        line = string.format(fmt, tostring((T() and T().KIND_WORDS[t.give]) or t.give or "goods"), placeOf(to))
        if trait ~= "greedy" then line = string.format(lines.default, tostring((T() and T().KIND_WORDS[t.give]) or t.give or "goods"), placeOf(to)) end
    else line = string.format(fmt, placeOf(to)) end
    local ob, obLine = objector(cb, act, by, sit)
    local id = "ask" .. tostring(BR.hash(key .. tostring(h)) % 1000000)
    local a = { id = id, key = key, tool = x.tool, job = x.job, n = math.max(1, math.floor(tonumber(x.n) or 1)), target = copy(x.target), by = by,
        line = line, why = BR.youWhy(cb, x, sit), ob = ob, obLine = obLine, h = h, untilH = h + num("campAskHours"), showH = h, laters = 0, act = act,
        planId = type(BR.of(cb).plan) == "table" and BR.of(cb).plan.id or nil }
    d.asks[id] = a
    ST.asks = ST.asks + 1
    BR.youShow(a)
    return true
end
local function answerFn(id, what) return function() local ok, err = pcall(BR.youAnswer, id, what, K.player()); if not ok then log("answer failed: " .. tostring(err)) end end end
function BR.youShow(a)
    a.shown = true
    local text = nameOf(a.by) .. ": \"" .. tostring(a.line) .. "\" <LINE> <LINE> " .. tostring(a.why)
    if a.ob then text = text .. " <LINE> <LINE> " .. nameOf(a.ob) .. " isn't happy about it: \"" .. tostring(a.obLine) .. "\"" end
    local titles = { war = " wants to fight", trade = " wants to trade", scout = " wants to scout", peace = " wants to make peace", ally = " wants to find allies", tribute = " wants to make them pay" }
    return BR.campCard({ id = "brainAsk:" .. a.id, title = nameOf(a.by) .. (titles[a.act] or " has an idea"), default = 3, text = text,
        choices = { { label = "Do it", fn = answerFn(a.id, "yes") }, { label = "No", fn = answerFn(a.id, "no") }, { label = "Later", fn = answerFn(a.id, "later") } } }, K.player())
end
function BR.youAnswer(id, what, player)
    local d = BR.youData()
    local a = d.asks[tostring(id or "")]
    if type(a) ~= "table" then return false, "gone" end
    local h = hours()
    player = player or K.player()
    if what == "later" then
        a.laters = (tonumber(a.laters) or 0) + 1
        if a.laters > 2 then return BR.youAnswer(id, "ignored", player) end
        a.shown = false
        a.showH = h + num("campLaterHours")
        a.untilH = a.showH + num("campAskHours")
        ST.later = ST.later + 1
        return true, "later"
    end
    d.asks[a.id] = nil
    if what == "yes" then
        ST.yes = ST.yes + 1
        local ok, msg = BR.youDo(a, player)
        if ok then
            trust(a.by, player, num("campYesTrust"), "You went with their idea")
            if a.ob then trust(a.ob, player, -math.max(1, math.floor(BR.youOverruleCost(a.ob) / 2)), "You went ahead over their objection") end
        end
        if msg then BR.campLetter(msg, not ok) end -- MP: the whole camp hears what was decided
        return ok, msg
    end
    d.cool[a.key] = h + num("campAskCooldown")
    if what == "no" then
        ST.no = ST.no + 1
        trust(a.by, player, -BR.youOverruleCost(a.by), "You turned down their idea")
        K.say(a.by, ({ war = "Fine. Hope you're right about them.", trade = "Your call. It's just sitting there.", scout = "Then we're guessing.", peace = "Then we keep bleeding.",
            ally = "We'll manage alone, then.", tribute = "They'll think we're soft." })[a.act] or "Your call.")
        return true, "no"
    end
    ST.ignored = ST.ignored + 1
    trust(a.by, player, -num("campIgnoreTrust"), "You never answered them")
    return true, "ignored"
end
-- every hour: show what waits, expire what nobody answered
function BR.youAsksTick(player, h)
    local d = BR.youData()
    for _, id in ipairs(BR.sortedKeys(d.asks)) do
        local a = d.asks[id]
        if type(a) ~= "table" then d.asks[id] = nil
        elseif h >= (tonumber(a.untilH) or 0) then BR.youAnswer(id, "ignored", player)
        elseif not a.shown and h >= (tonumber(a.showH) or 0) then BR.youShow(a) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- doing it: who goes (they may say no), then the real tool
----------------------------------------------------------------------------------------------------------------
-- willing people at home, the one whose idea it was first. Returns uids, refusal words
function BR.youCrew(want, by, player)
    local t = T()
    local cands = fn(t, "ownCandidates") and t.ownCandidates(player) or {}
    local crew, said = {}, {}
    table.sort(cands, function(a, c)
        if (a.uid == by) ~= (c.uid == by) then return a.uid == by end
        if (a.why == nil) ~= (c.why == nil) then return a.why == nil end
        return tostring(a.uid) < tostring(c.uid)
    end)
    for _, c in ipairs(cands) do
        if #crew >= want then break end
        if c.why == nil then crew[#crew + 1] = c.uid
        elseif #said < 2 then said[#said + 1] = string.gsub((t.REFUSE and t.REFUSE[c.why]) or "%1 won't go.", "%%1", tostring(c.name)); ST.refused = ST.refused + 1 end
    end
    return crew, said
end
local origCall = nil
function BR.youCall(id, cb, people, target, opts, player)
    player = player or K.player()
    if not BR.YOU_TOOLS[id] then return false, "not_for_camp" end
    local tool = BR.tools[id]
    if tool == nil then return false, "no_tool" end
    if id == "tradeRun" then
        local t = T()
        if type(target) ~= "table" or not fn(t, "ownSend") then return false, "no_engine" end
        BR.youSending = true
        local okC, ok, msg = pcall(t.ownSend, player, target.to, target.give, target.want)
        BR.youSending = nil
        if not okC then return false, "error" end
        if ok then BR.stats.tools = BR.stats.tools + 1; ST.went = ST.went + 1 end
        if ok and not (opts and opts.by) then BR.youReport((string.gsub(tostring(msg), "%.$", "")), "brain") end -- Run it: told after
        return ok == true, msg
    end
    -- peace / allies by radio when they're in range (nobody walks)
    if id == "envoy" and type(target) == "table" and target.goal ~= "tribute" then
        local o = BR.base(target.to)
        if o and tonumber(o.x) and tonumber(cb.x) and d2(o.x, o.y, cb.x, cb.y) <= BR.num("knowRadioTiles") ^ 2 then
            BR.envoyArrive(cb, target.to, target.goal, hours(), nil)
            return true, "radio"
        end
    end
    local minP, maxP = tonumber(tool.minPeople) or 1, tonumber(tool.maxPeople) or 1
    local want = clamp(math.floor(tonumber(opts and opts.n) or #(people or {})), minP, maxP)
    if fn(BR, "youOrder") and BR.youOrder("neverAlone") == true and want < 2 then want = 2 end -- your order: nobody goes out alone
    local crew, said = BR.youCrew(want, opts and opts.by, player)
    if #crew < math.max(tonumber(tool.minPeople) or 1, (fn(BR, "youOrder") and BR.youOrder("neverAlone") == true) and 2 or 1) then return false, (#said > 0 and table.concat(said, " ") or "Nobody at home to send.") end
    local ok, a = origCall(id, cb, crew, target, opts)
    if ok then ST.went = ST.went + 1 end
    local words = (#said > 0) and (" " .. table.concat(said, " ")) or ""
    if ok then return true, nil end
    return false, "They couldn't set out." .. words
end
function BR.youDo(a, player)
    local cb = BR.youRefresh(player)
    local to = type(a.target) == "table" and a.target.to or nil
    if to ~= nil and to ~= "you" and BR.base(to) == nil then return false, "Too late: " .. "that group is gone." end
    local ok, msg = BR.youCall(a.tool, cb, {}, a.target, { n = a.n, by = a.by }, player)
    if ok and msg == nil then
        local names = { war = "set out to fight", trade = "set out to trade", scout = "set out to have a look at", peace = "set out to talk peace with",
            ally = "set out to talk to", tribute = "set out to make them pay:" }
        msg = nameOf(a.by) .. "'s idea: our people " .. (names[a.act] or "set out for") .. " " .. placeOf(to) .. "."
    elseif ok and msg == "radio" then msg = nameOf(a.by) .. " got on the radio to " .. placeOf(to) .. "." end
    return ok, msg
end

----------------------------------------------------------------------------------------------------------------
-- the camp's own managers (trade = your caravans; diplomacy = envoys), then the shared ones that fit a camp
----------------------------------------------------------------------------------------------------------------
local function campTrade(cb, sit, h, s, bids)
    local t = T()
    local o = s.orders or {}
    if o.noTrade or not fn(t, "ownTargets") or not fn(t, "postKinds") then return end
    if (tonumber(o.keepFoodDays) or 0) > 0 and sit.food < o.keepFoodDays and s.stance ~= "trade" then return end
    if math.floor(h / 24) - (tonumber(s.tradeDay) or -99) < (s.stance == "trade" and 1 or 3) then return end
    for _, r in ipairs(fn(t, "runsOf") and t.runsOf("you") or {}) do if r.kind == "own" then return end end -- one caravan out at a time
    local kinds, loaded = t.postKinds()
    if not loaded then return end
    local give, gn = nil, 0
    for _, k in ipairs({ "food", "meds", "ammo", "tools", "materials" }) do
        local n = tonumber(kinds[k]) or 0
        local keep = (k == "food" and sit.food < 6) and 1e9 or 6
        if n > keep and n > gn then give, gn = k, n end
    end
    if give == nil then return end
    local want = nil
    for _, k in ipairs(type(s.want) == "table" and s.want or {}) do if k ~= give then want = k; break end end
    if want == nil then return end
    local best, bs = nil, -1e9
    for _, g in ipairs(t.ownTargets(K.player())) do
        local k = BR.belief(cb, g.id, h)
        local ob = BR.base(g.id)
        if not g.embargo and ob and (tonumber(ob.rep) or 50) >= 45 and not (k and k.hostile) then
            local sc = (tonumber(g.safe) or 50) - (tonumber(g.hours) or 0) * 2 + (k and 10 or 0) - (BR.mem(cb, "trade:" .. g.id, h).robbed or 0) * 20
            if sc > bs then best, bs = g.id, sc end
        end
    end
    if best == nil then return end
    s.tradeDay = math.floor(h / 24)
    bids[#bids + 1] = { job = "trade", n = 2, value = 1.5 + (s.stance == "trade" and 1.5 or 0), tool = "tradeRun", target = { to = best, give = give, want = want }, key = "trade" }
end
local function campDiplomacy(cb, sit, h, s, bids)
    if s.diploDay == math.floor(h / 24) then return end
    s.diploDay = math.floor(h / 24)
    if BR.flag("brainTribute") and s.stance == "dominate" then
        for _, p in ipairs(sit.prey) do
            if p.sure and p.ratio < 0.5 and p.id ~= "you" and not (type(s.plan) == "table" and s.plan.key == "tribute") then
                bids[#bids + 1] = { job = "scout", n = 1, value = 2.5, tool = "envoy", target = { to = p.id, goal = "tribute" }, key = "envoy:tribute" }
                break
            end
        end
    end
    for _, o in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if (tonumber(o.rep) or 50) <= 25 and BR.belief(cb, o.id, h) then
            local m = BR.mem(cb, "raid:" .. o.id, h)
            if s.pressure >= 50 or (m.losses or 0) >= 2 then bids[#bids + 1] = { job = "scout", n = 1, value = 2, tool = "envoy", target = { to = o.id, goal = "peace" }, key = "envoy:peace" }; break end
        end
    end
end
function BR.youManage(cb, h)
    local s = BR.of(cb)
    if s.stance == nil then BR.think(cb, h, "day") end
    local sit = BR.situation(cb, h)
    local bids = {}
    if BR.flag("brainPlans") and fn(BR, "planStep") then
        local ok, err = pcall(BR.planStep, cb, sit, h, bids, true)
        if not ok then BR.log("camp plan failed: " .. tostring(err)) end
    end
    for _, mg in ipairs(BR.managers) do
        if BR.YOU_MANAGERS[mg.name] then
            local ok, err = pcall(mg.f, cb, sit, h, s, bids, true)
            if not ok then BR.log("camp manager " .. mg.name .. " failed: " .. tostring(err)) end
        end
    end
    pcall(campTrade, cb, sit, h, s, bids)
    pcall(campDiplomacy, cb, sit, h, s, bids)
    if fn(BR, "youOrderBids") then pcall(BR.youOrderBids, cb, sit, h, s, bids) end
    -- away jobs: ask you (dial / war rule), or go
    local people = {}
    for _, x in ipairs(bids) do
        if x.job then
            if x.tool and BR.AWAY[x.job] then
                if BR.YOU_TOOLS[x.tool] then
                    -- Brain 2: your standing orders / lieutenants first (drop = an order forbids it, go = an order or a lieutenant allows it)
                    local v = nil
                    if fn(BR, "youVerdict") then local okV, r = pcall(BR.youVerdict, cb, x, sit, h); if okV then v = r end end
                    if v == "go" and not ((actOf(x) == "war" or actOf(x) == "tribute") and set("campBrainWarAsk") ~= false) then people[#people + 1] = x
                    elseif v ~= "drop" then
                        if BR.youNeedsAsk(x) then pcall(BR.youAsk, cb, x, sit, h) else people[#people + 1] = x end
                    end
                end
            else people[#people + 1] = x end
        end
    end
    BR.allocate(cb, h, people)
    for _, x in ipairs(people) do if x.started and x.onStart then pcall(x.onStart) end end
    s.sit = { threat = sit.threat, threatBy = sit.threatBy, food = sit.food, prey = sit.prey[1] and sit.prey[1].id or nil }
    if fn(BR, "wordsAfter") then pcall(BR.wordsAfter, cb, h) end
end

----------------------------------------------------------------------------------------------------------------
-- what the Work tab reads: the allocator's home-job counts
----------------------------------------------------------------------------------------------------------------
-- { guard, economy, build, idle, total, econFrac } or nil when the brain doesn't run the camp
function BR.youTargets()
    if not BR.on() or BR.youDial() < 1 then return nil end
    local s = BR.youRec().brain
    local a = type(s) == "table" and s.alloc or nil
    if type(a) ~= "table" or not tonumber(a.total) then return nil end
    return a
end
BR.YOU_LINE = {
    survive = "We're just trying to get through this: food first.", secure = "We're keeping our heads down and people on watch.",
    grow = "Things are steady. We're building up.", trade = "We've got more than we need of some things. Time to trade.",
    dominate = "Nobody round here is stronger than us.", revenge = "Some of us want to get even.", expand = "We're crowded.",
}
function BR.youLine()
    if BR.youDial() < 1 then return nil end
    local s = BR.youRec().brain
    if type(s) ~= "table" or s.stance == nil then return nil end
    local line = BR.YOU_LINE[s.stance] or BR.YOU_LINE.grow
    if s.stance == "revenge" then local to = BR.topGrudge(BR.youRec(), hours()); if to and BR.base(to) then line = "Some of us want to get even with " .. tostring(BR.base(to).name) .. "." end end
    if type(s.plan) == "table" and fn(BR, "planWords") then local w = BR.planWords(BR.youRec(), s.plan); if w then line = line .. " Talk is about how to " .. string.gsub(w, "the newcomer", "us") .. "." end end
    return line
end

----------------------------------------------------------------------------------------------------------------
-- what we know (the page): beliefs in words, no numbers on people (rule 6)
----------------------------------------------------------------------------------------------------------------
local function strWord(ratio)
    if ratio < 0.6 then return "much weaker than us" elseif ratio < 0.9 then return "weaker than us" elseif ratio < 1.2 then return "about as strong as us"
    elseif ratio < 2 then return "stronger than us" end
    return "much stronger than us"
end
local function foodWord(f) f = tonumber(f); if f == nil then return nil end; if f >= 7 then return "well fed" elseif f >= 3 then return "eating" elseif f >= 1 then return "going hungry" end return "starving" end
local SRC = { scout = "our scout saw it", fight = "we fought them", trade = "our traders were there", sight = "they're close enough to watch", visitors = "their traders came by",
    radio = "heard it on the radio", rumour = "a rumour", word = "word gets around", ally = "friends told us", second = "a trader told us", lookout = "our lookouts", cheat = "a guess", caught_scout = "our scout, before they ran" }
function BR.youKnowView(player)
    local out = {}
    local d = BR.youData()
    local cb = BR.youRec()
    local h = hours()
    local mine = math.max(0.1, youStr(cb))
    out[1] = { k = "head", dial = BR.youDial(), dialWord = BR.DIAL_WORDS[BR.youDial()] or "Advisor", line = BR.youLine() or "", asks = pending(),
        warAsk = set("campBrainWarAsk") ~= false }
    for _, k in ipairs(type(cb.brain) == "table" and BR.known(cb, h) or {}) do
        if k.id ~= "you" then
            local o = BR.base(k.id)
            local age = math.floor(math.max(0, h - (tonumber(k.h) or h)) / 24)
            local words = {}
            if tonumber(k.str) then words[#words + 1] = strWord(k.str / mine) end
            local fw = foodWord(k.food)
            if fw then words[#words + 1] = fw end
            if k.hostile then words[#words + 1] = "hostile" end
            if (tonumber(k.walls) or 0) >= 1 or k.stage == "fortified" then words[#words + 1] = "dug in" end
            local g = BR.grudgeV(cb, k.id, h)
            out[#out + 1] = { k = "g", id = k.id, name = tostring(k.name or (o and o.name) or "a group"), what = table.concat(words, ", "),
                src = SRC[tostring(k.src)] or "heard it somewhere", sure = k.c >= 0.7 and "sure" or (k.c >= 0.4 and "fairly sure" or "not sure"),
                age = age == 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago")), dist = math.floor(k.dist or 0), grudge = g >= 20 or nil }
        end
    end
    for i = #d.said, math.max(1, #d.said - 4), -1 do out[#out + 1] = { k = "said", t = d.said[i].t } end
    for _, id in ipairs(BR.sortedKeys(d.asks)) do local a = d.asks[id]; out[#out + 1] = { k = "ask", t = nameOf(a.by) .. ": " .. tostring(a.line) } end
    return out
end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "view") then ALifeRemote.view("byKnow", BR.youKnowView, {}) end
M.byDial = function(level, player) local v = BR.youSetDial(level); return v end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "expose") then ALifeRemote.expose("byDial", 1, 2) end

----------------------------------------------------------------------------------------------------------------
-- knowledge sources for the camp (fog of war for you too)
----------------------------------------------------------------------------------------------------------------
-- your traders reached a group (they see the place; the group sees your people): T.onLeg, run.from == "you"
local function onLeg(run, leg, gave, got, why)
    if not BR.on() or type(run) ~= "table" or type(leg) ~= "table" then return end
    local cb = BR.youRec()
    if run.from == "you" and not run.brain and leg.to ~= "you" then
        local o = BR.base(leg.to)
        if o then
            local t = BR.truth(o.id)
            if t then BR.learn(cb, o.id, t, 0.7, "trade", hours()); ST.learned = ST.learned + 1 end
            BR.remember(cb, "trade:" .. o.id, "runs", 1)
            if why == "robbed" then BR.remember(cb, "trade:" .. o.id, "robbed", 1); BR.grudge(cb, o.id, 15, "robbed our traders") end
        end
    elseif leg.to == "you" and run.from ~= "you" then
        -- their traders at your post: you see them, hear their news
        local o = BR.base(run.from)
        local t = o and BR.truth(o.id) or nil
        if t then BR.learn(cb, o.id, { x = t.x, y = t.y, crew = t.crew, mood = t.mood, wealth = t.wealth, name = t.name, hostile = t.hostile }, 0.5, "visitors", hours()); ST.learned = ST.learned + 1 end
    end
end

----------------------------------------------------------------------------------------------------------------
-- install: the wraps (each one passes NPC groups straight through)
----------------------------------------------------------------------------------------------------------------
local function install()
    origCall = origCall or BR.call
    BR.home = function(id) if id == "you" then return BR.youRec() end return BR.base(id) end
    K.wrap(BR, "str", "BrainYouStr", function(orig) return function(b, ...) if BR.isYou(b) then return youStr(b) end return orig(b, ...) end end)
    K.wrap(BR, "tie", "BrainYouTie", function(orig) return function(b, o, ...)
        if BR.isYou(b) then return youTie(o) end
        if BR.isYou(o) then return youTie(b) end
        return orig(b, o, ...)
    end end)
    K.wrap(BR, "people", "BrainYouPeople", function(orig) return function(b, ...) if BR.isYou(b) then return youPeople(b) end return orig(b, ...) end end)
    K.wrap(BR, "runs", "BrainYouRuns", function(orig) return function(b, ...) if BR.isYou(b) then return BR.on() and BR.youDial() >= 1 end return orig(b, ...) end end)
    K.wrap(BR, "event", "BrainYouEvent", function(orig) return function(b, text, kind, ...) if BR.isYou(b) then return BR.youReport(text, kind) end return orig(b, text, kind, ...) end end)
    -- (the camp never falls back to the NPC path: an error here is logged and the camp skips this round)
    K.wrap(BR, "manage", "BrainYouManage", function(orig) return function(b, h, far, ...)
        if BR.isYou(b) then local ok, err = pcall(BR.youManage, b, h); if not ok then log("manage failed: " .. tostring(err)) end; return nil end
        return orig(b, h, far, ...)
    end end)
    K.wrap(BR, "call", "BrainYouCall", function(orig)
        origCall = orig
        return function(id, b, people, target, opts, ...)
            if BR.isYou(b) then
                local ok, a, c = pcall(BR.youCall, id, b, people, target, opts)
                if not ok then log("call " .. tostring(id) .. " failed: " .. tostring(a)); return false, "error" end
                return a, c
            end
            return orig(id, b, people, target, opts, ...)
        end
    end)
    -- a camp war party / scout / envoy carries food from the trading post (not an NPC stash)
    K.wrap(BR, "packFood", "BrainYouPack", function(orig) return function(b, personDays, ...)
        if not BR.isYou(b) then return orig(b, personDays, ...) end
        local t = T()
        if not fn(t, "postTake") or (tonumber(personDays) or 0) <= 0 then return {} end
        local items = t.postTake("food", math.ceil(personDays / ((M.nbCfg and M.nbCfg.foodPerItem) or 0.25)) * 2)
        return items or {}
    end end)
    -- what a camp run brings home goes into the trading post (or waits at the gate)
    local t = T()
    if type(t) == "table" then
        K.wrap(t, "putIn", "BrainYouPutIn", function(orig) return function(b, items, ...)
            if not BR.isYou(b) then return orig(b, items, ...) end
            if #(items or {}) == 0 then return 0 end
            if fn(t, "postPut") and t.postPut(items) then return #items end
            local own = t.store().own
            own.pending = type(own.pending) == "table" and own.pending or {}
            for _, x in ipairs(items) do own.pending[#own.pending + 1] = x end
            return #items
        end end)
        if type(t.onLeg) == "table" and not t._brainYouLeg then t._brainYouLeg = true; t.onLeg[#t.onLeg + 1] = function(...) pcall(onLeg, ...) end end
    end
    -- plans and diplomacy ask too: no radio shortcut for the camp (the ask decides; radio is used when you say yes)
    K.wrap(BR, "envoyBid", "BrainYouEnvoyBid", function(orig) return function(b, bids, to, goal, value, ...)
        if not BR.isYou(b) then return orig(b, bids, to, goal, value, ...) end
        for _, r in ipairs(fn(T(), "runsOf") and T().runsOf("you") or {}) do if r.kind == "envoy" then return false end end
        bids[#bids + 1] = { job = "scout", n = 1, value = value or 2, tool = "envoy", target = { to = to, goal = goal }, key = "envoy:" .. tostring(goal) }
        return true
    end end)
    -- what an envoy of yours settles shows in how that group feels about you (their standing with you)
    K.wrap(BR, "envoyArrive", "BrainYouEnvoy", function(orig) return function(b, to, goal, h, run, ...)
        local r = orig(b, to, goal, h, run, ...)
        if BR.isYou(b) then
            local o = BR.base(to)
            local ans = type(b.brain) == "table" and type(b.brain.answers) == "table" and b.brain.answers[to] or nil
            if o and fn(M, "nbRep") then
                if ans == "peace" then pcall(M.nbRep, o, 10, "Your people came to make peace")
                elseif ans == "allied" then pcall(M.nbRep, o, 15, "Your people asked them to stand together")
                elseif ans == "paid" then pcall(M.nbRep, o, -10, "Your people made them pay")
                elseif ans == "refused" and goal == "tribute" then pcall(M.nbRep, o, -5, "Your people demanded payment") end
            end
        end
        return r
    end end)
    -- your war party hit them: they hold it against you (standing), like any raid of yours
    K.wrap(BR, "warArrive", "BrainYouWar", function(orig) return function(run, b, h, ...)
        local r = orig(run, b, h, ...)
        if BR.isYou(b) and run.target ~= "you" and not run.repHit and (run.won ~= nil or (tonumber(run.siegeDays) or 0) >= 1) then
            run.repHit = true
            local o = BR.base(run.target)
            if o and fn(M, "nbRep") then pcall(M.nbRep, o, -20, "Your people attacked them") end
        end
        return r
    end end)
    -- an NPC war party halfway to you: your camp braces (defense manager pulls your runs home, guards up)
    K.wrap(BR, "runHalfway", "BrainYouHalf", function(orig) return function(run, h, ...)
        local was = type(run) == "table" and run.seenHalf
        local r = orig(run, h, ...)
        if type(run) == "table" and run.target == "you" and run.kind == "war" and not was and run.seenHalf and BR.on() then
            local cb = BR.youRec()
            local s = BR.of(cb)
            s.incoming = { by = run.from, untilH = (tonumber(run.arrive) or h) + 24 }
            local o = BR.base(run.from)
            if o then BR.learn(cb, o.id, { x = o.x, y = o.y, hostile = true, name = o.name, str = run.str0 }, 0.7, "lookout", h) end
            BR.interrupt(cb, "warparty", { a = run.from })
        end
        return r
    end end)
    -- camped outside and demanding: the camp holds it against them
    K.wrap(BR, "tributeToYou", "BrainYouTribute", function(orig) return function(b, h, ...)
        local r = orig(b, h, ...)
        if r and type(b) == "table" and BR.on() then
            local cb = BR.youRec()
            BR.grudge(cb, b.id, 15, "came to our place making demands")
            BR.learn(cb, b.id, { x = b.x, y = b.y, hostile = true, name = b.name }, 0.8, "sight", h)
            BR.interrupt(cb, "demand", { a = b.id })
        end
        return r
    end end)
    -- Brain 2 R6: the camp radios allies in range for help (campAskHelp); their fighters walk to your place
    K.wrap(BR, "askHelp", "BrainYouHelp", function(orig) return function(b, ...) if BR.isYou(b) and BR.setting("campAskHelp") == false then return false end return orig(b, ...) end end)
    -- beaten badly by your people: they pay you (never absorbed into a camp record)
    K.wrap(BR, "surrender", "BrainYouSurrender", function(orig) return function(b, o, h, run, ...)
        if not BR.isYou(b) then return orig(b, o, h, run, ...) end
        if type(o) ~= "table" or o.status ~= "active" then return nil end
        if (tonumber(o.crewN) or 0) >= 3 and (tonumber(o.morale) or 50) >= 30 then return nil end
        local s = BR.of(b)
        s.tribute = type(s.tribute) == "table" and s.tribute or {}
        s.tribute[o.id] = { h = h, kind = "food" }
        BR.event(o, "Gave in to the newcomer's people", "war")
        return nil
    end end)
    -- the camp scores stances like any group, minus what a camp can't do (outposts)
    K.wrap(BR, "scoreStances", "BrainYouScores", function(orig) return function(b, sit, h, ...)
        local sc, disc = orig(b, sit, h, ...)
        if BR.isYou(b) and type(sc) == "table" then sc.expand = 0 end
        return sc, disc
    end end)
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)

----------------------------------------------------------------------------------------------------------------
-- the hour: refresh the record, learn, think, manage, ask
----------------------------------------------------------------------------------------------------------------
function BR.youMutterDay(player, h)
    local cb = BR.youRec()
    local s = cb.brain
    if type(s) ~= "table" or s.stance == nil or s.youMutterDay == math.floor(h / 24) then return end
    s.youMutterDay = math.floor(h / 24)
    for _, uid in ipairs(homeUids(cb)) do
        local line = BR.mutter(cb, uid, h)
        if line then K.say(uid, line); return end
    end
end
function BR.youTick(player, h)
    if not BR.on() then return end
    ST.ticks = ST.ticks + 1
    local cb = BR.youRefresh(player)
    if cb.x == nil or (tonumber(cb.crewN) or 0) <= 0 then return end
    local s = BR.of(cb)
    if BR.youDial() < 1 then
        -- Off: the camp still hears things (what we know), but nobody plans or asks
        local day = math.floor(h / 24)
        if s.knowDay ~= day and fn(BR, "knowDay") then s.knowDay = day; pcall(BR.knowDay, cb, h) end
        return
    end
    local ok, err = pcall(BR.step, cb, h, true, nil)
    if not ok then log("step failed: " .. tostring(err)) end
    pcall(BR.youAsksTick, player, h)
    pcall(BR.youMutterDay, player, h)
end
K.hourly(TAG, function(p, h) BR.youTick(p, h) end)

-- your own caravan sent while the camp is scraping by: someone says so (pushback; it still goes)
do
    local t = T()
    if type(t) == "table" then
        K.wrap(t, "ownSend", "BrainYouPushback", function(orig) return function(player, groupId, give, want, ...)
            local ok, msg = orig(player, groupId, give, want, ...)
            if ok and BR.on() and BR.youDial() >= 1 and not BR.youSending then
                local cb = BR.youRec()
                local s = cb.brain
                local tight = type(s) == "table" and (s.stance == "survive" or s.stance == "secure" or type(s.incoming) == "table")
                if tight or (give == "food" and BR.foodDays(cb) < 3) then
                    local uid = homeUids(cb)[1]
                    if uid then
                        local line = give == "food" and "We need that food ourselves." or "Now? With things the way they are?"
                        K.say(uid, line)
                        msg = tostring(msg) .. " " .. nameOf(uid) .. " isn't happy: \"" .. line .. "\""
                    end
                end
            end
            return ok, msg
        end end)
    end
end

if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(install)
        local d = BR.youData()
        log("ready v" .. tostring(BR.YOU_VERSION) .. ": your camp on the brain, dial " .. tostring(BR.DIAL_WORDS[BR.youDial()]) .. ", war asks "
            .. (set("campBrainWarAsk") ~= false and "always" or "per dial") .. ", " .. pending() .. " ideas waiting")
    end)
end
