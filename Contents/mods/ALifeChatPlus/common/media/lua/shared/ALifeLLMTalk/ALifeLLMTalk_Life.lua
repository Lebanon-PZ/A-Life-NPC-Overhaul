-- A-Life Talk 0.5.1: LIFE & TOPICS: real-people talk (life before, music, TV, family, food, jokes, theories, gossip, hot takes...) mixed with grounded survival talk
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Life") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Life"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Life") end end -- 0.5.1.6 perf label
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
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
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
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.cur == nil then -- pre-1.0 MP: first player with people near
        for _, p in ipairs(ALifeSide.online()) do
            local x, y, z = pos(p)
            local list = M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}
            if #list > 0 then return list, p end
        end
        return {}, nil
    end
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Life", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = true, nil
        if type(ALifeSide) == "table" and ALifeSide.mpServer() then -- pre-1.0 MP: once per online player
            M.eachPlayer(function() local ok2, e2 = pcall(f, now); if not ok2 then ok, e = ok2, e2 end end)
        else ok, e = pcall(f, now) end
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("lifeTopics", true)
M.lifeCfg = { recentTopics = 8, pairRecent = 6, callbackMinH = 2, callbackChance = 40, logKeep = 30, pairTopicMs = 90000 }
-- one consistent personal history per NPC (uid-seeded; 1993 Kentucky), revealed a bit at a time
M.lifePools = {
    hometown = { "Louisville", "Lexington", "Bowling Green", "Elizabethtown", "Frankfort", "Paducah", "Muldraugh", "West Point",
        "a farm outside Ekron", "Indianapolis", "Cincinnati", "Nashville", "Memphis", "Chicago", "Detroit", "Columbus", "Evansville",
        "a trailer park in Brandenburg", "Owensboro", "Knoxville", "Atlanta", "a little town in West Virginia" },
    music = { "Garth Brooks", "Nirvana", "Pearl Jam", "Dr. Dre", "Whitney Houston", "Metallica", "Reba McEntire", "R.E.M.",
        "Guns N' Roses", "Mariah Carey", "Alan Jackson", "Johnny Cash", "Prince", "Bon Jovi", "Tupac", "Def Leppard",
        "Patsy Cline", "the Smashing Pumpkins", "Boyz II Men", "Lynyrd Skynyrd", "Aretha Franklin", "Bruce Springsteen" },
    show = { "Seinfeld", "Cheers", "Twin Peaks", "Home Improvement", "The Simpsons", "Star Trek: The Next Generation",
        "Married... with Children", "Roseanne", "Jurassic Park (saw it twice in June)", "Terminator 2", "Groundhog Day",
        "Unforgiven", "Wayne's World", "Days of Our Lives", "Unsolved Mysteries", "Northern Exposure", "The X-Files pilot",
        "Golden Girls reruns", "Jeopardy!", "Die Hard", "The Wonder Years", "Lonesome Dove" },
    sport = { "Kentucky Wildcats basketball", "the Louisville Cardinals", "the Cincinnati Reds", "the Chicago Bulls and Jordan",
        "the Kentucky Derby", "the Dallas Cowboys", "NASCAR at Bristol", "a Tuesday bowling league", "high school football",
        "the Atlanta Braves", "pro wrestling", "bass fishing tournaments", "nothing - sports bore them" },
    food = { "White Castle at 2 AM", "their mom's biscuits and gravy", "a bucket of KFC", "an ice-cold Coke", "delivery pizza",
        "fresh oranges", "Derby pie", "real coffee", "a hot fudge sundae", "a cheeseburger off the grill", "Hot Browns",
        "sweet tea with real ice", "their grandma's fried chicken", "Taco Bell", "a cold beer on a porch" },
    flame = { "a high-school sweetheart who married a dentist", "a divorce that got ugly over the house",
        "someone at the bowling alley they never had the guts to ask out", "an engagement called off a week before the wedding",
        "a summer fling in Myrtle Beach", "a marriage that was actually good - until all this", "a pen pal they never met",
        "an ex they still write letters to in their head" },
    regret = { "not calling their mother back that last Sunday", "dropping out of college", "a fight with their brother over money",
        "leaving the dog behind when they ran", "never learning to swim", "selling their dad's truck", "a job they turned down in Texas",
        "not saying goodbye to a friend", "being a coward once, when it mattered" },
    dream = { "opening a bar on Lake Cumberland", "seeing the ocean", "finishing the novel in their glovebox", "driving Route 66",
        "getting their kids back", "a little farm with goats", "learning to fly a plane", "playing guitar on a real stage",
        "just one quiet morning with coffee and no gun" },
    belief = { "a Baptist who still prays every night", "a lapsed Catholic who started praying again", "sure God left the building",
        "agnostic, but prays when it's bad", "believes everything happens for a reason", "an atheist and proud of it",
        "thinks this is the Revelation, chapter and verse", "believes in luck more than anything" },
    theory = { "the Army cooked it up at Fort Knox", "it came out of a lab in Louisville", "a meteor shower back in June",
        "something in the water supply", "bad meat from a packing plant", "the Russians did it", "it's Judgment Day, plain and simple",
        "the government knew weeks before", "a vaccine trial gone wrong", "nobody knows and that's the scary part" },
    hobby = { "fishing", "model trains", "crosswords", "guitar", "quilting", "deer hunting", "fixing up an old Camaro", "poker",
        "gardening", "comic books", "bird watching", "woodworking", "baking", "karaoke", "baseball cards" },
    story = { "getting stuck in a drive-thru behind a horse", "their uncle's fish that got bigger every Thanksgiving",
        "the time they locked themselves out of the house in a towel", "winning forty bucks on a scratch-off and losing it the same day",
        "a wedding where the cake fell over", "the night their car broke down outside Graceland",
        "a raccoon that lived in their attic for a year", "the worst first date in Kentucky history" },
    joke = { "Why don't zombies eat clowns? They taste funny.", "What's a zombie's favorite cereal? Rice Creepies.",
        "Knock knock. Who's there? Not your neighbors anymore.", "I'd tell you a joke about canned beans, but it's too long a story.",
        "At least nobody's asking me to do my taxes.", "Rule one: never be the slowest. Rule two: don't run with a friend who's faster." },
    hottake = { "pineapple on pizza", "whether Elvis is still alive", "Star Trek versus Star Wars", "Coke versus Pepsi", "ketchup on eggs",
        "whether Jordan is the best ever", "whether country music counts as real music", "cats versus dogs", "the moon landing",
        "toilet paper over or under", "whether a hot dog is a sandwich", "the right way to make chili" },
}
M.lifeFlameNames = { "Debbie", "Tammy", "Rhonda", "Kim", "Lisa", "Brenda", "Mike", "Darryl", "Travis", "Kevin", "Shawn", "Wade" }
function M.lifeFacts(uid)
    uid = tostring(uid)
    local f = {}
    for key, pool in pairs(M.lifePools) do f[key] = pick(pool, uid .. "#life#" .. key) end
    -- persona fills what it already knows (hobby from their quirk, place from their background)
    pcall(function()
        local row = M.personaOf and M.personaOf(uid) or nil
        local p = row and M.personaParts and M.personaParts(row) or nil
        if p then
            if type(p.quirk) == "string" and string.sub(p.quirk, 1, 5) == "into " then f.hobby = string.sub(p.quirk, 6) end
            if type(p.bg) == "table" and type(p.bg.label) == "string" then f.job = string.lower(p.bg.label) end
        end
    end)
    f.flameName = pick(M.lifeFlameNames, uid .. "#flame")
    return f
