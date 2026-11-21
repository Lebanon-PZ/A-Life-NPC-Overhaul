-- A-Life NPC Overhaul 0.8.2: THEY DO WHAT YOU SAY (the client side) and THE COMMANDS TAB.
--   * Every line you say already goes through M.playerOrder (typed chat, voice, the talk window). This wraps it: if the
--     line holds one of the commands in ALifeCommands, the people it's meant for (a name you said, "everyone", or else
--     all of yours near you; "give me your..." goes to the person you're talking to) get it through ALifeCmd, the
--     server carries it out with A-Life's own orders, and the answer comes back here: who did it, who didn't and why.
--     The person you're talking to says it in their own words (the AI gets the order, how it went and why); the
--     others answer with a short line. A line with no command in it goes on to the old order words untouched.
--   * Where a command needs a spot, it's worked out here from what you see: where you stand, the closest threat in
--     front of you, where you're looking, the nearest car. The server checks it's near you.
--   * Help > Commands (was its own tab until pre-1.0): every command by group, what to say, what it does,
--     what it needs, the party size and what you still need for more; buttons give an order to someone near you.
-- Settings: "commands" (all), "cmd_<id>" (each one), and the numbers in ALifeCommands / ALifePartyCap.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Commands") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeCommands"
require "ALifeNPCOverhaul/ALifeCellCars"
require "ALifeNPCOverhaul/ALifePartyCap"
if ALifeRealCars == nil then require "ALifeNPCOverhaul/ALifeRealCars" end -- pre-1.0: loaded first by folder order before (ALifeChatPlus sorted first); now a real require
local M = ALifeLLMTalk
if type(M) ~= "table" then return end

