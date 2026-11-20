-- ALifeTalk_CampGrief.lua (0.5.8): what follows a death at camp.
-- The mod already grieves person by person (ALifeLLMTalk_Grief: who mourns whom, how hard, fading over days).
-- This adds the camp around it:
-- * a card when one of your own dies: hold a funeral at dusk, or "no time for that" (people remember which)
-- * the funeral: that evening everyone gathers at the memorial (or the fire) instead, someone says a few words,
--   and the mourners who were there carry it lighter
-- * grief weighs on morale (the closer they were, the more), less after a funeral
-- * a memorial (Camp > Memorial) that lists the dead; on a week, a month, a hundred days, someone remembers
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampGrief") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPGrief = true
M.grCfg = { anniversaries = { 7, 30, 100, 365 }, moraleMax = 4 }
M.grStats = { deaths = 0, funerals = 0, skipped = 0, remembered = 0 }

function M.grOn() return M.cpOpt("CPGrief") ~= false end
function M.grData()
    local d = M.cpData()
    d.grief = type(d.grief) == "table" and d.grief or {}
    local g = d.grief
    g.dead = type(g.dead) == "table" and g.dead or {}
    return g
end
local function today() return math.floor(H.hours() / 24) end
local function lens(uid) local l = {}; pcall(function() l = M.lens(tostring(uid)) end); return l end
local function L(l, k) return tonumber(l[k]) or 0 end
-- was this one of ours? (dead now, so ask the settler / resident records, not "who's home")
local function wasOurs(uid, r)
    if H.fn(M, "settlerOf") and M.settlerOf(uid) ~= nil then return true end
    return type(r) == "table" and type(r.memory) == "table" and type(r.memory.jimmyResident) == "table"
end
-- how hard a camp member grieves this dead person right now (0..1), from the grief layer
function M.grHow(mourner, deadUid)
    if not H.fn(M, "griefOf") or not H.fn(M, "griefIntensity") then return 0 end
    local e = M.griefOf(tostring(mourner))[tostring(deadUid)]
    if type(e) ~= "table" then return 0 end
    local ok, v = pcall(M.griefIntensity, e, H.hours())
    return ok and tonumber(v) or 0
