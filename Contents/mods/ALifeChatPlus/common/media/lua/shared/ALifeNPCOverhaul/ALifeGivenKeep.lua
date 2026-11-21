-- A-Life NPC Overhaul 0.8.8: WHAT YOU HAND SOMEONE STAYS ON THEIR BODY.
-- When an A-Life NPC dies, A-Life thins what they carried at random (ALifeDeathDrops defaultApply: supplies, ammo and
-- weapons each kept only by a chance roll; read in A-Life 1.5.1 server/ProjectALife/Shells/ALifeDeathDrops.lua). Fine for
-- loot they were spawned with; wrong for the coat you gave them yesterday. Real life: it's still on them.
-- How (never editing A-Life):
--   * We remember what you handed them, per person, by item type and count (ModData "ALifeGivenKeep"), from the two real
--     ways of handing things over: Jeem's hand gifts / Give window (it emits "npcGiven" {uid, fullType, key} per item it
--     really gave; Jeem HandGifts.lua H.giveItems) and A-Life's companion sheet (companionItem op "give" / "take",
--     ProjectALife.CompanionInventoryServer.act -> Srv.move; read in ALifeCompanionInventoryServer.lua).
--   * The item object itself is tagged too (modData ACPGiven) for as long as it lives; after their body is unloaded and
--     rebuilt A-Life recreates items by type (ShellState.itemState keeps no mod data of ours), so the count is what lasts.
--   * At death A-Life asks DeathDrops.stolenItem(item) first for every item and leaves those alone (its own rule for
--     things it took off you in a robbery). We answer yes also for what you gave them: the tag, or the next unclaimed
--     one of a type you gave (counted down per item, remembered per item so a second look at the same item agrees).
--   * Their tally is dropped once they're dead.
-- Setting: givenStays (on).
require "ALifeNPCOverhaul/AA_Side"
ALifeGivenKeep = ALifeGivenKeep or {}
local G = ALifeGivenKeep
local TAG = "[ALifeGivenKeep]"
G.VERSION = ALifeSide.MOD_VERSION
G.DEFAULTS = { givenStays = true }
G.KEYS = { "givenStays" }
G.MAX_TYPES = 40
G.metrics = G.metrics or { noted = 0, kept = 0, deaths = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
function G.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end
function G.on() return G.setting("givenStays") ~= false end
function G.store()
    local s = type(ModData) == "table" and ModData.getOrCreate("ALifeGivenKeep") or (G.tmp or {})
    if type(ModData) ~= "table" then G.tmp = s end
    s.by = type(s.by) == "table" and s.by or {}
    return s
end
local function fullType(item)
    local t = nil
    pcall(function() t = item:getFullType() end)
    return type(t) == "string" and t or nil
end
local function dataOf(item)
    local d = nil
    pcall(function() d = item:getModData() end)
    return type(d) == "table" and d or nil
end

-- ---------------------------------------------------------------------------------------------- remembering
function G.note(uid, t, n, item)
    if uid == nil or type(t) ~= "string" or t == "" then return false end
    n = tonumber(n) or 1
    local s = G.store()
    local row = s.by[tostring(uid)]
    if type(row) ~= "table" then row = {}; s.by[tostring(uid)] = row end
    if row[t] == nil then
        local count = 0
        for _ in pairs(row) do count = count + 1 end
        if count >= G.MAX_TYPES then return false end
    end
    row[t] = math.max(0, (tonumber(row[t]) or 0) + n)
    if row[t] == 0 then row[t] = nil end
    if item ~= nil and n > 0 then local d = dataOf(item); if d ~= nil then d.ACPGiven = true end end
    if item ~= nil and n < 0 then local d = dataOf(item); if d ~= nil then d.ACPGiven = nil end end
    if n > 0 then G.metrics.noted = G.metrics.noted + n end
    return true
end
function G.countOf(uid, t)
    local row = G.store().by[tostring(uid)]
    return type(row) == "table" and (tonumber(row[t]) or 0) or 0
end

-- Jeem: one event per item really handed over (what went back to you is not emitted)
function G.onGiven(ev)
    if not G.on() or type(ev) ~= "table" then return end
    G.note(ev.uid, ev.fullType, 1)
end

-- A-Life companion sheet: the op of the call in progress, so Srv.move knows which way things go
function G.wrapSheet()
    local Srv = PA().CompanionInventoryServer
    if not fn(Srv, "act") or not fn(Srv, "move") then return false end
    if Srv.acpGivenWrapped then return true end
    local act, move = Srv.act, Srv.move
    Srv.act = function(player, args, ...)
        G.cur = type(args) == "table" and { op = args.op, uid = args.uid } or nil
        local ok, a, b, c = pcall(act, player, args, ...)
        G.cur = nil
        if not ok then error(a) end
        return a, b, c
    end
    Srv.move = function(source, destination, items, limit, ...)
        local cur = G.cur
        local before = {}
        if cur ~= nil and type(items) == "table" then
            for i, item in ipairs(items) do before[i] = item end
        end
        local moved = move(source, destination, items, limit, ...)
        if cur ~= nil and G.on() and (cur.op == "give" or cur.op == "take") then
            pcall(function()
                for _, item in ipairs(before) do
                    -- (really moved: now in the destination)
                    local now = nil
                    pcall(function() now = item:getContainer() end)
                    if now == destination then G.note(cur.uid, fullType(item), cur.op == "give" and 1 or -1, item) end
                end
            end)
        end
        return moved
    end
    Srv.acpGivenWrapped = true
    return true
end

-- ---------------------------------------------------------------------------------------------- at death
G.dying = nil -- { uid, left = {type = n}, seen = weak item -> bool }
function G.isGiven(item)
    if item == nil then return false end
    local d = dataOf(item)
    local seen = G.dying and G.dying.seen or nil
    if seen ~= nil and seen[item] ~= nil then return seen[item] end
    local yes = false
    local t = fullType(item)
    local n = (G.dying ~= nil and t ~= nil) and (tonumber(G.dying.left[t]) or 0) or 0
    -- (a tagged item is one of the counted ones: it uses up its count, so an untagged one of theirs isn't kept for it)
    if d ~= nil and d.ACPGiven == true then yes = true; if n > 0 then G.dying.left[t] = n - 1 end
    elseif n > 0 then G.dying.left[t] = n - 1; yes = true end
    if seen ~= nil then seen[item] = yes end
    if yes then G.metrics.kept = G.metrics.kept + 1 end
    return yes
end
function G.wrapDeath()
    local D = PA().DeathDrops
    if not fn(D, "stolenItem") or not fn(D, "process") then return false end
    if D.acpGivenWrapped then return true end
    local stolen, process = D.stolenItem, D.process
    D.stolenItem = function(item, ...)
        if stolen(item, ...) then return true end
        if G.dying ~= nil and G.on() then
            local ok, yes = pcall(G.isGiven, item)
            if ok and yes then return true end
        end
        return false
    end
    D.process = function(shell, actor, ...)
        local uid = type(actor) == "table" and actor.uid ~= nil and tostring(actor.uid) or nil
        local row = uid and G.store().by[uid] or nil
        if uid ~= nil and type(row) == "table" and G.on() then
            local left = {}
            for t, n in pairs(row) do left[t] = tonumber(n) or 0 end
            G.dying = { uid = uid, left = left, seen = setmetatable({}, { __mode = "k" }) }
        end
        local ok, a, b = pcall(process, shell, actor, ...)
        if G.dying ~= nil then
            G.metrics.deaths = G.metrics.deaths + 1
            G.store().by[G.dying.uid] = nil
            G.dying = nil
        end
        if not ok then error(a) end
        return a, b
    end
    D.acpGivenWrapped = true
    return true
end

-- ---------------------------------------------------------------------------------------------- offer matches the hands
-- Jeem's hand gift (HandGifts.lua, J.on "talking") hands over WHATEVER is in your hands on any OFFER_ITEM line. "You want
-- some food?" with a rifle in hand gave the rifle away. Real life: you offer what you say. So we note the line, and when it
-- names a kind of thing (food / gun / ammo / medicine) and the held item is another kind, nothing changes hands.
-- A line naming nothing ("take this", "here") still hands over what you hold. Setting: offerMatch (on).
G.DEFAULTS.offerMatch = true
G.KEYS[#G.KEYS + 1] = "offerMatch"
G.WANT = {
    { kinds = { food = true }, words = { "food", "eat", "meal", "bread", "snack", "snacks", "ration", "rations", "hungry",
        "beans", "soup", "water", "drink", "canned", "cans", "dinner", "lunch", "breakfast", "supper" } },
    { kinds = { gun = true }, words = { "gun", "guns", "rifle", "rifles", "pistol", "pistols", "shotgun", "shotguns", "smg",
        "revolver", "firearm", "firearms", "handgun", "carbine" } },
    { kinds = { gun = true, melee = true }, words = { "weapon", "weapons" } },
    { kinds = { melee = true }, words = { "bat", "knife", "axe", "machete", "crowbar", "hammer", "sword", "blade" } },
    { kinds = { ammo = true }, words = { "ammo", "bullets", "rounds", "mags", "magazines", "shells", "cartridges" } },
    { kinds = { medical = true }, words = { "bandage", "bandages", "meds", "medicine", "pills", "medkit", "painkillers", "antibiotics" } },
}
G.OFFER_MS = 8000
local function nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return os.time() * 1000
end
local function sameWho(a, b)
    if a == nil or b == nil or a == b then return true end
    local ua, ub = nil, nil
    pcall(function() ua = a:getUsername() end)
    pcall(function() ub = b:getUsername() end)
    return ua ~= nil and ua == ub
end
-- kinds the line asks for, as a set; nil when it names none
function G.wantedKinds(text)
    if type(text) ~= "string" or text == "" then return nil end
    local low = " " .. string.gsub(string.lower(text), "[^%w']+", " ") .. " "
    local out, any = {}, false
    for _, row in ipairs(G.WANT) do
        for _, w in ipairs(row.words) do
            if string.find(low, " " .. w .. " ", 1, true) then
                for k in pairs(row.kinds) do out[k] = true end
                any = true
                break
            end
        end
    end
    return any and out or nil
end
-- Main calls this for every line A-Life reads as OFFER_ITEM
function G.noteOffer(player, text)
    G.offer = { player = player, wants = G.wantedKinds(text), at = nowMs(), text = text }
end
local function heldKind(player, item)
    local j = J()
    local gw = j and (j.GiftWorth or j.GiftsService)
    if not fn(gw, "kind") then return nil end
    local ok, k = pcall(gw.kind, item)
    return ok and k or nil
end
function G.wrapHandGift()
    local j = J()
    local H = j and j.HandGifts
    if not fn(H, "give") or not fn(H, "heldItem") then return false end
    if H.acpOfferWrapped then return true end
    local give = H.give
    H.give = function(player, record, stance, ...)
        local o = G.offer
        G.offer = nil -- (one line, one handover)
        if o ~= nil and G.setting("offerMatch") ~= false and o.wants ~= nil and sameWho(o.player, player)
                and nowMs() - o.at <= G.OFFER_MS then
            local okI, item = pcall(H.heldItem, player)
            local kind = okI and item ~= nil and heldKind(player, item) or nil
            if kind ~= nil and not o.wants[kind] then
                G.metrics.vetoed = (G.metrics.vetoed or 0) + 1
                log("offer vetoed: said \"" .. string.sub(tostring(o.text), 1, 50) .. "\" but hands hold " .. tostring(kind))
                pcall(function() j.notice(player, "IGUI_ALCP_OfferMismatch") end)
                return false
            end
        end
        return give(player, record, stance, ...)
    end
    H.acpOfferWrapped = true
    return true
end

-- Every typed line goes through A-Life's classifier, AI bridge or not: note the offers there (no player known on the
-- server side: sameWho takes it then; Main's own note, which has the player, replaces this one when the AI path runs)
function G.wrapClassify()
    local I = PA().TalkIntents
    if not fn(I, "classify") then return false end
    if I.acpOfferWrapped then return true end
    local classify = I.classify
    I.classify = function(text, ...)
        local intent, b, c = classify(text, ...)
        if intent == "OFFER_ITEM" and type(text) == "string" and not (G.offer ~= nil and G.offer.text == text and G.offer.player ~= nil) then
            pcall(G.noteOffer, nil, text)
        end
        return intent, b, c
    end
    I.acpOfferWrapped = true
    return true
end

function G.install()
    local n = 0
    pcall(G.wrapHandGift)
    pcall(G.wrapClassify)
    if pcall(G.wrapDeath) and PA().DeathDrops and PA().DeathDrops.acpGivenWrapped then n = n + 1 end
    if pcall(G.wrapSheet) and PA().CompanionInventoryServer and PA().CompanionInventoryServer.acpGivenWrapped then n = n + 1 end
    local j = J()
    if j ~= nil and fn(j, "on") and not G.jeemOn then
        j.on("npcGiven", function(ev) pcall(G.onGiven, ev) end)
        G.jeemOn = true
    end
    if G.jeemOn then n = n + 1 end
    G.hooks = n
    return n
end

if type(Events) == "table" then
    local function start()
        if ALifeSide.client() then return end -- MP: the server keeps it
        pcall(G.install)
        if not G.said then
            G.said = true
            log("ready v" .. G.VERSION .. ": what you hand someone stays on them (" .. tostring(G.hooks or 0) .. "/3 hooks, " .. (G.on() and "on" or "off") .. ")")
        end
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(start) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(start) end
end
