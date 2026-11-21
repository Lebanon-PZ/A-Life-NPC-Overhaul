-- A-Life NPC Overhaul 0.8.3 step 4: THEY ASK BACK. Now and then the person you talk to asks you something and waits:
--   * the bridge marks a reply that ends with a real question (JSON "ask"); how often = talkAskBack;
--   * they keep facing you for askWaitSec (A-Life's own Talk.hold), the talk window jumps to the Say tab, where the
--     suggestions are now possible answers (step 3);
--   * your next line to them goes out as the answer (req.answering), so they react to what you answered;
--   * no answer in time and you are still with them: one short shrug line (askNudge), then they let it go.
-- A-Life's own "they asked" strip (UI2Answer / UI2TalkAsk) is not used: its answers go to A-Life's server as
-- standoff answers. Client-side prompt state only (MP: moves with the bridge to the host later).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_AskBack") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifeAskBack = ALifeAskBack or {}
local K = ALifeAskBack
local TAG = "[ALifeAskBack]"
K.VERSION = ALifeSide.MOD_VERSION
K.open = K.open or {} -- [uid] = { q, at, untilMs, record, shell, player, nudged }
K.metrics = K.metrics or { asked = 0, answered = 0, ignored = 0, nudged = 0 }
K.DEFAULTS = { talkAskBack = 2, askWaitSec = 30, askNudge = true }
K.NUDGES = { "Guess you don't wanna say.", "Fine. Keep it to yourself.", "...Alright then.", "Not gonna answer that, huh?",
    "Forget I asked." }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function M() return ALifeLLMTalk end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` turns a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end
local function waitMs() return (tonumber(setting("askWaitSec")) or 30) * 1000 end

-- the talk window, if it is open with this uid (A-Life's TalkSurface, as ALifeWindowTalk finds it)
local function windowFor(uid)
    local W = ALifeWindowTalk
    if not fn(W, "window") then return nil end
    local ok, win = pcall(W.window)
    if not ok or win == nil or win.uid == nil or tostring(win.uid) ~= tostring(uid) then return nil end
    return win
end

-- called by Main.lua when a reply to you asks you something
function K.note(record, shell, player, text, now)
    if (tonumber(setting("talkAskBack")) or 0) <= 0 or type(record) ~= "table" or type(text) ~= "string" then return end
    now = now or nowMs()
    local uid = tostring(record.uid)
    K.open[uid] = { q = string.sub(text, 1, 240), at = now, untilMs = now + waitMs(), record = record, shell = shell,
        player = player }
    K.metrics.asked = K.metrics.asked + 1
    -- they wait for you: A-Life's own hold (Talk.hold(record, shell, player, now, ms), read in 1.5.1)
    local talk = type(ProjectALife) == "table" and ProjectALife.Talk or nil
    if fn(talk, "hold") and shell ~= nil then pcall(talk.hold, record, shell, player, now, waitMs()) end
    -- the window shows the Say tab, where the answers are
    local win = windowFor(uid)
    local W = ALifeWindowTalk
    if win ~= nil and win.topic ~= (W and W.TAB) and fn(win, "selectTopic") and fn(W, "tabAllowed") and W.tabAllowed(win) then
        pcall(win.selectTopic, win, { topic = W.TAB })
    end
end

-- your next line to them is the answer
function K.extra(req, player, listener, now)
    req.askBack = math.max(0, math.min(3, tonumber(setting("talkAskBack")) or 0))
    if listener == nil or type(listener.record) ~= "table" or type(req.said) ~= "string" or req.said == "" then return end
    local uid = tostring(listener.record.uid)
    local q = K.open[uid]
    if q == nil then return end
    K.open[uid] = nil
    if now > q.untilMs + 15000 then return end -- long forgotten
    req.answering = { q = q.q, ago = math.floor((now - q.at) / 1000) }
    K.metrics.answered = K.metrics.answered + 1
end

local function near(player, shell, tiles)
    local ok, d2 = pcall(function()
        local dx, dy = player:getX() - shell:getX(), player:getY() - shell:getY()
        return dx * dx + dy * dy
    end)
    return ok and type(d2) == "number" and d2 <= tiles * tiles
end

-- no answer in time: one shrug if you are still with them, then the question is dropped
function K.tick(now)
    now = now or nowMs()
    local done = {}
    for uid, q in pairs(K.open) do
        if now >= q.untilMs then done[#done + 1] = uid end
    end
    for _, uid in ipairs(done) do
        local q = K.open[uid]
        K.open[uid] = nil
        K.metrics.ignored = K.metrics.ignored + 1
        local mm = M()
        if fn(mm, "visitUnanswered") then pcall(mm.visitUnanswered, uid, q.player, q.q) end -- 0.8.3 step 6
        if setting("askNudge") ~= false and q.shell ~= nil and q.player ~= nil
                and (windowFor(uid) ~= nil or near(q.player, q.shell, 5)) then
            local m = M()
            local busy = fn(m, "yields") and m.yields(q.shell, q.record) or false
            if not busy and fn(m, "ownSay") then
                local line = K.NUDGES[(K.metrics.nudged % #K.NUDGES) + 1]
                if pcall(m.ownSay, q.shell, line, { face = q.player }) then K.metrics.nudged = K.metrics.nudged + 1 end
            end
        end
    end
end

-- load time: defaults, save keys, hooks into Main
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "talkAskBack", "askWaitSec", "askNudge" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
        m.noteAsk = function(record, shell, player, text, now) return K.note(record, shell, player, text, now) end
        if type(m.requestExtras) == "table" then table.insert(m.requestExtras, K.extra) end
    end
end

if Events ~= nil and Events.OnTick ~= nil then
    local last = 0
    Events.OnTick.Add(function()
        local now = nowMs()
        if now - last < 500 then return end
        last = now
        local ok, err = pcall(K.tick, now)
        if not ok and not K.tickErr then K.tickErr = true; log("tick error (once): " .. tostring(err)) end
    end)
end
log("ready v" .. K.VERSION .. ": they ask back (level " .. tostring(K.DEFAULTS.talkAskBack) .. ", wait "
    .. tostring(K.DEFAULTS.askWaitSec) .. " s)")
