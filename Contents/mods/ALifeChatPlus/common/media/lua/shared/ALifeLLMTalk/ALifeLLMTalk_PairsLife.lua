-- A-Life Talk 0.5.1: relationships evolve on their own (NPC <-> NPC pairs and NPC <-> player).
--   * time near each other strengthens a bond; long separation drifts it toward neutral
--   * grudges fade unless reinforced (vengeful / petty slower, forgiving faster - persona "forgive")
--   * surviving danger together (a horde, a fight) upgrades: rival -> grudging respect -> buddy
--   * loot fights, insults, betrayal and slander downgrade
--   * romance builds slowly (romantic personas, time together) or sours (partner -> ex)
--   * every type change has thresholds with hysteresis (in at X, out only below a lower Y) and is logged in both
--     NPCs' interaction logs, as ambient news ("bondNews") and, when notable, as a rumor.
-- Cadence: Events.EveryTenMinutes (together / danger) and Events.EveryHours (drift / decay); bounded work per tick.
-- Nothing in A-Life is modified: pairs live in our own "pairs" bucket; the player side uses A-Life's NpcOpinion.adjust
-- (the unwrapped original, silent, small) and a "ptie" bucket for the player tie's hysteresis.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_PairsLife") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "PairsLife"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("PairsLife") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
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
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function shellOf(uid) local pa = PA(); local s = nil; pcall(function() s = pa.Talk.shellFor(tostring(uid)) end); return s end
local function posOf(sh) local x, y, z = nil, nil, nil; pcall(function() x, y, z = sh:getX(), sh:getY(), sh:getZ() end); return x, y, z end

M.pairHours = hours
M.bondCfg = {
    togetherTiles = 6, maxLoaded = 40, togetherGain = 0.35, dailyCap = 6, playerGain = 0.5, playerDailyCap = 5,
    apartH = 48, driftPerH = 0.25, grudgeBasePerH = 0.5, grudgePauseH = 24, dangerQuietMs = 120000, dangerMinZ = 6,
    dangerGain = 6, playerDanger = 3, newsKeep = 12, newsH = 72, playerBudget = 200,
}
if M.settings.bonds == nil then M.settings.bonds = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "bonds" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "bonds" end
end

-- ladder: { type, in at, out below } (positive) / { type, in at <=, out above } (negative)
M.bondUp = { { "best friend", 65, 52 }, { "buddy", 38, 28 }, { "friend", 18, 10 }, { "acquaintance", 6, -6 } }
M.bondDown = { { "enemy", -50, -36 }, { "distrust", -15, -6 } }
local rankOf = { stranger = 0, acquaintance = 1, friend = 2, buddy = 3, ["best friend"] = 4 }
local FAMILY = { sibling = true, parent = true }

local function romantic(uid)
    local mods = M.personaMods and M.personaMods(uid) or nil
    return mods and (tonumber(mods.romance) or 0) or 0.3
end
local function forgiveOf(uid)
    local mods = M.personaMods and M.personaMods(uid) or nil
    return mods and (tonumber(mods.forgive) or 0.5) or 0.5
end

