-- A-Life NPC Overhaul 0.9.4 (Legacy): DEMOCRACY. The people of your base (Jeem residents) vote on laws.
-- NO ELECTIONS in your camp (Joe, Nov 14): you lead as long as they love you, need you or fear you (ALifeBonds /
-- ALifeBondsMind: held by fear alone, they steal, tip off enemies, and at worst turn on you). Same rules as NPCs.
--   * LAWS: rations (full / short / half / guards first: ALifeRations), the door (open: the camp leans yes on newcomers;
--     closed: it leans no), and the camp's rules (no killing prisoners, no killing the harmless, no stealing, share the
--     food: ALifeTalk_Camp's rules, client side). Each resident votes from real things: how hungry the base is and
--     how many days of food are left (rations), how full the beds are (the door), their temperament (A-Life:
--     predators want guards fed first, the fresh ones want the door open), and what they think of you when you're the
--     one asking. A law passes with more yes than no. "Let's vote on short rations" / "put the door to a vote" /
--     "vote on no killing prisoners".
--   * No numbers: "most of them", "about half", "only a few".
-- Store: global ModData "ALifeChatPlus_Democracy": [baseId] = { door, lastVote }.
-- Commands (ALifeCmd): demVote { law, value } -> demResult.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"
if ALifeCampVote == nil then require "ALifeNPCOverhaul/ALifeCampVote" end -- pre-1.0: loaded first by folder order before (ALifeChatPlus sorted first); now a real require

ALifeDemocracy = ALifeDemocracy or {}
local D = ALifeDemocracy
local TAG = "[ALifeDemocracy]"
D.VERSION = ALifeSide.MOD_VERSION
D.MODDATA = "ALifeChatPlus_Democracy"
D.DEFAULTS = {
    democracyLaws = true,   -- you can put laws to a vote
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(r)
    local m = mem(r)
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function temper(r) local t = nil; pcall(function() t = PA().Speech.contextFor(r, nil).temperament end); return type(t) == "string" and t or nil end
local function opinion(r, player) local v = 0; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end); return v end
local function pair(a, b) if not fn(ALifeHousehold, "get") then return 0 end local ok, v = pcall(ALifeHousehold.get, a, b); return ok and num(v, 0) or 0 end
function D.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = D.DEFAULTS[key] end
    return v
