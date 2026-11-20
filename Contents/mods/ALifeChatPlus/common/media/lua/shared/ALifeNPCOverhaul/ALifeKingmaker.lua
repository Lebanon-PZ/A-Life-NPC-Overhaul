-- A-Life NPC Overhaul 0.7.13: KINGMAKER (roadmap). Your share of the power around you changes how groups treat you.
-- Once a day your people are weighed against every group within about 5000 tiles, the same way groups weigh each
-- other (how many, how armed, how fed, dug in or not; the Guard counts its helicopters):
--   * KINGMAKER: you aren't the strongest, but the two strongest are close enough that whichever way you lean decides
--     it. Both send word. Back one (they're stronger with you behind them in every fight on paper, and they like you
--     for it; the other side doesn't), or stay out of it. Hurt the side you backed and the backing is over.
--   * THE ONE WHO RULES HERE: your people are the strongest group around by a clear margin. Raider bands weaker than
--     you stop sending tribute demands, and people around here talk about you that way.
-- No numbers anywhere: a letter or a decision when it changes, and how people talk.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "kingmaker" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeKingmaker") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeKingmaker = ALifeKingmaker or {}
local L = ALifeKingmaker
local TAG = "[ALifeKingmaker]"
L.VERSION = "0.9.5"
L.cfg = { reach = 5000, rulerShare = 0.35, kingShare = 0.15, backBoost = 0.25, backRep = 10, breakRep = -5, askGapH = 168,
    scanTiles = 30, maxContainers = 80, wandererMul = 0.6 }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { weighed = 0, kingmaker = 0, ruler = 0, backed = 0, broken = 0, demandsDropped = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end
local function xyOf(o) local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.kingmaker == false)
end
function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end
local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__Kingmaker"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__Kingmaker"] = orig
    L.hooked[hookName] = true
    return true
end
function L.store()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "kingmaker")
    if not ok or type(b) ~= "table" then return nil end
    b.state = b.state or "none"
    b.asked = type(b.asked) == "table" and b.asked or {}
    return b
end

----------------------------------------------------------------------------------------------------------------
-- your strength, weighed like a group's
----------------------------------------------------------------------------------------------------------------
function L.people(player)
    local m, seen, n = M(), {}, 1 -- you
    for _, f in ipairs({ "partyMembers", "cpPeople" }) do
        if fn(m, f) then
            local ok, list = pcall(m[f], player)
            for _, u in ipairs(ok and type(list) == "table" and list or {}) do
                u = tostring(type(u) == "table" and (u.uid or u) or u)
                if not seen[u] then seen[u] = true; n = n + 1 end
            end
        end
    end
    return n
end
-- food and guns in your base's containers (one bounded look a day)
function L.stores(b)
    local food, guns = 0, 0
    pcall(function()
        local cell = getCell()
        local cx, cy = math.floor((b.x1 + b.x2) / 2), math.floor((b.y1 + b.y2) / 2)
        local seen = 0
        local r = L.cfg.scanTiles
        for x = math.max(b.x1, cx - r), math.min(b.x2, cx + r) do
            for y = math.max(b.y1, cy - r), math.min(b.y2, cy + r) do
                local sq = cell:getGridSquare(x, y, 0)
                local objs = sq and sq:getObjects() or nil
                for i = 0, (objs and objs:size() or 0) - 1 do
                    local cont = nil
                    pcall(function() cont = objs:get(i):getContainer() end)
                    if cont ~= nil then
                        seen = seen + 1
                        local items = cont:getItems()
                        for j = 0, items:size() - 1 do
                            local it = items:get(j)
                            local isFood, isGun = false, false
                            pcall(function() isFood = it:getCategory() == "Food" end)
                            if not isFood then pcall(function() isGun = instanceof(it, "HandWeapon") and it:isRanged() end) end
                            if isFood then food = food + 1 elseif isGun then guns = guns + 1 end
                        end
                        if seen >= L.cfg.maxContainers then return end
                    end
                end
            end
        end
    end)
    return food, guns
end
function L.mine(player)
    local m = M()
    local n = L.people(player)
    local base = fn(m, "playerBase") and m.playerBase(player) or nil
    if type(base) ~= "table" or not tonumber(base.x1) then return n * L.cfg.wandererMul end
    local food, guns = L.stores(base)
    local armed = math.min(n, guns) / n
    local fed = math.min(1, (food / n) / 3)
    return n * (1 + 0.6 * armed) * (0.6 + 0.4 * fed) * 1.15 * 0.85
end
function L.center(player)
    local m = M()
    local base = fn(m, "playerBase") and m.playerBase(player) or nil
    if type(base) == "table" and tonumber(base.x1) then return (base.x1 + base.x2) / 2, (base.y1 + base.y2) / 2 end
    return xyOf(player)
