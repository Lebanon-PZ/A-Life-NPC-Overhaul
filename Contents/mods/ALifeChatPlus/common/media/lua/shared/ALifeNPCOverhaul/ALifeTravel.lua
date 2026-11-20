-- A-Life NPC Overhaul: "Go to Muldraugh. The bookstore, near the VHS store and the gas station. Wait for me there."
-- If they agree (the same willingness as "find me at my base": anyone not against you, easily), their group really
-- walks there over A-Life's road network, off-screen like any other trip, and when they arrive they settle at the
-- exact building you described and WAIT for you there for a few days instead of wandering off.
--   town: any town A-Life knows by name (its town regions, including map mods that define theirs)
--   place (optional): a kind of building - bookstore, gas station, pharmacy, police station, church, school, motel,
--     diner, bar, grocery, gun store, hardware store, mechanic, warehouse... - found in that town from the map itself
--   near ... (optional): more buildings to narrow it down; the one closest to all of them wins
-- Without a place they wait in the middle of town. People who aren't part of a travelling group (a lone encounter)
-- can't make the trip and say so.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeTravel") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeTravel]"
ALifeTravel = ALifeTravel or {}
local T = ALifeTravel
T.WAIT_HOURS = 72
T.TOWN_RADIUS = 450             -- how far from a town's middle its buildings are searched

-- words you might say -> pieces of Zomboid room names
T.PLACES = {
    { words = { "bookstore", "book store", "books" }, rooms = { "bookstore" } },
    { words = { "vhs", "video store", "video", "movie store", "rental" }, rooms = { "videostore", "video" } },
    { words = { "gas station", "gas", "petrol" }, rooms = { "gasstore", "gasstation", "gasstorage" } },
    { words = { "pharmacy", "drug store", "drugstore" }, rooms = { "pharmacy" } },
    { words = { "grocery", "supermarket", "grocer" }, rooms = { "grocery", "gigamart", "supermarket" } },
    { words = { "gun store", "gun shop", "gunstore" }, rooms = { "gunstore" } },
    { words = { "police station", "police", "cop shop", "sheriff" }, rooms = { "police" } },
    { words = { "fire station", "firehouse" }, rooms = { "fire" } },
    { words = { "hospital", "clinic", "doctor" }, rooms = { "hospital", "medical" } },
    { words = { "church" }, rooms = { "church" } },
    { words = { "school" }, rooms = { "school", "classroom" } },
    { words = { "motel", "hotel" }, rooms = { "motel", "hotel" } },
    { words = { "diner", "restaurant", "cafe", "pizza", "burger" }, rooms = { "restaurant", "diner", "fastfood", "cafe", "pizza", "spiffo", "burger" } },
    { words = { "bar", "pub", "tavern" }, rooms = { "bar" } },
    { words = { "hardware", "tool store" }, rooms = { "toolstore", "hardware" } },
    { words = { "mechanic", "garage", "auto shop", "car shop" }, rooms = { "mechanic", "garage" } },
    { words = { "liquor", "booze store" }, rooms = { "liquor" } },
    { words = { "warehouse", "factory" }, rooms = { "warehouse", "factory" } },
    { words = { "library" }, rooms = { "library" } },
    { words = { "bank" }, rooms = { "bank" } },
    { words = { "post office" }, rooms = { "post" } },
    { words = { "clothing store", "clothes store" }, rooms = { "clothesstore", "clothes" } },
    { words = { "bakery" }, rooms = { "bakery" } },
    { words = { "gym" }, rooms = { "gym", "fitness" } },
    { words = { "farm" }, rooms = { "farm", "barn" } },
}

local function lowerText(t) return " " .. string.lower(string.gsub(tostring(t or ""), "[^%w%s]", " ")) .. " " end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end

-- the towns you can name: { label, x, y }
--   1. A-Life's own town regions (the vanilla map)
--   2. every active map's spawn regions - map mods name their towns there ("Raven Creek", "Coryerdon"), and the
--      middle of their spawn points is the middle of town
--   3. Zomboid\Lua\alifeai_towns.txt for anything still missing, one per line:  Name = x, y
local townCache = nil
local function cleanName(n)
    n = tostring(n or "")
    n = string.gsub(n, ",%s*%u%u$", "")          -- "Muldraugh, KY" -> "Muldraugh"
    n = string.gsub(n, "^%s+", ""); n = string.gsub(n, "%s+$", "")
    return n
