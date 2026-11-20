-- A-Life NPC Overhaul 0.6.12: THE AIRPORT COMES ALIVE.
--
-- SUPPLY FLIGHTS. The Airport keeps a radio watch on a restricted channel. A call-out on a radio that reaches Louisville
-- gets a curt answer (they never say where they are). Once you've raised them: put what you're offering in your trading
-- post (0.6.8) and call for a supply flight. The helicopter comes (it's loud: the dead hear it for a long way), takes
-- what's in the post and leaves their goods in it, at their price: dear when they're well supplied, fair to friends
-- when they're short. What they give is what they really stripped from Louisville; what you give goes into their real
-- stores. Not there when it lands: they leave and think less of you.
-- ABDUCTIONS. When the Airport is short of food and hands, lone people near Louisville go missing: they're taken to the
-- Airport and work for it (real people, re-homed, eating from the Airport's supplies). The groups around notice, and
-- their traders bring the rumor to you (journal, 0.6.9).
-- Performance: one abduction roll a day; a flight is checked every ten minutes while one is coming.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_AirportLife") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "AirportLife"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("AirportLife") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("airport: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function line(text) if fn(M, "radioLine") then pcall(M.radioLine, nil, text) else print(text) end end
local function event(b, text, kind) if M.nbEvent then pcall(M.nbEvent, b, text, kind or "airport") end end

for k, v in pairs({ airportFlights = true, airportAbductions = true }) do if M.settings[k] == nil then M.settings[k] = v end end
M.alCfg = { prepH = 1.5, flightTilesPerH = 6000, waitH = 1, cooldownH = 72, nearPost = 100, noise = 300,
    value = { food = 1, water = 1, meds = 3, ammo = 3, fuel = 2, tools = 2, materials = 1, other = 0.5 },
    want = { low = { food = 1.6, meds = 1.3 }, desperate = { food = 2.0, meds = 1.5, ammo = 1.2 } },
    abductReach = 600, abductChance = { low = 0.12, desperate = 0.30 }, abductPlayerFar = 300, rumorTiles = 900, rumorDays = 14 }
M.alStats = { calls = 0, flights = 0, missed = 0, given = 0, taken = 0, abducted = 0 }

local function S() return fn(M, "apStore") and M.apStore() or {} end
local function ap() return fn(M, "apBase") and M.apBase() or nil end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
-- pre-1.0 MP (P5): a flight is called by one player (f.pk on a server); "you at the drop point" = that player, else
-- any online player there. Abductions only far from EVERY player. The radio menu's call runs on the server as you.
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function pxy(p) local x, y = nil, nil; pcall(function() x, y = p:getX(), p:getY() end); return x, y end
local function kindOf(t) return fn(M, "nbKindOf") and M.nbKindOf(t) or "other" end

----------------------------------------------------------------------------------------------------------------
-- the trading post container (your side of the deal)
----------------------------------------------------------------------------------------------------------------
local function postContainer()
    local post = fn(M, "tpStore") and M.tpStore().post or nil
    if post == nil then return nil, nil end
    local box = nil
    pcall(function()
        local sq = getCell():getGridSquare(post.x, post.y, post.z)
        local objs = sq and sq:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local c = objs:get(i):getContainer()
            if c then box = c; return end
        end
    end)
    return box, post
end

-- what a load is worth to them right now
function M.alWorth(t, mood)
    local k = kindOf(t)
    local v = M.alCfg.value[k] or M.alCfg.value.other
    if type(ALifeWorth) == "table" and M.settings.itemWorth ~= false then v = (ALifeWorth.of(t)) end -- 0.6.14: what it's really worth
    local w = M.alCfg.want[mood or ""]
    return v * ((w and w[k]) or 1), k
end

-- the deal: take everything in the post, pay in kind from their real stores
function M.alTrade(box)
    local s = S()
    local mood = fn(M, "apMood") and M.apMood() or "steady"
    local terms = fn(M, "apTerms") and M.apTerms(playerOf()) or { price = 1.3 }
    local taken, worth = {}, 0
    pcall(function()
        local items = box:getItems()
        for i = items:size() - 1, 0, -1 do
            local it = items:get(i)
            local t = it:getFullType()
            local v, k = M.alWorth(t, mood)
            worth = worth + v
            taken[#taken + 1] = { t = t, k = k }
            box:DoRemoveItem(it)
        end
    end)
    s.items = type(s.items) == "table" and s.items or {}
    -- their side first, from what they already had (never your own goods handed back), worth / price
    local budget = worth / math.max(0.5, tonumber(terms.price) or 1.3)
    local given = {}
    local i = #s.items
    while budget > 0.25 and i >= 1 do
        local t = s.items[i]
        local v, k = M.alWorth(t, nil)
        if v <= budget + 0.25 then
            table.remove(s.items, i)
            given[#given + 1] = t
            budget = budget - v
        end
        i = i - 1
    end
    for _, t in ipairs(given) do pcall(function() box:AddItem(t) end) end
    -- then yours go into their stores: food feeds them, the rest goes on the shelf
    for _, x in ipairs(taken) do
        if x.k == "food" or x.k == "water" then s.stock = (tonumber(s.stock) or 0) + ((M.nbCfg and M.nbCfg.foodPerItem) or 0.25)
        else s.items[#s.items + 1] = x.t end
    end
    M.alStats.taken = M.alStats.taken + #taken
    M.alStats.given = M.alStats.given + #given
    return #taken, #given, mood
end

----------------------------------------------------------------------------------------------------------------
-- the radio: raising them, calling a flight
----------------------------------------------------------------------------------------------------------------
function M.alInRange(player, range)
    local b = ap()
    local px, py = pxy(player)
    return b ~= nil and b.status == "active" and px ~= nil and d2(b.x, b.y, px, py) <= range * range
end
function M.alCallFlight(player)
    local s = S()
    local h = hours()
    local range, why = fn(M, "rcRadio") and M.rcRadio(player)
    if range == nil then line("[Radio] " .. tostring(why or "You need a radio.")); return false end
    if not M.alInRange(player, range) then line("[Radio] *kssht*... the restricted channel is just static from here."); return false end
    M.alStats.calls = M.alStats.calls + 1
    if s.flight then line("[Radio] " .. (M.apName or "Louisville National Guard") .. ": Already inbound. Stay off the channel."); return false end
    if (tonumber(s.flightH) or -1e9) > h - M.alCfg.cooldownH then line("[Radio] " .. (M.apName or "Louisville National Guard") .. ": Negative. Fuel's rationed. Try again in a few days."); return false end
    local box, post = postContainer()
    if post == nil then line("[Radio] " .. (M.apName or "Louisville National Guard") .. ": We don't land without a drop point. Mark one."); return false end
    local terms = fn(M, "apTerms") and M.apTerms(player) or { willing = 0.6 }
    if (ALifeRoll01 and ALifeRoll01("apflight" .. math.floor(h)) or 0.5) > (tonumber(terms.willing) or 0.6) then
        line("[Radio] " .. (M.apName or "Louisville National Guard") .. ": Not interested. Out.")
        s.rep = (tonumber(s.rep) or 0) - 1
        return false
    end
    local b = ap()
    local fly = math.sqrt(d2(b.x, b.y, post.x, post.y)) / M.alCfg.flightTilesPerH
    s.flight = { at = h + M.alCfg.prepH + fly, x = post.x, y = post.y, z = post.z, pk = mpServer() and player ~= nil and ALifeSide.keyOf(player) or nil }
    s.flightH = h
    line("[Radio] " .. (M.apName or "Louisville National Guard") .. ": Copy. Have the goods at your drop point. Wheels down in about " .. math.max(1, math.floor(M.alCfg.prepH + fly + 0.5)) .. " hours. Be there.")
    return true
end
-- every ten minutes while a flight is coming
function M.alTick()
    local s = S()
    local f = s.flight
    if type(f) ~= "table" then return end
    local h = hours()
    if h < (tonumber(f.at) or 0) then return end
    local player = playerOf()
    if mpServer() then player = (f.pk and ALifeSide.byKey(f.pk)) or ALifeSide.nearest(f.x, f.y) end
    local px, py = pxy(player)
    if mpServer() and player ~= nil and px ~= nil and d2(px, py, f.x, f.y) > M.alCfg.nearPost ^ 2 then
        local np = ALifeSide.nearest(f.x, f.y, M.alCfg.nearPost) -- whoever is at the drop point
        if np ~= nil then player = np; px, py = pxy(np) end
    end
    local box = postContainer()
    local here = px ~= nil and d2(px, py, f.x, f.y) <= M.alCfg.nearPost ^ 2 and box ~= nil
    if not here then
        if h - f.at < M.alCfg.waitH then return end
        s.flight = nil
        s.rep = (tonumber(s.rep) or 0) - 3
        M.alStats.missed = M.alStats.missed + 1
        local b = ap(); if b then event(b, "A supply flight went out to you and nobody was there", "airport") end
        return
    end
    s.flight = nil
    M.alStats.flights = M.alStats.flights + 1
    -- it's loud: every dead thing for a long way hears it
    pcall(function() addSound(player, math.floor(f.x), math.floor(f.y), 0, M.alCfg.noise, M.alCfg.noise) end)
    pcall(function() getSoundManager():PlayWorldSound("Helicopter", getCell():getGridSquare(f.x, f.y, 0), 0, M.alCfg.noise, 1.0, false) end)
    local got, gave, mood = M.alTrade(box)
    s.rep = (tonumber(s.rep) or 0) + (got > 0 and 2 or 0)
    line("[Radio] " .. (M.apName or "Louisville National Guard") .. ": Rotors overhead... a crate lowered, yours hauled up. They took " .. got .. " things and left " .. gave .. ".")
    local b = ap(); if b then event(b, "Flew a supply run: took " .. got .. ", left " .. gave, "airport") end
    log("flight: took " .. got .. ", gave " .. gave .. " (" .. tostring(mood) .. ")")
end

----------------------------------------------------------------------------------------------------------------
-- abductions
----------------------------------------------------------------------------------------------------------------
function M.alAbductDaily(h)
    if M.settings.airportAbductions == false then return nil end
    local b = ap()
    if b == nil or b.status ~= "active" then return nil end
    local s = S()
    local mood = fn(M, "apMood") and M.apMood() or "steady"
    local chance = M.alCfg.abductChance[mood]
    if chance == nil or (fn(M, "apCount") and M.apCount() + #(s.abducted or {}) >= ((M.apCfg and M.apCfg.cap) or 50)) then return nil end
    local day = math.floor(h / 24)
    if s.abductDay == day then return nil end
    s.abductDay = day
    if (ALifeRoll01 and ALifeRoll01("abduct" .. day) or 1) >= chance then return nil end
    local scan = M.nbScan(true)
    local reach = (tonumber(s.reach) or 0) + M.alCfg.abductReach
    local px, py = pxy(playerOf())
    local best, bd = nil, reach * reach
    for _, r in ipairs(scan.loners or {}) do
        local wp = type(r.worldPosition) == "table" and r.worldPosition or nil
        if mpServer() then px, py = nil, nil; if wp then px, py = pxy(ALifeSide.nearest(wp.x, wp.y)) end end -- MP: far from every player
        if wp and r.lifecycle == "dormant" and not r.virtual and (px == nil or d2(wp.x, wp.y, px, py) > M.alCfg.abductPlayerFar ^ 2) then
            local dd = d2(wp.x, wp.y, b.x, b.y)
            if dd < bd then best, bd = r, dd end
        end
    end
    if best == nil then return nil end
    local reg = PA().ActorRegistry
    local haven = M.nbHavenOf(b)
    local depot = haven and type(haven.depot) == "table" and haven.depot or { x = b.x, y = b.y, z = 0 }
    local wp = best.worldPosition
    local ok = pcall(reg.update, best.uid, best.revision, function(e)
        e.memory = type(e.memory) == "table" and e.memory or {}
        e.memory.havenId = b.id
        e.memory.supplyDepot = { x = depot.x, y = depot.y, z = depot.z or 0 }
        e.memory.alcpAbducted = { h = h, from = { x = wp.x, y = wp.y } }
        e.worldPosition = { x = depot.x + ((ALifeRoll01 and ALifeRoll01(best.uid) or 0.5) * 3) - 1, y = depot.y, z = depot.z or 0 }
    end)
    if not ok then return nil end
    s.abducted = type(s.abducted) == "table" and s.abducted or {}
    s.abducted[#s.abducted + 1] = tostring(best.uid)
    s.workers = (tonumber(s.workers) or 0) + 1
    M.alStats.abducted = M.alStats.abducted + 1
    event(b, "Brought in a new worker", "airport")
    -- the groups around notice someone's gone
    for _, o in ipairs(M.nbActive()) do
        if o.id ~= b.id and tonumber(o.x) and d2(o.x, o.y, wp.x, wp.y) <= M.alCfg.rumorTiles ^ 2 then
            o.abductRumorH = h
            event(o, "Someone from around here went missing. Tracks lead toward Louisville", "rumor")
        end
    end
    log("took a loner (" .. tostring(best.uid) .. ") from " .. math.floor(wp.x) .. "," .. math.floor(wp.y))
    return best.uid
end
-- 0.9.5: the Airport breaks up -> the people it took are free. Undo what the abduction wrote on their A-Life record
-- (haven, supply depot) so they're loners again, where they stand (no teleport home: they walk from there).
function M.alReleaseAbducted(why)
    local s = S()
    local reg = PA().ActorRegistry
    local b = ap()
    local freed = 0
    if not fn(reg, "read") or not fn(reg, "update") then return 0 end
    local h = 0
    pcall(function() h = getGameTime():getWorldAgeHours() end)
    for _, uid in ipairs(s.abducted or {}) do
        local r = reg.read(uid)
        if r and r.lifecycle ~= "dead" then
            -- (A-Life Registry.update returns nil, why on a conflict: it doesn't throw)
            local ok, res = pcall(reg.update, uid, r.revision, function(e)
                e.memory = type(e.memory) == "table" and e.memory or {}
                if b == nil or e.memory.havenId == nil or tostring(e.memory.havenId) == tostring(b.id) then
                    e.memory.havenId = nil
                    e.memory.supplyDepot = nil
                end
                local ab = type(e.memory.alcpAbducted) == "table" and e.memory.alcpAbducted or {}
                ab.freed, ab.why = h, tostring(why or "freed")
                e.memory.alcpAbducted = ab
            end)
            if ok and res ~= nil then freed = freed + 1 end
        end
    end
    s.abducted = {}
    s.workers = 0
    if freed > 0 then log("released " .. freed .. " abducted (" .. tostring(why) .. ")") end
    return freed
end
-- abducted people eat from the Airport's supplies too
function M.alAbductedAlive()
    local n, reg = 0, PA().ActorRegistry
    for _, uid in ipairs(S().abducted or {}) do
        local r = fn(reg, "read") and reg.read(uid) or nil
        if r and r.lifecycle ~= "dead" then n = n + 1 end
    end
    return n
end
function M.alPerf()
    local s = M.alStats
    return "airport life: calls " .. s.calls .. ", flights " .. s.flights .. " (missed " .. s.missed .. "), took " .. s.taken .. ", gave " .. s.given .. ", abducted " .. s.abducted
end

----------------------------------------------------------------------------------------------------------------
-- hooks (wrap, never replace; marked)
----------------------------------------------------------------------------------------------------------------
M._alcpHooks = M._alcpHooks or {}
local broken = false
local function guard(where, f, ...)
    if broken then return nil end
    local ok, a = pcall(f, ...)
    if not ok then broken = true; print("[ALifeAirportLife] " .. where .. " failed, off for this session: " .. tostring(a)) end
    return ok and a or nil
end
-- the radio: the Airport answers a call-out on its restricted channel; supply flights from the Radio menu
-- (RadioCalls loads after this file: hooked once the game starts)
function M.alInstallRadio()
    if M._alcpHooks.airportRadio or not fn(M, "rcCallOut") or not fn(M, "rcFill") then return false end
    M._alcpHooks.airportRadio = true
    if fn(M, "rcCallOut") then
        local call = M.rcCallOut
        M.rcCallOut = function(player, ...)
            local n = call(player, ...)
            guard("callout", function()
                local range = M.rcRadio(player)
                if range and M.alInRange(player, range) and M.settings.airportFlights ~= false then
                    local s = S()
                    if not s.radioKnown then s.radioKnown = hours() end
                    line("[Radio] (a flat voice, a restricted channel) This frequency is monitored. State your business or get off it.")
                    local b = ap()
                    if b and fn(M, "jnLearn") then M.jnLearn(b, "radio", {}, "A restricted military-sounding channel answered. They wouldn't say where they are.") end
                end
            end)
            return n
        end
    end
    if fn(M, "rcFill") then
        local fill = M.rcFill
        M.rcFill = function(playerNum, context, worldobjects, test, ...)
            local r = fill(playerNum, context, worldobjects, test, ...)
            local known = S().radioKnown
            if type(ALifeSide) == "table" and ALifeSide.mpClient() and type(ALifeRemote) == "table" then -- MP: the server's word
                local v = ALifeRemote.get("rcBases") or {}
                known = v.airport == true
            end
            if test ~= true and M.settings.airportFlights ~= false and known and type(context) == "table" then
                pcall(function()
                    local player = getSpecificPlayer(playerNum or 0)
                    for _, opt in ipairs(context.options or {}) do
                        if opt.name == ALifeTr("IGUI_ALCP_Radio", "Radio") and opt.subOption then
                            local sub = context:getSubMenu(opt.subOption)
                            if sub then sub:addOption(ALifeTr("IGUI_ALCP_AirportFlight", "Restricted channel: request a supply flight"), player, function(p) M.alCallFlight(p) end) end
                        end
                    end
                end)
            end
            return r
        end
    end
    return true
end
function M.alInstall()
    if M._alcpHooks.airportLife or not fn(M, "apDay") then return false end
    M._alcpHooks.airportLife = true
    -- a day at the Airport: the abducted eat too; maybe someone else goes missing
    local day = M.apDay
    M.apDay = function(s, n, ...)
        local extra = guard("count", M.alAbductedAlive) or 0
        local r = day(s, (tonumber(n) or 0) + extra, ...)
        guard("abduct", M.alAbductDaily, hours())
        return r
    end
    M.alInstallRadio()
    -- rumors reach you through traders
    M.cvArriveHooks = M.cvArriveHooks or {}
    table.insert(M.cvArriveHooks, function(visit, b, h)
        guard("rumor", function()
            if b.abductRumorH and h - b.abductRumorH < M.alCfg.rumorDays * 24 and fn(M, "jnLearn") then
                local a = ap()
                if a then M.jnLearn(a, "rumor", { status = "people go missing around there" }, tostring(b.name) .. " says people keep going missing, and the tracks lead toward Louisville", b.name) end
            end
        end)
    end)
    if type(Events) == "table" and Events.EveryTenMinutes then ALifeHealth.add(Events.EveryTenMinutes, "ALifeTalk_AirportLife", function() guard("flight", M.alTick) end) end
    print("[ALifeAirportLife] loaded v0.6.12 (supply flights on the restricted channel; abductions near Louisville)")
    return true
end
M.alInstall()
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then ALifeRemote.expose("alCallFlight", 0, 1) end
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() M.alInstall(); pcall(M.alInstallRadio) end) end
