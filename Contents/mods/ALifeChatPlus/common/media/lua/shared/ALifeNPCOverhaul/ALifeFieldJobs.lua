-- A-Life NPC Overhaul 0.8.9: THE REST OF THE COMMANDS (server side). Jobs that take a while, done by your A-Life
-- companions with A-Life's own orders (ProjectALife.Companions.order: go_to / watch_there / hold_there / follow) and
-- A-Life's own item move (CompanionInventoryServer.move / capacity), re-aimed every game minute:
--   take point     walk ahead of you along the way you're going; stop and call it when they see trouble
--   scout ahead    go out, look, come back and tell you roughly what's out there (real counts, rough words)
--   keep an eye    watch one person, follow them with their eyes; tell you if they walk off or turn on you
--   search body    go to the body, go through its pockets and bag (not what it wears), take what they can carry
--   lure them off  run off to the side making noise (real addSound), lose them, come back
--   feed them      walk over and hand someone their own food (keeps their last one); the other side is grateful
--   carry message  walk to a person you name and tell them; far = real walking time on paper; back with how it went
-- Only for your own people (L.isMine); they can say no (L.chance; risky asks are harder). A new order replaces a job.
-- Answers go back as ALifeCmd "cmdDone" { cmd, uid, ok, why, ... }. MP-shaped: the client sends, this decides.
-- Every number is a setting (ALifeCommands.setting -> mod settings, these are only the defaults).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeFieldJobs") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeCommands"

