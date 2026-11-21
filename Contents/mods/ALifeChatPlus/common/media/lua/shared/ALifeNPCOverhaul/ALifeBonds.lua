-- A-Life Bonds: three separate bonds per NPC - Love, Fear, Necessity - with logarithmic stages.
-- Driven by what actually happens in A-Life (its deed funnel NpcOpinion.note, its talk verdicts TalkSocial.ask,
-- time spent near you, and Jeem Extension residency). Saved in the world (global ModData "ALifeBonds").
--
--   Love       time together, help, gifts, kindness, keeping your word; romance grows only once they like you.
--   Fear       hurting/robbing their people, threats while you hold power. (Faction deals & captives: phase 2.)
--   Necessity  shelter at your base, food, water, medicine, being saved.
--
-- Effects in A-Life: Love raises their opinion of you, Fear and Necessity make them more likely to obey orders.
-- Stages need double the points of the last one: 10, 30, 70, 150, 310.

require "ALifeNPCOverhaul/AA_Side"
local TAG = "[ALifeBonds]"
local VERSION = ALifeSide.MOD_VERSION

ALifeBonds = ALifeBonds or {}
local B = ALifeBonds
B.version = VERSION

B.STEPS = { 10, 30, 70, 150, 310 }
B.NAMES = {
    l = { "Stranger", "Acquaintance", "Friend", "Close", "Devoted", "Inseparable" },
    f = { "Unafraid", "Uneasy", "Wary", "Afraid", "Cowed", "Broken" },
    n = { "Independent", "Helped", "Reliant", "Dependent", "Bound", "Lifeline" },
}
B.PARTNER_LOVE_STAGE = 4      -- Devoted
B.PARTNER_ROMANCE = 40
B.ROMANCE_OPEN_STAGE = 2      -- they must be at least a Friend before flirting lands

-- deeds A-Life reports -> { love, fear, necessity }
B.DEEDS = {
    gift = { 2, 0, 4 }, medicine = { 4, 0, 6 }, help_fight = { 6, 0, 2 }, saved = { 10, 0, 10 },
    trade = { 1, 0, 1 }, promise = { 3, 0, 0 }, door_kind = { 2, 0, 3 }, walk = { 2, 0, 0 },
    party_task = { 3, 0, 1 }, threat_failed = { -3, 1, 0 }, rude = { -2, 0, 0 },
    robbery = { -10, 12, 0 }, hit = { -8, 8, 0 }, killed_mate = { -25, 20, 0 }, betrayal = { -30, 0, -10 },
    party_fail = { -2, 0, 0 }, party_desert = { -6, 0, -4 },
}
-- talk intents (A-Life already decided whether it went over well; this is the bond side)
B.TALK = {
    COMPLIMENT = { 1, 0, 0 }, THANKS = { 0.5, 0, 0 }, SORRY = { 0.5, 0, 0 }, ENCOURAGE = { 1, 0, 0 },
    ASK_OKAY = { 1, 0, 0 }, HOW_ARE_YOU = { 0.5, 0, 0 }, ASK_FAMILY = { 0.5, 0, 0 }, ASK_MISS = { 0.5, 0, 0 },
    TELL_STORY = { 0.5, 0, 0 }, ASK_JOB_BEFORE = { 0.5, 0, 0 }, OFFER_HELP = { 1, 0, 0.5 },
    INSULT = { -3, 0, 0 }, THREATEN = { -4, 2, 0 }, GO_AWAY = { -1, 0, 0 },
}
B.TALK_DAILY_CAP = 6          -- love from words per NPC per day
B.NEAR_TILES = 6
B.NEAR_DAILY_CAP = 6          -- love from time together per NPC per day
B.WITNESS_TILES = 20

B.metrics = { deeds = 0, talks = 0, ticks = 0, partners = 0 }

-- ---------------------------------------------------------------- guard ----
local disabled = {}
local function tryOnce(id, fn, ...)
    if disabled[id] then return false, nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return true, a, b end
    disabled[id] = true
    print(TAG .. " " .. id .. " failed, disabled for this session: " .. tostring(a))
    return false, nil
end

local function hours()
    if type(getGameTime) == "function" then
        local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
        if ok and h then return h end
    end
    return 0
