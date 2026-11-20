-- A-Life Talk 0.5.1: FACTION MEMORY: helping or hurting one faction shifts how its rivals (and allies) see you
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_FactionRep") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "FactionRep"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("FactionRep") end end -- 0.5.1.6 perf label
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
    ALifeHealth.tickAdd("ALifeLLMTalk_FactionRep", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("factionMemory", true)
M.frCfg = { minDelta = 3, rivalShare = 0.4, allyShare = 0.3, cap = 60, newsAt = 10 }
function M.factionsList()
    local pa = PA()
    local out = {}
    local cur = pa and pa.Catalog and (pa.Catalog.current or {}) or {}
    for id, f in pairs(type(cur.factions) == "table" and cur.factions or {}) do out[#out + 1] = { id = id, f = f } end
    return out
end
function M.factionStanceTo(fromF, toF)
    local pa = PA()
    if not fn(pa and pa.RelationLayers, "towardFaction") then return nil end
    local ok, st = pcall(pa.RelationLayers.towardFaction, fromF, toF)
    st = ok and string.lower(tostring(st or "")) or ""
    if st == "hostile" or st == "enemy" or st == "war" then return "rival" end
    if st == "friendly" or st == "allied" or st == "ally" then return "ally" end
    return nil
end
function M.factionName(id)
    local f = nil
    pcall(function() f = PA().Catalog.faction(id) end)
    return (type(f) == "table" and type(f.general) == "table" and f.general.name) or tostring(id)
end
function M.factionRepOf(fid) return tonumber((bucket("factionRep")[tostring(fid)])) or 0 end
function M.factionDeed(fid, delta, why)
    if M.settings.factionMemory == false or fid == nil or math.abs(delta) < M.frCfg.minDelta then return end
    local rep = bucket("factionRep")
    local cat = PA() and PA().Catalog
    local target = nil
    pcall(function() target = cat.faction(fid) end)
    rep[tostring(fid)] = clamp(M.factionRepOf(fid) + delta, -M.frCfg.cap, M.frCfg.cap)
    local shifted = {}
    for _, e in ipairs(M.factionsList()) do
        if tostring(e.id) ~= tostring(fid) and target then
            local s = M.factionStanceTo(e.f, target)
            if s == "rival" then rep[tostring(e.id)] = clamp(M.factionRepOf(e.id) - delta * M.frCfg.rivalShare, -M.frCfg.cap, M.frCfg.cap); shifted[#shifted + 1] = e.id
            elseif s == "ally" then rep[tostring(e.id)] = clamp(M.factionRepOf(e.id) + delta * M.frCfg.allyShare, -M.frCfg.cap, M.frCfg.cap); shifted[#shifted + 1] = e.id end
        end
    end
    -- other faction mods (soft: only functions that exist are called)
    pcall(function()
        if type(LivingFactions) == "table" and type(LivingFactions.addPlayerReputation) == "function" then LivingFactions.addPlayerReputation(tostring(fid), delta) end
        if type(FactionsExpanded) == "table" and type(FactionsExpanded.changeReputation) == "function" then FactionsExpanded.changeReputation(tostring(fid), delta) end
    end)
    -- radio news for big swings
    local total = M.factionRepOf(fid)
    local mark = bucket("factionNews")
    local step = math.floor(total / M.frCfg.newsAt)
    if step ~= (mark[tostring(fid)] or 0) and (M.newsNote or ALifeSide.mpServer()) then
        mark[tostring(fid)] = step
        pcall(M.outNews, "faction", (total > 0 and "word is a drifter has been helping " or "word is a drifter has been making enemies of ") .. M.factionName(fid))
    end
    log("faction memory: " .. tostring(fid) .. " " .. (delta > 0 and "+" or "") .. delta .. " (" .. tostring(why) .. "), " .. #shifted .. " related faction(s) shifted")
end
-- every opinion change of a faction member by the player feeds it (the unwrapped adjust is never touched)
function M.factionInstall()
    local pa = PA()
    if M.frWrapped or not fn(pa and pa.NpcOpinion, "adjust") then return end
    M.frWrapped = true
    local inner = pa.NpcOpinion.adjust
    pa.NpcOpinion.adjust = function(record, player, delta, why, ...)
        local a, b, c = inner(record, player, delta, why, ...)
        pcall(function()
            if type(record) == "table" and tonumber(delta) and not M.frBusy and not string.find(tostring(why or ""), "Heard a rumor", 1, true) then
                M.frBusy = true
                pcall(M.factionDeed, record.factionId, tonumber(delta), why)
                M.frBusy = false
            end
        end)
        return a, b, c
    end
end
-- first meeting: a stranger of that faction starts where their faction stands with you (once)
function M.factionFirstMeet(record, player)
    if M.settings.factionMemory == false or type(record) ~= "table" then return 0 end
    local seen = bucket("factionMet")
    local uid = tostring(record.uid)
    if seen[uid] then return 0 end
    seen[uid] = true
    local d = math.floor(M.factionRepOf(record.factionId) / 4)
    if d ~= 0 and fn(PA().NpcOpinion, "adjust") then
        M.frBusy = true
        pcall(PA().NpcOpinion.adjust, record, player, d, "How their people talk about you")
        M.frBusy = false
    end
    return d
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local fid = listener.record.factionId
    local v = M.factionRepOf(fid)
    if math.abs(v) >= 5 then req.factionRep = { name = M.factionName(fid), v = math.floor(v) } end
end)
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.factionInstall) end) end
pcall(M.factionInstall)
return M
