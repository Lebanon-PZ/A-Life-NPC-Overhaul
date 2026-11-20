-- A-Life Talk v3.2: hearing. NPCs know what they could HEAR within earshot, not only what they see.
--   * Player lines: ProjectALife.Talk.onPlayerText is wrapped (outermost; the original always runs). Every line
--     is stored with its loudness: talk carries settings.talkTiles (14), a shout settings.shoutTiles (32).
--     NPCs in range get it as "just said nearby" context even when it wasn't said to them; lines that matter to
--     them (their name, their group, insults, secrets) go to their memory ("I heard what you said about me").
--   * NPC lines: every A-Life line (canned replies, ChatterDirector banter, barks) already passes our
--     Speech.say wrapper (Main) and is heard by NPCs within talkTiles.
--   * Sounds: vanilla Events.OnWorldSound (x, y, z, radius, volume, source) + Events.OnWeaponSwing (gunshots)
--     + a cheap zombie-moan count around the player + helicopter check. Range = the sound's own radius.
--   * Notable sounds (gunshot, explosion, alarm, helicopter, glass, horde) make one nearby NPC react out loud
--     (cooldowns per kind, the NPC must be close enough for you to hear them).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Hearing") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Hearing"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Hearing") end end -- 0.5.1.6 perf label

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

M.hear = {
    keepSounds = 30, soundMs = 300000, inPrompt = 6,
    reactTiles = 22,          -- the reacting NPC must be this close to you (you hear them)
    kindCooldownMs = { gunshot = 45000, explosion = 60000, alarm = 180000, helicopter = 300000, glass = 90000,
        door = 90000, horde = 180000, horn = 120000, groan = 600000, engine = 600000 },
    notable = { gunshot = true, explosion = true, alarm = true, helicopter = true, glass = true, horde = true, horn = true, door = true },
    groanEveryMs = 10000, groanTiles = 20, groanMin = 6, hordeMin = 15,
    rude = { "fuck", "shit", "idiot", "stupid", "moron", "bitch", "asshole", "retard", "loser", "ugly", "hate", "dumb",
        "creep", "liar", "useless", "worthless", "coward", "chud", "chump", "kill", "shoot", "rob ", "screw" },
    secret = { "secret", "don't tell", "dont tell", "between us", "between you and me", "i stole", "i killed", "bitten",
        "bit me", "infected", "scratched", "my stash", "hidden", "hide it", "rob them", "rob him", "rob her", "steal from" },
}
M.sounds = {}

----------------------------------------------------------------------------------------------------------------
-- direction words ("to the north, close")
----------------------------------------------------------------------------------------------------------------
function M.dirWord(dx, dy)
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 6 then return "right here" end
    if d ~= d then return "nearby" end -- NaN
    -- v0.4.0: Kahlua's % keeps the sign of negative numbers, so atan2's negative angles gave a nil direction word
    local ang = math.deg(math.atan2(-dy, dx)) -- map y grows south
    while ang < 0 do ang = ang + 360 end
    local names = { "east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast" }
    local how = d < 25 and "close" or (d < 80 and "not far" or "far off")
    local idx = math.floor((ang + 22.5) / 45)
    idx = idx - math.floor(idx / 8) * 8
    return "to the " .. tostring(names[idx + 1] or "side") .. ", " .. how
end

