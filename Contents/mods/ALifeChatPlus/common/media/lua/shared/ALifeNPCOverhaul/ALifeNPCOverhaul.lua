-- A-Life NPC Overhaul: makes typed chat with Project A-Life NPCs understand far more of what you type.
-- Wraps (never replaces) A-Life's own phrase matcher:
--   * slang and synonym canonicalising   ("grub" -> food, "walkers" -> zombies, "sry" -> sorry)
--   * typo correction against the words A-Life actually knows ("foood", "medcine", "trde")
--   * long messages split into clauses, so "hey man, got any food?" is heard as a food request
--   * fuzzy word-overlap fallback when no exact phrase matches
--   * short answers (yes/no/hello) no longer hijack longer sentences that merely contain "alright"
--   * door talk and visitor talk get the same treatment
-- Every hook keeps the original, calls it first, and only steps in when it failed or was weak.

require "ALifeNPCOverhaul/AA_Side"
local TAG = "[ALifeNPCOverhaul]"
local VERSION = ALifeSide.MOD_VERSION

ALifeNPCOverhaul = ALifeNPCOverhaul or {}
local CP = ALifeNPCOverhaul
CP.version = VERSION
CP.log = CP.log ~= false            -- print one line per rescued / missed message (useful for tuning)
CP.metrics = CP.metrics or { rescued = 0, missed = 0, typos = 0, doors = 0, visitors = 0 }

-- ---------------------------------------------------------------- guard ----
local disabled = {}
local function tryOnce(id, fn, ...)
    if disabled[id] then return false, nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return true, a, b end
    disabled[id] = true
    print(TAG .. " " .. id .. " failed, disabled for this session: " .. tostring(a))
    return false, nil
end

-- ------------------------------------------------------------- lexicon -----
-- Single words -> the word A-Life's patterns use. An entry is dropped automatically if A-Life
-- already uses the source word in a pattern, so this can never break an existing phrase.
local LEXICON = {
    helo = "hello", hullo = "hello", heyy = "hey", heyyy = "hey", hai = "hi", hiya = "hi", heya = "hey",
    mornin = "morning", evenin = "evening", goin = "going", nothin = "nothing", somethin = "something",
    anythin = "anything", doin = "doing", lookin = "looking", comin = "coming", talkin = "talking",
    thru = "through", tho = "though", b4 = "before", ppl = "people", abt = "about", n = "and",
    sry = "sorry", srry = "sorry", soz = "sorry", thnx = "thanks", thanx = "thanks", tysm = "thanks",
    cya = "see you", seeya = "see you", l8r = "later", gtg = "got to go", g2g = "got to go",
    sup = "what is up", wassup = "what is up", wazzup = "what is up", whassup = "what is up",
    yur = "your", yer = "your", urself = "yourself", yourselves = "yourself",
    walkers = "zombies", walker = "zombies", undead = "zombies", rotters = "zombies", roamers = "zombies",
    shamblers = "zombies", ghouls = "zombies", zombie = "zombies", zombos = "zombies",
    bandits = "raiders", bandit = "raiders", raider = "raiders", marauders = "raiders", hostiles = "raiders",
    looters = "raiders", thugs = "raiders",
    grub = "food", chow = "food", rations = "food", snacks = "food", groceries = "food", provisions = "food",
    vittles = "food", h2o = "water",
    meds = "medicine", medkit = "medicine", medication = "medicine", medications = "medicine", medicines = "medicine",
    ammunition = "ammo", cartridges = "ammo", mags = "ammo",
    definitely = "yes", absolutely = "yes", certainly = "yes", affirmative = "yes", yessir = "yes",
    pistol = "gun", handgun = "gun", revolver = "gun", firearm = "gun", shotgun = "gun",
    machete = "knife", blade = "knife",
}