end
-- every group within reach, strongest first
function L.rivals(cx, cy)
    local m = M()
    local out = {}
    if not fn(m, "nbActive") or not fn(m, "nbStrength") then return out end
    local r2 = L.cfg.reach * L.cfg.reach
    for _, b in ipairs(m.nbActive() or {}) do
        if type(b) == "table" and b.outpostOf == nil and tonumber(b.x) and (b.x - cx) ^ 2 + (b.y - cy) ^ 2 <= r2 then
            local ok, s = pcall(m.nbStrength, b)
            if ok and tonumber(s) and s > 0 then out[#out + 1] = { b = b, s = s } end
        end
    end
    table.sort(out, function(a, b) return a.s > b.s end)
    return out
end
-- 0.9.5: only groups that have actually had contact with you can court you or call you the strongest.
-- Read-only: never marks a group as knowing you (Market's tpKnows does that, with its own range rule).
function L.knowsYou(b)
    return type(b) == "table" and (b.knowsYou ~= nil or b.radioKnown ~= nil or b.known == "visited")
end
function L.allied(a, b)
    local m = M()
    if not fn(m, "dirTieState") or not fn(m, "dirTie") then return false end
    local ok, st = pcall(function() return m.dirTieState(m.dirTie(a, b)) end)
    return ok and st == "allied"
end
-- "ruler", "kingmaker" or "none", plus the two strongest
function L.weigh(player)
    local cx, cy = L.center(player)
    if cx == nil then return "none" end
    local mine = L.mine(player)
    local list = L.rivals(cx, cy)
    local total = mine
    for _, r in ipairs(list) do total = total + r.s end
    local A, B = list[1], list[2]
    local share = total > 0 and mine / total or 0
    L.last = { mine = mine, share = share, n = #list }
    if A == nil then return "none" end
    local anyKnows = false
    for _, r in ipairs(list) do if L.knowsYou(r.b) then anyKnows = true; break end end
    L.last.known = anyKnows
    -- nobody around here has met you: nobody talks about you, nobody sends word
    if not anyKnows then return "none", A, B end
    if mine > A.s and share >= L.cfg.rulerShare then return "ruler", A, B end
    if B ~= nil and L.knowsYou(A.b) and L.knowsYou(B.b)
        and mine >= (A.s - B.s) and share >= L.cfg.kingShare and not L.allied(A.b, B.b) then return "kingmaker", A, B end
    return "none", A, B
end

----------------------------------------------------------------------------------------------------------------
-- what changes
----------------------------------------------------------------------------------------------------------------
local function letter(player, text, bad) if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, text, nil, nil, nil, bad) end end
local function event(b, text, kind) local m = M(); if fn(m, "nbEvent") then pcall(m.nbEvent, b, text, kind or "politics") end end
function L.back(player, b, other)
    local s = L.store()
    local m = M()
    s.backed, s.backedName, s.backedAt = b.id, b.name, hours()
    L.metrics.backed = L.metrics.backed + 1
    if fn(m, "nbRep") then
        pcall(m.nbRep, b, L.cfg.backRep, "You backed them against " .. tostring(other and other.name or "their rivals"))
        if other then pcall(m.nbRep, other, -L.cfg.backRep, "You backed " .. tostring(b.name) .. " against them") end
    end
    event(b, "The newcomer's people are behind them now", "politics")
    if other then event(other, "The newcomer threw in with " .. tostring(b.name), "politics") end
    if fn(m, "newsNote") then pcall(m.newsNote, "politics", "Word is the newcomer's people are backing " .. tostring(b.name)) end
    letter(player, "You've backed " .. tostring(b.name) .. ". They know it, and so does everyone else.")
    log("backed " .. tostring(b.name))
end
function L.unback(player, why)
    local s = L.store()
    if s.backed == nil then return end
    local name = s.backedName
    s.backed, s.backedName, s.backedAt = nil, nil, nil
    L.metrics.broken = L.metrics.broken + 1
    letter(player, "Your backing of " .. tostring(name) .. " is over: " .. tostring(why) .. ".", true)
    log("backing over: " .. tostring(why))
end
function L.offer(player, A, B)
    local m = M()
    local s = L.store()
    local key = tostring(A.b.id) .. "|" .. tostring(B.b.id)
    local h = hours()
    if h - (tonumber(s.asked[key]) or -1e9) < L.cfg.askGapH then return end
    s.asked[key] = h
    local a, b = A.b, B.b
    local card = { id = "kingmaker:" .. key, title = "Both sides want you",
        text = tostring(a.name) .. " and " .. tostring(b.name) .. " are the two strongest groups around here, and they're close. "
            .. "Whichever way your people lean decides it. Word reaches you from both of them. <LINE> <LINE> "
            .. "Backing one makes them stronger in every fight they pick, and the other side won't forget it.",
        default = 3,
        choices = {
            { label = "Back " .. tostring(a.name), fn = function() L.back(player, a, b) end },
            { label = "Back " .. tostring(b.name), fn = function() L.back(player, b, a) end },
            { label = "Stay out of it", fn = function() log("stayed out of " .. key) end },
        } }
    if ALifeSide.canOutCard() then pcall(ALifeSide.outCard, ALifeSide.campPlayer(), card) else log("no decision cards: offer skipped") end -- pre-1.0 MP: to the camp's player
end
function L.day()
    local p = playerOf()
    local s = L.store()
    if p == nil or s == nil then return end
    L.metrics.weighed = L.metrics.weighed + 1
    local state, A, B = L.weigh(p)
    local was = s.state
    s.state = state
    -- the side you backed is gone or no longer one of the two that matter: the backing lapses quietly
    if s.backed ~= nil then
        local m = M()
        local b = fn(m, "nbOf") and m.nbOf(s.backed) or nil
        if b == nil or b.status ~= "active" then L.unback(p, "they're gone") end
    end
    if state == "kingmaker" then
        if was ~= "kingmaker" then L.metrics.kingmaker = L.metrics.kingmaker + 1 end
        if s.backed == nil then L.offer(p, A, B) end
    elseif state == "ruler" and was ~= "ruler" then
        L.metrics.ruler = L.metrics.ruler + 1
        letter(p, "Your people are the strongest group around here now. Others are starting to notice.")
        local m = M()
        if fn(m, "newsNote") then pcall(m.newsNote, "politics", "People say the newcomer's group runs things around here now") end
        if fn(m, "addDeed") then pcall(m.addDeed, "ruler", "the stranger's people are the strongest group around", 1, {}, nil, nil) end
    elseif was == "ruler" and state ~= "ruler" then
        letter(p, "Your people aren't the strongest group around here any more.", true)
    end
    log("weighed: " .. state .. " (" .. tostring(L.last and L.last.n or 0) .. " groups within reach)")
end

-- the side you back is stronger with you behind them
function L.hookStrength(m)
    return wrap(m, "nbStrength", "nbStrength", function(orig)
        return function(b, ...)
            local v = orig(b, ...)
            if type(b) ~= "table" or not tonumber(v) or not L.enabled() then return v end
            local s = L.store()
            if s and s.backed ~= nil and s.backed == b.id then return v * (1 + L.cfg.backBoost) end
            return v
        end
    end)
end
-- hurt the side you backed: it's over
function L.hookRep(m)
    return wrap(m, "nbRep", "nbRep", function(orig)
        return function(b, d, why, ...)
            local r = orig(b, d, why, ...)
            if L.enabled() and type(b) == "table" and (tonumber(d) or 0) <= L.cfg.breakRep then
                local s = L.store()
                if s and s.backed ~= nil and s.backed == b.id then L.guard("unback", L.unback, playerOf(), "you turned on them") end
            end
            return r
        end
    end)
end
-- raiders weaker than the one who rules here don't dare ask
function L.hookDemand(m)
    return wrap(m, "dynDemand", "dynDemand", function(orig)
        return function(b, player, myBase, ...)
            if L.enabled() and type(b) == "table" then
                local s = L.store()
                if s and s.state == "ruler" and fn(m, "nbStrength") then
                    local ok, theirs = pcall(m.nbStrength, b)
                    local mine = L.last and L.last.mine or 0
                    if ok and tonumber(theirs) and theirs < mine then
                        if type(b.dir) == "table" then b.dir.tribute = nil end
                        L.metrics.demandsDropped = L.metrics.demandsDropped + 1
                        event(b, "They thought about asking the newcomer for tribute, and thought better of it", "tribute")
                        log(tostring(b.name) .. " didn't dare demand tribute")
                        return nil
                    end
                end
            end
            return orig(b, player, myBase, ...)
        end
    end)
end
-- how people around here talk about you
function L.requestExtra(req, player, listener, now)
    if not L.enabled() or type(req.persona) ~= "table" then return end
    local s = L.store()
    if s == nil then return end
    local fact = nil
    if s.state == "ruler" then fact = "Everyone around here knows the stranger's group is the strongest one now; you're careful with them."
    elseif s.state == "kingmaker" then fact = "The two big groups around here are close, and the stranger's people could tip it either way."
        .. (s.backedName and (" They're backing " .. tostring(s.backedName) .. ".") or "") end
    if fact then req.persona.story = tostring(req.persona.story or "") .. " " .. fact end
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "nbStrength", "nbRep", "dynDemand", "extra" }
function L.install()
    local m = M()
    if type(m) ~= "table" then return 0, L.HOOKS end
    if type(m.settings) == "table" and m.settings.kingmaker == nil then m.settings.kingmaker = true end
    L.hookStrength(m); L.hookRep(m); L.hookDemand(m)
    if type(m.requestExtras) == "table" and not L.hooked.extra then
        table.insert(m.requestExtras, function(req, player, listener, now) L.guard("extra", L.requestExtra, req, player, listener, now) end)
        L.hooked.extra = true
    end
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end
L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or ""))
        return true
    end
    return false
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = nowMs()
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryDays ~= nil then
        Events.EveryDays.Add(function() if L.enabled() then L.guard("day", L.day) end end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
