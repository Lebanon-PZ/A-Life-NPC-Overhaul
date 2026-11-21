-- A-Life NPC Overhaul 0.9.3 (Legacy): THE AIRPORT'S FINAL MOVE. Once per save, the Louisville National Guard at the
-- airport makes its last big move, picked from its real state (checked once a game day, from airportFinalDay days
-- after it was founded):
--   * COLLAPSE: starving (desperate and few left): mutiny. The base breaks up; the people they took walk out.
--   * EVACUATE: short on food but with a helicopter left (ALifeSkyPower's fleet): the last flight out. They're gone.
--   * PACT: short on food and they like you (their rep with you): they offer a pact. Say yes and you're their supplier
--     (a supply flight at least every airportPactDays, or the pact breaks), and they stand behind you (Kingmaker).
--   * EXPAND: well supplied and strong: they take the weakest group near Louisville by force (the 0.7 off-screen
--     assault, with their real strength), and absorb what's left.
--   * Nothing fits yet: they wait. One time only. An airport that's emptied is the fortress someone will want (0.9.4).
-- Written to the Chronicle and the radio. Settings: airportFinal, airportFinalDay, airportPactDays, airportPactRep.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_AirportEnd") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeAirportEnd = ALifeAirportEnd or {}
local A = ALifeAirportEnd
local TAG = "[ALifeAirportEnd]"
A.VERSION = ALifeSide.MOD_VERSION
A.DEFAULTS = {
    airportFinal = true,     -- the airport makes one last big move from its real state
    airportFinalDay = 60,    -- not before this many days after it was founded
    airportPactDays = 7,     -- a pact: at least one supply flight this often, or it breaks
    airportPactRep = 25,     -- a pact is only offered when they like you this much (their rep with you)
    airportExpandN = 25,     -- they only push out with at least this many people
    airportCollapseN = 6,    -- desperate and this few: mutiny
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
-- pre-1.0 MP (P6): the airport's last move is world news: letters + news to everyone online, the pact card to the
-- camp's player (Main's M.homePlayer). SP: unchanged.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function playerOf()
    if mpServer() and fn(M, "homePlayer") then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = A.DEFAULTS[k] end; return v end
local function letter(t)
    if mpServer() then if type(ALifeOut) == "table" then ALifeOut.letter(nil, t, 190, 200, 230) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 190, 200, 230) end
