-- A-Life Talk v3: giving items to A-Life NPCs, and drinking.
--
-- What Project A-Life 1.4.5 itself has (read from its code, nothing invented):
--   * NpcOpinion.events.gift  (+8 "You shared food or water with them.") through NpcOpinion.note("gift", ...),
--     NpcOpinion.events.medicine (+12), NpcOpinion.adjust for everything else.
--   * A-Life's player -> NPC hand-overs are door/visitor/party flows (SafehouseVisit.give DOOR_GIVE/DOOR_TREAT,
--     door trades, VisitorOffers.transfer, Party.takeItems). All of them move the item with
--     ModuleRobbery.removeItem(entry, destination, owner) and apply their own opinion (NpcOpinion.noteDoor etc.).
--     We wrap removeItem (original always runs first) only to remember those hand-overs.
--   * Item value: ModuleRobbery.factsFor(item, player) + ModuleRobbery.valueOf(facts); A-Life's own safe move:
--     ModuleRobbery.removeItem(entry, destination, owner) (+ ShellState.markScavenged so the item persists).
-- Field NPCs have no "give" in A-Life, so this file adds a right-click "[A-Life Talk] Give ..." submenu that moves
-- the item with those A-Life functions. Other mods (e.g. a trade window such as the GECK extension) are never
-- touched: a light inventory watcher notices items that moved from you to an NPC standing next to you and treats
-- that as a gift (or as a trade if something came back), so their menus and trade paths keep working untouched.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Gifts") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Gifts"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Gifts") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function round(v) if v >= 0 then return math.floor(v + 0.5) end return -math.floor(-v + 0.5) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

M.gift = {
    menuTiles = 6,          -- same reach A-Life uses when an NPC hands you supplies (TalkSupplies: 36 = 6 tiles^2)
    watchTiles = 4,         -- watcher: NPCs this close are checked for items that came from you
    watchEveryTicks = 60,
    menuMax = 18,
    recentHours = 24,       -- diminishing returns window (in-game hours)
    factors = { 1, 0.6, 0.35, 0.2 },
    base = { food = 4, water = 4, medicine = 6, alcohol = 4, gun = 10, ammo = 6, weapon = 6, tool = 3, item = 2,
        clothing = 1, junk = 0 },
    drunkDecayPerHour = 10, -- drunk points lost per in-game hour
    drunkMax = 100,
}
M.handledIds = {}           -- item ids we already turned into a gift event (so the watcher ignores them)
M.npcInv = {}
M.prevPlayerIds = nil

local function hours()
    local pa = PA()
    if pa ~= nil and fn(pa.NpcOpinion, "hours") then
        local ok, h = pcall(pa.NpcOpinion.hours)
        if ok and type(h) == "number" then return h end
    end
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and type(h) == "number" and h or 0
end

local function bucket(name)
    local data = M.store()
    if type(data) ~= "table" then M.tmpStore = M.tmpStore or {}; data = M.tmpStore end
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end

----------------------------------------------------------------------------------------------------------------
-- What is this item?
----------------------------------------------------------------------------------------------------------------
M.alcoholWords = { { "beer", 0.05 }, { "lager", 0.05 }, { "ale", 0.05 }, { "cider", 0.05 }, { "wine", 0.12 },
    { "champagne", 0.12 }, { "whiskey", 0.4 }, { "whisky", 0.4 }, { "bourbon", 0.4 }, { "scotch", 0.4 },
    { "vodka", 0.4 }, { "rum", 0.4 }, { "gin", 0.4 }, { "tequila", 0.4 }, { "brandy", 0.4 }, { "cognac", 0.4 },
    { "liquor", 0.35 }, { "moonshine", 0.5 }, { "schnapps", 0.3 }, { "sake", 0.15 }, { "alcohol", 0.3 } }

local function wordStrength(text)
    text = string.lower(tostring(text or ""))
    for _, w in ipairs(M.alcoholWords) do
        if w[1] == "ale" or w[1] == "gin" or w[1] == "rum" then
            if string.find(" " .. string.gsub(text, "[^%a]", " ") .. " ", " " .. w[1] .. " ", 1, true) then return w[2] end
        elseif string.find(text, w[1], 1, true) then return w[2] end
    end
    return nil
end

