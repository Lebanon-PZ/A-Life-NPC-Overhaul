-- A-Life NPC Overhaul pre-1.0 (Nov 27, edge corpus): "close enough" orders.
-- One clean-up for a typed order line before the order readers look at it (ALifeCommands.parse, ALifeLLMTalk.parseOrder):
--   * texting slang to words ("u" -> you, "ur" -> your, "n" -> and, "gimme" -> give me, "every1" -> everyone ...),
--     game slang to the words the commands use ("zeds" -> zombies, "shotty" -> shotgun, "truck" -> car ...);
--   * stretched letters ("stooop" -> stop);
--   * typos fixed against the words the commands actually use ("siphn" -> siphon, "folow" -> follow): one letter off
--     (dropped, extra, wrong or two swapped) for words of 5+ letters, two for 8+, same first letter, only when one
--     command word is the closest. Short words, capitalised words (names) and common English words are never changed.
-- The readers try the line as typed first and only then this clean copy, so nothing that matched before stops matching.
-- Settings: orderCloseEnough (on), orderTypoFix (on).
ALifeOrderText = ALifeOrderText or {}
local T = ALifeOrderText
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end

do
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" then
        M.fileKeys = M.fileKeys or {}
        for _, k in ipairs({ "orderCloseEnough", "orderTypoFix" }) do
            if M.settings[k] == nil then M.settings[k] = true end
            local have = false
            for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
            if not have then M.fileKeys[#M.fileKeys + 1] = k end
        end
    end
end
local function setting(k)
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.settings) == "table" and M.settings[k] == false then return false end
    return true
end

T.SLANG = {
    u = "you", yu = "you", ya = "you", yah = "you", ur = "your", yer = "your", youre = "you're", r = "are", n = "and",
    w = "with", wit = "with", b4 = "before", pls = "please", plz = "please", plez = "please", em = "them", dem = "them",
    gimme = "give me", lemme = "let me", gotta = "got to", wanna = "want to", gonna = "going to", outta = "out of",
    every1 = "everyone", evry1 = "everyone", evryone = "everyone", everybodys = "everybody's", some1 = "someone",
    ppl = "people", rn = "right now", cuz = "because", coz = "because", da = "the", tha = "the", teh = "the",
    dat = "that", dis = "this", ova = "over", bout = "about", im = "i'm", ive = "i've", ill = "i'll", cmon = "come on",
    yall = "you all", ["y'all"] = "you all", alot = "a lot", ok = "ok", okay = "ok", k = "ok", kk = "ok",
    thx = "thanks", ty = "thanks", urself = "yourself", yurself = "yourself", yourslef = "yourself", urselves = "yourselves",
    bak = "back", bck = "back", wod = "wood", wud = "wood", fite = "fight", hlep = "help", hepl = "help", mee = "me",
    ot = "to", nto = "not", dnt = "dont", thnk = "think", thnik = "think", tihnk = "think", realy = "really", rly = "really",
    srs = "seriously", fr = "for real",
    gud = "good", liek = "like", wat = "what", wut = "what", y = "why", luv = "love", ded = "dead", nvm = "never mind", asap = "now", srsly = "seriously",
    zed = "zombie", zeds = "zombies", zeke = "zombie", zekes = "zombies", zombs = "zombies", zombos = "zombies",
    biters = "zombies", walkers = "zombies", rotters = "zombies", shamblers = "zombies", infected = "zombies",
    shotty = "shotgun", shottie = "shotgun", boomstick = "shotgun", piece = "gun", strap = "gun", gat = "gun", heater = "gun",
    mag = "magazine", mags = "magazine", meds = "meds", grub = "food", chow = "food",
    truck = "car", van = "car", pickup = "car", suv = "car", jeep = "car", whip = "car", vehicle = "car", motor = "car",
    torch = "flashlight", flashy = "flashlight", gas = "gas", petrol = "gas", fuel = "gas",
}
-- real words people type that look like a typo of a command word: never "fixed"
T.COMMON = {}
for w in string.gmatch([[
said talking walking taking drinks drink thinks shoots shooting shot shots messenger space seriously outside
the and you your that this with have from they will would there their been were when what about know just like time good
some could them than then look only come over think also back after work first well even want because these give most
really yeah right sure need feel said tell make thing still here where much many love help kill dead fire food safe base
home stay wait hold stop move shot shoot hole pitch ditch fold sold told cold bold gold mold fight light night right tight
might sight shit fuck damn hell crap please thanks sorry maybe never always again later today tonight tomorrow morning
house place water stuff other another every never something nothing anything everything someone anyone everyone people
little great guess wrong while where which whose whole world worse worst better best should shall shoot shout short
sleep sleepy steep sweep sweet street strong string stand stance start smart smell spell spill still stall story
cover clover lover hover lower power tower mover river liver giver diver fever never sever clever
watch witch match catch batch patch latch hatch crash trash brash flash clash splash
drive drove drink drunk dream bread break bring brought train track truck trust trick
plant plank planet planes plans plane place plate slate state skate
chop chip chap cheap check cheek chick chuck clean clear close cloth clothes
guard grand grant great green greed group grow growl
siphon]], "%a+") do T.COMMON[w] = true end

