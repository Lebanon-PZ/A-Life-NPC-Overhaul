-- A-Life NPC Overhaul: bargaining, in words, for real items.
-- "Want to trade?" / "I'll give you a can of beans for that bandage" / "What do you want for the shotgun shells?"
-- opens a deal. From then on you just talk: they say what they'd want, you counter, they hold firm or give ground,
-- based on what they actually carry, what you actually carry, what they're short of (a starving person values food
-- far above ammo), how much they trust or fear you, and their temperament. Say "deal" / "yes" / "shake on it" to a
-- standing offer and the items really change hands (A-Life's own item moving, the same as a frisk). "Forget it" /
-- "no deal" walks away. A fair trade counts as a fair deal with them (A-Life's opinion) and they remember it.
-- They never trade away the weapon in their hands, and never take something you no longer have.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeHaggle") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeHaggle]"
ALifeHaggle = ALifeHaggle or {}
local HG = ALifeHaggle
HG.SESSION_MS = 90000           -- a deal stays open this long after the last word
HG.MAX_ITEMS = 14
HG.sessions = {}

HG.INTENTS = {
    { id = "TRADE_OFFER", prio = 83, patterns = "want to trade|wanna trade|lets trade|let's trade|trade you|ill trade|i'll trade|trade for|swap you|ill swap|i'll swap|what do you want for|what would you take for|ill give you|i'll give you|how about a trade|make a deal|got anything to trade|barter" },
}
HG.ACCEPT = { "deal", "yes", "yeah", "okay", "ok", "sure", "shake on it", "you got a deal", "agreed", "fine", "alright", "done" }
HG.CANCEL = { "forget it", "no deal", "never mind", "nevermind", "nah", "no thanks", "not interested", "pass", "walk away" }

local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function lower(t) return " " .. string.lower(string.gsub(tostring(t or ""), "[^%w%s']", " ")) .. " " end
local function hasAny(t, list) for _, w in ipairs(list) do if string.find(t, " " .. w .. " ", 1, true) then return true end end return false end

local function items(container, skip)
    local out = {}
    local ok, list = pcall(function() return container:getItems() end)
    if not ok or list == nil then return out end
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        local okI, info = pcall(function()
            if skip[it] then return nil end
            local ft = tostring(it:getFullType())
            if ft == "Base.BareHands" or string.find(ft, "ProjectALife", 1, true) then return nil end
            if instanceof(it, "Clothing") and it:isEquipped() then return nil end
            if instanceof(it, "InventoryContainer") then return nil end
            return { item = it, name = tostring(it:getDisplayName()), type = ft }
        end)
        if okI and info ~= nil then out[#out + 1] = info end
        if #out >= HG.MAX_ITEMS then break end
    end
    return out
end

-- what each side can put on the table right now
function HG.inventories(shell, player)
    local skipN, skipP = {}, {}
    pcall(function() skipN[shell:getPrimaryHandItem()] = true; skipN[shell:getSecondaryHandItem()] = true end)
    pcall(function() skipP[player:getPrimaryHandItem()] = true; skipP[player:getSecondaryHandItem()] = true end)
    local theirs = items(shell:getInventory(), skipN)
    local yours = items(player:getInventory(), skipP)
    return theirs, yours
end

local function listText(list, prefix)
    local parts = {}
    for i, e in ipairs(list) do parts[#parts + 1] = prefix .. i .. ": " .. e.name end
    return table.concat(parts, "; ")
end

function HG.active(uid)
    local s = HG.sessions[uid]
    return s ~= nil and now() - s.at < HG.SESSION_MS
end

-- carry out the standing offer
function HG.execute(s, record, shell, player)
    local Orders = ProjectALife.TalkOrders
    local theirs, yours = HG.inventories(shell, player)
    local function find(list, name)
        for i, e in ipairs(list) do if e.name == name then table.remove(list, i); return e end end
        return nil
    end
    local give, take = {}, {}
    for _, n in ipairs(s.offer.give) do local e = find(theirs, n); if e == nil then return false, "gone" end; give[#give + 1] = e end
    for _, n in ipairs(s.offer.take) do local e = find(yours, n); if e == nil then return false, "missing" end; take[#take + 1] = e end
    local pInv, nInv = player:getInventory(), shell:getInventory()
    for _, e in ipairs(take) do Orders.relocate(pInv, nInv, e.item) end
    for _, e in ipairs(give) do Orders.relocate(nInv, pInv, e.item) end
    pcall(Orders.rebuildDeath, shell)
    pcall(function() ProjectALife.NpcOpinion.note("trade", record, player) end)
    local names = {}
    for _, e in ipairs(give) do names[#names + 1] = e.name end
    local paid = {}
    for _, e in ipairs(take) do paid[#paid + 1] = e.name end
    if ALifeMemory ~= nil then pcall(ALifeMemory.add, record, "traded with the stranger: gave " .. table.concat(names, ", ") .. " for " .. table.concat(paid, ", ")) end
    ALifeHealth.note(TAG, "traded " .. table.concat(paid, ", ") .. " for " .. table.concat(names, ", "))
    return true
end

-- one turn of the haggle (returns the "thinking" placeholder like other AI turns, or a line)
function HG.turn(player, listener, text)
    local record, shell = listener.record, listener.shell
    if ALifeOrders ~= nil and type(ALifeOrders.shunned) == "function" and ALifeOrders.shunned(record) then
        HG.sessions[record.uid] = nil
        local line = "I'm not trading with you."
        pcall(function() ProjectALife.Speech.say(shell, line, { face = player }) end)
        return line, "refused"
    end
    local uid = record.uid
    local s = HG.sessions[uid] or { at = now() }
    HG.sessions[uid] = s
    s.at = now()
    local t = lower(text)
    local ai = ALifeChatAI
    if hasAny(t, HG.CANCEL) then
        HG.sessions[uid] = nil
        local line = "Suit yourself."
        if ai then ai.say(shell, line, { face = player }) end
        return line, "answered"
    end
    if s.offer ~= nil and hasAny(t, HG.ACCEPT) and ALifeChatAI and ALifeChatAI.stillThere(player, shell, 6) and not string.find(t, " but ", 1, true) and not string.find(t, " for ", 1, true) then
        local ok, why = HG.execute(s, record, shell, player)
        HG.sessions[uid] = nil
        local line = ok and "Pleasure doing business." or (why == "missing" and "You don't have that anymore." or "Changed my mind about that one.")
        if ai then ai.say(shell, line, { face = player }) end
        return line, "answered"
    end
    if ai == nil or not ai.alive() then
        HG.sessions[uid] = nil
        return nil
    end
    local theirs, yours = HG.inventories(shell, player)
    s.theirs, s.yours = theirs, yours
    local p = ai.profile(record, player)
    local needs = {}
    pcall(function() needs = ProjectALifeJimmy.Needs.needs(record.memory) or {} end)
    local fields = { "mode=haggle", "name=" .. ai.clean(p.name, 40), "temperament=" .. ai.clean(p.temperament, 30),
        "stance=" .. ai.clean(p.stance, 20), "situation=" .. ai.clean(ai.situation(record, shell, player), 400),
        "needs=" .. string.format("hunger %d, thirst %d", tonumber(needs.hunger) or 0, tonumber(needs.thirst) or 0),
        "theirs=" .. ai.clean(listText(theirs, "T"), 900), "yours=" .. ai.clean(listText(yours, "Y"), 900),
        "offer=" .. ai.clean(s.offer and ("they give " .. table.concat(s.offer.give, ", ") .. " for " .. table.concat(s.offer.take, ", ")) or "none", 300),
        "player=" .. ai.clean(text, 300), "history=" .. ai.clean(table.concat(ai.history(uid), " || "), 600) }
    for _, l in ipairs(ai.context(record, p)) do fields[#fields + 1] = l end
    ai.remember(uid, "Stranger: " .. text)
    local sent = ai.request(fields, function(lines)
        if not ai.stillThere(player, shell, 20) then HG.sessions[uid] = nil; return end
        if lines == nil then ai.say(shell, "Let me think about it.", { face = player }); return end
        local say, give, take, status = nil, {}, {}, "offer"
        for _, l in ipairs(lines) do
            say = say or string.match(l, "^text=(.*)$")
            local g = string.match(l, "^give=(.*)$")
            if g then for ix in string.gmatch(g, "T(%d+)") do local e = theirs[tonumber(ix)]; if e then give[#give + 1] = e.name end end end
            local k = string.match(l, "^take=(.*)$")
            if k then for ix in string.gmatch(k, "Y(%d+)") do local e = yours[tonumber(ix)]; if e then take[#take + 1] = e.name end end end
            status = string.match(l, "^status=(%a+)") or status
        end
        if status == "refuse" then HG.sessions[uid] = nil
        elseif #give > 0 and #take > 0 then s.offer = { give = give, take = take } end
        if say and say ~= "" then
            ai.say(shell, say, { face = player })
            ai.remember(uid, (p.name ~= "" and p.name or "Them") .. ": " .. say)
        end
    end, 9000, 1)
    if not sent then HG.sessions[uid] = nil; return nil end
    pcall(function() ProjectALife.Talk.hold(record, shell, player, now()) end)
    return "...", "thinking"
end

-- ---------------------------------------------------------------- gifts ----
-- "Take these shells" / "here, have some water": the item you name really goes to them. A-Life's own OFFER_ITEM only
-- answers; this finds the thing you named in your inventory, hands it over, and counts it as a gift they remember.
HG.ALIASES = { ["12 gauge"] = "shotgun", ["12-gauge"] = "shotgun", gauge = "shotgun", buckshot = "shotgun", rounds = "ammo",
    bullets = "ammo", meds = "pill", medicine = "pill", smokes = "cigarette", cigs = "cigarette", booze = "alcohol" }
HG.STOP = { take = 1, this = 1, these = 1, here = 1, have = 1, some = 1, your = 1, from = 1, with = 1, keep = 1, them = 1,
    that = 1, those = 1, give = 1, box = 1, bottle = 1, pack = 1, can = 1, bag = 1, the = 1, ["for"] = 1, you = 1, ["and"] = 1 }

function HG.findNamed(player, text)
    local t = string.lower(tostring(text or ""))
    for k, v in pairs(HG.ALIASES) do
        local i = string.find(t, k, 1, true)
        while i do t = string.sub(t, 1, i - 1) .. " " .. v .. " " .. string.sub(t, i + #k); i = string.find(t, k, i + #v + 2, true) end
    end
    local words = {}
    for w in string.gmatch(t, "%a+") do
        if #w >= 3 and not HG.STOP[w] then words[#words + 1] = (string.gsub(w, "s$", "")) end
    end
    if #words == 0 then return nil end
    local skip = {}
    pcall(function() skip[player:getPrimaryHandItem()] = true; skip[player:getSecondaryHandItem()] = true end)
    local best, bestScore = nil, 0
    for _, e in ipairs(items(player:getInventory(), skip)) do
        local name = string.lower(e.name .. " " .. e.type)
        local score = 0
        for _, w in ipairs(words) do if string.find(name, w, 1, true) then score = score + #w end end
        if score > bestScore then best, bestScore = e, score end
    end
    return best
end

function HG.gift(record, shell, player, text)
    local e = HG.findNamed(player, text)
    if e == nil then return nil end
    local Orders = ProjectALife.TalkOrders
    if Orders == nil or not Orders.relocate(player:getInventory(), shell:getInventory(), e.item) then return nil end
    pcall(function() ProjectALife.NpcOpinion.note("gift", record, player) end)
    if ALifeMemory ~= nil then pcall(ALifeMemory.add, record, "the stranger gave you " .. e.name .. " for nothing") end
    ALifeHealth.note(TAG, "gave " .. e.name)
    local lines = { "...Thank you. I mean it.", "For me? Thanks.", "That's... thanks. I won't forget it." }
    local line = lines[(type(ZombRand) == "function" and ZombRand(#lines) or 0) + 1]
    pcall(function() ProjectALife.Speech.say(shell, line, { face = player }) end)
    return line, "answered"
end

-- ------------------------------------------------------------ demands ----
-- "Give me your car keys" / "hand me the bourbon": if they carry what you named, A-Life's own robbery roll decides
-- (trust, fear, need, guns, your gear vs theirs, their crew) - a yes hands over exactly that item, a no is A-Life's
-- own refusal (which can turn into a fight). Asking for one thing is a smaller ask than "give me everything".
function HG.findOn(shell, text)
    local t = string.lower(tostring(text or ""))
    for k, v in pairs(HG.ALIASES) do
        local i = string.find(t, k, 1, true)
        while i do t = string.sub(t, 1, i - 1) .. " " .. v .. " " .. string.sub(t, i + #k); i = string.find(t, k, i + #v + 2, true) end
    end
    local words = {}
    for w in string.gmatch(t, "%a+") do
        if #w >= 3 and not HG.STOP[w] and w ~= "hand" and w ~= "last" and w ~= "need" and w ~= "want" then
            words[#words + 1] = (string.gsub(w, "s$", ""))
        end
    end
    if #words == 0 then return nil end
    local best, bestScore = nil, 0
    local ok, list = pcall(function() return shell:getInventory():getItems() end)
    if not ok or list == nil then return nil end
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        local okI, name, worn = pcall(function()
            return string.lower(tostring(it:getDisplayName()) .. " " .. tostring(it:getFullType())),
                instanceof(it, "Clothing") and it:isEquipped()
        end)
        if okI and not worn then
            local score = 0
            for _, w in ipairs(words) do if string.find(name, w, 1, true) then score = score + #w end end
            if score > bestScore then best, bestScore = it, score end
        end
    end
    return best
end

function HG.demand(record, shell, player, context, now_, text)
    local item = HG.findOn(shell, text)
    if item == nil then return nil end
    local Orders = ProjectALife.TalkOrders
    if Orders == nil or type(Orders.chanceFor) ~= "function" then return nil end
    local chance = Orders.chanceFor("rob", record, shell, player, context) + 12
    local r = type(ZombRand) == "function" and ZombRand(100) or 0
    local name = tostring(item:getDisplayName())
    ALifeHealth.note(TAG, string.format("demand %s: chance %d, roll %d", name, chance, r))
    if r >= chance then
        pcall(function() ProjectALife.NpcOpinion.note("threat_failed", record, player) end)
        if type(Orders.refuse) == "function" then return Orders.refuse("rob", record, shell, player, context, now_) end
        return nil
    end
    if not Orders.relocate(shell:getInventory(), player:getInventory(), item) then return nil end
    Orders.clearHands(shell, item)
    pcall(Orders.rebuildDeath, shell)
    local armed = false
    pcall(function() armed = Orders.threatOf(player) == true end)
    if armed then pcall(function() ProjectALife.NpcOpinion.note("robbery", record, player) end) end
    if ALifeMemory ~= nil then pcall(ALifeMemory.add, record, (armed and "the stranger made you hand over " or "you gave the stranger ") .. name) end
    local lines = armed and { "Here. Take it.", "Fine. It's yours.", "Okay, okay. Here." } or { "...Alright. Here.", "Fine. Take it." }
    local line = lines[r % #lines + 1]
    pcall(function() ProjectALife.Speech.say(shell, line, { face = player }) end)
    return line, "ordered"
end

function HG.install()
    if HG.__installed then return true end
    local Data, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.Talk
    if Data == nil or Talk == nil or type(Talk.respond) ~= "function" then return false end
    HG.__installed = true
    pcall(Data.load)
    for _, def in ipairs(HG.INTENTS) do pcall(Data.intent, def.id, def.prio, def.patterns) end
    local function start(record, shell, player, context, now_, text)
        local ok, line, why = pcall(HG.turn, player, { record = record, shell = shell }, text or "want to trade?")
        if ok and line ~= nil then return line, why end
        return nil
    end
    local origOffer = Talk.choiceHandlers.OFFER_ITEM
    Talk.choiceHandlers.OFFER_ITEM = function(record, shell, player, context, now_, text, asked)
        local ok, line, why = pcall(HG.gift, record, shell, player, text)
        if ok and line ~= nil then return line, why end
        if type(origOffer) == "function" then return origOffer(record, shell, player, context, now_, text, asked) end
        return nil
    end
    local origDemand = Talk.choiceHandlers.DEMAND_ITEMS
    Talk.choiceHandlers.DEMAND_ITEMS = function(record, shell, player, context, now_, text, asked)
        local ok, line, why = pcall(HG.demand, record, shell, player, context, now_, text)
        if ok and line ~= nil then return line, why end
        if not ok then print(TAG .. " demand failed: " .. tostring(line)) end
        if type(origDemand) == "function" then return origDemand(record, shell, player, context, now_, text, asked) end
        return nil
    end
    local orig = Talk.choiceHandlers.ASK_TRADE
    Talk.choiceHandlers.TRADE_OFFER = start
    Talk.choiceHandlers.ASK_TRADE = function(...)
        local line, why = start(...)
        if line ~= nil then return line, why end
        if type(orig) == "function" then return orig(...) end
        return nil
    end
    -- while a deal is open, everything you say to them is part of it
    local origRespond = Talk.respond
    Talk.respond = function(player, listener, text, nowArg, choiceIntent)
        if choiceIntent == nil and listener ~= nil and type(listener.record) == "table" and HG.active(listener.record.uid)
                and type(text) == "string" and text ~= "" then
            local ok, line, why = pcall(HG.turn, player, listener, text)
            if ok and line ~= nil then return line, why end
        end
        return origRespond(player, listener, text, nowArg, choiceIntent)
    end
    if ProjectALife.TalkIntents then ProjectALife.TalkIntents.cache = {} end
    print(TAG .. " ready (bargain in words, items really change hands)")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(HG.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
