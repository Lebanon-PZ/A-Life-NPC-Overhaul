-- A-Life NPC Overhaul 0.8.2: THEY DO WHAT YOU SAY (part 1: the orders A-Life 1.5 already knows how to carry out).
-- You say it in your own words (typed, voice, the talk window, or the Commands tab). This file:
--   * knows every command: what it's called, the words for it, what A-Life order or item move carries it out,
--     what it needs, who can do it (L.CMDS, also what the Commands tab shows);
--   * reads a line and finds the command in it (L.parse);
--   * on the server, carries it out for each person you gave it to (L.run): A-Life companions only (your party),
--     they can refuse (how they feel about you, their skill, what they carry), A-Life's own order runs
--     (ProjectALife.Companions.order) or A-Life's own item move (ProjectALife.CompanionInventoryServer.act);
--   * answers who did it and who didn't, and why, so they can say so in their own voice.
-- Multiplayer-ready: the client sends { cmd, uids, x, y, z, noun } through ALifeCmd; the server decides.
-- Every command can be switched off in settings ("cmd_<id>"); every number is a setting.
-- A hook that errors logs one line and switches itself off; A-Life's own order wheel and menus are untouched.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeCellCars"

ALifeCommands = ALifeCommands or {}
local L = ALifeCommands
local TAG = "[ALifeCommands]"
L.VERSION = ALifeSide.MOD_VERSION
L.off = L.off or {}
L.metrics = L.metrics or { asked = 0, done = 0, refused = 0, notYours = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function M() return ALifeLLMTalk end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return math.random(0, n - 1) end

-- settings (they live with the rest of the mod's settings; these are only the defaults)
L.DEFAULTS = {
    cmdObey = 75,          -- how likely someone of yours does what you say when nothing else is known (0-100)
    cmdEasyBonus = 15,     -- small asks (lights, eat, stay close) are easier to agree to
    cmdFightObey = 100,    -- fighting stance orders (weapons free, hold fire, melee only...): chance they follow them (0-100). Safety calls, not favours
    cmdGiveTrust = 20,     -- handing over their own gear: how much harder than an order (0-100)
    cmdReach = 30,         -- how far away (tiles) someone of yours can hear an order
    cmdPointReach = 40,    -- how far from you a spot you point at may be
    cmdBuildingReach = 12, -- "clear this building": how far (tiles) to look for the building and its door when you're outside
    cmdBaseReach = 300,    -- 0.8.2 part 2: "back to base" works from this far away (tiles)
    -- 0.8.3
    wakeReach = 15,        -- "wake me": how close (tiles) the dead / someone hostile gets before they wake you
    wakeHours = 12,        -- "wake me": how long they keep watch (game hours)
    teachHours = 1,        -- "teach me": how long a lesson lasts (game hours)
    teachXp = 8,           -- "teach me": XP per 10 game minutes for each level they're ahead of you
    teachReach = 4,        -- "teach me": how close (tiles) you must stay
    teachGapH = 24,        -- "teach me": game hours before the same person teaches you the same skill again
    siphonMinutes = 10,    -- "siphon": game minutes at the car before the can is full
    siphonGiveUpMin = 90,  -- "siphon": game minutes before they give up getting to the car
    keepEngineMin = 60,    -- "keep the engine running": game minutes A-Life leaves it on after they get out
    guardTiles = 8,        -- a guard holding a post goes after the dead this far (tiles) from their own spot (A-Life's default 8)
}
function L.setting(key)
    local m = M()
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = L.DEFAULTS[key] end
    return v
end
function L.cmdOn(id)
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and (m.settings.commands == false or m.settings["cmd_" .. id] == false))
end

----------------------------------------------------------------------------------------------------------------
-- the commands (part 1). point: "here" (where you stand), "threat" (what you're facing), "ahead" (where you look),
-- "car" (the nearest car). easy: small ask. item: "take" (theirs to you) / "give" (yours to them).
----------------------------------------------------------------------------------------------------------------
L.GROUPS = { "Fighting", "Getting around", "Gear", "Looking after themselves", "Help me", "Lights and noise" }
L.CMDS = {
    { id = "hold_fire", group = "Fighting", order = "hold_fire", label = "hold fire",
      words = { "hold fire", "hold your fire", "don't shoot", "dont shoot", "do not shoot", "no shooting", "cease fire", "stop shooting" }, neg = true,
      say = { "Hold your fire.", "Don't shoot." }, what = "No shooting until you say so." },
    -- A-Life keeps two separate switches: fire (hold/free) and weapons (melee/needed/free/...). "fire_free" alone
    -- only lifts a hold; a guard on the default "needed" still swings a blade at a thin crowd. Send both.
    { id = "fire_free", group = "Fighting", orders = { "guns_free", "fire_free" }, label = "weapons free",
      words = { "weapons free", "open fire", "fire at will", "light them up", "shoot freely", "use your guns", "use your gun", "shoot them", "guns out",
          "pull out your gun", "pull out your guns", "pull your guns out", "pull your gun out", "pull out your weapon", "pull out your weapons",
          "draw your gun", "draw your guns", "draw your weapon", "draw your weapons", "get your guns out", "get your gun out",
          "take out your gun", "take out your guns", "start shooting", "shoot the zombies", "shoot the dead", "shoot em", "shoot 'em", "fire away", "weapons hot",
          "free fire", "fire freely", "fire when ready", "shoot at will", "shoot on sight", "shoot to kill", "shoot anything that moves",
          "guns hot", "guns up", "weapons up", "gun up", "arm up", "arm yourselves", "arm yourself", "lock and load",
          "raise your weapons", "raise your guns", "raise your gun", "ready your weapons", "ready your guns", "ready your gun", "ready weapons",
          "unholster", "load up and shoot", "everybody shoot", "everyone shoot", "all shoot", "you can shoot", "feel free to shoot", "go ahead and shoot",
          "use your weapons", "use your weapon", "use your firearms", "use your rifles", "use your rifle", "use your pistols", "use your pistol", "use the guns", "use guns",
          "kill them all", "take the shot", "take the shots", "engage them", "gun them down", "mow them down", "blast them", "blast em", "blast 'em",
          "light em up", "light 'em up", "put them down", "shoot back", "return fire" },
      say = { "Weapons free.", "Open fire." }, what = "Guns out, shoot at will: the dead and the living." },
    { id = "melee_only", group = "Fighting", order = "melee_only", label = "melee only",
      words = { "melee only", "no guns", "blades only", "use your knife", "hand to hand", "keep the guns away", "put the gun away" }, neg = true,
      say = { "Melee only.", "No guns, use your knife." }, what = "Guns away; quiet weapons only. Guns make noise that draws the dead." },
    { id = "guns_people", group = "Fighting", order = "guns_people", label = "guns on people only",
      words = { "only shoot people", "guns on people", "save the bullets for people", "shoot people only" },
      say = { "Only shoot people." }, what = "Guns for the living; the dead get blades." },
    { id = "guns_infected", group = "Fighting", order = "guns_infected", label = "guns on the dead only",
      words = { "only shoot the dead", "guns on the dead", "only shoot zombies", "shoot the dead only", "only shoot the infected" },
      say = { "Only shoot the dead." }, what = "Guns for the dead; no shooting at people." },
    { id = "guns_needed", group = "Fighting", order = "guns_needed", label = "guns only if needed",
      words = { "guns only if you need", "only if you have to", "shoot only if you have to", "guns if needed" },
      say = { "Guns only if you have to." }, what = "Their normal way: blades first, guns when it gets bad." },
    { id = "attack_target", group = "Fighting", order = "attack_target", point = "threat", label = "get that one",
      words = { "get that one", "take him out", "take her out", "take that one out", "kill that one", "shoot that one", "drop him", "drop that one" },
      say = { "Get that one!", "Take him out!" }, what = "They go after the closest threat in front of you (the dead or someone hostile)." },
    { id = "stay_close", group = "Getting around", order = "follow_close", label = "stay close", easy = true,
      words = { "stay behind me", "stay close", "stick close", "right behind me", "keep close", "tight on me" },
      say = { "Stay behind me.", "Stick close." }, what = "They follow you tight." },
    { id = "spread_out", group = "Getting around", order = "follow_loose", label = "spread out", easy = true,
      words = { "spread out", "fan out", "give me some room", "loosen up" },
      say = { "Spread out.", "Fan out." }, what = "They follow you with room between you." },
    { id = "to_car", group = "Getting around", order = "go_to", point = "car", label = "fall back to the car",
      words = { "back to the car", "fall back to the car", "get to the car", "run to the car", "go to the car", "head to the car" },
      say = { "Back to the car!" }, what = "They head for the nearest car to you and wait there." },
    { id = "guard_spot", group = "Getting around", order = "hold_there", point = "here", label = "guard this spot",
      words = { "guard this door", "watch this door", "guard the door", "hold this door", "watch the window", "guard this window",
          "guard this spot", "hold this spot", "guard right here" },
      say = { "Guard this door.", "Hold this spot." }, what = "They stand where you are and guard it until you call them." },
    { id = "lookout", group = "Getting around", order = "watch_there", point = "ahead", label = "keep a lookout",
      words = { "keep a lookout", "be the lookout", "on lookout", "look out that way", "watch that way", "keep watch over there", "eyes on that", "watch over there" },
      say = { "Keep a lookout that way." }, what = "They hold their spot and watch where you're looking." },
    { id = "clear_house", group = "Getting around", order = "clear_building", point = "building", label = "clear the house",
      words = { "clear the house", "clear this house", "clear the building", "clear this building", "sweep the house", "sweep the building", "clear this place" },
      say = { "Clear the house." }, what = "They go room by room through the building you're in or next to and call out what they find." },
    { id = "give_me", group = "Gear", item = "take", label = "hand it over",
      words = { "give me your", "hand me your", "pass me your", "let me have your", "toss me your", "gimme your" },
      say = { "Give me your rifle.", "Hand me your water." }, what = "They hand you that thing from their own gear, if they trust you enough. You need to be close." },
    { id = "carry", group = "Gear", item = "give", label = "carry this",
      words = { "carry this", "carry my", "carry the", "hold this for me", "hang on to this", "hang onto this", "keep this for me" },
      say = { "Carry my canned beans.", "Hold this hammer for me." }, what = "Name the thing in your bag (not in your hands). They take it if they can carry the weight." },
    { id = "heal_self", group = "Looking after themselves", order = "heal_self", label = "patch yourself up", easy = true,
      words = { "patch yourself up", "bandage yourself", "fix yourself up", "treat your wounds", "see to your wounds", "stop your bleeding" },
      say = { "Patch yourself up." }, what = "They bandage their own wounds with what they carry. Needs a little first aid." },
    { id = "heal_me", group = "Looking after themselves", order = "heal_me", label = "bandage me",
      words = { "bandage me", "patch me up", "fix me up", "i'm bleeding", "im bleeding", "treat my wounds", "help me i'm hurt" },
      say = { "Patch me up.", "I'm bleeding." }, what = "They bandage you with what they carry. Needs some first aid." },
    { id = "eat_now", group = "Looking after themselves", order = "eat_now", label = "eat something", easy = true,
      words = { "eat something", "get something to eat", "have something to eat", "go eat", "drink something", "drink some water", "have a drink" },
      say = { "Eat something.", "Drink some water." }, what = "They eat or drink from their own supplies." },
    { id = "go_dark", group = "Lights and noise", orders = { "stealth_on", "light_off" }, label = "go dark",
      words = { "go dark", "stay quiet", "keep quiet", "start sneaking", "sneak in", "keep low", "stay low", "quiet now" },
      say = { "Go dark.", "Stay low and quiet." }, what = "They crouch, put their light out and keep quiet." },
    { id = "stop_sneaking", group = "Lights and noise", order = "stealth_off", label = "stop sneaking", easy = true,
      words = { "stop sneaking", "you can stand up", "we're clear", "were clear", "all clear, relax" },
      say = { "We're clear, stand up." }, what = "They walk normally again." },
    { id = "light_off", group = "Lights and noise", order = "light_off", label = "lights off", easy = true,
      words = { "lights off", "kill the light", "kill your light", "turn off your light", "flashlight off", "put your light out" },
      say = { "Lights off." }, what = "They switch their flashlight off." },
    { id = "light_on", group = "Lights and noise", order = "light_on", label = "lights on", easy = true,
      words = { "lights on", "turn on your light", "flashlight on", "light it up", "get a light on" },
      say = { "Lights on." }, what = "They switch their flashlight on (they need one with charge)." },
    -- 0.8.2 part 2 (A-Life 1.5.1 Rules.ORDERS: retreat / go_to / hold_there / pickup_*; check_bites is the client's)
    { id = "back_off", group = "Getting around", order = "retreat", label = "back off", easy = true,
      words = { "back off", "pull back", "break it off", "disengage", "leave it", "get away from it", "get out of there" },
      say = { "Back off!", "Pull back!" }, what = "They stop fighting and come back to you." },
    { id = "to_base", group = "Getting around", order = "go_to", point = "base", far = true, label = "back to base",
      words = { "back to base", "go back to base", "head back to base", "go to my base", "go to the base", "wait at the base",
          "wait at my base", "go home and wait", "head home", "go back home" },
      say = { "Head back to base.", "Wait for me at the base." }, what = "They walk back to your base and wait there. Needs a base: a safehouse or a marked base." },
    { id = "wait_dawn", group = "Getting around", order = "hold_there", point = "here", dawn = true, label = "wait here till morning",
      words = { "wait here till morning", "wait here until morning", "wait till dawn", "wait until dawn", "stay here tonight",
          "wait here tonight", "hold here till morning", "wait here till sunrise" },
      say = { "Wait here till morning." }, what = "They hold where you stand and come find you after dawn." },
    { id = "pickup_on", group = "Gear", order = "pickup_on", label = "pick things up", easy = true,
      words = { "pick up what you find", "grab anything useful", "loot as you go", "pick stuff up", "grab what you can", "take what you find" },
      say = { "Grab anything useful." }, what = "They pick up useful things they walk past." },
    { id = "pickup_use", group = "Gear", order = "pickup_use", label = "use what you find", easy = true,
      words = { "use what you find", "use what you pick up", "equip what you find", "use anything better" },
      say = { "Use what you find." }, what = "They pick things up and use the better ones." },
    { id = "pickup_off", group = "Gear", order = "pickup_off", label = "leave things be", easy = true, neg = true,
      words = { "don't pick anything up", "dont pick anything up", "stop picking stuff up", "leave the loot", "leave stuff where it is", "stop looting" },
      say = { "Leave the loot." }, what = "They stop picking things up." },
    { id = "check_bites", group = "Looking after themselves", client = true, label = "check me for bites",
      words = { "check me for bites", "am i bitten", "am i bit", "do i have a bite", "look me over", "check me over", "did i get bit" },
      say = { "Check me for bites." }, what = "They look you over up close and tell you what they see." },
    { id = "show_map", group = "Getting around", client = true, label = "show me on the map",
      words = { "show me on the map", "mark it on my map", "mark your place on my map", "show me where you live",
          "where's your place", "where is your place", "mark your base", "show me your base on the map" },
      say = { "Show me on the map where you live." }, what = "They mark their group's place on your map, if they trust you. You need a pen or pencil." },
    -- 0.8.3 (engine calls read on 42.21: IsoGameCharacter.forceAwake / XP.AddXP, vanilla ISTakeGasolineFromVehicle,
    -- A-Life Cold.dressPass, A-Life DrivingEngine.shutDown)
    { id = "wake_me", group = "Help me", client = true, mine = true, label = "wake me if anything comes",
      words = { "wake me if", "wake me up if", "keep watch while i sleep", "watch over me while i sleep", "keep watch tonight",
          "keep an eye out while i sleep", "stand watch while i sleep", "take first watch", "you take the watch" },
      say = { "Wake me if anything comes.", "Keep watch while I sleep." }, what = "They stay up and wake you if the dead or someone hostile comes close while you sleep. One night." },
    { id = "teach_me", group = "Help me", client = true, mine = true, noun = true, label = "teach me",
      words = { "teach me", "show me how", "can you teach me", "teach me about", "show me some", "teach me some", "train me" },
      say = { "Teach me some carpentry.", "Show me how to shoot." }, what = "They teach you a skill they know better than you: first aid, cooking, carpentry, mechanics, aiming, sneaking, foraging, fighting. Stay close for an hour. You can't learn past what they know." },
    { id = "wear_this", group = "Gear", item = "wear", label = "put this on",
      words = { "wear this", "put this on", "put on your", "put on the", "put on my", "wear your", "wear the", "wear my", "wear that" },
      say = { "Put on your jacket.", "Wear my helmet." }, what = "They put on a piece of clothing: their own, or one from your bag (they take it first). Not if something's already there." },
    { id = "siphon", group = "Gear", point = "car", label = "siphon that car",
      words = { "siphon", "siphon the gas", "siphon that car", "siphon the tank", "get the gas out", "drain the tank", "drain the gas", "get gas from that car" },
      say = { "Siphon that car.", "Get the gas out of that one." }, what = "They walk to the nearest car and siphon its fuel into a can. They need a hose and a can of their own." },
    { id = "keep_engine", group = "Getting around", point = "car", label = "keep the engine running",
      words = { "keep the engine running", "leave the engine running", "keep it running", "leave it running", "keep the car running", "don't turn it off", "dont turn it off", "engine on" },
      say = { "Keep the engine running." }, what = "When they get out of the nearest car, they leave the engine on (it burns fuel). For a quick getaway." },
    -- 0.8.8: stand in the way of someone's revenge (ALifeGoals.warn; only when someone really has it out for them)
    { id = "warn_them", group = "Help me", client = true, label = "warn them",
      words = { "watch your back", "watch your six", "someone wants you dead", "somebody wants you dead", "is out to get you",
          "is coming for you", "is gunning for you", "wants to kill you", "they want you dead", "is after you" },
      say = { "Watch your back. Someone wants you dead." }, what = "Tell someone that a person you know is out for their blood. They get ready; the one who wanted it may find out it was you." },
    -- not said: what they do on their own after "wait here till morning"
    { id = "follow_me", hidden = true, order = "follow", label = "follow", words = {} },
}
L.byId = {}
for _, c in ipairs(L.CMDS) do L.byId[c.id] = c end

-- words for things in someone's bag, so "give me your rifle" finds a rifle
L.NOUNS = {
    rifle = { "rifle", "m16", "ar-15", "hunting rifle", "varmint" }, gun = { "rifle", "pistol", "shotgun", "revolver", "gun" },
    pistol = { "pistol", "revolver", "handgun", "m9", "m1911" }, shotgun = { "shotgun" },
    ammo = { "ammo", "rounds", "bullets", "shells", "box of", "magazine", "clip" }, bullets = { "ammo", "rounds", "bullets", "shells" },
    water = { "water" }, food = { "can", "canned", "beans", "soup", "chips", "crackers", "bar", "jerky" },
    bandage = { "bandage", "ripped sheets", "rag" }, bandages = { "bandage", "ripped sheets" }, knife = { "knife" },
    axe = { "axe" }, bat = { "bat" }, crowbar = { "crowbar" }, hammer = { "hammer" }, flashlight = { "flashlight", "torch" },
    pills = { "pills", "painkillers", "antibiotics" }, meds = { "pills", "antibiotics", "bandage", "disinfectant" },
}

----------------------------------------------------------------------------------------------------------------
-- reading a line
----------------------------------------------------------------------------------------------------------------
-- "don't", "not", "never" earlier in the same sentence (back to the last . , ! ? ;) turn the order off
local function negated(lowP, at)
    local before = string.sub(lowP, math.max(1, at - 40), at - 1)
    local cut = 0
    for i = #before, 1, -1 do
        if string.find(string.sub(before, i, i), "[%.,!%?;:]") then cut = i; break end
    end
    before = " " .. string.sub(before, cut + 1)
    return string.find(before, "n't", 1, true) ~= nil or string.find(before, " not ", 1, true) ~= nil
        or string.find(before, " never ", 1, true) ~= nil or string.find(before, " dont ", 1, true) ~= nil
end
-- returns the command row and the noun after it ("rifle" in "give me your rifle"), or nil
function L.parse(text)
    if type(text) ~= "string" or text == "" then return nil end
    local lowP = " " .. string.lower(text) .. " "
    local low = string.gsub(lowP, "[%.,!%?;:]", " ")
    local best, bestAt, bestLen = nil, nil, 0
    for _, c in ipairs(L.CMDS) do
        if L.cmdOn(c.id) and not c.hidden then
            for _, w in ipairs(c.words) do
                local a = string.find(low, w, 1, true)
                -- a phrase must start at a word boundary
                if a and string.find(string.sub(low, a - 1, a - 1), "%a") == nil and (c.neg or not negated(lowP, a)) and #w > bestLen then
                    best, bestAt, bestLen = c, a, #w
                end
            end
        end
    end
    if best == nil then return nil end
    local noun = nil
    if best.item ~= nil or best.noun then
        -- the noun ends at the end of the sentence ("put on your jacket, it's cold" -> "jacket"); low and lowP line up
        local rest = string.sub(lowP, bestAt + bestLen)
        local cut = string.find(rest, "[%.,!%?;:]")
        if cut then rest = string.sub(rest, 1, cut - 1) end
        rest = string.gsub(rest, "^%s*(about%s+)", "")
        rest = string.gsub(rest, "^%s*(how%s+to%s+)", "")
        rest = string.gsub(rest, "^%s*(to%s+)", "")
        rest = string.gsub(rest, "^%s*(the%s+)", "")
        rest = string.gsub(rest, "^%s*(your%s+)", "")
        rest = string.gsub(rest, "^%s*(my%s+)", "")
        rest = string.gsub(rest, "^%s*(some%s+)", "")
        rest = string.gsub(rest, "^%s*(a%s+)", "")
        rest = string.gsub(rest, "^%s+", "")
        rest = string.gsub(rest, "%s+for%s+me.*$", "")
        rest = string.gsub(rest, "%s+please.*$", "")
        rest = string.gsub(rest, "%s+$", "")
        if rest ~= "" and rest ~= "this" and rest ~= "that" and rest ~= "it" then noun = string.sub(rest, 1, 40) end
    end
    return best, noun
end

----------------------------------------------------------------------------------------------------------------
-- server side: carry it out
----------------------------------------------------------------------------------------------------------------
local function companions() local pa = PA(); return pa ~= nil and pa.Companions or nil end
local function keyOf(player)
    local c = companions()
    if not fn(c, "playerKey") or player == nil then return nil end
    local ok, k = pcall(c.playerKey, player)
    return ok and k or nil
end
-- an A-Life companion of this player (your party, with the companion link on)
function L.isMine(uid, player)
    local link = ALifeCompanionLink
    if fn(link, "isALife") then
        local ok, yes = pcall(link.isALife, uid, player)
        return ok and yes == true
    end
    local c, pa = companions(), PA()
    if not fn(c, "entry") or pa == nil or not fn(pa.ActorRegistry, "read") then return false end
    local okR, r = pcall(pa.ActorRegistry.read, tostring(uid))
    local okE, e = pcall(c.entry, okR and r or nil)
    return okE and type(e) == "table" and e.owner == keyOf(player)
end

-- how likely they do it (0-100): the mod's own obey chance (how they feel about you, who they are) when it's there
function L.chance(uid, player, c)
    local m = M()
    local base = nil
    if fn(m, "obeyChance") then
        local ok, v = pcall(m.obeyChance, uid, "player", c.id)
        if ok and tonumber(v) ~= nil then base = tonumber(v) end
    end
    base = base or tonumber(L.setting("cmdObey")) or 75
    -- stance orders (weapons free, hold fire, melee only, guns on...) are standing rules for the fight, not favours:
    -- the dice must not leave a camp standing there while the gate falls
    if c.group == "Fighting" and c.order ~= "attack_target" then base = tonumber(L.setting("cmdFightObey")) or 100 end
    if c.easy then base = base + (tonumber(L.setting("cmdEasyBonus")) or 0) end
    if c.item == "take" then base = base - (tonumber(L.setting("cmdGiveTrust")) or 0) end
    if fn(ALifeOathWatch, "isSworn") then
        local ok, sworn = pcall(ALifeOathWatch.isSworn, uid)
        if ok and sworn then base = math.max(base, 95) end
    end
    return math.max(0, math.min(100, math.floor(base + 0.5)))
end

local function distTo(player, x, y)
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    if px == nil then return 1e9 end
    return math.sqrt((px - x) ^ 2 + (py - y) ^ 2)
end

-- an A-Life order for one person; true or false + A-Life's reason
function L.order(player, uid, orderId, point)
    local c = companions()
    if not fn(c, "order") then return false, "no_companions" end
    local args = { order = orderId, uid = tostring(uid) }
    if point ~= nil then args.x, args.y, args.z = point.x, point.y, point.z end
    local ok, done, why = pcall(c.order, player, args)
    if not ok then return false, "error" end
    return done == true, why
end

-- find the thing named in a bag (an ItemContainer); returns the item or nil
function L.findItem(container, noun)
    if container == nil or type(noun) ~= "string" or noun == "" then return nil end
    local wants = L.NOUNS[noun] or { noun }
    local items = nil
    pcall(function() items = container:getItems() end)
    if items == nil then return nil end
    local n = 0
    pcall(function() n = items:size() end)
    for _, w in ipairs(wants) do
        for i = 0, n - 1 do
            local it = items:get(i)
            local name = ""
            pcall(function() name = string.lower(tostring(it:getDisplayName())) end)
            if string.find(name, w, 1, true) then return it end
        end
    end
    return nil
end

-- their own gear to you ("take"), or yours to them ("give"), through A-Life's own item move
function L.item(player, uid, c, noun)
    local pa = PA()
    local srv = pa ~= nil and pa.CompanionInventoryServer or nil
    local comp = companions()
    if not fn(srv, "act") or not fn(comp, "shellOf") then return false, "no_items" end
    if noun == nil then return false, "what_item" end
    local shell = comp.shellOf(tostring(uid))
    if shell == nil then return false, "gone" end
    if c.item == "take" then
        local inv = nil
        pcall(function() inv = shell:getInventory() end)
        local it = L.findItem(inv, noun)
        if it == nil then return false, "doesnt_have" end
        local t = ""
        pcall(function() t = it:getFullType() end)
        local cur = fn(srv, "isCurrent") and srv.isCurrent(shell, it) == true or false
        local worn = fn(srv, "isWorn") and srv.isWorn(shell, it) == true or false
        if worn then return false, "worn" end
        if cur then
            -- the weapon in their hands: they put it down first (A-Life's own "unequip"), then hand it over
            local okU = srv.act(player, { uid = tostring(uid), op = "unequip", t = t, cur = true })
            if okU ~= true then return false, "equipped_weapon" end
            if type(srv.gate) == "table" then srv.gate[tostring(uid)] = 0 end
        end
        local ok = srv.act(player, { uid = tostring(uid), op = "take", t = t, n = 1, cur = false, wn = false })
        return ok == true, ok == true and nil or "refused"
    end
    local mine = nil
    pcall(function() mine = player:getInventory() end)
    local it = L.findItem(mine, noun)
    if it == nil then return false, "you_dont_have" end
    local t = ""
    pcall(function() t = it:getFullType() end)
    local ok = srv.act(player, { uid = tostring(uid), op = "give", t = t, n = 1 })
    return ok == true, ok == true and nil or "too_heavy_or_equipped"
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.3: put this on (A-Life's own way of dressing someone: ALifeCold.dressPass)
----------------------------------------------------------------------------------------------------------------
-- one piece of clothing on an NPC body; true or false + why
function L.putOn(shell, item)
    if shell == nil or item == nil then return false, "gone" end
    local isCloth = false
    pcall(function() isCloth = instanceof(item, "Clothing") end)
    if not isCloth then return false, "not_clothing" end
    local list = nil
    pcall(function() list = shell:getWornItems() end)
    if list == nil then return false, "error" end
    local location = nil
    pcall(function() location = item:getBodyLocation() end)
    if location == nil then return false, "not_clothing" end
    local already, taken = false, false
    pcall(function() already = list:contains(item) end)
    if already then return false, "already_wearing" end
    pcall(function()
        if list:getItem(location) ~= nil then taken = true; return end
        local group = list:getBodyLocationGroup()
        for slot = 0, list:size() - 1 do
            local worn = list:getItemByIndex(slot)
            local wornLocation = worn ~= nil and list:getLocation(worn) or nil
            if wornLocation ~= nil and group:isExclusive(location, wornLocation) then taken = true; return end
        end
    end)
    if taken then return false, "slot_taken" end
    local ok = pcall(function()
        list:setItem(location, item)
        shell:setWornItems(list)
        shell:resetModelNextFrame()
    end)
    if not ok then return false, "error" end
    return true, nil
end

-- the thing of this type in their bag that they're not wearing yet
local function unwornOfType(shell, fullType)
    local found = nil
    pcall(function()
        local list = shell:getWornItems()
        local items = shell:getInventory():getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it:getFullType() == fullType and not list:contains(it) then found = it; return end
        end
    end)
    return found
end

function L.wear(player, uid, noun)
    local comp = companions()
    if not fn(comp, "shellOf") then return false, "no_companions" end
    if noun == nil then return false, "what_item" end
    local shell = comp.shellOf(tostring(uid))
    if shell == nil then return false, "gone" end
    local inv = nil
    pcall(function() inv = shell:getInventory() end)
    local it = L.findItem(inv, noun)
    if it == nil then
        -- yours: they take it from you first (A-Life's own item move, real carry weight)
        local pa = PA()
        local srv = pa ~= nil and pa.CompanionInventoryServer or nil
        if not fn(srv, "act") then return false, "no_items" end
        local mine = nil
        pcall(function() mine = player:getInventory() end)
        local yours = L.findItem(mine, noun)
        if yours == nil then return false, "neither_has" end
        local t = ""
        pcall(function() t = yours:getFullType() end)
        local okG = srv.act(player, { uid = tostring(uid), op = "give", t = t, n = 1 })
        if okG ~= true then return false, "too_heavy_or_equipped" end
        it = unwornOfType(shell, t)
        if it == nil then return false, "error" end
    end
    return L.putOn(shell, it)
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.3: siphon that car (vanilla ISTakeGasolineFromVehicle: a hose, a can that's empty or holds petrol, the tank part)
----------------------------------------------------------------------------------------------------------------
L.jobs = L.jobs or {}
local function worldMinutes() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return (tonumber(h) or 0) * 60 end

-- the car closest to x, y (within 4 tiles); server's loaded cell (unverified on a dedicated server, guarded)
function L.carAt(x, y)
    local best, bd = nil, 4 * 4
    pcall(function()
        for _, v in ipairs(ALifeCellCars.list()) do -- 0.9.5: 42.21 cell vehicles = HashSet (no get(i))
            local d = (v:getX() - x) ^ 2 + (v:getY() - y) ^ 2
            if d < bd then best, bd = v, d end
        end
    end)
    return best
end
function L.gasTank(vehicle)
    local tank = nil
    pcall(function()
        for i = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(i)
            if part:isContainer() and part:getContainerContentType() == "Gasoline" then tank = part; return end
        end
    end)
    return tank
end
-- what they need for it: a hose (ItemTag.SIPHON_GAS) and a can with room for petrol
function L.siphonKit(shell)
    local hose, can = nil, nil
    pcall(function()
        local inv = shell:getInventory()
        hose = inv:getFirstTagRecurse(ItemTag.SIPHON_GAS)
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local fc = it:getFluidContainer()
            if fc ~= nil and (fc:isEmpty() or (fc:contains(Fluid.Petrol) and fc:getFreeCapacity() > 0)) then can = it; break end
        end
    end)
    return hose, can
end
-- tank -> can, as vanilla does it; returns litres
function L.siphonNow(vehicle, can)
    local tank = L.gasTank(vehicle)
    if tank == nil then return 0, "no_tank" end
    local fc = nil
    pcall(function() fc = can:getFluidContainer() end)
    if fc == nil then return 0, "no_can" end
    local have, room, empty = 0, 0, false
    pcall(function() have = tank:getContainerContentAmount(); room = fc:getFreeCapacity(); empty = fc:isEmpty() end)
    local take = math.min(tonumber(room) or 0, tonumber(have) or 0)
    if take <= 0 then return 0, (tonumber(have) or 0) <= 0 and "tank_dry" or "can_full" end
    local ok = pcall(function()
        tank:setContainerContentAmount(have - take)
        if empty then fc:addFluid(Fluid.Petrol, take) else fc:adjustAmount(fc:getAmount() + take) end
        can:syncItemFields()
        vehicle:transmitPartModData(tank)
    end)
    if not ok then return 0, "error" end
    return take, nil
end
function L.startSiphon(player, uid, point)
    local comp = companions()
    if not fn(comp, "shellOf") then return false, "no_companions" end
    local shell = comp.shellOf(tostring(uid))
    if shell == nil then return false, "gone" end
    local hose, can = L.siphonKit(shell)
    if hose == nil then return false, "no_hose" end
    if can == nil then return false, "no_can" end
    local car = L.carAt(point.x, point.y)
    if car == nil then return false, "no_spot" end
    local tank = L.gasTank(car)
    local have = 0
    pcall(function() have = tank:getContainerContentAmount() end)
    if tank == nil or (tonumber(have) or 0) <= 0 then return false, "tank_dry" end
    local okO, why = L.order(player, uid, "go_to", point)
    if not okO then return false, why end
    L.jobs[tostring(uid)] = { kind = "siphon", player = player, x = point.x, y = point.y, z = point.z, at = worldMinutes() }
    return true, nil
end
-- every game minute: those on the way get there, work, fill the can, then come back to you
function L.jobTick()
    local now = worldMinutes()
    local comp = companions()
    local list = {}
    for uid, j in pairs(L.jobs) do list[#list + 1] = { uid = uid, j = j } end
    for _, row in ipairs(list) do
        local uid, j = row.uid, row.j
        local shell = fn(comp, "shellOf") and comp.shellOf(uid) or nil
        local done, litres, why = false, 0, nil
        if shell == nil then done, why = true, "gone"
        elseif now - j.at > (tonumber(L.setting("siphonGiveUpMin")) or 90) then done, why = true, "no_footing"
        else
            local close = false
            pcall(function() close = (shell:getX() - j.x) ^ 2 + (shell:getY() - j.y) ^ 2 <= 3 * 3 end)
            if close and j.arrived == nil then j.arrived = now end
            if j.arrived ~= nil and now - j.arrived >= (tonumber(L.setting("siphonMinutes")) or 10) then
                done = true
                local car = L.carAt(j.x, j.y)
                local _, can = L.siphonKit(shell)
                if car == nil then why = "no_spot" elseif can == nil then why = "no_can" else litres, why = L.siphonNow(car, can) end
            end
        end
        if done then
            L.jobs[uid] = nil
            if j.player ~= nil then
                L.order(j.player, uid, "follow", nil)
                ALifeCmd.reply(j.player, "cmdDone", { cmd = "siphon", uid = uid, ok = litres > 0, why = why, n = math.floor(litres + 0.5) })
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.3: keep the engine running. A-Life switches a car off when its NPC driver gets out
-- (ProjectALife.DrivingEngine.shutDown(s), server only); we skip that for a car you told them to keep running.
----------------------------------------------------------------------------------------------------------------
L.keepEngine = L.keepEngine or {}
function L.carKey(v)
    local k = nil
    pcall(function() local s = v:getSqlId(); if tonumber(s) ~= nil and s > 0 then k = "s" .. s end end)
    if k == nil then pcall(function() k = "i" .. tostring(v:getId()) end) end
    return k
end
function L.keepRunning(vehicle)
    local k = vehicle ~= nil and L.carKey(vehicle) or nil
    local untilM = k and L.keepEngine[k] or nil
    if untilM == nil then return false end
    if worldMinutes() > untilM then L.keepEngine[k] = nil; return false end
    return true
end
function L.startKeepEngine(point)
    local car = L.carAt(point.x, point.y)
    if car == nil then return false, "no_spot" end
    local k = L.carKey(car)
    if k == nil then return false, "error" end
    L.keepEngine[k] = worldMinutes() + (tonumber(L.setting("keepEngineMin")) or 60)
    return true, nil
end
function L.hookEngine()
    if L.engineHooked then return true end
    local pa = PA()
    local E = pa ~= nil and pa.DrivingEngine or nil
    if not fn(E, "shutDown") then return false end
    local orig = E.shutDown
    E.shutDown = function(s, ...)
        if not L.off.engine then
            local ok, keep = pcall(L.keepRunning, type(s) == "table" and s.vehicle or nil)
            if not ok then L.off.engine = true; log("keep engine failed, off for this session: " .. tostring(keep))
            elseif keep then L.metrics.keptRunning = (L.metrics.keptRunning or 0) + 1; return false end
        end
        return orig(s, ...)
    end
    L.engineHooked = true
    return true
end

-- one person, one command. agreed: they already said yes in their own words (the AI picked the command
-- from what you said and answered as someone who agrees), so the dice don't overrule them.
function L.runOne(player, uid, c, point, noun, agreed)
    if not L.isMine(uid, player) then L.metrics.notYours = L.metrics.notYours + 1; return false, "not_yours" end
    if c.client then return false, "client_only" end
    if agreed ~= true then
        local chance = L.chance(uid, player, c)
        if roll(100) >= chance then return false, "wont" end
    end
    if c.item == "wear" then return L.wear(player, uid, noun) end
    if c.item ~= nil then return L.item(player, uid, c, noun) end
    if c.id == "siphon" then return L.startSiphon(player, uid, point) end
    if c.id == "keep_engine" then return L.startKeepEngine(point) end
    if c.orders ~= nil then
        local any, why = false, nil
        for _, o in ipairs(c.orders) do
            local ok, w = L.order(player, uid, o, point)
            any = any or ok
            why = why or w
        end
        return any, any and nil or why
    end
    return L.order(player, uid, c.order, point)
end

-- the server handler: { cmd, uids = "a,b", x, y, z, noun }
function L.run(player, args)
    if L.off.run then return end
    local c = L.byId[tostring(args.cmd or "")]
    if c == nil or not L.cmdOn(c.id) then return end
    L.metrics.asked = L.metrics.asked + 1
    local point = nil
    if tonumber(args.x) ~= nil and tonumber(args.y) ~= nil then
        point = { x = tonumber(args.x), y = tonumber(args.y), z = tonumber(args.z) or 0 }
        local reach = c.far and (tonumber(L.setting("cmdBaseReach")) or 300) or (tonumber(L.setting("cmdPointReach")) or 40)
        if distTo(player, point.x, point.y) > reach then point = nil end
    end
    local results = {}
    if c.point ~= nil and point == nil then
        for uid in string.gmatch(tostring(args.uids or ""), "[^,]+") do results[#results + 1] = { uid = uid, ok = false, why = c.point == "base" and "no_base" or (c.point == "building" and "no_building" or "no_spot") } end
    else
        local n = 0
        for uid in string.gmatch(tostring(args.uids or ""), "[^,]+") do
            n = n + 1
            if n > 12 then break end
            local ok, done, why = pcall(L.runOne, player, uid, c, point, args.noun, args.agreed == true or c.hidden == true)
            if not ok then done, why = false, "error"; log("command '" .. c.id .. "' error: " .. tostring(done)) end
            if done then L.metrics.done = L.metrics.done + 1 else L.metrics.refused = L.metrics.refused + 1 end
            results[#results + 1] = { uid = uid, ok = done == true, why = why and tostring(why) or nil }
        end
    end
    ALifeCmd.reply(player, "cmdResult", { cmd = c.id, label = c.label, noun = args.noun, results = results, agreed = args.agreed == true })
end

-- why, in plain words (what they'd tell you)
L.WHY = {
    wont = "they didn't want to", not_yours = "they don't take orders from you", no_spot = "there was nothing there to do it to",
    no_skill = "they don't know enough first aid", needs_point = "there was nothing there to do it to", what_item = "you didn't say what",
    doesnt_have = "they don't have one", worn = "they're wearing it", equipped_weapon = "they wouldn't let go of the weapon in their hands",
    you_dont_have = "you don't have that in your bag", too_heavy_or_equipped = "it's too heavy for them, or it's in your hands",
    refused = "they wouldn't", too_far = "you're too far apart", gone = "they're not here", repeat_ = "they're already on it",
    ["repeat"] = "they're already on it", no_companions = "A-Life's companions are off", no_items = "A-Life's companion inventory is off",
    no_footing = "there's nowhere to stand there", busy = "they're busy", too_heavy = "it's too heavy for them",
    no_base = "you don't have a base for them to go to",
    no_building = "there's no building close enough", no_door = "they couldn't find a way in",
    -- 0.8.3
    not_clothing = "that isn't something you wear", already_wearing = "they're already wearing it",
    slot_taken = "they're already wearing something there", neither_has = "neither of you has one",
    no_hose = "they don't have a hose", no_can = "they don't have an empty gas can", tank_dry = "the tank is dry",
    can_full = "their can is full", no_tank = "that car has no tank", knows_less = "you know more about it than they do",
    too_soon = "they already taught you that today", what_skill = "you didn't say what", asleep = "you're asleep",
}
function L.whyWords(why) return L.WHY[tostring(why or "")] or nil end

-- 0.8.3: a skill you ask to be taught -> A-Life companion skill id (ALifeCompanionRules.SKILLS) + vanilla perk
-- (A-Life's own map, Companions.PERKS: melee = Blunt, no music perk)
L.SKILL_WORDS = {
    { id = "firstAid", perk = "Doctor", words = { "first aid", "medic", "doctor", "bandag", "stitch", "patch" } },
    { id = "cooking", perk = "Cooking", words = { "cook" } },
    { id = "carpentry", perk = "Woodwork", words = { "carpent", "woodwork", "build", "barricad", "hammer" } },
    { id = "mechanics", perk = "Mechanics", words = { "mechanic", "car", "engine", "fix" } },
    { id = "aiming", perk = "Aiming", words = { "aim", "shoot", "gun", "rifle", "pistol" } },
    { id = "stealth", perk = "Sneak", words = { "sneak", "stealth", "quiet" } },
    { id = "foraging", perk = "PlantScavenging", words = { "forag", "scaveng", "plants", "berries", "mushroom" } },
    { id = "melee", perk = "Blunt", words = { "fight", "melee", "swing", "bat", "club" } },
}
function L.skillOf(noun)
    if type(noun) ~= "string" then return nil end
    local low = string.lower(noun)
    for _, s in ipairs(L.SKILL_WORDS) do
        for _, w in ipairs(s.words) do if string.find(low, w, 1, true) then return s end end
    end
    return nil
end

-- A-Life's guard reach (Rules.GUARD.tiles, read live on every engage check) follows our setting. Default = A-Life's own 8.
function L.syncGuard()
    local pa = PA()
    local rules = pa ~= nil and pa.CompanionRules or nil
    if type(rules) ~= "table" or type(rules.GUARD) ~= "table" then return false end
    local v = tonumber(L.setting("guardTiles"))
    if v == nil then return false end
    v = math.max(2, math.min(40, v))
    if rules.GUARD.tiles ~= v then rules.GUARD.tiles = v end
    return true
end

if fn(ALifeCmd, "onServer") then ALifeCmd.onServer("cmd", function(player, args) return L.run(player, args) end) end
if type(Events) == "table" then
    if Events.EveryOneMinute ~= nil then
        Events.EveryOneMinute.Add(function()
            pcall(L.syncGuard)
            if L.off.jobs then return end
            local ok, err = pcall(L.jobTick)
            if not ok then L.off.jobs = true; log("jobs failed, off for this session: " .. tostring(err)) end
        end)
    end
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(L.hookEngine); pcall(L.syncGuard) end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(L.hookEngine); pcall(L.syncGuard) end) end
end
print(TAG .. " loaded v" .. L.VERSION .. " (" .. #L.CMDS .. " commands)")
