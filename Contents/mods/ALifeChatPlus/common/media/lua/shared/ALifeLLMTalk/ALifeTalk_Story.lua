-- A-Life NPC Overhaul 0.8.7: A STORY FOR EVERYONE, client side. Each survivor may carry one goal of their own, only
-- from what is really there (no real basis = no story):
--   * revenge: a nemesis (Pairs "nemesis": killed someone they loved, a long feud) who is still alive;
--   * family: real kin or a partner (Pairs sibling / parent / child / partner) in another group or far away;
--   * amends: someone they really fell out with (rival / distrust / ex / enemy, score <= -20), still alive;
--   * clean: a real drinker (Habits) who wants to stop (a share of drinkers, setting).
-- This file picks the goal (works with the AI off), sends it to the server through ALifeCmd ("storyGoal"), and pulls
-- the outcome back ("storyPull" -> "storyGoals"). The tasks, their lines and steps live in ALifeQuests (server):
-- story_family / story_amends / story_revenge / story_clean on A-Life's task board.
-- What follows from an outcome: ties move (Pairs), feelings (Psyche), key memories; a drinker who stays dry
-- questCleanDays after you held their bottles is off the drink (Habits). A drink from you (any gift) or a bottle of
-- their own while they try = relapse. While they try, the bottle pulls less; while dry, not at all.
-- Psyche's off-screen goal shows the real story goal when there is one (the AI hears it).
-- No numbers shown. Settings: questStory (server), questCleanDays (server), questCleanWant, questStoryBond,
-- questStoryFar, questStoryGap, questStoryReach.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Story") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCmd"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Story"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Story") end end

ALifeGoals = ALifeGoals or {}
local K = ALifeGoals
local TAG = "[ALifeGoals]"
K.VERSION = ALifeSide.MOD_VERSION
K.DEFAULTS = {
    questCleanWant = 40,   -- % of real drinkers who want to stop
    questStoryBond = 25,   -- how much a tie mends when you walk them to family / to make it right
    questStoryFar = 150,   -- tiles: kin this far away (or in another group) is someone to go find
    questStoryGap = 7,     -- days after a story ends before they carry a new one
    questStoryReach = 60,  -- tiles: people this close get looked at for a story
}
K.KEYS = { "questCleanWant", "questStoryBond", "questStoryFar", "questStoryGap", "questStoryReach" }
K.FAMILY = { sibling = true, parent = true, child = true, partner = true }
K.FELLOUT = { rival = true, distrust = true, ex = true, enemy = true }
K.metrics = K.metrics or { picked = 0, sent = 0, outcomes = 0, relapses = 0, cleaned = 0, gone = 0 }
K.metrics.warned, K.metrics.tempted = K.metrics.warned or 0, K.metrics.tempted or 0
K.checked = K.checked or {} -- [uid] = game hour last looked at (session only)

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function M() return ALifeLLMTalk end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil check: a false setting stays false
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    if v == nil and type(ALifeQuests) == "table" and fn(ALifeQuests, "setting") then v = ALifeQuests.setting(key) end
    return v
end
local function on()
    if type(ALifeQuests) == "table" and fn(ALifeQuests, "on") then return ALifeQuests.on("questStory") end
    return setting("questStory") ~= false
