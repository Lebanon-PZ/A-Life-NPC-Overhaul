-- A-Life Talk 0.5.1.7: Relationships window - the Bond tab (per person) + the settings rows of 0.5.1.7
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeLLMTalk_UI"
require "ALifeLLMTalk/ALifeLLMTalk_UIPage"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UIBond"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UIBond") end end
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
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
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
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
M.spokeAt = M.spokeAt or {}
-- one line: the AI (react mode) with a canned fallback
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    if l == nil or l.record == nil then return false end
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid) .. (opts.sub and (":" .. opts.sub) or "")
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 8000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 16,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say and l.shell then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    if x == nil then return {}, player end
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    local uid = tostring(l.record.uid)
    if M.isPaused and M.isPaused(uid) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_UIBond", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
local function lensOf(uid) local ok, l = pcall(function() return M.lens and M.lens(uid) or {} end); return ok and type(l) == "table" and l or {} end
local function keyOf(uid) local ok, k = pcall(function() local p = M.partsOf and M.partsOf(uid) or nil; return p and p.core and p.core.key or "" end); return ok and tostring(k or "") or "" end
local function modsOf(uid) local ok, m = pcall(function() return M.personaMods and M.personaMods(uid) or {} end); return ok and type(m) == "table" and m or {} end
local function opinionOf(uid, player)
    local r = rec(uid)
    local pa = PA()
    if r and player and fn(pa.NpcOpinion, "valueOf") then
        local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
        if ok and tonumber(v) then return tonumber(v) end
    end
    local e = bucket("book")[tostring(uid)]
    if type(e) == "table" and tonumber(e.value) then return tonumber(e.value) end
    return nil
end
local function opAdj(uid, player, d, why)
    local r = rec(uid)
    if r == nil or player == nil or d == 0 then return false end
    local pa = PA()
    local f = M.origAdjust or (pa.NpcOpinion and pa.NpcOpinion.adjust)
    if type(f) ~= "function" then return false end
    return pcall(f, r, player, d, why)
end
local function listenerOf(uid)
    local pa = PA()
    local r = rec(uid)
    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil
    if r == nil or sh == nil then return nil end
    return { record = r, shell = sh }
end
local function distTo(l, player)
    local x, y = pos(l and l.shell); local px, py = pos(player)
    if x == nil or px == nil then return 1e9 end
    return math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
end

