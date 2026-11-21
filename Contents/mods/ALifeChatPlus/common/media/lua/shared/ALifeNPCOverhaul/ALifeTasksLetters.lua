-- A-Life NPC Overhaul 0.7.8: CONTACTS, TASKS, LETTERS AND THINGS PEOPLE SAY ABOUT YOU (hook in, never replace).
--   * CONTACTS: people you've really talked to go into A-Life 1.5's contacts book (name, group, where you met), and
--     the Louisville National Guard once you've raised them on the restricted channel.
--   * TASKS: what this mod already asks of you shows in A-Life's journal Tasks tab, with the tracker and the arrow:
--     a supply flight on its way (be at your drop point), traders waiting at your place, someone missing you went to
--     look for, tribute that's due, and letters to deliver.
--   * ROADMAP, "IF I DON'T MAKE IT BACK": before a raid, or a run away from you, someone close to you may hand you a
--     letter for the person they love most. Come back alive and they take it back. Don't, and delivering it is a task:
--     find that person and give it to them. They'll remember who brought it.
--   * ROADMAP, HIDDEN ACHIEVEMENTS: nothing pops up. What you've done is told around like everything else, and people
--     who've heard say it to your face ("you're the one who drops the walking tanks").
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "tasksLetters" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeTasksLetters") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeTasksLetters = ALifeTasksLetters or {}
local L = ALifeTasksLetters
local TAG = "[ALifeTasksLetters]"
L.VERSION = ALifeSide.MOD_VERSION
L.cfg = { letterChance = 0.35, letterLove = 2, giveTiles = 3, keepH = 24, maxHeld = 3 }
L.TITLES = {
    { kind = "juggernaut", title = "the one who drops the walking tanks", w = 3 },
    { kind = "helidown", title = "the one who shot a helicopter out of the sky", w = -1 },
    { kind = "letter", title = "the one who carries the dead's last letters", w = 3 },
    { kind = "tradition", match = "wounded", title = "the one whose people stop for the wounded", w = 3 },
    { kind = "tradition", match = "quarter", title = "the one who gives no quarter", w = -2 },
    { kind = "tradition", match = "walking", title = "the one who walks past the dying", w = -2 },
}
L.LETTERS = {
    partner = { "{to}, if you're reading this, I didn't make it back. You were the best thing in all of this. Keep going. Don't stop for me.",
        "{to}. I'm sorry. I meant to come back. Every day with you was worth the rest of it." },
    family = { "{to}, if this reached you, I'm gone. Look after yourself. Don't take stupid risks. I love you, I always did.",
        "{to}. Don't come looking for me. Remember the good days. I'm proud of you." },
    friend = { "{to}, if you're reading this, you were right and I should have stayed. Drink one for me if you ever find any.",
        "{to}. You kept me going out here. Thanks for that. Don't waste what's left." },
}
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { contacts = 0, tasks = 0, written = 0, returned = 0, due = 0, delivered = 0, deeds = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(seed) return (hash(seed) % 10000) / 10000 end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end
local function record(uid)
    local pa = PA()
    if uid == nil or pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function shellOf(uid)
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "shellFor") then return nil end
    local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
    return ok and s or nil
end
local function nameOf(r)
    local pa = PA()
    if r ~= nil and pa ~= nil and fn(pa.Names, "of") then local ok, n = pcall(pa.Names.of, r); if ok and n then return tostring(n) end end
    return "someone"
end
local function first(n) return string.match(tostring(n), "^(%S+)") or tostring(n) end
local function xyOf(o) local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
-- 0.7.10: the letter is a real piece of paper in your pack (paper has no gameplay value: it may be made)
L.PAPER = "Base.Note"
function L.giveLetterItem(player, letter)
    local ok = pcall(function()
        local item = instanceItem(L.PAPER)
        if item == nil then return end
        item:setName("Letter for " .. letter.toName .. " (from " .. letter.fromName .. ")")
        item:getModData().ALCPLetter = letter.id
        player:getInventory():AddItem(item)
        letter.item = true
    end)
    return ok and letter.item == true
