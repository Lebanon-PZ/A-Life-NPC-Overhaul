-- A-Life Talk 0.5.1: NPC ROMANCE & RIVALRY: pairs fall for each other (PairsLife: crush -> partner -> ex), get jealous, break up, drama
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Love") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Love"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Love") end end -- 0.5.1.6 perf label
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Love", function()
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
setting("npcLove", true)
M.loveCfg = { jealousTiles = 15, jealousGapH = 6, dramaGapH = 12 }
function M.loveOf(uid)
    local out = {}
    for _, t in ipairs(M.tiesOf and M.tiesOf(uid, ALifeSide.you(), 12, true) or {}) do
        if t.type == "partner" or t.type == "crush" or t.type == "ex" or t.type == "rival" then out[#out + 1] = t end
    end
    return out
end
function M.partnerOf(uid)
    for _, t in ipairs(M.loveOf(uid)) do if t.type == "partner" and not t.dead then return t end end
    return nil
end
-- jealousy: A's partner B sees A cosy with C (chat / cards activity, or ambient flirting)
function M.jealousyCheck(a, c, why)
    if M.settings.npcLove == false then return nil end
    a, c = tostring(a), tostring(c)
    local p = M.partnerOf(a)
    if p == nil or tostring(p.uid) == c then return nil end
    local b = tostring(p.uid)
    local pa = PA()
    local bs = pa and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(b) or nil
    local as = pa and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(a) or nil
    local bx, by = pos(bs)
    local ax, ay = pos(as)
    if bx == nil or ax == nil or (bx - ax) ^ 2 + (by - ay) ^ 2 > M.loveCfg.jealousTiles ^ 2 then return nil end
    local mark = bucket("love")
    local key = b .. ">" .. c
    if hours() - (mark[key] or -1e9) < M.loveCfg.jealousGapH then return nil end
    mark[key] = hours()
    local lens = M.lens and M.lens(b) or {}
    local jealous = 0.3 + (lens.romantic or 0) + (lens.paranoid or 0) * 0.8 + (lens.volatile or 0) * 0.6 - (lens.calm or 0) * 0.5
    if jealous < 0.35 then return nil end
    local d = -math.floor(3 + jealous * 6)
    if M.pairBump then pcall(M.pairBump, b, c, d, "jealous over " .. firstOf(rec(a))); pcall(M.pairBump, a, b, math.floor(d / 2), "a jealous scene") end
    if M.feel then M.feel(b, "jealousy", 0.4 + jealous * 0.3, firstOf(rec(a)) .. " and " .. firstOf(rec(c))) end
    if M.logInteraction then
        pcall(M.logInteraction, b, "Got jealous: " .. firstOf(rec(a)) .. " and " .. firstOf(rec(c)), nil, nil, "event")
        pcall(M.logInteraction, a, firstOf(rec(b)) .. " made a jealous scene about " .. firstOf(rec(c)), nil, nil, "event")
    end
    local lines = { "Having fun over there, {a}?", "{a}. A word. Now.", "Oh, don't mind me, {a}.", "Get away from my {a}, {c}." }
    local line = string.gsub(string.gsub(pick(lines, b .. c .. hours()), "{a}", firstOf(rec(a))), "{c}", firstOf(rec(c)))
    local player = ALifeSide.you()
    if bs and player then speak({ record = rec(b), shell = bs }, player, "love", "Your partner " .. firstOf(rec(a)) .. " is getting cosy with " .. firstOf(rec(c))
        .. " right in front of you. You're jealous", line, { keyMs = 1800000 }) end
    if M.addDeed then pcall(M.addDeed, "drama", firstOf(rec(b)) .. " caught " .. firstOf(rec(a)) .. " with " .. firstOf(rec(c)), 0, { a, b, c }) end
    log("jealousy: " .. b .. " over " .. a .. " and " .. c)
    return d
end
-- big moments from the bond ladder: together / broke up / unrequited
function M.loveChanged(a, b, old, new, why)
    if M.settings.npcLove == false then return end
    local an, bn = firstOf(rec(a)), firstOf(rec(b))
    local text = nil
    if new == "partner" then text = an .. " and " .. bn .. " are together now"
    elseif new == "ex" and old == "partner" then text = an .. " and " .. bn .. " broke up"
    elseif new == "crush" then text = an .. " has a thing for " .. bn end
    if text == nil then return end
    bucket("loveNews")[#bucket("loveNews") + 1] = { t = text, h = hours() }
    while #bucket("loveNews") > 20 do table.remove(bucket("loveNews"), 1) end
    if M.addDeed and new ~= "crush" then pcall(M.addDeed, "drama", text, 0, { tostring(a), tostring(b) }) end
    -- group drama: friends take sides after a breakup
    if new == "ex" and old == "partner" then
        for _, t in ipairs(M.tiesOf and M.tiesOf(a, nil, 6) or {}) do
            if t.score >= 20 and tostring(t.uid) ~= tostring(b) and M.pairBump then pcall(M.pairBump, t.uid, b, -3, "took " .. an .. "'s side in the breakup") end
        end
        if M.feel then M.feel(tostring(a), "sadness", 0.4, "the breakup"); M.feel(tostring(b), "sadness", 0.4, "the breakup") end
    elseif new == "partner" and M.feel then M.feel(tostring(a), "love", 0.4, bn); M.feel(tostring(b), "love", 0.4, an) end
    log("love: " .. text)
end
function M.loveLine(uid)
    local out = {}
    for _, t in ipairs(M.loveOf(uid)) do
        if t.type == "partner" then out[#out + 1] = "With " .. t.name
        elseif t.type == "crush" then out[#out + 1] = "Sweet on " .. t.name
        elseif t.type == "ex" then out[#out + 1] = "Ex: " .. t.name
        elseif t.type == "rival" then out[#out + 1] = "Rival: " .. t.name end
        if #out >= 3 then break end
    end
    return #out > 0 and table.concat(out, "  |  ") or nil
end
function M.loveInstall()
    if M.loveHooked then return end
    if type(M.bondChanged) == "function" then
        M.loveHooked = true
        local orig = M.bondChanged
        M.bondChanged = function(a, b, old, new, why, row, ...)
            local r1, r2 = orig(a, b, old, new, why, row, ...)
            pcall(M.loveChanged, a, b, old, new, why)
            return r1, r2
        end
    end
    if type(M.startActivity) == "function" and not M.loveActWrapped then
        M.loveActWrapped = true
        local origS = M.startActivity
        M.startActivity = function(l, kind, now, opts, ...)
            local ok, why = origS(l, kind, now, opts, ...)
            if ok and opts and opts.partner and (kind == "chat" or kind == "cards") then pcall(M.jealousyCheck, l.record.uid, opts.partner, kind) end
            return ok, why
        end
    end
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local line = M.loveLine(tostring(listener.record.uid))
    if line then req.loveLife = line end
end)
regMode("love")
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.loveInstall) end) end
pcall(M.loveInstall)
return M
