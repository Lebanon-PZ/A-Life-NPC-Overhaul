-- A-Life NPC Overhaul 0.9.1 (Legacy): EVERY STORY ENDS. The 0.8.7 stories (ALifeGoals) get three acts and an end.
--   * Act 1, the hook: the goal itself (family / amends / revenge / clean), as before.
--   * Act 2, a lead: storyLeadDays in, word comes where their person really is (their real position and group, read
--     on the server: ALifeQuests storyLead), heard from a rumor, a trader or the radio. A letter, and they remember it.
--   * Act 3, the end, always with real people: found them (reunion), a grave (kin died: "grave"), revenge taken / their
--     person died first, made it right / never could, clean / relapsed, and now also: nothing moved for storyStallDays
--     -> it ends itself (they let it go, or it turns bitter; their temperament decides, on the server).
--   * Grudges pass to kin: someone who held a grudge against you dies -> their family carries it on (storyInherit % of
--     it), and an open revenge story passes to a relative who has none.
--   * Familiar face (rare): one of your camp who turned (Turned's tagged zombie) sometimes drifts back toward the camp
--     (vanilla zombie pathToLocation); when it gets close the camp knows who it was.
-- After an end: their mood moves (Psyche feel), a key memory, a Chronicle entry, and a new want after questStoryGap days.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_StoryEnds") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeTalk_Story"
local M = ALifeLLMTalk
local K = ALifeGoals
if type(M) ~= "table" or type(K) ~= "table" then return end
ALifeStoryEnds = ALifeStoryEnds or {}
local E = ALifeStoryEnds
local TAG = "[ALifeStoryEnds]"
E.VERSION = "0.9.1"
E.DEFAULTS = {
    storyInherit = 50,     -- % of a dead person's grudge against you their family carries on
    storyFamiliar = true,  -- a turned camp member sometimes drifts back toward the camp
    storyFamiliarChance = 10, -- % a game hour a loaded one starts for home
    storyFamiliarTiles = 250, -- only from this close to the camp (tiles)
}
E.stats = { leads = 0, stalls = 0, graves = 0, inherited = 0, passed = 0, homecomings = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(uid)
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or "someone"
end
local function setting(k)
    local v = nil
    if type(M.settings) == "table" then v = M.settings[k] end
    if v == nil then v = E.DEFAULTS[k] end
    return v
end
local function feel(uid, key, amount, why) if fn(M, "feel") then pcall(M.feel, uid, key, amount, why) end end
local function keyMem(uid, kind, text) if fn(M, "keyMem") then pcall(M.keyMem, uid, kind, text) end end
local function letter(text)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, playerOf(), text, 200, 200, 160) end; return end -- MP: that player
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), text, 200, 200, 160) end
end
local function send(name, args) local p = playerOf(); if p and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, p, name, args) end end
local function isDead(uid) local r = rec(uid); return r == nil or r.lifecycle == "dead" end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(E.DEFAULTS) do
            if M.settings[k] == nil then M.settings[k] = v end
            if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end

-- ------------------------------------------------------------------------------------------------ acts 2 and 3
-- every game hour: ask for a lead when it's time, end a stalled story, family dead -> a grave
function E.tick(player)
    if player == nil then return 0 end
    local now, n = hours(), 0
    for uid, row in pairs(K.store()) do
        if type(row) == "table" and row.outcome == nil and type(uid) == "string" and string.find(uid, ":", 1, true) == nil then
            local age = now - (tonumber(row.h) or now)
            if (row.k == "family" or row.k == "prodigal") and row.t and isDead(row.t) then
                row.deadSeen = row.deadSeen or now
                if now - row.deadSeen >= 2 then send("storyGoal", { act = "gone", uid = uid }); n = n + 1 end
            elseif age >= (tonumber(setting("storyStallDays")) or 30) * 24 then
                send("storyGoal", { act = "stall", uid = uid }); n = n + 1
            elseif (row.k == "family" or row.k == "amends" or row.k == "revenge" or row.k == "prodigal") and age >= (tonumber(setting("storyLeadDays")) or 2) * 24
                    and now - (tonumber(row.leadAskH) or -1e9) >= (tonumber(setting("storyLeadGap")) or 3) * 24 then
                row.leadAskH = now
                send("storyGoal", { act = "lead", uid = uid }); n = n + 1
            end
        end
    end
    return n
end
-- the server's answer carries the lead: tell it once
function E.onLead(uid, row, lead)
    if type(lead) ~= "table" or row.leadSeen == lead.h then return false end
    row.leadSeen = lead.h
    row.act = 2
    local who, t = first(uid), tostring(row.tn or "them")
    local where = (lead.grp and ("with " .. tostring(lead.grp) .. " ") or "") .. "around " .. tostring(lead.x) .. ", " .. tostring(lead.y)
    local what = (row.k == "family" or row.k == "prodigal") and (t .. " is alive, " .. where) or (t .. " was seen " .. where)
    keyMem(uid, "story", "Heard from " .. tostring(lead.how) .. ": " .. what)
    letter(who .. " heard from " .. tostring(lead.how) .. ": " .. what .. ".")
    row.lead = { x = lead.x, y = lead.y, grp = lead.grp, how = lead.how }
    E.stats.leads = E.stats.leads + 1
    return true