end
function L.letterItem(player, letter)
    local found = nil
    pcall(function()
        local items = player:getInventory():getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local md = it:getModData()
            if md and md.ALCPLetter == letter.id then found = it end
        end
    end)
    return found
end
function L.takeLetterItem(player, letter)
    local it = L.letterItem(player, letter)
    if it == nil then return false end
    return pcall(function() player:getInventory():Remove(it) end)
end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.tasksLetters == false)
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
    if tbl[name .. "__TasksLetters"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__TasksLetters"] = orig
    L.hooked[hookName] = true
    return true
end

-- something people tell each other about you (the existing rumor system carries it)
function L.deed(kind, text, w, witnesses, x, y)
    local m = M()
    if not fn(m, "addDeed") then return end
    pcall(m.addDeed, kind, text, w, witnesses or {}, x, y)
    L.metrics.deeds = L.metrics.deeds + 1
end

----------------------------------------------------------------------------------------------------------------
-- 1. contacts
----------------------------------------------------------------------------------------------------------------
local function contacts()
    local c = PA() and PA().Contacts
    if not fn(c, "add") or not fn(c, "enabled") then return nil end
    local ok, on = pcall(c.enabled)
    return ok and on and c or nil
end
function L.addContact(uid)
    local c = contacts()
    local r = record(uid)
    local p = playerOf()
    if c == nil or r == nil or p == nil then return false end
    local pa = PA()
    local faction = nil
    if fn(pa.Catalog, "faction") then
        pcall(function() local f = pa.Catalog.faction(r.factionId); if f and f.general and f.general.name then faction = f.general.name end end)
    end
    local x, y = xyOf(shellOf(uid))
    local m = M()
    local where = (x and fn(m, "placeName")) and m.placeName(x, y, 0) or nil
    local ok, status = pcall(c.add, { uid = tostring(uid), name = nameOf(r), faction = faction, factionId = r.factionId, source = "overhaul",
        seen = { text = where and ("Talked " .. tostring(where)) or "Talked", x = x, y = y } }, p)
    if ok and status == "added" then L.metrics.contacts = L.metrics.contacts + 1 end
    return ok
end
function L.hookTalked(m)
    return wrap(m, "noteTalked", "noteTalked", function(orig)
        return function(uid, op, ...)
            local r = orig(uid, op, ...)
            if L.enabled() then L.guard("contacts", L.addContact, uid) end
            return r
        end
    end)
end
function L.hookGuardRadio(m)
    return wrap(m, "alCallFlight", "guardContact", function(orig)
        return function(player, ...)
            local ok = orig(player, ...)
            if ok == true and L.enabled() then
                L.guard("guardContact", function()
                    local c = contacts()
                    if c then c.add({ name = tostring(m.apName or "Louisville National Guard"), faction = tostring(m.apName or "Louisville National Guard"),
                        role = "restricted channel", source = "radio", notes = "Answers on the restricted channel. Never says where they are." }, player) end
                end)
            end
            return ok
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 2. letters
----------------------------------------------------------------------------------------------------------------
function L.letters()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "letters")
    if not ok or type(b) ~= "table" then return nil end
    b.list = type(b.list) == "table" and b.list or {}
    return b
end
local function held(b)
    local n = 0
    for _, l in ipairs(b.list) do if l.state == "held" or l.state == "due" then n = n + 1 end end
    return n
end
-- your people (party + camp), the ones who might write
function L.yourPeople(player)
    local m, seen, out = M(), {}, {}
    local function add(list) for _, u in ipairs(list or {}) do u = tostring(type(u) == "table" and (u.uid or u) or u); if not seen[u] then seen[u] = true; out[#out + 1] = u end end end
    if fn(m, "partyMembers") then local ok, l = pcall(m.partyMembers, player); if ok then add(l) end end
    if fn(m, "cpPeople") then local ok, l = pcall(m.cpPeople, player); if ok then add(l) end end
    return out, seen
end
function L.close(player, uid)
    local B = ALifeBonds
    if not fn(B, "keyOf") or not fn(B, "row") or not fn(B, "stageOf") then return false end
    local key = B.keyOf(player)
    local r = key and B.row(key, tostring(uid), false) or nil
    return r ~= nil and B.stageOf(r.l) >= L.cfg.letterLove
end
function L.maybeWrite(player, uid, why)
    local b = L.letters()
    local m = M()
    if b == nil or not fn(m, "lovedOne") then return nil end
    uid = tostring(uid)
    for _, l in ipairs(b.list) do if l.from == uid and (l.state == "held" or l.state == "due") then return nil end end
    if held(b) >= L.cfg.maxHeld or not L.close(player, uid) then return nil end
    local h = hours()
    if roll(uid .. ":" .. math.floor(h / 24) .. ":" .. why) >= L.cfg.letterChance then return nil end
    local x, y = xyOf(shellOf(uid))
    local ok, to = pcall(m.lovedOne, uid, x, y)
    if not ok or type(to) ~= "table" or to.uid == nil then return nil end
    local fr = record(uid)
    local kind = (to.type == "partner" or to.type == "crush") and "partner" or (to.type == "family" and "family" or "friend")
    local pool = L.LETTERS[kind]
    local text = string.gsub(pool[(hash(uid .. to.uid) % #pool) + 1], "{to}", first(to.name))
    local letter = { id = uid .. ":" .. math.floor(h * 10), from = uid, fromName = first(nameOf(fr)), to = tostring(to.uid), toName = first(to.name),
        kind = kind, text = text, h = h, why = why, state = "held" }
    b.list[#b.list + 1] = letter
    L.metrics.written = L.metrics.written + 1
    L.giveLetterItem(player, letter)
    if fn(m, "keyMem") then pcall(m.keyMem, uid, "letter", "Gave the newcomer a letter for " .. letter.toName .. ", in case I don't make it back") end
    if type(ALifeLetter) == "function" then pcall(ALifeLetter, player, letter.fromName .. " pressed a folded letter into your hand: \"If I don't make it back, give this to " .. letter.toName .. ".\"") end
    log(letter.fromName .. " wrote a letter for " .. letter.toName .. " (" .. why .. ")")
    return letter
end
function L.onRaid(player)
    local people = L.yourPeople(player)
    for _, uid in ipairs(people) do L.maybeWrite(player, uid, "raid") end
end
function L.hookRaid(R)
    return wrap(R, "start", "raidStart", function(orig)
        return function(player, overrides, force, heldArg, ...)
            local ok, id = orig(player, overrides, force, heldArg, ...)
            if ok == true and L.enabled() then L.guard("raidLetters", L.onRaid, player) end
            return ok, id
        end
    end)
end
function L.hookLeave(m)
    return wrap(m, "lvSend", "lvSend", function(orig)
        return function(uid, o, ...)
            local ok = orig(uid, o, ...)
            if ok and L.enabled() and type(o) == "table" and not string.find(tostring(o.tag or ""), "caravan", 1, true) then
                local p = playerOf()
                local _, mine = L.yourPeople(p)
                if mine[tostring(uid)] then L.guard("runLetters", L.maybeWrite, p, uid, "run") end
            end
            return ok
        end
    end)
end
-- every ten minutes: back alive (they take it back), dead (it's yours to deliver), delivered
function L.letterStep()
    local b = L.letters()
    if b == nil then return end
    local p = playerOf()
    local px, py = xyOf(p)
    local h = hours()
    local m, B = M(), ALifeBonds
    for _, l in ipairs(b.list) do
        if l.state == "held" then
            local r = record(l.from)
            if r == nil or r.lifecycle == "dead" then
                l.state = "due"; l.dueH = h
                L.metrics.due = L.metrics.due + 1
                if type(ALifeLetter) == "function" then pcall(ALifeLetter, p, l.fromName .. " didn't make it back. You still have the letter for " .. l.toName .. ".") end
                log(l.fromName .. " is dead: the letter for " .. l.toName .. " is yours to deliver")
            elseif h - l.h >= L.cfg.keepH then
                local x, y = xyOf(shellOf(l.from))
                if x and px and d2(x, y, px, py) <= 30 * 30 then
                    l.state = "returned"
                    L.metrics.returned = L.metrics.returned + 1
                    if l.item then L.takeLetterItem(p, l) end
                    if fn(m, "keyMem") then pcall(m.keyMem, l.from, "letter", "Took my letter back from the newcomer - didn't need it this time") end
                end
            end
        elseif l.state == "due" then
            local tr = record(l.to)
            if tr == nil or tr.lifecycle == "dead" then
                l.state = "kept"
                log("the letter for " .. l.toName .. " can't be delivered any more (they're gone too)")
            elseif px then
                local sh = shellOf(l.to)
                local x, y = xyOf(sh)
                -- you need the letter itself (lose it and you've lost their last words)
                local have = not l.item or L.letterItem(p, l) ~= nil
                if x and have and d2(x, y, px, py) <= L.cfg.giveTiles * L.cfg.giveTiles then
                    if l.item then L.takeLetterItem(p, l) end
                    l.state = "delivered"; l.doneH = h
                    L.metrics.delivered = L.metrics.delivered + 1
                    if fn(m, "keyMem") then pcall(m.keyMem, l.to, "letter", "The newcomer brought me " .. l.fromName .. "'s last letter: \"" .. string.sub(l.text, 1, 90) .. "\"") end
                    if fn(m, "logInteraction") then pcall(m.logInteraction, l.to, "You gave them " .. l.fromName .. "'s last letter", nil, nil, "event") end
                    if fn(B, "keyOf") and fn(B, "change") then pcall(B.change, B.keyOf(p), l.to, 8, 0, 0, { player = p, record = tr }) end
                    if type(ALifeLetter) == "function" then pcall(ALifeLetter, p, "You gave " .. l.toName .. " the letter from " .. l.fromName .. ".") end
                    L.deed("letter", "the stranger carried " .. l.fromName .. "'s last letter to " .. l.toName, 4, { l.to }, x, y)
                    log("letter delivered to " .. l.toName)
                end
            end
        end
    end
    while #b.list > 30 do table.remove(b.list, 1) end
end

----------------------------------------------------------------------------------------------------------------
-- 3. tasks in A-Life's journal
----------------------------------------------------------------------------------------------------------------
local function stage(text, detail, done, current) return { text = text, detail = detail or "", done = done == true, current = current == true } end
local function view(id, title, summary, stages, target, glyph)
    return { id = id, title = title, summary = summary, state = "active", stage = 1, stages = stages, target = target, log = {}, glyph = glyph, overhaul = true }
end
local function hoursWord(n) n = math.max(0, math.floor((tonumber(n) or 0) + 0.5)); return n <= 1 and "about an hour" or ("about " .. n .. " hours") end

function L.ourTasks()
    local out = {}
    local m = M()
    if type(m) ~= "table" then return out end
    local h = hours()
    -- supply flight on its way
    if fn(m, "apStore") then
        local ok, s = pcall(m.apStore)
        local f = ok and type(s) == "table" and s.flight or nil
        if type(f) == "table" and tonumber(f.x) then
            out[#out + 1] = view("ovh_flight", "Supply flight", "The " .. tostring(m.apName or "Louisville National Guard") .. " is flying in",
                { stage("Be at your drop point", "Wheels down in " .. hoursWord((tonumber(f.at) or h) - h)) }, { x = f.x, y = f.y }, "supply")
        end
    end
    -- traders waiting at your place
    if fn(m, "nbStore") then
        local ok, st = pcall(m.nbStore)
        for id, v in pairs(ok and type(st) == "table" and type(st.ovVisits) == "table" and st.ovVisits or {}) do
            if type(v) == "table" and tonumber(v.x) then
                out[#out + 1] = view("ovh_trade_" .. tostring(id), "Traders at your place", "Traders from " .. tostring(v.name or "a group"),
                    { stage("Talk to them to trade", "They leave in " .. hoursWord((tonumber(v.leaveH) or h) - h)) }, { x = v.x, y = v.y }, "supply")
            end
        end
    end
    -- someone missing you went to look for
    if fn(m, "msStore") then
        local ok, st = pcall(m.msStore)
        for uid, c in pairs(ok and type(st) == "table" and st or {}) do
            if type(c) == "table" and c.state == "looking" and tonumber(c.x) then
                local r = (m.msCfg and m.msCfg.fuzz) or 150
                local jx = ((ALifeRoll01 and ALifeRoll01(c.uid .. "#mx") or 0.5) - 0.5) * 2 * r
                local jy = ((ALifeRoll01 and ALifeRoll01(c.uid .. "#my") or 0.5) - 0.5) * 2 * r
                local where = (c.dir and ("headed " .. c.dir) or "somewhere") .. (c.town and (", toward " .. c.town) or "")
                out[#out + 1] = view("ovh_missing_" .. tostring(uid), "Find " .. tostring(c.n or "them"), "Nobody's seen them since they went out",
                    { stage("Search the rough area", "They were " .. where .. ". Get close and you'll find them.") },
                    { x = math.floor(c.x + jx), y = math.floor(c.y + jy) }, "investigate")
            end
        end
    end
    -- tribute that's due
    local Pw = ALifeBondsPower
    if fn(Pw, "state") and fn(Pw, "tributeDueIn") and type(ALifeBonds) == "table" and fn(ALifeBonds, "keyOf") then
        local key = ALifeBonds.keyOf(playerOf())
        local ok, s = pcall(Pw.state)
        local mine = ok and key and type(s.deal) == "table" and s.deal[key] or nil
        for fid in pairs(type(mine) == "table" and mine or {}) do
            local okD, due = pcall(Pw.tributeDueIn, key, fid)
            if okD and tonumber(due) and due <= 0 then
                local title = tostring(fid)
                pcall(function() local f = PA().Catalog.faction(fid); if f and f.general and f.general.name then title = f.general.name end end)
                out[#out + 1] = view("ovh_tribute_" .. tostring(fid), "Tribute is due", title,
                    { stage("Ask any of them to pay", "Their deal with you says now") }, nil, "signal")
            end
        end
    end
    -- letters to deliver
    local b = L.letters()
    for _, l in ipairs(b and b.list or {}) do
        if l.state == "due" then
            local sh = shellOf(l.to)
            local x, y = xyOf(sh)
            if x == nil then
                local r = record(l.to)
                local wp = r and r.worldPosition or nil
                if type(wp) == "table" then x, y = tonumber(wp.x), tonumber(wp.y) end
            end
            out[#out + 1] = view("ovh_letter_" .. tostring(l.id), "A last letter", l.fromName .. " didn't make it back",
                { stage("Give the letter to " .. l.toName, "\"" .. string.sub(l.text, 1, 80) .. "...\"") }, x and { x = math.floor(x), y = math.floor(y) } or nil, "escort")
        end
    end
    L.metrics.tasks = #out
    return out
end

function L.hookDecorate(TB)
    return wrap(TB, "decorate", "decorate", function(orig)
        return function(player, out, ...)
            local r = orig(player, out, ...)
            if L.enabled() and type(out) == "table" and type(out.missions) == "table" then
                local ok, list = L.guard("decorate", L.ourTasks)
                if ok and type(list) == "table" then for _, v in ipairs(list) do out.missions[v.id] = v end end
            end
            return r
        end
    end)
end
function L.digest()
    local parts = {}
    for _, v in ipairs(L.ourTasks()) do parts[#parts + 1] = v.id .. "@" .. tostring(v.target and math.floor(v.target.x / 10) or "-") .. ":" .. tostring(v.stages[1].detail) end
    table.sort(parts)
    return "|ovh:" .. table.concat(parts, ",")
end
function L.hookDigest(TB)
    return wrap(TB, "digest", "digest", function(orig)
        return function(player, ...)
            local d = orig(player, ...)
            if not L.enabled() then return d end
            local ok, ours = L.guard("digest", L.digest)
            if ok and type(ours) == "string" then return tostring(d or "") .. ours end
            return d
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 4. hidden achievements: titles people have heard
----------------------------------------------------------------------------------------------------------------
function L.addTitles(m)
    if L.hooked.titles then return true end
    if type(m.titleRules) ~= "table" then return false end
    for _, t in ipairs(L.TITLES) do table.insert(m.titleRules, 1, t) end
    L.hooked.titles = true
    return true
end
-- feats from 0.7.4 / 0.7.7 become things people tell each other
function L.hookFeats()
    local S, I = ALifeSkyPower, ALifeInjuryBridge
    if not L.hooked.feats and type(S) == "table" and fn(S, "onDead") and fn(S, "onCrash") and type(I) == "table" and fn(I, "formTradition") then
        local onDead, onCrash, formTradition = S.onDead, S.onCrash, I.formTradition
        S.onDead = function(z, ...)
            local before = S.metrics and S.metrics.juggernauts or 0
            local r = onDead(z, ...)
            if L.enabled() and S.metrics and S.metrics.juggernauts > before then
                local x, y = xyOf(z)
                L.deed("juggernaut", "the stranger brought down one of those armored walking tanks", 4, {}, x, y)
            end
            return r
        end
        S.onCrash = function(flight, ...)
            local r = onCrash(flight, ...)
            if L.enabled() and type(flight) == "table" and type(flight.shooters) == "table" and (function() for _ in pairs(flight.shooters) do return true end; return false end)() then -- 0.7.11.1: no next() in Kahlua
                L.deed("helidown", "the stranger shot a helicopter out of the sky", -1, {}, flight.x, flight.y)
            end
            return r
        end
        I.formTradition = function(key, t, ...)
            local r = formTradition(key, t, ...)
            if L.enabled() and type(t) == "table" then
                local text = ({ help_fallen = "the stranger's people always stop for the wounded", no_quarter = "the stranger gives no quarter",
                    keep_walking = "the stranger's people keep walking past the dying" })[t.id]
                if text then L.deed("tradition", text, t.id == "help_fallen" and 3 or -2, {}, nil, nil) end
            end
            return r
        end
        L.hooked.feats = true
    end
    return L.hooked.feats == true
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "noteTalked", "guardContact", "lvSend", "raidStart", "decorate", "digest", "titles", "feats" }
function L.install()
    local m, pa = M(), PA()
    if type(m) == "table" and type(m.settings) == "table" and m.settings.tasksLetters == nil then m.settings.tasksLetters = true end
    if type(m) == "table" then L.hookTalked(m); L.hookGuardRadio(m); L.hookLeave(m); L.addTitles(m) end
    if pa ~= nil then
        if type(pa.RaidDirector) == "table" then L.hookRaid(pa.RaidDirector) end
        if type(pa.TaskBoard) == "table" then L.hookDecorate(pa.TaskBoard); L.hookDigest(pa.TaskBoard) end
    end
    L.hookFeats()
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
                local now = 0
                pcall(function() now = getTimestampMs() end)
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryTenMinutes ~= nil then Events.EveryTenMinutes.Add(function() if L.enabled() then L.guard("letters", L.letterStep) end end) end
end
print(TAG .. " loaded v" .. L.VERSION)
