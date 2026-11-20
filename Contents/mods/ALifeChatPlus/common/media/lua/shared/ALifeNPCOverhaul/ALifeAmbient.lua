-- A-Life NPC Overhaul: people talk without being asked.
--   They speak first. Someone near you who has a reason says something: asks for food when they're starving, warns
--   you off when you're too close and too well armed, thanks you for what you did last week, needles you about a
--   grudge, greets a familiar face. Or stays quiet and watches - most people do, most of the time.
--   They talk to each other. Two of the same group standing together (or two of your residents) talk where you can
--   hear: their day, their worries, the dead, each other, and you - fair or not.
-- Lines come from the AI with each person's life story, memories and situation, so they stay in character. Nothing
-- happens without the AI bridge running; it never interrupts a conversation you're having.

local TAG = "[ALifeAmbient]"
ALifeAmbient = ALifeAmbient or {}
local A = ALifeAmbient
A.CHECK_MS = 12000              -- how often to look around (real ms)
A.SPEAK_TILES, A.HEAR_TILES = 10, 18
A.SPEAK_CHANCE, A.BANTER_CHANCE = 30, 20       -- percent per check, when someone qualifies
A.PERSON_COOLDOWN_MS = 8 * 60000               -- a person speaks up unprompted at most this often
A.GROUP_COOLDOWN_MS = 6 * 60000                -- a group's overheard talk at most this often
A.QUIET_AFTER_TALK_MS = 45000                  -- not while you're talking to them
A.lastSpoke, A.lastBanter, A.busy = {}, {}, false

local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function AI() return ALifeChatAI end
local function pos(o)
    local ok, x, y = pcall(function() return o:getX(), o:getY() end)
    if ok then return x, y end
    return nil
end
local function groupKey(record)
    local m = type(record.memory) == "table" and record.memory or {}
    if type(m.jimmyResident) == "table" and m.jimmyResident.baseId then return "base:" .. tostring(m.jimmyResident.baseId), true end
    if m.groupId then return "g:" .. tostring(m.groupId), false end
    return nil
