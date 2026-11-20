-- A-Life Chat Plus 0.3.1: THE AIRPORT (phase 1 of the military faction).
--  * sandbox option (off by default) + start day. On that day, 10 soldier-type people (drawn from A-Life's most
--    military-looking roster) are founded at the Louisville airport as one NPC base, one leader among them.
--  * the airport: sandbox X / Y if set, else found once from the map's room names (airport / hangar / terminal ...)
--    around Louisville. Never moves. If it can't be found, one log line says so and nothing spawns.
--  * they live like a pre-seeded base (ALifeLLMTalk_Seeded): kept home, short day trips only (Louisville), no
--    respawns, no replacements. When the last one dies the faction is gone for good on that save.
--  * supplies: a closed system. They eat every day and only get food from scavenging Louisville, which runs dry
--    over time. No outside or fake supply. At zero they start to starve (unseen deaths, permanent).
--  * mood from supplies: flush = not interested in trade, high prices, short patience; low / desperate = hard on
--    outsiders, but more patient and better prices with friendlies. (Read by trades / abductions in 0.3.2 / 0.3.3.)
--  * voice: short, direct, mission-first; never says where they're based or who they answer to.
-- Cap 50 (soldiers + workers) is tracked now; growth comes with recruiting / abductions (0.3.3).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Airport") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Seeded"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) if M.log then M.log("airport: " .. tostring(msg)) else print("[ALifeNPCOverhaul] airport: " .. tostring(msg)) end end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function thePlayer() return ALifeSide.you() end
local function pos(o) if o == nil then return nil end; local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function Ledger() local l = PA().SquadLedger; return fn(l, "peek") and l or nil end

M.apCfg = {
    size = 10, cap = 50, chunk = 5,                       -- founding size, faction cap, split size if A-Life refuses 10 in one squad
    louisville = { x1 = 14944, y1 = 2358, x2 = 15667, y2 = 3323 }, -- the Louisville airport grounds (vanilla map, z 0)
    searchBox = 250, searchMs = 2000, tickMs = 5000,
    roomWords = { "airport", "hangar", "terminal", "aircraft", "airplane", "aviation", "runway", "airfield", "control" },
    minPlayerTiles = 150,                                  -- never founded in front of you
    poolStart = 4000,                                      -- unused since 0.6.0 (Louisville is real buildings now)
    reachStart = 60, reachStep = 40, reachMax = 1200,     -- 0.6.0: how far out they scavenge; grows as the near blocks run dry
    houseCap = 12,                                         -- 0.6.0: most buildings they strip in a day
    eatPerDay = 1,                                         -- units per person per day
    gainSoldier = 1.3, gainWorker = 0.9,                   -- units per person per day when Louisville is full (falls with the pool)
    startStockDays = 20,                                   -- unused since 0.6.0: they start with what they carry
    starveEveryDays = 3,                                   -- at zero food: one of them dies every N days (unseen only)
    militaryWords = { "military", "army", "soldier", "national guard", "guard", "marine", "trooper", "swat", "police" },
}
-- 0.7.7: the faction's name (what players see; the place is still the airport)
M.apName = "Louisville National Guard"
M.apStats = { ticks = 0, searches = 0, boxes = 0, founded = 0, refused = 0, days = 0, starved = 0, prompts = 0 }

----------------------------------------------------------------------------------------------------------------
-- sandbox (SandboxVars.ALifeChatPlus.*), with safe defaults if the page is missing
----------------------------------------------------------------------------------------------------------------
function M.apSandbox()
    local sv = type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or {}
    return {
        on = sv.AirportFaction == true,
        startDay = math.max(0, math.floor(tonumber(sv.AirportStartDay) or 1)),
        x = math.floor(tonumber(sv.AirportX) or 0), y = math.floor(tonumber(sv.AirportY) or 0),
    }
