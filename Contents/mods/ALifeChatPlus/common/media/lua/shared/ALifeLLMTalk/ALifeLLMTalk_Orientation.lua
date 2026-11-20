-- A-Life NPC Overhaul 0.5.1: ORIENTATION IN ROMANCE.
-- Every person has a fixed orientation, rolled once from who they are (stable per person, saved):
--   drawn to the other sex / drawn to the same sex / drawn to both. Shares are sandbox options.
-- It gates romance, it doesn't decide it. Whether it actually happens still takes what it took before (how they feel
-- about you, days together, the kindness that feeds romance) plus, new here:
--   * hardship shared: danger survived together, being patched up, a death you went through together -> it grows faster
--   * personality: warm, kind, romantic people fall easier; cold, paranoid, mean ones slower
--   * NPC couples: two people whose personalities line up are likelier to fall for each other
-- Paths gated: you and an NPC (romanceGate / romanceAsk), NPC couples seeded at first meeting (seedPair) and NPC couples
-- that grow later (bondRetype). Someone who can't be drawn to you just stays a friend, and says so kindly if you ask.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Orientation") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifeOrient]"
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function rec(uid) local pa = PA(); return fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end

local function opt(key, default)
    local sv = type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or nil
    local v = sv and tonumber(sv[key]) or nil
    if v == nil then return default end
    return v
end
M.orientStats = { gatedYou = 0, gatedSeed = 0, gatedGrow = 0, unknownSex = 0 }

-- "f" / "m" / nil: the body you see first, then A-Life's own description; cached once known
function M.sexOf(uid)
    uid = tostring(uid)
    local store = M.bucket("orient")
    local e = store[uid]
    if type(e) == "table" and (e.sex == "f" or e.sex == "m") then return e.sex end
    local sx = nil
    local pa = PA()
    if fn(pa.Talk, "shellFor") then pcall(function() local sh = pa.Talk.shellFor(uid); if sh ~= nil then sx = sh:isFemale() and "f" or "m" end end) end
    if sx == nil and fn(pa.DialogueRoles, "describe") then
        local r = rec(uid)
        if r then
            pcall(function()
                local who = pa.DialogueRoles.describe(r, 0)
                local s = type(who) == "table" and who.sex or nil
                if s == "female" or s == "f" then sx = "f" elseif s == "male" or s == "m" then sx = "m" end
            end)
        end
    end
    if sx then
        e = type(e) == "table" and e or {}
        e.sex = sx
        store[uid] = e
    end
    return sx
end

-- "other" | "same" | "both", fixed for life
function M.orientOf(uid)
    uid = tostring(uid)
    local store = M.bucket("orient")
    local e = type(store[uid]) == "table" and store[uid] or {}
    if e.o == "other" or e.o == "same" or e.o == "both" then return e.o end
    local same = clamp(opt("OrientSame", 7), 0, 100)
    local both = clamp(opt("OrientBoth", 10), 0, 100 - same)
    local roll = hash(uid .. "#orient") % 100
    e.o = (roll < same and "same") or (roll < same + both and "both") or "other"
    store[uid] = e
    return e.o
end

-- could someone (uid) be drawn to a person of sex 'sx'? Unknown sex on either side: don't block.
function M.drawnTo(uid, sx)
    if sx ~= "f" and sx ~= "m" then return true end
    local mine = M.sexOf(uid)
    if mine == nil then M.orientStats.unknownSex = M.orientStats.unknownSex + 1; return true end
    local o = M.orientOf(uid)
    if o == "both" then return true end
    if o == "same" then return mine == sx end
    return mine ~= sx
end
function M.drawnToPlayer(uid, player)
    player = player or ALifeSide.you()
    local sx = nil
    if fn(M, "playerSex") then sx = M.playerSex(player) else pcall(function() sx = player:isFemale() and "f" or "m" end) end
    return M.drawnTo(uid, sx)
end

-- compatibility beyond orientation (0.7 .. 1.6): personality warmth + hardship shared with you
function M.hardshipOf(uid) local e = M.bucket("orient")[tostring(uid)]; return type(e) == "table" and (tonumber(e.hard) or 0) or 0 end
local HARD = { danger = 3, heal = 2, death = 3 }
function M.romanceCompat(uid)
    local c = fn(M, "bondCompat") and M.bondCompat(uid) or 1
    c = c + math.min(0.4, M.hardshipOf(uid) / 50)
    return clamp(c, 0.7, 1.6)
end
-- NPC couples: how well two personalities line up (0.5 .. 1.5)
local MATCH = { "kind", "cheerful", "romantic", "disciplined", "brave", "calm", "curious", "devout" }
local CLASH = { { "kind", "mean" }, { "calm", "volatile" }, { "brave", "fearful" }, { "disciplined", "unhinged" } }
function M.pairMatch(a, b)
    local la, lb = {}, {}
    pcall(function() la = M.lens(tostring(a)) end)
    pcall(function() lb = M.lens(tostring(b)) end)
    local s = 1
    for _, k in ipairs(MATCH) do s = s + 0.25 * math.min(tonumber(la[k]) or 0, tonumber(lb[k]) or 0) end
    for _, p in ipairs(CLASH) do
        s = s - 0.3 * (math.min(tonumber(la[p[1]]) or 0, tonumber(lb[p[2]]) or 0) + math.min(tonumber(lb[p[1]]) or 0, tonumber(la[p[2]]) or 0))
    end
    return clamp(s, 0.5, 1.5)
end

