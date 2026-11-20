-- A-Life Talk 0.5.1: OUTFIT TALK: NPCs notice what you wear and hold (masks, goggles, gas masks, uniforms, blood, guns, a dead friend's jacket)
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Outfit") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Outfit"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Outfit") end end -- 0.5.1.6 perf label
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur == nil then -- pre-1.0 MP: first player with people near
        for _, p in ipairs(ALifeSide.online()) do
            local x, y, z = pos(p)
            local list = M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}
            if #list > 0 then return list, p end
        end
        return {}, nil
    end
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Outfit", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = true, nil
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- pre-1.0 MP: once per online player
            M.eachPlayer(function() local ok2, e2 = pcall(f, now); if not ok2 then ok, e = ok2, e2 end end)
        else ok, e = pcall(f, now) end
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("outfitTalk", true)
M.outfitCfg = { tick = 2500, tiles = 6, cacheMs = 1000, firstKeyMs = 900000, changeKeyMs = 600000, modeMs = 15000, nickAfter = 3, lowerAskMs = 90000 }
-- keyword groups, matched (lower case) against full type, display name, body location and tags: mod-agnostic
M.outfitWords = {
    -- strong: the only masks that really spook people
    horror = { "hockey", "skull", "clown", "jason", "cryoffear", "cry of fear", "cry_of_fear", "pyramid", "silenthill", "silent hill", "ghostface",
        "jigsaw", "demon", "ghoul", "horror", "creepy", "scarecrow", "plague doctor", "plaguedoctor", "spiffo mask" },
    -- practical survivor gear: mild, easily overcome (gas masks and respirators included)
    gas = { "gasmask", "gas mask", "gas_mask", "respirator", "hazmatmask", "nbc mask", "filter mask", "filtermask" },
    face = { "bandana", "dustmask", "dust mask", "surgical", "surgicalmask", "balaclava", "skimask", "ski mask", "neckgaiter", "neck gaiter",
        "scarf", "face cover", "facecover", "shemagh", "welding mask", "weldingmask", "mask" },
    goggles = { "goggles", "welding", "safety glasses", "safetyglasses" },
    hazmat = { "hazmat", "hazard suit", "hazardsuit", "bunnysuit", "nbc suit", "cbrn" },
    military = { "military", "army", "camo", "ghillie", "kevlar", "flak", "fatigues", "combat helmet", "tactical", "platecarrier", "plate carrier", "soldier", "bdu" },
    police = { "police", "sheriff", "swat", "riot", "officer", "ranger", "deputy" },
    fancy = { "tuxedo", "suit_", "wedding", "ballgown", "gown", "tutu", "bunny", "spiffo", "mascot", "santa", "jester", "kilt", "pajama", "pyjama",
        "bathrobe", "party hat", "partyhat", "sombrero", "tiara", "crown", "toga", "cowboy", "tophat", "top hat", "fedora", "feather boa", "costume", "chef hat" },
    food = { "food" }, medkit = { "firstaid", "first aid", "medkit", "medical", "bandage" }, guitar = { "guitar", "banjo", "violin", "ukulele" },
}
-- body locations that mean the item sits on the face / eyes (vanilla + common mods)
M.outfitFaceLocs = { "mask", "face", "eyes", "eye", "balaclava", "fullhelmet", "fullhat" }
local function low(s) return string.lower(tostring(s or "")) end
local function hasWord(s, list) for _, w in ipairs(list) do if string.find(s, w, 1, true) then return w end end; return nil end
local function call0(o, name) if o == nil or o[name] == nil then return nil end; local ok, v = pcall(function() return o[name](o) end); if ok then return v end; return nil end
local function itemInfo(it, loc)
    if it == nil then return nil end
    local name = tostring(call0(it, "getDisplayName") or "")
    local full = tostring(call0(it, "getFullType") or "")
    local tags = call0(it, "getTags")
    local blood = tonumber((call0(it, "getBloodLevel") or call0(it, "getBloodlevel"))) or 0
    local dirt = tonumber((call0(it, "getDirtiness"))) or 0
    if blood > 1 then blood = blood / 100 end -- some getters are 0..100
    if dirt > 1 then dirt = dirt / 100 end
    loc = loc or call0(it, "getBodyLocation")
    return { name = name, full = full, loc = low(loc), id = call0(it, "getID"), blood = blood, dirt = dirt,
        text = low(full .. " " .. name .. " " .. tostring(loc or "") .. " " .. (tags ~= nil and tostring(tags) or "")),
        custom = call0(it, "isCustomName") == true, weapon = (instanceof ~= nil and instanceof(it, "HandWeapon")) == true,
        ranged = call0(it, "isRanged") == true, isFood = (instanceof ~= nil and instanceof(it, "Food")) == true,
        cat = low(call0(it, "getDisplayCategory") or call0(it, "getCategory")) }
