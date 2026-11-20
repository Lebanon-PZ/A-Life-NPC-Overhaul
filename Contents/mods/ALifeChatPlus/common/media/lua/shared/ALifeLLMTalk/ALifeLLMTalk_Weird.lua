-- A-Life Talk 0.5.1: FEAR OF THE WEIRD: Silent Hill fog, Backrooms entrances, sewers, Cry of Fear monsters - detected softly
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Weird") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Weird"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Weird") end end -- 0.5.1.6 perf label
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Weird", function()
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
setting("weirdFear", true)
M.weirdCfg = { tick = 8000, tiles = 25, gapMs = 240000, refuseTiles = 6 }
M.weirdMods = nil
function M.detectWeirdMods()
    local found = {}
    local ids = {}
    pcall(function()
        local list = getActivatedMods()
        for i = 0, list:size() - 1 do ids[#ids + 1] = string.lower(tostring(list:get(i))) end
    end)
    local function has(words) for _, id in ipairs(ids) do for _, w in ipairs(words) do if string.find(id, w, 1, true) then return true end end end; return false end
    found.silenthill = has({ "silenthill", "silent_hill", "silent hill", "shfog" })
    found.backrooms = has({ "backrooms" })
    found.sewers = has({ "sewer" })
    found.cryoffear = has({ "cryoffear", "cry_of_fear", "cof" })
    M.weirdMods = found
    local any = {}
    for k, v in pairs(found) do if v then any[#any + 1] = k end end
    if #any > 0 then log("weird: detected " .. table.concat(any, ", ")) end
    return found
end
-- what's weird near (x, y, z): sprite / room name words for entrances and sewers, entity outfit / type for monsters
M.weirdWords = { backrooms = { "backroom", "levelzero", "level_0" }, sewers = { "sewer", "manhole", "drain_entry" },
    monster = { "cryoffear", "cof_", "monster", "faceless", "carcass", "sawrunner", "pyramid" } }
local function wordIn(s, list) s = string.lower(tostring(s or "")); for _, w in ipairs(list) do if string.find(s, w, 1, true) then return true end end; return false end
function M.weirdAt(x, y, z)
    local mods = M.weirdMods or M.detectWeirdMods()
    local out = {}
    local c = M.climate and M.climate() or { fog = 0 }
    if c.fog >= 0.6 and (mods.silenthill or c.fog >= 0.9) then out.fog = true end
    local cell = getCell and getCell() or nil
    if cell and (mods.backrooms or mods.sewers) then
        for dx = -M.weirdCfg.refuseTiles, M.weirdCfg.refuseTiles, 2 do
            for dy = -M.weirdCfg.refuseTiles, M.weirdCfg.refuseTiles, 2 do
                local sq = nil
                pcall(function() sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, math.floor(z or 0)) end)
                if sq ~= nil then
                    local objs = nil
                    pcall(function() objs = sq:getObjects() end)
                    local n = 0
                    pcall(function() n = objs:size() end)
                    for i = 0, math.min(n, 8) - 1 do
                        local name = ""
                        pcall(function() name = objs:get(i):getSprite():getName() end)
                        if mods.backrooms and wordIn(name, M.weirdWords.backrooms) then out.backrooms = { x = sq:getX(), y = sq:getY() } end
                        if mods.sewers and wordIn(name, M.weirdWords.sewers) then out.sewers = { x = sq:getX(), y = sq:getY() } end
                    end
                    pcall(function() local room = sq:getRoom(); if room and wordIn(room:getName(), M.weirdWords.backrooms) then out.backrooms = { x = sq:getX(), y = sq:getY() } end end)
                end
            end
        end
    end
    if cell and mods.cryoffear then
        local list = nil
        pcall(function() list = cell:getZombieList() end)
        local n = 0
        pcall(function() n = list:size() end)
        for i = 0, math.min(n, 300) - 1 do
            local zb = list:get(i)
            local zx, zy = pos(zb)
            if zx and (zx - x) ^ 2 + (zy - y) ^ 2 <= 15 * 15 then
                local outfit = ""
                pcall(function() outfit = zb:getOutfitName() end)
                local md = nil
                pcall(function() md = zb:getModData() end)
                if wordIn(outfit, M.weirdWords.monster) or (type(md) == "table" and (md.CoFMonster or md.cryOfFear or md.isMonster)) then out.monster = true; break end
            end
        end
    end
    return out
end
M.weirdLines = {
    fog = { "This fog ain't natural. Things walk in it.", "Don't go into the fog. Nobody comes back from the fog.", "Hear that siren? ...Tell me you hear it." },
    backrooms = { "I'm not going in there. The walls hum.", "Doors that lead nowhere. Nope. Not me.", "My cousin went in a place like that. Never came out." },
    sewers = { "Not the sewers. Something lives down there.", "You go down there, you go alone.", "I heard scratching from that drain." },
    monster = { "What the hell IS that?!", "That's not one of the dead - RUN!", "God help us, what is that thing?!" },
}
M.weirdAt2 = {}
function M.weirdTick(now)
    if M.settings.weirdFear == false or not M.worldHere() then return end
    local near, player = nearPlayer(M.weirdCfg.tiles)
    if player == nil or #near == 0 then return end
    local px, py, pz = pos(player)
    local w = M.weirdAt(px, py, pz)
    local kind = (w.monster and "monster") or (w.backrooms and "backrooms") or (w.sewers and "sewers") or (w.fog and "fog") or nil
    if kind == nil then return end
    for i, l in ipairs(near) do
        if i > 3 then break end
        local uid = tostring(l.record.uid)
        local lens = M.lens and M.lens(uid) or {}
        local scared = 0.3 + (lens.fearful or 0) + (lens.devout or 0) * 0.5 + (lens.unhinged or 0) * 0.5 - (lens.brave or 0) * 0.5
        if M.feel then M.feel(uid, kind == "monster" and "fear" or "dread", clamp(scared * (kind == "monster" and 0.8 or 0.4), 0.1, 0.9), "something unnatural (" .. kind .. ")") end
        if now - (M.weirdAt2[uid] or -1e12) >= M.weirdCfg.gapMs and idleOk(l, now) then
            M.weirdAt2[uid] = now
            local P = patch()
            if kind == "monster" then
                if P and fn(P, "gesture") then pcall(P.gesture, uid, "spooked") end
                local O = PA().TalkOrders
                if O and fn(O, "runAway") and scared > 0.5 then pcall(O.runAway, l.record, l.shell, player, now) end -- panic: flee (A-Life's own flee order)
            end
            local following = P and fn(P, "orderedBy") and P.orderedBy(uid) ~= nil
            if (kind == "backrooms" or kind == "sewers") and scared > 0.4 and not following and P and fn(P, "leaveArea") then
                local spot = w[kind]
                pcall(P.leaveArea, uid, { x1 = spot.x - 3, y1 = spot.y - 3, x2 = spot.x + 3, y2 = spot.y + 3 }, player, 120000) -- refuses to go near it
            end
            speak(l, player, "weird", "You see / feel something unnatural: " .. kind .. ". React with superstition or panic, in character", pick(M.weirdLines[kind], uid .. now),
                { keyMs = M.weirdCfg.gapMs, urgent = kind == "monster" })
            log("weird: " .. uid .. " reacts to " .. kind)
        end
    end
end
regMode("weird")
everyMs(M.weirdCfg.tick, M.weirdTick)
return M