-- a couple that can't be: what they become instead
local function downgrade(t) if t == "partner" then return "best friend" end; return "buddy" end
local function pairOk(row, a, b)
    if row == nil then return true end
    if row.t == "partner" then return M.drawnTo(a, M.sexOf(b)) and M.drawnTo(b, M.sexOf(a)) end
    if row.t == "crush" then
        local who = tostring(row.c or a)
        local other = who == tostring(a) and b or a
        return M.drawnTo(who, M.sexOf(other))
    end
    return true
end

M.orientWrapped = M.orientWrapped or {}
function M.orientInstall()
    local W = M.orientWrapped
    if M.settings.romance == false and M.settings.npcLove == false then return end
    -- you and them: the gate reads "not looking" when they can't be drawn to you
    if not W.gate and fn(M, "romanceGate") then
        W.gate = true
        local orig = M.romanceGate
        M.romanceGate = function(uid, ...)
            local rm, needOp = orig(uid, ...)
            if not M.drawnToPlayer(uid) then return 0, needOp end
            return rm, needOp
        end
    end
    if not W.ask and fn(M, "romanceAsk") then
        W.ask = true
        local orig = M.romanceAsk
        M.romanceAsk = function(uid, player, ...)
            if not M.drawnToPlayer(uid, player) then
                M.orientStats.gatedYou = M.orientStats.gatedYou + 1
                local px = fn(M, "playerSex") and M.playerSex(player) or nil
                return false, "you care about them, but you're not drawn to " .. (px == "f" and "women" or (px == "m" and "men" or "them")) .. " that way; let them down gently and say you'd still have their back"
            end
            return orig(uid, player, ...)
        end
    end
    -- romance grows with compatibility (personality + hardship shared)
    if not W.note and fn(M, "romanceNote") then
        W.note = true
        local orig = M.romanceNote
        M.romanceNote = function(uid, pts, why, ...)
            local c = 1
            pcall(function() c = M.romanceCompat(uid) end)
            return orig(uid, (tonumber(pts) or 0) * c, why, ...)
        end
    end
    -- hardship: danger survived together, being patched up, a death gone through together
    if not W.points and fn(M, "bondPoints") then
        W.points = true
        local orig = M.bondPoints
        M.bondPoints = function(uid, pts, why, ...)
            local h = HARD[tostring(why)]
            if h then
                local store = M.bucket("orient")
                local e = type(store[tostring(uid)]) == "table" and store[tostring(uid)] or {}
                e.hard = math.min(40, (tonumber(e.hard) or 0) + h)
                store[tostring(uid)] = e
            end
            return orig(uid, pts, why, ...)
        end
    end
    -- NPC couples seeded at first meeting
    if not W.seed and fn(M, "seedPair") then
        W.seed = true
        local orig = M.seedPair
        M.seedPair = function(ra, rb, key, ...)
            local row = orig(ra, rb, key, ...)
            if type(row) == "table" and type(ra) == "table" and type(rb) == "table" and M.settings.npcLove ~= false then
                if (row.t == "partner" or row.t == "crush") and not pairOk(row, ra.uid, rb.uid) then
                    row.t, row.c = downgrade(row.t), nil
                    M.orientStats.gatedSeed = M.orientStats.gatedSeed + 1
                end
            end
            return row
        end
    end
    -- NPC couples that grow later: blocked when they can't be drawn to each other; slower when personalities clash
    if not W.retype and fn(M, "bondRetype") then
        W.retype = true
        local orig = M.bondRetype
        M.bondRetype = function(row, a, b, why, delta, ...)
            local old, oldC = row and row.t, row and row.c
            local res = orig(row, a, b, why, delta, ...)
            if type(row) == "table" and row.t ~= old and (row.t == "partner" or row.t == "crush") and M.settings.npcLove ~= false then
                local blocked = not pairOk(row, a, b)
                -- clashing personalities: a romantic turn only sometimes sticks (stable per pair and day)
                if not blocked then
                    local m = M.pairMatch(a, b)
                    local day = 0
                    pcall(function() day = math.floor(getGameTime():getWorldAgeHours() / 24) end)
                    if m < 1 and (hash(tostring(a) .. tostring(b) .. day) % 100) >= math.floor(m * 100) then blocked = true end
                end
                if blocked then
                    row.t, row.c = old, oldC
                    M.orientStats.gatedGrow = M.orientStats.gatedGrow + 1
                end
            end
            return res
        end
    end
    log("installed (you: " .. tostring(W.gate and W.ask) .. ", NPC couples: " .. tostring(W.seed) .. "/" .. tostring(W.retype)
        .. ", hardship: " .. tostring(W.points) .. ")")
end

-- AI conversations: they know who they're drawn to (only said when romance comes up)
local function extra(req, player, listener)
    if type(listener) ~= "table" or type(listener.record) ~= "table" or M.settings.romance == false then return end
    local uid = tostring(listener.record.uid)
    local mine = M.sexOf(uid)
    if mine == nil then return end
    local o = M.orientOf(uid)
    local who = (o == "both" and "both men and women") or ((o == "same") == (mine == "f") and "women") or "men"
    req.psyche = type(req.psyche) == "table" and req.psyche or {}
    local note = "If romance ever comes up: you're drawn to " .. who .. "."
    req.psyche.mood = req.psyche.mood and (tostring(req.psyche.mood) .. ". " .. note) or note
end

if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(M.orientInstall)
        if not ok then log("install failed: " .. tostring(err)) end
        if not M._orientExtra and type(M.requestExtras) == "table" then
            table.insert(M.requestExtras, function(req, player, listener) pcall(extra, req, player, listener) end)
            M._orientExtra = true
        end
    end)
end
