-- A-Life Talk v3: event memory (things NPCs saw) and deaths (witness reactions).
--
-- Deaths: Project A-Life publishes its own Lua event "ProjectALife_NpcDied"(body, uid, killer) from
--   Lifecycle fanOutAttributedDeath -> Interop.died (killer from KillAttribution.resolve). We only listen to it.
--   A-Life itself already applies NpcOpinion.noteKill (-45 "killed_mate" to the victim's group + word spreading),
--   HostileAct.noteKill, Revenge, reputation etc. when the player is the killer, so we never repeat that. We add:
--   an in-the-moment LLM line from the closest witness, the death in every witness's memory (with the killer),
--   and a human-scaled NpcOpinion.adjust only for witnesses OUTSIDE the victim's group who saw you do it
--   (friends -12, same side -8, strangers -5); if that drops a witness to "Resents you" or lower while they
--   stand near you, A-Life's own Talk.escalate decides what happens next (careful / hostile / leave).
-- Places: no A-Life "observation" API fits (Perception is threat/target focused), so a throttled scan
--   (every scanEverySec real seconds, only around the player, only if A-Life NPCs are within hearing range)
--   looks for fires, burnt/smashed cars, piles of bodies and big hordes. Each find is deduped per ~10-tile cell
--   and stored (what / where / when / coords) in the memory of the NPCs who could see it.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Events") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Events"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Events") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function nowMs() return M.nowMs() end
local function log(msg) M.log(msg) end

M.ev = {
    scanEverySec = 15,
    scanRadius = 14,      -- tiles around the player
    scanStep = 2,         -- check every 2nd square (fires spread, bodies pile: good enough, 1/4 the cost)
    seeTiles = 20,        -- NPC must be this close to the thing to remember it
    hordeSize = 15,
    corpsePile = 5,
    dedupeMs = 30 * 60 * 1000,
    witnessTiles = 25,
    maxWitnesses = 4,
}
M.evSeen = {}
M.evNextScan = 0
M.metrics.events, M.metrics.deaths = 0, 0

local function dist2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function pos(o)
    if o == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end)
    return x, y, z
end