end
local function rec(uid)
    local pa = PA()
    if uid == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function memOf(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function isDead(uid, r)
    local m = M()
    r = r or rec(uid)
    if type(r) == "table" and r.lifecycle == "dead" then return true end
    if fn(m, "isPersonDead") then local ok, d = pcall(m.isPersonDead, uid, r); if ok and d then return true end end
    return false
end
local function posOf(r)
    if type(r) ~= "table" then return nil end
    local sh = nil
    pcall(function() sh = PA().Talk.shellFor(r.uid) end)
    if sh ~= nil then
        local x, y = nil, nil
        pcall(function() x, y = sh:getX(), sh:getY() end)
        if tonumber(x) and tonumber(y) then return tonumber(x), tonumber(y) end
    end
    local wp = r.worldPosition
    if type(wp) == "table" and tonumber(wp.x) and tonumber(wp.y) then return tonumber(wp.x), tonumber(wp.y) end
    if tonumber(r.x) and tonumber(r.y) then return tonumber(r.x), tonumber(r.y) end
    return nil
end
local function firstName(r, fallback)
    local m = memOf(r)
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    if type(n) == "string" and n ~= "" then return string.match(n, "^(%S+)") or n end
    return fallback or "someone"
end
local function feel(uid, key, amount, why)
    local m = M()
    if fn(m, "feel") then pcall(m.feel, uid, key, amount, why) end
end
local function keyMem(uid, kind, text)
    local m = M()
    if fn(m, "keyMem") then pcall(m.keyMem, uid, kind, text) end
end

-- 0.8.8: how they feel about you (A-Life's NpcOpinion, the same call the rest of the mod uses on the client)
local function opinion(uid, player, delta, why)
    local pa, r = PA(), rec(uid)
    if r == nil or player == nil or delta == 0 or not (type(pa.NpcOpinion) == "table" and fn(pa.NpcOpinion, "adjust")) then return false end
    return pcall(pa.NpcOpinion.adjust, r, player, delta, why)
end
local function sayLine(uid, player, line)
    local m, sh = M(), nil
    pcall(function() sh = PA().Talk.shellFor(tostring(uid)) end)
    if sh ~= nil and fn(m, "say") then pcall(m.say, sh, player, line, { record = rec(uid) }) end
end
K.opinion, K.sayLine = opinion, sayLine

-- our side of each story, in the save: [uid] = { k, t, tn, h, dryH, seen, outcome, endH }
function K.store()
    local m = M()
    local data = nil
    if fn(m, "store") then pcall(function() data = m.store() end) end
    if type(data) ~= "table" then K.tmp = K.tmp or {}; data = K.tmp end
    data.story = type(data.story) == "table" and data.story or {}
    return data.story
end
function K.rowOf(uid) local r = K.store()[tostring(uid)]; return type(r) == "table" and r or nil end
-- a story they're living now (not ended)
function K.active(uid) local r = K.rowOf(uid); if r ~= nil and r.outcome == nil then return r end return nil end
function K.trying(uid) local r = K.active(uid); return r ~= nil and (r.k == "clean" or r.k == "second") end
-- got clean with your help (kept apart from the row, so a later story doesn't wipe it)
function K.isClean(uid) return K.store()["clean:" .. tostring(uid)] == true end

-- kin far away or with other people
function K.apart(r, o)
    local ga, gb = memOf(r).groupId, memOf(o).groupId
    if ga ~= nil and gb ~= nil and tostring(ga) ~= tostring(gb) then return true end
    local ax, ay = posOf(r)
    local bx, by = posOf(o)
    if ax == nil or bx == nil then return false end
    local far = tonumber(setting("questStoryFar")) or 150
    return (ax - bx) ^ 2 + (ay - by) ^ 2 > far * far
end

-- the one goal real data gives them, strongest first; nil = no story. skip = people whose story is already told
function K.pick(uid, r, skip)
    local m = M()
    uid = tostring(uid)
    r = r or rec(uid)
    if r == nil then return nil end
    local ties = {}
    if fn(m, "tiesOf") then
        local ok, list = pcall(m.tiesOf, uid, nil, 12, true)
        if ok and type(list) == "table" then ties = list end
    end
    local best = {}
    -- 0.9.1 second chance: they relapsed, and haven't had their second try yet
    local prev = K.rowOf(uid)
    if prev ~= nil and prev.k == "clean" and prev.outcome == "relapsed" and not prev.secondUsed then return { k = "second" } end
    -- 0.9.1 survivor's guilt: they saw someone close die, in the last two weeks
    if fn(m, "griefOf") then
        local okG, gr = pcall(m.griefOf, uid)
        if okG and type(gr) == "table" then
            local now = hours()
            for vuid, e in pairs(gr) do
                if type(e) == "table" and e.saw and (tonumber(e.w) or 0) >= 0.45 and now - (tonumber(e.at) or -1e9) <= 14 * 24
                        and not (type(skip) == "table" and skip[tostring(vuid)]) and rec(vuid) ~= nil then
                    best.guilt = { uid = tostring(vuid), name = e.n }
                    break
                end
            end
        end
    end
    for _, t in ipairs(ties) do
        local o = rec(t.uid)
        if o ~= nil and t.uid ~= nil and not (type(skip) == "table" and skip[tostring(t.uid)]) then
            local alive = not t.dead and not isDead(t.uid, o)
            if t.type == "nemesis" and alive and best.revenge == nil then best.revenge = t
            elseif K.FAMILY[t.type] and alive and best.prodigal == nil and (tonumber(t.score) or 0) <= -10 and K.apart(r, o) then best.prodigal = t
            elseif K.FAMILY[t.type] and alive and best.family == nil and K.apart(r, o) then best.family = t
            elseif K.FELLOUT[t.type] and alive and (tonumber(t.score) or 0) <= -20 and best.amends == nil then best.amends = t end
        end
    end
    for _, k in ipairs({ "revenge", "guilt", "prodigal", "family", "amends" }) do
        local t = best[k]
        if t ~= nil then return { k = k, t = tostring(t.uid), tn = firstName(rec(t.uid), t.name) } end
    end
    if fn(m, "habitOf") then
        local ok, hb = pcall(m.habitOf, uid)
        if ok and type(hb) == "table" and hb.drinker and hash(uid .. "#clean") % 100 < (tonumber(setting("questCleanWant")) or 40) then
            return { k = "clean" }
        end
    end
    return nil
end

local function send(player, name, args)
    if player == nil or not fn(ALifeCmd, "send") then return false end
    K.metrics.sent = K.metrics.sent + 1
    return ALifeCmd.send(player, name, args)
end

-- look at the people around you; a real basis = a story (once a game day each; a gap after one ends)
function K.assign(player)
    local m = M()
    if not on() or player == nil or not fn(m, "nearbyNpcs") then return 0 end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = player:getX(), player:getY(), player:getZ() end)
    if x == nil then return 0 end
    local ok, near = pcall(m.nearbyNpcs, x, y, z, tonumber(setting("questStoryReach")) or 60)
    if not ok or type(near) ~= "table" then return 0 end
    local now, n = hours(), 0
    local gap = (tonumber(setting("questStoryGap")) or 7) * 24
    for _, e in ipairs(near) do
        if n >= 8 then break end
        local uid = e.record and tostring(e.record.uid) or nil
        if uid ~= nil and now - (K.checked[uid] or -1e9) >= 24 then
            K.checked[uid] = now
            local row = K.rowOf(uid)
            local free = row == nil or (row.outcome ~= nil and now - (tonumber(row.endH) or 0) >= gap)
                or (row.k == "clean" and row.outcome == "relapsed" and not row.secondUsed) -- 0.9.1 second chance: no wait
            if free then
                local past, skip = {}, {}
                for _, x in ipairs(row and type(row.past) == "table" and row.past or {}) do past[#past + 1] = x end
                if row ~= nil and row.t ~= nil then past[#past + 1] = row.t end
                while #past > 6 do table.remove(past, 1) end
                for _, x in ipairs(past) do skip[tostring(x)] = true end
                local g = K.pick(uid, e.record, skip)
                if g ~= nil then
                    K.store()[uid] = { k = g.k, t = g.t, tn = g.tn, h = now, past = #past > 0 and past or nil, secondUsed = (g.k == "second") or (row and row.secondUsed) or nil }
                    K.metrics.picked = K.metrics.picked + 1
                    send(player, "storyGoal", { act = "set", uid = uid, k = g.k, t = g.t, tn = g.tn })
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- what the server says: adopt its goal, act on what's new (held, done)
function K.onGoals(payload)
    if type(payload) ~= "table" or type(payload.goals) ~= "table" then return 0 end
    local store, n = K.store(), 0
    for uid, g in pairs(payload.goals) do
        uid = tostring(uid)
        local row = store[uid]
        if type(g) == "table" then
            if row == nil or row.k ~= g.k or row.t ~= g.t then -- the server's story wins (someone else set it first)
                row = { k = g.k, t = g.t, tn = g.tn, h = tonumber(g.h) or hours() }
                store[uid] = row
            end
            if g.tn ~= nil then row.tn = g.tn end
            if g.dryH ~= nil and row.dryH ~= g.dryH and g.done == nil then
                row.dryH = g.dryH
                feel(uid, "pride", 0.2, "handed over their bottles")
                keyMem(uid, "kindness", "You held on to their bottles so they could get clean")
            elseif g.dryH == nil and row.dryH ~= nil and g.outcome == nil then row.dryH = nil end
            if g.done ~= nil and row.seen ~= g.done and not (row.outcome ~= nil and row.outcome == g.outcome) then
                row.seen = g.done
                K.outcome(uid, row, g)
                n = n + 1
            end
        elseif g == false and row ~= nil and row.outcome == nil and type(K.player) == "function" then
            -- server lost it (new server, wiped save): tell it again
            send(K.player(), "storyGoal", { act = "set", uid = uid, k = row.k, t = row.t, tn = row.tn })
        end
    end
    return n
end

-- the end of a story
function K.outcome(uid, row, g)
    local m = M()
    local name = tostring(row.tn or "them")
    row.outcome = tostring(g.outcome or "helped")
    row.endH = hours()
    K.metrics.outcomes = K.metrics.outcomes + 1
    local bond = tonumber(setting("questStoryBond")) or 25
    if row.outcome == "helped" then
        if row.k == "family" and g.fate == "dead" then
            feel(uid, "grief", 0.7, name .. " is dead")
            keyMem(uid, "loss", "You were there when they found out " .. name .. " is dead")
        elseif row.k == "family" then
            if fn(m, "pairBump") and row.t then pcall(m.pairBump, uid, row.t, bond, "found each other again") end
            feel(uid, "joy", 0.6, "saw " .. name .. " again")
            feel(uid, "gratitude", 0.4, "you took them to " .. name)
            keyMem(uid, "kindness", "You took them to see " .. name .. " again")
        elseif row.k == "amends" then
            if fn(m, "pairBump") and row.t then pcall(m.pairBump, uid, row.t, bond, "talked it out") end
            feel(uid, "relief", 0.5, "made it right with " .. name)
            keyMem(uid, "kindness", "You walked them to " .. name .. " to make it right")
        elseif row.k == "prodigal" then
            if fn(m, "pairBump") and row.t then pcall(m.pairBump, uid, row.t, bond, "came home") end
            feel(uid, "joy", 0.6, name .. " came home")
            feel(uid, "gratitude", 0.4, "you brought " .. name .. " home")
            keyMem(uid, "kindness", "You found " .. name .. " and brought them home")
        elseif row.k == "guilt" then
            feel(uid, "relief", 0.4, "said goodbye to " .. name)
            feel(uid, "gratitude", 0.3, "you walked with them")
            keyMem(uid, "kindness", "You walked with them to where " .. name .. " died. They said goodbye")
        elseif row.k == "revenge" then
            feel(uid, "relief", 0.3, name .. " is dead")
            feel(uid, "numbness", 0.2, "the revenge is done")
            keyMem(uid, "kindness", name .. " is dead. Their revenge is done")
        end
    elseif row.outcome == "clean" then
        K.metrics.cleaned = K.metrics.cleaned + 1
        K.store()["clean:" .. tostring(uid)] = true
        if fn(m, "habitOf") then pcall(function() local hb = m.habitOf(uid); if type(hb) == "table" then hb.drinker = false end end) end
        feel(uid, "pride", 0.6, "off the drink")
        keyMem(uid, "kindness", row.k == "second" and "They got clean on their second try. You trusted them again" or "They got clean. You held their bottles when they couldn't")
    elseif row.outcome == "gone" then
        K.metrics.gone = K.metrics.gone + 1
        if row.k == "amends" then
            feel(uid, "guilt", 0.5, "never made it right with " .. name)
            keyMem(uid, "loss", name .. " died before they could make it right")
        else
            feel(uid, "relief", 0.2, name .. " is dead")
            feel(uid, "anger", 0.2, "someone else got to " .. name)
        end
    elseif row.outcome == "relapsed" then
        feel(uid, "shame", 0.5, "drinking again")
    elseif row.outcome == "warned" then
        -- 0.8.8 stand in the way: you warned the one they wanted dead
        K.metrics.warned = K.metrics.warned + 1
        local player = type(K.player) == "function" and K.player() or nil
        local giver = firstName(rec(uid), "someone")
        if row.t ~= nil then
            feel(row.t, "fear", 0.3, giver .. " wants them dead")
            feel(row.t, "gratitude", 0.3, "you warned them about " .. giver)
            keyMem(row.t, "kindness", "You warned them that " .. giver .. " wants them dead")
            opinion(row.t, player, tonumber(setting("storyWarnThanks")) or 6, "You warned them that " .. giver .. " wants them dead.")
            if fn(m, "pairBump") then pcall(m.pairBump, row.t, uid, -10, "found out they want them dead") end
        end
        feel(uid, "anger", 0.3, name .. " knew they were coming")
        if g.leak then
            feel(uid, "anger", 0.4, "you warned " .. name)
            keyMem(uid, "betrayal", "You warned " .. name .. " they were coming for them")
            opinion(uid, player, -(tonumber(setting("storyWarnCost")) or 12), "You warned " .. name .. " they were coming.")
        end
    end
    log("story ended: " .. uid .. " " .. tostring(row.k) .. " -> " .. row.outcome .. (g.fate and (" (" .. tostring(g.fate) .. ")") or ""))
end

-- a drink in their hand while they try (from you, or a bottle of their own)
function K.relapse(player, uid, why)
    uid = tostring(uid)
    local row = K.rowOf(uid)
    local trying = row ~= nil and (row.k == "clean" or row.k == "second") and row.outcome == nil
    local wasClean = K.isClean(uid)
    if not trying and not wasClean then return false end
    K.metrics.relapses = K.metrics.relapses + 1
    if trying then row.dryH = nil end
    if wasClean then
        K.store()["clean:" .. uid] = nil
        if row ~= nil and row.k == "clean" and row.outcome == "clean" then row.outcome, row.endH, row.seen = "relapsed", hours(), nil end
        local m = M()
        if fn(m, "habitOf") then pcall(function() local hb = m.habitOf(uid); if type(hb) == "table" then hb.drinker = true end end) end
    end
    feel(uid, "shame", 0.4, "drinking again")
    keyMem(uid, "story", why)
    send(player, "storyGoal", { act = "relapse", uid = tostring(uid) })
    return true
end
function K.onGiven(player, listener, items)
    if type(listener) ~= "table" or type(listener.record) ~= "table" or type(items) ~= "table" then return false end
    local booze = false
    for _, info in ipairs(items) do
        if type(info) == "table" and (info.alcohol or info.kind == "alcohol") then booze = true end
    end
    if not booze then return false end
    local uid = tostring(listener.record.uid)
    local hit = K.relapse(player, uid, "You gave them a drink while they were trying to quit")
    -- 0.8.8: once they sober up they know who put it in their hand
    if hit then K.store()["tempt:" .. uid] = hours(); K.metrics.tempted = K.metrics.tempted + 1 end
    return hit
end

-- every game hour: dry long enough, their person died some other way, ask for news, pick new stories
function K.tick(player)
    if not on() or player == nil then return end
    local now = hours()
    local days = tonumber(setting("questCleanDays")) or 7
    local pull = {}
    for uid, row in pairs(K.store()) do
        if type(row) == "table" and row.outcome == nil then
            if #pull < 30 then pull[#pull + 1] = uid end
            if (row.k == "clean" or row.k == "second") and row.dryH ~= nil and now - tonumber(row.dryH) >= days * 24 then
                send(player, "storyGoal", { act = "clean", uid = uid })
            elseif (row.k == "revenge" or row.k == "amends") and row.t ~= nil and isDead(row.t) then
                row.deadSeen = row.deadSeen or now
                -- a while, so a kill on a live task counts as yours first
                if now - row.deadSeen >= 2 then send(player, "storyGoal", { act = "gone", uid = uid }) end
            end
        end
    end
    if #pull > 0 then send(player, "storyPull", { uids = pull }) end
    K.sobered(player, now)
    K.assign(player)
end

-- 0.8.8: 12 hours after you handed a drinker a drink while they tried to quit, they're sober and they hold it against you
function K.sobered(player, now)
    local store = K.store()
    local due = {}
    for key, h in pairs(store) do
        if type(key) == "string" and string.sub(key, 1, 6) == "tempt:" and now - (tonumber(h) or now) >= 12 then due[#due + 1] = key end
    end
    for _, key in ipairs(due) do
        store[key] = nil
        local uid = string.sub(key, 7)
        if not isDead(uid) then
            feel(uid, "anger", 0.3, "you handed them a drink when they were trying to stop")
            keyMem(uid, "betrayal", "You handed them a drink when they were trying to stop")
            opinion(uid, player, -(tonumber(setting("storyTemptCost")) or 8), "You handed them a drink when they were trying to stop.")
        end
    end
    return #due
end

-- 0.8.8 stand in the way: "watch your back" to someone a person you know wants dead. The server checks it's real.
K.WARN_NOBODY = { "Who'd want me dead? Nobody I know of.", "Watch my back from who?", "You know something I don't?" }
K.WARN_HEARD = { "...Thanks. I'll keep my eyes open.", "Figures. Thanks for telling me.", "Then I won't sleep easy. Thanks." }
function K.warn(player, toUid)
    if player == nil or toUid == nil or not on() or setting("storyWarn") == false then return false end
    toUid = tostring(toUid)
    local giver = nil
    for uid, row in pairs(K.store()) do
        if type(row) == "table" and row.k == "revenge" and row.outcome == nil and tostring(row.t) == toUid then giver = uid end
    end
    local pick = function(list) return list[(hash(toUid .. math.floor(hours())) % #list) + 1] end
    if giver == nil then sayLine(toUid, player, pick(K.WARN_NOBODY)); return false end
    send(player, "storyGoal", { act = "warn", uid = giver, to = toUid })
    sayLine(toUid, player, pick(K.WARN_HEARD))
    return true
end

-- 0.8.8 UI: someone you know of really wants this person dead (a revenge story open on them, the one who wants it alive
-- and known to you by name). Returns the giver's uid or nil. The talk window's "Watch your back" row shows only then.
function K.wantsDead(toUid, player)
    if toUid == nil or not on() or setting("storyWarn") == false then return nil end
    toUid = tostring(toUid)
    local m = M()
    for uid, row in pairs(K.store()) do
        if type(row) == "table" and row.k == "revenge" and row.outcome == nil and tostring(row.t) == toUid and uid ~= toUid and not isDead(uid) then
            local known = false
            if fn(m, "knowsName") then local ok, k = pcall(m.knowsName, uid, player); known = ok and k == true end
            if not known and fn(m, "isKnownPerson") then local ok, k = pcall(m.isKnownPerson, uid, rec(uid)); known = ok and k == true end
            if known then return uid end
        end
    end
    return nil
end

-- what the AI hears as their own goal (Psyche's lifeLine)
function K.line(uid)
    local row = K.active(uid)
    if row == nil then return nil end
    local name = tostring(row.tn or "someone")
    if row.k == "family" then return "see " .. name .. " again - family, and far from you now" end
    if row.k == "amends" then return "make it right with " .. name .. ", face to face, after it went bad between you" end
    if row.k == "revenge" then return "see " .. name .. " dead for what they did" end
    if row.k == "prodigal" then return "get " .. name .. " to come home - family, who walked out after a fight and went with other people" end
    if row.k == "guilt" then return "live with " .. name .. "'s death - you saw it happen and think it should have been you; you want to go where it happened" end
    if row.k == "second" and row.dryH == nil then return "get a second chance to quit drinking, after you slipped" end
    if row.k == "clean" or row.k == "second" then
        if row.dryH ~= nil then
            local d = math.floor((hours() - tonumber(row.dryH)) / 24)
            return "stay off the bottle (" .. (d < 1 and "not even a day" or (d .. " days")) .. " dry now; someone you trust is holding your bottles)"
        end
        return "stop drinking, before it gets you killed"
    end
    return nil
end

-- load time: defaults, save keys, rows, hooks
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            local have = {}
            for _, x in ipairs(m.fileKeys) do have[x] = true end
            for _, key in ipairs(K.KEYS) do if not have[key] then m.fileKeys[#m.fileKeys + 1] = key; have[key] = true end end
        end
        m.storyLine = function(uid) return K.line(uid) end
        if type(m.settingRows) == "table" then
            local rows = {
                { "questStory", "Stories: people carry a goal of their own (family, revenge, making it right, getting clean)" },
                { "questCleanDays", "Stories: days dry before a drinker counts as off the drink", { 3, 7, 14, 30 } },
                { "questCleanWant", "Stories: share of drinkers who want to stop (0-100)", { 20, 40, 60, 100 } },
                { "questStoryBond", "Stories: how much a tie mends when you walk them to family or to make it right", { 10, 25, 40 } },
                { "questStoryFar", "Stories: kin this far away counts as someone to go find (tiles)", { 100, 150, 300 } },
                { "questStoryGap", "Stories: days after one ends before they carry another", { 3, 7, 14 } },
                { "questStoryReach", "Stories: people this close get a story (tiles)", { 30, 60, 100 } },
                { "storyWarn", "Stories: you can warn someone that a person wants them dead (\"watch your back\")" },
                { "storyWarnReach", "Stories: how close you must be to warn them (tiles)", { 3, 6, 10 } },
                { "storyWarnLeak", "Stories: chance the one who wanted revenge finds out you warned them (0-100)", { 0, 30, 60, 100 } },
                { "storyWarnCost", "Stories: how much less they like you when they find out", { 6, 12, 25 } },
                { "storyWarnThanks", "Stories: how much more the warned person likes you", { 3, 6, 12 } },
                { "storyTemptCost", "Stories: how much less a drinker likes you, sober, after you handed them a drink", { 4, 8, 15 } },
            }
            local have = {}
            for _, r in ipairs(m.settingRows) do have[r[1]] = true end
            for _, r in ipairs(rows) do
                if not have[r[1]] then m.settingRows[#m.settingRows + 1] = r end
                if type(m.settingCatOf) == "table" then m.settingCatOf[r[1]] = "Groups, trade and the world" end
            end
        end
    end
    if type(ALifeCmd) == "table" and fn(ALifeCmd, "onClient") then ALifeCmd.onClient("storyGoals", K.onGoals) end
end
K.player = function()
    local p = nil
    pcall(function() p = ALifeSide.you() end) -- UI side only: the local player whose world we look at
    return p
end

function K.hook()
    local m = M()
    if type(m) ~= "table" then return false end
    K.hooked = K.hooked or {}
    -- any gift (our Give, door give, trade watcher) goes through M.onGift
    if not K.hooked.gift and fn(m, "onGift") then
        local orig = m.onGift
        m.onGift = function(player, listener, items, opts)
            if not K.offGift then
                local ok, err = pcall(K.onGiven, player, listener, items)
                if not ok then K.offGift = true; log("gift check failed, off for this session: " .. tostring(err)) end
            end
            return orig(player, listener, items, opts)
        end
        K.hooked.gift = true
    end
    -- a bottle of their own while they try = relapse
    if not K.hooked.habit and fn(m, "habitStarted") then
        local orig = m.habitStarted
        m.habitStarted = function(l, kind, now)
            if kind == "booze" and not K.offHabit then
                local ok, err = pcall(function()
                    local uid = l and l.record and tostring(l.record.uid) or nil
                    if uid ~= nil and (K.trying(uid) or K.isClean(uid)) then K.relapse(K.player(), uid, "They found a bottle and drank it") end
                end)
                if not ok then K.offHabit = true; log("habit check failed, off for this session: " .. tostring(err)) end
            end
            return orig(l, kind, now)
        end
        K.hooked.habit = true
    end
    -- the bottle pulls less while they try, not at all while dry or once clean
    if not K.hooked.weights and fn(m, "habitWeights") then
        local orig = m.habitWeights
        m.habitWeights = function(uid, l, c, ctx, w)
            local out = orig(uid, l, c, ctx, w)
            if type(w) == "table" and w.booze ~= nil then
                local row = K.rowOf(uid)
                if row ~= nil and (row.k == "clean" or row.k == "second") then
                    if row.outcome == nil and row.dryH ~= nil then w.booze = nil
                    elseif row.outcome == nil then w.booze = w.booze * 0.5 end
                end
                if K.isClean(uid) then w.booze = nil end
            end
            return out
        end
        K.hooked.weights = true
    end
    -- clean stays clean (habitOf rebuilds for people not in the book)
    if not K.hooked.habitOf and fn(m, "habitOf") then
        local orig = m.habitOf
        m.habitOf = function(uid)
            local hb = orig(uid)
            if type(hb) == "table" and hb.drinker and K.isClean(uid) then hb.drinker = false end
            return hb
        end
        K.hooked.habitOf = true
    end
    return K.hooked.gift == true
end
pcall(K.hook)

if type(Events) == "table" then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            pcall(K.hook)
            local n = 0
            for _ in pairs(K.hooked or {}) do n = n + 1 end
            log("ready v" .. K.VERSION .. ": a story for everyone (" .. n .. "/4 hooks, stories " .. (on() and "on" or "off")
                .. ", clean after " .. tostring(setting("questCleanDays")) .. " days dry)")
        end)
    end
    if Events.EveryHours ~= nil then
        Events.EveryHours.Add(function()
            -- pre-1.0 MP (P5): runs where the world is, once per online player (SP: you); sends to the server modules
            -- are direct calls there, their answers go to that player's machine
            local function one(p)
                local ok, err = pcall(K.tick, p)
                if not ok and not K.tickErr then K.tickErr = true; log("tick error (once): " .. tostring(err)) end
            end
            if ALifeSide.mpServer() then ALifeSide.each(one) else one(K.player()) end
        end)
    end
end
return K
