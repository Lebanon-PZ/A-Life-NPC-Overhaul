-- A-Life Talk 0.5.1: SETTLERS: friends offer (or agree) to live at your base; base morale / food / safety, loyalties and family decide
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Settle") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Settle"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Settle") end end -- 0.5.1.6 perf label
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
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
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
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Settle", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("settlers", true)
M.settleCfg = { need = 45, offerTick = 30000, offerChance = 12, offerGapH = 24, askGapH = 3, offerTiles = 15, yesMs = 60000, scanTiles = 14 }
M.settleWords = { "join my base", "join our base", "come live with", "live with us", "live with me", "move in", "stay at my base", "come to my base",
    "join my camp", "join our camp", "settle with us", "settle down with", "come back to my place", "come stay with us", "live at my place",
    "live at our place", "join my settlement", "join our settlement", "come home with me", "be part of our base" }
M.yesWords = { "yes", "yeah", "sure", "okay", "ok", "welcome", "of course", "absolutely", "come on", "please do", "deal", "let's go" }
M.settleOffers = {} -- uid -> { at }
-- the base right now: residents, food, safety, morale 0..100 (cheap; food is cached)
M.baseCache = {}
-- pre-1.0: ONE food count (the camp widget, the base's mood, the party cap). It used to read only the ground floor, 14 tiles
-- round the middle, 60 containers, the first container of each object, rotten food too, and never the Food stores the player
-- marked (Jeem), so a full store read "running low". Now: the marked Food stores first (any floor, any distance), then the
-- base's own area on every floor, every container of every object, one bag deep, rotten food left out.
setting("foodScanRadius", 30)   -- tiles from the base's middle
setting("foodScanFloors", 4)    -- floors counted from the ground up
setting("foodScanMax", 400)     -- containers read in the area (the marked stores are always read)
M.foodScanSquares = 30000       -- hard stop for one count (never a long frame)
local function foodSetting(key, d) local v = tonumber(M.settings[key]); if v == nil or v < 1 then return d end return v end
local function foodItem(it)
    local cat, rotten = nil, false
    pcall(function() cat = it:getCategory() end)
    if cat ~= "Food" then return false end
    pcall(function() rotten = it:isRotten() == true end)
    return not rotten
end
local function isBag(it)
    local yes = false
    pcall(function() yes = type(instanceof) == "function" and instanceof(it, "InventoryContainer") == true end)
    return yes
end
local function containerFood(cont, depth)
    local n = 0
    local okI, items = pcall(function() return cont:getItems() end)
    if not okI or items == nil then return 0 end
    for j = 0, items:size() - 1 do
        local it = items:get(j)
        if foodItem(it) then n = n + 1
        elseif depth < 1 and isBag(it) then
            local inner = nil
            pcall(function() inner = it:getInventory() end)
            if inner ~= nil then n = n + containerFood(inner, depth + 1) end
        end
    end
    return n
end
local function storable(o)
    local no = false
    pcall(function()
        if type(instanceof) ~= "function" then return end
        no = instanceof(o, "IsoDeadBody") or instanceof(o, "BaseVehicle") or instanceof(o, "IsoGameCharacter")
    end)
    return not no
end
-- food in every container on one square; seen: "x,y,z:object:container" already counted (the stores and the area overlap)
local function squareFood(sq, key, seen)
    local n, c = 0, 0
    local okO, objs = pcall(function() return sq:getObjects() end)
    if not okO or objs == nil then return 0, 0 end
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if storable(o) then
            local count = 0
            pcall(function() count = tonumber(o:getContainerCount()) or 0 end)
            for ci = 0, count - 1 do
                local k = key .. ":" .. i .. ":" .. ci
                if not seen[k] then
                    seen[k] = true
                    local cont = nil
                    pcall(function() cont = o:getContainerByIndex(ci) end)
                    if cont ~= nil then n = n + containerFood(cont, 0); c = c + 1 end
                end
            end
        end
    end
    return n, c
end
-- { items, containers, stores }: base = a box { x1, y1, x2, y2 } (M.playerBase)
function M.foodScan(base, player)
    local out = { items = 0, containers = 0, stores = 0 }
    if type(base) ~= "table" then return out end
    local cx, cy = math.floor((base.x1 + base.x2) / 2), math.floor((base.y1 + base.y2) / 2)
    local seen = {}
    local okC, cell = pcall(getCell)
    if not okC or cell == nil then return out end
    -- the Food stores the player marked (Jeem's base areas): any floor, even outside the box
    pcall(function()
        local j = ProjectALifeJimmy
        if type(j) ~= "table" or type(j.BaseAreas) ~= "table" or type(j.BaseAreas.baseAt) ~= "function" or type(j.BaseAreas.storesOf) ~= "function" then return end
        local px, py = cx, cy
        local x, y = pos(player)
        if x ~= nil and y ~= nil then px, py = x, y end
        local jb = j.BaseAreas.baseAt(px, py, 30)
        if type(jb) ~= "table" then return end
        for _, st in ipairs(j.BaseAreas.storesOf(jb, "food") or {}) do
            local z = tonumber(st.z) or 0
            local sq = cell:getGridSquare(st.x, st.y, z)
            if sq ~= nil then
                local n, c = squareFood(sq, st.x .. "," .. st.y .. "," .. z, seen)
                out.items, out.containers, out.stores = out.items + n, out.containers + c, out.stores + 1
            end
        end
    end)
    -- the base's own area, every floor
    local ground, groundLoaded = 0, 0
    pcall(function()
        local r, floors, most = foodSetting("foodScanRadius", 30), foodSetting("foodScanFloors", 4), foodSetting("foodScanMax", 400)
        local squares, area = 0, 0
        for z = 0, floors - 1 do
            for x = math.max(base.x1, cx - r), math.min(base.x2, cx + r) do
                for y = math.max(base.y1, cy - r), math.min(base.y2, cy + r) do
                    squares = squares + 1
                    if squares > M.foodScanSquares then return end
                    local sq = cell:getGridSquare(x, y, z)
                    if z == 0 then ground = ground + 1; if sq ~= nil then groundLoaded = groundLoaded + 1 end end
                    if sq ~= nil then
                        local n, c = squareFood(sq, x .. "," .. y .. "," .. z, seen)
                        out.items, out.containers, area = out.items + n, out.containers + c, area + c
                        if area > most then return end
                    end
                end
            end
        end
    end)
    -- pre-1.0 (Rundown Nov 19): away from base its squares aren't loaded, so the count read 0 ("running low", the run
    -- meal called off). Unloaded (under half the ground squares there) = the last count taken while it was loaded.
    local key = cx .. ":" .. cy
    local okS, st = pcall(M.store)
    local known = okS and type(st) == "table" and st or nil
    if known then known.foodKnown = type(known.foodKnown) == "table" and known.foodKnown or {} end
    out.loaded = ground > 0 and groundLoaded * 2 >= ground
    if out.loaded then
        if known then known.foodKnown[key] = { items = out.items, containers = out.containers } end
    else
        local last = known and known.foodKnown[key] or nil
        if type(last) == "table" then
            out.items, out.containers = tonumber(last.items) or out.items, tonumber(last.containers) or out.containers
            out.remembered = true
        end
    end
    return out
end
-- pre-1.0: the base's area is loaded right now (its food can be counted and taken for real)
function M.baseLoaded(base)
    if type(base) ~= "table" or not tonumber(base.x1) then return false end
    local okC, cell = pcall(getCell)
    if not okC or cell == nil then return false end
    local cx, cy = math.floor((base.x1 + base.x2) / 2), math.floor((base.y1 + base.y2) / 2)
    local ok, sq = pcall(function() return cell:getGridSquare(cx, cy, 0) end)
    return ok and sq ~= nil
end
function M.baseState(player)
    local base = M.playerBase and M.playerBase(player) or nil
    if base == nil then return nil end
    local cx, cy = math.floor((base.x1 + base.x2) / 2), math.floor((base.y1 + base.y2) / 2)
    local key = cx .. ":" .. cy
    local now = nowMs()
    local c = M.baseCache[key]
    if c == nil or now - c.at > 120000 then
        c = { at = now, food = 0 }
        local okF, scan = pcall(M.foodScan, base, player)
        if okF and type(scan) == "table" then c.food = tonumber(scan.items) or 0 end
        pcall(function() local inv = player:getInventory(); local items = inv:getItems(); for j = 0, items:size() - 1 do if items:get(j):getCategory() == "Food" then c.food = c.food + 1 end end end)
        M.baseCache[key] = c
    end
    local P = patch()
    local zs = (P and fn(P, "zombiesNear")) and (P.zombiesNear(cx, cy, 30) or 0) or 0
    local settlers = 0
    local mood = 0
    for uid, e in pairs((P and fn(P, "settlersOf")) and P.settlersOf() or {}) do
        local r = rec(uid)
        if r and r.lifecycle ~= "dead" and (e.x - cx) ^ 2 + (e.y - cy) ^ 2 <= 60 * 60 then
            settlers = settlers + 1
            local v = 0
            pcall(function() v = PA().NpcOpinion.valueOf(r, player) or 0 end)
            mood = mood + v
        end
    end
    local foodPer = c.food / math.max(1, settlers + 1)
    local safety = clamp(100 - zs * 6, 0, 100)
    local morale = clamp(math.floor(40 + math.min(25, foodPer * 2) + (safety - 50) * 0.3 + (settlers > 0 and mood / settlers / 5 or 0) + math.min(10, settlers * 2)), 0, 100)
    return { x = cx, y = cy, z = 0, bounds = base, food = c.food, foodPer = foodPer, zombies = zs, safety = safety, settlers = settlers, morale = morale }
end
-- favours they owe you: gifts, help, jobs done, wounds treated (from their key memories)
function M.favorsOwed(uid)
    local n = 0
    for _, e in ipairs(M.keyMemOf and M.keyMemOf(uid) or {}) do
        if e.k == "kindness" or e.k == "gift" or e.k == "quest" or e.k == "treated" or e.k == "saved" then n = n + 1 end
    end
    return math.min(n, 6)
end
-- yes / no with a real reason; also who they'd bring (partner / sibling / child in their group)
function M.settleVerdict(l, player, base)
    local uid = tostring(l.record.uid)
    local pa = PA()
    local v = 0
    pcall(function() v = pa.NpcOpinion.valueOf(l.record, player) or 0 end)
    local tie = M.playerTie and select(1, M.playerTie(l.record, player)) or "stranger"
    local lens = M.lens and M.lens(uid) or {}
    local p = M.partsOf and M.partsOf(uid) or nil
    local k = p and p.core and p.core.key or ""
    local m = type(l.record.memory) == "table" and l.record.memory or {}
    local score = v + M.favorsOwed(uid) * 4
    if tie == "best friend" then score = score + 20 elseif tie == "buddy" or tie == "ally" then score = score + 10 end
    local ro = M.romanceOf and M.romanceOf(uid) or {}
    if (ro.stage or 0) >= 2 then score = score + 15 end
    if base then score = score + math.floor((base.morale - 50) / 3) end
    score = score - math.floor(((lens.proud or 0) * 25) + ((lens.paranoid or 0) * 15)) + math.floor((lens.kind or 0) * 8 + (lens.fearful or 0) * (base and base.safety >= 60 and 10 or -10))
    if k == "loner" or k == "drifter" or k == "hermit" or k == "lonewolf" then score = score - 20 end
    -- loyalty to their own people
    local leader = false
    pcall(function() local g = PA().ModuleLeader.groups[m.groupId]; leader = g ~= nil and tostring(g.leaderUid) == uid end)
    if leader then score = score - 30 end
    if m.groupId ~= nil then score = score - math.floor(10 + (lens.loyal or 0) * 25 + (lens.disciplined or 0) * 10) end
    -- family / partner in their group: bring them, or refuse to leave them
    local bring, family = {}, nil
    for _, t in ipairs(M.tiesOf and M.tiesOf(uid, nil, 8, true) or {}) do
        if not t.dead and (t.type == "partner" or t.type == "sibling" or t.type == "child" or t.type == "parent") then
            local fr = rec(t.uid)
            local fm = fr and type(fr.memory) == "table" and fr.memory or {}
            if fr and fm.groupId ~= nil and fm.groupId == m.groupId then
                local fv = 0
                pcall(function() fv = pa.NpcOpinion.valueOf(fr, player) or 0 end)
                if fv >= -5 then bring[#bring + 1] = { uid = tostring(t.uid), name = t.name, type = t.type }
                else family = family or { name = t.name, type = t.type } end
            end
        end
    end
    local why
    if score >= M.settleCfg.need and family == nil then
        why = #bring > 0 and ("you'll come - but your " .. bring[1].type .. " " .. bring[1].name .. " comes too")
            or ((base and base.morale >= 65) and "their place sounds good: food, walls, people" or "you trust them and it beats being out here")
        return true, why, bring, score
    end
    if v < 10 then why = "you don't know them well enough to live under their roof"
    elseif family then why = "you won't leave your " .. family.type .. " " .. family.name .. " behind, and they don't like the newcomer"
    elseif leader then why = "you lead your own people; they need you"
    elseif base and base.safety < 40 then why = "their place is crawling with the dead"
    elseif base and base.foodPer < 2 then why = "they can barely feed who they've got"
    elseif (lens.proud or 0) >= 0.3 or k == "loner" then why = "you don't take charity - you make it on your own"
    elseif m.groupId ~= nil then why = "your people need you here"
    else why = "not yet - maybe when you know them better" end
    return false, why, bring, score
end
function M.settleApply(l, player, base, bring)
    local P = patch()
    if base == nil or P == nil or not fn(P, "baseSettle") then return false end
    local ok = P.baseSettle(l.record.uid, base.x, base.y, base.z, 600000)
    if not ok then return false end
    local s = bucket("settlers")
    s[tostring(l.record.uid)] = { x = base.x, y = base.y, z = base.z, h = hours() }
    for _, b in ipairs(bring or {}) do
        if P.baseSettle(b.uid, base.x + 1, base.y, base.z, 600000) then s[b.uid] = { x = base.x, y = base.y, h = hours(), with = tostring(l.record.uid) } end
    end
    if M.keyMem then pcall(M.keyMem, l.record.uid, "settled", "Moved into the newcomer's base") end
    if M.logInteraction then pcall(M.logInteraction, l.record.uid, "Moved into your base" .. ((bring and #bring > 0) and (" with " .. bring[1].name) or ""), nil, nil, "event") end
    if M.feel then M.feel(l.record.uid, "hope", 0.4, "a real home again") end
    pcall(function() PA().NpcOpinion.adjust(l.record, player, 3, "You gave them a home") end)
    log("settler: " .. tostring(l.record.uid) .. " moves to the base")
    return true
end
-- asked by the player
M.settleAsks = {}
function M.onSettleWords(player, text, loud, hearers)
    if M.settings.settlers == false or type(text) ~= "string" then return end
    local low = string.lower(text)
    local now = nowMs()
    -- yes to an offer
    for uid, o in pairs(M.settleOffers) do
        if now - o.at <= M.settleCfg.yesMs then
            for _, w in ipairs(M.yesWords) do
                if string.find(" " .. low .. " ", "[^%a]" .. w .. "[^%a]") then
                    local pa = PA()
                    local r = rec(uid)
                    local sh = r and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
                    if r and sh then
                        local base = M.baseState(player)
                        M.settleApply({ record = r, shell = sh }, player, base, o.bring)
                        if M.say then M.say(sh, player, pick({ "Alright. I'll head over now.", "Thank you. Really. I'll pull my weight.", "Home. Huh. Been a while." }, uid), { record = r }) end
                    end
                    M.settleOffers[uid] = nil
                    return
                end
            end
        else M.settleOffers[uid] = nil end
    end
    local asked = false
    for _, w in ipairs(M.settleWords) do if string.find(low, w, 1, true) then asked = true; break end end
    if not asked or hearers == nil or hearers[1] == nil then return end
    local l = hearers[1]
    local uid = tostring(l.record.uid)
    if bucket("settlers")[uid] then return end
    local base = M.baseState(player)
    local ok, why, bring = M.settleVerdict(l, player, base)
    if base == nil then ok, why = false, "you don't even have a place yet" end
    local last = M.settleAsks[uid]
    if not ok and last and hours() - last < M.settleCfg.askGapH then why = "you asked already - still no" end
    M.settleAsks[uid] = hours()
    M.settleLast = { uid = uid, ok = ok, why = why, at = now }
    if ok then M.settleApply(l, player, base, bring) end
    if M.logInteraction then pcall(M.logInteraction, uid, (ok and "Agreed" or "Refused") .. " to live at your base (" .. why .. ")", nil, nil, "recruit") end
end
table.insert(M.playerWordHooks, M.onSettleWords)
table.insert(M.requestExtras, function(req, player, listener, now)
    local s = M.settleLast
    if s and s.uid == tostring(listener.record.uid) and now - s.at < 10000 then req.settle = { ok = s.ok, why = s.why } end
    if bucket("settlers")[tostring(listener.record.uid)] then req.settler = true end
end)
-- they offer on their own (good relationship, idle, safe)
-- pre-1.0 MP: once per online player (the one near the person offering is "you"); SP: the same single run as before
function M.settleOfferTick(now)
    if M.settings.settlers == false or not M.worldHere() then return end
    M.eachPlayer(M.settleOfferTickFor, now)
end
function M.settleOfferTickFor(p, now)
    local near, player = nearPlayer(M.settleCfg.offerTiles)
    if player == nil or #near == 0 then return end
    local base = nil
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        local mark = bucket("settleOfferH")
        if not bucket("settlers")[uid] and hours() - (mark[uid] or -1e9) >= M.settleCfg.offerGapH and idleOk(l, now) then
            base = base or M.baseState(player)
            if base == nil then return end
            local ok, why, bring, score = M.settleVerdict(l, player, base)
            if ok and score >= M.settleCfg.need + 15 and (hash(uid .. math.floor(hours())) % 100) < M.settleCfg.offerChance then
                mark[uid] = hours()
                M.settleOffers[uid] = { at = now, bring = bring }
                local fb = #bring > 0 and ("Hey... you got room at your place? For me and " .. bring[1].name .. "? We'd pull our weight.")
                    or pick({ "Hey... you got room at your place? I could pull my weight.", "I'm tired of sleeping with one eye open. Could I come stay at your place?",
                        "Your place - you need another pair of hands there?" }, uid)
                speak(l, player, "settle", "You trust the newcomer and you'd like to live at their base (" .. why .. "). Ask them, in your own words", fb, { keyMs = 3600000, urgent = true })
                log("settler offer: " .. uid)
                return
            end
        end
    end
end
regMode("settle")
everyMs(M.settleCfg.offerTick, M.settleOfferTick)
return M
