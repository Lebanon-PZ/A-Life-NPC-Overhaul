-- A-Life Talk 0.5.2.10 [pt270u]: WHAT THEY SAID TO EACH OTHER. "can we make it so in their interactions too it shows
-- what theyve said to eachother". Every line one NPC says to another NPC - pair chats / ambient talk, chimes and the
-- answers back, banter, grief talk between two mourners, bite confessions and the arguments about a bite, any react
-- line that names who it is said to (react.dlg = { to = uid, kind = ... }) - is noted here, once, for the PAIR:
--   bucket "dlg"    [pairKey] = { { h, f, fn, to, tn, x, k, s, src }, ... }  (newest last; per pair at most 40)
--   bucket "dlgIdx" [uid]     = { [pairKey] = true }                          (the pairs a person has lines in)
-- so a line is saved ONCE (ModData copies tables by value: a list per person would save every line twice) and each
-- person's log is the merge of their pairs, capped at 60 (the oldest line of that person goes first).
-- Only what you could know: heard live (you within dlgCfg.hearTiles of the speaker) = s true; else only with a
-- source (a companion who was there and tells you later, or a source the caller passes) = s false, shown dim as
-- "heard about"; no source -> not noted. Setting: npcDialog.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Dialogue") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Dialogue"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Dialogue") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function shellOf(uid) local pa = PA(); local s = nil; pcall(function() s = pa.Talk.shellFor(tostring(uid)) end); return s end
local function pos(o) if o == nil then return nil end; local x, y = nil, nil; pcall(function() x, y = o:getX(), o:getY() end); return x, y end
local function pkey(a, b) a, b = tostring(a), tostring(b); if a < b then return a .. "|" .. b end return b .. "|" .. a end
local function nameOf(uid)
    local n = nil
    local pa, r = PA(), rec(uid)
    if r and pa and fn(pa.Names, "of") then pcall(function() n = pa.Names.of(r) end) end
    if n == nil then local e = M.bucket and bucket("book")[tostring(uid)]; n = type(e) == "table" and e.name or nil end
    return tostring(n or "someone")
end

M.dlgCfg = { perPerson = 60, perPair = 40, hearTiles = 20, dupLook = 4 }
M.dlgKinds = { talk = "TALK", comfort = "COMFORT", argument = "ARGUMENT", confession = "CONFESSION" }
M.dlgStats = { noted = 0, skipped = 0, dup = 0 }

local HOSTILE = { rival = true, nemesis = true, enemy = true, distrust = true }
-- talk / argument from the tie (or a grief mode -> comfort)
function M.dlgKind(a, b, mode)
    if mode == "grief" then return "comfort" end
    local row = M.pairRow and M.pairRow(a, b, false)
    if row then
        local t = M.pairTypeFor and M.pairTypeFor(row, tostring(a), tostring(b)) or row.t
        if HOSTILE[t] or (tonumber(row.s) or 0) <= -30 then return "argument" end
    end
    return "talk"
end

-- did the player hear it? true / false + who could tell them (a companion near the speaker)
function M.dlgWitness(fromUid, player)
    player = player or ALifeSide.you()
    local sx, sy = pos(shellOf(fromUid))
    if sx == nil then return false, nil end
    local px, py = pos(player)
    local r2 = M.dlgCfg.hearTiles * M.dlgCfg.hearTiles
    if px ~= nil and (px - sx) ^ 2 + (py - sy) ^ 2 <= r2 then return true, nil end
    if M.partyMembers then
        local ok, list = pcall(M.partyMembers, player)
        for _, u in ipairs(ok and list or {}) do
            if u ~= tostring(fromUid) then
                local cx, cy = pos(shellOf(u))
                if cx ~= nil and (cx - sx) ^ 2 + (cy - sy) ^ 2 <= r2 then return false, nameOf(u) end
            end
        end
    end
    return false, nil
end

local function trimPerson(uid)
    local idx = bucket("dlgIdx")[uid]
    if type(idx) ~= "table" then return end
    local map = bucket("dlg")
    while true do
        local n, oldK, oldH = 0, nil, nil
        for k in pairs(idx) do
            local list = map[k]
            if type(list) ~= "table" or #list == 0 then idx[k] = nil
            else
                n = n + #list
                local h = tonumber(list[1].h) or 0
                if oldH == nil or h < oldH or (h == oldH and k < oldK) then oldK, oldH = k, h end
            end
        end
        if n <= M.dlgCfg.perPerson or oldK == nil then return end
        table.remove(map[oldK], 1)
        if #map[oldK] == 0 then map[oldK] = nil; idx[oldK] = nil end
    end
end

