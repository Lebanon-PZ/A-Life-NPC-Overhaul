-- ALifeTalk_CampAnimals.lua (0.5.9): the shepherd. Someone looks after your B42 animals.
-- Give someone the Shepherd role, then right-click your hutches and troughs > Camp > Animals > Tend this.
-- * Eggs: they empty the nest boxes and carry the eggs to your fresh-food drop point.
-- * Water: a trough under half gets topped up from the water spot you marked for the farm (real water, out of
--   the barrel: the same fluid transfer vanilla uses to fill a trough from a bucket).
-- * Feed: an empty trough gets animal feed from the feed store you mark (Camp > Animals > Animal feed here).
-- Not done: milking and shearing (vanilla does those as long hands-on actions with a bucket/shears).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampAnimals") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPAnimals = true
M.anCfg = { eggAgainH = 2, troughAt = 0.5, carryL = 20, feedPerTrip = 3, workMs = 3000, maxMarks = 8 }
M.anStats = { eggs = 0, watered = 0, fed = 0 }

-- the role
table.insert(M.cpRoles, { id = "shepherd", label = "Shepherd" })
M.cpRoleLabel.shepherd = "Shepherd"
M.cpRoleBg.shepherd = { farmer = 0.9, vet_animal = 1, hunter = 0.5, granny = 0.6, grandpa = 0.6, homemaker = 0.4, prepper = 0.4 }
M.cpRoleLens.shepherd = { kind = 0.5, calm = 0.4, volatile = -0.3, mean = -0.3 }
table.insert(M.cpIntents, { id = "CAMP_ROLE_SHEPHERD", kind = "role_shepherd", patterns = "you're our shepherd|be our shepherd|look after the animals|take care of the animals|tend the animals|you're on animal duty" })
-- role lines (Camp's table is local, so the role-change lines come from here)
local baseSetRole = M.cpSetRole
local LINES = { good = "Animals I understand. Better than people, most days.", ok = "I'll feed them and pick up the eggs.", poor = "Chickens scare me a little. But fine.", refuse = "I'm not shoveling animal crap. No." }
function M.cpSetRole(uid, role, player)
    local line, took = baseSetRole(uid, role, player)
    if role ~= "shepherd" then return line, took end
    if took == false then return LINES.refuse, false end
    local f = M.cpFit(uid, "shepherd")
    return (f >= 1.2 and LINES.good) or (f >= 0.8 and LINES.ok) or LINES.poor, took
end

function M.anOn() return M.cpOpt("CPAnimals") ~= false end
function M.anData()
    local d = M.cpData()
    d.animals = type(d.animals) == "table" and d.animals or {}
    local a = d.animals
    a.hutches = type(a.hutches) == "table" and a.hutches or {}
    a.troughs = type(a.troughs) == "table" and a.troughs or {}
    a.eggAt = type(a.eggAt) == "table" and a.eggAt or {}
    return a
end
local function key(p) return math.floor(p.x) .. ":" .. math.floor(p.y) .. ":" .. math.floor(p.z or 0) end
local function objectsAt(x, y, z)
    local out = {}
    local sq = H.sqAt(x, y, z)
    if sq then pcall(function() local objs = sq:getObjects(); for i = 0, objs:size() - 1 do out[#out + 1] = objs:get(i) end end) end
    return out
end
-- the hutch on a square (any part of it), vanilla's way: object:getHutch()
function M.anHutchAt(x, y, z)
    -- 0.5.11: only IsoHutch has getHutch() (vanilla ISHutchMenu checks the same). Calling it on every object threw
    -- on each one, and pcall still logs a Java stack trace: the log spam on every right-click.
    for _, o in ipairs(objectsAt(x, y, z)) do
        if H.isA(o, "IsoHutch") then
            local h = nil
            pcall(function() h = o:getHutch() end)
            if h then return h end
        end
    end
    return nil
end
function M.anTroughAt(x, y, z)
    for _, o in ipairs(objectsAt(x, y, z)) do if H.isA(o, "IsoFeedingTrough") then return o end end
    return nil
end
local function eggsIn(h)
    local n = 0
    pcall(function() for i = 0, h:getMaxNestBox() do local nb = h:getNestBox(i); if nb then n = n + (tonumber(nb:getEggsNb()) or 0) end end end)
    return n
end
local function entry(h, p)
    local sq = nil
    pcall(function() sq = h:getEntrySq() end)
    if sq then local e = nil; pcall(function() e = { x = sq:getX(), y = sq:getY(), z = sq:getZ() } end); if e then return e end end
    return p
end
local function fill(t) local a, c = 0, 0; pcall(function() a, c = tonumber(t:getFluidAmount()) or 0, tonumber(t:getFluidCapacity()) or 0 end); return a, c end
local function feedIn(c)
    local n = 0
    pcall(function() local items = c:getItems(); for i = 0, items:size() - 1 do if items:get(i):isAnimalFeed() then n = n + 1 end end end)
    return n
end
local function troughBox(t)
    local c = nil
    pcall(function() c = t:getContainer() end)
    return c
end

M.cpAddJob({
    kind = "animals", order = 3,
    pick = function(uid, shell, player, b, now)
        if not M.anOn() or M.cpRoleOf(uid) ~= "shepherd" then return nil end
        local a = M.anData()
        local h = H.hours()
        -- 1) eggs
        for _, p in ipairs(a.hutches) do
            local k = key(p)
            local claim = M.cpClaims["eggs:" .. k]
            if (claim == nil or claim == uid) and h - (tonumber(a.eggAt[k]) or -1e9) >= M.anCfg.eggAgainH then
                local hut = M.anHutchAt(p.x, p.y, p.z)
                if hut and eggsIn(hut) > 0 then
                    M.cpClaims["eggs:" .. k] = uid
                    return { key = "eggs:" .. k, task = "eggs", step = "take", hutch = p, from = entry(hut, p), items = {}, cat = "fresh" }
                end
            end
        end
        -- 2) water a trough under half, from the farm's water spot
        local water = type(M.cpFarmData) == "function" and M.cpFarmData().water or nil
        for _, p in ipairs(a.troughs) do
            local k = key(p)
            local t = M.anTroughAt(p.x, p.y, p.z)
            if t and water and M.cpClaims["trough:" .. k] == nil then
                local amt, cap = fill(t)
                if cap > 0 and amt < cap * M.anCfg.troughAt then
                    M.cpClaims["trough:" .. k] = uid
                    return { key = "trough:" .. k, task = "water", step = "fetch", trough = p, from = water, want = math.min(M.anCfg.carryL, cap - amt) }
                end
            end
        end
        -- 3) feed an empty trough from the feed store
        if a.feed then
            for _, p in ipairs(a.troughs) do
                local k = key(p)
                local t = M.anTroughAt(p.x, p.y, p.z)
                local box = t and troughBox(t)
                if box and feedIn(box) == 0 and M.cpClaims["feed:" .. k] == nil then
                    local sq = H.sqAt(a.feed.x, a.feed.y, a.feed.z)
                    local store = sq and H.containerOn(sq)
                    if store and feedIn(store) > 0 then
                        M.cpClaims["feed:" .. k] = uid
                        return { key = "feed:" .. k, task = "feed", step = "fetch", trough = p, from = a.feed, items = {} }
                    end
                end
            end
        end
        return nil
    end,
    spot = function(j)
        if j.step == "take" or j.step == "fetch" then return j.from end
        if j.step == "put" then return j.to end
        return j.trough
    end,
    ms = function(j) return M.anCfg.workMs end,
    run = function(j, uid, shell, player)
        local a = M.anData()
        if j.task == "eggs" then
            if j.step == "take" then
                local hut = M.anHutchAt(j.hutch.x, j.hutch.y, j.hutch.z)
                local inv = H.invOf(shell)
                a.eggAt[key(j.hutch)] = H.hours()
                if hut == nil or inv == nil then return "done" end
                pcall(function()
                    for i = 0, hut:getMaxNestBox() do
                        local nb = hut:getNestBox(i)
                        while nb and (tonumber(nb:getEggsNb()) or 0) > 0 do
                            local egg = nb:removeEgg(0)
                            if egg == nil then break end
                            inv:AddItem(egg)
                            j.items[#j.items + 1] = egg
                        end
                    end
                    hut:sync()
                end)
                if #j.items == 0 then return "done" end
                M.anStats.eggs = M.anStats.eggs + #j.items
                M.cpLog("animals", H.firstName(uid) .. " collected " .. #j.items .. " egg" .. (#j.items == 1 and "" or "s"))
                j.to = M.cpBestDrop("fresh", j.from.x, j.from.y, 0.1)
                if j.to == nil then
                    if not a.noDropSaid then a.noDropSaid = true; H.say(shell, "Where do the eggs go? Show me where the fresh food goes.") end
                    return "fail" -- held eggs are set down where they stand
                end
                j.step = "put"
                return "next"
            end
            return H.putDown(j, shell, uid)
        end
        if j.task == "water" then
            if j.step == "fetch" then
                local src, have = nil, 0
                for _, o in ipairs(objectsAt(j.from.x, j.from.y, j.from.z)) do
                    local v = 0
                    pcall(function() v = tonumber(o:getFluidAmount()) or 0 end)
                    if v > have then src, have = o, v end
                end
                local take = math.min(j.want, have)
                if src == nil or take <= 0 then
                    if (a.drySaid or -1) ~= math.floor(H.hours() / 24) then a.drySaid = math.floor(H.hours() / 24); H.say(shell, "No water for the animals. The barrel's dry.") end
                    return "done"
                end
                local ok = H.tryOnce("fluid", function() j.fc = src:moveFluidToTemporaryContainer(take) end)
                if not ok or j.fc == nil then return "done" end
                j.litres = take
                j.step = "pour"
                return "next"
            end
            local t = M.anTroughAt(j.trough.x, j.trough.y, j.trough.z)
            if t and j.fc then
                H.tryOnce("troughFill", function() t:transferFluidFrom(j.fc, j.litres) end)
                M.anStats.watered = M.anStats.watered + 1
            end
            if j.fc then pcall(function() FluidContainer.DisposeContainer(j.fc) end); j.fc = nil end
            return "done"
        end
        if j.task == "feed" then
            if j.step == "fetch" then
                local sq = H.sqAt(j.from.x, j.from.y, j.from.z)
                local store = sq and H.containerOn(sq)
                local inv = H.invOf(shell)
                if store == nil or inv == nil then return "done" end
                local picks = {}
                pcall(function() local items = store:getItems(); for i = 0, items:size() - 1 do local it = items:get(i); if it:isAnimalFeed() and #picks < M.anCfg.feedPerTrip then picks[#picks + 1] = it end end end)
                for _, it in ipairs(picks) do if pcall(function() store:DoRemoveItem(it); inv:AddItem(it) end) then j.items[#j.items + 1] = it end end
                if #j.items == 0 then return "done" end
                j.step = "pour"
                return "next"
            end
            local t = M.anTroughAt(j.trough.x, j.trough.y, j.trough.z)
            local box = t and troughBox(t)
            local inv = H.invOf(shell)
            if box and inv then
                for _, it in ipairs(j.items) do if pcall(function() inv:DoRemoveItem(it); box:AddItem(it) end) then M.anStats.fed = M.anStats.fed + 1 end end
                j.items = {}
            end
            return "done" -- anything not put in the trough is set down where they stand
        end
        return "done"
    end,
    release = function(j, uid, shell)
        if j.fc then pcall(function() FluidContainer.DisposeContainer(j.fc) end); j.fc = nil end -- spilled
        for _, k in ipairs({ "eggs:", "trough:", "feed:" }) do
            local p = j.hutch or j.trough
            if p and M.cpClaims[k .. key(p)] == uid then M.cpClaims[k .. key(p)] = nil end
        end
    end,
})

-- menu: Camp > Animals (on a hutch, a trough, or a container for feed)
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local am, ao = child("Animals")
    if not M.anOn() then off(ao, "Animal care is off in this world's sandbox settings.") end
    local a = M.anData()
    local here = { x = x, y = y, z = z }
    local function listToggle(list, label, what)
        for i, p in ipairs(list) do
            if key(p) == key(here) then am:addOption("Stop tending this " .. what, nil, function() M.cpAct("anUnmark", what, x, y, z, nil, player) end); return end
        end
        local o = am:addOption(label, nil, function() M.cpAct("anMark", what, x, y, z, nil, player) end)
        if #list >= M.anCfg.maxMarks then off(o, "That's " .. #list .. " already (max " .. M.anCfg.maxMarks .. ").")
        elseif not inRange then off(o, why or "Too far from your base.") end
    end
    if M.anHutchAt(x, y, z) then listToggle(a.hutches, "Tend this hutch (eggs)", "hutch") end
    if M.anTroughAt(x, y, z) then listToggle(a.troughs, "Tend this trough (water, feed)", "trough") end
    local sq = H.sqAt(x, y, z)
    if sq and H.containerOn(sq) and not M.anTroughAt(x, y, z) then
        if a.feed and key(a.feed) == key(here) then am:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_feed_store_anymore", "Not the feed store anymore"), nil, function() M.cpAct("anFeedOff", nil, nil, nil, nil, nil, player) end)
        else am:addOption(ALifeTr("IGUI_ALCP_Menu_Animal_feed_here", "Animal feed here"), nil, function() M.cpAct("anFeed", x, y, z, nil, nil, player) end) end
    end
    if #a.hutches == 0 and #a.troughs == 0 then off(am:addOption(ALifeTr("IGUI_ALCP_Menu_Right_click_a_hutch_or_trough", "Right-click a hutch or trough")), "Mark the hutches and troughs your shepherd should look after. Water comes from the farm's water spot (Camp > Farm).") end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender). what = "hutch" | "trough"
local function anList(what) local a = M.anData(); if what == "hutch" then return a.hutches end; if what == "trough" then return a.troughs end; return nil end
M.cpActs = M.cpActs or {}
M.cpActs.anUnmark = function(player, what, x, y, z)
    local list = anList(tostring(what))
    if list == nil then return false end
    local here = { x = M.cpNum(x), y = M.cpNum(y), z = M.cpNum(z) or 0 }
    for i, p in ipairs(list) do if key(p) == key(here) then table.remove(list, i); return true end end
    return false
end
M.cpActs.anMark = function(player, what, x, y, z)
    what = tostring(what)
    local list = anList(what)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    if list == nil or #list >= M.anCfg.maxMarks then return false end
    if what == "hutch" and not M.anHutchAt(x, y, z) then return false end
    if what == "trough" and not M.anTroughAt(x, y, z) then return false end
    list[#list + 1] = { x = x, y = y, z = z }
    H.halo("Your shepherd will look after this " .. what .. ".")
    if #M.cpWithRole("shepherd", player) == 0 then H.halo("Nobody's the shepherd yet. Camp > Roles.", 255, 200, 120) end
end
M.cpActs.anFeedOff = function() M.anData().feed = nil end
M.cpActs.anFeed = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    M.anData().feed = { x = x, y = y, z = z }
    H.halo("Feed store set. Troughs that run empty get filled from here.")
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function()
    local a = M.anData()
    local out = {}
    for _, p in ipairs(a.hutches) do out[#out + 1] = { p, 0.9, 0.8, 0.5 } end
    for _, p in ipairs(a.troughs) do out[#out + 1] = { p, 0.5, 0.7, 0.9 } end
    if a.feed then out[#out + 1] = { a.feed, 0.8, 0.6, 0.3 } end
    return out
end)