end
function M.wornList(chr)
    local out = {}
    local w = call0(chr, "getWornItems")
    if w == nil or w.size == nil or w.get == nil then return out end
    local n = tonumber((w:size())) or 0
    for i = 0, math.min(n, 40) - 1 do
        local wi = w:get(i)
        local it = wi ~= nil and call0(wi, "getItem") or nil
        local info = itemInfo(it, wi ~= nil and call0(wi, "getLocation") or nil)
        if info then out[#out + 1] = info end
    end
    return out
end
local function isFace(i)
    for _, l in ipairs(M.outfitFaceLocs) do if string.find(i.loc, l, 1, true) then return true end end
    return string.find(i.text, "mask", 1, true) ~= nil or string.find(i.text, "goggle", 1, true) ~= nil
end
-- one read of the player's look; cached a second
M.outfitCache = { at = -1e12 }
function M.outfitScan(player, force)
    local now = nowMs()
    if not force and M.outfitCache.player == player and now - M.outfitCache.at < M.outfitCfg.cacheMs then return M.outfitCache.o end
    local o = { items = {}, face = "none", faceNames = {}, tags = {}, hands = {}, ids = {} }
    local W = M.outfitWords
    local sigParts = {}
    local bloodSum, dirtSum, n = 0, 0, 0
    for _, i in ipairs(M.wornList(player)) do
        o.items[#o.items + 1] = i
        if i.id ~= nil then o.ids[tostring(i.id)] = i end
        n = n + 1; bloodSum = bloodSum + i.blood; dirtSum = dirtSum + i.dirt
        local face = isFace(i)
        local lvl = nil
        if hasWord(i.text, W.horror) and face then lvl = "horror"
        elseif hasWord(i.text, W.gas) then lvl = "gas"
        elseif face and hasWord(i.text, W.goggles) then lvl = "goggles"
        elseif face and hasWord(i.text, W.face) then lvl = "practical" end
        if lvl then
            o.faceNames[#o.faceNames + 1] = i.name
            local rank = { none = 0, goggles = 1, practical = 2, gas = 3, horror = 4 }
            if rank[lvl] > rank[o.face] then o.face = lvl end
            o.tags[lvl] = true
            if lvl == "goggles" then o.goggles = true elseif lvl ~= "horror" then o.covered = true else o.covered = true end
            sigParts[#sigParts + 1] = i.full
        end
        if hasWord(i.text, W.hazmat) then o.tags.hazmat = true; sigParts[#sigParts + 1] = "hazmat" end
        if hasWord(i.text, W.military) then o.tags.military = true end
        if hasWord(i.text, W.police) then o.tags.police = true end
        if hasWord(i.text, W.fancy) and not o.tags.horror then o.tags.fancy = o.tags.fancy or i.name; sigParts[#sigParts + 1] = i.full end
    end
    if o.tags.military then sigParts[#sigParts + 1] = "military" end
    if o.tags.police then sigParts[#sigParts + 1] = "police" end
    -- blood / dirt: the body visual first, then the clothes
    local hv = call0(player, "getHumanVisual")
    local tb = hv and tonumber((call0(hv, "getTotalBlood"))) or nil
    local td = hv and tonumber((call0(hv, "getTotalDirt"))) or nil
    o.blood = math.max(tb or 0, n > 0 and bloodSum / n or 0)
    o.dirt = math.max(td or 0, n > 0 and dirtSum / n or 0)
    if o.blood >= 0.35 then o.tags.bloody = true end
    if o.dirt >= 0.5 then o.tags.filthy = true end
    -- hands
    local p1 = itemInfo(call0(player, "getPrimaryHandItem"))
    local p2 = itemInfo(call0(player, "getSecondaryHandItem"))
    local h = o.hands
    for _, it in ipairs({ p1 or false, p2 or false }) do
        if it then
            if it.weapon and it.full ~= "Base.BareHands" then
                if it.ranged then h.gun = it.name else h.melee = it.name; if it.blood >= 0.3 then h.bloodyMelee = it.name end end
            end
            if it.isFood or it.cat == "food" then h.food = it.name end
            if hasWord(it.text, W.medkit) then h.medkit = it.name end
            if hasWord(it.text, W.guitar) then h.guitar = it.name end
        end
    end
    h.empty = p1 == nil and p2 == nil
    h.aiming = (h.gun ~= nil) and (call0(player, "isAiming") == true)
    -- holstered / slung weapon (attached items)
    local att = call0(player, "getAttachedItems")
    if att ~= nil and att.size ~= nil and att.get ~= nil then
        for i = 0, math.min(tonumber((att:size())) or 0, 12) - 1 do
            local a = att:get(i)
            local it = a and itemInfo(call0(a, "getItem")) or nil
            if it and it.weapon then h.holstered = it.name end
        end
    end
    table.sort(sigParts)
    o.sig = table.concat(sigParts, "|")
    o.look = M.outfitLook(o)
    M.outfitCache = { at = now, player = player, o = o }
    return o
end
-- the short handle an NPC would use for your look ("goggles", "the gas mask")
function M.outfitLook(o)
    if o.face == "horror" then return "the " .. low(o.faceNames[1] or "mask") end
    if o.face == "gas" then return "gas mask" end
    if o.goggles and o.covered then return "goggles and a mask" end
    if o.goggles then return "goggles" end
    if o.face == "practical" then return "the masked one" end
    if o.tags.hazmat then return "the hazmat suit" end
    return nil
end
-- dead NPCs' clothes: item ids at death (looting the body keeps the id) -> wearing them is recognised
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Outfit", function(body, uid, killer)
        pcall(function()
            if M.settings.outfitTalk == false or body == nil then return end
            local list = {}
            for _, i in ipairs(M.wornList(body)) do
                if i.id ~= nil and not string.find(i.loc, "underwear", 1, true) and not string.find(i.loc, "socks", 1, true) then list[#list + 1] = { id = tostring(i.id), name = i.name } end
                if #list >= 12 then break end
            end
            if #list > 0 then bucket("deadWear")[tostring(uid)] = { items = list, at = hours() } end
        end)
    end)
end
function M.deadFriendItem(viewerUid, o)
    for duid, d in pairs(bucket("deadWear")) do
        if duid ~= viewerUid and type(d) == "table" then
            for _, it in ipairs(d.items or {}) do
                if o.ids[it.id] then
                    local c = M.closeness and select(1, M.closeness(viewerUid, duid)) or 0
                    if c >= 0.3 then return { uid = duid, item = it.name, close = c } end
                end
            end
        end
    end
    return nil
end
-- military / police: respect or fear, from their job, faction and personality
function M.uniformStance(uid, l)
    local lens = M.lens and M.lens(uid) or {}
    local job = ""
    pcall(function() local f = M.lifeFacts and M.lifeFacts(uid) or {}; job = low(f.job) end)
    local fac = ""
    pcall(function() local pa = PA(); if fn(pa.Catalog, "faction") then local okF, f = pcall(pa.Catalog.faction, l.record); fac = low(okF and type(f) == "table" and (f.name or f.id) or f) end end)
    if hasWord(job, { "soldier", "army", "military", "police", "cop", "guard", "officer", "marine", "veteran" }) then return "respect", "they served too" end
    if hasWord(fac, { "bandit", "raider", "outlaw", "gang", "cult" }) or (lens.deceitful or 0) + (lens.greedy or 0) + (lens.mean or 0) > 0.6 then return "fear", "people like them hunt people like you" end
    if (lens.disciplined or 0) + (lens.loyal or 0) > 0.5 then return "respect", "they trust order" end
    if (lens.fearful or 0) + (lens.paranoid or 0) > 0.4 then return "fear", "uniforms mean guns" end
    return "wary", nil
end
-- the NPC's take on the look, by personality: kind, line pool, feelings, a short "what" for the AI
M.outfitLines = {
    horror = { "Jesus - take that thing off your face.", "What the hell is that mask? You trying to get shot?", "Okay. That mask is not okay. Who's under there?" },
    horrorTease = { "Nice mask. Very serial killer. Love it.", "Halloween came early, huh?" },
    practical = { "Can't see your face, pal.", "Bit of a bandit look, isn't it?", "Who's behind the bandana?" },
    goggles = { "Goggles, huh. Welding something?", "What's with the goggles?", "Those goggles - expecting sparks?" },
    goggleMask = { "Can't see much of you behind all that.", "Goggles and a mask. Can't read your face at all, pal.", "Lower that a bit, let me see who I'm talking to." },
    lower = { "Lower the mask a second. I want to see your face.", "Pull that down. I talk to faces, not rags.", "Show me your face and we'll talk." },
    gasSmart = { "Gas mask. Smart. Air's not right out here.", "Wish I had one of those.", "Where'd you get the mask? Got a spare?" },
    gasParanoid = { "Gas mask? Bit paranoid, aren't you?", "Expecting a gas attack, are we?" },
    gasSick = { "You know something about the air I don't?", "Is it the sickness? Is it in the air?" },
    gasFog = { "Good call on the gas mask in this fog.", "In this muck, a mask makes sense." },
    hazmat = { "Hazmat suit? What do you know that I don't?", "You from the CDC or something?", "Is it in the air? Is that why the suit?" },
    military = { "Soldier, huh? Where's the rest of your unit?", "Army gear. Respect - or did you take it off a body?" },
    militaryFear = { "Easy, soldier. I'm not looking for trouble.", "Uniforms. Great. Last ones shot first." },
    police = { "Officer. Not much law left out here.", "Badge doesn't mean much anymore, you know." },
    policeFear = { "Cop gear. You gonna arrest me?", "Whoa. Uniform. I'm not making trouble." },
    bloody = { "You're covered in it. Is any of that yours? Are you bitten?", "Christ, is that your blood? Show me your arms.", "Stay there - are you bit?" },
    filthy = { "You smell like a dumpster, friend.", "When did you last wash? Never mind." },
    fancy = { "Nice outfit. Going somewhere fancy?", "Dressed for the end of the world, I see.", "Is that a {i}? Out here?" },
    gun = { "Whoa - point that somewhere else.", "Lower the gun. Now.", "Easy with that. Easy." },
    bloodyMelee = { "That {i} has seen some use.", "Wipe that thing off, would you?" },
    food = { "Is that {i}? Haven't eaten all day.", "That smells good. Sharing?" },
    medkit = { "That a medkit? I could use a bandage.", "You got medical stuff? I've got a cut that won't close." },
    guitar = { "You play that {i}? Go on.", "A {i}! Play something." },
    deadFriend = { "That's {d}'s {i}. Where did you get that?", "Take that off. That was {d}'s.", "That {i}... that's {d}'s. You took it off them?" },
    known = { "There's {look}.", "Hey, {look}.", "Thought I recognised {look}." },
    changed = { "New look?", "Lost the {old}?", "Almost didn't recognise you without the {old}." },
}
function M.outfitReaction(l, player, o, now)
    local uid = tostring(l.record.uid)
    local lens = M.lens and M.lens(uid) or {}
    local seen = bucket("outfitSeen")[uid] or {}
    local known = (M.knowsName and M.knowsName(uid, player)) or (seen.n or 0) > 0
    local para, fear = (lens.paranoid or 0), (lens.fearful or 0)
    local joker = (lens.sarcastic or 0) + (lens.cheerful or 0)
    local h = o.hands
    local df = M.deadFriendItem(uid, o)
    if df then
        local r = rec(df.uid)
        return { kind = "deadFriend", pool = "deadFriend", d = r and firstOf(r) or "their", i = df.item, strong = true,
            feel = { { "grief", 0.4 }, { "anger", 0.25 } }, op = -2, what = "The newcomer is wearing " .. df.item .. " - it belonged to your dead friend " .. (r and firstOf(r) or "") .. ". React strongly" }
    end
    if h.aiming then return { kind = "gun", pool = "gun", strong = true, feel = { { "fear", 0.3 + fear * 0.3 }, { "anger", 0.1 + (lens.volatile or 0) * 0.3 } }, what = "The newcomer has a gun drawn and pointed your way. Tense" } end
    if o.face == "horror" then
        local tease = joker > 0.5 and para < 0.3 and fear < 0.3
        return { kind = "horror", pool = tease and "horrorTease" or "horror", strong = not tease, faceHidden = true,
            feel = tease and { { "joy", 0.1 } } or { { "fear", 0.3 + para * 0.3 + fear * 0.3 }, { "anxiety", 0.2 } },
            what = "The newcomer wears a creepy " .. low(o.faceNames[1] or "mask") .. ". " .. (tease and "Tease them about it" or "It spooks you; tell them to take it off") }
    end
    if o.tags.bloody then return { kind = "bloody", pool = "bloody", feel = { { "anxiety", 0.25 }, { "disgust", 0.15 } }, what = "The newcomer is covered in blood. Worried: are they bitten?" } end
    if o.tags.hazmat then return { kind = "hazmat", pool = "hazmat", feel = { { "anxiety", 0.15 } }, what = "The newcomer wears a hazmat suit. Ask questions" } end
    -- practical face gear: mild; once they know you it's just your look
    if o.face ~= "none" then
        if known and o.look and (seen.looks or {})[o.look] then
            return { kind = "known", pool = "known", look = seen.nick or o.look, recognized = true, feel = {}, what = "You recognise the newcomer by their usual look (" .. o.look .. "). Greet them casually" }
        end
        if o.face == "gas" then
            local c = M.climate and M.climate() or {}
            local fog = (tonumber(c.fog) or 0) >= 0.5 or (M.weirdMods and M.weirdMods.silenthill)
            local pool = fog and "gasFog" or (para + (lens.disciplined or 0) > 0.4 and "gasSmart") or (joker + (lens.proud or 0) > 0.5 and "gasParanoid")
                or ((lens.greedy or 0) > 0.3 and "gasSmart") or "gasSick"
            return { kind = "gas", pool = pool, feel = { { "anxiety", 0.05 + para * 0.1 } }, what = "The newcomer wears a gas mask. Mildly wary or curious (practical gear, not scary)" }
        end
        local ask = o.covered and not known and (para + (lens.proud or 0) + (lens.disciplined or 0) >= 0.45 or hash(uid .. "#lower") % 4 == 0)
        local pool = ask and "lower" or (o.goggles and o.covered and "goggleMask") or (o.goggles and "goggles") or "practical"
        return { kind = "practical", pool = pool, askLower = ask, feel = { { "anxiety", 0.04 + para * 0.08 } },
            what = "The newcomer's face is covered (" .. table.concat(o.faceNames, ", ") .. "). Mild: wary or curious, practical gear, NOT scary" .. (ask and ". Ask them to lower it so you can see their face" or "") }
    end
    if o.tags.military or o.tags.police then
        local st, why = M.uniformStance(uid, l)
        local kind = o.tags.military and "military" or "police"
        return { kind = kind, pool = st == "fear" and kind .. "Fear" or kind, feel = st == "fear" and { { "fear", 0.2 } } or {}, op = st == "respect" and 1 or 0,
            what = "The newcomer wears " .. kind .. " gear. You feel " .. st .. (why and (" (" .. why .. ")") or "") }
    end
    if h.bloodyMelee then return { kind = "bloodyMelee", pool = "bloodyMelee", i = h.bloodyMelee, feel = { { "anxiety", 0.12 } }, what = "The newcomer holds a bloody " .. h.bloodyMelee .. ". Nervous" } end
    if o.tags.fancy then return { kind = "fancy", pool = "fancy", i = o.tags.fancy, feel = { { "joy", 0.08 } }, what = "The newcomer wears a ridiculous " .. o.tags.fancy .. ". Joke about it" } end
    if o.tags.filthy then return { kind = "filthy", pool = "filthy", feel = { { "disgust", 0.08 } }, what = "The newcomer is filthy. Comment" } end
    local needs = M.needsOf and M.needsOf(l.shell) or {}
    if h.food and (tonumber(needs.hunger) or 0) >= 0.25 then return { kind = "food", pool = "food", i = h.food, what = "You are hungry and the newcomer holds " .. h.food .. ". Ask for some" } end
    if h.medkit then return { kind = "medkit", pool = "medkit", i = h.medkit, what = "The newcomer carries " .. h.medkit .. ". Comment or ask for help" } end
    if h.guitar then return { kind = "guitar", pool = "guitar", i = h.guitar, what = "The newcomer has a " .. h.guitar .. ". Ask them to play" } end
    return nil
end
local function fill(line, r, o, old)
    line = string.gsub(line, "{i}", function() return tostring(r.i or "thing") end)
    line = string.gsub(line, "{d}", function() return tostring(r.d or "their") end)
    line = string.gsub(line, "{look}", function() return tostring(r.look or o.look or "you") end)
    line = string.gsub(line, "{old}", function() return tostring(old or "mask") end)
    return line
end
-- remember the look; after a few sightings a masked stranger gets a nickname from it
function M.outfitRemember(uid, player, o, r)
    local b = bucket("outfitSeen")
    local s = b[uid] or { n = 0, looks = {} }
    s.n = (s.n or 0) + 1
    s.looks = s.looks or {}
    if o.look then
        s.looks[o.look] = (s.looks[o.look] or 0) + 1
        if s.nick == nil and s.looks[o.look] >= M.outfitCfg.nickAfter and not (M.knowsName and M.knowsName(uid, player)) then
            s.nick = (o.look == "goggles and a mask" and "Goggles") or (o.look == "gas mask" and "Gasmask") or (o.look == "goggles" and "Goggles")
                or (o.look == "the masked one" and "Masky") or nil
            if s.nick then log("outfit: " .. uid .. " calls you '" .. s.nick .. "'") end
        end
    end
    s.sig, s.at, s.kind, s.look, s.h = o.sig, nowMs(), r and r.kind or s.kind, o.look or s.look, hours()
    if r and r.askLower then s.askedLowerAt = nowMs() end
    b[uid] = s
    return s
end
-- harder to learn your name behind a horror mask (overheard / seen); practical gear doesn't hide you from people who know your look
function M.outfitInstall()
if type(M.markKnown) == "function" and not M.outfitMarkWrapped then
    M.outfitMarkWrapped = true
    local orig = M.markKnown
    M.markKnown = function(uid, player, how, fromUid)
        if M.settings.outfitTalk ~= false and player and how == "overheard" then
            local o = M.outfitScan(player)
            if o and o.face == "horror" and hash(tostring(uid) .. "#hide" .. tostring(math.floor(nowMs() / 60000))) % 2 == 0 then return false end
        end
        return orig(uid, player, how, fromUid)
    end
end
-- threats: a drawn gun, a horror mask, army gear or blood make a threat land harder
if type(M.threatChance) == "function" and not M.outfitThreatWrapped then
    M.outfitThreatWrapped = true
    local orig = M.threatChance
    M.threatChance = function(l, player, kind, now, opts)
        local c, info = orig(l, player, kind, now, opts)
        if M.settings.outfitTalk == false or type(c) ~= "number" then return c, info end
        local o = M.outfitScan(player)
        local add = 0
        if o then
            if o.face == "horror" then add = add + 8 end
            if o.tags.military or o.tags.police then add = add + 5 end
            if o.tags.bloody then add = add + 5 end
            if o.hands.bloodyMelee then add = add + 4 end
            if o.hands.empty and not o.hands.holstered then add = add - 8 end
        end
        if type(info) == "table" then info.outfit = add end
        return clamp(c + add, 2, 96), info
    end
end
end
M.outfitInstall()
if type(Events) == "table" and Events.OnGameStart and Events.OnGameStart.Add then Events.OnGameStart.Add(function() pcall(M.outfitInstall) end) end
-- compact LLM context
function M.outfitDesc(o)
    local parts = {}
    if #o.faceNames > 0 then parts[#parts + 1] = "face: " .. table.concat(o.faceNames, " + ") .. " (" .. (o.face == "horror" and "creepy mask" or "practical gear") .. ")" end
    if o.tags.hazmat then parts[#parts + 1] = "hazmat suit" end
    if o.tags.military then parts[#parts + 1] = "military gear" end
    if o.tags.police then parts[#parts + 1] = "police gear" end
    if o.tags.fancy then parts[#parts + 1] = "odd outfit: " .. o.tags.fancy end
    if o.tags.bloody then parts[#parts + 1] = "blood-soaked" elseif o.tags.filthy then parts[#parts + 1] = "filthy" end
    local h = o.hands
    if h.gun then parts[#parts + 1] = (h.aiming and "AIMING " or "holding ") .. h.gun
    elseif h.bloodyMelee then parts[#parts + 1] = "bloody " .. h.bloodyMelee
    elseif h.melee then parts[#parts + 1] = "holding " .. h.melee end
    if h.food then parts[#parts + 1] = "has " .. h.food end
    if h.medkit then parts[#parts + 1] = "has " .. h.medkit end
    if h.guitar then parts[#parts + 1] = "carrying " .. h.guitar end
    if h.empty then parts[#parts + 1] = h.holstered and "weapon holstered" or "empty hands" end
    return table.concat(parts, "; ")
end
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.outfitTalk == false or player == nil or listener == nil then return end
    local o = M.outfitScan(player)
    if o == nil then return end
    local uid = tostring(listener.record.uid)
    local s = bucket("outfitSeen")[uid] or {}
    local desc = M.outfitDesc(o)
    if desc == "" then return end
    req.outfit = { desc = desc, face = o.face, look = o.look, nick = s.nick,
        recognized = o.face ~= "none" and o.look ~= nil and s.looks ~= nil and (s.looks[o.look] or 0) > 0 or nil,
        faceHidden = o.face == "horror" or nil }
end)
-- first impressions on approach, and comments when the look changes
function M.outfitTick(now)
    if M.settings.outfitTalk == false or not M.worldHere() then return end
    local near, player = nearPlayer(M.outfitCfg.tiles)
    if player == nil or #near == 0 then return end
    local o = M.outfitScan(player)
    if o == nil then return end
    for i, l in ipairs(near) do
        if i > 2 then break end
        local uid = tostring(l.record.uid)
        local s = bucket("outfitSeen")[uid]
        local danger = M.attnDanger and M.attnDanger(l, player)
        local urgent = o.hands.aiming
        if (not danger or urgent) and (urgent or idleOk(l, now)) then
            if s ~= nil and s.sig == o.sig and not urgent and o.look and (hours() - (s.h or hours())) >= 6 then
                -- back after a while: the look is how they know you now ("There's goggles")
                s.h = hours()
                if hash(uid .. tostring(math.floor(hours()))) % 2 == 0 then
                    local r = { look = s.nick or o.look }
                    speak(l, player, "outfit", "You recognise the newcomer by their usual look (" .. o.look .. ")" .. (s.nick and (", you call them " .. s.nick) or "") .. ". Greet them casually",
                        fill(pick(M.outfitLines.known, uid .. "#known" .. tostring(math.floor(hours()))), r, o), { keyMs = M.outfitCfg.changeKeyMs, modeMs = M.outfitCfg.modeMs })
                    M.outfitRemember(uid, player, o, { kind = "known" })
                end
            elseif s == nil or (s.sig ~= o.sig) or urgent then
                local r = M.outfitReaction(l, player, o, now)
                local old = nil
                if s and s.sig ~= o.sig and r == nil and s.sig ~= "" and s.kind ~= nil then
                    -- they took the mask off: the "lower it" ask is answered, and some NPCs remark on the change
                    old = s.look or "mask"
                    if s.askedLowerAt and now - s.askedLowerAt < M.outfitCfg.lowerAskMs and o.face == "none" then
                        if fn(PA().NpcOpinion, "adjust") then pcall(PA().NpcOpinion.adjust, l.record, player, 2, "Showed their face") end
                        speak(l, player, "outfit", "The newcomer lowered their mask so you could see their face. Brief thanks", "Thanks. Better.", { keyMs = 0, modeMs = 0 })
                        s.askedLowerAt = nil
                    elseif s.n and s.n > 0 and hash(uid .. o.sig) % 3 == 0 then
                        speak(l, player, "outfit", "The newcomer changed their look (no more " .. old .. "). Comment briefly", fill(pick(M.outfitLines.changed, uid .. o.sig), {}, o, old), { keyMs = M.outfitCfg.changeKeyMs, modeMs = M.outfitCfg.modeMs })
                    end
                    s.sig = o.sig
                elseif r then
                    local line = fill(pick(M.outfitLines[r.pool] or M.outfitLines.practical, uid .. o.sig .. r.pool), r, o)
                    local spoke = speak(l, player, "outfit", r.what, line, { keyMs = urgent and 20000 or (s and M.outfitCfg.changeKeyMs or 0), modeMs = urgent and 0 or M.outfitCfg.modeMs, urgent = urgent })
                    if not spoke and s ~= nil and s.sig == o.sig then return end -- gated: no repeated feelings
                    for _, f in ipairs(r.feel or {}) do if M.feel then M.feel(uid, f[1], f[2], r.what) end end
                    if r.op and r.op ~= 0 and fn(PA().NpcOpinion, "adjust") then pcall(PA().NpcOpinion.adjust, l.record, player, r.op, "Your look: " .. r.kind) end
                    if r.kind == "deadFriend" and M.logInteraction then pcall(M.logInteraction, uid, "Saw you wearing " .. tostring(r.d) .. "'s " .. tostring(r.i), nil, nil, "event") end
                    M.outfitRemember(uid, player, o, r)
                    M.outfitLast = { uid = uid, kind = r.kind, pool = r.pool, line = line }
                elseif s == nil then
                    M.outfitRemember(uid, player, o, nil)
                end
            end
        end
    end
end
regMode("outfit")
everyMs(M.outfitCfg.tick, M.outfitTick)
return M