end
local function fieldsFor(ai, record, shell, player, prefix)
    local p = ai.profile(record, player)
    local out = {
        prefix .. "name=" .. ai.clean(p.name, 40), prefix .. "faction=" .. ai.clean(p.faction, 60),
        prefix .. "role=" .. ai.clean(p.role, 40), prefix .. "temperament=" .. ai.clean(p.temperament, 30),
        prefix .. "sex=" .. ai.clean(p.sex, 2), prefix .. "stance=" .. ai.clean(p.stance, 20), prefix .. "mood=" .. ai.clean(p.mood, 40),
        prefix .. "situation=" .. ai.clean(ai.situation(record, shell, player), 400),
    }
    local needs = {}
    pcall(function() needs = ProjectALifeJimmy.Needs.needs(record.memory) or {} end)
    out[#out + 1] = prefix .. "needs=" .. string.format("hunger %d, thirst %d, tired %d", tonumber(needs.hunger) or 0,
        tonumber(needs.thirst) or 0, tonumber(needs.fatigue) or 0)
    local _, resident = groupKey(record)
    out[#out + 1] = prefix .. "resident=" .. (resident and "1" or "0")
    for _, l in ipairs(ai.context(record, p)) do out[#out + 1] = prefix .. l end
    out[#out + 1] = prefix .. "history=" .. ai.clean(table.concat(ai.history(record.uid), " || "), 600)
    return out, p
end

-- someone speaks up to you
function A.speakUp(player, listeners)
    local ai = AI()
    local t = now()
    local pick = nil
    for _, l in ipairs(listeners) do
        local uid = l.record.uid
        if l.distance <= A.SPEAK_TILES and t - (A.lastSpoke[uid] or -1e12) > A.PERSON_COOLDOWN_MS
                and t - (ai.lastTalk[uid] or -1e12) > A.QUIET_AFTER_TALK_MS then
            pick = l
            break
        end
    end
    if pick == nil then return false end
    A.lastSpoke[pick.record.uid] = t
    local fields = { "mode=initiate", "day=" .. tostring(math.floor((getGameTime():getWorldAgeHours()) / 24) + 1),
        "distance=" .. tostring(math.floor(pick.distance)) }
    local f = fieldsFor(ai, pick.record, pick.shell, player, "")
    for _, x in ipairs(f) do fields[#fields + 1] = x end
    A.busy = true
    local sent = ai.request(fields, function(lines)
        A.busy = false
        if lines == nil or not ai.stillThere(player, pick.shell, A.HEAR_TILES + 6) then return end
        for _, line in ipairs(lines) do
            local st = string.match(line, "^story=(.*)$")
            if st ~= nil and st ~= "" and ALifeStory ~= nil and ALifeStory.get(pick.record) == nil then ALifeStory.set(pick.record, st) end
            local text = string.match(line, "^text=(.*)$")
            if text ~= nil and text ~= "" and text ~= "-" then
                ai.say(pick.shell, text, { face = player })
                ai.remember(pick.record.uid, "Them (unprompted): " .. text)
            end
        end
    end, 8000, 6)
    if not sent then A.busy = false end
    return sent
end

-- two of a group talk where you can hear
function A.banter(player, listeners)
    local ai = AI()
    local t = now()
    for i = 1, #listeners do
        local a = listeners[i]
        local ka = groupKey(a.record)
        if ka ~= nil and t - (A.lastBanter[ka] or -1e12) > A.GROUP_COOLDOWN_MS
                and t - (ai.lastTalk[a.record.uid] or -1e12) > A.QUIET_AFTER_TALK_MS then
            for j = i + 1, #listeners do
                local b = listeners[j]
                if groupKey(b.record) == ka then
                    local ax, ay = pos(a.shell)
                    local bx, by = pos(b.shell)
                    if ax and bx and (ax - bx) ^ 2 + (ay - by) ^ 2 <= 36 then
                        A.lastBanter[ka] = t
                        local fields = { "mode=banter", "day=" .. tostring(math.floor((getGameTime():getWorldAgeHours()) / 24) + 1),
                            "stranger_distance=" .. tostring(math.floor(math.min(a.distance, b.distance))) }
                        local fa, pa = fieldsFor(ai, a.record, a.shell, player, "a_")
                        local fb, pb = fieldsFor(ai, b.record, b.shell, player, "b_")
                        for _, x in ipairs(fa) do fields[#fields + 1] = x end
                        for _, x in ipairs(fb) do fields[#fields + 1] = x end
                        A.busy = true
                        local sent = ai.request(fields, function(lines)
                            A.busy = false
                            if lines == nil or not ai.stillThere(player, a.shell, A.HEAR_TILES + 6)
                                or not ai.stillThere(player, b.shell, A.HEAR_TILES + 6) then return end
                            local delay = 0
                            local Talk = ProjectALife.Talk
                            for _, line in ipairs(lines) do
                                local who, text = string.match(line, "^line=([ab])|(.*)$")
                                if who ~= nil and text ~= nil and text ~= "" then
                                    local speaker = who == "a" and a or b
                                    local other = who == "a" and b or a
                                    local say = function()
                                        if ai.stillThere(player, speaker.shell, A.HEAR_TILES + 6) then ai.say(speaker.shell, text, { face = other.shell }) end
                                    end
                                    if delay == 0 or Talk == nil or type(Talk.later) ~= "function" then say()
                                    else Talk.later(delay, say) end
                                    delay = delay + 2600 + #text * 45
                                end
                            end
                        end, 10000, 7)
                        if not sent then A.busy = false end
                        return sent
                    end
                end
            end
        end
    end
    return false
end

local lastCheck = 0
function A.check()
    local ai = AI()
    if ai == nil or type(ai.request) ~= "function" or not ai.alive() or A.busy then return end
    local Talk = ProjectALife and ProjectALife.Talk
    local player = ALifeSide.campPlayer()
    if Talk == nil or player == nil then return end
    local okL, listeners = pcall(Talk.listeners, player, A.HEAR_TILES)
    if not okL or type(listeners) ~= "table" or #listeners == 0 then return end
    table.sort(listeners, function(x, y) return x.distance < y.distance end)
    -- with the dead at the door nobody makes small talk (they'll still talk to you if you speak to them)
    if ALifeSituation ~= nil and type(ALifeSituation.deadNear) == "function" and ALifeSituation.deadNear(player, 15) >= 5 then return end
    if roll(100) < A.BANTER_CHANCE and A.banter(player, listeners) then return end
    if roll(100) < A.SPEAK_CHANCE then A.speakUp(player, listeners) end
end

local failed = false
if Events ~= nil and Events.OnTick ~= nil then
    ALifeHealth.add(Events.OnTick, "ALifeAmbient", function()
        if failed or (ALifeMerge and ALifeMerge.skip("ambient")) then return end
        local t = now()
        if t - lastCheck < A.CHECK_MS then return end
        lastCheck = t
        local ok, err = pcall(A.check)
        if not ok then failed = true; A.busy = false; print(TAG .. " failed, off for this session: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
