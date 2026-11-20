-- A-Life Talk v3.2: grief for dead comrades.
-- Per mourner, per dead NPC (save ModData bucket "grief"): closeness w (0..1, from our pair layer: family /
-- partner / best friend ... which is seeded from A-Life's group / faction / Relations), when it happened (world
-- hours), whether they saw it or were told (by you or another NPC), how and by whom. Intensity decays over
-- in-game days (half-life ~3 days) but never below 25% of w for close comrades (w >= 0.6).
-- Feeds every prompt (token-cheap: at most 2 lines), triggers reactions (being told / hearing the news, passing
-- the place where they died), ambient remembering between people who lost the same person, and news spreading
-- between NPCs (through what they say out loud). Hostility to a killer only through A-Life: A-Life's own
-- NpcOpinion.noteKill already hits the player for killing group members; for NPC killers we only change our
-- own pair layer (enemy / nemesis), because A-Life exposes no NPC->NPC hostility switch.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Grief") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Grief"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Grief") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end
local function log(msg) M.log(msg) end
local function pos(o)
    if o == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end)
    return x, y, z
end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hours()
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    return h
end
local function bucket(name) return M.bucket(name) end

M.griefCfg = { minW = 0.25, halfLifeDays = 3, closeW = 0.6, floor = 0.25, sawTiles = 15, placeTiles = 6,
    placeGapMs = 20 * 60000, newsGapMs = 15000, rememberChance = 35,
    deathWords = { "dead", "died", "dies", "killed", "kill ", "gone", "didn't make it", "didnt make it", "got him",
        "got her", "they got", "bit ", "bitten", "turned", "passed", "lost ", "murdered", "shot ", "is no more" } }

local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end

function M.griefOf(uid)
    local map = bucket("grief")
    local row = map[tostring(uid)]
    if type(row) ~= "table" then row = {}; map[tostring(uid)] = row end
    return row
end

function M.griefIntensity(e, h)
    h = h or hours()
    local days = math.max(0, (h - (tonumber(e.at) or 0)) / 24)
    -- the pain starts when they find out (told three days later = fresh grief now)
    local since = math.max(0, (h - math.max(tonumber(e.at) or 0, tonumber(e.learnedH) or 0)) / 24)
    local decay = math.exp(-since * 0.693 / M.griefCfg.halfLifeDays)
    local v = (tonumber(e.w) or 0) * decay
    if (tonumber(e.w) or 0) >= M.griefCfg.closeW then v = math.max(v, e.w * M.griefCfg.floor) end
    return v, days
end

