-- A-Life NPC Overhaul: Brain Patch (merged in from the separate ALifeBrainPatch mod)
-- A-Life Brain Patch: homestead chores.
-- Registered as an A-Life decision module (same system as A-Life's own "fortify"), between group plans (125)
-- and idle life (140): when a group has no plan, its people work on the building they live in.
--   1. board up ground-floor windows, using planks they carry (doors stay usable)
--   2. loot runs bring planks home (1-3 per person when a loot plan finishes)
--   3. daytime: if a group has sat idle a while, clear A-Life's plan back-off so the leader tries a new plan
-- Everything goes through A-Life's own movement, barricade and plank code. Any failure = do nothing.

require "ProjectALife/Behaviours/ALifeModuleRegistry"

local TAG = "[BrainPatch]"
BrainPatch = BrainPatch or {}
local H = BrainPatch
if H.__loaded then return end -- Chat Plus now carries Brain Patch; skip if the old separate mod already loaded it
H.__loaded = true
H.COOLDOWN_MS = 60000        -- between boarding jobs per person
H.MOVE_TIMEOUT_MS = 15000
H.NUDGE_IDLE_MS = 180000     -- 3 min idle in daylight -> let the leader plan again
H.metrics = { offers = 0, boarded = 0, noPlanks = 0, planksGiven = 0, nudges = 0 }
H.idleSince = {}

local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function mem(actor) return type(actor) == "table" and type(actor.memory) == "table" and actor.memory or {} end
local function groupKey(actor)
    local P = ProjectALife.GroupPlan
    if P and P.groupKey then local ok, k = pcall(P.groupKey, actor); if ok then return k end end
    return "solo:" .. tostring(actor.uid)
end
local function isNight()
    local P = ProjectALife.GroupPlan
    local ok, n = pcall(function() return P.isNight() end)
    return ok and n == true
end

-- this group has a live A-Life plan: stay out of its way
local function planActive(actor)
    local P = ProjectALife.GroupPlan
    if P == nil or type(P.board) ~= "table" then return false end
    return P.board[groupKey(actor)] ~= nil
end

local function windowsOfHome(shell)
    local out = {}
    pcall(function()
        local sq = shell:getCurrentSquare()
        local b = sq and sq:getBuilding()
        if b == nil then return end
        local probe = ProjectALife.OutpostBuilder.probeBuilding(b)
        if probe == nil then return end
        for _, w in ipairs(probe.windows()) do
            if w.barricaded ~= true and tonumber(w.z) == 0 then out[#out + 1] = w end
        end
    end)
    return out
end

local function nearest(list, x, y)
    local best, bd
    for _, o in ipairs(list) do
        local d = (o.x - x) ^ 2 + (o.y - y) ^ 2
        if bd == nil or d < bd then best, bd = o, d end
    end
    return best, bd and math.sqrt(bd) or nil
end

local function nudge(actor, t)
    local key = groupKey(actor)
    local since = H.idleSince[key]
    if since == nil then H.idleSince[key] = t return end
    if t - since < H.NUDGE_IDLE_MS or isNight() then return end
    local P = ProjectALife.GroupPlan
    if P and type(P.backoff) == "table" and P.backoff[key] ~= nil then
        P.backoff[key] = nil
        H.metrics.nudges = H.metrics.nudges + 1
    end
    H.idleSince[key] = t
end

function H.evaluate(actor, shell, context)
    if shell == nil or type(context) ~= "table" or context.threat ~= nil then return nil end
    local m = mem(actor)
    if m.outpostId ~= nil or m.outpostSquadId ~= nil then return nil end          -- A-Life's own fortify handles outposts
    local act = actor.activity
    if act == "combat" or act == "fleeing" or act == "warning" or act == "attacking" then return nil end
    local t = tonumber(context.now) or now()
    if planActive(actor) then H.idleSince[groupKey(actor)] = nil return nil end
    nudge(actor, t)
    if t < (tonumber(m.bpNextAtMs) or 0) then return nil end
    local function cool(ms)
        if type(context.persistMemory) == "function" then
            context.persistMemory(actor, function(mm) mm.bpNextAtMs = t + ms end)
        else m.bpNextAtMs = t + ms end
    end
    local Planks = ProjectALife.Planks
    local held = Planks and Planks.held({ shell }) or 0
    if held <= 0 then H.metrics.noPlanks = H.metrics.noPlanks + 1; cool(H.COOLDOWN_MS) return nil end
    local windows = windowsOfHome(shell)
    if #windows == 0 then cool(H.COOLDOWN_MS * 3) return nil end
    local x, y = shell:getX(), shell:getY()
    local w, dist = nearest(windows, x, y)
    H.metrics.offers = H.metrics.offers + 1
    if dist > 2.5 or math.floor(shell:getZ()) ~= w.z then
        if type(context.startMovement) ~= "function" then return nil end
        return context.startMovement(actor, shell, { x = w.x, y = w.y, z = w.z }, "bp_homestead", {
            kind = "movement", activity = "moving", intent = "board_home", pace = "walk", timeoutMs = H.MOVE_TIMEOUT_MS })
    end
    cool(H.COOLDOWN_MS)
    local F = ProjectALife.ModuleFortify
    local share = math.min(held, Planks.perOpeningMax or 4)
    if F and type(F.board) == "function" and F.board(shell, w, share) then
        H.metrics.boarded = H.metrics.boarded + 1
        pcall(function() ProjectALife.Animations.apply(shell, "board_up") end)
        if type(context.setActivity) == "function" then context.setActivity(actor, "working", "board_home") end
        return { kind = "idle", intent = "board_home", cooldownUntilMs = t + 2600 }
    end
    return nil
end

-- loot runs bring boards home
local function hookPlans()
    local P = ProjectALife.GroupPlan
    if P == nil or type(P.complete) ~= "function" or H.__planHooked then return end
    H.__planHooked = true
    local orig = P.complete
    P.complete = function(key, plan, roster, t, ...)
        pcall(function()
            local lootKinds = ProjectALife.PlanData and ProjectALife.PlanData.lootKinds or {}
            if not (type(plan) == "table" and lootKinds[plan.kind]) then return end
            for _, entry in ipairs(roster and roster.list or {}) do
                local shell = P.shellOf(entry.uid)
                if shell ~= nil then
                    local n = 1 + ZombRand(3)
                    for _ = 1, n do shell:getInventory():AddItem("Base.Plank") end
                    H.metrics.planksGiven = H.metrics.planksGiven + n
                end
            end
        end)
        return orig(key, plan, roster, t, ...)
    end
end

local function install()
    if H.__installed then return true end
    local R = ProjectALife and ProjectALife.ModuleRegistry
    if R == nil or type(R.register) ~= "function" then return false end
    local ok, err = R.register({
        id = "bp_homestead", kind = "upkeep", dispatch = "decision", priority = 130,
        label = "Homestead chores (Brain Patch)",
        summary = "Groups without a plan board up the building they live in and keep busy.",
        defaultEnabled = true, evaluate = function(a, s, c)
            local okE, r = pcall(H.evaluate, a, s, c)
            if not okE then if not H.warned then H.warned = true; print(TAG .. " evaluate failed: " .. tostring(r)) end return nil end
            return r
        end,
    })
    H.__installed = true
    hookPlans()
    print(TAG .. " ready (homestead chores, planks from loot runs, idle nudge) " .. tostring(ok) .. " " .. tostring(err or ""))
    return true
end

if not install() and Events and Events.OnGameStart then Events.OnGameStart.Add(install) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(hookPlans) end
if Events and Events.EveryHours then
    ALifeHealth.add(Events.EveryHours, "BP_Homestead", function()
        local m = H.metrics
        print(string.format("%s hour: offers=%d boarded=%d noPlanks=%d planksGiven=%d nudges=%d",
            TAG, m.offers, m.boarded, m.noPlanks, m.planksGiven, m.nudges))
    end)
end
print(TAG .. " loaded")