end
-- the new endings
function E.ending(uid, row, g)
    local o = tostring(row.outcome or "")
    local t = tostring(row.tn or "them")
    if o == "grave" then
        E.stats.graves = E.stats.graves + 1
        feel(uid, "grief", 0.7, t .. " is dead")
        keyMem(uid, "loss", "Found out " .. t .. " is dead. Never got to see them again")
    elseif o == "letgo" then
        E.stats.stalls = E.stats.stalls + 1
        feel(uid, "relief", 0.3, "let it go")
        keyMem(uid, "story", row.k == "revenge" and ("Let it go. " .. t .. " isn't worth the rest of my life") or ("Stopped waiting on " .. t .. ". Made my peace with it"))
    elseif o == "bitter" then
        E.stats.stalls = E.stats.stalls + 1
        feel(uid, "anger", 0.4, "it never came")
        feel(uid, "sadness", 0.3, "gave up on " .. t)
        keyMem(uid, "story", row.k == "revenge" and (t .. " is still out there. That eats at me") or ("Gave up on " .. t .. ". Nobody helped"))
    end
    row.act = 3
    return o
end
function E.hook()
    if E.hooked then return true end
    if not fn(K, "onGoals") or not fn(K, "outcome") then return false end
    local origGoals = K.onGoals
    K.onGoals = function(payload, ...)
        local r = origGoals(payload, ...)
        pcall(function()
            for uid, g in pairs(type(payload) == "table" and type(payload.goals) == "table" and payload.goals or {}) do
                local row = K.rowOf(uid)
                if type(g) == "table" and row and row.outcome == nil and g.leadH then
                    E.onLead(tostring(uid), row, { h = g.leadH, x = g.leadX, y = g.leadY, grp = g.leadGrp, how = g.leadHow })
                end
            end
        end)
        return r
    end
    -- ALifeCmd keeps one handler per name and Story registered the old function: route it through the wrapped one
    if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("storyGoals", function(p) return K.onGoals(p) end) end
    local origOut = K.outcome
    K.outcome = function(uid, row, g, ...)
        local r = origOut(uid, row, g, ...)
        pcall(E.ending, uid, row, g)
        return r
    end
    E.hooked = true
    return true
end