-- Extra phrasings added to A-Life's own intents (only to intents that already exist).
local EXTRA = {
    THREATEN = "your ass is grass|ass is grass|gonna mow|im gonna kill you|i'm gonna kill you|you're dead|youre dead|you're a dead man|dead man walking|i'll end you|ill end you|i will end you|i'll put you down|ill put you down|gonna put you down|i'll bury you|ill bury you|you're finished|youre finished|last mistake|i'll shoot you|ill shoot you|i'll blow your head off|i'll cut you|ill cut you|try me|don't make me hurt you|dont make me hurt you|i'll hurt you|ill hurt you",
    OFFER_ITEM = "take this|take these|here take this|here take these|have this|have these|you can have this|you can have these|this is for you|these are for you|keep this|keep these|i brought you|i got you some",
    GREETING = "good morning|good evening|good afternoon|morning|evening|hello there|hey there|greetings|howdy|hey you",
    ASK_NAME = "what is your name|and you are|what should i call you|what do i call you|who am i talking to|your name",
    ASK_FOOD = "food|got food|any food|anything to eat|something to eat|spare some food|can of beans|need food|i need food|food to spare",
    ASK_WATER = "water|any water|need water|i need water|dying of thirst|a drink of water|clean water",
    ASK_MEDS = "medicine|any medicine|medical supplies|first aid kit|first aid|i need bandages|got bandages",
    ASK_AMMO = "ammo|any ammo|need ammo|rounds|bullets|9mm|shells",
    ASK_TRADE = "make a deal|lets deal|lets trade|trade|swap|barter|swap some stuff|what are you selling|you selling anything",
    HANDS_UP = "reach for the sky|put em up|hands where i can see them|get your hands up",
    I_AM_FRIENDLY = "i am a friend|friend not foe|i come in peace|i am not going to hurt you|not here to hurt|i am not here to hurt anyone|we mean no harm",
    SORRY = "did not mean that|did not mean it|my apologies|forgive me|i apologize",
    FAREWELL = "i am off|i am heading out|i should go|i got to go|got to go|see you|catch you later|stay safe",
    JOIN_REQUEST = "can i come along|let me come along|can i tag along|can i roll with you|take me with you|can i join|let me join",
    ASK_ZOMBIES_NEARBY = "a lot of dead around|lot of dead around here|any zombies|seen any zombies|many zombies around|how many zombies|how many infected|many infected around",
    ASK_RAIDERS = "any raiders|seen any raiders|bad people around|any bad people",
    ASK_NEWS = "what is happening out there|what is going on out there|any updates|any word",
    YES = "of course|for sure|you bet|sure thing",
    ASK_BITTEN = "any bites|bites on you|bite marks|did they bite you|did anything bite you",
    ASK_GROUP = "what is your groups name|what is your group called|what do you call your group",
    ASK_JOB_BEFORE = "what did you do before|before everything|what did you used to do|what did you do for a living",
    WARN_ZOMBIES = "zombies|zombies coming|zombies behind you|behind you|look out|watch your back",
    LOWER_WEAPON = "put the gun down|put the weapon down|put the knife down|lower the gun",
    REPEAT = "come again|what did you say|huh",
    ASK_HOW_LONG = "how long have you survived|how long have you been out here|how long have you lasted",
    ASK_LEADER = "who runs your group|who runs this place|who is the boss|who calls the shots",
    ASK_RIVER = "where is the river|which way to the river",
    COME_WITH_ME = "join us|join my group|join my base|come live with us|come live with me|you can stay with us|you can live with us|i have a safe place|we have a safe place|we have a base|i have a base|everything you need|just pitch in|pitch in|food water and shelter|food water shelter|we have food and water|come back to my base|come to my base",
    FLIRT = "i love you|i like you|you are beautiful|you are pretty|you are handsome|go out with me|be with me|will you be mine|be my partner|stay with me tonight|i missed you|kiss me|you look good",
    ASK_MILITARY = "what happened to the army|where is the army|what about the military|where is the national guard",
    GO_AWAY = "buzz off|get outta here|get out of here|leave me alone|scram|shoo|move along",
    HOW_ARE_YOU = "holding up|how you been|how have you been|you doing ok|you doing okay|how is it going",
    ASK_LOOT_SPOT = "where can i scavenge|good spots for loot|good places to loot|where to loot|where can i loot",
}

local PRACTICAL_EXTRA = {
    ASK_PASSAGE = "just passing through|passing through|can i get by|let me pass|let me by|can i get through|i just want to pass",
    ASK_TRADE = "lets trade|wanna trade|want to trade|make a deal",
    OFFER_HELP = "can i help|can i help you out|want a hand|need a hand",
}

-- Intents that are fine as a whole message but should not win a longer sentence on a partial hit.
local WEAK = { YES = true, NO = true, MAYBE = true, OK_ACK = true, GREETING = true, LAUGH = true, REPEAT = true }

-- 0.8.11.2 (Kingston "Hola" -> "hold" -> hands up): intents that start a hold-up, a fight or a robbery. A guess
-- (typo fix, fuzzy overlap) never lands on one of these, and the typo fixer never turns a word into one of their words.
-- Only the player's own exact words reach them.
local DANGER = { HANDS_UP = true, STOP_FREEZE = true, DROP_WEAPON = true, DEMAND_ITEMS = true, THREATEN = true,
    INSULT = true, GO_AWAY = true, LOWER_WEAPON = true, DOOR_LEAVE_RUDE = true, DOOR_SEARCH = true,
    DOOR_WEAPONS_DOWN = true }
local function isDanger(id)
    if id == nil then return false end
    id = tostring(id)
    return DANGER[id] == true or string.sub(id, 1, 6) == "ORDER_" or string.sub(id, 1, 6) == "FRISK_"
end
CP.isDanger = isDanger

