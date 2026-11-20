-- A-Life Talk / Chat Plus: soft classifier for weaker local models (3B/4B).
-- Runs before the LLM request. Maps common survivor speech to intent / tone / forced GIST
-- so unknown lines become clarifying questions instead of "hm?" / "what?" / "huh?".
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Classify") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if type(ALifeLLMTalk) ~= "table" then require "ALifeLLMTalk/ALifeLLMTalk_Main" end -- 0.4.2: Main requires us at its end; avoid the recursive require warning
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Classify"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Classify") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

M.CLASSIFY_VERSION = "1.0.1"

-- Forced GIST when nothing matches (weak models must obey this)
M.UnknownGist =
    "You didn't fully catch what they said. Ask a short clarifying question or give a brief wary/neutral acknowledgment. "
    .. "Do not agree to anything, offer anything, give directions, or invent facts. One short sentence only."

-- Light slang / typo map (subset of Chat Plus lexicon; expand from weak-classify logs)
M.LEXICON = M.LEXICON or {
    helo = "hello", hullo = "hello", heyy = "hey", heyyy = "hey", hai = "hi", hiya = "hi", heya = "hey",
    mornin = "morning", evenin = "evening", goin = "going", nothin = "nothing", somethin = "something",
    anythin = "anything", doin = "doing", lookin = "looking", comin = "coming", talkin = "talking",
    thru = "through", tho = "though", b4 = "before", ppl = "people", abt = "about",
    sry = "sorry", srry = "sorry", soz = "sorry", thnx = "thanks", thanx = "thanks", tysm = "thanks",
    cya = "see you", seeya = "see you", l8r = "later", gtg = "got to go", g2g = "got to go",
    sup = "what is up", wassup = "what is up", wazzup = "what is up",
    yur = "your", yer = "your", ur = "your", u = "you", ya = "you", wanna = "want to", gonna = "going to",
    walkers = "zombies", walker = "zombies", undead = "zombies", rotters = "zombies",
    bandits = "raiders", bandit = "raiders",
    grub = "food", chow = "food", rations = "food", h2o = "water",
    meds = "medicine", medkit = "medicine", ammo = "ammo", mags = "ammo",
    foood = "food", foodd = "food", watre = "water", water = "water",
    pls = "please", plz = "please", idk = "i don't know",
}

