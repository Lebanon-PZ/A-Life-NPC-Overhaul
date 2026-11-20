-- A-Life Talk 0.5.1.7: BONDS WITH YOU - acquaintance / friend / close friend / best friend / lover, asked for by the player only
-- (speech or the Bond tab buttons), shared history timeline, "what they think of you", likes / dislikes. All in the people book.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Bond") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Bond"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Bond") end end -- perf label
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
local function nearPlayer(tiles, player)
    player = M.you(player) -- pre-1.0 MP (P2b): the player being handled (single player: you)
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Bond", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
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
-- settings (each feature can be switched off; off = the old behaviour, nothing of this runs)
----------------------------------------------------------------------------------------------------------------
setting("bondTiers", true)    -- acquaintance / friend / close friend / best friend / lover, asked for by the player only
setting("bondHistory", true)  -- shared history timeline (Bond tab)
setting("bondThought", true)  -- "what they think of you" (one cached first-person line)
setting("bondLikes", true)    -- likes / dislikes, "???" until learned
setting("unifiedDates", true)  -- 0.5.2.5 [pt252u]: one date format ("Dec 3, 10:25") in the whole window
setting("pronounFix", true)    -- 0.5.2.5 [pt252u]: the "what they think of you" line keeps the player's pronouns straight
setting("lastWordsConfirm", true) -- 0.5.2.5 [pt252u]: "heard X's last words" only once X really died (+ save clean-up)

M.tierNames = { "acquaintance", "friend", "close friend", "best friend", "lover" }
M.tierCfg = {
    need = { 0, 25, 45, 65, 0 },        -- standing needed to accept (lover goes through the romance rules)
    minDays = { 0, 0, 2, 5, 0 },        -- days known before they'd say yes
    cooldownH = 24, cooldownSoonH = 12, -- asking again: in-game hours
    stepCdH = 6, apolCdH = 12, hintCdH = 48,
    neglectDays = { 0, 30, 40, 50, 60 }, -- no contact at all for this long: one tier down (never from just being far away)
    histMax = 60, thoughtDays = 3, thoughtDelta = 10, tickMs = 10000,
    nearTiles = 15, askTiles = 12,
}

----------------------------------------------------------------------------------------------------------------
-- people book access (bucket "book": everything below lives in the entry, so it survives distance / unloading)
----------------------------------------------------------------------------------------------------------------
function M.pb(uid, create)
    uid = tostring(uid)
    local b = bucket("book")
    local e = b[uid]
    if type(e) ~= "table" then
        if not create then return nil end
        local r = rec(uid)
        if r and M.bookSnap then local ok, x = pcall(M.bookSnap, r); if ok and type(x) == "table" then e = x end end
        if type(e) ~= "table" then
            e = { name = r and nameOf(r) or "Someone" }
            b[uid] = e
        end
    end
    return e
end

-- in-game date for the timeline ("Jul 14, 15:00"); "Day N, HH:00" when the start date is unknown
local MON = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MLEN = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
function M.gameDate(h)
    h = tonumber(h) or hours()
    local sm, sd, st = nil, nil, nil
    pcall(function()
        local gt = getGameTime()
        sm, sd, st = gt:getStartMonth(), gt:getStartDay(), gt:getStartTimeOfDay()
    end)
    if type(sm) ~= "number" or type(sd) ~= "number" then
        local hh = math.floor(h % 24)
        return string.format("Day %d, %02d:00", math.floor(h / 24) + 1, hh)
    end
    local abs = (tonumber(st) or 9) + h
    local day, hh = sd + math.floor(abs / 24), math.floor(abs % 24)
    local mi = math.floor((abs * 60) % 60) -- 0.5.2.5: minutes too (one format everywhere, [pt252u])
    local mo = sm + 1
    local guard = 0
    while day >= MLEN[((mo - 1) % 12) + 1] and guard < 200 do day = day - MLEN[((mo - 1) % 12) + 1]; mo = mo + 1; guard = guard + 1 end
    return string.format("%s %d, %02d:%02d", MON[((mo - 1) % 12) + 1], day + 1, hh, mi)
end

-- 0.5.2.5 [pt252u]: ONE date format for every "when" in the window (header "Last talked", timeline, interactions,
-- memories). New rows carry the world hour (h); old rows only had "day N HH:MM" (nights survived) - mapped back
-- to a world hour from today's nights-survived count, then shown the same way as the timeline.
function M.legacyHour(n, hh, mm)
    n, hh, mm = tonumber(n), tonumber(hh) or 0, tonumber(mm) or 0
    if n == nil then return nil end
    local nowH, nowN, ch, cm = hours(), nil, 0, 0
    pcall(function() local gt = getGameTime(); nowN, ch, cm = gt:getNightsSurvived(), gt:getHour(), gt:getMinutes() end)
    if type(nowN) ~= "number" then return nil end
    local h = nowH - ((tonumber(ch) or 0) + (tonumber(cm) or 0) / 60) - (nowN - n) * 24 + hh + mm / 60
    if h < 0 then h = 0 end
    if h > nowH then h = nowH end
    return h
end
function M.whenText(row)
    if type(row) ~= "table" then return "" end
    if M.settings.unifiedDates == false then return tostring(row.t or row.when or "") end
    if tonumber(row.h) then return M.gameDate(tonumber(row.h)) end
    if row.d ~= nil and type(row.tm) == "string" then -- key memories {d = nights, tm = "HH:MM"}
        local hh, mm = string.match(row.tm, "^(%d+):(%d+)")
        local h = M.legacyHour(row.d, hh, mm)
        if h then return M.gameDate(h) end
        return "Day " .. tostring(row.d) .. ", " .. row.tm
    end
    if type(row.t) == "string" then
        local n, hh, mm = string.match(row.t, "^[Dd]ay (%d+),? (%d+):(%d+)")
        local h = n and M.legacyHour(n, hh, mm) or nil
        if h then return M.gameDate(h) end
        return row.t
    end
    return ""
end

----------------------------------------------------------------------------------------------------------------
-- (5b) shared history timeline
----------------------------------------------------------------------------------------------------------------
M.histIcons = { met = "met", save = "save", gift = "gift", gotgift = "gift", fight = "fight", betray = "betrayal", tier = "bond",
    danger = "danger", heal = "care", death = "death", apology = "apology", grudge = "grudge", change = "change", habit = "habit",
    party = "party", talk = "talk", likes = "learned" }
function M.histOf(uid)
    local e = bucket("book")[tostring(uid)]
    return (type(e) == "table" and type(e.hist) == "table") and e.hist or {}
