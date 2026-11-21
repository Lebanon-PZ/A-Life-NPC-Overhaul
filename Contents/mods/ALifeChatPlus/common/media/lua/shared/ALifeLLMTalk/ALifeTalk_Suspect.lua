-- A-Life NPC Overhaul pre-1.0: WHO YOU THINK THEY RUN WITH. The People list (A-Life's Contacts tab) is grouped by the
-- group you suspect someone belongs to, under the kind of group you take it for (raiders, friendly, traders...).
-- Only what you could really know: you know a group once you've talked to one of them, been introduced, or met the
-- group itself (Groups you know). Until then they're "people met near <town>" and you judge them by how they act
-- toward you. The kind comes from the group's creed (Bands.lua) or what it's called, else its standing with you.
-- Pure logic, no UI: the client list (ALifeTalk_PeopleGroups.lua) calls M.suspectOf for each row.
-- Settings: peopleGroups (on/off), peopleFoldAt (groups this size or bigger start folded), peopleFriendAt / peopleFoeAt
-- (how much someone of an unknown group must like / dislike you before you call them friendly / hostile).
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Suspect"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Suspect") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("peopleGroups", true)
setting("peopleFoldAt", 3)
setting("peopleFriendAt", 16)
setting("peopleFoeAt", -16)

-- the kinds, in list order (threats first after your own)
M.suspectCats = {
    { id = "starred", label = "Starred" },
    { id = "yours", label = "Your people" },
    { id = "hostile", label = "Hostile to you" },
    { id = "raiders", label = "Raiders" },
    { id = "friendly", label = "Friendly" },
    { id = "traders", label = "Traders" },
    { id = "faithful", label = "Faithful" },
    { id = "wary", label = "Keep to themselves" },
    { id = "unknown", label = "Can't tell yet" },
    { id = "dead", label = "Dead" },
}
M.suspectCatOrder = {}
for i, c in ipairs(M.suspectCats) do M.suspectCatOrder[c.id] = i end
M.suspectCreedCat = { raiders = "raiders", faithful = "faithful", traders = "traders", closed = "wary", wary = "wary", open = "friendly" }
M.suspectStandCat = { hostile = "hostile", enemy = "hostile", war = "hostile", careful = "wary", wary = "wary",
    friendly = "friendly", allied = "friendly", ally = "friendly" }

local function num(key, d) local v = tonumber(M.settings[key]); if v == nil then return d end return v end

-- what group (A-Life faction or a band of ours) a person is in, or nil
function M.suspectGroupOf(n)
    local uid = n and n.uid
    local band = (uid and M.bandOfUid) and M.bandOfUid(uid) or nil
    local rec = n and n.record
    local fid = band and band.id or (type(rec) == "table" and rec.factionId) or nil
    if band == nil and fid ~= nil and M.isBand and M.isBand(fid) and M.bandById then band = M.bandById(fid) end
    if fid == nil or tostring(fid) == "" or tostring(fid) == "unknown" then return nil, nil, nil end
    local name = band and band.name or (M.factionName and M.factionName(fid)) or nil
    if name == nil or tostring(name) == "" or tostring(name) == tostring(fid) then name = nil end -- raw ids read badly
    return tostring(fid), name and tostring(name) or nil, band
end

-- groups the player has met as groups (Groups you know: Upkeep.met + Jeem's known factions)
function M.suspectKnownGroups(player)
    local out = {}
    pcall(function()
        local met = ModData.getOrCreate("ALifeChatPlus.Upkeep").met
        if type(met) == "table" then for f in pairs(met) do out[tostring(f)] = true end end
    end)
    pcall(function()
        local J = ProjectALifeJimmy
        local key = J.BaseAreas.who(player).key
        local known = J.StandingService.knownFactions(key)
        if type(known) == "table" then for _, f in ipairs(known) do out[tostring(f)] = true end end
    end)
    return out
end

-- one pass over the rows: which groups you know through someone of theirs you've talked to or been introduced to
function M.suspectContext(rows, player)
    local ctx = { known = M.suspectKnownGroups(player), player = player, party = {}, standing = {} }
    if M.partyMembers then
        local ok, list = pcall(M.partyMembers, player)
        if ok and type(list) == "table" then for _, uid in ipairs(list) do ctx.party[tostring(uid)] = true end end
    end
    local pkey = nil
    pcall(function() local P = PA(); if fn(P.Speech, "playerKey") then pkey = P.Speech.playerKey(player) end end)
    for _, n in ipairs(rows or {}) do
        local fid = M.suspectGroupOf(n)
        if fid ~= nil and not ctx.known[fid] then
            local intro = false
            pcall(function()
                local it = n.record and n.record.memory and n.record.memory.introducedTo
                if type(it) == "table" then for k, v in pairs(it) do if v and (pkey == nil or tostring(k) == tostring(pkey)) then intro = true; break end end end
            end)
            if intro or (tonumber(n.lastN) or 0) > 0 then ctx.known[fid] = true end
        end
    end
    return ctx
end

-- the group's standing with you (Jeem's ladder), cached per refresh
local function standingOf(ctx, fid)
    if ctx.standing[fid] ~= nil then return ctx.standing[fid] or nil end
    local label = false
    pcall(function()
        local J = ProjectALifeJimmy
        local key = J.BaseAreas.who(ctx.player).key
        label = string.lower(tostring(J.StandingService.labelFor(key, fid) or "")) or false
    end)
    ctx.standing[fid] = label
    return label or nil
end

local function creedOf(band, name)
    if band and band.creed then return band.creed end
    local low = string.lower(tostring(name or ""))
    if string.find(low, "raider") or string.find(low, "bandit") or string.find(low, "gang") or string.find(low, "biker") then return "raiders" end
    if string.find(low, "church") or string.find(low, "cult") or string.find(low, "clergy") then return "faithful" end
    if string.find(low, "trader") or string.find(low, "merchant") or string.find(low, "caravan") then return "traders" end
    return nil
end

-- where you first came across them (book: first spot we noted; older saves: last seen)
function M.suspectMetTown(uid)
    local e = M.bucket and M.bucket("book")[tostring(uid)] or nil
    if type(e) ~= "table" then return nil end
    local x, y = e.mx or e.x, e.my or e.y
    if x == nil then return nil end
    return M.townAt and M.townAt(x, y) or nil
end

-- n: a People row; returns { cat = kind id, group = fold key, label = group line }
function M.suspectOf(n, ctx)
    local uid = tostring(n.uid)
    if n.dead then return { cat = "dead", group = "dead", label = nil } end
    if ctx.party[uid] or (M.settlerOf and M.settlerOf(uid) ~= nil) then return { cat = "yours", group = "yours", label = nil } end
    local fid, name, band = M.suspectGroupOf(n)
    local v = tonumber(n.value) or 0
    local byAct = v <= num("peopleFoeAt", -16) and "hostile" or (v >= num("peopleFriendAt", 16) and "friendly" or "unknown")
    if fid ~= nil and name ~= nil and ctx.known[fid] then
        local cat = M.suspectCreedCat[creedOf(band, name) or ""]
        if cat == nil then cat = M.suspectStandCat[standingOf(ctx, fid) or ""] end
        return { cat = cat or byAct, group = "g:" .. fid, label = name }
    end
    local town = M.suspectMetTown(uid)
    return { cat = byAct, group = "m:" .. tostring(town or "?") .. "|" .. byAct,
        label = town and ("Met near " .. town) or "Met somewhere along the way" }
end

print("[ALifeTalk_Suspect] ready pre-1.0: People list grouped by suspected group and kind")
return M
