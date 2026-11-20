-- A-Life NPC Overhaul 0.7.12: STRANGERS (roadmap). Real people who turn out to be someone (hook in, never replace).
--   * ODDBALLS: at most one per world. Somewhere after the first few days, one stranger you meet is a used-car
--     salesman still selling, a gym teacher with a whistle, a drill sergeant, an insurance adjuster, a doomsday
--     prepper, a mall Santa still in the suit, a conspiracy radio host, a wedding planner, a Spiffo's fry-station
--     manager, or a mime who never says a word. Nobody is made: an ordinary A-Life stranger you haven't met yet gets
--     the life (their name, what the AI knows about them, the odd thing they say when you meet them).
--   * FAMILIAR FACES: a chance (each on its own) for some of the people from a certain TV show about the dead to be
--     out there, under names that are almost theirs (Nick Graves, Darrell Dixby, Herschel Gray...). Each is a
--     stranger you haven't met yet who fits (a hunter for Darrell, a farmer for Herschel, a group's leader for The
--     Mayor). The show's children are grown: 18. Sandbox "Familiar faces use their real names" switches the names.
--   * THE CONFESSOR: Father Gabe Stoakes. Tell him you want to confess and he listens, and knows what people say
--     you've done. What you tell him stays with him.
--   * THE STRANGER WHO COMES WHEN IT'S OVER: once per world, when you're badly hurt with the dead on you and nobody
--     of yours near, someone walks out of nowhere, clears the dead off you, barely says a word, leaves a note, and
--     is gone by morning. Later it's a rumour on the radio. (The one person this mod ever brings into the world: he
--     isn't anyone's, and he never stays.)
--   * SUPPORTERS: people who back the mod show up in it (ALifeDonors.lua: tiers 5 / 15 / 30 / 50).
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "strangers" (on by default). Sandbox: ALifeChatPlus.TWDRealNames (off).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeStrangers") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeStrangers = ALifeStrangers or {}
local L = ALifeStrangers
local TAG = "[ALifeStrangers]"
L.VERSION = "0.7.12"
L.cfg = {
    scanTiles = 40, greetTiles = 6, oddDayMin = 3, oddDayMax = 20, cameoChance = 0.25, cameoGapH = 36, firstDay = 2,
    -- the rescuer
    rescueDayMin = 3, hurt = 45, deadNear = 10, deadCount = 5, crowd = 12, mineTiles = 20, checkMs = 2000,
    clearCount = 2, stayMin = 20, retireTiles = 35, rumourDaysMin = 2, rumourDaysMax = 4,
    rescueFactions = { "alife_deserters", "alife_guard_infantry", "alife_fire" },
    confessGapH = 24, askWindowMs = 8000,
}

----------------------------------------------------------------------------------------------------------------
-- the people
----------------------------------------------------------------------------------------------------------------
L.ODDBALL = {
    { id = "salesman", title = "used-car salesman",
      line = "Sold used cars on the Louisville strip for twenty years and has not stopped selling. Everything is a deal, every car is a creampuff, every survivor is a customer.",
      style = "a fast, warm sales pitch; calls people 'friend' and 'boss'; turns everything into a deal",
      say = { "Friend! You look like someone who appreciates a quality vehicle. Low miles. Well. Some miles.", "Boss, I can do you a deal you won't believe. I don't believe it myself." } },
    { id = "gym", title = "high school gym teacher",
      line = "Taught PE at a Knox County high school. Still wears the whistle, still counts laps, still thinks most problems are a fitness problem.",
      style = "coach voice: short shouted encouragements, sports talk, calls people by their last name",
      say = { "Hustle! The dead are slow, you've got no excuse.", "That's a lap. Give me another one. Knees up!" } },
    { id = "drill", title = "drill sergeant",
      line = "Was a drill sergeant at Fort Knox. Has never in his life spoken at a normal volume. Rates everyone like a recruit.",
      style = "a drill sergeant: barks, insults that are almost affectionate, everything an order",
      say = { "What are you looking at, recruit? Did I say you could look at me?", "You call that a perimeter? My grandmother walks a better perimeter!" } },
    { id = "adjuster", title = "insurance adjuster",
      line = "Was an insurance adjuster. Still assesses every ruin for damage and every injury for coverage, out of habit and maybe out of shock.",
      style = "dry, polite, bureaucratic; talks in claims, coverage, deductibles and acts of God",
      say = { "That's not covered, I'm afraid. Act of God. Technically.", "I'll need to see some documentation of the damage." } },
    { id = "prepper", title = "doomsday prepper",
      line = "Spent ten years and his savings preparing for the end. Lost the bunker in the first week. Was right about everything and it did not help at all.",
      style = "bitter, intense, full of gear talk and told-you-so; distrusts everyone",
      say = { "I had a bunker. I had a plan. I had three years of beans.", "Nobody listened. Now look." } },
    { id = "santa", title = "mall Santa", sex = "m",
      line = "Was the Santa at the Louisville mall the week it all happened. Still wears the suit because it's warm and it's what he has. Kind, tired, ho-ho-hos out of habit.",
      style = "gentle, grandfatherly; slips into Santa's voice; asks whether people have been good",
      say = { "Ho... ho. Have you been good this year? Never mind. Nobody has.", "The suit's warm. That's the only reason. Mostly." } },
    { id = "radio", title = "late-night conspiracy radio host",
      line = "Hosted a late-night call-in show about government cover-ups. Feels proven right and has a theory for everything, most of them wrong.",
      style = "radio-host cadence, dramatic pauses, 'wake up, people', talks to an audience that isn't there",
      say = { "You're listening to... well. Nobody's listening anymore. But they will. Wake up, people.", "Ask yourself who benefits. Ask yourself." } },
    { id = "wedding", title = "wedding planner",
      line = "Was a wedding planner with a big Saturday booked when it all went wrong. Plans everything, seats everyone, cannot stand chaos.",
      style = "brisk, organized, upbeat under stress; seating charts, timelines and color schemes",
      say = { "Okay. Okay. Who's in charge of logistics here? Because it's clearly nobody.", "We're behind schedule. Everyone's behind schedule." } },
    { id = "fryer", title = "Spiffo's fry-station manager",
      line = "Managed the fry station at a Spiffo's. Proud of it. Still runs every job like a lunch rush and still smells faintly of oil.",
      style = "lunch-rush energy: 'behind you', 'fries in the bag', short service-industry calls",
      say = { "Behind you! Sorry. Habit.", "Fries in the bag, people. Fries. In. The. Bag." } },
    { id = "mime", title = "street mime", mute = true,
      line = "Was a street performer, a mime. Has not said a word since it started and isn't going to. Still in the face paint, mostly.",
      style = "never speaks, not one word: answers only with one short action between asterisks",
      say = { "*mimes being trapped in a box, then points at the dead*", "*tips an invisible hat*" } },
}
L.ODD_BY = {}
for _, o in ipairs(L.ODDBALL) do L.ODD_BY[o.id] = o end