----------------------------------------------------------------------------------------------------------------
-- the Bond tab of the Relationships window (per person): tier + standing, what they're doing, "what they think of
-- you", likes / dislikes ("???" until learned), grudge / change, the Ask / Step back / Apologize buttons (gated,
-- with a hint when greyed out) and the shared-history timeline. Everything read from the people book, so it works
-- for people far away. Plus the settings rows of 0.5.1.7.
----------------------------------------------------------------------------------------------------------------
local newRows = {
    { "bondTiers", "Bond tiers with you: friend / close / best friend / lover (you ask)" },
    { "bondHistory", "Shared history timeline (Bond tab)" },
    { "bondThought", "'What they think of you' line (Bond tab)" },
    { "bondLikes", "Likes and dislikes, learned over time" },
    { "grudges", "Grudges and revenge, by personality" },
    { "changeOverTime", "People change over months (harden / crack / go feral)" },
    { "habits", "Routines and habits: chores, meals, smokes, drinks (less sitting)" },
    { "baseParty", "People living at your base can travel with you (and go home)" }, -- 0.5.1.8
    { "alifeBase", "Settlers use A-Life's own base (safehouse / BaseHeat) as home" },
    { "npcBases", "NPC bases: groups and loners settle into houses of their own" }, -- 0.5.2
    { "npcBasesMax", "NPC bases: most at once", { 2, 4, 6, 8, 10 } },
    { "npcBaseRate", "NPC bases: founding rate (%)", { 0, 25, 50, 100, 150, 200 } },
    { "npcBaseDanger", "NPC bases: attacks / overruns while you're away (final deaths)" },
    { "honestScavenge", "World bleeds dry: NPC scavenging takes from real buildings, which then stay bare (off = A-Life's own scavenging)" }, -- 0.6.0
    { "npcForage", "NPC bases forage and hunt a little food at home (off = only what they loot or trade)" }, -- 0.6.0
    { "derelictDebug", "Console: name the buildings NPCs strip (spoilers; off = counts only)" }, -- 0.6.0
    { "missingPeople", "Your people who die out of sight go missing first: someone tells you where they were headed; search for them" }, -- 0.6.15
    { "healthLog", "Health report: a note when a feature switches itself off after an error, and a cost log (Zomboid/Lua/ALifeChatPlus_health.txt)" }, -- 0.6.16
    { "peopleLeave", "People who go somewhere walk off out of sight and are on the road while they travel (you can meet them)" }, -- 0.6.17
    { "ownCaravans", "Without a Jeem base caravans come to your trading post or base and you trade face to face" }, -- 0.6.18
    { "chokepoints", "Outposts hold river crossings, the only road into town and crossroads; traders passing pay a toll or get robbed" }, -- 0.6.19
    { "warMap", "War map: known wars and estimated territory on your map, from what you've heard" }, -- 0.7.0
    { "itemWorth", "Every item has its own worth (trading, flights, raids, how rich groups are)" }, -- 0.6.14
    { "partyRides", "Your party gets in the car with you (real seats) and gets out when you do" }, -- 0.7.1
    { "partySecondCar", "Not enough seats: the rest of your party takes another car nearby and follows you" }, -- 0.7.2
    { "alifeCompanionLink", "A-Life's companions are your party too (A-Life moves them; your orders and their opinions of you still count)" }, -- 0.7.3
    { "injuryBridge", "Downed people: they and anyone watching remember what you did; downed enemies can be taken prisoner; camp medics get the downed up" }, -- 0.7.4
    { "fuelRoads", "Gas gets dearer as days pass and A-Life's drivers run dry; people off the road remember their trip; places get named after what happened there" }, -- 0.7.5
    { "paperCars", "Caravans that drive come in their own car: it leaves their lot, parks near you, and goes home (one car, moved on paper)" }, -- 0.7.6
    { "skyPower", "Helicopters: the Louisville National Guard flies real ones, shot-down helicopters matter, groups race you to the wreck; Juggernaut kills get talked about" }, -- 0.7.7
    { "tasksLetters", "Contacts and journal tasks from this mod; last letters from people close to you; what you've done gets told around" }, -- 0.7.8
    { "radioKnox", "The Field Band carries what really happened (groups you know, the Guard's call signs); ask anyone what happened in Knox" }, -- 0.7.9
    { "oathWatch", "The Oath (the most devoted swear never to leave you) and Night shift (30 nights on watch: they see twice as far)" }, -- 0.7.10
    { "seasons", "Seasons and ceremonies: your camp holds a feast on the day it all started, Christmas and every month since you set up, from your real stores; everyone stops for the first snow" }, -- 0.7.11
    { "strangers", "Strangers: one oddball per world, familiar faces from a certain TV show, Father Gabe hears confessions, and a stranger who comes when it's over (once)" }, -- 0.7.12
    { "kingmaker", "Kingmaker: when your weight decides who's strongest around you, both sides want you; the strongest group around isn't asked for tribute" }, -- 0.7.13
    { "saboteur", "The saboteur: after you wipe out a group, someone new among your people may be one of theirs (fair tells; someone of yours notices first)" }, -- 0.7.14
    { "guardOnlySky", "Helicopters fly only when the Louisville National Guard is using them (supply flights, its own raids and support); off = A-Life's own flights" }, -- 0.8.0
    { "alifeCarsOff", "A-Life makes no cars of its own (traffic, drive-bys, camp cars); only this mod puts NPCs behind the wheel; off = A-Life's cars" }, -- 0.8.0
    { "realCars", "NPC groups take real parked cars: get in, hotwire or use the keys, top up from a pump or another car, drive off (never a car from nothing)" }, -- 0.8.4
    { "realCarsReach", "Real cars: how close a parked car must be for a group to notice it (tiles)", { 25, 45, 80 } }, -- 0.8.4
    { "realCarsChance", "Real cars: chance a travelling group goes for a car it noticed (each look, 20 s apart)", { 5, 10, 20, 40 } }, -- 0.8.4
    { "realCarsTrips", "Real cars: most groups driving at once", { 2, 4, 6, 10 } }, -- 0.8.4
    { "realCarsPlayerHours", "Real cars: game hours after you were in a car that nobody takes it", { 24, 72, 168 } }, -- 0.8.4
    { "realCarsKeys", "Real cars: no made-up keys (it must be hotwired, have the keys in it, or they carry its key)" }, -- 0.8.4
    { "realCarsSiphonKit", "Real cars: siphoning another car needs a hose and a can on one of them" }, -- 0.8.4
    { "realCarsPumpReach", "Real cars: a pump further than this needs a can carried to it (tiles)", { 2, 4, 8 } }, -- 0.8.4
    { "realCarsBaseMargin", "Real cars: nobody takes a car in your base or this close to it (tiles)", { 0, 10, 30 } }, -- 0.8.4
    { "foodScanRadius", "Camp food count: how far from your base's middle it looks (tiles)", { 15, 30, 50, 80 } }, -- pre-1.0
    { "foodScanFloors", "Camp food count: how many floors it looks at", { 1, 2, 4, 6 } }, -- pre-1.0
    { "foodScanMax", "Camp food count: most containers it reads in the base area (marked Food stores are always read)", { 100, 400, 800, 1500 } }, -- pre-1.0
    { "windowTalk", "Talk window: a Say tab next to A-Life's tabs, and your chat key opens a typing box under the window; they answer in their own words" }, -- 0.8.1
    { "talkPauseKey", "Talk window: your pause key (Space) pauses the game instead of picking a row" }, -- 0.8.2
    { "talkAutoPause", "Pause while talking: the talk window pauses the game when it opens and unpauses when it closes" }, -- 0.8.2
    { "commands", "Commands: tell your people what to do in your own words (hold fire, go dark, clear the house...); Help > Commands lists them" }, -- 0.8.2
    { "aiCommands", "Commands: the AI understands orders in any words (they only do it if they agree)" }, -- 0.8.2 part 2
    { "cmdBaseReach", "Commands: \"back to base\" works from this far away (tiles)", { 100, 200, 300, 600 } }, -- 0.8.2 part 2
    { "cmdMapTrust", "How much someone must like you to show you their place on the map", { 0, 15, 30, 50 } }, -- 0.8.2 part 2
    { "thirstPerH", "How fast people get thirsty (per game hour; hunger is 0.035)", { 0.03, 0.05, 0.08 } }, -- 0.8.2 part 2
    { "wakeReach", "Wake me if anything comes: how close it gets before they wake you (tiles)", { 8, 15, 25 } }, -- 0.8.3
    { "wakeHours", "Wake me if anything comes: how long they keep watch (game hours)", { 8, 12, 24 } }, -- 0.8.3
    { "teachHours", "Teach me: how long a lesson lasts (game hours)", { 0.5, 1, 2 } }, -- 0.8.3
    { "teachXp", "Teach me: XP every 10 minutes for each level they're ahead of you", { 4, 8, 16 } }, -- 0.8.3
    { "teachReach", "Teach me: how close you must stay (tiles)", { 3, 4, 6 } }, -- 0.8.3
    { "teachGapH", "Teach me: hours before the same person teaches the same skill again", { 12, 24, 48 } }, -- 0.8.3
    { "siphonMinutes", "Siphon that car: minutes at the car before the can is full", { 5, 10, 20 } }, -- 0.8.3
    { "siphonGiveUpMin", "Siphon that car: minutes before they give up getting there", { 60, 90, 180 } }, -- 0.8.3
    { "keepEngineMin", "Keep the engine running: minutes it stays on after they get out", { 30, 60, 120 } }, -- 0.8.3
    { "guardTiles", "Guard post: how far (tiles) a guard goes after the dead from their spot (A-Life: 8)", { 8, 14, 20, 30 } },
    { "talkWants", "They ask you for things (food, water, medicine, ammo) and remember if you bring it" }, -- 0.8.3 step 10
    { "askThanks", "When you bring what they asked for: how much more they like you", { 2, 4, 8 } }, -- 0.8.3 step 10
    { "askDays", "How many days they wait for what they asked for", { 1, 2, 4 } }, -- 0.8.3 step 10
    { "askForgotCost", "When you never bring it: how much less they like you (0 = nothing)", { 0, 1, 3 } }, -- 0.8.3 step 10
    { "npcVehicles", "NPC groups drive their real vehicles when they have fuel" }, -- 0.6.11
    { "hubWindow", "One A-Life window with tabs (People, Party, Journal, Camp, Settings); off = separate windows" }, -- 0.6.10
    { "journal", "Journal: Places shows what you've learned (and from whom), not live numbers" }, -- 0.6.9
    { "tradingPost", "Trading post: groups that know your place send caravans on their own" }, -- 0.6.8
    { "marketDays", "Market days: announce one on the radio (pick the day and time, once or weekly)" }, -- 0.6.8
    { "radioCalls", "Radio: call nearby groups for traders or help (needs a two-way radio that's on)" }, -- 0.6.7
    { "allyHelp", "Radio: groups that like you send real fighters to help you" }, -- 0.6.7
    { "bounties", "Bounties: groups that hate you send real hunters after you" }, -- 0.6.7
    { "caravans", "Caravans: real people from nearby groups bring real goods to trade (needs the Jeem Extension's traders)" }, -- 0.6.6
    { "outposts", "Big NPC groups send a few people to hold outposts (police stations, clinics, gas stations...)" }, -- 0.6.5
    { "nomads", "Starving NPC groups whose land is stripped pack up and move on (off = they scatter)" }, -- 0.6.5
    { "darkContent", "Dark content: groups can become slavers (more with 0.7 captives). Off by default" }, -- 0.6.4
    { "seededBases", "Pre-seeded bases: some houses around the map are already NPC homes" }, -- 0.5.2.1
    { "seededBasesCount", "Pre-seeded bases: how many", { 0, 2, 3, 4, 6 } },
    { "seededSpawn", "Pre-seeded bases: A-Life may draw a new squad when nobody is around" },
    { "storeTidy", "Save tidy: drop saved data of people A-Life no longer has (daily)" }, -- 0.5.2.2
    { "reshowDedupe", "Speech: never stack a second copy of a line still on screen" }, -- 0.5.2.3
    { "yieldBusy", "Speech: when they are hurt or fighting, their own shout wins (your reply is not forced or shown again)" }, -- 0.8.2.1
    { "cleanMarkup", "Speech: strip colour / format codes from NPC lines" }, -- 0.5.2.3
    { "speechOnce", "Speech: each line once per NPC (no repeats within a few seconds)" }, -- 0.5.2.4
    { "hookOnce", "Load safety: hooks and listeners installed once, even with a second copy" }, -- 0.5.2.4
    { "stopReAdders", "Load safety: stop a leftover file that re-adds a listener every frame" }, -- 0.5.2.4
    { "unifiedDates", "Dates: one format everywhere in the Relationships window" }, -- 0.5.2.5
    { "pronounFix", "'What they think of you': keep he / she / they straight" }, -- 0.5.2.5
    { "lastWordsConfirm", "Last words: witnesses only remember them once the person really died" }, -- 0.5.2.5
    { "fastReplyPoll", "Replies: check for your answer every tick while it is on its way" }, -- 0.5.2.5
    { "replyFirst", "Replies: your line never waits behind an overheard-line / event job" }, -- 0.5.2.5
    { "preemptStock", "Replies: an injury line cut off by your line is still said (stock line)" }, -- 0.5.2.5
    { "orderRule", "Orders ('shoot to kill bandits'): always answered yes or no" }, -- 0.5.2.5
    { "offDeath", "Deaths you didn't see (scavenging, away, offline fights) count everywhere" }, -- 0.5.2.6
    { "deathMerge", "Relationships: one row per person (no 'Away' copy of someone dead)" }, -- 0.5.2.6
    { "toldDeath", "Telling an NPC someone died: they remember it and grieve" }, -- 0.5.2.6
    { "deathFacts", "Replies: NPCs always know who of theirs is dead (never cut)" }, -- 0.5.2.6
    { "bridgeVersionWarn", "Warn once when the bridge is older than the mod" }, -- 0.5.2.6
    { "uiFixedSize", "Relationships window: one size for every tab (from the screen), content scrolls" }, -- 0.5.2.7
    { "fixApology", "Apologize: says why when there's nothing to forgive; no false cooldown" }, -- 0.5.2.7
    { "uiFancy", "Relationships: card style (headers, pills, bars) like the Personality page" }, -- 0.5.2.7
    { "uiWrap", "Relationships lists: long lines wrap (rows grow), full text on hover" }, -- 0.5.2.7
    { "partnerLossTrauma", "Losing a partner / family / close friend is a major trauma (scaled by closeness, who's left)" }, -- 0.5.2.7
    { "lossTalk", "Grieving people bring the dead up on their own (mentions, reminders, anniversaries)" }, -- 0.5.2.7
    { "likesSaidOnly", "A like is learned only when they really say it (not when you ask)" }, -- 0.5.2.8
    { "talkThread", "They remember what they just said: short follow-ups stay on that topic" }, -- 0.5.2.8
    { "talkVisit", "They follow the whole conversation while you talk (not just their last line)" }, -- 0.8.3
    { "visitGapSec", "Conversation: a pause this long (seconds) ends it", { 120, 300, 600, 900 } }, -- 0.8.3
    { "visitTurns", "Conversation: lines they keep in mind", { 6, 8, 12, 16, 20 } }, -- 0.8.3
    { "visitChars", "Conversation: most text they keep in mind (lower for small local models)", { 800, 1200, 1600, 2400 } }, -- 0.8.3
    { "talkEndClose", "When they end the talk (or you say goodbye), the talk window closes" }, -- 0.8.3
    { "talkEndRefuse", "After they walk out of a talk they won't talk to you for a while (A-Life's refuse time)" }, -- 0.8.3
    { "talkPushCost", "Keep pushing after they ended it: how much they like you less each time", { 0, 1, 2, 3, 5 } }, -- 0.8.3
    { "talkPushMax", "Keep pushing: most times it counts per walk-out", { 1, 3, 5, 10 } }, -- 0.8.3
    { "talkSuggest", "Talk window: the AI suggests a few things you could say next (Say tab)" }, -- 0.8.3
    { "talkSuggestCount", "Talk window: how many suggestions", { 1, 2, 3 } }, -- 0.8.3
    { "talkSuggestMs", "Talk window: suggestions stay this long (ms)", { 60000, 120000, 300000 } }, -- 0.8.3
    { "talkAskBack", "They ask you things back: 0 never, 1 rarely, 2 sometimes, 3 often", { 0, 1, 2, 3 } }, -- 0.8.3
    { "askWaitSec", "When they ask you something, how long they wait for an answer (seconds)", { 15, 30, 60 } }, -- 0.8.3
    { "askNudge", "If you don't answer, they say something about it" }, -- 0.8.3
    { "aiRows", "AI on: rows you pick in A-Life's talk window get answered by the AI (rows that do something stay A-Life's)" }, -- 0.8.3
    { "stockState", "A-Life's own answers: asked how they are, they talk about what's really going on (grief, a bite, hunger)" }, -- 0.8.3
    { "talkLength", "How much they say: 1 short, 2 normal, 3 chatty", { 1, 2, 3 } }, -- 0.8.3
    { "thinkBeatMs", "While they think of an answer, their ... shows again every (ms; 0 = once)", { 0, 2000, 3000, 5000 } }, -- 0.8.3
    { "replyPace", "A very fast answer waits a moment, like a person would" }, -- 0.8.3
    { "talkRemember", "They remember how your last talk went and may bring it back up" }, -- 0.8.3
    { "rememberDays", "They remember your last talk for (game days)", { 1, 3, 7, 14, 30 } }, -- 0.8.3
    { "talkGestures", "The AI picks their body language for a line (off: A-Life guesses from the words)" }, -- 0.8.3
    { "talkApproach", "People come over to talk to you when they have a real reason" }, -- 0.8.3
    { "approachGapH", "Someone comes over at most every (game hours)", { 0.5, 1, 1.5, 3, 6 } }, -- 0.8.3
    { "approachPerNpcH", "The same person comes over at most every (game hours)", { 6, 12, 24, 48 } }, -- 0.8.3
    { "approachTiles", "How far away someone may be to come over (tiles)", { 10, 20, 30 } }, -- 0.8.3
    { "talkGroup", "Group talk: others who chime in become part of your talk (and show in the talk window)" }, -- 0.8.3
    { "groupChime", "Group talk: when you talk to all of them, chance someone else chimes in (%)", { 50, 75, 90, 100 } }, -- 0.8.3
    { "baseRepair", "Base members: on load, re-register anyone A-Life lost as living at your base" }, -- 0.5.2.9
    { "jeemAware", "Base members: show when Jeem's People list doesn't know them (+ console note)" }, -- 0.5.2.9
    { "jeemBase", "Camp: a base made with Jeem's Bases tool counts as your base" }, -- 0.5.11
    { "radialMenu", "Right-click: one \"A-Life\" entry that opens the radial menu (off = the old long menu)" }, -- 0.5.11
    { "radialPad", "Controller: D-pad up opens the A-Life radial when there's no vehicle or animal (not with Smart Radial Menu)" }, -- 0.5.11
    { "partyWordsStrict", "Party: \"go home\" / \"back to base\" only as an order (not \"let's go back to base\")" }, -- 0.5.2.9
    { "sharedPast", "Couples share their past: how / when they met, the kids, the late partner (Overview + AI)" }, -- 0.5.2.10
    { "biteCore", "Bites: shown in INJURIES + a red Bitten pill; the bitten fear it, the AI never forgets it" }, -- 0.5.2.10
    { "biteSpread", "Bites: they confide (partner first) and the news spreads; each reacts by tie and personality" }, -- 0.5.2.10
    { "uiWeb", "Relationships: a Web tab (their people around their full body; click = their talks)" }, -- 0.5.2.10
    { "npcDialog", "Interactions: also what they said to other people (heard by you or told to you)" }, -- 0.5.2.10
}
if type(M.settingRows) == "table" then
    local have = {}
    for _, r in ipairs(M.settingRows) do have[r[1]] = true end
    for _, r in ipairs(newRows) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
    if type(ALifeTalkSettings) == "table" and tonumber(ALifeTalkSettings.PER_COL) then
        ALifeTalkSettings.PER_COL = math.max(ALifeTalkSettings.PER_COL, math.ceil(#M.settingRows / 3))
    end
end

local W = ALifeTalkRelationWindow or {} -- no UI (server): methods land on a dummy table
local T, S = M.Theme, M.UIStyle
function M.bondUIInstall()
    if ALifeTalkRelationWindow == nil or W._bondUI or T == nil or S == nil then return end
    W._bondUI = true
    W.TABS[#W.TABS + 1] = "Bond"
    W.TAB.bond = #W.TABS
    if (W.SMALL_W or 620) < 700 then W.SMALL_W = 700 end -- six tabs need the room
    local baseNew, baseCreate, baseShow, baseRefresh, basePre = W.new, W.createChildren, W.showTab, W.refresh, W.prerender
    function W:new(uid)
        local o = baseNew(self, uid)
        if o and (o.width or 0) < W.SMALL_W then o.width = W.SMALL_W end
        return o
    end
    function W:createChildren()
        baseCreate(self)
        -- 0.5.2.5 [pt252u]: base createChildren ends in the wide Personality page (1000 x 620), so sizes taken from
        -- self.width / self.height here were the PAGE's: the buttons and the timeline ran ~300 px past the small
        -- window and the list hung below it. Children are made at 0,0 and placed by fitLayout from the small size.
        local fh = T.fontH()
        self.bondY = self:contentTop() + 124
        self.bondBtns = {
            ask = T.button(self, 0, 0, 100, 24, ALifeTr("IGUI_ALCP_Btn_Ask_to_be_friends", "Ask to be friends"), self, W.onBondAsk, S.green),
            together = T.button(self, 0, 0, 100, 24, ALifeTr("IGUI_ALCP_Btn_Ask_to_be_together", "Ask to be together"), self, W.onBondTogether, S.accent),
            step = T.button(self, 0, 0, 100, 24, ALifeTr("IGUI_ALCP_Btn_Step_back", "Step back"), self, W.onBondStep, S.amber),
            sorry = T.button(self, 0, 0, 100, 24, ALifeTr("IGUI_ALCP_Btn_Apologize", "Apologize"), self, W.onBondSorry, S.blue),
        }
        -- 0.5.1.8: a settler: "Come with me" / "Go back to base" (next to the where / right-now line)
        self.bondBtns.base = T.button(self, 0, 0, 150, fh + 4, ALifeTr("IGUI_ALCP_Btn_Come_with_me", "Come with me"), self, W.onBondBase, S.green)
        self.histList = T.list(self, self.cx or 176, 0, 100, 60, math.max(22, fh + 6), W.drawHist)
        self:fitLayout(true)
        self:bondRefresh()
        self:bondVisible(self.activeTab == W.TAB.bond)
    end
    function W:bondVisible(on)
        if self.histList then self.histList:setVisible(on) end
        for k, b in pairs(self.bondBtns or {}) do b:setVisible(on and (k ~= "base" or (self.bondView ~= nil and self.bondView.baseBtn ~= nil))) end
    end
    function W:showTab(i)
        baseShow(self, i)
        self:fitLayout(true) -- 0.5.2.5: after setPageMode put the small size back
        self:bondVisible(i == W.TAB.bond)
        if i == W.TAB.bond then
            self:bondRefresh()
            if M.thoughtRefresh then pcall(M.thoughtRefresh, self.uid, ALifeSide.you()) end
        end
    end
    function W:refresh()
        baseRefresh(self)
        if self.histList then pcall(function() self:bondRefresh() end) end
    end
    function W:prerender()
        -- 0.5.2.5: font / screen / UI-scale changed -> lay out again (cached key). 0.5.2.7 [pt255u]: the key is only
        -- looked at every 500 ms (not every frame) - the layout itself runs only when it changed
        local now = T.now()
        if M.settings.uiFixedSize == false or now - (self._fitCheckAt or 0) >= 500 or self.lay == nil then
            self._fitCheckAt = now
            pcall(function() self:fitLayout(false) end)
        end
        basePre(self)
        if not self.pageMode and self.activeTab == W.TAB.bond and self.bondView then pcall(function() self:drawBond() end) end
    end
end

----------------------------------------------------------------------------------------------------------------
-- 0.5.2.5 [pt252u]: one layout pass for the whole Relationships window, from the window's real size and the
-- real font metrics (UI font size / scale). Nothing is placed past the window's inner edge: tabs shrink (or cut
-- their titles), the Bond buttons go 4 / 2 / 1 per row, lists get the height that is left, the window grows for
-- big fonts but never past the screen, and it is moved back onto the screen. Runs at create, on every tab change
-- (after the page / small switch) and again from prerender only when font, screen or size changed (cached key).
----------------------------------------------------------------------------------------------------------------
local ASK_TITLES = { "Ask to be close friends", "Ask to be best friends", "Ask to be together", "Step back", "Apologize" }
W.FIXED = { fw = 0.46, fh = 0.52, minW = 1000, minH = 620, maxW = 1400, maxH = 900, margin = 20 } -- 0.5.2.7
local function screenWH()
    local sw, sh = 1920, 1080
    pcall(function() sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight() end)
    return tonumber(sw) or 1920, tonumber(sh) or 1080
end
function W:fitCompute()
    local fh, fhT = T.fontH(), T.fontH(S.fontTitle)
    local sw, sh = screenWH()
    local top = self:contentTop()
    local L = { fh = fh, fhT = fhT, sw = sw, sh = sh }
    L.role = top - 2 + math.max(22, fhT + 2)
    L.bar = L.role + math.max(22, fh + 6)
    L.badge = L.bar + math.max(20, fhT)
    L.badgeH = fh + 4
    L.tabH = math.max(22, fh + 6)
    L.tabY = L.badge + math.max(22, L.badgeH) + 8
    L.y0 = L.tabY + L.tabH + 10
    L.btnH = math.max(26, fh + 10)
    L.itemH = math.max(22, fh + 6)
    L.item2H = math.max(36, fh * 2 + 6)
    L.bottom = L.btnH + 20 -- bottom bar band
    local cx = self.cx or 176
    -- tabs: natural width
    local n, sumT = #W.TABS, 0
    for _, name in ipairs(W.TABS) do sumT = sumT + T.textW(name) end
    L.tabsNat = sumT + n * 24 + (n - 1) * 4
    L.tabsMin = sumT + n * 10 + (n - 1) * 4
    -- small-mode size: grow for big fonts, never past the screen
    local longest = 0
    for _, t in ipairs(ASK_TITLES) do longest = math.max(longest, T.textW(t) + 16) end
    local wantW = math.max(W.SMALL_W or 700, cx + L.tabsNat + 12)
    -- the four Bond buttons in one row when that keeps the window under ~70 % of the screen; else they wrap
    local fourW = cx + 4 * longest + 12 + 12
    if fourW <= math.floor(sw * 0.7) then wantW = math.max(wantW, fourW) end
    local smallW = math.max(math.min(wantW, sw - 20), math.min(W.SMALL_W or 700, sw - 20))
    local w = smallW - cx - 12
    local cols = 4
    while cols > 1 and math.floor((w - 4 * (cols - 1)) / cols) < longest do cols = (cols == 4) and 2 or 1 end
    L.cols, L.rows = cols, math.ceil(4 / cols)
    L.bw = math.floor((w - 4 * (cols - 1)) / cols)
    local b = {}
    b.pill = 0
    b.hint = math.max(fh + 4, L.badgeH) + 4
    b.now = b.hint + fh + 4
    b.thought = b.now + math.max(fh + 4, fh + 4)
    b.likes = b.thought + fh * 2 + 6
    b.extra = b.likes + fh * 2 + 4
    b.btn = b.extra + fh + 6
    b.msg = b.btn + L.rows * (L.btnH + 4) + 2
    b.list = b.msg + fh + 6
    local bf = nil
    if M.settings.uiFancy ~= false then -- 0.5.2.7 [pt255u]: tier ladder, quote card, likes / dislikes as pill rows
        local b0 = b
        b = {}
        for k, v in pairs(b0) do b[k] = v end
        bf, b = b, b0
        local b = bf
        b.ladder = math.max(fh + 4, L.badgeH) + 6
        b.hint = b.ladder + fh + 4 + 6
        b.now = b.hint + fh + 4
        b.thought = b.now + fh + 6
        b.likes = b.thought + fh * 2 + 10 + 8
        b.extra = b.likes + (fh + 6) * 2 + 4
        b.btn = b.extra + fh + 8
        b.msg = b.btn + L.rows * (L.btnH + 4) + 2
        b.list = b.msg + fh + 6
    end
    L.b = b
    local wantH = math.max(W.SMALL_H or 520, L.y0 + (bf or b).list + 3 * L.itemH + L.bottom + 4,
        (self.portraitY or top) + (self.portraitH or 270) + 8 + fh * 4 + L.bottom)
    L.smallW, L.smallH = smallW, math.max(math.min(wantH, sh - 20), math.min(W.SMALL_H or 520, sh - 20))
    -- 0.5.2.7 [pt255u]: ONE size for every tab (Personality too), from the screen: ~46 % x 52 %, at least the page
    -- (1000 x 620) and what the fonts need, at most 1400 x 900, never past the screen. No size jump between tabs.
    if M.settings.uiFixedSize ~= false then
        local F = W.FIXED
        local fw = math.max(F.minW, math.min(F.maxW, math.floor(sw * F.fw)))
        local fhh = math.max(F.minH, math.min(F.maxH, math.floor(sh * F.fh)))
        fw = math.min(math.max(fw, wantW), sw - F.margin)
        fhh = math.min(math.max(fhh, wantH), sh - F.margin)
        L.smallW, L.smallH, L.fixed = math.max(200, fw), math.max(200, fhh), true
    end
    -- pre-1.0: your own size (corner drag) wins, and is remembered
    if self.rsKey then
        local pw, ph = self:savedSize(nil, nil)
        if pw and ph then L.smallW = math.max(self.minW or 700, math.min(pw, sw - 20)); L.smallH = math.max(self.minH or 520, math.min(ph, sh - 20)) end
    end
    -- the fancy Bond block (ladder row, quote card, pill rows) only when the timeline still gets 3 rows; else compact
    if bf and L.y0 + bf.list + 3 * L.itemH + L.bottom + 4 <= L.smallH then L.b = bf end
    return L
end
function W:fitLayout(force)
    local fh = T.fontH()
    local sw, sh = screenWH()
    local key = table.concat({ fh, T.fontH(S.fontTitle), T.textW("Interactions"), sw, sh, tostring(self.pageMode == true),
        tostring(self.width), tostring(self.height), tostring(self.activeTab) }, ":")
    if not force and key == self._fitKey then return self.lay end
    local L = self:fitCompute()
    self.lay = L
    local cx = self.cx or 176
    self.layoutCount = (self.layoutCount or 0) + 1 -- 0.5.2.7: tests check this does not grow per frame
    if not self.pageMode or L.fixed then
        if self.width ~= L.smallW then self:setWidth(L.smallW) end
        if self.height ~= L.smallH then self:setHeight(L.smallH) end
    end
    local W_, H_ = self.width, self.height
    -- back onto the screen
    pcall(function()
        local x, y = self:getX(), self:getY()
        local nx = math.max(0, math.min(x, sw - W_))
        local ny = math.max(0, math.min(y, sh - H_))
        if nx ~= x then self:setX(nx) end
        if ny ~= y then self:setY(ny) end
    end)
    local hh = S.headerH
    if self.closeX then self.closeX:setX(W_ - hh + 3) end
    -- tabs: one row inside the window (narrower padding, then cut titles)
    local page = self.pageMode == true
    local tx0 = page and 24 or cx
    local ty = page and (self:contentTop() - 2) or L.tabY
    local avail = W_ - tx0 - 12
    local btns = self.tabButtons or {}
    local n = #btns
    if n > 0 then
        local sumT = 0
        for i, bt in ipairs(btns) do bt.fullTitle = bt.fullTitle or bt.title or W.TABS[i]; sumT = sumT + T.textW(bt.fullTitle) end
        local pad = 24
        if sumT + n * pad + (n - 1) * 4 > avail then pad = math.floor((avail - (n - 1) * 4 - sumT) / n) end
        local x = tx0
        for i, bt in ipairs(btns) do
            local bw
            if pad >= 8 then bw = T.textW(bt.fullTitle) + pad; bt:setTitle(bt.fullTitle)
            else bw = math.floor((avail - (n - 1) * 4) / n); bt:setTitle(T.fit(bt.fullTitle, bw - 6)) end
            bt:setX(x); bt:setY(ty); bt:setWidth(bw); bt:setHeight(L.tabH)
            x = x + bw + 4
        end
    end
    -- bottom bar: Close (right), Favorite (left of it), radio (content x); all inside
    local by = H_ - L.btnH - 10
    local closeW = math.max(80, T.textW("Close") + 24)
    local closeXp = W_ - 12 - closeW
    if self.closeBtn then self.closeBtn:setX(closeXp); self.closeBtn:setY(by); self.closeBtn:setWidth(closeW); self.closeBtn:setHeight(L.btnH) end
    local favW = math.max(120, T.textW("Unfavorite") + 24)
    self.favX, self.favW = closeXp - 6 - favW, favW
    if self.favBtn then self.favBtn:setX(self.favX); self.favBtn:setY(by); self.favBtn:setWidth(favW); self.favBtn:setHeight(L.btnH) end
    if self.radioBtn then
        local rw = math.max(170, T.textW("End radio call") + 24)
        rw = math.max(60, math.min(rw, self.favX - 6 - cx))
        self.radioBtn:setX(cx); self.radioBtn:setY(by); self.radioBtn:setWidth(rw); self.radioBtn:setHeight(L.btnH)
    end
    -- small-mode content (also placed while the page is up, for the small size it will come back to)
    local sW = (page and not L.fixed) and L.smallW or W_
    local sH = (page and not L.fixed) and L.smallH or H_
    local w = sW - cx - 12
    L.cw = w
    local listY = L.y0 - 4
    local listH = math.max(L.itemH, sH - listY - L.bottom - 4)
    local function placeList(l, itemH)
        if l == nil then return end
        l:setX(cx); l:setY(listY); l:setWidth(w); l:setHeight(listH)
        l.itemheight = itemH
        if l.vscroll then pcall(function() l.vscroll:setX(w - (l.vscroll.width or 16)); l.vscroll:setHeight(listH) end) end
    end
    placeList(self.memList, L.item2H)
    placeList(self.tieList, math.max(30, fh + 14))
    placeList(self.intList, L.item2H)
    self.bondY = L.y0
    if self.bondBtns then
        local order = { "ask", "together", "step", "sorry" }
        for i, k in ipairs(order) do
            local bt = self.bondBtns[k]
            if bt then
                local col, row = (i - 1) % L.cols, math.floor((i - 1) / L.cols)
                bt:setX(cx + col * (L.bw + 4)); bt:setY(L.y0 + L.b.btn + row * (L.btnH + 4))
                bt:setWidth(L.bw); bt:setHeight(L.btnH)
            end
        end
        local bb = self.bondBtns.base
        if bb then
            local bw = math.min(math.max(150, T.textW("Go back to base") + 24), math.floor(w / 2))
            bb:setX(cx + w - bw); bb:setY(L.y0 + L.b.now - 2); bb:setWidth(bw); bb:setHeight(fh + 4)
            L.baseW = bw
        end
    end
    if self.histList then
        local ly = L.y0 + L.b.list
        local lh = sH - ly - L.bottom - 4
        if lh < L.itemH then lh = math.max(8, lh) end
        self.histList:setX(cx); self.histList:setY(ly); self.histList:setWidth(w); self.histList:setHeight(math.max(8, lh))
        self.histList.itemheight = L.itemH
        if self.histList.vscroll then pcall(function() self.histList.vscroll:setX(w - (self.histList.vscroll.width or 16)); self.histList.vscroll:setHeight(math.max(8, lh)) end) end
    end
    self._fitKey = table.concat({ fh, T.fontH(S.fontTitle), T.textW("Interactions"), sw, sh, tostring(self.pageMode == true),
        tostring(self.width), tostring(self.height), tostring(self.activeTab) }, ":")
    if self.ovBuild and self.data then pcall(function() self:ovBuild() end) end -- 0.5.2.7: Overview rows for the new width
    return L
end

-- 0.5.2.7 [pt255u]: every child's rect + the body / bottom bar bands, for tests and the debug dump
-- (M.layoutDumpText(win) gives it as text, e.g. from the debug Lua console). Read only; no layout runs here.
function W:layoutDump()
    local L = self.lay or {}
    local out = { w = self.width, h = self.height, tab = self.activeTab, page = self.pageMode == true,
        bodyTop = L.y0, barY = self.height - (L.bottom or 46), layouts = self.layoutCount or 0, kids = {} }
    local function add(name, c)
        if c == nil then return end
        local vis = true
        pcall(function() if c.isVisible then vis = c:isVisible() ~= false end end)
        if c.visible == false then vis = false end
        out.kids[#out.kids + 1] = { name = name, x = c.x or 0, y = c.y or 0, w = c.width or 0, h = c.height or 0, vis = vis,
            bar = (name == "closeBtn" or name == "favBtn" or name == "radioBtn") }
    end
    for i, b in ipairs(self.tabButtons or {}) do add("tab" .. i, b) end
    add("closeBtn", self.closeBtn); add("favBtn", self.favBtn); add("radioBtn", self.radioBtn)
    add("memList", self.memList); add("tieList", self.tieList); add("intList", self.intList); add("histList", self.histList)
    for _, k in ipairs({ "ask", "together", "step", "sorry", "base" }) do add("bond_" .. k, (self.bondBtns or {})[k]) end
    if self.ovLines then
        local top, vh = self:ovView()
        out.ov = { top = top, view = vh, total = self.ovTotal or 0, scroll = self.ovScroll or 0, rows = #self.ovLines }
    end
    return out
end
function M.layoutDumpText(win)
    win = win or M.relationWindow
    if win == nil or win.layoutDump == nil then return "no Relationships window" end
    local d = win:layoutDump()
    local t = { "window " .. tostring(d.w) .. "x" .. tostring(d.h) .. " tab=" .. tostring(d.tab) .. " page=" .. tostring(d.page)
        .. " body=" .. tostring(d.bodyTop) .. ".." .. tostring(d.barY) .. " layouts=" .. tostring(d.layouts) }
    for _, k in ipairs(d.kids) do
        t[#t + 1] = string.format("  %-12s %5d %5d %5d %5d %s", k.name, k.x, k.y, k.w, k.h, k.vis and "shown" or "hidden")
    end
    return table.concat(t, "\n")
end

-- data for the tab (also used by tests): all from the people book
function M.bondView(uid, player)
    uid = tostring(uid)
    player = player or ALifeSide.you()
    local v = { uid = uid }
    v.tier = M.bondTier and M.bondTier(uid) or 1
    v.tierWord = M.tierWord and M.tierWord(v.tier) or "acquaintance"
    v.standing = M.bondStanding and M.bondStanding(uid, player) or 0
    v.state = M.bondAskState and M.bondAskState(uid, player) or {}
    v.history = M.histRows and M.histRows(uid) or {}
    v.thought = M.settings.bondThought ~= false and M.thoughtOf and select(1, M.thoughtOf(uid)) or nil
    -- 0.5.2.5 [pt252u]: the bond tier vs their opinion, said in words (they are separate on purpose)
    local op = M.bondStanding and select(2, M.bondStanding(uid, player)) or nil
    local ops = ((tonumber(op) or 0) > 0 and "+" or "") .. tostring(math.floor(tonumber(op) or 0))
    if v.state and v.state.ask and v.state.ask.want then
        v.hint = "Bond is separate from opinion (" .. ops .. "): ask to be " .. M.tierWord(v.state.ask.want) .. "s at standing " .. tostring(v.state.ask.need or "?") .. "."
    else v.hint = "Bond is separate from opinion (" .. ops .. ")." end
    if M.settings.bondLikes ~= false and M.likesOf and bucket("book")[uid] ~= nil then pcall(M.likesOf, uid, true) end
    v.likes = M.settings.bondLikes ~= false and M.likesShown and M.likesShown(uid) or nil
    local g = M.grudgeOf and M.settings.grudges ~= false and M.grudgeOf(uid) or nil
    if g then v.grudge = M.grudgeWord(g) .. " - " .. tostring(g.why) .. " (" .. tostring(M.grudgeWords[g.style] or g.style) .. ")" end
    local cw, cl = nil, nil
    if M.changeWord then cw, cl = M.changeWord(uid) end
    if cw then v.change = cl end
    local line = M.activityLine and M.activityLine(uid) or nil
    -- 0.5.1.8: where they live / travel ("At base" / "Travelling with you") + the base button state
    if M.baseWhere then
        local wh, extra = M.baseWhere(uid, player)
        if wh then v.where = wh .. (extra and (" (" .. extra .. ")") or "") end
        v.baseBtn = M.baseAskState and M.baseAskState(uid, player) or nil
    end
    if line then v.now = "Right now: " .. line
    else
        local e = bucket("book")[uid]
        local fs = bucket("finalState")[uid]
        if type(e) == "table" and e.dead then v.now = "Gone."
        elseif type(fs) == "table" and fs.activity then v.now = "Last seen " .. tostring(fs.activity)
        elseif listenerOf(uid) == nil then v.now = "Away - not around right now" end
    end
    if v.where then v.now = v.where .. (v.now and (" - " .. v.now) or "") end
    return v
end

function W:bondRefresh()
    if self.histList == nil then return end
    local v = M.bondView(self.uid, ALifeSide.you())
    self.bondView = v
    self.histList:clear()
    if M.settings.bondHistory == false then self.histList:addItem("off", { when = "", text = "Shared history is off in the settings.", kind = "" })
    elseif #v.history == 0 then self.histList:addItem("none", { when = "", text = "Nothing shared yet.", kind = "" }) end
    if M.settings.bondHistory ~= false then for i = #v.history, 1, -1 do self.histList:addItem(v.history[i].text, v.history[i]) end end
    local st = v.state or {}
    local function set(b, s, title, fallbackHint)
        if b == nil then return end
        if s == nil then b.enable = false; b:setTitle(title); b:setTooltip(fallbackHint); b.bondTip = fallbackHint; return end
        b:setTitle(s.label or title)
        b.enable = s.enabled == true
        b:setTooltip(tostring(s.hint or "")); b.bondTip = tostring(s.hint or "")
    end
    local off = M.settings.bondTiers == false and "Bond tiers are off in the settings." or nil
    set(self.bondBtns.ask, not off and st.ask or nil, "Ask to be friends", off or (v.tier >= 4 and "You're already best friends." or "Not now."))
    set(self.bondBtns.together, not off and st.together or nil, "Ask to be together", off or (v.tier >= 5 and "You're together." or "Not now."))
    set(self.bondBtns.step, not off and st.stepBack or nil, "Step back", off or "Nothing to step back from.")
    set(self.bondBtns.sorry, st.apologize, "Apologize", "Not now.")
    if self.bondBtns.base then -- 0.5.1.8
        set(self.bondBtns.base, v.baseBtn, "Come with me", "Only for people who live at your base.")
        self.bondBtns.base:setVisible(v.baseBtn ~= nil and self.activeTab == W.TAB.bond and not self.pageMode)
    end
end

function W.drawHist(list, y, item, alt)
    local r = item.item
    T.rowBack(list, y, item, alt)
    local c = ({ betray = S.red, fight = S.red, grudge = S.red, death = S.dim, save = S.green, gift = S.green, heal = S.green, tier = S.accent,
        apology = S.blue, change = S.amber, likes = S.blue, danger = S.amber, party = S.blue })[r.kind or ""] or S.text
    -- 0.5.2.5: the date column is as wide as "Dec 30, 23:59" in the real font; text cut to what is left
    local dw = T.textW("Dec 30, 23:59") + 16
    local lw = list:getWidth() - 20 -- scroll bar
    list:drawText(T.fit(tostring(r.when or ""), math.min(dw, lw) - 8), 8, y + 3, S.dim.r, S.dim.g, S.dim.b, 1, S.font)
    if lw - dw > 20 then list:drawText(T.fit(tostring(r.text or ""), lw - dw - 4), dw + 4, y + 3, c.r, c.g, c.b, 1, S.font) end
    return y + list.itemheight
end

local function wrapText(s, maxW, maxLines)
    local lines, cur = {}, ""
    for word in string.gmatch(tostring(s or ""), "%S+") do
        local t = cur == "" and word or (cur .. " " .. word)
        if T.textW(t) > maxW and cur ~= "" then lines[#lines + 1] = cur; cur = word else cur = t end
        if #lines >= maxLines then break end
    end
    if cur ~= "" and #lines < maxLines then lines[#lines + 1] = cur end
    return lines
end

function W:drawBond()
    local v = self.bondView
    local a = self.fade or 1
    local L = self.lay or self:fitLayout(true)
    local x, w = self.cx, self.width - self.cx - 12
    local y0 = L.y0
    local fh = T.fontH()
    local B = L.b
    -- tier + standing. 0.5.2.5 [pt252u]: the pill is the BOND tier (built over time, changes only when you ask /
    -- step back), labelled as such, next to "standing toward the next tier"; the header badges are their opinion
    -- of you right now - the hint line says so, so "Bond: acquaintances" next to "friendly" / +22 reads right.
    local tc = v.tier >= 4 and S.green or (v.tier >= 2 and S.accent or S.dim)
    if M.settings.bondTiers ~= false then
        local pill = "Bond: " .. (v.tier == 1 and "acquaintances" or (v.tierWord .. "s"))
        local tw = T.badge(self, x, y0 - 2, T.fit(pill, math.floor(w / 2)), tc, a)
        local need = v.state and v.state.ask and v.state.ask.need or nil
        local num = tostring(v.standing) .. (need and (" / " .. tostring(need)) or "")
        local lab = "Standing"
        local nw = T.textW(num)
        local bx = x + tw + 12 + T.textW(lab) + 8
        local barW = w - (bx - x) - nw - 10
        if barW >= 30 then
            self:drawText(lab, x + tw + 12, y0, S.dim.r, S.dim.g, S.dim.b, a, S.font)
            T.relBar(self, bx, y0 + math.floor(fh / 2) - 2, barW, 8, v.standing * 2 - 100, a)
        end
        self:drawTextRight(num, x + w, y0, tc.r, tc.g, tc.b, a, S.font)
        if v.hint then self:drawText(T.fit(v.hint, w), x, y0 + B.hint, S.dim.r, S.dim.g, S.dim.b, a * 0.9, S.font) end
    end
    if v.now then
        local maxW = (v.baseBtn and L.baseW) and (w - L.baseW - 8) or w -- 0.5.1.8: room for the base button
        self:drawText(T.fit(v.now, maxW), x, y0 + B.now, S.blue.r, S.blue.g, S.blue.b, a, S.font)
    end
    if v.thought then
        local lines = wrapText("\"" .. v.thought .. "\"", w, 2)
        for i, ln in ipairs(lines) do self:drawText(T.fit(ln, w), x, y0 + B.thought + (i - 1) * fh, S.text.r, S.text.g, S.text.b, a, S.font) end
    end
    if v.likes then
        local function join(list)
            local out = {}
            for _, it in ipairs(list) do out[#out + 1] = it.label end
            return #out > 0 and table.concat(out, ", ") or "???"
        end
        self:drawText(T.fit("Likes: " .. join(v.likes.likes), w), x, y0 + B.likes, S.green.r, S.green.g, S.green.b, a, S.font)
        self:drawText(T.fit("Can't stand: " .. join(v.likes.dislikes), w), x, y0 + B.likes + fh, S.red.r, S.red.g, S.red.b, a, S.font)
    end
    local extra = {}
    if v.grudge then extra[#extra + 1] = { "Grudge: " .. v.grudge, S.red } end
    if v.change then extra[#extra + 1] = { "Changed: " .. v.change, S.amber } end
    if #extra > 0 then
        local s = extra[1][1]
        if #extra > 1 then s = s .. "   |   " .. extra[2][1] end
        self:drawText(T.fit(s, w), x, y0 + B.extra, extra[1][2].r, extra[1][2].g, extra[1][2].b, a, S.font)
    end
    -- the last answer (buttons): its own line between the buttons and the timeline
    if self.bondMsg and T.now() - (self.bondMsgAt or 0) < 15000 then
        self:drawText(T.fit(self.bondMsg, w), x, y0 + B.msg, S.amber.r, S.amber.g, S.amber.b, a, S.font)
    end
end

-- the buttons (the result is decided here; the NPC says it out loud when they're here)
local function after(win, msg)
    win.bondMsg, win.bondMsgAt = msg, T.now()
    win:bondRefresh()
end
function W:onBondAsk()
    local st = M.bondAskState(self.uid, ALifeSide.you())
    if st.ask == nil or not st.ask.enabled then return end
    local r = M.bondDecide(self.uid, st.ask.want, ALifeSide.you())
    local p = { kind = "ask", want = M.tierWord(st.ask.want), ok = r.ok, why = r.why, awkward = r.awkward, already = r.already }
    M.bondVoice(self.uid, p, ALifeSide.you())
    after(self, r.ok and ("They said yes: " .. r.why .. ".") or ("Not yet: " .. r.why .. "."))
end
function W:onBondTogether()
    local st = M.bondAskState(self.uid, ALifeSide.you())
    if st.together == nil or not st.together.enabled or not M.romanceAsk then return end
    local ok, why = M.romanceAsk(self.uid, ALifeSide.you())
    local p = { kind = "ask", want = "partner", ok = ok, why = why or (ok and "you feel the same" or "not ready") }
    M.bondVoice(self.uid, p, ALifeSide.you())
    after(self, ok and "They said yes." or ("Not yet: " .. tostring(why) .. "."))
end
function W:onBondStep()
    local r = M.bondStepBack(self.uid, ALifeSide.you())
    if r == nil or not r.changed then return end
    M.bondVoice(self.uid, { kind = "step", react = r.react, from = M.tierWord(r.from), to = M.tierWord(r.to) }, ALifeSide.you())
    after(self, "You stepped back to " .. M.tierWord(r.to) .. "s. They " .. ({ hurt = "were hurt.", stung = "were stung.", shrugs = "shrugged it off.", accepts = "accepted it." })[r.react])
end
function W:onBondSorry()
    -- 0.5.2.7 [pt255u] "the apologize thing doesnt work": a dimmed button explains itself; every press that does
    -- something is answered out loud (LLM when they're here, a radio line on the radio) and in the tab
    local b = self.bondBtns and self.bondBtns.sorry
    if M.settings.fixApology ~= false and b and b.enable == false then after(self, tostring(b.bondTip or "Not now.")); return end
    local r = M.bondApologize(self.uid, ALifeSide.you())
    if r == nil then return end
    if r.nothing then
        if M.settings.fixApology ~= false then M.bondVoice(self.uid, { kind = "apology", nothing = true, ok = true, why = r.why }, ALifeSide.you()) end
        after(self, "They don't think you owe them an apology."); return
    end
    if r.cooldown then
        if M.settings.fixApology ~= false then M.bondVoice(self.uid, { kind = "apology", cooldown = true, why = r.why }, ALifeSide.you()) end
        after(self, "You already apologized - give it time."); return
    end
    M.bondVoice(self.uid, { kind = "apology", ok = r.ok, why = r.why }, ALifeSide.you())
    local dtxt = r.d and r.d ~= 0 and ("  (opinion +" .. tostring(r.d) .. ")") or ""
    after(self, (r.ok and ("Apology accepted: " .. r.why .. ".") or ("Not accepted: " .. r.why .. ".")) .. dtxt)
    self.bondMsgOk = r.ok
end

function W:onBondBase() -- 0.5.1.8
    if M.baseButton == nil then return end
    local was = M.settlerAway and M.settlerAway(self.uid)
    local ok, why = M.baseButton(self.uid, ALifeSide.you())
    if was then after(self, ok and "Sent home - they're heading back to the base." or ("Couldn't: " .. tostring(why) .. "."))
    else after(self, ok and ("They're coming with you: " .. tostring(why) .. ".") or ("They'd rather stay: " .. tostring(why) .. ".")) end
end

M.bondUIInstall()