end
-- topics: kind = life / light / deep / survival / social; fact(uid, ctx) -> text or nil (nil = not available now)
local F = function(key, fmt) return function(uid) local f = M.lifeFacts(uid); return f[key] and string.gsub(fmt, "%%s", f[key]) or nil end end
M.topics = {
    hometown = { kind = "life", label = "where you grew up", fact = F("hometown", "you grew up in %s") },
    job = { kind = "life", label = "your old job / life before", fact = function(uid) local f = M.lifeFacts(uid); return f.job and ("before all this you were a " .. f.job) or nil end },
    music = { kind = "light", label = "music", fact = F("music", "you love %s") },
    show = { kind = "light", label = "movies and TV", fact = F("show", "you miss %s") },
    sport = { kind = "light", label = "sports", fact = F("sport", "you followed %s") },
    food = { kind = "light", label = "food you miss", fact = F("food", "you'd kill for %s") },
    hobby = { kind = "light", label = "a hobby", fact = F("hobby", "your hobby was %s") },
    story = { kind = "light", label = "a dumb story from before", fact = F("story", "the story: %s") },
    joke = { kind = "light", label = "a dumb joke", fact = F("joke", "a joke you like: \"%s\"") },
    hottake = { kind = "light", label = "a hot take / petty argument", fact = F("hottake", "you have strong opinions on %s"), argue = true },
    flame = { kind = "deep", label = "an old relationship", fact = function(uid) local f = M.lifeFacts(uid); return "you think about " .. f.flame .. " (" .. f.flameName .. ")" end },
    regret = { kind = "deep", label = "a regret", fact = F("regret", "you regret %s") },
    dream = { kind = "deep", label = "a dream for after", fact = F("dream", "you dream of %s") },
    faith = { kind = "deep", label = "faith, God, fate", fact = F("belief", "you are %s") },
    theory = { kind = "deep", label = "what caused the outbreak", fact = F("theory", "you think %s") },
    family = { kind = "deep", label = "family", fact = function(uid)
        local bits = M.storyBits and M.personaOf and M.storyBits(M.personaOf(uid)) or {}
        return type(bits[2]) == "string" and ("family / who you lost: " .. bits[2]) or "family you haven't heard from" end },
    -- grounded survival talk (only when the game state backs it)
    hunger = { kind = "survival", label = "food running low", fact = function(uid, ctx) return ctx.hungry and "you're hungry and the food is thin" or nil end },
    ammo = { kind = "survival", label = "ammo", fact = function(uid, ctx) return ctx.ammo and ("you have " .. ctx.ammo .. " rounds left") or nil end },
    wounds = { kind = "survival", label = "an injury", fact = function(uid, ctx) return ctx.wound and ("your " .. ctx.wound) or nil end },
    weather = { kind = "survival", label = "the weather", fact = function(uid, ctx) return ctx.weather end },
    losses = { kind = "survival", label = "someone you lost", fact = function(uid, ctx) return ctx.loss end },
    plans = { kind = "survival", label = "plans: where to go, what to do next", fact = function(uid, ctx) return ctx.town and ("we're near " .. ctx.town .. "; where next?") or "what to do next" end },
    moral = { kind = "deep", label = "a moral dilemma", fact = function(uid, ctx) return ctx.deed or "would you shoot a stranger to save a friend?" end },
    rumors = { kind = "social", label = "a rumor", fact = function(uid, ctx) return ctx.rumor end },
    gossip = { kind = "social", label = "gossip about another survivor", fact = function(uid, ctx) return ctx.gossip end },
    recent = { kind = "social", label = "something that happened recently", fact = function(uid, ctx) return ctx.recent end },
}
-- what the game says right now (cheap; everything guarded)
function M.lifeContext(l, partner)
    local uid = tostring(l.record.uid)
    local ctx = { uid = uid }
    pcall(function() local life = M.lifeOf and M.lifeOf(uid); ctx.hungry = life and (tonumber(life.hunger) or 0) >= 0.5 end)
    pcall(function()
        local inv = l.shell:getInventory()
        local n = 0
        for _, t in ipairs({ "Base.Bullets9mm", "Base.Bullets38", "Base.Bullets45", "Base.Bullets44", "Base.ShotgunShells", "Base.223Bullets", "Base.308Bullets", "Base.556Bullets" }) do
            n = n + (tonumber((inv:getCountTypeRecurse(t))) or 0)
        end
        if n > 0 then ctx.ammo = n end
    end)
    pcall(function() local s = M.woundState and M.woundState(uid, l.shell, l.record); local w = s and s.list and s.list[1]; if w then ctx.wound = tostring(w.label or "wound") .. " on the " .. tostring(w.part or "body") end end)
    pcall(function() local c = M.wxState and M.wxState.prev; if c then ctx.weather = math.floor(c.temp) .. " C" .. (c.rain > 0.3 and ", raining" or "") .. (c.snow > 0.2 and ", snowing" or "") .. (c.fog > 0.4 and ", foggy" or "") end end)
    pcall(function()
        for _, e in pairs(M.griefOf and M.griefOf(uid) or {}) do
            if type(e) == "table" and e.known ~= false and hours() - (tonumber(e.at) or 0) < 24 * 14 then ctx.loss = e.n .. " (" .. tostring(e.t) .. ")" .. (e.kn and (", killed by " .. tostring(e.kn)) or ""); break end
        end
        if ctx.loss == nil then
            local lo = M.lossesKnownBy and M.lossesKnownBy(uid) or {}
            if lo[1] then ctx.loss = lo[1].n .. ", taken by " .. lo[1].by .. (lo[1].where and (" near " .. lo[1].where) or "") end
        end
    end)
    pcall(function() local x, y = pos(l.shell); ctx.town = x and M.townAt and M.townAt(x, y) or nil end)
    pcall(function() local r = M.rumorsKnownBy and M.rumorsKnownBy(uid) or {}; if #r > 0 then ctx.rumor = "about the newcomer: " .. r[#r].text end end)
    pcall(function() local km = M.keyMemOf and M.keyMemOf(uid) or {}; local e = km[#km]; if e then ctx.recent = e.t end end)
    pcall(function()
        for _, t in ipairs(M.tiesOf and M.tiesOf(uid, nil, 6) or {}) do
            if not t.dead and (partner == nil or tostring(t.uid) ~= tostring(partner.record.uid)) then
                ctx.gossip = nameOf(rec(t.uid)) .. " (your " .. tostring(t.word or t.type) .. (t.why and ("; " .. t.why) or "") .. ")"; break
            end
        end
    end)
    pcall(function() local km = M.keyMemOf and M.keyMemOf(uid) or {}; for i = #km, 1, -1 do if km[i].k == "threat" or km[i].k == "death" or km[i].k == "leave" then ctx.deed = km[i].t; break end end end)
    -- danger / safety
    local P = patch()
    local x, y = pos(l.shell)
    ctx.zombies = (P and fn(P, "zombiesNear") and x) and (P.zombiesNear(x, y, 12) or 0) or 0
    ctx.danger = ctx.zombies >= 2 or (M.inCombat and M.inCombat(l.shell, l.record)) or false
    local a = M.activities and M.activities[uid]
    ctx.cozy = a ~= nil and (a.kind == "campfire" or a.kind == "sit" or a.kind == "eat" or a.kind == "cards" or a.kind == "chat" or a.kind == "drink" or a.kind == "smoke" or a.kind == "rest")
    pcall(function() local e = M.emoBehavior and M.emoBehavior(uid); if e then ctx.low, ctx.fear, ctx.up = e.low or 0, e.fear or 0, e.up or 0 end end)
    return ctx
end
local function recentList(map, key) local t = map[key]; if type(t) ~= "table" then t = {}; map[key] = t end; return t end
function M.topicWeights(uid, ctx, tie, score)
    local lens = M.lens and M.lens(uid) or {}
    local w = {}
    local base = { life = 10, light = 10, deep = 5, survival = 8, social = 6 }
    if ctx.danger then base = { life = 0, light = 0, deep = 0, survival = 30, social = 0 } -- terse talk in danger
    elseif ctx.cozy then base.light, base.life, base.deep, base.survival = 18, 14, 9, 4 end
    local close = (tonumber(score) or 0) >= 35 or tie == "partner" or tie == "best friend" or tie == "sibling" or tie == "buddy"
    local stranger = (tonumber(score) or 0) < 10 and not close
    if close then base.deep = base.deep * 2 end
    if stranger then base.deep = base.deep * 0.3; base.social = base.social * 0.5 end
    if (ctx.low or 0) > 0.4 then base.deep = base.deep * 1.5; base.light = base.light * 0.6 end
    if (ctx.fear or 0) > 0.5 then base.survival = base.survival * 1.8 end
    for key, t in pairs(M.topics) do
        local v = base[t.kind] or 5
        if key == "joke" or key == "story" or key == "music" then v = v * (1 + (lens.cheerful or 0) * 2 + (lens.sarcastic or 0)) end
        if key == "hottake" then v = v * (0.6 + (lens.sarcastic or 0) * 2 + (lens.volatile or 0) * 1.5 + (lens.proud or 0)) end
        if key == "faith" then v = v * (0.5 + (lens.devout or 0) * 4) end
        if key == "theory" then v = v * (0.6 + (lens.paranoid or 0) * 3 + (lens.curious or 0)) end
        if key == "flame" or key == "dream" then v = v * (0.7 + (lens.romantic or 0) * 2.5) end
        if key == "regret" or key == "losses" then v = v * (0.7 + (lens.gloomy or 0) * 2) end
        if key == "family" then v = v * (0.8 + (lens.kind or 0) * 1.5) end
        if key == "gossip" then v = v * (0.6 + (lens.deceitful or 0) * 2 + (lens.curious or 0)) end
        if key == "hunger" or key == "ammo" then v = v * (0.8 + (lens.greedy or 0) * 1.5 + (lens.disciplined or 0)) end
        if key == "plans" then v = v * (0.7 + (lens.disciplined or 0) * 2) end
        if key == "moral" then v = v * (0.5 + (lens.kind or 0) + (lens.devout or 0)) end
        if key == "losses" and ctx.loss then v = v * 2 end
        if t.fact(uid, ctx) == nil then v = 0 end
        w[key] = v
    end
    return w
end
-- choose: weights x anti-repetition (this NPC's last topics, this pair's last topics)
function M.pickTopic(uid, ctx, pairKey, tie, score, seed)
    local w = M.topicWeights(uid, ctx, tie, score)
    local mine = recentList(bucket("topicsBy"), uid)
    local ours = pairKey and recentList(bucket("topicsPair"), pairKey) or {}
    for i, k in ipairs(mine) do if w[k] then w[k] = w[k] * (0.08 + 0.92 * (1 - i / (#mine + 1)) * 0.2) end end
    for _, k in ipairs(ours) do if w[k] then w[k] = w[k] * 0.05 end end
    local total = 0
    local keys = {}
    for k, v in pairs(w) do if v > 0 then keys[#keys + 1] = k; total = total + v end end
    if total <= 0 then return nil end
    table.sort(keys)
    local r = (hash(tostring(seed or nowMs()) .. uid) % 10000) / 10000 * total
    for _, k in ipairs(keys) do r = r - w[k]; if r <= 0 then return k end end
    return keys[#keys]
end
function M.noteTopic(uid, key, pairKey)
    local mine = recentList(bucket("topicsBy"), tostring(uid))
    table.insert(mine, 1, key)
    while #mine > M.lifeCfg.recentTopics do table.remove(mine) end
    if pairKey then
        local ours = recentList(bucket("topicsPair"), pairKey)
        table.insert(ours, 1, key)
        while #ours > M.lifeCfg.pairRecent do table.remove(ours) end
    end
end
-- the conversation log (callbacks): who said what on which topic
function M.topicLogFor(key) return recentList(bucket("topicLog"), key) end
function M.callbackFor(logKey, topic)
    for _, e in ipairs(M.topicLogFor(logKey)) do
        if e.k == topic and hours() - (e.h or 0) >= M.lifeCfg.callbackMinH then return e end
    end
    local list = M.topicLogFor(logKey)
    local e = list[1]
    if e and hours() - (e.h or 0) >= M.lifeCfg.callbackMinH and (hash(logKey .. math.floor(hours())) % 100) < M.lifeCfg.callbackChance then return e end
    return nil
end
function M.noteTopicLine(logKey, topic, who, line)
    local list = M.topicLogFor(logKey)
    table.insert(list, 1, { k = topic, w = who, t = string.sub(tostring(line or ""), 1, 120), h = hours() })
    while #list > M.lifeCfg.logKeep do table.remove(list) end
end
-- facts told: per NPC, to whom (player / uid); told facts become callbacks, untold ones are new things to share
function M.markTold(uid, topic, to)
    local t = recentList(bucket("lifeTold"), tostring(uid))
    t[topic .. ">" .. tostring(to)] = math.floor(hours())
end
function M.wasTold(uid, topic, to) return recentList(bucket("lifeTold"), tostring(uid))[topic .. ">" .. tostring(to)] ~= nil end
-- openers they used lately (the bridge refuses lines that start the same way)
function M.recentOpeners(uid)
    local out = {}
    local function opener(s)
        local w = {}
        for word in string.gmatch(string.lower(tostring(s or "")), "[%a']+") do w[#w + 1] = word; if #w >= 3 then break end end
        return #w >= 2 and table.concat(w, " ") or nil
    end
    pcall(function()
        local lines = M.memFor(uid).lines or {}
        for i = #lines, math.max(1, #lines - 5), -1 do local o = opener(lines[i].me); if o then out[#out + 1] = o end end
    end)
    for _, e in ipairs(M.topicLogFor("npc:" .. tostring(uid))) do
        local o = opener(e.t); if o then out[#out + 1] = o end
        if #out >= 8 then break end
    end
    return out
end
-- build the topic block for a request
function M.topicBlock(l, partner, logKey, pairKey, tie, score, to)
    local uid = tostring(l.record.uid)
    local ctx = M.lifeContext(l, partner)
    local key = M.pickTopic(uid, ctx, pairKey, tie, score, nowMs())
    if key == nil then return nil end
    local t = M.topics[key]
    local b = { key = key, label = t.label, kind = t.kind, fact = t.fact(uid, ctx), argue = t.argue or nil,
        mood = ctx.danger and "terse" or (ctx.cozy and "relaxed" or "normal") }
    if t.kind == "life" or t.kind == "light" or t.kind == "deep" then
        if M.wasTold(uid, key, to) then b.told = true end
    end
    local cb = M.callbackFor(logKey, key)
    if cb then b.callback = { topic = M.topics[cb.k] and M.topics[cb.k].label or cb.k, who = cb.w, line = cb.t } end
    if partner and key ~= "gossip" then
        local pf = M.topics[key].fact(tostring(partner.record.uid), M.lifeContext(partner, l))
        if pf and (t.kind == "light" or t.kind == "life" or t.kind == "deep") then b.theirs = pf end -- for a reply / disagreement
    end
    return b
end
-- NPC-NPC: topic per pair, kept for the follow-up lines of the same exchange
M.pairTopicNow = {}
function M.lifeInstall()
    if M.lifeAmbWrapped or type(M.ambientRequest) ~= "function" then return end
    M.lifeAmbWrapped = true
    local orig = M.ambientRequest
    M.ambientRequest = function(job, now, ...)
        local req = orig(job, now, ...)
        if req ~= nil and M.settings.lifeTopics ~= false then
            pcall(function()
                local me = M.refresh(job)
                local partner = M.refresh({ uid = job.speakerUid, listener = job.partner })
                if me == nil or partner == nil then return end
                local pk = M.pairKey(me.record.uid, partner.record.uid)
                local b = M.topicBlock(me, partner, "pair:" .. pk, pk, req.pairType, req.pairScore, tostring(partner.record.uid))
                if b then
                    req.topic = b
                    req.banOpeners = M.recentOpeners(tostring(me.record.uid))
                    M.pairTopicNow[pk] = { key = b.key, at = now, starter = tostring(me.record.uid) }
                end
            end)
        end
        return req
    end
end
-- the chime answering an ambient line: same topic, their own side of it
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.lifeTopics == false then return end
    local uid = tostring(listener.record.uid)
    -- player conversations: their life is consistent, revealed one bit at a time
    local f = M.lifeFacts(uid)
    local told = {}
    for _, k in ipairs({ "hometown", "job", "music", "show", "sport", "food", "hobby", "flame", "regret", "dream", "faith", "theory" }) do
        if M.wasTold(uid, k, "player") then told[#told + 1] = M.topics[k].label end
    end
    req.life = { hometown = f.hometown, job = f.job, music = f.music, show = f.show, sport = f.sport, food = f.food, hobby = f.hobby,
        flame = f.flame, regret = f.regret, dream = f.dream, belief = f.belief, theory = f.theory, story = f.story, joke = f.joke,
        hottake = f.hottake, told = told }
end)
-- after a line: remember topic, log it, consequences (bonds, opened up, petty arguments)
function M.lifeAfterPairLine(job, text, r)
    if M.settings.lifeTopics == false or job == nil or job.speakerUid == nil then return end
    local a, b = tostring(job.uid), tostring(job.speakerUid)
    if b == "player" then return end
    local pk = M.pairKey(a, b)
    local cur = M.pairTopicNow[pk]
    if cur == nil or nowMs() - cur.at > M.lifeCfg.pairTopicMs then return end
    M.noteTopic(a, cur.key, pk)
    M.noteTopicLine("pair:" .. pk, cur.key, nameOf(rec(a)), text)
    M.noteTopicLine("npc:" .. a, cur.key, nameOf(rec(a)), text)
    local t = M.topics[cur.key]
    if t and (t.kind == "deep" or t.kind == "life") and not M.wasTold(a, cur.key, b) then
        M.markTold(a, cur.key, b)
        if t.kind == "deep" and M.pairBump then pcall(M.pairBump, a, b, 2, "opened up about " .. t.label) end
    end
    if t and t.argue and type(r) == "table" and (r.pair == "ARGUE" or r.pair == "MOCK" or r.pair == "INSULT") then
        local lens = M.lens and M.lens(b) or {}
        local hot = (lens.volatile or 0) + (lens.proud or 0) - (lens.calm or 0) - (lens.cheerful or 0)
        if hot <= 0 and M.pairBump then pcall(M.pairBump, a, b, 2, "friendly ribbing about " .. tostring(M.lifeFacts(a).hottake)) end -- ribbing, not a feud
    end
end
-- player side: the AI's answer mentions a fact word -> told (callback next time, +1 trust once per fact)
function M.lifeAfterReply(p, r)
    if M.settings.lifeTopics == false or type(r) ~= "table" or type(r.text) ~= "string" or r.text == "" then return end
    local uid = tostring(p.uid)
    local f = M.lifeFacts(uid)
    local low = string.lower(r.text)
    local function hit(v)
        if type(v) ~= "string" then return false end
        for word in string.gmatch(string.lower(v), "[%a']+") do
            if #word >= 5 and string.find(low, word, 1, true) and word ~= "their" and word ~= "about" and word ~= "after" then return true end
        end
        return false
    end
    local map = { hometown = f.hometown, job = f.job, music = f.music, show = f.show, sport = f.sport, food = f.food, hobby = f.hobby,
        flame = f.flameName, regret = f.regret, dream = f.dream, faith = f.belief, theory = f.theory }
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        if not M.wasTold(uid, k, "player") and hit(map[k]) then
            M.markTold(uid, k, "player")
            M.noteTopic(uid, k, nil)
            M.noteTopicLine("player:" .. uid, k, "them", r.text)
            if M.keyMem then pcall(M.keyMem, uid, "shared", "Told the newcomer about " .. M.topics[k].label) end
            if M.topics[k].kind == "deep" and fn(PA().NpcOpinion, "adjust") and p.player then
                pcall(PA().NpcOpinion.adjust, p.listener and p.listener.record or rec(uid), p.player, 1, "Opened up to you about " .. M.topics[k].label)
            end
            break
        end
    end
end
function M.lifeInstall2()
    if not M.lifePairWrapped and type(M.notePairLine) == "function" then
        M.lifePairWrapped = true
        local orig = M.notePairLine
        M.notePairLine = function(job, text, r, ...)
            local t1, t2 = orig(job, text, r, ...)
            pcall(M.lifeAfterPairLine, job, text, r)
            return t1, t2
        end
    end
    if not M.lifeReplyWrapped and type(M.finish) == "function" then
        M.lifeReplyWrapped = true
        local origF = M.finish
        M.finish = function(p, r, ...)
            local a, b = origF(p, r, ...)
            if p and (p.mode == "reply" or p.mode == nil) then pcall(M.lifeAfterReply, p, r) end
            return a, b
        end
    end
end

if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.lifeInstall); pcall(M.lifeInstall2) end) end
pcall(M.lifeInstall)
pcall(M.lifeInstall2)
return M
