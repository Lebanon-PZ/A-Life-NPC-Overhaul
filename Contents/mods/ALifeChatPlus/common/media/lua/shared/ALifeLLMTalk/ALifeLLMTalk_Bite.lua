-- A-Life Talk 0.5.2.10 [pt270u]: A BITE IS THE BIGGEST THING IN THEIR LIFE - and the group finds out.
-- "josh got bit but doesnt care and its not like the menus go into it" / "shouldnt he confide in his partner and she
-- should react depending on who she is ... him and tom are rivals so tom might talk shit or be like he needs to go".
-- (1) the bitten NPC: a never-cut prompt core ("You were BITTEN ... almost always means death"), a mood that stays
--     scared and hopeless while it lasts, a reaction that always happens (hide it / pray / ask for help, from who
--     they are), amputation talk when The Only Cure+ is in the game.
-- (2) who knows: witnesses saw it. The bitten one CONFIDES in trust order (partner, then family / best friend, then
--     the player if bonded) - or tells only the partner, or hides it - from their personality. Everyone who knows
--     passes it on once along their own close ties, from a named source ("heard from Viola"), rate limited.
-- (3) each knower takes a STANCE from the tie and their own personality: a partner breaks down / denies / clings /
--     goes cold and practical / turns protective (keeps it quiet, threatens anyone who comes near him); friends and
--     family worry and offer help; rivals and nemeses want him gone ("he needs to go"), the cruel ones gloat; the
--     rest of the group wants him quarantined. A rival who wants him out and a partner who protects him fall out
--     (pair score, a grudge line both remember): the group splits. The player hears it as overheard arguments.
-- (4) menus: INJURIES puts the bite first, red, with the time; a red BITTEN pill on the portrait (Overview, Bond,
--     every tab), the list row and the Web node.
-- Data: ModData bucket "bites" = { [victim] = { h, spot, mode, src, knows = { [uid] = { s = how, f = from, h, st } },
-- told = { order }, pl = player knows, ag = last argument hour, sp = last spread hour, split } }. No per-frame work:
-- the spread step runs from the injury tick (every few seconds, one step per victim per gap).
-- Settings: biteCore (the self / witness core, mood, reactions, menus), biteSpread (confide + news + stances).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Bite") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Bite"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Bite") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function shellOf(uid) local pa = PA(); local s = nil; pcall(function() s = pa.Talk.shellFor(tostring(uid)) end); return s end
local function dataOf(shell) local d = nil; pcall(function() d = shell:getModData() end); return type(d) == "table" and d or nil end
local function nameOf(uid)
    local pa, r = PA(), rec(uid)
    local n = nil
    if r and fn(pa and pa.Names, "of") then pcall(function() n = pa.Names.of(r) end) end
    if n == nil then local e = bucket("book")[tostring(uid)]; n = type(e) == "table" and e.name or nil end
    return tostring(n or "someone")
end
local function firstOf(name) return string.match(tostring(name), "^(%S+)") or tostring(name) end
local function dead(uid)
    local r = rec(uid)
    if type(r) == "table" and r.lifecycle == "dead" then return true end
    if M.isPersonDead then local ok, d = pcall(M.isPersonDead, uid); if ok and d then return true end end
    return false
end

M.biteCfg = { keepH = 168, fearFloor = 0.45, despairFloor = 0.4, spreadGapH = 0.5, argueGapH = 2, maxKnow = 14,
    spreadTies = { partner = 1, sibling = 2, parent = 2, child = 2, ["best friend"] = 2, buddy = 3, friend = 3, comrade = 4,
        crush = 3, admirer = 3, ally = 4, rival = 4, nemesis = 5, enemy = 5, distrust = 5, acquaintance = 5, respect = 4, ex = 4 } }

