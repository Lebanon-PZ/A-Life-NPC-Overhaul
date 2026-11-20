-- A-Life Talk 0.5.1: when someone you knew comes back as one of them.
-- A-Life's Lifecycle.stepTurn wipes the corpse's A-Life ModData and calls reanimateLater, so the zombie that rises
-- has no identity. ALifeTalkPatch 1.3 wraps stepTurn and tells us who it was and where (hook "reanimating"); we tag
-- the zombie that gets up on that spot (same floor, within 2 tiles, same sex, not an A-Life NPC) with ModData
-- TalkWasUid / TalkWasName. Without the patch: the corpse spot from ProjectALife_NpcDied of an infected NPC.
--   * Friends who SEE them turn react (horror, denial) and the closest may ask you to put them down.
--   * When you kill that zombie in front of friends / family / squadmates, each reacts by personality and bond:
--     grateful ("thank you... he'd have wanted that", +opinion), grief (breaks down), blame (-opinion, a grudge for
--     hot-headed / unhinged / in-denial ones who think he could have been saved), numb. Bigger bond = bigger swing.
--   * Memory, log, rumors (deeds), the grief state (griefOf entry: turned / put down), last words context, popups.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Turned") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Turned"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Turned") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function bucket(name) return M.bucket(name) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end

if M.settings.turnedReact == nil then M.settings.turnedReact = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "turnedReact" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "turnedReact" end
end
M.turnCfg = { tagTiles = 2.2, tagWindowMs = 90000, witnessTiles = 22, minW = 0.12, askW = 0.35 }
M.turnPending = {} -- uid -> { x, y, z, female, atMs, name } waiting for the zombie to stand up
M.turnAsk = {}     -- dead uid -> witness uid who asked you to put them down