end

-- ---------------------------------------------------------------- store ----
local store
function B.store()
    if store ~= nil then return store end
    if ModData ~= nil and type(ModData.getOrCreate) == "function" then store = ModData.getOrCreate("ALifeBonds")
    else store = B._mem or {}; B._mem = store end
    store.p = store.p or {}
    return store
end

local function keyOf(player)
    local op = ProjectALife and ProjectALife.NpcOpinion
    if op ~= nil and type(op.keyOf) == "function" then
        local ok, k = pcall(op.keyOf, player)
        if ok and k ~= nil then return tostring(k) end
    end
    if type(player) == "string" then return player end
    return nil
end
B.keyOf = keyOf

local function uidOf(ref)
    if type(ref) == "string" then return ref end
    if type(ref) == "table" and ref.uid ~= nil then return tostring(ref.uid) end
    return nil
end

function B.row(key, uid, create)
    if key == nil or uid == nil then return nil end
    local s = B.store()
    local mine = s.p[key]
    if mine == nil then
        if not create then return nil end
        mine = {}; s.p[key] = mine
    end
    local r = mine[uid]
    if r == nil and create then
        r = { l = 0, f = 0, n = 0, r = 0, at = hours() }
        mine[uid] = r
    end
    return r
end

function B.stageOf(points)
    local p = tonumber(points) or 0
    local s = 0
    for i = 1, #B.STEPS do if p >= B.STEPS[i] then s = i end end
    return s
end

function B.nameOf(kind, points)
    return B.NAMES[kind][B.stageOf(points) + 1]
end

-- next threshold for a progress bar
function B.nextOf(points)
    local p = tonumber(points) or 0
    for i = 1, #B.STEPS do if p < B.STEPS[i] then return B.STEPS[i] end end
    return nil
end

-- ------------------------------------------------------------- notices -----
local function notify(player, text, good)
    if ALifeImmersion ~= nil and ALifeImmersion.enabled then return end   -- immersion: read it from people, not pop-ups
    if player == nil or type(player) ~= "userdata" and type(player) ~= "table" then return end
    pcall(function()
        if HaloTextHelper ~= nil then
            if type(ALifeLetter) == "function" then return ALifeLetter(player, text, 170, 210, 170, good == false) end
            if good == false and type(HaloTextHelper.addBadText) == "function" then return HaloTextHelper.addBadText(player, text) end
            if type(HaloTextHelper.addText) == "function" then return HaloTextHelper.addText(player, text) end
        end
    end)
end

local function displayName(r)
    return (r ~= nil and type(r.name) == "string" and r.name ~= "") and r.name or "They"
end

-- -------------------------------------------------------------- change -----
local function decayed(r)
    local now = hours()
    local days = (now - (tonumber(r.at) or now)) / 24
    if days >= 1 then
        -- love fades slowly without contact (after 3 days), necessity faster, fear fastest
        if days > 3 then r.l = math.max(0, r.l - (days - 3) * math.max(0.5, r.l * 0.01)) end
        if not r.home then r.n = math.max(0, r.n - days * math.max(1, r.n * 0.04)) end
        r.f = math.max(0, r.f - days * math.max(1, r.f * 0.08))
        r.at = now
    end
    return r
end

-- apply a change; returns the row. who = { player=, record= } for notices / names
function B.change(key, uid, dl, df, dn, who)
    local r = B.row(key, uid, true)
    if r == nil then return nil end
    decayed(r)
    if type(who) == "table" and type(who.record) == "table" then
        local names = ProjectALife and ProjectALife.Names
        local ok, n = pcall(function() return names and names.of(who.record) end)
        if ok and n then r.name = tostring(n) end
        r.fac = who.record.factionId or r.fac
    end
    local before = { l = B.stageOf(r.l), f = B.stageOf(r.f), n = B.stageOf(r.n) }
    r.l = math.max(0, r.l + (dl or 0))
    r.f = math.max(0, r.f + (df or 0))
    r.n = math.max(0, r.n + (dn or 0))
    local player = type(who) == "table" and who.player or nil
    for _, k in ipairs({ "l", "f", "n" }) do
        local after = B.stageOf(r[k])
        if after ~= before[k] then
            local label = ({ l = "Love", f = "Fear", n = "Need" })[k]
            notify(player, displayName(r) .. ": " .. label .. " - " .. B.NAMES[k][after + 1], after > before[k] and k ~= "f")
        end
    end
    -- partner falls apart if love drops too far
    if r.partner and B.stageOf(r.l) < B.PARTNER_LOVE_STAGE - 1 then
        r.partner = nil
        notify(player, displayName(r) .. " is no longer your partner", false)
    end
    return r