-- prefer: background keys (A-Life life story), base = what their group is, leader = runs their group
L.CAMEOS = {
    { key = "nick", fake = { "Nick", "Graves" }, real = { "Rick", "Grimes" }, sex = "m", bg = { cop = 1, deputy = 1, detective = 1 }, minDay = 2,
      line = "Was a sheriff's deputy in a small town. Woke up in a hospital after it started. A leader whether he wants it or not; would do anything for his family and his people, and it's changing him.",
      style = "slow Southern drawl, earnest, firm; speeches when it matters" },
    { key = "laurie", fake = { "Laurie", "Graves" }, real = { "Lori", "Grimes" }, sex = "f", bg = { homemaker = 1, clerk = 0.5 }, minDay = 2,
      line = "A mother and a deputy's wife who thought her husband was dead. Guarded, tired, carrying guilt about things she won't talk about.",
      style = "guarded, tired, protective" },
    { key = "cal", fake = { "Cal", "Graves" }, real = { "Carl", "Grimes" }, sex = "m", minDay = 6,
      line = "18. Was a boy when it started and grew up in it. Wears his father's old hat, missing an eye. Grew hard fast, then learned to be kind again.",
      style = "quiet, older than his years, earnest" },
    { key = "juniper", fake = { "Juniper", "Graves" }, real = { "Judith", "Grimes" }, sex = "f", minDay = 10,
      line = "18. Born after it started; has never known any other world. Sharp, brave, a good shot, and better at hope than the adults.",
      style = "bright, direct, brave" },
    { key = "shaun", fake = { "Shaun", "Welsh" }, real = { "Shane", "Walsh" }, sex = "m", bg = { cop = 1, deputy = 1, hothead = 1 }, minDay = 2,
      line = "Was a sheriff's deputy, his partner's best friend. Survives by doing what others won't, and resents anyone who can't. Something in him is coming apart.",
      style = "hard, quick to anger, blunt" },
    { key = "darrell", fake = { "Darrell", "Dixby" }, real = { "Daryl", "Dixon" }, sex = "m", bg = { hunter = 1, biker_bg = 0.8, drifter = 0.6 }, minDay = 3,
      line = "Grew up rough, in his older brother's shadow. A tracker and hunter who carries a crossbow. Few words, deep loyalty, uneasy with thanks.",
      style = "mumbles, very few words, gruff, never talks about feelings" },
    { key = "earl", fake = { "Earl", "Dixby" }, real = { "Merle", "Dixon" }, sex = "m", bg = { biker_bg = 1, gangbanger = 0.8, bully = 0.8 }, minDay = 5,
      line = "Darrell's older brother. Ex-army, mean mouth, does what pays. Loyal to his brother and nobody else, though there's more to him than he shows.",
      style = "mocking, crude nicknames, cocky" },
    { key = "glen", fake = { "Glen", "Ree" }, real = { "Glenn", "Rhee" }, sex = "m", bg = { clerk = 1, factory = 0.5 }, minDay = 2,
      line = "Delivered pizzas before. Knows every shortcut, fast on his feet, the one who goes into town for supplies. Good-hearted to the core.",
      style = "friendly, quick, a little nervous humor" },
    { key = "meg", fake = { "Meg", "Gray" }, real = { "Maggie", "Greene" }, sex = "f", bg = { farmer = 1 }, minDay = 3,
      line = "A farmer's daughter. Tough, practical, a natural leader in the making, fiercely loyal to the people she chose.",
      style = "plain-spoken, steady, a little dry" },
    { key = "herschel", fake = { "Herschel", "Gray" }, real = { "Hershel", "Greene" }, sex = "m", bg = { vet_animal = 1, farmer = 0.8, grandpa = 0.7 }, minDay = 3,
      line = "An old country veterinarian with a farm and a faith he's had to fight to keep. Patches people up. Calm, wise, honest even when it hurts.",
      style = "slow, gentle, wise, a quiet faith" },
    { key = "bess", fake = { "Bess", "Gray" }, real = { "Beth", "Greene" }, sex = "f", bg = { farmer = 0.6 }, minDay = 4,
      line = "Meg's younger sister. Sings when it's quiet. Looks gentle; is stronger than anyone expects.",
      style = "soft-spoken, kind, steel underneath" },
    { key = "carole", fake = { "Carole", "Pelton" }, real = { "Carol", "Peletier" }, sex = "f", bg = { homemaker = 1, granny = 0.5 }, minDay = 3,
      line = "Was a quiet housewife in a bad marriage. Has become the most practical and ruthless person you'll meet, behind a gentle smile and a tray of cookies.",
      style = "gentle and polite on the surface, cold logic underneath" },
    { key = "mishaun", fake = { "Mishaun", "" }, real = { "Michonne", "" }, sex = "f", minDay = 6,
      line = "Carries a sword and uses it better than most use guns. Arrived alone. Watches, judges, says little; fiercely protective once she trusts you.",
      style = "few words, dry, watchful" },
    { key = "andi", fake = { "Andi", "" }, real = { "Andrea", "" }, sex = "f", bg = { lawyer = 1, clerk = 0.4 }, minDay = 2,
      line = "Was a civil-rights lawyer. Turned out to be a natural shot. Argues, stands her ground, wants to matter.",
      style = "sharp, argumentative, confident" },
    { key = "dale", fake = { "Dale", "Horvat" }, real = { "Dale", "Horvath" }, sex = "m", bg = { grandpa = 1 }, minDay = 2,
      line = "A retired man who travels in an RV. The group's conscience: keeps asking what we're turning into.",
      style = "old-fashioned, thoughtful, moral; worries out loud" },
    { key = "tbone", fake = { "T-Bone", "" }, real = { "T-Dog", "" }, sex = "m", minDay = 2,
      line = "Easygoing, dependable, does the heavy work nobody thanks him for. Notices when he's left out of decisions.",
      style = "laid-back, honest, a little wry" },
    { key = "morgan", fake = { "Morgan", "Joyce" }, real = { "Morgan", "Jones" }, sex = "m", minDay = 8,
      line = "Lost everyone. Lost his mind for a while, then found a way back through a fighting stick and a belief that all life is precious.",
      style = "calm, deliberate, sometimes strange; talks about life being precious" },
    { key = "tyrell", fake = { "Tyrell", "" }, real = { "Tyreese", "" }, sex = "m", bg = { factory = 0.6, contractor = 0.6 }, minDay = 4,
      line = "A big, gentle man who fights with a hammer and hates that he has to. Protective of his sister, Sasha.",
      style = "gentle, slow to anger, troubled by violence" },
    { key = "sasha", fake = { "Sasha", "Wilkes" }, real = { "Sasha", "Williams" }, sex = "f", bg = { firefighter = 1 }, minDay = 4,
      line = "Was a firefighter. A sniper now. Tough, blunt, grieves hard and keeps going.",
      style = "blunt, tough" },
    { key = "rob", fake = { "Rob", "Stoker" }, real = { "Bob", "Stookey" }, sex = "m", bg = { medic_mil = 1, grunt = 0.5 }, minDay = 5,
      line = "Army medic who survived alone too long and drinks to forget it. An optimist anyway: thinks the nightmare will end.",
      style = "warm, hopeful, a little shy" },
    { key = "abram", fake = { "Abram", "Forde" }, real = { "Abraham", "Ford" }, sex = "m", bg = { gulfvet = 1, grunt = 0.8 }, minDay = 6,
      line = "A former Army sergeant with a mission he won't drop. Big voice, colorful language, carries a weight he won't talk about.",
      style = "booming, colorful, military; strange inventive expressions" },
    { key = "rosa", fake = { "Rosa", "Espino" }, real = { "Rosita", "Espinosa" }, sex = "f", minDay = 6,
      line = "Tough, capable, good with knots and engines. Travels with Abram and Eugen.",
      style = "no-nonsense, tough" },
    { key = "eugen", fake = { "Eugen", "Potter" }, real = { "Eugene", "Porter" }, sex = "m", bg = { conman = 0.6, curious = 0.6 }, minDay = 6,
      line = "Mullet, monotone, enormous vocabulary. Claims to be a scientist with a cure. Is lying about that, and is also genuinely brilliant at other things.",
      style = "monotone, extremely formal, long words, precise" },
    { key = "gabe", fake = { "Gabe", "Stoakes" }, real = { "Gabriel", "Stokes" }, sex = "m", bg = { chaplain = 1, devout = 0.8, churchlady = 0.3 }, minDay = 4, confessor = true,
      line = "A priest who locked his church doors when his congregation begged to be let in, and has carried it every day since. Hears confessions. Wants to be braver than he was.",
      style = "a priest: gentle, careful, full of guilt; listens more than he speaks" },
    { key = "tara", fake = { "Tara", "Chandler" }, real = { "Tara", "Chambler" }, sex = "f", bg = { cop = 0.8, deputy = 0.6 }, minDay = 5,
      line = "Was at the police academy. Funny, loyal, says what everyone's thinking.",
      style = "jokey, warm, blurts things out" },
    { key = "erin", fake = { "Erin", "" }, real = { "Aaron", "" }, sex = "m", minDay = 10,
      line = "Recruits for a walled community. Watches people for days before he talks to them; asks three questions to everyone.",
      style = "polite, careful, earnest; asks how many walkers you've killed, how many people, and why" },
    { key = "moses", fake = { "Paul \"Moses\"", "Rovello" }, real = { "Paul \"Jesus\"", "Rovia" }, sex = "m", minDay = 12,
      line = "A long-haired scout and trader for a farming community. Moves like a ninja, smiles a lot, trusts too easily.",
      style = "easygoing, playful, calm" },
    { key = "reagan", fake = { "Reagan", "" }, real = { "Negan", "" }, sex = "m", trade = { warband = 1, slavers = 1 }, leader = true, minDay = 15,
      line = "Runs a band that takes a cut from everyone around them. Charismatic, crude, terrifying, with rules of his own. Carries a barbed-wire bat he calls Lucy.",
      style = "swaggering, crude, theatrical, long drawn-out words, jokes before violence" },
    { key = "mayor", fake = { "Phil", "Black" }, real = { "Philip", "Blake" }, sex = "m", leader = true, fortified = true, minDay = 10,
      line = "Called The Mayor. Runs a walled town that feels safe and is not what it seems. Charming in public, ruthless in private.",
      style = "charming, smooth, politician's warmth, menace under it" },
    { key = "zechariah", fake = { "Zechariah", "" }, real = { "Ezekiel", "" }, sex = "m", leader = true, minDay = 12,
      line = "Leads a community as 'King Zechariah', a role he plays because it gives people hope. Keeps an enormous dog at his side.",
      style = "theatrical, kingly, flowery speech, warm underneath" },
    { key = "greg", fake = { "Greg", "" }, real = { "Gregory", "" }, sex = "m", leader = true, trade = { farmers = 1 }, minDay = 12,
      line = "Runs a farming community and mostly runs it for himself. Weaselly, self-serving, always tries to cut a deal.",
      style = "slimy politeness, condescending, gets names wrong on purpose" },
    { key = "dwayne", fake = { "Dwayne", "" }, real = { "Dwight", "" }, sex = "m", trade = { warband = 1, slavers = 1 }, minDay = 15,
      line = "Half his face is burned. Rides with Reagan's band and hates himself for it. Wants out.",
      style = "quiet, bitter, few words" },
    { key = "simeon", fake = { "Simeon", "" }, real = { "Simon", "" }, sex = "m", trade = { warband = 1, slavers = 1 }, minDay = 15,
      line = "Reagan's right hand. Mustache, grin, wants more than his boss allows. Cheerful when he's being cruel.",
      style = "cheerful menace, folksy" },
    { key = "jada", fake = { "Jada", "" }, real = { "Jadis", "" }, sex = "f", bg = { scavenger = 1, dreamer = 0.5 }, minDay = 12,
      line = "Leads scavengers living in a junkyard. Was an art teacher. Speaks in clipped, strange sentences; trades with whoever offers more.",
      style = "very short clipped sentences, no articles, strange" },
    { key = "omega", fake = { "Omega", "" }, real = { "Alpha", "" }, sex = "f", trade = { warband = 1 }, minDay = 20,
      line = "Leads people who walk among the dead and live like animals on purpose. Believes only the strong deserve to live. Cold, quiet, frightening.",
      style = "whispers, cold, few words, about strength and the pack" },
    { key = "gamma", fake = { "Gamma", "" }, real = { "Beta", "" }, sex = "m", trade = { warband = 1 }, minDay = 20,
      line = "A huge silent man who follows Omega. Never shows his face if he can help it.",
      style = "very few words, deep, threatening" },
    { key = "lydia", fake = { "Lydia", "" }, real = { "Lydia", "" }, sex = "f", minDay = 20,
      line = "18. Grew up with Omega's people and wants something softer. Wary, curious, starved for kindness.",
      style = "wary, quiet, curious" },
    { key = "enya", fake = { "Enya", "" }, real = { "Enid", "" }, sex = "f", minDay = 8,
      line = "18. Survived alone as a kid by trusting nobody. Writes JSS on things: just survive somehow.",
      style = "guarded, sarcastic, short" },
    { key = "dina", fake = { "Dina", "Munroe" }, real = { "Deanna", "Monroe" }, sex = "f", leader = true, fortified = true, minDay = 10,
      line = "A former congresswoman who runs a walled community like it's still the old world. Interviews newcomers on tape.",
      style = "measured, articulate, political" },
}
L.CAMEO_BY = {}
for _, c in ipairs(L.CAMEOS) do L.CAMEO_BY[c.key] = c end
L.FIRST_WORDS = { gabe = "Peace be with you. If there's anything you need to put down, I'm a good listener." }
L.RESCUE_LINES = { "Get up.", "Up. Now.", "Go." }
L.RESCUE_NOTE = { "Get up. Keep moving. Don't come looking for me.", "You were lucky. Don't count on it twice.", "Stay off the open road at dusk. -" }
L.CONFESS_WORDS = { "confess", "confession", "forgive me", "my sins", "absolution", "i have sinned", "bless me" }

