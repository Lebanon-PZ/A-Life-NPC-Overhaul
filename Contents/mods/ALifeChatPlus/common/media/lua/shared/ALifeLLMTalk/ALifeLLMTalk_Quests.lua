-- 0.8.6: RETIRED. Jobs now come from A-Life 1.5's own task board, made honest by ALifeQuests (shared). This file only
-- finishes jobs taken before 0.8.6 (without any made-up reward). "questsOld" (off) brings the old offers back.
-- A-Life Talk 0.5.0: jobs NPCs give you, checked against the real game.
-- Ask an NPC for work ("got any work?", "need help with anything?", "any jobs?"). If they like you well enough they
-- offer one that fits what is actually going on around them; say yes / no. Every job is verified by the game, not
-- by the AI:
--   fetch    bring N of an item their squad really lacks (A-Life ActivityPlanner needs) - counted in your inventory
--   deliver  carry a marked package to another living A-Life NPC - checked when you stand next to them with it
--   kill     an NPC they are enemies / rivals / at war with - checked by that NPC's death with you as the killer;
--            when there is nobody, "put down N of the dead" (your zombie kill counter)
--   escort   they walk with you (A-Life's own walk-with) to a real outpost / haven - checked by their position
--   clear    clear the zombies out of a real building - checked by counting zombies inside its bounds
-- Rewards: opinion (personality-scaled) plus an item from their stores; good word spreads as a rumor.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Quests") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Quests"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Quests") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function hash(s)
    local h = 5381
    s = tostring(s)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return h
end
local function Q()
    local data = M.store()
    data.quests = type(data.quests) == "table" and data.quests or {}
    local q = data.quests
    q.active = type(q.active) == "table" and q.active or {}
    q.offers = type(q.offers) == "table" and q.offers or {}
    q.done = type(q.done) == "table" and q.done or {}
    return q
end

M.questSettings = { minOpinion = 0, maxActive = 3, offerMinutes = 4, days = 3, cooldownH = 6, deliverMax = 900,
    escortMin = 120, escortMax = 1200, clearRange = 80 }
M.askWords = { "any work", "got work", "need help", "need anything", "any jobs", "a job", "got a job", "something to do",
    "can i help", "how can i help", "anything i can do", "favor", "favour", "task for me", "quest", "need a hand" }
M.yesWords = { "yes", "yeah", "yep", "sure", "ok", "okay", "deal", "i'll do it", "i will", "on it", "fine", "alright", "consider it done" }
M.noWords = { "no", "nope", "not now", "can't", "cannot", "pass", "later", "no thanks", "nah" }
local function hasWord(text, list)
    local t = " " .. string.lower(tostring(text or "")) .. " "
    t = string.gsub(t, "[%.,!%?;]", " ")
    for _, w in ipairs(list) do
        if string.find(t, "[^%a]" .. w .. "[^%a]") then return true end
    end
    return false
end

-- item helpers (every Java call is a method that exists on ItemContainer / InventoryItem in B42)
function M.itemExists(fullType)
    local ok, item = pcall(function() return getScriptManager():FindItem(fullType) end)
    return ok and item ~= nil
end
function M.firstItem(list)
    for _, t in ipairs(list) do if M.itemExists(t) then return t end end
    return nil
end
function M.countItem(player, fullType)
    local ok, n = pcall(function() return player:getInventory():getCountTypeRecurse(fullType) end)
    return ok and tonumber(n) or 0
end
function M.takeItems(player, fullType, n)
    local taken = 0
    for _ = 1, n do
        local ok = pcall(function()
            local it = player:getInventory():getFirstTypeRecurse(fullType)
            if it == nil then error("none") end
            it:getContainer():Remove(it)
        end)
        if not ok then break end
        taken = taken + 1
    end
    return taken
end
function M.notify(player, text)
    if ALifeSide.mpServer() then pcall(ALifeSide.outLetter, player, text, 214, 178, 96); return end -- MP: to that player's machine
    local ok = pcall(ALifeLetter, player, text, 214, 178, 96)
    if not ok then pcall(function() player:addLineChatElement(text, 0.84, 0.7, 0.38) end) end
end

M.fetchNeeds = {
    food = { label = "cans of food", items = { "Base.TinnedBeans", "Base.CannedChili", "Base.CannedCorn", "Base.TinnedSoup" }, n = 3 },
    water = { label = "bottles of water", items = { "Base.WaterBottleFull", "Base.WaterBottle", "Base.PopBottle" }, n = 2 },
    meds = { label = "bandages", items = { "Base.Bandage", "Base.AlcoholBandage" }, n = 3 },
    ammo = { label = "boxes of ammo", items = { "Base.Bullets9mmBox", "Base.ShotgunShellsBox", "Base.Bullets38Box" }, n = 1 },
}
M.rewards = { { "Base.Bullets9mmBox", "a box of 9mm" }, { "Base.TinnedBeans", "a can of beans" }, { "Base.Pills", "painkillers" },
    { "Base.Bandage", "a bandage" }, { "Base.CannedChili", "a can of chili" }, { "Base.WhiskeyFull", "a bottle of whiskey" },
    { "Base.Cigarettes", "a pack of cigarettes" }, { "Base.HandAxe", "a hand axe" }, { "Base.Battery", "batteries" } }

local function squadNeeds(record)
    local pa = PA()
    if not (fn(pa.ActivityPlanner, "needsOf") and fn(pa.SquadLedger, "peek")) then return nil end
    local sid = record.squadId or (type(record.memory) == "table" and record.memory.squadId) or nil
    local squad = sid and pa.SquadLedger.peek(sid) or nil
    if squad == nil then return nil end
    local ok, needs = pcall(pa.ActivityPlanner.needsOf, squad)
    return ok and type(needs) == "table" and needs or nil
end

local function enemyOf(uid)
    if not M.tiesOf then return nil end
    local ok, ties = pcall(M.tiesOf, uid)
    if not ok or type(ties) ~= "table" then return nil end
    local best, bs = nil, 0
    for _, t in ipairs(ties) do
        local bad = t.type == "enemy" or t.type == "nemesis" or t.type == "rival"
        if bad and not t.dead and (tonumber(t.score) or 0) < bs then
            local r = rec(t.uid)
            if r and r.lifecycle ~= "dead" then best, bs = t.uid, tonumber(t.score) or 0 end
        end
    end
    return best
end
local function someoneFar(record, minD, maxD)
    local pa = PA()
    local x, y = tonumber(record.x), tonumber(record.y)
    if x == nil or not fn(pa.ActorRegistry, "each") then return nil end
    local pick, k = nil, -1
    pcall(pa.ActorRegistry.each, function(r)
        if r.uid ~= record.uid and r.lifecycle ~= "dead" and tonumber(r.x) then
            local d = math.sqrt((r.x - x) ^ 2 + (r.y - y) ^ 2)
            if d >= minD and d <= maxD then
                local h = hash(tostring(r.uid) .. tostring(record.uid))
                if h > k then pick, k = r, h end
            end
        end
        return false
    end)
    return pick
end
local function placeFor(record)
    local pa = PA()
    local x, y = tonumber(record.x), tonumber(record.y)
    if x == nil then return nil end
    local best = nil
    pcall(function()
        for _, site in ipairs(fn(pa.OutpostRegistry, "list") and pa.OutpostRegistry.list() or {}) do
            local d = math.sqrt((site.x - x) ^ 2 + (site.y - y) ^ 2)
            if d >= M.questSettings.escortMin and d <= M.questSettings.escortMax and (best == nil or d < best.d) then
                best = { x = site.x, y = site.y, d = d, label = M.townAt and M.townAt(site.x, site.y) or "the outpost" }
            end
        end
    end)
    if best == nil and fn(pa.Havens, "homeOf") then
        local ok, h = pcall(pa.Havens.homeOf, record)
        if ok and type(h) == "table" and tonumber(h.x) then
            local d = math.sqrt((h.x - x) ^ 2 + (h.y - y) ^ 2)
            if d >= 60 then best = { x = h.x, y = h.y, d = d, label = "their place" } end
        end
    end
    return best
end
local function buildingNear(player)
    local best = nil
    pcall(function()
        local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
        local cell = getCell()
        for r = 10, M.questSettings.clearRange, 10 do
            for _, d in ipairs({ { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r }, { r, r }, { -r, -r }, { r, -r }, { -r, r } }) do
                local sq = cell:getGridSquare(px + d[1], py + d[2], 0)
                local b = sq and sq:getBuilding() or nil
                if b ~= nil then
                    local def = b:getDef()
                    if def ~= nil then
                        best = { x = def:getX(), y = def:getY(), w = def:getW(), h = def:getH() }
                        return
                    end
                end
            end
        end
    end)
    return best
end

-- choose a job that fits the real situation
function M.makeQuest(listener, player)
    local record = listener.record
    local uid = tostring(record.uid)
    local seed = hash(uid .. tostring(math.floor(hours())))
    local options = {}
    local needs = squadNeeds(record) or {}
    for key, spec in pairs(M.fetchNeeds) do
        local item = M.firstItem(spec.items)
        if item and (needs[key] or (seed % 4 == 0)) then
            options[#options + 1] = { kind = "fetch", item = item, n = spec.n, label = spec.label,
                text = "bring " .. spec.n .. " " .. spec.label .. (needs[key] and " - their people are running low" or "") }
        end
    end
    local foe = enemyOf(uid)
    if foe then
        options[#options + 1] = { kind = "kill", target = foe, text = "deal with " .. nameOf(rec(foe)) .. ", who they have bad blood with" }
    else
        local n = 15 + seed % 4 * 5
        local kills = 0
        pcall(function() kills = player:getZombieKills() end)
        options[#options + 1] = { kind = "zombies", n = n, base = kills, text = "put down " .. n .. " of the dead around here" }
    end
    local far = someoneFar(record, 40, M.questSettings.deliverMax)
    local pkg = M.firstItem({ "Base.Envelope", "Base.Note", "Base.SheetPaper2", "Base.Notebook" })
    if far and pkg then
        options[#options + 1] = { kind = "deliver", target = tostring(far.uid), item = pkg,
            text = "take a package to " .. nameOf(far) .. (M.townAt and M.townAt(far.x, far.y) and (" near " .. M.townAt(far.x, far.y)) or "") }
    end
    local place = placeFor(record)
    if place then
        options[#options + 1] = { kind = "escort", x = math.floor(place.x), y = math.floor(place.y), label = place.label,
            text = "walk them safely to " .. tostring(place.label) }
    end
    local b = buildingNear(player)
    if b then
        options[#options + 1] = { kind = "clear", b = b, text = "clear the dead out of the building at " .. b.x .. "," .. b.y }
    end
    if #options == 0 then return nil end
    local q = options[seed % #options + 1]
    local rw = nil
    for i = 0, #M.rewards - 1 do
        local cand = M.rewards[(seed + i) % #M.rewards + 1]
        if M.itemExists(cand[1]) then rw = cand; break end
    end
    q.giver = uid
    q.reward = rw and { rw[1], rw[2] } or nil
    q.opinion = 8 + seed % 5
    q.id = uid .. "-" .. tostring(math.floor(hours() * 10))
    return q
end

function M.questFor(uid)
    for _, q in ipairs(Q().active) do if q.giver == tostring(uid) then return q end end
    return nil
end

function M.acceptQuest(player, uid)
    local qs = Q()
    local offer = qs.offers[tostring(uid)]
    if offer == nil then return nil end
    qs.offers[tostring(uid)] = nil
    local q = offer.q
    q.startH = hours()
    q.dueH = q.startH + M.questSettings.days * 24
    if q.kind == "deliver" then
        pcall(function()
            local it = player:getInventory():AddItem(q.item)
            it:getModData().altQuest = q.id
            it:setName("Package for " .. nameOf(rec(q.target)))
        end)
    elseif q.kind == "escort" then
        if M.followAsk then pcall(M.followAsk, player, uid) end
    end
    qs.active[#qs.active + 1] = q
    M.notify(player, "Job: " .. q.text)
    log("quest accepted: " .. q.kind .. " for " .. nameOf(rec(uid)) .. " (" .. q.text .. ")")
    return q
end

local function find(uid, list)
    local pa = PA()
    for _, l in ipairs(list or {}) do if tostring(l.record.uid) == tostring(uid) then return l end end
    return nil
end

function M.completeQuest(player, q, i, how)
    local qs = Q()
    table.remove(qs.active, i)
    qs.done[#qs.done + 1] = { id = q.id, kind = q.kind, giver = q.giver, text = q.text, h = hours(), ok = how ~= "failed" }
    while #qs.done > 30 do table.remove(qs.done, 1) end
    local r = rec(q.giver)
    local pa = PA()
    if how == "failed" then
        if r and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, r, player, -4, "Let them down on a job: " .. q.text) end
        M.notify(player, "Job failed: " .. q.text)
        log("quest failed: " .. q.kind)
        return
    end
    if r and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, r, player, q.opinion or 8, "Did a job for them: " .. q.text) end
    q.reward = nil -- 0.8.6: no reward made from nothing (jobs now run on A-Life's board, paid from the giver's own pack)
    if M.feel then M.feel(q.giver, "gratitude", 0.5, "you did what you said") end
    if M.addDeed then M.addDeed("quest", "the stranger did a job for " .. nameOf(r) .. " and saw it through", 4, { q.giver }) end
    M.notify(player, "Job done: " .. q.text .. (q.reward and (" - reward: " .. q.reward[2]) or ""))
    log("quest done: " .. q.kind .. " for " .. nameOf(r))
    local l = find(q.giver, M.nearbyNpcs(player:getX(), player:getY(), player:getZ(), 10))
    if l and M.react then
        M.react("quest", l, player, { what = "They finished the job you gave them (" .. q.text .. ")."
            .. (q.reward and (" You hand over " .. q.reward[2] .. ".") or ""), style = "short thanks in your own voice", maxWords = 18 },
            { key = "quest:" .. q.giver, keyCooldownMs = 4000, urgent = true, face = "player" })
    end
end

-- verification against the game state
function M.questCheck(player)
    local qs = Q()
    if #qs.active == 0 then return end
    local h = hours()
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local near = M.nearbyNpcs(px, py, pz, 6) or {}
    for i = #qs.active, 1, -1 do
        local q = qs.active[i]
        local giver = rec(q.giver)
        local giverNear = find(q.giver, near)
        local done, failed = false, false
        if giver == nil or giver.lifecycle == "dead" then failed = q.kind == "escort"; if not failed then q.giverDead = true end end
        if q.kind == "fetch" and giverNear and M.countItem(player, q.item) >= q.n then
            M.takeItems(player, q.item, q.n); done = true
        elseif q.kind == "zombies" then
            local k = 0
            pcall(function() k = player:getZombieKills() end)
            q.progress = k - (q.base or k)
            if q.progress >= q.n then q.ready = true end
            done = q.ready and giverNear ~= nil
        elseif q.kind == "kill" then
            local t = rec(q.target)
            if t == nil or t.lifecycle == "dead" then q.ready = true end
            done = q.ready and giverNear ~= nil
        elseif q.kind == "deliver" then
            local tl = find(q.target, near)
            if tl then
                local ok = pcall(function()
                    local items = player:getInventory():getItemsFromFullType(q.item)
                    for j = 0, items:size() - 1 do
                        local it = items:get(j)
                        if it:getModData().altQuest == q.id then it:getContainer():Remove(it); return end
                    end
                    error("no package")
                end)
                if ok then
                    done = true
                    if M.react then M.react("quest", tl, player, { what = "The newcomer hands you a package sent by " .. nameOf(giver) .. ".",
                        style = "short, surprised or grateful", maxWords = 14 }, { key = "pkg:" .. q.target, urgent = true, face = "player" }) end
                end
            end
            local t = rec(q.target)
            if t and t.lifecycle == "dead" then failed = true end
        elseif q.kind == "escort" then
            local sh = nil
            local pa = PA()
            pcall(function() sh = pa.Watchdog.bindings[q.giver].shell end)
            if sh then
                local ok, d = pcall(function() return math.sqrt((sh:getX() - q.x) ^ 2 + (sh:getY() - q.y) ^ 2) end)
                if ok and d < 15 then done = true end
            end
        elseif q.kind == "clear" then
            local b = q.b
            local inside = px >= b.x - 2 and px <= b.x + b.w + 2 and py >= b.y - 2 and py <= b.y + b.h + 2
            if inside then q.visited = true end
            if q.visited and math.abs(px - (b.x + b.w / 2)) < 40 and math.abs(py - (b.y + b.h / 2)) < 40 then
                local count = 0
                pcall(function()
                    local zs = getCell():getZombieList()
                    for j = 0, zs:size() - 1 do
                        local z = zs:get(j)
                        local zx, zy = z:getX(), z:getY()
                        if zx >= b.x and zx <= b.x + b.w and zy >= b.y and zy <= b.y + b.h and not z:isDead() then count = count + 1 end
                    end
                end)
                q.left = count
                if count == 0 then q.ready = true end
            end
            done = q.ready and giverNear ~= nil
        end
        if done then M.completeQuest(player, q, i, "done")
        elseif failed or h > (q.dueH or 1e18) then M.completeQuest(player, q, i, "failed") end
    end
end

-- conversation: asking for work, accepting, declining; the AI voices the offer from req.quest
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.quests == false or not (listener and listener.record) then return end
    local uid = tostring(listener.record.uid)
    local qs = Q()
    local said = type(req.said) == "string" and req.said or nil
    local offer = qs.offers[uid]
    if offer and hours() - offer.h > M.questSettings.offerMinutes / 60 * 6 then qs.offers[uid] = nil; offer = nil end
    local active = M.questFor(uid)
    if said and offer then
        if hasWord(said, M.noWords) and not hasWord(said, { "no problem" }) then
            qs.offers[uid] = nil
            req.quest = { declined = offer.q.text }
            return
        elseif hasWord(said, M.yesWords) then
            local q = M.acceptQuest(player, uid)
            if q then req.quest = { accepted = q.text, reward = q.reward and q.reward[2] or nil } end
            return
        end
    end
    -- 0.8.6: new jobs come from A-Life's task board (ALifeQuests: real pay, real targets). This module only lets
    -- jobs taken before 0.8.6 finish; it offers no new ones.
    if said and hasWord(said, M.askWords) and not active and not offer and M.settings.questsOld == true then
        local pa = PA()
        local op = 0
        if fn(pa.NpcOpinion, "valueOf") then pcall(function() op = tonumber((pa.NpcOpinion.valueOf(listener.record, player))) or 0 end) end
        if op < M.questSettings.minOpinion then req.quest = { refuse = "you don't trust them enough to give them a job" }; return end
        if #qs.active >= M.questSettings.maxActive then req.quest = { refuse = "they already have their hands full with other jobs" }; return end
        local q = M.makeQuest(listener, player)
        if q then
            qs.offers[uid] = { q = q, h = hours() }
            req.quest = { offer = q.text, reward = q.reward and q.reward[2] or nil }
            log("quest offered: " .. q.kind .. " by " .. nameOf(listener.record))
        end
        return
    end
    if active then
        local prog = nil
        if active.kind == "zombies" then prog = tostring(active.progress or 0) .. " of " .. active.n .. " so far" end
        if active.kind == "clear" and active.left then prog = tostring(active.left) .. " still inside" end
        if active.ready then prog = "done - they can claim the reward from you" end
        req.quest = { active = active.text, progress = prog }
    end
end)

if M.settings.quests == nil then M.settings.quests = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "quests" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "quests" end
end
M.eventModes.quest = M.eventModes.quest or { request = M.reactRequest, finish = M.reactFinish }
local n = 0
if type(Events) == "table" and Events.OnTick then
    ALifeHealth.tickAdd("ALifeLLMTalk_Quests", function()
        n = n + 1
        if n % 120 ~= 0 or M.settings.quests == false or not M.worldHere() then return end
        M.eachPlayer(function(p) local ok, e = pcall(M.questCheck, p); if not ok then log("quest check error: " .. tostring(e)) end end) -- MP: every player's
    end)
end
return M
