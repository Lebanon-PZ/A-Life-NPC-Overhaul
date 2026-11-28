-- A-Life NPC Overhaul pre-1.0: BRAIN 4, S1-S3 GROUPS BREAK APART AND COME BACK (docs/PLAN-BRAIN-4.md).
--   S1 real splits: a group that's falling out (morale low, members against the leader's course, losses, hunger, a
--      close fight over who leads) loses a real piece of itself. The rival (the best leader after the boss, or the
--      one who lost the contest) leads; the ones closer to the rival's nature than the boss's follow, at most
--      splitMaxShare. They pick a real house (the nomads' search), walk there, carry their fair share of the stash,
--      get their own band name and their own brain. Ties -40 both ways, grudges both ways. Off screen only.
--      Brain on: Bands' old label-only split is off (M.b4OwnsSplits).
--   S2 kin: the two remember where they came from (o.kinOf). Without a war the bad blood eases a little each week;
--      later, small or pressed (the dead, hunger) and on good terms again, the splinter comes back (real nbAbsorb).
--   S3 succession: when the leader is gone, love / need / fear decide (from each one's nature, weighted by what the
--      group believes); A-Life's own group leader still counts. A close runner-up is a contest: S1 with "contest".
-- Never your camp. World side (server in MP). Nothing new on the network.
require "ALifeNPCOverhaul/ALifeBrainManagers"
pcall(require, "ALifeNPCOverhaul/ALifeBrainWords")
pcall(require, "ALifeNPCOverhaul/ALifeBrainMind")
pcall(require, "ALifeNPCOverhaul/ALifeBrainHistory")
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn, hours, clamp, roll = BR.fn, BR.hours, BR.clamp, BR.roll
local TAG = "[ALifeBrainSplit]"

BR.defaults({
    brainSplits = true,      -- groups really break apart (off = the old label-only split in Bands)
    splitMinCrew = 5,        -- smallest group that can split
    splitChance = 10,        -- percent a day per reason that it comes to a split
    splitGapDays = 14,       -- days between splits of one group
    splitMaxShare = 50,      -- most of a group that walks out (percent)
    kinRejoin = true,        -- a splinter can come back later
    kinRejoinDays = 21,      -- earliest it comes back (days after the split)
    kinRejoinChance = 15,    -- percent a day once it's small or pressed and on good terms
    kinHeal = 4,             -- how much the bad blood eases each week without a war
    succession = true,       -- love / need / fear decide who leads after a death; close calls are contests
    contestSplit = 35,       -- percent a close runner-up walks out with their people
})
BR.addRows({
    { "brainSplits", "Brain 4: groups really break apart (a real piece walks out with its share and a new name)" },
    { "splitMinCrew", "Brain 4: smallest group that can split", { 4, 5, 7 } },
    { "splitChance", "Brain 4: chance a day per reason a group splits (percent)", { 5, 10, 20 } },
    { "splitGapDays", "Brain 4: days between splits of one group", { 7, 14, 30 } },
    { "splitMaxShare", "Brain 4: most of a group that walks out (percent)", { 30, 50 } },
    { "kinRejoin", "Brain 4: a group that broke away can come back later" },
    { "kinRejoinDays", "Brain 4: earliest days before they come back", { 7, 21, 45 } },
    { "kinRejoinChance", "Brain 4: chance a day they come back once it makes sense (percent)", { 5, 15, 30 } },
    { "kinHeal", "Brain 4: how fast bad blood between them eases each week", { 0, 4, 8 } },
    { "succession", "Brain 4: love, need or fear decide who leads after a death (close calls split groups)" },
    { "contestSplit", "Brain 4: chance a close runner-up walks out with their people (percent)", { 15, 35, 60 } },
})
BR.splitStats = BR.splitStats or { tries = 0, splits = 0, noPlace = 0, noFollowers = 0, rejoins = 0, contests = 0, successions = 0 }
local SS = BR.splitStats
local function on() return BR.on() and BR.flag("brainSplits") end
local function day(h) return math.floor(h / 24) end
local function isYou(b) return type(b) == "table" and (b.isCamp == true or b.id == "you") end
local function lensOf(uid) if not fn(M, "lens") then return {} end local ok, l = pcall(M.lens, tostring(uid)); return ok and type(l) == "table" and l or {} end
local function firstOf(r)
    local n = nil
    pcall(function() n = BR.PA().Names.of(r) end)
    n = n or (type(r) == "table" and (r.name or (type(r.memory) == "table" and r.memory.personFirst))) or "someone"
    return string.match(tostring(n), "^(%S+)") or tostring(n)
end
local function farFromAll(b) local far = (M.nbCfg and M.nbCfg.farTiles) or 150; return ALifeSide.nearest(b.x, b.y, far) == nil end
local function recent(list, h, within) local n = 0; for _, t in ipairs(type(list) == "table" and list or {}) do if h - (tonumber(t) or -1e9) <= within then n = n + 1 end end; return n end
-- the group's living people (A-Life records)
function BR.splitPeople(b)
    local out = {}
    if not fn(M, "nbScan") then return out end
    local ok, scan = pcall(M.nbScan, true)
    for _, r in ipairs(ok and type(scan) == "table" and (scan.crews or {})[b.id] or {}) do
        if type(r) == "table" and r.lifecycle ~= "dead" and not r.virtual then out[#out + 1] = r end
    end
    table.sort(out, function(x, y) return tostring(x.uid) < tostring(y.uid) end)
    return out
end

----------------------------------------------------------------------------------------------------------------
-- S3 love / need / fear
----------------------------------------------------------------------------------------------------------------
BR.LNF = { raiders = { love = 0.1, need = 0.3, fear = 0.6 }, traders = { love = 0.4, need = 0.5, fear = 0.1 }, open = { love = 0.5, need = 0.4, fear = 0.1 },
    faithful = { love = 0.5, need = 0.3, fear = 0.2 }, wary = { love = 0.3, need = 0.5, fear = 0.2 } }
function BR.lnfParts(uid)
    local l = lensOf(uid)
    return { love = (l.kind or 0) * 2 + (l.loyal or 0) + (l.calm or 0) - (l.cruel or 0),
        need = (l.disciplined or 0) * 3 + (l.calm or 0) + (l.loyal or 0) - (l.volatile or 0),
        fear = (l.brave or 0) * 2 + (l.proud or 0) + (l.volatile or 0) * 0.5 + (l.cruel or 0) - (l.fearful or 0) * 2 }
end
function BR.lnfScore(b, r)
    local creed = type(b.dir) == "table" and b.dir.creed or "wary"
    local w = BR.LNF[creed] or BR.LNF.wary
    local p = BR.lnfParts(r.uid)
    local s = p.love * w.love + p.need * w.need + p.fear * w.fear
    if creed == "faithful" then s = s + (lensOf(r.uid).devout or 0) * 1.5 end
    local m = type(r.memory) == "table" and r.memory or {}
    pcall(function() local g = BR.PA().ModuleLeader.groups[m.groupId]; if g ~= nil and tostring(g.leaderUid) == tostring(r.uid) then s = s + 1 end end)
    return s + (BR.hash(tostring(r.uid) .. "lnf") % 100) / 2000, p
end
local function whyWon(b, p)
    local creed = type(b.dir) == "table" and b.dir.creed or "wary"
    local w = BR.LNF[creed] or BR.LNF.wary
    local best, bv = "need", -1e9
    for _, k in ipairs({ "love", "need", "fear" }) do local v = (p[k] or 0) * w[k]; if v > bv then best, bv = k, v end end
    return ({ love = "the others trusted them", need = "nobody else could keep things running", fear = "nobody dared stand against them" })[best]
end

----------------------------------------------------------------------------------------------------------------
-- S1 reasons, who goes, the split itself
----------------------------------------------------------------------------------------------------------------
function BR.splitGrumblers(b)
    local s = type(b.brain) == "table" and b.brain or {}
    local n = 0
    if s.stance == nil or type(BR.MUTTER) ~= "table" then return 0 end
    for _, r in ipairs(BR.splitPeople(b)) do
        if tostring(r.uid) ~= tostring(b.leader) then
            local l = lensOf(r.uid)
            for _, mt in ipairs(BR.MUTTER) do if mt.st[s.stance] and (tonumber(l[mt.trait]) or 0) > 0.3 then n = n + 1; break end end
        end
    end
    return n
end
function BR.splitReasons(b, sit, h)
    local out = {}
    local crew = math.max(1, tonumber(b.crewN) or 1)
    if (tonumber(b.morale) or 50) < 30 then out[#out + 1] = { k = "morale", w = "after weeks of things going wrong" } end
    if BR.splitGrumblers(b) / crew >= 0.4 then out[#out + 1] = { k = "course", w = "they didn't like where " .. tostring(b.leaderName or "their leader") .. " was taking them" } end
    if recent(b.losses, h, 168) >= 2 then out[#out + 1] = { k = "losses", w = "after the people they lost" } end
    if (tonumber(b.starveH) or 0) >= 24 or (type(sit) == "table" and (tonumber(sit.food) or 9) < 1) then out[#out + 1] = { k = "hunger", w = "too many mouths and not enough food" } end
    local c = b.b4Contest
    if type(c) == "table" and h - (tonumber(c.h) or -1e9) < 72 then out[#out + 1] = { k = "contest", w = "they wouldn't follow " .. tostring(c.wName or "the new leader"), rival = c.r } end
    return out
end
local function sim(a, c) local v = 0; for k, x in pairs(a) do local y = tonumber(c[k]); if y and tonumber(x) then v = v + math.min(x, y) end end; return v end
local function dist(a, c)
    local v = 0
    for k, x in pairs(a) do v = v + math.abs((tonumber(x) or 0) - (tonumber(c[k]) or 0)) end
    for k, y in pairs(c) do if a[k] == nil then v = v + math.abs(tonumber(y) or 0) end end
    return v
end
-- the rival and who follows them (nil when nobody would)
function BR.splitWho(b, rivalUid)
    local people = BR.splitPeople(b)
    local leader = tostring(b.leader or "")
    local rival = nil
    if rivalUid then for _, r in ipairs(people) do if tostring(r.uid) == tostring(rivalUid) then rival = r end end end
    if rival == nil then
        -- someone the others would follow who sees things differently from the boss
        local bs, ll0 = -1e9, lensOf(leader)
        for _, r in ipairs(people) do
            if tostring(r.uid) ~= leader then local v = BR.lnfScore(b, r) + dist(lensOf(r.uid), ll0); if v > bs then rival, bs = r, v end end
        end
    end
    if rival == nil then return nil end
    local lr, ll = lensOf(rival.uid), lensOf(leader)
    local rows = {}
    for _, r in ipairs(people) do
        local u = tostring(r.uid)
        if u ~= leader and u ~= tostring(rival.uid) then
            local l = lensOf(u)
            local aff = sim(l, lr) - sim(l, ll) + (roll(u .. "#follow" .. tostring(rival.uid)) - 0.5) * 0.4
            if aff > 0 then rows[#rows + 1] = { r = r, a = aff } end
        end
    end
    table.sort(rows, function(x, y) if x.a ~= y.a then return x.a > y.a end return tostring(x.r.uid) < tostring(y.r.uid) end)
    local max = math.floor(#people * BR.num("splitMaxShare") / 100) - 1
    local go = {}
    for i = 1, math.min(max, #rows) do go[#go + 1] = rows[i].r end
    if #go < 1 then return nil end
    return rival, go
end
-- move a fair share of the stash (items and rations) from one base to another
local function shareStash(b, o, frac)
    if not (fn(M, "nbHavenOf") and fn(M, "nbStashList")) then return 0 end
    local fs, ts = M.nbStashList(M.nbHavenOf(b)), M.nbStashList(M.nbHavenOf(o), true)
    local moved = 0
    if type(fs) == "table" and type(ts) == "table" then
        local byKind = {}
        for i, it in ipairs(fs) do
            local k = fn(M, "nbKindOf") and M.nbKindOf(type(it) == "table" and it.type or it) or "other"
            byKind[k] = byKind[k] or {}
            byKind[k][#byKind[k] + 1] = i
        end
        local take = {}
        for _, idx in pairs(byKind) do
            local n = math.floor(#idx * frac)
            for j = 1, n do take[#take + 1] = idx[#idx - j + 1] end
        end
        table.sort(take, function(x, y) return x > y end)
        for _, i in ipairs(take) do ts[#ts + 1] = table.remove(fs, i); moved = moved + 1 end
    end
    local r = (tonumber(b.rations) or 0) * frac
    b.rations = (tonumber(b.rations) or 0) - r
    o.rations = (tonumber(o.rations) or 0) + r
    pcall(M.nbFoodSync, b, M.nbHavenOf(b)); pcall(M.nbFoodSync, o, M.nbHavenOf(o))
    return moved
end
function BR.splitDo(b, rival, go, reason, h)
    SS.tries = SS.tries + 1
    local people = { rival }
    for _, r in ipairs(go) do people[#people + 1] = r end
    local n = #people
    if not (fn(M, "nmFindDest") and fn(M, "nbCreate")) then return nil end
    local okD, dest = pcall(M.nmFindDest, b, n, h)
    if not okD or type(dest) ~= "table" then SS.noPlace = SS.noPlace + 1; b.b4SplitH = h - BR.num("splitGapDays") * 12; return nil end
    local crewBefore = math.max(n + 1, tonumber(b.crewN) or (n + 1))
    local okC, haven2, o = pcall(M.nbCreate, "split:" .. tostring(b.id), people, dest, h, "broke away from " .. tostring(b.name))
    if not okC or type(o) ~= "table" then BR.log("split failed for " .. tostring(b.name) .. ": " .. tostring(haven2)); return nil end
    local d = type(b.dir) == "table" and b.dir or {}
    b.dir = d
    d.ties = type(d.ties) == "table" and d.ties or {}
    o.dir = { creed = d.creed, rule = "leader", ties = { [b.id] = -40 }, goals = {} }
    d.ties[o.id] = -40
    o.leader, o.leaderName = tostring(rival.uid), firstOf(rival)
    o.faction, o.trade, o.rep = b.faction, b.trade, b.rep
    o.kinOf, o.b4SplitH, b.b4SplitH = b.id, h, h
    -- their own band (Bands would otherwise fold them back into the old one by the leader)
    if fn(M, "bandCreate") and fn(M, "bandAssign") then
        local old = (d.band and fn(M, "bandById") and M.bandById(d.band)) or (fn(M, "bandOfUid") and M.bandOfUid(b.leader)) or nil
        local okB, band = pcall(M.bandCreate, nil, old and old.origin or b.faction, tostring(rival.uid), { splinter = true, from = old and old.name or b.name, parent = old and old.id or nil })
        if okB and type(band) == "table" then
            for _, r in ipairs(people) do pcall(M.bandAssign, r.uid, band) end
            band.baseId = o.id
            o.dir.band = band.id
            o.name = band.name
        end
    end
    local items = shareStash(b, o, n / crewBefore)
    -- they walk there (dormant people only; A-Life moves them)
    if fn(M, "lvSend") then
        local dist = math.sqrt(BR.d2(b.x, b.y, dest.center.x, dest.center.y))
        for _, r in ipairs(people) do if r.lifecycle ~= "dead" and not r.virtual then pcall(M.lvSend, r.uid, { tx = dest.center.x, ty = dest.center.y, untilH = h + math.max(2, dist / 400), tag = "split" }) end end
    end
    BR.grudge(b, o.id, 25, "they walked out on us", nil, h)
    BR.grudge(o, b.id, 15, reason.w, nil, h)
    local names = firstOf(rival) .. (#go == 1 and (" and " .. firstOf(go[1])) or (" and " .. #go .. " others"))
    BR.event(b, names .. " walked out - " .. reason.w, "split")
    BR.event(o, "They broke away from " .. tostring(b.name) .. " - " .. reason.w, "split")
    if fn(BR, "worldAdd") then
        BR.worldAdd({ k = "split", text = names .. " broke away from " .. tostring(b.name) .. " and started " .. tostring(o.name) .. " - " .. reason.w, x = b.x, y = b.y, ids = { b.id, o.id } })
    end
    b.b4Contest = nil
    M.nbScanCache = nil
    SS.splits = SS.splits + 1
    if reason.k == "contest" then SS.contests = SS.contests + 1 end
    BR.log(tostring(b.name) .. " split: " .. n .. " left for " .. tostring(o.id) .. " (" .. reason.k .. "), " .. items .. " items")
    if fn(BR, "interrupt") then pcall(BR.interrupt, b, "split") end
    return o
end

----------------------------------------------------------------------------------------------------------------
-- S2 kin: easing, coming back
----------------------------------------------------------------------------------------------------------------
function BR.kinStep(o, sit, h)
    local p = o.kinOf and M.nbOf and M.nbOf(o.kinOf) or nil
    if p == nil or p.status ~= "active" then
        if p and p.movedTo then o.kinOf = p.movedTo end
        return
    end
    local tie = BR.tie(o, p)
    local war = BR.tieState(tie) == "war"
    -- a week without a war: the bad blood eases
    if not war and fn(M, "dirBumpTie") and BR.num("kinHeal") > 0 and math.floor(h / 168) ~= tonumber(o.kinWeek) then
        o.kinWeek = math.floor(h / 168)
        pcall(M.dirBumpTie, o, p, BR.num("kinHeal"))
    end
    if not BR.flag("kinRejoin") or war or h - (tonumber(o.b4SplitH) or h) < BR.num("kinRejoinDays") * 24 then return end
    local pressed = (tonumber(o.crewN) or 1) <= 2 or (type(sit) == "table" and ((tonumber(sit.dead) or 0) >= 1 or (tonumber(sit.food) or 9) < 1))
    if not pressed or tie < 0 or not farFromAll(o) or not farFromAll(p) then return end
    local cap = (M.nbCfg and M.nbCfg.memberCap) or 8
    if (tonumber(p.crewN) or 0) + (tonumber(o.crewN) or 1) > cap then return end
    if roll(o.id .. "#rejoin" .. day(h)) >= BR.num("kinRejoinChance") / 100 then return end
    BR._worldQuiet = true
    local ok, done = pcall(M.nbAbsorb, p, o, h)
    BR._worldQuiet = nil
    if not ok or not done then return end
    SS.rejoins = SS.rejoins + 1
    BR.event(p, tostring(o.name) .. " came back to them - the old quarrel let go", "rejoin")
    if fn(BR, "worldAdd") then BR.worldAdd({ k = "rejoin", text = tostring(o.name) .. " came back to " .. tostring(p.name) .. " - the old quarrel let go", x = p.x, y = p.y, ids = { p.id, o.id } }) end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the manager: once a day per group the brain runs
----------------------------------------------------------------------------------------------------------------
function BR.splitManage(b, sit, h, s, bids, far)
    if not on() or isYou(b) or s.splitDay == day(h) then return end
    s.splitDay = day(h)
    if b.kinOf and BR.kinStep(b, sit, h) then return end
    if (tonumber(b.crewN) or 0) < BR.num("splitMinCrew") then return end
    if h - (tonumber(b.b4SplitH) or -1e9) < BR.num("splitGapDays") * 24 then return end
    if not farFromAll(b) then return end
    local reasons = BR.splitReasons(b, sit, h)
    if #reasons == 0 then return end
    local contest = nil
    for _, r in ipairs(reasons) do if r.k == "contest" then contest = r end end
    local chance = BR.num("splitChance") / 100 * #reasons
    if contest then chance = math.max(chance, BR.num("contestSplit") / 100) end
    if roll(b.id .. "#b4split" .. day(h)) >= chance then return end
    local reason = contest or reasons[1 + (BR.hash(b.id .. day(h)) % #reasons)]
    local rival, go = BR.splitWho(b, reason.rival)
    if rival == nil then SS.noFollowers = SS.noFollowers + 1; return end
    BR.splitDo(b, rival, go, reason, h)
end

----------------------------------------------------------------------------------------------------------------
-- wiring
----------------------------------------------------------------------------------------------------------------
function M.b4OwnsSplits() return on() end
local function install()
    -- S3: who leads when the leader is gone
    K.wrap(M, "nbPickLeader", "BrainSuccession", function(orig) return function(crew, current, ...)
        if not BR.on() or not BR.flag("succession") or type(crew) ~= "table" or #crew == 0 then return orig(crew, current, ...) end
        for _, r in ipairs(crew) do if current and tostring(r.uid) == tostring(current) and r.lifecycle ~= "dead" then return r end end
        local m = type(crew[1].memory) == "table" and crew[1].memory or {}
        local b = m.havenId and M.nbOf and M.nbOf(m.havenId) or nil
        if b == nil or b.status ~= "active" or isYou(b) or (b.leaderName == nil and current == nil and b.b4HadLeader ~= true) then
            local r = orig(crew, current, ...)
            if b and r then b.b4HadLeader = true end
            return r
        end
        local rows = {}
        for _, r in ipairs(crew) do
            if r.lifecycle ~= "dead" and not r.virtual then local v, p = BR.lnfScore(b, r); rows[#rows + 1] = { r = r, v = v, p = p } end
        end
        if #rows == 0 then return orig(crew, current, ...) end
        table.sort(rows, function(x, y) if x.v ~= y.v then return x.v > y.v end return tostring(x.r.uid) < tostring(y.r.uid) end)
        local win = rows[1]
        SS.successions = SS.successions + 1
        local why = whyWon(b, win.p)
        if fn(BR, "worldAdd") then BR.worldAdd({ k = "leader", text = firstOf(win.r) .. " leads " .. tostring(b.name) .. " now - " .. why, x = b.x, y = b.y, ids = { b.id } }) end
        local second = rows[2]
        if second and #rows >= BR.num("splitMinCrew") and second.v >= win.v * 0.85 and second.v > 0 then
            b.b4Contest = { w = tostring(win.r.uid), wName = firstOf(win.r), r = tostring(second.r.uid), h = hours() }
            BR.event(b, firstOf(second.r) .. " wanted to lead too. Not everyone is behind " .. firstOf(win.r), "leader")
        end
        b.b4HadLeader = true
        return win.r
    end end)
    local have = false
    for _, mg in ipairs(BR.managers or {}) do if mg.name == "splits" then have = true end end
    if not have and type(BR.managers) == "table" then BR.managers[#BR.managers + 1] = { name = "splits", f = BR.splitManage } end
    return true
end
BR.installers[#BR.installers + 1] = install
pcall(install)
do
    local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBrainSplit")
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(install)
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": real splits " .. (on() and "on" or "off") .. ", succession " .. (BR.flag("succession") and "love/need/fear" or "old")
                .. ", rejoin " .. (BR.flag("kinRejoin") and "on" or "off"))
        end)
    end
end
