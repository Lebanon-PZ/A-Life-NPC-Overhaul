-- A-Life NPC Overhaul 0.8.10b: PARTY TACTICS (server side). New orders for your own A-Life companions, done with
-- A-Life's own pieces (never moving anyone ourselves):
--   suppress them    A-Life ModuleGunner.order(..., { support = true }): steady fire where the enemy is, to keep
--                    heads down. Needs a semi/auto rifle with rounds (A-Life's own rule: no bolt-action dumps).
--                    Real rounds spent, real noise. While the order runs our fight-brain veto lets "supportFire" on.
--   flank left/right A-Life go_to a spot off to that side of the enemy, then attack_target where the enemy is.
-- Rows go into ALifeCommands (parser, Commands tab, AI list). Only your own people (L.isMine); they can say no
-- (L.chance; flanking is risky: cmdRiskTrust harder). Answer: ALifeCmd "cmdResult" (L.run).
-- Every number is a setting.
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeCommands"
require "ALifeNPCOverhaul/ALifeFieldJobs"
require "ALifeNPCOverhaul/ALifeFightBrain"

ALifePartyTactics = ALifePartyTactics or {}
local T = ALifePartyTactics
local L = ALifeCommands
local B = ALifeFightBrain
local TAG = "[ALifePartyTactics]"
T.VERSION = "0.8.10"
T.jobs = T.jobs or {}
T.metrics = T.metrics or { suppress = 0, suppressNo = 0, flank = 0, flankArrived = 0, flankGaveUp = 0 }

T.DEFAULTS = {
    suppressMs = 12000,     -- suppress: how long they keep the fire up (ms)
    suppressRetryMs = 1500, -- suppress: how often they pick it back up after a magazine / pause (ms)
    flankTiles = 10,        -- flank: how far off to the side of the enemy they swing out (tiles)
    flankBack = 4,          -- flank: how far short of the enemy's line they stop (tiles)
    flankArrive = 3,        -- flank: this close to the spot counts as there (tiles)
    flankGiveUpMs = 45000,  -- flank: they attack from wherever they got to after this long (ms)
}
for k, v in pairs(T.DEFAULTS) do if L.DEFAULTS[k] == nil then L.DEFAULTS[k] = v end end
T.FILE_KEYS = {}
for k in pairs(T.DEFAULTS) do T.FILE_KEYS[#T.FILE_KEYS + 1] = k end
table.sort(T.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(k) return tonumber(L.setting(k)) or tonumber(T.DEFAULTS[k]) or 0 end
local function nowMs() return B.nowMs() end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
local function xy(o) return tonumber(call(o, "getX")), tonumber(call(o, "getY")) end

T.CMDS = {
    { id = "suppress", group = "Fighting", tactic = "suppress", point = "enemy", label = "suppress them",
      words = { "suppress them", "suppress", "suppressing fire", "covering fire", "keep their heads down", "pin them down",
          "lay down fire", "lay down some fire", "put fire on them", "keep them pinned" },
      say = { "Suppress them!", "Keep their heads down!" },
      what = "Anyone with a semi or full auto rifle puts steady fire where the enemy is so they keep their heads down. Real rounds, real noise (the dead hear it)." },
    { id = "flank_left", group = "Fighting", tactic = "flank", side = "left", point = "enemy", risky = true, label = "flank left",
      words = { "flank left", "go left", "flank them left", "hit them from the left", "around the left", "swing left", "left flank" },
      say = { "Flank left!", "Swing round the left!" },
      what = "They swing out to the left of the enemy and hit them from the side. Dangerous." },
    { id = "flank_right", group = "Fighting", tactic = "flank", side = "right", point = "enemy", risky = true, label = "flank right",
      words = { "flank right", "go right", "flank them right", "hit them from the right", "around the right", "swing right", "right flank" },
      say = { "Flank right!", "Swing round the right!" },
      what = "They swing out to the right of the enemy and hit them from the side. Dangerous." },
}
function T.addRows()
    if T.rowsAdded then return end
    for _, c in ipairs(T.CMDS) do
        if L.byId[c.id] == nil then
            local at = #L.CMDS + 1
            for i, row in ipairs(L.CMDS) do if row.hidden then at = i; break end end
            table.insert(L.CMDS, at, c)
            L.byId[c.id] = c
        end
    end
    if type(L.WHY) == "table" then
        L.WHY.no_rifle = "they don't have a rifle that can lay down fire"
        L.WHY.cant_suppress = "they couldn't get a clear line or enough rounds"
        L.WHY.no_enemy = "there's nobody to shoot at"
    end
    T.rowsAdded = true
end
T.addRows()

-- ---------------------------------------------------------------------------------------------------- spots
-- the flank spot: off to `side` of the line you -> enemy, a little short of the enemy
function T.flankPoint(px, py, ex, ey, side, tiles, back)
    local dx, dy = ex - px, ey - py
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.5 then return nil end
    dx, dy = dx / l, dy / l
    local sx, sy
    if side == "left" then sx, sy = dy, -dx else sx, sy = -dy, dx end -- facing north (0,-1): left is west (-1,0)
    return { x = math.floor(ex - dx * back + sx * tiles + 0.5), y = math.floor(ey - dy * back + sy * tiles + 0.5) }
end

local function recShell(uid)
    local rec = B.recordOf(uid)
    local pa = PA()
    local sh = nil
    if pa and pa.Watchdog and type(pa.Watchdog.bindings) == "table" then
        local b = pa.Watchdog.bindings[tostring(uid)]
        sh = type(b) == "table" and b.shell or nil
    end
    if sh == nil and pa and fn(pa.Talk, "shellFor") then
        local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
        if ok then sh = s end
    end
    return rec, sh
end

-- ---------------------------------------------------------------------------------------------------- suppress
function T.suppressOnce(j, now)
    local pa = PA()
    local G = pa and pa.ModuleGunner or nil
    if not fn(G, "order") then return false, "cant_suppress" end
    local rec, sh = recShell(j.uid)
    if rec == nil or sh == nil then return false, "gone" end
    local left = math.max(1000, j.untilMs - now)
    B.partyOrders[j.uid] = { untilMs = j.untilMs } -- lets A-Life's supportFire through our veto for this one
    local ok, wrote = pcall(G.order, rec, sh, { x = j.x, y = j.y, z = j.z or 0 }, now, { support = true, durationMs = left })
    return ok and wrote == true, "cant_suppress"
end
function T.startSuppress(player, uid, c, point)
    local _, sh = recShell(uid)
    if sh == nil then return false, "gone" end
    local data = call(sh, "getModData")
    if type(data) ~= "table" or tostring(data.ProjectALifeWeaponClass or "") ~= "rifle" then
        T.metrics.suppressNo = T.metrics.suppressNo + 1
        return false, "no_rifle"
    end
    local now = nowMs()
    local j = { kind = "suppress", uid = tostring(uid), player = player, x = point.x, y = point.y, z = point.z or 0,
        untilMs = now + num("suppressMs"), nextMs = now + num("suppressRetryMs") }
    local ok, why = T.suppressOnce(j, now)
    if not ok then
        B.partyOrders[j.uid] = nil
        T.metrics.suppressNo = T.metrics.suppressNo + 1
        return false, why
    end
    T.jobs[j.uid] = j
    T.metrics.suppress = T.metrics.suppress + 1
    return true
end

-- ---------------------------------------------------------------------------------------------------- flank
function T.startFlank(player, uid, c, point)
    local px, py = xy(player)
    if px == nil then return false, "gone" end
    local spot = T.flankPoint(px, py, point.x, point.y, c.side, num("flankTiles"), num("flankBack"))
    if spot == nil then return false, "no_enemy" end
    spot.z = point.z or 0
    local ok, why = L.order(player, uid, "go_to", spot)
    if not ok then return false, why end
    T.jobs[tostring(uid)] = { kind = "flank", uid = tostring(uid), player = player, side = c.side, x = spot.x, y = spot.y, z = spot.z,
        ex = point.x, ey = point.y, ez = point.z or 0, untilMs = nowMs() + num("flankGiveUpMs") }
    T.metrics.flank = T.metrics.flank + 1
    return true
end

-- no cmdDone: the client's generic cmdDone answer is siphon's ("siphoned N litres"); a flank ends with their own
-- "In position!" (server side), a suppress just stops, as in life.
function T.done(j, ok, why)
    T.jobs[j.uid] = nil
    if j.kind == "suppress" then B.partyOrders[j.uid] = nil end
    T.last = { uid = j.uid, kind = j.kind, ok = ok == true, why = why }
end

function T.tickOne(j, now)
    if j.kind == "suppress" then
        if now >= j.untilMs then T.done(j, true); return end
        if now >= j.nextMs then
            j.nextMs = now + num("suppressRetryMs")
            local _, sh = recShell(j.uid)
            local data = call(sh, "getModData")
            if type(data) == "table" and now >= (tonumber(data.ProjectALifeSuppressUntilMs) or 0) then T.suppressOnce(j, now) end
        end
        return
    end
    if j.kind == "flank" then
        local _, sh = recShell(j.uid)
        local x, y = xy(sh)
        if x == nil then T.done(j, false, "gone"); return end
        local there = (x - j.x) ^ 2 + (y - j.y) ^ 2 <= num("flankArrive") ^ 2
        if there or now >= j.untilMs then
            L.order(j.player, j.uid, "attack_target", { x = j.ex, y = j.ey, z = j.ez })
            if there then T.metrics.flankArrived = T.metrics.flankArrived + 1 else T.metrics.flankGaveUp = T.metrics.flankGaveUp + 1 end
            local pa = PA()
            if there and pa and fn(pa.Speech, "sayLine") then pcall(pa.Speech.sayLine, sh, "In position!", "directed") end
            T.done(j, true, there and nil or "late")
        end
    end
end
function T.tick()
    if type(isClient) == "function" and isClient() then return end
    local now = nowMs()
    if now < (T.nextMs or 0) then return end
    T.nextMs = now + 500
    local list = {}
    for _, j in pairs(T.jobs) do list[#list + 1] = j end
    for _, j in ipairs(list) do
        local ok, e = pcall(T.tickOne, j, now)
        if not ok then log("job " .. tostring(j.kind) .. " failed: " .. tostring(e)); T.done(j, false, "error") end
    end
end

-- ---------------------------------------------------------------------------------------------------- hook
function T.start(player, uid, c, point)
    if point == nil then return false, "no_enemy" end
    if c.tactic == "suppress" then return T.startSuppress(player, uid, c, point) end
    if c.tactic == "flank" then return T.startFlank(player, uid, c, point) end
    return false, "error"
end
function T.hook()
    if T.hooked then return true end
    if not fn(L, "runOne") then return false end
    local runOne = L.runOne
    L.runOne = function(player, uid, c, point, noun, agreed, ...)
        if type(c) == "table" and c.tactic ~= nil then
            if not L.isMine(uid, player) then L.metrics.notYours = L.metrics.notYours + 1; return false, "not_yours" end
            if agreed ~= true then
                local chance = L.chance(uid, player, c)
                if c.risky then chance = math.max(0, chance - (tonumber(L.setting("cmdRiskTrust")) or 25)) end
                local r = 0
                if type(ZombRand) == "function" then r = ZombRand(100) else r = math.random(0, 99) end
                if r >= chance then return false, "wont" end
            end
            local old = T.jobs[tostring(uid)]
            if old ~= nil then T.jobs[tostring(uid)] = nil; B.partyOrders[tostring(uid)] = nil end
            local ok, done_, why = pcall(T.start, player, uid, c, point)
            if not ok then log("start " .. tostring(c.id) .. " failed: " .. tostring(done_)); return false, "error" end
            return done_, why
        end
        if T.jobs[tostring(uid)] ~= nil then -- a new order replaces the tactic
            local j = T.jobs[tostring(uid)]
            T.jobs[tostring(uid)] = nil
            if j.kind == "suppress" then B.partyOrders[tostring(uid)] = nil end
        end
        return runOne(player, uid, c, point, noun, agreed, ...)
    end
    T.hooked = true
    return true
end
T.hook()

if type(Events) == "table" and Events.OnTick ~= nil then
    Events.OnTick.Add(function()
        local any = false
        for _ in pairs(T.jobs) do any = true; break end
        if not any then return end
        local ok, e = pcall(T.tick)
        if not ok then log("tick failed: " .. tostring(e)) end
    end)
end
print(TAG .. " ready v" .. T.VERSION .. ": " .. #T.CMDS .. " commands (suppress them, flank left, flank right), hook " .. (T.hooked and "on" or "OFF"))

return T
