-- A-Life Talk 0.5.2.7 [pt255u]: LOSING SOMEONE. "the closer you are with someone ... that should affect them greatly,
-- its an apocalypse, sometimes the people you have is what you got". A death of a partner / family / close friend is
-- a major trauma (Change.lua 'loss' input), scaled by how close they really were (pair strength, shared history, tie),
-- by who they have left, and stacked when losses come close together. The loss decides which way they change
-- (crack / go cold / rage) by personality and grief style, fades over weeks (never fully for a partner or family),
-- faster with people around and when you comfort them. Grief also shows on its own: quiet mentions, reminders (name,
-- things they liked), two mourners talking about them, "a week since" lines. Once per (griever, dead) pair; deaths
-- from before 0.5.2.7 are applied once on load, scaled by how long ago (some already healed). Off: partnerLossTrauma.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Loss") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Loss"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Loss") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) if M.log then M.log(msg) end end
local function nowMs() return M.nowMs() end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function lensOf(uid) local ok, l = pcall(function() M._changeRaw = true; local x = M.lens and M.lens(uid) or {}; M._changeRaw = nil; return x end); M._changeRaw = nil; return ok and type(l) == "table" and l or {} end
local function keyOf(uid) local ok, k = pcall(function() local p = M.partsOf and M.partsOf(uid) or nil; return p and p.core and p.core.key or "" end); return ok and tostring(k or "") or "" end
local function modsOf(uid) local ok, m = pcall(function() return M.personaMods and M.personaMods(uid) or {} end); return ok and type(m) == "table" and m or {} end
local function first(name) return string.match(tostring(name or "someone"), "^(%S+)") or tostring(name or "someone") end