-- the type for a row's score, given its current type (hysteresis). Pure: easy to test.
function M.bondTypeFor(row, a, b, why, delta)
    local t, s = row.t or "stranger", tonumber(row.s) or 0
    if row.fx or FAMILY[t] then return t end
    if t == "nemesis" then return s > -45 and "enemy" or "nemesis" end
    local h = hours()
    local floor = (row.g == "comrade" or t == "comrade") and "comrade" or ((row.g == "ally" or t == "ally") and "ally" or nil)
    -- romance
    if t == "partner" then
        if s < 15 then return "ex" end
        return "partner"
    end
    if t == "crush" then
        if s < 12 then return "friend" end
        if s >= 55 and (row.rp or 0) >= 1 then return "partner" end
        return "crush"
    end
    if t == "ex" then
        if s > 20 then return "acquaintance" end
        if s <= -15 then return "distrust" end
        return "ex"
    end
    -- rival / grudging respect
    if t == "rival" then
        if (row.dz or 0) >= 1 and s >= 5 then return "respect" end
        if s <= -50 then return "enemy" end
        if s > 15 then return "acquaintance" end
        return "rival"
    end
    if t == "respect" then
        if s >= 38 then return "buddy" end
        if s < -15 then return "rival" end
        return "respect"
    end
    -- negative ladder (hysteresis: get in at <= in, leave only above out)
    if t == "enemy" then
        if s > -36 then t = "distrust" else return "enemy" end
    end
    if t == "distrust" then
        if s <= -50 then return "enemy" end
        if s > -6 then t = floor or "acquaintance" else return "distrust" end
    end
    if s <= -50 then return "enemy" end
    if s <= -15 then
        if (row.cf or 0) >= 2 and s > -45 then return "rival" end
        return "distrust"
    end
    -- conflicts between neutrals make rivals
    if (row.cf or 0) >= 2 and s <= 5 and s > -45 and (rankOf[t] or 0) <= 2 then return "rival" end
    -- positive ladder: up when s >= in; down one step only when s < out
    local cur = rankOf[t]
    if cur == nil then -- comrade / ally act as a floor until the score earns a warmer word
        cur = 1
        if s >= 38 then cur = 3 elseif s < -6 then return t end
        if cur == 1 then return t end
    end
    local target = cur
    for _, step in ipairs(M.bondUp) do
        local r = rankOf[step[1]]
        if r > target and s >= step[2] then target = r end
    end
    if target == cur then
        while target > 0 do
            local step = nil
            for _, st in ipairs(M.bondUp) do if rankOf[st[1]] == target then step = st end end
            if step and s < step[3] then target = target - 1 else break end
        end
        if target == 0 and (row.th or 0) >= 1 then target = 1 end
    end
    local word = "stranger"
    for k, v in pairs(rankOf) do if v == target then word = k end end
    if target <= 1 and floor then word = floor end
    -- romance can grow out of a close friendship
    if (word == "buddy" or word == "best friend" or word == "friend") and s >= 45 and (row.tg or 0) >= 6 then
        local ra, rb = romantic(a), romantic(b)
        if ra + rb >= 1.1 and M.hashRoll and M.hashRoll(tostring(a) .. tostring(b), "crush" .. math.floor(h / 24), 100) < 35 then
            row.c = tostring(ra >= rb and a or b)
            return "crush"
        end
    end
    return word
end

function M.bondRetype(row, a, b, why, delta)
    local old = row.t
    if old == nil then return end
    if old == "comrade" or old == "ally" then row.g = row.g or old end
    if old == "crush" and (tonumber(row.s) or 0) >= 55 then
        row.rp = (row.rp or 0) + ((M.hashRoll and M.hashRoll(tostring(a) .. tostring(b), "rp" .. math.floor(hours()), 100) < 30) and 1 or 0)
    end
    local t = M.bondTypeFor(row, a, b, why, delta)
    if t ~= old then row.t = t; row.tc = hours() end
end

