-- A-Life NPC Overhaul pre-1.0: BRAIN 2, R3 STANDING ORDERS + LIEUTENANTS (docs/PLAN-BRAIN-2.md). Your camp, run your way.
--   * Standing orders (Work tab, Orders page; saved with the camp; in-game choices, not sandbox): trade (never trade
--     food / medicine / ammo, keep N days of food back, only with groups that like us), people (always scout a group
--     we just heard of, never send anyone out alone), diplomacy (talk peace when it's going badly without asking,
--     never pay tribute, pay anyone much stronger), war (defend only / hit back when provoked / free hand, raids only,
--     never attack groups that like us).
--     An idea that breaks an order is never asked (the camp says so in "Lately"); one an order allows goes without a
--     card (a fight still asks while campBrainWarAsk is on). Orders show in the brain's why lines ("like you said").
--   * Lieutenants: put a member in charge of a branch (Trade, War, Scouting, Diplomacy, Home). Their nature runs that
--     branch (a greedy quartermaster trades more often, a reckless war chief picks fights, a paranoid scout master
--     scouts everything); they make the branch's small calls inside the dial and your orders and tell you after; the
--     big ones (fights) come to you as cards in their voice. Trust matters (love / need / fear): one who doesn't trust
--     you may stretch an order (ltOverrule) or skip a report; turned down too often, they quit the post (a card). A
--     lieutenant who dies or leaves leaves the branch unsure for stainDays (it asks you again meanwhile).
-- World side (MP: server). Client: ALifeWorkTab (Orders page) through byOrder / byLt and the byKnow view.
require "ALifeNPCOverhaul/AA_Side"
pcall(require, "ALifeNPCOverhaul/ALifeBrainYou")
local BR = ALifeBrain
local K = ALifeCampKit
if type(BR) ~= "table" or type(BR.M) ~= "table" or type(K) ~= "table" or type(BR.youData) ~= "function" then return end
local M = BR.M
local fn, hours, clamp = BR.fn, BR.hours, BR.clamp
local TAG = "[ALifeBrainCommandYou]"
local function log(m) print(TAG .. " " .. tostring(m)) end
local function T() return ALifeTrade end
local function roll01(key) return BR.roll(key) end
BR.CMD_STATS = BR.CMD_STATS or { dropped = 0, went = 0, autoPaid = 0, autoRefused = 0, ltCalls = 0, ltQuit = 0, ltStretched = 0, ltLost = 0 }
local ST = BR.CMD_STATS

BR.CMD_DEFAULTS = {
    lieutenants = true,   -- members can run a branch of the camp for you
    ltOverrule = 1,       -- how far a lieutenant who doesn't trust you may stretch your orders (0 never, 1 now and then, 2 often)
    ltQuitNos = 3,        -- turned down this many times in a week, a lieutenant gives up the post
    ltTrustLow = -15,     -- what they think of you below this = they don't trust you
    campAskHelp = true,   -- R6: your camp radios allies in range for help when a strong threat is near
    campAsksPerDay = 3,   -- R6: most idea cards a day (the rest wait, or a lieutenant handles them)
    campMapPins = true,   -- R6: what your camp knows goes on your paper map as notes
}
K.reg(BR.CMD_DEFAULTS, {
    { "lieutenants", "Camp brain: members can run a branch of the camp for you (lieutenants)" },
    { "ltOverrule", "Camp brain: how far a lieutenant who doesn't trust you stretches your orders", { 0, 1, 2 }, { "never", "now and then", "often" } },
    { "ltQuitNos", "Camp brain: times a week you can turn a lieutenant down before they quit the post", { 2, 3, 5, 99 } },
    { "ltTrustLow", "Camp brain: below this opinion of you a lieutenant doesn't trust you", { -30, -15, 0 } },
    { "campAskHelp", "Camp brain: your camp radios allies in range for help when a strong threat is near" },
    { "campAsksPerDay", "Camp brain: most idea cards a day (the rest wait or go to a lieutenant)", { 1, 3, 5, 99 } },
    { "campMapPins", "Camp brain: what your camp knows goes on your paper map" },
}, "Your camp and base")
local function num(k) return K.num(BR.CMD_DEFAULTS, k) end
local function set(k) return K.set(BR.CMD_DEFAULTS, k) end

