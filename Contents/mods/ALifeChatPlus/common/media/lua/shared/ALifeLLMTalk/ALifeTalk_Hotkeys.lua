-- A-Life NPC Overhaul 0.8.12 (Rock List 2): TWO HOTKEYS (Options > Mods > A-Life NPC Overhaul, unbound by default).
--   * Talk to the nearest person: opens the talk window with the closest A-Life person within talkKeyTiles, through
--     A-Life's own "Talk to ..." menu entry (the same one right-click shows; captured the way the radial does). Press
--     it again while the talk window is open and it closes.
--   * Repeat last order: gives your last order again, to the same people. Orders that need a spot ("hold there",
--     "flank left") work it out again from where you are now. Quick orders (radial / window) repeat too.
-- Every order path goes through ALifeTalkCommands.give (typed, voice, Commands tab, AI) or M.qoRun (quick orders);
-- both are wrapped at game start to remember the last one. Settings: talkKeyTiles (4).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Hotkeys") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCues"
local M = ALifeLLMTalk
local U = ALifeCues
if type(M) ~= "table" or type(U) ~= "table" then return end
local TAG = "[ALifeHotkeys]"
ALifeHotkeys = ALifeHotkeys or {}
local K = ALifeHotkeys
K.VERSION = ALifeSide.MOD_VERSION
K.last = K.last or nil
U.registerSettings()

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local tr = U.tr
local function halo(p, text) if p then pcall(function() p:setHaloNote(tostring(text), 220, 200, 140, 250) end) end end

----------------------------------------------------------------------------------------------------------------
-- remember the last order
----------------------------------------------------------------------------------------------------------------
function K.hookOrders()
    local C = ALifeTalkCommands
    if not K.giveHooked and fn(C, "give") then
        local orig = C.give
        C.give = function(player, c, uids, noun, agreed, ...)
            if not K.repeating and type(c) == "table" and c.id and type(uids) == "table" and #uids > 0 then
                local copy = {}
                for i, u in ipairs(uids) do copy[i] = tostring(u) end
                K.last = { kind = "cmd", c = c, uids = copy, noun = noun, agreed = agreed, at = now(), label = c.label or c.id }
            end
            return orig(player, c, uids, noun, agreed, ...)
        end
        K.giveHooked = true
    end
    if not K.qoHooked and fn(M, "qoRun") then
        local orig = M.qoRun
        M.qoRun = function(id, uid, ...)
            if not K.repeating and id ~= nil then
                local o = type(M.qoById) == "table" and M.qoById[id] or nil
                K.last = { kind = "qo", id = id, uid = uid, at = now(), label = o and o.label or tostring(id) }
            end
            return orig(id, uid, ...)
        end
        K.qoHooked = true
    end
    return K.giveHooked == true or K.qoHooked == true
end
function K.repeatLast(player)
    player = player or playerOf()
    local l = K.last
    if l == nil or player == nil then halo(player, tr("NoLastOrder", "No order to repeat yet.")); return false end
    K.repeating = true
    local ok, res = pcall(function()
        if l.kind == "cmd" and fn(ALifeTalkCommands, "give") then return ALifeTalkCommands.give(player, l.c, l.uids, l.noun, l.agreed) ~= nil end
        if l.kind == "qo" and fn(M, "qoRun") then return M.qoRun(l.id, l.uid) end
        return false
    end)
    K.repeating = false
    local done = ok and res ~= false
    halo(player, done and tr("Repeated", "Again: {1}", tostring(l.label)) or tr("RepeatFailed", "Couldn't repeat: {1}", tostring(l.label)))
    return done
end

----------------------------------------------------------------------------------------------------------------
-- talk to the nearest person
----------------------------------------------------------------------------------------------------------------
local function aLifeShell(c)
    local uid = nil
    pcall(function() if c:hasModData() then uid = c:getModData().ProjectALifeUID end end)
    return type(uid) == "string" and uid or nil
