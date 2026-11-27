-- A-Life NPC Overhaul pre-1.0: BRAIN 2, R5 SPYING AND LIES, BOTH WAYS (docs/PLAN-BRAIN-2.md).
--   * NPC lies on the radio: a group under pressure bluffs (says it's stronger than it is); a group out to dominate
--     spreads bait ("Ridge is starving", "Ridge is falling apart") about a rival so someone else does the hitting. The
--     ones who hear it believe it like any other rumour, your camp too ("What we know" can be wrong).
--   * wrong found out: when a sure look (scout, fight, traders) disagrees with what a liar said, the belief is marked
--     "turned out to be wrong", the liar is trusted less (what they say counts for less from then on), and the ones
--     lied to hold it against them.
--   * decoys: a group whose traders keep getting robbed sends armed people with nothing worth taking down that road;
--     an ambush that hits them gets a fight and nothing else.
--   * feints: a careful leader sends one or two ahead to make noise at the place a few hours early; the defenders look
--     the wrong way when the real party comes (they defend worse).
--   * spies: a trader from a group with designs on you stays at your trading post to look around (a sure look at your
--     camp). Your guards may catch them: a card (let it go / run them off).
--   * your side: "Spread word" on the radio (rumours about a group to everyone in range; caught lies cost you their
--     trust, the brain's claim check), decoys by standing order (Orders page). Your feints: walk with your war party.
-- Settings: brainLies, spies, decoys, feints, liesPerWeek. World side (server in MP).
require "ALifeNPCOverhaul/ALifeBrainFight"
pcall(require, "ALifeNPCOverhaul/ALifeBrainKnow")
if ALifeCampKit == nil then pcall(require, "ALifeNPCOverhaul/ALifeCampKit") end
local BR = ALifeBrain
local M = BR and BR.M
local K = ALifeCampKit
if type(BR) ~= "table" or type(M) ~= "table" or type(K) ~= "table" then return end
local fn, hours, d2, clamp, roll = BR.fn, BR.hours, BR.d2, BR.clamp, BR.roll
local TAG = "[ALifeBrainLies]"
local function T() return ALifeTrade end

BR.defaults({
    brainLies = true,   -- groups lie on the radio (bluffs, bait about rivals); what you hear can be wrong
    spies = true,       -- traders from groups with designs on you look around your place
    decoys = true,      -- groups robbed on a road send armed decoys down it
    feints = true,      -- careful leaders send a few ahead to draw the defenders' eyes
    liesPerWeek = 1,    -- most lies a group tells in a week
})
BR.addRows({
    { "brainLies", "Brain lies: groups bluff and spread bait on the radio; what you hear can be wrong" },
    { "spies", "Brain lies: traders from groups with designs on you look around your place" },
    { "decoys", "Brain lies: groups robbed on a road send armed decoys down it" },
    { "feints", "Brain lies: careful leaders send a few ahead to draw the defenders' eyes" },
    { "liesPerWeek", "Brain lies: most lies a group tells in a week", { 0, 1, 2 } },
})
BR.lieStats = BR.lieStats or { bluffs = 0, baits = 0, caught = 0, decoys = 0, decoyHit = 0, feints = 0, spied = 0, spyCaught = 0, rumours = 0 }
local LS = BR.lieStats
local SURE = { scout = true, fight = true, trade = true, spy = true, caught_scout = true }

----------------------------------------------------------------------------------------------------------------
-- beliefs that carry who said them: a lie is a rumour with lieBy / lieF, found out by the next sure look
----------------------------------------------------------------------------------------------------------------
local function differs(lieF, fields)
    if type(lieF) ~= "table" then return false end
    if lieF.str and tonumber(fields.str) and fields.str > 0 then local r = lieF.str / fields.str; if r > 1.6 or r < 0.6 then return true end end
    if lieF.food and tonumber(fields.food) and math.abs(lieF.food - fields.food) > 3 then return true end
    if lieF.hostile ~= nil and fields.hostile ~= nil and lieF.hostile ~= fields.hostile then return true end
    return false
end
-- how much this group still believes what `via` tells it (halved per lie caught)
function BR.trustIn(b, via)
    local s = type(b) == "table" and type(b.brain) == "table" and b.brain or nil
    local n = s and type(s.liars) == "table" and tonumber(s.liars[tostring(via)]) or 0
    return 0.5 ^ (n or 0)
end
function BR.lieCaught(b, k, id, h)
    local by = k.lieBy
    k.wrong = { h = h, by = by }
    k.lieBy, k.lieF = nil, nil
    LS.caught = LS.caught + 1
    local s = BR.of(b)
    s.liars = type(s.liars) == "table" and s.liars or {}
    s.liars[tostring(by)] = (tonumber(s.liars[tostring(by)]) or 0) + 1
    local liar = BR.home(by)
    local about = BR.home(id)
    local aboutName = about and tostring(about.name) or "them"
    if b.isCamp then
        if fn(BR, "youReport") then BR.youReport("What we heard about " .. aboutName .. " turned out to be wrong" .. (liar and (" - " .. tostring(liar.name) .. " lied to us") or ""), "brain", true) end
    elseif liar and not liar.isCamp then
        BR.grudge(b, by, 10, "lied to them")
        if fn(M, "dirTieAdd") then pcall(M.dirTieAdd, b, liar, -10) end
        BR.event(b, "Found out " .. tostring(liar.name) .. " lied to them about " .. aboutName, "brain")
    end
end
local function install()
    K.wrap(BR, "learn", "BrainLiesLearn", function(orig) return function(b, id, fields, conf, src, h, ...)
        if type(b) ~= "table" or type(fields) ~= "table" then return orig(b, id, fields, conf, src, h, ...) end
        h = h or hours()
        local s = BR.of(b)
        local prev = s.know[tostring(id)]
        local lieBy, lieF = prev and prev.lieBy, prev and prev.lieF
        -- a known liar's word counts for less
        if fields.via ~= nil then conf = (tonumber(conf) or 0) * BR.trustIn(b, fields.via) end
        local k = orig(b, id, fields, conf, src, h, ...)
        if type(k) ~= "table" then return k end
        if fields.lieBy ~= nil and k.src == src then
            k.lieBy, k.lieF = fields.lieBy, { str = fields.str, food = fields.food, hostile = fields.hostile }
            k.wrong = nil
        elseif lieBy ~= nil and (tonumber(conf) or 0) >= 0.75 and SURE[tostring(src)] then
            k.lieBy, k.lieF = lieBy, lieF
            if differs(lieF, fields) then BR.lieCaught(b, k, tostring(id), h) else k.lieBy, k.lieF = nil, nil end
        end
        return k
    end end)
    -- the what-we-know page: a belief that turned out wrong says so
    K.wrap(BR, "youKnowView", "BrainLiesView", function(orig) return function(player, ...)
        local out = orig(player, ...)
        local cb = BR.youRec()
        local know = type(cb.brain) == "table" and cb.brain.know or {}
        for _, r in ipairs(type(out) == "table" and out or {}) do
            local k = r.k == "g" and know[tostring(r.id)] or nil
            if type(k) == "table" and type(k.wrong) == "table" then
                r.wrong = true
                local liar = BR.home(k.wrong.by)
                r.src = tostring(r.src) .. "; what we heard before turned out to be wrong" .. (liar and (" (" .. tostring(liar.name) .. " lied)") or "")
            end
        end
        return out
    end end)
    if type(ALifeRemote) == "table" and fn(ALifeRemote, "view") and fn(BR, "youKnowView") then ALifeRemote.view("byKnow", BR.youKnowView, {}) end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- NPC lies on the radio (once a day per group, liesPerWeek at most)
----------------------------------------------------------------------------------------------------------------
local function radioReach(b)
    local out = {}
    local r2 = BR.num("knowRadioTiles") ^ 2
    for _, o in ipairs(fn(M, "nbActive") and M.nbActive() or {}) do
        if o.id ~= b.id and tonumber(o.x) and tonumber(b.x) and d2(o.x, o.y, b.x, b.y) <= r2 and BR.runs(o) then out[#out + 1] = o end
    end
    if fn(BR, "youRec") then
        local cb = BR.youRec()
        if tonumber(cb.x) and tonumber(b.x) and d2(cb.x, cb.y, b.x, b.y) <= r2 then out[#out + 1] = cb end
    end
    return out
end
local function told(b, h)
    local s = BR.of(b)
    s.lies = type(s.lies) == "table" and s.lies or {}
    local keep = {}
    for _, t in ipairs(s.lies) do if h - t < 24 * 7 then keep[#keep + 1] = t end end
    s.lies = keep
    return #keep
end
function BR.lieDay(b, h)
    if not BR.flag("brainLies") or not BR.runs(b) or told(b, h) >= BR.num("liesPerWeek") then return nil end
    local s = BR.of(b)
    local w = BR.w(b, h)
    local truth = BR.truth(b.id)
    if truth == nil then return nil end
    local day = math.floor(h / 24)
    -- a bluff: pressed hard, threatened, and not too proud to pretend
    if (s.pressure >= 40 or s.threatBy) and roll(b.id .. "bluff" .. day) < 0.25 * (w.caution or 1) then
        for _, o in ipairs(radioReach(b)) do
            BR.hear(o, b.id, { x = truth.x, y = truth.y, name = truth.name, str = (tonumber(truth.str) or 4) * 2, hostile = truth.hostile, lieBy = b.id, via = b.id }, 0.4, "radio", b.x, b.y, h)
        end
        s.lies[#s.lies + 1] = h
        LS.bluffs = LS.bluffs + 1
        BR.log(tostring(b.name) .. " bluffs on the radio")
        return "bluff"
    end
    -- bait: out to dominate (or holding a grudge), they talk a rival down so someone else hits them
    if s.stance == "dominate" or s.stance == "revenge" then
        local rival = s.stance == "revenge" and BR.topGrudge(b, h) or nil
        if rival == nil then local sit = s.sit; rival = type(sit) == "table" and sit.prey or nil end
        local ro = rival and BR.base(rival) or nil
        if ro and roll(b.id .. "bait" .. day) < 0.3 * (w.aggression or 1) then
            local rt = BR.truth(ro.id) or {}
            local fake = (roll(b.id .. "kind" .. day) < 0.5) and { food = 0.5 } or { str = (tonumber(rt.str) or 4) * 0.4 }
            fake.x, fake.y, fake.name, fake.lieBy, fake.via = ro.x, ro.y, ro.name, b.id, b.id
            for _, o in ipairs(radioReach(b)) do if o.id ~= ro.id then BR.hear(o, ro.id, fake, 0.4, "radio", b.x, b.y, h) end end
            s.lies[#s.lies + 1] = h
            LS.baits = LS.baits + 1
            BR.log(tostring(b.name) .. " spreads bait about " .. tostring(ro.name))
            return "bait"
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- decoys: armed people, nothing to take, down the road where they were robbed
----------------------------------------------------------------------------------------------------------------
BR.tool({ id = "decoy", job = "war", minPeople = 2, maxPeople = 4,
    start = function(b, people, target)
        if type(target) ~= "table" or target.to == nil or not BR.flag("decoys") then return false end
        local run = BR.launch(b, "decoy", target.to, people, hours(), { goal = "decoy" })
        if run then
            run.items, run.packs, run.decoy = {}, {}, true
            run.escorts = #run.crew
            LS.decoys = LS.decoys + 1
            BR.event(b, "Sent armed people down the road to " .. (target.to == "you" and "your place" or tostring((BR.base(target.to) or {}).name or "the next place")) .. " with nothing worth stealing", "brain")
        end
        return run ~= nil
    end })
function BR.decoyBid(b, sit, h, s, bids)
    if not BR.flag("decoys") or b.isCamp or (tonumber(b.crewN) or 0) < 4 or s.stance == "survive" then return end
    if h - (tonumber(s.decoyH) or -1e9) < 24 * 7 then return end
    for _, r in ipairs(fn(T(), "runsOf") and T().runsOf(b.id) or {}) do if r.kind == "decoy" or r.kind == "war" then return end end
    local worst, wn = nil, 1
    for key, m in pairs(s.memory or {}) do
        local to = string.match(tostring(key), "^trade:(.+)$")
        if to and BR.base(to) and (tonumber(m.robbed) or 0) > wn then worst, wn = to, tonumber(m.robbed) end
    end
    if worst == nil then return end
    s.decoyH = h
    bids[#bids + 1] = { job = "war", n = 3, value = 1.8, tool = "decoy", target = { to = worst }, key = "decoy", force = true }
end

----------------------------------------------------------------------------------------------------------------
-- feints: one or two go ahead, make noise, run; the real party comes a few hours later
----------------------------------------------------------------------------------------------------------------
BR.FEINT_LEAD = 3 -- hours the feint arrives before the real party
function BR.feintFor(b, people, target)
    if not BR.flag("feints") or type(target) ~= "table" or target.to == nil or target.goal == "siege" or #(people or {}) < 4 then return false end
    if b.isCamp then return false end -- your war parties: you plan those yourself (walk with them, R1)
    local w, disc = BR.w(b, hours())
    local l = fn(M, "lens") and M.lens(b.leader or (b.roster and b.roster[1] and b.roster[1].u) or "") or {}
    return (tonumber(disc) or 0) >= 0.4 or (tonumber(l.calm) or 0) + (tonumber(l.disciplined) or 0) >= 0.6
end
local function installFeints()
    K.wrap(BR, "call", "BrainLiesFeint", function(orig) return function(id, b, people, target, opts, ...)
        if id ~= "warParty" or type(b) ~= "table" or not BR.feintFor(b, people, target) then return orig(id, b, people, target, opts, ...) end
        local main, ahead = {}, {}
        for i, u in ipairs(people) do if i == #people then ahead[#ahead + 1] = u else main[#main + 1] = u end end
        local a, c = orig(id, b, main, target, opts, ...)
        if not a then return a, c end
        -- the real party starts a few hours behind
        local t = T()
        local mainRun = nil
        for _, r in ipairs(fn(t, "runsOf") and t.runsOf(b.id) or {}) do if r.kind == "war" and r.target == target.to and not r.feint then mainRun = r end end
        local f = BR.launch(b, "war", target.to, ahead, hours(), { goal = "feint" })
        if f and mainRun then
            f.feint = true
            mainRun.arrive = mainRun.arrive + BR.FEINT_LEAD
            for _, u in ipairs(mainRun.crew) do pcall(M.lvSend, u, { tx = mainRun.x1, ty = mainRun.y1, untilH = mainRun.arrive, tag = "brain_war" }) end
            LS.feints = LS.feints + 1
        end
        return a, c
    end end)
    -- the feint arrives: noise, the defenders look its way, it runs
    K.wrap(BR, "warArrive", "BrainLiesFeintArrive", function(orig) return function(run, b, h, ...)
        if type(run) == "table" and run.goal == "feint" then
            local o = BR.base(run.target)
            if o then
                local so = BR.of(o)
                so.feinted = { by = run.from, untilH = h + BR.FEINT_LEAD + 3 }
                so.incoming = { by = run.from, untilH = h + 12 }
                BR.event(o, "A few of " .. tostring(b.name) .. "'s people made noise at the edge of the place and ran off", "war")
            elseif run.target == "you" then
                BR.campLetter("Shots and shouting at the edge of your place, then nothing. Someone's testing you.", true)
            end
            run.won = nil
            return
        end
        BR._feintBy = type(run) == "table" and run.from or nil
        local r = orig(run, b, h, ...)
        BR._feintBy = nil
        return r
    end end)
    -- looking the wrong way: the defenders' strength against the party that feinted is down
    K.wrap(BR, "defStr", "BrainLiesDefStr", function(orig) return function(o, h, ...)
        local v = orig(o, h, ...)
        local s = type(o) == "table" and type(o.brain) == "table" and o.brain or nil
        if s and type(s.feinted) == "table" and BR._feintBy ~= nil and s.feinted.by == BR._feintBy and (h or hours()) < (tonumber(s.feinted.untilH) or 0) then return (tonumber(v) or 0) * 0.7 end
        return v
    end end)
    -- a feint never starts a real fight on screen (it's one or two people making noise)
    K.wrap(BR, "fightWanted", "BrainLiesFeintFight", function(orig) return function(run, ...)
        if type(run) == "table" and run.goal == "feint" then return false end
        return orig(run, ...)
    end end)
    return true
end

----------------------------------------------------------------------------------------------------------------
-- spies at your trading post
----------------------------------------------------------------------------------------------------------------
local function designs(b, h)
    local s = BR.of(b)
    if (tonumber(b.rep) or 50) <= 35 then return true end
    if BR.grudgeV(b, "you", h) >= 20 then return true end
    local sit = s.sit
    return (s.stance == "dominate" or s.stance == "revenge") and type(sit) == "table" and sit.prey == "you"
end
function BR.spyAt(run, h)
    if not BR.flag("spies") or type(run) ~= "table" or run.from == "you" then return nil end
    local b = BR.base(run.from)
    if b == nil or not BR.runs(b) or not designs(b, h) then return nil end
    if roll(run.id .. "spy") >= 0.5 then return nil end
    local t = BR.truth("you")
    if t == nil then return nil end
    BR.learn(b, "you", t, 0.9, "spy", h)
    LS.spied = LS.spied + 1
    local uid = run.crew and run.crew[1] or nil
    -- caught? guards on watch at your camp, or you nearby
    local guards = 0
    if fn(BR, "youTargets") then local a = BR.youTargets(); guards = a and tonumber(a.guard) or 0 end
    if roll(run.id .. "caught") < 0.2 + 0.15 * math.min(3, guards) then
        LS.spyCaught = LS.spyCaught + 1
        local name = uid and K.first(uid) or "One of their traders"
        local who = tostring(b.name)
        local cb = fn(BR, "youRec") and BR.youRec() or nil
        if cb then BR.learn(cb, b.id, { x = b.x, y = b.y, name = b.name, hostile = true }, 0.6, "caught_scout", h) end
        BR.campCard({ id = "brainSpy:" .. tostring(run.id), title = name .. " was snooping around", default = 1,
            text = "One of ours caught " .. name .. " from " .. who .. " poking around the camp instead of trading: counting heads, looking at the walls, where we keep things. <LINE> <LINE> Whatever they saw, " .. who .. " knows it now.",
            choices = {
                { label = "Let it go", fn = function() end },
                { label = "Run them off", fn = function()
                    local k = type(b.brain) == "table" and b.brain.know and b.brain.know.you or nil
                    if type(k) == "table" then k.conf = math.min(tonumber(k.conf) or 0, 0.4) end
                    if fn(M, "nbRep") then pcall(M.nbRep, b, -5, "You ran off one of their people") end
                    BR.grudge(b, "you", 5, "ran off their trader")
                    if uid then K.say(uid, "All right, all right. I'm going.") end
                end },
            } })
        return "caught"
    end
    return "spied"
end

----------------------------------------------------------------------------------------------------------------
-- your side: rumours on the radio (to every group in range), decoys and feints by order
----------------------------------------------------------------------------------------------------------------
BR.RUMOURS = {
    weak = { words = "is weak", f = function(t) return { str = (t.str or 4) * 0.4 } end },
    strong = { words = "is strong", f = function(t) return { str = (t.str or 4) * 2 } end },
    starving = { words = "is starving", f = function() return { food = 0.5 } end },
    rich = { words = "is sitting on a lot", f = function(t) return { wealth = 2, food = math.max(8, t.food or 8) } end },
    hostile = { words = "is coming for you", f = function() return { hostile = true } end },
    friendly = { words = "means no harm", f = function() return { hostile = false } end },
}
BR.RUMOUR_ORDER = { "weak", "strong", "starving", "rich", "hostile", "friendly" }
function BR.youRumour(player, aboutId, kind)
    local row = BR.RUMOURS[tostring(kind)]
    local about = BR.base(aboutId)
    if row == nil or about == nil or not fn(M, "rcRadio") or not fn(M, "rcInRange") then return 0 end
    local range = M.rcRadio(player)
    if range == nil then return 0 end
    local h = hours()
    local n = 0
    for _, b in ipairs(M.rcInRange(player, range)) do
        if b.id ~= about.id and BR.runs(b) and (tonumber(b.rep) or 50) > 20 then
            local s = BR.of(b)
            local trust = (tonumber(s.youTrust) or 50) / 100 * clamp((tonumber(b.rep) or 50) / 60, 0.2, 1.2)
            local cur = BR.belief(b, about.id, h) or {}
            local f = row.f(cur)
            f.x, f.y, f.name = about.x, about.y, about.name
            local c = clamp(trust, 0.1, 0.6)
            if (tonumber(cur.c) or 0) <= c then BR.learn(b, about.id, f, c, "you", h); n = n + 1 end
        end
    end
    LS.rumours = LS.rumours + 1
    local said = "[Radio] You put the word out: " .. tostring(about.name) .. " " .. row.words .. ". " .. (n > 0 and "Someone's listening." or "Nobody seems to care.")
    -- MP: to the one who said it (their screen); SP: the radio line as before
    if ALifeSide.mpServer() and type(ALifeOut) == "table" and fn(ALifeOut, "radio") then pcall(ALifeOut.radio, player, said)
    elseif fn(M, "radioLine") then pcall(ALifeSide.with, player, M.radioLine, nil, said) end
    return n
end
M.byRumour = function(aboutId, kind, player) return BR.youRumour(player or ALifeSide.you(), aboutId, kind) end
if type(ALifeRemote) == "table" and fn(ALifeRemote, "expose") then ALifeRemote.expose("byRumour", 2, 3) end
-- the radio menu: "Spread word" about every group your camp knows
local function installMenu()
    if not fn(M, "rcFill") or M._alcpHooks == nil or M._alcpHooks.brainRumourMenu then return M._alcpHooks and M._alcpHooks.brainRumourMenu == true end
    M._alcpHooks.brainRumourMenu = true
    local fill = M.rcFill
    M.rcFill = function(playerNum, context, worldobjects, test, ...)
        local r = fill(playerNum, context, worldobjects, test, ...)
        if test ~= true and BR.flag("brainLies") and type(context) == "table" and type(context.addOption) == "function" then
            pcall(function()
                local player = getSpecificPlayer(playerNum or 0)
                if player == nil or not fn(M, "rcRadio") or M.rcRadio(player) == nil then return end
                local rows = {}
                if type(ALifeRemote) == "table" then for _, x in ipairs(ALifeRemote.get("byKnow", player) or {}) do if type(x) == "table" and x.k == "g" then rows[#rows + 1] = x end end end
                if #rows == 0 then return end
                local opt = context:addOption(ALifeTr and ALifeTr("IGUI_ALCP_RadioRumour", "Spread word on the radio") or "Spread word on the radio", nil, nil)
                local sub = ISContextMenu:getNew(context)
                context:addSubMenu(opt, sub)
                for _, g in ipairs(rows) do
                    local o2 = sub:addOption(tostring(g.name), nil, nil)
                    local s2 = ISContextMenu:getNew(sub)
                    sub:addSubMenu(o2, s2)
                    for _, kind in ipairs(BR.RUMOUR_ORDER) do
                        s2:addOption(tostring(g.name) .. " " .. BR.RUMOURS[kind].words, { id = g.id, k = kind }, function(x) M.byRumour(x.id, x.k, player) end)
                    end
                end
            end)
        end
        return r
    end
    return true
end

----------------------------------------------------------------------------------------------------------------
-- hooks: the daily lie, decoy bids, decoys in ambushes, spies on legs to you, the camp's orders
----------------------------------------------------------------------------------------------------------------
local function installAll()
    install()
    installFeints()
    pcall(installMenu)
    M._alcpHooks = M._alcpHooks or {}
    K.wrap(BR, "knowDay", "BrainLiesDay", function(orig) return function(b, h, ...)
        local r = orig(b, h, ...)
        if not (type(b) == "table" and b.isCamp) then pcall(BR.lieDay, b, h) end
        return r
    end end)
    -- decoy bids ride the roads manager slot (after military)
    local have = false
    for _, mg in ipairs(BR.managers or {}) do if mg.name == "decoys" then have = true end end
    if not have and type(BR.managers) == "table" then BR.managers[#BR.managers + 1] = { name = "decoys", f = BR.decoyBid } end
    -- an ambush that hits a decoy: they fight like a war party, and there's nothing to take
    K.wrap(BR, "ambushSpring", "BrainLiesDecoy", function(orig) return function(a, b, run, h, ...)
        if type(run) == "table" and run.decoy then
            LS.decoyHit = LS.decoyHit + 1
            run.str0 = run.str0 or (BR.str(BR.home(run.from) or {}) * #run.crew / math.max(1, tonumber((BR.home(run.from) or {}).crewN) or 1))
            local r = orig(a, b, run, h, ...)
            if a.won ~= true then BR.event(b, "Their ambush hit a decoy: armed people and nothing to take", "war") end
            return r
        end
        return orig(a, b, run, h, ...)
    end end)
    local t = T()
    if type(t) == "table" and type(t.onLeg) == "table" and not t._brainLiesLeg then
        t._brainLiesLeg = true
        t.onLeg[#t.onLeg + 1] = function(run, leg, gave, got, why)
            if BR.on() and type(leg) == "table" and leg.to == "you" and run.from ~= "you" and not run.brain then pcall(BR.spyAt, run, hours()) end
        end
    end
    -- the camp: decoys and feints are standing orders
    if type(BR.ORDER_DEFS) == "table" and BR.ORDER_BY and BR.ORDER_BY.decoys == nil then
        local d1 = { key = "decoys", group = "war", label = "Send decoys down roads where we were robbed" }
        BR.ORDER_DEFS[#BR.ORDER_DEFS + 1] = d1; BR.ORDER_BY.decoys = d1
    end
    if type(BR.YOU_TOOLS) == "table" then BR.YOU_TOOLS.decoy = true end
    K.wrap(BR, "youOrderBids", "BrainLiesYouDecoy", function(orig) return function(cb, sit, h, s, bids, ...)
        local r = orig(cb, sit, h, s, bids, ...)
        if BR.flag("decoys") and fn(BR, "youOrder") and BR.youOrder("decoys") == true and h - (tonumber(s.decoyH) or -1e9) >= 24 * 7 then
            local worst, wn = nil, 0
            for key, m in pairs(s.memory or {}) do
                local to = string.match(tostring(key), "^trade:(.+)$")
                if to and BR.base(to) and (tonumber(m.robbed) or 0) > wn then worst, wn = to, tonumber(m.robbed) end
            end
            if worst then s.decoyH = h; bids[#bids + 1] = { job = "war", n = 3, value = 1.8, tool = "decoy", target = { to = worst }, key = "decoy", orderGo = true } end
        end
        return r
    end end)
    -- a decoy by your order goes without a card (it's your order)
    K.wrap(BR, "youVerdict", "BrainLiesYouVerdict", function(orig) return function(cb, x, sit, h, ...)
        if type(x) == "table" and x.tool == "decoy" and x.orderGo then return "go" end
        return orig(cb, x, sit, h, ...)
    end end)
    return true
end
BR.installers[#BR.installers + 1] = installAll
pcall(installAll)
do
    local Events = ALifeSide.hooks("world", "ALifeBrainLies")
    if type(Events) == "table" and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(installAll)
            print(TAG .. " ready v" .. tostring(ALifeSide.MOD_VERSION) .. ": lies " .. (BR.flag("brainLies") and "on" or "off") .. ", spies " .. (BR.flag("spies") and "on" or "off")
                .. ", decoys " .. (BR.flag("decoys") and "on" or "off") .. ", feints " .. (BR.flag("feints") and "on" or "off"))
        end)
    end
end