----------------------------------------------------------------------------------------------------------------
-- standing orders
----------------------------------------------------------------------------------------------------------------
BR.ORDER_DEFS = {
    { key = "tradeNoFood", group = "trade", label = "Never trade food away" },
    { key = "tradeNoMeds", group = "trade", label = "Never trade medicine away" },
    { key = "tradeNoAmmo", group = "trade", label = "Never trade ammo away" },
    { key = "keepFoodDays", group = "trade", vals = { 0, 3, 7, 14 }, label = "Keep days of food back", words = { [0] = "no rule", [3] = "3 days", [7] = "a week", [14] = "two weeks" } },
    { key = "tradeFriendsOnly", group = "trade", label = "Trade only with groups that like us" },
    { key = "scoutNew", group = "people", label = "Always scout a group we just heard of" },
    { key = "neverAlone", group = "people", label = "Never send anyone out alone" },
    { key = "peaceTalks", group = "diplomacy", label = "Talk peace when a fight goes badly, without asking" },
    { key = "neverPay", group = "diplomacy", label = "Never pay tribute" },
    { key = "payStronger", group = "diplomacy", label = "Pay tribute to anyone much stronger" },
    { key = "war", group = "war", vals = { 0, 1, 2 }, label = "War", words = { [0] = "defend only", [1] = "hit back when provoked", [2] = "free hand" } },
    { key = "raidsOnly", group = "war", label = "Raids only: never an all-out attack or a siege" },
    { key = "spareFriends", group = "war", label = "Never attack groups that like us" },
}
BR.ORDER_BY = {}
for _, o in ipairs(BR.ORDER_DEFS) do BR.ORDER_BY[o.key] = o end
local ORDER_DEFAULT = { keepFoodDays = 0, war = 2 }
function BR.youOrders()
    local d = BR.youData()
    if type(d.orders) ~= "table" then d.orders = {} end
    return d.orders
end
function BR.youOrder(key)
    local v = BR.youOrders()[key]
    if v == nil then v = ORDER_DEFAULT[key] end
    if v == nil then v = false end
    return v