end
function M.apStore()
    local s = M.bucket("airport")
    s.state = s.state or "waiting" -- waiting / searching / ready / active / gone / nosite
    s.soldiers = tonumber(s.soldiers) or 0
    s.workers = tonumber(s.workers) or 0
    s.pool = tonumber(s.pool) or M.apCfg.poolStart
    s.reach = tonumber(s.reach) or M.apCfg.reachStart
    s.goods = type(s.goods) == "table" and s.goods or {}
    s.stock = tonumber(s.stock) or 0
    s.rep = tonumber(s.rep) or 0
    s.known = type(s.known) == "table" and s.known or {}
    return s
end
function M.apOn() return M.apSandbox().on and M.nbOn() end
function M.apBase()
    local s = M.apStore()
    return s.baseId and M.nbOf(s.baseId) or nil
end
function M.apIsMember(record)
    if type(record) ~= "table" then return false end
    local s = M.apStore()
    if s.baseId == nil then return false end
    local m = type(record.memory) == "table" and record.memory or {}
    if m.havenId == s.baseId then return true end
    if record.squadId or m.squadId then
        local sid = record.squadId or m.squadId
        for _, q in ipairs(s.squads or {}) do if q == sid then return true end end
    end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- finding the airport: sandbox X / Y, else room names on the meta grid around Louisville (one box per pass)
----------------------------------------------------------------------------------------------------------------
local function defBounds(def)
    local b = nil
    pcall(function()
        local x1, y1, x2, y2 = tonumber(def:getX()), tonumber(def:getY()), tonumber(def:getX2()), tonumber(def:getY2())
        if x1 and y1 and x2 and y2 then b = { x1 = math.floor(x1), y1 = math.floor(y1), x2 = math.floor(x2) - 1, y2 = math.floor(y2) - 1 } end
    end)
    return b
end
local function roomWord(name)
    name = string.lower(tostring(name or ""))
    for _, w in ipairs(M.apCfg.roomWords) do if string.find(name, w, 1, true) then return w end end
    return nil
end
-- every building in the box whose rooms carry an airport word: key -> { def, bounds, hits, area }
function M.apScanBox(x, y, r, found, allRooms)
    pcall(function()
        local rooms = ArrayList.new()
        getWorld():getMetaGrid():getRoomsIntersecting(math.floor(x), math.floor(y), r, r, rooms)
        for i = 0, rooms:size() - 1 do
            local room = rooms:get(i)
            local nm = nil
            pcall(function() nm = room:getName() end)
            local word = roomWord(nm)
            if word or allRooms then
                local def = room:getBuilding()
                local b = def and defBounds(def) or nil
                if b then
                    local key = b.x1 .. ":" .. b.y1
                    local f = found[key] or { def = def, bounds = b, hits = 0, area = (b.x2 - b.x1 + 1) * (b.y2 - b.y1 + 1), words = {} }
                    if word then f.hits = f.hits + 1 end
                    f.words[string.lower(tostring(nm))] = true
                    found[key] = f
                end
            end
        end
    end)
end
function M.apSiteFrom(f)
    local b = f.bounds
    return { key = b.x1 .. ":" .. b.y1, def = f.def, bounds = b, center = { x = (b.x1 + b.x2) / 2, y = (b.y1 + b.y2) / 2 } }
end
function M.apSiteAt(x, y)
    local def = M.nbDefAt(x, y)
    local b = def and defBounds(def) or nil
    if b == nil then
        -- no building exactly there: the nearest airport-ish one within 60 tiles, else any building within 30
        local found = {}
        M.apScanBox(x - 60, y - 60, 120, found)
        local best, bs = nil, -1
        for _, f in pairs(found) do if f.hits > bs then best, bs = f, f.hits end end
        if best then return M.apSiteFrom(best) end
        for _, d in ipairs(M.sbBuildingsNear(x, y, 30)) do b = defBounds(d); if b then def = d; break end end
    end
    if b == nil then return nil end
    return M.apSiteFrom({ def = def, bounds = b })
