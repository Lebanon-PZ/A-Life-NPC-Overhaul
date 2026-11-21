-- A-Life NPC Overhaul 0.9.3 (Legacy): TRIBUTE AND POWER PLAYS between real groups (the NPC bases this mod keeps).
--   * TRIBUTE BETWEEN GROUPS: a ruling raider band (or any group far stronger than a neighbour within 900 tiles) makes
--     the weaker one pay: every week real food moves from their stores to the strong one's (the bases' own ledgers).
--     When you're near the ones paying, they ask you: help them break it (you back them: when the strong ones come to
--     collect, your strength stands with them), collect it for the strong ones (they like you, the weak hate you), or
--     stay out of it.
--   * THE KINGDOM DEAL: the strongest group around your base, far stronger than you, offers you a place under them:
--     food every week to any of them, and nobody weaker dares ask you for tribute. Miss a week and the deal is off.
--   * TWO CAMPS BLAME EACH OTHER: one of a group's people dies to the dead (or nobody saw) near another group, and
--     they blame the neighbours. If you're close, they ask what you know: the truth (it was the dead) calms it if
--     they believe you; a lie sets them on the neighbours (a real attack, their real strength); staying out, maybe.
--   * THE INSIDE MAN is a task on the board (ALifeQuests "spy_rival"): watch a rival group's place for the giver.
-- All written to the Chronicle (when it touches you) and to the groups' own event logs. Settings: powerPlays,
-- powerTributeDays, powerKingdom.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Power") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifePower = ALifePower or {}
local W = ALifePower
local TAG = "[ALifePower]"
W.VERSION = ALifeSide.MOD_VERSION
W.DEFAULTS = {
    powerPlays = true,       -- groups make each other pay, blame each other, and ask you to pick a side
    powerTributeDays = 7,    -- days between tribute payments
    powerKingdom = true,     -- the strongest group near you can offer a place under them
    powerWeakRatio = 60,     -- % of the strong group's strength (or less) that makes a neighbour pay
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = W.DEFAULTS[k] end; return v end
local function letter(t) -- pre-1.0 MP: on a server the player handled, else everyone online (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, ALifeSide.cur, t, 220, 190, 140) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 220, 190, 140) end
end
local function chron(k, what) if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = k, what = what }) end end
local function event(b, text) if fn(M, "nbEvent") then pcall(M.nbEvent, b, text, "politics") end end
local function news(t) if fn(M, "newsNote") then pcall(M.newsNote, "politics", t) end end
local function str(b) local ok, s = pcall(M.nbStrength, b); return ok and tonumber(s) or 0 end
local function d2(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(W.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function W.on() return setting("powerPlays") ~= false end
function W.store()
    local s = fn(M, "bucket") and M.bucket("power") or (W._mem or {})
    if not fn(M, "bucket") then W._mem = s end
    s.tribute = type(s.tribute) == "table" and s.tribute or {}  -- [weakId] = { strong, since, lastH, asked, side }
    s.blame = type(s.blame) == "table" and s.blame or {}        -- list of { a, b, name, h, asked }
    return s
end
local function active() return fn(M, "nbActive") and M.nbActive() or {} end
local function byId(id) return fn(M, "nbOf") and M.nbOf(id) or nil end
local function near(player, b, r)
    local x, y = nil, nil
    pcall(function() x, y = player:getX(), player:getY() end)
    return x ~= nil and tonumber(b.x) and (x - b.x) ^ 2 + (y - b.y) ^ 2 <= r * r
end
local function myStrength()
    local L = ALifeKingmaker
    return (type(L) == "table" and type(L.last) == "table" and tonumber(L.last.mine)) or 0
end
local function ruling(b) local d = type(b.dir) == "table" and b.dir or {}; return d.creed == "raiders" and type(d.goals) == "table" and type(d.goals.month) == "table" and d.goals.month.g == "rule" end

-- ---------------------------------------------------------------------------------------------- tribute
-- a strong group starts making a weak neighbour pay
function W.startTributes(h)
    local s, n = W.store(), 0
    local list = active()
    local ratio = (tonumber(setting("powerWeakRatio")) or 60) / 100
    for _, strong in ipairs(list) do
        local ss = str(strong)
        if ss > 0 and (ruling(strong) or ss >= 20) then
            for _, weak in ipairs(list) do
                if weak.id ~= strong.id and s.tribute[weak.id] == nil and tonumber(weak.x) and tonumber(strong.x) and d2(weak, strong) <= 900 * 900 then
                    local ws = str(weak)
                    if ws > 0 and ws <= ss * ratio then
                        s.tribute[weak.id] = { strong = strong.id, since = h, lastH = h }
                        event(weak, tostring(strong.name) .. " told them to pay, every week, or else")
                        event(strong, "They made " .. tostring(weak.name) .. " pay them, every week")
                        news(tostring(strong.name) .. " are making " .. tostring(weak.name) .. " pay them")
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end
-- every week: real food moves; a broken tribute brings the strong ones to collect
function W.collect(h, player)
    local s, n = W.store(), 0
    local days = tonumber(setting("powerTributeDays")) or 7
    for weakId, t in pairs(s.tribute) do
        local weak, strong = byId(weakId), byId(t.strong)
        if weak == nil or strong == nil or weak.status ~= "active" or strong.status ~= "active" then s.tribute[weakId] = nil
        elseif h - (tonumber(t.lastH) or h) >= days * 24 then
            t.lastH = h
            if t.side == "break" then
                -- they stopped paying: the strong ones come; your strength stands with them
                local old = M.nbForceStrength
                M.nbForceStrength = math.max(1, math.floor(str(strong) - myStrength()))
                local haven = fn(M, "nbHavenOf") and M.nbHavenOf(weak) or nil
                local crew = {}
                pcall(function() crew = M.nbScan(true).crews[weak.id] or {} end)
                local ok, res = pcall(M.nbAttack, weak, haven, crew, 1, h, "raiders")
                M.nbForceStrength = old
                if ok and res == "repelled" then
                    s.tribute[weakId] = nil
                    letter(tostring(weak.name) .. " held when " .. tostring(strong.name) .. " came to collect. With you behind them, they don't pay any more.")
                    chron("war", tostring(weak.name) .. " broke " .. tostring(strong.name) .. "'s hold on them, with our help")
                    if fn(M, "nbRep") then pcall(M.nbRep, weak, 10, "helped them stop paying " .. tostring(strong.name)) end
                else
                    t.side = nil
                    letter(tostring(strong.name) .. " came to collect from " .. tostring(weak.name) .. ", and took it by force.")
                end
                n = n + 1
            else
                local per = math.max(1, math.floor((tonumber(weak.crewN) or 2) / 2))
                local got = fn(M, "nbFoodTake") and M.nbFoodTake(weak, per) or 0
                if got > 0 and fn(M, "nbFoodAdd") then M.nbFoodAdd(strong, got) end
                if t.side == "collect" and fn(M, "nbRep") then pcall(M.nbRep, strong, 2, "you collect for them") end
                n = n + 1
            end
        end
    end
    return n
end
-- near the ones paying: they ask you (once)
function W.askTribute(player)
    local s = W.store()
    for weakId, t in pairs(s.tribute) do
        local weak, strong = byId(weakId), byId(t.strong)
        if weak and strong and not t.asked and near(player, weak, 60) then
            t.asked = hours()
            local function help()
                t.side = "break"
                if type(ALifeKingmaker) == "table" and fn(ALifeKingmaker, "back") then pcall(ALifeKingmaker.back, player, weak, strong) end
                if fn(M, "nbRep") then pcall(M.nbRep, strong, -15, "you told " .. tostring(weak.name) .. " to stop paying them") end
                chron("backed", "we stood with " .. tostring(weak.name) .. " against " .. tostring(strong.name) .. "'s tribute")
            end
            local function collect()
                t.side = "collect"
                if fn(M, "nbRep") then pcall(M.nbRep, strong, 8, "you help them collect"); pcall(M.nbRep, weak, -15, "you collect for " .. tostring(strong.name)) end
                chron("backed", "we collected " .. tostring(strong.name) .. "'s tribute from " .. tostring(weak.name))
            end
            if ALifeSide.canOutCard() then
                pcall(ALifeSide.outCard, playerOf(), { id = "tribute:" .. tostring(weakId), title = tostring(weak.name) .. " pay " .. tostring(strong.name), default = 3,
                    text = "\"Every week " .. tostring(strong.name) .. " take our food. We can't stop them alone.\" <LINE> <LINE> Help them stop paying, collect it for "
                        .. tostring(strong.name) .. ", or stay out of it?",
                    choices = { { label = "Help them break it", fn = help }, { label = "Collect it for " .. tostring(strong.name), fn = collect }, { label = "Stay out of it", fn = function() end } } })
            end
            return weakId
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------- the kingdom deal
function W.kingdom(player, h)
    if setting("powerKingdom") == false or player == nil then return nil end
    local s = W.store()
    local mine = myStrength()
    if s.kingdom and not s.kingdom.off then
        local k = s.kingdom
        local b = byId(k.id)
        if b == nil or b.status ~= "active" then s.kingdom = nil; return "gone" end
        if h - (tonumber(k.paidH) or k.since or h) > (tonumber(setting("powerTributeDays")) or 7) * 24 + 24 then
            k.off = h
            if fn(M, "nbRep") then pcall(M.nbRep, b, -20, "stopped paying what they owed us") end
            letter("You didn't pay " .. tostring(b.name) .. ". The deal is off, and they're not happy about it.")
            chron("backed", "the deal with " .. tostring(b.name) .. " ended: we stopped paying")
            return "off"
        end
        return "kept"
    end
    if s.kingdomAskedH and h - s.kingdomAskedH < 30 * 24 then return nil end
    local myBase = fn(M, "playerBase") and M.playerBase(player) or nil
    if myBase == nil then return nil end
    local cx, cy = (myBase.x1 + myBase.x2) / 2, (myBase.y1 + myBase.y2) / 2
    local best, bestS = nil, 0
    for _, b in ipairs(active()) do
        if tonumber(b.x) and (b.x - cx) ^ 2 + (b.y - cy) ^ 2 <= 1200 * 1200 then
            local bs = str(b)
            if bs > bestS then best, bestS = b, bs end
        end
    end
    if best == nil or bestS < math.max(10, mine * 2) then return nil end
    s.kingdomAskedH = h
    local function yes()
        s.kingdom = { id = best.id, since = h, paidH = h }
        chron("backed", "we took a place under " .. tostring(best.name) .. ": food every week, and nobody else asks")
        letter("You're under " .. tostring(best.name) .. " now. Food to any of them every week.")
    end
    if ALifeSide.canOutCard() then
        pcall(ALifeSide.outCard, playerOf(), { id = "kingdom:" .. tostring(best.id), title = tostring(best.name) .. " make an offer", default = 2,
            text = "\"You're small, we're not. Pay us every week and nobody else around here touches you.\" <LINE> <LINE> Food to any of them every "
                .. tostring(setting("powerTributeDays")) .. " days.",
            choices = { { label = "Take the deal", fn = yes }, { label = "Turn it down", fn = function() if fn(M, "nbRep") then pcall(M.nbRep, best, -5, "turned down our offer") end end } } })
    end
    return "offered"
end
-- paying the kingdom: food handed to one of them (Dynamics' tribute-paid path)
function W.paid(record, player)
    local s = W.store()
    local k = s.kingdom
    if k == nil or k.off then return false end
    local b = fn(M, "nbOfMember") and M.nbOfMember(record) or nil
    if b and b.id == k.id then k.paidH = hours(); return true end
    return false
end

-- ---------------------------------------------------------------------------------------------- blame
function W.onDied(body, uid, killer)
    if not W.on() then return nil end
    local r = nil
    pcall(function() r = ProjectALife.ActorRegistry.read(tostring(uid)) end)
    local a = (r and fn(M, "nbOfMember")) and M.nbOfMember(r) or nil
    if a == nil or a.status ~= "active" then return nil end
    local byDead = killer == nil
    if killer ~= nil then pcall(function() byDead = instanceof(killer, "IsoZombie") end) end
    if not byDead then return nil end
    local x, y = nil, nil
    pcall(function() x, y = body:getX(), body:getY() end)
    x, y = x or a.x, y or a.y
    local blamed, bestD = nil, 400 * 400
    for _, b in ipairs(active()) do
        if b.id ~= a.id and tonumber(b.x) then
            local dd = (b.x - x) ^ 2 + (b.y - y) ^ 2
            if dd < bestD then blamed, bestD = b, dd end
        end
    end
    if blamed == nil then return nil end
    local name = "one of theirs"
    pcall(function() name = string.match(tostring(ProjectALife.Names.of(r)), "^(%S+)") or name end)
    local s = W.store()
    s.blame[#s.blame + 1] = { a = a.id, b = blamed.id, name = name, h = hours() }
    while #s.blame > 10 do table.remove(s.blame, 1) end
    event(a, "They blame " .. tostring(blamed.name) .. " for " .. name .. "'s death")
    news(tostring(a.name) .. " blame " .. tostring(blamed.name) .. " for a death")
    return blamed.id
end
function W.attack(from, to, h)
    local old = M.nbForceStrength
    M.nbForceStrength = math.max(1, math.floor(str(from)))
    local haven = fn(M, "nbHavenOf") and M.nbHavenOf(to) or nil
    local crew = {}
    pcall(function() crew = M.nbScan(true).crews[to.id] or {} end)
    local ok, res = pcall(M.nbAttack, to, haven, crew, 1, h, "raiders")
    M.nbForceStrength = old
    return ok and res or nil
end
function W.askBlame(player, rollFn)
    local s = W.store()
    for _, e in ipairs(s.blame) do
        local a, b = byId(e.a), byId(e.b)
        if a and b and not e.asked and hours() - e.h <= 72 and near(player, a, 60) then
            e.asked = hours()
            local function roll() if rollFn then return rollFn() end local v = 99; pcall(function() v = ZombRand(100) end); return v end
            local function truth()
                local standing = 50
                pcall(function() local _, eff = M.nbStanding(a, player); standing = 50 + (tonumber(eff) or 0) / 2 end)
                if roll() < standing then
                    e.done = "calmed"
                    event(a, "The newcomer told them it was the dead. They let it go")
                    chron("other", tostring(a.name) .. " nearly went to war over " .. e.name .. "; we told them the truth")
                else
                    e.done = "war"
                    W.attack(a, b, hours())
                    letter(tostring(a.name) .. " didn't believe you. They went after " .. tostring(b.name) .. " anyway.")
                end
            end
            local function lie()
                e.done = "lie"
                if fn(M, "nbRep") then pcall(M.nbRep, a, 5, "told them who did it") end
                local res = W.attack(a, b, hours())
                letter(tostring(a.name) .. " went after " .. tostring(b.name) .. ". " .. ((res == "overrun" or res == "overrun_held") and "It went badly for " .. tostring(b.name) .. "." or "They were driven off."))
                chron("war", "we told " .. tostring(a.name) .. " that " .. tostring(b.name) .. " killed " .. e.name .. ". It wasn't true")
            end
            local function out()
                e.done = "out"
                if roll() < 50 then W.attack(a, b, hours()) end
            end
            if ALifeSide.canOutCard() then
                pcall(ALifeSide.outCard, playerOf(), { id = "blame:" .. tostring(e.a) .. ":" .. tostring(e.h), title = tostring(a.name) .. " want answers", default = 3,
                    text = "\"" .. e.name .. " is dead. " .. tostring(b.name) .. " did it, didn't they?\" <LINE> <LINE> It was the dead, as far as anyone knows.",
                    choices = { { label = "It was the dead", fn = truth }, { label = "Yes, " .. tostring(b.name) .. " did it", fn = lie }, { label = "Stay out of it", fn = out } } })
            end
            return e
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------- ticks
function W.daily(player)
    if not W.on() then return end
    local h = hours()
    W.startTributes(h)
    W.collect(h, player)
    W.kingdom(player, h)
end
function W.hourly(player)
    if not W.on() or player == nil then return end
    W.askTribute(player)
    W.askBlame(player)
end
function W.hook()
    if W.hooked or not fn(M, "dynTributePaid") then return W.hooked == true end
    local orig = M.dynTributePaid
    M.dynTributePaid = function(record, player, ...)
        pcall(W.paid, record, player)
        return orig(record, player, ...)
    end
    -- under a kingdom: nobody weaker than your lord dares demand (Dynamics' dynDemand)
    if fn(M, "dynDemand") then
        local origD = M.dynDemand
        M.dynDemand = function(b, player, myBase, ...)
            local s = W.store()
            local k = s.kingdom
            if k and not k.off and type(b) == "table" and b.id ~= k.id then
                local lord = byId(k.id)
                if lord and str(b) < str(lord) then
                    if type(b.dir) == "table" then b.dir.tribute = nil end
                    event(b, "They thought about asking the newcomer for tribute, then remembered who the newcomer pays")
                    return nil
                end
            end
            return origD(b, player, myBase, ...)
        end
    end
    W.hooked = true
    return true
end
function W.install()
    pcall(W.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "powerPlays", "Power plays: groups make each other pay, blame each other, and ask you to pick a side" },
            { "powerTributeDays", "Power plays: days between tribute payments", { 3, 7, 14 } },
            { "powerKingdom", "Power plays: the strongest group near you can offer you a place under them" },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. W.VERSION .. ": tribute between groups, the kingdom deal, blame (" .. (W.on() and "on" or "off") .. ")")
end
pcall(W.hook)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(W.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(W.daily, playerOf()) end) end
    if Events.EveryHours then Events.EveryHours.Add(function() pcall(W.hourly, playerOf()) end) end
    if type(Events.ProjectALife_NpcDied) == "table" and fn(Events.ProjectALife_NpcDied, "Add") then
        Events.ProjectALife_NpcDied.Add(function(body, uid, killer) pcall(W.onDied, body, uid, killer) end)
    end
end
return W
