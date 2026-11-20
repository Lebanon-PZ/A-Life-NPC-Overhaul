-- A-Life NPC Overhaul: driving by voice, through A-Life's own driving system.
--   "get in" (you're in or by a car)         -> they board as a passenger; you drive (A-Life "Player drives" mode)
--   "get out"                                -> they climb out
--   "you drive" / "take us to Muldraugh..."  -> they take the wheel, you ride, they drive the roads there
--                                               (A-Life "NPC drives / riders" mode)
-- Needs A-Life driving on (sandbox ALifeDriving.Enabled). Terrain must be loaded, so very long trips
-- may stop short; if anything fails they say so plainly and the console says why (A-Life's own reason).
--
-- 0.7.0.8: A-Life 1.5 only takes passenger orders when the car is in "Player drives" mode, and its calls never
-- throw: they refuse with a message. We used to fire the order on a car in the default mode, it was refused
-- ("This car is not in Player drives mode."), and the NPC still said "Alright, I'm in." Now every step is
-- checked against A-Life's own state, mode first, and the NPC only says yes when A-Life said yes.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeDriveOrders") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeDrive]"
ALifeDriveOrders = ALifeDriveOrders or {}
local D = ALifeDriveOrders
D.KMH = 40
D.NEAR_CAR = 6
D.JOB_MS = 120000          -- a drive order gives up after 2 minutes of waiting
D.STEP_MS = 500            -- the drive job looks again every half second
D.jobs = D.jobs or {}      -- car id -> drive job

local function C() return ProjectALife and ProjectALife.DrivingDemoClient end
local function U() return ProjectALife and ProjectALife.DrivingCarMode end
local function Q() return ProjectALife and ProjectALife.DrivingPassengers end
local function enabled()
    local sv = SandboxVars and SandboxVars.ALifeDriving
    return C() ~= nil and U() ~= nil and not (sv and sv.Enabled == false)
end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function status() local c = C(); return tostring(c and c.status or "no reason given") end

function D.spec(shell)
    local ok, md = pcall(function() return shell:getModData() end)
    if not ok or md == nil or md.ProjectALifeUID == nil then return nil end
    return { uid = md.ProjectALifeUID, generation = md.ProjectALifeGeneration }
end

-- the car: the one you're in, else the closest within a few tiles
function D.car(player)
    local ok, v = pcall(function() return player:getVehicle() end)
    if ok and v ~= nil then return v end
    local best, bd = nil, D.NEAR_CAR ^ 2
    pcall(function()
        local coll = getCell():getVehicles()
        local function visit(c)
            local d = (c:getX() - player:getX()) ^ 2 + (c:getY() - player:getY()) ^ 2
            if d <= bd then best, bd = c, d end
        end
        local ok2 = pcall(function() local it = coll:iterator(); while it:hasNext() do visit(it:next()) end end)
        if not ok2 then for i = 0, coll:size() - 1 do visit(coll:get(i)) end end
    end)
    return best
end

-- up to 20 road points ending with a dismount at the spot
function D.route(player, spot)
    local G = ProjectALife and ProjectALife.RoadGraph
    local pts = {}
    if G ~= nil and type(G.nearest) == "function" and type(G.route) == "function" then
        local a, b = G.nearest(player:getX(), player:getY()), G.nearest(spot.x, spot.y)
        local ids = (a and b) and G.route(a, b) or nil
        if type(ids) == "table" and #ids > 0 then
            local n = math.min(19, #ids)
            for i = 1, n do
                local node = G.nodes[ids[math.max(1, math.floor(i * #ids / n))]]
                if type(node) == "table" and node.x then pts[#pts + 1] = { x = node.x, y = node.y, kind = "drive" } end
            end
        end
    end
    pts[#pts + 1] = { x = spot.x, y = spot.y, kind = "dismount" }
    return pts
end

D.LINES = {
    off = { "I don't drive. Not these days.", "Not happening. I'm on foot." },
    nocar = { "Get in what? There's no car here.", "What car?" },
    no = { "No. I'm not getting in a car with you.", "I don't know you well enough for that." },
    fail = { "It won't work. Something's wrong.", "Can't. Not right now." },
    getin = { "Alright, I'm in.", "Scoot over.", "Fine. Drive careful." },
    already = { "I'm already in.", "I'm sitting right here." },
    full = { "There's no room in there.", "No seat left for me." },
    moving = { "Stop the car first.", "Not while it's moving." },
    getout = { "Okay, I'm out.", "Getting out." },
    notin = { "I'm not in the car.", "I'm already out." },
    drive = { "%s. Buckle up.", "%s? Alright, I've got the wheel.", "Hold on. %s it is." },
    wheel = { "Get out of the driver's seat first.", "You're in my seat. Slide over." },
    noplace = { "Drive where?", "Where am I taking us?" },
}

local function trusts(record, shell, player, text)
    local RC = ALifeRecruit
    if RC == nil or type(RC.weigh) ~= "function" then return true end
    local ok, _, _, no = pcall(RC.weigh, record, shell, player, text, "meet")
    return not (ok and no ~= nil)
end

----------------------------------------------------------------------------------------------------------------
-- A-Life state, read only
----------------------------------------------------------------------------------------------------------------
local function binding(id) local c = C(); return c and c.bindings and c.bindings[id] or nil end
local function crewSpec(id, spec)
    local b = binding(id)
    for _, s in ipairs(b and b.crew or {}) do
        if s.uid == spec.uid and s.generation == spec.generation then return s end
    end
    return nil
end
local function modeOf(id) local u = U(); return u and u.get(id) or "npc" end
local function modePending(id) local c = C(); return c and c.modeRequests and c.modeRequests[id] ~= nil or false end
local function speedOf(car)
    local Dm = ProjectALife and ProjectALife.DrivingDemo
    local ok, s = pcall(function() return Dm.speed(car) end)
    return ok and tonumber(s) or 0
end
-- the car this NPC is attached to, other than `except`
local function attachedElsewhere(spec, except)
    local c = C()
    for id, b in pairs(c and c.bindings or {}) do
        if id ~= except then
            for _, s in ipairs(b.crew or {}) do if s.uid == spec.uid then return id end end
        end
    end
    return nil
end
local function inCar(shell, car)
    local v
    pcall(function() v = shell:getVehicle() end)
    return v ~= nil and (car == nil or v == car)
end

-- attach this NPC to the car, keeping whoever is already attached (attachCrew replaces the whole crew)
local function attach(id, spec)
    local c = C()
    if crewSpec(id, spec) then return true end
    local other = attachedElsewhere(spec, id)
    if other ~= nil and not c.sessions[other] then pcall(c.detachNpc, other, spec.uid, spec.generation) end
    local list = {}
    local b = binding(id)
    for _, s in ipairs(b and b.crew or {}) do list[#list + 1] = { uid = s.uid, generation = s.generation } end
    list[#list + 1] = { uid = spec.uid, generation = spec.generation }
    local okA, errA = pcall(c.attachCrew, id, list)
    if not okA then print(TAG .. " attachCrew threw: " .. tostring(errA)) end
    return crewSpec(id, spec) ~= nil
end

----------------------------------------------------------------------------------------------------------------
-- get in (you drive) / get out
----------------------------------------------------------------------------------------------------------------
function D.boardPassenger(car, shell, spec)
    local c, u = C(), U()
    local id = car:getId()
    if inCar(shell, car) then return "already" end
    if speedOf(car) > 0.15 then return "moving" end
    -- 1. the car must be in "Player drives" mode (the driver seat is yours, NPCs take passenger seats)
    if not u.player(id) then
        if c.sessions[id] or modePending(id) then
            print(TAG .. " get in refused: car " .. id .. " is busy with an NPC drive or a mode change (" .. status() .. ")")
            return "fail"
        end
        pcall(c.setCarMode, id, "player")
        if not u.player(id) then print(TAG .. " get in: could not set Player drives on car " .. id .. ": " .. status()) return "fail" end
    end
    -- 2. attached as a passenger (seat 1+)
    if not attach(id, spec) then
        print(TAG .. " get in: A-Life would not attach " .. tostring(spec.uid) .. " to car " .. id .. ": " .. status())
        local st = status()
        if string.find(st, "No free passenger seat") or string.find(st, "Not enough") then return "full" end
        return "fail"
    end
    -- 3. board; A-Life walks them to their door and seats them
    pcall(c.passengerOrder, id, "board", spec.uid, spec.generation)
    local s = crewSpec(id, spec)
    local phase = s and s.passengerPhase
    if phase == "approach" or phase == "seated" then
        print(TAG .. " " .. tostring(spec.uid) .. " boarding car " .. id .. " as a passenger (seat " .. tostring(s.seat) .. ")")
        return "getin"
    end
    print(TAG .. " get in: board order refused for car " .. id .. ": " .. status())
    return "fail"
end

function D.leave(car, shell, spec)
    local c, u = C(), U()
    local id = car:getId()
    if not inCar(shell, car) and not (crewSpec(id, spec) and crewSpec(id, spec).passengerPhase == "approach") then return "notin" end
    c.status = nil -- A-Life's calls never throw: a refusal only shows up as a message, so clear it and read it back
    local mode = u.player(id) and "player" or "other"
    local before = crewSpec(id, spec) and crewSpec(id, spec).passengerPhase
    if mode == "player" then
        pcall(c.passengerOrder, id, "exit", spec.uid, spec.generation)
    else
        pcall(c.getOut, id)
    end
    local s = crewSpec(id, spec)
    local took = (s ~= nil and s.passengerPhase ~= before and (s.passengerPhase == "exit_pending" or s.passengerPhase == "outside" or s.passengerPhase == "walkaway"))
        or (c.sessions ~= nil and c.sessions[id] ~= nil and c.sessions[id].exitRequested == true)
    print(TAG .. " " .. tostring(spec.uid) .. " told to get out of car " .. id .. " mode=" .. mode .. " phase=" .. tostring(before) ..
        "->" .. tostring(s and s.passengerPhase) .. " took=" .. tostring(took) .. " (" .. status() .. ")")
    if not took then return "fail" end -- 0.9.x pre-1.0: never "Okay, I'm out" when A-Life ignored it
    return "getout"
end

----------------------------------------------------------------------------------------------------------------
-- you drive: a short job, because A-Life mode changes take a few ticks
--   exit  : seated as your passenger? climb out first (Player drives -> NPC mode waits for that)
--   mode  : "NPC drives / riders" (so you can ride; plain "npc" mode bars players from getting in)
--   crew  : attached as the driver (seat 0)
--   ride  : you get in a passenger seat (A-Life's ride walks you there)
--   go    : startDrive; A-Life boards the driver itself if needed, then drives the route
----------------------------------------------------------------------------------------------------------------
function D.startJob(car, spec, route, player)
    local id = car:getId()
    D.jobs[id] = { car = car, spec = spec, route = route, player = player, stage = "exit",
        untilMs = nowMs() + D.JOB_MS, nextMs = 0, asked = {} }
    print(TAG .. " drive job for car " .. id .. " started (" .. #route .. " route points)")
end

local function finishJob(id, why)
    local j = D.jobs[id]
    D.jobs[id] = nil
    if j and why then print(TAG .. " drive job for car " .. id .. ": " .. why) end
end

-- one step of one job; returns nothing, moves job.stage on
function D.step(id, j, now)
    local c, u = C(), U()
    local car, spec = j.car, j.spec
    local seatedMe = crewSpec(id, spec)
    if j.stage == "exit" then
        if u.player(id) and seatedMe and seatedMe.passengerPhase and seatedMe.passengerPhase ~= "outside" then
            if not j.asked.exit then j.asked.exit = true; pcall(c.passengerOrder, id, "exit", spec.uid, spec.generation) end
            return
        end
        j.stage = "mode"
    end
    if j.stage == "mode" then
        if modePending(id) then return end
        if modeOf(id) ~= "mixed" then
            if (j.asked.mode or 0) > 3 then finishJob(id, "A-Life would not switch the car to NPC drives / riders: " .. status()) return end
            j.asked.mode = (j.asked.mode or 0) + 1
            pcall(c.setCarMode, id, "mixed")
            return
        end
        j.stage = "crew"
    end
    -- a switch back from Player drives leaves A-Life's own "reboard" request open until the driver sits down;
    -- startDrive refuses while any mode request is open, so wait it out
    if modePending(id) then return end
    if j.stage == "crew" then
        if not crewSpec(id, spec) then
            if j.asked.crew then finishJob(id, "A-Life would not attach the driver: " .. status()) return end
            j.asked.crew = true
            attach(id, spec)
            return
        end
        j.stage = "ride"
    end
    if j.stage == "ride" then
        local p = j.player
        local mine
        pcall(function() mine = p:getVehicle() end)
        if mine == nil then
            if now >= (j.asked.rideMs or 0) then j.asked.rideMs = now + 4000; pcall(c.ride, id) end
            return
        end
        if mine ~= car then finishJob(id, "you got into a different car") return end
        j.stage = "go"
    end
    if j.stage == "go" then
        pcall(c.startDrive, id, j.route, D.KMH)
        local started = (c.departures and c.departures[id] ~= nil) or c.sessions[id] ~= nil
        finishJob(id, started and "driving (A-Life: " .. status() .. ")" or "A-Life refused the drive: " .. status())
    end
end

----------------------------------------------------------------------------------------------------------------
-- 0.7.1 PARTY RIDES: you get in a car, your party gets in with you (real seats, A-Life walks them to the doors);
-- you get out, they get out. Only people close enough to see you get in (PARTY_TILES). No seat left: they wait
-- outside the old way (the companion code brings them along when you stop). In someone else's car (an NPC is
-- driving it) they don't board: that's the driver's call.
----------------------------------------------------------------------------------------------------------------
D.PARTY_TILES = 25
D.partyCar = nil           -- the car you're in, as last seen
D.partyNextMs = 0

-- this NPC's A-Life passenger phase on any car: phase, car id (nil when not attached anywhere)
function D.passengerPhase(uid)
    local c = C()
    for id, b in pairs(c and c.bindings or {}) do
        for _, s in ipairs(b.crew or {}) do
            if s.uid == uid then return s.passengerPhase, id end
        end
    end
    return nil
end
-- in the crew of a car A-Life is driving (an NPC at the wheel, e.g. the second car): car id
function D.npcCrewCar(uid)
    local c = C()
    for id, b in pairs(c and c.bindings or {}) do
        if c.sessions[id] ~= nil then
            for _, s in ipairs(b.crew or {}) do if s.uid == uid then return id end end
        end
    end
    return nil
end
-- true while A-Life is boarding, carrying or unloading this NPC: leave them to A-Life
function D.aLifeHasThem(uid)
    if not enabled() then return false end
    local phase = D.passengerPhase(uid)
    if phase ~= nil and phase ~= "outside" then return true end
    return D.npcCrewCar(uid) ~= nil
end

local function partyOf(player)
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.partyMembers) == "function" then
        local ok, list = pcall(M.partyMembers, player)
        if ok and type(list) == "table" then
            -- 0.7.3: A-Life companions board and leave your car through A-Life's own code (two boarders would fight)
            local L = ALifeCompanionLink
            if type(L) == "table" and type(L.boardsSelf) == "function" then
                local out = {}
                for _, uid in ipairs(list) do
                    local okB, self = pcall(L.boardsSelf, uid)
                    if not (okB and self) then out[#out + 1] = uid end
                end
                return out
            end
            return list
        end
    end
    local P = ALifeTalkPatch
    local out = {}
    if type(P) == "table" and type(P.store) == "function" then
        local ok, d = pcall(P.store)
        if ok and type(d) == "table" then for uid in pairs(d.companions or {}) do out[#out + 1] = uid end end
    end
    return out
end
local function partyRidesOn()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.partyRides == false)
end

function D.partyBoard(player, car)
    local c = C()
    local id = car:getId()
    if c.sessions[id] then print(TAG .. " party: car " .. id .. " has an NPC driver; your party waits outside") return end
    local Talk = ProjectALife and ProjectALife.Talk
    if Talk == nil or type(Talk.shellFor) ~= "function" then return end
    local px, py = player:getX(), player:getY()
    local boarded, left = 0, {}
    for _, uid in ipairs(partyOf(player)) do
        local shell = Talk.shellFor(uid)
        local ok, near = pcall(function() return (shell:getX() - px) ^ 2 + (shell:getY() - py) ^ 2 <= D.PARTY_TILES ^ 2 end)
        local spec = ok and near and D.spec(shell) or nil
        -- already riding in the second car: they stay with it
        if spec ~= nil and D.npcCrewCar(spec.uid) == nil then
            local res = D.boardPassenger(car, shell, spec)
            if res == "getin" or res == "already" then boarded = boarded + 1
            elseif res == "full" then left[#left + 1] = { shell = shell, spec = spec } end
        end
    end
    if boarded + #left > 0 then print(TAG .. " party: " .. boarded .. " getting in car " .. id .. (#left > 0 and (", " .. #left .. " no seat") or "")) end
    if #left > 0 then
        local ok, err = pcall(D.secondCar, player, car, left)
        if not ok then print(TAG .. " second car failed: " .. tostring(err)) end
    elseif D.convoy and C().sessions[D.convoy.id] then
        D.convoy.lead, D.convoy.state = car, "follow"      -- back in a car: the second car keeps following
    end
end

----------------------------------------------------------------------------------------------------------------
-- 0.7.2 SECOND CAR: not enough seats and a car nearby -> whoever has no seat takes it; the first of them drives,
-- the rest ride with them, and they follow your car down the road you actually took (breadcrumbs every ~12
-- tiles, handed to A-Life's own NPC driving as waypoints). You get out: they pull up behind you and get out.
-- Their car won't start, or none is close: they wait outside as before and catch up when you stop.
----------------------------------------------------------------------------------------------------------------
D.SECOND_TILES = 20        -- how far from them a car may be
D.CRUMB_TILES = 12         -- breadcrumb spacing
D.CONVOY_KMH = 45
D.CONVOY_MS = 1000
D.ARRIVE_MS = 90000
D.convoy = nil             -- { id, car, lead, crumbs = {}, lastX, lastY, state, nextMs, fails, untilMs }
D.LINES.second = { "We'll take this one. Right behind you.", "Not enough room. We'll follow.", "I'll drive this one. Go." }
D.LINES.nostart = { "It won't start. We'll catch up.", "This thing's dead. Go, we'll walk." }

local function secondCarOn()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.partySecondCar == false)
end
local function partNumber(v, part, getter)
    local n = 0
    pcall(function() local p = v:getPartById(part); if p then n = tonumber(p[getter](p)) or 0 end end)
    return n
end
-- an empty, upright car that might run: engine, some gas, driver seat, nobody in it, not anyone's crew car
local function usable(v, playerCar)
    if v == playerCar then return false end
    local ok, fine = pcall(function()
        if v:getZ() ~= 0 or not v:isSeatInstalled(0) then return false end
        if v:getVehicleTowing() or v:getVehicleTowedBy() then return false end
        for s = 0, v:getMaxPassengers() - 1 do if v:getCharacter(s) then return false end end
        return true
    end)
    if not ok or not fine then return false end
    local b = binding(v:getId())
    if b and #(b.crew or {}) > 0 then return false end
    if C().sessions[v:getId()] then return false end
    return partNumber(v, "Engine", "getCondition") > 0 and partNumber(v, "GasTank", "getContainerContentAmount") > 0
end
local function seatsIn(v)
    local n = 0
    pcall(function() for s = 0, v:getMaxPassengers() - 1 do if v:isSeatInstalled(s) then n = n + 1 end end end)
    return n
end

function D.secondCar(player, playerCar, left)
    if not secondCarOn() then return end
    local c = C()
    if D.convoy and c.sessions[D.convoy.id] then
        print(TAG .. " second car: already have one (car " .. D.convoy.id .. "); " .. #left .. " wait outside")
        return
    end
    local lx, ly = left[1].shell:getX(), left[1].shell:getY()
    local cands = {}
    pcall(function()
        local coll = getCell():getVehicles()
        local function visit(v)
            local d = (v:getX() - lx) ^ 2 + (v:getY() - ly) ^ 2
            if d <= D.SECOND_TILES ^ 2 and usable(v, playerCar) then cands[#cands + 1] = { v = v, d = d } end
        end
        local ok = pcall(function() local it = coll:iterator(); while it:hasNext() do visit(it:next()) end end)
        if not ok then for i = 0, coll:size() - 1 do visit(coll:get(i)) end end
    end)
    table.sort(cands, function(a, b) return a.d < b.d end)
    for i = 1, math.min(3, #cands) do
        local v = cands[i].v
        local id = v:getId()
        local list = {}
        for k = 1, math.min(seatsIn(v), #left) do list[#list + 1] = { uid = left[k].spec.uid, generation = left[k].spec.generation } end
        if modeOf(id) ~= "npc" and not modePending(id) then pcall(c.setCarMode, id, "npc") end
        pcall(c.attachCrew, id, list)
        local b = binding(id)
        if b and #(b.crew or {}) == #list then
            pcall(c.getIn, id)
            if c.sessions[id] ~= nil then
                D.convoy = { id = id, car = v, lead = playerCar, crumbs = {}, lastX = playerCar:getX(), lastY = playerCar:getY(),
                    state = "follow", nextMs = 0, fails = 0 }
                print(TAG .. " second car: " .. #list .. " taking car " .. id .. " (" .. tostring(v:getScriptName()) .. "), "
                    .. tostring(list[1].uid) .. " driving" .. (#left > #list and (", " .. (#left - #list) .. " still no seat") or ""))
                pcall(ProjectALife.Speech.say, left[1].shell, pick(D.LINES.second), { face = player })
                return true
            end
            print(TAG .. " second car: car " .. id .. " refused boarding: " .. status())
            pcall(c.detachCrew, id)
        else
            print(TAG .. " second car: car " .. id .. " refused the crew: " .. status())
        end
    end
    if #cands == 0 then print(TAG .. " second car: no usable car within " .. D.SECOND_TILES .. " tiles; " .. #left .. " wait outside") end
end

local function endConvoy(why)
    if D.convoy then print(TAG .. " second car " .. D.convoy.id .. ": " .. why) end
    D.convoy = nil
end

-- hand new waypoints to the follower: start a trip when parked, extend it while driving
local function feed(cv, s, pts)
    local c = C()
    if #pts == 0 then return true end
    if s.phase == "seated" and not c.departures[cv.id] and not c.pending[cv.id] then
        pcall(c.startDrive, cv.id, pts, D.CONVOY_KMH)
        if s.phase == "seated" and not c.departures[cv.id] then
            cv.fails = cv.fails + 1
            print(TAG .. " second car " .. cv.id .. ": drive refused (" .. cv.fails .. "): " .. status())
            return false
        end
        cv.fails = 0
        return true
    end
    if s.phase == "driving" and not s.appendPending and type(s.route) == "table" and #s.route + #pts <= 20 then
        local F = ProjectALife.DrivingFleet
        pcall(F.focus, c, s, c.appendRoute, pts)
        return true
    end
    return false
end

function D.convoyTick(player, now)
    local cv = D.convoy
    if cv == nil or now < cv.nextMs then return end
    cv.nextMs = now + D.CONVOY_MS
    local c = C()
    local s = c.sessions[cv.id]
    if s == nil then endConvoy("crew got out; done") return end
    if cv.fails >= 3 then
        pcall(c.getOut, cv.id)
        local Talk = ProjectALife.Talk
        local b = binding(cv.id)
        local first = b and b.crew and b.crew[1]
        local shell = first and Talk and Talk.shellFor and Talk.shellFor(first.uid)
        if shell then pcall(ProjectALife.Speech.say, shell, pick(D.LINES.nostart), { face = player }) end
        endConvoy("won't drive; crew getting out to walk")
        return
    end
    local lead
    pcall(function() lead = player:getVehicle() end)
    if cv.state == "follow" then
        if lead == nil then
            -- you got out: pull up a few tiles short of where you stopped, then get out
            local bx, by = cv.lastX, cv.lastY
            local px, py = player:getX(), player:getY()
            local dx, dy = bx - px, by - py
            local d = math.sqrt(dx * dx + dy * dy)
            local tx, ty = px, py
            if d >= 1 then tx, ty = px + dx / d * math.min(6, d), py + dy / d * math.min(6, d) end
            cv.crumbs[#cv.crumbs + 1] = { x = tx, y = ty, kind = "dismount" }
            cv.state, cv.untilMs = "arrive", now + D.ARRIVE_MS
        else
            cv.lead = lead
            local lx, ly = lead:getX(), lead:getY()
            if (lx - cv.lastX) ^ 2 + (ly - cv.lastY) ^ 2 >= D.CRUMB_TILES ^ 2 then
                cv.crumbs[#cv.crumbs + 1] = { x = lx, y = ly, kind = "drive" }
                cv.lastX, cv.lastY = lx, ly
            end
        end
    elseif cv.state == "arrive" then
        if lead ~= nil then cv.state = "follow"    -- you got back in before they arrived: keep following
        elseif now > cv.untilMs then pcall(c.getOut, cv.id); endConvoy("couldn't reach you; crew getting out") return end
    end
    if #cv.crumbs == 0 then return end
    -- drop crumbs the follower is already on top of (A-Life wants waypoints at least a tile apart)
    local vx, vy = cv.car:getX(), cv.car:getY()
    while #cv.crumbs > 0 and (cv.crumbs[1].x - vx) ^ 2 + (cv.crumbs[1].y - vy) ^ 2 < 16 and cv.crumbs[1].kind ~= "dismount" do
        table.remove(cv.crumbs, 1)
    end
    if #cv.crumbs == 0 then return end
    local room = 20 - ((s.phase == "driving" and type(s.route) == "table") and #s.route or 0)
    if room <= 0 then return end
    local pts = {}
    for i = 1, math.min(room, #cv.crumbs) do pts[i] = cv.crumbs[i] end
    if feed(cv, s, pts) then
        for _ = 1, #pts do table.remove(cv.crumbs, 1) end
    end
end

function D.partyLeave(player, car)
    local c, u = C(), U()
    local id = car:getId()
    if not u.player(id) then return end
    local mine = {}
    for _, uid in ipairs(partyOf(player)) do mine[tostring(uid)] = true end
    local b = binding(id)
    local n = 0
    for _, s in ipairs(b and b.crew or {}) do
        if mine[tostring(s.uid)] and (s.passengerPhase == "seated" or s.passengerPhase == "approach") then
            pcall(c.passengerOrder, id, "exit", s.uid, s.generation); n = n + 1
        end
    end
    if n > 0 then print(TAG .. " party: " .. n .. " getting out of car " .. id) end
end

function D.partyTick(player, now)
    if now < D.partyNextMs then return end
    D.partyNextMs = now + D.STEP_MS
    local car
    pcall(function() car = player:getVehicle() end)
    local last = D.partyCar
    if car == last then return end
    D.partyCar = car
    if not enabled() or not partyRidesOn() then return end
    if last ~= nil then pcall(D.partyLeave, player, last) end
    if car ~= nil then
        local ok, err = pcall(D.partyBoard, player, car)
        if not ok then print(TAG .. " party board failed: " .. tostring(err)) end
    end
end

function D.tick()
    local player = ALifeSide.campPlayer()
    if player ~= nil then
        D.partyTick(player, nowMs())
        if D.convoy ~= nil then
            local ok, err = pcall(D.convoyTick, player, nowMs())
            if not ok then print(TAG .. " second car tick failed: " .. tostring(err)); D.convoy = nil end
        end
    end
    local any = false
    for _ in pairs(D.jobs) do any = true; break end -- 0.7.11.1: PZ's Kahlua has no next()
    if not any then return end
    local now = nowMs()
    for id, j in pairs(D.jobs) do
        if now >= j.nextMs then
            j.nextMs = now + D.STEP_MS
            if now > j.untilMs then
                finishJob(id, "gave up waiting at step '" .. tostring(j.stage) .. "' (" .. status() .. ")")
            else
                local ok, err = pcall(D.step, id, j, now)
                if not ok then finishJob(id, "step failed: " .. tostring(err)) end
            end
        end
    end
end

function D.drive(car, shell, spec, player, text, record)
    local id = car:getId()
    local town = ALifeTravel and ALifeTravel.townIn(text)
    if town == nil then return pick(D.LINES.noplace) end
    local driverSeat
    pcall(function() driverSeat = car:getCharacter(0) end)
    if driverSeat ~= nil and driverSeat == player then return pick(D.LINES.wheel) end
    if speedOf(car) > 0.15 and not inCar(shell, car) then return pick(D.LINES.moving) end
    local spot = ALifeTravel.spot(town, ALifeTravel.placesIn(text)) or { x = town.x, y = town.y, what = town.label }
    D.startJob(car, spec, D.route(player, spot), player)
    if ALifeMemory ~= nil then pcall(ALifeMemory.add, record, "you drove the stranger to " .. tostring(spot.what)) end
    local w = tostring(spot.what)
    return string.format(pick(D.LINES.drive), string.upper(string.sub(w, 1, 1)) .. string.sub(w, 2))
end

----------------------------------------------------------------------------------------------------------------
function D.ask(kind, record, shell, player, text)
    if not enabled() then return pick(D.LINES.off) end
    local spec = D.spec(shell)
    local car = D.car(player)
    if car == nil then return pick(D.LINES.nocar) end
    if spec == nil then return pick(D.LINES.fail) end
    if kind == "out" then return pick(D.LINES[D.leave(car, shell, spec)]) end
    if not trusts(record, shell, player, text) then return pick(D.LINES.no) end
    if kind == "in" then return pick(D.LINES[D.boardPassenger(car, shell, spec)] or D.LINES.fail) end
    return D.drive(car, shell, spec, player, text, record)
end

function D.install()
    if D.__installed then return true end
    local Data, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.Talk
    if Data == nil or Talk == nil then return false end
    D.__installed = true
    pcall(Data.intent, "DRIVE_TO", 92, "you drive|drive us to|drive me to|take us to|take me to|you take the wheel|drive us|get us to")
    pcall(Data.intent, "DRIVE_GET_IN", 88, "get in|get in the car|hop in|jump in|get in the truck")
    pcall(Data.intent, "DRIVE_GET_OUT", 88, "get out|get out of the car|hop out|out of the truck|exit the car|exit the truck|exit the vehicle|leave the car|leave the truck|climb out|step out of the car|get out of the vehicle|get out of the truck|out of the car|get off the car")
    -- A-Life's TalkSocial counts an uncategorised intent as "info": asking again inside the cooldown = "repeat", then
    -- "annoyed", then standing drops. Get in / get out / drive are orders tied to where the car is, not questions.
    local rows = ProjectALife.TalkSocialRows
    if rows ~= nil and type(rows.put) == "function" then pcall(rows.put, "order", "DRIVE_TO DRIVE_GET_IN DRIVE_GET_OUT") end
    local function h(kind)
        return function(record, shell, player, context, now, text)
            local ok, line = pcall(D.ask, kind, record, shell, player, text or "")
            if not ok then print(TAG .. " failed: " .. tostring(line)) return nil end
            if line and ProjectALife.Speech.say(shell, line, { face = player }) then return line, "answered" end
            return nil
        end
    end
    Talk.choiceHandlers.DRIVE_TO, Talk.choiceHandlers.DRIVE_GET_IN, Talk.choiceHandlers.DRIVE_GET_OUT = h("drive"), h("in"), h("out")
    if ProjectALife.TalkIntents then ProjectALife.TalkIntents.cache = {} end
    print(TAG .. " ready v0.7.11 (party rides, second car; get in: Player drives mode; drive: NPC drives / riders; checked against A-Life)")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(D.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
if Events ~= nil and Events.OnTick ~= nil and ALifeHealth ~= nil then
    ALifeHealth.add(Events.OnTick, "ALifeDrive", function()
        local ok, err = pcall(D.tick)
        if not ok then print(TAG .. " tick failed: " .. tostring(err)); D.jobs = {} end
    end)
end
print(TAG .. " loaded")
