-- A-Life Talk 0.5.0: the inner life of every NPC.
--   * optional-mod detection (getActivatedMods, soft: nothing is a hard dependency)          M.compat / M.modOn
--   * personality chart data: trait categories per NPC (core temperament + background + a uid-stable jitter)
--   * negative / unhinged temperaments (PersonaData 0.5.0): speech style, prompt rules, opinion rates; they insult,
--     mock, refuse, mope or rant but personality alone never turns them hostile (M.mayTurnHostile)
--   * emotions: ~32 feelings with intensities that decay toward a personality baseline, driven by events
--     (M.feel), shaped by personality, persisted in our ModData bucket "emo", fed to every prompt, the ambient
--     chatter and behaviour (M.emoBehavior)
--   * off-screen lives: needs (hunger, sleep, safety, company), stress and a personal goal that progress with
--     game time even while the NPC is far away, and come up in conversation
-- All state lives in A-Life Talk's own ModData; A-Life is only read.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Psyche") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Psyche"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Psyche") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function hourOfDay()
    local ok, h = pcall(function() return getGameTime():getTimeOfDay() end)
    return ok and tonumber(h) or 12
end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function recPeek(uid) local pa = PA(); local reg = pa and pa.ActorRegistry; if fn(reg, "peek") then return reg.peek(tostring(uid)) end; return rec(uid) end -- 0.5.2.2: read-only, no deep copy
local function bucket(name)
    local data = M.store()
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
local function D() return type(ALifeLLMTalkPersonaData) == "table" and ALifeLLMTalkPersonaData or nil end
local function hash(s)
    local h = 5381
    s = tostring(s)
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return h
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function round(v) return math.floor(v + 0.5) end
local function cap(s) s = tostring(s or ""); return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2) end

