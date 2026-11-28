-- A-Life Talk 0.5.0: NPCs react to the world, and take orders.
--   World reactions (verbal: one short AI line, "world" react mode; physical: an A-Life gesture through the patch;
--   emotional: M.feel) to gunfire, explosions, alarms, bodies, fire and smoke, hordes, vehicles, gyrocopters,
--   helicopters, weather and cold, darkness, blood and gore, dogs and animals, mutants / monsters / occult zombies,
--   sewers and the underground - each filtered by personality (a brave one doesn't flinch, a greedy one eyes the
--   body's pockets, a zealot preaches at the storm).
--   Orders: the player's orders to recruits / companions ("hold here", "fall back", "cover me", "move up",
--   "regroup", "take cover", "follow me", "guard this place") and NPC leaders' commands in danger, both obeyed or
--   refused by loyalty, personality and feelings, with spoken lines. Movement is A-Life's own (patch: setOrder).
--   Shelter hooks: the patch asks us how eager each NPC is to get inside (personality + fear).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_World") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCellCars"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "World"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("World") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return type(ALifeTalkPatch) == "table" and ALifeTalkPatch.loaded and ALifeTalkPatch or nil end
local function pos(o)
    if o == nil then return nil end
    local ok, x, y, z = pcall(function() return o:getX(), o:getY(), o:getZ() end)
    if ok then return x, y, z end
    return nil
end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return math.random(0, n - 1) end
local function hourOfDay() local ok, h = pcall(function() return getGameTime():getHour() end); return ok and tonumber(h) or 12 end

M.world = { everyMs = 4000, gapMs = 45000, perKindMs = 240000, perNpcMs = 90000, scanTiles = 6, nearTiles = 18, maxScan = 3,
    bodyTiles = 6, specialTiles = 14, gestureTiles = 20 }
M.worldAt = { kinds = {}, npc = {}, any = -1e12 }

-- personality lens: trait-chart weights (0..1) for one NPC
function M.lens(uid)
    local out = {}
    pcall(function()
        for _, c in ipairs(M.traitChart(uid, 6)) do out[c.key] = c.pct / 100 end
    end)
    local style, m = nil, nil
    if M.personaKind then
        local okK, _k, st, mm = pcall(M.personaKind, uid)
        if okK then style, m = st, mm end
    end
    out.style, out.mods = style, m or {}
    return out
end

-- one reaction: emotions, a gesture through the patch, and maybe one short AI line
-- spec = { kind, what, style, feel = { {emo, amt}, ... }, gesture = id | { fearful = id, brave = id, ... }, line = true }
function M.worldReact(l, player, spec)
    if M.settings.worldReactions == false or l == nil or l.record == nil then return false end
    local uid = tostring(l.record.uid)
    local lens = M.lens(uid)
    for _, f in ipairs(spec.feel or {}) do if M.feel then M.feel(uid, f[1], f[2], spec.what) end end
    local P = patch()
    local g = spec.gesture
    if type(g) == "table" then
        local best, bw = g.default, 0.12
        for k, id in pairs(g) do if k ~= "default" and (lens[k] or 0) > bw then best, bw = id, lens[k] end end
        g = best
    end
    if g and P and fn(P, "gesture") then pcall(P.gesture, uid, g) end
    if spec.line == false then return true end
    local now = nowMs()
    if now - M.worldAt.any < M.world.gapMs or now - (M.worldAt.kinds[spec.kind] or -1e12) < (spec.kindMs or M.world.perKindMs)
            or now - (M.worldAt.npc[uid] or -1e12) < M.world.perNpcMs then return true end
    local style = spec.style or "react"
    if lens.style and M.styleRules and M.styleRules[lens.style] then style = style .. "; " .. M.styleRules[lens.style] end
    local ok = M.react("world", l, player, { what = spec.what, style = style, maxWords = spec.maxWords or 14 },
        { key = "world:" .. spec.kind .. ":" .. uid, keyCooldownMs = spec.kindMs or M.world.perKindMs, modeCooldownMs = 15000 })
    if ok then M.worldAt.any, M.worldAt.kinds[spec.kind], M.worldAt.npc[uid] = now, now, now end
    return ok
