-- A-Life Talk 0.5.2.2: SAVE TIDY. A lot of our per-person save data is written for every NPC that ever came near you
-- (personality, last seen, emotions, off-screen life, outfits, wounds, pair bonds, rumours ...). A-Life itself deletes
-- dead records (it keeps the newest 256) and removes people its squads let go - but our rows for them stayed in the
-- save forever, and several timers walk all of them (off-screen lives, rumours, opinion drift). On a long game that
-- grew the save and the cost of those loops without end.
-- Once per in-game day this drops rows of people who are GONE: no A-Life record any more, not in your people book,
-- not in your party / base / favourites / keep list / grudges / romance, not seen by you for 14 days. Anyone A-Life
-- still knows (alive, dormant, dead-but-kept) and anyone you know is never touched. Also bounded: the dead people's
-- clothes list (newest 60) and the final-deaths list (entries of long-gone people after 30 days once it has 300+).
-- Setting: storeTidy (default true). Console: "[ALifeTalkLLM] tidy: ..." once per run.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Tidy") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Tidy"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Tidy") end end

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end

if M.settings.storeTidy == nil then M.settings.storeTidy = true end
if M.settings.cleanMarkup == nil then M.settings.cleanMarkup = true end   -- 0.5.2.3 (Main.lua)
if M.settings.reshowDedupe == nil then M.settings.reshowDedupe = true end -- 0.5.2.3 (Main.lua)
if M.settings.yieldBusy == nil then M.settings.yieldBusy = true end       -- 0.8.2.1 (Main.lua)
if M.settings.speechOnce == nil then M.settings.speechOnce = true end     -- 0.5.2.4 (Main.lua)
if M.settings.hookOnce == nil then M.settings.hookOnce = true end         -- 0.5.2.4 (Main.lua)
if M.settings.stopReAdders == nil then M.settings.stopReAdders = true end -- 0.5.2.4 (Main.lua)
if M.settings.fastReplyPoll == nil then M.settings.fastReplyPoll = true end -- 0.5.2.5 (Main.lua)
if M.settings.replyFirst == nil then M.settings.replyFirst = true end       -- 0.5.2.5 (Main.lua)
if M.settings.preemptStock == nil then M.settings.preemptStock = true end   -- 0.5.2.5 (Main.lua)
if M.settings.orderRule == nil then M.settings.orderRule = true end         -- 0.5.2.5 (Main.lua)
for _, k in ipairs({ "offDeath", "deathMerge", "toldDeath", "deathFacts", "bridgeVersionWarn" }) do -- 0.5.2.6 (OffDeath.lua, Main.lua)
    if M.settings[k] == nil then M.settings[k] = true end
end
for _, k in ipairs({ "jeemAware", "baseRepair", "partyWordsStrict" }) do -- 0.5.2.9 [pt266u] (Settlers.lua / Party.lua)
    if M.settings[k] == nil then M.settings[k] = true end
end
for _, k in ipairs({ "likesSaidOnly", "talkThread" }) do -- 0.5.2.8 [pt265u] (Bond.lua / Thread.lua)
    if M.settings[k] == nil then M.settings[k] = true end
end
for _, k in ipairs({ "uiFixedSize", "fixApology", "uiFancy", "uiWrap", "partnerLossTrauma", "lossTalk" }) do -- 0.5.2.7 (UIBond.lua / UI.lua / UIPage.lua / Bond.lua / UIStyle2)
    if M.settings[k] == nil then M.settings[k] = true end
end
for _, k in ipairs({ "sharedPast", "biteCore", "biteSpread", "uiWeb", "npcDialog" }) do -- 0.5.2.10 [pt270u] (Together / Bite / UIWeb / Dialogue)
    if M.settings[k] == nil then M.settings[k] = true end
