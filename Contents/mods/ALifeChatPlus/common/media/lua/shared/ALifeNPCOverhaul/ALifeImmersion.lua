-- A-Life NPC Overhaul: immersion.
--   * No numbers, no bond pop-ups, no "something's missing" hints, no out-of-character chat notices.
--   * Instead you ASK: "do you trust me?", "are you afraid of me?", "do you need us?", "how do you feel about me?",
--     "do you love me?", "are you loyal?" - typed, spoken, or from the talk menu.
--   * They answer from their real bonds - but people lie: the afraid say they're fine, the resentful smile,
--     the opportunist dodges. The honest ones are the ones who love you, or have nothing to fear.
-- Turn off with  immersion=false  in Zomboid\Lua\alifeai_config.txt  (brings back numbers and pop-ups).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeImmersion") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeImmersion]"
ALifeImmersion = ALifeImmersion or {}
local IM = ALifeImmersion
IM.enabled = IM.enabled ~= false

local function readConfig()
    pcall(function()
        local r = getFileReader("alifeai_config.txt", false)
        if r == nil then return end
        while true do
            local l = r:readLine()
            if l == nil then break end
            local v = string.match(tostring(l), "^%s*immersion%s*=%s*(%a+)")
            if v ~= nil then IM.enabled = (v ~= "false") end
        end
        r:close()
    end)
end
readConfig()

