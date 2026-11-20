-- A-Life Talk 0.5.0: word gets around.
--   * Rumors: the player's notable deeds (killings, rescues, gifts, kept / broken promises, robberies, quests, a big
--     zombie tally) spread NPC to NPC - inside groups quickly, between strangers slowly - and change with every hop
--     (numbers grow, names blur, places shift). Hearing one nudges that NPC's opinion of the player once, by how
--     good or bad it sounds, and they may bring it up ("heard you shot a man in Riverside").
--   * Faction politics: each A-Life faction with living members gets a leader (a real member), and a tension score
--     toward every other active faction, seeded from A-Life's own faction relations (RelationLayers.towardFaction,
--     which Living Factions / Factions Expanded feed when present). Deaths between factions, the player's deeds and
--     the leaders' temperaments move it daily: war, skirmishes, tension, truce, alliance. Changes go on the radio
--     news and into NPC prompts. With Living Factions running its own warfare we only narrate.
--   * Nemesis escalation: every time a nemesis comes back and fails, the next return is bigger (more backup,
--     a longer grudge) and the radio hears of it.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Social") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Social"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Social") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function bucket(name)
    local data = M.store()
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
local function hash(s)
    local h = 5381
    s = tostring(s)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return h
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

----------------------------------------------------------------------------------------------------------------
-- rumors
----------------------------------------------------------------------------------------------------------------
M.rumorSettings = { keep = 25, spreadEveryH = 0.5, groupChance = 60, strangerChance = 8, maxHops = 5, perTick = 40,
    opinionCap = 6, promptMax = 2, staleH = 240 }