end
local function spawnRegionTowns(out, seen)
    local ok, regions = pcall(function() return SpawnRegionMgr.getSpawnRegionsAux() end)
    if not ok or type(regions) ~= "table" then return end
    for _, region in ipairs(regions) do
        local label = cleanName(region.name)
        if label ~= "" and not seen[string.lower(label)] and type(region.points) == "table" then
            local sx, sy, n = 0, 0, 0
            for _, list in pairs(region.points) do
                for _, pt in ipairs(type(list) == "table" and list or {}) do
                    local x = pt.worldX and (pt.worldX * 300 + (pt.posX or 0)) or pt.posX
                    local y = pt.worldY and (pt.worldY * 300 + (pt.posY or 0)) or pt.posY
                    if tonumber(x) and tonumber(y) then sx, sy, n = sx + x, sy + y, n + 1 end
                end
            end
            if n > 0 then
                seen[string.lower(label)] = true
                out[#out + 1] = { label = label, x = sx / n, y = sy / n, from = "map" }
            end
        end
    end
end
local function fileTowns(out, seen)
    if type(getFileReader) ~= "function" then return end
    local r = getFileReader("alifeai_towns.txt", false)
    if r == nil then return end
    while true do
        local line = r:readLine()
        if line == nil then break end
        local name, x, y = string.match(tostring(line), "^%s*(.-)%s*=%s*(%-?%d+)%s*,%s*(%-?%d+)")
        if name and name ~= "" and not seen[string.lower(name)] then
            seen[string.lower(name)] = true
            out[#out + 1] = { label = name, x = tonumber(x), y = tonumber(y), from = "file" }
        end
    end
    r:close()
end
function T.towns()
    if townCache ~= nil then return townCache end
    local out, seen = {}, {}
    local R = ProjectALife and ProjectALife.TownRegions
    for _, d in ipairs(type(R) == "table" and type(R.definitions) == "table" and R.definitions or {}) do
        local minX, maxX, minY, maxY = tonumber(d.minX), tonumber(d.maxX), tonumber(d.minY), tonumber(d.maxY)
        if d.label and minX and maxX and minY and maxY then
            seen[string.lower(tostring(d.label))] = true
            out[#out + 1] = { label = tostring(d.label), x = (minX + maxX) / 2, y = (minY + maxY) / 2, from = "alife" }
        end
    end
    spawnRegionTowns(out, seen)
    fileTowns(out, seen)
    townCache = out
    return out
end
function T.resetTowns() townCache = nil end

-- which town you named (longest name that appears in what you said)
function T.townIn(text)
    local t = lowerText(text)
    local best
    for _, town in ipairs(T.towns()) do
        local name = " " .. string.lower(town.label) .. " "
        if string.find(t, name, 1, true) and (best == nil or #town.label > #best.label) then best = town end
    end
    return best
end

-- the kinds of buildings you named, in the order you said them
function T.placesIn(text)
    local t = lowerText(text)
    local found = {}
    for _, p in ipairs(T.PLACES) do
        local at = nil
        for _, w in ipairs(p.words) do
            local i = string.find(t, " " .. w .. " ", 1, true) or string.find(t, " " .. w .. "s ", 1, true)
            if i and (at == nil or i < at) then at = i end
        end
        if at then found[#found + 1] = { place = p, at = at } end
    end
    table.sort(found, function(a, b) return a.at < b.at end)
    local out = {}
    for _, f in ipairs(found) do out[#out + 1] = f.place end
    return out
end

-- rooms of a kind near (x, y), from the map itself (works on unloaded areas)
function T.rooms(x, y, radius, place)
    local out = {}
    pcall(function()
        local list = ArrayList.new()
        getWorld():getMetaGrid():getRoomsIntersecting(math.floor(x - radius), math.floor(y - radius), radius * 2, radius * 2, list)
        for i = 0, math.min(list:size(), 1500) - 1 do
            local d = list:get(i)
            local name = string.lower(tostring(d:getName() or ""))
            for _, r in ipairs(place.rooms) do
                if string.sub(name, 1, #r) == r then
                    out[#out + 1] = { x = d:getX() + math.floor((d:getW() or 2) / 2), y = d:getY() + math.floor((d:getH() or 2) / 2),
                        z = d:getZ() or 0, name = name }
                    break
                end
            end
        end
    end)
    return out
end

-- the spot: the first building you named, the one closest to everything else you named
function T.spot(town, places)
    if #places == 0 then return { x = town.x, y = town.y, z = 0, what = town.label } end
    local main = T.rooms(town.x, town.y, T.TOWN_RADIUS, places[1])
    if #main == 0 then return nil, places[1].words[1] end
    local others = {}
    for i = 2, #places do others[#others + 1] = T.rooms(town.x, town.y, T.TOWN_RADIUS, places[i]) end
    local best, bestScore = nil, nil
    for _, m in ipairs(main) do
        local score = ((m.x - town.x) ^ 2 + (m.y - town.y) ^ 2) * 0.01
        for _, list in ipairs(others) do
            local near = nil
            for _, o in ipairs(list) do
                local d = (o.x - m.x) ^ 2 + (o.y - m.y) ^ 2
                if near == nil or d < near then near = d end
            end
            score = score + (near or 1e6)
        end
        if bestScore == nil or score < bestScore then best, bestScore = m, score end
    end
    best.what = places[1].words[1] .. " in " .. town.label
    return best
end

-- send their group there (A-Life's own travel), to wait at the spot
function T.send(record, spot, town)
    local m = type(record.memory) == "table" and record.memory or {}
    local Ledger, Offline, Graph = ProjectALife.SquadLedger, ProjectALife.OfflineDirector, ProjectALife.RoadGraph
    if m.squadId == nil or Ledger == nil or Offline == nil or Graph == nil or type(Graph.nearest) ~= "function" then return nil, "no_group" end
    local q = Ledger.read(m.squadId)
    if q == nil then return nil, "no_group" end
    local dest = Graph.nearest(spot.x, spot.y, "town") or Graph.nearest(spot.x, spot.y)
    if dest == nil then return nil, "no_route" end
    local from = (q.nodeId ~= nil and Graph.nodes[q.nodeId] ~= nil) and q.nodeId or Graph.nearest(q.x, q.y)
    local route = from and Graph.route(from, dest) or nil
    local h = hours()
    local updated = Ledger.update(q.id, q.revision, function(s)
        local task = { kind = "travel", dest = dest, label = "travel to " .. tostring(spot.what),
            chatplusMeet = { x = spot.x, y = spot.y, z = spot.z or 0, what = spot.what, waitHours = T.WAIT_HOURS } }
        Offline.applyTask(s, task, route or { from, dest }, h)
    end)
    if updated == nil then return nil, "busy" end
    print(string.format("%s %s's group heading to %s (%d,%d)", TAG, tostring(m.squadId), tostring(spot.what), spot.x, spot.y))
    return true
end

-- arriving: settle at the exact spot and wait there
function T.arrived(q, task, h)
    local meet = type(task) == "table" and task.chatplusMeet or nil
    if meet == nil then return end
    q.x, q.y = meet.x, meet.y
    meet.untilH = h + (meet.waitHours or T.WAIT_HOURS)
    q.decisionDueHours = meet.untilH
    task.stationary = true
    task.untilHours = meet.untilH
    task.label = "waiting at " .. tostring(meet.what)
end

-- the whole ask: returns a line, or nil if no town was named
T.LINES = {
    yes = { "%s. Alright. I'll be there.", "%s? Okay. Don't keep me waiting too long.", "Fine. %s. I'll wait a few days, no more." },
    no_place = { "There's no %s there that I know of.", "A %s? Not in that town." },
    no_group = { "I'm not walking all the way over there.", "That's too far for me. I'm staying put." },
    refuse = { "I'm not going anywhere you tell me.", "Why would I do that?" },
}
local function pick(l) return l[roll(#l) + 1] end

function T.ask(record, shell, player, text)
    local town = T.townIn(text)
    if town == nil then return nil end
    local RC = ALifeRecruit
    if RC ~= nil and type(RC.weigh) == "function" then
        local _, _, no = RC.weigh(record, shell, player, text, "meet")
        if no ~= nil then return pick(RC.LINES[no] or T.LINES.refuse) end
    end
    local spot, missing = T.spot(town, T.placesIn(text))
    if spot == nil then return string.format(pick(T.LINES.no_place), tostring(missing)) end
    local ok, why = T.send(record, spot, town)
    if not ok then return pick(T.LINES.no_group) end
    if ALifeMemory ~= nil then pcall(ALifeMemory.add, record, "the stranger asked you to wait for them at the " .. tostring(spot.what)) end
    local what = spot.what
    return string.format(pick(T.LINES.yes), string.upper(string.sub(what, 1, 1)) .. string.sub(what, 2))
end

function T.install()
    if T.__installed then return true end
    local Data, Talk, Offline = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.Talk, ProjectALife and ProjectALife.OfflineDirector
    if Data == nil or Talk == nil then return false end
    T.__installed = true
    if Offline ~= nil then
        Offline.arrivals = Offline.arrivals or {}
        local prev = Offline.arrivals.travel
        Offline.arrivals.travel = function(q, task, h)
            if type(prev) == "function" then pcall(prev, q, task, h) end
            T.arrived(q, task, h)
        end
        -- A-Life sets their next decision right after arrival; while they're waiting for you, hold it off
        if type(Offline.serviceMutation) == "function" then
            local origService = Offline.serviceMutation
            Offline.serviceMutation = function(q)
                local meet = type(q) == "table" and type(q.task) == "table" and q.task.chatplusMeet or nil
                if meet ~= nil and meet.untilH ~= nil then
                    q.decisionDueHours = math.max(tonumber(q.decisionDueHours) or 0, meet.untilH)
                end
                return origService(q)
            end
        end
    end
    pcall(Data.intent, "TRAVEL_TO", 84, "go to|head to|head over to|wait for me at|wait for me in|wait for me by|wait at|wait in|meet me at|meet me in|meet me by|find me at|find me in|look for me at|look for me in|i'll find you at|ill find you at|i'll meet you at|ill meet you at")
    local function handler(fallback)
        return function(record, shell, player, context, now, text, asked)
            local ok, line = pcall(T.ask, record, shell, player, text)
            if not ok then print(TAG .. " failed: " .. tostring(line)) end
            if ok and line ~= nil then
                if ProjectALife.Speech.say(shell, line, { face = player }) then return line, "answered" end
                return nil
            end
            if type(fallback) == "function" then return fallback(record, shell, player, context, now, text, asked) end
            return nil
        end
    end
    Talk.choiceHandlers.TRAVEL_TO = handler(Talk.choiceHandlers.INVITE_BASE)
    -- "find me at ..." naming a town goes there; naming only your base still means your base
    Talk.choiceHandlers.INVITE_BASE = handler(Talk.choiceHandlers.INVITE_BASE)
    -- "go to Muldraugh ... wait for me there" often reads as a plain "wait here": a named town makes it a trip
    Talk.choiceHandlers.WAIT_HERE = handler(Talk.choiceHandlers.WAIT_HERE)
    Talk.choiceHandlers.FOLLOW_ME = handler(Talk.choiceHandlers.FOLLOW_ME)
    if ProjectALife.TalkIntents then ProjectALife.TalkIntents.cache = {} end
    -- the names you can use, written out so you can check them (Zomboid\Lua\alifeai_towns_known.txt)
    pcall(function()
        local w = getFileWriter("alifeai_towns_known.txt", true, false)
        if w ~= nil then
            for _, t in ipairs(T.towns()) do w:write(string.format("%s = %d, %d   (%s)\r\n", t.label, math.floor(t.x), math.floor(t.y), t.from or "")) end
            w:close()
        end
    end)
    print(TAG .. " ready (" .. #T.towns() .. " towns known; NPCs go where you tell them and wait)")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    -- after Recruit sets up INVITE_BASE (file order: ALifeRecruit < ALifeTravel)
    Events.OnGameStart.Add(function()
        local ok, err = pcall(T.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
