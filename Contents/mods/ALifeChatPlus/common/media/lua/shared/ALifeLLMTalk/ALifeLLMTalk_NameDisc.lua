-- A-Life Talk 0.5.1: NAME DISCOVERY.
-- A-Life shows an NPC as "Stranger" until it is introduced to you: record.memory.introducedTo[playerKey] = true, set
-- by A-Life's own Names.markIntroduced inside Talk.writeMemory (the same calls Talk.introduce / Talk.nameResult /
-- Party make). Overhead names (SpeechBubbles.nameFor), the talk menu and Party read Names.shown -> knows(), so marking
-- an NPC this way updates everything in the game at once. No patch needed for that.
-- Triggers: (1) an NPC says its own name (first / last / nickname, "name's X", "I'm X", "call me X" or just the name)
-- in a line you can hear; (2) any line you hear names ANOTHER A-Life NPC ("my buddy Steven"): word boundary, first
-- names resolved to the speaker's ties and the people nearby first, common-word names only when capitalized;
-- (3) NPC-NPC chatter counts the same; (4) "what's your name" / "who are you": trusting NPCs give the real name,
-- liars / schemers / the paranoid may give a FAKE one. The fake shows overhead (A-Life Talk Patch 1.3 wraps
-- Names.shown) until someone else says the real name - then it's exposed (a memorable moment, opinion effect).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_NameDisc") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "NameDisc"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("NameDisc") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function bucket(name)
    local data = M.store()
    if type(data) ~= "table" then M.tmpStore = M.tmpStore or {}; data = M.tmpStore end
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end

if M.settings.nameDiscovery == nil then M.settings.nameDiscovery = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "nameDiscovery" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "nameDiscovery" end
end
M.nameCfg = { indexMs = 60000, hearTiles = 14, askMs = 12000, nearTiles = 30 }
-- names that are also everyday words: only counted when written with a capital letter
M.nameCommonWords = { hope = true, will = true, may = true, rose = true, grace = true, joy = true, faith = true, mark = true,
    bill = true, frank = true, rich = true, ray = true, dawn = true, april = true, june = true, summer = true, art = true,
    pat = true, guy = true, chase = true, hunter = true, page = true, sky = true, bob = true, sue = true, jack = true,
    gene = true, brown = true, white = true, black = true, green = true, young = true, king = true, hill = true, wood = true,
    stone = true, long = true, rice = true, bell = true, cook = true, love = true, bishop = true, may_ = true, doc = true,
    red = true, tiny = true, ace = true, lucky = true, bear = true, buck = true }

local function playerKey(player)
    local pa = PA()
    if fn(pa and pa.Speech, "playerKey") then local ok, k = pcall(pa.Speech.playerKey, player); if ok then return k end end
    return nil
end

