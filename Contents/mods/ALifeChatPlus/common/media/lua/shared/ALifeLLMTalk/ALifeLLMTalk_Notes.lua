-- A-Life Talk 0.5.1: NOTES & GRAFFITI: readable notes left at camps (vanilla Base.SheetPaper2 with a page, the same recipe A-Life's own
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Notes") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Notes"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Notes") end end -- 0.5.1.6 perf label
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
    ALifeHealth.tickAdd("ALifeLLMTalk_Notes", function()
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
-- safehouse letters use: setName + setCustomName + addPage + setLockedBy), written by the AI with a canned fallback.
setting("notes", true)
M.notesCfg = { item = "Base.SheetPaper2", lockedBy = "alifetalk_note", gapH = 12, maxPerDay = 3 }
M.noteTemplates = {
    warning = { title = "KEEP OUT", body = { "This place is taken. Turn around or get shot. - {g}", "We see you. Walk away. - {g}" } },
    goodbye = { title = "Note", body = { "{to} - I couldn't stay. I'm sorry. Don't come looking. - {n}", "If you find this, {to}, I love you. Always did. - {n}" } },
    moved = { title = "Note", body = { "Went north to {place}. Find me. - {n}", "Moved on. Too many of them here. Heading for {place}. - {n}" } },
    lost = { title = "Note", body = { "{n} died here. Bitten. We buried what we could.", "RIP {n}. Good friend. Bad luck." } },
}
local function placeFor(seed)
    local places = { "Louisville", "the river", "the farms past Rosewood", "Fort Knox", "the lake", "West Point" }
    return pick(places, seed)
end
function M.noteText(kind, n, to, g, seed)
    local t = M.noteTemplates[kind] or M.noteTemplates.moved
    local body = pick(t.body, seed)
    body = string.gsub(body, "{n}", n or "a friend"); body = string.gsub(body, "{to}", to or "whoever reads this")
    body = string.gsub(body, "{g}", g or "the people here"); body = string.gsub(body, "{place}", placeFor(seed))
    return t.title, body
end
-- drop a readable note on a square (every call guarded); returns the item or nil
function M.dropNote(x, y, z, title, body, meta)
    if M.settings.notes == false or type(instanceItem) ~= "function" then return nil end
    local item = nil
    pcall(function() item = instanceItem(M.notesCfg.item) end)
    if item == nil then return nil end
    pcall(function() item:setName(title) end)
    pcall(function() item:setCustomName(true) end)
    if type(item.addPage) ~= "function" then return nil end
    pcall(function() item:addPage(1, body) end)
    pcall(function() item:setLockedBy(M.notesCfg.lockedBy) end)
    pcall(function() local md = item:getModData(); md.ALifeTalkNote = meta or true end)
    local sq = nil
    pcall(function() sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) end)
    if sq == nil then return nil end
    local ok = pcall(function() sq:AddWorldInventoryItem(item, 0.5, 0.5, 0) end)
    if not ok then return nil end
    local list = bucket("notes")
    list[#list + 1] = { title = title, body = body, x = math.floor(x), y = math.floor(y), h = hours() }
    while #list > 30 do table.remove(list, 1) end
    log("note left at " .. math.floor(x) .. "," .. math.floor(y) .. ": " .. title)
    return item
end
-- the AI rewrites the body when the bridge answers in time (mode "note"); the canned one is already on the floor
function M.leaveNote(l, kind, opts)
    opts = opts or {}
    local day = math.floor(hours() / 24)
    local cnt = bucket("notesDay")
    if (cnt[day] or 0) >= M.notesCfg.maxPerDay then return nil end
    cnt[day] = (cnt[day] or 0) + 1
    local x, y, z = pos(l.shell)
    if opts.x then x, y, z = opts.x, opts.y, opts.z end
    if x == nil then return nil end
    local uid = tostring(l.record.uid)
    local title, body = M.noteText(kind, firstOf(l.record), opts.to, opts.group, uid .. kind .. day)
    local item = M.dropNote(x, y, z, title, body, { kind = kind, uid = uid })
    local player = ALifeSide.you()
    if item and M.react and player then
        M.react("letter", l, player, { what = "You are writing a " .. kind .. " note to leave here" .. (opts.to and (" for " .. opts.to) or "")
            .. ". Write the note itself (2 short sentences, sign it)", style = "a written note, plain words", maxWords = 30 },
            { key = "letter:" .. uid, keyCooldownMs = 3600000, modeCooldownMs = 60000, onDone = function(job, r)
                if type(r) == "table" and type(r.text) == "string" and #r.text > 8 then
                    pcall(function() item:addPage(1, r.text) end)
                    local list = bucket("notes")
                    if list[#list] then list[#list].body = r.text end
                end
            end })
    end
    return item
end
M.eventModes.note2 = nil
-- triggers: final territory warning (KEEP OUT), a companion / squad leaving the area (moved on), a death by a bite (lost)
function M.notesInstall()
    if M.notesHooked then return end
    M.notesHooked = true
    if type(M.territoryStep) == "function" then
        local orig = M.territoryStep
        M.territoryStep = function(st, l, player, tier, now, ...)
            local before = st and st.step or 0
            local r = orig(st, l, player, tier, now, ...)
            pcall(function() if st and st.step >= 3 and before < 3 and st.bounds then M.leaveNote(l, "warning", { group = (M.factionName and M.factionName(l.record.factionId)) }) end end)
            return r
        end
    end
end
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Notes", function(body, uid, killer)
        pcall(function()
            if M.settings.notes == false then return end
            local x, y, z = pos(body)
            local friend = nil
            for _, l in ipairs(M.nearbyNpcs and x and M.nearbyNpcs(x, y, z, 12, uid) or {}) do
                if M.closeness and select(1, M.closeness(tostring(l.record.uid), tostring(uid))) >= 0.45 then friend = l; break end
            end
            if friend and (hash(tostring(uid) .. "#note") % 3 == 0) then
                local r = rec(uid)
                local text = select(2, M.noteText("lost", r and firstOf(r) or "a friend", nil, nil, tostring(uid)))
                M.dropNote(x + 1, y, z, "Note", text, { kind = "lost", uid = tostring(uid) })
            end
        end)
    end)
end
table.insert(M.requestExtras, function(req, player, listener, now)
    local list = bucket("notes")
    if #list > 0 and hours() - (list[#list].h or 0) < 48 then req.lastNote = { title = list[#list].title, body = string.sub(list[#list].body, 1, 160) } end
end)
-- "letter": written, never spoken - the finish only hands the text to onDone (the note's page)
if type(M.eventModes) == "table" and M.reactRequest then
    M.eventModes["letter"] = { request = M.reactRequest, finish = function(p, r) if type(p.onDone) == "function" then pcall(p.onDone, p, r) end end, fallback = function() end }
end
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.notesInstall) end) end
pcall(M.notesInstall)
return M