ALifeFieldJobs = ALifeFieldJobs or {}
local F = ALifeFieldJobs
local L = ALifeCommands
local TAG = "[ALifeFieldJobs]"
F.VERSION = ALifeSide.MOD_VERSION
F.off = F.off or {}
F.jobs = F.jobs or {}
F.metrics = F.metrics or { started = 0, done = 0, failed = 0, noise = 0, looted = 0, fed = 0, delivered = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(k) return tonumber(L.setting(k)) or tonumber(F.DEFAULTS[k]) or 0 end
local function minutes() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return math.floor((tonumber(h) or 0) * 60 + 0.5) end -- whole game minutes
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end

F.DEFAULTS = {
    pointTiles = 6,        -- take point: how far ahead of you they walk
    pointMinutes = 60,     -- take point: game minutes before they drop back
    pointStopTiles = 10,   -- take point: trouble this close to them and they stop and call it
    scoutTiles = 25,       -- scout: how far out they go
    scoutLookMin = 3,      -- scout: game minutes they look around out there
    scoutSee = 20,         -- scout: how far they can see from there (tiles)
    scoutGiveUpMin = 30,   -- scout: game minutes before they give up getting there
    eyeHours = 2,          -- keep an eye: game hours they keep watching
    eyeReach = 30,         -- keep an eye: further than this and they've lost them
    searchReach = 15,      -- search body: a body this close to you
    searchMinutes = 2,     -- search body: game minutes going through it
    searchMax = 8,         -- search body: most things they take
    searchGiveUpMin = 20,  -- search body: game minutes before they give up getting there
    lureTiles = 25,        -- lure: how far off to the side they run
    lureNoise = 30,        -- lure: how far their noise carries (tiles)
    lureMinutes = 6,       -- lure: game minutes they make noise
    lureLoseMin = 15,      -- lure: game minutes before they lose them and come back
    cmdRiskTrust = 25,     -- risky asks (lure, scout, take point): how much harder to agree to (0-100)
    feedKeep = 1,          -- feed them: food they keep for themselves
    feedThanks = 3,        -- feed them: how much better the other side thinks of you
    feedGiveUpMin = 20,    -- feed them: game minutes before they give up getting there
    msgReach = 300,        -- carry a message: how far away the person may be (tiles)
    msgTilesPerH = 150,    -- carry a message: walking speed on paper (tiles per game hour)
    msgGiveUpH = 24,       -- carry a message: game hours before they give up
}
for k, v in pairs(F.DEFAULTS) do if L.DEFAULTS[k] == nil then L.DEFAULTS[k] = v end end

----------------------------------------------------------------------------------------------------------------
-- the commands (rows in ALifeCommands.CMDS, so the parser, the Commands tab and the AI list see them)
----------------------------------------------------------------------------------------------------------------
F.GROUP = "Out ahead"
F.CMDS = {
    { id = "take_point", group = "Out ahead", job = "point", risky = true, label = "take point",
      words = { "take point", "take the point", "you take point", "lead the way", "you go first", "walk ahead of me", "go in front", "you're on point", "youre on point" },
      say = { "Take point.", "Lead the way." }, what = "They walk a few steps ahead of you the way you're going, and stop and call it when they see trouble. About an hour." },
    { id = "scout", group = "Out ahead", job = "scout", point = "far_ahead", risky = true, label = "scout ahead",
      words = { "scout ahead", "scout it out", "scout that", "go take a look", "go have a look", "check it out up ahead", "check up ahead", "recon", "go see what's out there", "go see whats out there" },
      say = { "Scout ahead.", "Go take a look up there." }, what = "They go out the way you're looking, look around, come back and tell you roughly what's there." },
    { id = "keep_eye", group = "Out ahead", job = "eye", target = true, label = "keep an eye on them",
      words = { "keep an eye on him", "keep an eye on her", "keep an eye on them", "keep an eye on that", "watch him", "watch her", "watch that guy",
          "don't let him out of your sight", "dont let him out of your sight", "don't let her out of your sight", "keep watching him", "keep watching her" },
      say = { "Keep an eye on him.", "Don't let her out of your sight." }, what = "They watch the person you're talking to (or the nearest stranger) and tell you if they walk off or turn on you." },
    { id = "search_body", group = "Out ahead", job = "search", point = "body", label = "search that body",
      words = { "search that body", "search the body", "search him", "search her", "check the body", "check his pockets", "check her pockets",
          "go through his pockets", "go through her pockets", "loot the body", "loot him", "loot her", "see what he had", "see what she had" },
      say = { "Search that body.", "Check his pockets." }, what = "They go to the nearest body and take what's in its pockets and bag (not what it's wearing), as much as they can carry." },
    { id = "lure", group = "Out ahead", job = "lure", point = "lure", risky = true, label = "lure them off",
      words = { "lure them off", "lure them away", "draw them off", "draw them away", "pull them away", "lead them away", "make some noise and run", "get their attention" },
      say = { "Lure them off.", "Draw them away from us." }, what = "They run off to the side making noise so the dead follow them, lose them, and come back. Dangerous." },
    { id = "message", group = "Out ahead", job = "message", target = true, noButton = true, label = "carry a message",
      words = { "go tell", "tell him that", "tell her that", "carry a message to", "take a message to", "give a message to", "let him know", "let her know", "pass word to", "get word to" },
      say = { "Go tell Sam we need ammo.", "Take a message to Rosa." }, what = "Name someone you know. They walk there, tell them, and come back with how it went. Far away takes real walking time." },
    { id = "feed_them", group = "Help me", job = "feed", target = true, label = "give them some food",
      words = { "give him some food", "give her some food", "give them some food", "feed him", "feed her", "feed them", "share your food with",
          "give him something to eat", "give her something to eat", "give them something to eat" },
      say = { "Give him some food.", "Share your food with her." }, what = "One of yours hands their own food to the person you're talking to (they keep their last one)." },
}

-- add them to ALifeCommands (once)
function F.addRows()
    if F.rowsAdded then return end
    local haveGroup = false
    for _, g in ipairs(L.GROUPS) do if g == F.GROUP then haveGroup = true end end
    if not haveGroup then table.insert(L.GROUPS, 3, F.GROUP) end
    for _, c in ipairs(F.CMDS) do
        if L.byId[c.id] == nil then
            -- before the hidden follow_me row (the Commands tab lists in order)
            local at = #L.CMDS + 1
            for i, row in ipairs(L.CMDS) do if row.hidden then at = i; break end end
            table.insert(L.CMDS, at, c)
            L.byId[c.id] = c
        end
    end
    F.rowsAdded = true
end
F.addRows()

-- why, in plain words (L.whyWords for the AI)
local WHY = {
    no_target = "there was nobody to do it to", no_body = "there was no body there", empty = "there was nothing on it worth taking",
    no_food = "they had no food to spare", lost = "they lost sight of them", contact = "they saw trouble", turned = "the other one turned on you",
    too_far_away = "that person is too far away", unknown = "they don't know who you mean", gave_up = "they couldn't get there",
}
for k, v in pairs(WHY) do if L.WHY[k] == nil then L.WHY[k] = v end end

----------------------------------------------------------------------------------------------------------------
-- helpers (all guarded)
----------------------------------------------------------------------------------------------------------------
local function comp() local pa = PA(); return pa ~= nil and pa.Companions or nil end
function F.shellOf(uid)
    uid = tostring(uid)
    local c = comp()
    local sh = nil
    if fn(c, "shellOf") then pcall(function() sh = c.shellOf(uid) end) end
    if sh == nil then
        pcall(function()
            local b = PA().Watchdog.bindings[uid]
            if b ~= nil then sh = b.shell end
        end)
    end
    return sh
end
function F.recOf(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return r end
local function xyz(o) local x, y, z = nil, nil, 0; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function posOfUid(uid)
    local x, y, z = xyz(F.shellOf(uid))
    if x ~= nil then return x, y, z, true end
    local r = F.recOf(uid)
    if type(r) == "table" and type(r.worldPosition) == "table" and tonumber(r.worldPosition.x) then
        return tonumber(r.worldPosition.x), tonumber(r.worldPosition.y), tonumber(r.worldPosition.z) or 0, false
    end
    return nil
end
F.posOfUid = posOfUid
function F.opinion(r, player)
    local v = 0
    pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end)
    return v
end
-- compass words from a to b (x east, y south)
F.DIRS = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }
function F.dirWord(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0 then return "right here" end
    local a = math.atan2(dy, dx) -- 0 = east, +90 = south
    local i = math.floor((a / (2 * math.pi)) * 8 + 0.5) % 8
    return F.DIRS[i + 1]
end
-- what's around x, y within r: dead (A-Life's own test: no actor behind the body), people, people hostile to you
function F.around(x, y, r, player, skipUid)
    local dead, people, hostile, nx, ny, nd = 0, 0, 0, nil, nil, 1e12
    pcall(function()
        local list = getCell():getZombieList()
        local Perc = PA() and PA().Perception or nil
        for i = 0, list:size() - 1 do
            local zb = list:get(i)
            if not zb:isDead() then
                local d = d2(zb:getX(), zb:getY(), x, y)
                if d <= r * r then
                    local actor = nil
                    if fn(Perc, "activeActorForShell") then pcall(function() actor = Perc.activeActorForShell(zb) end) end
                    if actor == nil then
                        dead = dead + 1
                        if d < nd then nx, ny, nd = zb:getX(), zb:getY(), d end
                    elseif tostring(actor.uid) ~= tostring(skipUid) and not L.isMine(actor.uid, player) then
                        people = people + 1
                        if F.opinion(F.recOf(actor.uid), player) <= -41 then
                            hostile = hostile + 1
                            if d < nd then nx, ny, nd = zb:getX(), zb:getY(), d end
                        end
                    end
                end
            end
        end
    end)
    return { dead = dead, people = people, hostile = hostile, x = nx, y = ny }