end
-- the closest A-Life person within talkKeyTiles on your floor: square, shell, uid
function K.nearest(player)
    local r = math.max(1, math.floor(tonumber(U.setting("talkKeyTiles")) or 4))
    local cell = getCell()
    local px, py, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local best, bd = nil, nil
    for dx = -r, r do
        for dy = -r, r do
            local d = dx * dx + dy * dy
            if d <= r * r and (bd == nil or d < bd) then
                local sq = cell:getGridSquare(px + dx, py + dy, z)
                if sq then
                    pcall(function()
                        local mv = sq:getMovingObjects()
                        for i = 0, mv:size() - 1 do
                            local c = mv:get(i)
                            local uid = c and aLifeShell(c)
                            local dead = false
                            pcall(function() dead = c:isDead() == true end)
                            if uid and not dead and (bd == nil or d < bd) then best, bd = { sq = sq, shell = c, uid = uid }, d end
                        end
                    end)
                end
            end
        end
    end
    return best
end
local function objectsOf(sq)
    local out = {}
    pcall(function() local objs = sq:getObjects(); for i = 0, objs:size() - 1 do out[#out + 1] = objs:get(i) end end)
    return out
end
function K.talkNearest(player)
    player = player or playerOf()
    if player == nil then return false end
    -- open already: the key closes it
    local WT = ALifeWindowTalk
    if fn(WT, "window") then
        local okW, win = pcall(WT.window)
        if okW and win ~= nil then pcall(function() win:close() end); return true end
    end
    local n = K.nearest(player)
    if n == nil then halo(player, tr("NobodyNear", "Nobody close enough to talk to.")); return false end
    local R = ALifeRadial
    if not fn(R, "capture") or not fn(R, "run") then return false end
    local okC, groups = pcall(R.capture, player:getPlayerNum(), objectsOf(n.sq))
    if not okC or type(groups) ~= "table" then R.capturing = false; return false end
    for _, node in ipairs(groups.npc or {}) do
        if type(node.label) == "string" and string.find(node.label, "^Talk to ") then
            if node.off then halo(player, node.off); return false end
            R.run(player:getPlayerNum(), node)
            return true
        end
    end
    halo(player, tr("CantTalk", "They won't talk right now."))
    return false
end

----------------------------------------------------------------------------------------------------------------
-- keys
----------------------------------------------------------------------------------------------------------------
local function typing()
    local ok, busy = pcall(function() return type(ISChat) == "table" and ISChat.instance ~= nil and ISChat.instance.focused == true end)
    return ok and busy
end
local function keyOf(opt)
    if opt == nil or not fn(opt, "getValue") then return nil end
    local ok, k = pcall(opt.getValue, opt)
    if ok and k ~= nil and k ~= 0 then return k end
    return nil
end
function K.onKey(key)
    local R = ALifeRadial
    if type(R) ~= "table" or typing() then return end
    local p = playerOf()
    if p == nil then return end
    local dead = false
    pcall(function() dead = p:isDead() == true end)
    if dead then return end
    if key == keyOf(R.talkKeyOpt) then pcall(K.talkNearest, p)
    elseif key == keyOf(R.repeatKeyOpt) then pcall(K.repeatLast, p) end
end
if type(Events) == "table" and Events.OnKeyStartPressed then Events.OnKeyStartPressed.Add(function(key) pcall(K.onKey, key) end) end

function K.install()
    K.hookOrders()
    if type(M.settingRows) == "table" then
        local have = false
        for _, r in ipairs(M.settingRows) do if r[1] == "talkKeyTiles" then have = true end end
        if not have then M.settingRows[#M.settingRows + 1] = { "talkKeyTiles", "Talk key: how close the nearest person must be (tiles)", { 2, 4, 8, 12 } } end
    end
    if type(M.settingCatOf) == "table" and M.settingCatOf.talkKeyTiles == nil then M.settingCatOf.talkKeyTiles = "Interface and immersion" end
    if type(M.winHelp) == "table" then
        table.insert(M.winHelp, { "Hotkeys", "Options > Mods > A-Life NPC Overhaul: talk to the nearest person (press again to close the talk window), repeat your last order (to the same people; spots worked out again from where you are), the A-Life window, the radial, hover." })
    end
    print(TAG .. " ready v" .. K.VERSION .. ": talk key (" .. tostring(U.setting("talkKeyTiles")) .. " tiles), repeat last order (orders "
        .. (K.giveHooked and "yes" or "no") .. ", quick orders " .. (K.qoHooked and "yes" or "no") .. ")")
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
return K