-- who they are, as words (persona traits + quirk; the test stub gives core.traits = { key })
function M.biteTraits(uid)
    local p = M.partsOf and M.partsOf(uid) or nil
    local t = {}
    if p and p.core and type(p.core.traits) == "table" then for _, x in ipairs(p.core.traits) do t[#t + 1] = tostring(x) end end
    if p and p.core and p.core.key then t[#t + 1] = tostring(p.core.key) end
    if p and p.quirk then t[#t + 1] = tostring(p.quirk) end
    return " " .. string.lower(table.concat(t, " ")) .. " "
end
local function has(tr, words) for _, w in ipairs(words) do if string.find(tr, w, 1, true) then return true end end return false end
function M.biteDevout(uid)
    local l = M.lens and M.lens(uid) or {}
    return (tonumber(l.devout) or 0) >= 0.3 or has(M.biteTraits(uid), { "relig", "devout", "bible", "pray", "zealo", "church", "fervent" })
end
-- how they deal with their own bite: "hide" (nobody but witnesses), "partner" (only the partner), "all"
function M.biteMode(uid)
    local tr = M.biteTraits(uid)
    if has(tr, { "liar", "two-faced", "secretive", "self-preserving", "manipulat", "scheming", "paranoid", "calculating" }) then return "hide" end
    if has(tr, { "proud", "guarded", "stoic", "shy", "withdrawn", "quiet", "silent", "distrustful", "slow to trust", "stubborn" }) then return "partner" end
    return "all"
end

-- their ties as { uid, type, word, score, dead } (no player filter: names are real)
local function tiesAll(uid)
    if not M.tiesOf then return {} end
    local ok, list = pcall(M.tiesOf, uid, nil, nil, true)
    return ok and type(list) == "table" and list or {}
end
function M.livingPartners(uid)
    local out = {}
    for _, t in ipairs(tiesAll(uid)) do if t.type == "partner" and not t.dead then out[#out + 1] = t end end
    return out
end
local function tieType(a, b)
    if M.pairRow and M.pairTypeFor then
        local row = M.pairRow(a, b, false)
        if row then return M.pairTypeFor(row, a, b), tonumber(row.s) or 0 end
    end
    return "stranger", 0
end

----------------------------------------------------------------------------------------------------------------
-- is this person bitten? (cheap: our record, A-Life's infection flags, their own memory)
----------------------------------------------------------------------------------------------------------------
local function memBite(uid)
    local km = M.keyMemOf and M.keyMemOf(uid) or {}
    local me = nameOf(uid)
    for i = #km, 1, -1 do
        local e = km[i]
        local t = tostring(e.t or "")
        if string.find(t, "^Got a bite") or (e.k == "bite" and string.find(t, "Saw: " .. me .. " got bitten", 1, true)) then
            local spot = string.match(t, "on the ([%a ]+)")
            if spot then spot = string.gsub(spot, "%s+$", "") end
            return { h = tonumber(e.h), spot = spot }
        end
    end
    return nil
end
function M.biteInfo(uid)
    if M.settings.biteCore == false or uid == nil or uid == "player" then return nil end
    uid = tostring(uid)
    local h = hours()
    local b = bucket("bites")[uid]
    if type(b) == "table" and h - (tonumber(b.h) or h) <= M.biteCfg.keepH then
        if dead(uid) then return nil end
        return { spot = b.spot, ageH = h - b.h, at = b.h, row = b }
    end
    local shell = shellOf(uid)
    local data = shell and dataOf(shell) or nil
    local r = rec(uid)
    local infected = (data ~= nil and data.ProjectALifeTurnAtHours ~= nil)
        or (type(r) == "table" and type(r.memory) == "table" and r.memory.infectedTurnAtHours ~= nil)
    local m = memBite(uid)
    if m and m.h and h - m.h > M.biteCfg.keepH then m = nil end
    if not infected and m == nil then return nil end
    if dead(uid) then return nil end
    local at = m and m.h or h
    return { spot = m and m.spot or nil, ageH = h - at, at = at, infected = infected }
end

-- the bite row (created on the fresh bite, or once from an old save's memories)
function M.biteRow(uid, create)
    uid = tostring(uid)
    local all = bucket("bites")
    local b = all[uid]
    if type(b) == "table" then b.knows = type(b.knows) == "table" and b.knows or {}; b.told = type(b.told) == "table" and b.told or {}; return b end
    if not create then return nil end
    local bi = M.biteInfo(uid)
    if bi == nil then return nil end
    b = { h = bi.at, spot = bi.spot, mode = M.biteMode(uid), knows = {}, told = {}, src = "memory" }
    all[uid] = b
    return b
end

function M.biteKnow(victim, who, how, from, stance)
    local b = M.biteRow(victim, false)
    if b == nil or who == nil then return false end
    who = tostring(who)
    if who == tostring(victim) then return false end
    if b.knows[who] ~= nil then return false end -- nobody gets the news twice
    b.knows[who] = { s = how, f = from, h = hours(), st = stance }
    return true
end

----------------------------------------------------------------------------------------------------------------
-- stances: from the tie and who THEY are
----------------------------------------------------------------------------------------------------------------
M.biteStanceText = {
    breakdown = "you break down: tears, panic, you can't lose them too; you beg anyone (the newcomer too) for help",
    denial = "denial: it's just a scratch, it can't be a bite, people survive these - you won't hear otherwise",
    clinging = "you won't leave their side; you cling to them and to every hour you still have together",
    practical = "cold and practical: you both know what has to happen; you make plans for the end, quietly",
    protective = "fiercely protective: you keep it quiet, you'd threaten anyone who comes near them, nobody touches them",
    worry = "worried sick: you offer help (clean it, cut it off if it comes to that, stay with them), and you're scared",
    exile = "contempt: they're a dead man walking and a danger to everyone - they need to go (exile, or put them down)",
    gloat = "you gloat: they had it coming; you want them out before they turn and say so to anyone",
    quarantine = "fear for the group: keep them apart, lock them up, watch for the fever - and be ready to do it",
}
function M.biteStance(who, victim)
    local t, s = tieType(who, victim)
    local tr = M.biteTraits(who)
    local cruel = has(tr, { "cruel", "sadistic", "bully", "mean", "spiteful", "petty", "vengeful", "amused by pain", "smug" })
    if t == "partner" then
        if has(tr, { "cold", "pragmatic", "stoic", "calculating", "detached", "professional", "by-the-book", "disciplined", "hard-nosed", "ruthless" }) then return "practical", t end
        if has(tr, { "protective", "possessive", "fiery", "hot-headed", "fearless", "devoted", "loyal" }) then return "protective", t end
        if has(tr, { "stubborn", "optimistic", "naive", "idealistic", "delusional", "dreamy" }) then return "denial", t end
        if has(tr, { "lonely", "insecure", "clingy", "fragile", "sensitive", "tender" }) then return "clinging", t end
        return ({ "breakdown", "denial", "clinging", "breakdown" })[hash(tostring(who) .. "#bitestance") % 4 + 1], t
    end
    if t == "rival" or t == "nemesis" or t == "enemy" or t == "distrust" or s <= -20 then return cruel and "gloat" or "exile", t end
    if t == "sibling" or t == "parent" or t == "child" or t == "best friend" or t == "friend" or t == "buddy" or t == "crush" or t == "admirer" then return "worry", t end
    if cruel then return "exile", t end
    return "quarantine", t
end

-- what the stance does: feelings, the pair, a grudge both remember when a rival wants him gone and a partner protects him
function M.biteStanceFx(who, victim, stance)
    if M.feel then
        if stance == "breakdown" or stance == "clinging" or stance == "denial" then
            M.feel(who, "fear", 0.55, nameOf(victim) .. " is bitten"); M.feel(who, "despair", 0.45, nameOf(victim) .. " is bitten")
        elseif stance == "practical" or stance == "protective" then
            M.feel(who, "dread", 0.5, nameOf(victim) .. " is bitten"); M.feel(who, "grief", 0.3, nameOf(victim) .. " will turn")
        elseif stance == "worry" then M.feel(who, "anxiety", 0.45, nameOf(victim) .. " is bitten")
        elseif stance == "exile" or stance == "gloat" or stance == "quarantine" then M.feel(who, "fear", 0.3, nameOf(victim) .. " could turn") end
    end
    if (stance == "exile" or stance == "gloat") and M.pairBump then pcall(M.pairBump, who, victim, -10, "wants them gone - bitten") end
    if stance == "protective" or stance == "clinging" or stance == "breakdown" then
        if M.pairBump then pcall(M.pairBump, who, victim, 5, "stood by them when bitten") end
    end
    M.biteSplitCheck(victim)
end

-- a rival who wants them gone vs someone who protects them: they fall out (once per pair)
function M.biteSplitCheck(victim)
    local b = M.biteRow(victim, false)
    if b == nil then return end
    b.split = type(b.split) == "table" and b.split or {}
    local out, keep = {}, {}
    for u, k in pairs(b.knows) do
        if u ~= "player" and (k.st == "exile" or k.st == "gloat") then out[#out + 1] = u end
        if u ~= "player" and (k.st == "protective" or k.st == "breakdown" or k.st == "clinging" or k.st == "denial") then keep[#keep + 1] = u end
    end
    table.sort(out); table.sort(keep)
    for _, a in ipairs(out) do
        for _, c in ipairs(keep) do
            local key = a .. ">" .. c
            if not b.split[key] then
                b.split[key] = hours()
                if M.pairBump then pcall(M.pairBump, a, c, -15, "fell out over " .. firstOf(nameOf(victim)) .. "'s bite") end
                if M.keyMem then
                    pcall(M.keyMem, c, "insult", nameOf(a) .. " wants " .. firstOf(nameOf(victim)) .. " gone - bitten")
                    pcall(M.keyMem, a, "event", nameOf(c) .. " is protecting " .. firstOf(nameOf(victim)) .. " - bitten")
                end
                log("bite: " .. nameOf(a) .. " vs " .. nameOf(c) .. " over " .. nameOf(victim))
            end
        end
    end
end

local function learn(victim, who, how, from)
    if who == "player" then
        local b = M.biteRow(victim, false)
        if b and not b.pl then b.pl = how; return true end
        return false
    end
    if dead(who) then return false end
    local stance = M.biteStance(who, victim)
    if not M.biteKnow(victim, who, how, from, stance) then return false end
    local vn = nameOf(victim)
    local line = (how == "saw" and ("Saw: " .. vn .. " got bitten")) or (how == "told" and (vn .. " told me they're bitten"))
        or ("Heard from " .. tostring(from) .. ": " .. vn .. " is bitten")
    local b = M.biteRow(victim, false)
    if b and b.spot and how ~= "saw" then line = line .. " (" .. tostring(b.spot) .. ")" end
    if M.keyMem and how ~= "saw" then pcall(M.keyMem, who, "bite", line) end
    M.biteStanceFx(who, victim, stance)
    log("bite news: " .. nameOf(who) .. " <- " .. vn .. " [" .. tostring(how) .. (from and (", from " .. tostring(from)) or "") .. "] -> " .. tostring(stance))
    return true
end
M.biteLearn = learn

----------------------------------------------------------------------------------------------------------------
-- a fresh bite (Injury.onHurt): the row, the witnesses, the mood
----------------------------------------------------------------------------------------------------------------
function M.noteBite(uid, spot, witnessUids, playerSaw)
    if M.settings.biteCore == false then return nil end
    uid = tostring(uid)
    local all = bucket("bites")
    local b = all[uid]
    local h = hours()
    if type(b) ~= "table" or h - (tonumber(b.h) or 0) > M.biteCfg.keepH then
        b = { h = h, spot = spot, mode = M.biteMode(uid), knows = {}, told = {}, src = "fresh" }
        all[uid] = b
    end
    b.spot = b.spot or spot
    b.sp = h -- confiding starts after a short while (they have to take it in first)
    if playerSaw then b.pl = b.pl or "saw" end
    for _, w in ipairs(witnessUids or {}) do if tostring(w) ~= uid then learn(uid, tostring(w), "saw", nil) end end
    M.biteMood(uid)
    return b
end

function M.biteMood(uid)
    if not M.emoRow or not M.feel then return end
    local row = M.emoRow(uid)
    local f, d = tonumber(row.e.fear) or 0, tonumber(row.e.despair) or 0
    if f < M.biteCfg.fearFloor then M.feel(uid, "fear", M.biteCfg.fearFloor - f, "bitten - they know what it means", { raw = true }) end
    if d < M.biteCfg.despairFloor then M.feel(uid, "despair", M.biteCfg.despairFloor - d, "bitten - a death sentence", { raw = true }) end
end

-- the style of their own first reaction (Injury.lua)
function M.biteSelfStyle(uid, witnesses)
    local mode = M.biteMode(uid)
    local devout = M.biteDevout(uid)
    if mode == "hide" then return "you HIDE it: cover the wound, downplay it, lie if anyone asks - you don't want to be put down", mode end
    local s = "terror and despair - you know a bite is a death sentence"
    if devout then s = s .. "; you pray out loud, a verse maybe" end
    if mode == "partner" then s = s .. "; you keep it from the others, only your partner may know" else s = s .. "; you ask for help (cut it off? a cure?)" end
    return s, mode
end

----------------------------------------------------------------------------------------------------------------
-- the spread: confide (trust order) then the news along the ties. One step per victim per gap; called from the tick.
----------------------------------------------------------------------------------------------------------------
local function confideOrder(uid)
    local list = {}
    for _, t in ipairs(tiesAll(uid)) do
        if not t.dead then
            local r = (t.type == "partner" and 1) or ((t.type == "sibling" or t.type == "parent" or t.type == "child" or t.type == "best friend") and 2) or nil
            if r then list[#list + 1] = { uid = tostring(t.uid), r = r, s = tonumber(t.score) or 0 } end
        end
    end
    table.sort(list, function(a, b) if a.r ~= b.r then return a.r < b.r end; if a.s ~= b.s then return a.s > b.s end; return a.uid < b.uid end)
    return list
end

function M.playerBonded(uid)
    local tier = M.bondTier and M.bondTier(uid) or 1
    local v = 0
    local r, p = rec(uid), ALifeSide.you()
    if r ~= nil and p ~= nil then -- 0.7.11.2: a bitten NPC whose record is gone has no opinion to read
        pcall(function() v = ProjectALife.NpcOpinion.valueOf(r, p) or 0 end)
    end
    return (tonumber(tier) or 1) >= 3 or (tonumber(v) or 0) >= 55
end

-- one step for one victim; returns what happened ("told" / "heard" / nil)
function M.biteSpreadStep(victim, player, force)
    victim = tostring(victim)
    local b = M.biteRow(victim, true)
    if b == nil then return nil end
    local h = hours()
    if dead(victim) then return nil end
    if not force and h - (tonumber(b.sp) or -1e9) < M.biteCfg.spreadGapH then return nil end
    b.sp = h
    local vn = nameOf(victim)
    local n = 0
    for _ in pairs(b.knows) do n = n + 1 end
    if n >= M.biteCfg.maxKnow then return nil end
    -- (1) confide (by trust order); "hide" tells nobody, "partner" only partners
    if b.mode ~= "hide" then
        for _, c in ipairs(confideOrder(victim)) do
            if (b.mode == "all" or c.r == 1) and b.knows[c.uid] == nil and learn(victim, c.uid, "told", vn) then
                b.told[#b.told + 1] = c.uid
                M.biteScene("confess", victim, c.uid, player)
                return "told", c.uid
            end
        end
        if b.mode == "all" and not b.pl and M.playerBonded(victim) then
            b.pl = "told"
            b.told[#b.told + 1] = "player"
            M.biteScene("confessPlayer", victim, nil, player)
            return "told", "player"
        end
    end
    -- (2) the news: someone who knows tells one of their close ties (protective / hiding partners keep quiet)
    local knowers = {}
    for u, k in pairs(b.knows) do
        if k.st ~= "protective" and not (b.mode ~= "all" and tieType(u, victim) == "partner") then knowers[#knowers + 1] = u end
    end
    table.sort(knowers)
    local best, bestR, bestFrom = nil, 99, nil
    for _, u in ipairs(knowers) do
        if not dead(u) then
            for _, t in ipairs(tiesAll(u)) do
                local o = tostring(t.uid)
                local r = M.biteCfg.spreadTies[t.type]
                if r and not t.dead and o ~= victim and b.knows[o] == nil and (r < bestR or (r == bestR and best ~= nil and o < best)) then
                    best, bestR, bestFrom = o, r, u
                end
            end
        end
    end
    if best ~= nil and learn(victim, best, "heard", nameOf(bestFrom)) then
        M.biteScene("argue", victim, best, player)
        return "heard", best
    end
    return nil
end

-- the scenes (LLM): a confession, an argument the player overhears (rate limited per victim)
M.biteScenes = {}
function M.biteScene(kind, victim, who, player)
    local b = M.biteRow(victim, false)
    if b == nil then return false end
    local vn = nameOf(victim)
    local spot = b.spot and (" on the " .. b.spot) or ""
    local shell = shellOf(kind == "argue" and who or victim)
    if shell == nil then return false end
    local l = { record = rec(kind == "argue" and who or victim), shell = shell }
    if l.record == nil then return false end
    local h = hours()
    local react
    if kind == "confess" then
        local st = b.knows[tostring(who)] and b.knows[tostring(who)].st or "breakdown"
        react = { what = "You are telling " .. nameOf(who) .. " (your " .. tostring((tieType(victim, who))) .. ") that you were bitten" .. spot
            .. ". " .. firstOf(nameOf(who)) .. " is taking it like this: " .. tostring(M.biteStanceText[st]),
            style = "a confession, quiet and scared; one line to them", maxWords = 18 }
    elseif kind == "confessPlayer" then
        react = { what = "You confide in the newcomer: you were bitten" .. spot .. ". You trust them", style = "quiet, scared, asking for help", maxWords = 18 }
        l.face = "player"
    else
        if h - (tonumber(b.ag) or -1e9) < M.biteCfg.argueGapH then return false end
        local k = b.knows[tostring(who)]
        if k == nil then return false end
        b.ag = h
        react = { what = "You just heard from " .. tostring(k.f) .. " that " .. vn .. " is bitten" .. spot .. ". You're their "
            .. tostring((tieType(who, victim))) .. ": " .. tostring(M.biteStanceText[k.st]), style = "say it out loud to whoever is near", maxWords = 18 }
    end
    if kind == "confess" then react.dlg = { to = tostring(who), kind = "confession" } -- 0.5.2.10: Interactions (Dialogue.lua)
    elseif kind == "argue" then react.dlg = { to = tostring(victim), kind = "argument" } end
    M.biteScenes[#M.biteScenes + 1] = { kind = kind, victim = victim, who = who, what = react.what }
    while #M.biteScenes > 30 do table.remove(M.biteScenes, 1) end
    if M.react then pcall(M.react, kind == "argue" and "injury" or "injury_self", l, player, react,
        { key = "bite:" .. kind .. ":" .. tostring(victim) .. ":" .. tostring(who), keyCooldownMs = 600000, face = l.face }) end
    return true
end

function M.biteTick(player)
    if M.settings.biteCore == false or M.settings.biteSpread == false then return end
    if not bucket("biteFill").done then pcall(M.biteBackfill) end
    local all = bucket("bites")
    local h = hours()
    local ids = {}
    for u, b in pairs(all) do
        if type(b) == "table" and h - (tonumber(b.h) or 0) <= M.biteCfg.keepH then ids[#ids + 1] = u end
    end
    table.sort(ids)
    for _, u in ipairs(ids) do pcall(M.biteSpreadStep, u, player) end
end

-- old saves: bites that happened before 0.5.2.10 (Josh) get a row once, witnesses from everyone's "Saw:" memories
function M.biteBackfill()
    if M.settings.biteCore == false then return 0 end
    local st = bucket("biteFill")
    if st.done then return 0 end
    st.done = hours()
    local km = bucket("keymem")
    local victims = {}
    for uid in pairs(km) do
        local bi = M.biteInfo(uid)
        if bi ~= nil and bucket("bites")[tostring(uid)] == nil then victims[#victims + 1] = tostring(uid) end
    end
    table.sort(victims)
    for _, v in ipairs(victims) do
        local b = M.biteRow(v, true)
        if b then
            b.sp = hours()
            local pat = "Saw: " .. nameOf(v) .. " got bitten"
            for u, list in pairs(km) do
                if tostring(u) ~= v and type(list) == "table" then
                    for _, e in ipairs(list) do if string.find(tostring(e.t), pat, 1, true) then learn(v, tostring(u), "saw", nil) end end
                end
            end
            log("bite: backfilled " .. nameOf(v) .. " (" .. tostring(b.spot) .. ")")
        end
    end
    return #victims
end

----------------------------------------------------------------------------------------------------------------
-- prompt: req.biteCore = { self = {...}, others = { {...} } } -> the bridge's never-cut bite_core
----------------------------------------------------------------------------------------------------------------
function M.biteCoreFor(uid)
    if M.settings.biteCore == false then return nil end
    uid = tostring(uid)
    local out = { others = {} }
    local h = hours()
    local bi = M.biteInfo(uid)
    if bi == nil and M.woundState then
        local ok, s = pcall(M.woundState, uid)
        if ok and s and s.bitten then
            for _, w in ipairs(s.list) do if w.kind == "bite" then bi = { spot = w.part, ageH = w.ageH, at = w.at } end end
        end
    end
    if bi ~= nil then
        local b = M.biteRow(uid, true) or {}
        local told = {}
        for _, u in ipairs(b.told or {}) do told[#told + 1] = u == "player" and "the newcomer" or firstOf(nameOf(u)) end
        local amp = nil
        if M.woundsOf then
            local ok, list = pcall(M.woundsOf, uid)
            if ok then for _, w in ipairs(list or {}) do if w.kind == "amputation" then amp = w.part end end end
        end
        local limb = bi.spot ~= nil and (string.find(bi.spot, "arm") or string.find(bi.spot, "hand") or string.find(bi.spot, "leg")
            or string.find(bi.spot, "shin") or string.find(bi.spot, "foot") or string.find(bi.spot, "knee") or string.find(bi.spot, "calf")
            or string.find(bi.spot, "thigh") or string.find(bi.spot, "wrist") or string.find(bi.spot, "ankle")) ~= nil
        out.self = { spot = bi.spot, h = math.floor((bi.ageH or 0) * 10 + 0.5) / 10, mode = b.mode or M.biteMode(uid), devout = M.biteDevout(uid) or nil,
            toc = (M.compat and M.compat.onlyCure and limb) or nil, amputated = amp, told = told }
        M.biteMood(uid)
    end
    if M.settings.biteSpread ~= false then
        for v, b in pairs(bucket("bites")) do
            if type(b) == "table" and type(b.knows) == "table" and b.knows[uid] and h - (tonumber(b.h) or 0) <= M.biteCfg.keepH and not dead(v) then
                local k = b.knows[uid]
                local t = tieType(uid, v)
                local word = M.typeWord and M.typeWord(t, rec(v)) or t
                out.others[#out.others + 1] = { n = nameOf(v), w = word, spot = b.spot, h = math.floor((h - b.h) * 10 + 0.5) / 10,
                    how = k.s, from = k.f, st = k.st, stance = M.biteStanceText[k.st] }
            end
        end
        table.sort(out.others, function(a, b) return a.n < b.n end)
        while #out.others > 3 do table.remove(out.others) end
    end
    if out.self == nil and #out.others == 0 then return nil end
    return out
end

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.biteCore == false or listener == nil or listener.record == nil then return end
    local ok, bc = pcall(M.biteCoreFor, listener.record.uid)
    if ok and bc ~= nil then req.biteCore = bc end
end)

-- one-time backfill on load (and lazily from the tick)
if type(Events) == "table" and type(Events.OnGameStart) == "table" and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function() pcall(M.biteBackfill) end)
end

return M