L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { oddball = 0, cameos = 0, donors = 0, renamed = 0, greeted = 0, confessions = 0, rescues = 0, rescueFail = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function roll(s) return (hash(s) % 10000) / 10000 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function M() return ALifeLLMTalk end
local function playerOf() local p = nil; p = ALifeSide.campPlayer(); return p end
local function xyOf(o) local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
local function record(uid)
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "read") then return nil end
    local ok, r = pcall(pa.ActorRegistry.read, tostring(uid))
    return ok and type(r) == "table" and r or nil
end
local function shellOf(uid)
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "shellFor") then return nil end
    local ok, s = pcall(pa.Talk.shellFor, tostring(uid))
    return ok and s or nil
end
local function worldKey()
    local m = M()
    if fn(m, "worldId") then local ok, w = pcall(m.worldId); if ok and w then return tostring(w) end end
    return "world"
end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.strangers == false)
end
function L.realNames()
    local v = nil
    pcall(function() v = SandboxVars.ALifeChatPlus.TWDRealNames end)
    return v == true
end
function L.guard(name, f, ...)
    if L.off[name] then return false, nil end
    local r = { pcall(f, ...) }
    if not r[1] then
        L.off[name] = true
        log("hook '" .. name .. "' failed, off for this session: " .. tostring(r[2]))
        return false, nil
    end
    return true, r[2], r[3]
