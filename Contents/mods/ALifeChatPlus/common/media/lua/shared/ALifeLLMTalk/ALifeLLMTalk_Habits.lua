-- A-Life Talk 0.5.1.7: ROUTINES AND HABITS - more to do than sit (daily schedule, chores, meals, water, smoking, drinking)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Habits") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Habits"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Habits") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
M.spokeAt = M.spokeAt or {}
-- one line: the AI (react mode) with a canned fallback
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    if l == nil or l.record == nil then return false end
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid) .. (opts.sub and (":" .. opts.sub) or "")
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 8000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 16,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say and l.shell then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur == nil then -- pre-1.0 MP: first player with people near
        for _, p in ipairs(ALifeSide.online()) do
            local x, y, z = pos(p)
            local list = M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}
            if #list > 0 then return list, p end
        end
        return {}, nil
    end
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    if x == nil then return {}, player end
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    local uid = tostring(l.record.uid)
    if M.isPaused and M.isPaused(uid) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Habits", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = true, nil
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- pre-1.0 MP: once per online player
            M.eachPlayer(function() local ok2, e2 = pcall(f, now); if not ok2 then ok, e = ok2, e2 end end)
        else ok, e = pcall(f, now) end
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
local function lensOf(uid) local ok, l = pcall(function() return M.lens and M.lens(uid) or {} end); return ok and type(l) == "table" and l or {} end
local function keyOf(uid) local ok, k = pcall(function() local p = M.partsOf and M.partsOf(uid) or nil; return p and p.core and p.core.key or "" end); return ok and tostring(k or "") or "" end
local function modsOf(uid) local ok, m = pcall(function() return M.personaMods and M.personaMods(uid) or {} end); return ok and type(m) == "table" and m or {} end
local function opinionOf(uid, player)
    local r = rec(uid)
    local pa = PA()
    if r and player and fn(pa.NpcOpinion, "valueOf") then
        local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
        if ok and tonumber(v) then return tonumber(v) end
    end
    local e = bucket("book")[tostring(uid)]
    if type(e) == "table" and tonumber(e.value) then return tonumber(e.value) end
    return nil
end
local function opAdj(uid, player, d, why)
    local r = rec(uid)
    if r == nil or player == nil or d == 0 then return false end
    local pa = PA()
    local f = M.origAdjust or (pa.NpcOpinion and pa.NpcOpinion.adjust)
    if type(f) ~= "function" then return false end
    return pcall(f, r, player, d, why)
end
local function listenerOf(uid)
    local pa = PA()
    local r = rec(uid)
    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil
    if r == nil or sh == nil then return nil end
    return { record = r, shell = sh }
end
local function distTo(l, player)
    local x, y = pos(l and l.shell); local px, py = pos(player)
    if x == nil or px == nil then return 1e9 end
    return math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
end