-- strength 0..1 (alcohol fraction) or nil. Every engine call is pcall'd: B42 moved drinks to fluid containers.
function M.alcoholOf(item)
    if item == nil then return nil end
    local name, full = "", ""
    pcall(function() name = tostring(item:getDisplayName() or "") end)
    pcall(function() full = tostring(item:getFullType() or "") end)
    local strength = nil
    pcall(function()
        local fc = item:getFluidContainer()
        if fc ~= nil and not fc:isEmpty() then
            local okP, a = pcall(function() return fc:getProperties():getAlcohol() end)
            if okP and type(a) == "number" and a > 0 then strength = a end
            if strength == nil then
                local okN, fname = pcall(function() return tostring(fc:getPrimaryFluid():getFluidTypeString()) end)
                if okN then strength = wordStrength(fname) end
            end
        end
    end)
    if strength == nil then
        local okA, alc = false, nil
        if item.isAlcoholic ~= nil then okA, alc = pcall(function() return item:isAlcoholic() end) end
        if okA and alc == true then strength = wordStrength(name .. " " .. full) or 0.2 end
    end
    if strength == nil and false then -- 0.5.0.1: B42 hasTag wants an ItemTag (the string probe logged an error); off
        local okT, tag = pcall(function() return item:hasTag("Alcoholic") end)
        if not okT then M.probeOff("hasTag", true) end
        if okT and tag == true then strength = wordStrength(name .. " " .. full) or 0.2 end
    end
    if strength == nil then
        local category = ""
        pcall(function() category = tostring(item:getCategory() or "") .. tostring(item:getDisplayCategory() or "") end)
        -- name match only for food/drink-like items (a "Wine Rack" or "Beer Poster" is not a drink)
        local drinkish = string.find(category, "Food", 1, true) or string.find(category, "Fluid", 1, true)
            or string.find(category, "Drink", 1, true)
        pcall(function() if item:getFluidContainer() ~= nil then drinkish = true end end)
        if drinkish then strength = wordStrength(name .. " " .. full) end
    end
    if strength ~= nil and strength > 1 then strength = strength / 100 end
    return strength
end

function M.itemInfo(item, player)
    local info = { name = "something", fullType = "", value = 1, kind = "item" }
    pcall(function() info.name = string.sub(tostring(item:getDisplayName() or "something"), 1, 60) end)
    pcall(function() info.fullType = tostring(item:getFullType() or "") end)
    pcall(function() info.id = item:getID() end)
    local pa = PA()
    local robbery = pa and pa.ModuleRobbery or nil
    local facts = {}
    if fn(robbery, "factsFor") then
        local ok, f = pcall(robbery.factsFor, item, player)
        if ok and type(f) == "table" then facts = f end
        if fn(robbery, "valueOf") then
            local okV, v = pcall(robbery.valueOf, facts)
            if okV and type(v) == "number" then info.value = v end
        end
    end
    info.alcohol = M.alcoholOf(item)
    if info.alcohol then info.kind = "alcohol"
    elseif facts.ranged then info.kind = "gun"
    elseif facts.ammo then info.kind = "ammo"
    elseif facts.weapon then info.kind = "weapon"
    elseif facts.medical then info.kind = "medicine"
    elseif facts.water then info.kind = "water"
    elseif facts.food then info.kind = "food"
    elseif facts.clothing or facts.worn then info.kind = "clothing"
    elseif facts.utility then info.kind = "tool"
    elseif (info.value or 0) <= 5 then info.kind = "junk" end
    if info.kind == "food" then
        local rotten = false
        pcall(function() rotten = instanceof(item, "Food") and item:isRotten() == true end) -- 0.8.3.1: Food only
        if rotten then info.kind, info.rotten = "junk", true end
    end
    return info
end

