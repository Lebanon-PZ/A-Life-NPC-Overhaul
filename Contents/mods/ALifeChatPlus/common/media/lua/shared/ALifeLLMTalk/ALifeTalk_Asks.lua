-- A-Life NPC Overhaul 0.8.3 step 10: ASKS BECOME THINGS. When someone asks you for something they need (food, water,
-- medicine, ammo), it stays asked:
--   * the bridge marks the line (JSON "want"); they remember it (one open ask per person, kept in the save);
--   * they may bring it up again while you still owe it (the AI hears what they asked for and how long ago);
--   * you hand them that kind of thing (any way: our Give, A-Life's door give / trade watcher, M.onGift) -> it's done:
--     they like you more (askThanks), it's a key memory, and their thank-you line knows you remembered;
--   * you never bring it within askDays: they let it go, a little sour (askForgotCost, 0 = nothing), key memory.
-- No numbers shown; it shows in how they talk to you. Settings: talkWants, askThanks, askDays, askForgotCost.
-- Client-side like the rest of the gift / opinion code (MP: moves to the host with it later).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Asks") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifeAsks = ALifeAsks or {}
local K = ALifeAsks
local TAG = "[ALifeAsks]"
K.VERSION = ALifeSide.MOD_VERSION
K.WANTS = { "food", "water", "medicine", "ammo" }
K.DEFAULTS = { talkWants = true, askThanks = 4, askDays = 2, askForgotCost = 1 }
K.metrics = K.metrics or { asked = 0, brought = 0, forgotten = 0 }
K.justDone = K.justDone or {} -- [uid] = { kind, at } so the thank-you line knows

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function M() return ALifeLLMTalk end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil check: a false setting stays false
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
local function isWant(kind) for _, k in ipairs(K.WANTS) do if k == kind then return true end end return false end

-- the open asks, in the save (falls back to a session table without one)
function K.store()
    local m = M()
    local data = nil
    if fn(m, "store") then pcall(function() data = m.store() end) end
    if type(data) ~= "table" then K.tmp = K.tmp or {}; data = K.tmp end
    data.asks = type(data.asks) == "table" and data.asks or {}
    return data.asks
end
function K.openOf(uid) local a = K.store()[tostring(uid)]; return type(a) == "table" and a or nil end

local function agoWords(h)
    if h < 1 then return "a little while ago" end
    if h < 20 then return math.floor(h + 0.5) .. " hours ago" end
    if h < 36 then return "yesterday" end
    return math.floor(h / 24 + 0.5) .. " days ago"
end

local function opinionAdjust(record, player, delta, why)
    if delta == 0 or record == nil or player == nil then return false end
    local op = PA().NpcOpinion
    if not fn(op, "adjust") then return false end
    return pcall(op.adjust, record, player, delta, why)
end
local function keyMem(uid, kind, text)
    local m = M()
    if fn(m, "keyMem") then pcall(m.keyMem, uid, kind, text) end
end

-- the AI said they asked you for something
function K.note(record, player, kind, text)
    if setting("talkWants") == false or type(record) ~= "table" or record.uid == nil then return false end
    kind = string.lower(tostring(kind or ""))
    if not isWant(kind) then return false end
    local uid = tostring(record.uid)
    local cur = K.openOf(uid)
    if cur ~= nil and cur.k == kind then return false end -- asked again for the same thing: still the one ask
    local pn = 0
    pcall(function() pn = player:getPlayerNum() end)
    K.store()[uid] = { k = kind, h = hours(), t = string.sub(tostring(text or ""), 1, 100), pn = pn,
        pk = ALifeSide.mpServer() and player ~= nil and ALifeSide.keyOf(player) or nil } -- MP: who they asked
    K.metrics.asked = K.metrics.asked + 1
    keyMem(uid, "ask", "They asked you for " .. kind)
    log("asked: " .. uid .. " wants " .. kind)
    return true
end

-- you handed them something: does it answer what they asked for?
function K.onGiven(player, listener, items, opts)
    if setting("talkWants") == false or type(listener) ~= "table" or type(listener.record) ~= "table" or type(items) ~= "table" then return false end
    if type(opts) == "table" and opts.trade then return false end -- a trade is a deal, not a favour
    local uid = tostring(listener.record.uid)
    local a = K.openOf(uid)
    if a == nil then return false end
    local hit = nil
    for _, info in ipairs(items) do
        if type(info) == "table" and info.kind == a.k and not info.rotten then hit = info; break end
    end
    if hit == nil then return false end
    K.store()[uid] = nil
    K.metrics.brought = K.metrics.brought + 1
    local thanks = tonumber(setting("askThanks")) or 0
    opinionAdjust(listener.record, player, thanks, "You brought the " .. a.k .. " they asked for.")
    keyMem(uid, "kindness", "You brought the " .. a.k .. " they asked for")
    K.justDone[uid] = { kind = a.k, at = nowMs() }
    local m = M()
    if fn(m, "feel") then pcall(m.feel, uid, "joy", 0.1) end
    log("brought: " .. uid .. " got the " .. a.k .. " (+" .. thanks .. ")")
    return true
end

-- every game hour: asks nobody answered fade, a little sour
function K.expire()
    local days = tonumber(setting("askDays")) or 2
    local now = hours()
    local store = K.store()
    local due = {}
    for uid, a in pairs(store) do
        if type(a) ~= "table" or now - (tonumber(a.h) or now) > days * 24 then due[#due + 1] = uid end
    end
    for _, uid in ipairs(due) do
        local a = store[uid]
        store[uid] = nil
        if type(a) == "table" then
            K.metrics.forgotten = K.metrics.forgotten + 1
            local cost = tonumber(setting("askForgotCost")) or 0
            local record, player = nil, nil
            pcall(function() record = PA().ActorRegistry.read(uid) end)
            pcall(function() player = getSpecificPlayer(tonumber(a.pn) or 0) end)
            if ALifeSide.mpServer() then player = a.pk and ALifeSide.byKey(a.pk) or nil end -- MP: that player (offline: no opinion change)
            if cost > 0 then opinionAdjust(record, player, -cost, "You never brought the " .. tostring(a.k) .. " they asked for.") end
            keyMem(uid, "ask", "You never brought the " .. tostring(a.k) .. " they asked for")
        end
    end
    return #due
end

-- what the AI hears: what they may ask for, what they're still waiting on, and whether a gift is the thing they asked for
function K.extra(req, player, listener, now)
    if setting("talkWants") == false or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local uid = tostring(listener.record.uid)
    local mode = req.mode
    if mode ~= nil and mode ~= "" and mode ~= "reply" then return end
    if type(req.said) ~= "string" or req.said == "" or string.sub(req.said, 1, 1) == "[" then return end -- "[gave you ...]" is a gift
    local a = K.openOf(uid)
    local w = {}
    if a == nil then w.can = K.WANTS else w.open = { kind = a.k, ago = agoWords(hours() - (tonumber(a.h) or hours())) } end
    req.wants = w
end

-- load time: defaults, save keys, hooks
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "talkWants", "askThanks", "askDays", "askForgotCost" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
        m.noteWant = function(record, player, kind, text) return K.note(record, player, kind, text) end
        if type(m.requestExtras) == "table" then table.insert(m.requestExtras, K.extra) end
    end
end

-- wrap M.onGift (Gifts.lua; every way of handing someone something goes through it) once it exists
function K.hook()
    local m = M()
    if K.hooked or not fn(m, "onGift") then return K.hooked == true end
    local orig = m.onGift
    m.onGift = function(player, listener, items, opts)
        if not K.off then
            local ok, err = pcall(K.onGiven, player, listener, items, opts)
            if not ok then K.off = true; log("gift check failed, off for this session: " .. tostring(err)) end
        end
        return orig(player, listener, items, opts)
    end
    -- the thank-you line knows it's what they asked for (gift prompt: req.gift.asked)
    if fn(m, "giftRequest") then
        local origReq = m.giftRequest
        m.giftRequest = function(job, now)
            local req = origReq(job, now)
            pcall(function()
                local d = type(job) == "table" and K.justDone[tostring(job.uid)] or nil
                if req and d ~= nil and nowMs() - d.at < 15000 and type(req.gift) == "table" then req.gift.asked = d.kind end
            end)
            return req
        end
        if type(m.eventModes) == "table" then
            if type(m.eventModes.gift) == "table" then m.eventModes.gift.request = m.giftRequest end
            if type(m.eventModes.note) == "table" then m.eventModes.note.request = m.giftRequest end
        end
    end
    K.hooked = true
    return true
end
pcall(K.hook)

if type(Events) == "table" then
    if Events.OnGameStart ~= nil then
        Events.OnGameStart.Add(function()
            pcall(K.hook)
            log("ready v" .. K.VERSION .. ": asks become things (" .. (K.hooked and "gifts on" or "gifts OFF") .. ", wait "
                .. tostring(setting("askDays")) .. " days)")
        end)
    end
    if Events.EveryHours ~= nil then
        Events.EveryHours.Add(function()
            local ok, err = pcall(K.expire)
            if not ok and not K.expireErr then K.expireErr = true; log("expire error (once): " .. tostring(err)) end
        end)
    end
end