end
-- set one order (value nil = next step: flip a yes/no, cycle a number)
function BR.youSetOrder(key, value)
    local def = BR.ORDER_BY[tostring(key)]
    if def == nil then return nil end
    local o = BR.youOrders()
    if def.vals then
        local cur = tonumber(BR.youOrder(def.key)) or def.vals[1]
        local v = tonumber(value)
        if v == nil then
            local i = 1
            for j, x in ipairs(def.vals) do if x == cur then i = j end end
            v = def.vals[(i % #def.vals) + 1]
        end
        local okv = false
        for _, x in ipairs(def.vals) do if x == v then okv = true end end
        if not okv then return nil end
        o[def.key] = v
    else
        if value == nil then o[def.key] = not (BR.youOrder(def.key) == true)
        else o[def.key] = (value == true or value == "true" or value == 1) end
    end
    return o[def.key]
end
function BR.orderWord(key)
    local def = BR.ORDER_BY[key]
    local v = BR.youOrder(key)
    if def and def.words then return def.words[tonumber(v) or 0] or tostring(v) end
    return v == true and "yes" or "no"
end
local function said(text)
    local d = BR.youData()
    local h = hours()
    -- once a day per line is plenty
    d.saidKey = type(d.saidKey) == "table" and d.saidKey or {}
    if (tonumber(d.saidKey[text]) or -1e9) > h - 24 then return end
    d.saidKey[text] = h
    d.said[#d.said + 1] = { h = h, t = text }
    while #d.said > 12 do table.remove(d.said, 1) end
end
BR.youOrderSaid = said
local function kindWord(k) local t = T(); return tostring((t and t.KIND_WORDS and t.KIND_WORDS[k]) or k or "goods") end
local function provoked(cb, to, h)
    if BR.grudgeV(cb, to, h) >= 20 then return true end
    local s = BR.of(cb)
    if s.lastHitBy == to and h - (tonumber(s.lastHitH) or -1e9) < 24 * 14 then return true end
    local o = BR.base(to)
    return o ~= nil and (tonumber(o.rep) or 50) <= 15
end

-- does an order forbid, shape or allow this idea? "drop" | "go" | nil (ask / per dial as usual)
function BR.youOrderVerdict(cb, x, sit, h)
    local act = BR.youActOf(x)
    local tg = type(x.target) == "table" and x.target or {}
    local to = tg.to
    local place = BR.youPlaceOf(to)
    local o = to and BR.base(to) or nil
    if act == "trade" then
        local give = tg.give
        if (give == "food" and BR.youOrder("tradeNoFood")) or (give == "meds" and BR.youOrder("tradeNoMeds")) or (give == "ammo" and BR.youOrder("tradeNoAmmo")) then
            said("We didn't trade our " .. kindWord(give) .. " away: you said not to"); return "drop", "order"
        end
        local keep = tonumber(BR.youOrder("keepFoodDays")) or 0
        if give == "food" and keep > 0 and (tonumber(sit and sit.food) or 0) < keep + 1 then
            said("We kept our food back, like you said"); return "drop", "order"
        end
        if BR.youOrder("tradeFriendsOnly") and not (o and (tonumber(o.rep) or 50) >= 60) then
            said("We didn't trade with " .. place .. ": you said only with friends"); return "drop", "order"
        end
    elseif act == "war" then
        local war = tonumber(BR.youOrder("war")) or 2
        if war <= 0 then said("Some wanted to hit " .. place .. ". You said we only defend"); return "drop", "order" end
        if war == 1 and not provoked(cb, to, h) then said("Nobody went after " .. place .. ": they haven't done anything to us yet"); return "drop", "order" end
        if BR.youOrder("spareFriends") and o and (tonumber(o.rep) or 50) >= 60 then said("We left " .. place .. " alone: they like us"); return "drop", "order" end
        if BR.youOrder("raidsOnly") and tg.goal ~= nil and tg.goal ~= "raid" then tg.goal = "raid"; x.orderWhy = "Just a raid, like you said" end
    elseif act == "tribute" then
        if (tonumber(BR.youOrder("war")) or 2) <= 0 then said("Some wanted to make " .. place .. " pay. You said we only defend"); return "drop", "order" end
        if BR.youOrder("spareFriends") and o and (tonumber(o.rep) or 50) >= 60 then return "drop", "order" end
    elseif act == "scout" then
        if BR.youOrder("scoutNew") and x.newGroup then x.orderWhy = "You said to always look at new people"; return "go", "order" end
    elseif act == "peace" then
        if BR.youOrder("peaceTalks") then x.orderWhy = "You said to talk peace when it goes badly"; return "go", "order" end
    end
    return nil
end

-- new bids the orders call for: a scout to a group we just heard of
function BR.youOrderBids(cb, sit, h, s, bids)
    if fn(BR, "youLtWarBids") then pcall(BR.youLtWarBids, cb, sit, h, s, bids) end
    if not BR.youOrder("scoutNew") or not BR.flag("scouts") then return end
    s.scouted = type(s.scouted) == "table" and s.scouted or {}
    local t = T()
    for _, r in ipairs(fn(t, "runsOf") and t.runsOf("you") or {}) do if r.kind == "scout" then return end end
    for _, k in ipairs(BR.known(cb, h)) do
        if k.id ~= "you" and BR.base(k.id) and s.scouted[k.id] == nil and (tonumber(k.c) or 0) < 0.6 then
            s.scouted[k.id] = h
            bids[#bids + 1] = { job = "scout", n = 1, value = 2, tool = "scoutRun", target = { to = k.id }, key = "scoutNew", newGroup = true }
            return
        end
    end
end

-- a demand on you: your orders answer it (never pay / pay anyone much stronger)
function BR.youOrderTribute(b, h)
    local t = T()
    if type(b) ~= "table" or not fn(t, "store") or not fn(M, "trDealAnswer") then return nil end
    local offId = nil
    for id, off in pairs(t.store().offers) do if type(off) == "table" and off.tribute and off.from == b.id then offId = id end end
    if offId == nil then return nil end
    local cb = BR.youRec()
    local k = BR.belief(cb, b.id, h)
    local mine = math.max(0.1, BR.youStrOf(cb))
    local much = k and tonumber(k.str) and k.str >= mine * 2
    local yes = nil
    if BR.youOrder("payStronger") and much then yes = true
    elseif BR.youOrder("neverPay") then yes = false end
    if yes == nil then return nil end
    local ok = pcall(M.trDealAnswer, offId, yes, K.player())
    if not ok then return nil end
    if yes then ST.autoPaid = ST.autoPaid + 1; BR.youReport("We agreed to pay " .. tostring(b.name) .. ", like you said we would when they're much stronger", "brain")
    else ST.autoRefused = ST.autoRefused + 1; BR.youReport("We told " .. tostring(b.name) .. " no. You said we never pay", "war", true) end
    return yes
end

----------------------------------------------------------------------------------------------------------------
-- lieutenants
----------------------------------------------------------------------------------------------------------------
BR.LT_BRANCHES = { "trade", "war", "scout", "diplomacy", "home" }
BR.LT_WORDS = { trade = "Trade", war = "War", scout = "Scouting", diplomacy = "Diplomacy", home = "Home" }
BR.LT_TITLES = { trade = "quartermaster", war = "war chief", scout = "scout master", diplomacy = "go-between", home = "steward" }
local ACT_BRANCH = { trade = "trade", war = "war", tribute = "war", scout = "scout", peace = "diplomacy", ally = "diplomacy" }
function BR.youLts()
    local d = BR.youData()
    if type(d.lt) ~= "table" then d.lt = {} end
    if type(d.ltNo) ~= "table" then d.ltNo = {} end
    if type(d.ltUnsure) ~= "table" then d.ltUnsure = {} end
    return d.lt, d
end
local function isHomeMember(uid)
    for _, u in ipairs(BR.youHomeUids(BR.youRec())) do if u == uid then return true end end
    return false
end
local function alive(uid) local r = K.rec(uid); return r ~= nil and r.lifecycle ~= "dead" end
local function inCamp(uid)
    local _, list = pcall(BR.youPeopleOf, BR.youRec())
    for _, p in ipairs(type(list) == "table" and list or {}) do if p.uid == uid then return true end end
    return false
end
-- who runs this branch now (nil: you, or unsure after a loss)
function BR.youLt(branch)
    if set("lieutenants") == false then return nil end
    local lt, d = BR.youLts()
    local uid = lt[branch]
    if uid == nil then return nil end
    return uid
end
function BR.youSetLt(branch, uid, player)
    if BR.LT_WORDS[tostring(branch)] == nil then return false end
    local lt, d = BR.youLts()
    if uid == nil or uid == "" or uid == "none" then
        lt[branch] = nil
        return true
    end
    uid = tostring(uid)
    if not inCamp(uid) then return false end
    for b, u in pairs(lt) do if u == uid and b ~= branch then lt[b] = nil end end -- one post each
    lt[branch] = uid
    d.ltUnsure[branch] = nil
    d.ltNo[uid] = nil
    K.say(uid, ({ trade = "I'll make sure we don't get cheated.", war = "Leave the fighting to me.", scout = "Nothing moves out there without us knowing.",
        diplomacy = "I'll do the talking.", home = "I'll keep this place running." })[branch] or "All right. I'll handle it.")
    K.opinion(uid, player or K.player(), 2, "You put them in charge")
    return true
end
-- what they think of you (A-Life NpcOpinion; nil = can't tell)
local function trustOf(uid, player)
    local v = nil
    pcall(function() v = K.PA().NpcOpinion.valueOf(K.rec(uid), player or K.player()) end)
    return tonumber(v)
end
function BR.youLtTrusts(uid)
    local v = trustOf(uid)
    return v == nil or v >= num("ltTrustLow")
end
-- a lieutenant's nature bends their branch: { often (more chances), bold (worse odds ok), keep (food days held), look (scout sooner) }
function BR.youLtBend(branch)
    local uid = BR.youLt(branch)
    if uid == nil then return nil end
    local l = K.lens(uid)
    local f = function(k) return tonumber(l[k]) or 0 end
    return { uid = uid, greedy = f("greedy"), bold = f("brave") + f("mean") + f("unhinged") * 0.5 - f("fearful") - f("kind") * 0.5,
        paranoid = f("paranoid"), kind = f("kind"), calm = f("calm"), proud = f("proud") }
end
-- the camp lost its lieutenant (dead, left the camp): that branch is unsure for stainDays
function BR.youLtCheck(h)
    local lt, d = BR.youLts()
    for _, branch in ipairs(BR.LT_BRANCHES) do
        local uid = lt[branch]
        if uid and (not alive(uid) or not inCamp(uid)) then
            lt[branch] = nil
            d.ltUnsure[branch] = h + BR.num("stainDays") * 24
            ST.ltLost = ST.ltLost + 1
            BR.youReport((alive(uid) and (BR.youNameOf(uid) .. " is gone from camp") or (BR.youNameOf(uid) .. " is dead")) .. ". Nobody's sure who runs " .. string.lower(BR.LT_WORDS[branch]) .. " now", "brain", true)
        end
    end
    for b, untilH in pairs(d.ltUnsure) do if h >= (tonumber(untilH) or 0) then d.ltUnsure[b] = nil end end
end
function BR.youLtUnsure(branch) local _, d = BR.youLts(); return d.ltUnsure[branch] ~= nil and hours() < (tonumber(d.ltUnsure[branch]) or 0) end

-- the lieutenant's call on an idea in their branch: "go" (small call, told after) / "drop" / "ask" (big call, in their voice) / nil
function BR.youLtVerdict(cb, x, sit, h)
    local act = BR.youActOf(x)
    local branch = ACT_BRANCH[act]
    if branch == nil or BR.youLtUnsure(branch) then return nil end
    local uid = BR.youLt(branch)
    if uid == nil then return nil end
    if not isHomeMember(uid) then return nil end -- away or hurt: the idea comes to you
    local bend = BR.youLtBend(branch)
    x.by = uid
    x.lt = branch
    if act == "war" or act == "tribute" then
        -- the big call stays yours; a careful war chief doesn't even bring a bad one
        if bend.bold < -0.3 then
            local k = BR.belief(cb, type(x.target) == "table" and x.target.to or nil, h)
            local mine = math.max(0.1, BR.youStrOf(cb))
            if k and tonumber(k.str) and k.str > mine * 0.8 then said(BR.youNameOf(uid) .. " (war) thinks a fight with " .. BR.youPlaceOf(x.target.to) .. " is a bad idea right now"); return "drop" end
        end
        return "ask"
    end
    if act == "peace" and bend.proud > 0.5 and bend.kind < 0.3 then said(BR.youNameOf(uid) .. " won't go begging " .. BR.youPlaceOf(x.target and x.target.to) .. " for peace"); return "drop" end
    if not BR.youLtTrusts(uid) and roll01(uid .. act .. math.floor(h / 24)) < 0.3 then x.noReport = true end -- doesn't bother telling you
    x.opts = { by = uid, n = x.n } -- their call: they go first, and they tell you (youLtReport), not the Run-it letter
    ST.ltCalls = ST.ltCalls + 1
    return "go"
end

-- their nature runs the branch: a greedy quartermaster trades every day (not every third), a paranoid scout master
-- looks twice as often; a steward who's calm keeps one more on guard (Home)
function BR.youLtBendBranches(cb, h)
    local s = BR.of(cb)
    local day = math.floor(h / 24)
    local tb = not BR.youLtUnsure("trade") and BR.youLtBend("trade") or nil
    if tb and tb.greedy >= 0.5 and s.tradeDay ~= nil and day - s.tradeDay >= 1 and day - s.tradeDay < 3 then s.tradeDay = day - 3 end
    local sb = not BR.youLtUnsure("scout") and BR.youLtBend("scout") or nil
    if sb and sb.paranoid >= 0.5 and s.scoutH ~= nil and h - s.scoutH >= 12 and h - s.scoutH < 24 then s.scoutH = h - 24 end
    local hb = not BR.youLtUnsure("home") and BR.youLtBend("home") or nil
    s.orders = type(s.orders) == "table" and s.orders or {}
    if hb and (hb.paranoid >= 0.5 or hb.calm >= 0.5) then s.orders.gate = math.max(tonumber(s.orders.gate) or 0, 2) end
end
-- a reckless war chief brings fights the camp's mood wouldn't (only weak, known targets; still asks you)
function BR.youLtWarBids(cb, sit, h, s, bids)
    local wb = not BR.youLtUnsure("war") and BR.youLtBend("war") or nil
    if wb == nil or wb.bold < 0.8 or not BR.flag("warParties") or s.stance == "dominate" or s.stance == "revenge" or s.stance == "survive" then return end
    for _, r in ipairs(fn(T(), "runsOf") and T().runsOf("you") or {}) do if r.kind == "war" then return end end
    local p = sit.prey and sit.prey[1] or nil
    if p and p.sure and p.ratio < 0.6 and p.id ~= "you" and BR.base(p.id) then
        bids[#bids + 1] = { job = "war", n = 2, value = 2, tool = "warParty", target = { to = p.id, goal = "raid" }, key = "ltWar" }
    end
end

-- a lieutenant who doesn't trust you may stretch an order (ltOverrule): returns true if this order is ignored this time
function BR.youLtStretch(branch, key, h)
    local uid = BR.youLt(branch)
    local level = num("ltOverrule")
    if uid == nil or level <= 0 or BR.youLtTrusts(uid) then return false end
    if BR.roll(uid .. key .. math.floor(h / 24)) >= (level >= 2 and 0.5 or 0.2) then return false end
    ST.ltStretched = ST.ltStretched + 1
    said(BR.youNameOf(uid) .. " (" .. string.lower(BR.LT_WORDS[branch]) .. ") went against what you said this time")
    return true
end

-- turned down: a lieutenant who keeps getting overruled gives up the post
function BR.youLtOverruled(uid, h)
    local lt, d = BR.youLts()
    local branch = nil
    for b, u in pairs(lt) do if u == uid then branch = b end end
    if branch == nil then return false end
    local row = type(d.ltNo[uid]) == "table" and d.ltNo[uid] or {}
    local keep = {}
    for _, t in ipairs(row) do if h - t < 24 * 7 then keep[#keep + 1] = t end end
    keep[#keep + 1] = h
    d.ltNo[uid] = keep
    if #keep < num("ltQuitNos") then return false end
    lt[branch] = nil
    d.ltNo[uid] = nil
    d.ltUnsure[branch] = h + BR.num("stainDays") * 24
    ST.ltQuit = ST.ltQuit + 1
    local name = BR.youNameOf(uid)
    BR.campCard({ id = "brainLtQuit:" .. uid .. ":" .. math.floor(h), title = name .. " quits as " .. BR.LT_TITLES[branch], default = 1,
        text = name .. ": \"You keep telling me no. Run " .. string.lower(BR.LT_WORDS[branch]) .. " yourself, then.\" <LINE> <LINE> Nobody runs it for you now. You can pick someone else in the Work tab (Orders).",
        choices = { { label = "So be it", fn = function() end } } }, K.player())
    K.opinion(uid, K.player(), -2, "You never listened to them")
    return true
end

-- the combined verdict youManage asks for (orders first, then the lieutenant)
function BR.youVerdict(cb, x, sit, h)
    local v = BR.youOrderVerdict(cb, x, sit, h)
    if v == "drop" then
        -- a lieutenant who doesn't trust you may go ahead anyway (never for a fight)
        local act = BR.youActOf(x)
        local branch = ACT_BRANCH[act]
        if branch and act ~= "war" and act ~= "tribute" and BR.youLtStretch(branch, act, h) then return "go" end
        ST.dropped = ST.dropped + 1
        return "drop"
    end
    local lv = BR.youLtVerdict(cb, x, sit, h)
    if lv == "drop" then ST.dropped = ST.dropped + 1; return "drop" end
    if v == "go" or lv == "go" then ST.went = ST.went + 1; return "go" end
    return nil -- ask (in the lieutenant's voice when x.by is set) or per dial
end

----------------------------------------------------------------------------------------------------------------
-- wraps: the ask speaks in the lieutenant's voice, a no counts against the post, orders in the why line
----------------------------------------------------------------------------------------------------------------
local function install()
    K.wrap(BR, "youSpeaker", "CmdYouSpeaker", function(orig) return function(cb, act, skip, ...)
        local branch = ACT_BRANCH[act]
        local uid = branch and not BR.youLtUnsure(branch) and BR.youLt(branch) or nil
        if uid and uid ~= skip and isHomeMember(uid) then return uid, nil end
        return orig(cb, act, skip, ...)
    end end)
    K.wrap(BR, "youWhy", "CmdYouWhy", function(orig) return function(cb, x, sit, ...)
        local w = orig(cb, x, sit, ...)
        local extra = {}
        if x.orderWhy then extra[#extra + 1] = x.orderWhy end
        local act = BR.youActOf(x)
        if act == "trade" and (tonumber(BR.youOrder("keepFoodDays")) or 0) > 0 then extra[#extra + 1] = "We keep our food back, like you said" end
        local branch = ACT_BRANCH[act]
        local uid = branch and BR.youLt(branch) or nil
        if uid then extra[#extra + 1] = BR.youNameOf(uid) .. " runs " .. string.lower(BR.LT_WORDS[branch]) .. " for you" end
        if #extra > 0 then w = tostring(w) .. " " .. table.concat(extra, ". ") .. "." end
        return w
    end end)
    K.wrap(BR, "youAnswer", "CmdYouAnswer", function(orig) return function(id, what, player, ...)
        local a = BR.youData().asks[tostring(id or "")]
        local by = type(a) == "table" and a.by or nil
        local r1, r2 = orig(id, what, player, ...)
        if by and what == "no" then pcall(BR.youLtOverruled, by, hours()) end
        return r1, r2
    end end)
    K.wrap(BR, "tributeToYou", "CmdYouTribute", function(orig) return function(b, h, ...)
        local r = orig(b, h, ...)
        if r then pcall(BR.youOrderTribute, b, h) end
        return r
    end end)
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)

-- lieutenant's go: the bid carries x.by / x.lt; youManage hands it to the allocator, then youCall runs. Report after.
K.wrap(BR, "youManage", "CmdYouManage", function(orig) return function(cb, h, ...)
    pcall(BR.youLtCheck, h)
    pcall(BR.youLtBendBranches, cb, h)
    return orig(cb, h, ...)
end end)
-- what a lieutenant did, in their words (the run engine tells us when a camp run starts)
function BR.youLtReport(x)
    if type(x) ~= "table" or not x.lt or x.noReport or not x.by then return end
    local words = { trade = "sent a trade run to", scout = "sent someone to look at", diplomacy = "sent word to", war = "sent our fighters against" }
    BR.youReport(BR.youNameOf(x.by) .. " (" .. string.lower(BR.LT_WORDS[x.lt]) .. ") " .. (words[x.lt] or "sent people to") .. " " .. BR.youPlaceOf(type(x.target) == "table" and x.target.to or nil), "brain")
end
K.wrap(BR, "allocate", "CmdYouAlloc", function(orig) return function(b, h, bids, ...)
    local r1, r2 = orig(b, h, bids, ...)
    if BR.isYou(b) and type(bids) == "table" then for _, x in ipairs(bids) do if x.started and x.lt then pcall(BR.youLtReport, x) end end end
    return r1, r2
end end)

----------------------------------------------------------------------------------------------------------------
-- R6 small gaps (camp side): real morale, the card limit, friends at your place, notes on your map
----------------------------------------------------------------------------------------------------------------
-- the camp's mood: the members' real unrest (ALifeLLMTalk_Dynamics, 0..100 worse), turned around
function BR.youMorale(cb)
    local list = {}
    if fn(BR, "youPeopleOf") then local ok, l = pcall(BR.youPeopleOf, cb); if ok and type(l) == "table" then list = l end end
    if #list == 0 then return nil end
    local sum = 0
    for _, p in ipairs(list) do sum = sum + K.unrest(p.uid) end
    return clamp(100 - sum / #list, 0, 100)
end
-- what friends standing at your place add (help parties staying: real people)
function BR.youHelpersStr(h)
    local cb = BR.youRec()
    local s = type(cb.brain) == "table" and cb.brain or nil
    local str = 0
    if s and type(s.helpers) == "table" then
        for k, x in pairs(s.helpers) do
            if type(x) == "table" and h < (tonumber(x.untilH) or 0) then str = str + (tonumber(x.str) or 0) else s.helpers[k] = nil end
        end
    end
    return str
end
-- notes on your paper map: one per group, again when what we know changes (position, hostile, turned out wrong)
-- MP: every camp player's own map (each one's notes kept by player key, so someone who joins later gets them all)
function BR.youPins(player, h)
    if set("campMapPins") == false or not fn(ALifeSide, "outMark") then return 0 end
    local d = BR.youData()
    d.pinsBy = type(d.pinsBy) == "table" and d.pinsBy or {}
    local key = tostring(ALifeSide.keyOf(player) or "sp")
    d.pinsBy[key] = type(d.pinsBy[key]) == "table" and d.pinsBy[key] or {}
    local pins = d.pinsBy[key]
    local cb = BR.youRec()
    local n = 0
    local day = math.floor(h / 24)
    for _, k in ipairs(type(cb.brain) == "table" and BR.known(cb, h) or {}) do
        local raw = cb.brain.know[tostring(k.id)]
        if k.id ~= "you" and tonumber(k.x) and (tonumber(k.c) or 0) >= 0.4 then
            local wrong = type(raw) == "table" and type(raw.wrong) == "table"
            local pin = pins[k.id]
            local moved = type(pin) ~= "table" or ((pin.x - k.x) ^ 2 + (pin.y - k.y) ^ 2 > 100 * 100)
            if type(pin) ~= "table" or moved or (k.hostile == true) ~= (pin.hostile == true) or wrong ~= (pin.wrong == true) then
                local name = tostring(k.name or (BR.base(k.id) or {}).name or "A group")
                local text = wrong and (name .. ": what we heard was wrong (day " .. day .. ")") or (name .. (k.hostile and ", hostile" or "") .. " (day " .. day .. ")")
                pcall(ALifeSide.outMark, player, text, math.floor(k.x), math.floor(k.y))
                pins[k.id] = { x = k.x, y = k.y, hostile = k.hostile == true, wrong = wrong, h = h }
                n = n + 1
            end
        end
    end
    return n
end
local function installGaps()
    K.wrap(BR, "youRefresh", "CmdYouMorale", function(orig) return function(player, ...)
        local cb = orig(player, ...)
        if type(cb) == "table" then local mo = BR.youMorale(cb); if mo ~= nil then cb.morale = mo end end
        return cb
    end end)
    -- at most campAsksPerDay cards; the rest wait (a lieutenant's small calls never needed one)
    K.wrap(BR, "youAsk", "CmdYouLimit", function(orig) return function(cb, x, sit, h, ...)
        local d = BR.youData()
        local day = math.floor((h or hours()) / 24)
        if d.askDay ~= day then d.askDay, d.askN = day, 0 end
        if (tonumber(d.askN) or 0) >= num("campAsksPerDay") then return false end
        local r = orig(cb, x, sit, h, ...)
        if r then d.askN = (tonumber(d.askN) or 0) + 1 end
        return r
    end end)
    -- off screen, a war party at your place sees your friends there and thinks better of it
    K.wrap(BR, "warArrive", "CmdYouHelpers", function(orig) return function(run, b, h, ...)
        if type(run) == "table" and run.target == "you" and run.kind == "war" and run.goal ~= "feint" and run.fight == nil then
            local helpers = BR.youHelpersStr(h)
            if helpers > 0 and helpers + BR.youStrOf(BR.youRec()) * 0.5 >= (fn(BR, "partyStr") and BR.partyStr(run) or 1) then
                BR.event(b, "Their fighters turned back from the newcomer's place: friends of theirs were there", "war")
                BR.campLetter("Armed people from " .. tostring(b.name) .. " came to your place, saw who was standing with you, and left.", false)
                return
            end
        end
        return orig(run, b, h, ...)
    end end)
    return true
end
BR.installers[#BR.installers + 1] = installGaps
pcall(installGaps)
K.hourly(TAG .. "Pins", function(p, h) if BR.on() and math.floor(h) % 6 == 0 then for _, cp in ipairs(BR.campPlayers()) do pcall(BR.youPins, cp, h) end end end)

----------------------------------------------------------------------------------------------------------------
-- the Orders page (view rows) + the calls the client makes
----------------------------------------------------------------------------------------------------------------
function BR.youOrdersView(player)
    local out = {}
    for _, o in ipairs(BR.ORDER_DEFS) do
        out[#out + 1] = { k = "order", key = o.key, group = o.group, label = o.label, word = BR.orderWord(o.key), on = o.vals == nil and BR.youOrder(o.key) == true or nil }
    end
    local lt = BR.youLts()
    for _, b in ipairs(BR.LT_BRANCHES) do
        local uid = lt[b]
        out[#out + 1] = { k = "lt", branch = b, label = BR.LT_WORDS[b], uid = uid, name = uid and BR.youNameOf(uid) or nil, unsure = BR.youLtUnsure(b) or nil,
            trust = uid and (BR.youLtTrusts(uid) and "trusts you" or "doesn't trust you") or nil }
    end
    for _, uid in ipairs(BR.youHomeUids(BR.youRec())) do out[#out + 1] = { k = "who", uid = uid, name = BR.youNameOf(uid) } end
    out[#out + 1] = { k = "ltOn", on = set("lieutenants") ~= false }
    return out
end
M.byOrder = function(key, value, player) return BR.youSetOrder(key, value) end
M.byLt = function(branch, uid, player) return BR.youSetLt(branch, uid, player) end
if type(ALifeRemote) == "table" then
    if fn(ALifeRemote, "view") then ALifeRemote.view("byOrders", BR.youOrdersView, {}) end
    if fn(ALifeRemote, "expose") then ALifeRemote.expose("byOrder", 2, 3); ALifeRemote.expose("byLt", 2, 3) end
end

do
    local Events = ALifeSide.hooks("world", "ALifeBrainCommandYou")
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            local n, lt = 0, BR.youLts()
            for _ in pairs(lt) do n = n + 1 end
            log("ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": standing orders (war " .. BR.orderWord("war") .. "), " .. n .. " lieutenants")
        end)
    end
end
