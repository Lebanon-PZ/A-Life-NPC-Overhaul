-- ALifeTalk_CampEvenings.lua (0.5.7): evenings by the fire.
-- After dinner (19:00-22:00 by default) everyone at home who isn't on duty gathers at the spot you mark
-- (Camp > Evenings > Gather here, ideally by a campfire) and winds down.
-- * With the AI: the usual NPC-to-NPC talk comes more often there, and each of them knows what happened at camp
--   today (dinner, the alarm, a bite, a harvest, a rule you broke), so that's what they talk about.
-- * Without the AI: they say lines built from the same day.
-- Gossip spreads at the fire (your broken rules travel), and an evening together lifts morale a little.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampEvenings") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPEvenings = true
M.cpDefaults.CPEveningStart = 19
M.cpDefaults.CPEveningEnd = 22
M.evCfg = { sitMs = 10000, lineGapMs = 45000, nudgeMs = 15000, ring = 2 }
M.evStats = { evenings = 0, lines = 0, nudges = 0 }

function M.evOn() return M.cpOpt("CPEvenings") ~= false end
function M.evData()
    local d = M.cpData()
    d.evening = type(d.evening) == "table" and d.evening or {}
    d.evening.sat = type(d.evening.sat) == "table" and d.evening.sat or {}
    return d.evening
end
function M.evNow()
    local h = H.hourOfDay()
    local a, b = tonumber(M.cpOpt("CPEveningStart")) or 19, tonumber(M.cpOpt("CPEveningEnd")) or 22
    if a <= b then return h >= a and h < b end
    return h >= a or h < b
end
-- a place in the ring around the fire
local function seat(uid)
    local f = (type(M.grGatherSpot) == "function" and M.grGatherSpot()) or M.evData().fire
    if f == nil then return nil end
    local i = H.hash(uid) % 8
    local o = ({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 }, { 2, 1 }, { -2, -1 }, { 1, -2 }, { -1, 2 } })[i + 1]
    return { x = f.x + o[1], y = f.y + o[2], z = f.z }