end
do
    local m = ALifeLLMTalk
    if type(m) == "table" and type(m.settings) == "table" then
        m.fileKeys = m.fileKeys or {}
        local have = {}
        for _, x in ipairs(m.fileKeys) do have[x] = true end
        for k, v in pairs(D.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end; if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end end
    end
end
function D.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return num(h, 0) end
function D.store()
    local d = nil
    pcall(function() d = ModData.getOrCreate(D.MODDATA) end)
    if type(d) ~= "table" then D._mem = D._mem or {}; d = D._mem end
    d.by = type(d.by) == "table" and d.by or {}
    return d
end
local function transmit() if type(ModData) == "table" and fn(ModData, "transmit") and ALifeSide.server() then pcall(ModData.transmit, D.MODDATA) end end
function D.rowOf(baseId)
    local d = D.store()
    local r = d.by[tostring(baseId)]
    if type(r) ~= "table" then r = {}; d.by[tostring(baseId)] = r end
    return r
end
function D.baseFor(player) return fn(ALifeCampVote, "baseFor") and ALifeCampVote.baseFor(player) or nil end
function D.people(base) return (base and fn(ALifeCampVote, "residents")) and ALifeCampVote.residents(base.id) or {} end

-- ---------------------------------------------------------------------------------------------- one vote on a law
D.LAWS = {
    rations = { values = { full = true, short = true, half = true, guards = true } },
    door = { values = { open = true, closed = true } },
    rule = { values = { prisoners = true, harmless = true, steal = true, share = true } },
}
-- one resident's view: + for, - against (and why, in plain words)
function D.view(r, law, value, ctx, player)
    local s, why = 0, nil
    local t = temper(r)
    if law == "rations" then
        local cut = value ~= "full"
        if ctx.hungry then s = s + (cut and -30 or 20); why = "they're already hungry" end
        if ctx.days ~= nil and ctx.days < 4 then s = s + (cut and 20 or -20); why = why or "the food is running out" end
        if ctx.days ~= nil and ctx.days >= 14 then s = s + (cut and -15 or 10); why = why or "there's plenty" end
        if value == "guards" and (t == "predator" or t == "veteran") then s = s + 15; why = why or "the ones on watch should eat first" end
    elseif law == "door" then
        if value == "open" then
            if t == "fresh" or t == "seasoned" then s = s + 10; why = "more hands help" end
            if t == "predator" or t == "veteran" then s = s - 10; why = "they don't trust strangers" end
            if ctx.bedsLeft ~= nil and ctx.bedsLeft < 1 then s = s - 15; why = "there's no room" end
        else
            if t == "predator" or t == "veteran" then s = s + 10; why = "strangers are trouble" end
            if t == "fresh" then s = s - 10; why = "they were strangers once" end
        end
    elseif law == "rule" then
        if t == "predator" then s = s - 12; why = "rules get people killed" elseif t == "fresh" or t == "seasoned" then s = s + 8; why = "it's the right thing" end
        if value == "share" and ctx.hungry then s = s + 15; why = "nobody should eat while others starve" end
    end
    if player ~= nil then s = s + opinion(r, player) / 8 end -- you asked: what they think of you counts
    return s, why
end
function D.ctx(base, people)
    local ctx = { hungry = type(base) == "table" and base.hungry == true }
    if fn(ALifeCampVote, "foodDays") then pcall(function() ctx.days = ALifeCampVote.foodDays(base, #people) end) end
    if fn(ALifeCampVote, "bedsLeft") then pcall(function() ctx.bedsLeft = ALifeCampVote.bedsLeft(base) end) end
    return ctx
end
-- plain words for a count, never numbers
function D.words(yes, total)
    if total <= 0 then return "nobody" end
    local f = yes / total
    if f >= 0.85 then return "nearly all of them" elseif f >= 0.6 then return "most of them" elseif f >= 0.4 then return "about half" elseif f > 0 then return "only a few" end
    return "none of them"
end
-- put a law to a vote: returns passed, { yes, no, loud = why }, or nil, why
function D.voteLaw(player, law, value)
    if D.setting("democracyLaws") == false then return nil, "off" end
    local L = D.LAWS[tostring(law)]
    if L == nil or not L.values[tostring(value)] then return nil, "law" end
    local base = D.baseFor(player)
    if base == nil then return nil, "nobase" end
    local people = D.people(base)
    if #people == 0 then return nil, "nobody" end
    local ctx = D.ctx(base, people)
    local yes, no, loud, loudW = 0, 0, nil, 0
    for _, r in ipairs(people) do
        local s, why = D.view(r, law, value, ctx, player)
        if s >= 5 then yes = yes + 1 elseif s <= -5 then no = no + 1 end
        if why and math.abs(s) > loudW then loud, loudW = first(r) .. " says " .. why, math.abs(s) end
    end
    local passed = yes > no
    local row = D.rowOf(base.id)
    row.lastVote = { law = law, value = value, passed = passed, h = D.hours() }
    if passed then
        if law == "rations" and fn(ALifeRations, "set") then pcall(ALifeRations.set, base, value, "the camp's vote") end
        if law == "door" then row.door = value end
        if law == "rule" then row.rules = type(row.rules) == "table" and row.rules or {}; row.rules[value] = true end
    end
    if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then
        pcall(ALifeChronicle.add, { k = "vote", what = tostring(D.lawWords(law, value)) .. ": " .. (passed and "passed" or "voted down") .. ", " .. D.words(yes, #people) .. " for it" })
    end
    transmit()
    return passed, { yes = yes, no = no, total = #people, loud = loud, words = D.words(yes, #people) }
end
function D.lawWords(law, value)
    if law == "rations" then return ({ full = "full rations", short = "short rations", half = "half rations", guards = "the ones on watch eat first" })[value] end
    if law == "door" then return value == "open" and "the door open to newcomers" or "the door closed to strangers" end
    if law == "rule" then return ({ prisoners = "no killing prisoners", harmless = "no killing people who aren't a threat", steal = "no stealing from other groups", share = "everyone shares food" })[value] end
    return tostring(law)
end

-- ---------------------------------------------------------------------------------------------- no elections
-- your camp doesn't vote on who leads: love, need or fear decides that (ALifeBondsMind)
function D.election(player)
    if D.baseFor(player) == nil then return nil, "nobase" end
    return nil, "bonds"
end
-- the door law leans the camp's vote on newcomers (CampVote voice)
function D.hook()
    local V = ALifeCampVote
    if not fn(V, "voice") or rawget(V, "_demDoor") then return false end
    local orig = V.voice
    V.voice = function(r, q, ctx, ...)
        local s, why = orig(r, q, ctx, ...)
        local base = (type(q) == "table" and q.k == "admit" and fn(V, "residentBase")) and V.residentBase(r) or nil
        if base ~= nil and type(s) == "number" then
            local row = D.store().by[tostring(base.id)]
            if type(row) == "table" and row.door == "open" then s = s + 10; why = why or "the camp voted to keep the door open"
            elseif type(row) == "table" and row.door == "closed" then s = s - 10; why = why or "the camp voted to keep strangers out" end
        end
        return s, why
    end
    rawset(V, "_demDoor", true)
    return true
end
function D.install()
    if D.installed or not fn(ALifeCmd, "onServer") then return D.installed == true end
    ALifeCmd.onServer("demVote", function(player, a)
        if type(a) ~= "table" then return end
        local passed, t = D.voteLaw(player, a.law, a.value)
        ALifeCmd.reply(player, "demResult", { ev = "law", law = a.law, value = a.value, passed = passed, words = type(t) == "table" and t.words or nil, loud = type(t) == "table" and t.loud or nil, why = type(t) == "string" and t or nil })
    end)
    D.installed = true
    return true
end
D.install()
pcall(D.hook)
print(TAG .. " ready v" .. D.VERSION .. ": votes on laws " .. (D.setting("democracyLaws") ~= false and "on" or "off") .. ", no elections (love / need / fear)")
return D