-- the name parts of one record: first, last, nick (from A-Life's "First \"Nick\" Last")
function M.nameParts(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or nil
    if m == nil or type(m.personName) ~= "string" or m.personName == "" then return nil end
    local nick = string.match(m.personName, "\"([^\"]+)\"")
    local first, last = m.personFirst, m.personLast
    if first == nil then first = string.match(m.personName, "^(%S+)") end
    return { first = first, last = last, nick = nick, full = m.personName }
end

-- index of everyone A-Life knows by name (lowercased word -> list of uids), rebuilt once a minute
M.nameIndex, M.nameIndexAt = nil, -1e12
function M.buildNameIndex(force)
    local now = nowMs()
    if not force and M.nameIndex ~= nil and now - M.nameIndexAt < M.nameCfg.indexMs then return M.nameIndex end
    local idx = { word = {}, parts = {} }
    local pa = PA()
    if fn(pa and pa.ActorRegistry, "each") then
        pcall(pa.ActorRegistry.each, function(r)
            if r.lifecycle ~= "dead" then
                local p = M.nameParts(r)
                if p then
                    idx.parts[tostring(r.uid)] = p
                    for _, w in ipairs({ p.first, p.last, p.nick }) do
                        if type(w) == "string" and #w >= 3 then
                            local k = string.lower(w)
                            idx.word[k] = idx.word[k] or {}
                            local l = idx.word[k]
                            l[#l + 1] = tostring(r.uid)
                        end
                    end
                end
            end
            return false
        end)
    end
    M.nameIndex, M.nameIndexAt = idx, now
    return idx
end

-- does 'text' contain the word (case-insensitive, word boundary)? common words need a capital first letter
function M.nameIn(text, word)
    if type(text) ~= "string" or type(word) ~= "string" or #word < 3 then return false end
    local low, w = string.lower(text), string.lower(word)
    local start = 1
    while true do
        local a, b = string.find(low, w, start, true)
        if a == nil then return false end
        local before = a > 1 and string.sub(low, a - 1, a - 1) or " "
        local after = string.sub(low, b + 1, b + 1)
        local okB = not string.find(before, "[%w']")
        local okA = after == "" or not string.find(after, "[%w]") or (after == "'" and string.sub(low, b + 2, b + 2) == "s")
        if okB and okA then
            if not M.nameCommonWords[w] then return true end
            local orig = string.sub(text, a, a)
            if string.upper(orig) == orig and string.lower(orig) ~= orig then return true end
        end
        start = b + 1
    end
end

function M.knowsName(uid, player)
    local pa = PA()
    local r = rec(uid)
    local key = playerKey(player)
    if r == nil or key == nil or not fn(pa.Names, "knows") then return false end
    local ok, k = pcall(pa.Names.knows, r, key)
    return ok and k == true
end

-- mark known through A-Life's own API (overhead name + A-Life UI follow); logs how we learned it
function M.markKnown(uid, player, how, fromUid)
    if M.settings.nameDiscovery == false then return false end
    local pa = PA()
    local r = rec(uid)
    local key = playerKey(player)
    if r == nil or key == nil or not fn(pa.Names, "markIntroduced") or not fn(pa.Talk, "writeMemory") then return false end
    if M.knowsName(uid, player) then return false end
    local ok = pcall(pa.Talk.writeMemory, tostring(uid), function(memory) pa.Names.markIntroduced(memory, key) end)
    if not ok then return false end
    local name = fn(pa.Names, "of") and pa.Names.of(r) or "someone"
    local fromName = nil
    if fromUid ~= nil and tostring(fromUid) ~= tostring(uid) then
        local fr = rec(fromUid)
        fromName = fr and fn(pa.Names, "of") and pa.Names.of(fr) or nil
    end
    local first = (M.nameParts(r) or {}).first or name
    local text = fromName and ("Learned " .. first .. "'s name from " .. fromName) or ("Learned their name: " .. first)
    if M.logInteraction then pcall(M.logInteraction, uid, text, nil, nil, "name") end
    log("names: " .. text .. " (" .. tostring(how) .. ")")
    -- a fake they gave you is exposed when someone ELSE says the real name
    if fromName ~= nil then pcall(M.exposeFake, uid, player, fromUid) end
    return true
end

-- fake names ------------------------------------------------------------------------------------------------
function M.fakeNameOf(uid) return bucket("fakeNames")[tostring(uid)] end
function M.pickFakeName(uid)
    local pa = PA()
    local female = false
    pcall(function() female = pa.Talk.shellFor(tostring(uid)):isFemale() end)
    local pool = pa and pa.Names and (female and pa.Names.female or pa.Names.male) or nil
    local real = (M.nameParts(rec(uid)) or {}).first
    if type(pool) ~= "table" or #pool == 0 then pool = female and { "Mary", "Linda", "Susan", "Karen" } or { "John", "Mike", "Dave", "Steve" } end
    for i = 0, 6 do
        local n = pool[(hash(tostring(uid) .. "#fake" .. i) % #pool) + 1]
        if type(n) == "table" then n = n[1] end
        if type(n) == "string" and n ~= real then return n end
    end
    return "John"
end
-- will they lie about their name to you? (personality "lie", paranoia / deceit, low trust)
function M.nameAnswer(uid, player)
    local pa = PA()
    local r = rec(uid)
    local op = 0
    pcall(function() op = tonumber((pa.NpcOpinion.valueOf(r, player))) or 0 end)
    local stance = fn(pa.Talk, "stance") and pa.Talk.stance(r, player) or "neutral"
    if stance == "hostile" or op <= -35 then return "refuse" end
    if M.fakeNameOf(uid) then return "fake", M.fakeNameOf(uid) end
    local lens = M.lens and M.lens(uid) or {}
    local mods = lens.mods or {}
    local lie = (tonumber(mods.lie) or 0.2) * 70 + (lens.deceitful or 0) * 60 + (lens.paranoid or 0) * 40 - math.max(0, op) * 0.8
    local core = M.partsOf and M.partsOf(uid) or nil
    local k = core and core.core and core.core.key or ""
    if k == "liar" or k == "schemer" or k == "manipulative" then lie = lie + 30 end
    if k == "honest" then lie = 0 end
    if hash(tostring(uid) .. "#namelie") % 100 < lie then return "fake", M.pickFakeName(uid) end
    -- Chat Plus: guarded people don't just hand it over. Wary / shy / proud types give a first name only or want
    -- yours first; warmer opinion wears that down. (Same person answers the same way until things change.)
    local guard = (lens.paranoid or 0) * 60 + (lens.fearful or 0) * 40 + (lens.proud or 0) * 30 + (lens.sarcastic or 0) * 20
        + (stance == "careful" and 30 or 0) - math.max(0, op) * 1.2
    if k == "shy" or k == "paranoid" or k == "stoic" or k == "cold" then guard = guard + 20 end
    if k == "cheerful" or k == "charmer" or k == "honest" or k == "gentle" then guard = guard - 25 end
    local roll = hash(tostring(uid) .. "#nameguard" .. tostring(math.floor(op / 10))) % 100
    if roll < guard * 0.5 then return "yoursFirst", (M.nameParts(r) or {}).first end
    if roll < guard then return "first", (M.nameParts(r) or {}).first end
    return "real", (M.nameParts(r) or {}).first
end

-- how this person says their name, from who they are (passed to the AI as a style hint, never shown to you)
function M.nameStyle(uid)
    local core = M.partsOf and M.partsOf(uid) or nil
    local c = core and core.core or {}
    local label = c.label or c.key
    local traits = type(c.traits) == "table" and table.concat(c.traits, ", ") or nil
    if label == nil and traits == nil then return nil end
    return "Say it the way a " .. tostring(label or "person") .. (traits and (" (" .. traits .. ")") or "") ..
        " would: in your own words and manner, not a stock introduction."
end

M.nameAsks = {}
M.askWords = { "what's your name", "whats your name", "what is your name", "who are you", "your name", "who're you",
    "what do they call you", "what do i call you", "what should i call you", "got a name", "introduce yourself" }
function M.onAskName(player, text, loud, hearers)
    if M.settings.nameDiscovery == false then return end
    local low = string.lower(tostring(text or ""))
    local asked = false
    for _, w in ipairs(M.askWords) do if string.find(low, w, 1, true) then asked = true end end
    if not asked then return end
    local l = hearers and hearers[1] or nil
    local px, py, pz = pos(player)
    if l == nil and M.nearbyNpcs and px then l = (M.nearbyNpcs(px, py, pz, 6) or {})[1] end
    if l == nil then return end
    local uid = tostring(l.record.uid)
    local how, name = M.nameAnswer(uid, player)
    M.nameAsks[uid] = { how = how, name = name, at = nowMs(), player = ALifeSide.cur } -- pre-1.0 MP: who asked
    if how == "fake" then
        bucket("fakeNames")[uid] = name
        local P = patch()
        if P and fn(P, "setFakeName") then pcall(P.setFakeName, uid, player, name) end
        if M.logInteraction then pcall(M.logInteraction, uid, "Gave you a false name (\"" .. tostring(name) .. "\")", nil, nil, "name") end
        log("names: " .. uid .. " gives a fake name: " .. tostring(name))
    end
end
table.insert(M.playerWordHooks, M.onAskName)
-- A-Life's preset ASK_NAME answer would always give the real name: the AI takes it (with the decision above)
M.aiTakes.ASK_NAME = true

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.nameDiscovery == false then return end
    local uid = tostring(listener.record.uid)
    local a = M.nameAsks[uid]
    if a and now - a.at < M.nameCfg.askMs then
        req.nameAsk = { how = a.how, name = a.name, style = M.nameStyle and M.nameStyle(uid) or nil }
    elseif M.fakeNameOf(uid) then
        req.nameAsk = { how = "keepFake", name = M.fakeNameOf(uid) } -- stay consistent with the lie
    end
    req.useNames = true
end)

function M.exposeFake(uid, player, byUid)
    uid = tostring(uid)
    local fake = bucket("fakeNames")[uid]
    if fake == nil then return false end
    bucket("fakeNames")[uid] = nil
    local P = patch()
    if P and fn(P, "clearFakeName") then pcall(P.clearFakeName, uid, player) end
    local pa = PA()
    local r = rec(uid)
    local real = (M.nameParts(r) or {}).first or "?"
    local by = rec(byUid)
    local byName = by and fn(pa.Names, "of") and pa.Names.of(by) or "someone"
    if fn(pa.NpcOpinion, "adjust") and r then
        M.opinionWhy = "Caught in a lie about their name"
        pcall(pa.NpcOpinion.adjust, r, player, -3, M.opinionWhy)
        M.opinionWhy = nil
    end
    if M.feel then M.feel(uid, "shame", 0.35, "their fake name was exposed") end
    if M.keyMem then pcall(M.keyMem, uid, "name", "You told the newcomer your name was " .. fake .. "; " .. byName .. " gave away the real one (" .. real .. ")") end
    if M.logInteraction then pcall(M.logInteraction, uid, "Exposed: \"" .. fake .. "\" is really " .. real .. " (" .. byName .. " said it)", nil, nil, "name") end
    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
    if sh and M.say then
        local lines = { "...Yeah. Okay. It's " .. real .. ".", "Fine. " .. real .. ". Happy now?", "Didn't know you, did I? Name's " .. real .. "." }
        M.say(sh, player, lines[(hash(uid) % #lines) + 1], { record = r })
    end
    log("names: fake name '" .. fake .. "' of " .. uid .. " exposed by " .. tostring(byUid))
    return true
end

-- every line you can hear: own name, other people's names
function M.namesInLine(shell, uid, text, x, y)
    if M.settings.nameDiscovery == false or type(text) ~= "string" or text == "" then return end
    local player = ALifeSide.you()
    if player == nil then return end
    local px, py, pz = pos(player)
    if px == nil or x == nil or (px - x) ^ 2 + (py - y) ^ 2 > M.nameCfg.hearTiles ^ 2 then return end
    local idx = M.buildNameIndex()
    local found = {}
    -- (1) own name (the fake one doesn't count: that's the lie)
    if uid ~= nil then
        local p = idx.parts[tostring(uid)] or M.nameParts(rec(uid))
        local fake = bucket("fakeNames")[tostring(uid)]
        if p then
            for _, w in ipairs({ p.first, p.last, p.nick }) do
                if type(w) == "string" and w ~= fake and M.nameIn(text, w) then
                    M.markKnown(uid, player, "said own name")
                    found[tostring(uid)] = true
                    break
                end
            end
        end
    end
    -- (2) other people: collect candidates per word, resolve ambiguity
    local ties, near = {}, {}
    if uid ~= nil and M.tiesOf then
        for _, t in ipairs(M.tiesOf(uid, nil, 12, true) or {}) do ties[tostring(t.uid)] = true end
    end
    if M.nearbyNpcs then for _, l in ipairs(M.nearbyNpcs(x, y, pz or 0, M.nameCfg.nearTiles) or {}) do near[tostring(l.record.uid)] = true end end
    for word, uids in pairs(idx.word) do
        if string.find(string.lower(text), word, 1, true) and M.nameIn(text, word) then
            local pick = nil
            local cands = {}
            for _, u in ipairs(uids) do if u ~= tostring(uid) then cands[#cands + 1] = u end end
            if #cands == 1 then pick = cands[1]
            else
                for _, u in ipairs(cands) do if ties[u] then pick = u; break end end
                if pick == nil then
                    local n, last = 0, nil
                    for _, u in ipairs(cands) do if near[u] then n, last = n + 1, u end end
                    if n == 1 then pick = last end
                end
            end
            -- a full name (first + last) settles it too
            if pick == nil then
                for _, u in ipairs(cands) do
                    local p = idx.parts[u]
                    if p and p.last and M.nameIn(text, p.first or "") and M.nameIn(text, p.last) then pick = u end
                end
            end
            if pick ~= nil and not found[pick] then
                found[pick] = true
                M.markKnown(pick, player, "overheard", uid)
            end
        end
    end
end
table.insert(M.npcLineHooks, function(shell, uid, text, x, y) M.namesInLine(shell, uid, text, x, y) end)

-- a fake name answer: if the AI's line didn't contain the fake, still treat the lie as told; a real answer marks known
function M.nameAskSettle(now)
    local player = ALifeSide.you()
    for uid, a in pairs(M.nameAsks) do
        if now - a.at > 6000 then
            local p = a.player or player -- MP: the one who asked
            if a.how == "real" and p then M.markKnown(uid, p, "asked") end
            M.nameAsks[uid] = nil
        end
    end
end
if type(Events) == "table" and Events.OnTick then
    local n = 0
    ALifeHealth.tickAdd("ALifeLLMTalk_NameDisc", function()
        n = n + 1
        if n % 60 ~= 23 then return end
        pcall(M.nameAskSettle, nowMs())
    end)
end

-- our own UI: the name as the game shows it (Stranger / fake / real)
function M.shownName(uid, player)
    local pa = PA()
    local r = rec(uid)
    if r == nil then return "Stranger", false end
    local key = playerKey(player)
    if fn(pa.Names, "shown") and key ~= nil then
        local ok, name, known = pcall(pa.Names.shown, r, key)
        if ok and known == true and type(name) == "string" and name ~= "" then return name, true end
    end
    local fake = M.fakeNameOf(uid)
    if fake then return fake, true end
    if player == nil then return (fn(pa.Names, "of") and pa.Names.of(r)) or "Someone", true end
    return "Stranger", false
end

return M