-- Soft buckets: higher tier (lower number) wins; longer phrase wins within tier
M.SoftBuckets = {
    { id = "FOLLOW", tier = 1, intent = "FOLLOW_ME", act = "WALK_WITH_ME", tone = nil,
      words = { "come with me", "come with", "follow me", "walk with me", "walk with", "join me",
                "tag along", "come along", "stick with me", "let's go", "lets go", "come on then" } },
    { id = "WAIT", tier = 1, intent = "WAIT_HERE", act = "WALK_STOP", tone = nil,
      words = { "wait here", "stay here", "stay put", "hold up", "stop following", "don't follow",
                "dont follow", "wait", "hold on" } },
    { id = "HANDS_UP", tier = 1, intent = "THREATEN", act = "HANDS_UP", tone = "THREATEN",
      words = { "hands up", "put your hands up", "hands in the air", "freeze" } },
    { id = "DROP_WEAPON", tier = 1, intent = "THREATEN", act = "DROP_WEAPON", tone = "THREATEN",
      words = { "drop it", "drop the gun", "drop your weapon", "put it down", "put the gun down",
                "lower your weapon", "drop that" } },
    { id = "ROB", tier = 1, intent = "THREATEN", act = "DEMAND_ITEMS", tone = "THREATEN",
      words = { "hand over", "hand it over", "give me your", "empty your pockets", "this is a robbery",
                "stick up", "everything you got" } },
    { id = "JOIN", tier = 1, intent = "JOIN_REQUEST", act = "PARTY_JOIN", tone = nil,
      words = { "join us", "join my group", "come join", "work with us", "live with us", "stay with us",
                "be part of" } },
    { id = "TRADE", tier = 1, intent = "ASK_TRADE", act = "ASK_TRADE", tone = nil,
      words = { "trade", "barter", "swap", "exchange", "do business", "make a deal", "want to trade",
                "wanna trade", "got anything to trade" } },
    { id = "FOOD", tier = 2, intent = "ASK_FOOD", act = "ASK_FOOD", tone = nil,
      words = { "got any food", "any food", "spare food", "need food", "looking for food", "something to eat",
                "hungry", "food", "grub", "chow", "rations", "can i have food" } },
    { id = "WATER", tier = 2, intent = "ASK_WATER", act = "ASK_WATER", tone = nil,
      words = { "got any water", "any water", "spare water", "need water", "looking for water",
                "something to drink", "thirsty", "water", "drink" } },
    { id = "MEDS", tier = 2, intent = "ASK_MEDS", act = "ASK_MEDS", tone = nil,
      words = { "got any meds", "any medicine", "need meds", "medicine", "meds", "bandage", "bandages",
                "first aid", "painkillers", "pills" } },
    { id = "AMMO", tier = 2, intent = nil, act = nil, tone = nil,
      gist = "They are asking about ammo or bullets. Answer only from what you know; do not invent stock.",
      words = { "got any ammo", "spare ammo", "need ammo", "ammo", "ammunition", "bullets", "shells",
                "rounds", "magazines" } },
    { id = "NAME", tier = 3, intent = "ASK_NAME", act = "ASK_NAME", tone = nil,
      words = { "what's your name", "whats your name", "who are you", "your name", "what do they call you",
                "call you" } },
    { id = "GREET", tier = 3, intent = "GREETING", act = nil, tone = "GREETING",
      words = { "good morning", "good evening", "good afternoon", "hello there", "hey there", "hello",
                "hey", "hi", "howdy", "morning", "evening", "yo" } },
    { id = "THANKS", tier = 3, intent = "THANKS", act = nil, tone = "THANKS",
      words = { "thank you", "thanks", "thx", "appreciate it", "cheers", "grateful" } },
    { id = "SORRY", tier = 3, intent = "SORRY", act = nil, tone = "SORRY",
      words = { "sorry", "my bad", "apologize", "apologise", "forgive me", "didn't mean", "didnt mean" } },
    { id = "BYE", tier = 3, intent = "FAREWELL", act = nil, tone = "FAREWELL",
      words = { "goodbye", "see you", "see ya", "take care", "gotta go", "got to go", "heading out",
                "bye", "later", "i'm out", "im out" } },
    { id = "HELP_OFFER", tier = 3, intent = "OFFER_HELP", act = nil, tone = "OFFER_HELP",
      words = { "need help", "want help", "i can help", "let me help", "can i help", "you need a hand",
                "need a hand", "i'll help", "ill help" } },
    { id = "FRIENDLY", tier = 3, intent = "I_AM_FRIENDLY", act = nil, tone = "I_AM_FRIENDLY",
      words = { "i'm friendly", "im friendly", "not a threat", "don't shoot", "dont shoot", "peaceful",
                "i mean no harm", "we're good", "we are good" } },
    { id = "INSULT", tier = 3, intent = "INSULT", act = nil, tone = "INSULT",
      words = { "idiot", "stupid", "asshole", "bastard", "piece of shit", "fuck you", "screw you",
                "moron", "dumbass" } },
    { id = "THREAT", tier = 3, intent = "THREATEN", act = nil, tone = "THREATEN",
      words = { "i'll kill you", "ill kill you", "you're dead", "youre dead", "kill you", "end you",
                "bury you", "your ass is grass", "i'll shoot", "ill shoot" } },
    { id = "GO_AWAY", tier = 3, intent = "GO_AWAY", act = nil, tone = "GO_AWAY",
      words = { "go away", "get lost", "leave me alone", "back off", "piss off", "get out of here",
                "move along" } },
    { id = "STATUS", tier = 4, intent = nil, act = nil, tone = nil,
      gist = "They are asking if you are okay or how you are doing. Answer briefly in character from your state.",
      words = { "you okay", "you good", "how are you", "are you hurt", "you hurt", "you alright",
                "how's it going", "hows it going", "you good?" } },
    { id = "TRUST", tier = 4, intent = nil, act = nil, tone = nil,
      gist = "They are asking whether you trust them or how you feel about them. Answer from your real bonds; you may lie if scared or resentful.",
      words = { "do you trust me", "trust me", "how do you feel about me", "what do you think of me",
                "are you afraid of me", "do you like me" } },
    { id = "BASE", tier = 4, intent = nil, act = nil, tone = nil,
      gist = "They are asking about this place or the base. Answer from what you know about the location and conditions.",
      words = { "this place", "the base", "your camp", "safe here", "is it safe", "how is this place",
                "what do you think of this place" } },
    { id = "GIFT", tier = 4, intent = "OFFER_ITEM", act = nil, tone = nil,
      gist = "They are offering you something. React in character; the game decides if anything changes hands.",
      words = { "take this", "take these", "for you", "have this", "have these", "this is for you",
                "got you something", "brought you" } },
}

