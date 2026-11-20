-- A-Life NPC Overhaul: "come pick me up" (in person or over the walkie).
-- No spawned cars: they use a real car the game has seen near them (every loaded car is written down,
-- with its parts and fuel). If none runs within ~300 tiles of them, they say so.
-- The drive itself is faked (the far world doesn't simulate): they go quiet for walk + drive time,
--   you hear an engine a few minutes out, then they pull up near you in a car and wait with the engine running.
-- Get in and say "take us to <place>" (ALifeDriveOrders) or drive it yourself.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifePickup") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifePickup]"
ALifePickup = ALifePickup or {}
local P = ALifePickup
P.MIN_MIN, P.MAX_MIN = 15, 120
P.NEAR = 40       -- within this many tiles (A-Life's own attach radius) they just walk over and get in
P.pending = nil   -- { uid, dueH, warnH, warned }

-- 42.21: these collections may not answer :get(i); walk the iterator first
local function eachOf(coll, fn)
    if coll == nil then return end
    local ok = pcall(function()
        local it = coll:iterator()
        while it:hasNext() do fn(it:next()) end
    end)
    if ok then return end
    pcall(function() for i = 0, coll:size() - 1 do fn(coll:get(i)) end end)
end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end

P.LINES = {
    yes = { "Copy. Find somewhere safe, I'm on my way.", "Alright. Give me a bit, I'll find wheels.", "On it. Stay put and stay quiet." },
    no = { "You want me to drive out to you? No.", "Not a chance. Find your own ride." },
    busy = { "I'm already on my way. Sit tight.", "I heard you the first time. Coming." },
    off = { "I don't drive these days.", "Can't help you there." },
    nocar = { "Nothing runs out here. I'd be walking.", "There's no car near me that'll start. Sorry.", "I've got no wheels. You're on your own." },
    close = { "I'm right here. Where's the car?", "Pick you up? I'm standing next to you." },
    here = { "Get in. Let's go.", "Your ride's here. Move.", "Get in before something hears us." },
}

-- where they are: loaded shell, else their squad position
local function whereOf(record, shell)
    local ok, x, y = pcall(function() return shell:getX(), shell:getY() end)
    if ok and x then return x, y end
    local m = type(record.memory) == "table" and record.memory or {}
    local L = ProjectALife and ProjectALife.SquadLedger
    local q = L and m.squadId and L.read(m.squadId)
    if q then return q.x, q.y end
    return nil
end

function P.ask(record, shell, player)
    local sv = SandboxVars and SandboxVars.ALifeDriving
    if sv and sv.Enabled == false then return pick(P.LINES.off) end
    if P.pending then return pick(P.LINES.busy) end
    local RC = ALifeRecruit
    if RC and type(RC.weigh) == "function" then
        local ok, _, _, no = pcall(RC.weigh, record, shell, player, "come pick me up", "meet")
        if ok and no ~= nil then return pick(P.LINES.no) end
    end
    local x, y = whereOf(record, shell)
    if x == nil then return pick(P.LINES.nocar) end
    -- 0.7.0.8: standing right next to you, "come in the car" means get in, not drive out and fetch you
    local near = false
    pcall(function() near = shell ~= nil and (x - player:getX()) ^ 2 + (y - player:getY()) ^ 2 <= P.NEAR ^ 2 end)
    if near then
        local D = ALifeDriveOrders
        if D and D.car(player) ~= nil then
            print(TAG .. " " .. tostring(record.uid) .. " is right here: treated as get in")
            return D.ask("in", record, shell, player, "get in")
        end
        return pick(P.LINES.close)
    end
    local snap, key, walk = P.carFor(x, y)
    if snap == nil then return pick(P.LINES.nocar) end
    local tiles = math.sqrt((snap.x - player:getX()) ^ 2 + (snap.y - player:getY()) ^ 2)
    -- walk to the car, get it going, then ~40 km/h on bad roads
    local mins = math.max(P.MIN_MIN, math.min(P.MAX_MIN, 5 + walk / 6 + tiles / 20))
    local h = hours()
    P.pending = { uid = record.uid, carKey = key, fuelUsed = tiles / 400,
        dueH = h + mins / 60, warnH = h + math.max(0, mins - 4) / 60 }
    if ALifeMemory then pcall(ALifeMemory.add, record, "the stranger asked you to come pick them up") end
    print(string.format("%s %s coming, %d min", TAG, tostring(record.uid), math.floor(mins)))
    return pick(P.LINES.yes)
end

-- a road tile 10-25 tiles from the player, not inside
local function roadSquare(player)
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    for _ = 1, 60 do
        local a = roll(360) * math.pi / 180
        local r = 10 + roll(16)
        local sq = getCell():getGridSquare(px + math.floor(math.cos(a) * r), py + math.floor(math.sin(a) * r), 0)
        if sq and sq:isOutside() and sq:isFree(false) and sq:getVehicleContainer() == nil then
            local f = sq:getFloor()
            local name = f and f:getSprite() and f:getSprite():getName() or ""
            if string.find(name, "street") or string.find(name, "road") then return sq end
        end
    end
    return nil
end

-- KNOWN CARS: every car the game loads gets written down (where, what, state), so a far-away NPC can only
-- use a car that really exists there. Saved in ModData.
local function cars()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeChatPlus.Cars") or {}
    s.list, s.taken = s.list or {}, s.taken or {}
    return s
end
local function keyAt(x, y) return math.floor(x / 4) .. "," .. math.floor(y / 4) end

function P.snapshot(v)
    local snap = { script = v:getScriptName(), skin = v:getSkinIndex(), x = v:getX(), y = v:getY(), parts = {} }
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        snap.parts[part:getId()] = { c = part:getCondition(), a = part:isContainer() and part:getContainerContentAmount() or nil }
    end
    local bat = v:getPartById("Battery")
    local item = bat and bat:getInventoryItem()
    snap.battery = item and item.getCurrentUsesFloat and item:getCurrentUsesFloat() or 0
    return snap
end

function P.runs(snap)
    local p = snap.parts or {}
    local eng, gas = p.Engine and p.Engine.c or 0, p.GasTank and p.GasTank.a or 0
    return eng >= 25 and gas >= 3 and (snap.battery or 0) >= 0.2
end

-- 0.8.4: an NPC group in A-Life's car life (ALifeRealCars) may have taken a car we wrote down. A car someone is
-- taking or driving is not up for grabs, and a written-down car whose spot is loaded but empty is gone.
local function inUse(v)
    local busy = false
    pcall(function()
        if v:hasModData() then
            local d = v:getModData()
            busy = d.ProjectALifeCarLife ~= nil or d.ProjectALifeCarOffline ~= nil
        end
    end)
    return busy
end
local function spotLoaded(x, y)
    local sq = nil
    pcall(function() sq = getCell():getGridSquare(math.floor(x), math.floor(y), 0) end)
    return sq ~= nil
end
function P.scan()
    local s = cars()
    local seen = {}
    eachOf(getCell():getVehicles(), function(v)
        local k = keyAt(v:getX(), v:getY())
        if s.taken[k] then
            -- this car was driven off by an NPC while you weren't here: it's gone
            pcall(function() v:permanentlyRemove() end)
            s.taken[k] = nil
        elseif v:getDriver() == nil and not inUse(v) then
            local ok, snap = pcall(P.snapshot, v)
            if ok then s.list[k] = snap; seen[k] = true end
        end
    end)
    local gone = {}
    for k, snap in pairs(s.list) do
        if not seen[k] and type(snap) == "table" and spotLoaded(snap.x or 0, snap.y or 0) then gone[#gone + 1] = k end
    end
    for _, k in ipairs(gone) do s.list[k] = nil end
end

-- the closest running car to them, within reach on foot
P.REACH = 300
function P.carFor(x, y)
    local best, bd, bk = nil, P.REACH ^ 2, nil
    for k, snap in pairs(cars().list) do
        local d = (snap.x - x) ^ 2 + (snap.y - y) ^ 2
        if d < bd and P.runs(snap) then best, bd, bk = snap, d, k end
    end
    return best, bk, best and math.sqrt(bd) or nil
end

function P.arrive(player)
    local p = P.pending
    local Talk = ProjectALife and ProjectALife.Talk
    local sq = roadSquare(player)
    if sq == nil then p.dueH = hours() + 0.1 return end      -- try again shortly
    local s = cars()
    local snap = s.list[p.carKey]
    if snap == nil then P.pending = nil return end
    -- take the real car from where it sat
    local removed = false
    pcall(function()
        eachOf(getCell():getVehicles(), function(v)
            if not removed and keyAt(v:getX(), v:getY()) == p.carKey then v:permanentlyRemove(); removed = true end
        end)
    end)
    s.list[p.carKey] = nil
    if not removed then
        -- 0.8.4: its spot is loaded and it isn't there: someone else drove it off. No car, no ride (never a copy).
        if spotLoaded(snap.x, snap.y) then
            print(TAG .. " " .. tostring(snap.script) .. " is gone from where it sat: nobody comes")
            pcall(ALifeLetter, player, "Nobody came. Whatever they meant to drive must be gone")
            P.pending = nil
            return
        end
        s.taken[p.carKey] = true
    end
    -- and bring it here as it was: same model, paint, parts, fuel (less what the drive burned)
    local car
    pcall(function() car = addVehicleDebug(snap.script, IsoDirections.N, snap.skin, sq) end)
    if car == nil then print(TAG .. " could not place " .. tostring(snap.script)); P.pending = nil return end
    pcall(function()
        for i = 0, car:getPartCount() - 1 do
            local part = car:getPartByIndex(i)
            local saved = snap.parts[part:getId()]
            if saved == nil then
                if part:getInventoryItem() then part:setInventoryItem(nil) end
            else
                part:setCondition(saved.c)
                if saved.a and part:isContainer() then
                    local a = saved.a
                    if part:getId() == "GasTank" then a = math.max(1, a - p.fuelUsed) end
                    part:setContainerContentAmount(a)
                end
            end
            car:transmitPartCondition(part)
        end
    end)
    local cx, cy = sq:getX() + 1, sq:getY() + 1
    local shell = Talk and Talk.shellFor and Talk.shellFor(p.uid)
    if shell then
        -- 0.7.0.8: through ALifeMove, so A-Life's watchdog doesn't read the jump as a lost body (it did: the NPC
        -- reached the car door, A-Life logged shell_displaced and respawned them back where they'd been standing)
        if ALifeMove then ALifeMove.body(shell, cx, cy, 0)
        else pcall(function() shell:setX(cx); shell:setY(cy); shell:setZ(0) end) end
    else
        local reg, L = ProjectALife.ActorRegistry, ProjectALife.SquadLedger
        pcall(reg.each, function(r)
            if r.uid == p.uid then
                local m = type(r.memory) == "table" and r.memory or {}
                local q = L and m.squadId and L.read(m.squadId)
                if q then L.update(q.id, q.revision, function(st) st.x, st.y = cx, cy end) end
                return true
            end
            return false
        end)
    end
    -- they drove it here, so they sit at the wheel. "NPC drives / riders" mode lets you get in beside them
    -- (plain "npc" mode bars players); then "take us to <place>" drives, or "get out" and drive it yourself.
    local C = ProjectALife.DrivingDemoClient
    local spec = shell and ALifeDriveOrders and ALifeDriveOrders.spec(shell)
    if C and spec then
        local id = car:getId()
        pcall(C.setCarMode, id, "mixed")
        pcall(C.attachCrew, id, { spec })
        pcall(C.getIn, id)
        local seated = C.sessions and C.sessions[id] ~= nil
        if not seated then print(TAG .. " driver not boarding car " .. id .. ": " .. tostring(C.status)) end
    end
    pcall(function() car:engineDoStarting() end)
    if shell then pcall(ProjectALife.Speech.say, shell, pick(P.LINES.here), { face = player }) end
    pcall(ALifeLetter, player, "A car pulls up nearby")
    print(TAG .. " arrived in " .. tostring(snap.script))
    P.pending = nil
end

function P.tick()
    local p = P.pending
    if p == nil then return end
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    local h = hours()
    if not p.warned and h >= p.warnH then
        p.warned = true
        pcall(ALifeLetter, player, "You hear an engine in the distance")
        pcall(function() getSoundManager():PlayWorldSound("VehicleEngineRunning", player:getCurrentSquare(), 0, 40, 1, false) end)
    end
    if h >= p.dueH then P.arrive(player) end
end

function P.install()
    if P.__installed then return true end
    local Data, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.Talk
    if Data == nil or Talk == nil then return false end
    P.__installed = true
    pcall(Data.intent, "PICKUP", 93, "pick me up|come get me|come pick me up|grab a car|bring a car|bring the truck|swing by and get me|come grab me|need a ride|i need a pickup")
    Talk.choiceHandlers.PICKUP = function(record, shell, player)
        local ok, line = pcall(P.ask, record, shell, player)
        if not ok then print(TAG .. " failed: " .. tostring(line)) return nil end
        if shell then pcall(ProjectALife.Speech.say, shell, line, { face = player }) end
        return line, "answered"
    end
    if ProjectALife.TalkIntents then ProjectALife.TalkIntents.cache = {} end
    print(TAG .. " ready (come pick me up)")
    return true
end

if Events ~= nil then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(P.install) end) end
    if Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifePickup", function() pcall(P.scan) end) end
    if Events.EveryOneMinute then ALifeHealth.add(Events.EveryOneMinute, "ALifePickup", function()
        local ok, err = pcall(P.tick)
        if not ok then print(TAG .. " tick failed: " .. tostring(err)); P.pending = nil end
    end) end
end
print(TAG .. " loaded")