end

local function done(uid, j, payload)
    F.jobs[tostring(uid)] = nil
    payload.uid = tostring(uid)
    payload.cmd = payload.cmd or j.cmd
    if payload.ok then F.metrics.done = F.metrics.done + 1 else F.metrics.failed = F.metrics.failed + 1 end
    if j.player ~= nil then ALifeCmd.reply(j.player, "cmdDone", payload) end
end
local function backToYou(uid, j) if j.player ~= nil then L.order(j.player, uid, "follow", nil) end end

----------------------------------------------------------------------------------------------------------------
-- starting a job (after L.runOne's checks: yours, and they agreed)
----------------------------------------------------------------------------------------------------------------
function F.start(player, uid, c, point, args)
    uid = tostring(uid)
    local now = minutes()
    local px, py, pz = xyz(player)
    if px == nil then return false, "gone" end
    local sh = F.shellOf(uid)
    if sh == nil and c.job ~= "message" then return false, "gone" end
    local j = { kind = c.job, cmd = c.id, player = player, at = now }
    if c.job == "point" then
        j.lx, j.ly = px, py
        F.jobs[uid] = j
        F.pointAim(uid, j, true)
        return true, nil
    end
    if c.job == "scout" or c.job == "search" or c.job == "lure" then
        if point == nil then return false, c.job == "search" and "no_body" or "no_spot" end
        local ok, why = L.order(player, uid, "go_to", point)
        if not ok then return false, why end
        j.x, j.y, j.z = point.x, point.y, point.z or 0
        F.jobs[uid] = j
        return true, nil
    end
    -- the other person: keep an eye on / feed / message
    local t = args ~= nil and args.target ~= nil and tostring(args.target) or nil
    if t == nil or t == uid then return false, c.job == "message" and "unknown" or "no_target" end
    local tr = F.recOf(t)
    if type(tr) ~= "table" or tr.lifecycle == "dead" then return false, c.job == "message" and "unknown" or "no_target" end
    local tx, ty, tz, loaded = posOfUid(t)
    if tx == nil then return false, "no_target" end
    j.target = t
    if c.job == "eye" then
        if not loaded or d2(tx, ty, px, py) > num("eyeReach") ^ 2 then return false, "no_target" end
        F.jobs[uid] = j
        F.eyeAim(uid, j, true)
        return true, nil
    end
    if c.job == "feed" then
        if not loaded then return false, "no_target" end
        if F.foodToGive(sh) == nil then return false, "no_food" end
        local ok, why = L.order(player, uid, "go_to", { x = math.floor(tx), y = math.floor(ty), z = math.floor(tz) })
        if not ok then return false, why end
        j.tx, j.ty = tx, ty
        F.jobs[uid] = j
        return true, nil
    end
    if c.job == "message" then
        if d2(tx, ty, px, py) > num("msgReach") ^ 2 then return false, "too_far_away" end
        j.text = string.sub(tostring(args.text or ""), 1, 200)
        j.tx, j.ty, j.tz = tx, ty, tz
        j.phase = "go"
        local ok, why = L.order(player, uid, "go_to", { x = math.floor(tx), y = math.floor(ty), z = math.floor(tz) })
        if not ok then return false, why end
        F.jobs[uid] = j
        return true, nil
    end
    return false, "error"
end

----------------------------------------------------------------------------------------------------------------
-- each job, every game minute
----------------------------------------------------------------------------------------------------------------
-- take point: the way you're going = how you moved since last minute; standing still = where you face
function F.pointAim(uid, j, first)
    local px, py, pz = xyz(j.player)
    if px == nil then return end
    local dx, dy = px - (j.lx or px), py - (j.ly or py)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then
        dx, dy = nil, nil
        pcall(function() local v = j.player:getForwardDirection(); dx, dy = v:getX(), v:getY() end) -- unverified on 42.21 (guarded)
        if dx == nil and j.hx ~= nil then dx, dy = j.hx, j.hy end
        if dx == nil then return end
        len = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    end
    j.hx, j.hy = dx / len, dy / len
    j.lx, j.ly = px, py
    local tx, ty = math.floor(px + j.hx * num("pointTiles")), math.floor(py + j.hy * num("pointTiles"))
    if first or j.ax == nil or d2(tx, ty, j.ax, j.ay) > 4 then
        j.ax, j.ay = tx, ty
        L.order(j.player, uid, "go_to", { x = tx, y = ty, z = math.floor(pz) })
    end
end
function F.tickPoint(uid, j, sh, now)
    if now - j.at > num("pointMinutes") then backToYou(uid, j); return done(uid, j, { ok = true }) end
    local x, y = xyz(sh)
    local seen = F.around(x, y, num("pointStopTiles"), j.player, uid)
    if seen.x ~= nil then
        L.order(j.player, uid, "hold_there", { x = math.floor(x), y = math.floor(y), z = 0 })
        return done(uid, j, { ok = true, why = "contact", dir = F.dirWord(x, y, seen.x, seen.y), dead = seen.dead, hostile = seen.hostile })
    end
    F.pointAim(uid, j, false)
end

-- scout: get there, look a few minutes, come back and tell
function F.tickScout(uid, j, sh, now)
    local x, y = xyz(sh)
    if j.arrived == nil then
        if d2(x, y, j.x, j.y) <= 9 then j.arrived = now
        elseif now - j.at > num("scoutGiveUpMin") then backToYou(uid, j); return done(uid, j, { ok = false, why = "gave_up" }) end
        return
    end
    if now - j.arrived < num("scoutLookMin") then return end
    local seen = F.around(x, y, num("scoutSee"), j.player, uid)
    local px, py = xyz(j.player)
    backToYou(uid, j)
    return done(uid, j, { ok = true, dead = seen.dead, people = seen.people, hostile = seen.hostile,
        dir = px and F.dirWord(px, py, j.x, j.y) or nil })
end

-- keep an eye on them: aim at them again when they move
function F.eyeAim(uid, j, first)
    local tx, ty, tz = xyz(F.shellOf(j.target))
    if tx == nil then return end
    if first or j.ax == nil or d2(tx, ty, j.ax, j.ay) > 4 then
        j.ax, j.ay = tx, ty
        L.order(j.player, uid, "watch_there", { x = math.floor(tx), y = math.floor(ty), z = math.floor(tz) })
    end
end
function F.tickEye(uid, j, sh, now)
    local tsh = F.shellOf(j.target)
    local tr = F.recOf(j.target)
    if tsh == nil or type(tr) ~= "table" or tr.lifecycle == "dead" then backToYou(uid, j); return done(uid, j, { ok = false, why = "lost", target = j.target }) end
    local x, y = xyz(sh)
    local tx, ty = xyz(tsh)
    if d2(x, y, tx, ty) > num("eyeReach") ^ 2 then
        backToYou(uid, j)
        return done(uid, j, { ok = false, why = "lost", target = j.target, dir = F.dirWord(x, y, tx, ty) })
    end
    if F.opinion(tr, j.player) <= -41 then return done(uid, j, { ok = true, why = "turned", target = j.target }) end
    if now - j.at > num("eyeHours") * 60 then backToYou(uid, j); return done(uid, j, { ok = true, target = j.target }) end
    F.eyeAim(uid, j, false)
end

-- search a body: its container, minus what the body wears; the best first (ALifeWorth when there), what they can carry
function F.bodyAt(x, y, z)
    local best, bd = nil, 2.5 * 2.5
    pcall(function()
        for dx = -2, 2 do
            for dy = -2, 2 do
                local sq = getCell():getGridSquare(math.floor(x) + dx, math.floor(y) + dy, math.floor(z or 0))
                local list = sq ~= nil and sq:getDeadBodys() or nil
                if list ~= nil then
                    for i = 0, list:size() - 1 do
                        local b = list:get(i)
                        local d = d2(b:getX(), b:getY(), x, y)
                        if d < bd then best, bd = b, d end
                    end
                end
            end
        end
    end)
    return best
end
local function worth(item)
    local W = ALifeWorth
    if fn(W, "item") then local ok, v = pcall(W.item, item); if ok and tonumber(v) then return tonumber(v) end end
    local w = 0
    pcall(function() w = item:getActualWeight() end)
    return 1 + (tonumber(w) or 0)
end
function F.loot(body, sh)
    local pa = PA()
    local Srv = pa ~= nil and pa.CompanionInventoryServer or nil
    if body == nil then return false, "no_body" end
    if not fn(Srv, "move") then return false, "no_items" end
    local cont, inv = nil, nil
    pcall(function() cont = body:getContainer() end)
    pcall(function() inv = sh:getInventory() end)
    if cont == nil or inv == nil then return false, "no_body" end
    local worn = nil
    pcall(function() worn = body:getWornItems() end)
    local list = {}
    pcall(function()
        local items = cont:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local isWorn = false
            if worn ~= nil then pcall(function() isWorn = worn:contains(it) == true end) end
            local attached = false
            pcall(function() attached = it:getAttachedSlot() ~= nil and it:getAttachedSlot() >= 0 end)
            if not isWorn and not attached then list[#list + 1] = { it = it, v = worth(it) } end
        end
    end)
    if #list == 0 then return false, "empty" end
    table.sort(list, function(a, b) return a.v > b.v end)
    local cap, carried = 50, 0
    if fn(Srv, "capacity") then local ok, c1, c2 = pcall(Srv.capacity, sh, inv); if ok then cap, carried = tonumber(c1) or 50, tonumber(c2) or 0 end end
    local room = cap - carried
    local take, names = {}, {}
    for _, row in ipairs(list) do
        if #take >= num("searchMax") then break end
        local w = 0
        pcall(function() w = fn(Srv, "weightOf") and Srv.weightOf(row.it) or row.it:getActualWeight() end)
        w = tonumber(w) or 0
        if w <= room then take[#take + 1] = row.it; room = room - w end
    end
    if #take == 0 then return false, "too_heavy" end
    for _, it in ipairs(take) do local n = ""; pcall(function() n = it:getDisplayName() end); names[#names + 1] = tostring(n) end
    local moved = Srv.move(cont, inv, take, #take)
    if (tonumber(moved) or 0) <= 0 then return false, "error" end
    F.metrics.looted = F.metrics.looted + moved
    local shown = {}
    for i = 1, math.min(4, #names) do shown[i] = names[i] end
    return true, nil, moved, table.concat(shown, "|")
end
function F.tickSearch(uid, j, sh, now)
    local x, y = xyz(sh)
    if j.arrived == nil then
        if d2(x, y, j.x, j.y) <= 2.5 * 2.5 then j.arrived = now
        elseif now - j.at > num("searchGiveUpMin") then backToYou(uid, j); return done(uid, j, { ok = false, why = "gave_up" }) end
        return
    end
    if now - j.arrived < num("searchMinutes") then return end
    local ok, why, n, names = F.loot(F.bodyAt(j.x, j.y, j.z), sh)
    backToYou(uid, j)
    return done(uid, j, { ok = ok, why = why, n = n, names = names })
end

-- lure them off: noise while they run, then they lose them and come back
function F.noise(sh)
    local x, y, z = xyz(sh)
    if x == nil then return false end
    local r = num("lureNoise")
    local ok = pcall(function() addSound(sh, math.floor(x), math.floor(y), math.floor(z), r, r) end) -- as A-Life's AimRetreat / Standoff
    if ok then F.metrics.noise = F.metrics.noise + 1 end
    return ok
end
function F.tickLure(uid, j, sh, now)
    if j.loseAt == nil then
        if now - j.at <= num("lureMinutes") then F.noise(sh); return end
        local x, y = xyz(sh)
        L.order(j.player, uid, "hold_there", { x = math.floor(x), y = math.floor(y), z = 0 })
        j.loseAt = now
        return
    end
    if now - j.loseAt < num("lureLoseMin") then return end
    local x, y = xyz(sh)
    local seen = F.around(x, y, 15, j.player, uid)
    backToYou(uid, j)
    return done(uid, j, { ok = true, dead = seen.dead })
end

-- feed them: walk over, hand over their own food (not rotten; keep feedKeep for themselves)
local function isFood(it)
    local yes = false
    pcall(function() yes = instanceof(it, "Food") end)
    if not yes then return false end
    local bad = false
    pcall(function() bad = it:isRotten() == true end)
    if bad then return false end
    pcall(function() bad = it:isSpice() == true end)
    return not bad
end
function F.foodToGive(sh)
    local foods = {}
    pcall(function()
        local items = sh:getInventory():getItems()
        for i = 0, items:size() - 1 do local it = items:get(i); if isFood(it) then foods[#foods + 1] = it end end
    end)
    if #foods <= num("feedKeep") then return nil end
    local best, bv = nil, -1
    for _, it in ipairs(foods) do
        local v = 0
        pcall(function() v = -(tonumber(it:getHungerChange()) or 0) end) -- hunger change is negative: more filling = bigger
        if v > bv then best, bv = it, v end
    end
    return best
end
function F.tickFeed(uid, j, sh, now)
    local tsh = F.shellOf(j.target)
    if tsh == nil then backToYou(uid, j); return done(uid, j, { ok = false, why = "no_target", target = j.target }) end
    local x, y = xyz(sh)
    local tx, ty, tz = xyz(tsh)
    if d2(x, y, tx, ty) > 2.5 * 2.5 then
        if now - j.at > num("feedGiveUpMin") then backToYou(uid, j); return done(uid, j, { ok = false, why = "gave_up", target = j.target }) end
        if d2(tx, ty, j.tx, j.ty) > 4 then
            j.tx, j.ty = tx, ty
            L.order(j.player, uid, "go_to", { x = math.floor(tx), y = math.floor(ty), z = math.floor(tz) })
        end
        return
    end
    local item = F.foodToGive(sh)
    if item == nil then backToYou(uid, j); return done(uid, j, { ok = false, why = "no_food", target = j.target }) end
    local Srv = PA() and PA().CompanionInventoryServer or nil
    local from, to = nil, nil
    pcall(function() from, to = sh:getInventory(), tsh:getInventory() end)
    local moved = 0
    if fn(Srv, "move") and from ~= nil and to ~= nil then moved = tonumber(Srv.move(from, to, { item }, 1)) or 0 end
    if moved <= 0 then backToYou(uid, j); return done(uid, j, { ok = false, why = "error", target = j.target }) end
    local name = ""
    pcall(function() name = item:getDisplayName() end)
    F.metrics.fed = F.metrics.fed + 1
    local tr = F.recOf(j.target)
    local delta = num("feedThanks")
    if delta ~= 0 and type(tr) == "table" then
        pcall(function() PA().NpcOpinion.adjust(tr, j.player, delta, "Your people gave them " .. tostring(name) .. ".") end)
    end
    backToYou(uid, j)
    return done(uid, j, { ok = true, target = j.target, name = tostring(name) })
end

-- carry a message: walk there (re-aimed while they're both here); unloaded = on paper at msgTilesPerH; told; back
local function paperMin(ax, ay, bx, by) return math.sqrt(d2(ax, ay, bx, by)) / math.max(10, num("msgTilesPerH")) * 60 end
function F.tickMessage(uid, j, sh, now)
    local r = F.recOf(uid)
    if type(r) ~= "table" or r.lifecycle == "dead" then return done(uid, j, { ok = false, why = "gone", target = j.target }) end
    if now - j.at > num("msgGiveUpH") * 60 then backToYou(uid, j); return done(uid, j, { ok = false, why = "gave_up", target = j.target }) end
    local tr = F.recOf(j.target)
    local tx, ty, tz = posOfUid(j.target)
    if j.phase == "go" then
        if type(tr) ~= "table" or tr.lifecycle == "dead" or tx == nil then
            j.phase, j.mood, j.why = "back", "gone", "gone"
            j.backAt, j.backMin = now, 0
            return
        end
        local x, y = xyz(sh)
        local there = false
        if x ~= nil then
            j.fromX, j.fromY = x, y
            there = d2(x, y, tx, ty) <= 3 * 3
            if not there and d2(tx, ty, j.tx, j.ty) > 9 then
                j.tx, j.ty = tx, ty
                L.order(j.player, uid, "go_to", { x = math.floor(tx), y = math.floor(ty), z = math.floor(tz or 0) })
            end
        else
            -- out of sight: on paper, from where they were last seen
            if not j.paper then
                local wx, wy = posOfUid(uid)
                j.paper, j.paperAt = true, now
                j.paperMin = paperMin(wx or tx, wy or ty, tx, ty)
            end
            there = now - j.paperAt >= j.paperMin
        end
        if there then
            j.phase = "back"
            local op = F.opinion(tr, j.player)
            j.mood = op >= 30 and "glad" or (op <= -20 and "cold" or "plain")
            F.metrics.delivered = F.metrics.delivered + 1
            if j.player ~= nil then ALifeCmd.reply(j.player, "cmdDone", { cmd = j.cmd, uid = uid, phase = "told", ok = true, target = j.target, text = j.text, mood = j.mood }) end
            local px, py = xyz(j.player)
            j.backAt = now
            j.backMin = (x == nil and px ~= nil) and paperMin(tx, ty, px, py) or 0
            if j.backMin <= 0 then backToYou(uid, j) end
        end
        return
    end
    -- back: walking back (A-Life follow) or still on the road on paper
    if now - (j.backAt or now) < (j.backMin or 0) then return end
    if not j.followed then j.followed = true; backToYou(uid, j) end
    local x, y = xyz(sh)
    local px, py = xyz(j.player)
    -- they report face to face: wait (up to 2 game hours) until they're back with you (walking, or A-Life brings a follower)
    local close = x ~= nil and px ~= nil and d2(x, y, px, py) <= 6 * 6
    if not close and now - (j.backAt or now) - (j.backMin or 0) < 120 then return end
    return done(uid, j, { ok = j.mood ~= "gone", phase = "back", why = j.why, target = j.target, mood = j.mood })
end

function F.tick()
    local now = minutes()
    local list = {}
    for uid, j in pairs(F.jobs) do list[#list + 1] = { uid = uid, j = j } end
    for _, row in ipairs(list) do
        local uid, j = row.uid, row.j
        local sh = F.shellOf(uid)
        if sh == nil and j.kind ~= "message" then
            F.jobs[uid] = nil
            if j.player ~= nil then ALifeCmd.reply(j.player, "cmdDone", { cmd = j.cmd, uid = uid, ok = false, why = "gone" }) end
        else
            local ok, err = pcall(function()
                if j.kind == "point" then F.tickPoint(uid, j, sh, now)
                elseif j.kind == "scout" then F.tickScout(uid, j, sh, now)
                elseif j.kind == "eye" then F.tickEye(uid, j, sh, now)
                elseif j.kind == "search" then F.tickSearch(uid, j, sh, now)
                elseif j.kind == "lure" then F.tickLure(uid, j, sh, now)
                elseif j.kind == "feed" then F.tickFeed(uid, j, sh, now)
                elseif j.kind == "message" then F.tickMessage(uid, j, sh, now) end
            end)
            if not ok then F.jobs[uid] = nil; log("job " .. tostring(j.kind) .. " for " .. uid .. " failed: " .. tostring(err)) end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- hooks into ALifeCommands: our rows go to F.start; any other order for someone ends their job
----------------------------------------------------------------------------------------------------------------
function F.hook()
    if F.hooked then return true end
    if not fn(L, "runOne") or not fn(L, "run") then return false end
    local runOne, run = L.runOne, L.run
    L.run = function(player, args, ...)
        F.curArgs = type(args) == "table" and args or nil
        local ok, err = pcall(run, player, args, ...)
        F.curArgs = nil
        if not ok then error(err) end
    end
    L.runOne = function(player, uid, c, point, noun, agreed, ...)
        if type(c) == "table" and c.job ~= nil and not F.off.jobs then
            if not L.isMine(uid, player) then L.metrics.notYours = L.metrics.notYours + 1; return false, "not_yours" end
            if agreed ~= true then
                local chance = L.chance(uid, player, c)
                if c.risky then chance = math.max(0, chance - num("cmdRiskTrust")) end
                local r = 0
                if type(ZombRand) == "function" then r = ZombRand(100) else r = math.random(0, 99) end
                if r >= chance then return false, "wont" end
            end
            F.jobs[tostring(uid)] = nil
            local ok, done_, why = pcall(F.start, player, uid, c, point, F.curArgs)
            if not ok then log("start " .. tostring(c.id) .. " failed: " .. tostring(done_)); return false, "error" end
            if done_ then F.metrics.started = F.metrics.started + 1 end
            return done_, why
        end
        F.jobs[tostring(uid)] = nil -- a new order replaces whatever they were doing for you
        return runOne(player, uid, c, point, noun, agreed, ...)
    end
    F.hooked = true
    return true
end
F.hook()

if type(Events) == "table" and Events.EveryOneMinute ~= nil then
    Events.EveryOneMinute.Add(function()
        if F.off.jobs then return end
        local any = false
        for _ in pairs(F.jobs) do any = true; break end
        if not any then return end
        local ok, err = pcall(F.tick)
        if not ok then F.off.jobs = true; log("jobs failed, off for this session: " .. tostring(err)) end
    end)
end
print(TAG .. " ready v" .. F.VERSION .. ": " .. #F.CMDS .. " commands (take point, scout, keep an eye, search body, lure, feed, message), hooks " .. (F.hooked and "on" or "OFF"))