end

-- the NPCs the player can see / hear react; nearest first
local function nearList(player, tiles)
    local pa = PA()
    if not fn(pa and pa.Talk, "listeners") then return {} end
    local ok, list = pcall(pa.Talk.listeners, player, tiles or M.world.nearTiles)
    if not ok or type(list) ~= "table" then return {} end
    local out = {}
    for _, l in ipairs(list) do
        if l.record and l.shell and not (fn(pa.Talk, "busy") and pa.Talk.busy(l.record, nowMs())) then out[#out + 1] = l end
    end
    return out
end
M.worldListeners = nearList

----------------------------------------------------------------------------------------------------------------
-- stimuli
----------------------------------------------------------------------------------------------------------------
M.specialWords = { mutant = "mutant", occult = "occult", cultist = "occult", demon = "monster", monster = "monster",
    cryoffear = "monster", fear = nil, pyramid = "monster", nurse = "monster", silenthill = "monster", backroom = "monster",
    entity = "monster", hound = "monster", crawler = "mutant", brute = "mutant", screamer = "mutant", spitter = "mutant" }
function M.specialZombie(z)
    local hit = nil
    pcall(function()
        local outfit = z.getOutfitName and string.lower(tostring(z:getOutfitName() or "")) or ""
        for w, k in pairs(M.specialWords) do if k and string.find(outfit, w, 1, true) then hit = k end end
        if hit == nil then
            local md = z:getModData()
            if type(md) == "table" then
                for key, _ in pairs(md) do
                    local lk = string.lower(tostring(key))
                    for w, k in pairs(M.specialWords) do if k and string.find(lk, w, 1, true) then hit = k end end
                end
            end
        end
    end)
    return hit
end

-- squares around a point (cheap ring scan); visit(sq, dx, dy) returns true to stop
local function scanSquares(x, y, z, r, visit)
    local cell = type(getCell) == "function" and getCell() or nil
    if cell == nil then return end
    for dx = -r, r do
        for dy = -r, r do
            local sq = nil
            pcall(function() sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, math.floor(z or 0)) end)
            if sq ~= nil and visit(sq, dx, dy) then return end
        end
    end
end

local function bodyOnSquare(sq)
    local b = nil
    if sq.getDeadBody ~= nil then pcall(function() b = sq:getDeadBody() end) end
    return b
end
local function fireOnSquare(sq)
    local f = false
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do if instanceof(objs:get(i), "IsoFire") then f = true end end
    end)
    return f
end
local function animalOnSquare(sq)
    local a = nil
    pcall(function()
        local list = sq.getMovingObjects ~= nil and sq:getMovingObjects() or nil
        if list == nil or list.size == nil then return end
        for i = 0, list:size() - 1 do
            local o = list:get(i)
            if instanceof(o, "IsoAnimal") then a = o end
        end
    end)
    return a
end
local function animalName(a)
    local n = "an animal"
    pcall(function()
        local t = string.lower(tostring(a.getAnimalType and a:getAnimalType() or a:getType() or ""))
        if string.find(t, "dog", 1, true) or string.find(t, "rott", 1, true) or string.find(t, "dober", 1, true) then n = "a dog"
        elseif t ~= "" then n = "a " .. t end
    end)
    return n
end

-- known dead: A-Life corpses carry the uid of who they were (WarDead / ResidentCorpses write it into modData)
local function bodyWho(b)
    local who = nil
    pcall(function()
        local md = b:getModData()
        local uid = type(md) == "table" and (md.ProjectALifeUID or md.ALifeUID or md.alifeUid) or nil
        if uid then who = tostring(uid) end
    end)
    return who
end