----------------------------------------------------------------------------------------------------------------
-- sounds
----------------------------------------------------------------------------------------------------------------
function M.addSound(kind, what, x, y, z, r, src)
    if x == nil then return end
    local now = nowMs()
    -- merge repeats of the same kind nearby (an alarm calls addSound every few ticks)
    for i = #M.sounds, math.max(1, #M.sounds - 8), -1 do
        local s = M.sounds[i]
        if s.kind == kind and now - s.at < 20000 and d2(s.x, s.y, x, y) < 400 then s.at, s.n = now, (s.n or 1) + 1; return s end
    end
    local s = { at = now, kind = kind, what = what, x = x, y = y, z = z or 0, r = math.max(8, math.min(r or 20, 400)), src = src }
    M.sounds[#M.sounds + 1] = s
    while #M.sounds > M.hear.keepSounds do table.remove(M.sounds, 1) end
    if M.hear.notable[kind] then pcall(M.soundReaction, s) end
    return s
end

local function isA(o, class)
    local ok, r = pcall(function() return instanceof(o, class) end)
    return ok and r == true
end

-- v0.4.0: Java exceptions inside pcall are still printed with a stack trace by PZ (the user's console had 600+).
-- Every engine probe checks the method exists first and is switched off for the session after its first failure.
function M.helicopterUp()
    local up = false
    if not M.probeOff("heli1") then
        local w = type(getWorld) == "function" and getWorld() or nil
        if w == nil or w.getHelicopter == nil then M.probeOff("heli1", true)
        else
            local ok = pcall(function() local h = w:getHelicopter(); if h ~= nil and h.isActive ~= nil and h:isActive() then up = true end end)
            if not ok then M.probeOff("heli1", true) end
        end
    end
    if not up and not M.probeOff("heli2") then
        local gt = type(getGameTime) == "function" and getGameTime() or nil
        if gt == nil or gt.getHelicopterDay == nil or gt.getHelicopterStartHour == nil or gt.getHelicopterEndHour == nil then M.probeOff("heli2", true)
        else
            local ok = pcall(function() if gt:getHelicopterDay() == gt:getNightsSurvived() and gt:getHour() >= gt:getHelicopterStartHour() and gt:getHour() <= gt:getHelicopterEndHour() then up = true end end)
            if not ok then M.probeOff("heli2", true) end
        end
    end
    return up
end

M.lastShotAt = -1e12
function M.onWorldSound(x, y, z, radius, volume, source)
    if not M.settings.enabled then return end
    radius = tonumber(radius) or 0
    if radius < 8 then return end
    local now = nowMs()
    if source ~= nil and isA(source, "IsoPlayer") then
        return -- the player's own shots come from OnWeaponSwing; shouts from chat; footsteps don't count
    elseif source ~= nil and isA(source, "IsoZombie") then
        local uid = M.uidOf(source)
        if uid ~= nil and radius >= 25 then
            local name = nil
            pcall(function() local r = PA().ActorRegistry.read(uid); name = PA().Names.of(r) end)
            M.addSound("gunshot", "a gunshot" .. (name and (" (" .. name .. " firing)") or ""), x, y, z, radius, uid)
        end
        return -- plain zombie noise is covered by the moan count
    elseif source ~= nil and isA(source, "BaseVehicle") then
        if radius >= 60 then M.addSound("horn", "a car horn or car alarm blaring", x, y, z, radius)
        else M.addSound("engine", "a car engine running", x, y, z, radius) end
    elseif source ~= nil and isA(source, "IsoWindow") then M.addSound("glass", "glass breaking", x, y, z, radius)
    elseif source ~= nil and (isA(source, "IsoDoor") or isA(source, "IsoThumpable") or isA(source, "IsoBarricade")) then
        M.addSound("door", "something banging on a door / wood splintering", x, y, z, radius)
    elseif source ~= nil and isA(source, "IsoTrap") then M.addSound("explosion", "an explosion", x, y, z, radius)
    elseif source == nil then
        if radius >= 100 then
            if M.helicopterUp() then M.addSound("helicopter", "a helicopter passing overhead", x, y, z, radius)
            else M.addSound("alarm", "a loud alarm going off", x, y, z, radius) end
        elseif radius >= 40 then M.addSound("explosion", "a loud bang", x, y, z, radius) end
    end
end

function M.onWeaponSwing(character, weapon)
    if character == nil or weapon == nil then return end
    local ranged = false
    pcall(function() ranged = weapon:isRanged() == true end)
    if not ranged then return end
    local radius = 60
    pcall(function() radius = weapon:getSoundRadius() or radius end)
    local x, y, z = pos(character)
    local who = isA(character, "IsoPlayer") and "the newcomer" or "someone"
    M.lastShotAt = nowMs()
    M.addSound("gunshot", "a gunshot (" .. who .. " firing)", x, y, z, radius, isA(character, "IsoPlayer") and "player" or nil)
end

M.groanNextAt = 0
M.groanBand = 0
M.groanBands = M.groanBands or {} -- pre-1.0 MP (P2b): each player's own groan level (single player: one)
function M.hearingTick()
    local now = nowMs()
    if not M.settings.enabled or now < M.groanNextAt then return end
    M.groanNextAt = now + M.hear.groanEveryMs
    M.eachPlayer(M.hearingTickFor, now)
end
function M.hearingTickFor(player, now)
    if player == nil then return end
    local mp = type(ALifeSide) == "table" and ALifeSide.mpServer()
    local bandKey = mp and tostring(ALifeSide.keyOf(player)) or nil
    if bandKey ~= nil then M.groanBand = M.groanBands[bandKey] or 0 end
    local px, py, pz = pos(player)
    if px == nil then return end
    local count = 0
    pcall(function()
        local list = getCell():getZombieList()
        local r2 = M.hear.groanTiles ^ 2
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            if not z:isDead() and d2(z:getX(), z:getY(), px, py) <= r2 and M.uidOf(z) == nil then count = count + 1 end
        end
    end)
    local band = count >= M.hear.hordeMin and 2 or (count >= M.hear.groanMin and 1 or 0)
    if band > M.groanBand then
        if band == 2 then M.addSound("horde", "a lot of zombies moaning close by (about " .. tostring(math.floor(count / 5 + 0.5) * 5) .. ")", px, py, pz, 30)
        else M.addSound("groan", "zombies moaning nearby", px, py, pz, 25) end
    end
    M.groanBand = band
    if bandKey ~= nil then M.groanBands[bandKey] = band end
    if M.helicopterUp() and now - (M.heliAt or -1e12) > 120000 then
        M.heliAt = now
        M.addSound("helicopter", "a helicopter overhead", px, py, pz, 300)
    end
end

-- one nearby NPC reacts out loud to a notable sound
function M.soundReaction(s)
    local pa = PA()
    -- pre-1.0 MP (P2b): the player nearest the sound (within its reach + the talk reach); single player: you
    local player = nil
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then player = ALifeSide.nearest(s.x, s.y, (tonumber(s.r) or 0) + M.hear.reactTiles)
    else player = M.you() end
    if player == nil or pa == nil or not fn(pa.Talk, "listeners") then return end
    if s.src == "player" and M.hostileFightNear and M.hostileFightNear(player) then return end -- mid-fight: combat barks instead
    local px, py = pos(player)
    local best, bestD = nil, 1e12
    for _, l in ipairs(pa.Talk.listeners(player, M.hear.reactTiles)) do
        local x, y = pos(l.shell)
        if x ~= nil and d2(x, y, s.x, s.y) <= s.r * s.r then
            local person = type(l.record.memory) == "table" and l.record.memory.person
            if type(person) ~= "table" and not pa.Talk.busy(l.record, nowMs()) and l.distance < bestD then best, bestD = l, l.distance end
        end
    end
    if best == nil then return end
    local x, y = pos(best.shell)
    local where = M.dirWord(s.x - x, s.y - y)
    local style = ({
        gunshot = "a gunshot means people and trouble; react like a survivor would (tense, alert, maybe tell them to get down or ask who's shooting)",
        explosion = "startled; say what you think it was and whether to stay away",
        alarm = "alarms pull every zombie for miles; react to that",
        helicopter = "a helicopter in 1993 Knox County could mean rescue or that they're leaving everyone; react",
        glass = "someone or something broke in; react quietly",
        door = "something is trying to get through; react quietly",
        horde = "the dead are close and many; react with fear or urgency, quietly",
        horn = "the noise will draw zombies; react",
    })[s.kind] or "react"
    M.react("sound", best, player, { what = "You just heard " .. s.what .. ", " .. where, style = style, maxWords = 14 },
        { key = "sound:" .. s.kind, keyCooldownMs = M.hear.kindCooldownMs[s.kind] or 60000, modeCooldownMs = 20000 })
end

-- prompt: the last few things this NPC could hear (talk is in "heard"; this is sounds)
table.insert(M.requestExtras, function(req, player, listener, now)
    local x, y = pos(listener.shell)
    if x == nil then return end
    local out = {}
    for i = #M.sounds, 1, -1 do
        local s = M.sounds[i]
        if now - s.at > M.hear.soundMs then break end
        if d2(s.x, s.y, x, y) <= s.r * s.r then
            table.insert(out, 1, { s.what, math.floor((now - s.at) / 1000), M.dirWord(s.x - x, s.y - y) })
            if #out >= M.hear.inPrompt then break end
        end
    end
    if #out > 0 then req.sounds = out end
end)

----------------------------------------------------------------------------------------------------------------
-- player lines (wrapper around Talk.onPlayerText; original always runs)
----------------------------------------------------------------------------------------------------------------
local function lower(s) return string.lower(tostring(s or "")) end
local function hasAny(low, list) for _, w in ipairs(list) do if string.find(low, w, 1, true) then return true end end return false end

function M.hearPlayer(player, text, loud)
    local now = nowMs()
    local x, y = pos(player)
    local r = loud and M.settings.shoutTiles or M.settings.talkTiles
    M.heardPlayerLast = { text = text, at = now }
    M.lastPlayerLineAt = now
    M.remember({ at = now, player = true, text = text, x = x, y = y, r = r, loud = loud == true })
    local pa = PA()
    local hearers = fn(pa.Talk, "listeners") and pa.Talk.listeners(player, r) or {}
    return hearers
end

-- who the line was about / why it matters to a hearer who wasn't spoken to
function M.overheard(player, text, loud, hearers)
    local pa = PA()
    local low = " " .. lower(text) .. " "
    local addressed = M.lastAddressee
    local addrUid = (addressed and addressed.text == text and nowMs() - addressed.at < 1500) and addressed.uid or nil
    local rude, secret = hasAny(low, M.hear.rude), hasAny(low, M.hear.secret)
    local list = {}
    for _, l in ipairs(hearers) do
        local uid = tostring(l.record.uid)
        if uid ~= addrUid then
            local m = type(l.record.memory) == "table" and l.record.memory or {}
            local named = false
            for _, n in ipairs({ m.personFirst, m.personLast }) do
                if type(n) == "string" and #n > 2 and string.find(low, "%W" .. string.lower(n) .. "%W") then named = true end
            end
            local faction = nil
            pcall(function() local f = pa.Catalog.faction(l.record.factionId); faction = f and f.general and f.general.name end)
            if type(faction) == "string" and #faction > 3 and string.find(low, string.lower(faction), 1, true) then named = true end
            if named or rude or secret then
                list[#list + 1] = { uid = uid, named = named, name = fn(pa.Names, "of") and pa.Names.of(l.record) or nil }
            end
        end
    end
    if #list == 0 then return end
    M.submit({ mode = "hear", uid = list[1].uid, player = player, listener = { record = pa.ActorRegistry.read(list[1].uid) },
        hear = { text = string.sub(text, 1, 200), loud = loud == true, listeners = list, rude = rude, secret = secret },
        startMs = nowMs(), depth = 0 })
end

function M.hearRequest(job, now)
    local listener = M.refresh(job) or job.listener
    if listener == nil or listener.record == nil then return nil end
    return { id = tostring(nowMs()) .. "-h" .. tostring(M.counter), mode = "hear", uid = job.uid, worldId = M.worldId(),
        hear = job.hear, said = job.hear.text, world = { day = (function() local d = 0; pcall(function() d = getGameTime():getNightsSurvived() end); return d end)(),
        hour = (function() local h = 0; pcall(function() h = getGameTime():getHour() end); return h end)() },
        npc = { name = job.hear.listeners[1].name } }
end

-- the bridge judged the line (same rules as face to face); NPCs it was ABOUT take an opinion hit for insults
M.overheardAt = {}
function M.hearFinish(p, r)
    local d = tonumber(r.d) or 0
    if d >= 0 then return end
    local pa = PA()
    if not fn(pa.NpcOpinion, "adjust") then return end
    for _, l in ipairs(p.hear.listeners) do
        if l.named and nowMs() - (M.overheardAt[l.uid] or -1e12) > 60000 then
            M.overheardAt[l.uid] = nowMs()
            local record = pa.ActorRegistry.read(l.uid)
            if record ~= nil then
                pa.NpcOpinion.adjust(record, p.player, math.max(-6, d), "They overheard what you said about them.")
                if M.keyMem then pcall(M.keyMem, l.uid, "insult", "Overheard you: \"" .. string.sub(p.hear.text, 1, 70) .. "\"") end
                log("overheard insult: " .. tostring(l.name) .. " " .. tostring(d))
            end
        end
    end
end
M.eventModes.hear = { request = M.hearRequest, finish = M.hearFinish }

-- A-Life's onPlayerText reasons that never reach Talk.respond (nobody listening, robbery / standoff words, shout warning)
M.respondSkip = { nobody = true, disabled = true, empty = true, robbery = true, standoff = true, noise_warning = true,
    server_authority_required = true, ["nil"] = true, radio = true }
function M.installHearing()
    local pa = PA()
    if M.hearingWrapped or not fn(pa and pa.Talk, "onPlayerText") then return end
    -- let the radio wrapper go first (we stay outermost); pre-1.0 MP: only where the radio part runs at all
    if M.installRadio and (M.partOn == nil or M.partOn("radio")) and M.origOnPlayerText == nil then return end
    local inner = pa.Talk.onPlayerText
    local body = function(player, text, loud, ...)
        local plain = type(text) == "string" and not string.match(text, "^%s*/") and not string.match(text, "^%s*$")
        local hearers = {}
        if plain and M.settings.enabled then
            local okH, got = pcall(M.hearPlayer, player, text, loud == true)
            if okH and type(got) == "table" then hearers = got end
            if M.griefFromPlayer then pcall(M.griefFromPlayer, player, text, hearers) end
            for _, h in ipairs(M.playerWordHooks or {}) do pcall(h, player, text, loud == true, hearers) end -- 0.5.1
        end
        M.respondHit = false
        local a, b, c, d = inner(player, text, loud, ...)
        if plain and M.settings.enabled and not M.respondHit and M.respondBypassed
                and not M.respondSkip[tostring(b)] then
            pcall(M.respondBypassed, b)
        end
        if plain and M.settings.enabled then
            if a == false and b == "nobody" and M.hostileReach then
                local okR, said = pcall(M.hostileReach, player, text, loud == true)
                if okR and said then a, b = true, "ai_hostile" end
            end
            pcall(M.overheard, player, text, loud == true, hearers)
        end
        return a, b, c, d
    end
    -- pre-1.0 MP (P2b): while a typed line is handled (on the server in MP), "you" is the player who typed it
    pa.Talk.onPlayerText = function(player, text, loud, ...)
        local side = ALifeSide
        if type(side) ~= "table" or player == nil then return body(player, text, loud, ...) end
        local prev = side.cur
        side.cur = player
        local ok, a, b, c, d = pcall(body, player, text, loud, ...)
        side.cur = prev
        if not ok then error(a, 0) end
        return a, b, c, d
    end
    M.hearingWrapped = true
    if type(Events) == "table" then
        if Events.OnWorldSound and Events.OnWorldSound.Add then
            Events.OnWorldSound.Add(function(...) pcall(M.onWorldSound, ...) end)
        end
        if Events.OnWeaponSwing and Events.OnWeaponSwing.Add then
            ALifeHealth.add(Events.OnWeaponSwing, "ALifeLLMTalk_Hearing", function(...) pcall(M.onWeaponSwing, ...) end)
        end
    end
    log("hearing: wrapped Talk.onPlayerText (all player lines, talk " .. M.settings.talkTiles .. " / shout "
        .. M.settings.shoutTiles .. " tiles), OnWorldSound, OnWeaponSwing")
end

return M
