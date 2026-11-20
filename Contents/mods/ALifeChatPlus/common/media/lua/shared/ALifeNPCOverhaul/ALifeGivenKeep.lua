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
ALifeGivenKeep = ALifeGivenKeep or {}
local G = ALifeGivenKeep
local TAG = "[ALifeGivenKeep]"
G.VERSION = "0.8.8"
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

function G.install()
    local n = 0
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
        if type(isClient) == "function" and isClient() then return end -- MP: the server keeps it
        pcall(G.install)
        if not G.said then
            G.said = true
            log("ready v" .. G.VERSION .. ": what you hand someone stays on them (" .. tostring(G.hooks or 0) .. "/3 hooks, " .. (G.on() and "on" or "off") .. ")")
        end
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(start) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(start) end
end
