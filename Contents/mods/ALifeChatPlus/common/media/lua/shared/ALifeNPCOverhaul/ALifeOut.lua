-- A-Life NPC Overhaul 0.9.5 (MP groundwork, docs/PLAN-MP.md P1): TELLING THE PLAYER, FROM WHEREVER THE LOGIC RUNS (docs/PLAN-MP.md).
-- World logic runs on the server in MP; letters, notes, news and moment cards are shown on a client. Everything a
-- world module says to a player goes through here:
--   ALifeOut.letter(player, text, r, g, b, bad) / note / toast / news(player, kind, text, x, y) / card(player, card)
--   player nil = everyone online (letters, news); a card always names one player.
-- Single player / MP client: the existing calls (ALifeLetter, M.momNote, M.momToast, M.newsNote, M.momCard).
-- Server: ALifeCmd.reply(player, "out", ...). Cards: choices are functions, which can't cross the network, so the
-- server keeps the card by id and sends the labels; the client's pick comes back ("outPick") and the server runs
-- that choice for THAT player (another player's pick is refused). Cards nobody answers expire after outCardTTL hours.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"
ALifeOut = ALifeOut or {}
local O = ALifeOut
O.VERSION = ALifeSide.MOD_VERSION
O.cards = O.cards or {}
O.seq = O.seq or 0
O.CARD_TTL_H = 48
O.DEFAULTS = { outCardTTL = 48 } -- MP: hours a card waits for its player's answer (the client file registers the key)
O.KEYS = { "outCardTTL" }
O.metrics = O.metrics or { sent = 0, shown = 0, cards = 0, picks = 0, refused = 0, expired = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function M() return ALifeLLMTalk end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function remote() return ALifeSide.mpServer() end

-- ---------------------------------------------------------------------------------------------- shown here
function O.show(p)
    if type(p) ~= "table" or type(p.text) ~= "string" or p.text == "" then return false end
    O.metrics.shown = O.metrics.shown + 1
    local m = M()
    if p.k == "radio" then
        local me = ALifeSide.localPlayer()
        if me == nil then return false end
        local shown = pcall(function() me:addLineChatElement(p.text, 0.55, 0.9, 0.55) end)
        if not shown then pcall(function() me:Say(p.text) end) end
        if type(m) == "table" then m.radioLog = m.radioLog or {}; m.radioLog[#m.radioLog + 1] = p.text; while #m.radioLog > 30 do table.remove(m.radioLog, 1) end end
        return true
    end
    if p.k == "mark" then
        if type(m) ~= "table" or tonumber(p.x) == nil or tonumber(p.y) == nil then return false end
        m.jnQueue = m.jnQueue or {}
        m.jnQueue[#m.jnQueue + 1] = { text = p.text, x = tonumber(p.x), y = tonumber(p.y) }
        if fn(m, "jnFlush") then pcall(m.jnFlush) end
        return true
    end
    if p.k == "note" and fn(m, "momNote") then return pcall(m.momNote, p.text, p.r, p.g, p.b) end
    if p.k == "toast" and fn(m, "momToast") then return pcall(m.momToast, p.text, p.r, p.g, p.b) end
    if p.k == "news" and fn(m, "newsNote") then return pcall(m.newsNote, p.cat or "world", p.text, p.x, p.y) end
    if type(ALifeLetter) == "function" then return pcall(ALifeLetter, ALifeSide.localPlayer(), p.text, p.r, p.g, p.b, p.bad == true) end
    return false
end
-- to one player (or everyone online when player is nil)
function O.send(player, p)
    if not remote() then return O.show(p) and 1 or 0 end
    local n = 0
    local list = player ~= nil and { player } or ALifeSide.online()
    for _, t in ipairs(list) do
        if ALifeCmd.reply(t, "out", p) then n = n + 1 end
    end
    O.metrics.sent = O.metrics.sent + n
    return n
end
function O.letter(player, text, r, g, b, bad) return O.send(player, { k = "letter", text = tostring(text or ""), r = r, g = g, b = b, bad = bad == true or nil }) end
function O.note(player, text, r, g, b) return O.send(player, { k = "note", text = tostring(text or ""), r = r, g = g, b = b }) end
function O.toast(player, text, r, g, b) return O.send(player, { k = "toast", text = tostring(text or ""), r = r, g = g, b = b }) end
function O.news(player, cat, text, x, y) return O.send(player, { k = "news", cat = tostring(cat or "world"), text = tostring(text or ""), x = tonumber(x), y = tonumber(y) }) end
-- pre-1.0 (P5): a radio line over that player's head (green, like vanilla radio chatter)
function O.radio(player, text) return O.send(player, { k = "radio", text = tostring(text or "") }) end
-- pre-1.0 (P5): a mark on that player's paper map (the journal's queue on their machine)
function O.mark(player, text, x, y) return O.send(player, { k = "mark", text = tostring(text or ""), x = tonumber(x), y = tonumber(y) }) end

-- ---------------------------------------------------------------------------------------------- cards
local function cLabel(c) if type(c) ~= "table" then return nil end; if c.label ~= nil then return c.label end; return c[1] end
local function cFn(c) if type(c) ~= "table" then return nil end; if type(c.fn) == "function" then return c.fn end; if type(c[2]) == "function" then return c[2] end; return nil end
local function runDefault(card)
    local f = cFn(card.choices[tonumber(card.default) or 1])
    if f then pcall(f) end
end
function O.card(player, card)
    if type(card) ~= "table" or type(card.choices) ~= "table" or #card.choices == 0 then return false end
    O.metrics.cards = O.metrics.cards + 1
    if not remote() then
        local m = M()
        if fn(m, "momCard") then local ok, shown = pcall(m.momCard, card); return ok and shown end
        runDefault(card)
        return false
    end
    if player == nil then return false end
    O.prune()
    O.seq = O.seq + 1
    local id = "k" .. O.seq
    O.cards[id] = { card = card, key = ALifeSide.keyOf(player), h = hours() }
    local labels = {}
    for i, c in ipairs(card.choices) do labels[i] = tostring(cLabel(c) or i) end
    ALifeCmd.reply(player, "out", { k = "card", id = id, cid = card.id and tostring(card.id) or nil, title = card.title and tostring(card.title) or nil,
        text = tostring(card.text or ""), default = tonumber(card.default) or 1, labels = labels })
    return true
end
function O.prune()
    local now = hours()
    local ttl = O.CARD_TTL_H
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" and tonumber(m.settings.outCardTTL) then ttl = tonumber(m.settings.outCardTTL) end
    local drop = {}
    for id, row in pairs(O.cards) do if now - (tonumber(row.h) or now) > ttl then drop[#drop + 1] = id end end
    for _, id in ipairs(drop) do O.cards[id] = nil; O.metrics.expired = O.metrics.expired + 1 end
end
-- server: a client picked choice i on card id
function O.pick(player, args)
    if type(args) ~= "table" then return false end
    local id = tostring(args.id or "")
    local row = O.cards[id]
    if row == nil or tostring(row.key) ~= tostring(ALifeSide.keyOf(player)) then O.metrics.refused = O.metrics.refused + 1; return false end
    local i = tonumber(args.i)
    local c = i and row.card.choices[i] or nil
    if c == nil then O.metrics.refused = O.metrics.refused + 1; return false end
    O.cards[id] = nil
    O.metrics.picks = O.metrics.picks + 1
    local f = cFn(c)
    if f then ALifeSide.with(player, f, player) end -- the choice runs as that player (ALifeSide.you() = them)
    if type(row.card.after) == "function" then
        local ok, t = pcall(row.card.after, i)
        if ok and type(t) == "string" and t ~= "" then O.toast(player, t) end
    end
    return true
end
-- client: what the server sent
function O.receive(p)
    if type(p) ~= "table" then return false end
    if p.k ~= "card" then return O.show(p) end
    local choices = {}
    for i, label in ipairs(type(p.labels) == "table" and p.labels or {}) do
        choices[i] = { label = tostring(label), fn = function()
            local me = ALifeSide.localPlayer()
            if me ~= nil then ALifeCmd.send(me, "outPick", { id = p.id, i = i }) end
        end }
    end
    if #choices == 0 then return false end
    local card = { id = p.cid or p.id, title = p.title, text = p.text, default = p.default or 1, choices = choices }
    local m = M()
    if fn(m, "momCard") then local ok, shown = pcall(m.momCard, card); return ok and shown end
    runDefault(card)
    return false
end

ALifeCmd.onServer("outPick", O.pick)
ALifeCmd.onClient("out", O.receive)
print("[ALifeOut] ready v" .. O.VERSION .. ": letters, notes, news and cards reach the right player")
return O
