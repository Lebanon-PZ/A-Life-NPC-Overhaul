-- A-Life Chat Plus (merged with A-Life Talk): DYNAMIC FACTIONS ("bands").
-- A-Life's factions are templates: every hospital squad in the county is "alife_hospital". Here that only decides
-- where people came from. The real factions are bands: each group starts as its own band with its own name
-- ("the Brandenburg Medics", "Vic's Boys", "the Flock of Ekron"), and bands change over time:
--   * people join (loners, refugees taken in by a community) and die; a band with nobody left dies out
--   * a band that settles is the community at its house; its name can follow the house ("Mill House people")
--   * renames when it changes (turns raider, finds faith, a new leader stamps their name on it)
--   * splits: a big unhappy band loses a splinter group under a new leader, with its own name
--   * merges: two small allied bands become one
-- Politics (A-Life Talk's wars / truces / alliances, leaders, radio news), the AI's sense of "my people" and the
-- factions screen (immersion off) all run on bands instead of A-Life's templates. A-Life's own combat hostility
-- still uses its template factions (we never edit A-Life records' factionId).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Bands") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Bands"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Bands") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(seed) local h = (hash(seed) * 16807) % 2147483647; h = (h * 16807) % 2147483647; return (h % 10000) / 10000 end
local function log(msg) if M.log then M.log("bands: " .. tostring(msg)) end end
local function rec(uid) local pa = PA(); return fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local ok, n = pcall(function() return PA().Names.of(r) end); return ok and n and tostring(n) or nil end
local function firstName(r) local n = nameOf(r); return n and string.match(n, "^(%S+)") or nil end
local function lastName(r) local n = nameOf(r); return n and string.match(n, "(%S+)$") or nil end

if M.settings.bands == nil then M.settings.bands = true end

function M.bandStore()
    local s = nil
    pcall(function() s = M.store() end)
    if type(s) ~= "table" then s = type(ModData) == "table" and ModData.getOrCreate("ALifeChatPlus.Bands") or {} end
    s.bands = type(s.bands) == "table" and s.bands or {}
    local b = s.bands
    b.seq = tonumber(b.seq) or 0
    b.byId = type(b.byId) == "table" and b.byId or {}
    b.ofUid = type(b.ofUid) == "table" and b.ofUid or {}
    b.ofKey = type(b.ofKey) == "table" and b.ofKey or {}
    return b
end
function M.isBand(id) return type(id) == "string" and string.sub(id, 1, 5) == "band:" end
-- 0.4.2: renamed from bandOf, which collided with the UI's score-to-label bandOf (UI loads later and replaced this one)
function M.bandById(id) if id == nil then return nil end return M.bandStore().byId[tostring(id)] end
function M.bandOfUid(uid) local s = M.bandStore(); local id = s.ofUid[tostring(uid)]; return id and s.byId[id] or nil end

local function history(band, text)
    band.history = type(band.history) == "table" and band.history or {}
    band.history[#band.history + 1] = { h = hours(), t = text }
    while #band.history > 12 do table.remove(band.history, 1) end
    log(tostring(band.name) .. ": " .. text)
    if (M.newsNote or ALifeSide.mpServer()) and band.notable then pcall(M.outNews, "politics", text) end -- MP: news to everyone online
end
M.bandHistory = history

----------------------------------------------------------------------------------------------------------------
-- names
----------------------------------------------------------------------------------------------------------------
local ORIGIN_WORDS = {
    { "hospital", "Medics" }, { "medic", "Medics" }, { "nurse", "Medics" }, { "fire", "Firefighters" }, { "vfd", "Volunteers" },
    { "police", "Deputies" }, { "sheriff", "Deputies" }, { "law", "Deputies" }, { "military", "Guardsmen" }, { "army", "Guardsmen" },
    { "riverside", "River Folk" }, { "bell", "Families" }, { "family", "Families" }, { "household", "Families" },
    { "farm", "Farmers" }, { "kettle", "Works Crew" }, { "works", "Works Crew" }, { "factory", "Works Crew" },
    { "radio", "Station Crew" }, { "station", "Station Crew" }, { "sanitation", "Sanitation Crew" }, { "pharmac", "Pharmacists" },
    { "trailer", "Trailer Folk" }, { "church", "Congregation" }, { "prison", "Cons" }, { "biker", "Riders" },
    { "raider", "Raiders" }, { "bandit", "Bandits" }, { "gang", "Crew" },
}
local function originWord(fid)
    local low = string.lower(tostring(fid or ""))
    for _, p in ipairs(ORIGIN_WORDS) do if string.find(low, p[1], 1, true) then return p[2] end end
    return "Survivors"
end
local function placeOf(x, y, fallback)
    local p = nil
    if x and y then
        pcall(function() local hv = PA().Havens; if hv and hv.placeName then p = hv.placeName({ x = x, y = y }) end end)
    end
    if (p == nil or p == "") and type(fallback) == "string" then
        p = string.match(fallback, "(%u[%a]+[%s%u%a]*)$") or string.match(fallback, "%u[%a]+")
    end
    if type(p) == "string" then p = string.gsub(p, "^outskirts of ", ""); p = string.gsub(p, "^north of ", "") end
    return (p ~= nil and p ~= "") and p or nil
end
local function nameTaken(name, except)
    for id, b in pairs(M.bandStore().byId) do if id ~= except and not b.dead and b.name == name then return true end end
    return false
end
-- Names the way survivors would actually name themselves: after a place, a building, a founder, an idea, or
-- something people started calling them. Hundreds of combinations; never two alike.
M.bandWords = {
    raiders = { "Wolves", "Claimers", "Reapers", "Vultures", "Jackals", "Highwaymen", "Butchers", "Scavengers", "Hounds",
        "Crows", "Rattlers", "Coyotes", "Buzzards", "Takers", "Collectors", "Saviors", "Black Hats", "Road Agents", "Tollmen",
        "Grinders", "Strippers", "Skinners", "Dogs", "Wreckers", "Night Riders", "Bone Pickers", "Red Hands", "Gravediggers" },
    faithful = { "the Chosen", "the Lambs", "the Shepherds", "the Pilgrims", "the Penitent", "the Flock", "the Remnant",
        "the Redeemed", "the Elect", "Children of the Morning", "the Watchers", "the Called", "the Anointed", "the Faithful",
        "Brethren", "the Sheltered", "the Lightkeepers", "the Covenant", "the Gathered", "the Spared" },
    open = { "the Haven", "Sanctuary", "the Commonwealth", "the Settlement", "Hope", "the Harbor", "the Homestead", "the Kingdom",
        "Refuge", "New Dawn", "Second Chance", "Better Days", "the Neighbors", "Common Ground", "the Long Table", "Open Door",
        "the Lantern", "Safe Harbor", "Hearth", "the Commons", "Last Light", "the Good Folks", "Mercy" },
    wary = { "the Holdouts", "the Watch", "the Stockade", "the Sentinels", "the Wall", "the Fence", "the Lookouts", "the Keep",
        "the Garrison", "Bulwark", "the Line", "Stand Fast", "the Barricade", "Ironside", "the Bunker", "Hardpoint" },
    closed = { "the Closed Gate", "Nobody's Home", "the Locked Door", "Keep Out", "the Hermits", "the Fortress", "No Vacancy",
        "the Shut-Ins", "Dead End", "the Island" },
    traders = { "the Exchange", "the Market", "the Caravan", "Crossroads", "the Swap", "the Trading Post", "Barter Town",
        "the Depot", "the General Store", "Fair Deal", "the Junkyard", "the Toll" },
    drifters = { "the Drifters", "the Strays", "the Stragglers", "the Lost", "the Walkers' Kin", "the Wanderers", "Roadside",
        "the Runners", "the Leftovers", "Nomads", "the Hitchers", "Tumbleweed", "the Unclaimed", "the Lucky Ones", "the Long Road",
        "Ninety-Three", "the Quiet", "Knox Free", "the Living", "Still Here" },
}
M.bandPlaceSuffix = { "Hill", "Hollow", "Ridge", "Landing", "Crossing", "Bend", "Point", "Creek", "Holdout", "Camp", "Free Zone",
    "Station", "Grove", "Flats", "Heights", "Junction", "Run", "Fork", "Mill", "Gap", "Bluff", "Commons", "Watch", "Yard" }
M.bandLandmarks = { church = { "the Church", "Saint %s's", "the Chapel" }, school = { "the School", "%s High", "the Schoolhouse" },
    farm = { "the Farm", "%s Farm", "the Barn" }, motel = { "the Motel", "the Inn" }, mall = { "the Mall" }, prison = { "the Prison", "the Yard" },
    station = { "the Station", "Firehouse" }, mill = { "the Mill" }, store = { "the Store" }, warehouse = { "the Warehouse", "the Depot" },
    hospital = { "the Hospital", "the Clinic" }, house = { "the House on %s", "the %s Place" } }
M.bandFounder = { "%s's Group", "%s's People", "the %s Camp", "%s's Crew", "the %s Outfit", "%s's Bunch", "the %s Family",
    "%s's Lot", "the %s Party", "%s and Them" }
M.bandOriginNicks = { Medics = { "the Medics", "the White Coats", "the Ward" }, Firefighters = { "the Firehouse", "Engine %s", "the Smoke Eaters" },
    Deputies = { "the Badges", "the Law", "the Sheriff's Men" }, Guardsmen = { "the Guard", "the Unit", "the Remnant Company" },
    ["River Folk"] = { "the River People", "Riverside", "the Ferry Folk" }, Farmers = { "the Growers", "the Fields" },
    Cons = { "the Escapees", "the Yard Birds", "the Cellblock" }, Riders = { "the Riders", "the Club" },
    ["Works Crew"] = { "the Works", "the Shop" }, ["Station Crew"] = { "the Station", "On the Air" }, Pharmacists = { "the Pharmacy", "the Dispensary" },
    ["Trailer Folk"] = { "the Park", "the Trailer Court" }, Families = { "the Families", "the Neighbors" }, Congregation = { "the Congregation" } }

function M.bandMakeName(band, opts)
    opts = opts or {}
    local place = opts.place or band.place
    local leader = opts.leader and rec(opts.leader) or (band.leader and rec(band.leader)) or nil
    local lead1, leadL = leader and firstName(leader), leader and lastName(leader)
    local word = originWord(band.origin)
    local creed = opts.creed or band.creed
    local seed = tostring(band.id) .. "#" .. tostring(opts.why or "") .. "#" .. tostring(creed)
    local W = M.bandWords
    local pool = {}
    local function add(list, weight, fill)
        for _, n in ipairs(list or {}) do
            if string.find(n, "%%s") then if fill then pool[#pool + 1] = { string.format(n, fill), weight } end
            else pool[#pool + 1] = { n, weight } end
        end
    end
    -- what they believe drives most names
    local key = creed == "raiders" and "raiders" or creed == "faithful" and "faithful" or creed == "closed" and "closed"
        or creed == "traders" and "traders" or creed == "open" and "open" or creed == "wary" and "wary" or nil
    if key then add(W[key], 3) else add(W.drifters, 2); add(W.wary, 1); add(W.open, 1) end
    if creed == "raiders" and place then for _, n in ipairs(W.raiders) do pool[#pool + 1] = { "the " .. place .. " " .. n, 1 } end end
    -- the place they hold
    if place then
        for _, sfx in ipairs(M.bandPlaceSuffix) do pool[#pool + 1] = { place .. " " .. sfx, 1 } end
        pool[#pool + 1] = { "the " .. place .. " Group", 1 }
    end
    if opts.base then pool[#pool + 1] = { tostring(opts.base), 3 }; pool[#pool + 1] = { tostring(opts.base) .. " people", 1 } end
    for tag, list in pairs(M.bandLandmarks) do if opts.landmark == tag then add(list, 3, place or lead1) end end
    -- the founder (more for one-person-rule groups and splinters)
    local fw = (opts.splinter or band.rule == "leader") and 3 or 1
    if lead1 then for i, n in ipairs(M.bandFounder) do if i % 2 == 1 then add({ n }, fw, lead1) else add({ n }, fw, leadL or lead1) end end end
    -- what people called them before (their trade)
    add(M.bandOriginNicks[word], 1, place or lead1)
    -- pick (weighted, stable for this band and moment), skipping names already in use
    local total = 0
    for _, e in ipairs(pool) do total = total + e[2] end
    local r = roll(seed) * total
    local order, acc, startI = {}, 0, 1
    for i, e in ipairs(pool) do acc = acc + e[2]; if r < acc then startI = i; break end end
    for i = 0, #pool - 1 do order[#order + 1] = pool[((startI - 1 + i) % #pool) + 1][1] end
    for _, n in ipairs(order) do if not nameTaken(n, band.id) then return n end end
    local n = order[1] or ("the " .. word)
    for k = 2, 9 do if not nameTaken(n .. " " .. k, band.id) then return n .. " " .. k end end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- founding and membership
----------------------------------------------------------------------------------------------------------------
function M.bandCreate(key, origin, leaderUid, opts)
    local s = M.bandStore()
    s.seq = s.seq + 1
    local id = "band:" .. s.seq
    local band = { id = id, key = key, origin = origin, leader = leaderUid and tostring(leaderUid) or nil, born = hours(),
        members = {}, place = opts and opts.place or nil, parent = opts and opts.parent or nil }
    local low = string.lower(tostring(origin or ""))
    if string.find(low, "raider") or string.find(low, "bandit") or string.find(low, "gang") or string.find(low, "biker") then band.creed = "raiders"
    elseif string.find(low, "church") or string.find(low, "cult") or string.find(low, "clergy") then band.creed = "faithful" end
    band.name = M.bandMakeName(band, opts)
    s.byId[id] = band
    if key then s.ofKey[key] = id end
    history(band, (opts and opts.splinter) and (tostring(band.name) .. " broke away" .. (opts.from and (" from " .. opts.from) or ""))
        or (tostring(band.name) .. " came together"))
    return band
end
function M.bandAssign(uid, band)
    if band == nil or uid == nil then return end
    local s = M.bandStore()
    uid = tostring(uid)
    local old = s.ofUid[uid]
    if old == band.id then band.members[uid] = true; return end
    if old and s.byId[old] then
        local ob = s.byId[old]
        ob.members[uid] = nil
        if not ob.dead then
            local any = false
            for _ in pairs(ob.members) do any = true; break end
            if not any then ob.dead = true; ob.mergedInto = band.id; history(ob, "the last of " .. tostring(ob.name) .. " joined " .. tostring(band.name)) end
        end
    end
    s.ofUid[uid] = band.id
    band.members[uid] = true
end
function M.bandLiving(band)
    local list = {}
    for uid in pairs(band.members or {}) do
        local r = rec(uid)
        if r and r.lifecycle ~= "dead" then list[#list + 1] = r elseif r == nil or r.lifecycle == "dead" then band.members[uid] = nil end
    end
    return list
end

-- every group A-Life has becomes a band (once); new members of known groups join theirs
function M.bandScan()
    if M.settings.bands == false then return end
    local s = M.bandStore()
    local reg = PA().ActorRegistry
    if not fn(reg, "each") then return end
    pcall(reg.each, function(r)
        if r.lifecycle ~= "dead" and r.uid then
            local uid = tostring(r.uid)
            local m = type(r.memory) == "table" and r.memory or {}
            if s.ofUid[uid] == nil then
                local key = m.groupId or m.squadId
                if key then
                    local id = s.ofKey[key]
                    local band = id and s.byId[id] or nil
                    if band == nil or band.dead then
                        local wp = type(r.worldPosition) == "table" and r.worldPosition or {}
                        local sq = nil
                        pcall(function() sq = m.squadId and PA().SquadLedger.read(m.squadId) end)
                        local task = sq and type(sq.task) == "table" and sq.task.label or nil
                        band = M.bandCreate(key, r.factionId, m.groupRole == "leader" and uid or nil,
                            { place = placeOf(wp.x, wp.y, task) })
                    end
                    M.bandAssign(uid, band)
                    if band.leader == nil or m.groupRole == "leader" then band.leader = uid end
                end
            end
        end
        return false
    end)
end

----------------------------------------------------------------------------------------------------------------
-- communities (A-Life Talk bases + directives) drive the band: the house, its creed, its leader, its ties
----------------------------------------------------------------------------------------------------------------
function M.bandForBase(b)
    if type(b) ~= "table" or type(b.dir) ~= "table" then return nil end
    local d = b.dir
    local band = d.band and M.bandById(d.band) or nil
    if band and band.dead then band = nil end
    if band == nil then
        band = b.leader and M.bandOfUid(b.leader) or nil
        if band == nil or band.dead then
            band = M.bandCreate("base:" .. tostring(b.id), b.faction, b.leader, { base = b.name, place = placeOf(b.x, b.y) })
        end
        d.band = band.id
        band.baseId = b.id
    end
    -- everyone living there is that band now (a loner taken in, refugees)
    for _, e in pairs(b.roster or {}) do
        if type(e) == "table" and e.u then
            local before = M.bandOfUid(e.u)
            if before ~= band then
                M.bandAssign(e.u, band)
                if before and not before.dead then history(band, tostring(e.n or "Someone") .. " left " .. tostring(before.name) .. " and joined them") end
            end
        end
    end
    band.creed, band.rule, band.leader, band.baseId = d.creed, d.rule, b.leader or band.leader, b.id
    band.place = band.place or placeOf(b.x, b.y)
    return band
end

local function rename(band, why, opts)
    local old = band.name
    local new = M.bandMakeName(band, opts)
    if new ~= old then
        band.name = new
        history(band, tostring(old) .. " now call themselves " .. new .. (why and (" (" .. why .. ")") or ""))
        local b = band.baseId and M.nbOf and M.nbOf(band.baseId) or nil
        if b and M.nbEvent then pcall(M.nbEvent, b, "They started calling themselves " .. new, "rename") end
    end
end

-- once a day: bands live, change their names, split and merge
function M.bandDay()
    if M.settings.bands == false then return end
    local s = M.bandStore()
    local h = hours()
    local day = math.floor(h / 24)
    if s.day == day then return end
    s.day = day
    pcall(M.bandScan)
    -- communities first (they own their band's creed / leader / house)
    for _, b in ipairs(M.nbActive and M.nbActive() or {}) do pcall(M.bandForBase, b) end
    local live = {}
    for id, band in pairs(s.byId) do
        if not band.dead then
            local people = M.bandLiving(band)
            if #people == 0 then
                band.dead = true; band.diedH = h
                history(band, tostring(band.name) .. " are gone - nobody left")
            else
                band.n = #people
                live[#live + 1] = band
                -- a leader who died: the next one
                local lr = band.leader and rec(band.leader)
                if lr == nil or lr.lifecycle == "dead" then band.leader = tostring(people[1].uid) end
                -- the name follows what they became
                if band.creed ~= band.lastCreed then
                    if band.lastCreed ~= nil and (band.creed == "raiders" or band.creed == "faithful") then rename(band, band.creed == "raiders" and "turned raider" or "found faith") end
                    band.lastCreed = band.creed
                end
                if band.leader ~= band.lastLeader then
                    if band.lastLeader ~= nil and band.rule == "leader" and roll(id .. "#stamp" .. day) < 0.3 then rename(band, "new leader") end
                    band.lastLeader = band.leader
                end
            end
        end
    end
    -- splits: a big unhappy community loses some people to a new band
    for _, band in ipairs(live) do
        local b = band.baseId and M.nbOf and M.nbOf(band.baseId) or nil
        local owned = fn(M, "b4OwnsSplits") and M.b4OwnsSplits() == true -- Brain 4 (ALifeBrainSplit): real splits instead of a new label
        if b and not owned and (band.n or 0) >= 5 and (tonumber(b.morale) or 50) < 30 and roll(band.id .. "#split" .. day) < 0.2 then
            local people = M.bandLiving(band)
            local leaving = {}
            for _, r in ipairs(people) do if tostring(r.uid) ~= tostring(band.leader) and #leaving < 2 then leaving[#leaving + 1] = r end end
            if #leaving == 2 then
                local new = M.bandCreate(nil, band.origin, tostring(leaving[1].uid), { splinter = true, from = band.name, parent = band.id, place = band.place })
                for _, r in ipairs(leaving) do M.bandAssign(r.uid, new) end
                history(band, (firstName(leaving[1]) or "Two of them") .. " and " .. (firstName(leaving[2]) or "another") .. " walked out and started " .. new.name)
                if M.nbEvent then pcall(M.nbEvent, b, (firstName(leaving[1]) or "Two of them") .. " walked out with " .. (firstName(leaving[2]) or "another") .. " after a falling-out", "split") end
                if b.dir then b.dir.ties = b.dir.ties or {} end
            end
        end
    end
    -- merges: two small allied communities become one
    for i = 1, #live do
        for j = i + 1, #live do
            local a, c = live[i], live[j]
            local ba = a.baseId and M.nbOf and M.nbOf(a.baseId) or nil
            local bc = c.baseId and M.nbOf and M.nbOf(c.baseId) or nil
            if ba and bc and not a.dead and not c.dead and (a.n or 0) <= 3 and (c.n or 0) <= 3 and M.dirTieState and M.dirTie
                and M.dirTieState(M.dirTie(ba, bc)) == "allied" and roll(a.id .. c.id .. "#merge" .. day) < 0.15 then
                local big, small = a, c
                if (c.n or 0) > (a.n or 0) then big, small = c, a end
                for uid in pairs(small.members) do M.bandAssign(uid, big) end
                small.dead = true; small.mergedInto = big.id
                history(big, tostring(small.name) .. " joined them - one group now")
                if M.nbEvent then pcall(M.nbEvent, ba, tostring(small.name) .. " and " .. tostring(big.name) .. " joined up as one group", "merge") end
                if M.nbEvent and bc ~= ba then pcall(M.nbEvent, bc, tostring(small.name) .. " and " .. tostring(big.name) .. " joined up as one group", "merge") end
            end
        end
    end
end

-- your standing with a band: what its living people actually think of you (A-Life opinion), averaged
function M.bandGoodwill(band, player)
    local sum, n = 0, 0
    for _, r in ipairs(M.bandLiving(band)) do
        local ok, v = pcall(function() return tonumber((PA().NpcOpinion.valueOf(r, player))) end)
        if ok and v then sum, n = sum + v, n + 1 end
    end
    return n > 0 and math.floor(sum / n) or 0, n
end

----------------------------------------------------------------------------------------------------------------
-- A-Life Talk's faction politics, news, AI and the factions screen run on bands
----------------------------------------------------------------------------------------------------------------
local function install()
    if M.__bandsInstalled or type(M.activeFactions) ~= "function" then return false end
    M.__bandsInstalled = true
    local origActive, origName, origSeed, origLine, origDeath = M.activeFactions, M.factionName, M.seedTension, M.politicsLine, M.politicsDeath
    M.activeFactions = function(...)
        if M.settings.bands == false then return origActive(...) end
        local list, members = {}, {}
        for id, band in pairs(M.bandStore().byId) do
            if not band.dead then
                local people = M.bandLiving(band)
                if #people > 0 then list[#list + 1] = { id = id, n = #people }; members[id] = people end
            end
        end
        table.sort(list, function(a, b) if a.n == b.n then return a.id < b.id end return a.n > b.n end)
        while #list > 12 do table.remove(list) end
        return list, members
    end
    M.factionName = function(id, ...)
        local band = M.isBand(id) and M.bandById(id) or nil
        if band then return band.name end
        return origName(id, ...)
    end
    if type(origSeed) == "function" then
        M.seedTension = function(a, b, ...)
            local ba, bb = M.isBand(a) and M.bandById(a), M.isBand(b) and M.bandById(b)
            if ba and bb then
                local base = 0
                pcall(function() base = origSeed(tostring(ba.origin), tostring(bb.origin)) end)
                if ba.parent == bb.id or bb.parent == ba.id then base = base - 25 end -- splinters start sour
                return base
            end
            return origSeed(a, b, ...)
        end
    end
    local function viaBand(r)
        local band = r and M.bandOfUid(r.uid)
        if band == nil then return r end
        return setmetatable({ factionId = band.id }, { __index = r })
    end
    if type(origLine) == "function" then M.politicsLine = function(r, ...) return origLine(viaBand(r), ...) end end
    if type(origDeath) == "function" then
        M.politicsDeath = function(ev, ...)
            if type(ev) == "table" and ev.kind == "death" then
                local v = ev.victimUid and M.bandOfUid(ev.victimUid)
                local k = ev.killerUid and ev.killerUid ~= "player" and M.bandOfUid(ev.killerUid)
                if v and k and v ~= k then
                    local pol = M.store().politics or {}
                    pol.ev = type(pol.ev) == "table" and pol.ev or {}
                    local a, b = v.id, k.id
                    local key = a < b and (a .. "|" .. b) or (b .. "|" .. a)
                    pol.ev[key] = (tonumber(pol.ev[key]) or 0) - 12
                    return
                end
            end
            return origDeath(ev, ...)
        end
    end
    log("ready (dynamic factions)")
    return true
end

if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(install); pcall(M.bandScan) end) end
    if Events.EveryHours then ALifeHealth.add(Events.EveryHours, "ALifeLLMTalk_Bands", function() local ok, err = pcall(M.bandDay); if not ok then log("day failed: " .. tostring(err)) end end) end
end