-- who mourns them (bond weight from our pair layer; same group counts as a squadmate)
function M.turnWitnesses(deadUid, x, y, z)
    local out = {}
    local dr = rec(deadUid)
    local dg = dr and type(dr.memory) == "table" and dr.memory.groupId or nil
    for _, l in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z or 0, M.turnCfg.witnessTiles, deadUid) or {}) do
        local wu = tostring(l.record.uid)
        local w, t = 0, "stranger"
        if M.closeness then w, t = M.closeness(wu, deadUid) end
        local m = type(l.record.memory) == "table" and l.record.memory or {}
        if dg ~= nil and m.groupId == dg then w, t = math.max(w, 0.4), (t == "stranger" or t == "acquaintance") and "squadmate" or t end
        if w >= M.turnCfg.minW then out[#out + 1] = { l = l, uid = wu, w = w, t = t } end
    end
    table.sort(out, function(a, b) return a.w > b.w end)
    return out
end

-- 0.5.1 (mercy rules): killing someone bitten or turned is almost never a reason to fight. Kinds:
-- grateful ("it had to be done"), accept, grief, numb, argue (a sad argument), anger (verbal + grudge / bond drop),
-- hostile (rare: only for extreme cases and mostly when they were killed BEFORE they turned, without anyone asking).
-- ctx = { stage = "turned" | "bitten", asked = bool, killerKind = "player" | "npc" | "other" }
function M.mercyFactors(wuid, w, t)
    local p = M.partsOf and M.partsOf(wuid) or nil
    local k = p and p.core and p.core.key or ""
    local mods = p and p.mods or {}
    local lens = M.lens and M.lens(wuid) or {}
    local kindKey = M.personaKind and select(1, M.personaKind(wuid)) or nil
    local family = t == "partner" or t == "sibling" or t == "parent" or t == "child" or t == "spouse"
    local close = family or (tonumber(w) or 0) >= 0.8
    local hot = k == "hothead" or k == "vengeful" or k == "delusional" or kindKey == "unhinged" or mods.grief == "rage"
        or (lens.volatile or 0) >= 0.35 or (lens.unhinged or 0) >= 0.3
    local denial = mods.grief == "denial"
    return { close = close, family = family, hot = hot, denial = denial, lens = lens, mods = mods, k = k }
end
function M.turnReactionKind(wuid, w, asked, ctx, t)
    ctx = ctx or {}
    if type(asked) == "table" then ctx = asked; asked = ctx.asked end
    asked = asked or ctx.asked
    local f = M.mercyFactors(wuid, w, t)
    local lens, mods = f.lens, f.mods
    local stage = ctx.stage or "turned"
    local s = { grateful = 30, accept = 22, grief = 28, numb = 10, argue = 4, anger = 0, hostile = 0 }
    if asked then s.grateful = s.grateful + 60 end
    s.grateful = s.grateful + ((lens.calm or 0) + (lens.disciplined or 0) + (lens.devout or 0) + (lens.brave or 0)) * 40
    s.accept = s.accept + ((lens.calm or 0) + (lens.disciplined or 0)) * 30
    s.grief = s.grief + ((lens.kind or 0) + (lens.gloomy or 0)) * 40 + (tonumber(w) or 0) * 30
    s.numb = s.numb + ((lens.mean or 0) + (lens.sarcastic or 0)) * 25
    if mods.grief == "weep" then s.grief = s.grief + 35 end
    if mods.grief == "cold" or mods.grief == "quiet" then s.numb = s.numb + 35 end
    if mods.grief == "pray" then s.grateful = s.grateful + 25 end
    if f.k == "stoic" or f.k == "survivalist" or f.k == "hardass" then s.accept = s.accept + 25; s.numb = s.numb + 10 end
    local early = stage == "bitten" and not asked
    if stage == "bitten" then s.argue = s.argue + 10 + (f.close and 10 or 0) end -- "we had time", "maybe it wasn't a bite"
    if f.denial then s.argue = s.argue + 20 end
    -- anger only in extreme cases; always verbal / grudge first
    if f.close or f.hot or f.denial or early then
        local a = (f.hot and 8 or 0) + (f.close and 6 or 0) + (f.denial and 8 or 0) + (early and 10 or 0)
        if stage == "turned" then a = (f.close and (f.hot or f.denial)) and math.floor(a * 0.3) or 0 end
        if asked then a = math.floor(a * 0.2) end
        s.anger = a
    end
    local total = 0
    for _, v in pairs(s) do total = total + v end
    local r = hash(tostring(wuid) .. "#turnreact#" .. tostring(ctx.victim or "") .. tostring(ctx.killer or "")) % math.max(1, math.floor(total))
    local kind = "numb"
    for _, kk in ipairs({ "grateful", "accept", "grief", "numb", "argue", "anger" }) do
        if r < s[kk] then kind = kk; break end
        r = r - s[kk]
    end
    -- the only path to a fight: anger + killed before turning + no one asked + family/partner + hot-headed or in denial
    if kind == "anger" and early and f.close and (f.hot or f.denial) and (hash(tostring(wuid) .. "#mercyfight#" .. tostring(ctx.victim or "")) % 100) < 15 then
        kind = "hostile"
    end
    return kind
end

M.turnLines = {
    grateful = { "Thank you, {k}... {n} would've wanted that.", "It had to be done. Thank you, {k}.", "Rest now, {n}... Thanks, {k}." },
    accept = { "It had to be done.", "{n} wasn't in there anymore.", "That's... that's the right thing. I know it is." },
    grief = { "No... {n}... no, no, no...", "Oh god, {n}...", "{n}! I can't... I can't do this..." },
    numb = { "...That was {n}.", "Yeah. {n}'s gone. Was gone already.", "Huh. {n}." },
    argue = { "We had time, {k}! We could've waited!", "Maybe it wasn't even a bite... you didn't know!", "You didn't have to do it like that, {k}." },
    anger = { "{k} - you didn't even ask! {n} was still {n}!", "I won't forget this, {k}.", "Don't you touch me. Don't talk to me." },
    hostile = { "You murdered {n}! You MURDERED {n}!", "{n} was still breathing, {k}!" },
    see = { "{n}...? No... getting up...", "Oh god - {n}'s turning!", "That's... that's not {n} anymore." },
    ask = { "Please... don't let {n} walk around like that. Put {n} down.", "I can't do it. Please - do it for {n}.", "Put {n} down. Please." },
}
local function line(kind, seed, name, killer) local t = string.gsub(pick(M.turnLines[kind], seed), "{n}", name); t = string.gsub(t, "{k}", killer or "you"); return t end

-- they see a friend turn
function M.onReanimating(uid, info)
    if M.settings.turnedReact == false or type(info) ~= "table" or info.x == nil then return end
    uid = tostring(uid)
    local r = rec(uid)
    local name = r and firstOf(r) or "him"
    M.turnPending[uid] = { x = info.x, y = info.y, z = info.z or 0, female = info.female, atMs = nowMs(), name = name }
    local player = ALifeSide.you()
    if ALifeSide.mpServer() then player = ALifeSide.nearest(info.x, info.y) end -- MP: the player nearest the body
    local ws = M.turnWitnesses(uid, info.x, info.y, info.z)
    for i, wt in ipairs(ws) do
        if i > 3 then break end
        if M.feel then M.feel(wt.uid, "fear", 0.3 + wt.w * 0.3, name .. " turned"); M.feel(wt.uid, "grief", wt.w * 0.6, name .. " turned") end
        local g = M.griefOf and M.griefOf(wt.uid)[uid] or nil
        if type(g) == "table" then g.turned = true end
        if M.keyMem then pcall(M.keyMem, wt.uid, "turned", name .. " came back as one of them") end
        if i == 1 then
            local txt = line("see", wt.uid .. uid, name)
            if wt.w >= M.turnCfg.askW and player ~= nil then
                txt = line("ask", wt.uid .. uid .. "a", name)
                M.turnAsk[uid] = wt.uid
            end
            if not (M.react and player and M.react("grief", wt.l, player, { what = name .. " (your " .. tostring(wt.t) .. ") just died and is getting up as a zombie"
                    .. (M.turnAsk[uid] and "; you can't do it yourself - ask the newcomer to put them down" or ""), style = "horror, raw, short", maxWords = 14, fallback = txt },
                    { key = "turnsee:" .. uid, keyCooldownMs = 600000, urgent = true, face = "player" })) and M.say then
                M.say(wt.l.shell, player, txt, { record = wt.l.record, combat = true })
            end
        end
    end
    log("turning: " .. name .. " (" .. uid .. "), " .. #ws .. " friend(s) saw it")
end

-- tag the zombie that stood up on that spot
function M.turnTagTick(now)
    if not M.hasAnyKey(M.turnPending) then return end
    local cell = getCell and getCell() or nil
    if cell == nil then return end
    for uid, e in pairs(M.turnPending) do
        if now - e.atMs > M.turnCfg.tagWindowMs then M.turnPending[uid] = nil
        else
            local found = nil
            local list = nil
            pcall(function() list = cell:getZombieList() end)
            local n = 0
            pcall(function() n = list:size() end)
            for i = 0, math.min(n, 600) - 1 do
                local z = list:get(i)
                local zx, zy, zz = pos(z)
                if zx and math.floor(zz or 0) == math.floor(e.z or 0) and (zx - e.x) ^ 2 + (zy - e.y) ^ 2 <= M.turnCfg.tagTiles ^ 2 then
                    local md = nil
                    pcall(function() md = z:getModData() end)
                    local isNpc = M.uidOf and M.uidOf(z) ~= nil
                    local sexOk = true
                    if e.female ~= nil then pcall(function() sexOk = (z:isFemale() == true) == (e.female == true) end) end
                    if type(md) == "table" and md.TalkWasUid == nil and not isNpc and sexOk then found = z; break end
                end
            end
            if found then
                pcall(function()
                    local md = found:getModData()
                    md.TalkWasUid, md.TalkWasName = uid, e.name
                    md.TalkWasOutfit = tostring(found:getOutfitName() or "")
                end)
                M.turnPending[uid] = nil
                bucket("turnedZ")[uid] = { n = e.name, x = math.floor(e.x), y = math.floor(e.y), h = hours() }
                log("tagged the zombie that was " .. tostring(e.name))
            end
        end
    end
end
function M.hasAnyKey(t) if type(t) ~= "table" then return false end; for _ in pairs(t) do return true end; return false end

-- who did it: the player, an A-Life NPC (companion, faction member, stranger) or something else
function M.mercyKiller(victimObj, attacker)
    local player = ALifeSide.you()
    if attacker == nil then pcall(function() attacker = victimObj:getAttackedBy() end) end
    if ALifeSide.mpServer() then -- MP: the killer is whichever online player it was (killer.player)
        if attacker ~= nil and ALifeSide.isOnlinePlayer(attacker) then return { kind = "player", name = "you", player = attacker } end
        player = ALifeSide.nearestTo(victimObj, 12)
    end
    if attacker ~= nil and player ~= nil and attacker == player then return { kind = "player", name = "you", player = player } end
    local kuid = attacker ~= nil and M.uidOf and M.uidOf(attacker) or nil
    if kuid ~= nil then return { kind = "npc", uid = tostring(kuid), name = firstOf(rec(kuid)), shell = attacker } end
    if attacker ~= nil then return { kind = "other", name = "someone" } end
    -- nobody recorded: the player when close, else the nearest A-Life NPC within 3 tiles
    local x, y, z = pos(victimObj)
    local px, py = pos(player)
    if x and px and (x - px) ^ 2 + (y - py) ^ 2 <= 144 then return { kind = "player", name = "you", player = player } end
    for _, l in ipairs(x and M.nearbyNpcs and M.nearbyNpcs(x, y, z or 0, 3) or {}) do
        return { kind = "npc", uid = tostring(l.record.uid), name = firstOf(l.record), shell = l.shell }
    end
    return { kind = "other", name = "someone" }
end
-- is this person bitten / infected (a mercy kill, not a murder)?
function M.isInfectedVictim(record, body)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    if m.infectedTurnAtHours ~= nil then return true end
    local yes = false
    pcall(function() local d = body and body:getModData(); if type(d) == "table" and d.ProjectALifeTurnAtHours ~= nil then yes = true end end)
    if yes then return true end
    pcall(function() local s = M.woundState and M.woundState(tostring(record.uid), body, record); if s and s.bitten then yes = true end end)
    return yes
end

-- bond change toward the killer (opinion for the player, pair bond for an NPC killer)
M.mercyDelta = { grateful = 4, accept = 1, grief = 0, numb = 0, argue = -2, anger = -6, hostile = -10 }
function M.onMercyKill(uid, victimObj, killer, stage)
    if M.settings.turnedReact == false then return nil end
    uid = tostring(uid)
    local r = rec(uid)
    local name = r and firstOf(r) or "him"
    local x, y, z = pos(victimObj)
    local player = ALifeSide.you()
    if ALifeSide.mpServer() then player = (type(killer) == "table" and killer.player) or (x and ALifeSide.nearest(x, y)) or nil end -- MP: the killer, else the nearest player
    if x == nil then return nil end
    killer = killer or { kind = "other", name = "someone" }
    -- 0.5.1.6: the zombie's own former self is never its killer ("Otis just killed the zombie that used to be Otis")
    if killer.kind == "npc" and killer.uid ~= nil and tostring(killer.uid) == uid then killer = { kind = "other", name = "someone" } end
    -- one reaction per person and stage
    M.mercyDone = M.mercyDone or {}
    local mk = uid .. ":" .. tostring(stage)
    if M.mercyDone[mk] ~= nil and nowMs() - M.mercyDone[mk] < 600000 then return nil end
    M.mercyDone[mk] = nowMs()
    local asked = M.turnAsk[uid]
    local ws = M.turnWitnesses(uid, x, y, z)
    local pa = PA()
    local P = patch()
    local lw = M.lastWordsDone and M.lastWordsDone[uid] or nil
    local spoke, out = 0, {}
    local kname = killer.kind == "player" and "you" or killer.name
    for i, wt in ipairs(ws) do
        if i > 6 then break end
        if killer.kind == "npc" and wt.uid == killer.uid then -- the one who did it: grief, no reaction to themselves
            if M.feel then M.feel(wt.uid, "grief", 0.3 + wt.w * 0.4, "had to put down " .. name) end
            if M.keyMem then pcall(M.keyMem, wt.uid, "turned", "You had to put down " .. name .. (stage == "bitten" and " (bitten)" or " (turned)")) end
        else
        local kind = M.turnReactionKind(wt.uid, wt.w, asked == wt.uid, { stage = stage, asked = asked ~= nil, victim = uid, killer = killer.uid or killer.kind }, wt.t)
        if killer.kind == "other" and (kind == "anger" or kind == "hostile" or kind == "argue") then kind = "grief" end
        local scale = 0.5 + wt.w * 1.5 -- bigger bond, bigger swing
        local delta = math.floor((M.mercyDelta[kind] or 0) * scale + (kind == "grateful" and asked == wt.uid and 3 or 0) + 0.5)
        if kind == "anger" or kind == "hostile" or kind == "argue" then delta = -math.floor(-(M.mercyDelta[kind] or 0) * scale + 0.5) end
        local why = (kind == "grateful" or kind == "accept") and ("Put " .. name .. " down (mercy)") or ("Killed " .. name .. (stage == "bitten" and " (bitten)" or " (turned)"))
        if delta ~= 0 then
            if killer.kind == "player" and player and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, wt.l.record, player, delta, why)
            elseif killer.kind == "npc" and M.pairBump then pcall(M.pairBump, wt.uid, killer.uid, delta, why) end
        end
        if kind == "anger" or kind == "hostile" then
            local f = M.mercyFactors(wt.uid, wt.w, wt.t)
            if (f.hot or f.denial) then
                if killer.kind == "player" and M.addGrudge then pcall(M.addGrudge, wt.uid, math.floor(8 * scale), "you killed " .. name .. " before anyone was sure", player) end
                if killer.kind == "npc" and M.pairBump then pcall(M.pairBump, wt.uid, killer.uid, -math.floor(6 * scale), "a grudge over " .. name) end
            end
            if kind == "hostile" then
                if killer.kind == "player" and P and fn(P, "attackNow") and M.settings.attackPlayer ~= false and player then pcall(P.attackNow, wt.uid, player, "killed " .. name .. " before they turned")
                elseif killer.kind == "npc" and P and fn(P, "npcFeud") then pcall(P.npcFeud, wt.uid, killer.uid, "killed " .. name, 6, false) end
            end
        end
        if M.feel then
            if kind == "grateful" or kind == "accept" then M.feel(wt.uid, "relief", 0.3, name .. " is at rest"); M.feel(wt.uid, "grief", wt.w * 0.4, name)
            elseif kind == "grief" or kind == "argue" then M.feel(wt.uid, "grief", 0.4 + wt.w * 0.5, name .. " put down")
            elseif kind == "anger" or kind == "hostile" then M.feel(wt.uid, "anger", 0.4 + wt.w * 0.4, kname .. " killed " .. name)
            else M.feel(wt.uid, "numbness", 0.3, name) end
        end
        if kind == "grief" then
            if P and fn(P, "gesture") then pcall(P.gesture, wt.uid, (wt.w >= 0.5) and "sit_ground" or "bow_head") end
        end
        local g = M.griefOf and M.griefOf(wt.uid)[uid] or nil
        if type(g) == "table" then g.turned = stage == "turned" or g.turned; g.putDown = kname; g.putDownReact = kind end
        local who = killer.kind == "player" and "the newcomer" or kname
        if M.keyMem then pcall(M.keyMem, wt.uid, "turned", "Watched " .. who .. " put down " .. name .. (stage == "bitten" and " (bitten, not turned yet)" or " (turned)") .. " - " .. kind) end
        if M.logInteraction then pcall(M.logInteraction, wt.uid, "Saw " .. who .. " put down " .. name .. " - " .. kind .. (delta ~= 0 and (" " .. (delta > 0 and "+" or "") .. delta) or ""), nil, nil, "event") end
        out[#out + 1] = { uid = wt.uid, kind = kind, delta = delta }
        if spoke < 2 then
            spoke = spoke + 1
            local txt = line(kind, wt.uid .. uid, name, killer.kind == "player" and "you" or kname)
            local what = (killer.kind == "player" and "The newcomer" or kname) .. " just killed " .. (stage == "bitten" and (name .. ", who was bitten but hadn't turned yet") or ("the zombie that used to be " .. name))
                .. " (your " .. tostring(wt.t) .. ")" .. (lw and lw.text and ("; " .. name .. "'s last words were \"" .. lw.text .. "\"") or "")
                .. ". You feel: " .. kind .. ((kind == "anger" or kind == "argue") and " (sad, not violent - words, not fists)" or "")
            local face = killer.kind == "player" and "player" or nil
            local function go()
                if not (M.react and player and M.react("grief", wt.l, player, { what = what, style = "one raw line, in character", maxWords = 16, fallback = txt },
                        { key = "turnkill:" .. wt.uid, keyCooldownMs = 300000, urgent = true, face = face })) and M.say then
                    M.say(wt.l.shell, killer.kind == "player" and player or killer.shell, txt, { record = wt.l.record })
                end
            end
            if spoke == 1 then go() elseif fn(pa.Talk, "later") then pcall(pa.Talk.later, 2200, go) else go() end
        end
        end
    end
    if M.addDeed and killer.kind == "player" and #out > 0 then
        local wit = {}
        for _, o in ipairs(out) do wit[#wit + 1] = o.uid end
        pcall(M.addDeed, "mercy", "the newcomer put down " .. name .. (stage == "bitten" and " after a bite" or " after he turned"), 1, wit, x, y)
    end
    M.turnAsk[uid] = nil
    M.lastMercy = { uid = uid, stage = stage, killer = killer.kind, out = out }
    log("mercy kill of " .. name .. " (" .. stage .. ", by " .. killer.kind .. "): " .. #out .. " witness reaction(s)")
    return out
end
-- 0.5.0 API kept: killed the turned zombie (true = by the player)
function M.onTurnedKilled(uid, zombie, killerIsPlayer)
    local k = killerIsPlayer == true and { kind = "player", name = "you" } or (type(killerIsPlayer) == "table" and killerIsPlayer or { kind = "other", name = "someone" })
    return M.onMercyKill(uid, zombie, k, "turned")
end

function M.onZombieDeadTurned(zombie)
    local md = nil
    pcall(function() md = zombie:getModData() end)
    if type(md) ~= "table" or md.TalkWasUid == nil then return end
    local uid = md.TalkWasUid
    md.TalkWasUid = nil
    M.onMercyKill(uid, zombie, M.mercyKiller(zombie, nil), "turned")
end

function M.turnedInstall()
    local P = patch()
    if M.turnedHooked or P == nil or type(P.hooks) ~= "table" or type(P.hooks.reanimating) ~= "table" then return end
    M.turnedHooked = true
    table.insert(P.hooks.reanimating, function(uid, info) pcall(M.onReanimating, uid, info) end)
    P.mercyCheck = function(actor, shell) return M.settings.turnedReact ~= false and M.isInfectedVictim(actor, shell) end
end

table.insert(M.requestExtras, function(req, player, listener, now)
    local g = M.griefOf and M.griefOf(tostring(listener.record.uid)) or nil
    if type(g) ~= "table" then return end
    for _, e in pairs(g) do
        if type(e) == "table" and e.turned then
            req.turned = req.turned or {}
            if #req.turned < 2 then req.turned[#req.turned + 1] = { name = e.n, putDown = e.putDown, react = e.putDownReact } end
        end
    end
end)

if type(Events) == "table" then
    if Events.OnZombieDead then ALifeHealth.add(Events.OnZombieDead, "ALifeLLMTalk_Turned", function(z) local ok, e = pcall(M.onZombieDeadTurned, z); if not ok then log("turned error: " .. tostring(e)) end end) end
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.turnedInstall) end) end
    if Events.OnTick then
        local n = 0
        ALifeHealth.tickAdd("ALifeLLMTalk_Turned", function()
            n = n + 1
            if n % 20 ~= 9 then return end
            if not M.turnedHooked then pcall(M.turnedInstall) end
            local ok, e = pcall(M.turnTagTick, nowMs())
            if not ok then log("turn tag error: " .. tostring(e)) end
        end)
    end
end
pcall(M.turnedInstall)

return M
