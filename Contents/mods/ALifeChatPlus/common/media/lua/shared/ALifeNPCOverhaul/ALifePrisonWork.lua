-- A-Life NPC Overhaul: putting prisoners to work.
-- Walk a prisoner (ALifeBondsPower) to your garden inside your base and tell them "work the garden".
--   They need to fear you (at least Wary) or they refuse.
--   Each in-game hour they water the plants within 8 tiles of where you put them (B42 farming).
--   They slack sometimes, quit after 8 hours a day, resent it, and with their hands down an unguarded
--   prisoner is likelier to walk off (the normal escape rules: out of your base half an hour = escaped).
--   "stop working" / "back inside" puts their hands back up.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifePrisonWork") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifePrisonWork]"
ALifePrisonWork = ALifePrisonWork or {}
local W = ALifePrisonWork
W.RADIUS, W.DAY_HOURS, W.SLACK = 8, 8, 20

local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end
local function P() return ALifeBondsPower end
local function B() return ALifeBonds end

W.LINES = {
    no = { "Make me.", "I'm not your slave.", "Go to hell." },
    yes = { "...Fine.", "Whatever keeps me breathing.", "Okay. Okay. Don't hurt me." },
    stop = { "Finally.", "Back to standing around, then." },
    quit = { "I'm done. You can shoot me, I'm done for today.", "My hands are raw. No more today." },
    tied = { "My hands are tied.", "How? Untie me first." },
    notbase = { "Out here? You want me to run?", "Not out here." },
}

function W.captive(record, player)
    local Pw = P()
    if Pw == nil or record == nil then return nil end
    local c = Pw.state().cap[record.uid]
    if c == nil or c.key ~= B().keyOf(player) then return nil end
    return c
end

-- water every plant in reach that needs it; returns how many
function W.garden(x, y, z)
    local sys = SFarmingSystem and SFarmingSystem.instance
    if sys == nil then return 0 end
    local n = 0
    for dx = -W.RADIUS, W.RADIUS do
        for dy = -W.RADIUS, W.RADIUS do
            local ok, plant = pcall(function() return sys:getLuaObjectAt(x + dx, y + dy, z) end)
            if ok and plant and plant.waterLvl ~= nil and not plant.dead and plant.waterLvl < 80 then
                plant.waterLvl = 100
                pcall(function() plant:saveData() end)
                n = n + 1
            end
        end
    end
    return n
end

function W.order(record, shell, player, stop)
    local c = W.captive(record, player)
    if c == nil then return nil end
    if stop then c.work = nil; return pick(W.LINES.stop) end
    if c.tied then return pick(W.LINES.tied) end
    local r = B().row(c.key, record.uid, false)
    if r == nil or B().stageOf(r.f) < 2 then return pick(W.LINES.no) end
    local ok, x, y, z = pcall(function() return shell:getX(), shell:getY(), shell:getZ() end)
    if not ok or P().yourBaseAt(player, x, y) == nil then return pick(W.LINES.notbase) end
    local day = math.floor(hours() / 24)
    c.work = { kind = "garden", x = math.floor(x), y = math.floor(y), z = math.floor(z or 0),
        day = day, done = (c.work and c.work.day == day) and c.work.done or 0 }
    if ALifeMemory then pcall(ALifeMemory.add, record, "the stranger made you work their garden as a prisoner") end
    if ALifeLLMTalk and ALifeLLMTalk.valPrisoner then ALifeLLMTalk.valPrisoner("forced_labor", player, record) end
    return pick(W.LINES.yes)
end

function W.hourly()
    local Pw = P()
    if Pw == nil then return end
    local Talk = ProjectALife and ProjectALife.Talk
    local day = math.floor(hours() / 24)
    for uid, c in pairs(Pw.state().cap) do
        local w = c.work
        if w then
            if w.day ~= day then w.day, w.done = day, 0 end
            local shell = Talk and Talk.shellFor and Talk.shellFor(uid)
            if shell and w.done < W.DAY_HOURS and roll(100) >= W.SLACK then
                local n = W.garden(w.x, w.y, w.z)
                w.done = w.done + 1
                if n > 0 then print(string.format("%s %s watered %d plants", TAG, tostring(c.name), n)) end
                if w.done >= W.DAY_HOURS then
                    pcall(ProjectALife.Speech.say, shell, pick(W.LINES.quit), {})
                    c.work = nil
                end
            end
            -- resentment: working wears a little fear into hate
            if B() and B().change then pcall(B().change, c.key, uid, -1, -1, 0, {}) end
        end
    end
end

function W.install()
    if W.__installed then return true end
    local Data, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.Talk
    if Data == nil or Talk == nil or P() == nil then return false end
    W.__installed = true
    pcall(Data.intent, "PRISON_WORK", 91, "work the garden|tend the garden|water the plants|water the garden|weed the garden|get to work|go work the garden|work the farm")
    pcall(Data.intent, "PRISON_STOP", 91, "stop working|back inside|that's enough work|thats enough work|quit working")
    local function h(stop, fallbackName)
        local fallback = Talk.choiceHandlers[fallbackName]
        return function(record, shell, player, context, now, text, asked)
            local ok, line = pcall(W.order, record, shell, player, stop)
            if not ok then print(TAG .. " failed: " .. tostring(line)) end
            if ok and line then
                pcall(ProjectALife.Speech.say, shell, line, { face = player })
                return line, "answered"
            end
            if type(fallback) == "function" then return fallback(record, shell, player, context, now, text, asked) end
            return nil
        end
    end
    Talk.choiceHandlers.PRISON_WORK = h(false, "ACTION_BUILD")
    Talk.choiceHandlers.PRISON_STOP = h(true, "WAIT_HERE")
    if ProjectALife.TalkIntents then ProjectALife.TalkIntents.cache = {} end
    print(TAG .. " ready (prisoners work the garden)")
    return true
end

if Events ~= nil then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(W.install) end) end
    if Events.EveryHours then ALifeHealth.add(Events.EveryHours, "ALifePrisonWork", function()
        local ok, err = pcall(W.hourly)
        if not ok and not W.warned then W.warned = true; print(TAG .. " hourly failed: " .. tostring(err)) end
    end) end
end
print(TAG .. " loaded")