-- the NPC's needs, read from the vanilla character the shell is (unverified on every A-Life shell type: pcall'd)
function M.needsOf(shell)
    local n = {}
    if shell == nil then return n end
    -- 0.5.0.1: method-exists checks first (B42 Stats has get(CharacterStat) only; A-Life shells may have no BodyDamage)
    local st = shell.getStats ~= nil and shell:getStats() or nil
    if st ~= nil then
        if st.getHunger ~= nil then local h = st:getHunger(); if type(h) == "number" then n.hunger = h end end
        if st.getThirst ~= nil then local t = st:getThirst(); if type(t) == "number" then n.thirst = t end end
        if n.hunger == nil and CharacterStat ~= nil and st.get ~= nil then
            if CharacterStat.HUNGER ~= nil then pcall(function() n.hunger = st:get(CharacterStat.HUNGER) end) end
            if CharacterStat.THIRST ~= nil then pcall(function() n.thirst = st:get(CharacterStat.THIRST) end) end
        end
    end
    local bd = shell.getBodyDamage ~= nil and shell:getBodyDamage() or nil
    if bd ~= nil and bd.getOverallBodyHealth ~= nil then
        local hp = bd:getOverallBodyHealth()
        if type(hp) == "number" then n.health = hp end
    end
    local out = {}
    if type(n.hunger) == "number" and n.hunger >= 0.25 then out.hungry = n.hunger >= 0.5 and "very hungry" or "hungry" end
    if type(n.thirst) == "number" and n.thirst >= 0.25 then out.thirsty = n.thirst >= 0.5 and "very thirsty" or "thirsty" end
    if type(n.health) == "number" and n.health < 80 then out.hurt = n.health < 50 and "badly hurt" or "hurt" end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- Drunk level (per NPC, saved with the game, decays with in-game time)
----------------------------------------------------------------------------------------------------------------
function M.drunkLabel(v)
    if v <= 0 then return nil end
    if v < 20 then return "a little buzzed" end
    if v < 45 then return "tipsy" end
    if v < 70 then return "drunk" end
    return "very drunk"
end

function M.drunkOf(uid)
    local row = bucket("drunk")[tostring(uid)]
    if type(row) ~= "table" then return 0, nil end
    local v = (tonumber(row.v) or 0) - math.max(0, hours() - (tonumber(row.h) or 0)) * M.gift.drunkDecayPerHour
    if v <= 0 then bucket("drunk")[tostring(uid)] = nil; return 0, nil end
    v = round(v)
    return v, M.drunkLabel(v)
end

function M.addDrunk(uid, points)
    local v = M.drunkOf(uid)
    v = clamp(v + points, 0, M.gift.drunkMax)
    bucket("drunk")[tostring(uid)] = { v = v, h = hours() }
    return v
end

-- take a drink from the item now in the NPC's inventory. Returns how it was consumed (or "none").
function M.drink(shell, item, strength)
    local how = "none"
    if item ~= nil then
        pcall(function()
            local fc = item:getFluidContainer()
            if fc ~= nil and not fc:isEmpty() then
                local amount = fc:getAmount()
                local sip = math.min(amount, 0.25)
                local okR = pcall(function() fc:removeFluid(sip) end)
                if not okR then fc:adjustAmount(amount - sip) end
                how = "fluid"
            end
        end)
        if how == "none" then
            local okU = pcall(function() item:Use() end) -- drainable / food portion (vanilla InventoryItem:Use)
            if okU then how = "use" end
        end
    end
    local points = clamp(round((strength or 0.2) * 70) + 8, 10, 35)
    return how, points
end

----------------------------------------------------------------------------------------------------------------
-- Opinion: A-Life's own gift/medicine events when they fit, otherwise human-scaled NpcOpinion.adjust
----------------------------------------------------------------------------------------------------------------
function M.recentGifts(uid)
    local list = bucket("gifts")[tostring(uid)]
    if type(list) ~= "table" then return 0, 0 end
    local now, n, junk = hours(), 0, 0
    for _, g in ipairs(list) do
        if now - (tonumber(g.h) or -1e9) <= M.gift.recentHours then
            n = n + 1
            if g.k == "junk" then junk = junk + 1 end
        end
    end
    return n, junk
end

