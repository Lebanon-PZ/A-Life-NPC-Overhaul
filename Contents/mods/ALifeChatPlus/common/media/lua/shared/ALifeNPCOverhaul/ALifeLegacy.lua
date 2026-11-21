-- A-Life NPC Overhaul 0.9.2 (Legacy): THE CAMP OUTLIVES YOU (server side).
-- You die. The camp doesn't stop:
--   * THE HEIR: your 1st lieutenant, else the 2nd, else the camp picks one (ALifeCampVote "lead": the resident most of
--     them would follow) - setting legacyHeir: "lt" (that order), "vote" (always the camp's pick), "dissolve" (nobody
--     leads: the camp only keeps itself). The heir runs it their way with no end date: the lieutenant's away rules
--     (door, rations) keep going even with you standing there, until the camp is handed back.
--   * YOUR TITLE, from what you really did: LEGEND (they loved you, the camp is strong), TYRANT (fear: exiles,
--     captives, people turned away, a camp that didn't like you), WARNING (the camp fell apart or you died with almost
--     nobody left), else FORGOTTEN. Written in the Chronicle with the new chapter ("after Joe fell, Darrell led").
--   * A STRANGER (legacyStranger, the default; off = the camp stays yours): your next character is nobody to them.
--     Jeem's base owner moves to the heir, so the new you can't run it (Jeem canManage); what they thought of you stays
--     with the dead (the client zeroes their opinion of the new you and keeps the old one here for the kin claim).
--   * GETTING IT BACK (legacyHandBack): "earn" (be trusted again: the heir's opinion of you reaches legacyTrust and you
--     ask), "never", or "ask" (the heir decides on the spot by what they think of you). A KIN CLAIM ("I'm Joe's
--     brother") is a lie the heir may see through (their suspicion; a Legend's kin gets the benefit of the doubt).
-- Store: global ModData "ALifeChatPlus_Legacy": [key] = { name, title, heir, heirName, baseId, h, x, y, z, owner, old }.
-- Commands (ALifeCmd): legacyDied (the client saw you die; the server checks), legacyAsk / legacyKin -> legacyState.
-- Multiplayer: only when no other living player of that key... and no other member of the faction is online.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeLegacy = ALifeLegacy or {}
local G = ALifeLegacy
local TAG = "[ALifeLegacy]"
G.VERSION = ALifeSide.MOD_VERSION
G.MODDATA = "ALifeChatPlus_Legacy"
G.DEFAULTS = {
    legacy = true,          -- the camp goes on after you die
    legacyHeir = "lt",      -- "lt" (1st, 2nd lieutenant, then the camp's pick) | "vote" | "dissolve"
    legacyStranger = true,  -- your next character is a stranger to them (off: the camp stays yours)
    legacyHandBack = "earn", -- "earn" | "ask" | "never"
    legacyTrust = 40,       -- earn: how much the heir must like the new you before they hand it back
    legacyKinClaim = true,  -- you can claim to be your old character's kin
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function J() return type(ProjectALifeJimmy) == "table" and ProjectALifeJimmy or nil end
local function mem(r) return type(r) == "table" and type(r.memory) == "table" and r.memory or {} end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return type(r) == "table" and r or nil end
local function first(r)
    local m = mem(r)
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return type(n) == "string" and (string.match(n, "^(%S+)") or n) or "Someone"
end
local function temper(r) local t = nil; pcall(function() t = PA().Speech.contextFor(r, nil).temperament end); return type(t) == "string" and t or nil end
function G.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end
function G.registerSettings()
    local m = ALifeLLMTalk
    if type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    m.fileKeys = m.fileKeys or {}
    local have = {}
    for _, x in ipairs(m.fileKeys) do have[x] = true end
    for k, v in pairs(G.DEFAULTS) do
        if m.settings[k] == nil then m.settings[k] = v end
        if not have[k] then m.fileKeys[#m.fileKeys + 1] = k end
    end
    return true
end
G.registerSettings()
function G.on() return G.setting("legacy") ~= false end
function G.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return num(h, 0) end
function G.store()
    local d = nil
    pcall(function() d = ModData.getOrCreate(G.MODDATA) end)
    if type(d) ~= "table" then G._mem = G._mem or {}; d = G._mem end
    d.by = type(d.by) == "table" and d.by or {}
    return d
end
local function transmit() if type(ModData) == "table" and fn(ModData, "transmit") and ALifeSide.server() then pcall(ModData.transmit, G.MODDATA) end end
function G.keyOf(player)
    if type(player) == "string" then return player end
    local j = J()
    if j and fn(j, "playerKey") then local ok, k = pcall(j.playerKey, player); if ok and k then return tostring(k) end end
    local R = PA().Reputation
    if fn(R, "playerKey") then local ok, k = pcall(R.playerKey, player); if ok and k then return tostring(k) end end
    local u = nil
    pcall(function() u = player:getUsername() end)
    return u and tostring(u) or nil
end
function G.of(key) local r = G.store().by[tostring(key or "")]; return type(r) == "table" and r or nil end

-- ---------------------------------------------------------------------------------------------- the camp you had
-- your base (Jeem: the first one owned by your key), its residents
function G.baseOf(key)
    local j = J()
    if j == nil or not fn(j.BaseAreas, "list") then return nil end
    local found = nil
    pcall(function()
        for _, b in ipairs(j.BaseAreas.list() or {}) do
            if type(b) == "table" and b.ownerKind == "player" and (b.owner == key or b.createdBy == key) then found = b; return end
        end
    end)
    return found
end
function G.residents(base)
    local j = J()
    local R = j and j.Residents or nil
    if base == nil or not fn(R, "residents") then return {} end
    local ok, list = pcall(R.residents, base.id)
    local out = {}
    for _, r in ipairs(ok and type(list) == "table" and list or {}) do if r.lifecycle ~= "dead" then out[#out + 1] = r end end
    return out
end
-- the heir: 1st / 2nd lieutenant (alive, at the base), else the one the camp would follow most
function G.heir(key, base, people)
    local mode = tostring(G.setting("legacyHeir") or "lt")
    if mode == "dissolve" then return nil, "dissolve" end
    if mode ~= "vote" and type(ALifeLieutenant) == "table" and fn(ALifeLieutenant, "rowOf") then
        local row = ALifeLieutenant.rowOf(key)
        for _, uid in ipairs(row.lts or {}) do
            local r = rec(uid)
            if r and r.lifecycle ~= "dead" then
                for _, p in ipairs(people) do if tostring(p.uid) == tostring(uid) then return r, "lt" end end
            end
        end
    end
    -- the camp's pick: who most would follow (ALifeCampVote "lead" tally per candidate)
    local best, bestScore = nil, -1e9
    if base ~= nil and type(ALifeCampVote) == "table" and fn(ALifeCampVote, "tally") then
        for _, r in ipairs(people) do
            local ok, t = pcall(ALifeCampVote.tally, base.id, { k = "lead", uid = tostring(r.uid) })
            if ok and type(t) == "table" then
                local score = num(t.yes, 0) * 2 - num(t.no, 0) * 2 + num(t.meh, 0) * 0.1
                if score > bestScore then best, bestScore = r, score end
            end
        end
    end
    if best == nil then best = people[1] end
    return best, best and "vote" or "none"
end
-- the title, from real things: what the camp thought of you, how big it is, what you did to people
function G.title(facts)
    local people, avg = num(facts.people, 0), num(facts.avg, 0)
    local hard = num(facts.exiles, 0) + num(facts.captives, 0) + num(facts.turned, 0)
    if people <= 1 or facts.fell then return "WARNING" end
    if hard >= 3 and avg < 10 then return "TYRANT" end
    if avg >= 25 and people >= 3 then return "LEGEND" end
    return "FORGOTTEN"
end
G.TITLE_WORDS = { LEGEND = "a Legend", TYRANT = "a Tyrant", WARNING = "a Warning", FORGOTTEN = "nobody much" }
-- what they said and did about you, counted from the Chronicle (exiles, people turned away) and the camp's opinions
function G.facts(player, key, people, old)
    local f = { people = #people, avg = 0, exiles = 0, turned = 0, captives = 0 }
    local sum, n = 0, 0
    for _, r in ipairs(people) do
        local v = old and old[tostring(r.uid)] or nil
        if v == nil then pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end) end
        if tonumber(v) then sum = sum + v; n = n + 1 end
    end
    if n > 0 then f.avg = sum / n end
    if type(ALifeChronicle) == "table" and fn(ALifeChronicle, "store") then
        for _, e in ipairs(ALifeChronicle.store().list) do
            if e.k == "exile" then f.exiles = f.exiles + 1 elseif e.k == "turnaway" then f.turned = f.turned + 1 end
        end
    end
    -- people you hold captive (ALifeBondsPower state().cap, the same list InjuryBridge reads)
    if type(ALifeBondsPower) == "table" and fn(ALifeBondsPower, "state") then
        pcall(function() local st = ALifeBondsPower.state(); for _ in pairs(type(st.cap) == "table" and st.cap or {}) do f.captives = f.captives + 1 end end)
    end
    return f
end

-- ---------------------------------------------------------------------------------------------- you died
-- a = { name, x, y, z, old = { [uid] = opinion } } from the client (it saw it). Returns the legacy row or nil, why
function G.died(player, a)
    if not G.on() then return nil, "off" end
    a = type(a) == "table" and a or {}
    local key = G.keyOf(player)
    if key == nil then return nil, "key" end
    local cur = G.of(key)
    if cur and cur.h and G.hours() - num(cur.h, 0) < 1 then return cur, "dupe" end
    local base = G.baseOf(key)
    if base == nil then return nil, "nobase" end
    local people = G.residents(base)
    local old = {}
    for k, v in pairs(type(a.old) == "table" and a.old or {}) do if tonumber(v) then old[tostring(k)] = tonumber(v) end end
    local facts = G.facts(player, key, people, old)
    local title = G.title(facts)
    local heir, how = G.heir(key, base, people)
    local name = string.sub(tostring(a.name or "The boss"), 1, 40)
    local row = { name = name, title = title, heir = heir and tostring(heir.uid) or nil, heirName = heir and first(heir) or nil, how = how,
        baseId = base.id, baseName = base.name, h = G.hours(), x = num(a.x, nil), y = num(a.y, nil), z = num(a.z, 0), old = old, people = #people }
    G.store().by[key] = row
    -- the heir runs it: the lieutenant's rules keep going even with the new you standing there
    if heir and type(ALifeLieutenant) == "table" and fn(ALifeLieutenant, "rowOf") then
        local lrow = ALifeLieutenant.rowOf(key)
        if lrow.lts[1] ~= tostring(heir.uid) then table.insert(lrow.lts, 1, tostring(heir.uid)) end
        lrow.heir = true
        lrow.awaySince = G.hours() - num(ALifeLieutenant.setting and ALifeLieutenant.setting("ltAwayHours"), 6)
    end
    -- a stranger: Jeem's base goes to the heir (the new you with the same key can't run it)
    if G.setting("legacyStranger") ~= false and base.ownerKind == "player" then
        row.owner = base.owner
        base.owner = "heir:" .. tostring(row.heir or "camp")
        base.alcpHeirOf = key
        pcall(function() local j = J(); if fn(j.BaseAreas, "save") then j.BaseAreas.save() end end)
    end
    -- the Chronicle: a new chapter
    if type(ALifeChronicle) == "table" then
        pcall(ALifeChronicle.add, { k = "legacy", who = name, what = name .. " is dead. The camp will remember them as " .. G.TITLE_WORDS[title] })
        if row.heirName then pcall(ALifeChronicle.setLeader, row.heirName, "fell") end
        if row.heirName then pcall(ALifeChronicle.add, { k = "leader", who = row.heirName, uid = row.heir, what = row.heirName .. " took over the camp" .. (how == "vote" and ", the camp's choice" or "") }) end
        if how == "dissolve" then pcall(ALifeChronicle.add, { k = "leader", what = "Nobody took charge. The camp keeps itself now" }) end
    end
    transmit()
    log(name .. " died: " .. title .. ", heir " .. tostring(row.heirName) .. " (" .. tostring(how) .. "), " .. #people .. " at " .. tostring(base.name))
    return row
end

-- ---------------------------------------------------------------------------------------------- getting it back
function G.handBack(player, key, row, why)
    local j = J()
    local base = nil
    if j and fn(j.BaseAreas, "base") then pcall(function() base = j.BaseAreas.base(row.baseId) end) end
    if base and base.alcpHeirOf == key then
        base.owner = row.owner or key
        base.alcpHeirOf = nil
        pcall(function() if fn(j.BaseAreas, "save") then j.BaseAreas.save() end end)
    end
    if type(ALifeLieutenant) == "table" and fn(ALifeLieutenant, "rowOf") then ALifeLieutenant.rowOf(key).heir = nil end
    row.back = G.hours()
    row.backWhy = why
    local who = nil
    pcall(function() who = player:getDescriptor():getForename() end)
    if type(ALifeChronicle) == "table" then
        if who then pcall(ALifeChronicle.setLeader, who, "heir") end
        pcall(ALifeChronicle.add, { k = "leader", who = row.heirName, what = tostring(row.heirName or "The camp") .. " handed the camp to " .. tostring(who or "a newcomer") .. (why == "kin" and ", " .. row.name .. "'s kin" or "") })
    end
    transmit()
    return true
end
-- what the heir thinks of you (the new you)
function G.heirOpinion(player, row)
    local v = 0
    pcall(function() v = tonumber((PA().NpcOpinion.valueOf(rec(row.heir), player))) or 0 end)
    return v
end
-- "I want the camp back"
function G.ask(player)
    local key = G.keyOf(player)
    local row = G.of(key)
    if row == nil or row.back ~= nil then return false, "none" end
    local mode = tostring(G.setting("legacyHandBack") or "earn")
    if mode == "never" then return false, "never" end
    local heirR = row.heir and rec(row.heir) or nil
    if heirR == nil or heirR.lifecycle == "dead" then G.handBack(player, key, row, "noheir"); return true, "noheir" end
    local v = G.heirOpinion(player, row)
    local need = num(G.setting("legacyTrust"), 40)
    if mode == "ask" then need = need * 0.5 end
    if v >= need then G.handBack(player, key, row, "earned"); return true, "earned" end
    return false, "notyet"
end
-- "I'm Joe's brother": a lie, unless... the heir decides how hard they look
G.SUSPICIOUS = { veteran = 25, predator = 35, seasoned = 10, fresh = 0 }
function G.kinClaim(player, rollFn)
    if G.setting("legacyKinClaim") == false then return false, "off" end
    local key = G.keyOf(player)
    local row = G.of(key)
    if row == nil or row.back ~= nil then return false, "none" end
    if row.kinTried then return false, "tried" end
    row.kinTried = G.hours()
    local heirR = row.heir and rec(row.heir) or nil
    if heirR == nil then G.handBack(player, key, row, "kin"); return true, "kin" end
    local oldV = num(row.old and row.old[tostring(row.heir)], 0)
    local chance = 35 + oldV / 2 - num(G.SUSPICIOUS[temper(heirR) or ""], 10) + (row.title == "LEGEND" and 15 or 0) - (row.title == "TYRANT" and 25 or 0)
    if chance < 5 then chance = 5 elseif chance > 85 then chance = 85 end
    local roll = 99
    if rollFn then roll = rollFn() else pcall(function() roll = ZombRand(100) end) end
    if roll < chance then G.handBack(player, key, row, "kin"); return true, "kin" end
    pcall(function() PA().NpcOpinion.adjust(heirR, player, -10, "lied about being " .. row.name .. "'s kin") end)
    transmit()
    return false, "caught"
end
function G.view(row)
    if type(row) ~= "table" then return nil end
    return { name = row.name, title = row.title, heirName = row.heirName, heir = row.heir, how = row.how, baseName = row.baseName, back = row.back, kinTried = row.kinTried }
end

function G.install()
    if G.installed or not fn(ALifeCmd, "onServer") then return G.installed == true end
    ALifeCmd.onServer("legacyDied", function(player, a) local row, why = G.died(player, a); ALifeCmd.reply(player, "legacyState", { row = G.view(row), why = why, ev = "died" }) end)
    ALifeCmd.onServer("legacyAsk", function(player, a) local ok, why = G.ask(player); ALifeCmd.reply(player, "legacyState", { row = G.view(G.of(G.keyOf(player))), ok = ok, why = why, ev = "ask" }) end)
    ALifeCmd.onServer("legacyKin", function(player, a) local ok, why = G.kinClaim(player); ALifeCmd.reply(player, "legacyState", { row = G.view(G.of(G.keyOf(player))), ok = ok, why = why, ev = "kin" }) end)
    ALifeCmd.onServer("legacyPull", function(player, a) ALifeCmd.reply(player, "legacyState", { row = G.view(G.of(G.keyOf(player))), ev = "pull" }) end)
    G.installed = true
    return true
end
G.install()
print(TAG .. " ready v" .. G.VERSION .. ": the camp outlives you (" .. (G.on() and "on" or "off") .. ", heir " .. tostring(G.setting("legacyHeir")) .. ", stranger " .. tostring(G.setting("legacyStranger") ~= false) .. ", hand back " .. tostring(G.setting("legacyHandBack")) .. ")")
return G
