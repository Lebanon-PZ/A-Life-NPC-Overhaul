-- A-Life Talk 0.5.1: REPUTATION PRECEDES YOU: titles from what you did (rumor deeds), heard by strangers; first meetings reflect it
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Reputation") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Reputation"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Reputation") end end -- 0.5.1.6 perf label
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Reputation", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("reputation", true)
M.repCfg = { famousAt = 3, firstMeetCap = 8 }
M.titleRules = {
    { kind = "medic", title = "the medic", w = 3 },
    { kind = "threat", match = "rob", title = "the robber", w = -4 },
    { kind = "threat", title = "the one who pulls guns on people", w = -3 },
    { kind = "kill", title = "the one who shot {v}", w = -5, victim = "killed (.+)$" },
    { kind = "mercy", title = "the one who puts the turned to rest", w = 2 },
    { kind = "attack", title = "the one who starts fights", w = -3 },
    { kind = "quest", title = "the one who gets jobs done", w = 2 },
    { kind = "gift", title = "the one who shares food", w = 2 },
    { kind = "promise", match = "kept", title = "someone who keeps their word", w = 1 },
    { kind = "promise", match = "broke", title = "a liar", w = -2 },
    { kind = "tally", title = "the one who's put down a hundred of the dead", w = 1 },
    { kind = "trespass", title = "the one who barges into camps", w = -2 },
}
-- titles in order of weight (count x |w|); { title, w, n, known = set of uids who heard }
function M.playerTitles(knownBy)
    local acc = {}
    for _, r in ipairs(bucket("rumors")) do
        for _, rule in ipairs(M.titleRules) do
            if r.k == rule.kind and (rule.match == nil or string.find(string.lower(r.t or ""), rule.match, 1, true)) then
                local t = rule.title
                if rule.victim then
                    local v = string.match(tostring(r.t or ""), rule.victim)
                    if v then t = string.gsub(t, "{v}", (string.match(v, "^(%S+)") or v)) else t = string.gsub(t, "{v}", "a man") end
                end
                local heard = knownBy == nil or (type(r.known) == "table" and r.known[tostring(knownBy)] ~= nil)
                if heard then
                    local a = acc[t] or { title = t, w = rule.w, n = 0 }
                    a.n = a.n + 1
                    acc[t] = a
                end
                break
            end
        end
    end
    local out = {}
    for _, a in pairs(acc) do out[#out + 1] = a end
    table.sort(out, function(a, b) if a.n * math.abs(a.w) == b.n * math.abs(b.w) then return a.title < b.title end return a.n * math.abs(a.w) > b.n * math.abs(b.w) end)
    return out
end
-- has this stranger heard of you? (a rumor reached them, or you're famous: several deeds told around)
function M.heardOf(uid)
    local mine = M.playerTitles(uid)
    if #mine > 0 then return mine, "rumor" end
    local all = M.playerTitles(nil)
    local total = 0
    for _, a in ipairs(all) do total = total + a.n end
    if total >= M.repCfg.famousAt and (hash(tostring(uid) .. "#fame") % 100) < math.min(80, total * 10) then return { all[1] }, "fame" end
    return {}, nil
end
-- first meeting (no opinion row yet): opinion starts from the titles (and their faction's memory of you)
function M.firstMeeting(l, player)
    if M.settings.reputation == false or l == nil then return nil end
    local pa = PA()
    local uid = tostring(l.record.uid)
    local met = bucket("repMet")
    if met[uid] then return nil end
    local key = fn(pa.NpcOpinion, "keyOf") and pa.NpcOpinion.keyOf(player) or nil
    if key and fn(pa.NpcOpinion, "rowOf") and pa.NpcOpinion.rowOf(l.record, key) ~= nil then met[uid] = true; return nil end
    met[uid] = true
    local titles, how = M.heardOf(uid)
    local d = 0
    for i, t in ipairs(titles) do if i <= 2 then d = d + t.w * math.min(2, t.n) end end
    -- a rumor they personally heard already moved their opinion (M.learnRumor); only second-hand fame adds a nudge here
    d = how == "fame" and clamp(math.floor(d * 0.5 + 0.5), -M.repCfg.firstMeetCap, M.repCfg.firstMeetCap) or 0
    if d ~= 0 and fn(pa.NpcOpinion, "adjust") then pcall(pa.NpcOpinion.adjust, l.record, player, d, "Heard of you: " .. titles[1].title) end
    if M.factionFirstMeet then pcall(M.factionFirstMeet, l.record, player) end
    if #titles > 0 then
        M.repMet = M.repMet or {}
        M.repMet[uid] = { title = titles[1].title, at = nowMs(), d = d }
        if M.logInteraction then pcall(M.logInteraction, uid, "Had heard of you as " .. titles[1].title, nil, nil, "event") end
        log("reputation: " .. uid .. " has heard of you as " .. titles[1].title .. " (" .. d .. ")")
    end
    return titles[1], d
end
function M.repOnWords(player, text, loud, hearers)
    if hearers and hearers[1] then pcall(M.firstMeeting, hearers[1], player) end
end
table.insert(M.playerWordHooks, 1, M.repOnWords) -- first: before anything else reacts to the line
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.reputation == false then return end
    local uid = tostring(listener.record.uid)
    local titles = M.playerTitles(uid)
    if #titles > 0 then
        req.reputation = { titles = {} }
        for i, t in ipairs(titles) do if i <= 3 then req.reputation.titles[#req.reputation.titles + 1] = t.title end end
        local fm = M.repMet and M.repMet[uid]
        if fm and now - fm.at < 120000 then req.reputation.firstMeet = true end
    end
end)

-- walking up to a stranger who has heard of you: they may say so first ("You're the medic, right?")
M.repLines = {
    good = { "Wait - you're {t}, aren't you?", "Heard about you. {T}. That true?", "Huh. So you're {t}." },
    bad = { "I know who you are. {T}. Keep your distance.", "You're {t}. Don't try anything.", "Stay back. I heard what you did." },
}
-- pre-1.0 MP: once per online player (people meeting THAT player); SP: the same single run as before
function M.repTick(now)
    if not M.worldHere() then return end
    if M.repTickCatchUp then M.repTickCatchUp() end -- one check per character, then a flag read
    if M.settings.reputation == false then return end
    M.eachPlayer(M.repTickFor, now)
end
function M.repTickFor(p, now)
    local near, player = nearPlayer(5)
    for i, l in ipairs(near) do
        if i > 2 then break end
        local uid = tostring(l.record.uid)
        if not bucket("repMet")[uid] and idleOk(l, now) then
            local t, d = M.firstMeeting(l, player)
            if t and t.title then
                local pool = t.w < 0 and M.repLines.bad or M.repLines.good
                local line = pick(pool, uid .. t.title)
                local cap = string.upper(string.sub(t.title, 1, 1)) .. string.sub(t.title, 2)
                line = string.gsub(string.gsub(line, "{t}", t.title), "{T}", cap)
                speak(l, player, "reputation", "You meet the newcomer for the first time; you've heard of them as " .. t.title
                    .. ". Say so (react to the reputation)", line, { keyMs = 600000 })
            end
        end
    end
end
regMode("reputation")
everyMs(3000, M.repTick)

-- pre-1.0: A NEW CHARACTER IS A STRANGER. Our "about you" data had no owner in single player, so after a death the
-- next character inherited every rumor (titles, fame), grudge, betrayal and faction memory, and old rumors kept
-- spreading and lowering opinions of the new you. A-Life already decides "new character" (CharacterReset.check on
-- OnCreatePlayer: dead, or a fresh char id) and wipes its own opinions in CharacterReset.forget(key, player); we hook
-- that same call, so A-Life's sandbox option Reputation_ResetOnNewCharacter switches ours too. Setting "repNewLife".
-- Single player: all of it goes. MP server: only that player's rumors (r.pk); the rest is shared world state.
setting("repNewLife", true)
M.repNewLifeBuckets = { "repMet", "factionMet", "factionRep", "factionNews", "betrayal", "playerNemesis" }
M.repNewLifeStats = { lives = 0, rumors = 0 }
function M.repNewLife(key, player)
    if M.settings.repNewLife == false then return false end
    local mp = type(ALifeSide) == "table" and ALifeSide.mpServer()
    local list = bucket("rumors")
    local keep, dropped = {}, 0
    for _, r in ipairs(list) do
        local mine = (r.pk == nil and not mp) or (key ~= nil and r.pk ~= nil and tostring(r.pk) == tostring(key))
        if mine then dropped = dropped + 1 else keep[#keep + 1] = r end
    end
    for i = #list, 1, -1 do list[i] = nil end
    for i, r in ipairs(keep) do list[i] = r end
    if not mp then
        local data = M.store()
        for _, name in ipairs(M.repNewLifeBuckets) do data[name] = {} end
        M.repMet = {}
    end
    M.repNewLifeStats.lives = M.repNewLifeStats.lives + 1
    M.repNewLifeStats.rumors = M.repNewLifeStats.rumors + dropped
    log("reputation: new character (" .. tostring(key) .. "): a stranger again, " .. dropped .. " old rumor(s) dropped")
    return true
end
-- catch-up for saves where the new character came before this fix (A-Life already counts it as "same"): once per
-- character (flag on the character itself), rumors dated before this character was born (world hours - hours
-- survived) are the old one's. Any found, or A-Life's own life counter past 1 = an earlier life: the same reset.
M.repBornSlackH = 1
function M.repCatchUp(player)
    if M.settings.repNewLife == false or player == nil then return false end
    local data = nil
    pcall(function() data = player:getModData() end)
    if type(data) ~= "table" or data.ALifeRepCaught then return false end
    data.ALifeRepCaught = true
    local R = PA().CharacterReset
    if fn(R, "enabled") and R.enabled() == false then return false end
    local survived = nil
    pcall(function() survived = tonumber(player:getHoursSurvived()) end)
    if survived == nil then return false end
    local born = hours() - survived - M.repBornSlackH
    local key = nil
    pcall(function() key = PA().Reputation.playerKey(player) end)
    local mp = type(ALifeSide) == "table" and ALifeSide.mpServer()
    local older = false
    for _, r in ipairs(bucket("rumors")) do
        local mine = (r.pk == nil and not mp) or (key ~= nil and r.pk ~= nil and tostring(r.pk) == tostring(key))
        if mine and tonumber(r.h) ~= nil and r.h < born then older = true; break end
    end
    if not older then
        pcall(function()
            local row = PA().PersonalRep.store().players[tostring(key)]
            if type(row) == "table" and (tonumber(row.life) or 1) > 1 then older = true end
        end)
    end
    if not older then return false end
    -- only the old rumors: deeds of this character (after born) stay
    local list = bucket("rumors")
    local keep = {}
    for _, r in ipairs(list) do
        local mine = (r.pk == nil and not mp) or (key ~= nil and r.pk ~= nil and tostring(r.pk) == tostring(key))
        if not (mine and (tonumber(r.h) or 0) < born) then keep[#keep + 1] = r end
    end
    M.repNewLife(key, player) -- the tables (and all of this player's rumors; the new ones go back below)
    for i = #list, 1, -1 do list[i] = nil end
    for i, r in ipairs(keep) do list[i] = r end
    log("reputation: catch-up for a character made before the fix (born ~" .. math.floor(born) .. "h)")
    return true
end
function M.repTickCatchUp() M.eachPlayer(function(p) pcall(M.repCatchUp, p) end) end
function M.repHookReset()
    local R = PA().CharacterReset
    if not fn(R, "forget") then return false end
    if R._alcpNewLife then return true end
    local inner = R.forget
    R.forget = function(key, player, ...)
        local a, b = inner(key, player, ...)
        local ok, e = pcall(M.repNewLife, key, player)
        if not ok then log("new life error: " .. tostring(e)) end
        return a, b
    end
    R._alcpNewLife = true
    return true
end
pcall(M.repHookReset)
-- A-Life's server files load after shared/: hook again once the world loads (before OnCreatePlayer on a reload)
if type(Events) == "table" and Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(function() pcall(M.repHookReset) end) end
if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local ok, hooked = pcall(M.repHookReset)
        print("[ALifeLLMTalk_Reputation] ready v0.9.5-pre1.0: new character = stranger " .. ((ok and hooked) and "(hooked A-Life CharacterReset)" or "(unverified: A-Life CharacterReset.forget missing, off)"))
    end)
end
return M
