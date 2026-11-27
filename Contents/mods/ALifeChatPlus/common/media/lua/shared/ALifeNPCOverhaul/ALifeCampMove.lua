-- A-Life NPC Overhaul pre-1.0: MOVE CAMP. "Make this our camp" (Camp tab) moves your camp to the building you stand in.
-- Why it's needed: the camp is A-Life's home for you (SafehouseDirector.houseFor: a marked house first, then a vanilla
-- safehouse claim, then the BaseHeat base you've slept the most nights at). Move house and the old place keeps
-- winning on nights slept until the new one catches up, even after it's torn down.
-- So we set A-Life's own mark (SafehouseDirector.mark, the same call as its "Create test base here" tool; it clears
-- your old mark first). "Let the camp follow where we sleep" clears it (SafehouseDirector.clearMark).
-- Read in ProjectALifeNPCs 42.20 server/ProjectALife/World/ALifeSafehouseDirector.lua: mark(player, now, at) ->
-- ok, why ("not_in_a_building"), house; clearMark(player) -> count. Server side (MP: through ALifeCmd).
-- A building made only of walls you built yourself may not count as a building to the engine (unverified 42.21).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeCampMove = ALifeCampMove or {}
local V = ALifeCampMove
local TAG = "[ALifeCampMove]"
V.VERSION = ALifeSide.MOD_VERSION
V.DEFAULTS = { campMove = true } -- the "Make this our camp" button
local function M() return ALifeLLMTalk end
-- new setting keys go in fileKeys at load (CLAUDE.md rule 2)
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        m.fileKeys = m.fileKeys or {}
        local have = {}
        for _, x in ipairs(m.fileKeys) do have[x] = true end
        for k, v in pairs(V.DEFAULTS) do
            if m.settings[k] == nil then m.settings[k] = v end
            if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end
        end
    end
end
local function setting(k)
    local m, v = M(), nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[k] end
    if v == nil then v = V.DEFAULTS[k] end
    return v
end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function director() return type(ProjectALife) == "table" and ProjectALife.SafehouseDirector or nil end
function V.on() return setting("campMove") ~= false end

-- our cached copies of the base: drop them so everything picks up the new place now
function V.forget()
    local m = M()
    if type(m) ~= "table" then return end
    m.alifeBaseCache = nil
    m.cpFortB = nil
end

-- server: args.off = true clears the mark (back to where you sleep)
function V.apply(player, args)
    if player == nil then return false, "no_player" end
    if not V.on() then return false, "off" end
    local D = director()
    if args ~= nil and type(args) ~= "table" then return false, "bad_args" end
    local off = type(args) == "table" and args.off == true
    if off then
        if not fn(D, "clearMark") then return false, "no_alife" end
        local ok, n = pcall(D.clearMark, player)
        V.forget()
        return ok, ok and (tonumber(n) or 0) > 0 and "cleared" or "nothing"
    end
    if not fn(D, "mark") then return false, "no_alife" end
    local ok, done, why = pcall(D.mark, player, nil, nil) -- no clicked spot: the building you stand in
    if not ok then return false, "error" end
    if done ~= true then return false, tostring(why or "failed") end
    V.forget()
    return true, "moved"
end

V.TEXT = {
    moved = "This is home now. Your people's camp is here.",
    cleared = "The camp follows where you sleep again.",
    nothing = "The camp already follows where you sleep.",
    not_in_a_building = "Stand inside the building you want for your camp.",
    off = "Moving camp is turned off in the settings.",
    no_alife = "Project A-Life isn't keeping a home for you here.",
}
function V.textFor(why) return V.TEXT[tostring(why)] or "Couldn't move the camp." end

-- client: ask, and say how it went
function V.ask(player, off)
    if player == nil or not fn(ALifeCmd, "send") then return false end
    return ALifeCmd.send(player, "campMove", { off = off == true or nil })
end
function V.onDone(p)
    V.forget()
    local m = M()
    local line = V.textFor(type(p) == "table" and p.why or nil)
    if type(m) == "table" and fn(m, "momToast") then pcall(m.momToast, line) else print(TAG .. " " .. line) end
end

if type(ALifeCmd) == "table" and fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("campMove", function(player, args)
        local ok, why = V.apply(player, args)
        ALifeCmd.reply(player, "campMoveDone", { ok = ok == true, why = tostring(why) })
        return ok and "ok" or tostring(why)
    end)
    ALifeCmd.onClient("campMoveDone", function(p) V.onDone(p) end)
end

function V.rows()
    local m = M()
    if type(m) ~= "table" or type(m.settingRows) ~= "table" then return end
    for _, r in ipairs(m.settingRows) do if r[1] == "campMove" then return end end
    m.settingRows[#m.settingRows + 1] = { "campMove", "Camp tab: 'Make this our camp' moves your camp to the building you stand in" }
    if type(m.settingCatOf) == "table" then m.settingCatOf.campMove = "Your camp and base" end
end

if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        pcall(V.rows)
        print(TAG .. " ready v" .. tostring(V.VERSION) .. ": move camp (" .. (V.on() and "on" or "off") .. ", A-Life mark "
            .. (fn(director(), "mark") and "found" or "not here") .. ")")
    end)
end
return V