end
-- who's sitting at the fire right now
function M.evSeated(player)
    local out = {}
    for u, j in pairs(M.cpJobs) do if j.kind == "evening" and j.seated then out[#out + 1] = u end end
    table.sort(out)
    return out
end

M.cpAddJob({
    kind = "evening", order = 8,
    pick = function(uid, shell, player, b, now)
        if not M.evOn() or not M.evNow() then return nil end
        if M.evData().fire == nil and not (type(M.grGatherSpot) == "function" and M.grGatherSpot()) then return nil end
        return { key = "evening:" .. uid }
    end,
    spot = function(j) return seat(j.key) end,
    ms = function(j) return M.evCfg.sitMs end,
    run = function(j, uid, shell, player)
        if not M.evNow() then return "done" end
        if not j.seated then
            j.seated = true
            M.evData().sat[uid] = H.hours()
        end
        return "again"
    end,
})

-- what today was like, as lines people would say (no AI)
local EVENT = {
    meal = { "Good food tonight. Somebody tell the cook.", "First time in a while I'm not hungry." },
    thin = { "My stomach's still growling.", "Half a bowl. We need to find more food." },
    nomeal = { "No dinner. Again. This can't go on.", "Can't sleep when you're this hungry." },
    alarm = { "Thought we were done for today. When that alarm went...", "My hands are still shaking from earlier." },
    bite = { "I keep thinking about %s.", "Nobody's said it, but we're all thinking about %s." },
    harvest = { "Field's coming along. We might make it through winter.", "Fresh food. I'd almost forgotten." },
    rule = { "Did you see what the boss did today? After all that talk about rules?", "Rules for us, not for them, I guess." },
    gear = { "Feels better with a real weapon at hand.", "Checked my gun twice tonight." },
    morale = { "Glad they stayed. We need every pair of hands.", "Thought we were losing someone today." },
    death = { "I miss %s.", "It's quiet without %s." },
}
local IDLE = {
    "You ever think about what you'd be doing right now? Before, I mean.",
    "I used to hate Mondays. I'd kill for a Monday.",
    "Remember coffee? Real coffee?",
    "Somebody tell a story. Anything. I need to hear something that isn't screaming.",
    "Saw a deer today. First one in weeks.",
    "Think anyone's still out there? Like, a real government?",
    "My mom used to sing this song while she cooked. I can't remember the words anymore.",
    "Fire's nice. Let's just sit a while.",
}
local function eventKey(e)
    if e.k == "meal" then
        if string.find(e.t, "no dinner") then return "nomeal" end
        if string.find(e.t, "thin") then return "thin" end
        return "meal"
    end
    return e.k
end
local function nameIn(e) return string.match(e.t, "^(%S+)") end
function M.evLine(uid)
    local today = M.cpToday(24)
    -- the newest thing that has a line, picked per speaker so two people don't say the same
    for i = #today, 1, -1 do
        local e = today[i]
        local k = eventKey(e)
        local pool = EVENT[k]
        if pool and (H.hash(uid .. i) % 3) ~= 0 then
            local l = H.pickLine(pool, uid .. e.h)
            if string.find(l, "%%s") then l = string.format(l, nameIn(e) or "them") end
            return l
        end
    end
    return H.pickLine(IDLE, uid .. math.floor(H.hours()))
end

-- the evening tick: gossip once, AI talk nudged, canned lines without the AI
M.evNextLine = 0
function M.evTick(player)
    if not M.evOn() or not M.evNow() then return end
    local ev = M.evData()
    local seated = M.evSeated(player)
    if #seated < 2 then return end
    local day = math.floor(H.hours() / 24)
    if ev.day ~= day then
        ev.day = day
        M.evStats.evenings = M.evStats.evenings + 1
        if H.fn(M, "cpHearsay") then pcall(M.cpHearsay, player) end -- gossip goes round the fire
        H.log("evening by the fire: " .. #seated .. " people")
    end
    local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
    local aiUp = H.fn(M, "bridgeAlive") and M.bridgeAlive(now)
    if aiUp then
        -- the AI writes the talk: bring the next NPC-to-NPC conversation forward
        if M.ambientNextAt and M.ambientNextAt > now + M.evCfg.nudgeMs then M.ambientNextAt = now + M.evCfg.nudgeMs; M.evStats.nudges = M.evStats.nudges + 1 end
        return
    end
    if now < M.evNextLine then return end
    M.evNextLine = now + M.evCfg.lineGapMs
    local who = seated[(H.hash(tostring(now)) % #seated) + 1]
    if H.say(H.shellFor(who), M.evLine(who)) then M.evStats.lines = M.evStats.lines + 1 end
end

-- morale: an evening together helps a little for a day
M.cpMoraleHooks = M.cpMoraleHooks or {}
table.insert(M.cpMoraleHooks, function(uid)
    if not M.evOn() then return 0 end
    local at = M.evData().sat[tostring(uid)]
    if at and H.hours() - at < 24 then return -1.5 end
    return 0
end)

-- AI: by the fire, they know where they are and what today was
M.cpExtras = M.cpExtras or {}
table.insert(M.cpExtras, function(req, player, listener)
    if not M.evOn() or not M.evNow() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local uid = tostring(listener.record.uid)
    local j = M.cpJobs[uid]
    if not (j and j.kind == "evening" and j.seated) then return end
    local names = {}
    for _, u in ipairs(M.evSeated(player)) do if u ~= uid then names[#names + 1] = H.firstName(u) end end
    local evs = {}
    for _, e in ipairs(M.cpToday(24)) do evs[#evs + 1] = e.t end
    while #evs > 5 do table.remove(evs, 1) end
    return "It's evening and you're sitting around the fire" .. (#names > 0 and (" with " .. table.concat(names, ", ")) or "")
        .. ". " .. (#evs > 0 and ("Today at camp: " .. table.concat(evs, "; ") .. ". ") or "")
        .. "Wind down: talk about the day, gossip, or tell a story from before."
end)

-- menu: Camp > Evenings
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local em, eo = child("Evenings")
    if not M.evOn() then off(eo, "Evenings are off in this world's sandbox settings.") end
    local ev = M.evData()
    if ev.fire and ev.fire.x == x and ev.fire.y == y and ev.fire.z == z then
        em:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_gathering_spot_anymore", "Not the gathering spot anymore"), nil, function() M.cpAct("evFireOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = em:addOption(ev.fire and "Gather here instead" or "Gather here (the fire)", nil, function() M.cpAct("evFire", x, y, z, nil, nil, player) end)
        if not inRange then off(o, why or "Too far from your base.") end
    end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender)
M.cpActs = M.cpActs or {}
M.cpActs.evFireOff = function() M.evData().fire = nil end
M.cpActs.evFire = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    M.evData().fire = { x = x, y = y, z = z }
    H.halo("After dinner, everyone who isn't on duty sits here and winds down.")
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function() local f = M.evData().fire; if f then return { { f, 1, 0.45, 0.1 } } end end)

if type(Events) == "table" and Events.OnTick then
    local last = 0
    ALifeHealth.add(Events.OnTick, "ALifeTalk_CampEvenings", function()
        if M._evDead then return end
        local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
        if now - last < 2000 then return end
        last = now
        local ok, err = pcall(function() local p = H.thePlayer(); if p then M.evTick(p) end end)
        if not ok then M._evDead = true; H.log("evening tick error, off for this session: " .. tostring(err)) end
    end)
end
