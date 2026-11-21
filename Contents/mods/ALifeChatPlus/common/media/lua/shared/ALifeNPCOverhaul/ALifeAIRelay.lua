-- A-Life NPC Overhaul pre-1.0 (MP port P2, docs/PLAN-MP.md): EACH PLAYER'S OWN AI, IN MULTIPLAYER.
-- A-Life's NPCs and its Talk.respond live on the server, so the server builds the AI request (it needs the registry).
-- The AI bridge runs on each player's own machine. So:
--   server: ALifeLLMTalk_Main writes a request -> ALifeAIRelay.ask -> "aiAsk" pieces to the talking player
--           (background lines: the nearest player whose AI is on). Main's poll reads ALifeAIRelay.lines() instead of
--           the reply file. No AI on that player = false = A-Life's own line, as before.
--   client: the pieces arrive -> written to the bridge request file exactly as in single player -> the reply file is
--           read -> "aiLine" pieces back. The server takes them only from that player, only for that request id.
--   client: "aiState" (is my AI on) on every change and every mpAIStateSec; older than mpAIStaleSec = off.
-- ALifeCmd caps a string at 300 chars, so a request / reply crosses in pieces of PIECE chars (the network limit for
-- one command table on 42.21 is unverified; pieces keep every command small). Bridge protocol unchanged.
-- One request at a time (Main's queue is serial already); per-player slots can come later.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"
ALifeAIRelay = ALifeAIRelay or {}
local R = ALifeAIRelay
R.VERSION = ALifeSide.MOD_VERSION
R.PIECE = 280
R.MAX_PIECES = 200 -- 56k chars: a request bigger than that is refused (A-Life answers)
R.state = R.state or {}     -- server: key -> { on, at, ver }
R.inbox = R.inbox or {}     -- client: id -> { n, parts, got }
R.metrics = R.metrics or { asked = 0, pieces = 0, answered = 0, refused = 0, noAI = 0, written = 0, sentBack = 0, timedOut = 0 }
local function M() return ALifeLLMTalk end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function nowMs() local ok, v = pcall(getTimestampMs); return ok and type(v) == "number" and v or 0 end
local function setting(k, d) local m = M(); local v = type(m) == "table" and type(m.settings) == "table" and m.settings[k] or nil; if v == nil then return d end; return v end
local function log(msg) print("[ALifeAIRelay] " .. tostring(msg)) end
local function splitLines(text)
    local out = {}
    for line in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
        line = string.gsub(line, "\r$", "")
        out[#out + 1] = line
    end
    while #out > 0 and out[#out] == "" do table.remove(out) end
    return out
end
local function idOf(lines)
    for _, l in ipairs(lines or {}) do
        local v = string.match(l, "^id=(.*)$")
        if v ~= nil then return v end
    end
    return nil
end
R.splitLines, R.idOf = splitLines, idOf
-- send text in pieces: one command per piece { id, i, n, s }
local function pieces(text)
    text = tostring(text or "")
    local n = math.max(1, math.ceil(#text / R.PIECE))
    local out = {}
    for i = 1, n do out[i] = string.sub(text, (i - 1) * R.PIECE + 1, i * R.PIECE) end
    return out
end
R.pieces = pieces
-- gather pieces; returns the whole text once every piece is in
local function gather(box, args)
    if type(args) ~= "table" or type(args.id) ~= "string" or type(args.s) ~= "string" then return nil end
    local i, n = tonumber(args.i), tonumber(args.n)
    if i == nil or n == nil or n < 1 or n > R.MAX_PIECES or i < 1 or i > n or i ~= math.floor(i) then return nil end
    if box.n ~= nil and box.n ~= n then return nil end
    box.n, box.parts = n, box.parts or {}
    if box.parts[i] == nil then box.got = (box.got or 0) + 1 end
    box.parts[i] = args.s
    if box.got < n then return nil end
    return table.concat(box.parts, "", 1, n)
end

-- ------------------------------------------------------------------------------------------------ server
local function stateOf(player, now)
    local k = ALifeSide.keyOf(player)
    local st = k and R.state[k] or nil
    if type(st) ~= "table" or st.on ~= true then return false end
    return (now or nowMs()) - (st.at or -1e12) <= (tonumber(setting("mpAIStaleSec", 90)) or 90) * 1000
end
-- this player's AI is on (nil player = anyone online)
function R.aiOn(player, now)
    if player ~= nil then return stateOf(player, now) end
    for _, p in ipairs(ALifeSide.online()) do if stateOf(p, now) then return true end end
    return false
end
local function shellOf(job)
    local l = type(job) == "table" and job.listener or nil
    return type(l) == "table" and l.shell or nil
end
local function d2(a, b)
    local d = nil
    pcall(function() d = (a:getX() - b:getX()) ^ 2 + (a:getY() - b:getY()) ^ 2 end)
    return d
end
-- who answers: the player in the job (their line, their NPC) if their AI is on; a background line goes to the
-- nearest player whose AI is on (never across the map: the NPC must be someone's neighbour, 60 tiles)
function R.target(job, now)
    if type(job) ~= "table" then return nil end
    if job.player ~= nil then
        if stateOf(job.player, now) then return job.player end
        if job.mode == "reply" or job.mode == "reply-merged" then return nil end -- your line, your AI, or A-Life's
    end
    local shell = shellOf(job)
    local best, bestD = nil, 60 * 60
    for _, p in ipairs(ALifeSide.online()) do
        if stateOf(p, now) then
            local d = shell ~= nil and d2(p, shell) or nil
            if d ~= nil and d <= bestD then best, bestD = p, d end
        end
    end
    return best
end
function R.ask(job, text, id)
    local now = nowMs()
    local target = R.target(job, now)
    if target == nil then R.metrics.noAI = R.metrics.noAI + 1; return false end
    local list = pieces(text)
    if #list > R.MAX_PIECES then R.metrics.refused = R.metrics.refused + 1; log("request too big (" .. #tostring(text) .. " chars), A-Life answers"); return false end
    id = tostring(id or "")
    R.pend = { id = id, key = ALifeSide.keyOf(target), at = now, box = {} }
    R.reply = nil
    for i, s in ipairs(list) do
        ALifeCmd.reply(target, "aiAsk", { id = id, i = i, n = #list, s = s })
    end
    R.metrics.asked = R.metrics.asked + 1
    R.metrics.pieces = R.metrics.pieces + #list
    return true
end
-- Main's poll: the last whole reply (same as reading the reply file: Main skips ids it has seen)
function R.lines() return R.reply end
function R.onLine(player, args)
    local p = R.pend
    if type(p) ~= "table" or type(args) ~= "table" or tostring(args.id) ~= p.id then R.metrics.refused = R.metrics.refused + 1; return false end
    if ALifeSide.keyOf(player) ~= p.key then R.metrics.refused = R.metrics.refused + 1; return false end
    local text = gather(p.box, args)
    if text == nil then return true end
    local lines = splitLines(text)
    if idOf(lines) ~= p.id then R.metrics.refused = R.metrics.refused + 1; p.box = {}; return false end
    R.reply = lines
    R.metrics.answered = R.metrics.answered + 1
    return true
end
function R.onState(player, args)
    local k = ALifeSide.keyOf(player)
    if k == nil or type(args) ~= "table" then return false end
    R.state[k] = { on = args.on == true, at = nowMs(), ver = type(args.ver) == "string" and args.ver or nil }
    return true
end

-- ------------------------------------------------------------------------------------------------ client
local function me() return ALifeSide.localPlayer() end
local function aiOnHere(now)
    local m = M()
    if type(m) ~= "table" or type(m.settings) ~= "table" or m.settings.enabled == false then return false end
    if not fn(m, "bridgeAlive") then return false end
    local ok, on = pcall(m.bridgeAlive, now)
    return ok and on == true
end
local function sendBack(text, id)
    local p = me()
    if p == nil then return false end
    local list = pieces(text)
    for i, s in ipairs(list) do ALifeCmd.send(p, "aiLine", { id = id, i = i, n = #list, s = s }) end
    R.metrics.sentBack = R.metrics.sentBack + 1
    return true
end
function R.onAsk(args)
    if type(args) ~= "table" or type(args.id) ~= "string" then return false end
    local box = R.inbox[args.id]
    if box == nil then
        R.inbox = {} -- one request at a time: a new id drops what was half in
        box = {}
        R.inbox[args.id] = box
    end
    local text = gather(box, args)
    if text == nil then return true end
    R.inbox[args.id] = nil
    local m = M()
    local now = nowMs()
    if not aiOnHere(now) or not fn(m, "writeFile") then
        sendBack("id=" .. args.id .. "\nfail=1\nwhy=that player's AI is off", args.id)
        return false
    end
    if not m.writeFile(m.REQ_FILE, text) then
        sendBack("id=" .. args.id .. "\nfail=1\nwhy=could not write the request file", args.id)
        return false
    end
    R.waiting = { id = args.id, at = now }
    R.metrics.written = R.metrics.written + 1
    return true
end
-- every tick on an MP client (Main.onTickUI): tell the server about our AI, carry the reply back
function R.clientTick(now)
    now = now or nowMs()
    local m = M()
    local p = me()
    if p == nil or type(m) ~= "table" then return end
    local on = aiOnHere(now)
    local every = (tonumber(setting("mpAIStateSec", 20)) or 20) * 1000
    if on ~= R.sentOn or now - (R.sentAt or -1e12) >= every then
        R.sentOn, R.sentAt = on, now
        ALifeCmd.send(p, "aiState", { on = on, ver = type(m.status) == "table" and m.status.version or nil })
    end
    local w = R.waiting
    if w == nil then return end
    if now - w.at > (tonumber(setting("lateReplyMs", 30000)) or 30000) + 5000 then
        R.waiting = nil
        R.metrics.timedOut = R.metrics.timedOut + 1
        return
    end
    if not fn(m, "readLines") then return end
    local lines = m.readLines(m.REPLY_FILE)
    if lines == nil or idOf(lines) ~= w.id then return end
    R.waiting = nil
    sendBack(table.concat(lines, "\n"), w.id)
end

ALifeCmd.onServer("aiLine", R.onLine)
ALifeCmd.onServer("aiState", R.onState)
ALifeCmd.onClient("aiAsk", R.onAsk)
print("[ALifeAIRelay] ready " .. R.VERSION .. ": in multiplayer each player's own AI bridge answers (server asks, client replies)")
return R
