-- A-Life NPC Overhaul: every NPC has a life, and keeps it.
-- The first time the AI speaks for someone it writes who they are from what A-Life knows (name, job title, group,
-- temperament, the day): life before, family and what happened to them, how they've survived, how many of the dead
-- and how many living people they've killed and why, what they want, what they hide, whether they lie easily.
-- It's saved (by A-Life profile, so it survives them leaving and coming back on screen), and every later answer -
-- typed or spoken, today or fifty days from now - comes from the same story.
-- Personal questions ("what did you do before?", "family?", Rick's three: "How many walkers have you killed?
-- How many people? Why?") are answered from it by the AI instead of A-Life's generic lines. You judge the answers.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeStory") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeStory]"
ALifeStory = ALifeStory or {}
local ST = ALifeStory
ST.STORE = "ALifeChatPlus.Stories"

ST.QUESTIONS = {
    { id = "Q_WALKERS", prio = 88, patterns = "how many walkers have you killed|how many zombies have you killed|how many of them have you killed|how many dead have you killed|how many have you put down|how many biters have you killed|how many zeds have you killed|walkers have you killed|zombies have you killed" },
    { id = "Q_PEOPLE", prio = 88, patterns = "how many people have you killed|how many living have you killed|have you killed anyone|have you ever killed someone|ever killed a person|killed any people|killed anybody|how many men have you killed|have you killed people|people have you killed" },
    { id = "Q_WHY", prio = 45, patterns = "why did you kill|why|why did you do it|what for|why them" },
}
-- answered from their story by the AI (when it's running) instead of A-Life's stock lines
ST.PERSONAL = { Q_WALKERS = true, Q_PEOPLE = true, Q_WHY = true, ASK_JOB_BEFORE = true, ASK_FAMILY = true, ASK_KIDS = true,
    ASK_HOMETOWN = true, ASK_HOW_SURVIVED = true, ASK_HOW_LONG = true, ASK_AGE = true, ASK_PETS = true, WHO_ARE_YOU = true,
    ASK_BEFORE = true, ASK_MISS = true, ASK_FAVORITE_FOOD = true, ASK_MUSIC = true, ASK_SPORTS = true, ASK_GOD = true,
    ASK_SCARED = true, ASK_ORIGIN_TODAY = true, ASK_DESTINATION = true, ASK_PLANS = true }
-- without the AI: short honest-enough answers so the questions still work
ST.PLAIN = {
    Q_WALKERS = { "Lost count.", "Enough.", "More than I'd like." },
    Q_PEOPLE = { "...None.", "Why do you want to know?", "That's my business." },
    Q_WHY = { "Because I had to.", "You don't get to ask that yet." },
}

local function store() return type(ModData) == "table" and ModData.getOrCreate(ST.STORE) or {} end

function ST.keyOf(record)
    local m = type(record) == "table" and record.memory or nil
    local pid = type(m) == "table" and (m.profileId or m.profile) or nil
    if pid ~= nil then return "p:" .. tostring(pid) end
    return type(record) == "table" and record.uid and ("u:" .. tostring(record.uid)) or nil
end

function ST.get(record)
    local k = ST.keyOf(record)
    return k and store()[k] or nil
end

function ST.set(record, text)
    local k = ST.keyOf(record)
    if k == nil or type(text) ~= "string" or #text < 20 then return false end
    store()[k] = string.sub(text, 1, 1500)
    return true
end

-- what A-Life knows about them, for the AI to build the story from
function ST.seed(record, profile)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    local parts = {}
    local function add(k, v) if v ~= nil and tostring(v) ~= "" then parts[#parts + 1] = k .. ": " .. tostring(v) end end
    add("name", profile and profile.name)
    add("title", m.title or m.profileTitle)
    add("group", profile and profile.faction)
    add("role", profile and profile.role)
    add("temperament", profile and profile.temperament)
    add("sex", profile and profile.sex)
    add("job", m.conduct or m.specialty)
    add("day of outbreak", profile and profile.day)
    return table.concat(parts, "; ")
end

function ST.install()
    if ALifeMerge and ALifeMerge.skip("story") then return true end
    if ST.__installed then return true end
    local Data, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.Talk
    if Data == nil or Talk == nil then return false end
    ST.__installed = true
    pcall(Data.load)
    Talk.choiceHandlers = Talk.choiceHandlers or {}
    for _, q in ipairs(ST.QUESTIONS) do
        pcall(Data.intent, q.id, q.prio, q.patterns)
        local lines = ST.PLAIN[q.id]
        Talk.choiceHandlers[q.id] = function(record, shell, player)
            local line = lines[(type(ZombRand) == "function" and ZombRand(#lines) or 0) + 1]
            if ProjectALife.Speech.say(shell, line, { face = player }) then return line, "answered" end
            return nil
        end
    end
    if ProjectALife.TalkIntents then ProjectALife.TalkIntents.cache = {} end
    print(TAG .. " ready (NPCs keep a life story; personal questions answered from it)")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(ST.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