function M.normalizeLine(s)
    s = string.lower(tostring(s or ""))
    local lex = M.LEXICON or {}
    s = s:gsub("%S+", function(w)
        local clean = w:gsub("[^%w']", "")
        return lex[clean] or lex[w] or w
    end)
    s = s:gsub("[^%w%s'%?%!%.%,]", " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

function M.splitClauses(s)
    local parts = {}
    for chunk in string.gmatch(tostring(s or ""), "[^%.%!%?%;]+") do
        chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
        if #chunk > 0 then parts[#parts + 1] = chunk end
    end
    if #parts == 0 and s and s ~= "" then parts[1] = s end
    return parts
end

-- 1.0.1: whole words only ("hi" no longer matches "this", "hey" no longer matches "they")
function M.softClassify(text)
    if type(text) ~= "string" or text == "" then return nil end
    local low = " " .. string.gsub(M.normalizeLine(text), "[^%w']+", " ") .. " "
    local best, bestTier, bestLen = nil, 99, 0
    for _, b in ipairs(M.SoftBuckets) do
        for _, w in ipairs(b.words) do
            local pat = " " .. string.gsub(w, "[^%w']+", " ") .. " "
            if string.find(low, pat, 1, true) then
                local len = #w
                if b.tier < bestTier or (b.tier == bestTier and len > bestLen) then
                    best, bestTier, bestLen = b, b.tier, len
                end
            end
        end
    end
    return best
end

local function wordCount(s)
    local n = 0
    for _ in string.gmatch(tostring(s or ""), "%w+") do n = n + 1 end
    return n
end

-- Returns table: textNorm, soft, intent, tone, act, gistForce, reason, weak
function M.softPreprocess(text, alifeIntent)
    local textNorm = M.normalizeLine(text)
    local soft = M.softClassify(textNorm)
    if not soft then
        local clauses = M.splitClauses(textNorm)
        if clauses[1] then soft = M.softClassify(clauses[1]) end
    end

    local intent = alifeIntent
    local tone, act, gistForce, reason = nil, nil, nil, nil

    -- Prefer a real A-Life intent when present; soft fills gaps
    local alifeWeak = (intent == nil or intent == "" or intent == "UNKNOWN" or intent == "unknown")
    if soft then
        -- 1.0.1: only commands/requests (tiers 1-2) may set an intent; small talk stays with the AI
        if alifeWeak and soft.intent and soft.tier <= 2 then intent = soft.intent end
        tone = soft.tone
        act = soft.act
        gistForce = soft.gist
        reason = "soft"
    end

    -- 1.0.1: "didn't catch that" only for very short lines nothing understood (garble, one stray word);
    -- a real sentence with no keyword is ordinary free chat and goes to the AI as-is
    local stillWeak = (intent == nil or intent == "" or intent == "UNKNOWN" or intent == "unknown")
        and tone == nil and gistForce == nil and wordCount(textNorm) <= 2
    -- 0.5.1: another language isn't garble: let the AI read it
    if stillWeak and type(ALifeLanguage) == "table" and ALifeLanguage.foreign(text or textNorm) then stillWeak = false end
    if stillWeak then
        gistForce = M.UnknownGist
        reason = "unknown"
    end

    if stillWeak then
        print(string.format('[ALifeTalkLLM] weak classify: "%s" -> unknown fallback', string.sub(textNorm, 1, 80)))
    elseif soft then
        print(string.format('[ALifeTalkLLM] soft classify: "%s" -> bucket=%s intent=%s tone=%s',
            string.sub(textNorm, 1, 60), soft.id, tostring(intent), tostring(tone)))
    end

    return {
        textNorm = textNorm,
        soft = soft,
        intent = intent,
        tone = tone,
        act = act,
        gistForce = gistForce,
        reason = reason,
        weak = stillWeak,
        -- pre-1.0 PLAN-CONVO P1: small talk / status buckets are a hint, not an order (threats and commands stay strict)
        gistSoft = (soft ~= nil and gistForce == soft.gist and soft.tier >= 3 and soft.tone ~= "THREATEN") or nil,
    }
end

if M.log then M.log("Classify " .. M.CLASSIFY_VERSION .. " ready (soft buckets + unknown GIST for weak models)") end
print("[ALifeTalkLLM] Classify " .. M.CLASSIFY_VERSION .. " ready (soft buckets + unknown GIST for weak models)")