end
if type(M.fileKeys) == "table" then
    for _, key in ipairs({ "sharedPast", "biteCore", "biteSpread", "uiWeb", "npcDialog", "jeemAware", "baseRepair", "partyWordsStrict", "likesSaidOnly", "talkThread", "uiFixedSize", "fixApology", "uiFancy", "uiWrap", "partnerLossTrauma", "lossTalk", "storeTidy", "cleanMarkup", "reshowDedupe", "yieldBusy", "speechOnce", "speechOnceMs", "hookOnce", "stopReAdders",
        "offDeath", "deathMerge", "toldDeath", "deathFacts", "bridgeVersionWarn" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end

M.tidyCfg = {
    everyH = 24, firstDelayMs = 300000, checkMs = 60000, seenKeepH = 24 * 14,
    -- uid -> row maps written automatically for NPCs near you
    perUid = { "persona", "seen", "outfitSeen", "emo", "life", "ptie", "grief", "wdet", "wown", "trauma", "drunk",
        "lifeTold", "topicsBy", "repMet", "ilog", "dlgIdx" }, -- dlgIdx: 0.5.2.10 (Dialogue.lua)
    -- pair key "a|b" maps
    perPair = { "pairs", "topicsPair", "dlg" }, -- dlg: 0.5.2.10 (Dialogue.lua)
    -- buckets whose people are protected (any uid string inside, keys or values)
    protect = { "book", "party", "settlers", "favorites", "keepMarks", "nemesis", "romance", "promises", "betrayal",
        "gifts", "playerNemesis", "keymem", "fakeNames", "npcBases", "deaths" },
    deadWearKeep = 60, finalKeepH = 24 * 30, finalMin = 300,
}
M.tidyStats = { runs = 0, dropped = 0, last = nil }

local function looksUid(s) return type(s) == "string" and string.find(s, ":", 1, true) ~= nil and string.len(s) < 80 end
local function collect(t, out, depth)
    if depth > 4 or type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if looksUid(k) then out[k] = true end
        if looksUid(v) then out[v] = true
        elseif type(v) == "table" then collect(v, out, depth + 1) end
    end
end

-- A-Life's registry, read-only existence check (peek = no deep copy); nil = not usable now
local function registry()
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    if not (fn(reg, "peek") or fn(reg, "read")) then return nil end
    -- never tidy against an empty / not yet restored registry (that would look like "everyone is gone")
    local n = 0
    if fn(reg, "each") then pcall(reg.each, function() n = n + 1; return n >= 1 end)
    elseif type(reg.order) == "table" then n = #reg.order end
    if n == 0 then return nil end
    return reg
end
local function exists(reg, uid)
    local ok, r = pcall(fn(reg, "peek") and reg.peek or reg.read, tostring(uid))
    return ok and r ~= nil
end

function M.tidyRun(force)
    if M.settings.storeTidy == false and not force then return nil end
    local reg = registry()
    if reg == nil then return nil end
    local h = hours()
    local cfg = M.tidyCfg
    local keep = {}
    for _, b in ipairs(cfg.protect) do pcall(collect, bucket(b), keep, 1) end
    pcall(function() local P = M.patch and M.patch(); if P and fn(P, "store") then local pd = P.store(); collect(pd.companions, keep, 1); collect(pd.nemesis, keep, 1); collect(pd.ordered, keep, 1); collect(pd.shelter, keep, 1) end end)
    local seen = bucket("seen")
    local verdict = {}
    local function gone(uid)
        uid = tostring(uid)
        local v = verdict[uid]
        if v ~= nil then return v end
        v = true
        if keep[uid] or exists(reg, uid) then v = false
        else
            local s = seen[uid]
            if type(s) == "table" and h - (tonumber(s.h) or -1e9) < cfg.seenKeepH then v = false end
            if v and M.isKnownPerson then local ok, k = pcall(M.isKnownPerson, uid, nil); if ok and k then v = false end end
        end
        verdict[uid] = v
        return v
    end
    local dropped, by = 0, {}
    for _, name in ipairs(cfg.perUid) do
        local map = bucket(name)
        local drop = {}
        for uid in pairs(map) do if type(uid) == "string" and gone(uid) then drop[#drop + 1] = uid end end
        for _, uid in ipairs(drop) do map[uid] = nil end
        if #drop > 0 then by[#by + 1] = name .. " " .. #drop; dropped = dropped + #drop end
    end
    for _, name in ipairs(cfg.perPair) do
        local map = bucket(name)
        local drop = {}
        for key in pairs(map) do
            if type(key) == "string" then
                local a, b = string.match(key, "^(.-)|(.+)$")
                if a and b and (gone(a) or gone(b)) then drop[#drop + 1] = key end
            end
        end
        for _, key in ipairs(drop) do map[key] = nil end
        if #drop > 0 then by[#by + 1] = name .. " " .. #drop; dropped = dropped + #drop end
    end
    -- rumours: who knows them
    local rn = 0
    for _, r in ipairs(bucket("rumors")) do
        if type(r) == "table" and type(r.known) == "table" then
            local drop = {}
            for uid in pairs(r.known) do if gone(uid) then drop[#drop + 1] = uid end end
            for _, uid in ipairs(drop) do r.known[uid] = nil end
            rn = rn + #drop
        end
    end
    if rn > 0 then by[#by + 1] = "rumour listeners " .. rn; dropped = dropped + rn end
    -- dead people's clothes: newest few only
    local dw = bucket("deadWear")
    local rows = {}
    for uid, d in pairs(dw) do rows[#rows + 1] = { uid = uid, at = type(d) == "table" and tonumber(d.at) or -1e9 } end
    if #rows > cfg.deadWearKeep then
        table.sort(rows, function(x, y) if x.at ~= y.at then return x.at > y.at end; return tostring(x.uid) < tostring(y.uid) end)
        for i = cfg.deadWearKeep + 1, #rows do dw[rows[i].uid] = nil end
        by[#by + 1] = "dead clothes " .. (#rows - cfg.deadWearKeep); dropped = dropped + #rows - cfg.deadWearKeep
    end
    -- final deaths: A-Life no longer has the record (it can never come back under that uid), long ago, not someone you know
    pcall(function()
        local fd = M.finalStore and M.finalStore() or nil
        if type(fd) ~= "table" or type(fd.uids) ~= "table" then return end
        local n, old = 0, {}
        for uid, e in pairs(fd.uids) do
            n = n + 1
            local eh = type(e) == "table" and tonumber(e.h) or nil
            if eh ~= nil and h - eh >= cfg.finalKeepH and not keep[tostring(uid)] and not exists(reg, uid) then old[#old + 1] = uid end
        end
        if n >= cfg.finalMin and #old > 0 then
            for _, uid in ipairs(old) do fd.uids[uid] = nil end
            by[#by + 1] = "final-death entries " .. #old; dropped = dropped + #old
        end
    end)
    M.tidyStats.runs = M.tidyStats.runs + 1
    M.tidyStats.dropped = M.tidyStats.dropped + dropped
    M.tidyStats.last = by
    local st = bucket("tidy")
    st.h = h
    M.log("tidy: " .. (dropped > 0 and ("dropped " .. dropped .. " saved rows of people who are gone (" .. table.concat(by, ", ") .. ")")
        or "nothing to drop") .. "; people you know are never touched")
    return dropped, by
end

if type(Events) == "table" and Events.OnTick then
    local startAt, lastCheck = nil, -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Tidy", function()
        local now = M.nowMs()
        if startAt == nil then startAt = now end
        if now - lastCheck < M.tidyCfg.checkMs or now - startAt < M.tidyCfg.firstDelayMs then return end
        lastCheck = now
        if M.settings.storeTidy == false then return end
        local st = bucket("tidy")
        if hours() - (tonumber(st.h) or -1e9) < M.tidyCfg.everyH then return end
        local ok, e = pcall(M.tidyRun)
        if not ok then M.log("tidy error: " .. tostring(e)); st.h = hours() end
    end)
end