M.seenThing = {}
-- pre-1.0 MP (P2b): "seen lately" is per player on a server (two players in two towns each get their storm, their
-- body); single player: no prefix, exactly as before
local scanKey = ""
local function fresh(key, ms)
    key = scanKey .. tostring(key)
    local now = nowMs()
    if now - (M.seenThing[key] or -1e12) < (ms or 600000) then return false end
    M.seenThing[key] = now
    return true
end

function M.worldScan(player)
    scanKey = (type(ALifeSide) == "table" and ALifeSide.mpServer()) and (tostring(ALifeSide.keyOf(player)) .. "|") or ""
    local px, py, pz = pos(player)
    if px == nil then return end
    local list = nearList(player)
    if #list == 0 then return end
    local P = patch()
    local hod = hourOfDay()
    local w = P and fn(P, "weatherNow") and P.weatherNow() or { rain = 0, snow = 0, wind = 0, storm = false, temp = 15, dark = false }
    local l1 = list[1]
    local uid1 = tostring(l1.record.uid)
    local lens1 = M.lens(uid1)
    -- weather / cold / darkness / underground (one speaker, rare)
    if w.storm and fresh("storm", 1800000) then
        M.worldReact(l1, player, { kind = "storm", what = "A thunderstorm is breaking over you", style = "thunder, lightning and rain; react to the weather and whether to get inside",
            feel = { { "anxiety", 0.2 } }, gesture = { fearful = "spooked", default = nil } })
    elseif (tonumber(w.snow) or 0) > 0.6 and (tonumber(w.wind) or 0) > 0.5 and fresh("blizzard", 1800000) then
        M.worldReact(l1, player, { kind = "blizzard", what = "A blizzard is blowing - you can barely see and it's bitterly cold" ..
            (M.modOn and M.modOn("eternalWinter") and " (the winter that never ends)" or ""), style = "freezing; react to the cold and the need for shelter",
            feel = { { "dread", 0.2 }, { "anxiety", 0.2 } }, gesture = "shiver" })
    elseif (tonumber(w.temp) or 15) <= -5 and fresh("cold", 2400000) then
        M.worldReact(l1, player, { kind = "cold", what = "It's freezing out - about " .. math.floor(w.temp) .. " C", style = "the cold; complain, worry or tough it out, as you would",
            feel = { { "irritation", 0.1 } }, gesture = "warm_hands" })
    elseif (tonumber(w.rain) or 0) > 0.5 and fresh("rain", 2400000) then
        M.worldReact(l1, player, { kind = "rain", what = "It's pouring rain", style = "the rain; a gripe, or a remark on the noise covering footsteps",
            feel = { { "boredom", 0.1 } } })
    elseif (hod >= 21 or hod < 5) and w.dark and fresh("dark", 3600000) then
        M.worldReact(l1, player, { kind = "dark", what = "It's dark now, the dead are hard to see", style = (lens1.fearful or 0) > 0.15 and "you're scared of the dark; nervous" or "night; caution",
            feel = { { "anxiety", 0.15 } } })
    end
    if (pz or 0) < 0 and fresh("underground", 1800000) then
        local where = (M.modOn and M.modOn("sewers")) and "down in the sewers" or "underground"
        M.worldReact(l1, player, { kind = "underground", what = "You're " .. where .. " - dark, tight, echoing, it stinks", style = "claustrophobic, the stink, the dark; react",
            feel = { { "anxiety", 0.25 }, { "disgust", 0.2 } } })
    end
    -- the player covered in blood
    local bloody = 0
    pcall(function()
        local hv = player.getHumanVisual ~= nil and player:getHumanVisual() or nil
        if hv and hv.getTotalBlood then bloody = tonumber((hv:getTotalBlood())) or 0 end
    end)
    if bloody > 0.5 and fresh("blood:" .. uid1, 1800000) then
        M.worldReact(l1, player, { kind = "blood", what = "The newcomer is soaked in blood" .. (M.modOn and M.modOn("gore") and ", bits of gore stuck to them" or ""),
            style = "react to how they look (ask if it's theirs, if they're bit; or grim humour)",
            feel = { { "disgust", 0.25 }, { "anxiety", 0.15 } }, gesture = { fearful = "spooked", default = nil } })
    end
    -- vehicles near (gyrocopters / cars)
    pcall(function()
        local vs = ALifeCellCars.list() -- 0.9.5: 42.21 cell vehicles = HashSet (no size()/get(i))
        for i = 1, math.min(#vs, 40) do
            local v = vs[i]
            if v == nil or v.getX == nil then break end
            local vx, vy = v:getX(), v:getY()
            if (vx - px) ^ 2 + (vy - py) ^ 2 < 400 then
                local sname = string.lower(tostring(v:getScriptName() or ""))
                local gyro = string.find(sname, "gyro", 1, true) ~= nil
                local running = v.isEngineRunning and v:isEngineRunning()
                if gyro and fresh("gyro:" .. tostring(v:getId()), 1800000) then
                    M.worldReact(l1, player, { kind = "gyro", what = "There's a gyrocopter right here - a little flying machine", style = "amazed, suspicious or eager to fly out; react",
                        feel = { { "awe", 0.3 }, { "hope", 0.2 } } })
                elseif running and fresh("car", 900000) then
                    M.worldReact(l1, player, { kind = "vehicle", what = "A car engine is running right next to you", style = "engines draw the dead; react (or ask for a ride)",
                        feel = { { "anxiety", 0.1 } } })
                end
            end
        end
    end)
    -- special dead: mutants / monsters / occult zombies, and a horde count
    pcall(function()
        local c2 = getCell()
        local zs = c2 ~= nil and c2.getZombieList ~= nil and c2:getZombieList() or nil
        if zs == nil or zs.size == nil then return end
        local n, special = 0, nil
        for i = 0, math.min(zs:size(), 500) - 1 do
            local z = zs:get(i)
            if z and not z:isDead() then
                local zx, zy = z:getX(), z:getY()
                if (zx - px) ^ 2 + (zy - py) ^ 2 <= M.world.specialTiles ^ 2 then
                    n = n + 1
                    if special == nil then
                        local okA = M.uidOf == nil or M.uidOf(z) == nil
                        if okA then special = M.specialZombie(z) end
                    end
                end
            end
        end
        if n >= ((M.bondCfg and M.bondCfg.dangerMinZ) or 6) and M.bondDanger then -- 0.5.1: survived together -> bonds
            local ids = {}
            for _, l in ipairs(M.nearbyNpcs(px, py, pz, M.world.specialTiles)) do ids[#ids + 1] = l.record.uid end
            M.bondDanger("horde", ids)
        end
        if special and fresh("special:" .. special, 900000) then
            local what = ({ mutant = "a mutated thing - not a normal zombie, bigger, wrong", occult = "zombies in robes and strange markings, like a cult",
                monster = "a monster - something out of a nightmare, not a zombie at all" })[special]
            M.worldReact(l1, player, { kind = "special", what = "You see " .. what, style = "pure horror; react (pray, curse, freeze, rant, giggle - as you would)",
                feel = { { "fear", 0.6 }, { "dread", 0.4 }, { "awe", 0.1 } }, gesture = { fearful = "spooked", devout = "bow_head", default = "spooked" }, kindMs = 600000 })
        end
    end)
    -- bodies, fire and smoke, animals around the nearest few NPCs (every third scan: square probes cost the most)
    M.worldScanN = (M.worldScanN or 0) + 1
    if M.worldScanN % 3 ~= 0 then return end
    for i = 1, math.min(#list, M.world.maxScan) do
        local l = list[i]
        local uid = tostring(l.record.uid)
        local sx, sy, sz = pos(l.shell)
        if sx then
            local found = {}
            scanSquares(sx, sy, sz, M.world.scanTiles, function(sq, dx, dy)
                if found.body == nil and dx * dx + dy * dy <= M.world.bodyTiles ^ 2 then
                    local b = bodyOnSquare(sq)
                    if b then found.body = b end
                end
                if found.fire == nil and fireOnSquare(sq) then found.fire = true end
                if found.animal == nil then local a = animalOnSquare(sq); if a then found.animal = a end end
                return found.body and found.fire and found.animal
            end)
            if found.body then
                local who = bodyWho(found.body)
                local key = "body:" .. tostring(who or (math.floor(sx / 10) .. "," .. math.floor(sy / 10)))
                if fresh(key .. ":" .. uid, 1200000) then
                    local lens = M.lens(uid)
                    local close = 0
                    if who and M.closeness then close = select(1, M.closeness(uid, who)) or 0 end
                    local dead = who and rec(who) or nil
                    if close >= 0.3 then
                        M.worldReact(l, player, { kind = "mourn", what = "You found the body of " .. nameOf(dead) .. ", someone close to you",
                            style = "grief, raw and short", feel = { { "grief", 0.6 }, { "sadness", 0.3 } }, gesture = "bow_head", kindMs = 60000 })
                    elseif (lens.greedy or 0) > 0.15 or (lens.mean or 0) > 0.2 then
                        M.worldReact(l, player, { kind = "loot", what = "There's a dead body here" .. (dead and (" - " .. nameOf(dead)) or ""),
                            style = "you eye its pockets (or mock it); say it", feel = { { "excitement", 0.1 } }, gesture = "search_low" })
                    else
                        M.worldReact(l, player, { kind = "body", what = "There's a dead body here" .. (dead and (" - " .. nameOf(dead)) or ""),
                            style = "check it (bitten? who was it?) or look away", feel = { { "disgust", 0.2 }, { "sadness", 0.1 } },
                            gesture = { devout = "bow_head", kind = "bow_head", default = "search_low" } })
                    end
                end
            end
            if found.fire and fresh("fire:" .. math.floor(sx / 15) .. "," .. math.floor(sy / 15), 600000) then
                M.worldReact(l, player, { kind = "fire", what = "Fire and smoke right nearby", style = "fire spreads and draws the dead; react, urgent",
                    feel = { { "fear", 0.35 } }, gesture = "cough", kindMs = 120000 })
            end
            if found.animal and fresh("animal:" .. uid, 1200000) then
                local an = animalName(found.animal)
                local dog = an == "a dog"
                M.worldReact(l, player, { kind = "animal", what = "There's " .. an .. " here" .. (dog and (M.modOn and M.modOn("dogs") and " (somebody's dog)" or "") or ""),
                    style = dog and "a dog - warm, wary or practical (dogs bark and draw the dead)" or "an animal - food, danger or just strange to see",
                    feel = { { dog and "joy" or "excitement", 0.2 } } })
            end
        end
    end
end

-- physical flinch / duck at gunfire and explosions (A-Life gestures via the patch), and fear
if type(M.addSound) == "function" and not M._worldSoundWrapped then
    local orig = M.addSound
    M.addSound = function(kind, what, x, y, z, r, src)
        local s = orig(kind, what, x, y, z, r, src)
        pcall(function()
            if (kind ~= "gunshot" and kind ~= "explosion" and kind ~= "alarm" and kind ~= "horde") or x == nil then return end
            local P = patch()
            if P == nil or not fn(P, "gesture") then return end
            for _, l in ipairs(M.nearbyNpcs(x, y, z or 0, kind == "gunshot" and M.world.gestureTiles or 30) or {}) do
                local lens = M.lens(l.record.uid)
                if (lens.brave or 0) < 0.2 or kind == "explosion" then
                    P.gesture(tostring(l.record.uid), ((lens.fearful or 0) + (lens.unhinged or 0) > 0.15 or kind == "explosion") and "spooked" or "hit_react")
                end
            end
        end)
        return s
    end
    M._worldSoundWrapped = true
end

----------------------------------------------------------------------------------------------------------------
-- orders: the player's to recruits / companions, leaders' to their group
----------------------------------------------------------------------------------------------------------------
M.orderWords = {
    { "fall_back", { "fall back", "pull back", "retreat", "get back", "back off", "everyone back" } },
    { "cover_me", { "cover me", "covering fire", "watch my back", "got my back", "cover my" } },
    { "move_up", { "move up", "push up", "push forward", "advance", "go go go", "move in", "push in" } },
    { "regroup", { "regroup", "on me", "form up", "group up", "rally on me", "to me" } },
    { "shelter", { "take cover", "get inside", "find shelter", "get indoors", "inside now", "get in the house" } },
    { "guard", { "guard this", "watch this place", "keep watch here", "stand guard" } },
    { "hold", { "hold here", "hold position", "stay here", "wait here", "stay put", "hold up", "hold the line", "stay back", "hold it here" } },
    { "follow", { "follow me", "come with me", "let's go", "lets go", "with me", "keep up" } },
}
function M.parseOrder(text)
    -- 0.8.11.2: whole words ("hold upstairs" is not "hold up")
    local low = " " .. string.gsub(string.lower(tostring(text or "")), "[^%w']+", " ") .. " "
    for _, row in ipairs(M.orderWords) do
        for _, w in ipairs(row[2]) do
            local a = string.find(low, " " .. w .. " ", 1, true)
            if a then a = a + 1 end
            if a then
                local before = string.sub(low, math.max(1, a - 6), a - 1)
                if not string.find(before, "n't", 1, true) and not string.find(before, "not ", 1, true) and not string.find(before, "never", 1, true) then
                    return row[1]
                end
            end
        end
    end
    return nil
end

M.orderLabel = { fall_back = "fall back", cover_me = "cover me", move_up = "move up", regroup = "regroup", shelter = "take cover inside",
    guard = "guard this place", hold = "hold here", follow = "follow" }

function M.obeyChance(uid, leaderUid, kind)
    uid = tostring(uid)
    local lens = M.lens(uid)
    local c = 60
    if leaderUid == "player" then
        local op = 0
        pcall(function() op = PA().NpcOpinion.valueOf(rec(uid), M.you()) or 0 end) -- pre-1.0 MP: the player giving the order
        c = 30 + op * 0.6
        local P = patch()
        if P and fn(P, "companionOf") and P.companionOf(uid) then c = c + 20 end
    elseif M.closeness then
        local w = select(1, M.closeness(uid, leaderUid)) or 0.3
        c = 50 + w * 35
    end
    c = c + ((lens.disciplined or 0) + (lens.loyal or 0)) * 60 - ((lens.volatile or 0) + (lens.proud or 0)) * 50 - (lens.unhinged or 0) * 40
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    if kind == "fall_back" or kind == "shelter" then c = c + (b.fear or 0) * 30 end
    if kind == "move_up" then c = c - (b.fear or 0) * 40 + (lens.brave or 0) * 40 end
    if kind == "hold" or kind == "guard" then c = c - (b.anger or 0) * 20 end
    if (M.stressOf and M.stressOf(uid) or 0) > 70 then c = c - 10 end
    local _, style = M.personaKind and M.personaKind(uid)
    if style == "refuse" then c = c - 15 end
    return math.max(5, math.min(98, math.floor(c + 0.5)))
end

M.ackLines = {
    yes = { "On it.", "Got it.", "Okay, okay.", "Right behind you.", "Copy.", "You got it." },
    no = { "Hell no.", "Not a chance.", "Do it yourself.", "I'm not doing that.", "Forget it.", "You're not my boss." },
    yes_mean = { "Fine. Whatever.", "Yeah, yeah.", "Don't get used to it." },
    no_mope = { "What's the point...", "I can't. I just can't." },
    yes_unhinged = { "They told me you'd say that.", "Heh. Okay. Okay okay." },
    no_unhinged = { "No - they're watching that way.", "The voices say stay." },
}
M.commandLines = {
    fall_back = { "Fall back! Fall back!", "Pull back, now!", "Back, everybody back!" },
    cover_me = { "Cover me!", "Keep 'em off me!", "Watch my back!" },
    hold = { "Hold here! Hold!", "Stay put, hold the line!", "Nobody move!" },
    regroup = { "Regroup on me!", "On me, everybody!", "Form up!" },
    move_up = { "Move up! Go!", "Push forward!", "Go, go, go!" },
}
local function pick(list) return list[roll(#list) + 1] end
function M.ackLine(uid, obeyed)
    local kind, style = nil, nil
    if M.personaKind then kind, style = M.personaKind(uid) end
    if obeyed then
        if kind == "unhinged" then return pick(M.ackLines.yes_unhinged) end
        if style == "insult" or style == "mock" or style == "refuse" then return pick(M.ackLines.yes_mean) end
        return pick(M.ackLines.yes)
    end
    if kind == "unhinged" then return pick(M.ackLines.no_unhinged) end
    if style == "mope" then return pick(M.ackLines.no_mope) end
    return pick(M.ackLines.no)
end

-- the player gave an order: companions / recruits near the player answer it
function M.playerOrder(player, text)
    if M.settings.playerOrders == false then return nil end
    local kind = M.parseOrder(text)
    if kind == nil then return nil end
    local P = patch()
    if P == nil or not fn(P, "playerOrder") then return nil end
    local px, py, pz = pos(player)
    local out = {}
    for _, l in ipairs(M.nearbyNpcs(px, py, pz or 0, 30) or {}) do
        local uid = tostring(l.record.uid)
        local mine = (fn(P, "companionOf") and P.companionOf(uid) ~= nil)
        if not mine then
            pcall(function() local m = l.record.memory; mine = type(m) == "table" and type(m.walkWith) == "table" end)
        end
        if mine then
            local chance = M.obeyChance(uid, "player", kind)
            local obeyed = roll(100) < chance
            local done = false
            if obeyed then local ok, r = pcall(P.playerOrder, uid, kind, player); done = ok and r == true end
            out[#out + 1] = { uid = uid, obeyed = done, chance = chance }
            if M.feel then M.feel(uid, done and "pride" or "irritation", 0.05) end
            if M.logInteraction then pcall(M.logInteraction, uid, (done and "Obeyed your order: " or "Refused your order: ") .. M.orderLabel[kind], nil, nil, "event") end
            M.lastOrder = M.lastOrder or {}
            M.lastOrder[uid] = { kind = kind, obeyed = done, at = nowMs() }
            -- the one you're talking to answers with the AI (req.order below); the rest with a quick line
            local talkingTo = M.pending and tostring(M.pending.uid) == uid
            if not talkingTo then M.say(l.shell, player, M.ackLine(uid, done), { record = l.record }) end
        end
    end
    if #out > 0 then log("order '" .. kind .. "': " .. #out .. " recruits") end
    return kind, out
end
if type(M.notePlayerLine) == "function" and not M._orderWrapped then
    local orig = M.notePlayerLine
    M.notePlayerLine = function(player, text, ...)
        local a, b = orig(player, text, ...)
        -- already checked when the line came in (respondNow, ordersFirst): don't run it twice
        local dup = M.orderCheckedText == text and M.nowMs() - (M.orderCheckedAt or -1e12) < 3000
        if not dup then pcall(M.playerOrder, player, text) end
        return a, b
    end
    M._orderWrapped = true
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local o = M.lastOrder and M.lastOrder[tostring(listener.record.uid)]
    if o and now - o.at < 8000 then
        req.order = { kind = M.orderLabel[o.kind], obeyed = o.obeyed }
    end
end)

-- patch hooks: leader commands are shouted, refusals answered; shelter eagerness by personality + fear
function M.onPatchCommand(leaderUid, kind, results)
    local pa = PA()
    local lsh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(leaderUid) or nil
    if lsh and M.commandLines[kind] then M.say(lsh, nil, pick(M.commandLines[kind]), { record = rec(leaderUid), combat = true }) end
    local P = patch()
    if P and fn(P, "gesture") then pcall(P.gesture, leaderUid, kind == "regroup" and "come_here" or (kind == "hold" and "stop" or "shout")) end
    for i, r in ipairs(results or {}) do
        if i <= 2 then
            local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(r.uid) or nil
            if sh and (not r.obeyed or roll(3) == 0) then M.say(sh, nil, M.ackLine(r.uid, r.obeyed), { record = rec(r.uid), combat = true }) end
        end
        if M.feel then M.feel(r.uid, kind == "fall_back" and "fear" or "anxiety", 0.1) end
    end
end
function M.shelterBias(uid, why)
    local lens = M.lens(uid)
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    if why == "night" then
        if b.hide or (lens.fearful or 0) > 0.15 then return 2 end
        if (lens.brave or 0) > 0.2 or lens.style == "giggle" then return 0 end
    end
    if why == "storm" and lens.style == "preach" then return 0 end -- preaches at the storm
    return 1
end
function M.onPatchShelter(what, uid, why)
    if what ~= "start" then return end
    local l = { record = rec(uid) }
    pcall(function() l.shell = PA().Talk.shellFor(uid) end)
    if l.shell and M.feel then M.feel(uid, "relief", 0.1) end
    -- pre-1.0 MP (P2b): the player nearest them hears it (single player: you)
    local near = type(ALifeSide) == "table" and l.shell and ALifeSide.nearestTo(l.shell, M.world.nearTiles) or nil
    if near == nil and not (type(ALifeSide) == "table" and ALifeSide.mpServer()) then near = M.you() end
    if l.shell and near and roll(3) == 0 then
        M.worldReact(l, near, { kind = "shelter", what = "You're heading inside to get out of the " .. ({ horde = "way of the horde", storm = "storm",
            blizzard = "blizzard", cold = "cold", night = "dark" })[why or ""] .. "", style = "say it as you go (tell the others, or the newcomer)", maxWords = 10, kindMs = 600000 })
    end
end
function M.hookPatchV12()
    local P = patch()
    if P == nil or P._talkV12 or type(P.hooks) ~= "table" then return false end
    P.shelterBias = M.shelterBias
    P.obeyChance = M.obeyChance
    if type(P.hooks.command) == "table" then table.insert(P.hooks.command, function(...) pcall(M.onPatchCommand, ...) end) end
    if type(P.hooks.shelter) == "table" then table.insert(P.hooks.shelter, function(...) pcall(M.onPatchShelter, ...) end) end
    P._talkV12 = true
    log("patch 1.2 hooks: shelter, leader commands, player orders")
    return true
end

----------------------------------------------------------------------------------------------------------------
for k, v in pairs({ worldReactions = true, playerOrders = true }) do if M.settings[k] == nil then M.settings[k] = v end end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "worldReactions", "playerOrders" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
if type(M.eventModes) == "table" and M.reactRequest then M.eventModes.world = { request = M.reactRequest, finish = M.reactFinish } end
local lastScan = -1e12
function M.worldTick()
    if not M.worldHere() then return end
    pcall(M.hookPatchV12)
    local now = nowMs()
    if now - lastScan < M.world.everyMs then return end
    lastScan = now
    if M.settings.worldReactions == false then return end
    M.eachPlayer(M.worldScan) -- pre-1.0 MP (P2b): every player's surroundings (single player: yours)
end
if type(Events) == "table" and Events.OnTick then
    local n = 0
    ALifeHealth.tickAdd("ALifeLLMTalk_World", function()
        n = n + 1
        if n % 20 ~= 7 then return end
        local ok, e = pcall(M.worldTick)
        if not ok then log("world tick error: " .. tostring(e)) end
    end)
end
return M
