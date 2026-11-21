-- A-Life NPC Overhaul 0.9.1 (Legacy): THE CHRONICLE. The camp's history, told by the people who were there.
--   * One entry per real event (a death, a funeral or none, people let in or turned away, exiles, who leads, what the
--     lieutenant decided while you were away, captures, backing a side, a survivor's story ending, feasts, traditions,
--     quests). Nothing is made up: every entry comes from a call another system really made.
--   * Each entry is told by one resident who was there, in their own way: someone who likes you tells it warm, someone
--     who doesn't tells it bitter, the rest plain (stock lines per event x bias; the AI rewrites it in their voice when
--     it's on, client side). No numbers shown.
--   * Chapters per season and per leader ("Summer, year 1 - under Joe", then "After Joe fell, Darrell led").
--   * The client writes it into a real notebook (vanilla addPage, needs a pen) and exports it to a text file.
-- Store: global ModData "ALifeChatPlus_Chronicle" (saved with the world, shared in multiplayer). Server decides.
-- Commands (ALifeCmd): chronAdd (a client-side event, validated), chronAsk -> chronList.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeChronicle") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)
require "ALifeNPCOverhaul/ALifeCmd"
if ALifeCampVote == nil then require "ALifeNPCOverhaul/ALifeCampVote" end -- pre-1.0: loaded first by folder order before (ALifeChatPlus sorted first); now a real require

ALifeChronicle = ALifeChronicle or {}
local C = ALifeChronicle
local TAG = "[ALifeChronicle]"
C.VERSION = ALifeSide.MOD_VERSION
C.MODDATA = "ALifeChatPlus_Chronicle"
C.DEFAULTS = {
    chronicle = true,       -- the camp keeps a chronicle
    chronMax = 300,         -- most entries kept (the small ones go first)
    chronRate = 100,        -- % of small events written down (big ones always are)
    chronAI = true,         -- the AI tells entries in the narrator's voice when it's on
    chronDedupeH = 2,       -- the same thing about the same person is written once in this many game hours
}
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function num(v, d) v = tonumber(v); if v == nil then return d end return v end
function C.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = C.DEFAULTS[key] end
    return v
