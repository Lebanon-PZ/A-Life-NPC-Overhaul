-- A-Life NPC Overhaul pre-1.0: MELEE STYLE. Everyone has a kind of melee weapon they know, and their skill with each
-- kind decides what they swing and how well.
-- A-Life 1.5.1 alone (read on 42.20 files):
--   * server/ProjectALife/Combat/ALifeWeapons.lua Weapons.bestMelee + local equipMelee: the melee weapon with the
--     highest getMaxDamage(), nothing else.
--   * server/ProjectALife/Combat/ALifeCombatStrike.lua Combat.meleeLevel(): ONE melee level for every NPC (setting
--     meleeSkillLevel, default 2). It drives melee damage on the dead (weaponBase 0.3 + levelStep 0.1 x level), crit
--     chance (+3 per level) and meleeSkillDamage (blunt / axe / spear +10% from 3, +20% from 7).
--   * client/ProjectALife/Combat/ALifeZombieParity.lua Parity.meleeLevel(): the same one level for dodging a bite and
--     shoving the dead off (Parity.thresholds / Parity.defendChance).
--   * Companion skill "melee" (shared/.../ALifeCompanionRules.lua, 0-10) is never read by combat.
-- Here: six kinds, the vanilla WeaponCategory set (vanilla server/XpSystem/XpUpdate.lua: AXE, BLUNT, SPEAR, LONG_BLADE,
-- SMALL_BLADE, SMALL_BLUNT, one perk each). Each person:
--   * a favourite kind: the kind of the best melee weapon they were carrying when first seen (people carry what they
--     know), else one picked from their uid (the same every time, every machine). Nothing made up, nothing spawned.
--   * a level with it: an A-Life companion's own "melee" skill (so teaching / camp practice count); anyone else A-Life's
--     meleeSkillLevel -1 .. +meleeStyleSpread, rolled once from their uid.
--   * the kind next to it (long / short blade, long / short blunt, axe / long blunt, spear / long blade) meleeStyleFamilyGap
--     lower, everything else meleeStyleOtherGap lower (+-1 per person).
--   * they get better by hitting: meleeStyleHits x (level + 1) hits with a kind = +1 with that kind (server, stored).
-- Choice: bestMelee scores max damage x A-Life's own skill factor for that kind (0.3 + 0.1 x level), +meleeStyleFavBonus %
-- for their best kind. A blade man keeps his machete over a bigger bat he can't swing.
-- Fights: their level with the kind in hand replaces A-Life's one level in the melee wound, crit roll and zombie parity.
-- A weapon with no kind (improvised, bare hands): A-Life's own level, untouched.
-- Fights with the living: A-Life's human melee path never reads a skill (unverified there is one): untouched.
-- No numbers shown (immersion): the Party tab gear line says "good with knives" at meleeStyleCue or better.
-- MP: wraps live where A-Life's tables are (Combat / Weapons on the server, Parity on the client). Learning is stored in
-- global ModData on the server; an MP client's parity uses the same uid roll without the learning (unverified sync).
ALifeMeleeStyle = ALifeMeleeStyle or {}
local S = ALifeMeleeStyle
local TAG = "[ALifeMeleeStyle]"
S.VERSION = "pre-1.0"
S.metrics = S.metrics or { picked = 0, swapped = 0, wounds = 0, learned = 0, parity = 0 }

