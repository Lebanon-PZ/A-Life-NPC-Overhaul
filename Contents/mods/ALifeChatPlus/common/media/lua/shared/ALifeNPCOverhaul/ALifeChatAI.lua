-- A-Life NPC Overhaul: AI voice (phase 2).
-- A-Life still decides EVERYTHING (what you meant, trades, orders, opinion, fights). This only changes
-- the words an NPC says: A-Life picks its line as usual, we hold that line back for a moment, ask a local
-- model (via the alifeai_bridge helper + Ollama) to say the same thing in the NPC's own voice, and show
-- that instead. No reply in time / helper not running -> A-Life's own line is shown, unchanged.
--
-- Files (all in C:\Users\<you>\Zomboid\Lua\):
--   alifeai_req_<id>.txt    written here, read + deleted by the helper
--   alifeai_resp_<id>.txt   written by the helper, read here, then blanked
--   alifeai_alive.txt       helper heartbeat (epoch ms); no fresh heartbeat = feature sleeps
--   alifeai_config.txt      optional: enabled=, timeoutMs=, menu=  (key=value per line)

require "ALifeNPCOverhaul/AA_Side"
local TAG = "[ALifeChatAI]"
local VERSION = ALifeSide.MOD_VERSION

ALifeChatAI = ALifeChatAI or {}
local AI = ALifeChatAI
AI.version = VERSION
AI.enabled = AI.enabled ~= false
AI.timeoutMs = AI.timeoutMs or 3500     -- longest we hold A-Life's line back
AI.voiceMenu = AI.voiceMenu == true     -- also voice menu (right-click Talk) choices, not just typed chat
AI.metrics = AI.metrics or { asked = 0, voiced = 0, timeouts = 0, skipped = 0, understood = 0, chatted = 0, missed = 0 }
AI.understand = AI.understand ~= false  -- when the phrase matcher can't place what you said, the AI works out what you meant
AI.understandMs = AI.understandMs or 6000

local HEARTBEAT_FILE, CONFIG_FILE = "alifeai_alive.txt", "alifeai_config.txt"
local HEARTBEAT_MAX_AGE = 10000
local POLL_EVERY = 6                    -- ticks between response checks, only while something is pending

-- ---------------------------------------------------------------- guard ----
local disabled = {}
local function tryOnce(id, fn, ...)
    if disabled[id] then return false, nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return true, a, b end
    disabled[id] = true
    print(TAG .. " " .. id .. " failed, disabled for this session: " .. tostring(a))
    return false, nil
end

local function now()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return 0
end

-- is a delayed reply still meaningful? (you alive, them alive, loaded, and still close enough to hear)
local function stillThere(player, shell, maxTiles)
    if shell == nil then return false end
    local ok, good = pcall(function()
        if type(shell.isDead) == "function" and shell:isDead() then return false end
        if player ~= nil then
            if type(player.isDead) == "function" and player:isDead() then return false end
            if type(shell.getX) ~= "function" or type(player.getX) ~= "function" then return true end
            local dx, dy = shell:getX() - player:getX(), shell:getY() - player:getY()
            if dx * dx + dy * dy > (maxTiles or 30) ^ 2 then return false end
        end
        return true
    end)
    return ok and good == true
end

local function clean(s, limit)
    s = tostring(s or "")
    s = string.gsub(s, "[\r\n|]", " ")
    s = string.gsub(s, "%s+", " ")
    if limit and #s > limit then s = string.sub(s, 1, limit) end
    return s
end