ALifeTalkCommands = ALifeTalkCommands or {}
local K = ALifeTalkCommands
local TAG = "[ALifeTalkCommands]"
K.VERSION = ALifeSide.MOD_VERSION
K.off = K.off or {}
K.metrics = K.metrics or { lines = 0, sent = 0, results = 0, buttons = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return r end
local function shellOf(uid) local s = nil; pcall(function() s = PA().Talk.shellFor(tostring(uid)) end); return s end
local function nameOf(uid)
    if fn(M, "qolName") then local ok, n = pcall(M.qolName, uid); if ok and n then return tostring(n) end end
    local r = rec(uid)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    return tostring(m.personFirst or m.name or "Someone")
end
function K.guard(name, f, ...)
    if K.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        K.off[name] = true
        log("'" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end
function K.on() return M.settings == nil or M.settings.commands ~= false end

----------------------------------------------------------------------------------------------------------------
-- who: yours near you
----------------------------------------------------------------------------------------------------------------
function K.mineNear(player)
    local out = {}
    local link = ALifeCompanionLink
    if not fn(link, "roster") then return out end
    local ok, list = pcall(link.roster, player)
    if not ok or type(list) ~= "table" then return out end
    local reach = tonumber(ALifeCommands.setting("cmdReach")) or 30
    local px, py = player:getX(), player:getY()
    for _, uid in ipairs(list) do
        local sh = shellOf(uid)
        local near = false
        if sh ~= nil then pcall(function() near = (sh:getX() - px) ^ 2 + (sh:getY() - py) ^ 2 <= reach * reach end) end
        if near then out[#out + 1] = tostring(uid) end
    end
    return out
end
local function has(list, uid) for _, u in ipairs(list) do if u == uid then return true end end return false end
local function everyone(low)
    return string.find(low, "everyone", 1, true) or string.find(low, "everybody", 1, true) or string.find(low, "all of you", 1, true)
        or string.find(low, "you all", 1, true) or string.find(low, "y'all", 1, true)
end
function K.targets(player, text, c)
    if c.client and not c.mine then -- 0.8.2 part 2: things done right here can be asked of anyone: the talk window's person, else who you just spoke to
        local W = ALifeWindowTalk
        if fn(W, "window") then
            local okW, win = pcall(W.window)
            if okW and win ~= nil and win.uid ~= nil then return { tostring(win.uid) } end
        end
        local la0 = M.lastAddressee
        if type(la0) == "table" and nowMs() - (tonumber(la0.at) or 0) < 4000 then return { tostring(la0.uid) } end
    end
    local mine = K.mineNear(player)
    if #mine == 0 then return {} end
    local low = string.lower(tostring(text or ""))
    if fn(M, "partyNamed") then
        local ok, named = pcall(M.partyNamed, player, text)
        if ok and named ~= nil and has(mine, tostring(named)) and not everyone(low) then return { tostring(named) } end
    end
    local la = M.lastAddressee
    local talking = type(la) == "table" and nowMs() - (tonumber(la.at) or 0) < 4000 and has(mine, tostring(la.uid)) and tostring(la.uid) or nil
    if c.item ~= nil or c.client then -- one person: the one you're talking to, or the only one near
        if talking then return { talking } end
        if #mine == 1 then return mine end
        return {}
    end
    return mine
end

----------------------------------------------------------------------------------------------------------------
-- where: the spot a command needs
----------------------------------------------------------------------------------------------------------------
function K.point(player, kind)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    if kind == "here" then return { x = math.floor(px), y = math.floor(py), z = math.floor(pz) } end
    if kind == "base" then -- 0.8.2 part 2: the middle of your base (marked base / safehouse / claimed base, not just any building)
        if not fn(M, "playerBase") then return nil end
        local ok, b, how = pcall(M.playerBase, player)
        if not ok or type(b) ~= "table" or how == "building" or tonumber(b.x1) == nil then return nil end
        return { x = math.floor((b.x1 + (tonumber(b.x2) or b.x1)) / 2), y = math.floor((b.y1 + (tonumber(b.y2) or b.y1)) / 2), z = 0 }
    end
    if kind == "threat" then
        local best, bd = nil, 15 * 15
        pcall(function()
            local list = getCell():getZombieList()
            local Perc = PA().Perception
            for i = 0, list:size() - 1 do
                local zb = list:get(i)
                if not zb:isDead() then
                    local d = (zb:getX() - px) ^ 2 + (zb:getY() - py) ^ 2
                    if d < bd then
                        local actor = nil
                        if Perc and fn(Perc, "activeActorForShell") then pcall(function() actor = Perc.activeActorForShell(zb) end) end
                        local threat = actor == nil
                        if not threat then
                            local r = rec(actor.uid)
                            pcall(function() threat = (tonumber((PA().NpcOpinion.valueOf(r, player))) or 0) <= -41 end)
                        end
                        if threat then best, bd = { x = zb:getX(), y = zb:getY(), z = zb:getZ() }, d end
                    end
                end
            end
        end)
        return best
    end
    if kind == "car" then
        local best, bd = nil, 40 * 40
        pcall(function()
            for _, v in ipairs(ALifeCellCars.list()) do -- 0.9.5: 42.21 cell vehicles = HashSet (no get(i))
                local d = (v:getX() - px) ^ 2 + (v:getY() - py) ^ 2
                if d < bd then best, bd = { x = math.floor(v:getX()), y = math.floor(v:getY()), z = math.floor(v:getZ()) }, d end
            end
        end)
        return best
    end
    if kind == "ahead" then
        -- where you're facing, 8 tiles out (not checked on 42.21: getForwardDirection; else the closest dead in sight)
        local dx, dy = nil, nil
        pcall(function() local v = player:getForwardDirection(); dx, dy = v:getX(), v:getY() end)
        if dx ~= nil and (dx ~= 0 or dy ~= 0) then return { x = math.floor(px + dx * 8), y = math.floor(py + dy * 8), z = math.floor(pz) } end
        return K.point(player, "threat")
    end
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- a line: is there a command in it?
----------------------------------------------------------------------------------------------------------------
function K.fromLine(player, text)
    if not K.on() or player == nil then return nil end
    local c, noun = ALifeCommands.parse(text)
    if c == nil then return nil end
    local uids = K.targets(player, text, c)
    if #uids == 0 then return nil end
    K.metrics.lines = K.metrics.lines + 1
    return K.give(player, c, uids, noun)
end

-- send one command to these people; returns the command id
function K.give(player, c, uids, noun, agreed)
    if c.client then -- 0.8.2 part 2: things they do right here with you, no A-Life order behind them
        if c.id == "check_bites" then K.checkBites(player, uids[1]) end
        if c.id == "show_map" then K.showMap(player, uids[1]) end
        if c.id == "wake_me" or c.id == "teach_me" then K.helpMe(player, c, uids[1], noun, agreed) end -- 0.8.3
        if c.id == "warn_them" and type(ALifeGoals) == "table" and fn(ALifeGoals, "warn") then ALifeGoals.warn(player, uids[1]) end -- 0.8.8
        if c.camp ~= nil and type(ALifeSettlement) == "table" and fn(ALifeSettlement, "command") then ALifeSettlement.command(player, c, uids[1]) end -- 0.8.8
        return c.id
    end
    local args = { cmd = c.id, uids = table.concat(uids, ","), noun = noun, agreed = agreed == true or nil }
    if c.point ~= nil then
        local p = K.point(player, c.point)
        if p ~= nil then args.x, args.y, args.z = p.x, p.y, p.z end
    end
    K.metrics.sent = K.metrics.sent + 1
    K.pendingWho = uids
    ALifeCmd.send(player, "cmd", args)
    return c.id
end

----------------------------------------------------------------------------------------------------------------
-- the answer: who did it, who didn't, and why
----------------------------------------------------------------------------------------------------------------
K.SAY_WHY = {
    doesnt_have = { "I don't have one.", "Don't have one on me." }, no_skill = { "I don't know enough first aid for that." },
    worn = { "I'm wearing it." }, equipped_weapon = { "Not letting go of this one." }, you_dont_have = { "You don't have that." },
    too_heavy_or_equipped = { "Can't carry that. Or it's still in your hands." }, too_heavy = { "Too heavy for me." },
    what_item = { "Give you what?", "What do you want?" }, no_spot = { "I don't see anything there." },
    too_far = { "Come closer." }, ["repeat"] = { "Already on it." }, no_footing = { "Can't get there." },
    no_base = { "What base? We don't have one.", "Back where? We don't have a place." },
    -- 0.8.3
    not_clothing = { "I can't wear that." }, already_wearing = { "Already got it on." }, slot_taken = { "I'm already wearing something there." },
    neither_has = { "Neither of us has one." }, no_hose = { "I need a hose for that." }, no_can = { "Got nothing to put it in." },
    tank_dry = { "Tank's dry." },
}
local function pick(list) local n = #list; if n == 0 then return nil end; local i = 1; pcall(function() i = ZombRand(n) + 1 end); return list[i] end
function K.onResult(payload)
    if type(payload) ~= "table" or type(payload.results) ~= "table" then return end
    K.metrics.results = K.metrics.results + 1
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    local id, label = tostring(payload.cmd or "?"), tostring(payload.label or payload.cmd or "an order")
    M.orderLabel = M.orderLabel or {}
    M.orderLabel[id] = label
    M.lastOrder = M.lastOrder or {}
    local talkingTo = M.pending and tostring(M.pending.uid) or (type(M.lastAddressee) == "table" and tostring(M.lastAddressee.uid) or nil)
    local okN, noN = 0, 0
    for _, r in pairs(payload.results) do
        if type(r) == "table" and r.uid ~= nil then
            local uid = tostring(r.uid)
            local done = r.ok == true
            if done then okN = okN + 1 else noN = noN + 1 end
            M.lastOrder[uid] = { kind = id, obeyed = done, at = nowMs(), why = r.why }
            if done and id == "wait_dawn" then K.dawn[uid] = { player = player, h = K.hours() } end -- 0.8.2 part 2
            if M.feel then pcall(M.feel, uid, done and "pride" or "irritation", 0.05) end
            if M.logInteraction then pcall(M.logInteraction, uid, (done and "Did what you said: " or "Didn't do what you said: ") .. label, nil, nil, "event") end
            if uid ~= talkingTo and fn(M, "say") then
                local sh = shellOf(uid)
                local line = nil
                if not done and r.why ~= nil and K.SAY_WHY[r.why] then line = pick(K.SAY_WHY[r.why]) end
                if line == nil and fn(M, "ackLine") then local okA, l = pcall(M.ackLine, uid, done); if okA then line = l end end
                if sh ~= nil and line ~= nil then pcall(M.say, sh, player, line, { record = rec(uid) }) end
            end
        end
    end
    log("'" .. label .. "': " .. okN .. " did it, " .. noN .. " didn't")
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("cmdResult", function(p) return K.onResult(p) end) end

-- the AI hears why too (req.order = { kind, obeyed } is filled by the mod's own order code; we add why)
if type(M.requestExtras) == "table" and not K._extras then
    K._extras = true
    table.insert(M.requestExtras, function(req, player, listener, now)
        local uid = type(listener) == "table" and type(listener.record) == "table" and tostring(listener.record.uid) or nil
        local o = uid and M.lastOrder and M.lastOrder[uid] or nil
        if o and o.why and type(req.order) == "table" and now - (o.at or 0) < 8000 then
            req.order.why = ALifeCommands.whyWords(o.why) or tostring(o.why)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.2 part 2: things done here, by the client
----------------------------------------------------------------------------------------------------------------
function K.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end

-- "check me for bites": they come in close, look you over (vanilla BodyDamage / BodyPart:bitten(), as the health
-- panel does) and say what they see. Only someone close enough to look.
K.BITE_LINES = {
    bite = { "That's a bite. On your %s.", "Oh no. That's a bite, %s.", "...That's a bite on your %s." },
    scratch = { "Just scratches. Keep an eye on them.", "Scratched up, no bite I can see.", "Scratches. Could be nothing. Could be." },
    clean = { "You're clean.", "Nothing. You're clean.", "Looks clean to me." },
}
function K.lookOver(player)
    local bit, scratched, where = false, false, nil
    pcall(function()
        local parts = player:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            if bp:bitten() and not bit then
                bit = true
                pcall(function() where = string.lower(tostring(BodyPartType.getDisplayName(bp:getType()))) end)
            elseif bp:scratched() then scratched = true end
        end
    end)
    if bit then return "bite", where or "skin" end
    if scratched then return "scratch" end
    return "clean"
end
function K.checkBites(player, uid)
    if player == nil or uid == nil then return false end
    local sh = shellOf(uid)
    if sh == nil then return false end
    local close = false
    pcall(function() close = (sh:getX() - player:getX()) ^ 2 + (sh:getY() - player:getY()) ^ 2 <= 2.5 * 2.5 end)
    local line
    if not close then
        line = pick({ "Come here so I can see.", "Get over here, I can't see from here." })
    else
        local kind, where = K.lookOver(player)
        line = pick(K.BITE_LINES[kind])
        if kind == "bite" then line = string.format(line, where) end
        M.lastOrder = M.lastOrder or {}
        M.lastOrder[tostring(uid)] = { kind = "check_bites", obeyed = true, at = nowMs(), why = kind } -- the AI hears what they saw
        if kind == "bite" and fn(M, "feel") then pcall(M.feel, uid, "fear", 0.15) end
    end
    if fn(M, "say") then pcall(M.say, sh, player, line, { record = rec(uid) }) end
    K.metrics.checked = (K.metrics.checked or 0) + 1
    return true
end

-- "show me on the map": their group's place (Bases.lua nbOfMember), marked exactly on your map like the journal
-- does (pen or pencil needed), if they trust you (opinion >= cmdMapTrust)
K.MAP_LINES = {
    none = { "We don't have a place. Not anymore.", "No place to show. We move around." },
    no = { "Not telling you where we sleep.", "Nice try.", "I don't know you that well." },
    pen = { "Got a pen? I'll mark it.", "Need something to write with." },
    ok = { "There. That's us.", "Here. Don't bring trouble.", "That's the place." },
}
local function hasPen(player)
    local yes = false
    pcall(function()
        local inv = player:getInventory()
        for _, t in ipairs({ "Base.Pencil", "Base.Pen", "Base.BluePen", "Base.RedPen", "Base.GreenPen", "Base.MarkerBlack", "Base.Crayons" }) do
            if inv:containsTypeRecurse(t) then yes = true; return end
        end
    end)
    return yes
end
function K.showMap(player, uid)
    if player == nil or uid == nil then return false end
    local sh = shellOf(uid)
    if sh == nil then return false end
    local r = rec(uid)
    local b = fn(M, "nbOfMember") and M.nbOfMember(tostring(uid)) or nil
    local op = 0
    pcall(function() op = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end)
    local kind
    if type(b) ~= "table" or tonumber(b.x) == nil then kind = "none"
    elseif op < (tonumber(M.settings.cmdMapTrust) or 30) then kind = "no"
    elseif not hasPen(player) then kind = "pen"
    else
        kind = "ok"
        b.intel = type(b.intel) == "table" and b.intel or {}
        b.intel.exact, b.intel.x, b.intel.y = true, b.x, b.y -- they told you exactly where
        local name = string.gsub(tostring(b.name or "Their place"), "^the ", "The ")
        M.jnQueue = M.jnQueue or {}
        M.jnQueue[#M.jnQueue + 1] = { text = name, x = b.x, y = b.y }
        if type(ISWorldMap) == "table" and fn(ISWorldMap, "ShowWorldMap") then
            pcall(ISWorldMap.ShowWorldMap, player:getPlayerNum(), b.x, b.y, 14)
        end
        if fn(M, "jnFlush") then pcall(M.jnFlush) end
    end
    M.lastOrder = M.lastOrder or {}
    M.lastOrder[tostring(uid)] = { kind = "show_map", obeyed = kind == "ok", at = nowMs(), why = kind }
    if fn(M, "say") then pcall(M.say, sh, player, pick(K.MAP_LINES[kind]), { record = r }) end
    return kind == "ok"
end

-- "wait here till morning": after dawn (06:00, at least two game hours later) they come find you
K.dawn = K.dawn or {}
function K.dawnTick()
    local hour = nil
    pcall(function() hour = getGameTime():getHour() end)
    if hour == nil or hour < 6 or hour >= 10 then return end
    local h = K.hours()
    local due = {}
    for uid, d in pairs(K.dawn) do if h - (tonumber(d.h) or h) >= 2 then due[#due + 1] = uid end end
    for _, uid in ipairs(due) do
        local d = K.dawn[uid]
        K.dawn[uid] = nil
        if d.player ~= nil and ALifeCommands.byId.follow_me then K.give(d.player, ALifeCommands.byId.follow_me, { uid }, nil, true) end
    end
end
if type(Events) == "table" and Events.EveryTenMinutes ~= nil then
    Events.EveryTenMinutes.Add(function() K.guard("dawn", K.dawnTick) end)
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.3: help me (wake me if anything comes, teach me). Your own people; they can say no like any order.
-- forceAwake and AddXP only work on your own (local) character, so this is the client's.
----------------------------------------------------------------------------------------------------------------
local function setting(k) return tonumber(ALifeCommands.setting(k)) end
local function near(sh, player, reach)
    local yes = false
    pcall(function() yes = (sh:getX() - player:getX()) ^ 2 + (sh:getY() - player:getY()) ^ 2 <= reach * reach end)
    return yes
end
local function sayAs(uid, player, line)
    local sh = shellOf(uid)
    if sh ~= nil and line ~= nil and fn(M, "say") then pcall(M.say, sh, player, line, { record = rec(uid) }) end
end
local function noteOrder(uid, kind, ok, why)
    M.lastOrder = M.lastOrder or {}
    M.lastOrder[tostring(uid)] = { kind = kind, obeyed = ok, at = nowMs(), why = why }
    if fn(M, "feel") then pcall(M.feel, uid, ok and "pride" or "irritation", 0.05) end
end
K.HELP_LINES = {
    wake_ok = { "Get some sleep. I've got it.", "Sleep. I'll wake you.", "I'll keep watch." },
    wake_up = { "Up! Something's coming.", "Wake up. We've got company.", "Hey. Hey! Get up, they're close." },
    teach_ok = { "Alright. Watch close.", "Sure. Pay attention.", "Okay. Like this." },
    teach_done = { "That's enough for today.", "You'll get the hang of it.", "Not bad. Let it sink in." },
    teach_caught = { "You've caught up to me. Nothing left I can show you.", "That's all I know." },
    teach_left = { "Where'd you go? Lesson's over then." },
    knows_less = { "You know more about that than I do.", "You should be teaching me." },
    too_soon = { "We did that already today. Let it sink in.", "Tomorrow. Too much at once and it won't stick." },
    what_skill = { "Teach you what?", "Show you how to do what?" },
    wont = { "Not now.", "No." },
}
K.wake = K.wake or {}
K.teach = K.teach or {}
K.taught = K.taught or {}

-- their A-Life companion skill (0-10) and yours, for one of L.SKILL_WORDS
function K.skillLevels(player, uid, s)
    local theirs, yours = 0, 0
    pcall(function()
        local C = PA().Companions
        local entry = C.entry(rec(uid))
        theirs = tonumber(C.rules().skill(entry and entry.state or nil, s.id)) or 0
    end)
    pcall(function() yours = tonumber(player:getPerkLevel(Perks[s.perk])) or 0 end)
    return theirs, yours
end

function K.helpMe(player, c, uid, noun, agreed)
    if player == nil or uid == nil then return false end
    uid = tostring(uid)
    if not has(K.mineNear(player), uid) then return false end
    if c.id == "teach_me" then
        local s = ALifeCommands.skillOf(noun)
        if s == nil then noteOrder(uid, c.id, false, "what_skill"); sayAs(uid, player, pick(K.HELP_LINES.what_skill)); return false end
        local theirs, yours = K.skillLevels(player, uid, s)
        local why = nil
        if theirs <= yours then why = "knows_less"
        elseif K.hours() - (tonumber(K.taught[uid .. ":" .. s.id]) or -1e9) < (setting("teachGapH") or 24) then why = "too_soon" end
        if why then noteOrder(uid, c.id, false, why); sayAs(uid, player, pick(K.HELP_LINES[why])); return false end
    end
    if agreed ~= true then
        local chance = ALifeCommands.chance(uid, player, c)
        local r = 0
        pcall(function() r = ZombRand(100) end)
        if r >= chance then noteOrder(uid, c.id, false, "wont"); sayAs(uid, player, pick(K.HELP_LINES.wont)); return false end
    end
    noteOrder(uid, c.id, true, nil)
    if c.id == "wake_me" then
        K.wake[uid] = { player = player, untilH = K.hours() + (setting("wakeHours") or 12) }
        sayAs(uid, player, pick(K.HELP_LINES.wake_ok))
    else
        local s = ALifeCommands.skillOf(noun)
        K.teach[uid] = { player = player, skill = s.id, perk = s.perk, untilH = K.hours() + (setting("teachHours") or 1), lastH = K.hours() }
        K.taught[uid .. ":" .. s.id] = K.hours()
        sayAs(uid, player, pick(K.HELP_LINES.teach_ok))
    end
    return true
end

-- the dead, or someone hostile to you, within reach of x, y
function K.threatNear(player, x, y, reach)
    local found = false
    pcall(function()
        local list = getCell():getZombieList()
        local Perc = PA().Perception
        for i = 0, list:size() - 1 do
            local zb = list:get(i)
            if not zb:isDead() and (zb:getX() - x) ^ 2 + (zb:getY() - y) ^ 2 <= reach * reach then
                local actor = nil
                if Perc and fn(Perc, "activeActorForShell") then pcall(function() actor = Perc.activeActorForShell(zb) end) end
                local threat = actor == nil
                if not threat then pcall(function() threat = (tonumber((PA().NpcOpinion.valueOf(rec(actor.uid), player))) or 0) <= -41 end) end
                if threat then found = true; return end
            end
        end
    end)
    return found
end

-- every game minute: the one keeping watch wakes you if something comes; one night only
function K.wakeTick()
    local h = K.hours()
    local due = {}
    for uid, w in pairs(K.wake) do due[#due + 1] = uid end
    for _, uid in ipairs(due) do
        local w = K.wake[uid]
        local p = w.player
        local asleep = false
        pcall(function() asleep = p:isAsleep() == true end)
        if asleep then w.slept = true end
        if h > w.untilH or (w.slept and not asleep) then
            K.wake[uid] = nil
        elseif asleep then
            local sh = shellOf(uid)
            local reach = setting("wakeReach") or 15
            if sh ~= nil and near(sh, p, tonumber(ALifeCommands.setting("cmdReach")) or 30) and K.threatNear(p, p:getX(), p:getY(), reach) then
                pcall(function() p:forceAwake() end)
                K.wake[uid] = nil
                K.metrics.woke = (K.metrics.woke or 0) + 1
                sayAs(uid, p, pick(K.HELP_LINES.wake_up))
                if M.logInteraction then pcall(M.logInteraction, uid, "Woke you when something came", nil, nil, "event") end
            end
        end
    end
end

-- every ten game minutes: a lesson, while you stay close and awake
function K.teachTick()
    local h = K.hours()
    local due = {}
    for uid, t in pairs(K.teach) do due[#due + 1] = uid end
    for _, uid in ipairs(due) do
        local t = K.teach[uid]
        local p = t.player
        local sh = shellOf(uid)
        local s = nil
        for _, row in ipairs(ALifeCommands.SKILL_WORDS) do if row.id == t.skill then s = row end end
        local theirs, yours = K.skillLevels(p, uid, s)
        local asleep = false
        pcall(function() asleep = p:isAsleep() == true end)
        local close = sh ~= nil and near(sh, p, setting("teachReach") or 4)
        local endLine = nil
        if yours >= theirs then endLine = "teach_caught"
        elseif h > t.untilH then endLine = "teach_done"
        elseif not close or asleep then
            t.away = (t.away or 0) + 1
            if t.away >= 3 then endLine = "teach_left" end
        else
            t.away = 0
            local xp = (setting("teachXp") or 8) * (theirs - yours)
            local ok = pcall(function() p:getXp():AddXP(Perks[t.perk], xp, false, true) end)
            if ok then K.metrics.taughtXp = (K.metrics.taughtXp or 0) + xp end
        end
        if endLine then
            K.teach[uid] = nil
            sayAs(uid, p, pick(K.HELP_LINES[endLine]))
            if M.logInteraction then pcall(M.logInteraction, uid, "Taught you some " .. tostring(t.skill), nil, nil, "event") end
            if fn(M, "feel") and endLine ~= "teach_left" then pcall(M.feel, uid, "pride", 0.05) end
        end
    end
end
if type(Events) == "table" then
    if Events.EveryOneMinute ~= nil then Events.EveryOneMinute.Add(function() K.guard("wake", K.wakeTick) end) end
    if Events.EveryTenMinutes ~= nil then Events.EveryTenMinutes.Add(function() K.guard("teach", K.teachTick) end) end
end

-- a job done later (siphon): what they say when they're back
K.DONE_LINES = {
    siphon = { "Got about %d litres.", "%d litres. Smells awful.", "Here. About %d litres in the can." },
    tank_dry = { "Tank's dry.", "Nothing in it." }, no_can = { "Got nothing to put it in." }, can_full = { "Can's full already." },
    no_spot = { "Car's gone." }, no_footing = { "Couldn't get to it." }, no_tank = { "No tank on that thing." },
}
function K.onDone(p)
    if type(p) ~= "table" or p.uid == nil then return end
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    local uid = tostring(p.uid)
    local line
    if p.ok then line = string.format(pick(K.DONE_LINES.siphon), tonumber(p.n) or 0)
    else line = pick(K.DONE_LINES[tostring(p.why or "")] or { "Couldn't do it." }) end
    noteOrder(uid, tostring(p.cmd), p.ok == true, p.why)
    if M.logInteraction then pcall(M.logInteraction, uid, p.ok and ("Siphoned " .. tostring(p.n) .. " litres for you") or "Couldn't siphon the car", nil, nil, "event") end
    sayAs(uid, player, line)
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("cmdDone", function(p) return K.onDone(p) end) end

-- the AI picks the command: when you talk to one of yours and no command words matched, the bridge gets the list
-- (req.cmds) and sets cmd only if they agree to do it; Main.lua's finish calls M.onAiCmd.
function K.cmdList(clientOnly)
    local out = {}
    for _, c in ipairs(ALifeCommands.CMDS) do
        if not c.hidden and ALifeCommands.cmdOn(c.id) and (not clientOnly or (c.client and not c.mine)) then
            out[#out + 1] = { id = c.id, label = c.label, item = c.item }
        end
    end
    return out
end
function K.aiCmd(player, uid, id, noun)
    if not K.on() or M.settings.aiCommands == false or player == nil or uid == nil then return false end
    local c = ALifeCommands.byId[tostring(id)]
    if c == nil or c.hidden or not ALifeCommands.cmdOn(c.id) then return false end
    if (not c.client or c.mine) and not has(K.mineNear(player), tostring(uid)) then return false end -- orders: your people only
    K.metrics.aiPicked = (K.metrics.aiPicked or 0) + 1
    K.give(player, c, { tostring(uid) }, noun, true)
    return true
end
M.onAiCmd = function(player, uid, id, noun) return K.aiCmd(player, uid, id, noun) end
if type(M.requestExtras) == "table" and not K._aiExtras then
    K._aiExtras = true
    table.insert(M.requestExtras, function(req, player, listener, now)
        if not K.on() or M.settings.aiCommands == false or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
        if type(req.said) ~= "string" or req.said == "" then return end
        local mine = has(K.mineNear(player), tostring(listener.record.uid))
        local list = K.cmdList(not mine) -- anyone: only what they'd do right here (check you for bites, show you on the map)
        if #list > 0 then req.cmds = list end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- the hook: M.playerOrder(player, text), outermost; the original runs for any line without one of these commands
----------------------------------------------------------------------------------------------------------------
function K.hook()
    if K.hooked or not fn(M, "playerOrder") then return K.hooked == true end
    local orig = M.playerOrder
    M.playerOrder = function(player, text, ...)
        if not K.off.line then
            local ok, id = K.guard("line", K.fromLine, player, text)
            if ok and id ~= nil then return id, {} end
        end
        return orig(player, text, ...)
    end
    K.hooked = true
    return true
end

----------------------------------------------------------------------------------------------------------------
-- the Commands tab
----------------------------------------------------------------------------------------------------------------
-- pre-1.0 (Joe): every group is a drop-down heading, closed until clicked ("[+] COMBAT (6)"); open ones remembered
K.PARTY_FOLD = "Your party"
local function foldOpen(g)
    if type(M.uiPref) == "function" then local ok, v = pcall(M.uiPref, "cmdFold." .. string.gsub(g, "[^%w]+", "_"), false); if ok then return v == true end end
    return K.folds ~= nil and K.folds[g] == true
end
local function foldSet(g, open)
    K.folds = K.folds or {}
    K.folds[g] = open
    if type(M.uiSet) == "function" then pcall(M.uiSet, "cmdFold." .. (string.gsub(g, "[^%w]+", "_")), open) end
end
local function foldHead(kit, g, n, open)
    return " <LINE> " .. kit.GOLD .. (open and "[-] " or "[+] ") .. kit.esc(string.upper(g)) .. (n and (" (" .. n .. ")") or "") .. kit.TXT .. " <LINE> "
end
-- the line under the mouse ("[+] COMBAT (6)") -> open / close that group; true = changed
function K.pageClick(line)
    local mark, name = string.match(tostring(line or ""), "^%[([%+%-])%]%s*(.-)%s*$")
    if mark == nil then return false end
    name = string.gsub(name, "%s*%(%d+%)$", "")
    local all = {}
    for _, g in ipairs(ALifeCommands.GROUPS) do all[#all + 1] = g end
    all[#all + 1] = K.PARTY_FOLD
    for _, g in ipairs(all) do
        if string.upper(g) == name then foldSet(g, not foldOpen(g)); return true end
    end
    return false
end
function K.foldAll(open)
    for _, g in ipairs(ALifeCommands.GROUPS) do foldSet(g, open) end
    foldSet(K.PARTY_FOLD, open)
end
function K.pageText()
    local kit = M.winKit
    local esc, GOLD, TXT, DIM, RED = kit.esc, kit.GOLD, kit.TXT, kit.DIM, kit.RED
    local out = { " <SIZE:medium> " .. GOLD .. "What you can tell your people" .. TXT .. " <SIZE:small> <LINE> " }
    out[#out + 1] = DIM .. "Say it however you like: typed, by voice, or in the talk window. Say a name to give it to one person, \"everyone\" for all; otherwise it goes to everyone of yours nearby. They can say no: how they feel about you, what they know, what they carry." .. TXT .. " <LINE> "
    out[#out + 1] = DIM .. "These work on people in your party. Click a heading to open or close it." .. TXT .. " <LINE> "
    for _, g in ipairs(ALifeCommands.GROUPS) do
        local rows = {}
        for _, c in ipairs(ALifeCommands.CMDS) do
            if c.group == g and ALifeCommands.cmdOn(c.id) then
                rows[#rows + 1] = GOLD .. esc(c.label) .. TXT .. "  " .. DIM .. "\"" .. esc(table.concat(c.say or {}, "\"  \"")) .. "\"" .. TXT
                    .. " <LINE> " .. esc(c.what or "") .. " <LINE> "
            end
        end
        if #rows > 0 then
            local open = foldOpen(g)
            out[#out + 1] = foldHead(kit, g, #rows, open)
            if open then out[#out + 1] = table.concat(rows, " <LINE> ") end
        end
    end
    -- the party size and what it needs
    local p = nil
    pcall(function() p = ALifeSide.you() end)
    local cap, met = 0, {}
    local okC, c1, m1 = pcall(ALifePartyCap.capNow, p)
    if okC then cap, met = c1 or 0, m1 or {} end
    local n = 0
    if fn(M, "partyMembers") then local ok, l = pcall(M.partyMembers, p); if ok and type(l) == "table" then n = #l end end
    out[#out + 1] = foldHead(kit, K.PARTY_FOLD, nil, foldOpen(K.PARTY_FOLD))
    if not foldOpen(K.PARTY_FOLD) then return table.concat(out) end
    out[#out + 1] = "With you: " .. n .. " of " .. tostring(cap) .. ". You picked " .. tostring(ALifePartyCap.setting("partyCap"))
        .. " (Settings, up to " .. tostring(ALifePartyCap.setting("partyMax")) .. "). " .. tostring(ALifePartyCap.setting("partyFree")) .. " is free; each place above that needs one of these: <LINE> "
    if #met == 0 then
        out[#out + 1] = DIM .. "Pick a party size above " .. tostring(ALifePartyCap.setting("partyFree")) .. " in Settings to see what you'd need." .. TXT .. " <LINE> "
    else
        for _, q in ipairs(met) do
            out[#out + 1] = (q.met and GOLD .. "Met: " or RED .. "Not yet: ") .. TXT .. esc(q.words) .. " <LINE> "
        end
    end
    out[#out + 1] = DIM .. "Lookouts (keep a lookout, guard this spot, take point) call out trouble they see. Drop food near someone hungry and they'll take it." .. TXT .. " <LINE> "
    return table.concat(out)
end

-- a button per group: pick the command, then who
function K.menuFor(win, btn, group)
    local kit = M.winKit
    local player = nil
    pcall(function() player = ALifeSide.you() end)
    if player == nil then return end
    local cm = kit.menuAt(win, btn)
    local mine = K.mineNear(player)
    if #mine == 0 then
        local o = cm:addOption(ALifeTr("IGUI_ALCP_Menu_Nobody_of_yours_is_near_you", "Nobody of yours is near you."), nil, nil)
        o.notAvailable = true
        return
    end
    if group == "Gear" then K.gearMenu(cm, player, mine) end
    for _, c in ipairs(ALifeCommands.CMDS) do
        if c.group == group and ALifeCommands.cmdOn(c.id) and c.item == nil and not c.hidden and not c.noButton then -- 0.8.9: noButton = needs your words (a name, a place)
            local o = cm:addOption(c.label, nil, nil)
            local sub = ISContextMenu:getNew(cm)
            cm:addSubMenu(o, sub)
            sub:addOption(ALifeTr("IGUI_ALCP_Menu_Everyone_near_you", "Everyone near you"), nil, function() K.metrics.buttons = K.metrics.buttons + 1; K.give(player, c, mine, nil) end)
            for _, uid in ipairs(mine) do
                sub:addOption(nameOf(uid), nil, function() K.metrics.buttons = K.metrics.buttons + 1; K.give(player, c, { uid }, nil) end)
            end
        end
    end
end

-- 0.8.2 part 2: Gear buttons - "hand it over": their own things (not worn); "carry this": yours (not in your hands)
local function itemNames(container, skip, max)
    local out, seen = {}, {}
    pcall(function()
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local name = tostring(it:getDisplayName())
            if not seen[name] and not skip(it) then seen[name] = true; out[#out + 1] = name end
            if #out >= max then break end
        end
    end)
    table.sort(out)
    return out
end
function K.gearMenu(cm, player, mine)
    local give, carry = ALifeCommands.byId.give_me, ALifeCommands.byId.carry
    if give and ALifeCommands.cmdOn(give.id) then
        local o = cm:addOption(give.label, nil, nil)
        local sub = ISContextMenu:getNew(cm)
        cm:addSubMenu(o, sub)
        for _, uid in ipairs(mine) do
            local sh = shellOf(uid)
            local inv = nil
            pcall(function() inv = sh:getInventory() end)
            local names = inv and itemNames(inv, function(it) local w = false; pcall(function() w = it:isWorn() == true end); return w end, 15) or {}
            local po = sub:addOption(nameOf(uid), nil, nil)
            if #names == 0 then po.notAvailable = true else
                local ss = ISContextMenu:getNew(sub)
                sub:addSubMenu(po, ss)
                for _, n in ipairs(names) do ss:addOption(n, nil, function() K.metrics.buttons = K.metrics.buttons + 1; K.give(player, give, { uid }, n) end) end
            end
        end
    end
    if carry and ALifeCommands.cmdOn(carry.id) then
        local names = itemNames(player:getInventory(), function(it)
            local skip = false
            pcall(function() skip = it:isWorn() == true or player:isEquipped(it) == true end)
            return skip
        end, 15)
        local o = cm:addOption(carry.label, nil, nil)
        local sub = ISContextMenu:getNew(cm)
        cm:addSubMenu(o, sub)
        for _, uid in ipairs(mine) do
            local po = sub:addOption(nameOf(uid), nil, nil)
            if #names == 0 then po.notAvailable = true else
                local ss = ISContextMenu:getNew(sub)
                sub:addSubMenu(po, ss)
                for _, n in ipairs(names) do ss:addOption(n, nil, function() K.metrics.buttons = K.metrics.buttons + 1; K.give(player, carry, { uid }, n) end) end
            end
        end
    end
end

function K.addTab()
    if K.tabAdded then return true end
    local kit = M.winKit
    if type(kit) ~= "table" then return false end
    -- pre-1.0 (Joe): no tab of its own any more; it's a view on the Help tab (Help > Commands)
    M.helpSections = M.helpSections or {}
    local have = false
    for _, s in ipairs(M.helpSections) do if s.id == "commands" then have = true end end
    if not have then
        table.insert(M.helpSections, { id = "commands", label = "Commands", text = K.pageText, click = K.pageClick, actions = function()
            local out = {}
            out[#out + 1] = { label = "Open all", fn = function(win) K.foldAll(true); win:refresh() end }
            out[#out + 1] = { label = "Close all", fn = function(win) K.foldAll(false); win:refresh() end }
            for _, g in ipairs(ALifeCommands.GROUPS) do
                out[#out + 1] = { label = g, fn = function(win, b) K.menuFor(win, b, g) end }
            end
            return out
        end })
    end
    if type(M.winHelp) == "table" then
        table.insert(M.winHelp, 4, { "Commands", "Tell your people what to do in your own words: hold fire, get that one, go dark, clear the house, patch me up, give me your rifle... Help > Commands lists them all, what they need, and your party size." })
    end
    K.tabAdded = true
    return true
end

-- settings that must outlive a restart (Zomboid/Lua/alifetalk_settings.txt keeps only listed keys). Also the 0.8.0 /
-- 0.8.1 switches, which weren't listed before (they fell back to "on" every restart).
K.FILE_KEYS = { "commands", "cmdObey", "cmdEasyBonus", "cmdFightObey", "cmdGiveTrust", "cmdReach", "windowTalk", "talkPauseKey", "talkAutoPause",
    "guardOnlySky", "alifeCarsOff", "aiCommands", "cmdBaseReach", "cmdMapTrust", "thirstPerH",
    "wakeReach", "wakeHours", "teachHours", "teachXp", "teachReach", "teachGapH", "siphonMinutes", "siphonGiveUpMin", "keepEngineMin", "guardTiles" } -- 0.8.3
function K.fileKeys()
    if type(M.fileKeys) ~= "table" or type(M.settings) ~= "table" then return end
    local have = {}
    for _, k in ipairs(M.fileKeys) do have[k] = true end
    for _, k in ipairs(K.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    if M.settings.commands == nil then M.settings.commands = true end
    if M.settings.aiCommands == nil then M.settings.aiCommands = true end -- 0.8.2 part 2
    if M.settings.cmdMapTrust == nil then M.settings.cmdMapTrust = 30 end
    if M.settings.thirstPerH == nil then M.settings.thirstPerH = 0.05 end
    for k, v in pairs(ALifeCommands.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    -- 0.8.4: NPCs take real cars (shared/ALifeRealCars.lua loads first)
    local RC = ALifeRealCars
    if type(RC) == "table" and type(RC.FILE_KEYS) == "table" then
        for _, k in ipairs(RC.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
        for k, v in pairs(RC.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    end
end
-- listed now (load time), before the settings file is read
pcall(K.fileKeys)
if type(M.fileKeys) == "table" and type(ALifePartyCap) == "table" then
    local have = {}
    for _, k in ipairs(M.fileKeys) do have[k] = true end
    for _, k in ipairs({ "partyMax", "partyFree", "capBeds", "capBedTiles", "capFood", "capFoodDays", "capFoodPerDay", "capWater",
            "capWaterPerDay", "capTrust", "capTrustShare", "capTrustOpinion", "capSeats", "capSeatsTiles" }) do
        if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
function K.install()
    K.guard("fileKeys", K.fileKeys)
    local okH = K.guard("hook", K.hook)
    local okT = K.guard("tab", K.addTab)
    log("ready v" .. K.VERSION .. ": words " .. ((okH and K.hooked) and "on" or "OFF") .. ", Help > Commands " .. ((okT and K.tabAdded) and "on" or "OFF")
        .. " (" .. #ALifeCommands.CMDS .. " commands)")
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
print(TAG .. " loaded v" .. K.VERSION)