function M.noteGift(uid, info)
    local map = bucket("gifts")
    local list = type(map[tostring(uid)]) == "table" and map[tostring(uid)] or {}
    list[#list + 1] = { h = hours(), k = info.kind, n = info.name }
    while #list > 10 do table.remove(list, 1) end
    map[tostring(uid)] = list
end

function M.giftOpinion(record, player, info, needs)
    local pa = PA()
    local opinion = pa and pa.NpcOpinion or nil
    if opinion == nil then return 0, "none", 1 end
    local n, junk = M.recentGifts(record.uid)
    local f = M.gift.factors[math.min(n + 1, #M.gift.factors)]
    local needed = (info.kind == "food" and needs.hungry) or (info.kind == "water" and needs.thirsty)
    if n == 0 and needed and fn(opinion, "note") then
        if opinion.note("gift", record, player) then return 8, "A-Life gift", f end
    end
    if n == 0 and info.kind == "medicine" and needs.hurt and fn(opinion, "note") then
        if opinion.note("medicine", record, player) then return 12, "A-Life medicine", f end
    end
    local base = M.gift.base[info.kind] or 2
    if needed then base = base * 2 end
    if info.kind == "junk" and junk >= 2 then base = -2 end    -- third piece of junk today: feels like mockery
    if info.rotten then base = -2 end
    local delta = base > 0 and round(base * f) or base
    if delta ~= 0 and fn(opinion, "adjust") then
        opinion.adjust(record, player, delta, delta > 0 and ("You gave them " .. info.name .. ".")
            or ("You handed them " .. info.name .. "."))
        return delta, "adjust", f
    end
    return 0, "none", f
end

----------------------------------------------------------------------------------------------------------------
-- A gift happened (from our menu, the door flow, or the watcher)
----------------------------------------------------------------------------------------------------------------
function M.onGift(player, listener, items, opts)
    opts = opts or {}
    if player == nil or listener == nil or listener.record == nil or type(items) ~= "table" or #items == 0 then return end
    local pa = PA()
    local talk = pa.Talk
    local record, shell = listener.record, listener.shell
    local needs = M.needsOf(shell)
    local first = items[1]
    local applied, how, factor = 0, opts.trade and "trade" or "none", 1
    if not opts.opinionDone and not opts.trade then
        local ok, d, h, f = pcall(M.giftOpinion, record, player, first, needs)
        if ok then applied, how, factor = d, h, f else log("gift opinion error: " .. tostring(d)) end
    end
    local recent = M.recentGifts(record.uid)
    for _, info in ipairs(items) do
        if info.id ~= nil then M.handledIds[info.id] = true end
        if not opts.trade then M.noteGift(record.uid, info) end
    end
    if M.keyMem then
        local names = {}
        for _, info in ipairs(items) do names[#names + 1] = info.name end
        pcall(M.keyMem, record.uid, opts.trade and "trade" or "gift",
            (opts.trade and "You traded them " or "You gave them ") .. table.concat(names, ", ")
            .. (applied ~= 0 and string.format(" (%+d)", applied) or ""))
    end
    log(string.format("gift to %s: %s (%s, value %s) opinion %+d via %s", tostring(record.uid), first.name, first.kind,
        tostring(first.value), applied, how))
    M.metrics.gifts = (M.metrics.gifts or 0) + 1
    local stance = fn(talk, "stance") and talk.stance(record, player) or "neutral"
    local quiet = opts.quiet or stance == "hostile" or (fn(talk, "busy") and talk.busy(record, nowMs()))
    M.submit({ mode = quiet and "note" or "gift", uid = tostring(record.uid), player = player, listener = listener,
        items = items, needs = needs, trade = opts.trade, received = opts.received, applied = applied, factor = factor,
        recent = recent, door = opts.door, stance = stance, startMs = nowMs(), depth = 0 })
end

function M.giftRequest(job, now)
    local listener = M.refresh(job) or job.listener
    if listener == nil then return nil end
    local names = {}
    for _, info in ipairs(job.items) do names[#names + 1] = info.name end
    local label = table.concat(names, ", ")
    local req = M.buildRequest(job.player, listener, "[gave you " .. label .. "]", nil, job.stance, now)
    req.mode = job.mode
    local gifts = {}
    for i, info in ipairs(job.items) do
        if i > 4 then break end
        gifts[#gifts + 1] = { name = info.name, kind = info.kind, value = info.value, alcohol = info.alcohol,
            rotten = info.rotten }
    end
    req.gift = { items = gifts, trade = job.trade == true, received = job.received, opinion = job.applied,
        before = job.recent, door = job.door == true }
    req.needs = job.needs
    local alcohol = false
    for _, info in ipairs(job.items) do if info.alcohol then alcohol = true end end
    if job.mode == "gift" and alcohol then
        req.acts, req.actHints = { "DRINK" }, { "DRINK=take a drink of it right now" }
    else
        req.acts, req.actHints = {}, {}
    end
    return req
end

function M.finishGift(p, r)
    local listener = M.refresh(p)
    if listener == nil then return end
    local pa = PA()
    local talk, opinion = pa.Talk, pa.NpcOpinion
    local record, shell, player = listener.record, listener.shell, p.player
    local now = nowMs()
    log(string.format("gift reaction in %d ms: d=%s act=%s", now - p.startMs, tostring(r.d), tostring(r.act)))
    if fn(talk, "busy") and talk.busy(record, now) then return end
    -- the model's own read of the moment adds a little on top (offended by junk, touched by a kind gesture)
    local nuance = clamp(tonumber(r.d) or 0, -3, 2)
    if nuance > 0 then nuance = round(nuance * (p.factor or 1)) end
    if nuance ~= 0 and not p.trade and fn(opinion, "adjust") then
        opinion.adjust(record, player, nuance, nuance > 0 and "You were generous." or "Your gift rubbed them the wrong way.")
    end
    if r.act == "DRINK" and fn(talk, "stance") and talk.stance(record, player) ~= "hostile" then
        local drinkItem, strength = nil, nil
        for _, info in ipairs(p.items) do
            if info.alcohol then strength = info.alcohol; drinkItem = M.findItem(shell, info.id) end
        end
        if strength ~= nil then
            local how, points = M.drink(shell, drinkItem, strength)
            local level = M.addDrunk(record.uid, points)
            p.drank = true
            if M.keyMem then pcall(M.keyMem, record.uid, "drink", "Had a drink of what you gave them (" .. (M.drunkLabel(level) or "sober") .. ")") end
            log(string.format("%s drank (%s), drunk level now %d", tostring(record.uid), how, level))
        end
    end
    local text = r.text
    if type(text) ~= "string" or text == "" then text = M.giftLine(p) end
    M.say(shell, player, text)
end

function M.giftLine(p)
    local info = p.items[1] or {}
    local needs = p.needs or {}
    if p.trade then return "Pleasure doing business." end
    if info.rotten then return "Is this... rotten? Thanks a lot." end
    if info.kind == "alcohol" then return "Oh, now that's a welcome sight. Thanks." end
    if (info.kind == "food" and needs.hungry) or (info.kind == "water" and needs.thirsty) then
        return "God, thank you. I really needed that."
    end
    if info.kind == "junk" then return "Uh... thanks, I guess." end
    if (p.recent or 0) >= 2 then return "You don't have to keep giving me stuff, you know." end
    return "Thanks, I appreciate it."
end

function M.giftFallback(p)
    local listener = M.refresh(p)
    if listener == nil then return end
    M.say(listener.shell, p.player, M.giftLine(p))
end

function M.findItem(shell, id)
    if id == nil then return nil end
    local found = nil
    pcall(function()
        local inv = shell:getInventory()
        local okI, item = pcall(function() return inv:getItemById(id) end)
        if okI and item ~= nil then found = item; return end
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            if items:get(i):getID() == id then found = items:get(i); return end
        end
    end)
    return found
end

----------------------------------------------------------------------------------------------------------------
-- Give from the right-click menu (moves the item with A-Life's own functions)
----------------------------------------------------------------------------------------------------------------
function M.giveCandidates(player)
    local pa = PA()
    local robbery = pa and pa.ModuleRobbery or nil
    if not fn(robbery, "gatherItems") then return {} end
    local ok, listed = pcall(robbery.gatherItems, player, { playerOnly = true, limit = 256 })
    if not ok or type(listed) ~= "table" then return {} end
    local rows, seen = {}, {}
    for _, entry in ipairs(listed) do
        local item = entry.source == "player" and entry.item or nil
        local equipped = false
        pcall(function() equipped = item:isEquipped() == true end)
        local isBag = false
        pcall(function() isBag = instanceof(item, "InventoryContainer") end)
        if item ~= nil and not equipped and not isBag then
            local name = "item"
            pcall(function() name = tostring(item:getDisplayName()) end)
            local key = tostring(entry.fullType) .. ":" .. name
            if not seen[key] then
                seen[key] = true
                local alcohol = M.alcoholOf(item)
                local score = (alcohol and 200 or 0) + (tonumber(entry.value) or 0)
                rows[#rows + 1] = { entry = entry, name = name, score = score }
            end
        end
    end
    table.sort(rows, function(a, b) if a.score == b.score then return a.name < b.name end return a.score > b.score end)
    while #rows > M.gift.menuMax do table.remove(rows) end
    return rows
end

function M.addGiftMenu(context, player, l, name)
    local rows = M.giveCandidates(player)
    if #rows == 0 or type(context.getNew) ~= "function" then return end
    local parent = M.menuOpt(context, "gift", "A-Life: Give to " .. tostring(name or "them"))
    local sub = context:getNew(context)
    context:addSubMenu(parent, sub)
    for _, row in ipairs(rows) do
        local id = nil
        pcall(function() id = row.entry.item:getID() end)
        if id ~= nil then sub:addOption(row.name, player, M.onGiveOption, tostring(l.record.uid), id) end
    end
end

function M.onGiveOption(player, uid, itemId)
    local ok, err = pcall(M.give, player, uid, itemId)
    if not ok then log("give error: " .. tostring(err)) end
end

function M.give(player, uid, itemId)
    local pa = PA()
    local talk, reg, robbery = pa.Talk, pa.ActorRegistry, pa.ModuleRobbery
    local record = fn(reg, "read") and reg.read(uid) or nil
    local shell = fn(talk, "shellFor") and talk.shellFor(uid) or nil
    if record == nil or shell == nil then return false end
    local px, py, sx, sy = nil, nil, nil, nil
    pcall(function() px, py, sx, sy = player:getX(), player:getY(), shell:getX(), shell:getY() end)
    if px == nil or (px - sx) ^ 2 + (py - sy) ^ 2 > M.gift.menuTiles ^ 2 then
        pcall(function() player:Say("Too far away.") end)
        return false
    end
    local entry = nil
    local okG, listed = pcall(robbery.gatherItems, player, { playerOnly = true, limit = 256 })
    if okG and type(listed) == "table" then
        for _, e in ipairs(listed) do
            local id = nil
            pcall(function() id = e.item:getID() end)
            if id == itemId and e.source == "player" then entry = e; break end
        end
    end
    if entry == nil then return false end
    local info = M.itemInfo(entry.item, player)
    local dest = nil
    pcall(function() dest = shell:getInventory() end)
    if dest == nil then return false end
    local state = pa.ShellState
    local previous = nil
    pcall(function() previous = entry.item:getModData().ProjectALifeScavenged end)
    if fn(state, "markScavenged") then pcall(state.markScavenged, entry.item) end -- A-Life keeps it in the NPC's bag
    local moved = false
    if fn(robbery, "removeItem") then
        M.ourGive = true
        local okM, res = pcall(robbery.removeItem, entry, dest, shell)
        M.ourGive = false
        moved = okM and res == true
    end
    if not moved and fn(pa.TalkOrders, "relocate") then
        moved = pa.TalkOrders.relocate(entry.container, dest, entry.item) == true
    end
    if not moved then
        pcall(function() entry.item:getModData().ProjectALifeScavenged = previous end)
        pcall(function() player:Say("They can't carry that.") end)
        return false
    end
    M.handledIds[itemId] = true
    local listener = { record = record, shell = shell, distance = 1 }
    M.onGift(player, listener, { info }, {})
    return true
end

----------------------------------------------------------------------------------------------------------------
-- A-Life's own hand-overs. Every A-Life path that moves an item from the player to an NPC goes through
-- ModuleRobbery.removeItem(entry, destination, owner): SafehouseVisit.give (door DOOR_GIVE/DOOR_TREAT), door
-- trades/payments, VisitorOffers.transfer (visitor gifts) and Party.takeItems (party jobs). Those paths already
-- apply A-Life's own opinion events and speak A-Life's own lines, so we only (a) mark the item so the watcher
-- ignores it and (b) remember the hand-over in the NPC's memory. The original always runs first.
----------------------------------------------------------------------------------------------------------------
function M.installGifts()
    local pa = PA()
    local robbery = pa and pa.ModuleRobbery or nil
    if M.origRemoveItem ~= nil or not fn(robbery, "removeItem") then return end
    M.origRemoveItem = robbery.removeItem
    robbery.removeItem = function(entry, destination, owner, ...)
        local item = type(entry) == "table" and entry.item or nil
        local fromPlayer = type(entry) == "table" and entry.source == "player" and destination ~= nil and owner ~= nil
        local info = nil
        if fromPlayer and not M.ourGive then pcall(function() info = M.itemInfo(item, nil) end) end
        local a, b, c, d = M.origRemoveItem(entry, destination, owner, ...)
        if a == true and item ~= nil then
            pcall(function() M.handledIds[item:getID()] = true end)
            if info ~= nil then pcall(M.alifeHandOver, owner, info) end
        end
        return a, b, c, d
    end
    log("wrapped ModuleRobbery.removeItem (A-Life hand-overs are remembered, never changed)")
end

function M.alifeHandOver(owner, info)
    local pa = PA()
    local uid = M.uidOf(owner)
    if uid == nil or not fn(pa.ActorRegistry, "read") then return end
    local record = pa.ActorRegistry.read(uid)
    local player = ALifeSide.you()
    if player == nil and type(ALifeSide) == "table" and ALifeSide.mpServer() then player = ALifeSide.nearestTo(owner, 5) end -- MP: the giver beside them
    if record == nil or player == nil then return end
    M.noteGift(record.uid, info)
    M.submit({ mode = "note", uid = tostring(record.uid), player = player, listener = { record = record, shell = owner },
        items = { info }, needs = {}, applied = 0, factor = 1, recent = 0, door = true, stance = "neutral",
        startMs = nowMs(), depth = 0 })
end

----------------------------------------------------------------------------------------------------------------
-- Watcher: items that left your inventory and showed up on an NPC next to you (other mods' give/trade windows)
----------------------------------------------------------------------------------------------------------------
local function collectIds(container, out, depth, limit)
    if container == nil or depth > 2 then return end
    local items = container:getItems()
    for i = 0, math.min(items:size(), limit) - 1 do
        local item = items:get(i)
        local id = item:getID()
        out[id] = item
        local isBag = false
        pcall(function() isBag = instanceof(item, "InventoryContainer") end)
        if isBag then pcall(collectIds, item:getInventory(), out, depth + 1, limit) end
    end
end

-- pre-1.0 MP (P5): the gift watcher runs on the server for every online player, each with their own memory of what
-- they and the people near them carried (M.npcInv / M.prevPlayerIds are per player there: Main's M.perPlayer)
if type(ALifeSide) == "table" and ALifeSide.mpServer() and fn(M, "perPlayer") then M.perPlayer("npcInv"); M.perPlayer("prevPlayerIds") end
function M.giftTick()
    if not M.settings.enabled or not M.worldHere() then return end
    M.eachPlayer(M.giftTickFor)
end
function M.giftTickFor(player)
    local pa = PA()
    local talk = pa and pa.Talk or nil
    if not fn(talk, "listeners") then return end
    if player == nil then return end
    if M.npcInv == nil then M.npcInv = {} end
    local near = talk.listeners(player, M.gift.watchTiles)
    if #near == 0 then M.npcInv, M.prevPlayerIds = {}, nil; return end
    local mine = {}
    pcall(collectIds, player:getInventory(), mine, 0, 400)
    local prevMine = M.prevPlayerIds
    local now = nowMs()
    local seenNow = {}
    for i = 1, math.min(#near, 3) do
        local l = near[i]
        local uid = tostring(l.record.uid)
        seenNow[uid] = true
        local ids = {}
        pcall(collectIds, l.shell:getInventory(), ids, 0, 300)
        local prev = M.npcInv[uid]
        local memory = type(l.record.memory) == "table" and l.record.memory or {}
        if type(memory.robbery) == "table" or (fn(talk, "stance") and talk.stance(l.record, player) == "hostile") then
            prev = nil -- being robbed / hostile: items leaving you are not gifts
        end
        if prev ~= nil and prevMine ~= nil and now - prev.at < 5000 then
            local given, received = {}, {}
            for id, item in pairs(ids) do
                if prev.ids[id] == nil and prevMine[id] ~= nil and mine[id] == nil and not M.handledIds[id] then
                    given[#given + 1] = M.itemInfo(item, player)
                end
            end
            for id, item in pairs(prev.ids) do
                if ids[id] == nil and mine[id] ~= nil and prevMine[id] == nil then
                    local name = "something"
                    pcall(function() name = tostring(item:getDisplayName()) end)
                    received[#received + 1] = name
                end
            end
            if #given > 0 then
                M.onGift(player, l, given, { trade = #received > 0, received = #received > 0 and received or nil })
            end
        end
        M.npcInv[uid] = { ids = ids, at = now }
    end
    for uid in pairs(M.npcInv) do if not seenNow[uid] then M.npcInv[uid] = nil end end
    M.prevPlayerIds = mine
end

M.eventModes.gift = { request = M.giftRequest, finish = M.finishGift, fallback = M.giftFallback }
M.eventModes.note = { request = M.giftRequest }

return M