S.DEFAULTS = {
    meleeStyle = true,        -- people have a melee kind they know; skill per kind decides what they swing and how well
    meleeStyleSpread = 3,     -- favourite kind level: A-Life's melee skill setting -1 .. +this (rolled once per person)
    meleeStyleFamilyGap = 2,  -- levels lower with the kind next to theirs (long / short blade, long / short blunt, axe / long blunt)
    meleeStyleOtherGap = 4,   -- levels lower with every other kind
    meleeStyleFavBonus = 15,  -- pct they lean to their best kind when choosing what to swing
    meleeStyleHits = 30,      -- hits with a kind per level gained (x the level they go for); 0 = they never learn
    meleeStyleCue = 5,        -- Party tab: "good with ..." at this level or better (0 = never)
}
S.FILE_KEYS = {}
for k in pairs(S.DEFAULTS) do S.FILE_KEYS[#S.FILE_KEYS + 1] = k end
table.sort(S.FILE_KEYS)

-- order matters: an item in two kinds takes the first (spear before blades, small before long blunt)
S.KINDS = {
    { id = "spear", wc = "SPEAR", word = "spears" },
    { id = "axe", wc = "AXE", word = "axes" },
    { id = "longBlade", wc = "LONG_BLADE", word = "long blades" },
    { id = "smallBlade", wc = "SMALL_BLADE", word = "knives" },
    { id = "smallBlunt", wc = "SMALL_BLUNT", word = "short clubs" },
    { id = "blunt", wc = "BLUNT", word = "bats and clubs" },
}
S.WORD = {}
for _, k in ipairs(S.KINDS) do S.WORD[k.id] = k.word end
S.NEAR = { longBlade = "smallBlade", blunt = "smallBlunt", axe = "blunt", spear = "longBlade" }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function clamp(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end

function S.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = S.DEFAULTS[key] end
    return v
end
function S.n(key) return num(S.setting(key), num(S.DEFAULTS[key], 0)) end
function S.on() return S.setting("meleeStyle") ~= false end

-- same hash as A-Life's ALifeCombatCore stablePercent: stable per string, every machine
function S.hash(text)
    text = tostring(text or "")
    local r = 0
    for i = 1, #text do r = (r * 33 + string.byte(text, i)) % 2147483647 end
    return r
end

-- learning store: server / SP only (an MP client reads, never writes)
function S.store()
    if type(isClient) == "function" and isClient() then return nil end
    if S.tmp then return S.tmp end
    if type(ModData) ~= "table" or not fn(ModData, "getOrCreate") then S.tmp = { p = {} }; return S.tmp end
    local s = ModData.getOrCreate("ALifeMeleeStyle")
    s.p = type(s.p) == "table" and s.p or {}
    return s
end
function S.row(uid, make)
    local s = S.store()
    if s == nil or uid == nil then return nil end
    uid = tostring(uid)
    local r = s.p[uid]
    if type(r) ~= "table" then
        if not make then return nil end
        r = { g = {}, h = {} }
        s.p[uid] = r
    end
    r.g = type(r.g) == "table" and r.g or {}
    r.h = type(r.h) == "table" and r.h or {}
    return r
end

function S.uidOf(shell)
    local uid = nil
    pcall(function() local md = shell:getModData(); uid = md and (md.ProjectALifeUID or md.ProjectALifeActorUID) end)
    return uid
end

-- which kind an item is (vanilla HandWeapon:isOfWeaponCategory, A-Life's own test; else the script item's list)
S.kindMemo = S.kindMemo or {}
function S.kindOf(item)
    if item == nil then return nil end
    local key = nil
    pcall(function() key = tostring(item:getFullType()) end)
    if key ~= nil and S.kindMemo[key] ~= nil then return S.kindMemo[key] or nil end
    local found = false
    if WeaponCategory ~= nil then
        for _, k in ipairs(S.KINDS) do
            local wc = nil
            pcall(function() wc = WeaponCategory[k.wc] end)
            if wc ~= nil then
                local hit = false
                pcall(function() hit = item:isOfWeaponCategory(wc) == true end)
                if not hit then pcall(function() hit = item:getScriptItem():containsWeaponCategory(wc) == true end) end
                if hit then found = k.id; break end
            end
        end
    end
    if key ~= nil then S.kindMemo[key] = found end
    return found or nil
end

local function itemsOf(shell)
    local out = {}
    pcall(function()
        local list = shell:getInventory():getItems()
        for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    end)
    return out
end
-- a usable melee weapon: A-Life's bestMelee test (IsWeapon, no ammo, not bare hands, damage > 0, condition > 0)
function S.melee(item)
    local ok, yes, power = pcall(function()
        if item:IsWeapon() ~= true then return false, 0 end
        if (tonumber(item:getMaxAmmo()) or 0) > 0 then return false, 0 end
        if tostring(item:getFullType()) == "Base.BareHands" then return false, 0 end
        local p = tonumber(item:getMaxDamage()) or 0
        local c = nil
        pcall(function() c = tonumber(item:getCondition()) end)
        if p <= 0 or (c ~= nil and c <= 0) then return false, 0 end
        return true, p
    end)
    if ok and yes then return true, power end
    return false, 0
end

-- A-Life's one melee level (its setting), the base for people who aren't companions
function S.globalLevel()
    local pa = PA()
    local v = nil
    if type(pa.Combat) == "table" and type(pa.Combat.settings) == "table" then v = tonumber(pa.Combat.settings.meleeSkillLevel) end
    if v == nil and type(pa.BehaviorSettings) == "table" and type(pa.BehaviorSettings.combat) == "table" then
        v = tonumber(pa.BehaviorSettings.combat.meleeSkillLevel)
    end
    return clamp(math.floor(v or 2), 0, 10)
end

-- an A-Life companion's own melee skill (0-10), nil for anyone else. Read at most every 2 s per person (a pick asks often).
S.compMemo = S.compMemo or {}
local function nowMs()
    local t = nil
    if type(getTimestampMs) == "function" then pcall(function() t = getTimestampMs() end) end
    return tonumber(t)
end
function S.companionSkill(uid)
    if uid == nil then return nil end
    local key, now = tostring(uid), nowMs()
    local m = S.compMemo[key]
    if m ~= nil and now ~= nil and now >= m.at and now - m.at < 2000 then return m.v end
    local v = S.readCompanionSkill(uid)
    if now ~= nil then S.compMemo[key] = { at = now, v = v } end
    return v
end
function S.readCompanionSkill(uid)
    local pa = PA()
    local C, reg = pa.Companions, pa.ActorRegistry
    if uid == nil or not fn(C, "entry") or type(reg) ~= "table" then return nil end
    local r = nil
    pcall(function() r = (reg.peek or reg.read)(tostring(uid)) end)
    if type(r) ~= "table" then return nil end
    local e = nil
    pcall(function() e = C.entry(r) end)
    if type(e) ~= "table" or type(e.state) ~= "table" or type(e.state.skills) ~= "table" then return nil end
    local v = tonumber(e.state.skills.melee)
    if v == nil then return nil end
    return clamp(math.floor(v), 0, 10)
end

-- their favourite kind (fixed once): stored, else what they carry, else the uid roll
function S.favOf(uid, shell)
    local r = S.row(uid, false)
    if r ~= nil and type(r.f) == "string" and S.WORD[r.f] then return r.f end
    local fav, best = nil, -1
    if shell ~= nil then
        for _, it in ipairs(itemsOf(shell)) do
            local ok, p = S.melee(it)
            local k = ok and S.kindOf(it) or nil
            if k ~= nil and p > best then fav, best = k, p end
        end
    end
    if fav == nil then fav = S.KINDS[S.hash(tostring(uid) .. ":kind") % #S.KINDS + 1].id end
    local w = S.row(uid, true)
    if w ~= nil then w.f = fav end
    return fav
end

function S.near(a, b) return S.NEAR[a] == b or S.NEAR[b] == a end

-- level 0-10 with a kind; nil kind = nil (A-Life's own level stands)
function S.level(uid, shell, kind)
    if kind == nil or uid == nil then return nil end
    local fav = S.favOf(uid, shell)
    local base = S.companionSkill(uid)
    if base == nil then
        local spread = math.max(0, math.floor(S.n("meleeStyleSpread")))
        base = S.globalLevel() + (S.hash(tostring(uid) .. ":lv") % (spread + 2)) - 1
    end
    local lv = base
    if kind ~= fav then
        lv = base - (S.near(fav, kind) and S.n("meleeStyleFamilyGap") or S.n("meleeStyleOtherGap"))
            + (S.hash(tostring(uid) .. ":" .. kind) % 3) - 1
    end
    local r = S.row(uid, false)
    if r ~= nil then lv = lv + num(r.g[kind], 0) end
    return clamp(math.floor(lv), 0, 10)
end

-- their best kind right now (learning can move it), and its level
function S.bestKind(uid, shell)
    if uid == nil then return nil, 0 end
    local fav = S.favOf(uid, shell)
    local bk, bl = fav, S.level(uid, shell, fav) or 0
    for _, k in ipairs(S.KINDS) do
        local l = S.level(uid, shell, k.id) or 0
        if l > bl then bk, bl = k.id, l end
    end
    return bk, bl
end

-- A-Life's own damage factor for a level (Combat.MELEE_WOUND weaponBase + levelStep x level)
function S.factor(lv)
    local w = type(PA().Combat) == "table" and PA().Combat.MELEE_WOUND or nil
    local base = type(w) == "table" and tonumber(w.weaponBase) or 0.3
    local step = type(w) == "table" and tonumber(w.levelStep) or 0.1
    return base + step * lv
end

-- the melee weapon they'd pick: damage x their skill with its kind, a lean to their best kind
function S.pick(shell)
    local uid = S.uidOf(shell)
    if uid == nil then return nil, false end
    local bk = S.bestKind(uid, shell)
    local lean = 1 + math.max(0, S.n("meleeStyleFavBonus")) / 100
    local g = S.globalLevel()
    local best, bestScore = nil, -1
    for _, it in ipairs(itemsOf(shell)) do
        local ok, p = S.melee(it)
        if ok then
            local k = S.kindOf(it)
            local lv = k and S.level(uid, shell, k) or g
            local score = p * S.factor(lv)
            if k ~= nil and k == bk then score = score * lean end
            if score > bestScore then best, bestScore = it, score end
        end
    end
    S.metrics.picked = S.metrics.picked + 1
    return best, true
end

-- a hit with a kind: learning (server)
function S.learn(uid, kind)
    local per = S.n("meleeStyleHits")
    if uid == nil or kind == nil or per <= 0 then return false end
    local r = S.row(uid, true)
    if r == nil then return false end
    local lv = S.level(uid, nil, kind) or 0
    if lv >= 10 then return false end
    r.h[kind] = num(r.h[kind], 0) + 1
    if r.h[kind] >= per * (lv + 1) then
        r.h[kind] = 0
        r.g[kind] = num(r.g[kind], 0) + 1
        S.metrics.learned = S.metrics.learned + 1
        return true
    end
    return false
end

-- Party tab: their best kind id ("smallBlade" -> "good with knives") when good enough, else nil
function S.cueKind(shell)
    if not S.on() or shell == nil then return nil end
    local at = S.n("meleeStyleCue")
    if at <= 0 then return nil end
    local uid = S.uidOf(shell)
    if uid == nil then return nil end
    local k, l = S.bestKind(uid, shell)
    if k == nil or l < at then return nil end
    return k
end

----------------------------------------------------------------------------------------------------------------
-- wraps
----------------------------------------------------------------------------------------------------------------
S.lvNow = nil -- the level for the strike being worked out right now (nil = A-Life's own)

local function handItem(shell)
    local W = PA().Weapons
    local it = nil
    if fn(W, "current") then pcall(function() it = W.current(shell) end) end
    if it == nil then pcall(function() it = shell:getPrimaryHandItem() end) end
    return it
end
function S.levelInHand(shell, weapon)
    local uid = S.uidOf(shell)
    if uid == nil then return nil end
    return S.level(uid, shell, S.kindOf(weapon or handItem(shell)))
end

function S.installServer()
    if S.serverDone then return true end
    local pa = PA()
    local W, Cb = pa.Weapons, pa.Combat
    if not fn(W, "bestMelee") or not fn(Cb, "meleeZombieWound") or not fn(Cb, "meleeLevel") then return false end
    S.serverDone = true

    local origBest = W.bestMelee
    W.bestMelee = function(shell, ...)
        if S.on() and shell ~= nil then
            local ok, it, handled = pcall(S.pick, shell)
            if ok and handled then return it end
            if not ok and not S.pickErr then S.pickErr = true; log("pick error (once): " .. tostring(it)) end
        end
        return origBest(shell, ...)
    end

    -- A-Life's out-of-ammo fallback (local equipMelee, max damage) runs inside ensureReady: put their own kind in hand
    if fn(W, "ensureReady") and fn(W, "current") and fn(W, "select") then
        local origReady = W.ensureReady
        W.ensureReady = function(shell, ...)
            local before = nil
            if S.on() then pcall(function() before = W.current(shell) end) end
            local res = origReady(shell, ...)
            if S.on() and shell ~= nil then
                pcall(function()
                    local after = W.current(shell)
                    if after == nil or after == before or (tonumber(after:getMaxAmmo()) or 0) > 0 then return end
                    local want = W.bestMelee(shell)
                    if want ~= nil and want ~= after then
                        W.select(shell, want, (fn(W, "slot") and W.slot(want)) or "melee")
                        S.metrics.swapped = S.metrics.swapped + 1
                    end
                end)
            end
            return res
        end
    end

    local origLevel = Cb.meleeLevel
    Cb.meleeLevel = function(...)
        if S.lvNow ~= nil then return S.lvNow end
        return origLevel(...)
    end
    local origWound = Cb.meleeZombieWound
    Cb.meleeZombieWound = function(shell, zombie, weapon, share, ...)
        if not S.on() then return origWound(shell, zombie, weapon, share, ...) end
        local lv, kind, uid = nil, nil, nil
        pcall(function()
            uid = S.uidOf(shell)
            kind = S.kindOf(weapon)
            lv = S.level(uid, shell, kind)
        end)
        local prev = S.lvNow
        S.lvNow = lv
        local ok, a, b = pcall(origWound, shell, zombie, weapon, share, ...)
        S.lvNow = prev
        if not ok then error(a) end
        if lv ~= nil then
            S.metrics.wounds = S.metrics.wounds + 1
            pcall(S.learn, uid, kind)
        end
        return a, b
    end
    return true
end

function S.installParity()
    if S.parityDone then return true end
    local P = PA().ZombieParity
    if type(P) ~= "table" or not fn(P, "meleeLevel") then return false end
    S.parityDone = true
    local origLevel = P.meleeLevel
    P.meleeLevel = function(...)
        if S.lvNow ~= nil then return S.lvNow end
        return origLevel(...)
    end
    for _, name in ipairs({ "thresholds", "defendChance" }) do
        if fn(P, name) then
            local orig = P[name]
            P[name] = function(actor, zombie, ...)
                if not S.on() then return orig(actor, zombie, ...) end
                local lv = nil
                pcall(function() lv = S.levelInHand(actor) end)
                local prev = S.lvNow
                S.lvNow = lv
                local ok, r1, r2, r3, r4, r5 = pcall(orig, actor, zombie, ...) -- thresholds: 5 values, defendChance: 1
                S.lvNow = prev
                if not ok then error(r1) end
                if lv ~= nil then S.metrics.parity = S.metrics.parity + 1 end
                return r1, r2, r3, r4, r5
            end
        end
    end
    return true
end

function S.install()
    local a = S.installServer()
    local b = S.installParity()
    if (a or b) and not S.saidReady then
        S.saidReady = true
        log("ready v" .. S.VERSION .. ": " .. (S.on() and "on" or "off") .. " (choice + wounds " .. (a and "yes" or "no")
            .. ", bite parity " .. (b and "yes" or "no") .. "), spread +" .. tostring(math.floor(S.n("meleeStyleSpread")))
            .. ", gaps " .. tostring(S.n("meleeStyleFamilyGap")) .. "/" .. tostring(S.n("meleeStyleOtherGap"))
            .. ", learn every " .. tostring(S.n("meleeStyleHits")) .. " x level hits")
    end
    return a or b
end

function S.qaLine()
    local m = S.metrics
    return "[ALIFE-QA] MeleeStyle: picked=" .. m.picked .. " swapped=" .. m.swapped .. " wounds=" .. m.wounds
        .. " learned=" .. m.learned .. " parity=" .. m.parity
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() local ok, e = pcall(S.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(S.install) end) end
end

return S