local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(list) return list[roll(#list) + 1] end

-- ------------------------------------------------------------ questions -----
IM.QUESTIONS = {
    { id = "BOND_TRUST", text = "Do you trust me?", words = "do you trust me",
      patterns = "do you trust me|can i trust you|you trust me|how much do you trust me|do you believe me|do you trust us|actually trust me|really trust me|trust me to|do you even trust me|would you trust me" },
    { id = "BOND_FEAR", text = "Are you afraid of me?", words = "are you afraid of me",
      patterns = "are you afraid of me|are you scared of me|do you fear me|you scared of me|am i scaring you|do i scare you" },
    { id = "BOND_NEED", text = "Do you need us?", words = "do you need us",
      patterns = "do you need me|do you need us|could you make it without us|would you be okay without me|could you survive without us" },
    { id = "BOND_FEEL", text = "How do you feel about me?", words = "how do you feel about me",
      patterns = "how do you feel about me|what do you think of me|do you like me|where do we stand|are we good|what am i to you" },
    { id = "BOND_LOVE", text = "Do you love me?", words = "do you love me",
      patterns = "do you love me|do you have feelings for me|are we together|do you care about me|am i yours" },
    { id = "BOND_LOYAL", text = "Are you with me?", words = "are you with me",
      patterns = "are you loyal|would you die for me|will you stand by me|are you with me|do you have my back|can i count on you" },
}

-- what they say, by what they're willing to show
IM.LINES = {
    stranger = { "I don't know you well enough to answer that.", "Ask me again when I know you.", "You're a stranger. That's my answer." },
    BOND_TRUST = {
        no = { "No. Not yet.", "Trust is earned. You haven't.", "Honestly? No." },
        some = { "More than most. Less than I'd like.", "I'm getting there.", "Some. Don't make me regret it." },
        yes = { "Yeah. I do.", "With my life, these days.", "I trust you. That's rare for me now." },
    },
    BOND_FEAR = {
        no = { "Afraid of you? No.", "Should I be?", "No. Not of you." },
        some = { "A little. You've got a way about you.", "Sometimes. When you get quiet.", "I'd be stupid not to be, a little." },
        yes = { "...Yes.", "Everyone here is. You know that.", "I don't want to answer that." },
    },
    BOND_NEED = {
        no = { "I got by before you. I'll get by after.", "Need? No. It's convenient, that's all.", "I can take care of myself." },
        some = { "Your walls help. I won't pretend they don't.", "Out there alone? I wouldn't last long.", "I'd manage. Badly." },
        yes = { "Without this place I'm dead. You know it.", "You're all I've got.", "Don't put me back out there. Please." },
    },
    BOND_FEEL = {
        cold = { "I don't think about you much.", "You're someone I'm stuck with.", "I'll be civil. That's all you get." },
        warm = { "You're alright. More than alright, maybe.", "I'm glad you found me.", "You're good people. Rare thing now." },
        close = { "You're the reason I'm still going.", "You matter to me. A lot.", "I'd be lost without you. I mean that." },
    },
    BOND_LOVE = {
        no = { "...No. I'm sorry.", "That's not what this is.", "I care about you. Not like that." },
        maybe = { "Ask me that again sometime.", "I... don't know yet.", "Maybe. Don't rush me." },
        yes = { "You know I do.", "Yeah. God help me, I do.", "Every day." },
        minor = { "What? No. That's not okay.", "Don't. Just don't.", "I'm going to pretend you didn't say that." },
    },
    BOND_LOYAL = {
        no = { "I'm with me.", "Until it stops making sense.", "Don't ask me to bleed for you." },
        some = { "I'm with you. Mostly.", "For now, yeah.", "As long as you're fair." },
        yes = { "To the end.", "Wherever you go.", "I'd stand in front of a horde for you." },
    },
}

-- questions about your base (answered from the real place: beds, food stores, how many live there, their own state)
IM.BASE_QUESTIONS = {
    { id = "BASE_OPINION", text = "What do you think of this place?", words = "what do you think of this place",
      patterns = "what do you think of this place|do you like it here|how do you like it here|how is this place|is this place okay|do you feel safe here|is it safe here|how do you like the place|what do you think of the base" },
    { id = "BASE_COMFORT", text = "How can I make it better here?", words = "how can i make it better here",
      patterns = "how can i make it more comfortable|how can i make it more comfortable here|what would make this place better|how can i make it better here|what would make you happier|how can i make you happy here|what can i do to make it better|what does this place need|what should i fix|what should we fix around here|what would make it better" },
}
IM.BASE_LINES = {
    outsider = { "It's your place, not mine.", "I don't live here. Ask your people.", "Looks solid. Not my business." },
    bed = { "A real bed. I'm sleeping on whatever I can find.", "We need more beds. People are doubling up.", "Somewhere to sleep that isn't the floor." },
    food = { "Food. A proper store we can count on.", "I'm hungry more than I'm not. We need a food store.", "Stock up. Hunger makes people stupid." },
    water = { "Water. That's first. Always.", "I'm thirsty all the time here.", "Get us a steady water supply." },
    tired = { "Let people rest. We're running on nothing.", "Fewer watches. Or more people for them.", "Sleep. I need sleep." },
    stress = { "Some quiet. Some time to breathe.", "Less fear. I don't know how. Just less.", "Something normal. A meal at a table. Anything." },
    grief = { "...Give me some time.", "I keep seeing them. I just need time.", "Nothing you can fix." },
    guards = { "More people on watch. It's too thin.", "If they come at night, who's awake? Get more hands.", "We need guards. Real ones." },
    crowded = { "Fewer of us, or more room.", "It's getting crowded. Tempers are short.", "Too many people, not enough space." },
    fine = { "Honestly? It's good here. Keep doing what you're doing.", "Don't change much. It works.", "Better than anywhere I've been since it started." },
    fine_cold = { "It's fine.", "It keeps the dead out. That's enough.", "I've got no complaints. None I'd tell you." },
    -- opinions
    op_good = { "It's the closest thing to home I've got.", "Safe. Warm. More than most get.", "I like it here. Don't tell anyone." },
    op_mixed = { "It's alright. Could be better.", "Walls are good. The rest needs work.", "It keeps us alive. That's something." },
    op_bad = { "It's a roof. That's about it.", "I've seen worse. Not much worse.", "I'm here because there's nowhere else." },
}

local function B() return ALifeBonds end
local function st(p) return B().stageOf(p or 0) end

-- When they lie, it shows - the way it does with people: a pause, a dodge, too quick, eyes elsewhere.
-- No numbers, nothing certain: honest people hesitate sometimes too.
IM.TELLS = {
    function(l) return "..." .. l end,
    function(l) return "[Looks away] " .. l end,
    function(l) return "Why are you asking? " .. l end,
    function(l) return l .. " [Too quick]" end,
    function(l) return "[Swallows] " .. l end,
    function(l) return l .. " ...Can we drop it?" end,
}
IM.HONEST_PAUSE = 12            -- percent of honest answers that hesitate anyway, so a pause alone proves nothing
function IM.tell(line) return IM.TELLS[roll(#IM.TELLS) + 1](line) end
local function lie(line) return IM.tell(line) end
local function truth(line) if roll(100) < IM.HONEST_PAUSE then return "..." .. line end return line end

-- the answer they choose to give (may not be the truth)
function IM.answer(id, record, player)
    local Bd = B()
    local key = Bd.keyOf(player)
    local r = Bd.row(key, record.uid, false)
    if r == nil then return pick(IM.LINES.stranger) end
    local L = IM.LINES[id]
    local love, need, loyal = st(r.l), st(r.n), st(r.d)
    local fear = st(Bd.effectiveFear(key, record.uid, r))
    local arch = (ALifeBondsMind and ALifeBondsMind.archetypeOf(record, r)) or "Pragmatist"
    local resentful = (r.sv or 0) >= 3
    local honest = love >= 2 or (fear <= 1 and not resentful) or arch == "Martyr"
    local scared = fear >= 2 and love <= 1                      -- tells you what you want to hear
    if id ~= "BOND_LOVE" and love + need + fear + loyal == 0 and (r.r or 0) == 0 then return pick(IM.LINES.stranger) end

    if id == "BOND_TRUST" then
        if not honest and (scared or resentful) then return lie(pick(L.some)) end
        return truth(pick(love >= 3 and L.yes or love >= 1 and L.some or L.no))
    elseif id == "BOND_FEAR" then
        if scared and not honest then return lie(pick(L.no)) end   -- "afraid? no." (they are)
        return truth(pick(fear >= 3 and L.yes or fear >= 1 and L.some or L.no))
    elseif id == "BOND_NEED" then
        if arch == "Opportunist" or arch == "Pragmatist" and love <= 1 then
            return (need >= 3 and lie or truth)(pick(need >= 4 and L.some or L.no))   -- proud: understate it
        end
        return pick(need >= 3 and L.yes or need >= 1 and L.some or L.no)
    elseif id == "BOND_FEEL" then
        if (scared or resentful) and not honest then return lie(pick(L.warm)) end
        return truth(pick(love >= 4 and L.close or love >= 2 and L.warm or L.cold))
    elseif id == "BOND_LOVE" then
        if not Bd.canRomance(record) then return pick(L.minor) end
        if r.partner then return pick(L.yes) end
        if scared and not honest then return lie(pick(L.maybe)) end
        return pick((love >= 3 and (r.r or 0) >= 10) and L.maybe or L.no)
    elseif id == "BOND_LOYAL" then
        if (scared or resentful) and not honest then return lie(pick(L.yes)) end   -- the loudest oath, the emptiest
        return truth(pick(loyal >= 3 and L.yes or (loyal >= 1 or love >= 3) and L.some or L.no))
    end
    return pick(IM.LINES.stranger)
end

local function baseFacts(record)
    local f = { resident = false }
    local m = type(record.memory) == "table" and record.memory or {}
    local res = type(m.jimmyResident) == "table" and m.jimmyResident or nil
    local J = ProjectALifeJimmy
    if res == nil or J == nil or J.BaseAreas == nil then return f end
    f.resident = true
    local base = J.BaseAreas.base(res.baseId)
    f.beds = base and tonumber(base.beds) or nil
    f.food = 0
    pcall(function() f.food = #J.BaseAreas.storesOf(base, "food") end)
    f.people = 0
    pcall(function()
        ProjectALife.ActorRegistry.each(function(r)
            local rr = type(r.memory) == "table" and r.memory.jimmyResident or nil
            if type(rr) == "table" and rr.baseId == res.baseId and r.lifecycle ~= "dead" then f.people = f.people + 1 end
            return false
        end)
    end)
    local needs = (J.Needs and J.Needs.needs(m)) or {}
    f.hunger, f.thirst = tonumber(needs.hunger) or 0, tonumber(needs.thirst) or 0
    f.fatigue, f.stress = tonumber(needs.fatigue) or 0, tonumber(needs.stress) or 0
    f.grief = m.jimmyGrief ~= nil
    return f
end

function IM.answerBase(id, record, player)
    local f = baseFacts(record)
    local L = IM.BASE_LINES
    if not f.resident then return pick(L.outsider) end
    local Bd = B()
    local key = Bd.keyOf(player)
    local r = Bd.row(key, record.uid, false) or { l = 0, f = 0, n = 0 }
    local love, fear = st(r.l), st(Bd.effectiveFear(key, record.uid, r))
    local open = love >= 1 or fear <= 1            -- afraid strangers keep complaints to themselves
    -- what's actually wrong, worst first
    local issue = nil
    if f.grief then issue = "grief"
    elseif f.thirst >= 60 then issue = "water"
    elseif f.hunger >= 60 or f.food == 0 then issue = "food"
    elseif f.beds ~= nil and f.people > f.beds then issue = "bed"
    elseif f.fatigue >= 70 then issue = "tired"
    elseif f.stress >= 60 then issue = "stress"
    elseif f.people <= 1 then issue = "guards"
    elseif f.beds ~= nil and f.people >= 10 and f.people >= f.beds then issue = "crowded" end
    if id == "BASE_COMFORT" then
        if issue ~= nil and open then return pick(L[issue]) end
        if issue ~= nil then return lie(pick(L.fine_cold)) end   -- won't tell you
        return pick(love >= 2 and L.fine or L.fine_cold)
    end
    -- opinion: love and how many problems there are
    local score = love - ((issue ~= nil) and 1 or 0) - ((f.hunger >= 60 or f.thirst >= 60) and 1 or 0)
    if not open then return pick(L.op_mixed) end
    return pick(score >= 2 and L.op_good or score >= 0 and L.op_mixed or L.op_bad)
end

-- --------------------------------------------------------------- install ----
function IM.install()
    if ALifeMerge and ALifeMerge.skip("immersion") then return true end
    if IM.__installed then return true end
    local Data, Intents, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.TalkIntents,
        ProjectALife and ProjectALife.Talk
    if Data == nil or Intents == nil or Talk == nil or B() == nil then return false end
    IM.__installed = true
    pcall(Data.load)
    for _, q in ipairs(IM.QUESTIONS) do
        pcall(Data.intent, q.id, 80, q.patterns)
        if type(Intents.addChoice) == "function" then
            pcall(Intents.addChoice, { id = q.id, text = q.text, words = q.words, topic = "Personal" })
        end
        Talk.choiceHandlers = Talk.choiceHandlers or {}
        Talk.choiceHandlers[q.id] = function(record, shell, player)
            local ok, line = pcall(IM.answer, q.id, record, player)
            if not ok or line == nil then return nil end
            if not ProjectALife.Speech.say(shell, line, { face = player }) then return nil end
            return line, "answered"
        end
    end
    for _, q in ipairs(IM.BASE_QUESTIONS) do
        pcall(Data.intent, q.id, 80, q.patterns)
        if type(Intents.addChoice) == "function" then
            pcall(Intents.addChoice, { id = q.id, text = q.text, words = q.words, topic = "Personal" })
        end
        Talk.choiceHandlers[q.id] = function(record, shell, player)
            local ok, line = pcall(IM.answerBase, q.id, record, player)
            if not ok or line == nil then return nil end
            if not ProjectALife.Speech.say(shell, line, { face = player }) then return nil end
            return line, "answered"
        end
    end
    Intents.cache = {}
    -- out-of-character chat notices ("Pick one of the door options...", "No trade is available here...")
    if IM.enabled and type(Talk.typedNotice) == "function" then
        local orig = Talk.typedNotice
        Talk.typedNotice = function(player, reason, now, ...)
            if IM.enabled then return false end
            return orig(player, reason, now, ...) -- 0.7.2.1: A-Life 1.5 added a 4th arg (listener)
        end
    end
    print(TAG .. " ready (immersion " .. (IM.enabled and "ON" or "off") .. ", " .. (#IM.QUESTIONS + #IM.BASE_QUESTIONS) .. " questions you can ask)")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(IM.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