end
local function mourners(deadUid, player)
    local out = {}
    for _, u in ipairs(M.cpPeople(player)) do
        local v = M.grHow(u, deadUid)
        if v > 0.05 then out[#out + 1] = { uid = u, v = v } end
    end
    table.sort(out, function(a, b) return a.v > b.v end)
    return out
end

-- where people gather tonight: the memorial on a funeral or remembrance day
function M.grGatherSpot()
    if not M.grOn() then return nil end
    local g = M.grData()
    if g.memorial == nil then return nil end
    if (g.funeral and g.funeral.day == today()) or g.rememberDay == today() then return g.memorial end
    return nil
end

local EULOGY = { "%s would've hated all this fuss. So let's keep it short. We'll miss you.", "%s kept us going more than once. Rest easy.", "I didn't know %s long. Long enough to know we lost a good one." }
local FUNERAL = { "Rest easy, %s.", "Wherever you are, %s, it's better than here.", "I keep expecting %s to walk in.", "We'll keep going. For %s." }
local REMEMBER = { "A %s since we lost %s.", "It's been a %s. I still think about %s every day.", "%s. A %s already." }
local SPAN = { [7] = "week", [30] = "month", [100] = "hundred days", [365] = "year" }

-- a death at camp
table.insert(M.cpDeathHooks, function(body, uid, killer)
    if not M.grOn() then return false end
    uid = tostring(uid)
    local r = H.rec(uid)
    if not wasOurs(uid, r) then return false end
    local g = M.grData()
    for _, e in ipairs(g.dead) do if e.uid == uid then return false end end
    local player = H.thePlayer()
    local name = H.firstName(uid)
    local how = nil
    if player and H.fn(M, "killerOf") then local ok, kn = pcall(M.killerOf, killer, player, body); if ok then how = kn end end
    local e = { uid = uid, name = name, day = today(), h = H.hours(), how = how and tostring(how) or nil }
    table.insert(g.dead, e)
    M.grStats.deaths = M.grStats.deaths + 1
    M.cpLog("death", name .. " died" .. (e.how and (", " .. e.how) or ""))
    H.log("death at camp: " .. name .. " (" .. uid .. ")")
    -- the card: funeral or not
    local ms = mourners(uid, player)
    local took = {}
    for i = 1, math.min(2, #ms) do took[#took + 1] = H.firstName(ms[i].uid) end
    local funeralDay = H.hourOfDay() < (tonumber(M.cpOpt("CPEveningStart")) or 19) and today() or today() + 1
    local function hold()
        g.funeral = { uid = uid, name = name, day = funeralDay, said = false, came = {} }
        M.grStats.funerals = M.grStats.funerals + 1
        H.halo("A funeral for " .. name .. " at dusk" .. (g.memorial and " by the memorial." or "."), 200, 200, 230)
        local NO = H.PA().NpcOpinion
        for _, u in ipairs(M.cpPeople(player)) do
            local l = lens(u)
            local v = math.floor(2 * (L(l, "devout") + L(l, "kind") + L(l, "loyal")) + 0.5)
            local rr = H.rec(u)
            if v > 0 and rr and NO and NO.adjust then pcall(NO.adjust, rr, player, math.min(v, 4), "held a funeral for " .. name) end
        end
    end
    local function skip()
        M.grStats.skipped = M.grStats.skipped + 1
        local NO = H.PA().NpcOpinion
        for _, u in ipairs(M.cpPeople(player)) do
            local l = lens(u)
            local v = -math.floor(2 * (L(l, "devout") + L(l, "kind") + L(l, "loyal")) + 4 * M.grHow(u, uid) + 0.5)
            local rr = H.rec(u)
            if v < 0 and rr and NO and NO.adjust then pcall(NO.adjust, rr, player, math.max(v, -6), "no time to bury " .. name) end
        end
        M.cpLog("death", "you had no time for " .. name .. "'s funeral")
    end
    if ALifeSide.canOutCard() then
        ALifeSide.outCard(player, { id = "death:" .. uid, title = name .. " is dead", default = 1,
            text = name .. " died" .. (e.how and (", " .. e.how) or "") .. "." .. (#took > 0 and (" " .. table.concat(took, " and ") .. " took it hardest.") or "")
                .. " <LINE> <LINE> Hold a funeral at dusk? People remember either way.",
            choices = { { label = "Hold a funeral at dusk", fn = hold }, { label = "No time for that", fn = skip } } })
    else
        hold()
    end
    return false
end)

-- the evening: a funeral (someone says a few words first), or remembering on an anniversary
local baseLine = M.evLine
function M.evLine(uid)
    local g = M.grData()
    local f = g.funeral
    if M.grOn() and f and f.day == today() then return string.format(H.pickLine(FUNERAL, uid .. f.uid), f.name) end
    if M.grOn() and g.rememberDay == today() and g.rememberName then
        return string.format(H.pickLine(FUNERAL, uid .. g.rememberName), g.rememberName)
    end
    return baseLine and baseLine(uid) or ""
end
M.grTickDay = -1
function M.grTick(player)
    if not M.grOn() then return end
    local g = M.grData()
    local day = today()
    -- once a day: anniversaries
    if M.grTickDay ~= day then
        M.grTickDay = day
        g.rememberDay, g.rememberName = nil, nil
        for _, e in ipairs(g.dead) do
            local span = SPAN[day - (tonumber(e.day) or day)]
            if span then
                g.rememberDay, g.rememberName = day, e.name
                M.grStats.remembered = M.grStats.remembered + 1
                local ms = mourners(e.uid, player)
                local who = ms[1] and ms[1].uid or M.cpPeople(player)[1]
                local line = H.pickLine(REMEMBER, e.name .. day)
                if string.find(line, "^%%s%.") then line = string.format(line, e.name, span) else line = string.format(line, span, e.name) end
                if who then H.say(H.shellFor(who), line) end
                H.halo("A " .. span .. " since " .. e.name .. " died.", 200, 200, 230)
                M.cpLog("death", "a " .. span .. " since " .. e.name .. " died")
                break
            end
        end
    end
    -- the funeral: when people are gathered, the closest mourner says a few words, once
    local f = g.funeral
    if f and f.day == day and not f.said and H.fn(M, "evSeated") then
        local seated = M.evSeated(player)
        if #seated >= 1 then
            f.said = true
            local ms = mourners(f.uid, player)
            local who = (ms[1] and ms[1].uid) or seated[1]
            H.say(H.shellFor(who), string.format(H.pickLine(EULOGY, who .. f.uid), f.name))
            for _, u in ipairs(seated) do f.came[u] = true end
            M.cpLog("death", "we buried " .. f.name .. " at dusk")
        end
    elseif f and f.day == day and not f.said and g.memorial == nil and not (H.fn(M, "evData") and M.evData().fire)
        and H.hourOfDay() >= (tonumber(M.cpOpt("CPEveningStart")) or 19) then
        -- nowhere to gather: the closest mourner says it wherever they are
        f.said = true
        local ms = mourners(f.uid, player)
        local who = (ms[1] and ms[1].uid) or M.cpPeople(player)[1]
        if who then H.say(H.shellFor(who), string.format(H.pickLine(EULOGY, who .. f.uid), f.name)) end
        M.cpLog("death", "we said goodbye to " .. f.name .. " at dusk")
    elseif f and f.day == day and f.said and H.fn(M, "evSeated") then
        for _, u in ipairs(M.evSeated(player)) do f.came[u] = true end
    end
end

-- grief weighs on morale; lighter for those who came to the funeral
M.cpMoraleHooks = M.cpMoraleHooks or {}
table.insert(M.cpMoraleHooks, function(uid)
    if not M.grOn() then return 0 end
    local g = M.grData()
    local worst = 0
    for _, e in ipairs(g.dead) do
        local v = M.grHow(uid, e.uid)
        if g.funeral and g.funeral.uid == e.uid and g.funeral.came and g.funeral.came[tostring(uid)] then v = v * 0.5 end
        if v > worst then worst = v end
    end
    return math.min(M.grCfg.moraleMax, 4 * worst)
end)

-- AI: anniversaries and funerals
M.cpExtras = M.cpExtras or {}
table.insert(M.cpExtras, function(req, player, listener)
    if not M.grOn() then return end
    local g = M.grData()
    if g.funeral and g.funeral.day == today() then return "Today the camp buries " .. g.funeral.name .. "." end
    if g.rememberDay == today() and g.rememberName then return "Today is an anniversary of " .. g.rememberName .. "'s death. People are quiet." end
end)

-- menu: Camp > Memorial
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local mm, mo = child("Memorial")
    if not M.grOn() then off(mo, "Grief at camp is off in this world's sandbox settings.") end
    local g = M.grData()
    if g.memorial and g.memorial.x == x and g.memorial.y == y and g.memorial.z == z then
        mm:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_memorial_anymore", "Not the memorial anymore"), nil, function() M.cpAct("grMemorialOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = mm:addOption(g.memorial and "Move the memorial here" or "Memorial here", nil, function() M.cpAct("grMemorial", x, y, z, nil, nil, player) end)
        if not inRange then off(o, why or "Too far from your base.") end
    end
    for i = #g.dead, math.max(1, #g.dead - 5), -1 do
        local e = g.dead[i]
        off(mm:addOption(e.name .. ", day " .. tostring((tonumber(e.day) or 0) + 1)), e.how and ("Died: " .. e.how) or "Gone.")
    end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender)
M.cpActs = M.cpActs or {}
M.cpActs.grMemorialOff = function() M.grData().memorial = nil end
M.cpActs.grMemorial = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    M.grData().memorial = { x = x, y = y, z = z }
    H.halo("Memorial set. Funerals and anniversaries gather here.")
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function() local m = M.grData().memorial; if m then return { { m, 0.7, 0.7, 0.9 } } end end)

if type(Events) == "table" and Events.OnTick then
    local last = 0
    ALifeHealth.add(Events.OnTick, "ALifeTalk_CampGrief", function()
        if M._grDead then return end
        local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
        if now - last < 3000 then return end
        last = now
        local ok, err = pcall(function() local p = H.thePlayer(); if p then M.grTick(p) end end)
        if not ok then M._grDead = true; H.log("grief tick error, off for this session: " .. tostring(err)) end
    end)
end