-- Words ignored by the fuzzy overlap scorer (kept in the text for A-Life's own matcher).
local STOP = {}
for w in string.gmatch("i me my we us our you your yours the a an is are am was were be been do does did to of for in on at it its this that these those any some got get have has had can could would will shall should please just so like man men buddy pal dude brother hey um uh oh well really very there and or but then now ok okay yeah right alright mate sir maam lady guy guys folks all", "%S+") do STOP[w] = true end

-- ---------------------------------------------------------------- state -----
local Intents, Data
local baseNormalize          -- A-Life's own normalize (slang expansion)
local vocab, vocabList       -- word -> frequency; list of words
local lexicon                -- LEXICON minus entries A-Life already uses
local typoCache = {}
local built = false
local index                  -- fuzzy index: { {entry=, toks={set}, n=} ... }
local dangerWords = {}       -- 0.8.11.2: words of danger-intent patterns (the typo fixer never produces them)

local function words(s)
    local t, n = {}, 0
    for w in string.gmatch(s, "%S+") do n = n + 1; t[n] = w end
    return t, n
end

-- Optimal string alignment distance with an upper bound (returns bound+1 when exceeded).
local function osa(a, b, bound)
    local la, lb = #a, #b
    if math.abs(la - lb) > bound then return bound + 1 end
    local prev2, prev, cur = {}, {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur = {}
        cur[0] = i
        local rowMin = i
        local ca = string.byte(a, i)
        for j = 1, lb do
            local cb = string.byte(b, j)
            local cost = (ca == cb) and 0 or 1
            local v = prev[j] + 1
            if cur[j - 1] + 1 < v then v = cur[j - 1] + 1 end
            if prev[j - 1] + cost < v then v = prev[j - 1] + cost end
            if i > 1 and j > 1 and ca == string.byte(b, j - 1) and string.byte(a, i - 1) == cb then
                if prev2[j - 2] + 1 < v then v = prev2[j - 2] + 1 end
            end
            cur[j] = v
            if v < rowMin then rowMin = v end
        end
        if rowMin > bound then return bound + 1 end
        prev2, prev = prev, cur
    end
    return prev[lb]
end

local function correct(w)
    if vocab == nil or vocab[w] ~= nil then return w end
    local cached = typoCache[w]
    if cached ~= nil then return cached end
    local len = #w
    if len < 3 or string.find(w, "^%d") then typoCache[w] = w; return w end
    local bound = (len <= 5) and 1 or 2
    local first, last = string.sub(w, 1, 1), string.sub(w, -1)
    local best, bestD, bestRank = nil, bound + 1, -1
    for i = 1, #vocabList do
        local cand = vocabList[i]
        if #cand >= 3 and math.abs(#cand - len) <= bound and not dangerWords[cand] then
            local d = osa(w, cand, bound)
            if d <= bound then
                local rank = vocab[cand]
                if string.sub(cand, 1, 1) == first then rank = rank + 10000 end
                if string.sub(cand, -1) == last then rank = rank + 5000 end
                if d < bestD or (d == bestD and rank > bestRank) then best, bestD, bestRank = cand, d, rank end
            end
        end
    end
    -- three-letter words: only fix when the first letter agrees (avoids "yes" -> "yet" style surprises)
    if best ~= nil and len == 3 and string.sub(best, 1, 1) ~= first then best = nil end
    typoCache[w] = best or w
    if best ~= nil then CP.metrics.typos = CP.metrics.typos + 1 end
    return best or w
end

-- lexicon + optional typo pass over an already base-normalized string
local function polish(s, fixTypos)
    local out, n = {}, 0
    for w in string.gmatch(s, "%S+") do
        local mapped = (lexicon or LEXICON)[w]
        if mapped == nil and fixTypos then
            mapped = correct(w)
            local again = (lexicon or LEXICON)[mapped]
            if again ~= nil then mapped = again end
        end
        n = n + 1
        out[n] = mapped or w
    end
    return table.concat(out, " ")
end

local function addVocab(s)
    for w in string.gmatch(s, "%S+") do vocab[w] = (vocab[w] or 0) + 1 end
end

local function build()
    if built then return true end
    if Data == nil or type(Data.load) ~= "function" then return false end
    pcall(Data.load)
    if type(Data.intents) ~= "table" or #Data.intents == 0 then return false end
    built = true
    -- 1) extra phrasings
    local added = 0
    for id, list in pairs(EXTRA) do
        if Data.intentById ~= nil and Data.intentById[id] ~= nil then
            Data.intent(id, nil, list)
            for _ in string.gmatch(list, "[^|]+") do added = added + 1 end
        end
    end
    -- A-Life's built-in "practical" intents live outside the data tables
    for _, e in ipairs(Intents.practical or {}) do
        local more = PRACTICAL_EXTRA[e.id]
        if more ~= nil and type(e.patterns) == "table" then
            for p in string.gmatch(more, "[^|]+") do e.patterns[#e.patterns + 1] = p; added = added + 1 end
        end
    end
    -- 2) which source words does A-Life already use? those lexicon entries are dropped
    local raw = {}
    local function rawWords(s) for w in string.gmatch(baseNormalize(s), "%S+") do raw[w] = true end end
    for _, e in ipairs(Data.intents) do for _, p in ipairs(e.patterns or {}) do rawWords(p) end end
    lexicon = {}
    local dropped = 0
    for k, v in pairs(LEXICON) do
        if raw[k] then dropped = dropped + 1 else lexicon[k] = v end
    end
    -- 3) vocabulary for typo correction
    vocab, vocabList = {}, {}
    local function feed(s) addVocab(polish(baseNormalize(s), false)) end
    for _, e in ipairs(Data.intents) do
        for _, p in ipairs(e.patterns or {}) do feed(p) end
        for _, g in ipairs(e.all or {}) do for _, w in ipairs(g) do feed(w) end end
    end
    for _, e in ipairs(Intents.practical or {}) do for _, p in ipairs(e.patterns or {}) do feed(p) end end
    for _, c in ipairs(Intents.choices or {}) do if type(c.words) == "string" then feed(c.words) end end
    for _, list in pairs(CP.DOOR or {}) do for _, p in ipairs(list) do feed(p) end end
    local regions = ProjectALife and ProjectALife.TownRegions
    if regions ~= nil and type(regions.definitions) == "table" then
        for _, d in ipairs(regions.definitions) do if type(d.label) == "string" then feed(d.label) end end
    end
    for w in pairs(vocab) do vocabList[#vocabList + 1] = w end
    dangerWords = {}
    local function dangerFeed(s2) for w in string.gmatch(polish(baseNormalize(s2), false), "%S+") do if not STOP[w] then dangerWords[w] = true end end end
    for _, e in ipairs(Data.intents) do if isDanger(e.id) then for _, p in ipairs(e.patterns or {}) do dangerFeed(p) end end end
    for _, e in ipairs(Intents.practical or {}) do if isDanger(e.id) then for _, p in ipairs(e.patterns or {}) do dangerFeed(p) end end end
    for _, c in ipairs(Intents.choices or {}) do if isDanger(c.id) and type(c.words) == "string" then dangerFeed(c.words) end end
    typoCache = {}
    index = nil
    Intents.cache = {}
    -- every phrase A-Life understands, for the voice helper's grammar (big accuracy boost for speech)
    pcall(function()
        if type(getFileWriter) ~= "function" then return end
        local seen, list = {}, {}
        local function put(t)
            if type(t) ~= "string" then return end
            t = string.lower(t)
            t = string.gsub(t, "[^a-z0-9' ]", " ")
            t = string.gsub(t, "%s+", " ")
            t = string.gsub(t, "^ ", ""); t = string.gsub(t, " $", "")
            if #t >= 2 and #t <= 80 and not seen[t] then seen[t] = true; list[#list + 1] = t end
        end
        for _, e in ipairs(Data.intents) do for _, ph in ipairs(e.patterns or {}) do put(ph) end end
        for _, e in ipairs(Intents.practical or {}) do for _, ph in ipairs(e.patterns or {}) do put(ph) end end
        for _, c in ipairs(Intents.choices or {}) do put(c.words); put(c.text) end
        for _, l in pairs(CP.DOOR or {}) do for _, ph in ipairs(l) do put(ph) end end
        local w = getFileWriter("alifeai_phrases.txt", true, false)
        if w ~= nil then
            for i = 1, #list do w:write(list[i] .. "\n") end
            w:close()
        end
    end)
    print(TAG .. " ready: +" .. added .. " phrasings, " .. #vocabList .. " known words, lexicon " ..
        (dropped > 0 and ("(" .. dropped .. " entries already native) ") or "") .. "active")
    return true
end

local function looksForeign(text)
    return ALifeLanguage ~= nil and type(ALifeLanguage.looksForeign) == "function" and ALifeLanguage.looksForeign(text) == true
end
CP.looksForeign = looksForeign

local function plusNormalize(text)
    local base = baseNormalize(text)
    if not built then build() end
    if not built then return base end
    -- 0.8.11.2: another language is not English with typos ("hola" is not "hold")
    if looksForeign(text) then return base end
    return polish(base, true)
end

-- --------------------------------------------------------------- fuzzy -----
local function contentSet(s)
    local set, n = {}, 0
    for w in string.gmatch(s, "%S+") do
        if not STOP[w] and set[w] == nil then set[w] = true; n = n + 1 end
    end
    return set, n
end

local function buildIndex()
    index = {}
    local function add(entry, pattern)
        local set, n = contentSet(Intents.normalize(pattern))
        if n > 0 then index[#index + 1] = { entry = entry, toks = set, n = n } end
    end
    for _, e in ipairs(Intents.practical or {}) do for _, p in ipairs(e.patterns or {}) do add(e, p) end end
    for _, e in ipairs(Data.intents or {}) do for _, p in ipairs(e.patterns or {}) do add(e, p) end end
end

local function fuzzy(normalized)
    if index == nil then buildIndex() end
    local inSet, inN = contentSet(normalized)
    if inN == 0 then return nil, 0 end
    local bestId, bestScore, bestPri = nil, 0, -1
    local vetoed = {}
    for i = 1, #index do
        local row = index[i]
        local e = row.entry
        -- pre-1.0: DRIVE_* never fuzzy ("exit the car" / "watch the car" -> DRIVE_GET_IN: pattern "get in the car" is only {car})
        if not vetoed[e] and not isDanger(e.id) and string.sub(tostring(e.id), 1, 6) ~= "DRIVE_" then
            local m = 0
            for w in pairs(row.toks) do if inSet[w] then m = m + 1 end end
            if m > 0 and (m >= 2 or (row.n == 1 and inN <= 2)) and not (WEAK[e.id] and inN >= 2) then
                local r = m / row.n
                if r >= 0.6 then
                    if Intents.score(e, normalized) < 0 then
                        vetoed[e] = true
                    else
                        local s = 30 + math.floor(20 * r + 8 * (m / inN))
                        if s > 58 then s = 58 end
                        local pri = tonumber(e.priority) or 50
                        if s > bestScore or (s == bestScore and pri > bestPri) then
                            bestId, bestScore, bestPri = e.id, s, pri
                        end
                    end
                end
            end
        end
    end
    return bestId, bestScore
end

-- split the raw text into clauses on punctuation and a few joining words
local function clauses(text)
    local out = {}
    local s = string.lower(tostring(text or ""))
    s = string.gsub(s, "[%.!%?;:,]+", "|")
    s = string.gsub(s, " but ", "|")
    s = string.gsub(s, " so ", "|")
    s = string.gsub(s, " and then ", "|")
    for part in string.gmatch(s, "[^|]+") do
        if string.find(part, "%a") then out[#out + 1] = part end
    end
    return out
end

-- ------------------------------------------------------------ classify -----
local origClassify

-- did the player really say a danger intent's words? (exact phrase on the text as typed, no typo fixes)
local function saidPlainly(text, id)
    local plain = baseNormalize(text)
    if plain == "" then return false end
    local need = Intents.threshold or 30
    for _, e in ipairs(Intents.practical or {}) do
        if e.id == id and (Intents.score(e, plain) or 0) >= 60 then return true end
    end
    for _, e in ipairs((Data and Data.intents) or {}) do
        if e.id == id and (Intents.score(e, plain) or 0) >= need then return true end
    end
    return false
end
CP._saidPlainly = function(t, id) return saidPlainly(t, id) end

local function plusClassify(text, pending, data)
    CP.lastHow = nil -- set below; an early return must not leave the last line's "fuzzy" for heardFilter
    local id, score = origClassify(text, pending, data)
    if not built then return id, score end
    if pending == true and (id == "YES" or id == "NO") then return id, score end
    -- 0.8.11.2: a danger intent the player didn't plainly say (A-Life's own match on typo-fixed words, an "all" group
    -- hit) is dropped: nobody gets held up or insulted by a misheard word. The AI reads the line instead.
    if isDanger(id) and not saidPlainly(text, id) then
        if CP.log then print(TAG .. " '" .. tostring(text) .. "' looked like " .. tostring(id) .. " only after guessing: not taken") end
        CP.lastHow, CP.lastScore = "danger_guess", 0
        return nil, 0
    end
    -- 0.8.11.2: another language: no English guessing (the AI understands it; A-Life's own exact match stays)
    if looksForeign(text) then
        CP.lastHow, CP.lastScore = "foreign", score or 0
        if CP.log and id == nil then print(TAG .. " foreign line, left for the AI: '" .. tostring(text) .. "'") end
        return id, score
    end
    local normalized = Intents.normalize(text)
    local _, wc = words(normalized)
    local weakHit = id ~= nil and WEAK[id] and (score or 0) < 100 and wc >= 5
    if id ~= nil and (score or 0) >= 60 and not weakHit then return id, score end

    local bestId, bestScore, how = id, score or 0, nil
    if weakHit then bestScore = bestScore - 30 end

    -- clauses: the request usually sits in one of them
    local parts = clauses(text)
    if #parts > 1 then
        for i = 1, #parts do
            local cid, cs = origClassify(parts[i], pending, data)
            if cid ~= nil and cs ~= nil then
                local eff = cs
                if WEAK[cid] then eff = eff - 15 end
                if eff >= bestScore then bestId, bestScore, how = cid, eff, "clause" end
            end
        end
    end
    -- fuzzy word overlap: fills gaps, and only overrides a real (non-weak) A-Life answer by a clear margin
    if bestScore < 60 then
        local fid, fs = fuzzy(normalized)
        local margin = (bestId ~= nil and not WEAK[bestId] and how == nil and not weakHit) and 8 or 1
        if fid ~= nil and fs >= bestScore + margin then bestId, bestScore, how = fid, fs, "fuzzy" end
    end

    CP.lastHow, CP.lastScore = how, bestScore
    -- a fuzzy guess is only a guess: with the AI running it gets a second opinion (ChatAI); without it, a weak guess
    -- is treated as not understood so they ask "what?" instead of answering a question you didn't ask
    if how == "fuzzy" and bestScore < 50 and not (ALifeChatAI ~= nil and type(ALifeChatAI.alive) == "function" and ALifeChatAI.alive()) then
        CP.metrics.missed = CP.metrics.missed + 1
        if CP.log then print(TAG .. " unsure about '" .. tostring(text) .. "' (fuzzy " .. tostring(bestId) .. "), asking again") end
        return nil, 0
    end
    if bestId ~= nil and bestScore >= (Intents.threshold or 30) then
        if bestId ~= id then
            CP.metrics.rescued = CP.metrics.rescued + 1
            if CP.log then
                ALifeHealth.note(TAG, "heard '" .. tostring(text) .. "' as " .. bestId .. " (" .. tostring(how or "weak") ..
                    ", was " .. tostring(id) .. ")")
            end
        end
        return bestId, math.max(bestScore, Intents.threshold or 30)
    end
    if id == nil then
        CP.metrics.missed = CP.metrics.missed + 1
        if CP.log then print(TAG .. " not understood: '" .. tostring(text) .. "'") end
    end
    return id, score
end

-- ------------------------------------------------------- heard filter -----
-- pre-1.0 (edge corpus, Nov 27: 5000 generated orders run through the real path): last word on what a line was heard
-- as. Each rule drops a reading the player can't have meant; nil = not understood (the AI reads it, or they ask).
-- 1. said to one of your own people: no hold-up / robbery / threat against them ("dont move", "hand over the keys")
-- 2. A-Life's bare "stop" pattern makes any line with "stop" a hold-up: not a question ("why did you stop"), not
--    "stop <something>" ("stop being weird", "stop the car"); plain "stop", "stop right there", "stop now" stay
-- 3. some intents need one of their own words: "back to work" / "fight back" are not GIVE_BACK
-- 4. a fuzzy guess never makes an NPC do something ("come on really" -> follow, "ditch that" -> "pitch in" -> join)
CP.STOP_OK_AFTER = { right = true, there = true, now = true, it = true, please = true, pls = true, man = true, dude = true }
CP.QUESTION_LEAD = { why = true, what = true, how = true, when = true, where = true, who = true, ["do"] = true, does = true,
    did = true, can = true, could = true, are = true, is = true, will = true, would = true, have = true, wat = true, y = true }
CP.NEEDS_WORD = { GIVE_BACK = { "give", "return", "mine", "stole", "my stuff", "my things" } }
CP.FUZZY_NO_ACTION = { FOLLOW_ME = true, COME_WITH_ME = true, WAIT_HERE = true, WALK_WITH_ME = true, JOIN_REQUEST = true,
    WALK_STOP = true, GO_AWAY = true, OFFER_ITEM = true, GIVE_BACK = true }
CP.INTERJECTION = { FOLLOW_ME = { "come on" }, WAIT_HERE = { "hold on", "hang on" } }
CP.SIGH_WORDS = { "really", "seriously", "think", "no way", "kidding", "for real", "srsly", "rly" }
function CP.heardFilter(text, id, score)
    if id == nil or id == "YES" or id == "NO" then return id, score end
    local low = " " .. string.gsub(string.lower(tostring(text or "")), "[^%w']+", " ") .. " "
    local why
    local M = ALifeLLMTalk
    local own = type(M) == "table" and type(M.ownLine) == "table" and M.ownLine.text == text
    if own and isDanger(id) then why = "threat at your own people" end
    if why == nil and id == "STOP_FREEZE" then
        local first = string.match(low, "^ (%S+)")
        local after = string.match(low, " stop (%S+) ")
        if CP.QUESTION_LEAD[first or ""] or string.find(tostring(text), "?", 1, true) then why = "question"
        elseif after ~= nil and not CP.STOP_OK_AFTER[after] and not string.find(low, " freeze ", 1, true)
                and not string.find(low, " move ", 1, true) and not string.find(low, " halt ", 1, true) then
            why = "stop <" .. after .. ">"
        end
    end
    if why == nil and CP.NEEDS_WORD[id] then
        local has = false
        for _, w in ipairs(CP.NEEDS_WORD[id]) do if string.find(low, " " .. w .. " ", 1, true) then has = true end end
        if not has then why = "missing its words" end
    end
    if why == nil and CP.lastHow == "fuzzy" and CP.FUZZY_NO_ACTION[id] then why = "fuzzy guess" end
    -- 5. "come on" / "hold on" as a sigh, not an order: "come on really", "hold on a sec let me think"
    if why == nil and CP.INTERJECTION[id] and type(ALifeOrderText) == "table" and type(ALifeOrderText.clean) == "function" then
        local okC, c = pcall(ALifeOrderText.clean, text)  -- typo'd sighs too ("come on raelly")
        if okC and type(c) == "string" then low = low .. " " .. string.gsub(c, "[^%w']+", " ") .. " " end
    end
    if why == nil and CP.INTERJECTION[id] then
        for _, w in ipairs(CP.INTERJECTION[id]) do
            if string.find(low, " " .. w .. " ", 1, true) then
                for _, c in ipairs(CP.SIGH_WORDS) do
                    if string.find(low, " " .. c .. " ", 1, true) then why = "'" .. w .. "' as a sigh" end
                end
            end
        end
    end
    if why == nil then return id, score end
    CP.lastHow, CP.lastScore = "filtered", 0
    if CP.log then print(TAG .. " '" .. tostring(text) .. "' looked like " .. tostring(id) .. ", not taken: " .. why) end
    return nil, 0
end

-- ---------------------------------------------------------------- door -----
CP.DOOR = {
    DOOR_WHO = { "who is it", "who is there", "who are you", "what do you want", "what brings you here",
        "why are you here", "state your business", "what is your business", "who goes there", "hello" },
    DOOR_NEED = { "what do you need", "what do you want from me", "how can i help you" },
    DOOR_HEALTH = { "are you hurt", "are you bitten", "are you bit", "are you injured", "any bites", "are you sick",
        "did you get bit", "you hurt" },
    DOOR_COMPANY = { "are you alone", "did you come alone", "anyone with you", "how many of you", "who is with you" },
    DOOR_STAY = { "how long do you need to stay", "how long will you stay", "how long" },
    DOOR_LEAVE = { "leave", "go away", "get lost", "not today", "no thanks", "i can not help you", "please leave",
        "move along", "beat it", "keep moving" },
    DOOR_LEAVE_RUDE = { "fuck off", "piss off", "get the hell away", "get off my property", "scram" },
    DOOR_GIVE = { "give food", "here is some food", "take some food", "have some food" },
    DOOR_SEARCH = { "let me search you", "search you", "empty your pockets", "turn out your pockets",
        "let me check your bag", "let me see your bag" },
    DOOR_WEAPONS_DOWN = { "drop your weapon", "put your weapon down", "lower your weapon", "weapons down",
        "put the gun down", "drop the gun", "drop it" },
    DOOR_INVITE = { "come in", "come inside", "get in here", "you can stay", "you can come in", "door is open" },
    GUEST_LEAVE = { "time to go", "time for you to go", "you need to leave now" },
    DOOR_TRADE = { "trade", "what do you have", "what have you got", "got anything to trade" },
    DOOR_THANK = { "thank you", "thanks" },
    DOOR_ASK_A = { "tell me more" },
    DOOR_TREAT = { "let me treat that", "let me patch you up", "i can bandage that", "let me look at that" },
}
local DOOR_FROM_INTENT = {
    GREETING = "DOOR_WHO", WHO_ARE_YOU = "DOOR_WHO", ASK_NAME = "DOOR_WHO",
    GO_AWAY = "DOOR_LEAVE", INSULT = "DOOR_LEAVE_RUDE", ASK_TRADE = "DOOR_TRADE",
    DROP_WEAPON = "DOOR_WEAPONS_DOWN", LOWER_WEAPON = "DOOR_WEAPONS_DOWN",
    ASK_BITTEN = "DOOR_HEALTH", ASK_OKAY = "DOOR_HEALTH", ASK_HOW_MANY = "DOOR_COMPANY",
    ASK_NEED = "DOOR_NEED", THANKS = "DOOR_THANK",
}
local origDoorFor

local function plusDoorFor(text, intent)
    local r = origDoorFor(text, intent)
    if r ~= nil or intent ~= nil or not built then return r end
    local n = Intents.normalize(text)
    local padded = " " .. n .. " "
    local best, bestLen = nil, 0
    for id, list in pairs(CP.DOOR) do
        for _, p in ipairs(list) do
            local np = Intents.normalize(p)
            if np == n then best, bestLen = id, 1000
            elseif #np > bestLen and string.find(padded, " " .. np .. " ", 1, true) then best, bestLen = id, #np end
        end
    end
    if best == nil then
        local cid = plusClassify(text, false)
        best = cid and DOOR_FROM_INTENT[cid] or nil
    end
    if best ~= nil then
        CP.metrics.doors = CP.metrics.doors + 1
        if CP.log then print(TAG .. " door: '" .. tostring(text) .. "' as " .. best) end
    end
    return best
end

-- ------------------------------------------------------------- visitor -----
local origVT
local vtIndex                -- { {id=, padded=, toks=, n=} }

local function plusVisitorClassify(text)
    local id, s = origVT(text)
    if id ~= nil or not built then return id, s end
    local VT = ProjectALife.VisitorTalk
    local list = type(VT.patternIndex) == "function" and VT.patternIndex() or nil
    if list == nil then return id, s end
    if vtIndex == nil then
        vtIndex = {}
        for i = 1, #list do
            local np = plusNormalize(list[i].text)
            local set, n = contentSet(np)
            vtIndex[#vtIndex + 1] = { id = list[i].id, padded = " " .. np .. " ", size = #np, toks = set, n = n }
            addVocab(np)
        end
    end
    local n = plusNormalize(text)
    local hay = " " .. n .. " "
    local best, bestScore = nil, 0
    for i = 1, #vtIndex do
        local e = vtIndex[i]
        if e.size > bestScore and string.find(hay, e.padded, 1, true) then best, bestScore = e.id, e.size end
    end
    if best == nil then
        local inSet, inN = contentSet(n)
        local bestF = 0
        if inN > 0 then
            for i = 1, #vtIndex do
                local e = vtIndex[i]
                local m = 0
                for w in pairs(e.toks) do if inSet[w] then m = m + 1 end end
                if m > 0 and (m >= 2 or e.n == 1) and m / e.n >= 0.6 then
                    local f = m / e.n + 0.3 * m / inN
                    if f > bestF then best, bestF = e.id, f end
                end
            end
        end
        if best ~= nil then bestScore = 3 end
    end
    if best ~= nil then
        CP.metrics.visitors = CP.metrics.visitors + 1
        if CP.log then print(TAG .. " visitor heard '" .. tostring(text) .. "' as " .. tostring(best)) end
    end
    return best, bestScore
end

-- ------------------------------------------------------------- install -----
local function installTalk()
    Intents = ProjectALife and ProjectALife.TalkIntents
    Data = ProjectALife and ProjectALife.DialogueData
    if Intents == nil or Data == nil then return false end
    if Intents.__ChatPlus_wrapped then return true end
    if type(Intents.normalize) ~= "function" or type(Intents.classify) ~= "function"
            or type(Intents.score) ~= "function" then
        print(TAG .. " A-Life talk API not as expected, chat upgrade not installed")
        return true
    end
    Intents.__ChatPlus_wrapped = true
    baseNormalize = Intents.normalize
    origClassify = Intents.classify
    Intents.normalize = function(text)
        local ok, r = tryOnce("normalize", plusNormalize, text)
        if ok and r ~= nil then return r end
        return baseNormalize(text)
    end
    Intents.classify = function(text, pending, data)
        local ok, a, b = tryOnce("classify", plusClassify, text, pending, data)
        if ok then
            local okF, fa, fb = pcall(CP.heardFilter, text, a, b)
            if okF then return fa, fb end
            return a, b
        end
        return origClassify(text, pending, data)
    end
    if type(Intents.doorFor) == "function" then
        origDoorFor = Intents.doorFor
        Intents.doorFor = function(text, intent)
            local ok, r = tryOnce("doorFor", plusDoorFor, text, intent)
            if ok then return r end
            return origDoorFor(text, intent)
        end
    end
    Intents.cache = {}
    print(TAG .. " hooked TalkIntents.normalize/classify" .. (origDoorFor and "/doorFor" or ""))
    return true
end

local function installVisitors()
    local VT = ProjectALife and ProjectALife.VisitorTalk
    if VT == nil then return false end
    if VT.__ChatPlus_wrapped then return true end
    if type(VT.classify) ~= "function" then return true end
    VT.__ChatPlus_wrapped = true
    origVT = VT.classify
    VT.classify = function(text)
        local ok, a, b = tryOnce("visitorClassify", plusVisitorClassify, text)
        if ok then return a, b end
        return origVT(text)
    end
    print(TAG .. " hooked VisitorTalk.classify")
    return true
end

function CP.install()
    local a = installTalk()
    local b = installVisitors()
    return a, b
end

-- expose for tests / console poking
CP._plusNormalize = function(t) return plusNormalize(t) end
CP._build = function() return build() end

pcall(require, "ProjectALife/Talk/ALifeTalkIntents")
CP.install()
if Events ~= nil then
    local function late()
        CP.install()
        if built == false and Intents ~= nil and Intents.__ChatPlus_wrapped then build() end
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(late) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(late) end
end
print(TAG .. " loaded v" .. VERSION)