-- note one line; opts { seen = bool, src = "name", h = hours, mode }. Returns the entry or nil (why in M.dlgLast)
function M.dlgNote(fromUid, toUid, text, kind, opts)
    opts = opts or {}
    if M.settings.npcDialog == false then return nil end
    if fromUid == nil or toUid == nil or type(text) ~= "string" then return nil end
    local a, b = tostring(fromUid), tostring(toUid)
    if a == b or a == "player" or b == "player" then return nil end
    if M.cleanText then local ok, t = pcall(M.cleanText, text); if ok and type(t) == "string" then text = t end end
    if text == "" then return nil end
    local seen, src = opts.seen, opts.src
    if seen == nil then
        local s2, s3 = M.dlgWitness(a, opts.player)
        seen = s2
        src = src or s3
    end
    if not seen and (src == nil or src == "") then M.dlgStats.skipped = M.dlgStats.skipped + 1; M.dlgLast = "nobody to tell you"; return nil end
    local k = pkey(a, b)
    local map = bucket("dlg")
    local list = map[k]
    if type(list) ~= "table" then list = {}; map[k] = list end
    for i = #list, math.max(1, #list - M.dlgCfg.dupLook + 1), -1 do
        if list[i].x == text and list[i].f == a then M.dlgStats.dup = M.dlgStats.dup + 1; M.dlgLast = "dup"; return nil end
    end
    local e = { h = tonumber(opts.h) or hours(), f = a, fn = nameOf(a), to = b, tn = nameOf(b), x = text,
        k = M.dlgKinds[kind or ""] and kind or M.dlgKind(a, b, opts.mode), s = seen and true or false, src = (not seen) and src or nil }
    list[#list + 1] = e
    while #list > M.dlgCfg.perPair do table.remove(list, 1) end
    local idx = bucket("dlgIdx")
    for _, u in ipairs({ a, b }) do
        idx[u] = type(idx[u]) == "table" and idx[u] or {}
        idx[u][k] = true
        trimPerson(u)
    end
    M.dlgStats.noted = M.dlgStats.noted + 1
    M.dlgLast = "noted"
    return e
end

-- one person's lines, oldest first; with = nil (all) or the other uid
function M.dlgOf(uid, with)
    uid = tostring(uid)
    local out = {}
    local idx = bucket("dlgIdx")[uid]
    if type(idx) ~= "table" then return out end
    local map = bucket("dlg")
    if with ~= nil then
        local list = map[pkey(uid, with)]
        for _, e in ipairs(type(list) == "table" and list or {}) do out[#out + 1] = e end
        return out
    end
    for k in pairs(idx) do
        local list = map[k]
        if type(list) == "table" then for _, e in ipairs(list) do out[#out + 1] = e end end
    end
    table.sort(out, function(x, y)
        local hx, hy = tonumber(x.h) or 0, tonumber(y.h) or 0
        if hx ~= hy then return hx < hy end
        return tostring(x.f) .. tostring(x.x) < tostring(y.f) .. tostring(y.x)
    end)
    return out
end

-- the people a person has lines with (for the filter list): { { uid, name, n } } most lines first
function M.dlgPeople(uid)
    uid = tostring(uid)
    local out = {}
    local idx = bucket("dlgIdx")[uid]
    local map = bucket("dlg")
    for k in pairs(type(idx) == "table" and idx or {}) do
        local a, b = string.match(k, "^(.-)|(.*)$")
        local other = (a == uid) and b or a
        local list = map[k]
        if other and type(list) == "table" and #list > 0 then
            local last = list[#list]
            out[#out + 1] = { uid = other, name = (last.f == other) and last.fn or last.tn, n = #list }
        end
    end
    table.sort(out, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.uid < y.uid end)
    return out
end

-- hooks (called from Main.lua finishChime / reactFinish; react tables may carry dlg = { to, kind, src })
function M.dlgFromChime(job, text, r)
    if job == nil or job.speakerUid == nil or tostring(job.speakerUid) == "player" then return nil end
    return M.dlgNote(job.uid, job.speakerUid, text, nil, { mode = job.mode, player = job.player })
end
function M.dlgFromReact(p, text)
    local d = type(p) == "table" and type(p.react) == "table" and p.react.dlg or nil
    if type(d) ~= "table" or d.to == nil then return nil end
    return M.dlgNote(p.uid, d.to, text, d.kind, { src = d.src, mode = p.mode, player = p.player })
end

-- A-Life's own scripted banter (ChatterDirector scenes): the scene's lines are already in M.heard (uid + text);
-- each is addressed to the member who spoke before it (else the other member). Once per line (h.dlg).
function M.dlgFromScene(scene)
    if M.settings.npcDialog == false or type(scene) ~= "table" or type(scene.members) ~= "table" or #scene.members < 2 then return 0 end
    local inScene, order = {}, {}
    for _, m in ipairs(scene.members) do if m.uid ~= nil then inScene[tostring(m.uid)] = true; order[#order + 1] = tostring(m.uid) end end
    local now = 0
    pcall(function() now = getTimestampMs() end)
    local lines = {}
    for i = #(M.heard or {}), 1, -1 do
        local h = M.heard[i]
        if now > 0 and h.at ~= nil and now - h.at > 60000 then break end
        if h.uid ~= nil and inScene[tostring(h.uid)] and not h.dlg then table.insert(lines, 1, h) end
    end
    local n, prev = 0, nil
    for _, h in ipairs(lines) do
        h.dlg = true
        local from = tostring(h.uid)
        local to = (prev ~= nil and prev ~= from) and prev or nil
        if to == nil then for _, u in ipairs(order) do if u ~= from then to = u; break end end end
        if to ~= nil and M.dlgNote(from, to, h.text, nil, { mode = "banter" }) then n = n + 1 end
        prev = from
    end
    return n
end
if M.onSceneFinished and not M._dlgSceneWrapped then
    M._dlgSceneWrapped = true
    local baseScene = M.onSceneFinished
    M.onSceneFinished = function(scene)
        pcall(M.dlgFromScene, scene)
        return baseScene(scene)
    end
end

return M
