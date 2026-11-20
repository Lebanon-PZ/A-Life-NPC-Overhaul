-- A-Life NPC Overhaul pre-1.0: ALLOWED AREAS (docs/PLAN-RIM.md #6). Mark an "inside" zone (Camp > Areas, up to areaMax
-- rectangles: the house, the yard inside the wall...). Then per person: Anywhere / Inside at night / Inside always, and
-- one switch "Everyone in at night".
--   * Outside when their rule says inside: they walk back in (a camp job, before any other work).
--   * Camp work outside the zone is skipped while the rule holds. The night watch, patrols and urgent jobs (quarantine,
--     sick bay, a breakdown) are not stopped: a guard on duty walks where the duty is.
-- People away (runs, your party, following you) aren't at camp, so the rule doesn't touch them.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeAreas") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeAreas = ALifeAreas or {}
local A = ALifeAreas
local TAG = "[ALifeAreas]"
A.VERSION = "pre-1.0"
A.DEFAULTS = {
    areas = true,         -- inside zone + who has to stay in it
    areaMax = 4,          -- most rectangles in the inside zone
    areaSide = 80,        -- longest side of one rectangle (tiles)
    areaNightFrom = 21,   -- "night" for the rule starts at this hour
    areaNightTo = 6,      -- and ends at this hour
}
K.reg(A.DEFAULTS, {
    { "areas", "Camp: an inside zone, and who has to stay in it (at night / always)" },
    { "areaMax", "Areas: most rectangles in the inside zone", { 1, 2, 4, 6, 8 } },
    { "areaNightFrom", "Areas: 'night' starts at", { 18, 19, 20, 21, 22, 23 } },
    { "areaNightTo", "Areas: 'night' ends at", { 5, 6, 7, 8 } },
}, "Your camp and base")
A.RULES = { any = "Anywhere", night = "Inside at night", always = "Inside always" }
A.stats = { walkedBack = 0, skipped = 0 }
local function set(k) return K.set(A.DEFAULTS, k) end
local function num(k) return K.num(A.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function A.on() return set("areas") ~= false end
function A.store()
    local s = K.bucket("rimAreas")
    s.rects = type(s.rects) == "table" and s.rects or {}
    s.rule = type(s.rule) == "table" and s.rule or {}
    return s
end
function A.inside(x, y)
    if x == nil then return false end
    for _, r in ipairs(A.store().rects) do if x >= r.x1 and x <= r.x2 + 0.99 and y >= r.y1 and y <= r.y2 + 0.99 then return true end end
    return false
end
function A.isNight()
    local h = K.hourOfDay()
    local a, b = num("areaNightFrom"), num("areaNightTo")
    if a > b then return h >= a or h < b end
    return h >= a and h < b
end
function A.ruleOf(uid)
    local s = A.store()
    local r = s.rule[tostring(uid)]
    if A.RULES[r or ""] and r ~= "any" then return r end
    if r == "any" then return "any" end
    if s.nightAll then return "night" end
    return "any"
end
-- does the rule hold for them right now?
function A.holds(uid)
    if not A.on() or #A.store().rects == 0 then return false end
    local r = A.ruleOf(uid)
    return r == "always" or (r == "night" and A.isNight())
end
-- the nearest square inside the zone (one tile in from the edge)
function A.nearestIn(x, y)
    local best, bd = nil, nil
    for _, r in ipairs(A.store().rects) do
        local tx = math.max(r.x1 + (r.x2 > r.x1 and 1 or 0), math.min(r.x2 - (r.x2 > r.x1 and 1 or 0), math.floor(x)))
        local ty = math.max(r.y1 + (r.y2 > r.y1 and 1 or 0), math.min(r.y2 - (r.y2 > r.y1 and 1 or 0), math.floor(y)))
        local dd = K.d2(tx, ty, x, y)
        if bd == nil or dd < bd then best, bd = { x = tx, y = ty, z = r.z or 0 }, dd end
    end
    return best
end
A.JOB = {
    kind = "rim_inside", order = -1,
    pick = function(uid, shell, player, b, now)
        if not A.holds(uid) then return nil end
        local M = K.M()
        if K.fn(M, "cpWatcher") and M.cpWatcher(player) == tostring(uid) then return nil end
        local x, y = K.pos(shell)
        if x == nil or A.inside(x, y) then return nil end
        local spot = A.nearestIn(x, y)
        if spot == nil then return nil end
        return { key = "inside:" .. tostring(uid), spot = spot }
    end,
    spot = function(j) return j.spot end,
    ms = function(j) return 500 end,
    run = function(j, uid, shell, player) A.stats.walkedBack = A.stats.walkedBack + 1; return "done" end,
}
-- where a camp job is (nil when it has no fixed place)
function A.jobSpot(j)
    local M = K.M()
    if type(j) ~= "table" then return nil end
    local def = M.cpKinds and M.cpKinds[j.kind] or nil
    if def and type(def.spot) == "function" then local ok, s = pcall(def.spot, j); if ok then return s end; return nil end
    if j.kind == "haul" or j.kind == "harvest" then return j.from end
    if j.kind == "water" then return M.cpFarmData and M.cpFarmData().water or nil end
    return j.spot
end
-- urgent or on duty: never stopped by the zone
function A.exempt(j)
    local M = K.M()
    if j.kind == "watch" or j.kind == "patrol" then return true end
    if string.sub(tostring(j.kind), 1, 4) == "rim_" then return true end
    local def = M.cpKinds and M.cpKinds[j.kind] or nil
    return def ~= nil and (def.order or 0) < 0
end
-- drop a job picked for them (its claim and its own release), as if nothing was picked
function A.drop(j, uid, shell)
    local M = K.M()
    if j.key and M.cpClaims and M.cpClaims[j.key] == tostring(uid) then M.cpClaims[j.key] = nil end
    local def = M.cpKinds and M.cpKinds[j.kind] or nil
    if def and type(def.release) == "function" then pcall(def.release, j, tostring(uid), shell) end
end
function A.hook()
    local M = K.M()
    if M == nil then return 0 end
    return K.wrap(M, "cpPick", "areas:cpPick", function(orig)
        return function(uid, shell, player, now, ...)
            local j = orig(uid, shell, player, now, ...)
            if j == nil or not A.holds(uid) or A.exempt(j) then return j end
            local sp = A.jobSpot(j)
            if sp ~= nil and not A.inside(sp.x, sp.y) then
                A.drop(j, uid, shell)
                A.stats.skipped = A.stats.skipped + 1
                return nil
            end
            return j
        end
    end) and 1 or 0
end

-- menu: Camp > Areas
function A.menu(child, off, player, x, y, z, inRange, why)
    if not A.on() then return end
    local s = A.store()
    local m = child("Areas")
    if A.sel == nil then
        local o = m:addOption("Inside zone: first corner here", nil, function()
            A.sel = { x = x, y = y, z = z }
            K.letter("First corner set. Right-click the opposite corner > Camp > Areas.", 190, 200, 230)
        end)
        if #s.rects >= num("areaMax") then off(o, "The inside zone already has " .. #s.rects .. " parts (most " .. num("areaMax") .. ").")
        elseif not inRange then off(o, why or "Too far from your base.") end
    else
        local sel = A.sel
        local o = m:addOption("Inside zone: opposite corner here", nil, function()
            A.sel = nil
            K.run("arRect", player, sel.x, sel.y, x, y, sel.z)
        end)
        if math.abs(x - sel.x) + 1 > num("areaSide") or math.abs(y - sel.y) + 1 > num("areaSide") then off(o, "Too big. Keep each side under " .. num("areaSide") .. " tiles.") end
        m:addOption("Cancel", nil, function() A.sel = nil end)
    end
    for i, r in ipairs(s.rects) do
        if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
            m:addOption("Remove this part of the inside zone", nil, function() K.run("arRectDel", player, x, y) end)
            break
        end
    end
    m:addOption(s.nightAll and "Everyone in at night: on (turn off)" or "Everyone in at night: off (turn on)", nil, function() K.run("arNight", player, not s.nightAll) end)
    local people = K.people(player)
    if #people > 0 then
        local pm = ISContextMenu:getNew(m)
        m:addSubMenu(m:addOption("Who stays inside"), pm)
        for _, uid in ipairs(people) do
            local cur = s.rule[uid]
            local im = ISContextMenu:getNew(pm)
            pm:addSubMenu(pm:addOption(K.first(uid) .. " (" .. A.RULES[A.ruleOf(uid)] .. ")"), im)
            for _, r in ipairs({ "any", "night", "always" }) do
                local o = im:addOption(A.RULES[r], nil, function() K.run("arRule", player, uid, r) end)
                if cur == r then off(o, "Already this.") end
            end
            if cur ~= nil then im:addOption("Camp default", nil, function() K.run("arRule", player, uid, "default") end) end
        end
    end
end
-- pre-1.0 MP (P4): this menu's writes (SP directly; MP on the server as the sender, values checked)
K.act("arRect", function(player, x1, y1, x2, y2, z)
    local s = A.store()
    x1, y1, x2, y2, z = K.cnum(x1), K.cnum(y1), K.cnum(x2), K.cnum(y2), K.cnum(z) or 0
    if x1 == nil or y1 == nil or x2 == nil or y2 == nil or #s.rects >= num("areaMax") then return false end
    if math.abs(x2 - x1) + 1 > num("areaSide") or math.abs(y2 - y1) + 1 > num("areaSide") then return false end
    s.rects[#s.rects + 1] = { x1 = math.min(x1, x2), y1 = math.min(y1, y2), x2 = math.max(x1, x2), y2 = math.max(y1, y2), z = z }
    K.letter("Inside zone set. Camp > Areas sets who stays in it.", 190, 200, 230)
end)
K.act("arRectDel", function(player, x, y)
    local s = A.store()
    x, y = K.cnum(x), K.cnum(y)
    if x == nil or y == nil then return false end
    for i, r in ipairs(s.rects) do if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then table.remove(s.rects, i); return true end end
    return false
end)
K.act("arNight", function(player, want)
    local s = A.store()
    s.nightAll = (want == true) or nil
    K.letter(s.nightAll and "Everyone comes inside at night." or "People go where they like at night again.", 190, 200, 230)
end)
K.act("arRule", function(player, uid, r)
    r = tostring(r)
    if uid == nil or (r ~= "default" and A.RULES[r] == nil) then return false end
    A.store().rule[tostring(uid)] = r ~= "default" and r or nil
end)
function A.marks()
    local out = {}
    if A.sel then out[#out + 1] = { A.sel, 0.4, 0.4, 1 } end
    return out
end
function A.hookRender()
    local M = K.M()
    return K.wrap(M, "cpRender", "areas:cpRender", function(orig)
        return function(...)
            local r = orig(...)
            if M.cpShow and type(addAreaHighlight) == "function" then
                for _, a in ipairs(A.store().rects) do addAreaHighlight(a.x1, a.y1, a.x2 + 1, a.y2 + 1, a.z or 0, 0.4, 0.4, 1, 0.18) end
            end
            return r
        end
    end) and 1 or 0
end
function A.install()
    local n = A.hook() + A.hookRender()
    K.addJob(A.JOB)
    local M = K.M()
    if not A._menu then K.addMenu(function(...) return A.menu(...) end); A._menu = true end
    if not A._marks and M then M.cpMarks = M.cpMarks or {}; table.insert(M.cpMarks, A.marks); A._marks = true end
    return n
end
pcall(A.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(A.install)
        log("ready v" .. A.VERSION .. ": allowed areas " .. (A.on() and "on" or "off") .. ", " .. #A.store().rects .. " zone parts (" .. tostring(ok and n or 0) .. "/2 camp hooks)")
    end)
end
return A