local moods = {
    fresh_saw = { "in shock, shaky", "numb, staring", "tearful, voice breaking" },
    fresh_told = { "stunned, in denial", "tearful", "numb" },
    player = { "furious at the newcomer", "bitter and dangerous toward the newcomer" },
    npc = { "bitter, wants payback", "angry" },
    zombies = { "numb", "tearful", "hollow" },
    guilt = { "guilty (you were there and couldn't stop it)", "blaming yourself" },
    older = { "quiet sadness", "bitter", "missing them" },
}
function M.griefMood(e, inten, days)
    local key
    local learnedAgo = (hours() - (tonumber(e.learnedH) or tonumber(e.at) or 0)) / 24
    if e.kid == "player" then key = "player"
    elseif days < 0.5 or learnedAgo < 0.5 then key = e.saw and "fresh_saw" or "fresh_told"
    elseif e.kid ~= nil and e.kid ~= "zombie" then key = "npc"
    elseif e.saw and (tonumber(e.w) or 0) >= 0.6 and days < 3 then key = "guilt"
    elseif days < 2 then key = "zombies"
    else key = "older" end
    local list = moods[key]
    return list[M.hashRoll(tostring(e.n) .. tostring(e.at), key, #list) + 1]
end

local function agoText(days)
    local hrs = days * 24
    if hrs < 1 then return "just now" elseif hrs < 6 then return "a few hours ago" elseif days < 1 then return "earlier today" end
    local n = math.floor(days + 0.5)
    if n <= 1 then return "yesterday" end
    return tostring(n) .. " days ago"
end

-- a death: everyone close to the victim gets a grief entry (known now if they saw it, otherwise later)
-- 0.5.2.6 [pt254u]: opts (off-screen deaths, ALifeLLMTalk_OffDeath.lua): victim = a stand-in record (A-Life already
-- removed theirs), kn = how it happened, skipName = don't add a second entry for a mourner who already grieves
-- someone of that name (the same person under an older uid)
function M.griefOnDeath(body, uid, killer, opts)
    local pa = PA()
    opts = type(opts) == "table" and opts or {}
    local victim = rec(uid) or opts.victim
    if victim == nil or not fn(pa.ActorRegistry, "each") then return end
    local bx, by, bz = pos(body)
    -- pre-1.0 MP: the killer if a player, else the player nearest the body (single player: you)
    local player = ALifeSide.you()
    if ALifeSide.mpServer() then player = (ALifeSide.isOnlinePlayer(killer) and killer) or ALifeSide.nearest(bx, by) end
    local kname, kid = "something unseen", nil
    if opts.kn ~= nil then kname = tostring(opts.kn)
    elseif M.killerOf then kname, kid = M.killerOf(killer, player, body) end
    -- 0.5.1: a bitten victim's killer is not a murderer (mercy): no nemesis / feud from grief
    local mercy = kid ~= "zombie" and M.isInfectedVictim and M.settings.turnedReact ~= false and M.isInfectedVictim(victim, body)
    local vmem = type(victim.memory) == "table" and victim.memory or {}
    local h = hours()
    local vname = nameOf(victim)
    local count = 0
    pa.ActorRegistry.each(function(r)
        if r.uid ~= victim.uid and r.lifecycle == "active" and count < 24 then
            local m = type(r.memory) == "table" and r.memory or {}
            local related = (vmem.groupId ~= nil and m.groupId == vmem.groupId) or r.factionId == victim.factionId
                or (bucket("pairs")[(M.pairKey(r.uid, victim.uid))] ~= nil)
            if related then
                local w, t = M.closeness(r.uid, victim.uid)
                if w >= M.griefCfg.minW and opts.skipName and M.griefHasName and M.griefHasName(r.uid, vname) then w = -1 end
                if w >= M.griefCfg.minW then
                    count = count + 1
                    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(r.uid) or nil
                    local x, y, z = pos(sh)
                    local saw = x ~= nil and bx ~= nil and math.floor(z or 0) == math.floor(bz or 0)
                        and d2(x, y, bx, by) <= M.griefCfg.sawTiles ^ 2
                    if opts.victim ~= nil then saw = false end
                    M.griefOf(r.uid)[tostring(victim.uid)] = { n = vname, t = t, w = w, at = tonumber(opts.at) or h, saw = saw, known = saw, off = opts.victim ~= nil or nil,
                        src = saw and "you saw it" or nil, kid = kid, kn = kname, x = bx and math.floor(bx), y = by and math.floor(by),
                        z = bz and math.floor(bz) or 0, learnedMs = saw and nowMs() or nil, learnedH = saw and h or nil, reacted = saw }
                    -- the killer: A-Life already handles the player (NpcOpinion.noteKill for the group); NPC killers only in our layer
                    if mercy then
                        -- handled by M.onMercyKill (grief, gratitude, rare anger)
                    elseif kid == "player" and w >= M.griefCfg.closeW and M.markPlayerNemesis then
                        M.markPlayerNemesis(r.uid, "killed their " .. tostring(t) .. " " .. vname)
                    elseif kid ~= nil and kid ~= "zombie" and kid ~= "player" and kid ~= tostring(r.uid) and M.pairBump then
                        pcall(M.pairBump, r.uid, kid, -math.floor(60 * w), "killed " .. vname, w >= M.griefCfg.closeW and "nemesis" or nil)
                        -- v0.3.3: with A-Life Talk Patch the killer becomes a real enemy in A-Life (they fight on sight)
                        local P = M.patch and M.patch() or nil
                        if P ~= nil and type(P.setPairStance) == "function" and w >= 0.4 then
                            pcall(P.setPairStance, r.uid, kid, "hostile", w >= M.griefCfg.closeW and 72 or 24, "killed " .. vname, nil)
                        end
                    end
                    if M.keyMem and not saw then pcall(M.keyMem, r.uid, "death", vname .. " (" .. tostring(t) .. ") died - they don't know yet") end
                end
            end
        end
        return false
    end)
    if count > 0 then log("grief: " .. vname .. " is mourned by " .. count .. " NPC(s)") end
end

-- someone tells them (you, or another NPC out loud)
local function mentionsDeath(low)
    for _, w in ipairs(M.griefCfg.deathWords) do if string.find(low, w, 1, true) then return true end end
    return false
end
function M.learnFrom(mournerUid, low, src, onlyRelated)
    local learned = nil
    for deadUid, e in pairs(M.griefOf(mournerUid)) do
        if type(e) == "table" and not e.known then
            local first = string.match(tostring(e.n), "^(%S+)")
            if first and #first > 2 and string.find(low, string.lower(first), 1, true) then
                e.known, e.src, e.learnedMs, e.learnedH, e.reacted = true, src, nowMs(), hours(), false
                learned = e
                if M.keyMem then pcall(M.keyMem, mournerUid, "death", "Learned " .. e.n .. " died (" .. src .. ")") end
                log("grief news: " .. tostring(mournerUid) .. " learned about " .. e.n .. " (" .. src .. ")")
            end
        end
    end
    -- 0.5.2.6 [pt254u]: told about someone who is dead but they had no grief entry (not close enough when it happened,
    -- or the death was off-screen): they learn it now - key memory + grief (light unless close). Off: toldDeath.
    if learned == nil and M.learnUnlisted and M.settings.toldDeath ~= false then
        local ok, got = pcall(M.learnUnlisted, mournerUid, low, src, onlyRelated)
        if ok and got then learned = got end
    end
    return learned
end
function M.griefHasName(mournerUid, name)
    for _, e in pairs(M.griefOf(mournerUid)) do
        if type(e) == "table" and tostring(e.n) == tostring(name) then return true end
    end
    return false
end

function M.griefFromPlayer(player, text, hearers)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    if not mentionsDeath(low) then return end
    for _, l in ipairs(hearers or {}) do M.learnFrom(l.record.uid, low, "the newcomer told you") end
end

table.insert(M.npcLineHooks, function(shell, uid, text, x, y)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    if x == nil or not mentionsDeath(low) then return end
    local pa = PA()
    if not fn(pa.ActorRegistry, "each") then return end
    local speaker = uid and rec(uid)
    local src = "you heard it from " .. (speaker and nameOf(speaker) or "someone")
    local r2 = M.settings.talkTiles ^ 2
    if not fn(pa.Talk, "shellFor") then return end
    pa.ActorRegistry.each(function(r)
        if type(r) == "table" and r.lifecycle == "active" and tostring(r.uid) ~= tostring(uid) then
            local g = bucket("grief")[tostring(r.uid)]
            if type(g) == "table" and M.hasAny(g) then
                local sh = pa.Talk.shellFor(r.uid)
                local rx, ry = pos(sh)
                if rx ~= nil and d2(rx, ry, x, y) <= r2 then M.learnFrom(r.uid, low, src, true) end
            elseif M.settings.toldDeath ~= false and M.learnUnlisted then -- 0.5.2.6: no entry yet -> only people tied to the dead
                local sh = pa.Talk.shellFor(r.uid)
                local rx, ry = pos(sh)
                if rx ~= nil and d2(rx, ry, x, y) <= r2 then M.learnFrom(r.uid, low, src, true) end
            end
        end
        return false
    end)
end)

-- prompt: at most 2 griefs, strongest first
table.insert(M.requestExtras, function(req, player, listener, now)
    local h = hours()
    local list = {}
    for deadUid, e in pairs(M.griefOf(listener.record.uid)) do
        if type(e) == "table" and e.known then
            local inten, days = M.griefIntensity(e, h)
            if inten >= 0.08 then
                local dead = rec(deadUid)
                local word = (M.typeWord and dead) and M.typeWord(e.t or "comrade", dead) or tostring(e.t or "comrade")
                if M.lateTypes and M.lateTypes[tostring(e.t)] then word = "late " .. tostring(word) end -- 0.5.2.6
                local frac = days - math.floor(days)
                local item = { e.n, word, agoText(days), tostring(e.kn or "?"), e.saw and 1 or 0, M.griefMood(e, inten, days),
                    math.floor(inten * 100), (days >= 1.5 and (frac < 0.08 or frac > 0.92)) and math.floor(days + 0.5) or 0,
                    e.src or "", (e.learnedMs and now - e.learnedMs < 60000 and h - (tonumber(e.learnedH) or h) < 1) and 1 or 0, deadUid }
                list[#list + 1] = item
                if req.said ~= nil and req.said ~= "" and item[10] == 1 then e.reacted = true end -- they react in this reply
            end
        end
    end
    table.sort(list, function(a, b) return a[7] > b[7] end)
    while #list > 2 do table.remove(list) end
    if #list > 0 then req.grief = list end
end)

-- ambient: break the news to a comrade who doesn't know, or remember someone you both lost
function M.ambientGrief(req, me, partner)
    local mine, theirs = M.griefOf(me.record.uid), M.griefOf(partner.record.uid)
    for deadUid, e in pairs(mine) do
        local t = theirs[deadUid]
        if type(e) == "table" and e.known and type(t) == "table" and not t.known and M.griefIntensity(e) >= 0.15 then
            req.news = { e.n, tostring(e.kn or "something"), e.saw and 1 or 0 }
            t.known, t.src, t.learnedMs, t.learnedH, t.reacted = true, "you heard it from " .. nameOf(me.record), nowMs(), hours(), true
            return
        end
    end
    if M.roll(100) >= M.griefCfg.rememberChance then return end
    for deadUid, e in pairs(mine) do
        local t = theirs[deadUid]
        if type(e) == "table" and e.known and type(t) == "table" and t.known and M.griefIntensity(e) >= 0.12 then
            req.remember = e.n
            return
        end
    end
end

-- tick: react to news you just learned (if you weren't the one being told) and to the place where they died
M.griefNextAt = 0
function M.griefTick()
    local now = nowMs()
    if now < M.griefNextAt then return end
    M.griefNextAt = now + 4000
    M.eachPlayer(M.griefTickFor) -- pre-1.0 MP (P3): mourners near every player (single player: you)
end
function M.griefTickFor(player)
    local now = nowMs()
    local pa = PA()
    if player == nil or not fn(pa and pa.Talk, "listeners") then return end
    for _, l in ipairs(pa.Talk.listeners(player, 20)) do
        local g = bucket("grief")[tostring(l.record.uid)]
        if type(g) == "table" then
            local x, y = pos(l.shell)
            for deadUid, e in pairs(g) do
                if type(e) == "table" and e.known then
                    if e.reacted == false and e.learnedMs and now - e.learnedMs > 2500 and now - e.learnedMs < 60000 then
                        e.reacted = true
                        M.react("news", l, player, { what = "You just learned that " .. e.n .. " (your " .. tostring(e.t) .. ") is dead ("
                            .. tostring(e.src) .. ")", style = "react like a real person who just heard this: "
                            .. ((M.griefNewsStyle and M.settings.partnerLossTrauma ~= false and M.griefNewsStyle(l.record.uid)) or "denial, shock, tears or rage") .. ", as strong as your bond", maxWords = 16 }, { key = "news:" .. tostring(l.record.uid), keyCooldownMs = M.griefCfg.newsGapMs, urgent = true })
                    elseif x ~= nil and e.x ~= nil and d2(x, y, e.x, e.y) <= M.griefCfg.placeTiles ^ 2
                            and now - (e.learnedMs or -1e12) > 600000
                            and now - (e.placeMs or -1e12) > M.griefCfg.placeGapMs and M.griefIntensity(e) >= 0.2 then
                        e.placeMs = now
                        local inten, days = M.griefIntensity(e)
                        M.react("grief", l, player, { what = "You're at the spot where " .. e.n .. " (your " .. tostring(e.t) .. ") died, "
                            .. agoText(days), style = "a quiet, raw line to yourself or to them; say their name", maxWords = 14 },
                            { key = "grief:" .. tostring(l.record.uid), keyCooldownMs = 120000, modeCooldownMs = 30000 })
                    end
                end
            end
        end
    end
end

function M.installGrief()
    if M.griefHooked then return end
    if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Grief", function(body, uid, killer)
            local ok, err = pcall(M.griefOnDeath, body, uid, killer)
            if not ok then log("grief death error: " .. tostring(err)) end
        end)
        M.griefHooked = true
    end
end

return M