-- words that change what a line means (sighs, disbelief): typos of these get fixed too, so the filters see them
T.EXTRA_VOCAB = "really seriously kidding think thinking please"
-- words the order readers know (rebuilt when the command list grows)
local vocab, vocabN, byFirst = {}, -1, {}
local function addWords(s)
    for w in string.gmatch(string.lower(tostring(s or "")), "%a[%a']*") do
        if #w >= 4 and not vocab[w] then
            vocab[w] = true
            local f = string.sub(w, 1, 1)
            byFirst[f] = byFirst[f] or {}
            byFirst[f][#byFirst[f] + 1] = w
        end
    end
end
function T.vocab()
    local C = ALifeCommands
    local n = (type(C) == "table" and type(C.CMDS) == "table") and #C.CMDS or 0
    local M = ALifeLLMTalk
    local o = (type(M) == "table" and type(M.orderWords) == "table") and #M.orderWords or 0
    if n * 100 + o == vocabN then return vocab end
    vocab, byFirst = {}, {}
    if n > 0 then for _, c in ipairs(C.CMDS) do for _, w in ipairs(c.words or {}) do addWords(w) end end end
    if type(C) == "table" and type(C.NOUNS) == "table" then for k, list in pairs(C.NOUNS) do addWords(k); for _, w in ipairs(list) do addWords(w) end end end
    if o > 0 then for _, row in ipairs(M.orderWords) do for _, w in ipairs(row[2]) do addWords(w) end end end
    for _, v in pairs(T.SLANG) do addWords(v) end
    addWords(T.EXTRA_VOCAB)
    vocabN = n * 100 + o
    return vocab
end
-- every word in A-Life's own talk patterns is a real word people type: never "fix" those into something else
-- (A-Life loads its talk data lazily: rebuilt when the intent count changes)
T.KNOWN, T.knownN = {}, -1
function T.known()
    local n = 0
    pcall(function() n = #ProjectALife.DialogueData.intents end)
    if n == T.knownN then return T.KNOWN end
    local k = {}
    pcall(function()
        for _, e in ipairs(ProjectALife.DialogueData.intents or {}) do
            for _, p in ipairs(e.patterns or {}) do
                for w in string.gmatch(string.lower(tostring(p)), "%a+") do k[w] = true end
            end
        end
    end)
    T.KNOWN, T.knownN = k, n
    return k
end

-- Damerau-Levenshtein (optimal string alignment), stops early past `cap`
local function dist(a, b, cap)
    local la, lb = #a, #b
    if math.abs(la - lb) > cap then return cap + 1 end
    local prev2, prev, cur = {}, {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur = { [0] = i }
        local rowMin = i
        local ai = string.sub(a, i, i)
        for j = 1, lb do
            local cost = (ai == string.sub(b, j, j)) and 0 or 1
            local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if i > 1 and j > 1 and ai == string.sub(b, j - 1, j - 1) and string.sub(a, i - 1, i - 1) == string.sub(b, j, j) then
                v = math.min(v, prev2[j - 2] + 1)
            end
            cur[j] = v
            if v < rowMin then rowMin = v end
        end
        if rowMin > cap then return cap + 1 end
        prev2, prev = prev, cur
    end
    return prev[lb]
end
T.dist = dist

-- two letters swapped, nothing else ("hlod" -> "hold"): safe enough for 4-letter words
local function swapOf(a, b)
    if #a ~= #b then return false end
    for i = 1, #a - 1 do
        if string.sub(a, i, i) ~= string.sub(b, i, i) then
            return string.sub(a, i, i) == string.sub(b, i + 1, i + 1) and string.sub(a, i + 1, i + 1) == string.sub(b, i, i)
                and string.sub(a, i + 2) == string.sub(b, i + 2)
        end
    end
    return false
end
function T.fixWord(w)
    local v = T.vocab()
    if v[w] or T.COMMON[w] or T.known()[w] then return w end
    if #w == 4 then
        local hit = nil
        for _, c in ipairs(byFirst[string.sub(w, 1, 1)] or {}) do
            if swapOf(w, c) then if hit ~= nil then return w end; hit = c end
        end
        return hit or w
    end
    if #w < 5 then return w end
    local cap = (#w >= 8) and 2 or 1
    local best, bestD, ties = nil, cap + 1, {}
    for _, c in ipairs(byFirst[string.sub(w, 1, 1)] or {}) do
        local d = dist(w, c, cap)
        if d < bestD then best, bestD, ties = c, d, { c }
        elseif d == bestD then ties[#ties + 1] = c end
    end
    if best == nil then return w end
    if #ties == 1 then return best end
    -- a tie: two swapped letters is the likeliest slip ("raelly" is really, not rally)
    local swap = nil
    for _, c in ipairs(ties) do if swapOf(w, c) then if swap ~= nil then return w end; swap = c end end
    return swap or w
end

-- three or more of the same letter in a row -> two ("shooot" -> "shoot"); clean() then tries one ("stoop" -> "stop")
function T.squeeze(w)
    local out, last, run = {}, nil, 0
    for i = 1, #w do
        local ch = string.sub(w, i, i)
        if ch == last then run = run + 1 else last, run = ch, 1 end
        out[#out + 1] = ch
        if run > 2 then out[#out] = nil end
    end
    return table.concat(out)
end

-- the clean copy (keeps . , ! ? ; : so negation and nouns still find their sentence)
function T.clean(text)
    if type(text) ~= "string" or text == "" or not setting("orderCloseEnough") then return text end
    local typos = setting("orderTypoFix")
    local s = string.gsub(text, "[Ww]/", " with ")
    s = string.gsub(s, "&", " and ")
    s = string.gsub(s, "(%a[%a'%d]*)", function(word)
        local low = string.lower(word)
        low = T.squeeze(low)                               -- stooop -> stop
        local sl = T.SLANG[low]
        if sl ~= nil then return sl end
        if typos and string.find(word, "^%u%l") == nil then -- "Mike" is a name; MIKE (caps) and mike are checked
            local f = T.fixWord(low)
            if f == low and string.find(low, "(%a)%1") and not T.vocab()[low] and not T.COMMON[low] and not T.known()[low] then
                local once = string.gsub(low, "(%a)%1", "%1")
                if T.vocab()[once] then f = once end             -- stopp -> stop, chhop -> chop (exact words only)
            end
            return f
        end
        return low
    end)
    s = string.gsub(string.lower(s), "%s+", " ")
    return s
end

-- more ways to say commands that already exist (edge corpus misses). Merged into ALifeCommands rows on first use
-- (camp rows join the list later, so this runs again when the list grows). Only for commands that exist; a missing
-- id is skipped. Your people only: ALifeTalk_Commands sends a command to nobody else.
T.MORE = {
    melee_only = { "knives only", "knife only", "melee weapons only", "bats only", "no firearms", "quiet weapons only", "melee only please" },
    fire_free = { "go loud", "go hard", "shoot anything", "shoot everything", "kill them all", "waste them", "light em up", "open up on them" },
    guns_needed = { "stay defensive", "fight back only", "defend yourself", "only if they shoot first", "only shoot if shot at", "shoot back only", "only shoot back" },
    attack_target = { "attack him", "attack her", "attack that one", "attack that guy", "hit it", "hit him", "hit her",
        "kill him", "kill her", "kill it", "shoot him", "shoot her", "smoke him", "smoke her", "waste him", "waste her", "waste that guy",
        "drop that guy", "take that guy out", "take it out" },
    give_me = { "give me that", "give me the", "hand me the", "hand me that", "pass me the", "pass me that", "toss me the", "toss me a",
        "toss me that", "let me have that", "let me have the", "throw me the", "throw me a" },
    carry = { "hold my bag", "hold my stuff", "take this for me", "hold onto this" },
    lookout = { "keep watch", "guard duty", "you're on watch", "take watch", "watch out for us", "watch for zombies" },
    heal_me = { "heal me", "fix my arm", "fix my leg", "fix my wounds", "patch my", "bandage my", "i need a bandage",
        "help me im bleeding", "stop my bleeding", "doc me up" },
    heal_self = { "fix your wound", "fix your wounds", "heal yourself", "patch up yourself", "bandage your", "treat yourself",
        "you're bleeding", "youre bleeding", "see to yourself" },
    go_dark = { "crouch", "keep your head down", "heads down", "be quiet", "sneak around", "sneak up", "go quiet" },
    scout = { "go look around", "recon", "check it out", "peek outside", "have a look around", "scout north", "scout south",
        "scout east", "scout west", "go scout" },
    siphon = { "siphon the car", "siphon gas", "drain that car", "get gas out of that car", "get the gas out of", "suck the gas out" },
    work_wood = { "get firewood", "get some firewood", "cut some logs", "cut logs", "chop trees", "chop some trees", "go chop", "chop wood" },
    work_farm = { "go farm", "work the garden", "water the crops", "do the farming", "farm duty", "tend the plants" },
    work_sort = { "stash the stuff", "put it in storage", "put the stuff away", "sort the stuff", "stash it", "put that in storage" },
    back_off = { "get away from them", "leave them", "break off", "back away" },
    stay_close = { "tag along", "stick with me", "walk with me", "keep with me" },
}
local merged = -1
function T.merge()
    local C = ALifeCommands
    if type(C) ~= "table" or type(C.CMDS) ~= "table" or type(C.byId) ~= "table" then return end
    if #C.CMDS == merged then return end
    for id, list in pairs(T.MORE) do
        local c = C.byId[id]
        if type(c) == "table" and type(c.words) == "table" then
            local have = {}
            for _, w in ipairs(c.words) do have[w] = true end
            for _, w in ipairs(list) do if not have[w] then c.words[#c.words + 1] = w; have[w] = true end end
        end
    end
    merged = #C.CMDS
    vocabN = -1
end

-- run a reader on the line as typed, then on the clean copy; returns what the reader returns (+ true if the clean one hit)
function T.tryBoth(reader, text)
    pcall(T.merge)
    local a, b = reader(text)
    if a ~= nil then return a, b end
    local c = T.clean(text)
    if c == nil or c == text or c == string.lower(tostring(text)) then return a, b end
    local x, y = reader(c)
    if x ~= nil then T.lastClean = { text = text, clean = c } end
    return x, y
end

print("[ALifeOrderText] ready v" .. tostring(type(ALifeSide) == "table" and ALifeSide.MOD_VERSION or "?") .. ": close-enough orders (slang, stretched letters, typos)")
