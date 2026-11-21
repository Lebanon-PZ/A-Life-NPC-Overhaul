-- A-Life NPC Overhaul 0.9.1 (Legacy): FEASTS AND TRADITIONS. The camp grows habits from what it really did.
-- Traditions come from the Chronicle: when the same kind of thing happens often enough (traditionRepeat times), it
-- becomes "our way", the camp says so, and it changes how people act from then on:
--   * runs come home (Jeem scavenging trips)      -> "we eat together after a run": a meal from real stores after each run
--   * funerals held                                -> "we bury our own": no time for one costs more than before
--   * people let in at the gate                     -> "we take people in": the camp leans yes on newcomers (CampVote)
--   * people turned away at the gate                -> "strangers stay outside": the camp leans no
--   * feasts held                                   -> "we keep our feast days": a feast eases people more
--   * fights talked down                            -> "we settle it with words": stepping into a fight works better
-- Going against it (no funeral, turning people away while "we take people in", ...) traditionBreak times ends it, and
-- the Chronicle writes that down too. Big days keep their feasts (ALifeSeasonsCamp); a run meal is a feast from the
-- same real food. Nothing spawns. Settings: traditions, traditionRepeat, traditionBreak, traditionRunMeal.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Traditions") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeChronicle"
local M = ALifeLLMTalk
local C = ALifeChronicle
if type(M) ~= "table" or type(C) ~= "table" then return end
ALifeTraditions = ALifeTraditions or {}
local T = ALifeTraditions
local TAG = "[ALifeTraditions]"
T.VERSION = ALifeSide.MOD_VERSION
T.DEFAULTS = {
    traditions = true,      -- the camp grows its own ways from what it keeps doing
    traditionRepeat = 3,    -- times something happens before it's "our way"
    traditionBreak = 2,     -- times the camp goes against it before it's gone
    traditionRunMeal = true, -- "we eat together after a run" makes a real meal after each run
}
-- id -> { from = chronicle kind that builds it, breaks = kind that breaks it, name = how the camp says it }
T.WAYS = {
    run_meal = { from = "run", name = "we eat together after a run" },
    funeral_rite = { from = "funeral", breaks = "nofuneral", name = "we bury our own" },
    open_door = { from = "join", breaks = "turnaway", name = "we take people in", against = "shut_door" },
    shut_door = { from = "turnaway", breaks = "join", name = "strangers stay outside", against = "open_door" },
    feast_days = { from = "feast", name = "we keep our feast days" },
    words = { from = "standoff", match = "talked down", name = "we settle it with words" },
}
T.ORDER = { "run_meal", "funeral_rite", "open_door", "shut_door", "feast_days", "words" }
T.stats = { formed = 0, broken = 0, meals = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = T.DEFAULTS[k] end; return v end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return r end
local function log(m) print(TAG .. " " .. tostring(m)) end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(T.DEFAULTS) do
            if M.settings[k] == nil then M.settings[k] = v end
            if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end
function T.on() return setting("traditions") ~= false end
-- kept with the chronicle (global ModData): counts, ways, breaks
function T.store()
    local d = C.store()
    d.trad = type(d.trad) == "table" and d.trad or {}
    local t = d.trad
    t.count = type(t.count) == "table" and t.count or {}
    t.ways = type(t.ways) == "table" and t.ways or {}
    t.brk = type(t.brk) == "table" and t.brk or {}
    return t
end
function T.has(id) return T.store().ways[id] ~= nil end
function T.list()
    local out = {}
    for _, id in ipairs(T.ORDER) do if T.has(id) then out[#out + 1] = T.WAYS[id].name end end
    return out
end
local function people() local p = playerOf(); local out = {}; if fn(M, "cpPeople") and p then pcall(function() out = M.cpPeople(p) or {} end) end; return out end
local function adjustAll(d, why) local p = playerOf(); for _, u in ipairs(people()) do pcall(function() PA().NpcOpinion.adjust(rec(u), p, d, why) end) end end
local function memAll(text) if fn(M, "keyMem") then for _, u in ipairs(people()) do pcall(M.keyMem, u, "occasion", text) end end end

-- a new entry in the chronicle: count it, maybe a tradition forms or breaks, and act on the ways the camp has
function T.onEntry(e)
    if not T.on() or type(e) ~= "table" or e.k == "tradition" then return end
    local s = T.store()
    for _, id in ipairs(T.ORDER) do
        local w = T.WAYS[id]
        if e.k == w.from and (w.match == nil or string.find(tostring(e.what or ""), w.match, 1, true)) then
            s.count[id] = (s.count[id] or 0) + 1
            if s.ways[id] == nil and s.count[id] >= (tonumber(setting("traditionRepeat")) or 3) and not (w.against and s.ways[w.against]) then
                s.ways[id] = { h = hours() }
                s.brk[id] = 0
                if w.against then s.count[w.against] = 0 end -- the opposite starts counting again from here
                T.stats.formed = T.stats.formed + 1
                C.add({ k = "tradition", what = w.name })
                memAll("It's our way now: " .. w.name)
                pcall(ALifeSide.outLetter, playerOf(), "Your camp has a way of its own now: " .. w.name .. ".", 200, 190, 140) -- pre-1.0 MP: ALifeSide.outLetter
            end
        end
        if w.breaks and e.k == w.breaks and s.ways[id] then
            s.brk[id] = (s.brk[id] or 0) + 1
            if id == "funeral_rite" then adjustAll(-3, "no funeral, and we always bury our own") end
            if s.brk[id] >= (tonumber(setting("traditionBreak")) or 2) then
                s.ways[id] = nil
                s.count[id] = 0
                T.stats.broken = T.stats.broken + 1
                C.add({ k = "tradition", what = "we stopped: " .. w.name .. ". Not any more" })
            end
        end
    end
    -- acting on the ways
    if e.k == "run" and T.has("run_meal") then T.runMeal() end
    if e.k == "feast" and T.has("feast_days") then adjustAll(2, "we keep our feast days") end
end
-- a meal after a run: a feast from real stores (ALifeSeasonsCamp, once a day; called off when there isn't enough)
function T.runMeal()
    if setting("traditionRunMeal") == false then return false end
    local L = ALifeSeasonsCamp
    local p = playerOf()
    if not (fn(L, "feast") and fn(L, "base") and fn(L, "atTable")) or p == nil then return false end
    local b = L.base(p)
    if b == nil then return false end
    local day = math.floor(hours() / 24)
    local ok, done = pcall(L.feast, p, b, L.atTable(p, b), "runmeal:" .. day, "a meal after the run", "We ate together after the run, like always")
    if ok and done then T.stats.meals = T.stats.meals + 1 end
    return ok and done
end

-- the ways change how people act
function T.hook()
    local n = 0
    -- every chronicle entry
    if C.wrap(C, "add", function(res) if type(res[1]) == "table" then pcall(T.onEntry, res[1]) end end) then n = n + 1 end
    -- the camp's vote on newcomers leans by the door ways (V.voice(r, q, ctx) -> score, why)
    local V = ALifeCampVote
    if fn(V, "voice") and not rawget(V, "_tradVoice") then
        local orig = V.voice
        V.voice = function(r, q, ctx, ...)
            local score, why = orig(r, q, ctx, ...)
            if T.on() and type(q) == "table" and q.k == "admit" and type(score) == "number" then
                if T.has("open_door") then score = score + 10; why = why or "taking people in is our way" end
                if T.has("shut_door") then score = score - 10; why = why or "strangers stay outside, that's our way" end
            end
            return score, why
        end
        rawset(V, "_tradVoice", true)
        n = n + 1
    end
    -- stepping into a fight works better where that's the way
    local S = ALifeNpcStandoff
    if fn(S, "calmChance") and not rawget(S, "_tradCalm") then
        local orig = S.calmChance
        S.calmChance = function(...)
            local c = orig(...)
            if T.on() and T.has("words") and type(c) == "number" then c = math.min(0.95, c + 0.15) end
            return c
        end
        rawset(S, "_tradCalm", true)
        n = n + 1
    end
    T.hooked = n
    return n
end
function T.install()
    pcall(T.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "traditions", "Traditions: the camp grows its own ways from what it keeps doing (Chronicle)" },
            { "traditionRepeat", "Traditions: times something happens before it's the camp's way", { 2, 3, 5, 8 } },
            { "traditionBreak", "Traditions: times the camp goes against a way before it's gone", { 1, 2, 3 } },
            { "traditionRunMeal", "Traditions: 'we eat together after a run' makes a real meal from the stores" },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Your camp and base" end
        end
    end
    print(TAG .. " ready v" .. T.VERSION .. ": " .. tostring(T.hooked or 0) .. " hooks, ways now: " .. (#T.list() > 0 and table.concat(T.list(), "; ") or "none yet"))
end
pcall(T.hook)
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(T.install) end) end
return T