----------------------------------------------------------------------------------------------------------------
-- more to do than sit: a daily routine (time of day, weather, personality) and personal habits. Smokers smoke and
-- bum one off you; drinkers drink (more when stressed or grieving - tipsy talk comes from the drunk meter);
-- everyone eats and drinks water on a schedule. Sitting is capped. All of it runs inside the existing 4 s activity
-- tick (weights at pick time) - no per-frame work, and the activity tick's busy / listen / party / danger checks
-- still decide WHETHER they do anything.
----------------------------------------------------------------------------------------------------------------
setting("habits", true)
M.habitCfg = { sitCap = 0.25, recentN = 8, mealGapH = 5, waterGapH = 4, smokeGapH = 3, askCdH = 6, askTiles = 8, waterTiles = 8, waterCacheMs = 600000 }
M.habitNew = {
    cook = { preset = "search_mid", alt = "build_crate", ms = 240000, words = "cooking something", line = { "Smells almost like food.", "Who wants some?" } },
    water = { preset = "talk_water", alt = "drink", ms = 60000, words = "drinking some water", line = { "Gotta stay hydrated.", "Tastes like the bottle. Still good." } },
    booze = { preset = "talk_booze", alt = "drink", ms = 150000, words = "having a drink (the hard stuff)", line = { "Just one. Maybe two.", "To the ones who aren't here." } },
    patrol = { preset = nil, window = true, anchorKind = "patrol", ms = 70000, words = "patrolling the area", line = { "Checking the perimeter.", "All clear this side." } },
    carry = { preset = "search_low", window = true, anchorKind = "carry", ms = 120000, words = "hauling supplies around", line = { "Where do you want this?", "Heavy. Real heavy." } },
    repair = { preset = "build_crate", ms = 240000, words = "repairing things around here", line = { "This needs fixing. Again.", "Hold that for me?" } },
    workbench = { preset = "saw_planks", alt = "build_crate", ms = 240000, words = "working at the bench", line = { "Measure twice, cut once.", "Almost there." } },
    fish = { preset = "fish_wait", where = "outdoors", window = true, anchorKind = "water", ms = 420000, words = "fishing", line = { "Come on, bite.", "Patience. That's the whole trick." } },
    tend = { preset = "heal_bandage", alt = "sit_ground", ms = 90000, words = "tending their wounds", line = { "Hold still, you idiot. Me, I mean.", "That's gonna scar." } },
    guitar = { preset = "play_guitar", alt = "sit_ground", ms = 300000, words = "playing guitar", line = { "Requests? No? Good.", "This one's old." } },
    wash = { preset = "wash_face", alt = "wash_hands", ms = 80000, words = "washing up", line = { "Feel human again.", "Cold. So cold." } },
}
M.habitSitKinds = { sit = true, rest = true }
M.habitOutdoor = { chop = true, garden = true, fish = true, patrol = true, campfire = true }
M.habitChores = { patrol = true, carry = true, repair = true, workbench = true, tinker = true, scavenge = true, chop = true, garden = true, barricade = true, cook = true, clean = true }
M.habitRecent = {}

M.habitMem = M.habitMem or {}
local function hb(uid)
    uid = tostring(uid)
    local e = M.pb(uid, false)
    if type(e) == "table" then
        local h = M.habitOf and M.habitOf(uid) or { v = 1 }
        local mem = M.habitMem[uid]
        if mem and mem ~= h then for k, v in pairs(mem) do if h[k] == nil then h[k] = v end end; M.habitMem[uid] = nil end
        e.habit = h
        return h
    end
    local h = M.habitMem[uid]
    if h == nil then h = M.habitOf and M.habitOf(uid) or { v = 1 }; M.habitMem[uid] = h end
    return h
