-- ALifeTalk_CampAlarm.lua (0.5.2): the camp alarm.
-- Sound it (menu, voice, or the watch/patrol spotting a horde or armed strangers) and everyone at the base drops
-- what they're doing: fighters run to their posts, everyone else gets in the safe room, the lights go out.
-- All clear when you say so, or once it's been quiet for a while.
-- Loads after ALifeTalk_Camp.lua (file name sorts after it) and uses its helpers on M.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampAlarm") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpData) ~= "function" then return end

local TAG = "[ALifeAlarm]"
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function rawMs() return (type(getTimestampMs) == "function" and getTimestampMs()) or 0 end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pickLine(list, seed) return list[(hash(seed) % #list) + 1] end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function isA(o, cls) local ok, v = pcall(function() return instanceof(o, cls) end); return ok and v == true end
local function thePlayer() return M.homePlayer and M.homePlayer() or ALifeSide.you() end -- MP: the base's player (Main)
local function shellFor(uid) local t = PA().Talk; return fn(t, "shellFor") and t.shellFor(tostring(uid)) or nil end
local function halo(text, r, g, b)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- MP: the player being handled, else everyone
        if type(ALifeOut) == "table" then ALifeOut.note(ALifeSide.cur, tostring(text), r or 255, g or 170, b or 110) end
        return
    end
    if type(M.momNote) == "function" then M.momNote(text, r or 255, g or 170, b or 110); return end
    local p = thePlayer()
    if p then pcall(ALifeLetter, p, tostring(text), r or 255, g or 170, b or 110) end
end
local function say(shell, line)
    if shell == nil or line == nil then return false end
    local ok, res = pcall(function() return PA().Speech.say(shell, line, {}) end)
    return ok and res ~= false
end
local function firstName(uid)
    local r = fn(PA().ActorRegistry, "read") and PA().ActorRegistry.read(tostring(uid)) or nil
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return "Someone"
end
local retired = {}
local function tryOnce(id, f)
    if retired[id] then return false end
    local ok, err = pcall(f)
    if ok then return true end
    retired[id] = true
    log(id .. " failed, off for this session: " .. tostring(err))
    return false
end

M.cpDefaults.CPAlarm = true
M.cpDefaults.CPAlarmAuto = true
M.cpDefaults.CPAlarmFighters = 2
M.cpDefaults.CPAlarmLights = true
M.cpDefaults.CPAlarmClear = 30
M.cpDefaults.CPAlarmBell = false
M.alCfg_bell = { radius = 60, volume = 60 }
M.alCfg = { scanMs = 5000, scanTiles = 30, maxPosts = 6, lightRadius = 25, arriveTiles = 1.8 }
M.alStats = { raised = 0, cleared = 0, lightsOff = 0, arrived = 0 }

----------------------------------------------------------------------------------------------------------------
-- state (saved with the camp)
----------------------------------------------------------------------------------------------------------------
function M.alData()
    local d = M.cpData()
    d.alarm = type(d.alarm) == "table" and d.alarm or {}
    local a = d.alarm
    a.posts = type(a.posts) == "table" and a.posts or {}
    a.lights = type(a.lights) == "table" and a.lights or {}
    a.said = type(a.said) == "table" and a.said or {}
    return a
end
function M.alOn() return M.cpOpt("CPAlarm") ~= false and M.alData().on == true end
-- the camp is at alarm and this person lives here: every other camp/work/build job stands down
function M.alHolds(uid, player)
    if not M.alOn() then return false end
    if type(M.cbKnown) == "function" and M.cbKnown(uid) then return false end -- the bitten stay in quarantine
    return M.cpIsHome(tostring(uid), player or thePlayer())
end

----------------------------------------------------------------------------------------------------------------
-- who fights: 1 guards only, 2 guards + anyone who'd make a decent guard, 3 everyone but cooks and medics
----------------------------------------------------------------------------------------------------------------
function M.alFighter(uid)
    local role = M.cpRoleOf(uid)
    if role == "guard" then return true end
    local mode = tonumber(M.cpOpt("CPAlarmFighters")) or 2
    if role == "medic" or role == "cook" then return false end
    if mode >= 3 then return true end
    if mode <= 1 then return false end
    return M.cpFit(uid, "guard") >= 1.0
end
-- where this person goes: their post (fighters, spread over the posts) or the safe room (everyone else)
function M.alSpot(uid, player)
    local a = M.alData()
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    if M.alFighter(uid) then
        if #a.posts == 0 then return b and { x = b.x, y = b.y, z = b.z or 0 } or nil, "post" end
        local fighters = {}
        for _, u in ipairs(M.cpPeople(player)) do if M.alFighter(u) then fighters[#fighters + 1] = u end end
        local i = 1
        for k, u in ipairs(fighters) do if u == tostring(uid) then i = k end end
        return a.posts[((i - 1) % #a.posts) + 1], "post"
    end
    if a.safe then return a.safe, "safe" end
    return nil, "safe" -- no safe room marked: they stop where they are and keep their heads down
end

----------------------------------------------------------------------------------------------------------------
-- lights out (B42 light switches inside the base). Remember which we turned off, put them back on all clear.
----------------------------------------------------------------------------------------------------------------
local function eachSwitch(b, f)
    local x1, y1, x2, y2 = b.x1, b.y1, b.x2, b.y2
    if x1 == nil then local r = M.alCfg.lightRadius; x1, y1, x2, y2 = b.x - r, b.y - r, b.x + r, b.y + r end
    local cell = getCell()
    for z = 0, 2 do
        for x = math.floor(x1), math.floor(x2) do
            for y = math.floor(y1), math.floor(y2) do
                local sq = cell:getGridSquare(x, y, z)
                if sq then
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if isA(o, "IsoLightSwitch") then f(o, x, y, z) end
                    end
                end
            end
        end
    end
end
function M.alLightsOut(player)
    if M.cpOpt("CPAlarmLights") == false then return 0 end
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    if b == nil then return 0 end
    local a = M.alData()
    local n = 0
    tryOnce("lightsOut", function()
        eachSwitch(b, function(o, x, y, z)
            if o:isActivated() then
                o:setActive(false, false, true)
                a.lights[#a.lights + 1] = { x = x, y = y, z = z }
                n = n + 1
            end
        end)
    end)
    M.alStats.lightsOff = M.alStats.lightsOff + n
    return n
end
function M.alLightsBack()
    local a = M.alData()
    if #a.lights == 0 then return 0 end
    local want = {}
    for _, p in ipairs(a.lights) do want[p.x .. ":" .. p.y .. ":" .. p.z] = true end
    local n = 0
    tryOnce("lightsBack", function()
        local cell = getCell()
        for _, p in ipairs(a.lights) do
            local sq = cell:getGridSquare(p.x, p.y, p.z)
            if sq then
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if isA(o, "IsoLightSwitch") and not o:isActivated() then o:setActive(true, false, true); n = n + 1 end
                end
            end
        end
    end)
    a.lights = {}
    return n
end

----------------------------------------------------------------------------------------------------------------
-- raise / clear
----------------------------------------------------------------------------------------------------------------
local RAISE = {
    horde = { "Horde coming! Everyone to your posts!", "They're coming! Posts, now! Lights out!" },
    hostile = { "Armed people outside! Get to your posts!", "We've got company! Posts! Everyone else, inside!" },
    you = { "Alarm! Everyone to your posts!", "You heard them! Posts! Move!" },
}
local CLEAR = { "All clear. Back to it.", "Looks like it passed. Stand down.", "Alright. All clear." }
local POSTED = { "In position.", "I've got this side.", "On my post.", "Ready." }
local HIDING = { "We're in.", "Inside. Door's shut.", "We're safe. Go." }
local REFUSE_NO_PEOPLE = "Nobody's home to hear it."

-- the watch spotted something: with cards on, ask first ("To your posts!" / "I'll handle it")
function M.alRaise(reason, player, said)
    if reason == "you" or not ALifeSide.canOutCard() or M.alOn() or M.cpOpt("CPAlarm") == false or M.cpOpt("CPAlarmAuto") == false then
        return M.alRaiseNow(reason, player)
    end
    local a = M.alData()
    if (tonumber(a.snoozeUntil) or -1) > hours() then return false end
    player = player or thePlayer()
    if #M.cpPeople(player) == 0 then return false end
    ALifeSide.outCard(player, {
        id = "alarm", title = reason == "horde" and "Horde coming" or "Armed strangers",
        text = (said and (said .. " <LINE> <LINE> ") or "") .. "Sound the alarm? Fighters go to their posts (and the armory), everyone else to the safe room, lights out, all work stops.",
        choices = {
            { label = "To your posts!", fn = function() M.alRaiseNow(reason, player) end },
            { label = "I'll handle it", fn = function() M.alData().snoozeUntil = hours() + 0.25 end },
        },
        default = 1,
    })
    return true
end
-- reason: "horde" | "hostile" | "you"
function M.alRaiseNow(reason, player)
    if M.cpOpt("CPAlarm") == false then return false, "The camp alarm is off in this world's sandbox settings." end
    player = player or thePlayer()
    local a = M.alData()
    if reason ~= "you" and M.cpOpt("CPAlarmAuto") == false then return false end
    local people = M.cpPeople(player)
    if #people == 0 then return false, REFUSE_NO_PEOPLE end
    local h = hours()
    if a.on then a.seenAt = h; return true end
    a.on, a.reason, a.since, a.seenAt, a.said, a.geared = true, reason, h, h, {}, {}
    M.alStats.raised = M.alStats.raised + 1
    for _, uid in ipairs(people) do if fn(M, "cpRelease") then pcall(M.cpRelease, uid, shellFor(uid)) end end
    local lights = M.alLightsOut(player)
    -- the bell: everyone hears it. So does everything dead within 60 tiles.
    if M.cpOpt("CPAlarmBell") == true then
        local b = fn(M, "wzBase") and M.wzBase(player) or nil
        if b and type(addSound) == "function" then
            pcall(addSound, player, math.floor(b.x), math.floor(b.y), math.floor(b.z or 0), M.alCfg_bell.radius, M.alCfg_bell.volume)
            halo("The bell rings out. Everything for sixty tiles heard it.", 255, 150, 90)
        end
    end
    -- someone shouts it: a guard if there is one
    local caller = nil
    for _, uid in ipairs(people) do if M.cpRoleOf(uid) == "guard" then caller = uid; break end end
    caller = caller or people[1]
    local line = pickLine(RAISE[reason] or RAISE.you, caller .. math.floor(h))
    if reason ~= "you" then say(shellFor(caller), line) end
    halo("ALARM: " .. (reason == "horde" and "horde" or reason == "hostile" and "armed strangers" or "posts") .. (lights > 0 and (". " .. lights .. " lights out.") or "."), 255, 120, 90)
    if type(M.cpLog) == "function" then M.cpLog("alarm", reason == "horde" and "a horde came and the alarm went up" or reason == "hostile" and "armed strangers came and the alarm went up" or "you sounded the alarm") end
    log("alarm raised (" .. tostring(reason) .. ", " .. #people .. " people, " .. lights .. " lights out)")
    return true, line
end
function M.alClear(player, why)
    local a = M.alData()
    if not a.on then return false end
    player = player or thePlayer()
    a.on, a.reason, a.said = false, nil, {}
    M.alStats.cleared = M.alStats.cleared + 1
    local back = M.alLightsBack()
    local people = M.cpPeople(player)
    for _, uid in ipairs(people) do M.cpNextTry[uid] = nil end
    if why ~= "you" and people[1] then say(shellFor(people[1]), pickLine(CLEAR, people[1] .. math.floor(hours()))) end
    halo("All clear." .. (back > 0 and (" Lights back on.") or ""), 180, 230, 160)
    log("all clear (" .. tostring(why) .. ")")
    return true
end
-- while it's up: look around the base; quiet long enough -> all clear
M.alScanAt = 0
function M.alTick(player)
    if not M.alOn() then return end
    local now = rawMs()
    if now - M.alScanAt < M.alCfg.scanMs then return end
    M.alScanAt = now
    local b = fn(M, "wzBase") and M.wzBase(player) or nil
    if b == nil then return end
    local a = M.alData()
    local s = M.cpSpot(b.x, b.y, M.alCfg.scanTiles, player)
    if s.zombies > 0 or s.hostile then a.seenAt = hours() end
    local mins = tonumber(M.cpOpt("CPAlarmClear")) or 30
    if mins > 0 and (hours() - (tonumber(a.seenAt) or 0)) * 60 >= mins then M.alClear(player, "quiet") end
end

----------------------------------------------------------------------------------------------------------------
-- A-Life behaviour module: get to your spot and hold it
----------------------------------------------------------------------------------------------------------------
function M.alEvaluate(actor, shell, context)
    if shell == nil or type(context) ~= "table" or type(actor) ~= "table" then return nil end
    if not M.alOn() then return nil end
    if context.threat ~= nil then return nil end -- A-Life's own fight-or-flee handles the moment itself
    local uid = tostring(actor.uid)
    local player = M.homePlayer and M.homePlayer(pos(shell)) or thePlayer() -- MP: the base's player nearest them
    if not M.cpIsHome(uid, player) then return nil end
    if type(M.cbKnown) == "function" and M.cbKnown(uid) then return nil end
    local now = tonumber(context.now) or rawMs()
    local spot, kind = M.alSpot(uid, player)
    local a = M.alData()
    if spot then
        local sx, sy = pos(shell)
        if sx == nil then return nil end
        if d2(sx, sy, spot.x + 0.5, spot.y + 0.5) > M.alCfg.arriveTiles ^ 2 then
            if type(context.startMovement) ~= "function" then return nil end
            return context.startMovement(actor, shell, { x = spot.x + 0.5, y = spot.y + 0.5, z = spot.z or 0 }, "chatplus_alarm",
                { pace = "run", timeoutMs = 15000, tolerance = 1.2 })
        end
    end
    if kind == "armory" then -- grabbing gear on the way to the post (CampArmory)
        if type(M.arAlarmStop) == "function" then pcall(M.arAlarmStop, uid, shell) end
        return { kind = "idle", intent = "chatplus_alarm", cooldownUntilMs = now + 800 }
    end
    if not a.said[uid] then
        a.said[uid] = true
        M.alStats.arrived = M.alStats.arrived + 1
        if hash(uid .. tostring(a.since)) % 3 == 0 then say(shell, pickLine(kind == "post" and POSTED or HIDING, uid .. tostring(a.since))) end
    end
    if type(context.setActivity) == "function" then pcall(context.setActivity, actor, "idle", "chatplus_alarm") end
    return { kind = "idle", intent = "chatplus_alarm", cooldownUntilMs = now + 1500 }
end
function M.alRegister()
    if M._alRegistered then return true end
    local reg = PA().ModuleRegistry
    if not fn(reg, "register") then return false end
    local ok, done, why = pcall(reg.register, {
        id = "chatplus_alarm", label = "NPC Overhaul: camp alarm",
        summary = "When the alarm goes up, fighters run to their posts and everyone else gets in the safe room.",
        kind = "orders", priority = 90, defaultEnabled = true,
        evaluate = function(actor, shell, context)
            local ok2, res = pcall(M.alEvaluate, actor, shell, context)
            if not ok2 then
                if not M._alErr then M._alErr = true; log("module error (logged once): " .. tostring(res)) end
                return nil
            end
            return res
        end,
    })
    if ok and (done == true or (done == false and tostring(why):find("duplicate", 1, true))) then
        local prof = PA().BehaviorProfiles
        if type(prof) == "table" and type(prof.definitions) == "table" then
            for _, def in ipairs(prof.definitions) do
                if type(def) == "table" and type(def.overlays) == "table" then def.overlays.chatplus_alarm = true end
            end
        end
        M._alRegistered = true
        log("registered with A-Life's behaviour modules (priority 90)")
        return true
    end
    log("could not register with A-Life: " .. tostring(why or done))
    return false
end

----------------------------------------------------------------------------------------------------------------
-- menu: Camp > Alarm (called from the camp menu)
----------------------------------------------------------------------------------------------------------------
function M.alMenu(child, off, player, x, y, z, inRange, why)
    local am, ao = child("Alarm")
    if M.cpOpt("CPAlarm") == false then off(ao, "The camp alarm is off in this world's sandbox settings.") end
    local a = M.alData()
    if a.on then
        am:addOption(ALifeTr("IGUI_ALCP_Menu_All_clear", "All clear"), nil, function() M.cpAct("alClear", nil, nil, nil, nil, nil, player) end)
    else
        local o = am:addOption(ALifeTr("IGUI_ALCP_Menu_Sound_the_alarm", "Sound the alarm"), nil, function() M.cpAct("alRaise", nil, nil, nil, nil, nil, player) end)
        if #M.cpPeople(player) == 0 then off(o, "Nobody's home to hear it.") end
    end
    local here = nil
    for i, p in ipairs(a.posts) do if p.x == x and p.y == y and p.z == z then here = i end end
    if here then
        am:addOption("Remove post " .. here, nil, function() M.cpAct("alPostRemove", x, y, z, nil, nil, player) end)
    else
        local o = am:addOption("Post here (" .. (#a.posts + 1) .. ")", nil, function() M.cpAct("alPost", x, y, z, nil, nil, player) end)
        if #a.posts >= M.alCfg.maxPosts then off(o, "You already have " .. #a.posts .. " posts (max " .. M.alCfg.maxPosts .. ").")
        elseif not inRange then off(o, why or "Too far from your base.") end
    end
    local isSafe = a.safe and a.safe.x == x and a.safe.y == y and a.safe.z == z
    if isSafe then
        am:addOption(ALifeTr("IGUI_ALCP_Menu_Remove_the_safe_room", "Remove the safe room"), nil, function() M.cpAct("alSafeOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = am:addOption(a.safe and "Move the safe room here" or "Safe room here", nil, function() M.cpAct("alSafe", x, y, z, nil, nil, player) end)
        if not inRange then off(o, why or "Too far from your base.") end
    end
    if #a.posts > 0 then am:addOption(ALifeTr("IGUI_ALCP_Menu_Clear_all_posts", "Clear all posts"), nil, function() M.cpAct("alPostsClear", nil, nil, nil, nil, nil, player) end) end
end
-- pre-1.0 MP (P4): the alarm menu's writes (run by M.cpAct: SP directly, MP on the server as the sender)
local function inReach(player, x, y) if fn(M, "wzInRange") then return M.wzInRange(player, x, y) end; return true end
M.cpActs = M.cpActs or {}
M.cpActs.alClear = function(player) return M.alClear(player, "you") end
M.cpActs.alRaise = function(player)
    local ok, msg = M.alRaise("you", player)
    if not ok and msg then halo(msg) end
    return ok == true
end
M.cpActs.alPostRemove = function(player, x, y, z)
    local a = M.alData()
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    for i, p in ipairs(a.posts) do if p.x == x and p.y == y and p.z == z then table.remove(a.posts, i); return true end end
    return false
end
M.cpActs.alPost = function(player, x, y, z)
    local a = M.alData()
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or #a.posts >= M.alCfg.maxPosts or not inReach(player, x, y) then return false end
    a.posts[#a.posts + 1] = { x = x, y = y, z = z }
    halo("Post " .. #a.posts .. " set. On the alarm, fighters spread out over the posts.")
end
M.cpActs.alSafeOff = function() M.alData().safe = nil end
M.cpActs.alSafe = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or not inReach(player, x, y) then return false end
    M.alData().safe = { x = x, y = y, z = z }
    halo("Safe room set. On the alarm, everyone who isn't fighting goes here.")
end
M.cpActs.alPostsClear = function() local a = M.alData(); for i = #a.posts, 1, -1 do a.posts[i] = nil end end
function M.alRender()
    if not M.cpShow or type(addAreaHighlight) ~= "function" then return end
    local a = M.alData()
    for _, p in ipairs(a.posts) do addAreaHighlight(p.x, p.y, p.x + 1, p.y + 1, p.z, 1, 0.25, 0.2, 0.7) end
    if a.safe then addAreaHighlight(a.safe.x, a.safe.y, a.safe.x + 1, a.safe.y + 1, a.safe.z, 0.6, 0.4, 1, 0.7) end
end

----------------------------------------------------------------------------------------------------------------
-- words: "sound the alarm" / "all clear"
----------------------------------------------------------------------------------------------------------------
table.insert(M.cpIntents, { id = "CAMP_ALARM", kind = "alarm", patterns = "sound the alarm|to your posts|man your posts|everyone to your posts|get to your posts|raise the alarm|battle stations" })
table.insert(M.cpIntents, { id = "CAMP_ALARM_CLEAR", kind = "alarm_clear", patterns = "all clear|stand down|it's all clear|we're clear|you can stand down" })
local baseOrder = M.cpOrder
function M.cpOrder(kind, record, player)
    if kind == "alarm" then
        if not M.cpIsHome(tostring(record.uid), player) then return nil end
        local ok, msg = M.alRaise("you", player)
        if not ok then return msg or "We don't do that here." end
        return M.alFighter(tostring(record.uid)) and "On it! Posts!" or "Going! Everyone inside!"
    elseif kind == "alarm_clear" then
        if not M.cpIsHome(tostring(record.uid), player) then return nil end
        if not M.alOn() then return "Nothing's up." end
        M.alClear(player, "you")
        return "Alright. Standing down."
    end
    return baseOrder(kind, record, player)
end
function M.alExtra(req, player, listener)
    if not M.alOn() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local uid = tostring(listener.record.uid)
    if not M.cpIsHome(uid, player) then return end
    local note = M.alFighter(uid) and "The camp alarm is up and you're at your post, ready to fight. Keep it short." or
        "The camp alarm is up and you're hiding in the safe room, scared and whispering."
    req.psyche = type(req.psyche) == "table" and req.psyche or {}
    req.psyche.mood = req.psyche.mood and (tostring(req.psyche.mood) .. ". " .. note) or note
end
function M.alPerf()
    local s = M.alStats
    return "alarm: raised " .. s.raised .. ", cleared " .. s.cleared .. ", lights off " .. s.lightsOff .. ", at posts " .. s.arrived
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
if type(Events) == "table" then
    if Events.OnTick then
        ALifeHealth.add(Events.OnTick, "ALifeTalk_CampAlarm", function()
            if M._alTickDead then return end
            local ok, err = pcall(function()
                if not M._alRegistered then M.alRegister() end
                local p = thePlayer()
                if p then M.alTick(p) end
            end)
            if not ok then M._alTickDead = true; log("tick error, alarm tick off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnPostRender then
        Events.OnPostRender.Add(function()
            if M._alRenderDead or not M.cpShow then return end
            local ok, err = pcall(M.alRender)
            if not ok then M._alRenderDead = true; log("render error, alarm drawing off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnGameStart then
        Events.OnGameStart.Add(function()
            pcall(M.alRegister)
            if not M._alExtraOn and type(M.requestExtras) == "table" then
                table.insert(M.requestExtras, function(req, player, listener, now) pcall(M.alExtra, req, player, listener) end)
                M._alExtraOn = true
            end
            local a = M.alData()
            log("loaded (" .. #a.posts .. " posts, safe room " .. (a.safe and "set" or "not set") .. (a.on and ", ALARM UP" or "") .. ")")
        end)
    end
end