end
function L.store()
    local m = M()
    if not fn(m, "bucket") then return nil end
    local ok, b = pcall(m.bucket, "strangers")
    if not ok or type(b) ~= "table" then return nil end
    b.who = type(b.who) == "table" and b.who or {}        -- uid -> { kind, key, name, h, greeted }
    b.used = type(b.used) == "table" and b.used or {}      -- key -> uid
    b.rescue = type(b.rescue) == "table" and b.rescue or {}
    b.confess = type(b.confess) == "table" and b.confess or {}
    b.lines = type(b.lines) == "table" and b.lines or {}   -- donor lines already used
    return b
end
function L.of(uid)
    local s = L.store()
    return s and s.who[tostring(uid)] or nil
end

----------------------------------------------------------------------------------------------------------------
-- who's who in this world (decided once from the world id, so a reload doesn't reroll)
----------------------------------------------------------------------------------------------------------------
function L.oddballPlan()
    local w = worldKey()
    local o = L.ODDBALL[(hash(w .. "#odd") % #L.ODDBALL) + 1]
    local day = L.cfg.oddDayMin + (hash(w .. "#oddday") % (L.cfg.oddDayMax - L.cfg.oddDayMin + 1))
    return o, day
end
function L.cameoInWorld(c)
    return roll(worldKey() .. "#cameo#" .. c.key) < L.cfg.cameoChance
end
function L.nameFor(c)
    local n = L.realNames() and c.real or c.fake
    return n[1], n[2]
end

----------------------------------------------------------------------------------------------------------------
-- strangers you haven't met
----------------------------------------------------------------------------------------------------------------
function L.unmet(player, l)
    local r = l.record
    if type(r) ~= "table" or r.lifecycle ~= "active" or type(r.memory) ~= "table" then return false end
    local uid = tostring(r.uid)
    local s = L.store()
    if s == nil or s.who[uid] ~= nil then return false end
    local m, pa = M(), PA()
    if fn(m, "store") then
        local ok, st = pcall(m.store)
        if ok and type(st) == "table" and type(st.npcs) == "table" and st.npcs[uid] ~= nil then return false end
    end
    if fn(pa.Names, "knows") and fn(pa.Speech, "playerKey") then
        local okK, key = pcall(pa.Speech.playerKey, player)
        local okN, known = pcall(pa.Names.knows, r, okK and key or nil)
        if okN and known == true and pa.Names.settings and pa.Names.settings.introductions == true then return false end
    end
    if fn(m, "apIsMember") then local ok, yes = pcall(m.apIsMember, r); if ok and yes then return false end end
    if fn(m, "partyIsMember") then local ok, yes = pcall(m.partyIsMember, uid, player); if ok and yes then return false end end
    if fn(m, "settlerOf") then local ok, yes = pcall(m.settlerOf, uid); if ok and yes then return false end end
    return true
end
local function sexOf(l) local f = nil; pcall(function() f = l.shell:isFemale() end); if f == nil then return nil end; return f and "f" or "m" end
local function bgOf(uid)
    local m = M()
    local k = nil
    if fn(m, "partsOf") then pcall(function() local p = m.partsOf(uid); k = p and p.bg and (p.bg.key or p.bg.k) end) end
    return k and tostring(k) or nil
end
local function baseOf(r)
    local m = M()
    if not fn(m, "nbOfMember") then return nil end
    local ok, b = pcall(m.nbOfMember, r)
    return ok and b or nil
end
-- how well this person fits a part (nil = doesn't fit)
function L.fit(c, l)
    if c.sex and sexOf(l) ~= c.sex then return nil end
    local r = l.record
    local uid = tostring(r.uid)
    local b = baseOf(r)
    if c.leader and not (b and tostring(b.leader) == uid) then return nil end
    if c.fortified and not (b and b.stage == "fortified") then return nil end
    if c.trade and not (b and c.trade[tostring(b.trade)]) then return nil end
    local score = 0.2
    if c.bg then
        local w = c.bg[bgOf(uid) or ""]
        if w then score = score + w end
    end
    return score
end
function L.donorFit(d, l)
    if d.sex and sexOf(l) ~= d.sex then return nil end
    local r = l.record
    local uid = tostring(r.uid)
    local b = baseOf(r)
    local bg = bgOf(uid) or ""
    local k = tostring(d.kind or "")
    if k == "trader" then return (b and (b.trade == "traders" or b.trade == "crafters")) and 1 or nil end
    if k == "leader" then return (b and tostring(b.leader) == uid) and 1 or nil end
    if k == "loner" then return b == nil and 1 or nil end
    if k == "medic" then return ({ nurse = 1, doctor = 1, paramedic = 1, medic_mil = 1, pharmacist = 1 })[bg] and 1 or nil end
    if k == "guard" then return ({ guard = 1, cop = 1, deputy = 1, grunt = 1 })[bg] and 1 or nil end
    if k == "soldier" then return ({ grunt = 1, gulfvet = 1, medic_mil = 1, deserter_bg = 1, delta_bg = 1 })[bg] and 1 or nil end
    return 0.5 -- any stranger
end

-- give a stranger their new name (record, body, ID card): nobody has met them, so nobody notices
function L.rename(l, first, last)
    local pa = PA()
    local r = l.record
    if not fn(pa.ActorRegistry, "update") then return false end
    first, last = tostring(first or ""), tostring(last or "")
    local full = last ~= "" and (first .. " " .. last) or first
    local ok, res = pcall(pa.ActorRegistry.update, r.uid, r.revision, function(e)
        e.memory = type(e.memory) == "table" and e.memory or {}
        e.memory.personFirst, e.memory.personLast, e.memory.personName = first, last ~= "" and last or nil, full
    end)
    if not ok or res == nil then return false end
    -- the body they walk around in (A-Life's ID card and the descriptor it names from it)
    local sh = l.shell
    if sh ~= nil then
        pcall(function()
            local desc = sh:getDescriptor()
            desc:setForename(first)
            desc:setSurname(last ~= "" and last or first)
        end)
        local H = pa.ProfileHydrator
        if fn(H, "nameIdentityCard") then
            pcall(function()
                local items = sh:getInventory():getItems()
                for i = 0, items:size() - 1 do
                    local it = items:get(i)
                    if it:hasModData() and it:getModData().ProjectALifeIdentityCard == true then
                        H.nameIdentityCard(it, { personName = full })
                    end
                end
            end)
        end
    end
    L.metrics.renamed = L.metrics.renamed + 1
    return true
end
function L.assign(l, kind, key, first, last, extra)
    local s = L.store()
    if s == nil then return false end
    if first ~= nil and not L.rename(l, first, last) then return false end
    local uid = tostring(l.record.uid)
    local row = { kind = kind, key = key, h = hours() }
    if type(extra) == "table" then for k, v in pairs(extra) do row[k] = v end end
    s.who[uid] = row
    s.used[key] = uid
    log(kind .. " '" .. tostring(key) .. "' is " .. uid .. (first and (" (" .. tostring(first) .. (last and last ~= "" and (" " .. last) or "") .. ")") or ""))
    return true
end

-- once every ten minutes, a look at strangers nearby
function L.scan()
    local p = playerOf()
    local s = L.store()
    local m = M()
    if p == nil or s == nil or not fn(m, "nearbyNpcs") then return end
    local px, py = xyOf(p)
    if px == nil then return end
    local pz = 0
    pcall(function() pz = p:getZ() end)
    local h = hours()
    local day = math.floor(h / 24)
    local okN, near = pcall(m.nearbyNpcs, px, py, pz, L.cfg.scanTiles)
    if not okN or type(near) ~= "table" then return end
    L.greet(p, near)
    if day < L.cfg.firstDay then return end
    local fresh = {}
    for _, l in ipairs(near) do if L.unmet(p, l) then fresh[#fresh + 1] = l end end
    if #fresh == 0 then return end
    if L.placeDonor(fresh) then return end
    if L.placeOddball(fresh, day) then return end
    if h - (tonumber(s.lastCameoH) or -1e9) >= L.cfg.cameoGapH and L.placeCameo(fresh, day) then s.lastCameoH = h end
end
function L.placeDonor(fresh)
    local D, s = ALifeDonors, L.store()
    if not fn(D, "active") then return false end
    for _, d in ipairs(D.active()) do
        local key = "donor:" .. tostring(d.id or d.name)
        local inWorld = (tonumber(d.tier) or 0) >= 50 or roll(worldKey() .. "#" .. key) < 0.5
        if (tonumber(d.tier) or 0) >= 5 and inWorld and s.used[key] == nil then
            for _, l in ipairs(fresh) do
                if L.donorFit(d, l) then
                    local first, last = string.match(tostring(d.name), "^(%S+)%s+(.+)$")
                    if first == nil then first, last = tostring(d.name), "" end
                    if L.assign(l, "donor", key, first, last, { donor = d.id or d.name, odd = d.kind == "oddball" and d.oddball or nil }) then
                        L.metrics.donors = L.metrics.donors + 1
                        L.donorLine(d, l, key)
                        return true
                    end
                end
            end
        end
    end
    return false
end
-- tier 30+: their line, once per world, where they chose it
function L.donorLine(d, l, key)
    local s = L.store()
    if (tonumber(d.tier) or 0) < 30 or type(d.line) ~= "string" or d.line == "" or s.lines[key] then return end
    s.lines[key] = hours()
    local name = tostring(d.name)
    if d.lineAt == "note" then
        local N = ALifeNotes
        local sq = nil
        pcall(function() sq = l.shell:getCurrentSquare() end)
        if sq ~= nil and fn(N, "leaveNote") then pcall(N.leaveNote, sq, "Note from " .. name, d.line) end
    else
        s.lines[key .. ":radioAt"] = hours() + 6 + (hash(key) % 48)
    end
end
function L.placeOddball(fresh, day)
    local s = L.store()
    local o, oddDay = L.oddballPlan()
    if s.used["odd:" .. o.id] ~= nil or day < oddDay then return false end
    for _, l in ipairs(fresh) do
        if o.sex == nil or sexOf(l) == o.sex then
            if L.assign(l, "oddball", "odd:" .. o.id, nil, nil, { odd = o.id }) then
                L.metrics.oddball = L.metrics.oddball + 1
                return true
            end
        end
    end
    return false
end
function L.placeCameo(fresh, day)
    local s = L.store()
    local bestC, bestL, bestScore = nil, nil, -1
    for _, c in ipairs(L.CAMEOS) do
        if s.used["tv:" .. c.key] == nil and day >= (c.minDay or 0) and L.cameoInWorld(c) then
            for _, l in ipairs(fresh) do
                local sc = L.fit(c, l)
                if sc and sc > bestScore then bestC, bestL, bestScore = c, l, sc end
            end
        end
    end
    if bestC == nil then return false end
    local first, last = L.nameFor(bestC)
    if not L.assign(bestL, "cameo", "tv:" .. bestC.key, first, last, { cameo = bestC.key, real = L.realNames() }) then return false end
    L.metrics.cameos = L.metrics.cameos + 1
    return true
end
-- the sandbox name switch changed since they were named: follow it
function L.renameCameos()
    local s = L.store()
    if s == nil then return end
    local want = L.realNames()
    for uid, row in pairs(s.who) do
        if row.kind == "cameo" and row.real ~= want and L.CAMEO_BY[row.cameo] then
            local r = record(uid)
            if r and r.lifecycle ~= "dead" then
                local first, last = L.nameFor(L.CAMEO_BY[row.cameo])
                if L.rename({ record = r, shell = shellOf(uid) }, first, last) then row.real = want end
            end
        end
    end
end

-- the odd thing they say when you first come close (and the confessor's offer)
function L.greet(p, near)
    local s = L.store()
    local m = M()
    local px, py = xyOf(p)
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        local row = s.who[uid]
        if row and not row.greeted and (tonumber(l.d2) or 1e9) <= L.cfg.greetTiles * L.cfg.greetTiles then
            local line = nil
            local o = row.odd and L.ODD_BY[row.odd] or nil
            if o then line = o.say[(hash(uid) % #o.say) + 1]
            elseif row.cameo and L.FIRST_WORDS[row.cameo] then line = L.FIRST_WORDS[row.cameo] end
            row.greeted = true
            if line and fn(m, "say") and l.shell then
                pcall(m.say, l.shell, p, line, { record = l.record })
                L.metrics.greeted = L.metrics.greeted + 1
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- what the AI knows about them (persona and how they talk)
----------------------------------------------------------------------------------------------------------------
function L.personaFor(uid)
    local row = L.of(uid)
    if row == nil then return nil end
    if row.kind == "rescuer" then
        return "A lone man in old military gear who appeared out of nowhere and cleared the dead off the stranger. Nobody knows who he is. He will not say.",
            "barely talks: one to three words at most, never explains himself, never gives a name"
    end
    local o = row.odd and L.ODD_BY[row.odd] or nil
    if o then return "Before all this: " .. o.title .. ". " .. o.line, o.style end
    local c = row.cameo and L.CAMEO_BY[row.cameo] or nil
    if c then return c.line, c.style end
    if row.kind == "donor" and fn(ALifeDonors, "active") then
        for _, d in ipairs(ALifeDonors.active()) do
            if (d.id or d.name) == row.donor and type(d.persona) == "string" and d.persona ~= "" then return d.persona, nil end
        end
    end
    return nil
end
function L.requestExtra(req, player, listener, now)
    if not L.enabled() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local uid = tostring(listener.record.uid)
    local line, style = L.personaFor(uid)
    if line ~= nil then
        req.persona = type(req.persona) == "table" and req.persona or {}
        req.persona.line = line
        req.persona.needStory = nil
        if style then
            req.psyche = type(req.psyche) == "table" and req.psyche or {}
            req.psyche.style = style
        end
    end
    local c = L.confessLast
    if c and c.uid == uid and (tonumber(now) or nowMs()) - c.at <= L.cfg.askWindowMs then
        req.topic = { label = "a confession", key = "confession", fact = c.fact }
    end
end

----------------------------------------------------------------------------------------------------------------
-- the confessor
----------------------------------------------------------------------------------------------------------------
function L.isConfession(text)
    local t = string.lower(tostring(text or ""))
    for _, w in ipairs(L.CONFESS_WORDS) do if string.find(t, w, 1, true) then return true end end
    return false
end
-- what people say you've done (the rumours about you, worst and best)
function L.deedsSaid()
    local m = M()
    if not fn(m, "bucket") then return {}, 0, 0 end
    local ok, list = pcall(m.bucket, "rumors")
    if not ok or type(list) ~= "table" then return {}, 0, 0 end
    local bad, good, out = 0, 0, {}
    for i = #list, 1, -1 do
        local r = list[i]
        if type(r) == "table" and type(r.t) == "string" then
            local w = tonumber(r.w) or 0
            if w < 0 then bad = bad + 1 elseif w > 0 then good = good + 1 end
            if #out < 5 and w ~= 0 then out[#out + 1] = r.t end
        end
    end
    return out, bad, good
end
L.CONFESS_SAY = {
    heavy = "I've heard what people say about you. I won't pretend I haven't. But you're here, and that counts for something. Say it. All of it.",
    light = "People speak well of you, mostly. And still you came. Whatever it is, it's safe with me.",
    none = "I don't know you, and that's fine. God does. Go on.",
}
function L.onWords(player, text, loud, hearers)
    if not L.enabled() or type(hearers) ~= "table" or not L.isConfession(text) then return end
    local l = hearers[1]
    local r = type(l) == "table" and l.record or nil
    if type(r) ~= "table" then return end
    local uid = tostring(r.uid)
    local row = L.of(uid)
    if row == nil or row.cameo ~= "gabe" then return end
    local s = L.store()
    local h = hours()
    local said, bad, good = L.deedsSaid()
    local fact = "the stranger wants to confess to you, a priest. What people say they've done: "
        .. (#said > 0 and table.concat(said, "; ") or "nothing you've heard of")
        .. ". Listen, don't judge them harshly, keep what they say secret. If they did terrible things, say so gently but honestly."
    L.confessLast = { uid = uid, at = nowMs(), fact = fact }
    L.metrics.confessions = L.metrics.confessions + 1
    local m = M()
    if fn(m, "keyMem") and h - (tonumber(s.confess[uid]) or -1e9) >= L.cfg.confessGapH then
        pcall(m.keyMem, uid, "confession", "Heard the newcomer's confession. I keep it to myself")
    end
    local aiUp = fn(m, "bridgeAlive") and m.bridgeAlive(nowMs()) == true
    if not aiUp and h - (tonumber(s.confess[uid]) or -1e9) >= L.cfg.confessGapH and fn(m, "say") and l.shell ~= nil then
        local line = (bad > good and L.CONFESS_SAY.heavy) or ((bad + good) > 0 and L.CONFESS_SAY.light) or L.CONFESS_SAY.none
        pcall(m.say, l.shell, player, line, { record = r })
    end
    s.confess[uid] = h
end

----------------------------------------------------------------------------------------------------------------
-- the stranger who comes when it's over
----------------------------------------------------------------------------------------------------------------
-- cheap, allocation-free checks first (run every 2 s)
local function bodyHealth(p) local bd = p and p:getBodyDamage(); if bd == nil then return 100 end; return bd:getOverallBodyHealth() end
function L.deadAround(px, py, tiles)
    local list = nil
    pcall(function() list = getCell():getZombieList() end)
    if list == nil then return 0 end
    local n, r2 = 0, tiles * tiles
    local size = list:size()
    if size > 600 then size = 600 end
    for i = 0, size - 1 do
        local z = list:get(i)
        local zx, zy = z:getX(), z:getY()
        if (zx - px) * (zx - px) + (zy - py) * (zy - py) <= r2 then
            local npc = false
            if z:hasModData() and z:getModData().ProjectALifeUID ~= nil then npc = true end
            if not npc and not z:isDead() then n = n + 1 end
        end
    end
    return n
end
function L.mineNear(player, px, py, pz)
    local m = M()
    if not fn(m, "nearbyNpcs") then return false end
    local ok, near = pcall(m.nearbyNpcs, px, py, pz, L.cfg.mineTiles)
    if not ok or type(near) ~= "table" then return false end
    for _, l in ipairs(near) do
        local uid = tostring(l.record.uid)
        if (fn(m, "partyIsMember") and m.partyIsMember(uid, player)) or (fn(m, "settlerOf") and m.settlerOf(uid)) then return true end
    end
    return false
end
function L.rescueCheck()
    local s = L.store()
    if s == nil or s.rescue.done or s.rescue.groupId then return end
    local h = hours()
    if h < L.cfg.rescueDayMin * 24 then return end
    local p = playerOf()
    if p == nil then return end
    local okH, health = pcall(bodyHealth, p)
    if not okH or (tonumber(health) or 100) >= L.cfg.hurt then return end
    local px, py = xyOf(p)
    local pz = 0
    pcall(function() pz = p:getZ() end)
    local dead = L.deadAround(px, py, L.cfg.deadNear)
    if dead < L.cfg.deadCount then return end
    if dead < L.cfg.crowd and L.mineNear(p, px, py, pz) then return end
    L.summon(p, px, py, h)
end
function L.summon(p, px, py, h)
    local s = L.store()
    local S = PA() and PA().DebugService
    if not fn(S, "spawnEncounter") then s.rescue.done = true; L.metrics.rescueFail = L.metrics.rescueFail + 1; log("rescuer: no spawn service"); return end
    for i, fid in ipairs(L.cfg.rescueFactions) do
        local ok, accepted, why, res = pcall(S.spawnEncounter, p, {
            requestId = "alcp_rescuer_" .. tostring(math.floor(h * 10)) .. "_" .. i,
            mode = "hunt", count = 1, factionId = fid, playerStance = "friendly",
            arrival = "foot", persistent = false, adminPick = true, distance = 18,
            objectiveX = math.floor(px), objectiveY = math.floor(py),
        }, true)
        if ok and accepted == true and type(res) == "table" and res.groupId ~= nil then
            s.rescue.groupId, s.rescue.at, s.rescue.x, s.rescue.y = tostring(res.groupId), h, math.floor(px), math.floor(py)
            L.metrics.rescues = L.metrics.rescues + 1
            log("rescuer on the way (" .. fid .. ", group " .. tostring(res.groupId) .. ")")
            return
        end
        log("rescuer: " .. fid .. " refused (" .. tostring(ok and why or accepted) .. ")")
    end
    s.rescue.done = true
    L.metrics.rescueFail = L.metrics.rescueFail + 1
end
function L.findRescuer(gid)
    local pa = PA()
    local found = nil
    if not fn(pa.ActorRegistry, "each") then return nil end
    pcall(pa.ActorRegistry.each, function(rec)
        if found == nil and type(rec.memory) == "table" and tostring(rec.memory.groupId) == gid and rec.lifecycle ~= "dead" then found = rec end
        return found ~= nil
    end)
    return found
end
function L.rescueStep()
    local s = L.store()
    local res = s and s.rescue or nil
    if res == nil or res.groupId == nil or res.gone then return end
    local p = playerOf()
    local px, py = xyOf(p)
    if px == nil then return end
    local h = hours()
    if res.uid == nil then
        local r = L.findRescuer(res.groupId)
        if r == nil then
            if h - (tonumber(res.at) or h) > 2 then res.gone, res.done = true, true; log("rescuer never arrived") end
            return
        end
        res.uid = tostring(r.uid)
        s.who[res.uid] = { kind = "rescuer", key = "rescuer", h = h }
    end
    local sh = shellOf(res.uid)
    local m = M()
    local sx, sy = xyOf(sh)
    if sx ~= nil and not res.spoke and d2(sx, sy, px, py) <= 64 and fn(m, "say") then
        res.spoke = true
        pcall(m.say, sh, p, L.RESCUE_LINES[(hash(res.uid) % 2) + 1], { record = record(res.uid) })
    end
    -- it's over: a note, one word, and he walks
    if not res.note and (L.deadAround(px, py, L.cfg.deadNear) < L.cfg.clearCount or h - res.at >= L.cfg.stayMin / 60) then
        res.note = h
        local sq = nil
        pcall(function() sq = p:getCurrentSquare() end)
        if sq and fn(ALifeNotes, "leaveNote") then pcall(ALifeNotes.leaveNote, sq, "Note", L.RESCUE_NOTE[(hash(res.uid .. "n") % #L.RESCUE_NOTE) + 1]) end
        if sh and fn(m, "say") then pcall(m.say, sh, p, L.RESCUE_LINES[3], { record = record(res.uid) }) end
        if type(ALifeLetter) == "function" then pcall(ALifeLetter, p, "Someone pulled you out of it. He left a note at your feet.") end
        if fn(m, "addDeed") then pcall(m.addDeed, "rescued", "a man nobody knows pulled the stranger out of a horde and walked off", 0, {}, px, py) end
        res.rumourAt = h + 24 * (L.cfg.rumourDaysMin + (hash(res.uid .. "r") % (L.cfg.rumourDaysMax - L.cfg.rumourDaysMin + 1)))
    end
    -- gone by morning: once you're far from him, or it's dawn and you can't see him
    if res.note then
        local far = sx == nil or d2(sx, sy, px, py) > L.cfg.retireTiles * L.cfg.retireTiles
        local dawn = false
        pcall(function() local t = getGameTime():getTimeOfDay(); dawn = t >= 5 and t < 9 and h - res.note > 3 end)
        if far or dawn and (sx == nil or d2(sx, sy, px, py) > 400) then
            local SS = PA() and PA().SpawnService
            if fn(SS, "retire") then pcall(SS.retire, res.uid, "alcp_rescuer_gone") end
            res.gone, res.done = true, true
            log("rescuer gone")
        end
    end
end
function L.rumourStep()
    local s = L.store()
    local res = s and s.rescue or nil
    local m = M()
    if res and res.rumourAt and not res.rumoured and hours() >= res.rumourAt then
        res.rumoured = true
        if fn(m, "newsNote") then pcall(m.newsNote, "rumor", "Someone on the band swears a lone soldier walks the roads at night and pulls people out of hordes. Nobody's ever got his name", res.x, res.y) end
    end
    -- supporters' radio lines
    if s and fn(m, "radioLine") then
        local h = hours()
        for key, at in pairs(s.lines) do
            if type(key) == "string" and string.sub(key, -8) == ":radioAt" and tonumber(at) and h >= at and not s.lines[key .. ":done"] then
                s.lines[key .. ":done"] = true
                local id = string.sub(key, 1, -9)
                for _, d in ipairs(fn(ALifeDonors, "active") and ALifeDonors.active() or {}) do
                    if "donor:" .. tostring(d.id or d.name) == id then pcall(m.radioLine, nil, d.line, d.name) end
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "extra", "words", "help" }
function L.install()
    local m = M()
    if type(m) ~= "table" then return 0, L.HOOKS end
    if type(m.settings) == "table" and m.settings.strangers == nil then m.settings.strangers = true end
    if type(m.requestExtras) == "table" and not L.hooked.extra then
        table.insert(m.requestExtras, function(req, player, listener, now) L.guard("extra", L.requestExtra, req, player, listener, now) end)
        L.hooked.extra = true
    end
    if type(m.playerWordHooks) == "table" and not L.hooked.words then
        table.insert(m.playerWordHooks, function(player, text, loud, hearers) L.guard("words", L.onWords, player, text, loud, hearers) end)
        L.hooked.words = true
    end
    if type(m.winHelp) == "table" and not L.hooked.help then
        local thanks = fn(ALifeDonors, "creditsText") and ALifeDonors.creditsText() or nil
        if thanks then m.winHelp[#m.winHelp + 1] = { "Thanks", thanks } end
        L.hooked.help = true
    end
    L.guard("rename", L.renameCameos)
    local n, missing = 0, {}
    for _, h in ipairs(L.HOOKS) do if L.hooked[h] then n = n + 1 else missing[#missing + 1] = h end end
    return n, missing
end
L.tries = 0
function L.tryInstall()
    L.tries = L.tries + 1
    local ok, n, missing = pcall(L.install)
    if not ok then log("install failed: " .. tostring(n)); return true end
    if #missing == 0 or L.tries >= 20 then
        local o, day = L.oddballPlan()
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or "")
            .. " (names: " .. (L.realNames() and "real" or "almost") .. ")")
        return true
    end
    return false
end
L.lastCheck = 0
if Events ~= nil then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            if L.tryInstall() then return end
            if Events.OnTick == nil then return end
            local last = 0
            local function retry()
                local now = nowMs()
                if now - last < 500 then return end
                last = now
                if L.tryInstall() then Events.OnTick.Remove(retry) end
            end
            Events.OnTick.Add(retry)
        end)
    end
    if Events.EveryTenMinutes ~= nil then
        Events.EveryTenMinutes.Add(function()
            if not L.enabled() then return end
            L.guard("scan", L.scan)
            L.guard("rumour", L.rumourStep)
        end)
    end
    if Events.OnTick ~= nil then
        -- every 2 s: are you down with the dead on you (cheap checks, nothing allocated unless it's bad)
        Events.OnTick.Add(function()
            local t = nowMs()
            if t - L.lastCheck < L.cfg.checkMs then return end
            L.lastCheck = t
            if L.off.rescue or not L.enabled() then return end
            local ok, err = pcall(L.rescueCheck)
            if ok then ok, err = pcall(L.rescueStep) end
            if not ok then L.off.rescue = true; log("hook 'rescue' failed, off for this session: " .. tostring(err)) end
        end)
    end
end
print(TAG .. " loaded v" .. L.VERSION)