end
function M.habitInstall()
    for k, def in pairs(M.habitNew) do if M.actCatalog[k] == nil then M.actCatalog[k] = def end end
    local pa = PA()
    if pa and fn(pa.Animations, "registerPreset") and fn(pa.Animations, "presetOf") and not M.habitPresets then
        M.habitPresets = true
        pcall(function()
            if pa.Animations.presetOf("talk_water") == nil then
                pa.Animations.registerPreset({ id = "talk_water", bumpType = "ALifeBottleSip", hidden = true, looped = true, timeoutMs = 9000, idle = true, handsFree = true,
                    variants = { { bumpType = "ALifeBottleSip", prop = "Base.WaterBottle", hand = "primary" } } })
            end
            if pa.Animations.presetOf("talk_booze") == nil then
                pa.Animations.registerPreset({ id = "talk_booze", bumpType = "ALifeBottleSip", hidden = true, looped = true, timeoutMs = 9000, idle = true, handsFree = true,
                    variants = { { bumpType = "ALifeBottleSip", prop = "Base.BeerCan" }, { bumpType = "ALifeBottleSip", prop = "Base.BeerBottle" },
                        { bumpType = "ALifeBottleSip", prop = "Base.Whiskey" } } })
            end
        end)
    end
    if M._w517 == nil then M._w517 = {} end
    local W = M._w517
    if not W.actWeights and type(M.actWeights) == "function" then
        W.actWeights = true
        local orig = M.actWeights
        M.actWeights = function(uid, l, c, ctx)
            local w = orig(uid, l, c, ctx)
            if M.settings.habits == false or type(w) ~= "table" then return w end
            local ok, out = pcall(M.habitWeights, uid, l, c, ctx or {}, w)
            return ok and out or w
        end
    end
    if not W.pickActivity and type(M.pickActivity) == "function" then
        W.pickActivity = true
        local orig = M.pickActivity
        M.pickActivity = function(uid, l, c, ctx, now)
            local k = orig(uid, l, c, ctx, now)
            if k and M.settings.habits ~= false then
                local r = M.habitRecent[tostring(uid)] or {}
                M.habitRecent[tostring(uid)] = r
                r[#r + 1] = k
                while #r > M.habitCfg.recentN do table.remove(r, 1) end
            end
            return k
        end
    end
    if not W.findWindowNear and type(M.findWindowNear) == "function" then
        W.findWindowNear = true
        local orig = M.findWindowNear
        M.findWindowNear = function(l)
            local a = l and l.record and M.habitAnchor and M.habitAnchor[tostring(l.record.uid)] or nil
            if a then return a end
            return orig(l)
        end
    end
    if not W.startActivity and type(M.startActivity) == "function" then
        W.startActivity = true
        local orig = M.startActivity
        M.startActivity = function(l, kind, now, opts)
            local def = M.actCatalog[kind]
            local uid = l and l.record and tostring(l.record.uid) or nil
            if uid and def and def.anchorKind then
                M.habitAnchor = M.habitAnchor or {}
                M.habitAnchor[uid] = M.habitAnchorFor(l, def.anchorKind, now)
                if M.habitAnchor[uid] == nil and def.anchorKind == "water" then return false, "no water near" end
            end
            local ok, why = orig(l, kind, now, opts)
            if uid and M.habitAnchor then M.habitAnchor[uid] = nil end
            if ok and uid and M.settings.habits ~= false then pcall(M.habitStarted, l, kind, now) end
            return ok, why
        end
    end
end

-- spots to walk to: a patrol point (6-12 tiles from home / here), a carry spot, the nearest water
local function squareOk(x, y, z)
    local ok = false
    pcall(function()
        local sq = getCell():getGridSquare(x, y, z)
        ok = sq ~= nil and sq:isFree(false) and not sq:isSolidTrans()
    end)
    return ok
end
M.waterNear = {}
-- 0.5.1: "is this tile water?" without ever calling a method that isn't there. 42.21's PropertyContainer has no
-- Is() any more (calling it threw "Object tried to call nil in pcall" from this file's water search). Look the
-- method up first (indexing a missing Java method gives nil, it doesn't throw), test it once, and if nothing
-- works, the water habits are simply off for the session (one log line).
local waterTest = nil -- nil = not resolved yet, false = unavailable, function(sq) -> bool
local function resolveWaterTest(sq)
    local pc = nil
    pcall(function() pc = sq:getProperties() end)
    if pc == nil then return nil end -- try again on another tile
    local flag = type(IsoFlagType) ~= "nil" and IsoFlagType.water or nil
    local tries = {}
    if flag ~= nil and pc.has ~= nil then tries[#tries + 1] = { "has(IsoFlagType.water)", function(p) return p:has(flag) end } end
    if flag ~= nil and pc.Is ~= nil then tries[#tries + 1] = { "Is(IsoFlagType.water)", function(p) return p:Is(flag) end } end
    if pc.has ~= nil then tries[#tries + 1] = { "has(\"water\")", function(p) return p:has("water") end } end
    for _, t in ipairs(tries) do
        local ok, v = pcall(t[2], pc)
        if ok and (v == true or v == false) then
            local f = t[2]
            print("[ALifeLLMTalk] habits: water check uses PropertyContainer." .. t[1])
            return function(s)
                local p = nil
                pcall(function() p = s:getProperties() end)
                if p == nil then return false end
                local ok2, v2 = pcall(f, p)
                return ok2 and v2 == true
            end
        end
    end
    print("[ALifeLLMTalk] habits: no working water check in this game version - water habits off this session")
    return false
end
function M.habitAnchorFor(l, kind, now)
    local x, y, z = pos(l.shell)
    if x == nil then return nil end
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    local uid = tostring(l.record.uid)
    if kind == "water" then
        if waterTest == false then return nil end
        local key = uid .. "@" .. math.floor(x / 10) .. "," .. math.floor(y / 10)
        local c = M.waterNear[key]
        if c and now - c.at < M.habitCfg.waterCacheMs then return c.spot end
        local spot = nil
        local r = M.habitCfg.waterTiles
        pcall(function()
            local cell = getCell()
            for dx = -r, r, 2 do
                for dy = -r, r, 2 do
                    local sq = cell:getGridSquare(x + dx, y + dy, 0)
                    if sq ~= nil and waterTest == nil then waterTest = resolveWaterTest(sq) end
                    if waterTest == false then return end
                    if sq ~= nil and waterTest and waterTest(sq) then
                        spot = { x = x + dx - (dx > 0 and 1 or -1), y = y + dy, z = 0 }
                        return
                    end
                end
            end
        end)
        M.waterNear[key] = { at = now, spot = spot }
        return spot
    end
    local m = type(l.record.memory) == "table" and l.record.memory or {}
    local hx, hy = tonumber(m.homeX) or x, tonumber(m.homeY) or y
    local dmin, dmax = 6, 12
    if kind == "carry" then dmin, dmax = 3, 6 end
    for i = 0, 5 do
        local ang = ((hash(uid .. "#pt" .. math.floor(now / 60000) .. i) % 360) / 180) * math.pi
        local dist = dmin + hash(uid .. "#pd" .. i) % (dmax - dmin + 1)
        local tx, ty = math.floor(hx + math.cos(ang) * dist), math.floor(hy + math.sin(ang) * dist)
        if squareOk(tx, ty, z) then return { x = tx, y = ty, z = z } end
    end
    return nil
end

-- the routine (called through M.actWeights; orig weights in w)
function M.habitWeights(uid, l, c, ctx, w)
    uid = tostring(uid)
    local lens = lensOf(uid)
    local h = hours()
    local habit = hb(uid)
    local function add(k, v) if v > 0 and M.actCatalog[k] then w[k] = (w[k] or 0) + v end end
    local function mul(k, f) if w[k] then w[k] = w[k] * f; if w[k] <= 0.01 then w[k] = nil end end end
    local outdoorsOk = not ctx.indoors and (c.rain or 0) < 0.3 and (c.snow or 0) < 0.3 and not c.storm
    local hour = c.hour or 12
    local since = function(key) return h - (tonumber(habit[key]) or (h - 3)) end
    -- old generic kinds: "drink" is now water / booze
    w.drink = nil
    -- sitting: less of it, and never more than a quarter of the recent picks in daytime
    mul("sit", 0.35)
    if not c.night and not ctx.tired and not ctx.hurt then mul("rest", 0.5) end
    local recent = M.habitRecent[uid] or {}
    if #recent >= 4 and not c.night then
        local n = 0
        for _, k in ipairs(recent) do if M.habitSitKinds[k] then n = n + 1 end end
        if n / #recent >= M.habitCfg.sitCap then w.sit = nil; if not ctx.tired and not ctx.hurt then w.rest = nil end end
    end
    -- meals and water on a schedule
    local mealDue = since("lastMealH") >= M.habitCfg.mealGapH
    local mealTime = (hour >= 7 and hour <= 9) or (hour >= 12 and hour <= 13) or (hour >= 18 and hour <= 20)
    if since("lastMealH") < 3 then w.eat, w.cook = nil, nil
    else
        if mealDue and mealTime then add("eat", 30) elseif since("lastMealH") >= 8 then add("eat", 25) end
        if mealTime and hour >= 17 then add("cook", 18 + (ctx.camp and 8 or 0)) end
    end
    add("water", math.min(35, 2 + math.max(0, since("lastWaterH") - 1) * 8))
    if since("lastWaterH") < 1 then w.water = nil end
    if not c.night then
        -- morning
        if hour >= 6 and hour < 9 then add("wash", 12); add("exercise", 4 + (lens.disciplined or 0) * 12) end
        -- work blocks
        if (hour >= 9 and hour < 12) or (hour >= 13 and hour < 17) then
            local work = 1 + (lens.disciplined or 0) * 1.5 + (lens.brave or 0) * 0.5
            add("patrol", (4 + (lens.paranoid or 0) * 12 + (lens.brave or 0) * 6) * work)
            add("carry", 5 * work); add("repair", 4 * work); add("workbench", 3 * work)
            add("scavenge", 3 * work)
            mul("chat", 0.5); mul("cards", 0.4) -- work first, talk later
            if outdoorsOk then add("fish", 3 + (lens.calm or 0) * 10) end
        end
        -- evening: social
        if hour >= 18 and hour < 22 then
            add("guitar", 2 + (lens.cheerful or 0) * 10 + (lens.romantic or 0) * 4)
            if ctx.partner then add("chat", 10); add("cards", 6) end
            add("read", 3)
        end
    else
        add("patrol", (lens.paranoid or 0) * 6 + (lens.brave or 0) * 3)
    end
    if ctx.hurt then add("tend", 20 + (ctx.hurt or 0) * 40) end
    -- weather: indoors
    if not outdoorsOk then
        for k in pairs(M.habitOutdoor) do if k ~= "campfire" or (c.rain or 0) > 0.3 then w[k] = nil end end
        mul("read", 1.3); mul("repair", 1.3); mul("cards", 1.3); mul("clean", 1.3); mul("workbench", 1.2)
    end
    -- habits
    if habit.smoker then
        w.smoke = 3 + math.min(40, math.max(0, since("lastSmokeH") - 1) * 8)
        if since("lastSmokeH") < 1 then w.smoke = 1 end
    else w.smoke = nil end
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    local stress = math.min(1, (tonumber(b.fear) or 0) + (tonumber(b.low) or 0))
    if habit.drinker then
        w.booze = 2 + stress * 20 + (ctx.grief or 0) * 30 + ((hour >= 18 or c.night) and 6 or 0)
        if since("lastDrinkH") < 1.5 then w.booze = w.booze * 0.2 end
        if ctx.drunk then w.booze = w.booze * 0.3 end
    elseif habit.teetotal then w.booze = nil
    else w.booze = (hour >= 19 and hour < 23) and 0.6 or nil end
    -- the chores a personality likes
    if (lens.disciplined or 0) > 0.15 then for k in pairs(M.habitChores) do mul(k, 1.3) end end
    if (lens.gloomy or 0) > 0.15 then mul("rest", 1.3); for k in pairs(M.habitChores) do mul(k, 0.75) end end
    return w
end

-- after a start: timers, drunkenness, what you notice, "got a smoke?"
M.smokeAsked = M.smokeAsked or {}
function M.habitStarted(l, kind, now)
    local uid = tostring(l.record.uid)
    local habit = hb(uid)
    local h = hours()
    if kind == "eat" or kind == "cook" then habit.lastMealH = h
    elseif kind == "water" then habit.lastWaterH = h
    elseif kind == "smoke" then habit.lastSmokeH = h
    elseif kind == "booze" then
        habit.lastDrinkH = h
        local b = M.emoBehavior and M.emoBehavior(uid) or {}
        if M.addDrunk then M.addDrunk(uid, 12 + math.floor(math.min(1, (tonumber(b.fear) or 0) + (tonumber(b.low) or 0)) * 10)) end
    end
    local player = ALifeSide.you()
    if player == nil or bucket("book")[uid] == nil then return end
    local d = distTo(l, player)
    if d > 12 then return end
    -- seen with their brand / drink: learned
    if M.settings.bondLikes ~= false and (kind == "smoke" or kind == "booze") and M.likesOf then
        local lk = M.likesOf(uid, true)
        for _, it in ipairs(lk and lk.list or {}) do
            if it.like and ((kind == "smoke" and it.c == "smoke") or (kind == "booze" and it.c == "drink")) then M.likeLearn(uid, it, "you saw them") end
        end
    end
    if kind == "smoke" and d <= M.habitCfg.askTiles and h >= (tonumber(habit.askH) or -1e9) and (hash(uid .. math.floor(h)) % 3) == 0 and idleOk(l, now) then
        habit.askH = h + M.habitCfg.askCdH
        M.smokeAsked[uid] = h
        local brand = "a cigarette"
        local lk = M.likesOf and M.likesOf(uid, false) or nil
        for _, it in ipairs(lk and lk.list or {}) do if it.c == "smoke" and it.like then brand = it.label end end
        speak(l, player, "habit", "You're dying for a smoke and you're out. Ask the newcomer if they've got one (you smoke " .. brand .. ", but anything will do).",
            "Hey... got a smoke?", { keyMs = 0 })
    end
end

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.habits == false then return end
    local uid = tostring(listener.record.uid)
    local habit = hb(uid)
    local hx = {}
    if habit.smoker then hx.smoker = true; hx.craving = (hours() - (tonumber(habit.lastSmokeH) or hours() - 3)) >= 4 end
    if habit.drinker then hx.drinker = true end
    if habit.teetotal then hx.teetotal = true end
    if M.smokeAsked[uid] and hours() - M.smokeAsked[uid] < 1 then hx.askedSmoke = true end
    if hx.smoker or hx.drinker or hx.teetotal then req.habit = hx end
end)
regMode("habit")
