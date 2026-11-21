-- A-Life NPC Overhaul 0.7.4: INJURED PEOPLE AND PRISONERS, ON TOP OF A-LIFE 1.5 (hook in, never replace).
-- A-Life 1.5's "Injured survivor" menu decides what happens to a downed person (help, splint, pills, food, water,
-- what happened, search, mercy, leave). We remember it:
--   * the downed person remembers what you did (their opinion of you and a memory the AI talks from);
--   * people who saw it (your party, anyone around who knows you) judge it: helping a stranger counts, robbing or
--     finishing off someone who begged doesn't; finishing off someone who was cursing you scares people more than it
--     upsets them;
--   * "What happened?": who really put them down goes into their memory, and the chat turns to them so you can ask more.
-- Prisoners of war: a downed (or dragged) enemy counts as having given up, so you can drag them into your base and
-- take them prisoner (ransom, swap, recruit, prison work: the rules you already have). They aren't forced to put
-- their hands up while lying down.
-- Camp medics treat downed people too: a medic's own dressing, through A-Life's own recovery, so they get up.
-- Captives adapter: A-Life 1.5's own prisoner system ships switched off. When it's on, someone held by A-Life can't
-- be taken by us and the other way round; A-Life prisoners you hold count as leverage over their faction.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "injuryBridge" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeInjuryBridge") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeInjuryBridge = ALifeInjuryBridge or {}
local L = ALifeInjuryBridge
local TAG = "[ALifeInjuryBridge]"
L.VERSION = ALifeSide.MOD_VERSION
L.WITNESS_TILES = 20
-- opinion changes: { love for the downed person, fear for them, love for witnesses, fear for witnesses }
L.DEEDS = {
    aid    = { mine = { l = 8 },  seen = { l = 2 },  mem = "{p} stopped my bleeding when I was down" },
    splint = { mine = { l = 3 },  seen = { l = 1 },  mem = "{p} splinted me up when I was down" },
    pills  = { mine = { l = 3 },  seen = {},         mem = "{p} gave me pills when I was down" },
    food   = { mine = { l = 3 },  seen = { l = 1 },  mem = "{p} fed me when I was down" },
    water  = { mine = { l = 3 },  seen = { l = 1 },  mem = "{p} gave me water when I was down" },
    leave  = { mine = { l = -4 }, seen = { l = -1 }, mem = "{p} walked away and left me lying there" },
    search = { mine = { l = -10, f = 6 }, seen = { l = -3, f = 1 }, mem = "{p} went through my pockets while I bled",
               hostile = { mine = { f = 4 }, seen = {}, mem = "{p} searched me after the fight" } },
    mercy  = { mine = {}, seen = { l = -4, f = 3 }, seenMem = "Watched {p} finish off {n}, who was begging",
               hostile = { mine = {}, seen = { f = 2 }, seenMem = "Watched {p} finish off {n}, who was still cursing" } },
}
L.STORY = { zombie = "the dead", firearm = "gunfire", melee = "someone up close", player = "you", survivor = "other people",
    fire = "fire", unknown = "something they didn't see" }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { deeds = 0, witnesses = 0, stories = 0, downedPrisoners = 0, medicRecoveries = 0, refusedHeld = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end

function L.enabled()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.injuryBridge == false)
end

function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3], r[4]
end

local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__InjuryBridge"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__InjuryBridge"] = orig
    L.hooked[hookName] = true
    return true
end

local function record(uid)
    local pa = PA()
    if uid == nil or pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function shellOf(uid)
    local pa = PA()
    if uid == nil or pa == nil or not fn(pa.Talk, "shellFor") then return nil end
    local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
    return ok and s or nil
end
local function dataOf(shell)
    if shell == nil then return nil end
    local d = nil
    pcall(function() if shell:hasModData() then d = shell:getModData() end end)
    return type(d) == "table" and d or nil
end
local function nameOf(r)
    local pa = PA()
    if r ~= nil and pa ~= nil and fn(pa.Names, "of") then
        local ok, n = pcall(pa.Names.of, r)
        if ok and n then return tostring(n) end
    end
    return "someone"
end
local function keyOf(player)
    local B = ALifeBonds
    if fn(B, "keyOf") then local ok, k = pcall(B.keyOf, player); if ok then return k end end
    return nil