end
function M.histAdd(uid, kind, text, opts)
    if M.settings.bondHistory == false then return nil end
    opts = opts or {}
    local e = M.pb(uid, true)
    if e == nil then return nil end
    e.hist = type(e.hist) == "table" and e.hist or {}
    local h = tonumber(opts.h) or hours()
    if #e.hist == 0 and kind ~= "met" then
        local b = type(e.bond) == "table" and e.bond or nil
        e.hist[1] = { h = (b and b.metH) or h, k = "met", t = "First met" }
    end
    -- same thing again within the hour: one row
    for i = #e.hist, math.max(1, #e.hist - 4), -1 do
        local r = e.hist[i]
        if r.k == kind and r.t == text and math.abs(h - (tonumber(r.h) or -1e9)) < 1 then return r end
    end
    -- 0.5.2.7 [pt255u] "sometimes the sentences get clipped out too": rows were cut at 90 characters mid-word with
    -- no "..."; now up to 240 (the timeline wraps), cut at a word with an ellipsis (uiWrap off: the old cut)
    local tx = tostring(text or "")
    if M.settings.uiWrap == false then tx = string.sub(tx, 1, 90)
    elseif #tx > 240 then
        local cut = string.sub(tx, 1, 237)
        local sp = string.find(cut, " [^ ]*$")
        if sp and sp > 180 then cut = string.sub(cut, 1, sp - 1) end
        tx = cut .. "..."
    end
    local row = { h = h, k = kind, t = tx }
    e.hist[#e.hist + 1] = row
    while #e.hist > M.tierCfg.histMax do table.remove(e.hist, 2) end -- keep "First met"
    return row
end
function M.histRows(uid)
    local out = {}
    for _, r in ipairs(M.histOf(uid)) do
        out[#out + 1] = { when = M.gameDate(r.h), kind = r.k, icon = M.histIcons[r.k] or r.k, text = r.t, h = r.h }
    end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- (3) bond tiers + standing
----------------------------------------------------------------------------------------------------------------
local DEFAULT = { tier = 1, pts = 0, ask = {} }
function M.bondOf(uid, create)
    local e = M.pb(uid, create)
    if e == nil then return DEFAULT, nil end
    if type(e.bond) ~= "table" then
        if not create then return DEFAULT, e end
        local h = hours()
        e.bond = { tier = 1, metH = h, lastH = h, pts = 0, ask = {} }
        if M.settings.bondHistory ~= false then
            e.hist = type(e.hist) == "table" and e.hist or {}
            if #e.hist == 0 then e.hist[1] = { h = h, k = "met", t = "First met" } end
        end
    end
    local b = e.bond
    b.ask = type(b.ask) == "table" and b.ask or {}
    b.tier = tonumber(b.tier) or 1
    b.pts = tonumber(b.pts) or 0
    return b, e
end
-- lover tier follows the romance layer (partner = lover; a break-up drops back to the tier before)
function M.bondTier(uid)
    local b, e = M.bondOf(uid, false)
    local t = b.tier or 1
    if e ~= nil and type(e.bond) == "table" then
        local ro = bucket("romance")[tostring(uid)]
        local st = type(ro) == "table" and (ro.stage or 0) or 0
        if st >= 3 and t < 5 then b.prevTier = t; b.tier = 5; t = 5
        elseif st < 3 and t == 5 then t = math.max(2, math.min(4, tonumber(b.prevTier) or 3)); b.tier = t end
    end
    return t
end
function M.tierWord(t) return M.tierNames[clamp(tonumber(t) or 1, 1, 5)] end

-- how well this personality gets on with you (from their make-up; 0.75 .. 1.25)
function M.bondCompat(uid)
    local l = lensOf(uid)
    local k = keyOf(uid)
    local c = 1 + 0.25 * (((l.cheerful or 0) + (l.kind or 0) + (l.romantic or 0)) / 3) - 0.3 * (((l.paranoid or 0) + (l.mean or 0)) / 2)
    if k == "cold" or k == "loner" or k == "paranoid" or k == "bitter" then c = c - 0.1 end
    if k == "gentle" or k == "cheerful" or k == "warm" then c = c + 0.05 end
    return clamp(c, 0.75, 1.25)
end
function M.bondStanding(uid, player)
    player = player or ALifeSide.you()
    local b = M.bondOf(uid, false)
    local v = opinionOf(uid, player) or 0
    local histPart = math.min(45, (b.pts or 0) * 0.6) * M.bondCompat(uid)
    local g = M.grudgeLevel and M.grudgeLevel(uid) or 0
    local s = 0.5 * math.max(0, v) + histPart - g * 0.5
    if v < 0 then s = s + v * 0.5 end
    return clamp(math.floor(s + 0.5), 0, 100), v
end
function M.bondNeed(uid, want)
    local need = M.tierCfg.need[want] or 99
    local l = lensOf(uid)
    local k = keyOf(uid)
    need = need + math.floor((l.paranoid or 0) * 10 - (l.cheerful or 0) * 6 - (l.kind or 0) * 4)
    if k == "cold" or k == "loner" then need = need + 8 end
    return clamp(need, 10, 95)
end
local function daysKnown(b) return math.floor((hours() - (tonumber(b.metH) or hours())) / 24) end
-- points of shared history (time together, saves, gifts, deep talks, danger)
function M.bondPoints(uid, pts, why, opts)
    if M.settings.bondTiers == false and M.settings.bondHistory == false then return end
    opts = opts or {}
    local b = M.bondOf(uid, true)
    if b == nil or b == DEFAULT then return end
    if opts.dailyCap then
        local day = math.floor(hours() / 24)
        b.capDay = b.capDay or {}
        local key = tostring(opts.capKey or why)
        local row = b.capDay[key]
        if type(row) ~= "table" or row.d ~= day then row = { d = day, n = 0 }; b.capDay[key] = row end
        if row.n >= opts.dailyCap then return end
        row.n = row.n + pts
    end
    b.pts = math.min(200, (b.pts or 0) + pts)
    b.lastH = hours()
end
function M.bondContact(uid)
    local e = bucket("book")[tostring(uid)]
    if type(e) == "table" and type(e.bond) == "table" then e.bond.lastH = hours() end
end
function M.bondSeverity(uid) return 1 + 0.3 * (M.bondTier(uid) - 1) end -- betrayal from a close friend cuts deeper

local function setTier(uid, t, why, kind)
    local b = M.bondOf(uid, true)
    local old = M.bondTier(uid)
    t = clamp(t, 1, 5)
    if t == old then return old end
    if t == 5 then b.prevTier = old end
    b.tier = t
    b.changedH = hours()
    M.histAdd(uid, kind or "tier", (why or "Bond") .. ": " .. M.tierWord(old) .. " -> " .. M.tierWord(t))
    if M.logInteraction then pcall(M.logInteraction, uid, (why or "Bond") .. ": " .. M.tierWord(old) .. " -> " .. M.tierWord(t), nil, nil, "bondtier") end
    log("[Bond] " .. tostring(uid) .. " " .. M.tierWord(old) .. " -> " .. M.tierWord(t) .. " (" .. tostring(why) .. ")")
    return t
end
M.bondSetTier = setTier

-- the decision (Lua decides; the AI only voices it). want = 2..4 (5 goes through the romance rules)
function M.bondDecide(uid, want, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    local res = { want = want, ok = false, why = "", awkward = false }
    if M.settings.bondTiers == false then res.why = "off"; return res end
    if M.isFinalDead and M.isFinalDead(uid) then res.why = "they're gone"; return res end
    local b = M.bondOf(uid, true)
    local tier = M.bondTier(uid)
    local h = hours()
    res.standing, res.need = M.bondStanding(uid, player), M.bondNeed(uid, want)
    if tier >= want then res.ok, res.why, res.already = true, "you already are", true; return res end
    if h < (tonumber(b.ask[tostring(want)]) or -1e9) then
        res.why, res.awkward, res.cooldown = "they asked you that not long ago - still no, and it's a little awkward they asked again", true, true
        opAdj(uid, player, -1, "Asked again too soon.")
        return res
    end
    local g = M.grudgeLevel and M.grudgeLevel(uid) or 0
    if g >= 30 then
        res.why = "not after what they did" .. ((M.grudgeOf and M.grudgeOf(uid) and M.grudgeOf(uid).why) and (" (" .. M.grudgeOf(uid).why .. ")") or "")
        b.ask[tostring(want)] = h + M.tierCfg.cooldownH
        return res
    end
    if want > tier + 1 then
        res.why = "too soon: you're not even " .. M.tierWord(want - 1) .. "s yet"
        res.awkward = true
        b.ask[tostring(want)] = h + M.tierCfg.cooldownSoonH
        opAdj(uid, player, -1, "Asked for too much too soon.")
        M.histAdd(uid, "tier", "You asked to be " .. M.tierWord(want) .. "s - too soon")
        return res
    end
    local days = daysKnown(b)
    if res.standing >= res.need and days >= (M.tierCfg.minDays[want] or 0) then
        res.ok = true
        res.why = ({ "", "you like them and trust them enough", "you've been through enough together", "nobody's had your back like them" })[want] or "yes"
        setTier(uid, want, "You asked, they said yes")
        opAdj(uid, player, 2, "Became " .. M.tierWord(want) .. "s.")
        return res
    end
    if res.standing < res.need - 15 then
        res.why, res.awkward = "you barely know them well enough for that", true
        b.ask[tostring(want)] = h + M.tierCfg.cooldownH
        opAdj(uid, player, -1, "Asked too early.")
    elseif days < (M.tierCfg.minDays[want] or 0) then
        res.why = "you like them, but you haven't known them long enough - give it a few days"
        b.ask[tostring(want)] = h + M.tierCfg.cooldownSoonH
    else
        res.why = "you like them, but you're not there yet - a bit more time together"
        b.ask[tostring(want)] = h + M.tierCfg.cooldownSoonH
    end
    M.histAdd(uid, "tier", "You asked to be " .. M.tierWord(want) .. "s - not yet")
    return res
end

-- button state for the next tier (gated by standing; greyed out with a hint)
function M.bondAskState(uid, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    local tier = M.bondTier(uid)
    local out = { tier = tier, word = M.tierWord(tier) }
    local b = M.bondOf(uid, false)
    local h = hours()
    local l = listenerOf(uid)
    local here = l ~= nil and player ~= nil and distTo(l, player) <= M.tierCfg.askTiles
    local radio = M.radio ~= nil and tostring(M.radio.uid) == uid
    local st = M.bondStanding(uid, player)
    out.standing = st
    if M.settings.bondTiers == false then out.off = true; return out end
    local dead = (M.isFinalDead and M.isFinalDead(uid)) or (bucket("book")[uid] and bucket("book")[uid].dead)
    local function gate(want, label)
        local s = { want = want, label = label, enabled = true, hint = "" }
        local need = M.bondNeed(uid, want)
        s.need = need
        if dead then s.enabled, s.hint = false, "They're gone."
        elseif not (here or radio) then s.enabled, s.hint = false, "They need to be here (or on the radio)."
        elseif h < (tonumber(b.ask[tostring(want)]) or -1e9) then
            s.enabled, s.hint = false, "You asked recently - wait " .. math.ceil(tonumber(b.ask[tostring(want)]) - h) .. " h."
        elseif want == 5 then
            local ro = bucket("romance")[uid]
            local stg = type(ro) == "table" and (ro.stage or 0) or 0
            if M.settings.romance == false then s.enabled, s.hint = false, "Romance is off in the settings."
            elseif stg < 2 then s.enabled, s.hint = false, "They'd need real feelings for you first."
            elseif tier < 2 then s.enabled, s.hint = false, "Be friends first." end
        elseif st < need then s.enabled, s.hint = false, "Not close enough yet (standing " .. st .. " / " .. need .. ")."
        elseif daysKnown(b) < (M.tierCfg.minDays[want] or 0) then s.enabled, s.hint = false, "Known them " .. daysKnown(b) .. " of " .. M.tierCfg.minDays[want] .. " days." end
        if s.enabled then s.hint = "Ask them." end
        return s
    end
    if tier < 4 then out.ask = gate(tier + 1, ({ "Ask to be friends", "Ask to be close friends", "Ask to be best friends" })[tier]) end
    if tier < 5 then out.together = gate(5, "Ask to be together") end
    out.stepBack = { enabled = tier > 1 and not dead and (here or radio), label = "Step back",
        hint = tier <= 1 and "Nothing to step back from." or ((here or radio) and ("Go back to " .. M.tierWord(tier == 5 and (b.prevTier or 4) or tier - 1) .. ".") or "They need to be here (or on the radio).") }
    if tier > 1 and h < (tonumber(b.stepH) or -1e9) then out.stepBack.enabled, out.stepBack.hint = false, "You just did." end
    local sev = M.apologySeverity(uid, player)
    out.apologize = { enabled = not dead and (here or radio) and h >= (tonumber(b.apolH) or -1e9), label = "Apologize",
        hint = sev <= 0 and "Nothing to apologize for right now (they'll say so)." or ("Say sorry (" .. (sev >= 50 and "they're badly hurt" or (sev >= 20 and "they're upset" or "small thing")) .. ").") }
    if h < (tonumber(b.apolH) or -1e9) then
        out.apologize.hint = "You already apologized - give it time (" .. tostring(math.max(1, math.ceil((tonumber(b.apolH) or h) - h))) .. "h)."
        out.apologize.cooldown = true
    end
    -- 0.5.2.7 [pt255u] "the apologize thing doesnt work": with nothing to forgive the button now says so and is
    -- dimmed (fixApology off: the old always-on button); dead / away get their own reason
    if M.settings.fixApology ~= false and sev <= 0 and out.apologize.enabled then
        out.apologize.enabled, out.apologize.nothing = false, true
        out.apologize.hint = "Nothing to apologize for - they aren't upset with you (no grudge, no recent hurt)."
    end
    if dead then out.apologize.enabled, out.apologize.hint = false, "They're gone. It's too late to say sorry." end
    if not (here or radio) and not dead then out.apologize.hint = "They need to be here (or on the radio)." end
    return out
end

-- step back a tier: an NPC reaction by personality (never counted as a betrayal)
function M.bondStepBack(uid, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    if M.settings.bondTiers == false then return nil end
    local b = M.bondOf(uid, true)
    local tier = M.bondTier(uid)
    if tier <= 1 then return { changed = false, react = "none" } end
    local to = tier - 1
    if tier == 5 then
        to = clamp(tonumber(b.prevTier) or 4, 2, 4)
        local ro = bucket("romance")[uid]
        if type(ro) == "table" then ro.stage, ro.since = 1, nil end -- fond of you, no heartbreak flag
    end
    local l = lensOf(uid)
    local react, d = "accepts", -1
    if (l.romantic or 0) + (l.kind or 0) >= 0.3 and tier >= 3 then react, d = "hurt", -3
    elseif (l.volatile or 0) >= 0.25 or (l.proud or 0) >= 0.25 then react, d = "stung", -2
    elseif (l.calm or 0) >= 0.25 or keyOf(uid) == "cold" or keyOf(uid) == "stoic" then react, d = "shrugs", 0 end
    setTier(uid, to, "You stepped back")
    b.ask[tostring(tier)] = hours() + M.tierCfg.cooldownH
    b.stepH = hours() + M.tierCfg.stepCdH
    if d ~= 0 then opAdj(uid, player, d, "You stepped back from them.") end
    return { changed = true, from = tier, to = to, react = react, d = d }
end

-- apology: how bad it is (grudge, nemesis, recent losses of opinion)
function M.apologySeverity(uid, player)
    uid = tostring(uid)
    local sev = M.grudgeLevel and M.grudgeLevel(uid) or 0
    local n = bucket("nemesis")[uid]
    if type(n) == "table" then sev = math.max(sev, (tonumber(n.g) or 0) * 0.6) end
    local rows = M.interactionsOf and M.interactionsOf(uid) or {}
    local neg = 0
    for i = #rows, math.max(1, #rows - 8), -1 do
        local r = rows[i]
        if type(r) == "table" and r.a and r.b and r.b < r.a then neg = neg + (r.a - r.b) end
    end
    return math.floor(math.max(sev, neg * 0.8))
end
function M.bondApologize(uid, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    local b = M.bondOf(uid, true)
    local h = hours()
    local res = { ok = false, why = "", sev = M.apologySeverity(uid, player) }
    if h < (tonumber(b.apolH) or -1e9) then res.why, res.cooldown = "they already apologized; words alone won't fix it faster", true; return res end
    -- 0.5.2.7 [pt255u]: "nothing to forgive" no longer starts the 12 h cooldown (it used to lock the button for half
    -- a day, so a real apology right after a fight was refused with "give it time" - the reported bug)
    if res.sev <= 0 then
        res.ok, res.why, res.nothing = true, "there's nothing to forgive", true
        if M.settings.fixApology == false then b.apolH = h + M.tierCfg.apolCdH end
        return res
    end
    b.apolH = h + M.tierCfg.apolCdH
    local m, l = modsOf(uid), lensOf(uid)
    local score = (tonumber(m.forgive) or 0.5) * 60 + (l.kind or 0) * 20 + (l.devout or 0) * 10 + (M.bondTier(uid) - 1) * 6
        - res.sev * 0.6 - (l.proud or 0) * 15 - (l.volatile or 0) * 10 - (l.mean or 0) * 10
    res.score = math.floor(score)
    local g = M.grudgeOf and M.grudgeOf(uid) or nil
    if score >= 20 then
        res.ok = true
        res.why = res.sev >= 50 and "it doesn't undo it, but you believe they mean it" or "you appreciate them saying it"
        if g then g.v = math.max(0, (g.v or 0) * 0.45 - 5); g.apolH = h; if g.v < 8 then M.grudgeSettle(uid, "apology") end end
        local n = bucket("nemesis")[uid]
        if type(n) == "table" then n.g = math.max(0, (tonumber(n.g) or 0) - 25) end
        opAdj(uid, player, math.min(8, math.max(2, math.floor(res.sev / 6))), "You apologized.")
        M.histAdd(uid, "apology", "You apologized - they accepted")
        M.bondPoints(uid, 2, "apology")
        res.d = math.min(8, math.max(2, math.floor(res.sev / 6)))
    else
        res.why = res.sev >= 50 and "sorry doesn't cover it - not after that" or "you're not ready to let it go yet"
        if g then g.v = math.max(0, (g.v or 0) - 5) end
        -- 0.5.2.7: a refused apology still counts a little (they heard it)
        if M.settings.fixApology ~= false then opAdj(uid, player, 1, "You apologized (not accepted yet)."); res.d = 1 end
        M.histAdd(uid, "apology", "You apologized - they weren't ready")
    end
    return res
end

----------------------------------------------------------------------------------------------------------------
-- (5d) likes and dislikes (seeded once from personality + backstory; "???" until learned)
----------------------------------------------------------------------------------------------------------------
M.likePools = {
    smoke = { { "Lucky Strikes" }, { "Camels" }, { "Marlboro Reds" }, { "hand-rolled tobacco" }, { "menthols" } },
    drink = { { "cheap beer", { "beer" } }, { "whiskey", { "whiskey", "bourbon", "scotch" } }, { "red wine", { "wine" } },
        { "vodka", { "vodka" } }, { "rum", { "rum" } } },
    food = { { "chocolate", { "chocolate" } }, { "canned peaches", { "peach" } }, { "peanut butter", { "peanut" } },
        { "potato chips", { "crisps", "chips" } }, { "coffee", { "coffee" } }, { "beef jerky", { "jerky" } },
        { "soda pop", { "pop", "soda", "cola" } }, { "candy", { "candy", "mint", "gum", "lollipop" } }, { "canned chili", { "chili" } },
        { "cereal", { "cereal" } }, { "crackers", { "cracker" } }, { "honey", { "honey" } } },
    foodBad = { { "sardines", { "sardine" } }, { "canned tuna", { "tuna" } }, { "beans", { "beans" } }, { "Spam", { "spam" } },
        { "dog food", { "dogfood", "dog food" } }, { "pickles", { "pickle" } } },
    peeve = {
        noise = { "loud noise", {} }, cowardice = { "cowardice", { "run away", "let's run", "lets run", "i'm scared", "im scared", "leave them" } },
        swearing = { "swearing", { "fuck", "shit", "bitch", "bastard", "asshole", "goddamn" } },
        whining = { "whining", { "this sucks", "i give up", "i can't do this", "so tired of this", "i hate this" } },
        rudeness = { "rudeness", {} }, lying = { "liars", {} }, waste = { "waste", {} }, filth = { "filth", {} },
    },
}
local SMOKE_KEYS = { "cigarette", "cigar", "tobacco", "smoke" }
local BOOZE_KEYS = { "beer", "whiskey", "wine", "vodka", "rum", "gin", "bourbon", "scotch", "liquor", "alcohol", "booze" }
M.smokerKeys = { hothead = true, bitter = true, drifter = true, hardass = true, haunted = true, sour = true }
M.drinkerKeys = { hedonist = true, sour = true, haunted = true, depressive = true, bitter = true }
-- habits (shared with Habits.lua): smoker / drinker / teetotal, stable per person
function M.habitOf(uid)
    uid = tostring(uid)
    local e = M.pb(uid, false)
    if type(e) == "table" and type(e.habit) == "table" and e.habit.v == 1 then return e.habit end
    local l, k = lensOf(uid), keyOf(uid)
    local hb = { v = 1 }
    local hs = hash(uid .. "#smoke") % 100
    hb.smoker = M.smokerKeys[k] == true or hs < 18 + math.floor(((l.volatile or 0) + (l.gloomy or 0)) * 15)
    local hd = hash(uid .. "#drink") % 100
    hb.drinker = M.drinkerKeys[k] == true or hd < 16 + math.floor(((l.gloomy or 0) + (l.cheerful or 0)) * 10)
    hb.teetotal = not hb.drinker and ((l.devout or 0) >= 0.2 or (l.disciplined or 0) >= 0.25 or hd >= 88)
    if e ~= nil then e.habit = hb end
    return hb
end
local function persona(uid)
    local row = nil
    pcall(function() row = M.personaOf and M.personaOf(uid) or nil end)
    return type(row) == "table" and row or {}
end
function M.likesOf(uid, create)
    uid = tostring(uid)
    local e = M.pb(uid, create)
    if e == nil then return nil end
    if type(e.likes) == "table" and type(e.likes.list) == "table" then return e.likes end
    if not create then return nil end
    local l = lensOf(uid)
    local hb = M.habitOf(uid)
    local list = {}
    local function add(c, label, keys, like) list[#list + 1] = { c = c, label = label, keys = keys or {}, like = like, known = false } end
    if hb.smoker then local s = pick(M.likePools.smoke, uid .. "#brand"); add("smoke", s[1], SMOKE_KEYS, true)
    elseif hash(uid .. "#nosmoke") % 2 == 0 then add("peeve", "cigarette smoke", SMOKE_KEYS, false) end
    if hb.drinker then local d = pick(M.likePools.drink, uid .. "#drinkb"); add("drink", d[1], d[2], true)
    elseif hb.teetotal then add("drink", "booze (doesn't drink)", BOOZE_KEYS, false) end
    local f1 = pick(M.likePools.food, uid .. "#f1")
    add("food", f1[1], f1[2], true)
    local f2 = pick(M.likePools.food, uid .. "#f2")
    if f2[1] ~= f1[1] then add("food", f2[1], f2[2], true) end
    local fb = pick(M.likePools.foodBad, uid .. "#fb")
    add("food", fb[1], fb[2], false)
    -- pet peeves: personality first, then what their backstory says they can't stand
    local score = {
        noise = (l.paranoid or 0) + (l.fearful or 0), cowardice = (l.brave or 0) + (l.proud or 0) + (l.volatile or 0) * 0.5,
        swearing = (l.devout or 0) * 1.5 + (l.kind or 0) * 0.5 + (l.disciplined or 0) * 0.5, whining = (l.disciplined or 0) + (l.mean or 0) * 0.5,
        rudeness = (l.proud or 0) + (l.kind or 0) * 0.5, lying = (l.loyal or 0) + (l.paranoid or 0) * 0.5,
        waste = (l.greedy or 0) + (l.disciplined or 0) * 0.5, filth = (l.disciplined or 0) * 0.7 + 0.1,
    }
    local dis = string.lower(tostring(persona(uid).dislikes or ""))
    for key, words in pairs({ cowardice = { "coward" }, lying = { "liar", "lying", "lie" }, noise = { "noise", "loud" }, whining = { "whin", "complain" },
        rudeness = { "rude", "talked down", "disrespect" }, waste = { "waste" }, filth = { "dirt", "filth", "mess" }, swearing = { "swear", "cursing" } }) do
        for _, w in ipairs(words) do if string.find(dis, w, 1, true) then score[key] = score[key] + 2 end end
    end
    local keys = {}
    for kk in pairs(score) do keys[#keys + 1] = kk end
    table.sort(keys, function(a, b) if score[a] ~= score[b] then return score[a] > score[b] end return a < b end)
    local n = 1 + hash(uid .. "#peeves") % 2
    for i = 1, n do
        local p = M.likePools.peeve[keys[i]]
        if p then list[#list + 1] = { c = "peeve", id = keys[i], label = p[1], keys = p[2], like = false, known = false } end
    end
    e.likes = { list = list, v = 1 }
    return e.likes
end
local function itemHits(item, info)
    local hay = string.lower(tostring(info.name or "") .. " " .. tostring(info.fullType or "") .. " " .. tostring(info.kind or ""))
    if item.c == "drink" and item.like == false and info.kind == "alcohol" then return true end
    if item.c == "drink" and item.like == true and info.kind == "alcohol" and #item.keys == 0 then return true end
    for _, k in ipairs(item.keys or {}) do if k ~= "" and string.find(hay, k, 1, true) then return true end end
    return false
end
function M.likeLearn(uid, item, how)
    if item == nil or item.known then return false end
    item.known, item.how, item.knownH = true, how, hours()
    M.histAdd(uid, "likes", "Learned they " .. (item.like and "like " or "can't stand ") .. item.label .. " (" .. tostring(how) .. ")")
    return true
end
-- a gift: did it hit a like / dislike? (reveals it; small opinion bonus / malus)
M.likeHit = {}
function M.likesOnGift(uid, info, player)
    if M.settings.bondLikes == false or type(info) ~= "table" then return nil end
    local lk = M.likesOf(uid, true)
    if lk == nil then return nil end
    for _, it in ipairs(lk.list) do
        if it.c ~= "peeve" or #(it.keys or {}) > 0 then
            if itemHits(it, info) then
                M.likeLearn(uid, it, "how they took your gift")
                opAdj(uid, player, it.like and 4 or -3, it.like and ("They love " .. it.label .. ".") or ("They can't stand " .. it.label .. "."))
                M.likeHit[tostring(uid)] = { label = it.label, like = it.like, at = nowMs() }
                return it
            end
        end
    end
    return nil
end
function M.likesShown(uid)
    local lk = M.likesOf(uid, false)
    local out = { likes = {}, dislikes = {} }
    if lk == nil then return out end
    for _, it in ipairs(lk.list) do
        local row = { label = it.known and it.label or "???", known = it.known, c = it.c, how = it.how }
        if it.like then out.likes[#out.likes + 1] = row else out.dislikes[#out.dislikes + 1] = row end
    end
    return out
end
-- 0.5.2.8 [pt265u]: "he never said he likes chocolate". A like is learned only when the NPC's spoken line really names
-- it (word-start match on the label's main word or a key; "chocolate bars" -> "chocolate", "Lucky Strikes" -> "strik").
local LIKE_STOP = { ["with"] = true, ["from"] = true, ["that"] = true, ["some"] = true, ["good"] = true, ["fresh"] = true, ["cold"] = true,
    ["doesn"] = true, ["drink"] = true, ["people"] = true, ["anything"] = true, ["things"] = true, ["their"] = true, ["other"] = true }
local function likeStem(w)
    if #w <= 5 then return w end
    if string.sub(w, -3) == "ies" then return string.sub(w, 1, #w - 3) end
    return string.sub(w, 1, math.max(5, #w - 2))
end
local function wordsOf(text)
    local out = {}
    for w in string.gmatch(string.lower(tostring(text or "")), "%a+") do out[#out + 1] = w end
    return out
end
-- the stems that count as "naming" this item
function M.likeStems(item)
    local best = nil
    for _, w in ipairs(wordsOf(item.label)) do
        if #w >= 4 and not LIKE_STOP[w] and (best == nil or #w > #best) then best = w end
    end
    local out = {}
    if best then out[#out + 1] = likeStem(best) end
    for _, k in ipairs(item.keys or {}) do
        local kw = string.lower(tostring(k))
        if #kw >= 5 and not string.find(kw, "[^%a]") then out[#out + 1] = likeStem(kw) end
    end
    return out
end
-- does this spoken text name the item?
function M.likeSaid(item, text)
    if type(item) ~= "table" or type(text) ~= "string" then return false end
    local stems = M.likeStems(item)
    if #stems == 0 then return false end
    for _, w in ipairs(wordsOf(text)) do
        for _, st in ipairs(stems) do
            if #w >= #st and string.sub(w, 1, #st) == st then return true end
        end
    end
    return false
end
-- the next unknown like (or dislike) WITHOUT learning it: the candidate the prompt asks them to talk about
function M.likesCandidate(uid, wantDislike)
    local lk = M.likesOf(uid, true)
    if lk == nil then return nil end
    for pass = 1, 2 do
        for _, it in ipairs(lk.list) do
            local side = (pass == 1) == (wantDislike == true)
            if not it.known and ((side and not it.like) or (not side and it.like)) then return it end
        end
    end
    return nil
end
-- their persona hobby ("into Bible verses"): a like they may name even though it is not on the food/smoke/drink list
function M.likeQuirk(uid)
    local ok, h = pcall(function()
        local row = M.personaOf and M.personaOf(uid) or nil
        local pp = row and M.personaParts and M.personaParts(row) or nil
        if pp == nil or pp.entry == nil or pp.entry.qk == "fear" then return nil end
        local q = tostring(pp.quirk or "")
        return string.match(q, "^into (.+)$")
    end)
    return ok and h or nil
end
-- a spoken NPC line: learn what it names. Right after "what do you like?" it counts as "they told you"; a quirk hobby
-- they name then becomes a learned like too. Without the question, only the list items ("they mentioned it").
M.likeAsk = M.likeAsk or {}
function M.likesOnLine(uid, text, now)
    if M.settings.bondLikes == false or uid == nil or type(text) ~= "string" or text == "" then return nil end
    uid = tostring(uid)
    now = now or nowMs()
    local ask = M.likeAsk[uid]
    if ask and now - (ask.at or 0) > 30000 then M.likeAsk[uid] = nil; ask = nil end
    local lk = M.likesOf(uid, ask ~= nil)
    if lk == nil then return nil end
    local got = nil
    for _, it in ipairs(lk.list) do
        if not it.known and (it.c ~= "peeve" or (ask and ask.dislike)) and M.likeSaid(it, text) then
            M.likeLearn(uid, it, ask and "they told you" or "they mentioned it")
            got = got or it
        end
    end
    if got == nil and ask and not ask.dislike then
        local hobby = M.likeQuirk(uid)
        if hobby then
            local qi = { c = "quirk", label = hobby, keys = {}, like = true, known = false }
            local have = false
            for _, it in ipairs(lk.list) do if it.c == "quirk" and it.label == hobby then have = true end end
            if not have and M.likeSaid(qi, text) then
                lk.list[#lk.list + 1] = qi
                M.likeLearn(uid, qi, "they told you")
                got = qi
            end
        end
    end
    if got then M.likeAsk[uid] = nil end
    return got
end
-- "what do you like?" -> reveal the next unknown (likes first; "what bugs you" -> dislikes)
function M.likesReveal(uid, wantDislike, how)
    local lk = M.likesOf(uid, true)
    if lk == nil then return nil end
    for pass = 1, 2 do
        for _, it in ipairs(lk.list) do
            local side = (pass == 1) == (wantDislike == true)
            if not it.known and ((side and not it.like) or (not side and it.like)) then
                M.likeLearn(uid, it, how or "they told you")
                return it
            end
        end
    end
    return nil
end
-- something the player said hits a pet peeve
function M.likesPeeveWords(uid, low)
    local lk = M.likesOf(uid, false)
    if lk == nil then return nil end
    for _, it in ipairs(lk.list) do
        if it.c == "peeve" and it.id ~= nil then
            for _, k in ipairs(it.keys or {}) do if string.find(low, k, 1, true) then return it end end
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- (5c) what they think of you: one cached first-person line (regenerated on a real change or every few days)
----------------------------------------------------------------------------------------------------------------
M.thoughtLines = {
    { "I don't know them well enough to say.", "They seem alright. Time will tell.", "Can't figure them out yet." },
    { "I like having them around.", "They're good people, I think.", "I'd call them a friend now." },
    { "I trust them. That's not nothing these days.", "They've been there for me.", "We've been through some things." },
    { "I'd take a bullet for them.", "Best friend I've had since all this started.", "Can't imagine this without them." },
    { "I love them. Simple as that.", "When they're gone too long I get scared.", "They're my person." },
}
M.thoughtBad = { "I don't trust them.", "Stay away from me.", "After what they did? Nothing nice to say." }
function M.thoughtFallback(uid, st, tier)
    local g = M.grudgeLevel and M.grudgeLevel(uid) or 0
    if g >= 30 or (st or 0) <= 0 and (opinionOf(uid, ALifeSide.you()) or 0) < -15 then return pick(M.thoughtBad, uid .. "#tb") end
    return pick(M.thoughtLines[clamp(tier or 1, 1, 5)], uid .. "#t" .. tostring(tier))
end
function M.thoughtOf(uid)
    local e = bucket("book")[tostring(uid)]
    local th = type(e) == "table" and e.thought or nil
    if type(th) == "table" and type(th.text) == "string" and th.text ~= "" then
        if M.settings.pronounFix ~= false then return M.fixPronouns(th.text, M.playerSex()), th end -- 0.5.2.5: old saves too
        return th.text, th
    end
    return M.thoughtFallback(uid, M.bondStanding(uid), M.bondTier(uid)), nil
end
function M.thoughtStale(uid, player)
    local e = bucket("book")[tostring(uid)]
    local th = type(e) == "table" and e.thought or nil
    if type(th) ~= "table" or th.fallback then return true, "none" end
    local st = M.bondStanding(uid, player)
    if math.abs(st - (tonumber(th.st) or 0)) >= M.tierCfg.thoughtDelta then return true, "standing" end
    if (th.tier or 1) ~= M.bondTier(uid) then return true, "tier" end
    if hours() - (tonumber(th.h) or 0) >= M.tierCfg.thoughtDays * 24 then return true, "days" end
    return false, nil
end
----------------------------------------------------------------------------------------------------------------
-- 0.5.2.5 [pt252u]: pronoun clean-up for lines ABOUT the player ("they've been around long enough to not get
-- himself killed"). Uses the player's gender: wrong-gender forms are swapped, and singular "they" forms mixed with
-- gendered ones are made gendered (with the verb: "they've" -> "he's", "they seem" -> "he seems"). A line that only
-- uses "they" is left alone. Same rules as fix_pronouns() in the bridge. Off: pronounFix = false.
----------------------------------------------------------------------------------------------------------------
M.pronounSets = {
    m = { he = "he", him = "him", his = "his", himself = "himself", hers = "his", ["he's"] = "he's", ["he'd"] = "he'd", ["he'll"] = "he'll" },
    f = { he = "she", him = "her", his = "her", himself = "herself", hers = "hers", ["he's"] = "she's", ["he'd"] = "she'd", ["he'll"] = "she'll" },
}
local P_MALE = { he = "he", him = "him", his = "his", himself = "himself", ["he's"] = "he's", ["he'd"] = "he'd", ["he'll"] = "he'll" }
local P_FEM = { she = "he", her = "her*", hers = "hers", herself = "himself", ["she's"] = "he's", ["she'd"] = "he'd", ["she'll"] = "he'll" }
local P_THEY = { they = "he", them = "him", their = "his", theirs = "hers", themselves = "himself", themself = "himself",
    ["they're"] = "he's", ["they've"] = "he's", ["they'd"] = "he'd", ["they'll"] = "he'll" }
local P_VERB = { are = "is", were = "was", have = "has", ["do"] = "does", ["don't"] = "doesn't", ["aren't"] = "isn't", ["weren't"] = "wasn't",
    ["haven't"] = "hasn't", go = "goes", try = "tries", carry = "carries", watch = "watches", catch = "catches", fix = "fixes", miss = "misses" }
local P_BASE = { "seem", "look", "know", "think", "want", "need", "say", "keep", "act", "talk", "come", "mean", "get", "make", "take",
    "pull", "help", "work", "listen", "fight", "shoot", "run", "walk", "stick", "hold", "show", "care", "remind", "sound", "feel", "like",
    "deserve", "earn", "owe", "pay", "handle", "move", "smile", "laugh", "stay", "leave", "give", "bring", "hide", "lie", "tell", "ask" }
for _, v in ipairs(P_BASE) do P_VERB[v] = v .. "s" end
local P_ADV = { just = true, really = true, never = true, always = true, still = true, probably = true, sure = true, actually = true,
    clearly = true, obviously = true, only = true, also = true, ["don't"] = false }
local P_NOTNOUN = { ["and"] = true, ["or"] = true, but = true, to = true, up = true, out = true, off = true, ["in"] = true, on = true,
    at = true, ["for"] = true, with = true, again = true, now = true, yet = true, too = true, down = true, alone = true, back = true,
    go = true, be = true, the = true, a = true, an = true, is = true, was = true, so = true, much = true, here = true, there = true }
local function pCase(orig, rep)
    if string.sub(orig, 1, 1) ~= string.lower(string.sub(orig, 1, 1)) then return string.upper(string.sub(rep, 1, 1)) .. string.sub(rep, 2) end
    return rep
end
function M.fixPronouns(text, sex)
    if type(text) ~= "string" or (sex ~= "m" and sex ~= "f") then return text end
    local toks, i, n = {}, 1, #text
    while i <= n do
        local a, b = string.find(text, "^[%a']+", i)
        if a then toks[#toks + 1] = { s = string.sub(text, a, b), w = true }
        else a, b = string.find(text, "^[^%a']+", i); toks[#toks + 1] = { s = string.sub(text, a, b) } end
        i = b + 1
    end
    local own, other = (sex == "m") and P_MALE or P_FEM, (sex == "m") and P_FEM or P_MALE
    local hasOwn, hasOther, hasThey, group = false, false, false, false
    local words = {}
    for k, t in ipairs(toks) do
        if t.w then
            local lw = string.lower(t.s)
            words[#words + 1] = k
            if own[lw] then hasOwn = true elseif other[lw] then hasOther = true elseif P_THEY[lw] then hasThey = true end
            if lw == "all" or lw == "both" or lw == "people" or lw == "folks" then group = true end
        end
    end
    if not (hasOwn or hasOther) then return text end -- only "they" (or none): leave it
    local S = M.pronounSets[sex]
    local function nextWord(wi) local k = words[wi + 1]; return k and string.lower(toks[k].s) or nil, k end
    local changed = false
    for wi, k in ipairs(words) do
        local t = toks[k]
        local lw = string.lower(t.s)
        local rep = nil
        if hasOther and other[lw] then
            local base = other[lw]
            if sex == "m" then
                if base == "her*" then local nw = nextWord(wi); base = (nw ~= nil and not P_NOTNOUN[nw] and not P_VERB[nw]) and "his" or "him" end
                rep = S[base] or base
            else
                if lw == "his" then local nw = nextWord(wi); rep = (nw == nil or P_NOTNOUN[nw]) and "hers" or "her"
                else rep = S[lw] or lw end
            end
        elseif hasThey and not group and P_THEY[lw] then
            rep = S[P_THEY[lw]] or P_THEY[lw]
            if lw == "they" then -- verb agreement: they are -> he is, they seem -> he seems (skipping "just", "really" ...)
                local j = wi + 1
                while words[j] and P_ADV[string.lower(toks[words[j]].s)] do j = j + 1 end
                local vk = words[j]
                if vk then
                    local vw = string.lower(toks[vk].s)
                    if P_VERB[vw] then toks[vk].s = pCase(toks[vk].s, P_VERB[vw]) end
                end
            end
        end
        if rep and rep ~= lw then t.s = pCase(t.s, rep); changed = true end
    end
    if not changed then return text end
    local out = {}
    for _, t in ipairs(toks) do out[#out + 1] = t.s end
    return table.concat(out)
end
function M.playerSex(player)
    local sx = nil
    player = player or ALifeSide.you()
    pcall(function() if player ~= nil then sx = player:isFemale() and "f" or "m" end end)
    return sx
end

M.thoughtGen = 0
function M.thoughtRefresh(uid, player)
    if M.settings.bondThought == false then return false end
    uid = tostring(uid)
    player = player or ALifeSide.you()
    local stale = M.thoughtStale(uid, player)
    if not stale then return false end
    local e = M.pb(uid, false)
    if e == nil then return false end
    local st, tier = M.bondStanding(uid, player), M.bondTier(uid)
    if type(e.thought) ~= "table" then e.thought = { text = M.thoughtFallback(uid, st, tier), h = hours(), st = st, tier = tier, fallback = true } end
    local l = listenerOf(uid)
    if l == nil or player == nil or not (M.bridgeAlive and M.bridgeAlive(nowMs())) then return false end
    local hist = M.histOf(uid)
    local bits = {}
    for i = #hist, math.max(1, #hist - 3), -1 do bits[#bits + 1] = hist[i].t end
    local sx = M.settings.pronounFix ~= false and M.playerSex(player) or nil
    local pr = sx == "f" and "her" or (sx == "m" and "him" or "them")
    local what = "Someone asks what you honestly think of the newcomer right now. You see " .. pr .. " as your " .. M.tierWord(tier)
        .. " (standing " .. st .. "/100)" .. (#bits > 0 and ("; lately: " .. table.concat(bits, "; ")) or "")
    local ok = M.react("thought", l, player, { what = what, maxWords = 28, fallback = e.thought.text },
        { key = "thought:" .. uid, keyCooldownMs = 600000, modeCooldownMs = 20000, urgent = true, onDone = function(job, r)
            local text = type(r) == "table" and r.text or nil
            if type(text) == "string" and text ~= "" then
                if sx then text = M.fixPronouns(text, sx) end
                e.thought = { text = string.sub(text, 1, 200), h = hours(), st = st, tier = tier }
                M.thoughtGen = M.thoughtGen + 1
            end
        end })
    return ok
end

----------------------------------------------------------------------------------------------------------------
-- speech: "wanna be friends", "best friends?", "be with me" (romance), "let's just be friends", "sorry", "what do you like?"
----------------------------------------------------------------------------------------------------------------
M.bondWords = {
    best = { "best friends", "best friend", "my best bud", "bestie" },
    close = { "close friends", "closer friends", "real friends", "good friends now" },
    friends = { "be friends", "be my friend", "wanna be friends", "want to be friends", "we friends", "are we friends", "we're friends now", "friends now?" },
    step = { "just friends", "take a step back", "step back from", "cool it", "need some space", "slow things down", "only friends" },
    sorry = { "i'm sorry", "im sorry", "i am sorry", "i apologize", "my bad", "forgive me", "sorry about", "sorry for", "i was wrong" },
    likes = { "what do you like", "what you like", "your favorite", "your favourite", "what do you enjoy", "what are you into", "what's your poison" },
    dislikes = { "what do you hate", "what bugs you", "what annoys you", "pet peeve", "what can't you stand", "what do you not like" },
}
local function has(low, list) for _, w in ipairs(list) do if string.find(low, w, 1, true) then return true end end return false end
M.bondPending = {}
local function neg(low) return has(low, { "don't want to be", "dont want to be", "not friends", "never be friends", "aren't friends" }) end
function M.bondOnWords(player, text, loud, hearers)
    if M.settings.enabled == false then return end
    local low = " " .. string.lower(tostring(text or "")) .. " "
    local l = hearers and hearers[1] or nil
    if l == nil or l.record == nil then return end
    local uid = tostring(l.record.uid)
    local now = nowMs()
    local p = nil
    M.bondContact(uid)
    if M.settings.bondTiers ~= false and not neg(low) then
        local want = nil
        if has(low, M.bondWords.step) and M.bondTier(uid) > 1 then
            local r = M.bondStepBack(uid, player)
            if r and r.changed then p = { kind = "step", react = r.react, from = M.tierWord(r.from), to = M.tierWord(r.to) } end
        elseif has(low, M.bondWords.best) then want = 4
        elseif has(low, M.bondWords.close) then want = 3
        elseif has(low, M.bondWords.friends) then want = 2 end
        if want then
            local r = M.bondDecide(uid, want, player)
            p = { kind = "ask", want = M.tierWord(want), ok = r.ok, why = r.why, awkward = r.awkward, already = r.already }
        end
    end
    if p == nil and has(low, M.bondWords.sorry) then
        local r = M.bondApologize(uid, player)
        if r and (not r.nothing or M.settings.fixApology ~= false) then p = { kind = "apology", ok = r.ok, why = r.why, nothing = r.nothing, cooldown = r.cooldown } end
    end
    if M.settings.bondLikes ~= false then
        local hit = M.likesPeeveWords(uid, low)
        if hit then
            M.likeLearn(uid, hit, "you hit a nerve")
            opAdj(uid, player, -1, "They can't stand " .. hit.label .. ".")
            p = p or {}
            p.peeve = hit.label
        end
        if has(low, M.bondWords.likes) or has(low, M.bondWords.dislikes) then
            local dis = has(low, M.bondWords.dislikes)
            p = p or {}
            if M.settings.likesSaidOnly ~= false then
                -- 0.5.2.8 [pt265u]: only a candidate; it is learned when their reply really names it (M.likesOnLine)
                local it = M.likesCandidate(uid, dis)
                M.likeAsk[uid] = { at = now, dislike = dis or nil, cand = it and it.label or nil }
                p.reveal = it and { label = it.label, like = it.like, pending = true } or { none = true }
            else
                local it = M.likesReveal(uid, dis, "they told you")
                p.reveal = it and { label = it.label, like = it.like } or { none = true }
            end
        end
    end
    if p then
        p.at = now
        M.bondPending[uid] = p
        -- no bridge: a stock answer right away (the AI voices it otherwise, in the reply)
        if not (M.bridgeAlive and M.bridgeAlive(now)) and M.say and l.shell then
            M.say(l.shell, player, M.bondStock(uid, p), { record = l.record })
        end
    end
end
function M.bondStock(uid, p)
    if p.kind == "ask" then
        if p.already then return "We already are, dummy." end
        if p.ok then return pick({ "Yeah. Yeah, I'd like that.", "Took you long enough. Yes.", "Sure. I mean it." }, uid .. "#y") end
        if p.awkward then return pick({ "Uh... let's not rush it.", "That's... a bit much right now.", "Ask me again some other time." }, uid .. "#aw") end
        return pick({ "Not yet. Give it time.", "Maybe one day. Not today.", "I like you. Just... not there yet." }, uid .. "#n")
    elseif p.kind == "step" then
        return ({ hurt = "Oh. Okay... if that's what you want.", stung = "Fine. Whatever you say.", shrugs = "Sure. No problem.", accepts = "Alright. I get it." })[p.react] or "Alright."
    elseif p.kind == "apology" then
        if p.nothing then return "Sorry? For what? We're good." end
        if p.cooldown then return "I heard you the first time." end
        return p.ok and "...Okay. I hear you. Thanks for saying it." or "Sorry doesn't cut it. Not yet."
    end
    if p.reveal then
        if p.reveal.none then return "You already know what I'm like." end
        return (p.reveal.like and "Honestly? " or "Can't stand ") .. p.reveal.label .. "."
    end
    if p.peeve then return "Do you have to?" end
    return "Hm."
end

-- prompt: tier, standing, the pending answer, recent history, what they like (only what's known to the player... they know themselves)
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.bondTiers == false and M.settings.bondLikes == false and M.settings.bondHistory == false then return end
    local uid = tostring(listener.record.uid)
    local e = bucket("book")[uid]
    if type(e) ~= "table" then return end
    local bd = {}
    if M.settings.bondTiers ~= false then bd.tier = M.tierWord(M.bondTier(uid)); bd.standing = M.bondStanding(uid, player) end
    local p = M.bondPending[uid]
    if p and now - (p.at or 0) < 12000 then bd.now = p end
    if M.settings.bondHistory ~= false then
        local hist, last = M.histOf(uid), {}
        for i = #hist, math.max(1, #hist - 3), -1 do last[#last + 1] = hist[i].t end
        if #last > 0 then bd.history = last end
    end
    if M.settings.bondLikes ~= false then
        local lk = M.likesOf(uid, true)
        if lk then
            local likes, dis = {}, {}
            for _, it in ipairs(lk.list) do if it.like then likes[#likes + 1] = it.label else dis[#dis + 1] = it.label end end
            bd.likes, bd.dislikes = likes, dis
        end
        local hit = M.likeHit[uid]
        if hit and now - hit.at < 15000 then bd.gift = { label = hit.label, like = hit.like } end
    end
    if M.bondHintNow and M.bondHintNow.uid == uid and now - M.bondHintNow.at < 12000 then bd.hint = M.bondHintNow.want end
    req.bond = bd
end)

----------------------------------------------------------------------------------------------------------------
-- events -> history + shared-history points (one wrapper on the interaction log: every system already writes it)
----------------------------------------------------------------------------------------------------------------
M.histMap = {
    { "You shared food or water with them.", "gift", "You shared food or water", 3 },
    { "You patched someone up.", "heal", "You patched them up", 4 },
    { "You fought beside them.", "danger", "Fought side by side", 4 },
    { "You saved a life.", "save", "You saved a life", 10 },
    { "You kept your word.", "talk", "You kept your word", 2 },
    { "You came through for the group.", "talk", "You came through for the group", 2 },
    { "You threatened them", "fight", "You threatened them", 0, -1 },
    { "You were rude to them.", "fight", "You were rude to them", 0 },
    { "You hit one of theirs.", "fight", "You hit one of theirs", 0, -1 },
    { "You took things from them.", "betray", "You robbed them", 0, -1, true },
    { "You killed one of their own.", "betray", "You killed one of their own", 0, -2, true },
    { "You broke a deal.", "betray", "You broke a deal", 0, -2, true },
    { "You left them when it mattered.", "fight", "You left them when it mattered", 0 },
}
M.histEventMap = {
    { "Joined your party", "party", "Joined your party", 3 }, { "Left your party", "party", nil, 0 },
    { "Heard ", "death", nil, 2 }, { "Moved into your base", "party", "Moved into your base", 3 },
    { "Caught up with you", "party", nil, 1 },
}
local CONTACT = { talk = true, opinion = true, wound = true, romance = true, recruit = true, name = true, bond = true }
function M.bondOnLog(uid, what, before, after, kind)
    uid = tostring(uid)
    what = tostring(what or "")
    if kind == "bondtier" or kind == "history" then return end
    if M.grudgeOnLog then pcall(M.grudgeOnLog, uid, what, before, after, kind) end
    if M.changeOnLog then pcall(M.changeOnLog, uid, what, before, after, kind) end
    if CONTACT[kind] then
        local b = M.bondOf(uid, true)
        if b ~= DEFAULT then b.lastH = hours() end
    end
    if kind == "opinion" then
        for _, m in ipairs(M.histMap) do
            if string.sub(what, 1, #m[1]) == m[1] then
                M.histAdd(uid, m[2], m[3])
                if (m[4] or 0) > 0 then M.bondPoints(uid, m[4], m[2], { dailyCap = 12, capKey = m[2] }) end
                if m[5] and M.settings.bondTiers ~= false then
                    local t = M.bondTier(uid)
                    if t >= 2 then
                        local to = math.max(1, t + m[5])
                        if t == 5 and M.romanceBreak then pcall(M.romanceBreak, uid, "you betrayed them") end
                        setTier(uid, to, "Betrayal")
                    end
                end
                if m[6] and M.grudgeFromBetrayal then pcall(M.grudgeFromBetrayal, uid, m[3]) end
                if m[3] == "You were rude to them" and M.settings.bondLikes ~= false then
                    local lk = M.likesOf(uid, false)
                    for _, it in ipairs(lk and lk.list or {}) do if it.id == "rudeness" then M.likeLearn(uid, it, "you were rude") end end
                end
                return
            end
        end
    elseif kind == "talk" then
        M.bondPoints(uid, 1, "talk", { dailyCap = 3, capKey = "talk" })
        local b = M.bondOf(uid, true)
        local day = math.floor(hours() / 24)
        b.talkDay = type(b.talkDay) == "table" and b.talkDay or {}
        if b.talkDay.d ~= day then b.talkDay = { d = day, n = 0 } end
        b.talkDay.n = b.talkDay.n + 1
        if b.talkDay.n == 4 then M.histAdd(uid, "talk", "Talked for a long while"); M.bondPoints(uid, 3, "deep talk") end
    elseif kind == "bond" and string.sub(what, 1, 9) == "Survived " and string.find(what, "with you", 1, true) then
        M.histAdd(uid, "danger", string.gsub(what, " with you", " together"))
        M.bondPoints(uid, 5, "danger", { dailyCap = 15, capKey = "danger" })
    elseif kind == "wound" and string.sub(what, 1, 12) == "You gave the" then
        M.histAdd(uid, "heal", "Treated their wounds (" .. string.sub(what, 14, 60) .. ")")
        M.bondPoints(uid, 4, "heal", { dailyCap = 8, capKey = "heal" })
    elseif kind == "nemesis" then
        M.histAdd(uid, "grudge", what)
    elseif kind == "romance" and (what == "Became your partner" or string.sub(what, 1, 13) == "Broke up with") then
        M.histAdd(uid, "tier", what)
    elseif kind == "event" then
        for _, m in ipairs(M.histEventMap) do
            if string.sub(what, 1, #m[1]) == m[1] then
                if m[2] == "death" and not string.find(what, "last words", 1, true) then return end
                M.histAdd(uid, m[2], m[3] or what)
                if (m[4] or 0) > 0 then M.bondPoints(uid, m[4], m[2], { dailyCap = 6, capKey = m[2] }) end
                return
            end
        end
    end
end

-- gifts given (Gifts.lua noteGift) and the like / dislike check
function M.bondOnGift(uid, info)
    if type(info) ~= "table" then return end
    local player = ALifeSide.you()
    local it = M.likesOnGift(uid, info, player)
    if M.changeNote then pcall(M.changeNote, uid, "care", (it and it.like) and 3 or 1.5) end
    local txt = "You gave them " .. tostring(info.name or "something") .. (it and (it.like and " (they loved it)" or " (they hated it)") or "")
    M.histAdd(uid, "gift", txt)
    M.bondPoints(uid, (info.kind == "junk") and 0 or ((it and it.like) and 4 or 2), "gift", { dailyCap = 8, capKey = "gift" })
    -- a smoker who asked for one (Habits.lua)
    if M.smokeAsked and M.smokeAsked[tostring(uid)] and hours() - M.smokeAsked[tostring(uid)] < 2 then
        local hay = string.lower(tostring(info.name or "") .. " " .. tostring(info.fullType or ""))
        for _, k in ipairs(SMOKE_KEYS) do
            if string.find(hay, k, 1, true) then
                M.smokeAsked[tostring(uid)] = nil
                opAdj(uid, player, 4, "You gave them a smoke when they asked.")
                M.histAdd(uid, "gift", "Gave them a smoke when they asked")
                break
            end
        end
    end
end

-- deaths witnessed together (a known person near you when someone dies near both of you)
function M.bondOnDeath(body, uid, killer)
    if M.settings.bondHistory == false then return end
    local bx, by = pos(body)
    if bx == nil then return end
    -- pre-1.0 MP (P2b): the player who was there (nearest within 25 tiles; single player: you, as before)
    local who = nil
    if type(ALifeSide) == "table" then who = ALifeSide.nearest(bx, by, 25) else who = M.you() end
    if who == nil then return end
    local near, player = nearPlayer(M.tierCfg.nearTiles, who)
    if player == nil then return end
    local px, py = pos(player)
    if (bx - px) ^ 2 + (by - py) ^ 2 > 25 * 25 then return end
    local vname = nameOf(rec(uid))
    for _, l in ipairs(near) do
        local u = tostring(l.record.uid)
        if u ~= tostring(uid) and type(bucket("book")[u]) == "table" then
            M.histAdd(u, "death", "Watched " .. vname .. " die, with you")
            M.bondPoints(u, 2, "death", { dailyCap = 4, capKey = "death" })
            if M.changeNote then pcall(M.changeNote, u, "witness", 1) end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- slow tick (every 10 s real): contact + time together for people near you, one hint at most, one thought at most,
-- and once per in-game hour the neglect check over the book. No per-frame work.
----------------------------------------------------------------------------------------------------------------
M.bondHintNow = nil
function M.bondTick(now)
    if M.settings.enabled == false then return end
    if M.f517Install then pcall(M.f517Install) end
    local h = hours()
    M.bondHintedTick = false
    M.eachPlayer(M.bondTickFor, now, h) -- pre-1.0 MP (P2b): every player's people (single player: yours)
    M.bondNeglect(h)
end
function M.bondTickFor(player, now, h)
    local near
    near, player = nearPlayer(M.tierCfg.nearTiles, player)
    local hinted = M.bondHintedTick == true
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        local e = bucket("book")[uid]
        if type(e) == "table" and type(e.bond) == "table" then
            local b = e.bond
            b.lastH = h
            if h - (tonumber(b.togH) or -1e9) >= 1 then
                if b.togH ~= nil then
                    M.bondPoints(uid, 0.5, "together", { dailyCap = 4, capKey = "together" })
                    if M.changeNote then pcall(M.changeNote, uid, "care", 0.3) end
                end
                b.togH = h
            end
            -- a hint (never a promotion): standing well past the next tier, idle, not hinted lately
            if not hinted and M.settings.bondTiers ~= false and b.tier < 4 and h >= (tonumber(b.hintH) or -1e9) and idleOk(l, now) then
                local want = b.tier + 1
                if M.bondStanding(uid, player) >= M.bondNeed(uid, want) + 5 and daysKnown(b) >= (M.tierCfg.minDays[want] or 0)
                        and h >= (tonumber(b.ask[tostring(want)]) or -1e9) and distTo(l, player) <= 8 then
                    b.hintH = h + M.tierCfg.hintCdH
                    hinted = true
                    M.bondHintedTick = true
                    M.bondHintNow = { uid = uid, want = M.tierWord(want), at = now }
                    speak(l, player, "bond", "You've come to feel close to the newcomer. Hint - don't ask outright - that you'd call them a "
                        .. M.tierWord(want) .. " now, if they asked", ({ "", "You know... you're alright. I mean that.", "I don't say this to many people. You're good company.",
                        "Funny. Never thought I'd trust anyone this much again." })[want], { keyMs = 600000 })
                end
            end
        end
    end
    -- what they think: at most one refresh per tick, for someone near
    if M.settings.bondThought ~= false and now - (M.thoughtTickAt or -1e12) >= 30000 then
        M.thoughtTickAt = now
        for _, l in ipairs(near) do
            local uid = tostring(l.record.uid)
            if type(bucket("book")[uid]) == "table" and M.thoughtStale(uid, player) then
                if M.thoughtRefresh(uid, player) then break end
            end
        end
    end
end
-- neglect: hourly, over the book (never from a far-away or unreadable opinion: only time without any contact)
function M.bondNeglect(h)
    if M.settings.bondTiers ~= false and math.floor(h) ~= M.neglectHour then
        M.neglectHour = math.floor(h)
        for uid, e in pairs(bucket("book")) do
            if type(e) == "table" and type(e.bond) == "table" and not e.dead and (tonumber(e.bond.tier) or 1) >= 2 then
                local b = e.bond
                local days = M.tierCfg.neglectDays[b.tier] or 30
                local inParty = bucket("party")[uid] ~= nil or bucket("settlers")[uid] ~= nil
                if not inParty and h - (tonumber(b.lastH) or h) > days * 24 then
                    setTier(uid, b.tier == 5 and math.max(2, math.min(4, tonumber(b.prevTier) or 3)) or b.tier - 1, "Drifted apart (no contact for " .. days .. " days)")
                    if b.tier < 5 then
                        local ro = bucket("romance")[uid]
                        if type(ro) == "table" and (ro.stage or 0) >= 3 and M.romanceBreak then pcall(M.romanceBreak, uid, "no contact for weeks") end
                    end
                    b.lastH = h - days * 12
                end
            elseif type(e) == "table" and type(e.bond) == "table" then
                -- the party / settlers keep contact
                if bucket("party")[uid] ~= nil or bucket("settlers")[uid] ~= nil then e.bond.lastH = h end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- install: wrap the shared functions once (all files loaded: OnGameStart / first tick)
----------------------------------------------------------------------------------------------------------------
M._w517 = M._w517 or {}
local function wrapOnce(name, maker)
    if M._w517[name] or type(M[name]) ~= "function" then return end
    M._w517[name] = true
    M[name] = maker(M[name])
end
function M.tierInstall()
    wrapOnce("logInteraction", function(orig) return function(uid, what, before, after, kind)
        local r = orig(uid, what, before, after, kind)
        if uid ~= nil then pcall(M.bondOnLog, uid, what, before, after, kind) end
        return r
    end end)
    wrapOnce("noteGift", function(orig) return function(uid, info)
        local r = orig(uid, info)
        pcall(M.bondOnGift, uid, info)
        return r
    end end)
    -- the tie word: the player's own tier (no auto best-friend from opinion alone)
    if type(M.playerTie) == "function" and M.playerTie ~= M._bondTieFn then
        local orig = M.playerTie
        M._bondTieFn = function(r, player)
            local word, v = orig(r, player)
            if M.settings.bondTiers == false or r == nil then return word, v end
            if word == "nemesis" or word == "enemy" or word == "distrust" or word == "ally" then return word, v end
            local t = M.bondTier(r.uid)
            if t >= 5 then return "lover", v end
            if t >= 2 then return M.tierWord(t), v end
            if word == "friend" or word == "buddy" or word == "best friend" then return "friendly", v end
            return word, v
        end
        M.playerTie = M._bondTieFn
    end
    -- lover tier through the romance rules + a cooldown and an awkward refusal
    wrapOnce("romanceAsk", function(orig) return function(uid, player)
        if M.settings.bondTiers == false then return orig(uid, player) end
        local b = M.bondOf(uid, true)
        local h = hours()
        if h < (tonumber(b.ask["5"]) or -1e9) and (bucket("romance")[tostring(uid)] or {}).stage ~= 3 then
            opAdj(uid, player, -1, "Asked again too soon.")
            return false, "they asked you that not long ago - it's awkward; give it time"
        end
        local ok, why = orig(uid, player)
        if ok then
            if M.bondTier(uid) < 5 then setTier(uid, 5, "You asked, they said yes") end
        else
            b.ask["5"] = h + M.tierCfg.cooldownH
            M.histAdd(uid, "tier", "You asked to be together - not yet")
        end
        return ok, why
    end end)
    -- "will you be my best friend" is not asking them out
    wrapOnce("rpIntent", function(orig) return function(text)
        local out = orig(text)
        if M.settings.bondTiers ~= false and type(out) == "table" and out.askOut then
            local low = string.gsub(string.gsub(string.lower(tostring(text or "")), "girlfriend", ""), "boyfriend", "")
            if string.find(low, "friend", 1, true) then out.askOut = nil end
        end
        return out
    end end)
    -- tiers: following (recruit), sharing (what they open up about)
    wrapOnce("recruitVerdict", function(orig) return function(listener, player)
        if M.settings.bondTiers == false or M.rp == nil or listener == nil or listener.record == nil then return orig(listener, player) end
        local t = M.bondTier(listener.record.uid)
        local bonus = ({ 0, 8, 14, 20, 20 })[t] or 0
        local keep = M.rp.recruitNeed
        M.rp.recruitNeed = keep - bonus
        local a, b, c, d, e2 = orig(listener, player)
        M.rp.recruitNeed = keep
        return a, b, c, d, e2
    end end)
    wrapOnce("revealLevel", function(orig) return function(uid, op)
        if M.settings.bondTiers == false then return orig(uid, op) end
        local t = M.bondTier(uid)
        return orig(uid, (tonumber(op) or 0) + (t - 1) * 8)
    end end)
    -- grief: your friends grieve you too (partners already do)
    wrapOnce("onPlayerDeath", function(orig) return function(player)
        local r = orig(player)
        if M.settings.bondTiers ~= false and M.griefOf then
            local pname = "the newcomer"
            pcall(function() pname = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname() end)
            for uid, e in pairs(bucket("book")) do
                if type(e) == "table" and type(e.bond) == "table" and (tonumber(e.bond.tier) or 1) >= 2 and (tonumber(e.bond.tier) or 1) < 5 and not e.dead then
                    local g = M.griefOf(uid)
                    if g["player:" .. pname] == nil then
                        g["player:" .. pname] = { n = pname, t = M.tierWord(e.bond.tier), w = ({ 0, 0.4, 0.6, 0.8 })[e.bond.tier] or 0.4, at = hours(),
                            saw = false, known = false, kid = "zombie", kn = "the dead" }
                    end
                end
            end
        end
        return r
    end end)
    -- conversation reveals likes: anything they say that names one of their likes / dislikes
    wrapOnce("say", function(orig) return function(shell, player, text, opts)
        local r = orig(shell, player, text, opts)
        if M.settings.bondLikes ~= false and type(text) == "string" and type(opts) == "table" and type(opts.record) == "table" then
            pcall(function()
                local lk = M.likesOf(opts.record.uid, false)
                if lk == nil then return end
                if M.settings.likesSaidOnly ~= false then M.likesOnLine(opts.record.uid, text); return end
                local low = string.lower(text)
                for _, it in ipairs(lk.list) do
                    if not it.known and it.c ~= "peeve" and string.find(low, string.lower(it.label), 1, true) then M.likeLearn(opts.record.uid, it, "they mentioned it") end
                end
            end)
        end
        return r
    end end)
end

regMode("bond")
-- "thought": written, never spoken - the finish only hands the text to onDone (cached in the book)
if type(M.eventModes) == "table" and M.reactRequest then
    M.eventModes["thought"] = { request = M.reactRequest, finish = function(p, r) if type(p.onDone) == "function" then pcall(p.onDone, p, r) end end, fallback = function() end }
end
table.insert(M.playerWordHooks, M.bondOnWords)
-- 0.5.2.8: every line an NPC really says (A-Life's own lines too) can name a like
if type(M.npcLineHooks) == "table" then
    table.insert(M.npcLineHooks, function(shell, uid, text)
        if uid ~= nil and M.settings.likesSaidOnly ~= false then M.likesOnLine(uid, text) end
    end)
end
everyMs(M.tierCfg.tickMs, M.bondTick)
if type(Events) == "table" then
    if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Bond", function(body, uid, killer) pcall(M.bondOnDeath, body, uid, killer) end)
    end
end

-- 0.5.1.7: one idempotent installer for every wrapper of the new files (files load alphabetically; the wrapped
-- functions live in later files). Called on game start, lazily from the slow ticks, and from the UI.
function M.f517Install()
    for _, name in ipairs({ "tierInstall", "grudgeInstall", "changeInstall", "habitInstall", "bondUIInstall", "baseLifeInstall", "webUIInstall" }) do
        if type(M[name]) == "function" then
            local ok, err = pcall(M[name])
            if not ok then log("[f517] " .. name .. " failed: " .. tostring(err)) end
        end
    end
end
if type(Events) == "table" and type(Events.OnGameStart) == "table" and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function() pcall(M.f517Install) end)
end

-- the AI instruction for a decided bond answer (Lua decides, the AI voices it)
function M.bondWhat(p)
    if p.kind == "ask" then
        if p.already then return "The newcomer just asked if you two could be " .. tostring(p.want) .. "s. You already are - say so, amused." end
        if p.ok then return "The newcomer just asked if you two could be " .. tostring(p.want) .. "s. You say YES (" .. tostring(p.why) .. "). Say it your way, warmly." end
        return "The newcomer just asked if you two could be " .. tostring(p.want) .. "s. You say NO for now (" .. tostring(p.why) .. ")"
            .. (p.awkward and ". It came too early - be a little awkward about it, not hostile." or ". Be kind: you still like them, this doesn't change that.")
    elseif p.kind == "step" then
        return "The newcomer just told you they want to step back from being " .. tostring(p.from) .. "s to just " .. tostring(p.to) .. "s. You're "
            .. ({ hurt = "hurt but you accept it", stung = "stung and a bit cold about it", shrugs = "fine with it", accepts = "okay with it, a little sad" })[p.react or "accepts"] .. ". React."
    elseif p.kind == "apology" then
        if p.nothing then return "The newcomer just apologized to you, but you don't think they owe you anything. Say so, lightly - you're fine." end
        if p.cooldown then return "The newcomer apologized to you AGAIN, soon after the last time. You heard them the first time - say so, not unkind." end
        return "The newcomer just apologized to you. You " .. (p.ok and "accept it" or "don't accept it yet") .. " (" .. tostring(p.why) .. "). React."
    end
    return "React to the newcomer."
end
-- say a decided answer out loud (button presses; speech already goes through the reply prompt)
function M.bondVoice(uid, p, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    p.at = nowMs()
    M.bondPending[uid] = p
    local l = listenerOf(uid)
    if l == nil then
        -- 0.5.2.7 [pt255u]: on the radio (body not loaded) the answer comes over the radio instead of nowhere
        if M.radio ~= nil and tostring(M.radio.uid) == uid and M.radioLine and M.settings.fixApology ~= false then
            local r = rec(uid)
            pcall(M.radioLine, nil, M.bondStock(uid, p), M.radio.name or (r and r.name) or "?")
            return true
        end
        return false
    end
    return speak(l, player, "bond", M.bondWhat(p), M.bondStock(uid, p), { keyMs = 0, modeMs = 0, urgent = true, sub = p.kind, maxWords = 24 })
end