end

function B.partners(key)
    local out = {}
    local mine = B.store().p[key]
    if mine == nil then return out end
    for uid, r in pairs(mine) do if r.partner then out[#out + 1] = uid end end
    return out
end

-- ---------------------------------------------------------- live shells -----
local function liveShells()
    local wd = ProjectALife and ProjectALife.Watchdog
    return (wd ~= nil and type(wd.bindings) == "table") and wd.bindings or nil
end

local function dist2(a, b)
    local ok, d = pcall(function()
        local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
        return dx * dx + dy * dy
    end)
    return ok and d or 1e12
end

local function readRecord(uid)
    local reg = ProjectALife and ProjectALife.ActorRegistry
    if reg == nil or type(reg.read) ~= "function" then return nil end
    local ok, r = pcall(reg.read, uid)
    return ok and r or nil
end

-- partners / residents near the player who saw something and react
local function witnesses(key, player, exceptUid, fn)
    local binds = liveShells()
    if binds == nil or player == nil then return end
    local mine = B.store().p[key]
    if mine == nil then return end
    for uid, bind in pairs(binds) do
        local r = mine[uid]
        if uid ~= exceptUid and r ~= nil and type(bind) == "table" and bind.shell ~= nil
                and dist2(bind.shell, player) <= B.WITNESS_TILES * B.WITNESS_TILES then
            fn(uid, r)
        end
    end
end

-- ------------------------------------------------------------ adult gate ---
-- Romance is only ever possible with adults. Anything that hints at a young NPC is excluded, erring on the side of no.
B.YOUNG_WORDS = { "teen", "kid", "child", "boy", "girl", "student", "young", "youth", "minor", "school", "junior",
    "son", "daughter", "orphan", "looking for parents" }
function B.canRomance(record)
    if type(record) ~= "table" then return false end
    local parts = { tostring(record.profileId or "") }
    pcall(function()
        local cat = ProjectALife.Catalog
        local prof = cat ~= nil and type(cat.npc) == "function" and cat.npc(record.profileId) or nil
        local g = type(prof) == "table" and type(prof.general) == "table" and prof.general or {}
        parts[#parts + 1] = tostring(g.name or ""); parts[#parts + 1] = tostring(g.role or "")
        if type(g.tags) == "table" then for _, t in pairs(g.tags) do parts[#parts + 1] = tostring(t) end
        elseif g.tags ~= nil then parts[#parts + 1] = tostring(g.tags) end
        local nh = ProjectALife.NpcHealth
        if nh ~= nil and type(nh.isMinor) == "function" and nh.isMinor(g) then parts[#parts + 1] = "minor" end
    end)
    pcall(function()
        local m = record.memory
        if type(m) == "table" and type(m.person) == "table" and m.person.ad ~= nil and m.person.ad ~= 1 then
            parts[#parts + 1] = "minor"
        end
    end)
    local text = string.lower(table.concat(parts, " "))
    for _, w in ipairs(B.YOUNG_WORDS) do
        if string.find(text, w, 1, true) then return false end
    end
    return true
end

-- ---------------------------------------------------------------- deeds ----
local function onDeed(kind, ref, player)
    local d = B.DEEDS[kind]
    if d == nil or player == nil then return end
    local key = keyOf(player)
    local record = type(ref) == "table" and ref or readRecord(uidOf(ref))
    local uid = uidOf(record) or uidOf(ref)
    if key == nil or uid == nil then return end
    B.metrics.deeds = B.metrics.deeds + 1
    B.change(key, uid, d[1], d[2], d[3], { player = player, record = record })
    -- cruelty seen by the people who love you costs you (unless they're too afraid to care)
    if d[2] > 0 then
        witnesses(key, player, uid, function(wuid, r)
            if B.stageOf(r.f) < 2 then B.change(key, wuid, -math.ceil(d[2] / 3), 0, 0, { player = player }) end
        end)
    end
end
B._onDeed = onDeed

-- ----------------------------------------------------------------- talk ----
local function today() return math.floor(hours() / 24) end

local function onTalk(player, listener, intent, verdict)
    if type(listener) ~= "table" or type(listener.record) ~= "table" or intent == nil then return end
    if type(verdict) == "table" and verdict.action ~= nil and verdict.action ~= "go" then return end
    local key, record = keyOf(player), listener.record
    local uid = uidOf(record)
    if key == nil or uid == nil then return end
    local r = B.row(key, uid, true)
    decayed(r)
    local d = today()
    if r.td ~= d then r.td, r.tl = d, 0 end
    B.metrics.talks = B.metrics.talks + 1

    if intent == "FLIRT" then
        local hr = math.floor(hours())
        if r.fh == hr then return end            -- once per in-game hour
        r.fh = hr
        if not B.canRomance(record) then
            r.r, r.partner = 0, nil
            B.change(key, uid, -3, 0, 0, { player = player, record = record })
            return
        end
        if B.stageOf(r.l) < B.ROMANCE_OPEN_STAGE then
            B.change(key, uid, -2, 0, 0, { player = player, record = record })
            r.awk = (r.awk or 0) + 1
            return
        end
        local gain = 4 / (1 + (r.r or 0) / 20)   -- diminishing
        r.r = (r.r or 0) + gain
        B.change(key, uid, 1, 0, 0, { player = player, record = record })
        -- jealousy: other partners who are close enough to see it
        witnesses(key, player, uid, function(wuid, w)
            if w.partner then B.change(key, wuid, -5, 0, 0, { player = player }) end
        end)
        if not r.partner and B.stageOf(r.l) >= B.PARTNER_LOVE_STAGE and r.r >= B.PARTNER_ROMANCE then
            r.partner = true
            B.metrics.partners = B.metrics.partners + 1
            notify(player, displayName(r) .. " is now your partner", true)
        end
        return
    end

    local t = B.TALK[intent]
    if t == nil then return end
    local dl = t[1]
    if dl > 0 then
        dl = math.min(dl, B.TALK_DAILY_CAP - (r.tl or 0))
        if dl <= 0 then dl = 0 else r.tl = (r.tl or 0) + dl end
    end
    local df = t[2]
    -- threats only frighten if you actually hold power over them (leverage) or they already fear you
    if df > 0 and not B.hasLeverage(key, uid) and B.stageOf(B.effectiveFear(key, uid, r)) < 1 then df = 0 end
    B.change(key, uid, dl, df, t[3], { player = player, record = record })
end
B._onTalk = onTalk

-- -------------------------------------------------------- time together -----
local function everyTen()
    local binds = liveShells()
    if binds == nil or type(getSpecificPlayer) ~= "function" then return end
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    local key = keyOf(player)
    if key == nil then return end
    B.metrics.ticks = B.metrics.ticks + 1
    local d = today()
    for uid, bind in pairs(binds) do
        if type(bind) == "table" and bind.shell ~= nil and dist2(bind.shell, player) <= B.NEAR_TILES * B.NEAR_TILES then
            local record = readRecord(uid)
            if record ~= nil and record.lifecycle ~= "dead" then
                local talk = ProjectALife.Talk
                local stance = "neutral"
                if talk ~= nil and type(talk.stance) == "function" then
                    local ok, s = pcall(talk.stance, record, player); if ok and s then stance = s end
                end
                if stance ~= "hostile" then
                    local r = B.row(key, uid, true)
                    if r.nd ~= d then r.nd, r.nl = d, 0 end
                    local dl = (stance == "friendly") and 0.5 or 0.2
                    if (r.nl or 0) + dl > B.NEAR_DAILY_CAP then dl = 0 end
                    r.nl = (r.nl or 0) + dl
                    local resident = type(record.memory) == "table" and type(record.memory.jimmyResident) == "table"
                    r.home = resident or nil
                    B.change(key, uid, dl, 0, resident and 0.3 or 0, { player = player, record = record })
                end
            end
        end
    end
end
B._everyTen = everyTen

-- Fear including leverage (captives, deals). The power module (ALifeBondsPower) replaces this.
function B.effectiveFear(key, uid, r)
    return r ~= nil and (tonumber(r.f) or 0) or 0
end
function B.hasLeverage(key, uid)
    return false
end

-- ------------------------------------------------------------- effects -----
local function loveBonus(record, player)
    local r = B.row(keyOf(player), uidOf(record), false)
    if r == nil then return 0 end
    return B.stageOf(r.l) * 6 + (r.partner and 6 or 0)
end
local function obeyBonus(record, player)
    local r = B.row(keyOf(player), uidOf(record), false)
    local key, uid = keyOf(player), uidOf(record)
    local f = B.effectiveFear(key, uid, r)
    if r == nil and f <= 0 then return 0 end
    return B.stageOf(f) * 4 + B.stageOf(r and r.n or 0) * 2
end

-- text summary for the AI voice and the menu
function B.describe(key, uid)
    local r = B.row(key, uid, false)
    local f = B.effectiveFear(key, uid, r)
    if r == nil and f <= 0 then return "none" end
    r = r or { l = 0, f = 0, n = 0, r = 0, at = hours() }
    decayed(r)
    local parts = { "love " .. B.nameOf("l", r.l), "fear " .. B.nameOf("f", f), "need " .. B.nameOf("n", r.n) }
    if B.hasLeverage(key, uid) then parts[#parts + 1] = "you hold power over their people" end
    if r.partner then parts[#parts + 1] = "your partner"
    elseif (r.r or 0) >= 10 then parts[#parts + 1] = "romantic interest" end
    return table.concat(parts, ", ")
end

-- ------------------------------------------------------------- install -----
function B.install()
    local op, social = ProjectALife and ProjectALife.NpcOpinion, ProjectALife and ProjectALife.TalkSocial
    if op == nil then return false end
    if op.__Bonds_wrapped then return true end
    op.__Bonds_wrapped = true
    local hooked = {}
    if type(op.note) == "function" then
        local orig = op.note
        op.note = function(kind, ref, player, options)
            local result = orig(kind, ref, player, options)
            tryOnce("deed", onDeed, kind, ref, player)
            return result
        end
        hooked[#hooked + 1] = "note"
    end
    if type(op.valueOf) == "function" then
        local orig = op.valueOf
        op.valueOf = function(record, player)
            -- 0.7.11.2: callers read records by uid and get nil once an NPC is gone; A-Life's opinion code then indexes
            -- nil (Reputation factionIdOf / Opinion.spread) and logs a stack trace even under pcall. No record, no opinion.
            if type(record) ~= "table" then return nil end
            local v, row, base = orig(record, player)
            local ok, bonus = tryOnce("valueOf", loveBonus, record, player)
            if ok and type(v) == "number" and bonus ~= 0 then v = math.min(op.maximum or 100, v + bonus) end
            return v, row, base
        end
        hooked[#hooked + 1] = "valueOf"
    end
    if type(op.orderShift) == "function" then
        local orig = op.orderShift
        op.orderShift = function(record, player)
            local v = orig(record, player)
            local ok, bonus = tryOnce("orderShift", obeyBonus, record, player)
            if ok and type(v) == "number" then v = v + bonus end
            return v
        end
        hooked[#hooked + 1] = "orderShift"
    end
    if social ~= nil and type(social.ask) == "function" and not social.__Bonds_wrapped then
        social.__Bonds_wrapped = true
        local orig = social.ask
        social.ask = function(player, listener, intent, source)
            local verdict = orig(player, listener, intent, source)
            tryOnce("talk", onTalk, player, listener, intent, verdict)
            return verdict
        end
        hooked[#hooked + 1] = "TalkSocial.ask"
    end
    print(TAG .. " hooked " .. table.concat(hooked, "/"))
    return true
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() B.install() end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() B.install() end) end
    if Events.EveryTenMinutes ~= nil then ALifeHealth.add(Events.EveryTenMinutes, "ALifeBonds", function() tryOnce("tick", everyTen) end) end
end
print(TAG .. " loaded v" .. VERSION)