end
local function playerName(player)
    local n = nil
    pcall(function() n = player:getDescriptor():getForename() end)
    return (n ~= nil and n ~= "") and tostring(n) or "the newcomer"
end
local function fill(text, p, n) return (string.gsub(string.gsub(text, "{p}", p), "{n}", n)) end

-- lying on the ground in A-Life's injury system (downed, or being dragged)
function L.downed(uid, shell)
    local d = dataOf(shell or shellOf(uid))
    return d ~= nil and (d.ProjectALifeInjured == "down" or d.ProjectALifeInjured == "dragged")
end

----------------------------------------------------------------------------------------------------------------
-- 1. what you did to a downed person: they remember, witnesses judge
----------------------------------------------------------------------------------------------------------------
local function remember(uid, kind, text)
    local M = ALifeLLMTalk
    if fn(M, "keyMem") then pcall(M.keyMem, uid, kind, text) end
    if fn(M, "logInteraction") then pcall(M.logInteraction, uid, text, nil, nil, "event") end
end

-- everyone A-Life has a body for within reach of the player, except the victim (only people who know you get an
-- opinion change; everyone gets the memory)
function L.witnesses(player, victimUid)
    local out = {}
    local wd = PA() and PA().Watchdog
    if wd == nil or type(wd.bindings) ~= "table" or player == nil then return out end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    if px == nil then return out end
    local r2 = L.WITNESS_TILES * L.WITNESS_TILES
    for uid, bind in pairs(wd.bindings) do
        if tostring(uid) ~= tostring(victimUid) and type(bind) == "table" and bind.shell ~= nil then
            local x, y, dead = nil, nil, false
            pcall(function() x, y = bind.shell:getX(), bind.shell:getY(); dead = bind.shell:isDead() == true end)
            if x ~= nil and not dead and (x - px) ^ 2 + (y - py) ^ 2 <= r2 and not L.downed(uid, bind.shell) then
                out[#out + 1] = tostring(uid)
            end
        end
    end
    table.sort(out)
    return out
end

function L.onDeed(player, act, uid, payload)
    local row = L.DEEDS[act]
    if row == nil then return end
    if payload.hostile == true and row.hostile ~= nil then row = row.hostile end
    local key = keyOf(player)
    local B = ALifeBonds
    local victim = record(uid)
    local p, n = playerName(player), nameOf(victim)
    if row.mine and (row.mine.l or row.mine.f) and key and fn(B, "change") and act ~= "mercy" then
        pcall(B.change, key, tostring(uid), row.mine.l or 0, row.mine.f or 0, 0, { player = player, record = victim })
    end
    if row.mem then remember(uid, "injured_" .. act, fill(row.mem, p, n)) end
    local count = 0
    local _, mine = L.yourPeople(player)
    local factor = L.customFactor(key, act, payload.hostile == true)
    for _, w in ipairs(L.witnesses(player, uid)) do
        local known = key ~= nil and fn(B, "row") and B.row(key, w, false) ~= nil
        local k = mine[w] and factor or 1
        if known and (row.seen.l or row.seen.f) and k > 0 then
            pcall(B.change, key, w, (row.seen.l or 0) * k, (row.seen.f or 0) * k, 0, { player = player, record = record(w) })
        end
        if row.seenMem then remember(w, "saw_" .. act, fill(row.seenMem, p, n))
        elseif act ~= "pills" then remember(w, "saw_" .. act, "Saw " .. p .. " with " .. n .. " lying hurt: " .. act) end
        count = count + 1
    end
    L.metrics.deeds = L.metrics.deeds + 1
    L.metrics.witnesses = L.metrics.witnesses + count
    L.tally(key, act, payload.hostile == true)
    log("deed " .. act .. " on " .. tostring(uid) .. (payload.hostile and " (hostile)" or "") .. ", " .. count .. " saw it")
end

-- CAMP TRADITIONS (roadmap): what you keep doing becomes what your people do. Counted per player; at the threshold
-- the custom forms once, your party and camp hear about it (their memory, the AI talks from it), and from then on
-- your own people judge by it: breaking the custom costs double with them, keeping a hard custom costs nothing.
L.TRADITIONS = {
    { id = "help_fallen", act = "aid", n = 3, letter = "Your people have a custom now: we stop for the wounded.",
      mem = "It's how we do things now: we don't leave the hurt lying, whoever they are" },
    { id = "no_quarter", act = "mercy_hostile", n = 3, letter = "Your people have a custom now: no quarter for those who come at us.",
      mem = "It's how we do things now: whoever comes at us and goes down doesn't get back up" },
    { id = "keep_walking", act = "leave", n = 4, letter = "Your people have a custom now: we don't stop for strangers on the ground.",
      mem = "It's how we do things now: we keep walking, we can't save everyone" },
}
function L.tally(key, act, hostile)
    local M = ALifeLLMTalk
    if key == nil or not fn(M, "bucket") then return end
    local ok, b = pcall(M.bucket, "injuredDeeds")
    if not ok or type(b) ~= "table" then return end
    b[key] = type(b[key]) == "table" and b[key] or {}
    local name = (act == "mercy" and hostile) and "mercy_hostile" or act
    b[key][name] = (tonumber(b[key][name]) or 0) + 1
    b[key].traditions = type(b[key].traditions) == "table" and b[key].traditions or {}
    for _, t in ipairs(L.TRADITIONS) do
        if t.act == name and not b[key].traditions[t.id] and b[key][name] >= t.n then
            b[key].traditions[t.id] = true
            L.formTradition(key, t)
        end
    end
end
function L.traditionOf(key, id)
    local M = ALifeLLMTalk
    if key == nil or not fn(M, "bucket") then return false end
    local ok, b = pcall(M.bucket, "injuredDeeds")
    return ok and type(b) == "table" and type(b[key]) == "table" and type(b[key].traditions) == "table" and b[key].traditions[id] == true
end
-- your people: party + camp
function L.yourPeople(player)
    local M, seen, out = ALifeLLMTalk, {}, {}
    local function add(list) for _, u in ipairs(list or {}) do u = tostring(type(u) == "table" and (u.uid or u) or u); if not seen[u] then seen[u] = true; out[#out + 1] = u end end end
    if fn(M, "partyMembers") then local ok, l = pcall(M.partyMembers, player); if ok then add(l) end end
    if fn(M, "cpPeople") then local ok, l = pcall(M.cpPeople, player); if ok then add(l) end end
    return out, seen
end
function L.formTradition(key, t)
    local player = nil
    player = ALifeSide.campPlayer()
    local people = L.yourPeople(player)
    for _, u in ipairs(people) do remember(u, "tradition_" .. t.id, t.mem) end
    if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, t.letter) end
    log("tradition formed: " .. t.id .. " (" .. #people .. " of your people know it)")
end
-- your own people judge by the custom: breaking it doubles the cost with them, keeping a hard one costs nothing
function L.customFactor(key, act, hostile)
    if act == "aid" or act == "splint" or act == "food" or act == "water" then
        if L.traditionOf(key, "keep_walking") then return 0.5 end
        return 1
    end
    if (act == "leave" or (act == "mercy" and not hostile)) and L.traditionOf(key, "help_fallen") then return 2 end
    if act == "mercy" and hostile and L.traditionOf(key, "no_quarter") then return 0 end
    if act == "leave" and L.traditionOf(key, "keep_walking") then return 0 end
    return 1
end

-- "What happened?": the real story goes into their memory, and your next words go to them
function L.onStory(player, uid, payload)
    local shell = shellOf(uid)
    local who = L.STORY[tostring(payload.class)] or L.STORY.unknown
    local pa = PA()
    if payload.class == "survivor" and shell ~= nil and pa and pa.Health and type(pa.Health.lastAttacker) == "table" then
        local attacker = pa.Health.lastAttacker[shell]
        local ad = dataOf(attacker)
        local ar = ad and record(ad.ProjectALifeUID) or nil
        if ar ~= nil then
            local title = ar.factionId
            if fn(pa.Catalog, "faction") then
                pcall(function() local f = pa.Catalog.faction(ar.factionId); if f and f.general and f.general.name then title = f.general.name end end)
            end
            who = nameOf(ar) .. " (" .. tostring(title) .. ")"
        end
    end
    remember(uid, "injured_story", "Was put down by " .. who .. "; told " .. playerName(player) .. " about it")
    local M = ALifeLLMTalk
    if type(M) == "table" then
        local lockMs = (type(M.settings) == "table" and tonumber(M.settings.targetLockMs)) or 30000
        M.lock = { uid = tostring(uid), untilMs = nowMs() + lockMs }
    end
    L.metrics.stories = L.metrics.stories + 1
end

function L.hookInjuredAct(I)
    return wrap(I, "act", "injuredAct", function(orig)
        return function(player, args, ...)
            local payload = orig(player, args, ...)
            if L.enabled() and type(payload) == "table" and payload.ok == true then
                local act, uid = tostring(payload.act), tostring(payload.uid)
                if act == "story" then L.guard("injuredStory", L.onStory, player, uid, payload)
                else L.guard("injuredAct", L.onDeed, player, act, uid, payload) end
            end
            return payload
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 2. prisoners of war: downed = gave up; don't force hands up on someone lying down
----------------------------------------------------------------------------------------------------------------
function L.hookSurrenderedTo(Pw)
    return wrap(Pw, "surrenderedTo", "surrenderedTo", function(orig)
        return function(rec, key, ...)
            local yes = orig(rec, key, ...)
            if yes or not L.enabled() or type(rec) ~= "table" or key == nil then return yes end
            local ok, down = L.guard("surrenderedTo", L.downed, rec.uid)
            if ok and down then L.metrics.downedPrisoners = L.metrics.downedPrisoners + 1; return true end
            return yes
        end
    end)
end

function L.hookBeginSurrender(Orders)
    return wrap(Orders, "beginSurrender", "beginSurrender", function(orig)
        return function(rec, shell, player, now, kind, ...)
            if L.enabled() and type(rec) == "table" then
                local ok, down = L.guard("beginSurrender", L.downed, rec.uid, shell)
                if ok and down then return true end -- lying down: they already gave up, no hands-up pose
            end
            return orig(rec, shell, player, now, kind, ...)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 3. camp medics: downed people count as treatable, and a medic's dressing gets them up through A-Life
----------------------------------------------------------------------------------------------------------------
L.DRESSINGS = { "Base.AlcoholBandage", "Base.Bandage", "Base.AlcoholRippedSheets", "Base.RippedSheets" }
L.KIT = { ["Base.AlcoholBandage"] = 0.7, ["Base.Bandage"] = 0.65, ["Base.AlcoholRippedSheets"] = 0.55, ["Base.RippedSheets"] = 0.5 }

function L.aidFraction(kit)
    local f = L.KIT[kit] or 0.5
    local R = PA() and PA().InjuryRules
    if fn(R, "settings") then
        local ok, s = pcall(R.settings)
        if ok and type(s) == "table" and tonumber(s.aidFraction) then f = math.max(f, tonumber(s.aidFraction)) end
    end
    return math.min(0.9, f)
end

function L.medicRecover(medicUid, patientUid)
    local pa = PA()
    local inj = pa and pa.Injury
    if not fn(inj, "recover") then return nil end
    local ps, ms = shellOf(patientUid), shellOf(medicUid)
    local data = dataOf(ps)
    if ps == nil or ms == nil or data == nil or data.ProjectALifeInjured ~= "down" then return nil end
    local item, kind = nil, nil
    for _, t in ipairs(L.DRESSINGS) do
        pcall(function() item = ms:getInventory():getFirstTypeRecurse(t) end)
        if item ~= nil then kind = t; break end
    end
    if item == nil then return false end
    pcall(function() local c = item:getContainer() or ms:getInventory(); c:Remove(item) end)
    if pa.Health and fn(pa.Health, "heal") then pcall(pa.Health.heal, ps, data) end
    inj.recover(ps, data, nowMs(), "aided", L.aidFraction(kind), true)
    pcall(function() ms:faceThisObject(ps) end)
    L.metrics.medicRecoveries = L.metrics.medicRecoveries + 1
    log("medic " .. tostring(medicUid) .. " got " .. tostring(patientUid) .. " up with " .. kind)
    return true, kind
end

function L.hookTreatOther(P)
    return wrap(P, "treatOther", "treatOther", function(orig)
        return function(medicUid, patientUid, ...)
            if L.enabled() then
                local ok, done, kind = L.guard("treatOther", L.medicRecover, medicUid, patientUid)
                if ok and done ~= nil then return done, kind end
            end
            return orig(medicUid, patientUid, ...)
        end
    end)
end

function L.hookTreatable(M)
    return wrap(M, "mdTreatable", "mdTreatable", function(orig)
        return function(uid, ...)
            if orig(uid, ...) then return true end
            if not L.enabled() then return false end
            local ok, down = L.guard("mdTreatable", function()
                local d = dataOf(shellOf(uid))
                return d ~= nil and d.ProjectALifeInjured == "down"
            end)
            return ok and down == true
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 4. captives adapter (A-Life's own prisoners, when its "hostage_core" switch is on)
----------------------------------------------------------------------------------------------------------------
local function captives()
    local c = PA() and PA().Captives
    if fn(c, "heldUid") and fn(c, "enabled") then return c end
    return nil
end
function L.heldByALife(uid)
    local c = captives()
    if c == nil then return false end
    local ok, on = pcall(c.enabled)
    if not ok or not on then return false end
    local okH, held = pcall(c.heldUid, uid)
    return okH and held == true
end
function L.heldByUs(uid)
    local Pw = ALifeBondsPower
    if not fn(Pw, "state") then return false end
    local ok, s = pcall(Pw.state)
    return ok and type(s) == "table" and type(s.cap) == "table" and s.cap[tostring(uid)] ~= nil
end

function L.hookCanTake(Pw)
    return wrap(Pw, "canTake", "canTake", function(orig)
        return function(player, rec, ...)
            if L.enabled() and type(rec) == "table" then
                local ok, held = L.guard("canTake", L.heldByALife, rec.uid)
                if ok and held then L.metrics.refusedHeld = L.metrics.refusedHeld + 1; return false, "held_by_alife" end
            end
            return orig(player, rec, ...)
        end
    end)
end

-- A-Life prisoners you hold are leverage over their faction too
function L.alifeCaptivesOf(key, fid)
    local c = captives()
    if c == nil or not fn(c, "uidsFor") then return 0 end
    local ok, on = pcall(c.enabled)
    if not ok or not on then return 0 end
    local n = 0
    for _, uid in ipairs(c.uidsFor(key) or {}) do
        if not L.heldByUs(uid) then
            local r = record(uid)
            if fid == nil or (r ~= nil and r.factionId == fid) then n = n + 1 end
        end
    end
    return n
end

function L.hookCaptivesOf(Pw)
    return wrap(Pw, "captivesOf", "captivesOf", function(orig)
        return function(key, fid, ...)
            local n = orig(key, fid, ...)
            if not L.enabled() then return n end
            local ok, extra = L.guard("captivesOf", L.alifeCaptivesOf, key, fid)
            if ok and type(extra) == "number" then return (tonumber(n) or 0) + extra end
            return n
        end
    end)
end

function L.hookEligible(C)
    return wrap(C, "eligible", "eligible", function(orig)
        return function(player, uid, ...)
            if L.enabled() then
                local ok, held = L.guard("eligible", L.heldByUs, uid)
                if ok and held then L.metrics.refusedHeld = L.metrics.refusedHeld + 1; return nil, nil, "held_by_overhaul" end
            end
            return orig(player, uid, ...)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
-- required hooks (A-Life 1.5 + our own files); the captives ones only exist once A-Life's captives are loaded
L.HOOKS = { "injuredAct", "surrenderedTo", "beginSurrender", "treatOther", "mdTreatable", "canTake", "captivesOf", "eligible" }

function L.install()
    local pa, M = PA(), ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" and M.settings.injuryBridge == nil then M.settings.injuryBridge = true end
    if pa ~= nil then
        if type(pa.Injured) == "table" then L.hookInjuredAct(pa.Injured) end
        if type(pa.TalkOrders) == "table" then L.hookBeginSurrender(pa.TalkOrders) end
        if type(pa.Captives) == "table" then L.hookEligible(pa.Captives) end
    end
    if type(ALifeBondsPower) == "table" then
        L.hookSurrenderedTo(ALifeBondsPower); L.hookCanTake(ALifeBondsPower); L.hookCaptivesOf(ALifeBondsPower)
    end
    if type(ALifeTalkPatch) == "table" then L.hookTreatOther(ALifeTalkPatch) end
    if type(M) == "table" then L.hookTreatable(M) end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end

L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or ""))
        return true
    end
    return false
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        if L.tryInstall() then return end
        if Events.OnTick == nil then return end
        local last = 0
        local function retry()
            local now = nowMs()
            if now - last < 500 then return end
            last = now
            if L.tryInstall() then Events.OnTick.Remove(retry) end
        end
        Events.OnTick.Add(retry)
    end)
end
print(TAG .. " loaded v" .. L.VERSION)