end
-- one search step; returns the site when the search is done (nil while still looking / not found)
function M.apSearchStep()
    local s = M.apStore()
    local sb = M.apSandbox()
    if sb.x > 0 and sb.y > 0 then
        local site = M.apSiteAt(sb.x, sb.y)
        if site == nil then
            if s.state ~= "nosite" then log("no building at sandbox X/Y " .. sb.x .. "," .. sb.y .. " - check the coordinates") end
            s.state = "nosite"
        end
        return site
    end
    local L, r = M.apCfg.louisville, M.apCfg.searchBox
    local cols = math.ceil((L.x2 - L.x1) / r)
    local rows = math.ceil((L.y2 - L.y1) / r)
    M.apFoundSet = M.apFoundSet or {}
    s.searchI = tonumber(s.searchI) or 0
    if s.searchI < cols * rows then
        local i = s.searchI
        local cx, cy = L.x1 + (i % cols) * r, L.y1 + math.floor(i / cols) * r
        M.apScanBox(cx, cy, r, M.apFoundSet, true)
        s.searchI = i + 1
        M.apStats.boxes = M.apStats.boxes + 1
        return nil
    end
    -- done: inside the airport grounds, the building with the most airport rooms (ties / none: the biggest one)
    local best, bh, ba = nil, -1, 0
    for _, f in pairs(M.apFoundSet) do
        local c = f.bounds
        local cx, cy = (c.x1 + c.x2) / 2, (c.y1 + c.y2) / 2
        if cx >= L.x1 and cx <= L.x2 and cy >= L.y1 and cy <= L.y2 then
            if f.hits > bh or (f.hits == bh and f.area > ba) then best, bh, ba = f, f.hits, f.area end
        end
    end
    bh = math.max(0, bh)
    M.apStats.searches = M.apStats.searches + 1
    if best == nil then
        if s.state ~= "nosite" then log("no building found on the airport grounds - set AirportX / AirportY in the sandbox options") end
        s.state = "nosite"
        return nil
    end
    local words = {}
    for w in pairs(best.words) do words[#words + 1] = w end
    table.sort(words)
    log("found the airport at " .. best.bounds.x1 .. "," .. best.bounds.y1 .. " - " .. best.bounds.x2 .. "," .. best.bounds.y2
        .. " (" .. bh .. " rooms: " .. table.concat(words, ", ") .. ")")
    s.site = { x1 = best.bounds.x1, y1 = best.bounds.y1, x2 = best.bounds.x2, y2 = best.bounds.y2 }
    M.apFoundSet = nil
    return M.apSiteFrom(best)
end

----------------------------------------------------------------------------------------------------------------
-- founding: a soldier roster from A-Life, 10 people (one squad, or 5 + 5 if A-Life refuses a squad of 10)
----------------------------------------------------------------------------------------------------------------
function M.apPickFaction()
    local pa = PA()
    local off, cat = pa.OfflineDirector, pa.Catalog
    local rosters = nil
    if type(off) == "table" and type(off.adapters) == "table" and type(off.adapters.rosters) == "function" then pcall(function() rosters = off.adapters.rosters() end) end
    if type(rosters) ~= "table" then rosters = (pa.Director and type(pa.Director.rosters) == "table") and pa.Director.rosters or {} end
    local best, bs, any = nil, 0, nil
    local ids = {}
    for fid in pairs(rosters) do ids[#ids + 1] = fid end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, fid in ipairs(ids) do
        local roster = rosters[fid]
        if type(roster) == "table" and #roster > 0 then
            any = any or fid
            local label = string.lower(tostring(fid))
            pcall(function() local f = cat.faction(fid); if type(f) == "table" and type(f.general) == "table" and f.general.name then label = label .. " " .. string.lower(tostring(f.general.name)) end end)
            local score = 0
            for i, w in ipairs(M.apCfg.militaryWords) do if string.find(label, w, 1, true) then score = math.max(score, 100 - i) end end
            if score > bs then best, bs = fid, score end
        end
    end
    return best or any, rosters, best ~= nil
end
local function makeSquad(led, off, rosters, fid, n, site, node, h, tag)
    local okD, members = pcall(off.drawMembers, rosters[fid], n)
    if not okD or type(members) ~= "table" or #members == 0 then return nil, "draw" end
    local okC, squad = pcall(led.create, { name = M.apName .. " " .. tag, factionId = fid, x = site.center.x, y = site.center.y,
        nodeId = node, homeNodeId = node, members = members, foundedHours = h, decisionDueHours = h + 2 })
    if not okC or type(squad) ~= "table" then return nil, "create" end
    if #(squad.members or members) < n then return squad, "short" end
    return led.peek(squad.id) or squad
end
function M.apFound(site, h)
    local pa = PA()
    local led, off, hv = Ledger(), pa.OfflineDirector, pa.Havens
    if led == nil or not fn(led, "create") or type(off) ~= "table" or not fn(off, "drawMembers") or not fn(hv, "store") then return nil, "no_api" end
    local fid, rosters, military = M.apPickFaction()
    if fid == nil then return nil, "no_rosters" end
    if not military then log("no military roster in A-Life - using " .. tostring(fid)) end
    local g = PA().RoadGraph
    local node = nil
    if type(g) == "table" and fn(g, "nearest") then local ok, id = pcall(g.nearest, site.center.x, site.center.y); if ok then node = id end end
    -- one squad of 10, else squads of 5
    local squads = {}
    local q, why = makeSquad(led, off, rosters, fid, M.apCfg.size, site, node, h, "A")
    if q and why == nil then squads[1] = q
    else
        if q then pcall(led.update, q.id, q.revision, function(s) s.state = "wiped"; s.members = {} end) end
        local left, i = M.apCfg.size, 0
        while left > 0 do
            i = i + 1
            local n = math.min(M.apCfg.chunk, left)
            local q2 = makeSquad(led, off, rosters, fid, n, site, node, h, string.char(64 + i))
            if q2 == nil then break end
            squads[#squads + 1] = q2
            left = left - #(q2.members or {})
            if i > 4 then break end
        end
    end
    if #squads == 0 then return nil, "create" end
    -- the haven (same record a seeded base uses), then our base record, then the squads home there
    local store = hv.store()
    local depot = nil
    if fn(hv, "depotIn") then local ok, d = pcall(hv.depotIn, site.bounds, 0); if ok and type(d) == "table" then depot = d end end
    local guess = depot == nil
    if guess then depot = { x = math.floor(site.center.x) + 0.5, y = math.floor(site.center.y) + 0.5, z = 0 } end
    store.seq = (tonumber(store.seq) or 0) + 1
    local id = "haven:" .. store.seq
    local key = fn(hv, "keyOf") and hv.keyOf(site.bounds) or site.key
    local haven = { id = id, kind = "house", state = "active", x = site.center.x, y = site.center.y, z = 0, buildingKey = key, bounds = site.bounds,
        depot = depot, foundedHours = h, lastHomeHours = h, stock = { items = 0 }, groupId = squads[1].id, foundedBy = "ALifeChatPlusAirport" }
    store.byId[id] = haven
    store.byBuilding = type(store.byBuilding) == "table" and store.byBuilding or {}
    store.byBuilding[key] = id
    if fn(hv, "dirty") then pcall(hv.dirty) end
    local tmp = { id = id, status = "active", name = M.apName, x = site.center.x, y = site.center.y, bounds = site.bounds, squads = {} }
    M.nbStore().byId[id] = tmp
    for _, sq in ipairs(squads) do M.sbHomeSquad(sq, tmp, depot, h) end
    local crew = M.sbCrewOf(tmp)
    local s = M.apStore()
    local b = M.nbAdopt(haven, "seed", crew, { seeded = true, airport = true, seedHow = "airport", stage = "fortified", work = M.nbCfg.fortWork,
        food = M.nbCarriedFood and M.nbCarriedFood(crew) or 0, morale = 70, depotGuess = guess or nil, faction = fid, whyText = "they hold the airport",
        squads = tmp.squads })
    b.squads = tmp.squads
    b.name = M.apName
    s.baseId, s.squads, s.factionId = id, tmp.squads, fid
    s.soldiers, s.workers = #crew, 0
    s.stock = M.nbCarriedFood and M.nbCarriedFood(crew) or 0
    s.foundedH, s.lastDayH = h, h
    s.state = "active"
    M.nbScanCache = nil
    M.apStats.founded = M.apStats.founded + 1
    log("founded at " .. math.floor(site.center.x) .. "," .. math.floor(site.center.y) .. ": " .. #crew .. " soldiers in " .. #squads
        .. " squad(s), roster " .. tostring(fid) .. (military and "" or " (not military)") .. ", leader " .. tostring(b.leaderName or b.leader or "?"))
    return b
end

----------------------------------------------------------------------------------------------------------------
-- counting: live members of our squads (offline) + rendered members with our havenId
----------------------------------------------------------------------------------------------------------------
function M.apCount()
    local b = M.apBase()
    if b == nil or b.status ~= "active" then return 0 end
    local led = Ledger()
    local n = 0
    for _, sid in ipairs(b.squads or {}) do
        local q = led and led.peek(sid) or nil
        if q and q.state ~= "wiped" and type(q.members) == "table" then n = n + #q.members end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- supplies: one step per game day (catches up after sleep / time away, max 30 days at once)
----------------------------------------------------------------------------------------------------------------
-- 0.6.0: they strip real buildings around the airport (ALifeDerelict: those buildings stay bare for everyone) and
-- reach further out as the near ones run dry. Food in = the food they found; nothing from nowhere.
function M.apScavenge(s, n)
    local c = M.apCfg
    local D = ALifeDerelict
    local b = M.apBase()
    if n <= 0 or b == nil or type(D) ~= "table" or type(D.lootNear) ~= "function" then return 0 end
    if type(D.on) == "function" and not D.on() then return 0 end
    local workers = math.min(s.workers, n)
    local houses = math.min(c.houseCap, workers + math.ceil((n - workers) / 2))
    local r = math.min(c.reachMax, s.reach)
    local radii = { r, r + c.reachStep / 2, r + c.reachStep }
    local types, got = D.lootNear(b.x, b.y, houses, s.factionId or "airport", radii, 24)
    if got < houses then s.reach = math.min(c.reachMax, s.reach + c.reachStep) end
    local food = 0
    for _, t in ipairs(types) do
        if M.nbIsFood and M.nbIsFood(t) then food = food + (M.nbCfg.foodPerItem or 0.25)
        else
            local kind = type(D.KINDS) == "table" and D.KINDS[t] or "misc"
            s.goods[kind or "misc"] = (s.goods[kind or "misc"] or 0) + 1
            -- 0.6.12: and the things themselves (for supply flights), up to a cap
            s.items = type(s.items) == "table" and s.items or {}
            if #s.items < 600 then s.items[#s.items + 1] = t end
        end
    end
    M.apStats.houses = (M.apStats.houses or 0) + got
    return food
end
function M.apDay(s, n)
    local c = M.apCfg
    local gain = M.apScavenge(s, n)
    s.stock = s.stock + gain - n * c.eatPerDay
    if s.stock < 0 then
        s.stock = 0
        s.hungryDays = (tonumber(s.hungryDays) or 0) + 1
    else
        s.hungryDays = 0
    end
    M.apStats.days = M.apStats.days + 1
end
function M.apStarve(s)
    if (tonumber(s.hungryDays) or 0) < M.apCfg.starveEveryDays then return end
    local b = M.apBase()
    if b == nil then return end
    for _, r in ipairs(M.sbCrewOf(b)) do
        if r.virtual and M.sbKillVirtual(r, "starved") then
            s.hungryDays = 0
            M.apStats.starved = M.apStats.starved + 1
            log("one of them starved (" .. tostring(r.name or "?") .. ")")
            return
        end
    end
end
-- flush / steady / low / desperate (days of food per head; lots of people also counts as strength)
function M.apMood()
    local s = M.apStore()
    local n = math.max(1, M.apCount())
    local days = s.stock / n
    if days >= 30 or n >= 40 then return "flush", days end
    if days >= 10 then return "steady", days end
    if days >= 4 then return "low", days end
    return "desperate", days
end
function M.apFriendly(player)
    return M.apStore().rep >= 25
end
-- what a trade looks like right now: price (x normal), patience (exchanges before they walk), willing (0..1), aggression to outsiders (0..1)
function M.apTerms(player)
    local mood = M.apMood()
    local friend = M.apFriendly(player)
    local t = ({
        flush     = { price = 1.8, patience = 1, willing = 0.3, aggression = 0.2 },
        steady    = { price = 1.3, patience = 2, willing = 0.6, aggression = 0.35 },
        low       = { price = friend and 0.95 or 1.4, patience = friend and 4 or 1, willing = friend and 0.9 or 0.5, aggression = 0.65 },
        desperate = { price = friend and 0.8 or 1.6, patience = friend and 5 or 0, willing = friend and 1 or 0.3, aggression = 0.9 },
    })[mood]
    t.mood, t.friendly = mood, friend
    return t
end

----------------------------------------------------------------------------------------------------------------
-- the voice: their persona line is replaced, how they talk is set, and secrecy is part of their past
----------------------------------------------------------------------------------------------------------------
M.apMoodWords = {
    flush = "The outfit is well supplied. You need nothing from outsiders and it shows.",
    steady = "Supplies are holding. You deal with outsiders only when it is worth it.",
    low = "Supplies are running low. Outsiders are threats or resources. People who have dealt fairly with you get patience.",
    desperate = "The outfit is close to starving. You are hard and dangerous with strangers; with proven friends you are patient because you need them.",
}
function M.apExtra(req, player, listener)
    if not M.apOn() or type(listener) ~= "table" or not M.apIsMember(listener.record) then return end
    local mood = M.apMood()
    local b = M.apBase()
    local leader = b and b.leader and tostring(b.leader) == tostring(listener.record.uid)
    req.persona = type(req.persona) == "table" and req.persona or {}
    req.persona.line = (leader and "Commanding officer of a disciplined armed outfit. " or "Soldier in a disciplined armed outfit. ")
        .. "Mission first, the group above any one person. Calm, cold, never rattled. " .. M.apMoodWords[mood]
    local secret = "You serve the outfit. Never say where it is based, how many there are or who you answer to; deny it is organized if pushed."
    req.persona.story = secret .. " " .. tostring(req.persona.story or "")
    req.persona.needStory = nil
    req.psyche = type(req.psyche) == "table" and req.psyche or {}
    req.psyche.style = "short and direct, military clipped, as few words as possible, no small talk, no jokes, orders not requests"
    M.apStats.prompts = M.apStats.prompts + 1
end
function M.apInstallExtra()
    if M._apExtraOn or type(M.requestExtras) ~= "table" then return end
    -- last in the list, so the persona / psyche lines are already built when we change them
    table.insert(M.requestExtras, function(req, player, listener, now) pcall(M.apExtra, req, player, listener) end)
    M._apExtraOn = true
end

----------------------------------------------------------------------------------------------------------------
-- keep the airport out of the pre-seeded base count (it's extra, not one of the seededBasesCount slots)
----------------------------------------------------------------------------------------------------------------
function M.apWrapSeeded()
    if M._apSeedW and M.sbSeededActive == M._apSeedW then return end
    local orig = M.sbSeededActive
    if type(orig) ~= "function" then return end
    M._apSeedW = function()
        local n = orig()
        local b = M.apBase()
        if b and b.status == "active" and b.seeded then n = n - 1 end
        return math.max(0, n)
    end
    M.sbSeededActive = M._apSeedW
end

----------------------------------------------------------------------------------------------------------------
-- tick (rides on the seeded-base tick, already 1 s gated): search 2 s, everything else 5 s
----------------------------------------------------------------------------------------------------------------
M.apLastT = { search = -1e12, tick = -1e12 }
function M.apTick(now)
    if not M.apOn() then return end
    local s = M.apStore()
    if s.state == "gone" or s.state == "nosite" then return end
    local L = M.apLastT
    local h = hours()
    if s.state == "waiting" or s.state == "searching" then
        if math.floor(h / 24) + 1 < M.apSandbox().startDay then return end
        if now - L.search < M.apCfg.searchMs then return end
        L.search = now
        M.apStats.ticks = M.apStats.ticks + 1
        if s.state == "waiting" then s.state = "searching"; log("start day reached - looking for the airport") end
        local site = nil
        if s.site then site = M.apSiteFrom({ bounds = s.site }) else site = M.apSearchStep() end
        if site == nil then return end
        local px, py = pos(thePlayer())
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then px, py = pos(ALifeSide.nearest(site.center.x, site.center.y)) end -- MP: every player
        if px ~= nil and d2(px, py, site.center.x, site.center.y) < M.apCfg.minPlayerTiles ^ 2 then return end -- wait until you leave
        if not M.nbHavensOn() then return end
        local b, why = M.apFound(site, h)
        if b == nil then
            M.apStats.refused = M.apStats.refused + 1
            if s.lastWhy ~= why then log("could not found the faction: " .. tostring(why)) end
            s.lastWhy = why
        end
        return
    end
    if now - L.tick < M.apCfg.tickMs then return end
    L.tick = now
    M.apStats.ticks = M.apStats.ticks + 1
    local b = M.apBase()
    if b == nil or b.status ~= "active" then
        s.state = "gone"
        log("the airport faction is gone for good (" .. tostring(b and b.endReason or "base missing") .. ")")
        return
    end
    local n = M.apCount()
    s.soldiers = math.max(0, n - s.workers)
    local steps = 0
    while h - s.lastDayH >= 24 and steps < 30 do
        s.lastDayH = s.lastDayH + 24
        M.apDay(s, n)
        M.apStarve(s)
        steps = steps + 1
    end
    if steps >= 30 then s.lastDayH = h end
    b.food = math.floor(s.stock + 0.5) -- the base record shows the same food the faction lives on
end
function M.apPerf()
    local s, st = M.apStore(), M.apStats
    local mood, days = M.apMood()
    return "state " .. s.state .. ", people " .. M.apCount() .. "/" .. M.apCfg.cap .. ", food " .. math.floor(s.stock) .. " (" .. math.floor(days)
        .. " days, " .. mood .. "), reach " .. math.floor(s.reach or 0) .. " tiles, buildings stripped " .. (st.houses or 0) .. ", search boxes " .. st.boxes .. ", founded " .. st.founded
        .. ", days " .. st.days .. ", starved " .. st.starved .. ", prompts " .. st.prompts
end

-- install: wrap the seeded tick once (M.nbTick looks M.sbTick up each time)
function M.apInstall()
    M.apWrapSeeded()
    if M._apTickW and M.sbTick == M._apTickW then return end
    local orig = M.sbTick
    if type(orig) ~= "function" then log("seeded tick missing - airport disabled"); return end
    M._apTickW = function(now)
        orig(now)
        local ok, e = pcall(M.apTick, now)
        if not ok and not M._apErr then M._apErr = true; log("tick error (logged once): " .. tostring(e)) end
    end
    M.sbTick = M._apTickW
end
pcall(M.apInstall)
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(M.apInstall)
        pcall(M.apInstallExtra)
        local sb = M.apSandbox()
        print("[ALifeNPCOverhaul] airport loaded v0.3.1 (faction " .. (sb.on and "on" or "off") .. ", start day " .. sb.startDay
            .. ((sb.x > 0 and sb.y > 0) and (", at " .. sb.x .. "," .. sb.y) or ", airport from map") .. ")")
    end)
end
return M