----------------------------------------------------------------------------------------------------------------
-- optional mods (ids from the user's mod list / console; substring keys for mods whose id we could not read)
----------------------------------------------------------------------------------------------------------------
M.compatIds = {
    livingFactions = { "AliveJeemDynamicWorld" }, factionsExpanded = { "ALifeKnoxFractured" },
    survivorStudio = { "ALifeSurvivorStudio" }, npcMap = { "ALifeNpcMap" }, jeem = { "ProjectALifeJimmy" },
    crew = { "NPCCrew" }, bandits = { "Bandits2", "Bandits" }, weekOne = { "BanditsWeekOne" }, dtg = { "ALifeDTGCrewExtension" },
    tvRadio = { "TVRadio_ReInvented" }, dogs = { "CompanionDogs", "CompanionDogsRottweiler", "CompanionDogsDoberman" },
    mutants = { "PZTheMutants" }, occult = { "OccultZombieBaseHighPop", "OccultZombieBaseLowpop", "OccultZombieBasetesting", "*occult" },
    cryOfFear = { "CryOfFearMonsters" }, silentHill = { "*silenthill", "*silent_hill" }, backrooms = { "nb_backrooms_mod", "*backroom" },
    sewers = { "TrueSewers" }, underground = { "HydeCoUnderGround" }, eternalWinter = { "EternalWinter" },
    coldWinters = { "coldwinters" }, winterFX = { "WinterFX" }, snow = { "ImmersiveSnow" }, atmospherics = { "Atmospherics" },
    gyro = { "KafeenaGyrocopters", "*gyrocopter" }, wildlife = { "KnoxWildlife" }, wounds = { "WoundExpansion", "WoundExpansionZB" },
    onlyCure = { "TheOnlyCurePlus" }, gore = { "IsoGore" }, drugs = { "SkylerDrugModPatched", "*skylerdrug" }, xanny = { "*xanny" },
    patch = { "ALifeTalkPatch" },
}
M.compat = M.compat or {}
function M.activeModIds()
    local out = {}
    pcall(function()
        if type(getActivatedMods) ~= "function" then return end
        local list = getActivatedMods()
        if list == nil or list.size == nil then return end
        for i = 0, list:size() - 1 do out[#out + 1] = tostring(list:get(i)) end
    end)
    return out
end
function M.detectMods(ids)
    ids = ids or M.activeModIds()
    local have, low = {}, {}
    for _, id in ipairs(ids) do
        local s = tostring(id)
        if string.sub(s, 1, 1) == "\\" then s = string.sub(s, 2) end -- B42 sometimes prefixes "\"
        have[s] = true
        low[#low + 1] = string.lower(s)
    end
    local found = {}
    for key, list in pairs(M.compatIds) do
        local on = false
        for _, id in ipairs(list) do
            if string.sub(id, 1, 1) == "*" then
                local sub = string.sub(id, 2)
                for _, l in ipairs(low) do if string.find(l, sub, 1, true) then on = true end end
            elseif have[id] then on = true end
        end
        M.compat[key] = on
        if on then found[#found + 1] = key end
    end
    table.sort(found)
    M.compat._list = table.concat(found, ", ")
    return M.compat
end
function M.modOn(key) return M.compat[key] == true end

----------------------------------------------------------------------------------------------------------------
-- personality: parts, chart categories, dark / unhinged rules
----------------------------------------------------------------------------------------------------------------
local function parts(uid)
    local p = nil
    pcall(function()
        local row = M.personaOf(uid)
        p = row and M.personaParts(row)
    end)
    return p
end
M.partsOf = parts
function M.personaKind(uid)
    local p = parts(uid)
    local m = p and p.mods or {}
    return m.kind, m.style, m
end
-- personality alone never turns these hostile; only what the player actually did can (attacks, threats, kills)
function M.mayTurnHostile(uid, provoked)
    if provoked then return true end
    local _, _, m = M.personaKind(uid)
    return not (m and m.nohostile)
end

M.bgCats = { military = { disciplined = 0.6, brave = 0.4 }, law = { disciplined = 0.6, loyal = 0.3 }, swat = { brave = 0.6, disciplined = 0.4 },
    elite = { brave = 0.5, calm = 0.4 }, rescue = { kind = 0.5, calm = 0.4 }, clergy = { devout = 0.7, kind = 0.3 },
    family = { loyal = 0.5, kind = 0.3 }, civilian = { curious = 0.3, cheerful = 0.3 }, worker = { disciplined = 0.4, loyal = 0.2 },
    raider = { mean = 0.4, greedy = 0.4 }, gang = { volatile = 0.4, loyal = 0.3 }, outlaw = { greedy = 0.4, paranoid = 0.3 },
    crime = { deceitful = 0.5, greedy = 0.3 }, prison = { paranoid = 0.4, brave = 0.3 }, club = { loyal = 0.5, volatile = 0.3 },
    militia = { paranoid = 0.4, disciplined = 0.3 } }
M.speechCats = { ["dry humor"] = "sarcastic", deadpan = "sarcastic", folksy = "cheerful", nervous = "fearful", preachy = "devout",
    ["cusses a lot"] = "volatile", ["sweet-talker"] = "romantic", ["fast-talker"] = "deceitful", polite = "kind", clipped = "disciplined",
    mean = "mean", flat = "gloomy", ranting = "volatile", whispering = "paranoid", giggly = "unhinged", rapid = "unhinged", sermon = "devout" }

-- { { key, label, rgb, tip, pct }, ... } top 5, percentages summing to 100
function M.traitChart(uid, limit)
    limit = limit or 5
    local d, p = D(), parts(uid)
    if d == nil or p == nil or type(d.cats) ~= "table" then return {} end
    local w = {}
    for k, v in pairs(p.core.cats or {}) do w[k] = (w[k] or 0) + v end
    for r in string.gmatch(tostring(p.bg.regs or ""), "%S+") do
        for k, v in pairs(M.bgCats[r] or {}) do w[k] = (w[k] or 0) + v * 0.6 end
    end
    for _, sp in ipairs({ p.speech, p.speech2 }) do
        local k = sp and M.speechCats[sp[1]]
        if k then w[k] = (w[k] or 0) + 0.3 end
    end
    if p.entry.qk == "fear" then w.fearful = (w.fearful or 0) + 0.15 else w.curious = (w.curious or 0) + 0.15 end
    local out = {}
    for _, c in ipairs(d.cats) do
        local v = w[c.key]
        if v and v > 0 then
            v = v * (0.85 + (hash(tostring(uid) .. "#cat#" .. c.key) % 31) / 100) -- stable per NPC
            v = math.sqrt(v) -- flatter, readable ring (order unchanged)
            out[#out + 1] = { key = c.key, label = c.label, rgb = c.rgb, tip = c.tip, w = v }
        end
    end
    table.sort(out, function(a, b) if a.w == b.w then return a.key < b.key end return a.w > b.w end)
    while #out > limit do table.remove(out) end
    local total = 0
    for _, c in ipairs(out) do total = total + c.w end
    local sum = 0
    for _, c in ipairs(out) do c.pct = math.floor(c.w / total * 100); sum = sum + c.pct; c.rem = c.w / total * 100 - c.pct end
    local order = {}
    for i = 1, #out do order[i] = out[i] end
    table.sort(order, function(a, b) return a.rem > b.rem end)
    local i = 1
    while sum < 100 and #order > 0 do order[i].pct = order[i].pct + 1; sum = sum + 1; i = i % #order + 1 end
    return out
end

-- short display lines for the page (TRAITS / QUIRKS)
function M.traitLines(uid)
    local p = parts(uid)
    if p == nil then return {}, {} end
    local tl = {}
    for i, t in ipairs(p.core.traits or {}) do if i <= 3 then tl[#tl + 1] = cap(t) end end
    local ql = { cap(p.quirk) }
    if p.phrase and p.phrase ~= "" then ql[#ql + 1] = "Often says " .. tostring(p.phrase) end
    return tl, ql
end

-- 0.5.0 age: A-Life has none; stable per NPC from their temperament band
function M.ageOf(uid)
    local p = parts(uid)
    local row = nil
    pcall(function() row = M.personaOf(uid) end)
    if type(row) == "table" and tonumber(row.age) then return row.age end
    local temper = p and p.core.temper or "seasoned"
    local lo, hi = 24, 58
    if string.find(temper, "fresh", 1, true) then lo, hi = 18, 40 end
    if string.find(temper, "veteran", 1, true) then lo, hi = 32, 66 end
    local r = rec(uid)
    pcall(function()
        local who = PA().DialogueRoles.describe(r, 0)
        local label = string.lower(tostring(who and who.label or ""))
        if string.find(label, "elder", 1, true) then lo, hi = 62, 81 end
        if string.find(label, "young", 1, true) or string.find(label, "youth", 1, true) then lo, hi = 17, 24 end
    end)
    local age = lo + hash(tostring(uid) .. "#age") % (hi - lo + 1)
    if type(row) == "table" then row.age = age end
    return age
end

M.styleRules = {
    insult = "You're mean: you throw insults and put-downs, but you don't start fights - words only.",
    mock = "You mock people, laugh at their troubles and talk down to them - words only, you don't start fights.",
    refuse = "You refuse things, give short grudging answers and hold back; you aren't violent about it.",
    mope = "You're low: you mope, sigh, expect the worst and turn down cheer-ups; never violent.",
    rant = "You rant about what you believe and won't let it go; loud but not violent.",
    ramble = "You ramble and drift into your own reality; earnest, odd, not violent.",
    giggle = "You giggle at the wrong moments and find the horror funny; unsettling, not violent.",
    preach = "You preach at people about the Judgement; fervent, not violent.",
    flatter = "You flatter and guilt-trip to get what you want; never openly hostile.",
    swing = "Your mood swings hard from line to line - warm, then sharp, then sorry; never violent.",
}
function M.styleLine(uid)
    local kind, style, m = M.personaKind(uid)
    if not (m and m.nohostile) then return nil end
    local out = tostring(m.voice or "")
    if M.styleRules[style] then out = out .. ". " .. M.styleRules[style] end
    if kind == "unhinged" then out = out .. " Stay coherent enough to answer; your oddness colours the line, it doesn't replace it." end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- emotions
----------------------------------------------------------------------------------------------------------------
-- key, adjective (pill), valence (+1/-1/0), half-life in game hours, colour, group (for personality susceptibility)
M.EMOTIONS = {
    { "joy", "Happy", 1, 3, { 226, 206, 112 }, "pos" }, { "contentment", "Content", 1, 12, { 150, 196, 140 }, "pos" },
    { "hope", "Hopeful", 1, 24, { 150, 200, 190 }, "pos" }, { "love", "Loving", 1, 240, { 214, 130, 170 }, "pos" },
    { "gratitude", "Grateful", 1, 24, { 138, 198, 150 }, "pos" }, { "pride", "Proud", 1, 12, { 220, 160, 110 }, "pos" },
    { "relief", "Relieved", 1, 2, { 150, 190, 210 }, "pos" }, { "amusement", "Amused", 1, 1, { 226, 190, 96 }, "pos" },
    { "excitement", "Excited", 1, 2, { 236, 170, 80 }, "pos" }, { "awe", "Awed", 0, 6, { 200, 186, 230 }, "pos" },
    { "nostalgia", "Nostalgic", 0, 12, { 190, 160, 130 }, "sad" },
    { "fear", "Frightened", -1, 1, { 146, 112, 196 }, "fear" }, { "anxiety", "Anxious", -1, 6, { 128, 140, 200 }, "fear" },
    { "dread", "Full of dread", -1, 8, { 110, 96, 160 }, "fear" }, { "paranoia", "Paranoid", -1, 12, { 160, 96, 190 }, "fear" },
    { "sadness", "Sad", -1, 12, { 110, 128, 170 }, "sad" }, { "grief", "Grieving", -1, 96, { 110, 128, 170 }, "sad" },
    { "loneliness", "Lonely", -1, 24, { 120, 130, 160 }, "sad" }, { "despair", "Despairing", -1, 48, { 90, 100, 140 }, "sad" },
    { "numbness", "Numb", -1, 48, { 120, 124, 130 }, "sad" }, { "guilt", "Guilty", -1, 24, { 150, 130, 110 }, "sad" },
    { "shame", "Ashamed", -1, 12, { 160, 120, 120 }, "sad" },
    { "jealousy", "Jealous", -1, 12, { 170, 190, 90 }, "anger" }, { "envy", "Envious", -1, 24, { 150, 170, 90 }, "anger" },
    { "resentment", "Resentful", -1, 48, { 190, 110, 90 }, "anger" }, { "anger", "Angry", -1, 1.5, { 201, 92, 84 }, "anger" },
    { "rage", "Enraged", -1, 0.5, { 226, 60, 50 }, "anger" }, { "irritation", "Irritated", -1, 1, { 210, 130, 90 }, "anger" },
    { "contempt", "Contemptuous", -1, 12, { 170, 100, 100 }, "anger" }, { "disgust", "Disgusted", -1, 1, { 130, 150, 90 }, "anger" },
    { "boredom", "Bored", 0, 6, { 130, 130, 130 }, "sad" }, { "confusion", "Confused", 0, 2, { 160, 160, 190 }, "fear" },
    { "pain", "In pain", -1, 1, { 214, 120, 96 }, "fear" }, -- 0.5.1: fed by their wounds (Wounds.lua)
}
M.emo = {}
for i, e in ipairs(M.EMOTIONS) do
    M.emo[e[1]] = { key = e[1], adj = e[2], val = e[3], half = e[4], rgb = e[5], group = e[6], i = i }
end
M.emoSettings = { maxStored = 10, floor = 0.03, promptMin = 0.18, pills = 3 }

local function baseline(uid)
    local out = {}
    local _, _, m = M.personaKind(uid)
    local s = m and m.emo
    if type(s) == "string" then
        for k, v in string.gmatch(s, "(%a+):([%d%.]+)") do if M.emo[k] then out[k] = tonumber(v) * 0.6 end end
    end
    return out
end
M.emoBaseline = baseline

function M.emoRow(uid)
    local all = bucket("emo")
    uid = tostring(uid)
    local row = all[uid]
    if type(row) ~= "table" then row = { t = hours(), e = {}, why = {} }; all[uid] = row end
    row.e = type(row.e) == "table" and row.e or {}
    row.why = type(row.why) == "table" and row.why or {}
    return row
end

-- decay toward the personality baseline since the last update
function M.emoDecay(uid, now)
    local row = M.emoRow(uid)
    now = now or hours()
    local dt = now - (tonumber(row.t) or now)
    if dt < 0.01 then return row end
    local base = baseline(uid)
    for k, def in pairs(M.emo) do
        local v, b = tonumber(row.e[k]) or 0, base[k] or 0
        if v ~= b then
            local f = 0.5 ^ (dt / def.half)
            v = b + (v - b) * f
            if math.abs(v - b) < 0.01 then v = b end
            if v < M.emoSettings.floor then v = nil; row.why[k] = nil end
            row.e[k] = v
        end
    end
    row.t = now
    return row
end

local function susceptibility(uid, key)
    local def = M.emo[key]
    local kind, style, m = M.personaKind(uid)
    m = m or {}
    local mul = 1
    if def.group == "fear" then mul = 0.6 + (tonumber(m.fear) or 0.4) end
    if def.group == "anger" then mul = 0.4 + (tonumber(m.neg) or 1) * 0.6 end
    if def.group == "pos" then mul = 0.4 + (tonumber(m.pos) or 1) * 0.6 end
    if def.group == "sad" and (style == "mope" or kind == "dark") then mul = 1.25 end
    if kind == "unhinged" then mul = mul * 1.25 end
    local st = M.stressOf and M.stressOf(uid) or 0
    if def.val < 0 then mul = mul * (1 + st / 250) end
    return mul
end

-- the one entry point: something happened that makes them feel 'key' (amount 0..1, can be negative to soothe)
function M.feel(uid, key, amount, why, opts)
    if M.settings.emotions == false or uid == nil or M.emo[key] == nil then return nil end
    uid = tostring(uid)
    local row = M.emoDecay(uid)
    local a = tonumber(amount) or 0
    if a > 0 and not (opts and opts.raw) then a = a * susceptibility(uid, key) end
    local v = clamp((tonumber(row.e[key]) or 0) + a * (1 - (tonumber(row.e[key]) or 0) * 0.5), 0, 1)
    row.e[key] = v >= M.emoSettings.floor and v or nil
    if why and a > 0 then row.why[key] = string.sub(tostring(why), 1, 80) end
    -- spill-overs: anger past 0.75 boils into rage, fear soothed by relief, joy pushes sadness down a little
    if key == "anger" and v >= 0.75 then row.e.rage = clamp((row.e.rage or 0) + 0.2, 0, 1); row.why.rage = row.why.anger end
    if key == "relief" and a > 0 then row.e.fear = row.e.fear and math.max(0, row.e.fear - a * 0.6) or nil end
    if (key == "joy" or key == "gratitude") and a > 0 and row.e.sadness then row.e.sadness = math.max(0, row.e.sadness - a * 0.25) end
    -- wild mood swings: sometimes a strong feeling flips to its opposite a moment later
    local _, style = M.personaKind(uid)
    if style == "swing" and a > 0.15 and hash(uid .. "#" .. tostring(round(hours() * 60))) % 4 == 0 then
        local flip = M.emo[key].val > 0 and "anger" or (M.emo[key].val < 0 and "joy" or nil)
        if flip then row.e[flip] = clamp((row.e[flip] or 0) + a * 0.6, 0, 1) end
    end
    -- keep the table small
    local list = {}
    for k, x in pairs(row.e) do list[#list + 1] = { k, x } end
    if #list > M.emoSettings.maxStored then
        table.sort(list, function(p, q) return p[2] > q[2] end)
        for i = M.emoSettings.maxStored + 1, #list do row.e[list[i][1]] = nil; row.why[list[i][1]] = nil end
    end
    return v
end

-- strongest feelings first: { { key, adj, v, why, rgb }, ... }
function M.moodOf(uid, limit)
    local row = M.emoDecay(uid)
    local out = {}
    for k, v in pairs(row.e) do
        if M.emo[k] and v >= M.emoSettings.floor then
            out[#out + 1] = { key = k, adj = M.emo[k].adj, v = v, why = row.why[k], rgb = M.emo[k].rgb, val = M.emo[k].val }
        end
    end
    table.sort(out, function(a, b) if a.v == b.v then return a.key < b.key end return a.v > b.v end)
    if limit then while #out > limit do table.remove(out) end end
    return out
end

function M.valence(uid)
    local s = 0
    for _, e in ipairs(M.moodOf(uid)) do s = s + e.v * e.val end
    return s
end

local function strength(v) if v >= 0.7 then return "very " elseif v < 0.35 then return "a little " end return "" end
function M.moodLine(uid)
    local parts_ = {}
    for _, e in ipairs(M.moodOf(uid, 3)) do
        if e.v >= M.emoSettings.promptMin then
            parts_[#parts_ + 1] = strength(e.v) .. string.lower(e.adj) .. (e.why and (" (" .. e.why .. ")") or "")
        end
    end
    if #parts_ == 0 then return nil end
    return table.concat(parts_, ", ")
end

-- how feelings bend opinion changes toward the player (used by the NpcOpinion wrapper)
function M.opinionMul(uid, delta)
    local row = M.emoDecay(uid)
    local e = row.e
    local st = M.stressOf and M.stressOf(uid) or 0
    if delta < 0 then
        return 1 + (e.anger or 0) * 0.4 + (e.rage or 0) * 0.4 + (e.resentment or 0) * 0.25 + st / 400 - (e.love or 0) * 0.3
    end
    return 1 + (e.gratitude or 0) * 0.25 + (e.joy or 0) * 0.15 + (e.loneliness or 0) * 0.2 - (e.paranoia or 0) * 0.3
        - (e.despair or 0) * 0.2 - (e.contempt or 0) * 0.3
end

-- behaviour knobs for the world / orders / ambient code
function M.emoBehavior(uid)
    local e = M.emoDecay(uid).e
    local fear = math.max(e.fear or 0, (e.dread or 0) * 0.8, (e.anxiety or 0) * 0.6)
    local anger = math.max(e.anger or 0, e.rage or 0)
    local low = math.max(e.sadness or 0, e.grief or 0, e.despair or 0, e.numbness or 0)
    local up = math.max(e.joy or 0, e.excitement or 0, e.amusement or 0)
    return { fear = fear, anger = anger, low = low, up = up,
        hide = fear > 0.55, -- wants shelter / cover
        snappy = anger > 0.5, -- short fuse, disobeys "hold"
        chatty = up > 0.4 and low < 0.4, -- more ambient lines
        quiet = low > 0.6 or (e.numbness or 0) > 0.5 }
end

----------------------------------------------------------------------------------------------------------------
-- needs, stress and personal goals (off-screen lives)
----------------------------------------------------------------------------------------------------------------
M.lifeSettings = { tickEveryH = 0.5, perTick = 25, hungerPerH = 0.035, thirstPerH = 0.05, sleepPerH = 0.045, companyPerH = 0.02,
    safetyCalmPerH = 0.08, stressDecayPerH = 1.2, goalPerH = 0.9, maxCatchUpH = 72 }
M.GOALS = {
    { "find_family", "find {kin} - last heard of in {place}", "kin" },
    { "leave_county", "get a car running and get out of Knox County", "practical" },
    { "radio_out", "build a radio strong enough to reach the military", "practical" },
    { "meds_stash", "stockpile enough antibiotics to feel safe", "practical" },
    { "garden", "grow a real garden somewhere the dead don't wander", "home" },
    { "sober", "stay sober for a whole month", "self" },
    { "learn_shoot", "learn to shoot straight", "self" },
    { "dog", "find a dog - a good one, to keep watch", "home" },
    { "names", "write down the names of everyone they've lost", "grief" },
    { "fortify", "fortify a place of their own", "home" },
    { "debt", "pay back what they owe {kin}", "people" },
    { "prove", "prove to the others they're worth keeping around", "people" },
    { "map", "map every safe house between here and {place}", "practical" },
    { "faith", "find something to believe in again", "grief" },
    { "revenge", "settle the score with whoever took {kin}", "grief" },
    { "hoard", "fill the cellar to the brim, just in case", "practical" },
    { "truth", "find out what really happened at the start of all this", "odd" },
    { "signal", "answer the voices on the radio that nobody else hears", "odd" },
}
M.KIN = { "their sister", "their brother", "their daughter", "their son", "their mother", "their old man", "their wife",
    "their husband", "their best friend", "their cousin", "their kid" }

-- 0.8.7: no made-up kin (find / pay back / avenge "their sister" who never existed): real kin and real feuds are
-- story goals now (ALifeTalk_Story); "stay sober" only for a real drinker
function M.goalAllowed(g, uid)
    if type(g) ~= "table" then return false end
    if string.find(tostring(g[2]), "{kin}", 1, true) then return false end
    if g[1] == "sober" then
        local ok, hb = pcall(function() return M.habitOf and M.habitOf(uid) or nil end)
        return ok and type(hb) == "table" and hb.drinker == true
    end
    return true
end
function M.lifeOf(uid)
    local all = bucket("life")
    uid = tostring(uid)
    local row = all[uid]
    -- an old save's made-up kin goal: drop it, keep the rest of their life
    if type(row) == "table" and type(row.goal) == "table" and row.goal.id ~= nil then
        local bad = false
        for _, g in ipairs(M.GOALS) do if g[1] == row.goal.id and not M.goalAllowed(g, uid) then bad = true end end
        if bad then
            all[uid] = nil
            local fresh = M.lifeOf(uid)
            fresh.t, fresh.hunger, fresh.sleep, fresh.stress = row.t, row.hunger, row.sleep, row.stress
            fresh.thirst, fresh.safety, fresh.company, fresh.lastGoal = row.thirst, row.safety, row.company, row.lastGoal
            return fresh
        end
    end
    if type(row) ~= "table" then
        local k = hash(uid .. "#life")
        local _, style = M.personaKind(uid)
        local pool = {}
        for _, g in ipairs(M.GOALS) do
            if (g[3] ~= "odd" or style == "ramble" or style == "rant") and M.goalAllowed(g, uid) then pool[#pool + 1] = g end
        end
        local g = pool[k % #pool + 1]
        local d = D()
        local place = d and d.places and d.places[math.floor(k / 7) % #d.places + 1] or "Louisville"
        local text = string.gsub(string.gsub(g[2], "{kin}", M.KIN[math.floor(k / 11) % #M.KIN + 1]), "{place}", place)
        row = { t = hours(), hunger = (k % 30) / 100, sleep = (math.floor(k / 3) % 30) / 100, safety = 0.3, company = 0.3,
            stress = 15 + math.floor(k / 5) % 25, goal = { id = g[1], text = text, p = math.floor(k / 13) % 25, step = nil, done = 0 } }
        all[uid] = row
    end
    return row
end
function M.stressOf(uid)
    local all = bucket("life")
    local row = all[tostring(uid)]
    return type(row) == "table" and (tonumber(row.stress) or 0) or 0
end

M.goalSteps = { "made a little headway", "hit a setback", "found something that might help", "had a close call trying",
    "got a lead from a stranger", "lost their nerve and put it off" }
-- advance one NPC by dt game hours; 'here' = currently loaded near the player (danger/company read from the world)
function M.lifeStep(uid, dt, here)
    local row = M.lifeOf(uid)
    local s = M.lifeSettings
    dt = clamp(dt, 0, s.maxCatchUpH)
    if dt <= 0 then return row end
    local hod = hourOfDay()
    local night = hod >= 22 or hod < 6
    row.hunger = clamp((row.hunger or 0) + s.hungerPerH * dt, 0, 1)
    row.thirst = clamp((row.thirst or 0) + (tonumber(M.settings.thirstPerH) or s.thirstPerH) * dt, 0, 1) -- 0.8.2 part 2
    -- they eat at meal times when their group has food, and drink through the day when it has water
    -- (A-Life ActivityPlanner.needsOf(squad): food / water 0-100, read in 1.5.1)
    local food, water = 50, 50
    pcall(function()
        local r = rec(uid)
        local pa = PA()
        local sq = r and r.squadId and fn(pa.SquadLedger, "peek") and pa.SquadLedger.peek(r.squadId) or nil
        if sq and fn(pa.ActivityPlanner, "needsOf") then
            local n = pa.ActivityPlanner.needsOf(sq)
            food, water = n.food or 50, n.water or 50
        end
    end)
    if food > 15 and (dt >= 4 or hod >= 7 and hod < 9 or hod >= 12 and hod < 14 or hod >= 18 and hod < 20) then
        row.hunger = clamp(row.hunger - 0.5 * math.min(1, dt / 2 + 0.5), 0, 1)
    end
    if water > 15 and (dt >= 3 or hod >= 7 and hod < 8 or hod >= 10 and hod < 11 or hod >= 13 and hod < 14
            or hod >= 16 and hod < 17 or hod >= 19 and hod < 20) then
        row.thirst = clamp(row.thirst - 0.6 * math.min(1, dt / 2 + 0.5), 0, 1)
    end
    if night or dt >= 8 then row.sleep = clamp((row.sleep or 0) - 0.12 * dt, 0, 1)
    else row.sleep = clamp((row.sleep or 0) + s.sleepPerH * dt, 0, 1) end
    local danger = here and here.danger or 0
    row.safety = clamp((row.safety or 0) + danger * 0.5 - s.safetyCalmPerH * dt, 0, 1)
    local company = here and here.company or (hash(uid .. "#grp") % 3 > 0 and 1 or 0)
    row.company = clamp((row.company or 0) + (company > 0 and -0.05 or s.companyPerH) * dt, 0, 1)
    -- stress: pressure from unmet needs and dark feelings, eased by safety and company
    local e = M.emoDecay(uid).e
    local neg = (e.fear or 0) + (e.anxiety or 0) + (e.grief or 0) + (e.despair or 0) + (e.anger or 0) * 0.5
    local press = (row.hunger + (row.thirst or 0) * 0.8 + row.sleep + row.safety + row.company) * 2.2 + neg * 3
    row.stress = clamp((row.stress or 20) + (press - s.stressDecayPerH * 2) * dt, 0, 100)
    if row.company > 0.7 then M.feel(uid, "loneliness", 0.05 * dt, "been alone too long", { raw = true }) end
    if row.hunger > 0.75 then M.feel(uid, "irritation", 0.04 * dt, "hungry", { raw = true }) end
    if row.thirst > 0.75 then M.feel(uid, "irritation", 0.05 * dt, "thirsty", { raw = true }) end
    if row.sleep > 0.8 then M.feel(uid, "numbness", 0.03 * dt, "exhausted", { raw = true }) end
    if row.stress > 80 then M.feel(uid, "anxiety", 0.03 * dt, "everything piling up", { raw = true }) end
    -- the personal goal moves on: faster when calm and fed, setbacks when stressed
    local g = row.goal
    if type(g) == "table" then
        local rate = s.goalPerH * (1.2 - row.stress / 100) * (row.hunger > 0.8 and 0.4 or 1)
        local before = g.p or 0
        g.p = clamp(before + rate * dt, 0, 100)
        local k = hash(uid .. "#step#" .. tostring(math.floor(hours() / 6)))
        if math.floor(g.p / 20) > math.floor(before / 20) then
            local stepI = (row.stress > 70 and (k % 2 == 0)) and 2 or ({ 1, 3, 5 })[k % 3 + 1]
            g.step = M.goalSteps[stepI]
            if stepI == 2 then g.p = clamp(g.p - 8, 0, 100) end
            g.stepH = hours()
        end
        if g.p >= 100 then
            g.done = (g.done or 0) + 1
            M.feel(uid, "pride", 0.5, "finally managed to " .. tostring(g.text), { raw = true })
            M.feel(uid, "joy", 0.4, nil, { raw = true })
            local ilog = M.logInteraction
            if ilog then pcall(ilog, uid, "Reached a goal: " .. tostring(g.text), nil, nil, "event") end
            local all = bucket("life")
            local old = row
            all[tostring(uid)] = nil
            local fresh = M.lifeOf(uid .. "")
            fresh.goal.p, fresh.hunger, fresh.sleep, fresh.stress = 0, old.hunger, old.sleep, math.max(5, old.stress - 25)
            fresh.lastGoal = old.goal.text
            row = fresh
        end
    end
    row.t = hours()
    return row
end

function M.needWords(row)
    local out = {}
    if (row.hunger or 0) > 0.7 then out[#out + 1] = (row.hunger > 0.9 and "starving" or "hungry") end
    if (row.thirst or 0) > 0.7 then out[#out + 1] = (row.thirst > 0.9 and "parched, your mouth is sand" or "thirsty") end
    if (row.sleep or 0) > 0.7 then out[#out + 1] = (row.sleep > 0.9 and "dead on your feet" or "tired") end
    if (row.safety or 0) > 0.6 then out[#out + 1] = "you don't feel safe" end
    if (row.company or 0) > 0.7 then out[#out + 1] = "you've been alone too long" end
    if (row.stress or 0) > 75 then out[#out + 1] = "stressed to breaking point"
    elseif (row.stress or 0) > 55 then out[#out + 1] = "stressed" end
    return out
end

function M.lifeLine(uid)
    local row = M.lifeOf(uid)
    local bits = M.needWords(row)
    local g = row.goal
    local out = {}
    if #bits > 0 then out[#out + 1] = "Right now you're " .. table.concat(bits, ", ") .. "." end
    local story = nil
    if M.storyLine then pcall(function() story = M.storyLine(uid) end) end -- 0.8.7: the real goal comes first
    if type(story) == "string" and story ~= "" then
        out[#out + 1] = "What you want most: " .. story .. " - mention it only if it fits."
    elseif type(g) == "table" then
        out[#out + 1] = "Your own goal: " .. tostring(g.text) .. " (" .. (g.p < 30 and "barely started" or (g.p < 70 and "getting there" or "nearly there"))
            .. (g.step and (", lately you " .. g.step) or "") .. ") - mention it only if it fits."
    end
    if row.lastGoal then out[#out + 1] = "You recently managed to " .. tostring(row.lastGoal) .. "." end
    return table.concat(out, " ")
end

-- what's around a loaded NPC (cheap): zombies within 12 tiles = danger, other A-Life people within 6 = company
function M.surroundings(shell, uid)
    local here = { danger = 0, company = 0 }
    pcall(function()
        local x, y = shell:getX(), shell:getY()
        local cell = getCell()
        local zs = cell and cell:getZombieList()
        if zs then
            local n = 0
            for i = 0, math.min(zs:size(), 400) - 1 do
                local z = zs:get(i)
                if z and math.abs(z:getX() - x) < 12 and math.abs(z:getY() - y) < 12 and not z:isDead() then n = n + 1 end
            end
            here.danger = math.min(1, n / 8)
        end
        if M.nearbyNpcs then here.company = #(M.nearbyNpcs(x, y, shell:getZ(), 6, uid) or {}) end
    end)
    return here
end

local cursor = 0
function M.lifeTick()
    if M.settings.offscreenLives == false then return end
    local now = hours()
    local all = bucket("persona")
    local ids = {}
    for uid in pairs(all) do ids[#ids + 1] = uid end
    if #ids == 0 then return end
    table.sort(ids)
    local talk = PA() and PA().Talk
    for n = 1, math.min(#ids, M.lifeSettings.perTick) do
        cursor = cursor % #ids + 1
        local uid = ids[cursor]
        -- 0.5.2.2: live check first (peek = no copy); the dead and people A-Life removed get no new life row
        local r = recPeek(uid)
        if r and r.lifecycle ~= "dead" then
            local life = M.lifeOf(uid)
            local dt = now - (tonumber(life.t) or now)
            if dt >= M.lifeSettings.tickEveryH then
                local shell = talk and fn(talk, "shellFor") and talk.shellFor(uid) or nil
                M.lifeStep(uid, dt, shell and M.surroundings(shell, uid) or nil)
            end
        else
            local life = bucket("life")[tostring(uid)]
            if type(life) == "table" then life.t = now end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- event wiring (each wrapper calls the original first; all pcall-guarded)
----------------------------------------------------------------------------------------------------------------
function M.onOpinionChanged(uid, before, after, what)
    local d = (after or 0) - (before or 0)
    if d >= 2 then
        M.feel(uid, "gratitude", math.min(0.5, d / 20), what)
        if after >= 40 then M.feel(uid, "contentment", 0.1) end
    elseif d <= -2 then
        local m = select(3, M.personaKind(uid)) or {}
        if (tonumber(m.fear) or 0.4) >= 0.6 then M.feel(uid, "fear", math.min(0.5, -d / 25), what)
        else M.feel(uid, "anger", math.min(0.6, -d / 18), what) end
        M.feel(uid, "resentment", math.min(0.3, -d / 40), what)
    end
end

local function wrapM(name, after)
    local orig = M[name]
    if type(orig) ~= "function" or M["_psy_" .. name] then return end
    M[name] = function(...)
        local a, b, c = orig(...)
        local args = { ... }
        pcall(after, args, a)
        return a, b, c
    end
    M["_psy_" .. name] = true
end
function M.installPsycheHooks()
    wrapM("onGift", function(args)
        local l = args[2]
        if l and l.record then
            M.feel(l.record.uid, "gratitude", 0.35, "you gave them something")
            M.feel(l.record.uid, "joy", 0.2)
        end
    end)
    wrapM("onNpcDied", function(args)
        local uid = args[2]
        if uid == nil then return end
        uid = tostring(uid)
        local dead = rec(uid)
        local pa = PA()
        local nm = dead and fn(pa.Names, "of") and pa.Names.of(dead) or "someone close"
        -- everyone with a tie to the dead feels it: grief by closeness, relief for enemies
        for key, row in pairs(bucket("pairs")) do
            if type(row) == "table" then
                local a, b = string.match(tostring(key), "^(.-)|(.+)$")
                local other = (a == uid and b) or (b == uid and a) or nil
                if other then
                    local w = M.closeness and select(1, M.closeness(other, uid)) or 0
                    local score = tonumber(row.s) or 0
                    if w >= 0.3 then
                        M.feel(other, "grief", math.min(1, w), "lost " .. tostring(nm))
                        M.feel(other, "sadness", 0.3 * w)
                        if args[3] ~= nil and M.killerOf then
                            local okK, _, kuid = pcall(M.killerOf, args[3], (type(ALifeSide) == "table" and ALifeSide.isOnlinePlayer(args[3])) and args[3] or M.you()) -- pre-1.0 MP: the killer, if a player
                            if okK and kuid == "player" then M.feel(other, "anger", 0.6 * w, "you killed " .. tostring(nm)) end
                        end
                    elseif score <= -40 then
                        M.feel(other, "relief", 0.2, tostring(nm) .. " is dead")
                    end
                end
            end
        end
    end)
    wrapM("noteAttack", function(args)
        local uid = args[1]
        if uid then M.feel(uid, "anger", 0.5, "you attacked them"); M.feel(uid, "fear", 0.35, "you attacked them") end
    end)
    wrapM("settlePromise", function(args)
        local uid, p, kept = args[1], args[2], args[3]
        if uid == nil then return end
        if kept == true or kept == "kept" then M.feel(uid, "gratitude", 0.3, "you kept your word"); M.feel(uid, "hope", 0.2)
        elseif kept ~= nil then M.feel(uid, "resentment", 0.35, "you broke a promise") end
    end)
    wrapM("addSound", function(args)
        local kind = args[1]
        if kind ~= "gunshot" and kind ~= "explosion" and kind ~= "alarm" and kind ~= "horde" then return end
        local x, y = args[3], args[4]
        if M.nearbyNpcs == nil or x == nil then return end
        for _, l in ipairs(M.nearbyNpcs(x, y, args[5] or 0, kind == "gunshot" and 25 or 35) or {}) do
            if l.record then M.feel(l.record.uid, (kind == "alarm" and "anxiety") or (kind == "horde" and "dread") or "fear", kind == "explosion" and 0.4 or 0.2, args[2]) end
        end
    end)
end

-- prompt: feelings, how they speak (dark / unhinged), needs + goal
table.insert(M.requestExtras, function(req, player, listener, now)
    if not (listener and listener.record) then return end
    local uid = listener.record.uid
    local psy = {}
    if M.settings.emotions ~= false then psy.mood = M.moodLine(uid) end
    psy.style = M.styleLine(uid)
    if M.settings.offscreenLives ~= false then psy.life = M.lifeLine(uid) end
    local kind = M.personaKind(uid)
    psy.kind = kind
    if M.hasAny(psy) then req.psyche = psy end
end)

----------------------------------------------------------------------------------------------------------------
-- settings + tick
----------------------------------------------------------------------------------------------------------------
for k, v in pairs({ emotions = true, offscreenLives = true, darkPersonas = true }) do
    if M.settings[k] == nil then M.settings[k] = v end
end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "emotions", "offscreenLives", "darkPersonas" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end

local tickN = 0
function M.psycheTick()
    if not M.worldHere() then return end
    tickN = tickN + 1
    if tickN == 30 then
        pcall(M.installPsycheHooks)
        M.detectMods()
        log("optional mods found: " .. (M.compat._list ~= "" and M.compat._list or "none"))
        if not M.compat.patch then log("note: ALifeTalkPatch is not enabled - shelter, orders, recruit following and betrayal actions stay off") end
    end
    if tickN % 300 == 150 then pcall(M.lifeTick) end
end
if type(Events) == "table" and Events.OnTick then
    ALifeHealth.tickAdd("ALifeLLMTalk_Psyche", function() local ok, e = pcall(M.psycheTick); if not ok then log("psyche tick error: " .. tostring(e)) end end)
end

return M