----------------------------------------------------------------------------------------------------------------
-- Where is this? ("Muldraugh, kitchen of a house" + coords)
----------------------------------------------------------------------------------------------------------------
function M.placeName(x, y, z)
    local pa = PA()
    local parts = {}
    pcall(function()
        local sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
        local room = sq and sq:getRoom() or nil
        if room ~= nil then
            local name = tostring(room:getName() or "")
            if name ~= "" then parts[#parts + 1] = (string.gsub(name, "_", " ")) end
        end
    end)
    if fn(pa and pa.Speech, "nearestTown") then
        local ok, town = pcall(pa.Speech.nearestTown, x, y)
        if ok and type(town) == "string" and town ~= "" then parts[#parts + 1] = "near " .. town end
    end
    return table.concat(parts, ", ")
end

----------------------------------------------------------------------------------------------------------------
-- Scan (throttled; only around the player; only when A-Life NPCs are close enough to see)
----------------------------------------------------------------------------------------------------------------
local function squareFinds(sq, out)
    local fire = false
    pcall(function() if sq:haveFire() then fire = true end end)
    if not fire then
        pcall(function()
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                if instanceof(objs:get(i), "IsoFire") then fire = true; return end
            end
        end)
    end
    if fire then out.fire = (out.fire or 0) + 1; out.fireAt = out.fireAt or sq end
    pcall(function()
        local bodies = sq:getDeadBodys()
        if bodies ~= nil and bodies:size() > 0 then
            out.bodies = (out.bodies or 0) + bodies:size()
            out.bodyAt = out.bodyAt or sq
        end
    end)
    pcall(function()
        local v = sq:getVehicleContainer()
        if v ~= nil then
            local name = string.lower(tostring(v:getScriptName() or ""))
            if string.find(name, "burnt", 1, true) then out.burntCar = sq
            elseif string.find(name, "smashed", 1, true) then out.wreck = sq end
        end
    end)
end

function M.scanEvents()
    local s = M.settings
    if not s.enabled or not M.worldHere() then return end
    local now = nowMs()
    if now < M.evNextScan then return end
    M.evNextScan = now + M.ev.scanEverySec * 1000
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then M.eachPlayer(function() M.scanEventsFor(now) end); return end -- MP: around every player
    return M.scanEventsFor(now)
end
function M.scanEventsFor(now)
    local s = M.settings
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "listeners") then return end
    local player = ALifeSide.you()
    if player == nil then return end
    local radius = (type(pa.Talk.settings) == "table" and tonumber(pa.Talk.settings.listenRadius)) or 12
    local npcs = pa.Talk.listeners(player, radius)
    if #npcs == 0 then return end
    local px, py, pz = pos(player)
    local out = {}
    local cell = getCell()
    local r, step = M.ev.scanRadius, M.ev.scanStep
    for dx = -r, r, step do
        for dy = -r, r, step do
            local sq = nil
            pcall(function() sq = cell:getGridSquare(math.floor(px + dx), math.floor(py + dy), math.floor(pz)) end)
            if sq ~= nil then squareFinds(sq, out) end
        end
    end
    local zombies, zx, zy = 0, 0, 0
    pcall(function()
        local list = cell:getZombieList()
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local x, y = z:getX(), z:getY()
            if dist2(x, y, px, py) <= 30 * 30 and not z:isDead() and M.uidOf(z) == nil then
                zombies, zx, zy = zombies + 1, zx + x, zy + y
            end
        end
    end)
    local finds = {}
    local function sqPos(sq) local x, y, z = nil, nil, nil; pcall(function() x, y, z = sq:getX(), sq:getY(), sq:getZ() end); return x, y, z end
    if out.fire then
        local x, y, z = sqPos(out.fireAt)
        local inside = false
        pcall(function() inside = out.fireAt:getRoom() ~= nil end)
        finds[#finds + 1] = { kind = "fire", what = inside and "a building on fire" or (out.fire >= 4 and "a big fire" or "a fire"), x = x, y = y, z = z }
    end
    if (out.bodies or 0) >= M.ev.corpsePile then
        local x, y, z = sqPos(out.bodyAt)
        finds[#finds + 1] = { kind = "bodies", what = "a pile of bodies (" .. tostring(out.bodies) .. ")", x = x, y = y, z = z }
    end
    if out.burntCar then local x, y, z = sqPos(out.burntCar); finds[#finds + 1] = { kind = "burntcar", what = "a burnt-out car", x = x, y = y, z = z } end
    if out.wreck then local x, y, z = sqPos(out.wreck); finds[#finds + 1] = { kind = "wreck", what = "a wrecked car", x = x, y = y, z = z } end
    if zombies >= M.ev.hordeSize then
        finds[#finds + 1] = { kind = "horde", what = "a horde of about " .. tostring(math.floor(zombies / 5 + 0.5) * 5) .. " zombies",
            x = zx / zombies, y = zy / zombies, z = pz }
    end
    for _, f in ipairs(finds) do
        if f.x ~= nil then
            local key = f.kind .. ":" .. math.floor(f.x / 10) .. ":" .. math.floor(f.y / 10)
            if now - (M.evSeen[key] or -1e12) >= M.ev.dedupeMs then
                local who = {}
                for _, l in ipairs(npcs) do
                    local nx, ny = pos(l.shell)
                    if nx ~= nil and dist2(nx, ny, f.x, f.y) <= M.ev.seeTiles ^ 2 then who[#who + 1] = l end
                end
                if #who > 0 then
                    M.evSeen[key] = now
                    f.where = M.placeName(f.x, f.y, f.z)
                    M.recordEvent(player, who, f)
                end
            end
        end
    end
end

-- memory only (no LLM): one "event" request lists every NPC who saw it
function M.recordEvent(player, who, f)
    M.metrics.events = M.metrics.events + 1
    log("event: " .. f.what .. (f.where ~= "" and (" at " .. f.where) or "") .. " seen by " .. #who .. " NPC(s)")
    local uids = {}
    for _, l in ipairs(who) do uids[#uids + 1] = tostring(l.record.uid) end
    if M.keyMem and f.kind ~= "death" then
        for _, u in ipairs(uids) do pcall(M.keyMem, u, "event", "Saw " .. f.what .. ((f.where or "") ~= "" and (" at " .. f.where) or "")) end
    end
    M.submit({ mode = "event", uid = uids[1], player = player, listener = who[1], event = {
        kind = f.kind, what = f.what, where = f.where, x = math.floor(f.x), y = math.floor(f.y), witnesses = uids,
        killer = f.killer, killerUid = f.killerUid, victim = f.victim, victimUid = f.victimUid, tie = f.tie },
        startMs = nowMs(), depth = 0 })
end

function M.eventRequest(job, now)
    local listener = M.refresh(job) or job.listener
    if listener == nil then return nil end
    local req = M.buildRequest(job.player, listener, "", nil, "neutral", now)
    req.mode = job.mode
    req.event = job.event
    req.acts, req.actHints = {}, {}
    if job.mode == "death" then
        req.line = nil
        req.needs = nil
    end
    return req
end

----------------------------------------------------------------------------------------------------------------
-- Deaths
----------------------------------------------------------------------------------------------------------------
function M.killerOf(killer, player, body)
    if killer == nil then
        -- 0.5.1: A-Life's kill attribution often has no killer object for zombie kills; ask A-Life itself
        local byZ = false
        if body ~= nil then pcall(function() local L = PA().Lifecycle; byZ = L.killedByZombie(body) == true end) end
        if byZ then return "zombies", "zombie" end
        return "zombies or something unseen", nil
    end
    if killer == player then return "player", "player" end
    local uid = M.uidOf(killer)
    if uid ~= nil then
        local pa = PA()
        local rec = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid) or nil
        -- v0.4.2: only real A-Life actors get a killer uid (grudges, pair stances). NPCs of other mods (Bandits,
        -- NPC Crew / DTGCrew) are never made targets of our NPC-vs-NPC layer.
        if rec == nil then return "another survivor", nil end
        local name = fn(pa.Names, "of") and pa.Names.of(rec) or "another survivor"
        return name, uid
    end
    if instanceof(killer, "IsoZombie") then
        local bandit = false
        pcall(function() local md = killer:getModData(); bandit = type(md) == "table" and (md.brain ~= nil or md.Bandit ~= nil) end)
        if bandit then return "a bandit", nil end
        return "zombies", "zombie"
    end
    if instanceof(killer, "IsoPlayer") then return "player", "player" end
    return "someone", nil
end

function M.onNpcDied(body, uid, killer)
    if not M.settings.enabled or not M.worldHere() then return end
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "read") then return end
    local victim = pa.ActorRegistry.read(uid)
    if victim == nil then return end
    local player = ALifeSide.you()
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- MP: the killer if a player, else the player nearest the body
        player = ALifeSide.isOnlinePlayer(killer) and killer or ALifeSide.nearestTo(body)
        if player == nil then return end
        local okW, res = ALifeSide.with(player, M.onNpcDiedFor, body, uid, killer, victim, player)
        if not okW then error(res) end
        return res
    end
    return M.onNpcDiedFor(body, uid, killer, victim, player)
end
function M.onNpcDiedFor(body, uid, killer, victim, player)
    local pa = PA()
    local now = nowMs()
    local vname = fn(pa.Names, "of") and pa.Names.of(victim) or "someone"
    local killerName, killerUid = M.killerOf(killer, player, body)
    local bx, by, bz = pos(body)
    if bx == nil then return end
    -- 0.5.1: killed while bitten / infected (by you, a companion, anyone): a mercy kill - grief and acceptance, not murder
    local mercy = killerUid ~= "zombie" and M.isInfectedVictim and M.settings.turnedReact ~= false and M.isInfectedVictim(victim, body)
    if mercy and M.onMercyKill then
        local k = killerUid == "player" and { kind = "player", name = "you" }
            or (killerUid ~= nil and { kind = "npc", uid = killerUid, name = killerName, shell = killer }) or { kind = "other", name = "someone" }
        pcall(M.onMercyKill, uid, body, k, "bitten")
        if M.noteLoss then pcall(M.noteLoss, victim, "a mercy kill after a bite", bx, by, bz, true) end
        log("death: " .. vname .. " was bitten - mercy kill by " .. tostring(killerName))
        return
    end
    local vgroup = type(victim.memory) == "table" and victim.memory.groupId or nil
    -- witnesses: living A-Life NPCs close to the body (A-Life's own talkable/registry view)
    local witnesses = {}
    -- v0.4.0: registry + shell binding + cell-scan fallback, 25 tiles, one floor up/down (0.3.2 often found nobody)
    for _, n in ipairs(M.nearbyNpcs(bx, by, bz, M.ev.witnessTiles, victim.uid)) do
        if #witnesses >= 12 then break end
        local rec, sh = n.record, n.shell
        local g = type(rec.memory) == "table" and rec.memory.groupId or nil
        local tie = "stranger"
        if vgroup ~= nil and g == vgroup then tie = "group"
        elseif fn(pa.Relations, "status") then
            local okS, st = pcall(pa.Relations.status, rec, victim)
            if okS and st == "friendly" then tie = "friend"
            elseif okS and st == "hostile" then tie = "enemy" end
            if tie == "stranger" and fn(pa.Relations, "sameSide") then
                local okSS, same = pcall(pa.Relations.sameSide, rec, victim)
                if okSS and same == true then tie = "side" end
            end
        end
        witnesses[#witnesses + 1] = { record = rec, shell = sh, tie = tie, d2 = n.d2 }
    end
    M.metrics.deaths = M.metrics.deaths + 1
    log(string.format("death: %s killed by %s, %d witness(es)", vname, killerName, #witnesses))
    if M.noteLoss then pcall(M.noteLoss, victim, killerName, bx, by, bz, #witnesses > 0) end -- 0.5.1: mentioned later (off-screen too)
    if #witnesses == 0 then return end
    local rank = { group = 0, friend = 1, side = 2, stranger = 3, enemy = 4 }
    table.sort(witnesses, function(a, b)
        if rank[a.tie] ~= rank[b.tie] then return rank[a.tie] < rank[b.tie] end
        return a.d2 < b.d2
    end)
    while #witnesses > M.ev.maxWitnesses do table.remove(witnesses) end
    -- opinion: only witnesses outside the victim's group (A-Life's noteKill already covers the group)
    if killerUid == "player" and fn(pa.NpcOpinion, "adjust") then
        for _, w in ipairs(witnesses) do
            local delta = ({ friend = -12, side = -8, stranger = -5, enemy = 0 })[w.tie]
            if delta ~= nil and delta ~= 0 then
                pa.NpcOpinion.adjust(w.record, player, delta, "They saw you kill " .. vname .. ".")
                local v = fn(pa.NpcOpinion, "valueOf") and pa.NpcOpinion.valueOf(w.record, player) or 0
                local px, py = pos(player)
                local wx, wy = pos(w.shell)
                if v <= -41 and px ~= nil and wx ~= nil and dist2(px, py, wx, wy) <= 12 * 12 and fn(pa.Talk, "stance") then
                    pcall(M.escalate, w.record, w.shell, player, pa.Talk.stance(w.record, player))
                end
            end
        end
    end
    -- 0.4.0: a close tie watched you do it -> grudge (nemesis) and, unless they're the running kind, straight to
    -- attacking (patch: A-Life's own hostile state, no warnings)
    if killerUid == "player" then
        local P = M.patch and M.patch()
        for _, w in ipairs(witnesses) do
            pcall(function()
                local c = ({ group = 0.6, friend = 0.5, side = 0.2, stranger = 0, enemy = 0 })[w.tie] or 0
                if M.closeness then
                    local okC, cw = pcall(M.closeness, w.record.uid, victim.uid)
                    if okC and tonumber(cw) then c = math.max(c, cw) end
                end
                if M.grudgeFromKill then M.grudgeFromKill(w.record.uid, vname, c) end
                local mods = M.personaMods and M.personaMods(w.record.uid) or nil
                local timid = mods and (tonumber(mods.fear) or 0) >= 0.7
                if c >= 0.5 and not timid and M.settings.attackPlayer ~= false and P and fn(P, "attackNow") then
                    local okA, turned = pcall(P.attackNow, w.record.uid, player, "saw you kill " .. vname)
                    if okA and turned then log("attack: " .. tostring(w.record.uid) .. " saw you kill " .. vname .. " and attacks") end
                end
            end)
        end
    end
    local uids = {}
    for _, w in ipairs(witnesses) do uids[#uids + 1] = tostring(w.record.uid) end
    local where = M.placeName(bx, by, bz)
    local ev = { kind = "death", what = vname .. " was killed by " .. (killerUid == "player" and "the player" or killerName),
        where = where, x = math.floor(bx), y = math.floor(by), witnesses = uids, killer = killerName,
        killerUid = killerUid, victim = vname, victimUid = tostring(victim.uid) }
    if M.keyMem then
        for _, w in ipairs(witnesses) do
            local tieWord = ({ group = "their friend ", friend = "their friend ", side = "", stranger = "", enemy = "" })[w.tie] or ""
            pcall(M.keyMem, w.record.uid, "death", "Saw " .. tieWord .. vname .. " killed by "
                .. (killerUid == "player" and "YOU" or killerName) .. (where ~= "" and (" (" .. where .. ")") or ""))
        end
    end
    -- 1) everyone remembers it (memory only)
    M.submit({ mode = "event", uid = uids[1], player = player, listener = witnesses[1], event = ev, startMs = now, depth = 0 })
    -- 2) the closest / most attached witness reacts out loud right now (ahead of chatter, after your own line)
    local w = witnesses[1]
    -- v3.2: our pair layer says how close they were (sibling, partner, best friend ...); close comrades react
    -- even mid-fight (rage / panic bark)
    local bond, close = nil, 0
    if M.closeness then
        local okC, cw, ct = pcall(M.closeness, w.record.uid, victim.uid)
        if okC then close, bond = cw or 0, M.typeWord and M.typeWord(ct, victim) or ct end
    end
    local fighting = fn(pa.Talk, "busy") and pa.Talk.busy(w.record, now) or false
    if fighting and w.tie ~= "group" and close < 0.4 then
        -- 0.5.1: zombie kills happen mid-fight; 0.5.0 dropped the reaction here (why nobody ever reacted to zombie
        -- deaths). Now: an instant canned bark (no AI wait) and a proper grief line once the fight is over.
        if M.deathBark then pcall(M.deathBark, w, vname, killerUid) end
        if M.deferDeathReaction then for _, ww in ipairs(witnesses) do pcall(M.deferDeathReaction, ww, victim, vname, killerName, killerUid, where) end end
        return
    end
    if killerUid == "zombie" and M.deferDeathReaction then -- the others process it after the fight / when it's quiet
        for i, ww in ipairs(witnesses) do if i > 1 then pcall(M.deferDeathReaction, ww, victim, vname, killerName, killerUid, where) end end
    end
    local job = { mode = "death", uid = tostring(w.record.uid), player = player, listener = { record = w.record, shell = w.shell },
        event = { kind = "death", what = ev.what, victim = vname, killer = killerName, killerUid = killerUid,
            tie = w.tie, where = where, witnesses = { tostring(w.record.uid) }, x = ev.x, y = ev.y, react = true,
            bond = bond, close = math.floor(close * 100), fight = fighting },
        startMs = now, depth = 0 }
    local cur = M.pending
    if cur ~= nil and (cur.mode == "chime" or cur.mode == "banter" or cur.mode == "ambient") then M.pending = nil end
    M.chatGen = M.chatGen + 1 -- queued banter lines are stale after a death
    local kept = {}
    for _, q in ipairs(M.queue) do if q.mode == "reply" or M.eventModes[q.mode] then kept[#kept + 1] = q end end
    M.queue = kept
    local at = 1
    while M.queue[at] ~= nil and M.queue[at].mode == "reply" do at = at + 1 end
    table.insert(M.queue, at, job)
    M.pump(now)
end

M.deathLines = {
    group = "No... no, no! Not like this!",
    friend = "God... they got him. They got him!",
    side = "Damn it. Another one gone.",
    stranger = "Jesus...",
    enemy = "Huh. One less to worry about.",
}

function M.finishDeath(p, r)
    local me = M.refresh(p)
    if me == nil then return end
    local text = r.text
    if type(text) ~= "string" or text == "" then text = M.deathLines[p.event.tie] or "Jesus..." end
    local face = p.event.killerUid == "player" and p.player or nil
    M.say(me.shell, face, text, { record = me.record, combat = true }) -- v0.3.3: shown even mid-fight
end

function M.deathFallback(p)
    M.finishDeath(p, { text = "" })
end

-- 0.5.1 zombie deaths -----------------------------------------------------------------------------------------
M.deathPanic = {
    group = { "They got {n}! They got {n}!", "{n}! NO!", "{n}'s down - fall back!" },
    friend = { "{n}! Oh god, {n}!", "They're eating {n}!", "Get them off {n}!" },
    side = { "We lost one! Move!", "{n}'s gone - watch your flank!" },
    stranger = { "Jesus - they tore him apart!", "Don't look, just move!" },
    enemy = { "Better them than me.", "One less." },
}
local function next_key(t) if type(t) ~= "table" then return false end; for _ in pairs(t) do return true end; return false end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
M.deathLater = {} -- witness uid -> { n, tie, by, where, atMs }
function M.deathBark(w, vname, killerUid)
    local pool = M.deathPanic[w.tie] or M.deathPanic.stranger
    local first = string.match(vname or "", "^(%S+)") or "him"
    local txt = string.gsub(pool[(hash(tostring(w.record.uid) .. vname) % #pool) + 1], "{n}", first)
    if M.say then M.say(w.shell, nil, txt, { record = w.record, combat = true }) end
    if M.voiceOnly and getPlayer then pcall(M.voiceOnly, { record = w.record, shell = w.shell }, ALifeSide.you(), txt) end
    M.lastDeathBark = { uid = tostring(w.record.uid), text = txt }
    return txt
end
function M.deferDeathReaction(w, victim, vname, killerName, killerUid, where)
    if w.tie == "enemy" then return end
    M.deathLater[tostring(w.record.uid)] = { n = vname, tie = w.tie, by = killerName, where = where, atMs = nowMs(), vuid = tostring(victim.uid) }
end
function M.deathLaterTick(now)
    if not next_key(M.deathLater) then return end
    local pa = PA()
    local player = ALifeSide.you()
    for wuid, e in pairs(M.deathLater) do
        if now - e.atMs > 600000 then M.deathLater[wuid] = nil
        else
            local r = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(wuid) or nil
            local sh = r and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(wuid) or nil
            if type(ALifeSide) == "table" and ALifeSide.mpServer() then player = sh and ALifeSide.nearestTo(sh) or nil end -- MP: the player near them
            local busy = r == nil or sh == nil or (fn(pa.Talk, "busy") and pa.Talk.busy(r, now))
            if not busy and now - e.atMs >= 4000 then
                M.deathLater[wuid] = nil
                local first = string.match(e.n or "", "^(%S+)") or "him"
                local tieWord = ({ group = "one of yours", friend = "your friend", side = "on your side", stranger = "a stranger" })[e.tie] or "someone"
                local fb = ({ group = "We lost " .. first .. ". Just like that.", friend = first .. "... I watched them take " .. first .. ".",
                    side = "Poor " .. first .. ". Nobody deserves that.", stranger = "I keep seeing it. What they did to him." })[e.tie] or "God..."
                local l = { record = r, shell = sh }
                if not (M.react and player and M.react("grief", l, player, { what = "The fighting's over. A few minutes ago " .. e.n .. " (" .. tieWord .. ") was killed by "
                        .. tostring(e.by) .. " right in front of you. Now it sinks in", style = "grief, shock, quiet or shaking", maxWords = 16, fallback = fb },
                        { key = "deathlater:" .. wuid, keyCooldownMs = 120000, modeCooldownMs = 4000, urgent = true })) and M.say then
                    M.say(sh, nil, fb, { record = r })
                end
                if M.feel then M.feel(wuid, "grief", e.tie == "group" and 0.5 or 0.25, e.n .. " killed") end
                break -- one per tick
            end
        end
    end
end
-- losses: every death is remembered (seen or not) so it can come up later ("heard the dead got Mike near Riverside")
function M.noteLoss(victim, by, x, y, z, seen)
    local list = M.bucket("losses")
    local pa = PA()
    list[#list + 1] = { n = fn(pa.Names, "of") and pa.Names.of(victim) or "someone", uid = tostring(victim.uid), f = victim.factionId,
        g = type(victim.memory) == "table" and victim.memory.groupId or nil, by = tostring(by or "something"), seen = seen == true,
        where = M.townAt and x and M.townAt(x, y) or nil, x = x and math.floor(x), y = y and math.floor(y), h = getGameTime and getGameTime():getWorldAgeHours() or 0 }
    while #list > 30 do table.remove(list, 1) end
    if not seen and (M.newsNote or ALifeSide.mpServer()) and (by == "zombies" or by == "zombies or something unseen") then
        pcall(M.outNews, "death", list[#list].n .. " was killed by the dead" .. (list[#list].where and (" near " .. list[#list].where) or ""), x, y)
    end
end
-- losses this NPC would plausibly know of: own faction / group, or nearby (word travels), within 3 days
function M.lossesKnownBy(uid)
    local pa = PA()
    local r = pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil
    if r == nil then return {} end
    local out = {}
    local h = getGameTime and getGameTime():getWorldAgeHours() or 0
    local g = type(r.memory) == "table" and r.memory.groupId or nil
    local pos0 = r.worldPosition or {}
    local list = M.bucket("losses")
    for i = #list, 1, -1 do
        local e = list[i]
        if e.uid ~= tostring(uid) and h - (e.h or 0) < 72 then
            local near = e.x and pos0.x and (e.x - pos0.x) ^ 2 + (e.y - pos0.y) ^ 2 <= 300 * 300
            if (g ~= nil and e.g == g) or (e.f ~= nil and e.f == r.factionId) or near then out[#out + 1] = e end
        end
        if #out >= 3 then break end
    end
    return out
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local lo = M.lossesKnownBy(tostring(listener.record.uid))
    if #lo > 0 then
        req.losses = {}
        for _, e in ipairs(lo) do req.losses[#req.losses + 1] = e.n .. " - " .. e.by .. (e.where and (" near " .. e.where) or "") .. (e.seen and "" or " (you only heard about it)") end
    end
end)

function M.installEvents()
    if M.deathHooked then return end
    if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Events", function(body, uid, killer)
            local ok, err = pcall(M.onNpcDied, body, uid, killer)
            if not ok then log("death hook error: " .. tostring(err)) end
        end)
        M.deathHooked = true
        log("listening to ProjectALife_NpcDied (A-Life's own death event)")
        if Events.OnTick then
            local last = -1e12
            ALifeHealth.tickAdd("ALifeLLMTalk_Events", function()
                local now = nowMs()
                if now - last < 2000 then return end
                last = now
                local ok, e = pcall(M.deathLaterTick, now)
                if not ok then log("death later error: " .. tostring(e)) end
            end)
        end
    end
end

M.eventModes.event = { request = M.eventRequest }
M.eventModes.death = { request = M.eventRequest, finish = M.finishDeath, fallback = M.deathFallback }

return M