-- deed: kind, plain text about "the stranger", w = how good (+) or bad (-) it sounds (-10..10), witnesses = { uid }
function M.addDeed(kind, text, w, witnesses, x, y)
    if M.settings.rumors == false or type(text) ~= "string" then return nil end
    local list = bucket("rumors")
    local h = hours()
    for i = #list, math.max(1, #list - 5), -1 do
        if list[i].t == text and h - (list[i].h or 0) < 6 then return list[i] end
    end
    local town = M.townAt and M.townAt(x, y) or nil
    local r = { id = tostring(math.floor(h * 100)) .. "-" .. tostring(#list + 1), k = kind, t = text, w = tonumber(w) or 0, h = h,
        town = town, known = {} }
    -- pre-1.0 MP (P2b): whose deed it was (the player being handled); single player: no key, you
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur ~= nil then r.pk = ALifeSide.keyOf(ALifeSide.cur) end
    for _, uid in ipairs(witnesses or {}) do r.known[tostring(uid)] = 0 end
    list[#list + 1] = r
    while #list > M.rumorSettings.keep do table.remove(list, 1) end
    log("rumor: " .. text .. (town and (" (" .. town .. ")") or "") .. " - " .. tostring(#(witnesses or {})) .. " witnesses")
    return r
end

M.distort = {
    { "killed a man", "killed two men" }, { "killed two men", "killed a whole family" }, { "killed", "butchered" },
    { "shot", "gunned down" }, { "a few", "a dozen" }, { "dozens of", "hundreds of" }, { "helped", "saved" },
    { "saved", "risked their neck for" }, { "gave", "handed out" }, { "food", "a whole truckload of food" },
    { "robbed", "cleaned out" }, { "broke a promise", "lies to everybody" }, { "a stranger", "that drifter" },
    { "a woman", "some girl" }, { "a man", "some fella" }, { "kept their word", "is good for it" },
}
-- the rumor as an NPC 'hops' away from the source would tell it (deterministic per rumor + hop)
function M.rumorText(r, hop, teller)
    local t = r.t
    hop = math.min(tonumber(hop) or 0, M.rumorSettings.maxHops)
    local town = r.town
    local towns = { "Riverside", "Muldraugh", "West Point", "Rosewood", "March Ridge", "Louisville", "Ekron", "Irvington" }
    for i = 1, hop do
        local k = hash(r.id .. "#" .. i)
        local d = M.distort[k % #M.distort + 1]
        local a = string.find(t, d[1], 1, true)
        if a then t = string.sub(t, 1, a - 1) .. d[2] .. string.sub(t, a + #d[1]) end
        if k % 5 == 0 and town then town = towns[math.floor(k / 7) % #towns + 1] end -- wrong place
    end
    -- liars and gossips spin it further
    local m = teller and M.personaMods and M.personaMods(teller) or nil
    if m and (tonumber(m.lie) or 0) >= 0.7 and hop >= 1 then t = t .. ", and they say worse" end
    return t .. (town and (" near " .. town) or "")
end

function M.learnRumor(r, uid, hop)
    uid = tostring(uid)
    if r.known[uid] ~= nil then return false end
    r.known[uid] = hop
    -- pre-1.0 MP (P2b): the rumor is about the player who did it (offline: heard, no opinion change until later)
    local player = nil
    if r.pk ~= nil and type(ALifeSide) == "table" then player = ALifeSide.byKey(r.pk) else player = M.you() end
    local record = rec(uid)
    if record and player and r.w ~= 0 then
        -- hearsay counts less the further it travelled; personality scales it (Persona wrapper)
        local d = clamp(math.floor(r.w * (1 - hop * 0.15) + 0.5), -M.rumorSettings.opinionCap, M.rumorSettings.opinionCap)
        if d ~= 0 and fn(PA().NpcOpinion, "adjust") then
            M.opinionWhy = "Heard a rumor: " .. M.rumorText(r, hop, uid)
            pcall(PA().NpcOpinion.adjust, record, player, d, M.opinionWhy)
            M.opinionWhy = nil
        end
        if M.feel then M.feel(uid, r.w < 0 and "fear" or "hope", math.min(0.3, math.abs(r.w) / 30), "a rumor about the newcomer") end
    end
    return true
end

function M.rumorsKnownBy(uid)
    local out = {}
    uid = tostring(uid)
    for _, r in ipairs(bucket("rumors")) do
        local hop = r.known[uid]
        if hop ~= nil then out[#out + 1] = { r = r, hop = hop, text = M.rumorText(r, hop, uid) } end
    end
    return out
end

-- one spread step: groups share fast, strangers sometimes pass word along (persona rows = NPCs that exist for us)
function M.rumorTick()
    if M.settings.rumors == false then return end
    local list = bucket("rumors")
    if #list == 0 then return end
    local h = hours()
    local people = {}
    for uid in pairs(bucket("persona")) do people[#people + 1] = uid end
    table.sort(people)
    if #people == 0 then return end
    local groupOf = {}
    local function gid(uid)
        if groupOf[uid] == nil then
            local r = rec(uid)
            groupOf[uid] = (r and type(r.memory) == "table" and r.memory.groupId) or false
        end
        return groupOf[uid]
    end
    local budget = M.rumorSettings.perTick
    for _, r in ipairs(list) do
        if h - (r.h or 0) <= M.rumorSettings.staleH and budget > 0 then
            local tellers = {}
            for uid, hop in pairs(r.known) do if hop < M.rumorSettings.maxHops then tellers[#tellers + 1] = uid end end
            table.sort(tellers)
            for _, t in ipairs(tellers) do
                if budget <= 0 then break end
                local hop = r.known[t]
                local g = gid(t)
                local k = hash(r.id .. t .. tostring(math.floor(h * 2)))
                local m = M.personaMods and M.personaMods(t) or nil
                local gossip = m and ((tonumber(m.lie) or 0) >= 0.6 or (tonumber(m.pos) or 1) >= 1.2) and 1.5 or 1
                for i = 1, 3 do
                    local other = people[(k + i * 7919) % #people + 1]
                    budget = budget - 1
                    if other ~= t and r.known[other] == nil then
                        local same = g and gid(other) == g
                        local chance = (same and M.rumorSettings.groupChance or M.rumorSettings.strangerChance) * gossip
                        if (math.floor(k / (i * 13)) % 100) < chance then M.learnRumor(r, other, hop + 1) end
                    end
                end
            end
        end
    end
end

-- deeds from our own pipeline
function M.deedFromEvent(ev)
    if type(ev) ~= "table" then return end
    if ev.kind == "death" and ev.killerUid == "player" then
        local wit = {}
        for _, w in ipairs(ev.witnesses or {}) do if type(w) == "table" and w.uid then wit[#wit + 1] = w.uid elseif type(w) == "string" then wit[#wit + 1] = w end end
        M.addDeed("kill", "a stranger killed " .. tostring(ev.victim or "a man"), -8, wit, ev.x, ev.y)
    end
end
if type(M.submit) == "function" and not M._deedWrapped then
    local orig = M.submit
    M.submit = function(job)
        if type(job) == "table" and job.mode == "event" and type(job.event) == "table" then pcall(M.deedFromEvent, job.event) end
        return orig(job)
    end
    M._deedWrapped = true
end
local function wrapAfter(name, f)
    local orig = M[name]
    if type(orig) ~= "function" or M["_soc_" .. name] then return end
    M[name] = function(...)
        local a, b, c = orig(...)
        local args = { ... }
        pcall(f, args, a)
        return a, b, c
    end
    M["_soc_" .. name] = true
end
function M.installDeedHooks()
    wrapAfter("onGift", function(args)
        local l, opts = args[2], args[4]
        if l and l.record and not (opts and opts.trade) then
            M.addDeed("gift", "a stranger gave food and supplies to " .. nameOf(l.record), 3, { l.record.uid }, nil, nil)
        end
    end)
    wrapAfter("settlePromise", function(args)
        local uid, row, kept = args[1], args[2], args[3]
        if uid == nil or type(row) ~= "table" then return end
        if kept then M.addDeed("promise", "the stranger kept their word to " .. nameOf(rec(uid)), 2, { uid })
        else M.addDeed("promise", "the stranger broke a promise to " .. nameOf(rec(uid)), -3, { uid }) end
    end)
    wrapAfter("noteAttack", function(args)
        local uid = args[1]
        if uid then M.addDeed("attack", "a stranger attacked " .. nameOf(rec(uid)) .. " for no reason", -5, { uid }) end
    end)
end
-- zombie tally milestones
M.killMarks = { 50, 150, 400, 1000 }
function M.killTally(player)
    local n = 0
    pcall(function() n = player:getZombieKills() end)
    local st = bucket("deedState")
    -- pre-1.0 MP (P2b): each player's own tally ("kills" in single player, as before)
    local kk = (type(ALifeSide) == "table" and ALifeSide.mpServer()) and ("kills:" .. tostring(ALifeSide.keyOf(player))) or "kills"
    local done = tonumber(st[kk]) or 0
    for i, mark in ipairs(M.killMarks) do
        if n >= mark and done < i then
            st[kk] = i
            local x, y = player:getX(), player:getY()
            local near = {}
            for _, l in ipairs(M.nearbyNpcs(x, y, player:getZ(), 25) or {}) do near[#near + 1] = l.record.uid end
            M.addDeed("tally", "a stranger has put down " .. ({ "dozens of", "a hundred or more", "hundreds of", "a thousand" })[i] .. " the dead", 2 + i, near, x, y)
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- faction politics
----------------------------------------------------------------------------------------------------------------
M.polSettings = { maxFactions = 7, dayDrift = 9, warAt = -60, skirmishAt = -30, allyAt = 60, truceUp = -40 }
M.wordScore = { hostile = -55, careful = -25, wary = -25, neutral = 0, friendly = 35, allied = 65, ally = 65 }

function M.factionName(id)
    local pa = PA()
    local f = fn(pa.Catalog, "faction") and pa.Catalog.faction(id) or nil
    local n = f and type(f.general) == "table" and f.general.name or nil
    return (n and tostring(n) ~= "") and tostring(n) or tostring(id)
end

function M.activeFactions()
    local pa = PA()
    local counts, members = {}, {}
    if not fn(pa.ActorRegistry, "each") then return {}, {} end
    pcall(pa.ActorRegistry.each, function(r)
        if r.lifecycle ~= "dead" and r.factionId then
            local f = tostring(r.factionId)
            counts[f] = (counts[f] or 0) + 1
            members[f] = members[f] or {}
            if #members[f] < 60 then members[f][#members[f] + 1] = r end
        end
        return false
    end)
    local list = {}
    for f, n in pairs(counts) do list[#list + 1] = { id = f, n = n } end
    table.sort(list, function(a, b) if a.n == b.n then return a.id < b.id end return a.n > b.n end)
    while #list > M.polSettings.maxFactions do table.remove(list) end
    return list, members
end

local function pairKey(a, b) if a < b then return a .. "|" .. b end return b .. "|" .. a end
function M.seedTension(a, b)
    local pa = PA()
    local fa = fn(pa.Catalog, "faction") and pa.Catalog.faction(a) or nil
    local fb = fn(pa.Catalog, "faction") and pa.Catalog.faction(b) or nil
    local word = nil
    if fa and fb and fn(pa.RelationLayers, "towardFaction") then
        local ok, w1 = pcall(pa.RelationLayers.towardFaction, fa, fb)
        if ok then word = w1 end
    end
    return (M.wordScore[tostring(word)] or 0) + (hash(pairKey(a, b)) % 21) - 10
end

function M.stateOf(score, prev)
    local s = M.polSettings
    if score <= s.warAt then return "war" end
    if score <= s.skirmishAt then return (prev == "war") and "truce" or "skirmishes" end
    if score >= s.allyAt then return "alliance" end
    if prev == "war" or prev == "truce" then return score < 0 and "truce" or "peace" end
    if score < -10 then return "tension" end
    return "peace"
end
M.stateNews = { war = "%s and %s are at war", skirmishes = "%s and %s have been trading shots", truce = "%s and %s have agreed a truce",
    alliance = "%s and %s have joined forces", tension = "bad blood is brewing between %s and %s", peace = "%s and %s have made peace" }

function M.leaderFor(fid, list)
    local pol = bucket("politics")
    pol.leaders = type(pol.leaders) == "table" and pol.leaders or {}
    local cur = pol.leaders[fid]
    local r = cur and rec(cur) or nil
    if r and r.lifecycle ~= "dead" then return cur, false end
    local best, bk = nil, -1
    for _, m in ipairs(list or {}) do
        local conduct = type(m.memory) == "table" and m.memory.conduct or nil
        local k = (conduct == "leader" and 1000000 or 0) + hash(tostring(m.uid) .. "#lead") % 1000000
        if m.lifecycle == "active" or m.lifecycle == "offline" or m.lifecycle == nil then
            if k > bk then best, bk = tostring(m.uid), k end
        end
    end
    pol.leaders[fid] = best
    return best, cur ~= nil and best ~= nil
end

function M.politicsDay(force)
    if M.settings.politics == false then return end
    local pol = bucket("politics")
    pol.t = type(pol.t) == "table" and pol.t or {}
    pol.st = type(pol.st) == "table" and pol.st or {}
    pol.ev = type(pol.ev) == "table" and pol.ev or {}
    local day = math.floor(hours() / 24)
    if not force and pol.day == day then return end
    pol.day = day
    local list, members = M.activeFactions()
    -- leaders (a real member; a new one when the old one dies)
    for _, f in ipairs(list) do
        local uid, changed = M.leaderFor(f.id, members[f.id])
        if changed and uid then
            M.politicsNews("leader", M.factionName(f.id) .. " have a new leader: " .. nameOf(rec(uid)))
        end
    end
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i].id, list[j].id
            local key = pairKey(a, b)
            local t = pol.t[key]
            if t == nil then t = M.seedTension(a, b) end
            -- drift: random, pulled by events and by how hot-headed the two leaders are
            local k = hash(key .. "#" .. day)
            local drift = (k % (M.polSettings.dayDrift * 2 + 1)) - M.polSettings.dayDrift
            for _, lead in ipairs({ pol.leaders[a], pol.leaders[b] }) do
                local m = lead and M.personaMods and M.personaMods(lead) or nil
                if m then drift = drift - ((tonumber(m.neg) or 1) - 1) * 6 + ((tonumber(m.forgive) or 0.5) - 0.5) * 6 end
            end
            local evs = tonumber(pol.ev[key]) or 0
            pol.ev[key] = 0
            t = clamp(t + drift + evs, -100, 100)
            -- wars burn out: deep enmity drifts back up a little each day
            if t < -70 then t = t + 4 end
            pol.t[key] = t
            local prev = pol.st[key]
            local st = M.stateOf(t, prev)
            if prev ~= nil and st ~= prev and M.stateNews[st] then
                M.politicsNews(st, string.format(M.stateNews[st], M.factionName(a), M.factionName(b)))
            end
            pol.st[key] = st
        end
    end
end
function M.politicsNews(kind, text)
    log("politics: " .. text)
    if M.newsNote then pcall(M.newsNote, "politics", text) end
    local pol = bucket("politics")
    pol.log = type(pol.log) == "table" and pol.log or {}
    pol.log[#pol.log + 1] = { h = hours(), k = kind, t = text }
    while #pol.log > 20 do table.remove(pol.log, 1) end
end
-- a member of one faction killed by another: tension falls
function M.politicsDeath(ev)
    if type(ev) ~= "table" or ev.kind ~= "death" then return end
    local victim = ev.victimUid and rec(ev.victimUid) or nil
    local killer = ev.killerUid and ev.killerUid ~= "player" and rec(ev.killerUid) or nil
    if victim and killer and victim.factionId and killer.factionId and victim.factionId ~= killer.factionId then
        local pol = bucket("politics")
        pol.ev = type(pol.ev) == "table" and pol.ev or {}
        local key = pairKey(tostring(victim.factionId), tostring(killer.factionId))
        pol.ev[key] = (tonumber(pol.ev[key]) or 0) - 12
    end
end
if type(M.submit) == "function" and not M._polWrapped then
    local orig = M.submit
    M.submit = function(job)
        if type(job) == "table" and job.mode == "event" and type(job.event) == "table" then pcall(M.politicsDeath, job.event) end
        return orig(job)
    end
    M._polWrapped = true
end

function M.politicsLine(record)
    local pol = bucket("politics")
    if type(pol.st) ~= "table" or record == nil or record.factionId == nil then return nil end
    local me = tostring(record.factionId)
    local bits = {}
    for key, st in pairs(pol.st) do
        local a, b = string.match(key, "^(.-)|(.+)$")
        local other = (a == me and b) or (b == me and a) or nil
        if other and st ~= "peace" then bits[#bits + 1] = st .. " with " .. M.factionName(other) end
    end
    table.sort(bits)
    local lead = type(pol.leaders) == "table" and pol.leaders[me] or nil
    local out = {}
    if lead then
        local lr = rec(lead)
        out[#out + 1] = (tostring(lead) == tostring(record.uid)) and ("You lead " .. M.factionName(me) .. ".")
            or ("Your faction (" .. M.factionName(me) .. ") is led by " .. nameOf(lr) .. ".")
    end
    if #bits > 0 then out[#out + 1] = "Your people are in " .. table.concat(bits, "; ") .. "." end
    if #out == 0 then return nil end
    return table.concat(out, " ")
end

-- skirmishes for factions at war (only without Living Factions, which runs its own warfare); our A-Life actors only
function M.skirmishTick(player)
    if M.settings.politics == false or M.settings.attackNpc == false or (M.modOn and M.modOn("livingFactions")) then return end
    local P = M.patch and M.patch()
    if P == nil or not fn(P, "npcFeud") or player == nil then return end
    local pol = bucket("politics")
    if type(pol.st) ~= "table" then return end
    local x, y, z = player:getX(), player:getY(), player:getZ()
    local near = M.nearbyNpcs(x, y, z, 40) or {}
    for i = 1, #near do
        for j = i + 1, #near do
            local a, b = near[i].record, near[j].record
            if a.factionId and b.factionId and a.factionId ~= b.factionId then
                local st = pol.st[pairKey(tostring(a.factionId), tostring(b.factionId))]
                local d2 = (near[i].shell:getX() - near[j].shell:getX()) ^ 2 + (near[i].shell:getY() - near[j].shell:getY()) ^ 2
                if st == "war" and d2 < 400 and fn(P, "pairStance") and P.pairStance(a.uid, b.uid) ~= "hostile" then
                    pcall(P.npcFeud, a.uid, b.uid, "their factions are at war", 1, true)
                    log("politics: skirmish " .. nameOf(a) .. " vs " .. nameOf(b))
                    return
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- nemesis escalation: each failed return makes the next one bigger
----------------------------------------------------------------------------------------------------------------
function M.nemesisEscalate(uid, n)
    if type(n) ~= "table" then return end
    n.g = (tonumber(n.g) or 0) + 15
    local before = tonumber(n.tier) or 0
    if M.tierFor then n.tier = math.max(before, M.tierFor(n.g)) end
    local P = M.patch and M.patch()
    if P and type(P.store) == "function" then
        local row = P.store().nemesis[tostring(uid)]
        if type(row) == "table" then row.visits = (n.visits or 0); row.tier = math.max(tonumber(row.tier) or 0, n.tier or 0) end
    end
    local r = rec(uid)
    local times = ({ "again", "a third time", "a fourth time" })[math.min(3, n.visits or 1)] or "again"
    if M.newsNote then pcall(M.newsNote, "nemesis", nameOf(r) .. " has sworn to hunt down a stranger " .. times) end
    if M.feel then M.feel(uid, "resentment", 0.3, "they got away from you"); M.feel(uid, "anger", 0.3) end
    log("nemesis escalates: " .. nameOf(r) .. " visit " .. tostring(n.visits) .. ", tier " .. tostring(n.tier))
end

-- prompt: rumors they heard about the player, faction politics
table.insert(M.requestExtras, function(req, player, listener, now)
    if not (listener and listener.record) then return end
    local soc = {}
    if M.settings.rumors ~= false then
        local heard = M.rumorsKnownBy(listener.record.uid)
        local out = {}
        for i = #heard, math.max(1, #heard - M.rumorSettings.promptMax + 1), -1 do
            out[#out + 1] = { heard[i].text, heard[i].hop == 0 and "you saw it yourself" or (heard[i].hop == 1 and "heard it from someone who saw it" or "hearsay") }
        end
        if #out > 0 then soc.rumors = out end
    end
    if M.settings.politics ~= false then soc.politics = M.politicsLine(listener.record) end
    if M.hasAny(soc) then req.social = soc end
end)

for k, v in pairs({ rumors = true, politics = true }) do if M.settings[k] == nil then M.settings[k] = v end end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "rumors", "politics" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
local tickN = 0
local lastSpreadH = -1e9
function M.socialTick()
    if not M.worldHere() then return end
    tickN = tickN + 1
    if tickN == 40 then pcall(M.installDeedHooks) end
    -- pre-1.0 MP (P2b): per player (kill tally, skirmishes near you); world-wide once (rumors, politics)
    if tickN % 600 == 100 then M.eachPlayer(M.killTally) end
    local h = hours()
    if h - lastSpreadH >= M.rumorSettings.spreadEveryH then lastSpreadH = h; pcall(M.rumorTick) end
    if tickN % 900 == 450 then pcall(M.politicsDay) end
    if tickN % 300 == 200 then M.eachPlayer(M.skirmishTick) end
end
if type(Events) == "table" and Events.OnTick then
    ALifeHealth.tickAdd("ALifeLLMTalk_Social", function() local ok, e = pcall(M.socialTick); if not ok then log("social tick error: " .. tostring(e)) end end)
end
return M
