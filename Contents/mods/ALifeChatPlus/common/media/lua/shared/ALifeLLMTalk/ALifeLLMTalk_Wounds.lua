-- A-Life Talk 0.5.1: NPCs feel and talk about their SPECIFIC injuries.
--
-- What exists (read from Project A-Life's code, nothing invented):
--   * A-Life keeps real per-NPC wounds: shell ModData ProjectALifeInjuries = { { p = part, k = kind, s = severity,
--     h = world hour, b = bandaged, sp = splinted } } (persisted to record.memory.injuries). Parts: head, torso,
--     arm_l, arm_r, leg_l, leg_r. Kinds: scratch, laceration, deep, bite, bullet, bruise, fracture, burn.
--     Causes: firearm / blade / blunt / fists / vehicle / zombie / fire (ProjectALifeLastAttackKind); A-Life also
--     knows "fall" but never calls it. Health.lastAttacker[shell], ProjectALifeWoundLeg (limp), ProjectALifeArmAimScale,
--     bleeding (Wounds.bleeding), bleed-out / downed (ProjectALifeInjured), infection (ProjectALifeTurnAtHours),
--     self-dressing with a Bandage / RippedSheets from their own bag (ModuleHealing), healing over time (Wounds.prune).
--   * The NPCs are IsoZombie: their vanilla BodyDamage is not simulated, so Wound Expansion (player health panel,
--     Java patches on the player's body) has nothing per NPC. The Only Cure+ amputates limbs of ANY IsoZombie hit
--     with an axe / long blade when its "zombie amputations" option is on - A-Life NPCs included: the stump is a
--     "TOC.Amputation_<Limb>" item in the shell's inventory and a lost leg makes it crawl. Gore (IsoGore) can also
--     take limbs off living zombies (no API; a lost leg = crawling). Both are read only, softly.
-- What we derive (A-Life has no finer detail): the exact spot (forearm, knee, neck ...) from the hit direction
-- (attacker in front / behind / beside, or A-Life's isHitFromBehind) and the cause, deterministic per wound; who
-- did it; falls (z drop without stairs). Without A-Life's wound system (older A-Life, Health off) we track hits
-- ourselves (OnHitZombie, ProjectALife_NpcHit) with the same kinds and healing times.
-- Everything we add lives in our own ModData buckets "wdet" / "wown". A-Life is only changed through the optional
-- A-Life Talk Patch (1.3: treatment with a gifted bandage / splint, a medic patching a comrade, sitting down to rest,
-- clutching the wound, falls written as A-Life injuries).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Wounds") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Wounds"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Wounds") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function bucket(name)
    local data = M.store()
    if type(data) ~= "table" then M.tmpStore = M.tmpStore or {}; data = M.tmpStore end
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
local function hash(s)
    local h = 5381
    s = tostring(s)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return h
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function shellOf(uid) local pa = PA(); local s = nil; pcall(function() s = pa.Talk.shellFor(tostring(uid)) end); return s end
local function dataOf(shell) local d = nil; pcall(function() d = shell:getModData() end); return type(d) == "table" and d or nil end
local function pick(list, k) return list[(k % #list) + 1] end

M.woundCfg = { everyMs = 3000, watchTiles = 30, seeTiles = 12, talkTiles = 10, freshH = 0.08, selfGapMs = 90000,
    askGapMs = 240000, mentionGapMs = 420000, comradeGapMs = 120000, restGapMs = 900000, restMs = 240000,
    painScale = 160, maxPrompt = 4 }
if M.settings.wounds == nil then M.settings.wounds = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "wounds" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "wounds" end
end

----------------------------------------------------------------------------------------------------------------
-- vocabulary
----------------------------------------------------------------------------------------------------------------
M.woundKinds = { -- (own fallback tracker uses the same numbers as A-Life's Wounds.kinds)
    scratch = { bleed = true, clotH = 0.25, healH = 48, label = "scratch" },
    laceration = { bleed = true, clotH = 1.0, healH = 120, label = "laceration" },
    deep = { bleed = true, healH = 216, label = "deep wound" },
    bite = { bleed = true, clotH = 1.5, healH = 168, label = "bite" },
    bullet = { bleed = true, healH = 240, label = "bullet wound" },
    bruise = { healH = 72, label = "bruise" },
    fracture = { healH = 960, label = "fracture" },
    burn = { healH = 240, label = "burn" },
    sprain = { healH = 72, label = "sprain" },
}
-- A-Life part -> region, side
M.woundRegion = { head = { "head" }, torso = { "torso" }, arm_l = { "arm", "left" }, arm_r = { "arm", "right" },
    leg_l = { "leg", "left" }, leg_r = { "leg", "right" } }
-- finer spot by region and how the hit came (weights); front / back / side / bite / blade / bullet / fall / fire
M.woundSpots = {
    head = { front = { face = 3, jaw = 2, neck = 2, scalp = 1, ear = 1 }, back = { scalp = 3, neck = 3, ear = 1 },
        side = { ear = 3, scalp = 2, jaw = 2, neck = 1 }, bite = { neck = 5, ear = 2, face = 1 },
        bullet = { scalp = 2, face = 1, jaw = 1, neck = 1 }, fire = { face = 3, scalp = 1, neck = 1 } },
    torso = { front = { chest = 3, belly = 3, ribs = 2, shoulder = 1 }, back = { back = 4, shoulder = 2, ribs = 1 },
        side = { ribs = 3, side = 3, hip = 1 }, bite = { shoulder = 4, side = 1, back = 1 }, fire = { chest = 2, back = 2, side = 1 } },
    arm = { front = { forearm = 4, hand = 3, ["upper arm"] = 2, elbow = 1, fingers = 1 },
        back = { ["upper arm"] = 3, elbow = 2, forearm = 2 }, side = { ["upper arm"] = 3, forearm = 2, elbow = 1 },
        bite = { forearm = 5, hand = 3, ["upper arm"] = 1 }, blade = { forearm = 5, hand = 3, fingers = 1 },
        fall = { wrist = 4, elbow = 2, hand = 1 }, fire = { hand = 4, forearm = 3 } },
    leg = { front = { thigh = 3, knee = 2, shin = 3, foot = 1 }, back = { calf = 4, thigh = 2, ankle = 1 },
        side = { thigh = 3, knee = 2, calf = 1 }, bite = { calf = 4, ankle = 3, shin = 1 },
        fall = { ankle = 4, knee = 3, foot = 2 }, fire = { shin = 2, foot = 2, thigh = 1 } },
}
M.medicBgs = { nurse = true, doctor = true, paramedic = true, medic_mil = true, vet_animal = true, pharmacist = true,
    firefighter = true }

local function weighted(map, k)
    local keys, total = {}, 0
    for name, w in pairs(map) do keys[#keys + 1] = name end
    table.sort(keys)
    for _, name in ipairs(keys) do total = total + map[name] end
    local at = k % math.max(1, total)
    for _, name in ipairs(keys) do
        at = at - map[name]
        if at < 0 then return name end
    end
    return keys[#keys]
end

-- where the hit came from, relative to the way the NPC faces: "front" | "back" | "side" | nil
function M.hitDirection(shell, attacker)
    local dir = nil
    if attacker ~= nil then
        pcall(function()
            local fx, fy = shell:getForwardDirectionX(), shell:getForwardDirectionY()
            local dx, dy = attacker:getX() - shell:getX(), attacker:getY() - shell:getY()
            local len = math.sqrt(dx * dx + dy * dy)
            local fl = math.sqrt(fx * fx + fy * fy)
            if len > 0.01 and fl > 0.01 then
                local dot = (dx * fx + dy * fy) / (len * fl)
                dir = dot > 0.35 and "front" or (dot < -0.35 and "back" or "side")
            end
        end)
    end
    if dir == nil then pcall(function() if shell:isHitFromBehind() == true then dir = "back" end end) end
    return dir
end

-- deterministic spot for one wound (same wound -> same spot on every load)
function M.woundSpot(region, kind, cause, dir, key)
    local spots = M.woundSpots[region]
    if spots == nil then return nil end
    local how = nil
    if kind == "bite" then how = "bite"
    elseif kind == "burn" or cause == "fire" then how = "fire"
    elseif cause == "fall" or kind == "sprain" then how = "fall"
    elseif cause == "blade" and dir ~= "back" then how = "blade"
    elseif kind == "bullet" or cause == "firearm" then how = spots.bullet and "bullet" or dir end
    local map = (how and spots[how]) or spots[dir or ""] or spots.front
    if dir == nil and how == nil then -- no direction known: mix front / back / side
        local k = hash(key .. "#dir") % 10
        map = spots[k < 6 and "front" or (k < 8 and "back" or "side")]
    end
    return weighted(map, hash(key .. "#spot"))
end

local causeOfKind = { bullet = "firearm", bite = "zombie", scratch = "zombie", burn = "fire", fracture = "blunt",
    bruise = "blunt", laceration = "blade", deep = "blade", sprain = "fall" }

----------------------------------------------------------------------------------------------------------------
-- reading: A-Life's list + our detail + derived wounds + other mods
----------------------------------------------------------------------------------------------------------------
function M.alifeWoundList(record, shell)
    local pa = PA()
    local list = nil
    local data = shell and dataOf(shell) or nil
    if data ~= nil and fn(pa.Health, "injuriesOf") then pcall(function() list = pa.Health.injuriesOf(shell, data) end) end
    if list == nil and data ~= nil and type(data.ProjectALifeInjuries) == "table" then list = data.ProjectALifeInjuries end
    if list == nil and type(record) == "table" and type(record.memory) == "table" and type(record.memory.injuries) == "table" then
        list = record.memory.injuries -- offline / not loaded: the persisted copy
    end
    return type(list) == "table" and list or {}
end

function M.alifeWoundsOn()
    local pa = PA()
    return pa ~= nil and type(pa.Wounds) == "table" and type(pa.Health) == "table" and pa.Health.enabled ~= false
        and fn(pa.Health, "injuriesOf")
end

local function bleedingOf(w, h)
    local pa = PA()
    if w.src ~= "own" and pa and fn(pa.Wounds, "bleeding") then
        local ok, b = pcall(pa.Wounds.bleeding, w.raw, h)
        if ok then return b == true end
    end
    local kd = M.woundKinds[w.kind]
    if kd == nil or not kd.bleed or w.bandaged then return false end
    if kd.clotH and h >= (w.at or 0) + kd.clotH then return false end
    return true
end

function M.woundKey(uid, w) return tostring(uid) .. "|" .. tostring(w.p) .. "|" .. tostring(w.k) .. "|" .. tostring(math.floor((tonumber(w.h) or 0) * 100)) end

-- every current wound of an NPC, normalised:
-- { key, region, side, spot, part ("left forearm"), kind, label, sev, bleeding, bandaged, splinted, ageH, cause, by, src }
function M.woundsOf(uid, shell, record)
    uid = tostring(uid)
    record = record or rec(uid)
    shell = shell or shellOf(uid)
    local h = hours()
    local out = {}
    local det = bucket("wdet")[uid] or {}
    local function add(raw, src)
        local reg = M.woundRegion[raw.p]
        if reg == nil or M.woundKinds[raw.k] == nil then return end
        local key = M.woundKey(uid, raw)
        local d = det[key] or {}
        local cause = d.c or causeOfKind[raw.k]
        local spot = d.spot or M.woundSpot(reg[1], raw.k, cause, nil, key)
        local part = reg[1] == "head" and (spot or "head") or ((reg[2] and (reg[2] .. " ") or "") .. (spot or reg[1]))
        if reg[1] == "torso" and (spot == "shoulder" or spot == "side" or spot == "hip") then part = spot end
        local w = { key = key, region = reg[1], side = reg[2], spot = spot, part = part, kind = raw.k,
            label = M.woundKinds[raw.k].label, sev = tonumber(raw.s) or 30, bandaged = raw.b == true, splinted = raw.sp == true,
            at = tonumber(raw.h) or h, ageH = h - (tonumber(raw.h) or h), cause = cause, by = d.by, byPlayer = d.bp, src = src, raw = raw }
        w.bleeding = bleedingOf(w, h)
        out[#out + 1] = w
    end
    for _, raw in ipairs(M.alifeWoundList(record, shell)) do if type(raw) == "table" then add(raw, "alife") end end
    for _, raw in ipairs(bucket("wown")[uid] or {}) do add(raw, "own") end
    -- other mods: The Only Cure+ stumps (inventory items) and crawling (TOC+ / Gore lost a leg)
    if shell ~= nil then
        pcall(function()
            local items = shell:getInventory():getItems()
            for i = 0, math.min(items:size(), 120) - 1 do
                local t = tostring(items:get(i):getFullType() or "")
                local limb = string.match(t, "^TOC%.Amputation_(%a+_[LR])$")
                if limb then
                    local part, side = string.match(limb, "^(%a+)_([LR])$")
                    local names = { Hand = "hand", ForeArm = "forearm", UpperArm = "arm", Foot = "foot", LowerLeg = "lower leg", UpperLeg = "leg" }
                    out[#out + 1] = { key = uid .. "|toc|" .. limb, region = (part == "Foot" or part == "LowerLeg" or part == "UpperLeg") and "leg" or "arm",
                        side = side == "L" and "left" or "right", part = (side == "L" and "left " or "right ") .. (names[part] or "limb"),
                        kind = "amputation", label = "lost", sev = 90, ageH = 0, src = "toc" }
                end
            end
        end)
        local crawling = false
        if shell ~= nil and shell.isCrawling ~= nil then pcall(function() crawling = shell:isCrawling() == true end) end
        local data = dataOf(shell)
        if crawling and (data == nil or data.ProjectALifeInjured == nil) then
            local have = false
            for _, w in ipairs(out) do if w.kind == "amputation" and w.region == "leg" then have = true end end
            if not have then out[#out + 1] = { key = uid .. "|crawl", region = "leg", part = "legs", kind = "maimed",
                label = "can't stand - only crawl", sev = 80, ageH = 0, src = "mod" } end
        end
    end
    -- 0.5.2.10 [pt270u]: a bite (then a lost limb) always comes first - it is the one wound that decides if they live.
    -- Before, a clotted bite (sev 30-60) sorted behind two merged bruises and the page's 2-line INJURIES hid it in "+3".
    local biteFirst = M.settings.biteCore ~= false
    local rank = { bite = 0, amputation = 1 }
    table.sort(out, function(a, b)
        if biteFirst then
            local ra, rb = rank[a.kind] or 9, rank[b.kind] or 9
            if ra ~= rb then return ra < rb end
        end
        if (a.bleeding == true) ~= (b.bleeding == true) then return a.bleeding == true end
        if a.sev ~= b.sev then return a.sev > b.sev end
        return a.key < b.key
    end)
    return out
end

-- the whole picture: list + what it does to them
function M.woundState(uid, shell, record)
    uid = tostring(uid)
    record = record or rec(uid)
    shell = shell or shellOf(uid)
    local pa = PA()
    local s = { list = M.woundsOf(uid, shell, record), limp = false, arm = false, bleeding = 0, bitten = false,
        downed = false, fracture = false }
    local data = shell and dataOf(shell) or nil
    if data then
        s.limp = data.ProjectALifeWoundLeg == true or data.ProjectALifeInjuryLimp == true
        s.arm = tonumber(data.ProjectALifeArmAimScale) ~= nil and tonumber(data.ProjectALifeArmAimScale) < 1
        s.downed = data.ProjectALifeInjured == "down" or data.ProjectALifeBleedOutAtMs ~= nil
        s.recovering = data.ProjectALifeInjured == "recovering"
        s.infected = data.ProjectALifeTurnAtHours ~= nil
    end
    if not s.infected and type(record) == "table" and type(record.memory) == "table" then s.infected = record.memory.infectedTurnAtHours ~= nil end
    if shell and fn(pa and pa.Health, "hpPercent") then pcall(function() s.hp = pa.Health.hpPercent(shell) end) end
    local pain = 0
    for _, w in ipairs(s.list) do
        if w.bleeding then s.bleeding = s.bleeding + 1 end
        if w.kind == "bite" then s.bitten = true end
        if w.kind == "fracture" and not w.splinted then s.fracture = true end
        if w.region == "leg" and (w.kind == "fracture" or w.kind == "maimed" or w.kind == "amputation" or w.kind == "sprain"
            or (w.sev >= 40 and not w.bandaged and (w.kind == "deep" or w.kind == "bullet" or w.kind == "bite" or w.kind == "laceration"))) then s.limp = true end
        if w.region == "arm" and (w.kind == "fracture" or w.kind == "amputation" or (w.sev >= 45 and (w.kind == "deep" or w.kind == "bullet"))) then s.arm = true end
        local p = w.sev * (w.bleeding and 1.3 or ((w.bandaged or w.splinted) and 0.6 or 1)) * math.max(0.3, 1 - w.ageH / 96)
        pain = pain + p
    end
    s.pain = clamp(pain / M.woundCfg.painScale, 0, 0.95)
    s.hurt = #s.list > 0
    return s
end

-- "deep wound on the left forearm (bleeding)"
function M.woundText(w, opts)
    opts = opts or {}
    if w.kind == "amputation" then return "lost the " .. w.part .. " (a stump now)" end
    if w.kind == "maimed" then return "legs ruined - can only crawl" end
    local t = w.label .. " " .. ((w.region == "torso" and (w.spot == "back" or w.spot == "belly" or w.spot == "chest" or w.spot == "ribs")) and "in the " or "on the ") .. w.part
    local tags = {}
    if w.bleeding then tags[#tags + 1] = "bleeding" elseif w.bandaged then tags[#tags + 1] = "bandaged" end
    if w.splinted then tags[#tags + 1] = "splinted" end
    if opts.cause and w.by then tags[#tags + 1] = (w.byPlayer and "you did it" or (w.by .. " did it")) end
    if w.ageH and w.ageH < 1 and not opts.short then tags[#tags + 1] = "fresh" end
    if #tags > 0 then t = t .. " (" .. table.concat(tags, ", ") .. ")" end
    return t
end

----------------------------------------------------------------------------------------------------------------
-- detail for new wounds (spot from the hit direction, cause, who) + derived wounds
----------------------------------------------------------------------------------------------------------------
function M.noteWoundDetail(uid, shell, w)
    local pa = PA()
    local det = bucket("wdet")
    local row = det[tostring(uid)] or {}
    det[tostring(uid)] = row
    if row[w.key] ~= nil then return row[w.key] end
    local data = shell and dataOf(shell) or {}
    local attacker = nil
    if shell and pa and type(pa.Health) == "table" and type(pa.Health.lastAttacker) == "table" then
        pcall(function() attacker = pa.Health.lastAttacker[shell] end)
    end
    local cause = (w.ageH or 0) <= M.woundCfg.freshH and data.ProjectALifeLastAttackKind or nil
    if cause == nil or cause == "unknown" then cause = w.cause or causeOfKind[w.kind] end
    if cause == "melee" or cause == "fists" then cause = (w.kind == "laceration" or w.kind == "deep") and "blade" or "blunt" end
    local dir = M.hitDirection(shell, attacker)
    local d = { c = cause, dir = dir, at = hours() }
    d.spot = M.woundSpot(w.region, w.kind, cause, dir, w.key)
    if attacker ~= nil then
        pcall(function()
            if instanceof(attacker, "IsoPlayer") then d.by, d.bp = "the newcomer", true
            else
                local au = M.uidOf and M.uidOf(attacker) or nil
                if au then d.by, d.byUid = nameOf(rec(au)), tostring(au)
                elseif instanceof(attacker, "IsoZombie") then d.by = "a zombie" end
            end
        end)
    end
    row[w.key] = d
    return d
end

function M.pruneWoundDetail(uid, list)
    local det = bucket("wdet")
    local row = det[tostring(uid)]
    if row == nil then return end
    local live = {}
    for _, w in ipairs(list) do live[w.key] = true end
    local n = 0
    for k in pairs(row) do if not live[k] then row[k] = nil else n = n + 1 end end
    if n == 0 then det[tostring(uid)] = nil end
end

-- our own wound (falls; everything when A-Life's wound system is missing)
function M.addOwnWound(uid, part, kind, sev, cause, by)
    local all = bucket("wown")
    local list = all[tostring(uid)] or {}
    all[tostring(uid)] = list
    local raw = { p = part, k = kind, s = clamp(tonumber(sev) or 30, 5, 100), h = hours() }
    list[#list + 1] = raw
    while #list > 8 do table.remove(list, 1) end
    local key = M.woundKey(uid, raw)
    local det = bucket("wdet")
    det[tostring(uid)] = det[tostring(uid)] or {}
    local reg = M.woundRegion[part] or { "torso" }
    det[tostring(uid)][key] = { c = cause, by = by, spot = M.woundSpot(reg[1], kind, cause, nil, key), at = raw.h }
    return raw
end
function M.healOwnWounds(uid, h)
    local all = bucket("wown")
    local list = all[tostring(uid)]
    if list == nil then return end
    local kept = {}
    for _, raw in ipairs(list) do
        local kd = M.woundKinds[raw.k] or M.woundKinds.bruise
        local healAt = (raw.h or 0) + kd.healH * (0.5 + (raw.s or 50) / 100) * ((kd.bleed and not raw.b) and 1.25 or 1)
        if h < healAt then kept[#kept + 1] = raw end
    end
    all[tostring(uid)] = #kept > 0 and kept or nil
end

-- the same classification A-Life uses (only for the fallback tracker)
function M.classifyOwn(cause, region, k)
    if cause == "firearm" then return "bullet", 45 + k % 40 end
    if cause == "blade" then return (k % 10 < 7) and "laceration" or "deep", 25 + k % 45 end
    if cause == "zombie" then local r = k % 100; return r < 55 and "scratch" or (r < 85 and "laceration" or "bite"), 10 + k % 45 end
    if cause == "fall" then return region == "leg" and ((k % 10 < 4) and "fracture" or "sprain") or "bruise", 30 + k % 40 end
    if cause == "fire" then return "burn", 15 + k % 10 end
    if region == "arm" or region == "leg" then local r = k % 100; return r < 70 and "bruise" or (r < 80 and "scratch" or "fracture"), 25 + k % 35 end
    return "bruise", 10 + k % 20
end
function M.ownHit(shell, attacker, cause, bodyPartName)
    if M.alifeWoundsOn() or shell == nil then return end
    local uid = M.uidOf and M.uidOf(shell) or nil
    if uid == nil then return end
    local k = hash(tostring(uid) .. "#" .. tostring(nowMs()))
    local part = nil
    local name = string.lower(tostring(bodyPartName or ""))
    if string.find(name, "head", 1, true) or string.find(name, "neck", 1, true) then part = "head"
    elseif string.find(name, "hand", 1, true) or string.find(name, "arm", 1, true) then part = string.find(name, "_l", 1, true) and "arm_l" or "arm_r"
    elseif string.find(name, "leg", 1, true) or string.find(name, "foot", 1, true) or string.find(name, "thigh", 1, true) then part = string.find(name, "_l", 1, true) and "leg_l" or "leg_r"
    elseif name ~= "" then part = "torso" end
    if part == nil then
        local r = k % 100
        part = r < 12 and "head" or (r < 45 and "torso" or (r < 60 and "arm_l" or (r < 75 and "arm_r" or (r < 88 and "leg_l" or "leg_r"))))
    end
    local region = (M.woundRegion[part] or { "torso" })[1]
    local kind, sev = M.classifyOwn(cause, region, math.floor(k / 7))
    local by = nil
    pcall(function() if instanceof(attacker, "IsoPlayer") then by = "the newcomer" elseif cause == "zombie" then by = "a zombie" end end)
    M.addOwnWound(uid, part, kind, sev, cause, by)
end

----------------------------------------------------------------------------------------------------------------
-- personality-shaped first-person lines (used as the AI's guide and as the fallback when no AI line comes)
----------------------------------------------------------------------------------------------------------------
M.woundLines = {
    bite = { "It bit my %s.", "The thing got my %s... it got me.", "My %s - it bit me. Oh no." },
    bleed = { "I'm bleeding bad from my %s.", "My %s won't stop bleeding.", "Blood's pouring out of my %s." },
    leg = { "My %s - I can't run.", "Can't put weight on my %s.", "My %s is shot, I can barely walk." },
    fracture = { "My %s is broken. I heard it go.", "Broke my %s. Don't touch it.", "My %s - it's broken, it's bent wrong." },
    bullet = { "I took one in the %s.", "I'm shot - my %s!", "Bullet in my %s. Damn it." },
    burn = { "My %s is burned raw.", "Burned my %s - it's blistering.", "My %s, it's cooking - get it off!" },
    scratch = { "Just a scratch on my %s. Just a scratch.", "It scratched my %s.", "Scratched my %s, it's fine. It's fine." },
    bruise = { "Took a hit to the %s. I'll live.", "My %s is going to be purple tomorrow.", "Ow - my %s." },
    cut = { "Got cut on my %s.", "My %s is sliced open.", "They opened up my %s." },
    amputation = { "My %s... it's gone. It's just gone.", "Where's my %s? Where is it?" },
    maimed = { "My legs won't hold me. I can't get up.", "I can't stand - I'm crawling like one of them." },
    ask = { "You got a bandage? I'm bleeding here.", "Anything to wrap this %s with? Rags, anything.", "Please - a bandage, I'm losing blood." },
}
M.woundStyleWrap = {
    tough = { "It's nothing. %s", "%s Keep moving.", "%s Don't fuss." },
    mean = { "%s Stop staring.", "%s What, never seen blood?", "Back off. %s" },
    mope = { "Of course. %s Figures.", "%s Just my luck.", "%s Doesn't matter anyway." },
    unhinged = { "Heh. %s Look at it.", "%s The voices said this would happen.", "%s ...it's kind of pretty." },
    fearful = { "Oh god - %s Is it bad? Is it bad?", "%s I'm scared.", "%s Help me, please." },
    preach = { "%s The Lord's testing me.", "%s Judgement day, one cut at a time." },
}
function M.woundTone(uid)
    local lens = M.lens and M.lens(uid) or {}
    local kind, style = nil, lens.style
    if M.personaKind then kind = M.personaKind(uid) end
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    if style == "giggle" or style == "ramble" or kind == "unhinged" then return "unhinged" end
    if style == "preach" then return "preach" end
    if style == "insult" or style == "mock" or (lens.mean or 0) >= 0.3 then return "mean" end
    if style == "mope" then return "mope" end
    if (lens.fearful or 0) >= 0.2 or (b.fear or 0) > 0.5 then return "fearful" end
    if (lens.brave or 0) >= 0.2 or (lens.disciplined or 0) >= 0.25 or (lens.proud or 0) >= 0.25 then return "tough" end
    return nil
end
function M.woundLineKey(w, s)
    if w.kind == "amputation" or w.kind == "maimed" or w.kind == "bite" then return w.kind end
    if w.bleeding and w.sev >= 35 then return "bleed" end
    if w.kind == "fracture" then return "fracture" end
    if w.region == "leg" and s and s.limp then return "leg" end
    if w.kind == "bullet" or w.kind == "burn" or w.kind == "scratch" or w.kind == "bruise" then return w.kind end
    if w.kind == "laceration" or w.kind == "deep" then return "cut" end
    return "bruise"
end
function M.woundLine(uid, w, s, which)
    local key = which or M.woundLineKey(w, s)
    local list = M.woundLines[key] or M.woundLines.bruise
    local k = hash(tostring(uid) .. "#" .. tostring(w.key) .. "#" .. key)
    local spot = (key == "bleed" and w.region == "arm" and w.side) and (w.side .. " arm") or w.part
    local line = string.format(pick(list, k), spot)
    local tone = M.woundTone(uid)
    if tone and M.woundStyleWrap[tone] and key ~= "maimed" then
        line = string.format(pick(M.woundStyleWrap[tone], math.floor(k / 3)), line)
    end
    return line
end

----------------------------------------------------------------------------------------------------------------
-- reactions
----------------------------------------------------------------------------------------------------------------
M.woundSeen = {}   -- uid -> { [key] = true }
M.woundTalkAt = {} -- uid -> ms
M.woundZ = {}

local function speakOr(mode, l, player, react, opts, fallback)
    if M.react(mode, l, player, react, opts) then return true end
    -- no bridge: say the stock line ourselves (cooldown by key)
    if fallback and not M.bridgeAlive(nowMs()) then
        local key = (opts and opts.key) or mode
        M.woundSaidAt = M.woundSaidAt or {}
        if nowMs() - (M.woundSaidAt[key] or -1e12) >= ((opts and opts.keyCooldownMs) or 60000) then
            M.woundSaidAt[key] = nowMs()
            return M.say(l.shell, nil, fallback, { record = l.record, combat = true })
        end
    end
    return false
end

-- feelings: pain tracks the wounds; fresh ones scare / anger / crush them
function M.woundFeel(uid, w, s)
    if not M.feel then return end
    local sev = (w and w.sev or 30) / 100
    if w then
        M.feel(uid, "pain", 0.25 + sev * 0.6, w.label .. " on the " .. tostring(w.part))
        M.feel(uid, "fear", (w.bleeding and 0.25 or 0.1) + (w.kind == "bite" and 0.5 or 0) + (w.kind == "amputation" and 0.4 or 0), "hurt: " .. tostring(w.part))
        if w.kind == "bite" or w.kind == "amputation" or w.kind == "maimed" or (w.kind == "fracture" and sev > 0.5) then
            M.feel(uid, "despair", w.kind == "bite" and 0.45 or 0.3, w.kind == "bite" and "bitten - they know what it means" or "badly maimed")
        end
        if w.by and w.by ~= "a zombie" then M.feel(uid, "anger", 0.25, (w.byPlayer and "you" or w.by) .. " hurt them") end
    end
    if s then -- pain never sits far below what the wounds say
        local row = M.emoRow and M.emoRow(uid) or nil
        local cur = row and tonumber(row.e.pain) or 0
        if s.pain > cur + 0.03 then M.feel(uid, "pain", s.pain - cur, nil, { raw = true }) end
        if s.bleeding > 0 and s.hp and s.hp < 45 then M.feel(uid, "dread", 0.05, "losing blood") end
    end
end

function M.isMedic(uid)
    local p = M.partsOf and M.partsOf(uid) or nil
    local bg = p and p.bg and p.bg.key or nil
    return bg ~= nil and M.medicBgs[bg] == true, bg
end
function M.isCruel(uid)
    local kind, style = nil, nil
    if M.personaKind then kind, style = M.personaKind(uid) end
    local p = M.partsOf and M.partsOf(uid) or nil
    local core = p and p.core and p.core.key or nil
    if core == "cruel" or core == "mean" or core == "bully" or core == "petty" then return true end
    local lens = M.lens and M.lens(uid) or {}
    return (lens.mean or 0) >= 0.35
end

-- a comrade sees the wound: medic helps, cruel mocks, close ones worry
function M.comradeReact(victim, w, s, player)
    local pa = PA()
    local vx, vy, vz = nil, nil, nil
    pcall(function() vx, vy, vz = victim.shell:getX(), victim.shell:getY(), victim.shell:getZ() end)
    if vx == nil then return nil end
    local vuid = tostring(victim.record.uid)
    local best, bestScore, role = nil, -1, nil
    for _, l in ipairs(M.nearbyNpcs(vx, vy, vz, M.woundCfg.seeTiles, vuid)) do
        local u = tostring(l.record.uid)
        local w8, t = 0, "stranger"
        if M.closeness then w8, t = M.closeness(u, vuid) end
        local same = type(l.record.memory) == "table" and type(victim.record.memory) == "table" and l.record.memory.groupId ~= nil
            and l.record.memory.groupId == victim.record.memory.groupId
        local medic = M.isMedic(u)
        local cruel = M.isCruel(u)
        local score, r = -1, nil
        if medic and (same or w8 >= 0.3) then score, r = 3 + w8, "medic"
        elseif cruel and (same or t == "rival" or t == "distrust" or t == "enemy" or w8 < 0.3) then score, r = 2 + (1 - w8), "mock"
        elseif w8 >= 0.45 or same then score, r = 1 + w8, "worry" end
        if score > bestScore then best, bestScore, role = l, score, r end
    end
    if best == nil then return nil end
    best.t = "comrade"
    if M.closeness then local _, tt = M.closeness(best.record.uid, vuid); best.t = tt or best.t end
    local vname = nameOf(victim.record)
    local what = vname .. " is hurt: " .. M.woundText(w, { short = true })
    local style
    if role == "medic" then
        style = "you have medical training (" .. tostring(select(2, M.isMedic(best.record.uid))) .. "): take charge, tell them what to do for this exact wound, offer to patch it"
        local P = M.patch and M.patch() or nil
        if P and fn(P, "treatOther") and (w.bleeding or w.kind == "fracture") then
            local ok, done = pcall(P.treatOther, tostring(best.record.uid), vuid)
            if ok and done then
                style = style .. "; you're patching them up right now"
                if M.pairBump then pcall(M.pairBump, best.record.uid, vuid, 4, "patched up their " .. tostring(w.part)) end
                if M.feel then M.feel(vuid, "gratitude", 0.3, nameOf(best.record) .. " patched them up"); M.feel(vuid, "relief", 0.3, "wound dressed") end
            end
        end
    elseif role == "mock" then
        style = "you're cruel: mock their " .. tostring(w.part) .. " wound, make fun of them for getting hurt - words only"
        if M.pairBump then pcall(M.pairBump, best.record.uid, vuid, -4, "mocked their wound") end
        if M.feel then M.feel(vuid, "shame", 0.15, nameOf(best.record) .. " mocked their wound"); M.feel(vuid, "anger", 0.15, "mocked") end
    else
        style = "they're your " .. tostring(best.t) .. ": worried about exactly this wound; ask about it, tell them to sit / wrap it"
    end
    local fallback = role == "medic" and ("Let me see that " .. tostring(w.part) .. ". Hold still.")
        or (role == "mock" and ("Look at you, crying over a " .. tostring(w.label) .. "."))
        or ("Your " .. tostring(w.part) .. " - let me see it. Sit down.")
    speakOr("injury", best, player, { what = "You see that " .. what, style = style, maxWords = 16, fallback = fallback },
        { key = "injury:" .. vuid .. ":injury", keyCooldownMs = M.woundCfg.comradeGapMs }, fallback)
    log("wound: " .. nameOf(best.record) .. " (" .. tostring(role) .. ") reacts to " .. what)
    return role, best
end

-- a fresh wound on an NPC near the player
function M.onFreshWound(l, w, s, player)
    local uid = tostring(l.record.uid)
    local d = M.noteWoundDetail(uid, l.shell, w)
    w.spot, w.cause, w.by, w.byPlayer = d.spot or w.spot, d.c or w.cause, d.by, d.bp
    local reg = M.woundRegion[w.raw and w.raw.p or ""]
    if reg and w.spot then
        w.part = reg[1] == "head" and w.spot or ((reg[2] and (reg[2] .. " ") or "") .. w.spot)
        if reg[1] == "torso" and (w.spot == "shoulder" or w.spot == "side" or w.spot == "hip") then w.part = w.spot end
    end
    log("wound: " .. nameOf(l.record) .. " - " .. M.woundText(w, { cause = true }) .. " [" .. tostring(w.cause) .. ", " .. tostring(d.dir or "?") .. "]")
    M.woundFeel(uid, w, s)
    if M.logInteraction then pcall(M.logInteraction, uid, "Hurt: " .. M.woundText(w, { cause = true, short = true }), nil, nil, "wound") end
    if M.keyMem and (w.sev >= 40 or w.kind == "bite") then pcall(M.keyMem, uid, "event", "Got a " .. M.woundText(w, { cause = true, short = true })) end
    local P = M.patch and M.patch() or nil
    if P and fn(P, "woundGesture") then pcall(P.woundGesture, uid, w.region) end
    if s.downed then return end -- A-Life's own downed barks have the floor
    if w.kind ~= "bite" then -- (bites: the injury module speaks; its line now names the spot too)
        local line = M.woundLine(uid, w, s)
        speakOr("injury_self", l, player, { what = "You just got hurt: " .. M.woundText(w, { cause = true }) .. ". React to this exact wound",
            style = "in your own voice; e.g. \"" .. line .. "\"", maxWords = 14, fallback = line },
            { key = "self:" .. uid, keyCooldownMs = M.woundCfg.selfGapMs, urgent = w.sev >= 40 }, line)
        M.woundTalkAt[uid] = nowMs()
    end
    if w.sev >= 25 or w.bleeding or w.kind == "bite" then pcall(M.comradeReact, l, w, s, player) end
end

-- now and then: the wound still hurts / they ask for a bandage / they sit down
function M.woundMention(l, s, player, dist2)
    local uid = tostring(l.record.uid)
    local now = nowMs()
    local top = s.list[1]
    if top == nil or s.downed then return end
    local pa = PA()
    local P = M.patch and M.patch() or nil
    -- bleeding with nothing to dress it: ask the newcomer (if they don't hate them)
    if s.bleeding > 0 and dist2 <= M.woundCfg.talkTiles ^ 2 and now - (M.woundTalkAt[uid] or -1e12) >= M.woundCfg.askGapMs then
        local hasKit = false
        if fn(pa.ModuleHealing, "dressingOf") then pcall(function() hasKit = pa.ModuleHealing.dressingOf(l.shell) ~= nil end) end
        local op = 0
        pcall(function() op = pa.NpcOpinion.valueOf(l.record, player) or 0 end)
        if not hasKit and op >= -15 then
            local busy = fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now)
            if not busy then
                M.woundTalkAt[uid] = now
                local line = string.format(pick(M.woundLines.ask, hash(uid .. "#ask")), top.part)
                local tone = M.woundTone(uid)
                local style = tone == "tough" and "too proud to beg: hint that a bandage would help"
                    or (tone == "mean" and "demand a bandage, rudely") or "ask the newcomer for a bandage or rags"
                speakOr("injury_self", l, player, { what = "You're bleeding from your " .. top.part .. " and have nothing to dress it with",
                    style = style .. "; e.g. \"" .. line .. "\"", maxWords = 14, fallback = line, wantBandage = true },
                    { key = "ask:" .. uid, keyCooldownMs = M.woundCfg.askGapMs, face = "player" }, line)
                M.woundWants = M.woundWants or {}
                M.woundWants[uid] = now
                return
            end
        end
    end
    -- sit down to rest (patch): bad leg / low health, no danger around, personality allowing
    if P and fn(P, "woundRest") and (s.fracture or s.limp or (s.hp and s.hp < 45)) and now - ((M.woundRestAt or {})[uid] or -1e12) >= M.woundCfg.restGapMs then
        local lens = M.lens and M.lens(uid) or {}
        local stubborn = (lens.brave or 0) >= 0.25 or (lens.disciplined or 0) >= 0.3 or (lens.proud or 0) >= 0.3
        if not stubborn or s.fracture then
            M.woundRestAt = M.woundRestAt or {}
            M.woundRestAt[uid] = now
            local ok, sat = pcall(P.woundRest, uid, M.woundCfg.restMs, top.part)
            if ok and sat then
                log("wound: " .. nameOf(l.record) .. " sits down to rest (" .. top.part .. ")")
                local line = s.limp and string.format(pick(M.woundLines.leg, hash(uid .. "#rest")), top.region == "leg" and top.part or "leg")
                    or "I need to sit. Just for a minute."
                speakOr("injury_self", l, player, { what = "You sit down to rest your " .. top.part, style = "tired, in pain", maxWords = 10, fallback = line },
                    { key = "rest:" .. uid, keyCooldownMs = M.woundCfg.restGapMs }, line)
                return
            end
        end
    end
    -- a passing remark about it
    if dist2 <= M.woundCfg.talkTiles ^ 2 and now - (M.woundTalkAt[uid] or -1e12) >= M.woundCfg.mentionGapMs and M.roll(100) < 35 then
        M.woundTalkAt[uid] = now
        local line = M.woundLine(uid, top, s)
        speakOr("injury_self", l, player, { what = "Your " .. M.woundText(top) .. " is still hurting" .. (s.limp and " and you're limping" or ""),
            style = "mention it in passing, in your own voice; e.g. \"" .. line .. "\"", maxWords = 12, fallback = line },
            { key = "mention:" .. uid, keyCooldownMs = M.woundCfg.mentionGapMs }, line)
    end
end

-- fall: z dropped by a floor or more without stairs (A-Life has "fall" wounds but never records them)
function M.checkFall(l)
    local uid = tostring(l.record.uid)
    local z, sq = nil, nil
    pcall(function() z = math.floor(l.shell:getZ()); sq = l.shell:getCurrentSquare() end)
    local prev = M.woundZ[uid]
    M.woundZ[uid] = z ~= nil and { z = z, stairs = sq ~= nil and (function() local ok, v = pcall(function() return sq:HasStairs() end); return ok and v == true end)() } or nil
    if prev == nil or z == nil or prev.z - z < 1 or prev.stairs or (M.woundZ[uid] and M.woundZ[uid].stairs) then return false end
    local P = M.patch and M.patch() or nil
    local done = false
    if P and fn(P, "addFallWound") then
        local ok, part, kind = pcall(P.addFallWound, uid)
        done = ok and part ~= nil
    end
    if not done then
        local k = hash(uid .. "#fall#" .. tostring(math.floor(hours() * 10)))
        local kind, sev = M.classifyOwn("fall", "leg", k)
        M.addOwnWound(uid, (k % 2 == 0) and "leg_l" or "leg_r", kind, sev + (prev.z - z - 1) * 15, "fall", nil)
    end
    log("wound: " .. nameOf(l.record) .. " fell " .. tostring(prev.z - z) .. " floor(s)")
    return true
end

function M.woundTick()
    if not M.settings.enabled or M.settings.wounds == false or not M.worldHere() then return end
    local now = nowMs()
    if now < (M.woundNextAt or 0) then return end
    M.woundNextAt = now + M.woundCfg.everyMs
    M.eachPlayer(M.woundTickFor, now) -- pre-1.0 MP: wounds watched near every player (SP: you)
end
function M.woundTickFor(player, now)
    if player == nil then return end
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local h = hours()
    for _, l in ipairs(M.nearbyNpcs(px, py, pz, M.woundCfg.watchTiles)) do
        local uid = tostring(l.record.uid)
        pcall(M.checkFall, l)
        M.healOwnWounds(uid, h)
        local s = M.woundState(uid, l.shell, l.record)
        local seen = M.woundSeen[uid]
        local fresh = {}
        local cur = {}
        for _, w in ipairs(s.list) do
            cur[w.key] = true
            if w.raw ~= nil then
                if seen ~= nil and not seen[w.key] and (w.ageH or 0) <= M.woundCfg.freshH + 0.05 then fresh[#fresh + 1] = w end
                if seen == nil then M.noteWoundDetail(uid, l.shell, w) end -- first look: fill in detail quietly
            elseif seen ~= nil and not seen[w.key] then fresh[#fresh + 1] = w end
        end
        M.woundSeen[uid] = cur
        if #s.list == 0 then M.pruneWoundDetail(uid, s.list) end
        if #fresh > 0 then
            table.sort(fresh, function(a, b) return a.sev > b.sev end)
            pcall(M.onFreshWound, l, fresh[1], s, player)
        elseif s.hurt then
            M.woundFeel(uid, nil, s)
            pcall(M.woundMention, l, s, player, l.d2 or 1e9)
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- treatment: the player's bandage / splint gift
----------------------------------------------------------------------------------------------------------------
M.treatItems = { ["Base.Bandage"] = "bandage", ["Base.AlcoholBandage"] = "bandage", ["Base.RippedSheets"] = "rags",
    ["Base.AlcoholRippedSheets"] = "rags", ["Base.Splint"] = "splint" }
M.woundTreated = {} -- uid -> { what, at } (for the next prompt)
function M.onTreatGift(player, listener, items)
    local uid = tostring(listener.record.uid)
    local s = M.woundState(uid, listener.shell, listener.record)
    for _, info in ipairs(items or {}) do
        local what = M.treatItems[tostring(info.fullType or "")]
        if what then
            local need = (what == "splint" and s.fracture) or (what ~= "splint" and (s.bleeding > 0 or s.downed))
            if need then
                local P = M.patch and M.patch() or nil
                local result = "own"
                if P and fn(P, "treatWithItem") then
                    local ok, done, how = pcall(P.treatWithItem, uid, info.fullType, player)
                    result = ok and done and (how or "dressing") or ("failed " .. tostring(how))
                end
                -- without the patch A-Life's own Dress Wounds module uses a Bandage / RippedSheets from their bag
                local top = s.list[1]
                M.woundTreated[uid] = { what = what, part = top and top.part or nil, at = nowMs(), how = result }
                if M.feel then M.feel(uid, "relief", 0.35, "you gave them a " .. what .. " for the wound"); M.feel(uid, "gratitude", 0.3, "your " .. what) end
                if M.logInteraction then pcall(M.logInteraction, uid, "You gave them a " .. what .. " for their " .. tostring(top and top.part or "wound"), nil, nil, "wound") end
                log("wound: " .. nameOf(listener.record) .. " treats their wound with your " .. what .. " (" .. tostring(result) .. ")")
                if M.addDeed then pcall(M.addDeed, "medic", "the stranger patched up " .. nameOf(listener.record) .. "'s wounds", 4, { uid }) end -- 0.5.1: "the medic"
                return true
            end
        end
    end
    return false
end
if type(M.onGift) == "function" and not M._woundGiftWrapped then
    M._woundGiftWrapped = true
    local orig = M.onGift
    M.onGift = function(player, listener, items, opts)
        pcall(M.onTreatGift, player, listener, items) -- first: the gift prompt then knows they're dressing it
        return orig(player, listener, items, opts)
    end
end

----------------------------------------------------------------------------------------------------------------
-- fallback hit tracking (only when A-Life's wound system is missing)
----------------------------------------------------------------------------------------------------------------
if type(Events) == "table" then
    if Events.OnHitZombie and type(Events.OnHitZombie.Add) == "function" then
        ALifeHealth.add(Events.OnHitZombie, "ALifeLLMTalk_Wounds", function(zombie, attacker, bodyPart, weapon)
            if M.alifeWoundsOn() then return end
            pcall(function()
                local pa = PA()
                local cause = "blunt"
                if weapon ~= nil and fn(pa.Wounds, "weaponKind") then cause = pa.Wounds.weaponKind(weapon) or cause
                elseif weapon ~= nil then
                    local ok, ranged = pcall(function() return weapon:isRanged() end)
                    if ok and ranged then cause = "firearm" end
                end
                M.ownHit(zombie, attacker, cause, bodyPart and tostring(bodyPart) or nil)
            end)
        end)
    end
    if Events.ProjectALife_NpcHit and type(Events.ProjectALife_NpcHit.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcHit, "ALifeLLMTalk_Wounds", function(body, attacker, damage)
            if M.alifeWoundsOn() then return end
            pcall(function() if instanceof(attacker, "IsoZombie") and (M.uidOf == nil or M.uidOf(attacker) == nil) then M.ownHit(body, attacker, "zombie", nil) end end)
        end)
    end
end

----------------------------------------------------------------------------------------------------------------
-- prompt: their body right now (so "you okay?" gets the real answer)
----------------------------------------------------------------------------------------------------------------
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.wounds == false or listener == nil or listener.record == nil then return end
    local uid = tostring(listener.record.uid)
    local s = M.woundState(uid, listener.shell, listener.record)
    local t = M.woundTreated[uid]
    if not s.hurt and t == nil then return end
    local out = { list = {}, limp = s.limp or nil, arm = s.arm or nil, downed = s.downed or nil, hp = s.hp,
        bitten = s.bitten or nil, pain = math.floor(s.pain * 10 + 0.5) }
    for i, w in ipairs(s.list) do
        if i > M.woundCfg.maxPrompt then break end
        out.list[#out.list + 1] = M.woundText(w, { cause = true })
    end
    if #s.list > M.woundCfg.maxPrompt then out.more = #s.list - M.woundCfg.maxPrompt end
    local want = M.woundWants and M.woundWants[uid]
    if want and now - want < 600000 and s.bleeding > 0 then out.wantsBandage = true end
    if t and now - t.at < 600000 then out.treated = "the newcomer just gave you a " .. t.what .. (t.part and (" for your " .. t.part) or "")
        .. ((t.how == "dressing" or t.how == "own") and " - you're dressing it now" or (t.how == "splinted" and " - you splinted it" or "")) end
    req.wounds = out
end)

----------------------------------------------------------------------------------------------------------------
-- the bite (for the bite reaction in the injury module): "left forearm"
function M.biteSpot(uid, shell, record)
    for _, w in ipairs(M.woundsOf(uid, shell, record)) do
        if w.kind == "bite" then
            local d = M.noteWoundDetail(uid, shell, w)
            local reg = M.woundRegion[w.raw and w.raw.p or ""] or { w.region }
            local spot = d.spot or w.spot
            if reg[1] == "head" then return spot or "neck" end
            if reg[1] == "torso" then return spot or "shoulder" end
            return ((reg[2] and (reg[2] .. " ")) or "") .. (spot or reg[1])
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- page / overview: one short line
-- 0.5.2.10: "40 min ago" / "5 h ago" / "2 days ago"
function M.agoText(h)
    h = tonumber(h) or 0
    if h < 1 then return tostring(math.max(1, math.floor(h * 60 + 0.5))) .. " min ago" end
    if h < 48 then return tostring(math.floor(h + 0.5)) .. " h ago" end
    return tostring(math.floor(h / 24 + 0.5)) .. " days ago"
end
----------------------------------------------------------------------------------------------------------------
function M.injuryLine(uid, limit)
    local s = M.woundState(uid)
    if not s.hurt then return nil, s end
    local parts = {}
    local biteOn = M.settings.biteCore ~= false
    for i, w in ipairs(s.list) do
        if i > (limit or 2) then break end
        local t = w.kind == "amputation" and ("lost " .. w.part) or (w.kind == "maimed" and "can only crawl")
            or (string.upper(string.sub(w.label, 1, 1)) .. string.sub(w.label, 2) .. " \194\183 " .. w.part)
        if biteOn and w.kind == "bite" then -- 0.5.2.10 [pt270u]: "Bite - left shin (infected?) - 5 h ago", drawn red
            t = "Bite \194\183 " .. w.part .. (s.turned and " (turning)" or " (infected?)") .. " \194\183 " .. M.agoText(w.ageH)
        elseif w.bleeding then t = t .. " (bleeding)" elseif w.splinted then t = t .. " (splinted)" elseif w.bandaged then t = t .. " (bandaged)" end
        parts[#parts + 1] = { text = t, bleeding = w.bleeding, covered = w.bandaged or w.splinted, bite = (biteOn and w.kind == "bite") or nil }
    end
    -- the wound healed off A-Life's list but they are still bitten (infected / our bite record): keep it on top
    if biteOn and not s.bitten and M.biteInfo then
        local bi = M.biteInfo(uid)
        if bi ~= nil then
            table.insert(parts, 1, { text = "Bite \194\183 " .. tostring(bi.spot or "healed over") .. " (infected?) \194\183 " .. M.agoText(bi.ageH), bite = true })
            if #parts > (limit or 2) then table.remove(parts) end
            s.bitten = true
        end
    end
    local extra = math.max(0, #s.list - #parts)
    return parts, s, extra
end

if type(Events) == "table" and Events.OnTick then
    local n = 0
    ALifeHealth.tickAdd("ALifeLLMTalk_Wounds", function()
        n = n + 1
        if n % 30 ~= 11 then return end
        local ok, e = pcall(M.woundTick)
        if not ok then log("wound tick error: " .. tostring(e)) end
    end)
end
return M
