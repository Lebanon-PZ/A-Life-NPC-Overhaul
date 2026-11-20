-- A-Life NPC Overhaul pre-1.0: MENTAL BREAKS (docs/PLAN-RIM.md #1). Someone at your camp who's been unhappy too long
-- loses it for a few hours, before it gets as far as walking out (unrest 60, ALifeLLMTalk_Dynamics).
-- Hourly: a person at home with unrest >= brkAt, no break in brkGapDays, rolls brkChance %. What they do comes from who
-- they are (A-Life personality lens):
--   tantrum  volatile / mean : tears through one of your drop points, dumps it on the floor (real items, nothing broken)
--   snap     mean / proud    : goes after a housemate with words (their bond sours, the other one is upset too)
--   binge    greedy          : eats 1-3 real things from your food drop points
--   drink    anyone          : drinks a bottle from your stores (real alcohol only) and gets drunk
--   hide     fearful         : shuts themselves in a room inside the base
--   wander   anyone          : walks to the edge of the base and sits there
--   sulk     proud           : sits down and won't work
-- It lasts brkHours. They do no camp work meanwhile; danger and the alarm still pull them out (ALifeTalk_Camp).
-- After: unrest -brkRelief (it's out of their system). Camp > People > "Talk X down" ends it early (by how they feel
-- about you). Letter + chronicle + their memory. No numbers anywhere.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeBreaks") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeBreaks = ALifeBreaks or {}
local B = ALifeBreaks
local TAG = "[ALifeBreaks]"
B.VERSION = "pre-1.0"
B.DEFAULTS = {
    brk = true,          -- people at your camp can break down when they're unhappy too long
    brkAt = 45,          -- how unhappy before it can happen (0-100 inside; walking out is 60)
    brkChance = 6,       -- % a game hour once they're there
    brkGapDays = 3,      -- days at least between two breaks of the same person
    brkHours = 5,        -- game hours a break lasts
    brkRelief = 25,      -- how much better they feel after (unrest)
    brkTantrum = true,   -- tantrums can dump a drop point on the floor
    brkBinge = true,     -- binges eat real food from your stores
    brkDumpMax = 15,     -- most items a tantrum throws on the floor
}
K.reg(B.DEFAULTS, {
    { "brk", "Camp: people break down when unhappy too long (tantrum, binge, hide...)" },
    { "brkAt", "Breaks: how unhappy before (walking out is 60)", { 30, 40, 45, 50, 55 } },
    { "brkChance", "Breaks: chance each hour once that unhappy (%)", { 2, 4, 6, 10, 15 } },
    { "brkGapDays", "Breaks: days at least between two of the same person", { 1, 2, 3, 5, 7 } },
    { "brkHours", "Breaks: game hours one lasts", { 2, 3, 5, 8, 12 } },
    { "brkRelief", "Breaks: how much better they feel after", { 10, 15, 25, 35, 50 } },
    { "brkTantrum", "Breaks: a tantrum can throw a drop point's things on the floor" },
    { "brkBinge", "Breaks: a binge eats real food from your stores" },
    { "brkDumpMax", "Breaks: most things one tantrum throws on the floor", { 5, 10, 15, 25, 40 } },
}, "Your camp and base")
B.stats = { started = 0, ended = 0, talkedDown = 0, dumped = 0, ate = 0, drank = 0 }
local function set(k) return K.set(B.DEFAULTS, k) end
local function num(k) return K.num(B.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function B.on() return set("brk") ~= false end
function B.store()
    local s = K.bucket("rimBreaks")
    s.on = type(s.on) == "table" and s.on or {}
    s.last = type(s.last) == "table" and s.last or {}
    return s
end
function B.active(uid) local b = B.store().on[tostring(uid)]; return type(b) == "table" and b or nil end

B.WORDS = {
    tantrum = { start = "%s has lost it. They're tearing through the stores.", line = { "I can't DO this anymore!", "What's the point of any of it?!", "Get out of my way!" } },
    snap = { start = "%s snapped at %s. Nasty words, the whole camp heard.", line = { "You think you're better than me? Look at you!", "Everything's always about you, isn't it?", "Don't you dare look at me like that." } },
    binge = { start = "%s is eating everything they can get their hands on.", line = { "Leave me alone. I'm hungry.", "Just let me have this." } },
    drink = { start = "%s found a bottle in the stores and isn't stopping.", line = { "One more. Just one more.", "Don't. Just don't." } },
    hide = { start = "%s locked themselves away inside and won't come out.", line = { "I can't be out there. Not today.", "Leave me alone. Please." } },
    wander = { start = "%s wandered off to the edge of camp and just sat down.", line = { "I need to be on my own for a while.", "Don't follow me." } },
    sulk = { start = "%s has stopped working. They're just sitting there.", line = { "Do it yourself.", "I'm done. For today, I'm done." } },
}
local function pickLine(list, seed) return list[(K.hash(seed) % #list) + 1] end

-- what kind of break: who they are + what's there (a dump needs a drop point, a binge food, a snap a housemate)
function B.kindFor(uid, player)
    local l = K.lens(uid)
    local function v(k) return math.max(0, tonumber(l[k]) or 0) end
    local w = {
        tantrum = set("brkTantrum") ~= false and (0.3 + v("volatile") * 3 + v("mean") * 2) or 0,
        snap = 0.3 + v("mean") * 3 + v("proud") * 2 + v("volatile"),
        binge = set("brkBinge") ~= false and (0.5 + v("greedy") * 2) or 0,
        drink = 0.4 + v("unhinged"),
        hide = 0.2 + v("fearful") * 3 + v("paranoid"),
        wander = 0.8 + v("romantic") * 0.5,
        sulk = 0.6 + v("proud"),
    }
    if B.dropFor("any") == nil then w.tantrum = 0 end
    if B.dropFor("food") == nil then w.binge = 0 end
    if #B.housemates(uid, player) == 0 then w.snap = 0 end
    local keys = { "tantrum", "snap", "binge", "drink", "hide", "wander", "sulk" }
    local total = 0
    for _, k in ipairs(keys) do total = total + w[k] end
    local r = K.rnd() * total
    for _, k in ipairs(keys) do
        if r < w[k] then return k end
        r = r - w[k]
    end
    return "sulk"
end
function B.housemates(uid, player)
    local out = {}
    for _, o in ipairs(K.people(player)) do if o ~= tostring(uid) and B.active(o) == nil then out[#out + 1] = o end end
    return out
end
-- a drop point: "food" (food that spoils / keeps), "any" (any category)
function B.dropFor(what)
    local M = K.M()
    if M == nil or not K.fn(M, "cpData") then return nil end
    local drops = M.cpData().drops or {}
    local cats = what == "food" and { "fresh", "cans" } or { "fresh", "cans", "meds", "clothes", "tools", "materials", "weapons", "ammo", "other" }
    local all = {}
    for _, c in ipairs(cats) do for _, p in ipairs(drops[c] or {}) do all[#all + 1] = p end end
    if #all == 0 then return nil end
    return all[1 + math.floor(K.rnd() * #all) % #all]
end
local function containerAt(p)
    local M = K.M()
    local H = M and M.cpH or nil
    if H == nil or p == nil then return nil, nil end
    local sq = H.sqAt(p.x, p.y, p.z)
    if sq == nil then return nil, nil end
    return H.containerOn(sq), sq
end
-- a square inside the base (indoors for "hide"), else the base edge (for "wander")
function B.spotFor(kind, uid, player)
    local b = K.base(player)
    local sh = K.shell(uid)
    local sx, sy, sz = K.pos(sh)
    if kind == "tantrum" then return B.dropFor("any") end
    if kind == "binge" then return B.dropFor("food") end
    if kind == "drink" then return B.dropFor("food") or B.dropFor("any") or (sx and { x = math.floor(sx), y = math.floor(sy), z = sz or 0 }) end
    if b == nil or tonumber(b.x1) == nil then return sx and { x = math.floor(sx), y = math.floor(sy), z = sz or 0 } or nil end
    if kind == "hide" then
        for _ = 1, 20 do
            local x = b.x1 + math.floor(K.rnd() * (b.x2 - b.x1 + 1))
            local y = b.y1 + math.floor(K.rnd() * (b.y2 - b.y1 + 1))
            local sq = nil
            pcall(function() sq = getCell():getGridSquare(x, y, b.z or 0) end)
            local inside = false
            pcall(function() inside = sq ~= nil and sq:isOutside() == false and sq:isFree(false) end)
            if inside then return { x = x, y = y, z = b.z or 0 } end
        end
        return { x = b.x, y = b.y, z = b.z or 0 }
    end
    if kind == "wander" then
        local side = math.floor(K.rnd() * 4)
        local t = K.rnd()
        if side == 0 then return { x = b.x1, y = math.floor(b.y1 + t * (b.y2 - b.y1)), z = b.z or 0 } end
        if side == 1 then return { x = b.x2, y = math.floor(b.y1 + t * (b.y2 - b.y1)), z = b.z or 0 } end
        if side == 2 then return { x = math.floor(b.x1 + t * (b.x2 - b.x1)), y = b.y1, z = b.z or 0 } end
        return { x = math.floor(b.x1 + t * (b.x2 - b.x1)), y = b.y2, z = b.z or 0 }
    end
    if sx then return { x = math.floor(sx), y = math.floor(sy), z = sz or 0 } end
    return { x = b.x, y = b.y, z = b.z or 0 }
end

function B.start(uid, kind, player)
    uid = tostring(uid)
    local s = B.store()
    if s.on[uid] then return false end
    kind = kind or B.kindFor(uid, player)
    local brk = { kind = kind, h = K.hours(), untilH = K.hours() + num("brkHours"), spot = B.spotFor(kind, uid, player) }
    if kind == "snap" then
        local mates = B.housemates(uid, player)
        if #mates == 0 then brk.kind, kind = "sulk", "sulk" else
            -- the one they like least
            table.sort(mates, function(a, c) return K.pairS(uid, a) < K.pairS(uid, c) end)
            brk.target = mates[1]
        end
    end
    s.on[uid] = brk
    s.last[uid] = K.hours()
    B.stats.started = B.stats.started + 1
    local name = K.first(uid)
    local words = B.WORDS[kind] or B.WORDS.sulk
    local text = brk.target and string.format(words.start, name, K.first(brk.target)) or string.format(words.start, name)
    K.letter(text, 230, 170, 120)
    K.say(uid, pickLine(words.line, uid .. K.day()))
    K.chron(text, name)
    K.campLog("break", text)
    K.mem(uid, "Lost it at camp (" .. kind .. ")")
    log(name .. " (" .. uid .. ") breaks: " .. kind .. " for " .. num("brkHours") .. " h")
    return true
end
function B.finish(uid, why)
    uid = tostring(uid)
    local s = B.store()
    local brk = s.on[uid]
    if brk == nil then return false end
    s.on[uid] = nil
    B.stats.ended = B.stats.ended + 1
    local relief = num("brkRelief")
    if why == "talked" then relief = math.floor(relief / 2) end
    K.addUnrest(uid, -relief)
    local name = K.first(uid)
    if why == "talked" then
        K.letter(name .. " let you talk them down.", 190, 210, 170)
    else
        K.letter(name .. " seems to have pulled themselves together.", 190, 200, 180)
    end
    K.say(uid, pickLine({ "...Sorry. I don't know what came over me.", "I'm alright now. I think.", "Don't look at me like that. I'm fine." }, uid .. K.hours()))
    log(name .. " break over (" .. tostring(why or "time") .. ")")
    return true
end

-- the one-time act at the spot: dump / eat / drink / insult
function B.act(brk, uid, player)
    if brk.acted then return end
    brk.acted = true
    if brk.kind == "tantrum" then
        local c, sq = containerAt(brk.spot)
        if c == nil then return end
        local list = {}
        pcall(function()
            local items = c:getItems()
            for i = 0, items:size() - 1 do if #list < num("brkDumpMax") then list[#list + 1] = items:get(i) end end
        end)
        local n = 0
        for _, it in ipairs(list) do
            local ok = pcall(function() c:DoRemoveItem(it); sq:AddWorldInventoryItem(it, K.rnd() * 0.8, K.rnd() * 0.8, 0) end)
            if ok then n = n + 1 end
        end
        B.stats.dumped = B.stats.dumped + n
        brk.dumped = n
    elseif brk.kind == "binge" or brk.kind == "drink" then
        local c = containerAt(brk.spot)
        if c == nil then return end
        local want = brk.kind == "binge" and (1 + math.floor(K.rnd() * 3)) or 1
        local list = {}
        pcall(function()
            local items = c:getItems()
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                local food = instanceof(it, "Food")
                local booze = false
                pcall(function() booze = it:isAlcoholic() == true end)
                local rotten = false
                pcall(function() rotten = it:isRotten() == true end)
                if #list < want and food and not rotten and ((brk.kind == "drink") == booze) then list[#list + 1] = it end
            end
        end)
        local n = 0
        for _, it in ipairs(list) do if pcall(function() c:DoRemoveItem(it) end) then n = n + 1 end end
        if brk.kind == "binge" then B.stats.ate = B.stats.ate + n else
            B.stats.drank = B.stats.drank + n
            local M = K.M()
            if n > 0 and M and K.fn(M, "addDrunk") then pcall(M.addDrunk, uid, 45) end
        end
        brk.used = n
    elseif brk.kind == "snap" and brk.target then
        K.pairBump(uid, brk.target, -15, "said ugly things in a breakdown")
        K.pairBump(brk.target, uid, -15, "said ugly things to me in a breakdown")
        K.addUnrest(brk.target, 5)
        K.say(brk.target, pickLine({ "What the hell is wrong with you?", "Back off. I mean it.", "Wow. Okay." }, brk.target .. K.hours()))
    end
end
B.ANIM = { tantrum = "shout", snap = "insult", binge = "eat", drink = "drink", hide = "sit_ground", wander = "sit_ground", sulk = "sit_wall" }

function B.hourly(player, h)
    if not B.on() or player == nil then return 0 end
    local s = B.store()
    local n = 0
    -- over?
    for uid, brk in pairs(s.on) do
        if K.hours() >= (tonumber(brk.untilH) or 0) or K.rec(uid) == nil then B.finish(uid, "time") end
    end
    for _, uid in ipairs(K.people(player)) do
        if s.on[uid] == nil and K.unrest(uid) >= num("brkAt") and K.hours() - (tonumber(s.last[uid]) or -1e9) >= num("brkGapDays") * 24 then
            if K.chance(num("brkChance")) and B.start(uid, nil, player) then n = n + 1 end
        end
    end
    return n
end

-- the camp job: holds them at the break spot
B.JOB = {
    kind = "rim_break", order = -3, -- after quarantine (-10), sick bay (-5) and the medic (-4); before the night watch
    pick = function(uid, shell, player, b, now)
        if not B.on() then return nil end
        local brk = B.active(uid)
        if brk == nil then return nil end
        if K.hours() >= (tonumber(brk.untilH) or 0) then B.finish(uid, "time"); return nil end
        if brk.spot == nil then brk.spot = B.spotFor(brk.kind, uid, player) end
        if brk.spot == nil then return nil end
        return { key = "brk:" .. tostring(uid), uid = tostring(uid), anim = B.ANIM[brk.kind] }
    end,
    spot = function(j)
        local brk = B.active(j.uid)
        if brk == nil then return nil end
        if brk.kind == "snap" and brk.target and not brk.acted then
            local x, y, z = K.pos(K.shell(brk.target))
            if x then return { x = math.floor(x), y = math.floor(y), z = z or 0 } end
        end
        return brk.spot
    end,
    ms = function(j) return 4000 end,
    run = function(j, uid, shell, player)
        local brk = B.active(uid)
        if brk == nil then return "done" end
        if K.hours() >= (tonumber(brk.untilH) or 0) then B.finish(uid, "time"); return "done" end
        B.act(brk, uid, player)
        if brk.kind == "snap" and brk.acted then brk.kind = "sulk"; j.anim = B.ANIM.sulk end
        return "again"
    end,
}

-- Camp > People > Talk X down (you, close by; works by how they feel about you)
function B.talkDown(uid, player)
    uid = tostring(uid)
    if B.active(uid) == nil or player == nil then return false end
    local px, py = K.pos(player)
    local sx, sy = K.pos(K.shell(uid))
    if px == nil or sx == nil or K.d2(px, py, sx, sy) > 5 * 5 then K.letter("Get closer to " .. K.first(uid) .. " first."); return false end
    local op = 0
    pcall(function() op = tonumber((K.PA().NpcOpinion.valueOf(K.rec(uid), player))) or 0 end)
    local odds = K.clamp(35 + op * 0.6, 5, 95)
    local s = B.store()
    local tries = s.on[uid].tries or 0
    s.on[uid].tries = tries + 1
    if tries >= 2 then odds = odds / 2 end
    if K.chance(odds) then B.stats.talkedDown = B.stats.talkedDown + 1; return B.finish(uid, "talked") end
    K.say(uid, pickLine({ "Not now. Just... not now.", "You don't get it. Leave me be.", "Talking won't fix this." }, uid .. K.hours()))
    return false
end
function B.menu(child, off, player)
    local s = B.store()
    local any = false
    for _ in pairs(s.on) do any = true; break end
    if not any then return end
    local m = child("People")
    for uid in pairs(s.on) do
        m:addOption("Talk " .. K.first(uid) .. " down", nil, function() K.run("brTalkDown", player, uid) end)
    end
end
-- pre-1.0 MP (P4): runs where the world is, as the player who clicked (B.talkDown checks they're close)
K.act("brTalkDown", function(player, uid) if uid == nil then return false end; return B.talkDown(tostring(uid), player) end)
-- the AI knows when they're mid-break
function B.extra(req, player, listener)
    local uid = listener and listener.record and tostring(listener.record.uid) or nil
    local brk = uid and B.active(uid) or nil
    if brk == nil then return nil end
    return "Right now you're having a breakdown (" .. brk.kind .. "): you're overwhelmed, short-tempered and not working. Act like it."
end

function B.install()
    K.addJob(B.JOB)
    if not B._menu then K.addMenu(function(child, off, player) return B.menu(child, off, player) end); B._menu = true end
    if not B._extra then K.addExtra(B.extra); B._extra = true end
    if not B._hourly then K.hourly(TAG, B.hourly); B._hourly = true end
    return true
end
pcall(B.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        pcall(B.install)
        log("ready v" .. B.VERSION .. ": mental breaks " .. (B.on() and "on" or "off") .. " (at " .. num("brkAt") .. ", " .. num("brkChance") .. " %/h)")
    end)
end
return B
