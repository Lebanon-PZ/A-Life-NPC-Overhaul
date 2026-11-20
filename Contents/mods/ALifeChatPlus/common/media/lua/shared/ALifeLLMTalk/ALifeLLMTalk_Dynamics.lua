-- A-Life Chat Plus (merged with A-Life Talk): THE WORLD PUSHES BACK.
--   1. Kingmaker: what you do for (or to) a community changes the community itself - food you share fills their
--      stores, medicine you bring can finish their hunt for it, clearing the dead around them lifts them, robbing or
--      killing their people sets them back. Their goals and fortunes move with you.
--   2. Territory: every community claims the ground around its house. Scavenging there is noticed (by a member who
--      sees it, or found out later) and costs you with them; closed and raider groups take it worst.
--   3. They come for you: a community that hates you (or a raider band that wants tribute and doesn't get it) sends
--      its leader after you with backup - a real visit through A-Life Talk's nemesis / A-Life's Revenge system.
--      Raider bands that "rule the area" demand tribute first: pay it (give any of them food) or face them.
--   4. Unrest at home: people living at your base judge how it's run - short food, danger, a gang of clashing
--      personalities. Discontent shows in what they say; the fed-up walk out, and the volatile can turn on you.
--   5. Secret pacts: some alliances are kept quiet (raiders and the groups they protect). Their people know; you
--      only hear of it as a rumor once a member trusts you. The factions screen hides them until then.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Dynamics") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Dynamics"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Dynamics") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(seed) local h = (hash(seed) * 16807) % 2147483647; h = (h * 16807) % 2147483647; return (h % 10000) / 10000 end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function log(msg) if M.log then M.log("dynamics: " .. tostring(msg)) end end
local function rec(uid) local pa = PA(); return fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local ok, n = pcall(function() return PA().Names.of(r) end); return ok and n and tostring(n) or "someone" end
local function first(r) return string.match(nameOf(r), "^(%S+)") or "someone" end
local function event(b, t, k) if M.nbEvent then pcall(M.nbEvent, b, t, k or "dynamics") end end
-- pre-1.0 MP (P5): community life is world logic. On a server "you" = the player being handled, else the camp's player
-- (Main's M.homePlayer); kills count for whichever online player made them; alerts / cards go through ALifeOut.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function thePlayer() if mpServer() and ALifeSide.cur == nil and M.homePlayer then return M.homePlayer() end; return ALifeSide.you() end
local function pos(o) if o == nil then return nil end local x, y, z; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function shellFor(uid) local t = PA().Talk; return fn(t, "shellFor") and t.shellFor(tostring(uid)) or nil end
local function lens(uid) local ok, l = pcall(function() return M.lens(tostring(uid)) end); return ok and type(l) == "table" and l or {} end

if M.settings.dynamics == nil then M.settings.dynamics = true end
M.dynCfg = { claimTiles = 45, seeTiles = 25, clearKills = 8, enemyEff = -40, tributeDays = 3, unrestEvery = 24, walkOut = 60 }

----------------------------------------------------------------------------------------------------------------
-- 1. kingmaker
----------------------------------------------------------------------------------------------------------------
M.dynDeedFx = {
    gift = { food = 1.5, morale = 2, rep = 2, text = "The newcomer shared food with %s" },
    medicine = { morale = 4, rep = 3, medicine = true, text = "The newcomer patched up %s" },
    trade = { food = 0.5, rep = 1, text = "Traded with the newcomer" },
    help_fight = { morale = 3, rep = 3, text = "The newcomer fought alongside %s" },
    saved = { morale = 6, rep = 6, text = "The newcomer saved %s's life" },
    robbery = { food = -1.5, morale = -5, rep = -8, text = "The newcomer robbed %s" },
    hit = { morale = -3, rep = -4, text = "The newcomer beat %s" },
}
M.dynLastDeed = {}
function M.dynDeed(kind, record, player)
    local fx = M.dynDeedFx[kind]
    if fx == nil or M.settings.dynamics == false or record == nil then return end
    local b = M.nbOfMember and M.nbOfMember(record) or nil
    if b == nil then
        -- tribute: giving food to a raider band that demanded it
        if kind == "gift" then pcall(M.dynTributePaid, record, player) end
        return
    end
    local key = b.id .. ":" .. kind
    local now = M.nowMs and M.nowMs() or 0
    if now - (M.dynLastDeed[key] or -1e12) < 60000 then return end
    M.dynLastDeed[key] = now
    local n = math.max(1, tonumber(b.crewN) or 1)
    if fx.food then -- 0.6.1: your gift / trade goes in, a robbery takes real food out
        if fx.food > 0 and M.nbFoodAdd then M.nbFoodAdd(b, fx.food)
        elseif fx.food < 0 and M.nbFoodTake then M.nbFoodTake(b, -fx.food)
        else b.food = clamp((b.food or 0) + fx.food, 0, n * ((M.nbCfg and M.nbCfg.foodCapDays) or 20)) end
    end
    if fx.morale then b.morale = clamp((b.morale or 50) + fx.morale, 0, 100) end
    local txt = string.format(fx.text, first(record))
    if fx.rep and M.nbRep then pcall(M.nbRep, b, fx.rep, txt) else event(b, txt) end
    if fx.medicine and type(b.dir) == "table" and b.dir.goals and b.dir.goals.week and b.dir.goals.week.g == "medicine" then
        b.dir.goals.week.at = -1e9 -- found: the next check finishes it
        b.dir.goals.week.g = "medicine"; b.dir.medFromPlayer = true
        event(b, "The newcomer brought the medicine they were looking for", "goal_done")
        b.dir.goals.week = nil
        b.morale = clamp((b.morale or 50) + 6, 0, 100)
    end
    pcall(M.dynTributePaid, record, player)
end

-- clearing the dead around a community
M.dynKills = {}
function M.dynZombieDead(z)
    if M.settings.dynamics == false or not M.nbActive then return end
    local zx, zy = pos(z)
    local px, py = pos(thePlayer())
    if mpServer() and zx ~= nil then px, py = pos(ALifeSide.nearest(zx, zy)) end -- MP: any player close
    if zx == nil or px == nil or (zx - px) ^ 2 + (zy - py) ^ 2 > 30 * 30 then return end
    local day = math.floor(hours() / 24)
    for _, b in ipairs(M.nbActive()) do
        if b.bounds and zx >= b.bounds.x1 - 30 and zx <= b.bounds.x2 + 30 and zy >= b.bounds.y1 - 30 and zy <= b.bounds.y2 + 30 then
            local k = M.dynKills[b.id] or {}
            if k.day ~= day then k = { day = day, n = 0 } end
            k.n = k.n + 1
            M.dynKills[b.id] = k
            if k.n == M.dynCfg.clearKills then
                b.morale = clamp((b.morale or 50) + 5, 0, 100)
                event(b, "The newcomer cleared out the dead around " .. tostring(b.name), "help")
                if type(b.dir) == "table" and b.dir.goals and b.dir.goals.day and b.dir.goals.day.g == "guard" then b.dir.goals.day.g = "rest" end
            end
            return
        end
    end
end


----------------------------------------------------------------------------------------------------------------
-- 1b. the dead you put down near people: a handful earns thanks, a few dozen real respect, a pile of them makes
--     people want to join you. Counted per group (or per person) over the last few days, by who actually saw it.
----------------------------------------------------------------------------------------------------------------
M.killTiers = {
    { n = 25,   op = 1,  rep = 1, what = "The newcomer put down some of the dead near you. Acknowledge it briefly, in your own way.",
      lines = { "Thanks for the hand.", "Appreciate that.", "Good timing.", "Nice. Thanks." } },
    { n = 75,   op = 2,  rep = 2, what = "The newcomer keeps killing the dead around you. You're starting to notice. Thank them like you mean it.",
      lines = { "You've been busy. Thanks.", "That's a lot fewer for us to worry about.", "Keep that up and we'll sleep tonight." } },
    { n = 200,  op = 4,  rep = 4, what = "The newcomer has killed a lot of the dead around you and your people. You're impressed - they're really doing a lot for you. Say so.",
      lines = { "You're doing a lot for us. Don't think we haven't noticed.", "Damn. You've cleared half the street for us.", "We owe you for this." } },
    { n = 450,  op = 6,  rep = 7, what = "The newcomer has cleared more of the dead around you than your people have in weeks. People are talking about them. Tell them.",
      lines = { "Folks are talking about you, you know.", "I've never seen anyone clear the dead like that.", "You're the reason this place is quiet." } },
    { n = 800,  op = 8,  rep = 10, what = "The newcomer has cut down an enormous number of the dead around you. You're in awe, and a little afraid of what that takes.", 
      lines = { "How are you still standing?", "There's nothing left out there. You did that.", "I don't know what you are, but I'm glad you're on our side." } },
    { n = 1500, op = 10, rep = 14, join = true, what = "The newcomer has killed more of the dead around you than you can count - more than your whole group ever could. Someone like that keeps people alive. Tell them you want to be with them: offer to join them, or ask them to take your people in.",
      lines = { "My God. We should be with you. Let us come with you.", "Whatever you're doing, we want in. Take us with you.", "With you out there we might actually make it. Let us join you." } },
}
M.killWindowH = 24 * 21
function M.dynKillCredit(z)
    if M.settings.dynamics == false then return end
    local player = thePlayer()
    local by = nil
    pcall(function() by = z:getAttackedBy() end)
    if mpServer() and ALifeSide.isOnlinePlayer(by) then player = by end -- MP: whoever killed it
    if player == nil then return end
    if by ~= player then return end
    local zx, zy, zz = pos(z)
    if zx == nil then return end
    local reg, talk = PA().ActorRegistry, PA().Talk
    if not (fn(reg, "each") and fn(talk, "shellFor")) then return end
    local h = hours()
    local store = M.store and M.store() or {}
    store.kills = type(store.kills) == "table" and store.kills or {}
    local seen = {}
    pcall(reg.each, function(r)
        if r.lifecycle == "active" and r.uid then
            local sh = talk.shellFor(tostring(r.uid))
            local sx, sy, sz = pos(sh)
            if sx and math.abs((sz or 0) - (zz or 0)) < 1 and (sx - zx) ^ 2 + (sy - zy) ^ 2 <= 25 * 25 then
                local m = type(r.memory) == "table" and r.memory or {}
                local key = m.havenId or m.groupId or ("u:" .. tostring(r.uid))
                if not seen[key] then seen[key] = { r = r, sh = sh } end
            end
        end
        return false
    end)
    for key, w in pairs(seen) do
        local k = store.kills[key]
        if k == nil or h - (tonumber(k.since) or -1e9) > M.killWindowH then k = { since = h, n = 0, tier = 0 } end
        k.n = k.n + 1
        store.kills[key] = k
        local nextTier = M.killTiers[k.tier + 1]
        if nextTier and k.n >= nextTier.n then
            k.tier = k.tier + 1
            pcall(M.dynKillTier, key, w.r, w.sh, player, nextTier, k.n)
        end
    end
end
function M.dynKillTier(key, r, sh, player, tier, count)
    local O = PA().NpcOpinion
    -- everyone in that group who's around feels it
    local m = type(r.memory) == "table" and r.memory or {}
    local reg = PA().ActorRegistry
    pcall(reg.each, function(o)
        local om = type(o.memory) == "table" and o.memory or {}
        local same = (o.uid == r.uid) or (m.havenId and om.havenId == m.havenId) or (m.groupId and om.groupId == m.groupId)
        if same and o.lifecycle == "active" and fn(O, "adjust") then
            pcall(O.adjust, o, player, tier.op, "Watched them cut down the dead around us (" .. tostring(count) .. ")")
            if M.keyMem then pcall(M.keyMem, tostring(o.uid), "deed", "You watched the newcomer put down " .. tostring(count) .. " of the dead around your people") end
        end
        return false
    end)
    local b = M.nbOfMember and M.nbOfMember(r) or nil
    if b and M.nbRep then
        pcall(M.nbRep, b, tier.rep, tier.join and ("The newcomer has put down so many of the dead around them that people want to join up with them")
            or (tier.n >= 25 and "The newcomer has done a lot to keep the dead off them" or nil))
        if tier.join then b.wantsJoin = hours() end
    end
    if tier.join then
        local store = M.store and M.store() or {}
        store.wantJoin = type(store.wantJoin) == "table" and store.wantJoin or {}
        store.wantJoin[tostring(r.uid)] = hours()
    end
    local line = tier.lines[(hash(tostring(r.uid) .. count) % #tier.lines) + 1]
    local creed = b and type(b.dir) == "table" and b.dir.creed or nil
    if tier.join and (creed == "raiders" or creed == "closed") then
        line = "...Huh. Maybe you're worth knowing after all."
        tier = { what = "The newcomer has killed a huge number of the dead around you. Your people don't join outsiders, but you're grudgingly impressed. Say so.", lines = { line } }
    end
    if tier.join and creed ~= "raiders" and creed ~= "closed" then
        M.dynAlert((b and b.name and (tostring(b.name) .. " want") or "They want") .. " to join you. Ask them", 140, 220, 140)
    end
    if M.react then
        pcall(M.react, "npcBase", { record = r, shell = sh }, player, { what = tier.what, maxWords = 22, fallback = line },
            { key = "kills:" .. tostring(key) .. ":" .. tostring(count), keyCooldownMs = 30000, modeCooldownMs = 4000, face = "player" })
    elseif M.say then pcall(M.say, sh, player, line, { record = r }) end
end

----------------------------------------------------------------------------------------------------------------
-- 2. territory
----------------------------------------------------------------------------------------------------------------
local function claimOf(x, y)
    -- pre-1.0: claimed ground = a radius around each standing claim sign (ALifeClaimSign). Old box only with signs off.
    local CS = ALifeClaimSign
    if type(CS) == "table" and type(CS.on) == "function" and CS.on() then return CS.baseAt(x, y) end
    for _, b in ipairs(M.nbActive and M.nbActive() or {}) do
        local bb, c = b.bounds, M.dynCfg.claimTiles
        if bb and x >= bb.x1 - c and x <= bb.x2 + c and y >= bb.y1 - c and y <= bb.y2 + c then return b end
    end
    return nil
end
M.dynClaimOf = claimOf
M.dynTakeAt = {}
function M.dynTake(player, container)
    if M.settings.dynamics == false or player == nil or container == nil then return end
    local mine = false
    pcall(function() mine = container:isInCharacterInventory(player) end)
    if mine then return end
    local x, y
    pcall(function() local p = container:getParent(); local sq = p and p:getSquare(); if sq then x, y = sq:getX(), sq:getY() end end)
    if x == nil then return end
    local b = claimOf(x, y)
    if b == nil or (tonumber(b.guestUntilH) or -1) > hours() then return end
    if b.bounds and x >= b.bounds.x1 - 1 and x <= b.bounds.x2 + 1 and y >= b.bounds.y1 - 1 and y <= b.bounds.y2 + 1 then return end -- their own stores: A-Life Talk handles it
    local now = M.nowMs and M.nowMs() or 0
    if now - (M.dynTakeAt[b.id] or -1e12) < 120000 then return end
    M.dynTakeAt[b.id] = now
    local creed = type(b.dir) == "table" and b.dir.creed or "wary"
    local cost = ({ closed = 6, raiders = 5, wary = 3, open = 1, traders = 2, faithful = 1 })[creed] or 3
    -- seen right now?
    local watcher = nil
    for _, r in ipairs((M.nbScan and M.nbScan().crews or {})[b.id] or {}) do
        local sx, sy = pos(shellFor(r.uid))
        if sx and (sx - x) ^ 2 + (sy - y) ^ 2 <= M.dynCfg.seeTiles ^ 2 then watcher = r; break end
    end
    if watcher then
        if M.nbRep then pcall(M.nbRep, b, -cost, "Caught the newcomer scavenging on their ground") end
        local line = ({ closed = "This is our ground. Get off it.", raiders = "Everything around here is ours. You'll pay for that.",
            wary = "That's our side of town you're picking through.", open = "We usually ask before taking around here." })[creed] or "That's ours."
        if M.react then pcall(M.react, "npcBase", { record = watcher, shell = shellFor(watcher.uid) }, player,
            { what = "The newcomer is scavenging on ground your people claim (around " .. tostring(b.name) .. "). React the way your people would (" .. creed .. ").", maxWords = 16, fallback = line },
            { key = "claim:" .. b.id, keyCooldownMs = 120000, modeCooldownMs = 5000, urgent = true, face = "player" }) end
        if (creed == "raiders" or creed == "closed") and b.leader and M.addGrudge then pcall(M.addGrudge, b.leader, 8, "scavenging on our ground", player) end
    elseif roll(b.id .. "#found" .. math.floor(now / 60000)) < 0.25 then
        b.dir = type(b.dir) == "table" and b.dir or b.dir
        if M.nbRep then pcall(M.nbRep, b, -math.max(1, math.floor(cost / 2)), "Found signs someone's been picking through their ground - they think it was the newcomer") end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 3. they come for you (and tribute)
----------------------------------------------------------------------------------------------------------------
-- MAJOR EVENTS: never left to the AI to remember. The game says them itself (story text over your head), even in
-- immersive mode - no numbers, just what happened.
function M.dynAlert(text, r, g, b)
    local player = thePlayer()
    if player == nil or text == nil then return end
    -- 0.7.0.2: the red ones (someone wants you dead, someone turned on you) are primary: a popup that pauses
    if mpServer() then pcall(ALifeSide.outLetter, ALifeSide.cur, tostring(text), r or 230, g or 180, b or 120, (tonumber(r) or 0) >= 220 and (tonumber(g) or 255) <= 100) -- MP: that player, else everyone
    elseif (tonumber(r) or 0) >= 220 and (tonumber(g) or 255) <= 100 and type(M.momAlert) == "function" then pcall(M.momAlert, tostring(text), "", "dyn:" .. tostring(text))
    else pcall(ALifeLetter, player, tostring(text), r or 230, g or 180, b or 120) end
    log("alert: " .. tostring(text))
end

function M.dynWar(h)
    local player = thePlayer()
    if player == nil or not M.nbActive or not M.nbStanding then return end
    local day = math.floor(h / 24)
    local myBase = M.playerBase and M.playerBase(player) or nil
    for _, b in ipairs(M.nbActive()) do
        local d = type(b.dir) == "table" and b.dir or nil
        if d and b.leader then
            local okS, tier, eff = pcall(M.nbStanding, b, player)
            eff = okS and tonumber(eff) or 0
            -- open war: the leader comes for you (and grows angrier each day it lasts)
            if eff <= M.dynCfg.enemyEff and (d.creed == "raiders" or d.creed == "closed" or (tonumber(b.raidedH) and h - b.raidedH < 240)) then
                if d.warDay ~= day then
                    d.warDay = day
                    if M.addGrudge then pcall(M.addGrudge, b.leader, 18, "your people are at war with the newcomer", player) end
                    if not d.warDeclared then
                        d.warDeclared = true
                        event(b, "They decided the newcomer has to answer for what they did", "war")
                        M.dynAlert("Word gets around: " .. tostring(b.name) .. " want you dead", 230, 90, 80)
                    end
                end
            end
            -- tribute: raiders who mean to rule the area demand it from anyone with a place nearby
            local ruling = d.creed == "raiders" and d.goals and d.goals.month and d.goals.month.g == "rule"
            if ruling and myBase and eff < 15 then
                local dx, dy = (myBase.x1 + myBase.x2) / 2 - b.x, (myBase.y1 + myBase.y2) / 2 - b.y
                if dx * dx + dy * dy <= 900 * 900 then
                    if d.tribute == nil and h - (tonumber(d.tributeH) or -1e9) >= 168 then
                        d.tribute = { dueH = h + M.dynCfg.tributeDays * 24 }
                        d.tributeH = h
                        pcall(M.dynDemand, b, player, myBase)
                    elseif d.tribute and h > d.tribute.dueH then
                        d.tribute = nil
                        event(b, "The newcomer never paid. They're going to collect", "tribute")
                        M.dynAlert("You never paid " .. tostring(b.name) .. ". They're coming to collect", 230, 90, 80)
                        if M.addGrudge then pcall(M.addGrudge, b.leader, 75, "didn't pay what they owed us", player) end
                    end
                end
            end
        end
    end
end

function M.dynDemand(b, player, myBase)
    event(b, "They sent word to the newcomer: pay up or else", "tribute")
    local text = "To whoever's holed up here. This area belongs to " .. tostring(b.name) .. ". You want to stay, you pay. " ..
        "Bring food to any of us within three days. Don't make us come get it."
    local okN = false
    pcall(function()
        local cx, cy = math.floor((myBase.x1 + myBase.x2) / 2), math.floor((myBase.y1 + myBase.y2) / 2)
        local N = ALifeNotes
        local sq = N and N.outdoorSquare and N.outdoorSquare(myBase.x1 - 2, cy, 0) or nil
        if sq and N.leaveNote then okN = N.leaveNote(sq, "Note nailed to your door", text) end
    end)
    pcall(ALifeSide.outLetter, player, okN and "Someone left a note outside your base" or ("Word reaches you: " .. tostring(b.name) .. " want tribute"), 230, 180, 120)
    if M.newsNote then pcall(M.newsNote, "politics", tostring(b.name) .. " are said to be demanding tribute from anyone living near them") end
end

function M.dynTributePaid(record, player)
    local band = M.bandOfUid and M.bandOfUid(record and record.uid) or nil
    for _, b in ipairs(M.nbActive and M.nbActive() or {}) do
        local d = type(b.dir) == "table" and b.dir or nil
        local same = (M.nbOfMember and M.nbOfMember(record) == b) or (band and d and d.band == band.id)
        if same and d and d.tribute then
            d.tribute = nil
            event(b, "The newcomer paid what they asked", "tribute")
            if M.nbRep then pcall(M.nbRep, b, 6, nil) end
            pcall(ALifeSide.outLetter, player, "They take it. For now.", 200, 200, 200)
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 4. unrest at your base
----------------------------------------------------------------------------------------------------------------
M.dynGripes = {
    food = { "We can't keep going on these rations.", "Who decided how the food gets split? Because it's not working.", "I'm hungry. Again." },
    danger = { "This place isn't safe. Somebody's going to die.", "How many of them are out there now? We should be doing something." },
    clash = { "I can't stand %s much longer.", "Either %s goes or I do.", "%s keeps acting like they run things." },
    you = { "You make the calls and we pay for them.", "Nobody voted for you, you know.", "I didn't sign up to follow you into the ground." },
}
function M.dynUnrest(h)
    local player = thePlayer()
    if player == nil or not M.baseState then return end
    local st = nil
    pcall(function() st = M.baseState(player) end)
    if type(st) ~= "table" or (st.settlers or 0) == 0 then return end
    if M.cpOpt and M.cpOpt("CPMorale") == false then return end -- 0.5.0: group morale off in sandbox
    local P = M.patch and M.patch() or nil
    local settlers = (P and fn(P, "settlersOf")) and P.settlersOf() or {}
    local list = {}
    for uid, e in pairs(settlers) do
        local r = rec(uid)
        if r and r.lifecycle ~= "dead" and not (M.settlerAway and M.settlerAway(uid)) then list[#list + 1] = r end
    end
    if #list == 0 then return end
    local store = M.store and M.store() or {}
    store.unrest = type(store.unrest) == "table" and store.unrest or {}
    local day = math.floor(h / 24)
    for _, r in ipairs(list) do
        local uid = tostring(r.uid)
        local l = lens(uid)
        local u = store.unrest[uid] or { v = 0 }
        local op = 0
        pcall(function() op = tonumber((PA().NpcOpinion.valueOf(r, player))) or 0 end)
        local temper = (l.volatile or 0) + (l.proud or 0) * 0.7 + (l.greedy or 0) * 0.6 + (l.mean or 0) * 0.5 - (l.calm or 0) - (l.loyal or 0) - (l.kind or 0) * 0.4
        local push = 0
        local why = nil
        if (st.foodPer or 9) < 2 then push = push + 10; why = "food" end
        if (st.safety or 100) < 50 then push = push + 6; why = why or "danger" end
        -- a housemate they clash with
        local rival = nil
        for _, o in ipairs(list) do
            if o ~= r and M.pairRow then
                local okP, s = pcall(function() local row = M.pairRow(uid, tostring(o.uid), true); return row and tonumber(row.s) end)
                if okP and tonumber(s) and s <= -30 then rival = o; push = push + 5; why = why or "clash" end
            end
        end
        if op < 0 then push = push + 4; why = why or "you" end
        -- 0.5.0: camp life (roles, losses, your own rules) - negative helps
        if M.cpMoralePush then
            local okC, cp = pcall(M.cpMoralePush, r, st, player)
            if okC and tonumber(cp) then
                if cp > 0 then why = why or "you" end
                push = push + cp
            end
        end
        push = push * (1 + temper)
        if push <= 0 then u.v = math.max(0, u.v - 8) else u.v = clamp(u.v + push, 0, 100) end
        store.unrest[uid] = u
        -- say it (once a day at most)
        if u.v >= 25 and why and u.day ~= day then
            u.day = day
            local lines = M.dynGripes[why] or M.dynGripes.you
            local line = lines[(hash(uid .. day) % #lines) + 1]
            if string.find(line, "%%s") then line = string.format(line, rival and first(rival) or "them") end
            local sh = shellFor(uid)
            local voiced = false
            if sh and M.react then
                local okR, res = pcall(M.react, "npcBase", { record = r, shell = sh }, player, { what = "You live at the newcomer's base and you're fed up (" .. why ..
                    (rival and (", especially with " .. first(rival)) or "") .. "). Grumble about it out loud, in your own words.", maxWords = 18, fallback = line },
                    { key = "unrest:" .. uid, keyCooldownMs = 600000, modeCooldownMs = 8000 })
                voiced = okR and res == true
            end
            -- 0.5.0: no AI running - they still say it (it used to stay silent)
            if not voiced and sh then pcall(function() PA().Speech.say(sh, line, {}) end) end
        end
        -- walking out, or turning
        if u.v >= M.dynCfg.walkOut and op < 10 and u.left ~= true and not (M.cpOpt and M.cpOpt("CPMoraleLeave") == false) then

            local function goOut()
            u.left = true
            if (l.volatile or 0) >= 0.3 and op <= -30 and M.addGrudge then
                pcall(M.addGrudge, uid, 70, "fed up with how the newcomer runs things", player); M.dynAlert(tostring(r.name or "Someone") .. " has turned on you", 230, 90, 80)
                if M.histAdd then pcall(M.histAdd, uid, "party", "Turned on you after too long at your base") end
            elseif M.baseLeave then
                pcall(M.baseLeave, uid, player, "fed up"); M.dynAlert(tostring(r.name or "Someone") .. " packed up and left your base", 230, 180, 120)
                if M.histAdd then pcall(M.histAdd, uid, "party", "Walked out of your base - fed up") end
            end
            pcall(function() player:setHaloNote(first(r) .. " has had enough", 230, 160, 140, 400) end)
            log(uid .. " left / turned (unrest " .. math.floor(u.v) .. ")")
            end
            -- 0.5.7: a card first (Talk them down / Let them go); cards off = they just go, as before
            if ALifeSide.canOutCard() and u.asked ~= day then
                u.asked = day
                local name = first(r)
                ALifeSide.outCard(player, { id = "walkout:" .. uid, title = name .. " has had enough", default = 2,
                    text = name .. " is packing up. " .. (why == "food" and "They say there isn't enough to eat." or why == "danger" and "They say it isn't safe here." or why == "clash" and ("They can't stand living with " .. (rival and first(rival) or "someone here") .. ".") or "They say it's how you run things.")
                        .. " <LINE> <LINE> Talking them down works better if they like you.",
                    choices = {
                        { label = "Talk them down", fn = function()
                            local chance = math.max(0.1, math.min(0.85, 0.35 + op / 100 + (l.loyal or 0) * 0.3 - (l.volatile or 0) * 0.3))
                            if (hash(uid .. day .. "talk") % 100) / 100 < chance then
                                u.v = M.dynCfg.walkOut * 0.6
                                local sh = shellFor(uid)
                                if sh then pcall(function() PA().Speech.say(sh, "...Fine. One more week. Things better change.", {}) end) end
                                if M.cpLog then pcall(M.cpLog, "morale", "you talked " .. name .. " into staying") end
                            else
                                local sh = shellFor(uid)
                                if sh then pcall(function() PA().Speech.say(sh, "No. I'm done. Don't follow me.", {}) end) end
                                goOut()
                            end
                        end },
                        { label = "Let them go", fn = goOut },
                    } })
            else
                goOut()
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 5. secret pacts (raiders and the groups they quietly protect / trade with)
----------------------------------------------------------------------------------------------------------------
function M.dynSecrets()
    if not M.nbActive or not M.dirTieState then return end
    for _, b in ipairs(M.nbActive()) do
        local d = type(b.dir) == "table" and b.dir or nil
        if d and d.ties then
            d.secret = d.secret or {}
            for id, v in pairs(d.ties) do
                local o = M.nbOf and M.nbOf(id) or nil
                local od = o and type(o.dir) == "table" and o.dir or nil
                if od and M.dirTieState(v) == "allied" and d.secret[id] == nil then
                    local hush = (d.creed == "raiders") ~= (od.creed == "raiders") or d.creed == "closed" or od.creed == "closed"
                    d.secret[id] = hush and true or false
                    if od.secret == nil then od.secret = {} end
                    od.secret[b.id] = d.secret[id]
                end
            end
        end
    end
end
function M.dynSecretKnown(b, player)
    local okS, _, eff = pcall(M.nbStanding, b, player)
    return okS and tonumber(eff) and eff >= 35
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
local function install()
    if M.__dynInstalled then return true end
    local O = PA().NpcOpinion
    if not fn(O, "note") then return false end
    M.__dynInstalled = true
    local note = O.note
    O.note = function(kind, ref, player, options, ...)
        local r = note(kind, ref, player, options, ...)
        pcall(function() M.dynDeed(kind, fn(O, "recordOf") and O.recordOf(ref) or nil, player) end)
        return r
    end
    if type(M.nbOnTake) == "function" then
        local take = M.nbOnTake
        M.nbOnTake = function(player, container, ...)
            local handled = take(player, container, ...)
            if not handled then pcall(M.dynTake, player, container) end
            return handled
        end
    end
    if type(M.nbOnZombieDead) == "function" then
        local zd = M.nbOnZombieDead
        M.nbOnZombieDead = function(z, ...)
            local r = zd(z, ...)
            pcall(M.dynZombieDead, z)
            pcall(M.dynKillCredit, z)
            return r
        end
    end
    -- the AI hears about secret pacts only on the inside, and the newcomer only once trusted
    if type(M.nbBrief) == "function" then
        local brief = M.nbBrief
        M.nbBrief = function(b, h, player, ...)
            local nb = brief(b, h, player, ...)
            pcall(function()
                local d = type(b) == "table" and b.dir or nil
                if type(nb) ~= "table" or d == nil or type(d.secret) ~= "table" then return end
                local hidden = {}
                for id, s in pairs(d.secret) do if s then local o = M.nbOf(id); if o then hidden[#hidden + 1] = o.name end end end
                if #hidden > 0 then
                    nb.secretAllies = hidden
                    nb.secretOk = M.dynSecretKnown(b, player) or nil
                end
                if d.tribute then nb.tributeDemanded = true end
            end)
            pcall(function()
                if type(nb) ~= "table" or type(b) ~= "table" then return end
                local d = type(b.dir) == "table" and b.dir or {}
                if d.warDeclared and player and M.nbStanding then
                    local okS, _, eff = pcall(M.nbStanding, b, player)
                    if okS and (tonumber(eff) or 0) <= M.dynCfg.enemyEff then nb.atWar = true end
                end
                if b.wantsJoin and hours() - b.wantsJoin < M.killWindowH * 2 then nb.wantsJoin = true end
            end)
            return nb
        end
    end
    -- someone who saw you cut down a horde for them wants to come along: they say yes when you ask
    if type(M.recruitVerdict) == "function" then
        local verdict = M.recruitVerdict
        M.recruitVerdict = function(listener, player, ...)
            local ok, why, need, v = verdict(listener, player, ...)
            if not ok then
                pcall(function()
                    local uid = tostring(listener.record.uid)
                    local wj = (M.store().wantJoin or {})[uid]
                    local b = M.nbOfMember and M.nbOfMember(listener.record) or nil
                    local creed = b and type(b.dir) == "table" and b.dir.creed or nil
                    if (wj and hours() - wj < M.killWindowH * 2) or (b and b.wantsJoin and hours() - b.wantsJoin < M.killWindowH * 2) then
                        if creed ~= "raiders" and creed ~= "closed" and (v or 0) > -20 then
                            ok, why = true, "you've watched them cut down a horde of the dead for you - you want to be with someone like that"
                        end
                    end
                end)
            end
            return ok, why, need, v
        end
    end
    log("ready (kingmaker, territory, war + tribute, unrest, secret pacts, horde credit)")
    return true
end

if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(install) end) end
    if Events.EveryHours then
        ALifeHealth.add(Events.EveryHours, "ALifeLLMTalk_Dynamics", function()
            if M.settings.dynamics == false then return end
            if not M.__dynInstalled then pcall(install) end
            local h = hours()
            local ok, err = pcall(M.dynWar, h); if not ok then log("war failed: " .. tostring(err)) end
            pcall(M.dynSecrets)
            if math.floor(h) % M.dynCfg.unrestEvery == 18 then local ok2, e2 = pcall(M.dynUnrest, h); if not ok2 then log("unrest failed: " .. tostring(e2)) end end
        end)
    end
end