-- ------------------------------------------------------------------------------------------------ grudges pass to kin
E.KIN = { sibling = true, parent = true, child = true, partner = true }
function E.kinOf(uid)
    local out = {}
    if not fn(M, "tiesOf") then return out end
    local ok, list = pcall(M.tiesOf, tostring(uid), nil, 12, true)
    for _, t in ipairs(ok and type(list) == "table" and list or {}) do
        if E.KIN[t.type] and t.uid and not t.dead and not isDead(t.uid) then out[#out + 1] = { uid = tostring(t.uid), type = t.type } end
    end
    return out
end
function E.onDied(body, uid, killer)
    uid = tostring(uid or "")
    if uid == "" then return 0 end
    local n = 0
    -- a grudge against you
    local nem = fn(M, "nemesisOf") and M.nemesisOf(uid) or nil
    local share = (tonumber(setting("storyInherit")) or 50) / 100
    if type(nem) == "table" and (tonumber(nem.g) or 0) >= 35 and share > 0 and fn(M, "addGrudge") then
        for _, k in ipairs(E.kinOf(uid)) do
            pcall(M.addGrudge, k.uid, nem.g * share, "carries on their " .. k.type .. " " .. first(uid) .. "'s grudge against you", playerOf())
            keyMem(k.uid, "grudge", first(uid) .. " hated the newcomer. Now they're dead, and I remember why")
            E.stats.inherited = E.stats.inherited + 1
            n = n + 1
        end
    end
    -- an open revenge story: a relative with no story takes it on (the server checks it's real)
    local row = K.rowOf(uid)
    if row and row.k == "revenge" and row.outcome == nil and row.t and not isDead(row.t) then
        for _, k in ipairs(E.kinOf(uid)) do
            local theirs = K.rowOf(k.uid)
            if (theirs == nil or theirs.outcome ~= nil) and k.uid ~= tostring(row.t) then
                K.store()[k.uid] = { k = "revenge", t = row.t, tn = row.tn, h = hours(), inherited = uid }
                send("storyGoal", { act = "set", uid = k.uid, k = "revenge", t = row.t, tn = row.tn })
                keyMem(k.uid, "story", first(uid) .. " wanted " .. tostring(row.tn) .. " dead. Now it's on me")
                E.stats.passed = E.stats.passed + 1
                n = n + 1
                break
            end
        end
    end
    return n
end

-- ------------------------------------------------------------------------------------------------ familiar face
function E.campCentre(player)
    local b = nil
    if fn(M, "wzBase") then pcall(function() b = M.wzBase(player) end) end
    if type(b) ~= "table" then return nil end
    local x = b.x or (b.x1 and b.x2 and math.floor((b.x1 + b.x2) / 2))
    local y = b.y or (b.y1 and b.y2 and math.floor((b.y1 + b.y2) / 2))
    if x == nil or y == nil then return nil end
    return x, y, b.z or 0
end
function E.wasOurs(uid)
    if string.sub(tostring(uid), 1, 7) == "player:" then return true end -- 0.9.2: your own old self (ALifeTalk_Legacy)
    if fn(M, "settlerOf") then local ok, s = pcall(M.settlerOf, uid); if ok and s then return true end end
    local g = nil
    if fn(M, "grData") then pcall(function() g = M.grData() end) end
    for _, e in ipairs(type(g) == "table" and type(g.dead) == "table" and g.dead or {}) do if tostring(e.uid) == tostring(uid) then return true end end
    return false
end
E.home = E.home or {} -- [uid] = { started = h, near = bool }
function E.familiar(player, rollFn)
    if setting("storyFamiliar") == false or player == nil then return 0 end
    local cx, cy, cz = E.campCentre(player)
    if cx == nil then return 0 end
    local cell = nil
    pcall(function() cell = getCell() end)
    if cell == nil then return 0 end
    local list, n = nil, 0
    pcall(function() list = cell:getZombieList() end)
    pcall(function() n = list:size() end)
    local reach = tonumber(setting("storyFamiliarTiles")) or 250
    local moved = 0
    for i = 0, math.min(n, 800) - 1 do
        local z = list:get(i)
        local md = nil
        pcall(function() md = z:getModData() end)
        local uid = type(md) == "table" and md.TalkWasUid or nil
        if uid and E.wasOurs(uid) then
            local zx, zy = nil, nil
            pcall(function() zx, zy = z:getX(), z:getY() end)
            local d2 = zx and ((zx - cx) ^ 2 + (zy - cy) ^ 2) or 1e12
            local h = E.home[tostring(uid)]
            if h and not h.near and d2 <= 15 * 15 then
                h.near = true
                E.stats.homecomings = E.stats.homecomings + 1
                local name = tostring(md.TalkWasName or first(uid))
                letter("Something is shambling at the edge of camp. The way it walks... it's " .. name .. ".")
                if fn(M, "cpPeople") then
                    for _, u in ipairs(M.cpPeople(player) or {}) do keyMem(u, "turned", name .. " came back to camp. One of them now, but it walked home") end
                end
                if type(ALifeChronicleUI) == "table" and fn(ALifeChronicleUI, "note") then pcall(ALifeChronicleUI.note, "story", name, tostring(uid), "came home to camp, one of the dead now") end
            elseif h == nil and d2 <= reach * reach and d2 > 15 * 15 then
                local roll = rollFn and rollFn() or 100
                if roll == 100 then pcall(function() roll = ZombRand(100) end) end
                if roll < (tonumber(setting("storyFamiliarChance")) or 10) then
                    local ok = pcall(function() z:pathToLocation(math.floor(cx), math.floor(cy), math.floor(cz or 0)) end) -- vanilla (DebugContextMenu)
                    if ok then E.home[tostring(uid)] = { started = hours() }; moved = moved + 1 end
                end
            elseif h and not h.near then
                pcall(function() z:pathToLocation(math.floor(cx), math.floor(cy), math.floor(cz or 0)) end) -- keep it walking
            end
        end
    end
    return moved
end

function E.install()
    pcall(E.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "storyLeadDays", "Stories: days in before a lead turns up (where their person is)", { 1, 2, 4, 7 } },
            { "storyStallDays", "Stories: a story nobody moves ends itself after this many days", { 14, 30, 60 } },
            { "storyInherit", "Stories: share of a dead person's grudge their family carries on (%)", { 0, 25, 50, 100 } },
            { "storyFamiliar", "Stories: a turned camp member sometimes walks back toward camp" },
            { "storyFamiliarChance", "Stories: chance a game hour a turned camp member heads home (%)", { 2, 5, 10, 25 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. E.VERSION .. ": leads, stalls, graves, grudges to kin" .. (E.hooked and "" or " (Goals NOT hooked)") .. ", familiar face " .. (setting("storyFamiliar") ~= false and "on" or "off"))
end
pcall(E.hook)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(E.install) end) end
    if Events.EveryHours then Events.EveryHours.Add(function() -- pre-1.0 MP (P5): once per online player (SP: you)
        local function one(p) pcall(E.tick, p); pcall(E.familiar, p) end
        if ALifeSide.mpServer() then ALifeSide.each(one) else one(playerOf()) end
    end) end
    if type(Events.ProjectALife_NpcDied) == "table" and fn(Events.ProjectALife_NpcDied, "Add") then
        Events.ProjectALife_NpcDied.Add(function(body, uid, killer) pcall(E.onDied, body, uid, killer) end)
    end
end
return E