if M.settings.partnerLossTrauma == nil then M.settings.partnerLossTrauma = true end
if M.settings.lossTalk == nil then M.settings.lossTalk = true end
if type(M.fileKeys) == "table" then
    for _, key in ipairs({ "partnerLossTrauma", "lossTalk" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end

M.lossCfg = {
    base = { partner = 52, parent = 40, child = 45, sibling = 40, ["best friend"] = 35, crush = 35, admirer = 10,
        buddy = 20, comrade = 20, friend = 8, ally = 5, respect = 6, acquaintance = 2, ex = 6 },
    sawMul = 1.3, violentMul = 1.2, cap = 120,
    aloneNone = 2.0, aloneFew = 1.5, manyLeft = 0.9, -- who they have left
    stackDays = 30, stackAdd = 0.35, -- each earlier loss in the window adds 35 %
    halfDays = 21, floorClose = 0.12, -- the grief level fades (half-life), never below the floor for partner / family
    retroHalfDays = 40, -- deaths from before 0.5.2.7: scaled by how long ago
    idleGapMs = 8 * 60000, pairGapMs = 20 * 60000, remindGapMs = 3 * 60000, tickMs = 4000,
    closeTypes = { partner = true, parent = true, child = true, sibling = true, ["best friend"] = true, buddy = true, comrade = true, crush = true },
    familyTypes = { partner = true, parent = true, child = true, sibling = true },
}
local C = M.lossCfg

local function aliveUid(uid)
    uid = tostring(uid)
    if M.isFinalDead and M.isFinalDead(uid) then return false end
    local e = bucket("book")[uid]
    if type(e) == "table" and e.dead then return false end
    local r = rec(uid)
    if r ~= nil and r.lifecycle == "dead" then return false end
    if r == nil and type(e) ~= "table" then return false end
    if M.isPersonDead and M.settings.offDeath ~= false then
        local ok, dead = pcall(M.isPersonDead, uid, r)
        if ok and dead then return false end
    end
    return true
end
M.lossAlive = aliveUid

-- every tie of one person (cheap: one pass over the pairs map; only on a loss / daily)
local function tiesOf(uid)
    local out, me = {}, tostring(uid)
    for key, row in pairs(bucket("pairs")) do
        if type(row) == "table" then
            local a, b = string.match(key, "^(.-)|(.*)$")
            local other = (a == me and b) or (b == me and a) or nil
            if other then out[#out + 1] = { uid = other, row = row, t = M.pairTypeFor and M.pairTypeFor(row, me, other) or row.t } end
        end
    end
    return out
end
M.lossTies = tiesOf

-- how close they REALLY were: pair strength, shared history, tie type (a near-stranger "friend" barely registers)
function M.lossDepth(g, d, t, row)
    row = row or (M.pairRow and M.pairRow(g, d, false)) or nil
    local s = type(row) == "table" and (tonumber(row.s) or 0) or 0
    local whys = type(row) == "table" and type(row.why) == "table" and #row.why or 0
    local depth = 0.35 + math.max(0, s) / 100 * 0.75 + math.min(4, whys) * 0.05
    if type(row) == "table" and row.fx then depth = depth + 0.1 end -- a fixed (A-Life) tie: family, squad
    if s < 0 then depth = depth * 0.5 end
    return clamp(depth, 0.2, 1.3), s
end

-- who they have left: living partner / family / close friends, and you if you're at least friends
function M.lossLeft(g, deadUid)
    local n, names = 0, {}
    for _, t in ipairs(tiesOf(g)) do
        if t.uid ~= tostring(deadUid) and (C.closeTypes[t.t] or (tonumber(t.row.s) or 0) >= 50) and aliveUid(t.uid) then
            n = n + 1; names[#names + 1] = t.uid
        end
    end
    if M.bondTier and M.bondTier(g) >= 2 then n = n + 1; names[#names + 1] = "player" end
    return n, names
end
local function leftMul(n) if n <= 0 then return C.aloneNone elseif n <= 2 then return C.aloneFew elseif n >= 5 then return C.manyLeft end return 1 end

-- which way the loss bends them (personality + grief style from PersonaData)
function M.lossSteer(uid)
    local l, k, m = lensOf(uid), keyOf(uid), modsOf(uid)
    local crack = (l.romantic or 0) + (l.kind or 0) + (l.cheerful or 0) + (l.fearful or 0) + (l.gloomy or 0) * 0.8
    local cold = (l.calm or 0) + (l.brave or 0) + (l.proud or 0) + (l.disciplined or 0) * 0.6 + (l.sarcastic or 0) * 0.3
    local rage = (l.volatile or 0) * 1.2 + (l.mean or 0) * 0.6 + math.max(0, 0.5 - (tonumber(m.forgive) or 0.5)) * 0.8
    if k == "stoic" or k == "cold" or k == "brave" or k == "hardass" or k == "proud" or k == "sarcastic" then cold = cold + 0.6 end
    if k == "hothead" or k == "vengeful" or k == "volatile" then rage = rage + 0.7 end
    if k == "cheerful" or k == "gentle" or k == "romantic" or k == "coward" then crack = crack + 0.5 end
    local style = tostring(m.grief or "")
    if style == "weep" then crack = crack + 0.4 elseif style == "cold" then cold = cold + 0.4
    elseif style == "rage" then rage = rage + 0.5 elseif style == "quiet" then crack = crack + 0.2; cold = cold + 0.2
    elseif style == "denial" then cold = cold + 0.25 end
    if rage > crack and rage > cold then return "raging", style end
    if cold > crack then return "hardened", style end
    return "cracking", style
end

local function pronoun(uid)
    local lk = M.lookOf and M.lookOf(uid) or nil
    if type(lk) == "table" and lk.female == true then return "her" elseif type(lk) == "table" and lk.female == false then return "him" end
    return "them"
end
local function lossLine(uid, name, steer)
    local p = pronoun(uid)
    if steer == "hardened" then return "Lost " .. first(name) .. " - went cold, shut it all away" end
    if steer == "raging" then return "Lost " .. first(name) .. " - it turned to rage" end
    return "Lost " .. first(name) .. " - something went out of " .. p
end

-- the loss lands (Change.lua changeNote 'loss' calls this with the change state)
function M.lossNote(uid, c, amount, info)
    if M.settings.partnerLossTrauma == false then return end
    info = type(info) == "table" and info or {}
    local h = hours()
    local L = type(c.loss) == "table" and c.loss or { list = {} }
    L.list = type(L.list) == "table" and L.list or {}
    -- stacking: earlier losses in the window add more, and the fear of being alone grows
    local recent = 0
    for _, x in ipairs(L.list) do if h - (tonumber(x.h) or -1e9) <= C.stackDays * 24 then recent = recent + 1 end end
    amount = amount * (1 + C.stackAdd * recent)
    amount = math.min(C.cap * 1.5, amount)
    L.list[#L.list + 1] = { h = h, n = info.name, t = info.t, a = math.floor(amount) }
    while #L.list > 8 do table.remove(L.list, 1) end
    local steer = info.steer or M.lossSteer(uid)
    L.steer, L.name, L.t, L.at, L.dead = steer, info.name, info.t, h, info.dead
    L.g = clamp((tonumber(L.g) or 0) + amount / 60, 0, 1.5)
    L.close = L.close or C.familyTypes[info.t or ""] or nil
    L.left = info.left
    L.alone = clamp((tonumber(L.alone) or 0) + 0.3 * recent + ((info.left or 3) <= 0 and 0.5 or ((info.left or 3) <= 2 and 0.2 or 0)), 0, 1)
    if L.alone <= 0 then L.alone = nil end
    L.worst = (info.left or 3) <= 0 and C.familyTypes[info.t or ""] and true or L.worst
    c.loss = L
    c.tr = math.min(200, (tonumber(c.tr) or 0) + amount)
    -- the shock: straight into the new direction, part of the way at once
    local shock = math.min(0.75, amount / 250)
    if c.state ~= steer then c.deg = math.max(shock, (tonumber(c.deg) or 0) * 0.5); c.state = steer
    else c.deg = math.max(tonumber(c.deg) or 0, shock) end
    if M.histAdd then M.histAdd(uid, "change", lossLine(uid, info.name, steer)) end
    local st = c.deg >= 0.7 and 3 or (c.deg >= 0.4 and 2 or (c.deg >= 0.15 and 1 or 0))
    c.stage = st
    c.sinceDay = math.floor(h / 24)
    c.day = c.day or math.floor(h / 24)
    log("loss: " .. tostring(uid) .. " lost " .. tostring(info.name) .. " (" .. tostring(info.t) .. ") amount=" .. math.floor(amount)
        .. " left=" .. tostring(info.left) .. " -> " .. steer .. " " .. ALifeFmtDec(c.deg, 2))
end

-- Change.lua: direction + how far (fresh losses reach far; being left with nobody risks the worst stage)
function M.lossTarget(uid, c)
    local L = c.loss
    local g = tonumber(L.g) or 0
    if g < 0.08 then return nil end
    local want = clamp(g * 0.9 - (tonumber(c.care) or 0) / 40, 0, 1)
    if L.worst and g >= 0.5 then want = math.max(want, 0.9) end
    return L.steer or "cracking", want
end
function M.lossStep(uid, c, step)
    local L = c.loss
    if type(L) ~= "table" or (tonumber(L.g) or 0) < 0.3 or M.settings.partnerLossTrauma == false then return step end
    return step * (L.worst and 2.5 or 2)
end
-- one day: the grief fades; people around them (and you) pull them back faster
function M.lossDay(uid, c)
    local L = c.loss
    if type(L) ~= "table" or M.settings.partnerLossTrauma == false then return end
    local g = tonumber(L.g) or 0
    local f = math.exp(-0.693 / C.halfDays)
    local care = tonumber(c.care) or 0
    local left = tonumber(L.left) or 0
    if care >= (M.changeCfg and M.changeCfg.careNeed or 4) then f = f * 0.96 end -- you / others looking after them
    if left >= 3 then f = f * 0.985; c.care = math.min(40, care + 0.3) -- the loved ones still here
    elseif left >= 1 then f = f * 0.995 end
    g = g * f
    if L.close then g = math.max(g, C.floorClose) end
    L.g = g
    if L.alone then L.alone = L.alone * 0.985; if L.alone < 0.05 then L.alone = nil end end
    if L.worst and (g < 0.5 or left > 0) then L.worst = nil end
end
-- you comfort them (talk that went well, a gift): extra care while they grieve
function M.lossComfort(uid, amount, how)
    if M.settings.partnerLossTrauma == false then return end
    local e = bucket("book")[tostring(uid)]
    local c = type(e) == "table" and e.change or nil
    if type(c) ~= "table" or type(c.loss) ~= "table" or (tonumber(c.loss.g) or 0) < 0.08 then return end
    c.care = math.min(40, (tonumber(c.care) or 0) + amount)
    c.loss.g = math.max(0, (tonumber(c.loss.g) or 0) - amount / 120)
    c.loss.comfortH = hours()
end

-- one (griever, dead) pair: decide the amount and apply it, once
function M.lossApply(g, deadUid, e, opts)
    if M.settings.partnerLossTrauma == false or M.settings.changeOverTime == false then return nil end
    opts = opts or {}
    g, deadUid = tostring(g), tostring(deadUid)
    if g == deadUid or not aliveUid(g) then return nil end
    local done = bucket("lossDone")
    local key = g .. "|" .. deadUid
    local nameKey = g .. "|n:" .. string.lower(tostring(e and e.n or ""))
    if done[key] or (e and e.n and done[nameKey]) then if e then e.lossDone = true end return nil end
    local row = M.pairRow and M.pairRow(g, deadUid, false) or nil
    local t = (e and e.t) or (row and M.pairTypeFor and M.pairTypeFor(row, g, deadUid)) or "acquaintance"
    local base = C.base[t] or 0
    local depth, s = M.lossDepth(g, deadUid, t, row)
    if row == nil and e and tonumber(e.w) then depth = clamp(0.4 + e.w * 0.6, 0.2, 1.1) end
    local amount = base * depth
    if e and e.saw then amount = amount * C.sawMul end
    local violent = e and ((e.kid ~= nil and e.kid ~= "zombie") or string.find(string.lower(tostring(e.kn or "")), "shot", 1, true)
        or string.find(string.lower(tostring(e.kn or "")), "murder", 1, true))
    if violent then amount = amount * C.violentMul end
    local left = M.lossLeft(g, deadUid)
    amount = amount * leftMul(left)
    -- time since they found out (deaths from before 0.5.2.7, or learned long ago): some of it already healed
    local learned = e and (tonumber(e.learnedH) or tonumber(e.at)) or tonumber(opts.at) or hours()
    local days = math.max(0, (hours() - learned) / 24)
    local tf = 1
    if days > 1 then tf = math.exp(-days * 0.693 / C.retroHalfDays); if C.familyTypes[t] then tf = math.max(tf, 0.35) end end
    amount = math.min(C.cap * 1.5, amount * tf)
    done[key] = hours(); if e and e.n then done[nameKey] = hours() end
    if e then e.lossDone = true; e.lossTf = tf end
    if amount < 1 then return { amount = amount, t = t, left = left, small = true } end
    local steer = M.lossSteer(g)
    M.changeNote(g, "loss", amount, { name = (e and e.n) or opts.name or "someone", t = t, left = left, steer = steer, dead = deadUid })
    -- clingier toward who's left (only real ties)
    if amount >= 15 and M.pairBump then
        for _, tt in ipairs(tiesOf(g)) do
            if tt.uid ~= deadUid and C.closeTypes[tt.t] and aliveUid(tt.uid) then pcall(M.pairBump, g, tt.uid, 3, "all they have left") end
        end
    end
    -- rage with a known killer: a grudge (you) or a feud (an NPC)
    if steer == "raging" and e and e.kid ~= nil and e.kid ~= "zombie" and amount >= 15 then
        if e.kid == "player" and M.grudgeAdd then pcall(M.grudgeAdd, g, math.min(60, amount), "killed " .. tostring(e.n), deadUid, "betray")
        elseif e.kid ~= g and M.pairBump then pcall(M.pairBump, g, e.kid, -math.floor(math.min(60, amount)), "killed " .. tostring(e.n), "nemesis") end
    end
    return { amount = amount, t = t, left = left, steer = steer, days = days }
end

-- every death path ends in a known grief entry (saw it / told / word reached you / off-screen confirmations):
-- scan those (cheap: grief map only) and apply each pair once
function M.lossScan()
    if M.settings.partnerLossTrauma == false then return 0 end
    local n = 0
    for g, map in pairs(bucket("grief")) do
        if type(map) == "table" then
            for deadUid, e in pairs(map) do
                if type(e) == "table" and e.known and not e.lossDone then
                    local ok, r = pcall(M.lossApply, g, deadUid, e)
                    if not ok then log("loss error: " .. tostring(r)); e.lossDone = true end
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- deaths from before 0.5.2.7 with no grief entry (e.g. Jorge, off-screen before 0.5.2.6): a dead person in the
-- people book / final-deaths list and a living partner or family member -> they know by now (word reaches family)
function M.lossRetro()
    if M.settings.partnerLossTrauma == false then return 0 end
    local meta = bucket("lossMeta")
    if meta.retro then return 0 end
    meta.retro = hours()
    local deadSet = {}
    for uid, e in pairs(bucket("book")) do if type(e) == "table" and e.dead then deadSet[tostring(uid)] = { h = tonumber(e.diedH), n = e.real or e.name } end end
    pcall(function() for uid, d in pairs(M.finalStore().uids or {}) do deadSet[tostring(uid)] = deadSet[tostring(uid)] or { h = tonumber(type(d) == "table" and d.h), n = type(d) == "table" and d.name or nil } end end)
    local made = 0
    for deadUid, d in pairs(deadSet) do
        for _, tt in ipairs(tiesOf(deadUid)) do
            local g = tt.uid
            local t = M.pairTypeFor and M.pairTypeFor(tt.row, g, deadUid) or tt.row.t
            local gm = M.griefOf(g)
            local e = gm[deadUid]
            local knows = type(e) == "table" and e.known
            if not knows then
                -- a "Learned X died" / death memory, or family / partner (word reaches family)
                local nm = string.lower(first(d.n or (e and e.n) or ""))
                for _, km in ipairs(M.keyMemOf and M.keyMemOf(g) or {}) do
                    if #nm > 2 and string.find(string.lower(tostring(km.t)), nm, 1, true) and (km.k == "death" or string.find(string.lower(tostring(km.t)), "died", 1, true)) then knows = true end
                end
                if C.familyTypes[t] or t == "best friend" then knows = true end
            end
            if knows and aliveUid(g) and (C.base[t] or 0) >= 8 then
                if type(e) ~= "table" then
                    local nm = d.n
                    if nm == nil then local gr = M.ghostRecord and M.ghostRecord(deadUid); if gr then local pa = PA(); nm = fn(pa.Names, "of") and pa.Names.of(gr) or nil end end
                    e = { n = nm or "someone", t = t, w = (M.closeness and select(1, M.closeness(g, deadUid))) or 0.5, at = d.h or hours(), saw = false, known = true,
                        src = "word reached you", learnedH = d.h or hours(), learnedMs = nil, reacted = true, retro = true }
                    gm[deadUid] = e
                elseif not e.known then
                    e.known, e.src, e.learnedH, e.reacted = true, "word reached you", d.h or e.at or hours(), true
                end
                made = made + 1
            end
        end
    end
    local n = M.lossScan()
    log("loss: retro pass - " .. made .. " old death(s) taken on, " .. n .. " applied")
    return n
end

-- the strongest loss of one person right now (for prompt + unprompted lines)
function M.lossNow(uid)
    local e = bucket("book")[tostring(uid)]
    local c = type(e) == "table" and e.change or nil
    local L = type(c) == "table" and c.loss or nil
    if type(L) ~= "table" or (tonumber(L.g) or 0) < 0.05 then return nil end
    return L, c
end
local function levelWord(g) if g >= 0.9 then return "raw, it's all you think about" elseif g >= 0.5 then return "heavy, it colors everything" elseif g >= 0.2 then return "a dull ache that comes and goes" end return "an old scar" end
-- a trio (A-Life Talk's own pair rolls can make A, B and C all partners): describe it as one family, not a cheat
function M.lossTrio(uid, deadUid)
    local out = {}
    for _, tt in ipairs(tiesOf(uid)) do
        if tt.t == "partner" and tt.uid ~= tostring(deadUid) and aliveUid(tt.uid) then
            local row = M.pairRow and M.pairRow(tt.uid, deadUid, false)
            if row and row.t == "partner" then
                local r = rec(tt.uid) or (M.ghostRecord and M.ghostRecord(tt.uid))
                local pa = PA()
                out[#out + 1] = r and fn(pa.Names, "of") and first(pa.Names.of(r)) or "the other one"
            end
        end
    end
    return out
end
function M.lossPrompt(req, uid)
    if M.settings.partnerLossTrauma == false then return end
    local L = M.lossNow(uid)
    if L == nil then return end
    local days = math.floor(math.max(0, hours() - (tonumber(L.at) or hours())) / 24)
    local x = { n = tostring(L.name), t = tostring(M.typeWords and M.typeWords[L.t or ""] or L.t or "someone close"), days = days,
        level = levelWord(tonumber(L.g) or 0), how = L.steer, g = math.floor((tonumber(L.g) or 0) * 100 + 0.5) / 100 }
    if L.alone then x.alone = true end
    if (tonumber(L.left) or 1) <= 0 then x.nobody = true end
    local trio = L.dead and M.lossTrio(uid, L.dead) or {}
    if #trio > 0 then x.trio = table.concat(trio, ", ") end
    req.loss = x
end

----------------------------------------------------------------------------------------------------------------
-- grief on its own (unprompted, rate-limited, one cheap pass every 4 s over the people near you)
----------------------------------------------------------------------------------------------------------------
M.lossSpokeAt = M.lossSpokeAt or {}
M.lossQueue = M.lossQueue or {}
local function styleOf(uid)
    local s = tostring(modsOf(uid).grief or "")
    return ({ weep = "tearful, voice breaking", cold = "flat and clipped, shut down", rage = "angry, someone should pay",
        quiet = "very quiet, half to yourself", denial = "as if they might still walk in" })[s] or "quiet, in character"
end
M.lossStyleOf = styleOf
local function say(l, player, what, fallback, key, gapMs, extra, answer, dlg)
    local now = nowMs()
    if now - (M.lossSpokeAt[key] or -1e12) < gapMs then return false end
    if not answer and now - (M.lossSpokeAt["any"] or -1e12) < 15000 then return false end
    M.lossSpokeAt[key], M.lossSpokeAt["any"] = now, now
    M.lossLastLine = { uid = tostring(l.record.uid), what = what, key = key, at = now }
    local ok = M.react and M.react("grief", l, player, { what = what, style = (extra or "") .. styleOf(l.record.uid), maxWords = 16, fallback = fallback, dlg = dlg },
        { key = "loss:" .. key, keyCooldownMs = 0, modeCooldownMs = 0 })
    if not ok and fallback and M.say and l.shell then
        M.say(l.shell, player, fallback, { record = l.record })
        if dlg and M.dlgNote then pcall(M.dlgNote, l.record.uid, dlg.to, fallback, dlg.kind, { player = player }) end -- 0.5.2.10
    end
    return true
end
local function dayWord(days) if days <= 1 then return "yesterday" end return tostring(days) .. " days ago" end
local idleLines = { cracking = { "%s would've known what to do.", "I keep thinking I hear %s.", "I miss %s." },
    hardened = { "%s's gone. Nothing to say about it.", "Don't. Not about %s.", "We keep moving. %s would." },
    raging = { "Whoever did that to %s is going to pay.", "%s didn't deserve that.", "Don't tell me it's fine. %s is dead." } }
local function stock(L, seed)
    local list = idleLines[L.steer or "cracking"] or idleLines.cracking
    local i = (math.floor(tonumber(seed) or 0) % #list) + 1
    return string.format(list[i], first(L.name))
end
function M.lossTick(now)
    if M.settings.partnerLossTrauma == false or M.settings.lossTalk == false then return end
    local pa = PA()
    local player = ALifeSide.you()
    if player == nil or not fn(pa.Talk, "listeners") then return end
    -- queued answers (the second mourner)
    for i = #M.lossQueue, 1, -1 do
        local q = M.lossQueue[i]
        if now >= q.at then table.remove(M.lossQueue, i); pcall(say, q.l, player, q.what, q.fallback, q.key, 0, q.extra, true, q.dlg) end
    end
    local near = pa.Talk.listeners(player, 20) or {}
    local mourners = {}
    for _, l in ipairs(near) do
        local L = M.lossNow(l.record.uid)
        if L then mourners[#mourners + 1] = { l = l, L = L } end
    end
    for _, m in ipairs(mourners) do
        local uid, L = tostring(m.l.record.uid), m.L
        local g = tonumber(L.g) or 0
        local days = math.floor(math.max(0, hours() - (tonumber(L.at) or hours())) / 24)
        local busy = fn(pa.Talk, "busy") and pa.Talk.busy(m.l.record, now)
        if not busy then
            -- "a week since" / "a month" (once each)
            L.anniv = type(L.anniv) == "table" and L.anniv or {}
            local mark = (days >= 100 and 100) or (days >= 30 and 30) or (days >= 7 and 7) or nil
            if mark and not L.anniv[tostring(mark)] then
                L.anniv[tostring(mark)] = say(m.l, player, "It's been " .. (mark == 7 and "a week" or (mark == 30 and "a month" or "a hundred days")) .. " since " .. tostring(L.name)
                    .. " (your " .. tostring(L.t) .. ") died. Say it out loud, unprompted.", (mark == 7 and "A week. A week since " or "Been a long time since ") .. first(L.name) .. ".",
                    uid .. ":anniv" .. mark, 0) or nil -- marked only once it was really said
            else
                -- two who lost the same person, both here: they talk about them (comfort or snap)
                local other = nil
                for _, o in ipairs(mourners) do
                    if o ~= m and tostring(o.L.dead) == tostring(L.dead) and L.dead ~= nil then
                        local x1, y1 = pos(m.l.shell); local x2, y2 = pos(o.l.shell)
                        if x1 and x2 and (x1 - x2) ^ 2 + (y1 - y2) ^ 2 <= 36 then other = o end
                    end
                end
                local pk = "pair:" .. tostring(L.dead)
                if other and now - (M.lossSpokeAt[pk] or -1e12) >= C.pairGapMs then
                    local row = M.pairRow and M.pairRow(uid, other.l.record.uid, false)
                    local warm = (row and (tonumber(row.s) or 0) >= 25) and L.steer ~= "raging" and other.L.steer ~= "raging"
                    local on = first(other.l.record and (PA().Names and PA().Names.of and PA().Names.of(other.l.record)) or "you")
                    if say(m.l, player, "You and " .. on .. " both lost " .. tostring(L.name) .. ". Say something to " .. on .. " about " .. first(L.name)
                            .. (warm and " - you're trying to hold each other up." or " - grief makes you snap at them."),
                            warm and ("You okay, " .. on .. "? I keep thinking about " .. first(L.name) .. ".") or ("Don't look at me like that. I miss " .. first(L.name) .. " too."), pk, C.pairGapMs, "to " .. on .. ", ",
                            nil, { to = tostring(other.l.record.uid), kind = warm and "comfort" or "argument" }) then
                        M.lossQueue[#M.lossQueue + 1] = { at = now + 6000, l = other.l, key = pk .. ":b", extra = "answering " .. first(m.l.record and PA().Names.of(m.l.record) or "them") .. ", ",
                            what = "Answer: you lost " .. tostring(L.name) .. " too" .. (warm and "; you lean on each other." or "; you snap back, then soften a little."),
                            fallback = warm and "Yeah. Me too. Every day." or "Fine. Sorry. I just... I miss them.",
                            dlg = { to = tostring(uid), kind = warm and "comfort" or "argument" } }
                        if warm then M.lossComfort(uid, 1.5, "company"); M.lossComfort(other.l.record.uid, 1.5, "company") end
                    end
                elseif ZombRand and g >= 0.15 then
                    -- a quiet mention, more often while it's raw (gap 8 min at full grief, longer as it fades)
                    local gap = C.idleGapMs / clamp(g, 0.2, 1.2)
                    if now - (M.lossSpokeAt[uid .. ":idle"] or -1e12) >= gap and ZombRand(6) == 0 then
                        say(m.l, player, "Unprompted, nobody asked: " .. tostring(L.name) .. " (your " .. tostring(L.t) .. ") died " .. dayWord(days)
                            .. ". Something reminds you. One quiet line about them (what they'd have said or done).", stock(L, now / 1000), uid .. ":idle", gap)
                    end
                end
            end
        end
    end
end

-- reminders: their name comes up, or something they liked (your words, or another NPC's line)
local function remind(text, speakerUid)
    if M.settings.partnerLossTrauma == false or M.settings.lossTalk == false then return end
    local pa = PA()
    local player = ALifeSide.you()
    if player == nil or not fn(pa.Talk, "listeners") then return end
    local low = string.lower(tostring(text or ""))
    for _, l in ipairs(pa.Talk.listeners(player, 14) or {}) do
        local uid = tostring(l.record.uid)
        local L = uid ~= tostring(speakerUid) and M.lossNow(uid) or nil
        if L and L.name then
            local nm = string.lower(first(L.name))
            local hit = (#nm > 2 and string.find(low, nm, 1, true)) and "name" or nil
            if not hit and L.dead and M.likesShown then
                local ok, lk = pcall(M.likesShown, L.dead)
                if ok and type(lk) == "table" then
                    for _, it in ipairs(lk.likes or {}) do
                        local lab = string.lower(tostring(it.label or ""))
                        if #lab > 3 and string.find(low, lab, 1, true) then hit = lab end
                    end
                end
            end
            if hit then
                say(l, player, hit == "name" and ("Someone just said " .. first(L.name) .. "'s name. " .. first(L.name) .. " (your " .. tostring(L.t) .. ") is dead. React.")
                    or ("Someone mentioned " .. hit .. " - " .. first(L.name) .. " (your " .. tostring(L.t) .. ", dead now) loved that. React, briefly."),
                    hit == "name" and (first(L.name) .. "... yeah.") or (first(L.name) .. " loved that."), uid .. ":remind", C.remindGapMs)
            end
        end
    end
end
M.lossRemind = remind
if type(M.playerWordHooks) == "table" then table.insert(M.playerWordHooks, function(player, text) remind(text, nil) end) end
if type(M.npcLineHooks) == "table" then table.insert(M.npcLineHooks, function(shell, uid, text) remind(text, uid) end) end

-- the habits: a cracking mourner reaches for the bottle (when the habit system is there)
function M.lossInstall()
    if M._lossW == nil then M._lossW = {} end
    local W = M._lossW
    if not W.habit and type(M.habitWeights) == "function" then
        W.habit = true
        local orig = M.habitWeights
        M.habitWeights = function(uid, l, c, ctx, w, ...)
            local r = orig(uid, l, c, ctx, w, ...)
            if M.settings.partnerLossTrauma ~= false and type(w) == "table" then
                local L = M.lossNow(uid)
                if L and L.steer == "cracking" and (tonumber(L.g) or 0) >= 0.25 and w.booze ~= nil then w.booze = w.booze + 14 * L.g end
            end
            return r
        end
    end
    -- grief style for the short-term "just learned" line (Grief.lua uses M.griefNewsStyle when set)
    M.griefNewsStyle = styleOf
end

if type(Events) == "table" and Events.OnTick then
    local last, lastScan = -1e12, -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Loss", function()
        local now = nowMs()
        if now - last < C.tickMs then return end
        last = now
        if M.settings.enabled == false then return end
        pcall(M.lossInstall)
        if not bucket("lossMeta").retro then pcall(M.lossRetro) end
        if now - lastScan >= 3000 then lastScan = now; pcall(M.lossScan) end
        M.eachPlayer(function() -- pre-1.0 MP: mourners near every player (SP: you)
            local ok, e = pcall(M.lossTick, now)
            if not ok then log("loss tick error: " .. tostring(e)) end
        end)
    end)
end