end
function C.registerSettings()
    local m = ALifeLLMTalk
    if type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    m.fileKeys = m.fileKeys or {}
    for k, v in pairs(C.DEFAULTS) do
        if m.settings[k] == nil then m.settings[k] = v end
        local have = false
        for _, x in ipairs(m.fileKeys) do if x == k then have = true end end
        if not have then m.fileKeys[#m.fileKeys + 1] = k end
    end
    return true
end
C.registerSettings()
function C.on() return C.setting("chronicle") ~= false end
function C.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return num(h, 0) end
-- season from the game's month (0 = January)
C.SEASONS = { "Winter", "Winter", "Spring", "Spring", "Spring", "Summer", "Summer", "Summer", "Fall", "Fall", "Fall", "Winter" }
function C.season()
    local m = nil
    pcall(function() m = getGameTime():getMonth() end)
    return C.SEASONS[(num(m, 6) % 12) + 1]
end
function C.store()
    local d = nil
    pcall(function() d = ModData.getOrCreate(C.MODDATA) end)
    if type(d) ~= "table" then C._mem = C._mem or {}; d = C._mem end
    d.seq = num(d.seq, 0)
    d.list = type(d.list) == "table" and d.list or {}
    d.leaders = type(d.leaders) == "table" and d.leaders or {}
    return d
end
local function transmit()
    if type(ModData) == "table" and fn(ModData, "transmit") and ALifeSide.server() then pcall(ModData.transmit, C.MODDATA) end
end
C.transmit = transmit

-- the kinds, how big they are (big = always written, kept longest)
C.KINDS = {
    death = { big = true }, funeral = { big = true }, nofuneral = {}, join = {}, turnaway = {}, exile = { big = true },
    lead = { big = true }, away = {}, captured = { big = true }, freed = { big = true }, backed = { big = true },
    story = { big = true }, feast = {}, tradition = { big = true }, quest = {}, standoff = {}, leader = { big = true },
    legacy = { big = true }, war = { big = true }, vote = {}, run = {}, other = {},
}
-- stock telling: per kind, per bias (warm / plain / bitter). {who} = the person it's about, {what} = the fact,
-- {lead} = whoever led then, {by} = the narrator
C.LINES = {
    death = { warm = "We lost {who}. {what}. {lead} made sure we kept going.", plain = "{who} died. {what}.", bitter = "{who} died. {what}. Some of us still ask if {lead} could have stopped it." },
    funeral = { warm = "We buried {who} at dusk, all of us together. {lead} let us take the time.", plain = "We held a funeral for {who}.", bitter = "We buried {who}. Took a death to get us all in one place." },
    nofuneral = { warm = "There was no time to bury {who} properly. {lead} hated that as much as we did.", plain = "No funeral for {who}. No time.", bitter = "{lead} had no time for {who}'s funeral. I remember that." },
    join = { warm = "{who} came to us and we let them in. Good day.", plain = "{who} joined the camp. {what}.", bitter = "{who} got let in. More mouths. {what}." },
    turnaway = { warm = "We turned {who} away. Hard call, the right one.", plain = "{who} came to the door. We said no. {what}.", bitter = "We sent {who} back out there. {what}. Hope we can live with it." },
    exile = { warm = "{who} had to go. The camp decided, and it was fair.", plain = "{who} was thrown out. {what}.", bitter = "They threw {who} out. {what}. Could've been any of us." },
    lead = { warm = "{who} stood up for the camp. {what}.", plain = "{who}: {what}.", bitter = "{who} took charge. {what}. Nobody asked me." },
    away = { warm = "While {lead} was gone, {who} kept things running. {what}.", plain = "While {lead} was away: {what}.", bitter = "{lead} was off somewhere again. {what}." },
    captured = { warm = "They took {who}. We didn't stop looking.", plain = "{who} was taken. {what}.", bitter = "{who} got themselves taken. {what}." },
    freed = { warm = "{who} came back to us. {what}.", plain = "{who} was free again. {what}.", bitter = "{who} got loose. {what}. Took long enough." },
    backed = { warm = "{lead} picked a side: {what}. We trusted that.", plain = "{what}.", bitter = "{lead} tied us to {what}. Somebody'll pay for that." },
    story = { warm = "{who}: {what}. I was glad for them.", plain = "{who}: {what}.", bitter = "{who}: {what}. That's how it goes now." },
    feast = { warm = "{what}. Best night we'd had in a long time.", plain = "{what}.", bitter = "{what}. Ate well for once." },
    tradition = { warm = "It became our way: {what}.", plain = "We started doing it every time: {what}.", bitter = "{what}. Now it's a rule, apparently." },
    quest = { warm = "{who}: {what}. We did right by them.", plain = "{who}: {what}.", bitter = "{who}: {what}. Cost us, too." },
    standoff = { warm = "{what}. {lead} stepped in.", plain = "{what}.", bitter = "{what}. Blood on somebody's hands." },
    leader = { warm = "{what}. We followed.", plain = "{what}.", bitter = "{what}. Not everyone liked it." },
    legacy = { warm = "{what}. We won't forget.", plain = "{what}.", bitter = "{what}. Some of us won't miss it." },
    war = { warm = "{what}. We held together.", plain = "{what}.", bitter = "{what}. For what?" },
    run = { warm = "{what}. Everyone home safe, or near enough.", plain = "{what}.", bitter = "{what}. Hardly worth the risk." },
    vote = { warm = "The camp voted: {what}.", plain = "The camp voted: {what}.", bitter = "They took a vote: {what}. Mine didn't count for much." },
    other = { warm = "{what}.", plain = "{what}.", bitter = "{what}." },
}
local function clip(s, n) s = tostring(s or ""); if #s > n then s = string.sub(s, 1, n) end return s end
local function fill(t, e)
    return (string.gsub(t, "{(%a+)}", function(k)
        local v = (k == "who" and e.who) or (k == "what" and e.what) or (k == "lead" and e.lead) or (k == "by" and e.byName) or nil
        if v == nil or v == "" then return (k == "lead" and "we") or "someone" end
        return tostring(v)
    end))
end
function C.telling(e)
    if type(e) ~= "table" then return "" end
    if type(e.ai) == "string" and e.ai ~= "" then return e.ai end
    local set = C.LINES[e.k] or C.LINES.other
    local t = set[e.bias or "plain"] or set.plain
    local s = fill(t, e)
    s = string.gsub(s, "%.%.", ".")
    s = string.gsub(s, "^%s*%.%s*", "")
    return s
end

-- the leader now (chapter by leader): the last row of d.leaders, else nil
function C.leader()
    local l = C.store().leaders
    local r = l[#l]
    return r and r.name or nil
end
-- a new leader: a chapter starts. how: "first" | "fell" (the last one died) | "vote" | "heir" | "coup" | "left"
function C.setLeader(name, how)
    name = clip(name, 40)
    if name == "" then return false end
    local d = C.store()
    local last = d.leaders[#d.leaders]
    if last and last.name == name then return false end
    d.leaders[#d.leaders + 1] = { name = name, h = C.hours(), how = clip(how or "first", 12), before = last and last.name or nil }
    transmit()
    return true
end

-- write an entry. ev = { k, who, uid, what, by (narrator uid), byName, bias, big }. Returns the entry or nil, why
function C.add(ev)
    if not C.on() then return nil, "off" end
    if type(ev) ~= "table" then return nil, "bad" end
    local k = C.KINDS[ev.k] and ev.k or "other"
    local big = C.KINDS[k].big == true or ev.big == true
    local d = C.store()
    local h = C.hours()
    local who, what = clip(ev.who, 40), clip(ev.what, 200)
    for i = #d.list, math.max(1, #d.list - 30), -1 do
        local o = d.list[i]
        local recent = h - num(o.h, 0) < num(C.setting("chronDedupeH"), 2)
        if recent and o.k == k and o.who == who and o.what == what then return nil, "dupe" end
        if recent and o.k == k and o.who == who and who ~= "" and k ~= "away" and k ~= "other" then return nil, "dupe" end
    end
    if not big then
        local rate = num(C.setting("chronRate"), 100)
        if rate < 100 then
            local roll = 0
            pcall(function() roll = ZombRand(100) end)
            if roll >= rate then return nil, "rate" end
        end
    end
    d.seq = d.seq + 1
    local bias = (ev.bias == "warm" or ev.bias == "bitter") and ev.bias or "plain"
    local e = { id = d.seq, k = k, who = who, uid = ev.uid and clip(ev.uid, 40) or nil, what = what, by = ev.by and clip(ev.by, 40) or nil,
        byName = ev.byName and clip(ev.byName, 40) or nil, bias = bias, big = big or nil, h = h, season = C.season(), lead = C.leader() }
    d.list[#d.list + 1] = e
    C.trim(d)
    transmit()
    if fn(C, "onAdded") then pcall(C.onAdded, e) end
    return e
end
-- too many: drop the oldest small entry first, then the oldest of all
function C.trim(d)
    local max = math.max(20, num(C.setting("chronMax"), 300))
    while #d.list > max do
        local drop = nil
        for i, e in ipairs(d.list) do if not e.big then drop = i; break end end
        table.remove(d.list, drop or 1)
    end
end
function C.byId(id) for _, e in ipairs(C.store().list) do if e.id == id then return e end end return nil end
-- the AI's telling arrives later (client, SP / the host): keep it
function C.setAI(id, text)
    local e = C.byId(num(id, -1))
    if e == nil or type(text) ~= "string" or #text < 8 then return false end
    e.ai = clip(text, 400)
    transmit()
    return true
end

-- chapters: a new one when the season changes or the leader changes. { title, entries = {...} } oldest first
function C.chapters()
    local out, cur = {}, nil
    local year = 1
    local lastSeason = nil
    for _, e in ipairs(C.store().list) do
        if lastSeason == "Winter" and e.season == "Spring" then year = year + 1 end
        local key = tostring(e.season) .. "|" .. tostring(year) .. "|" .. tostring(e.lead)
        if cur == nil or cur.key ~= key then
            local title = tostring(e.season or "") .. ", year " .. year
            if e.lead then
                local why = nil
                for _, l in ipairs(C.store().leaders) do if l.name == e.lead and l.before then why = l end end
                if why and why.how == "fell" then title = title .. " - after " .. why.before .. " fell, " .. e.lead .. " led"
                elseif why and why.before then title = title .. " - " .. e.lead .. " led after " .. why.before
                else title = title .. " - under " .. e.lead end
            end
            cur = { key = key, title = title, entries = {} }
            out[#out + 1] = cur
        end
        table.insert(cur.entries, e)
        lastSeason = e.season
    end
    return out
end
-- the whole thing as text (export, notebook pages)
function C.chapterText(ch)
    local lines = { ch.title, "" }
    for _, e in ipairs(ch.entries) do
        local by = e.byName and (" - " .. e.byName) or ""
        lines[#lines + 1] = "Day " .. (math.floor(num(e.h, 0) / 24) + 1) .. ": " .. C.telling(e) .. by
    end
    return table.concat(lines, "\n")
end
function C.text(campName)
    local parts = { "THE CHRONICLE OF " .. string.upper(tostring(campName or "OUR CAMP")), "" }
    for _, ch in ipairs(C.chapters()) do parts[#parts + 1] = C.chapterText(ch); parts[#parts + 1] = "" end
    if #C.store().list == 0 then parts[#parts + 1] = "Nothing written yet." end
    return table.concat(parts, "\n")
end
-- a plain list for clients (newest last)
function C.view(maxN)
    local l = C.store().list
    local out = {}
    for i = math.max(1, #l - (maxN or 200) + 1), #l do
        local e = l[i]
        out[#out + 1] = { id = e.id, k = e.k, who = e.who, what = e.what, byName = e.byName, bias = e.bias, h = e.h, season = e.season, lead = e.lead, ai = e.ai, big = e.big }
    end
    return out
end

-- server-side hooks into the shared systems (each one guarded: missing module = no hook)
local function wrap(tbl, name, after)
    if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then return false end
    local mark = "_chron_" .. name
    if rawget(tbl, mark) then return true end
    local orig = tbl[name]
    local function pack(...) return { n = select("#", ...), ... } end
    tbl[name] = function(...)
        local r = pack(orig(...))
        local args = pack(...)
        pcall(after, r, unpack(args, 1, args.n))
        return unpack(r, 1, r.n)
    end
    rawset(tbl, mark, true)
    return true
end
C.wrap = wrap
local function pname(uid)
    local n = nil
    pcall(function() local pa = ProjectALife; local rec = pa.ActorRegistry.read(tostring(uid)); n = pa.Names.of(rec) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or nil
end
C.pname = pname
local function playerName(p)
    local n = nil
    pcall(function() n = p:getDescriptor():getForename() end)
    if n == nil or n == "" then pcall(function() n = p:getUsername() end) end
    return n
end
C.playerName = playerName
function C.hookShared()
    local n = 0
    -- the lieutenant's decisions while you're away (L.note(row, r, text))
    if wrap(ALifeLieutenant, "note", function(res, row, r, text)
        -- 0.9.5: a door decision is already in the book as the gate line (naming the lieutenant): one line per door event
        local lt = type(ALifeLieutenant) == "table" and ALifeLieutenant.doorBy or nil
        if type(lt) == "table" and lt.chron then return end
        local who = nil
        pcall(function() local n = ProjectALife.Names.of(r); who = string.match(tostring(n), "^(%S+)") end)
        C.add({ k = "away", who = who, uid = type(r) == "table" and r.uid and tostring(r.uid) or nil, what = text })
    end) then n = n + 1 end
    -- the camp lets people in or not (V.onAnswered(ev, yes))
    if wrap(ALifeCampVote, "onAnswered", function(res, ev, yes)
        if type(ev) ~= "table" then return end
        local uids = type(ev.uids) == "table" and ev.uids or {}
        local who = uids[1] and pname(uids[1]) or nil
        if who and #uids > 1 then who = who .. " and " .. (#uids - 1) .. " more" end
        local what = yes and "they were let in at the gate" or "they were turned away at the gate"
        local lt = type(ALifeLieutenant) == "table" and ALifeLieutenant.doorBy or nil
        if type(lt) == "table" then
            what = what .. (lt.who and (" (" .. tostring(lt.who) .. "'s call, while you were away)") or " (while you were away)")
            lt.chron = true
        end
        C.add({ k = yes and "join" or "turnaway", who = who or "people at the door", uid = uids[1] and tostring(uids[1]) or nil, what = what })
    end) then n = n + 1 end
    if wrap(ALifeCampVote, "exiled", function(res, player, uid, t)
        C.add({ k = "exile", who = pname(uid) or "someone", uid = uid, what = "the camp voted them out" })
    end) then n = n + 1 end
    if wrap(ALifeCampVote, "newLead", function(res, player, uid)
        C.add({ k = "lead", who = pname(uid) or "someone", uid = uid, what = "the camp chose them to lead while the boss was away" })
    end) then n = n + 1 end
    -- captured / free (C.take(player, crew, kind, why), C.free(player, why))
    if wrap(ALifeCapture, "take", function(res, player, crew, kind, why)
        if res[1] == false or res[1] == nil then return end
        C.add({ k = "captured", who = playerName(player) or "the boss", what = "taken by " .. tostring(kind or "strangers") })
    end) then n = n + 1 end
    if wrap(ALifeCapture, "free", function(res, player, why)
        C.add({ k = "freed", who = playerName(player) or "the boss", what = tostring(why or "got away") })
    end) then n = n + 1 end
    -- backing a side (Kingmaker L.back(player, b, other))
    if wrap(ALifeKingmaker, "back", function(res, player, b, other)
        local a = type(b) == "table" and (b.name or b.factionName) or "one side"
        local o = type(other) == "table" and (other.name or other.factionName) or "the other"
        C.add({ k = "backed", what = "backing " .. tostring(a) .. " against " .. tostring(o) })
    end) then n = n + 1 end
    -- a scavenging run comes home (ALifeExpeditions.returnHome(orig, m, q, hours), server: Jeem's missions)
    if wrap(ALifeExpeditions, "returnHome", function(res, orig, m, q, hours)
        if type(m) ~= "table" or m.kind ~= "scavenge" then return end
        local back = type(q) == "table" and type(q.members) == "table" and #q.members or 0
        C.add({ k = "run", what = (back == 1 and "One of ours" or (back .. " of ours")) .. " came back from a scavenging run" })
    end) then n = n + 1 end
    C.hookedShared = n
    return n
end

function C.install()
    if C.installed or not fn(ALifeCmd, "onServer") then return C.installed == true end
    local function answer(player) ALifeCmd.reply(player, "chronList", { list = C.view(200), leaders = C.store().leaders }) end
    ALifeCmd.onServer("chronAsk", function(player, a) answer(player) end)
    ALifeCmd.onServer("chronAdd", function(player, a)
        if type(a) ~= "table" or C.KINDS[tostring(a.k)] == nil then return end
        C.add({ k = tostring(a.k), who = a.who, uid = a.uid, what = a.what, by = a.by, byName = a.byName, bias = a.bias })
    end)
    ALifeCmd.onServer("chronAI", function(player, a) if type(a) == "table" then C.setAI(a.id, a.text) end end)
    C.installed = true
    return true
end
C.install()
pcall(C.hookShared)
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(C.hookShared) end) end
print(TAG .. " ready v" .. C.VERSION .. ": chronicle " .. (C.on() and "on" or "off") .. ", " .. tostring(C.hookedShared or 0) .. " shared hooks, " .. #C.store().list .. " entries")
return C
