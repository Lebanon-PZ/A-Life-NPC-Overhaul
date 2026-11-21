-- A-Life NPC Overhaul 0.9.4 (Legacy): THE REGION SETTLES. Coalitions, the last war, and the order that hardens after.
-- All between the real groups this mod keeps (NPC bases), with their real strength (nbStrength) and real fights
-- (the 0.7 off-screen assault, nbAttack). Checked once a game day.
--   * COALITIONS: when one group towers over the rest (stronger than everyone else near it put together, half over),
--     the weaker ones near each other band together against it - only if together they'd match it. A coalition
--     breaks when the group it stood against is gone, a member falls or is absorbed, or two members fight.
--   * THE LAST WAR (from regionWarDay): the two strongest sides (a coalition counts as one) close in power go to war.
--     A card: back one (your strength fights with them), broker peace (by how both see you), or stay out. A battle a
--     week; the side that breaks the other's place wins, or after regionWarBattles the stronger one does. The loser
--     is taken in if it's still standing. Then the winners pick one leader for the region (their strongest member's).
--   * THE ORDER HARDENS: no war for regionSettleDays after the last war -> the region settles into one of: KINGDOM
--     (one group holds most of the strength), WARLORD (that group lives by raiding), COALITION (the coalition holds),
--     or FREE TOWNS (nobody does). It shapes daily life: kingdom and warlord make every weaker group near them pay
--     (tribute, ALifePower), a coalition's members stand with each other when attacked, free towns end all tribute.
--     It can break: the ruling side's share falls below regionBreakShare -> unsettled again, and war is possible.
-- Written to the Chronicle and the news. Settings: regionPolitics, regionWarDay, regionWarBattles, regionSettleDays,
-- regionBreakShare.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Region") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeRegion = ALifeRegion or {}
local R = ALifeRegion
local TAG = "[ALifeRegion]"
R.VERSION = ALifeSide.MOD_VERSION
R.DEFAULTS = {
    regionPolitics = true,   -- coalitions, the last war, and the order that settles after
    regionWarDay = 120,      -- the last war can't start before this many days
    regionWarRatio = 85,     -- the weaker side needs this % of the stronger side's strength
    regionWarNear = true,    -- the two sides must be in the same region (regionTiles)
    regionWarTie = -20,      -- bad blood needed: worst tie between them at or below this (-20 rivals, -50 at war)
    regionWarRivalDays = 7,  -- days the rivalry must hold (close in power, near, bad blood) before war can start
    regionWarChance = 10,    -- % chance a day once all of that holds
    regionWarBattles = 4,    -- most battles (a week apart) before the stronger side wins
    regionSettleDays = 14,   -- days without war after the last war before the order hardens
    regionBreakShare = 40,   -- % of the strength the ruling side must keep, or the order breaks
    regionTiles = 2000,      -- how far apart groups count as one region
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function playerOf() -- pre-1.0 MP (P6): on a server, the player being handled, else the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function setting(k) local v = nil; if type(M.settings) == "table" then v = M.settings[k] end; if v == nil then v = R.DEFAULTS[k] end; return v end
local function letter(t) -- pre-1.0 MP: on a server the player handled, else everyone online (ALifeSide.outLetter)
    if ALifeSide.mpServer() then if true then pcall(ALifeSide.outLetter, ALifeSide.cur, t, 220, 180, 150) end; return end
    if type(ALifeLetter) == "function" and playerOf() then pcall(ALifeLetter, playerOf(), t, 220, 180, 150) end
end
local function chron(k, what) if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = k, what = what }) end end
local function news(t) if fn(M, "newsNote") then pcall(M.newsNote, "politics", t) end end
local function event(b, t) if fn(M, "nbEvent") then pcall(M.nbEvent, b, t, "war") end end
local function str(b) local ok, s = pcall(M.nbStrength, b); return ok and tonumber(s) or 0 end
local function byId(id) return fn(M, "nbOf") and M.nbOf(id) or nil end
local function alive(b) return type(b) == "table" and b.status == "active" end
do
    if type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        local have = {}
        for _, x in ipairs(M.fileKeys) do have[x] = true end
        for k, v in pairs(R.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end; if not have[k] then M.fileKeys[#M.fileKeys + 1] = k end end
    end
end
function R.on() return setting("regionPolitics") ~= false end
function R.store()
    local s = fn(M, "bucket") and M.bucket("region") or (R._mem or {})
    if not fn(M, "bucket") then R._mem = s end
    s.coalitions = type(s.coalitions) == "table" and s.coalitions or {}
    return s
end
local function active() return fn(M, "nbActive") and M.nbActive() or {} end
local function myStrength() local L = ALifeKingmaker; return (type(L) == "table" and type(L.last) == "table" and tonumber(L.last.mine)) or 0 end
local function close(a, b) local t = tonumber(setting("regionTiles")) or 2000; return tonumber(a.x) and tonumber(b.x) and (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= t * t end
local function names(ids) local o = {}; for _, id in ipairs(ids) do local b = byId(id); if b then o[#o + 1] = tostring(b.name) end end; return table.concat(o, ", ") end

-- ---------------------------------------------------------------------------------------------- sides
-- a side = one group, or a coalition (its members' strength summed)
function R.coalitionOf(id)
    for _, c in ipairs(R.store().coalitions) do if not c.broken then for _, m in ipairs(c.members) do if m == id then return c end end end end
    return nil
end
function R.sideStrength(side)
    if side.coalition then
        local n = 0
        for _, id in ipairs(side.coalition.members) do local b = byId(id); if alive(b) then n = n + str(b) end end
        return n
    end
    return alive(byId(side.id)) and str(byId(side.id)) or 0
end
function R.sideName(side) return side.coalition and ("the coalition (" .. names(side.coalition.members) .. ")") or tostring((byId(side.id) or {}).name or "?") end
function R.sides()
    local out, seen = {}, {}
    for _, b in ipairs(active()) do
        if not seen[b.id] then
            local c = R.coalitionOf(b.id)
            if c then for _, m in ipairs(c.members) do seen[m] = true end; out[#out + 1] = { coalition = c, id = c.members[1] }
            else seen[b.id] = true; out[#out + 1] = { id = b.id } end
        end
    end
    for _, s in ipairs(out) do s.str = R.sideStrength(s) end
    table.sort(out, function(a, b) return a.str > b.str end)
    return out
end

-- ---------------------------------------------------------------------------------------------- coalitions
function R.formCoalitions(h)
    local list = active()
    local made = 0
    for _, big in ipairs(list) do
        local bs = str(big)
        local others, sum = {}, 0
        for _, b in ipairs(list) do
            if b.id ~= big.id and close(b, big) and not R.coalitionOf(b.id) then others[#others + 1] = b; sum = sum + str(b) end
        end
        if #others >= 2 and bs > sum * 0.5 and sum >= bs * 0.9 and not R.coalitionOf(big.id) then
            local ids = {}
            for _, b in ipairs(others) do ids[#ids + 1] = b.id end
            local c = { id = "c" .. math.floor(h), members = ids, against = big.id, since = h }
            table.insert(R.store().coalitions, c)
            for _, b in ipairs(others) do event(b, "They joined a coalition against " .. tostring(big.name)) end
            news(names(ids) .. " have banded together against " .. tostring(big.name))
            chron("war", names(ids) .. " banded together against " .. tostring(big.name))
            made = made + 1
        end
    end
    return made
end
function R.checkCoalitions()
    local broke = 0
    for _, c in ipairs(R.store().coalitions) do
        if not c.broken then
            local why = nil
            if not alive(byId(c.against)) then why = tostring(c.againstName or "the one they stood against") .. " is gone" end
            for _, m in ipairs(c.members) do if not alive(byId(m)) then why = why or "one of them fell" end end
            if c.infight then why = why or "two of them fought" end
            if why then c.broken = hours(); c.why = why; news("The coalition is over: " .. why); broke = broke + 1 end
        end
    end
    return broke
end
-- two members fighting each other breaks it (power plays' attacks go through nbAttack)
function R.noteFight(attacker, defender)
    if attacker == nil or defender == nil then return end
    local c = R.coalitionOf(attacker.id)
    if c and R.coalitionOf(defender.id) == c then c.infight = true end
end

-- ---------------------------------------------------------------------------------------------- the last war
-- 0.9.5: members of a side (one group, or a coalition's living members)
local function members(side)
    local out = {}
    if side.coalition then for _, id in ipairs(side.coalition.members) do local x = byId(id); if alive(x) then out[#out + 1] = x end end
    else local x = byId(side.id); if alive(x) then out[1] = x end end
    return out
end
-- any member of one side within regionTiles of any member of the other
function R.sidesNear(a, b)
    for _, x in ipairs(members(a)) do for _, y in ipairs(members(b)) do if close(x, y) then return true end end end
    return false
end
-- worst tie between any member of one side and any member of the other (dirTie, -100..100)
function R.sidesTie(a, b)
    local worst = nil
    for _, x in ipairs(members(a)) do
        for _, y in ipairs(members(b)) do
            local t = fn(M, "dirTie") and tonumber(M.dirTie(x, y)) or 0
            local t2 = fn(M, "dirTie") and tonumber(M.dirTie(y, x)) or 0
            t = math.min(t or 0, t2 or 0)
            if worst == nil or t < worst then worst = t end
        end
    end
    return worst or 0
end
-- the two sides that could go to war, or nil and why not (time and roll gates are in startWar)
function R.warPair()
    local sides = R.sides()
    if #sides < 2 then return nil, "fewer than two sides" end
    local a, b = sides[1], sides[2]
    local ratio = (tonumber(setting("regionWarRatio")) or 85) / 100
    if a.str <= 0 or b.str < a.str * ratio then return nil, "not close in power" end
    if setting("regionWarNear") ~= false and not R.sidesNear(a, b) then return nil, "too far apart" end
    if R.sidesTie(a, b) > (tonumber(setting("regionWarTie")) or -20) then return nil, "no bad blood" end
    return a, b
end
local function pairKey(a, b)
    local ka, kb = (a.coalition and a.coalition.id or tostring(a.id)), (b.coalition and b.coalition.id or tostring(b.id))
    if ka > kb then ka, kb = kb, ka end
    return ka .. "|" .. kb
end
function R.startWar(h, player)
    local s = R.store()
    if s.war or s.lastWarDone then return nil end
    if h < (tonumber(setting("regionWarDay")) or 120) * 24 then return nil end
    local a, b = R.warPair()
    if not a then s.rival = nil; return nil end
    -- the rivalry has to hold for regionWarRivalDays (same pair every day), then a daily roll
    local key = pairKey(a, b)
    if type(s.rival) ~= "table" or s.rival.key ~= key then s.rival = { key = key, since = h }; return nil end
    if h - (tonumber(s.rival.since) or h) < (tonumber(setting("regionWarRivalDays")) or 7) * 24 then return nil end
    local roll = 99
    pcall(function() roll = ZombRand(100) end)
    if R.rollFn then roll = R.rollFn() end
    if roll >= (tonumber(setting("regionWarChance")) or 10) then return nil end
    s.rival = nil
    s.war = { a = a, b = b, h = h, battles = 0 }
    news("War: " .. R.sideName(a) .. " against " .. R.sideName(b))
    chron("war", "The last war began: " .. R.sideName(a) .. " against " .. R.sideName(b))
    local function back(side)
        s.war.backed = side == a and "a" or "b"
        local leadB = byId(side.id)
        if type(ALifeKingmaker) == "table" and fn(ALifeKingmaker, "back") and leadB then pcall(ALifeKingmaker.back, player, leadB, byId((side == a and b or a).id)) end
        chron("backed", "we went to war beside " .. R.sideName(side))
    end
    local function peace()
        local okA, _, effA = pcall(M.nbStanding, byId(a.id), player)
        local okB, _, effB = pcall(M.nbStanding, byId(b.id), player)
        local ea = okA and tonumber(effA) or 0
        local eb = okB and tonumber(effB) or 0
        local chance = 30 + (ea + eb) / 4
        local roll = 99
        pcall(function() roll = ZombRand(100) end)
        if R.rollFn then roll = R.rollFn() end
        if roll < chance then R.endWar(nil, "peace") else letter("Neither side would listen. The war goes on.") end
    end
    if ALifeSide.canOutCard() then
        pcall(ALifeSide.outCard, playerOf(), { id = "lastwar", title = "The last war", default = 4,
            text = R.sideName(a) .. " and " .. R.sideName(b) .. " are going to war. Whoever wins will run this place. <LINE> <LINE> Back one, try to broker a peace, or stay out of it?",
            choices = { { label = "Back " .. R.sideName(a), fn = function() back(a) end }, { label = "Back " .. R.sideName(b), fn = function() back(b) end },
                { label = "Broker a peace", fn = peace }, { label = "Stay out of it", fn = function() end } } })
    end
    return s.war
end
-- a battle a week: the stronger side's lead group hits the other's (backed side gets your strength)
function R.battle(h)
    local s = R.store()
    local w = s.war
    if w == nil or h - (tonumber(w.lastH or w.h) or h) < 7 * 24 then return nil end
    w.lastH = h
    w.battles = w.battles + 1
    local sa, sb = R.sideStrength(w.a) + (w.backed == "a" and myStrength() or 0), R.sideStrength(w.b) + (w.backed == "b" and myStrength() or 0)
    if sa <= 0 or sb <= 0 then return R.endWar(sa > 0 and w.a or w.b, "fell") end
    local atk, def, atkS = w.a, w.b, sa
    if sb > sa then atk, def, atkS = w.b, w.a, sb end
    local target = byId(def.id)
    local old = M.nbForceStrength
    M.nbForceStrength = math.floor(atkS)
    local crew = {}
    pcall(function() crew = M.nbScan(true).crews[target.id] or {} end)
    local ok, res = pcall(M.nbAttack, target, fn(M, "nbHavenOf") and M.nbHavenOf(target) or nil, crew, 1, h, "raiders")
    M.nbForceStrength = old
    event(target, "War: " .. R.sideName(atk) .. " hit them (" .. tostring(res) .. ")")
    if ok and (res == "overrun" or not alive(target)) then return R.endWar(atk, "broke them") end
    if w.battles >= (tonumber(setting("regionWarBattles")) or 4) then return R.endWar(sa >= sb and w.a or w.b, "outlasted them") end
    return res
end
function R.endWar(winner, how)
    local s = R.store()
    local w = s.war
    if w == nil then return nil end
    s.war = nil
    s.lastWarDone = hours()
    s.peaceSince = hours()
    if how == "peace" then
        news("The war is over before it really began: a peace was brokered")
        chron("war", "We brokered a peace between " .. R.sideName(w.a) .. " and " .. R.sideName(w.b))
        return "peace"
    end
    local loser = winner == w.a and w.b or w.a
    local lb, wb = byId(loser.id), byId(winner.id)
    if alive(lb) and alive(wb) and fn(M, "nbAbsorb") then pcall(M.nbAbsorb, wb, lb, hours()) end
    -- the winners pick one leader: their strongest member's
    local best, bestS = wb, -1
    for _, id in ipairs(winner.coalition and winner.coalition.members or { winner.id }) do
        local b = byId(id)
        if alive(b) and str(b) > bestS then best, bestS = b, str(b) end
    end
    s.regionLeader = best and best.id or nil
    news(R.sideName(winner) .. " won the war (" .. tostring(how) .. ")" .. (best and (". " .. tostring(best.name) .. " lead the region now") or ""))
    chron("war", "The last war is over: " .. R.sideName(winner) .. " won" .. (best and (", and " .. tostring(best.name) .. " lead now") or ""))
    letter("The war is over. " .. R.sideName(winner) .. " won.")
    return "won"
end

-- ---------------------------------------------------------------------------------------------- the order
function R.settle(h)
    local s = R.store()
    if s.order or s.war or not s.lastWarDone then return nil end
    if h - (tonumber(s.peaceSince) or h) < (tonumber(setting("regionSettleDays")) or 14) * 24 then return nil end
    local sides = R.sides()
    local total = 0
    for _, x in ipairs(sides) do total = total + x.str end
    if total <= 0 then return nil end
    local top = sides[1]
    local share = top.str / total
    local kind
    if top.coalition and share >= 0.5 then kind = "coalition"
    elseif share >= 0.6 then
        local b = byId(top.id)
        kind = (b and type(b.dir) == "table" and b.dir.creed == "raiders") and "warlord" or "kingdom"
    else kind = "free" end
    s.order = { kind = kind, side = top, h = h }
    R.applyOrder(s.order)
    local words = ({ kingdom = "a kingdom under " .. R.sideName(top), warlord = "a warlord's land: " .. R.sideName(top) .. " rule by force",
        coalition = "held by " .. R.sideName(top), free = "free towns, nobody on top" })[kind]
    news("The region has settled: " .. words)
    chron("leader", "The order hardened: " .. words)
    return kind
end
function R.applyOrder(o)
    local W = ALifePower
    if type(W) ~= "table" or not fn(W, "store") then return end
    if o.kind == "free" then W.store().tribute = {} end
end
function R.checkOrder()
    local s = R.store()
    local o = s.order
    if o == nil then return nil end
    local sides = R.sides()
    local total, mine = 0, R.sideStrength(o.side)
    for _, x in ipairs(sides) do total = total + x.str end
    if o.kind ~= "free" and total > 0 and mine / total * 100 < (tonumber(setting("regionBreakShare")) or 40) then
        s.order = nil
        s.lastWarDone = nil -- war is possible again
        news("The order broke: " .. R.sideName(o.side) .. " can't hold the region any more")
        chron("leader", "The order broke. " .. R.sideName(o.side) .. " couldn't hold it")
        return "broken"
    end
    return o.kind
end
-- under a kingdom / warlord, every weaker group near the rulers pays (ALifePower's tribute, ratio ignored)
function R.dailyLife(h)
    local s = R.store()
    local o = s.order
    local W = ALifePower
    if o == nil or (o.kind ~= "kingdom" and o.kind ~= "warlord") or type(W) ~= "table" or not fn(W, "store") then return 0 end
    local ruler = byId(o.side.id)
    if not alive(ruler) then return 0 end
    local n = 0
    for _, b in ipairs(active()) do
        if b.id ~= ruler.id and close(b, ruler) and W.store().tribute[b.id] == nil then
            W.store().tribute[b.id] = { strong = ruler.id, since = h, lastH = h, order = true }
            n = n + 1
        end
    end
    return n
end
-- a coalition's members stand with each other: an attack on one meets some of the others' strength
function R.hook()
    if R.hooked or not fn(M, "nbAttack") then return R.hooked == true end
    local orig = M.nbAttack
    M.nbAttack = function(b, haven, crew, home, h, kind, ...)
        local forced = M.nbForceStrength
        local c = type(b) == "table" and R.coalitionOf(b.id) or nil
        local o = R.store().order
        if forced and c and (o == nil or o.kind == "coalition") then
            local help = 0
            for _, id in ipairs(c.members) do if id ~= b.id then local x = byId(id); if alive(x) then help = help + str(x) * 0.3 end end end
            M.nbForceStrength = math.max(1, math.floor(forced - help))
        end
        local r = { orig(b, haven, crew, home, h, kind, ...) }
        M.nbForceStrength = forced
        return unpack(r)
    end
    -- two coalition members fighting (power plays' blame attacks) breaks it
    local W = ALifePower
    if fn(W, "attack") and not rawget(W, "_regionAttack") then
        local origA = W.attack
        W.attack = function(from, to, h, ...) pcall(R.noteFight, from, to); return origA(from, to, h, ...) end
        rawset(W, "_regionAttack", true)
    end
    R.hooked = true
    return true
end
function R.daily(player)
    if not R.on() then return end
    local h = hours()
    R.checkCoalitions()
    R.formCoalitions(h)
    R.checkOrder()
    R.startWar(h, player)
    R.battle(h)
    R.settle(h)
    R.dailyLife(h)
end
function R.install()
    pcall(R.hook)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "regionPolitics", "Region: coalitions, the last war, and the order that settles after" },
            { "regionWarDay", "Region: the last war can't start before this day", { 60, 120, 240 } },
            { "regionWarRatio", "Region: last war needs the weaker side this close in strength (percent of the stronger)", { 75, 85, 95 } },
            { "regionWarNear", "Region: last war only between sides in the same region" },
            { "regionWarTie", "Region: bad blood the last war needs (-20 rivals, -50 at war)", { -10, -20, -50 } },
            { "regionWarRivalDays", "Region: days the rivalry must hold before the last war", { 3, 7, 14 } },
            { "regionWarChance", "Region: daily chance of the last war once it all holds (percent)", { 5, 10, 25 } },
            { "regionWarBattles", "Region: most battles before the stronger side wins", { 2, 4, 8 } },
            { "regionSettleDays", "Region: days of peace before the order hardens", { 7, 14, 30 } },
            { "regionBreakShare", "Region: share of strength the rulers must keep or the order breaks (%)", { 30, 40, 50 } },
        }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
            if type(M.settingCatOf) == "table" then M.settingCatOf[r[1]] = "Groups, trade and the world" end
        end
    end
    print(TAG .. " ready v" .. R.VERSION .. ": coalitions, the last war, the order (" .. (R.on() and "on" or "off") .. ")")
end
pcall(R.hook)
if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(R.install) end) end
    if Events.EveryDays then Events.EveryDays.Add(function() pcall(R.daily, playerOf()) end) end
end
return R
