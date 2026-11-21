-- A-Life NPC Overhaul: spoken orders for your residents, using Jeem's real mission system.
--   "We need to scavenge" / "go find supplies"      -> a scavenging trip (12-24 h out, can be hurt or not come back)
--   "Go on patrol" / "check the perimeter"         -> a patrol (4-8 h)
--   "Go after them" / "hunt them down"             -> a hunt on a crew that holds a grudge against you
--   "Come back" / "everyone head home"             -> calls back missions from their base
-- Who goes: the person you're talking to; "take someone" / "take a couple" adds 1-2 more; "all of you" sends up to 4.
-- Someone always stays home. They can refuse: strangers to you, the exhausted, the starving, and people with no
-- reason to obey (no love, fear, need or loyalty) say no - like real people would.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeOrders") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeOrders]"
ALifeOrders = ALifeOrders or {}
local O = ALifeOrders

local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end

O.ORDERS = {
    { id = "ORDER_SCAVENGE", kind = "scavenge",
      patterns = "we need to scavenge|go scavenge|go scavenging|go find supplies|go grab supplies|go get supplies|go on a supply run|do a supply run|go loot|go out and loot|we need supplies|bring back supplies|go find food|go find us some food|go out and find stuff|time to scavenge|lets go scavenge" },
    { id = "ORDER_PATROL", kind = "patrol",
      patterns = "go on patrol|patrol the area|go patrol|walk the perimeter|check the perimeter|scout around|go scout|go have a look around|sweep the area" },
    { id = "ORDER_HUNT", kind = "hunt",
      patterns = "go after them|hunt them down|take care of them|go deal with them|track them down|make them pay|go settle it" },
    { id = "ORDER_RECALL", kind = "recall",
      patterns = "come back|come home|call them back|everyone head home|get back here|head back home|return to base|abort the mission|pull back" },
}
-- things A-Life can't make a person do: they answer like a person (watching = they'll keep an eye out where they
-- stand; building and locking = your job), instead of cheerfully agreeing to something that never happens
O.ACTIONS = {
    { id = "ACTION_WATCH", patterns = "keep your eyes on|keep an eye on|watch the window|watch the door|watch that|keep watch|stand guard|guard the|cover me|cover the|watch my back|watch our back|keep lookout|be the lookout" },
    { id = "ACTION_BUILD", patterns = "barricade|board up|board it up|board the|lock the door|lock it|block the door|block it|nail it shut|help me barricade|help me board" },
}
-- A slur (the AI recognizes it from context; there's no word list): worse than rude. Trust drops hard, they remember
-- exactly what you called them, their group hears it, they won't trade or come with you for half a day, and how they
-- react depends on who they are and who's stronger: the confident get in your face, the outgunned go cold and quiet.
O.SLUR_HOURS = 12
O.SLUR_LINES = {
    strong = { "Say that again. I dare you.", "You want to die today? Keep talking.", "Walk away while you still can." },
    even = { "What the hell did you just call me?", "Get out of my sight.", "We're done here." },
    weak = { "...", "[Stares at you and says nothing]", "...Fine. Whatever you say." },
}
function O.slur(record, shell, player, context, now)
    pcall(function() ProjectALife.NpcOpinion.note("rude", record, player) end)
    pcall(function()
        local B = ALifeBonds
        B.change(B.keyOf(player), record.uid, -12, 0, 0, { player = player, record = record })
        local r = B.row(B.keyOf(player), record.uid, true)
        r.harm = (tonumber(r.harm) or 0) + 1           -- a wound they carry: recruiting gets much harder
        r.sv = (tonumber(r.sv) or 0) + 1               -- and resentment, if they live under your roof
    end)
    pcall(function()
        local h = getGameTime():getWorldAgeHours()
        ProjectALife.Talk.writeMemory(record.uid, function(m) m.chatplusShunUntil = h + O.SLUR_HOURS end)
        record.memory = record.memory or {}
        record.memory.chatplusShunUntil = h + O.SLUR_HOURS
    end)
    if ALifeMemory ~= nil then pcall(ALifeMemory.deed, "slur", record, player) end
    local shift = 0
    pcall(function() shift = ALifeSituation.read(record, shell, player).shift end)
    local pool = (shift <= -4 and O.SLUR_LINES.strong) or (shift >= 4 and O.SLUR_LINES.weak) or O.SLUR_LINES.even
    pcall(function() ProjectALife.Talk.escalate(record, shell, player, context or {}, now) end)
    return pick(pool)
end
-- are they still refusing you over it?
function O.shunned(record)
    local m = type(record) == "table" and record.memory or nil
    local until_ = type(m) == "table" and tonumber(m.chatplusShunUntil) or nil
    if until_ == nil then return false end
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and h < until_
end
O.ACTION_LINES = {
    ACTION_WATCH = { "I'll keep an eye out.", "Yeah. I've got eyes on it.", "I'll watch. Don't take long." },
    ACTION_WATCH_NO = { "Watch it yourself.", "I'm not your lookout." },
    ACTION_BUILD = { "You do it. I'll watch your back.", "No time for that. Do it yourself.", "Your hands, not mine." },
}
O.LINES = {
    go = { "Alright. I'll get going.", "On it. Don't wait up.", "Fine. Back when I'm back.", "Okay. Keep the door shut till I'm home." },
    go_group = { "We'll head out. Keep the place standing.", "Alright, we're going. Keep watch for us.", "We'll be back. Hopefully all of us." },
    recall = { "We'll bring them home.", "Calling them back.", "Alright. Everyone's coming home." },
    outsider = { "I don't take orders from you.", "You're not my boss.", "Ask your own people." },
    refuse = { "Do it yourself.", "Not for you. Not yet.", "Why would I risk my neck for you?" },
    tired = { "I'm dead on my feet. Ask me after I sleep.", "Not like this. I need rest first.", "I'd get myself killed out there right now." },
    hungry = { "Feed me first. I can't go out like this.", "On an empty stomach? No.", "I'm starving. I'd be useless." },
    busy = { "I'm already on something.", "Can't, I'm tied up.", "Someone else'll have to." },
    cant = { "We can't do that right now.", "Not possible right now.", "There's no way to do that from here." },
    no_grudge = { "Go after who? Nobody's after us right now.", "There's no one to hunt.", "Who? Name them." },
    nothing = { "Nobody's out.", "Everyone's already home.", "No one to call back." },
}

local function B() return ALifeBonds end
local function R() return ProjectALifeJimmy and ProjectALifeJimmy.Residents end
local function st(p) return B().stageOf(p or 0) end

local function residentOf(record)
    return type(record) == "table" and type(record.memory) == "table" and type(record.memory.jimmyResident) == "table"
        and record.memory.jimmyResident or nil
end

-- how many they want sent, from what you said
function O.partySize(text)
    local t = string.lower(tostring(text or ""))
    if string.find(t, "all of you", 1, true) or string.find(t, "everyone", 1, true) or string.find(t, "everybody", 1, true)
            or string.find(t, "you all", 1, true) or string.find(t, "yall", 1, true) then return 4 end
    if string.find(t, "couple", 1, true) or string.find(t, "few", 1, true) or string.find(t, "two", 1, true) then return 3 end
    if string.find(t, "someone", 1, true) or string.find(t, "somebody", 1, true) or string.find(t, "with you", 1, true)
            or string.find(t, "a buddy", 1, true) or string.find(t, "partner up", 1, true) then return 2 end
    return 1
end

-- will this person go? (nil = yes, else a refusal line key)
function O.willing(record, player)
    local Bd = B()
    local key = Bd.keyOf(player)
    local r = Bd.row(key, record.uid, false)
    local m = record.memory or {}
    local needs = (ProjectALifeJimmy and ProjectALifeJimmy.Needs and ProjectALifeJimmy.Needs.needs(m)) or {}
    if (tonumber(needs.fatigue) or 0) >= 80 then return "tired" end
    if (tonumber(needs.hunger) or 0) >= 80 or (tonumber(needs.thirst) or 0) >= 80 then return "hungry" end
    if m.jimmyMission ~= nil then return "busy" end
    if r == nil then return "refuse" end
    local reason = st(r.l) >= 2 or st(r.d) >= 1 or st(Bd.effectiveFear(key, record.uid, r)) >= 2 or st(r.n) >= 2
    if not reason then return "refuse" end
    return nil
end

function O.freeMatesOf(record, player, count)
    local res = residentOf(record)
    local out, home = {}, 0
    pcall(function()
        ProjectALife.ActorRegistry.each(function(r)
            local rr = residentOf(r)
            if rr ~= nil and rr.baseId == res.baseId and r.lifecycle ~= "dead" and r.uid ~= record.uid then
                if r.memory.jimmyMission == nil then
                    home = home + 1
                    if #out < count and O.willing(r, player) == nil then out[#out + 1] = r.uid end
                end
            end
            return false
        end)
    end)
    -- someone always stays home
    while #out > 0 and home - #out < 1 do table.remove(out) end
    return out
end

function O.order(def, record, player, text)
    local res = residentOf(record)
    local Rs = R()
    if res == nil or Rs == nil or Rs.missions == nil then return pick(O.LINES.outsider) end
    if type(Rs.isMember) == "function" and Rs.isMember(res.baseId, player) ~= true then return pick(O.LINES.outsider) end
    local M = Rs.missions
    if def.kind == "recall" then
        local n = 0
        pcall(function()
            for id, m in pairs(M.data().list) do
                if m.baseId == res.baseId then
                    if M.recall(player, id) then n = n + 1 end
                end
            end
        end)
        return pick(n > 0 and O.LINES.recall or O.LINES.nothing)
    end
    local no = O.willing(record, player)
    if no ~= nil then return pick(O.LINES[no] or O.LINES.refuse) end
    local uids = { record.uid }
    local want = O.partySize(text) - 1
    if want > 0 then for _, u in ipairs(O.freeMatesOf(record, player, want)) do uids[#uids + 1] = u end end
    local ok, id, why = pcall(M.start, player, def.kind, uids, {})
    if not ok then return pick(O.LINES.cant) end
    if id == nil then
        if why == "no_grudge" then return pick(O.LINES.no_grudge) end
        if why == "nobody_free" or why == "busy" then return pick(O.LINES.busy) end
        ALifeHealth.note(TAG, def.kind .. " refused by Jeem: " .. tostring(why))
        return pick(O.LINES.cant)
    end
    ALifeHealth.note(TAG, def.kind .. " started (" .. #uids .. " people): " .. tostring(id))
    return pick(#uids > 1 and O.LINES.go_group or O.LINES.go)
end

function O.install()
    if O.__installed then return true end
    local Data, Intents, Talk = ProjectALife and ProjectALife.DialogueData, ProjectALife and ProjectALife.TalkIntents,
        ProjectALife and ProjectALife.Talk
    if Data == nil or Intents == nil or Talk == nil or B() == nil then return false end
    O.__installed = true
    pcall(Data.load)
    Talk.choiceHandlers = Talk.choiceHandlers or {}
    for _, def in ipairs(O.ORDERS) do
        pcall(Data.intent, def.id, 82, def.patterns)
        Talk.choiceHandlers[def.id] = function(record, shell, player, context, now, text)
            local ok, line = pcall(O.order, def, record, player, text)
            if not ok then print(TAG .. " order failed: " .. tostring(line)); return nil end
            if line == nil or not ProjectALife.Speech.say(shell, line, { face = player }) then return nil end
            return line, "answered"
        end
    end
    pcall(Data.intent, "SLUR", 20, "uses a hateful slur against them")
    Talk.choiceHandlers.SLUR = function(record, shell, player, context, now)
        local ok, line = pcall(O.slur, record, shell, player, context, now)
        if not ok or line == nil then return nil end
        ProjectALife.Speech.say(shell, line, { face = player })
        return line, "answered"
    end
    for _, a in ipairs(O.ACTIONS) do
        pcall(Data.intent, a.id, 82, a.patterns)
        Talk.choiceHandlers[a.id] = function(record, shell, player, context)
            local key = a.id
            if a.id == "ACTION_WATCH" and context and context.stance == "hostile" then key = "ACTION_WATCH_NO" end
            local line = pick(O.ACTION_LINES[key])
            if not ProjectALife.Speech.say(shell, line, { face = player }) then return nil end
            return line, "answered"
        end
    end
    Intents.cache = {}
    print(TAG .. " ready (scavenge, patrol, hunt, call back" .. (R() and R().missions and "" or " - Jeem missions NOT found") .. ")")
    return true
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(O.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
