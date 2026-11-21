-- A-Life NPC Overhaul 0.7.9: THE RADIO, AND ASK ABOUT KNOX (hook in, never replace).
--   * THE FIELD BAND CARRIES THE REAL WORLD: A-Life 1.5's Field Band chatter now also carries what really happened
--     (the same events this mod's radio news is made from: helicopters down, fights, fires, wrecks, deaths), told by
--     groups you've raised on the radio by name, and now and then a garbled exchange of Louisville National Guard
--     call signs while they still have something that flies.
--   * ROADMAP, ASK ABOUT KNOX: ask anyone what really happened in Knox County and you get their own theory (every
--     person has one, from their life story). One theory is the truth in every world, and the few who hold it don't
--     sound like they're guessing. With the AI on, it answers from their theory; without it, they say it themselves.
-- Every hook wraps the original and returns its result; a hook that errors logs one line and switches itself off.
-- Setting: "radioKnox" (on by default).
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeRadioKnox") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

ALifeRadioKnox = ALifeRadioKnox or {}
local L = ALifeRadioKnox
local TAG = "[ALifeRadioKnox]"
L.VERSION = ALifeSide.MOD_VERSION
L.cfg = { worldShare = 0.35, newsH = 48, newsLast = 8, guardShare = 0.25, askGapH = 24, askWindowMs = 8000 }
L.REPLIES = { "Copy. Staying clear of that.", "Heard it too. Keep your heads down.", "Roger. Anybody hurt?", "Copy that. Thanks for the word.",
    "Understood. Don't go poking around there.", "Yeah. We saw the smoke." }
L.GUARD = {
    { { "Bird One", "Louisville, Bird One, fuel state three-quarters, starting the river loop" }, { "Louisville", "Bird One, Louisville, copy, eyes on the bridges" } },
    { { "Louisville", "All Guard units, curfew in effect, report contacts only" }, { "Gate Two", "Gate Two copies, quiet out here" } },
    { { "Bird Two", "Louisville, Bird Two, smoke to the south, going to look" }, { "Louisville", "Negative, Bird Two. Fuel's short. Come home." } },
    { { "Louisville", "Bird One, say again, you're breaking up" }, { "Bird One", "...static... two hundred, maybe more, headed... static..." } },
}
L.KNOX_SAY = { "If you ask me? %s.", "%s. That's what I think, anyway.", "Honestly? %s.", "You want my opinion? %s." }
L.KNOX_TRUE = { " And I'm not guessing. I saw things I wasn't supposed to.", " I'd stake my life on it. I was there when it started.",
    " Don't laugh. I know what I saw." }
L.off, L.hooked = L.off or {}, L.hooked or {}
L.metrics = L.metrics or { worldRows = 0, guardRows = 0, knoxAsked = 0, knoxTrue = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function M() return ALifeLLMTalk end
local function cap(s) s = tostring(s or ""); return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2) end

function L.enabled()
    local m = M()
    return not (type(m) == "table" and type(m.settings) == "table" and m.settings.radioKnox == false)
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
local function wrap(tbl, name, hookName, make)
    if L.hooked[hookName] then return true end
    if not fn(tbl, name) then return false end
    if tbl[name .. "__RadioKnox"] then L.hooked[hookName] = true; return true end
    local orig = tbl[name]
    tbl[name] = make(orig)
    tbl[name .. "__RadioKnox"] = orig
    L.hooked[hookName] = true
    return true
end

----------------------------------------------------------------------------------------------------------------
-- 1. the Field Band carries the real world
----------------------------------------------------------------------------------------------------------------
-- groups you've raised on the radio (they talk on the band by name)
function L.knownGroups()
    local m = M()
    local out = {}
    if not fn(m, "nbActive") then return out end
    for _, b in ipairs(m.nbActive() or {}) do
        if type(b) == "table" and b.radioKnown and not b.airport and type(b.name) == "string" then out[#out + 1] = b.name end
    end
    table.sort(out)
    return out
end
function L.newsEvents()
    local m = M()
    if not fn(m, "store") then return {} end
    local ok, data = pcall(m.store)
    local n = ok and type(data) == "table" and type(data.news) == "table" and data.news or nil
    local ev = n and type(n.events) == "table" and n.events or {}
    local h, out = hours(), {}
    for i = #ev, math.max(1, #ev - L.cfg.newsLast + 1), -1 do
        local e = ev[i]
        if type(e) == "table" and type(e.x) == "string" and h - (tonumber(e.h) or 0) <= L.cfg.newsH then out[#out + 1] = e end
    end
    return out
end
-- a chatter row made from what really happened (nil when there's nothing to tell)
function L.worldRow(rand, recent)
    local skip = {}
    for _, id in ipairs(recent or {}) do skip[id] = true end
    local m = M()
    -- the Guard, while they still fly
    local S = ALifeSkyPower
    local guardOn = fn(S, "guardActive") and S.guardActive() and fn(S, "fleet") and S.fleet() > 0
    if guardOn and (rand * 7919) % 1 < L.cfg.guardShare then
        local pick = L.GUARD[math.floor((rand * 104729) % #L.GUARD) + 1]
        local id = "ovh_guard_" .. tostring(hash(pick[1][2]) % 100000)
        if not skip[id] then
            L.metrics.guardRows = L.metrics.guardRows + 1
            return { id = id, lines = { { name = pick[1][1], text = pick[1][2], color = 3 }, { name = pick[2][1], text = pick[2][2], color = 3 } } }
        end
    end
    -- the news, by groups you know
    local ev = L.newsEvents()
    if #ev == 0 then return nil end
    local e = nil
    for _, x in ipairs(ev) do
        local id = "ovh_news_" .. tostring(hash(x.x) % 1000000)
        if not skip[id] then e = x; e.rowId = id; break end
    end
    if e == nil then return nil end
    local groups = L.knownGroups()
    local teller = #groups > 0 and groups[(hash(e.x) % #groups) + 1] or "Unknown station"
    local other = #groups > 1 and groups[((hash(e.x) + 1) % #groups) + 1] or "Gate"
    if other == teller then other = "Gate" end
    L.metrics.worldRows = L.metrics.worldRows + 1
    return { id = e.rowId, lines = { { name = teller, text = cap(e.x), color = 2 },
        { name = other, text = L.REPLIES[(hash(e.x .. "r") % #L.REPLIES) + 1], color = 1 } } }
end

function L.hookChatter(C)
    return wrap(C, "pick", "chatter", function(orig)
        return function(ctx, rand, recent, ...)
            if L.enabled() and (tonumber(rand) or 1) < L.cfg.worldShare then
                local ok, row = L.guard("chatter", L.worldRow, tonumber(rand) or 0, recent)
                if ok and type(row) == "table" then return row end
            end
            return orig(ctx, rand, recent, ...)
        end
    end)
end

----------------------------------------------------------------------------------------------------------------
-- 2. ask about Knox
----------------------------------------------------------------------------------------------------------------
function L.isKnoxQuestion(text)
    local t = " " .. string.lower(tostring(text or "")) .. " "
    if string.find(t, "knox", 1, true) then
        for _, w in ipairs({ "happen", "what", "why", "start", "cause", "really", "how", "think" }) do
            if string.find(t, w, 1, true) then return true end
        end
        return false
    end
    if string.find(t, "what caused", 1, true) or string.find(t, "how did this start", 1, true) or string.find(t, "how did it start", 1, true)
        or string.find(t, "how did all this start", 1, true) or string.find(t, "where did this come from", 1, true) then return true end
    return false
end
function L.theoryOf(uid)
    local m = M()
    if not fn(m, "lifeFacts") then return nil end
    local ok, f = pcall(m.lifeFacts, uid)
    return ok and type(f) == "table" and f.theory or nil
end
-- the one theory that's true in this world
function L.truth()
    local m = M()
    local pool = type(m) == "table" and type(m.lifePools) == "table" and m.lifePools.theory or nil
    if type(pool) ~= "table" or #pool == 0 then return nil end
    local wid = fn(m, "worldId") and m.worldId() or "world"
    return pool[(hash(tostring(wid) .. "#knox") % #pool) + 1]
end
function L.answerFor(uid)
    local theory = L.theoryOf(uid)
    if theory == nil then return nil end
    local line = string.format(L.KNOX_SAY[(hash(uid .. "#k") % #L.KNOX_SAY) + 1], cap(theory))
    local right = theory == L.truth()
    if right then line = line .. L.KNOX_TRUE[(hash(uid .. "#t") % #L.KNOX_TRUE) + 1] end
    return line, theory, right
end
function L.asked()
    local m = M()
    if not fn(m, "bucket") then return {} end
    local ok, b = pcall(m.bucket, "knoxAsked")
    return ok and type(b) == "table" and b or {}
end
function L.onWords(player, text, loud, hearers)
    if not L.enabled() or not L.isKnoxQuestion(text) or type(hearers) ~= "table" then return end
    local l = hearers[1]
    local rec = type(l) == "table" and l.record or nil
    if type(rec) ~= "table" or rec.uid == nil then return end
    local uid = tostring(rec.uid)
    local line, theory, right = L.answerFor(uid)
    if line == nil then return end
    L.knoxLast = { uid = uid, at = nowMs(), theory = theory, right = right }
    L.metrics.knoxAsked = L.metrics.knoxAsked + 1
    if right then L.metrics.knoxTrue = L.metrics.knoxTrue + 1 end
    local m = M()
    local asked = L.asked()
    local h = hours()
    local first = asked[uid] == nil
    if first and fn(m, "keyMem") then pcall(m.keyMem, uid, "knox", "Told the newcomer what I think happened in Knox: " .. theory) end
    -- with the AI up, it answers (from their theory, see the request extra); without it, they say it themselves
    local aiUp = fn(m, "bridgeAlive") and m.bridgeAlive(nowMs()) == true
    if not aiUp and h - (tonumber(asked[uid]) or -1e9) >= L.cfg.askGapH and fn(m, "say") and l.shell ~= nil then
        pcall(m.say, l.shell, player, line, { record = rec })
    end
    asked[uid] = h
end
function L.requestExtra(req, player, listener, now)
    local k = L.knoxLast
    if not L.enabled() or type(k) ~= "table" or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    if tostring(listener.record.uid) ~= k.uid or (tonumber(now) or nowMs()) - k.at > L.cfg.askWindowMs then return end
    req.topic = { label = "what really happened in Knox County", key = "knox",
        fact = "you think " .. k.theory .. (k.right and "; and you're not guessing, you saw proof with your own eyes" or "; it's a guess, but you believe it") }
end

----------------------------------------------------------------------------------------------------------------
-- install
----------------------------------------------------------------------------------------------------------------
L.HOOKS = { "chatter", "words", "extra" }
function L.install()
    local m, pa = M(), PA()
    if type(m) == "table" and type(m.settings) == "table" and m.settings.radioKnox == nil then m.settings.radioKnox = true end
    if pa ~= nil and type(pa.RadioChatter) == "table" then L.hookChatter(pa.RadioChatter) end
    if type(m) == "table" and type(m.playerWordHooks) == "table" and not L.hooked.words then
        table.insert(m.playerWordHooks, function(player, text, loud, hearers) L.guard("words", L.onWords, player, text, loud, hearers) end)
        L.hooked.words = true
    end
    if type(m) == "table" and type(m.requestExtras) == "table" and not L.hooked.extra then
        table.insert(m.requestExtras, function(req, player, listener, now) L.guard("extra", L.requestExtra, req, player, listener, now) end)
        L.hooked.extra = true
    end
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
        log("ready v" .. L.VERSION .. ": " .. n .. "/" .. #L.HOOKS .. " hooks" .. (#missing > 0 and ("; missing: " .. table.concat(missing, ", ")) or ""))
        return true
    end
    return false
end
if Events ~= nil and Events.OnGameStart ~= nil then
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
print(TAG .. " loaded v" .. L.VERSION)