M.bondPhrase = {
    up = "grew closer", down = "drifted apart", respect = "came to grudgingly respect each other", crush = "fell for",
    partner = "got together", ex = "broke up", enemy = "became enemies", rival = "turned into rivals", distrust = "stopped trusting each other",
}
-- every type change: interaction log on both, ambient news, a rumor when notable
function M.bondChanged(a, b, old, new, why, row)
    if old == new then return end
    local ra, rb = rec(a), rec(b)
    local na, nb = nameOf(ra), nameOf(rb)
    local up = (rankOf[new] or (new == "respect" and 1.5) or (new == "crush" and 3) or (new == "partner" and 5) or -1)
        > (rankOf[old] or (old == "respect" and 1.5) or (old == "crush" and 3) or (old == "partner" and 5) or -1)
    local verb = M.bondPhrase[new] or (up and M.bondPhrase.up or M.bondPhrase.down)
    local reason = (type(why) == "string" and why ~= "") and (" after " .. why) or ""
    local text
    if new == "crush" then text = nameOf(rec(row.c)) .. " fell for " .. (tostring(row.c) == tostring(a) and nb or na)
    else text = na .. " and " .. nb .. " " .. verb .. reason end
    local tw = function(t) return (M.typeWords and M.typeWords[t]) or t end
    if M.logInteraction then
        pcall(M.logInteraction, a, text .. " (" .. tw(old) .. " -> " .. tw(new) .. ")", nil, nil, "bond")
        pcall(M.logInteraction, b, text .. " (" .. tw(old) .. " -> " .. tw(new) .. ")", nil, nil, "bond")
    end
    local news = bucket("bondNews")
    news[#news + 1] = { a = tostring(a), b = tostring(b), t = text, h = hours(), n = new, o = old }
    while #news > M.bondCfg.newsKeep do table.remove(news, 1) end
    log("bond: " .. text .. " (" .. tostring(old) .. " -> " .. tostring(new) .. ")")
    local notable = new == "partner" or new == "ex" or new == "enemy" or new == "best friend" or new == "respect" or new == "rival"
    if notable and M.addDeed then
        local x, y = posOf(shellOf(a))
        pcall(M.addDeed, "bond", text, 0, { tostring(a), tostring(b) }, x, y)
    end
end

-- recent news about the people in this talk (ambient / pair prompts)
function M.bondNewsFor(uids)
    local want = {}
    for _, u in ipairs(uids or {}) do want[tostring(u)] = true end
    local out, h = {}, hours()
    local news = bucket("bondNews")
    for i = #news, 1, -1 do
        local n = news[i]
        if h - (n.h or 0) <= M.bondCfg.newsH and (want[n.a] or want[n.b]) then out[#out + 1] = n.t end
        if #out >= 2 then break end
    end
    return out
end

-- compatibility 0.2..1.6 from personas (simple: forgiving + positive types get along)
local function compat(a, b)
    local ma = M.personaMods and M.personaMods(a) or nil
    local mb = M.personaMods and M.personaMods(b) or nil
    if ma == nil or mb == nil then return 1 end
    local pos = ((tonumber(ma.pos) or 1) + (tonumber(mb.pos) or 1)) / 2
    local neg = ((tonumber(ma.neg) or 1) + (tonumber(mb.neg) or 1)) / 2
    return clamp(pos / neg, 0.2, 1.6)
end

-- the loaded NPCs (bounded)
function M.bondLoaded()
    local pa = PA()
    local out = {}
    local player = ALifeSide.you()
    local px, py, pz = posOf(player)
    if px ~= nil and M.nearbyNpcs then
        for _, l in ipairs(M.nearbyNpcs(px, py, pz, 70)) do
            if #out >= M.bondCfg.maxLoaded then break end
            out[#out + 1] = l
        end
    end
    return out
end

-- danger episodes: World (horde) and Hostile (fighters) report; resolved after a quiet spell
M.bondDangerNow = nil
function M.bondDanger(kind, uids, now)
    if M.settings.bonds == false then return end
    now = now or M.nowMs()
    local d = M.bondDangerNow or { at = now, uids = {}, kind = kind, player = false }
    d.last = now
    if kind == "horde" or d.kind == nil then d.kind = kind end
    for _, u in ipairs(uids or {}) do d.uids[tostring(u)] = true end
    M.bondDangerNow = d
end

local function dayKey() return math.floor(hours() / 24) end
local function capAdd(row, field, amount, cap)
    local dk = dayKey()
    if row.dk ~= dk then row.dk = dk; row.dd = 0; row.pd = 0 end
    local room = cap - (row[field] or 0)
    if room <= 0 then return 0 end
    local add = math.min(room, amount)
    row[field] = (row[field] or 0) + add
    return add
end

function M.bondEvent(a, b, kind, why)
    if M.settings.bonds == false or M.pairRow == nil then return nil end
    local row = M.pairRow(a, b)
    if row == nil then return nil end
    if kind == "danger" then
        row.dz = (row.dz or 0) + 1
        return M.pairBump(a, b, M.bondCfg.dangerGain, why or "surviving the horde together")
    elseif kind == "loot" then
        row.cf = (row.cf or 0) + 1
        return M.pairBump(a, b, -6, why or "a fight over loot")
    elseif kind == "insult" then
        row.cf = (row.cf or 0) + 1
        return M.pairBump(a, b, -4, why or "an insult")
    elseif kind == "betrayal" then
        row.cf = (row.cf or 0) + 2
        return M.pairBump(a, b, -35, why or "a betrayal")
    elseif kind == "slander" then
        row.cf = (row.cf or 0) + 1
        return M.pairBump(a, b, -8, why or "what they said behind their back")
    end
    return nil
end

function M.bondDangerResolve(now)
    local d = M.bondDangerNow
    if d == nil or now - (d.last or 0) < M.bondCfg.dangerQuietMs then return end
    M.bondDangerNow = nil
    local alive = {}
    for u in pairs(d.uids) do
        local r = rec(u)
        if r and r.lifecycle ~= "dead" then alive[#alive + 1] = u end
    end
    table.sort(alive)
    local why = d.kind == "horde" and "the horde" or "the fight"
    for i = 1, math.min(#alive, 8) - 1 do
        for j = i + 1, math.min(#alive, 8) do M.bondEvent(alive[i], alive[j], "danger", why) end
    end
    -- the player stood with them
    local player = ALifeSide.you()
    local pa = PA()
    if player and M.origAdjust and pa and pa.NpcOpinion then
        for _, u in ipairs(alive) do
            local r = rec(u)
            if r then
                pcall(M.origAdjust, r, player, M.bondCfg.playerDanger, "survived " .. why .. " together")
                local pt = bucket("ptie")[tostring(u)] or {}
                pt.dz = (pt.dz or 0) + 1
                bucket("ptie")[tostring(u)] = pt
                if M.logInteraction then pcall(M.logInteraction, u, "Survived " .. why .. " with you", nil, nil, "bond") end
            end
        end
    end
end

-- every ten minutes: together time + danger resolution
function M.bondTen()
    if M.settings.bonds == false or M.pairRow == nil then return end
    M.bondInstall()
    local now, h = M.nowMs(), hours()
    pcall(M.bondDangerResolve, now)
    local list = M.bondLoaded()
    local c = M.bondCfg
    local pa = PA()
    for i = 1, #list do
        local la = list[i]
        local ax, ay = posOf(la.shell)
        for j = i + 1, #list do
            local lb = list[j]
            local bx, by = posOf(lb.shell)
            if ax and bx and (ax - bx) ^ 2 + (ay - by) ^ 2 <= c.togetherTiles ^ 2 then
                local a, b = la.record.uid, lb.record.uid
                local row = M.pairRow(a, b)
                if row then
                    row.lt = h
                    row.tg = (row.tg or 0) + 1 / 6
                    if row.tg >= 1 then row.th = 1 end
                    local hostile = false
                    if fn(pa.Relations, "status") then
                        local ok, st = pcall(pa.Relations.status, la.record, lb.record)
                        hostile = ok and st == "hostile"
                    end
                    if hostile and (tonumber(row.s) or 0) > 10 and not row.btr then
                        row.btr = true
                        M.bondEvent(a, b, "betrayal", "turning on each other")
                    elseif not hostile then
                        row.btr = nil
                        if (tonumber(row.s) or 0) > -40 then
                            local add = capAdd(row, "dd", c.togetherGain * compat(a, b), c.dailyCap)
                            if add > 0 then M.pairBump(a, b, add, nil) end
                        end
                    end
                end
            end
        end
    end
    -- the player keeping company (silent, capped)
    local player = ALifeSide.you()
    local px, py = posOf(player)
    if player and px and M.origAdjust then
        for _, l in ipairs(list) do
            local x, y = posOf(l.shell)
            if x and (x - px) ^ 2 + (y - py) ^ 2 <= c.togetherTiles ^ 2 then
                local pt = bucket("ptie")[tostring(l.record.uid)] or {}
                bucket("ptie")[tostring(l.record.uid)] = pt
                pt.lt = h
                local stance = fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) or nil
                if stance ~= "hostile" then
                    local add = capAdd(pt, "pd", c.playerGain, c.playerDailyCap)
                    if add > 0 then pcall(M.origAdjust, l.record, player, add, "time together") end
                end
            end
        end
    end
end

-- hourly: separation drift + grudge decay (pairs), personality-shaped opinion decay (player)
M.bondCursor = 0
function M.bondHour()
    if M.settings.bonds == false or M.pairRow == nil then return end
    local h = hours()
    local c = M.bondCfg
    local map = bucket("pairs")
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local row = map[key]
        local a, b = string.match(key, "^(.-)|(.*)$")
        local s = tonumber(row.s) or 0
        if type(row) == "table" and a and not row.fx and row.t ~= "nemesis" then
            local delta = 0
            if s < 0 and h - (row.nb or -1e9) >= c.grudgePauseH then
                local fg = (forgiveOf(a) + forgiveOf(b)) / 2 -- 0.1 (petty / vengeful) .. 1 (forgiving)
                delta = math.min(-s, c.grudgeBasePerH * (0.2 + fg * 1.6))
            elseif s > 0 and h - (row.lt or h) > c.apartH then
                delta = -math.min(s, c.driftPerH)
            end
            if delta ~= 0 then
                row.cf = (s < 0 and delta > 0 and (row.cf or 0) > 0 and h - (row.nb or -1e9) > 72) and (row.cf - 1) or row.cf
                M.pairBump(a, b, delta, nil)
            end
        end
    end
    -- player side: vengeful types hold on (counter A-Life's own decay), forgiving types let go faster
    local player = ALifeSide.you()
    local pa = PA()
    if player and M.origAdjust and pa and fn(pa.NpcOpinion, "valueOf") and fn(pa.NpcOpinion, "decay") then
        local per = (tonumber((pa.NpcOpinion.decay())) or 3) / 24
        local ids = {}
        for uid in pairs(bucket("persona")) do ids[#ids + 1] = uid end
        table.sort(ids)
        local n = #ids
        local budget = math.min(n, c.playerBudget)
        for k = 1, budget do
            M.bondCursor = (M.bondCursor % math.max(1, n)) + 1
            local uid = ids[M.bondCursor]
            local r = rec(uid)
            if r and r.lifecycle ~= "dead" then
                local okV, v = pcall(pa.NpcOpinion.valueOf, r, player)
                if okV and type(v) == "number" and v < -5 then
                    local fg = forgiveOf(uid)
                    local extra = (fg - 0.5) * 2 * per -- -per .. +per
                    if math.abs(extra) > 0.01 then pcall(M.origAdjust, r, player, extra, nil) end
                end
            end
        end
    end
end

-- player tie with hysteresis (special types on top: respect after danger)
M.ptieLadder = { { "best friend", 71, 62 }, { "buddy", 41, 33 }, { "friend", 16, 9 } }
function M.bondWrapTie()
    if not M.playerTie or M._ptieWrapped then return end
    M._ptieWrapped = true
    local orig = M.playerTie
    M.playerTie = function(r, player)
        local t, v = orig(r, player)
        if M.settings.bonds == false or r == nil then return t, v end
        local pt = bucket("ptie")[tostring(r.uid)]
        if pt == nil then pt = {}; bucket("ptie")[tostring(r.uid)] = pt end
        local prev = pt.t
        if t == "nemesis" or t == "ally" then pt.t = t; return t, v end
        -- 0.5.1.6: unreadable opinion (far away / unloaded / re-rendered) never moves the tie
        if tonumber(v) == nil or r.lifecycle == "dead" then return prev or t, v end
        v = tonumber(v)
        -- stay on the previous rung until we fall below its 'out' line
        if prev then
            for _, st in ipairs(M.ptieLadder) do
                if prev == st[1] and v >= st[3] and (rankOf[t] or 0) < rankOf[prev] then t = prev end
            end
            if prev == "distrust" and v <= -9 and v > -16 then t = "distrust" end
        end
        if (pt.dz or 0) >= 1 and v > -16 and v < 16 and prev ~= "friend" then
            local okK = false
            pcall(function() okK = M.playerKnows(r.uid, player) end)
            if okK and v >= 0 then t = "respect" end
        end
        if prev ~= nil and prev ~= t and M.logInteraction then
            pcall(M.logInteraction, r.uid, "Their view of you changed: " .. tostring(prev) .. " -> " .. tostring(t), nil, nil, "bond")
        end
        pt.t = t
        return t, v
    end
end

-- conflicts ---------------------------------------------------------------------------------------------------
-- loot: A-Life's body looting (observed only - Loot.take runs unchanged); greedy same-group watchers resent it
function M.bondWrapLoot()
    local pa = PA()
    local L = pa and pa.BodyLoot
    if not fn(L, "take") or L.take == M.bondLootWrap then return false end
    local orig = L.take
    M.bondLootOrig = orig
    M.bondLootWrap = function(actor, shell, state)
        local taken, event = orig(actor, shell, state)
        if M.settings.bonds ~= false and (tonumber(taken) or 0) > 0 and type(actor) == "table" then
            pcall(function()
                local x, y, z = posOf(shell)
                local gid = type(actor.memory) == "table" and actor.memory.groupId or nil
                for _, l in ipairs(M.nearbyNpcs(x, y, z, 8, actor.uid)) do
                    local mods = M.personaMods and M.personaMods(l.record.uid) or nil
                    local greedy = mods and (tonumber(mods.greed) or 0) >= 0.5
                    local mate = gid ~= nil and type(l.record.memory) == "table" and l.record.memory.groupId == gid
                    if greedy and mate then M.bondEvent(l.record.uid, actor.uid, "loot", "a fight over loot") end
                end
            end)
        end
        return taken, event
    end
    L.take = M.bondLootWrap
    return true
end

-- NPC <-> NPC talk changes the pair bond (0.5.1). The bridge tags each NPC-NPC line (pair=JOKE/SUPPORT/FRIENDLY/NEUTRAL/
-- ARGUE/MOCK/INSULT/THREAT, pd=delta); without it a keyword fallback. The listener's personality scales it: thin-skinned
-- (mods.neg high) take insults harder, forgiving ones softer; warm ones (mods.pos) enjoy kindness more.
M.insultWords = { "idiot", "moron", "stupid", "useless", "pathetic", "coward", "shut up", "shut your", "screw you",
    "hate you", "dumbass", "freak", "loser", "worthless", "get lost", "piece of" }
M.pairTagWords = {
    { "THREAT", -6, { "i'll kill you", "i'll hurt you", "watch your back", "or else", "you're dead" } },
    { "INSULT", -4, M.insultWords },
    { "MOCK", -3, { "real smart", "nice going", "genius", "tough guy", "big man", "crybaby" } },
    { "ARGUE", -2, { "you're wrong", "no way", "that's crap", "says who", "your fault", "back off", "whatever" } },
    { "SUPPORT", 3, { "got your back", "we'll make it", "i'm here", "thank you", "thanks", "proud of you", "good job", "don't worry", "you okay" } },
    { "JOKE", 2, { "haha", "heh", "kidding", "funny", "remember when" } },
    { "FRIENDLY", 1, { "buddy", "pal", "good to see", "how you holding", "nice" } },
}
M.pairTagVerb = { THREAT = "threatened", INSULT = "insulted", MOCK = "mocked", ARGUE = "argued with", SUPPORT = "backed up",
    JOKE = "joked around with", FRIENDLY = "had a friendly word with", NEUTRAL = "talked with" }
function M.isInsult(text)
    text = string.lower(tostring(text or ""))
    for _, w in ipairs(M.insultWords) do if string.find(text, w, 1, true) then return true end end
    return false
end
function M.pairTagLocal(text)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    for _, row in ipairs(M.pairTagWords) do
        for _, w in ipairs(row[3]) do if string.find(low, w, 1, true) then return row[1], row[2] end end
    end
    return "NEUTRAL", 0
end
function M.pairTalkDelta(listenerUid, raw)
    raw = tonumber(raw) or 0
    if raw == 0 then return 0 end
    local mods = M.personaMods and M.personaMods(listenerUid) or nil
    local neg, pos, fg = 1, 1, 0.5
    if mods then neg, pos, fg = tonumber(mods.neg) or 1, tonumber(mods.pos) or 1, tonumber(mods.forgive) or 0.5 end
    local d
    if raw < 0 then d = raw * neg * (1.3 - fg * 0.6) else d = raw * pos end
    d = clamp(d, -10, 6)
    if math.abs(d) < 1 then d = d < 0 and -1 or 1 end
    return math.floor(d + (d > 0 and 0.5 or -0.5))
end
M.pairTalkCap = {}
function M.notePairLine(job, text, r)
    if M.settings.bonds == false or job == nil or job.uid == nil or job.speakerUid == nil or M.pairRow == nil then return nil end
    local speaker, listener = tostring(job.uid), tostring(job.speakerUid) -- job.uid just spoke to job.speakerUid
    if speaker == listener or listener == "player" then return nil end
    local tag, raw = nil, nil
    if type(r) == "table" and type(r.pair) == "string" and M.pairTagVerb[r.pair] then tag, raw = r.pair, tonumber(r.pd) or 0 end
    if tag == nil then tag, raw = M.pairTagLocal(text) end
    local d = M.pairTalkDelta(listener, raw)
    if d == 0 then return tag, 0 end
    -- small daily cap per pair so a chatty pair doesn't max out in an evening
    local row = M.pairRow(speaker, listener)
    if row == nil then return tag, 0 end
    local dk = math.floor(hours() / 24)
    if row.tk ~= dk then row.tk, row.tp, row.tn = dk, 0, 0 end
    if d > 0 then d = math.min(d, 10 - (row.tp or 0)); row.tp = (row.tp or 0) + math.max(0, d)
    else d = math.max(d, -20 - (row.tn or 0)); row.tn = (row.tn or 0) + math.min(0, d) end
    if d == 0 then return tag, 0 end
    if d < 0 and (tag == "INSULT" or tag == "MOCK" or tag == "THREAT" or tag == "ARGUE") then row.cf = (row.cf or 0) + 0.5 end
    local ra, rb = rec(speaker), rec(listener)
    local na, nb = nameOf(ra), nameOf(rb)
    local after = M.pairBump(speaker, listener, d, (M.pairTagVerb[tag] or "talked with") .. " " .. nb)
    local line = na .. " " .. (M.pairTagVerb[tag] or "talked with") .. " " .. nb .. ": " .. (d > 0 and "+" or "") .. tostring(d)
    if tag == "JOKE" then line = na .. " and " .. nb .. " joked around: " .. (d > 0 and "+" or "") .. tostring(d) end
    if M.logInteraction then
        pcall(M.logInteraction, speaker, line, nil, nil, "bond")
        pcall(M.logInteraction, listener, line, nil, nil, "bond")
    end
    if M.feel then
        if d < 0 then M.feel(listener, tag == "THREAT" and "fear" or "anger", math.min(0.4, -d / 15), na .. " " .. M.pairTagVerb[tag] .. " them")
        else M.feel(listener, "joy", math.min(0.3, d / 15), na .. " was kind") end
    end
    if M.showPairPopup and after then pcall(M.showPairPopup, listener, na, d, tonumber(after.s) or 0) end
    log("pair talk: " .. line)
    return tag, d
end

-- slander: a rumor one NPC spread about another reaches the victim
function M.slander(byUid, aboutUid, text, witnesses)
    if not M.addDeed then return nil end
    local r = M.addDeed("slander", text, 0, witnesses or { tostring(byUid) })
    if r then r.pa, r.pv = tostring(byUid), tostring(aboutUid) end
    return r
end
function M.bondWrapRumor()
    if not M.learnRumor or M._bondRumorWrapped then return end
    M._bondRumorWrapped = true
    local orig = M.learnRumor
    M.learnRumor = function(r, uid, hop)
        local learned = orig(r, uid, hop)
        if learned and type(r) == "table" and r.pv ~= nil and tostring(uid) == r.pv and r.pa then
            M.bondEvent(r.pv, r.pa, "slander", "hearing what " .. nameOf(rec(r.pa)) .. " said about them")
        end
        return learned
    end
end

-- ambient / pair prompts: what changed between them lately
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.bonds == false then return end
    local ids = { listener.record.uid }
    if req.speakerUid then ids[#ids + 1] = req.speakerUid end
    local news = M.bondNewsFor(ids)
    if #news > 0 then req.bondNews = news end
end)

-- files after this one (Social) define what we wrap: install lazily (load, game start, first ticks)
function M.bondInstall()
    pcall(M.bondWrapTie); pcall(M.bondWrapRumor); pcall(M.bondWrapLoot)
end
local function hookEvents()
    if type(Events) ~= "table" then return end
    if Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeLLMTalk_PairsLife", function() local ok, e = pcall(M.bondTen); if not ok then log("bonds: " .. tostring(e)) end end) end
    if Events.EveryHours then ALifeHealth.add(Events.EveryHours, "ALifeLLMTalk_PairsLife", function() local ok, e = pcall(M.bondHour); if not ok then log("bonds: " .. tostring(e)) end end) end
    if Events.OnGameStart then Events.OnGameStart.Add(function() M.bondInstall() end) end
end
hookEvents()
M.bondInstall()

return M