end
local function radio(t) if fn(M, "radioLine") then pcall(M.radioLine, nil, t) end end
local function chron(k, what) if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = k, what = what }) end end
local function news(t) if fn(M, "newsNote") then pcall(M.newsNote, "politics", t) end end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(A.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
    if type(M.nbEndWords) == "table" then M.nbEndWords.moved = M.nbEndWords.moved or "they flew out"; M.nbEndWords.mutiny = M.nbEndWords.mutiny or "they turned on each other and scattered" end
end
function A.store()
    local s = fn(M, "apStore") and M.apStore() or nil
    if type(s) ~= "table" then return nil end
    return s
end
function A.fleet()
    local L = ALifeSkyPower
    if fn(L, "fleet") then local ok, n = pcall(L.fleet); if ok and tonumber(n) then return n end end
    return 0
end
-- the weakest active group near the airport (not the airport, not yours)
function A.weakest(ab)
    local best, bestS = nil, 1e12
    if not fn(M, "nbActive") then return nil end
    for _, b in ipairs(M.nbActive() or {}) do
        if b.id ~= ab.id and b.status == "active" and tonumber(b.x) and tonumber(ab.x) and (b.x - ab.x) ^ 2 + (b.y - ab.y) ^ 2 <= 2500 * 2500 then
            local st = fn(M, "nbStrength") and M.nbStrength(b) or 0
            if st < bestS then best, bestS = b, st end
        end
    end
    return best
end

-- what the state says (nil = nothing yet)
function A.decide(s, ab, player)
    local mood = fn(M, "apMood") and M.apMood() or "steady"
    local n = fn(M, "apCount") and M.apCount() or 0
    if mood == "desperate" and n <= (tonumber(setting("airportCollapseN")) or 6) then return "collapse" end
    if (mood == "desperate" or mood == "low") then
        if (tonumber(s.rep) or 0) >= (tonumber(setting("airportPactRep")) or 25) and not s.pactOffered and player then return "pact" end
        if A.fleet() > 0 then return "evacuate" end
    end
    if (mood == "flush" or mood == "steady") and n >= (tonumber(setting("airportExpandN")) or 25) and A.weakest(ab) then return "expand" end
    return nil
end

-- the moves
function A.collapse(s, ab)
    local took = tonumber(s.workers) or 0
    -- 0.9.5: the people they took really go free (their A-Life records lose the airport as home), not just words
    if fn(M, "alReleaseAbducted") then local ok, n = pcall(M.alReleaseAbducted, "mutiny"); if ok then took = tonumber(n) or 0 end end
    s.workers = 0
    if fn(M, "nbAbandon") then pcall(M.nbAbandon, ab, "mutiny") end
    s.state = "gone"
    s.emptyAt = hours()
    letter("The radio from the airport is all shouting, then nothing. The Guard turned on itself." .. (took > 0 and (" The people they took are walking out.") or ""))
    radio("...airport, this is... nobody's in charge here anymore. Don't come. Don't...")
    news("the airport's soldiers turned on each other; the place is emptying out")
    chron("war", "The Guard at the airport turned on itself and broke apart")
    return true
end
function A.evacuate(s, ab)
    local L = ALifeSkyPower
    pcall(function() local gs = L.guardStore(); gs.helis = math.max(0, (tonumber(gs.helis) or 1) - 1) end)
    -- the ones off the map go with the helicopter (their records leave the world; anyone loaded stays where they are)
    local gone = 0
    if fn(M, "sbCrewOf") and fn(M, "sbKillVirtual") then
        for _, r in ipairs(M.sbCrewOf(ab) or {}) do if r.virtual and M.sbKillVirtual(r, "flew out") then gone = gone + 1 end end
    end
    if fn(M, "nbEnded") then pcall(M.nbEnded, ab, "moved") end
    s.state = "gone"
    s.emptyAt = hours()
    letter("A helicopter lifts off from the airport and heads north, and keeps going. The Guard is gone.")
    radio("All units, final transmission. We are leaving Louisville. Good luck down there.")
    news("the last helicopter left the airport; the Guard pulled out")
    chron("war", "The Guard flew out of the airport on its last helicopter. The airport stands empty")
    return true
end
function A.expand(s, ab)
    local t = A.weakest(ab)
    if t == nil then return false end
    local haven = fn(M, "nbHavenOf") and M.nbHavenOf(t) or nil
    local crew = {}
    pcall(function() crew = M.nbScan(true).crews[t.id] or {} end)
    local old = M.nbForceStrength
    M.nbForceStrength = math.floor(fn(M, "nbStrength") and M.nbStrength(ab) or 50) -- their real strength, not a dice roll
    local ok, res = pcall(M.nbAttack, t, haven, crew, 1, hours(), "raiders")
    M.nbForceStrength = old
    if ok and (res == "overrun" or res == "overrun_held") and fn(M, "nbAbsorb") and t.status == "active" then pcall(M.nbAbsorb, ab, t, hours()) end
    letter("The Guard moved on " .. tostring(t.name) .. ". " .. ((ok and (res == "overrun" or res == "overrun_held")) and "They took it." or "They were driven back."))
    news("the airport's soldiers attacked " .. tostring(t.name))
    chron("war", "The Guard pushed out from the airport and hit " .. tostring(t.name))
    return ok
end
function A.offerPact(s, ab, player)
    s.pactOffered = hours()
    local function yes()
        s.pact = { h = hours(), lastFlightH = hours() }
        if type(ALifeKingmaker) == "table" and fn(ALifeKingmaker, "back") then pcall(ALifeKingmaker.back, player, ab, nil) end
        chron("backed", "a pact with the Guard at the airport: we keep them fed, they stand behind us")
        letter("You have a pact with the Guard. Keep the supply flights coming, at least every " .. tostring(setting("airportPactDays")) .. " days.")
    end
    local function no()
        s.rep = (tonumber(s.rep) or 0) - 10
        letter("You turned the Guard down. They'll find another way, or not.")
    end
    if ALifeSide.canOutCard() then
        pcall(ALifeSide.outCard, player, { id = "airportpact", title = "The Guard offers a pact", default = 2,
            text = "\"We're running short. You're not. Keep us supplied and we'll stand behind you, against anyone.\" <LINE> <LINE> A supply flight at least every "
                .. tostring(setting("airportPactDays")) .. " days. Miss it and the pact is off.",
            choices = { { label = "Agree to the pact", fn = yes }, { label = "Turn them down", fn = no } } })
    else no() end
    return true
end
-- a pact kept by supply flights: AirportLife's trade (M.alTrade) marks it
function A.pactTick(s, player)
    local p = s.pact
    if type(p) ~= "table" or p.broken then return nil end
    if hours() - (tonumber(p.lastFlightH) or 0) > (tonumber(setting("airportPactDays")) or 7) * 24 then
        p.broken = hours()
        s.rep = (tonumber(s.rep) or 0) - 20
        if type(ALifeKingmaker) == "table" and fn(ALifeKingmaker, "unback") then pcall(ALifeKingmaker.unback, player, "you stopped supplying the Guard") end
        letter("No supplies, no pact. The Guard is done with you.")
        chron("backed", "the pact with the Guard broke: no supplies came")
        return "broken"
    end
    return "kept"
end
function A.hook()
    if A.hooked or not fn(M, "alTrade") then return A.hooked == true end
    local orig = M.alTrade
    M.alTrade = function(box, ...)
        local r = { orig(box, ...) }
        pcall(function() local s = A.store(); if s and type(s.pact) == "table" and not s.pact.broken then s.pact.lastFlightH = hours() end end)
        return unpack(r)
    end
    A.hooked = true
    return true
end

-- once a game day
function A.daily(player)
    if setting("airportFinal") == false then return nil end
    local s = A.store()
    if s == nil then return nil end
    if s.pact then A.pactTick(s, player) end
    if s.final or s.state ~= "active" then return nil end
    local ab = fn(M, "apBase") and M.apBase() or nil
    if ab == nil or ab.status ~= "active" then return nil end
    local founded = tonumber(s.foundedH or ab.foundedH or ab.h) or 0
    if hours() - founded < (tonumber(setting("airportFinalDay")) or 60) * 24 then return nil end
    local move = A.decide(s, ab, player)
    if move == nil then return nil end
    if move == "pact" then A.offerPact(s, ab, player); return "pact" end -- an offer isn't the final move unless it's taken
    local ok = false
    if move == "collapse" then ok = A.collapse(s, ab)
    elseif move == "evacuate" then ok = A.evacuate(s, ab)
    elseif move == "expand" then ok = A.expand(s, ab) end
    if ok then s.final = { kind = move, h = hours() }; log("final move: " .. move) end
    return move
end
function A.install()
    pcall(A.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "airportFinal", "Airport: the Guard makes one last big move from how it's really doing (leave, fall apart, a pact, or push out)" },
            { "airportFinalDay", "Airport: not before this many days after it was founded", { 30, 60, 120 } },
            { "airportPactDays", "Airport: a pact needs a supply flight at least this often (days)", { 4, 7, 14 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. A.VERSION .. ": the airport's final move " .. (setting("airportFinal") ~= false and "on" or "off") .. ", pact flights " .. (A.hooked and "watched" or "NOT watched"))
end
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(A.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(A.daily, playerOf()) end) end
end
return A