local function readAll(name)
    if type(getFileReader) ~= "function" then return nil end
    local reader = getFileReader(name, false)
    if reader == nil then return nil end
    local lines = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        lines[#lines + 1] = tostring(line)
    end
    reader:close()
    return lines
end

local function writeLines(name, lines)
    -- 0.5.1: every request to the AI helper says which language NPCs speak
    if type(ALifeLanguage) == "table" and string.sub(name, 1, 12) == "alifeai_req_" and #lines > 0 and lines[#lines] == "end=1" then
        local ok, code, lname = pcall(ALifeLanguage.code)
        if ok and code and code ~= "en" then
            table.insert(lines, #lines, "lang=" .. code)
            table.insert(lines, #lines, "langName=" .. tostring(lname))
        end
    end
    local writer = getFileWriter(name, true, false)
    if writer == nil then return false end
    for i = 1, #lines do writer:write(lines[i] .. "\n") end
    writer:close()
    return true
end

-- -------------------------------------------------------- helper alive -----
local aliveAt, aliveCheckedAt = false, -1e18
local function helperAlive()
    local t = now()
    if t - aliveCheckedAt < 3000 then return aliveAt end
    aliveCheckedAt = t
    aliveAt = false
    local ok, lines = pcall(readAll, HEARTBEAT_FILE)
    if ok and lines ~= nil and lines[1] ~= nil then
        local beat = tonumber(string.match(lines[1], "(%d+)"))
        if beat ~= nil and math.abs(t - beat) < HEARTBEAT_MAX_AGE then aliveAt = true end
    end
    return aliveAt
end

local function loadConfig()
    local ok, lines = pcall(readAll, CONFIG_FILE)
    if not ok or lines == nil then return end
    for _, line in ipairs(lines) do
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "enabled" then AI.enabled = v ~= "false" and v ~= "0"
        elseif k == "timeoutMs" and tonumber(v) then AI.timeoutMs = math.max(500, math.min(15000, tonumber(v)))
        elseif k == "menu" then AI.voiceMenu = v == "true" or v == "1"
        elseif k == "understand" then AI.understand = v ~= "false" and v ~= "0" end
    end
end

-- -------------------------------------------------------------- history ----
local history = {}                      -- uid -> { "Stranger: ...", "Name: ..." } (last 8)
local function remember(uid, line)
    if uid == nil then return end
    local h = history[uid]
    if h == nil then h = {}; history[uid] = h end
    h[#h + 1] = clean(line, 200)
    while #h > 8 do table.remove(h, 1) end
end

-- ---------------------------------------------------------- npc profile ----
local function profile(record, player)
    local p = { name = "", faction = "", role = "", register = "", temperament = "", sex = "", voice = "",
        stance = "", mood = "", day = "", hour = "" }
    local Speech = ProjectALife.Speech
    pcall(function()
        local c = Speech.contextFor(record, player)
        p.role, p.register, p.temperament = tostring(c.role or ""), tostring(c.register or ""), tostring(c.temperament or "")
        p.sex, p.voice, p.stance = tostring(c.sex or ""), tostring(c.voice or ""), tostring(c.stance or "")
        p.day, p.hour = tostring(c.day or ""), tostring(c.hour or "")
        local fid = c.factionId
        if fid ~= nil then
            p.faction = tostring(fid)
            local cat = ProjectALife.Catalog
            local f = cat ~= nil and type(cat.faction) == "function" and cat.faction(fid) or nil
            if type(f) == "table" and type(f.title) == "string" then p.faction = f.title
            elseif type(f) == "table" and type(f.name) == "string" then p.faction = f.name end
        end
    end)
    pcall(function()
        local names = ProjectALife.Names
        local n = names ~= nil and names.of(record) or nil
        if n ~= nil then p.name = tostring(n) end
    end)
    pcall(function()
        local social = ProjectALife.TalkSocial
        if social ~= nil and type(social.mood) == "function" then
            local m = social.mood(record, player)
            if type(m) == "string" then p.mood = m elseif type(m) == "table" and m.label then p.mood = tostring(m.label) end
        end
    end)
    return p
end

local function situationOf(record, shell, player)
    local S = ALifeSituation
    if S == nil or type(S.read) ~= "function" then return "" end
    local ok, r = pcall(S.read, record, shell, player)
    return ok and type(r) == "table" and r.text or ""
end

local function storyLines(record, p)
    local out = {}
    local ST = ALifeStory
    if ST ~= nil then
        out[#out + 1] = "story=" .. clean(ST.get(record) or "", 1400)
        out[#out + 1] = "seed=" .. clean(ST.seed(record, p), 300)
    end
    if ALifeMemory ~= nil then
        local ok, m = pcall(ALifeMemory.about, record)
        out[#out + 1] = "memory=" .. clean(ok and m or "", 1400)
    end
    return out
end
local function keepStory(job, lines)
    if job.record == nil then return end
    for _, line in ipairs(lines or {}) do
        local v = string.match(line, "^story=(.*)$")
        if v ~= nil and v ~= "" and ALifeStory ~= nil and ALifeStory.get(job.record) == nil then ALifeStory.set(job.record, v) end
        local n = string.match(line, "^note=(.*)$")
        if n ~= nil and n ~= "" and n ~= "-" and ALifeMemory ~= nil then
            pcall(ALifeMemory.add, job.record, "the stranger told you: " .. n)
        end
    end
end

-- the list of things A-Life can understand, for the AI to choose from (rewritten when it changes)
local catalogCount = -1
local function writeCatalog()
    local Data = ProjectALife.DialogueData
    if Data == nil or type(Data.intents) ~= "table" then return false end
    pcall(Data.load)
    if #Data.intents == catalogCount then return true end
    local lines = {}
    for _, it in ipairs(Data.intents) do
        local ex = {}
        for i = 1, math.min(3, #(it.patterns or {})) do ex[#ex + 1] = it.patterns[i] end
        lines[#lines + 1] = tostring(it.id) .. ": " .. table.concat(ex, " / ")
    end
    if not writeLines("alifeai_intents.txt", lines) then return false end
    catalogCount = #Data.intents
    return true
end

-- ------------------------------------------------------------- pending -----
local pending = {}                      -- id -> job
local pendingCount = 0
local seq = 0
local sessionTag = tostring(math.floor(now() / 1000) % 100000)
local origSay                           -- ProjectALife.Speech.say as found

local function finish(job, text, voiced)
    if job.done then return end
    job.done = true
    pending[job.id] = nil
    pendingCount = pendingCount - 1
    local Speech = ProjectALife.Speech
    local spoke = false
    if not stillThere(job.player, job.shell, 30) then
        AI.metrics.stale = (AI.metrics.stale or 0) + 1
        pcall(writeLines, "alifeai_resp_" .. job.id .. ".txt", {})
        return
    end
    if voiced and text ~= nil and text ~= "" then
        local ok, r = pcall(origSay, job.shell, text, job.options)
        spoke = ok and r == true
        if spoke then
            AI.metrics.voiced = AI.metrics.voiced + 1
            remember(job.uid, (job.p.name ~= "" and job.p.name or "Them") .. ": " .. text)
        end
    end
    if not spoke then
        for i = 1, #job.held do pcall(origSay, job.shell, job.held[i].text, job.held[i].options) end
        remember(job.uid, (job.p.name ~= "" and job.p.name or "Them") .. ": " .. (job.held[1] and job.held[1].text or ""))
    end
    pcall(writeLines, "alifeai_resp_" .. job.id .. ".txt", {})   -- blank it; the helper sweeps blanks
end

local finishUnderstand
local function poll()
    if pendingCount <= 0 then return end
    local t = now()
    local ids = {}
    for id in pairs(pending) do ids[#ids + 1] = id end      -- answering can add jobs; don't loop the live table
    for _, id in ipairs(ids) do
        local job = pending[id]
        if job == nil then job = { kind = "gone", at = t } end      -- answered earlier in this pass
        local ok, lines = pcall(readAll, "alifeai_resp_" .. id .. ".txt")
        local text, intent = nil, nil
        if ok and lines ~= nil then
            for _, line in ipairs(lines) do
                local v = string.match(line, "^text=(.*)$")
                if v ~= nil then text = v end
                local i = string.match(line, "^intent=(.*)$")
                if i ~= nil then intent = i end
            end
        end
        if ok and lines ~= nil and (intent ~= nil or (text ~= nil and text ~= "")) then keepStory(job, lines) end
        if job.kind == "custom" then
            local got = false
            for _, line in ipairs(ok and lines or {}) do if string.match(line, "^done=1") then got = true end end
            if got or t - job.at > job.timeout then
                job.done = true
                pending[id] = nil
                pendingCount = pendingCount - 1
                pcall(writeLines, "alifeai_resp_" .. id .. ".txt", {})
                local okCb, err = pcall(job.callback, got and lines or nil)
                if not okCb then print(TAG .. " callback failed: " .. tostring(err)) end
            end
        elseif job.kind == "understand" then
            if intent ~= nil then finishUnderstand(job, intent, text)
            elseif t - job.at > AI.understandMs + (job.extra or 0) then
                AI.metrics.timeouts = AI.metrics.timeouts + 1
                finishUnderstand(job, nil, nil)
            end
        elseif text ~= nil and text ~= "" then
            finish(job, text, true)
        elseif t - job.at > AI.timeoutMs + (job.extra or 0) then
            AI.metrics.timeouts = AI.metrics.timeouts + 1
            finish(job, nil, false)
        end
    end
end

local tick = 0
local function onTick()
    if pendingCount <= 0 then return end
    tick = tick + 1
    if tick < POLL_EVERY then return end
    tick = 0
    tryOnce("poll", poll)
end

-- ------------------------------------------------------------- respond -----
local origRespond

local function wantVoice(choiceIntent, text)
    if not AI.enabled then return false end
    if choiceIntent ~= nil and not AI.voiceMenu and not AI.__force then return false end
    if type(text) ~= "string" or text == "" then return false end
    return helperAlive()
end

local askUnderstand                     -- defined below (the AI works out what you meant)

-- ------------------------------------------------------------ compound ----
-- "Hand me the bourbon, help me barricade, and give me your keys. Stay here." is several requests. Split it into
-- clauses; each one A-Life recognizes is asked separately, in order, a beat apart - each with its own yes or no.
AI.CLAUSE_GAP_MS = 2600
function AI.clauses(text)
    local t = " " .. tostring(text or "") .. " "
    t = string.gsub(t, "[%.;!%?]+", "|")
    t = string.gsub(t, ",%s*and then%s+", "|")
    t = string.gsub(t, ",%s*then%s+", "|")
    t = string.gsub(t, "%s+and then%s+", "|")
    t = string.gsub(t, "%s+then%s+", "|")
    t = string.gsub(t, ",%s*and%s+", "|")
    t = string.gsub(t, ",", "|")
    local out = {}
    for part in string.gmatch(t, "[^|]+") do
        part = string.gsub(string.gsub(part, "^%s+", ""), "%s+$", "")
        if #part > 1 then out[#out + 1] = part end
    end
    return out
end

local function compound(player, listener, text, nowArg)
    -- directions to a town are one request, however many commas: "Muldraugh, the bookstore, near the gas station"
    if ALifeTravel ~= nil and type(ALifeTravel.townIn) == "function" and ALifeTravel.townIn(text) ~= nil then return nil end
    local parts = AI.clauses(text)
    if #parts < 1 then return nil end
    local I = ProjectALife.TalkIntents
    local plan, leftover = {}, {}
    for _, raw in ipairs(parts) do
        -- softeners aren't requests: "I know you're scared", "look at me", "listen", "but ..."
        local part = string.gsub(raw, "^[Bb]ut%s+", "")
        local low = string.lower(part)
        local preamble = string.match(low, "^i know you") or string.match(low, "^i know that you") or low == "listen"
            or low == "look" or low == "hey" or low == "look at me" or string.match(low, "^okay") or low == "please"
        if preamble then part = nil end
        if part ~= nil then
        local ok, got = pcall(I.classify, part, false)
        if not ok then got = nil end
        -- "X and Y" inside one clause, when both halves are requests of their own
        do
            local a, b = string.match(part, "^(.-)%s+and%s+(.+)$")
            local okA, ia = false, nil
            local okB, ib = false, nil
            if a ~= nil then okA, ia = pcall(I.classify, a, false); okB, ib = pcall(I.classify, b, false) end
            if okA and okB and ia ~= nil and ib ~= nil and ia ~= ib then
                plan[#plan + 1] = { text = a, intent = ia }
                plan[#plan + 1] = { text = b, intent = ib }
            elseif got ~= nil and (#plan == 0 or plan[#plan].intent ~= got) then
                plan[#plan + 1] = { text = part, intent = got }
            elseif got == nil then
                local _, words = string.gsub(part, "%S+", "")
                if words >= 3 then leftover[#leftover + 1] = part end
            end
        end
        end
    end
    -- what the matcher couldn't place ("keep your eyes on that window") goes to the AI as the last step
    if #leftover > 0 and #plan >= 1 then plan[#plan + 1] = { text = table.concat(leftover, ", "), intent = nil } end
    if #plan < 2 then return nil end
    ALifeHealth.note(TAG, #plan .. " requests in one line")
    local Talk = ProjectALife.Talk
    local function ask(step)
        if step.intent == nil then
            if askUnderstand ~= nil and AI.alive() then
                local ok, said, why = pcall(askUnderstand, player, listener, step.text, now())
                if ok then return said, why end
            end
            return nil
        end
        AI.__force = true
        local ok, said, why = pcall(Talk.respond, player, listener, step.text, now(), step.intent)
        AI.__force = false
        if ok then return said, why end
        return nil
    end
    for i = 2, #plan do
        local step = plan[i]
        Talk.later((i - 1) * AI.CLAUSE_GAP_MS, function()
            if stillThere(player, listener.shell, 20) then ask(step) end
        end)
    end
    return ask(plan[1])
end

local function plusRespond(player, listener, text, nowArg, choiceIntent)
    if listener ~= nil and type(listener.record) == "table" and listener.record.uid then AI.lastTalk[listener.record.uid] = now() end
    if choiceIntent == nil and listener ~= nil and listener.shell ~= nil and type(text) == "string"
            and type(listener.record) == "table" and not (type(listener.record.memory) == "table" and type(listener.record.memory.person) == "table")
            and type(ProjectALife.Talk.later) == "function" then
        local okC, said, why = pcall(compound, player, listener, text, nowArg)
        if okC and said ~= nil then return said, why end
    end
    if choiceIntent == nil and AI.understand and listener ~= nil and listener.shell ~= nil and wantVoice(nil, text) then
        local rec = listener.record
        local plain = type(rec) == "table" and not (type(rec.memory) == "table" and type(rec.memory.person) == "table")
        local visit = ProjectALife.SafehouseVisit
        if plain and visit ~= nil and type(visit.doorPeer) == "function" then
            local okD, peer = pcall(visit.doorPeer, player, rec.uid)
            if okD and peer ~= nil then plain = false end
        end
        if plain then
            local I = ProjectALife.TalkIntents
            local okI, got = pcall(I.classify, text, false)
            if okI and got ~= nil and ALifeStory ~= nil and ALifeStory.PERSONAL[got] then
                -- about them: answered from their own story, not a stock line
                local okA, said, why = pcall(askUnderstand, player, listener, text, nowArg, true)
                if okA and said ~= nil then
                    local job = nil
                    for _, j in pairs(pending) do if j.kind == "understand" and j.text == text and j.asked == nil then job = j end end
                    if job ~= nil then job.asked = got end
                    return said, why
                end
            end
            -- the matcher only guessed (word overlap): let the AI decide what you meant
            if okI and got ~= nil and ALifeNPCOverhaul ~= nil and ALifeNPCOverhaul.lastHow == "fuzzy" then
                local okA, said, why = pcall(askUnderstand, player, listener, text, nowArg)
                if okA and said ~= nil then return said, why end
            end
            if okI and got == nil then
                local okA, said, why = pcall(askUnderstand, player, listener, text, nowArg)
                if okA and said ~= nil then return said, why end
            end
        end
    end
    if not wantVoice(choiceIntent, text) or listener == nil or listener.shell == nil then
        return origRespond(player, listener, text, nowArg, choiceIntent)
    end
    local Speech = ProjectALife.Speech
    local shell = listener.shell
    local held = {}
    -- hold back lines this NPC says while A-Life works out its answer; everyone else speaks normally
    Speech.say = function(s, line, options)
        if s == shell then
            held[#held + 1] = { text = line, options = options }
            return true
        end
        return origSay(s, line, options)
    end
    local ok, said, reason = pcall(origRespond, player, listener, text, nowArg, choiceIntent)
    Speech.say = origSay
    if not ok then
        for i = 1, #held do pcall(origSay, shell, held[i].text, held[i].options) end
        error(said)
    end
    -- only voice simple one-line answers; scripted scenes, menus, gifts etc. play exactly as A-Life wrote them
    local voiceable = #held == 1 and type(held[1].text) == "string"
        and reason ~= "scripted" and reason ~= "gift_select" and reason ~= "busy"
    if not voiceable then
        AI.metrics.skipped = AI.metrics.skipped + 1
        for i = 1, #held do origSay(shell, held[i].text, held[i].options) end
        return said, reason
    end
    local record = listener.record
    local uid = type(record) == "table" and record.uid or nil
    seq = seq + 1
    local id = sessionTag .. "_" .. seq
    local p = profile(record, player)
    local intent = choiceIntent
    if intent == nil then
        local I = ProjectALife.TalkIntents
        local okI, got = pcall(I.classify, text, false)
        if okI then intent = got end
    end
    local h = history[uid] or {}
    local bond, romanceOk = "none", "0"
    pcall(function()
        local B = ALifeBonds
        if B ~= nil then
            bond = B.describe(B.keyOf(player), uid)
            romanceOk = B.canRomance(record) and "1" or "0"
        end
    end)
    local lines = {
        "id=" .. id, "priority=1",
        "name=" .. clean(p.name, 40), "faction=" .. clean(p.faction, 60), "role=" .. clean(p.role, 40),
        "register=" .. clean(p.register, 30), "temperament=" .. clean(p.temperament, 30), "sex=" .. clean(p.sex, 2),
        "voice=" .. clean(p.voice, 120), "stance=" .. clean(p.stance, 20), "mood=" .. clean(p.mood, 40),
        "day=" .. clean(p.day, 6), "hour=" .. clean(p.hour, 4),
        "intent=" .. clean(intent or "", 40), "reason=" .. clean(reason or "", 30),
        "player=" .. clean(text, 300), "gist=" .. clean(held[1].text, 400),
        "history=" .. clean(table.concat(h, " || "), 1200),
        "bond=" .. clean(bond, 160), "romance_ok=" .. romanceOk,
        "situation=" .. clean(situationOf(record, shell, player), 400),
    }
    for _, l in ipairs(storyLines(record, p)) do lines[#lines + 1] = l end
    lines[#lines + 1] = "end=1"
    local okW, wrote = pcall(writeLines, "alifeai_req_" .. id .. ".txt", lines)
    if not okW then wrote = false end
    remember(uid, "Stranger: " .. text)
    if wrote ~= true then
        origSay(shell, held[1].text, held[1].options)
        return said, reason
    end
    AI.metrics.asked = AI.metrics.asked + 1
    pending[id] = { id = id, at = now(), shell = shell, uid = uid, p = p, held = held, record = record, player = player,
        extra = (ALifeStory ~= nil and ALifeStory.get(record) == nil) and 5000 or 0,   -- first talk: their story gets written
        options = held[1].options }
    pendingCount = pendingCount + 1
    return said, reason
end

-- ----------------------------------------------------------- understand ----
-- The phrase matcher didn't place it: ask the AI what you meant (one of A-Life's intents, or NONE for plain talk).
-- An intent goes back through A-Life as if you'd picked it, so the game reacts for real (and it's voiced as usual);
-- NONE gets the AI's own in-character reply. While it thinks, they stop and look at you.
askUnderstand = function(player, listener, text, nowArg, force)
    if not writeCatalog() then return nil end
    local record, shell = listener.record, listener.shell
    local uid = record.uid
    seq = seq + 1
    local id = sessionTag .. "_" .. seq
    local p = profile(record, player)
    local h = history[uid] or {}
    local bond = "none"
    pcall(function() if ALifeBonds ~= nil then bond = ALifeBonds.describe(ALifeBonds.keyOf(player), uid) end end)
    local lines = {
        "id=" .. id, "mode=understand", "priority=1",
        "name=" .. clean(p.name, 40), "faction=" .. clean(p.faction, 60), "role=" .. clean(p.role, 40),
        "register=" .. clean(p.register, 30), "temperament=" .. clean(p.temperament, 30), "sex=" .. clean(p.sex, 2),
        "voice=" .. clean(p.voice, 120), "stance=" .. clean(p.stance, 20), "mood=" .. clean(p.mood, 40),
        "day=" .. clean(p.day, 6), "hour=" .. clean(p.hour, 4),
        "player=" .. clean(text, 300), "history=" .. clean(table.concat(h, " || "), 1200),
        "bond=" .. clean(bond, 160), "situation=" .. clean(situationOf(record, shell, player), 400),
        "force=" .. (force and "none" or ""),
    }
    for _, l in ipairs(storyLines(record, p)) do lines[#lines + 1] = l end
    lines[#lines + 1] = "end=1"
    if not writeLines("alifeai_req_" .. id .. ".txt", lines) then return nil end
    remember(uid, "Stranger: " .. text)
    pcall(function() ProjectALife.Talk.hold(record, shell, player, nowArg or now()) end)
    pending[id] = { id = id, kind = "understand", at = now(), shell = shell, uid = uid, p = p, held = {},
        player = player, listener = listener, text = text, record = record, force = force,
        extra = (ALifeStory ~= nil and ALifeStory.get(record) == nil) and 5000 or 0 }
    pendingCount = pendingCount + 1
    AI.metrics.asked = AI.metrics.asked + 1
    return "...", "thinking"
end

finishUnderstand = function(job, intent, text)
    if job.done then return end
    job.done = true
    pending[job.id] = nil
    pendingCount = pendingCount - 1
    pcall(writeLines, "alifeai_resp_" .. job.id .. ".txt", {})
    if not stillThere(job.player, job.shell, 30) then
        AI.metrics.stale = (AI.metrics.stale or 0) + 1
        return
    end
    local history_ = history[job.uid]
    if history_ ~= nil and #history_ > 0 then table.remove(history_) end   -- respond() will log "Stranger: ..." again
    local Data = ProjectALife.DialogueData
    intent = intent and string.upper(string.gsub(intent, "%s", "")) or nil
    if intent ~= nil and intent ~= "NONE" and Data ~= nil and Data.intentById[intent] ~= nil then
        AI.metrics.understood = AI.metrics.understood + 1
        ALifeHealth.note(TAG, "understood '" .. tostring(job.text) .. "' as " .. intent)
        AI.__force = true
        local ok, err = pcall(ProjectALife.Talk.respond, job.player, job.listener, job.text, now(), intent)
        AI.__force = false
        if not ok then print(TAG .. " understood reply failed: " .. tostring(err)) end
        return
    end
    if intent == "NONE" and text ~= nil and text ~= "" then
        AI.metrics.chatted = AI.metrics.chatted + 1
        remember(job.uid, "Stranger: " .. tostring(job.text))
        local ok, r = pcall(origSay, job.shell, text, { face = job.player })
        if ok and r == true then remember(job.uid, (job.p.name ~= "" and job.p.name or "Them") .. ": " .. text) end
        return
    end
    -- the AI didn't answer in time or made no sense: A-Life's own answer (or its "didn't catch that")
    AI.metrics.missed = AI.metrics.missed + 1
    pcall(origRespond, job.player, job.listener, job.text, now(), job.force and job.asked or nil)
end

-- ------------------------------------------------------------- public ------
-- Other parts of Chat Plus ask the AI for lines through these (NPCs speaking first, overheard talk, radio, haggling).
AI.alive = function() return AI.enabled and helperAlive() end
AI.stillThere = stillThere
AI.profile = profile
AI.situation = situationOf
AI.context = storyLines
AI.remember = remember
AI.say = function(shell, text, options) return pcall(origSay or ProjectALife.Speech.say, shell, text, options) end
AI.history = function(uid) return history[uid] or {} end
AI.clean = clean
-- fields: list of "key=value" lines (without id/end); callback(lines or nil) when the bridge answers ("done=1") or times out
AI.request = function(fields, callback, timeoutMs, priority)
    if not AI.alive() then return false end
    seq = seq + 1
    local id = sessionTag .. "_" .. seq
    local lines = { "id=" .. id, "priority=" .. tostring(priority or 5), "made=" .. tostring(now()) }
    for _, f in ipairs(fields) do lines[#lines + 1] = f end
    lines[#lines + 1] = "end=1"
    if not writeLines("alifeai_req_" .. id .. ".txt", lines) then return false end
    pending[id] = { id = id, kind = "custom", at = now(), callback = callback, timeout = timeoutMs or 8000 }
    pendingCount = pendingCount + 1
    return true
end
AI.lastTalk = AI.lastTalk or {}    -- uid -> ms the player last spoke to them

-- ------------------------------------------------------------- install -----
function AI.install()
    if ALifeMerge and ALifeMerge.skip("respond") then loadConfig(); return true end
    local Talk, Speech = ProjectALife and ProjectALife.Talk, ProjectALife and ProjectALife.Speech
    if Talk == nil or Speech == nil then return false end
    if Talk.__ChatAI_wrapped then return true end
    if type(Talk.respond) ~= "function" or type(Speech.say) ~= "function" then
        print(TAG .. " A-Life Talk API not as expected, AI voice not installed")
        return true
    end
    if type(getFileWriter) ~= "function" or type(getFileReader) ~= "function" then
        print(TAG .. " file API missing, AI voice not installed")
        return true
    end
    Talk.__ChatAI_wrapped = true
    origRespond, origSay = Talk.respond, Speech.say
    Talk.respond = function(player, listener, text, nowArg, choiceIntent)
        if disabled.respond then return origRespond(player, listener, text, nowArg, choiceIntent) end
        local ok, a, b = pcall(plusRespond, player, listener, text, nowArg, choiceIntent)
        if ok then return a, b end
        disabled.respond = true
        Speech.say = origSay
        print(TAG .. " respond failed, AI voice disabled for this session: " .. tostring(a))
        return origRespond(player, listener, text, nowArg, choiceIntent)
    end
    loadConfig()
    print(TAG .. " hooked Talk.respond (timeout " .. tostring(AI.timeoutMs) .. " ms, menu " ..
        tostring(AI.voiceMenu) .. ", helper " .. (helperAlive() and "running" or "not running yet") .. ")")
    return true
end

AI._poll = function() return poll() end

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() AI.install() end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() AI.install() end) end
    if Events.OnTick ~= nil then ALifeHealth.add(Events.OnTick, "ALifeChatAI", onTick) end
end
print(TAG .. " loaded v" .. VERSION)
