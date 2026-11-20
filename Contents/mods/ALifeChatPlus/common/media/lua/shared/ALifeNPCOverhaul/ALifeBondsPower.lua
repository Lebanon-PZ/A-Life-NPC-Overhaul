-- A-Life Bonds, phase 2: power over factions.  (Single player.)
--
--   Prisoners  Hold someone up (A-Life's hands-up order, or Jeem's), walk them into your base (order them to follow),
--              right-click -> Take prisoner. While you hold them, everyone in their faction fears you (at least "Wary")
--              and obeys you more. They're kept surrendered with A-Life's own surrender order while you're nearby.
--              Every day there's a chance they escape - fewer if your base has residents to guard them.
--              Release them: their people calm down a little. Lose them (escape/death): the leverage is gone and
--              their faction resents you.
--   Tribute    With leverage over a faction (a prisoner, or someone who already fears you), demand tribute from one of
--              its members. Then every 3 days any member can be asked to pay: they hand over what they carry (A-Life's
--              own handover). Hurt their people while the deal stands and you broke it: fear collapses, they hate you.
--              Ask to collect without real leverage left and they refuse - the deal is over.
--   Desertion  Residents who stayed only out of fear (no love, no need) watch for the leverage to go. When it does,
--              each day some of them leave (Jeem's own "leave on their own").
--   Watching   Taking prisoners and demanding tribute costs love with residents and partners nearby.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeBondsPower") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)

local TAG = "[ALifeBondsPower]"
local VERSION = "1.3.0"

ALifeBondsPower = ALifeBondsPower or {}
local P = ALifeBondsPower
P.version = VERSION
P.LEVERAGE_FEAR = 30            -- prisoner held: their faction is at least "Wary" (stage 2)
P.DEAL_FEAR = 10                -- a standing deal: at least "Uneasy"
P.TRIBUTE_EVERY_H = 72
P.TRIBUTE_ITEMS = 4
P.ESCAPE_BASE, P.ESCAPE_PER_GUARD, P.ESCAPE_MIN = 15, 3, 2   -- percent per day
P.DESERT_CHANCE = 30            -- percent per day once fear-only residents lose their leverage
P.metrics = { taken = 0, released = 0, escaped = 0, died = 0, tributes = 0, broken = 0, deserted = 0 }

local disabled = {}
local function tryOnce(id, fn, ...)
    if disabled[id] then return false, nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return true, a, b end
    disabled[id] = true
    print(TAG .. " " .. id .. " failed, disabled for this session: " .. tostring(a))
    return false, nil
end

local function B() return ALifeBonds end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and h or 0
end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function roll100() return type(ZombRand) == "function" and ZombRand(100) or 50 end
local function registry() return ProjectALife and ProjectALife.ActorRegistry end
local function readRecord(uid)
    local reg = registry()
    if reg == nil or uid == nil then return nil end
    local ok, r = pcall(reg.read, uid)
    return ok and r or nil
end
local function shellFor(uid)
    local talk = ProjectALife and ProjectALife.Talk
    if talk ~= nil and type(talk.shellFor) == "function" then
        local ok, s = pcall(talk.shellFor, uid)
        if ok then return s end
    end
    return nil
end
local function notify(player, text, good)
    if ALifeImmersion ~= nil and ALifeImmersion.enabled then return end   -- immersion: read it from people, not pop-ups
    pcall(function()
        if HaloTextHelper == nil or player == nil then return end
        if type(ALifeLetter) == "function" then ALifeLetter(player, text, 170, 210, 170, good == false)
        elseif good == false and type(HaloTextHelper.addBadText) == "function" then HaloTextHelper.addBadText(player, text)
        elseif type(HaloTextHelper.addText) == "function" then HaloTextHelper.addText(player, text) end
    end)
end
local function nameOf(record)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    if type(m.personName) == "string" and m.personName ~= "" then return m.personName end
    return "They"
end
local function factionTitle(fid)
    local title = tostring(fid or "their people")
    pcall(function()
        local f = ProjectALife.Catalog.faction(fid)
        if type(f) == "table" and type(f.title) == "string" then title = f.title end
    end)
    return title
end
local function posOf(obj)
    local ok, x, y, z = pcall(function() return obj:getX(), obj:getY(), obj:getZ() end)
    if ok then return x, y, z end
    return nil
end

-- --------------------------------------------------------------- state -----
function P.state()
    local s = B().store()
    s.cap = s.cap or {}      -- uid -> { key, fid, since, base, name }
    s.deal = s.deal or {}    -- key -> fid -> { since, last }
    s.lost = s.lost or {}    -- key -> fid -> hours when leverage was lost (for desertion)
    s.fled = s.fled or {}    -- uid -> { key, fid, name, since }: ran off, you can still find them (Code Orange)
    return s
end

function P.captivesOf(key, fid)
    local n = 0
    for _, c in pairs(P.state().cap) do
        if c.key == key and (fid == nil or c.fid == fid) then n = n + 1 end
    end
    return n
end

function P.dealOf(key, fid)
    local d = P.state().deal[key]
    return d and d[fid] or nil
end

local function factionOfUid(uid)
    local r = readRecord(uid)
    return r and r.factionId or nil, r
end

-- --------------------------------------------------- bonds integration -----
local function installBondsHooks()
    local Bd = B()
    Bd.hasLeverage = function(key, uid)
        local fid = factionOfUid(uid)
        if fid == nil or key == nil then return false end
        return P.captivesOf(key, fid) > 0 or P.dealOf(key, fid) ~= nil
    end
    Bd.effectiveFear = function(key, uid, r)
        local f = r ~= nil and (tonumber(r.f) or 0) or 0
        local fid = factionOfUid(uid)
        if fid == nil or key == nil then return f end
        if P.captivesOf(key, fid) > 0 then f = math.max(f, P.LEVERAGE_FEAR) end
        if P.dealOf(key, fid) ~= nil then f = math.max(f, P.DEAL_FEAR) end
        return f
    end
end

local function witnessCost(key, player, amount)
    local wd = ProjectALife and ProjectALife.Watchdog
    local mine = B().store().p[key]
    if wd == nil or type(wd.bindings) ~= "table" or mine == nil or player == nil then return end
    local px, py = posOf(player)
    if px == nil then return end
    for uid, bind in pairs(wd.bindings) do
        local r = mine[uid]
        if r ~= nil and type(bind) == "table" and bind.shell ~= nil then
            local x, y = posOf(bind.shell)
            if x ~= nil and (x - px) ^ 2 + (y - py) ^ 2 <= 400 and B().stageOf(r.f) < 2 then
                B().change(key, uid, -amount, 0, 0, { player = player })
            end
        end
    end
end

-- each bond row of that faction you know: a nudge
local function shakeFaction(key, fid, dl, df, player)
    local mine = B().store().p[key]
    if mine == nil then return end
    for uid in pairs(mine) do
        if factionOfUid(uid) == fid then B().change(key, uid, dl, df, 0, { player = player }) end
    end
end

local function markLost(key, fid)
    local s = P.state()
    s.lost[key] = s.lost[key] or {}
    if P.captivesOf(key, fid) == 0 and P.dealOf(key, fid) == nil then s.lost[key][fid] = hours() end
end

-- ------------------------------------------------------------- jeem/base ----
local function J() return ProjectALifeJimmy end

-- your base containing this position, or nil
function P.yourBaseAt(player, x, y)
    local j = J()
    if j == nil or j.BaseAreas == nil or type(j.BaseAreas.baseAt) ~= "function" or x == nil then return nil end
    local ok, base = pcall(j.BaseAreas.baseAt, x, y, 0)
    if not ok or type(base) ~= "table" then return nil end
    local R = j.Residents
    if R ~= nil and type(R.isMember) == "function" then
        local ok2, member = pcall(R.isMember, base.id, player)
        if ok2 and member ~= true then return nil end
    end
    return base
end

local function guardsAt(baseId)
    local reg = registry()
    if reg == nil or type(reg.each) ~= "function" or baseId == nil then return 0 end
    local n = 0
    pcall(reg.each, function(r)
        local res = type(r.memory) == "table" and r.memory.jimmyResident or nil
        if type(res) == "table" and res.baseId == baseId and r.lifecycle ~= "dead" then n = n + 1 end
        return false
    end)
    return n
end

-- -------------------------------------------------------------- holding ----
-- Is this NPC currently surrendered to this player (A-Life order or Jeem hold-up)?
function P.surrenderedTo(record, key)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or nil
    if m == nil or key == nil then return false end
    local o = m.orderedTo
    if type(o) == "table" and o.kind == "surrender" and o.playerKey == key and nowMs() < (tonumber(o.untilMs) or 0) then return true end
    local s = m.jimmySurrender
    if type(s) == "table" and s.by == key then return true end
    return false
end

local function keepSurrendered(uid, record, shell, player)
    local Orders = ProjectALife and ProjectALife.TalkOrders
    if Orders == nil or type(Orders.states) ~= "table" then return false end
    local now = nowMs()
    local st = Orders.states[uid]
    if st == nil then
        if type(Orders.beginSurrender) ~= "function" then return false end
        local ok, began = pcall(Orders.beginSurrender, record, shell, player, now, "surrender")
        return ok and began == true
    end
    local untilMs = now + ((Orders.settings and Orders.settings.surrenderMs) or 90000)
    st.untilMs, st.lastSeenMs, st.player = untilMs, now, player
    if now - (st.renewAtMs or 0) > 30000 then
        st.renewAtMs = now
        local talk = ProjectALife.Talk
        pcall(talk.writeMemory, uid, function(m)
            if type(m.orderedTo) == "table" and m.orderedTo.kind == "surrender" then m.orderedTo.untilMs = untilMs end
        end)
    end
    return true
end

-- player setting (ALifeCapture.DEFAULTS holds the defaults + file keys); explicit nil checks, a false setting stays false
function P.setting(key, default)
    local C = ALifeCapture
    local v = nil
    if type(C) == "table" and type(C.setting) == "function" then
        local ok, got = pcall(C.setting, key)
        if ok then v = got end
    end
    if v == nil then return default end
    return v
end

-- rope: tying someone up costs rope (real inventory item); untying at your base gives it back
P.ROPE = "Base.Rope"
local function ropeCount(player)
    local ok, n = pcall(function() return player:getInventory():getCountTypeRecurse(P.ROPE) end)
    return ok and tonumber(n) or 0
end
local function ropesNeeded() return math.max(1, math.floor(tonumber(P.setting("prisonerRopeCount", 1)) or 1)) end
local function takeRope(player, n)
    for _ = 1, n do
        local ok = pcall(function()
            local it = player:getInventory():getFirstTypeRecurse(P.ROPE)
            if it == nil then error("none") end
            it:getContainer():Remove(it)
        end)
        if not ok then return false end
    end
    return true
end
local function giveRope(player, n)
    if player == nil then return end
    for _ = 1, n do pcall(function() player:getInventory():AddItem(P.ROPE) end) end
end

-- Code Orange: a primary popup on your machine (letter if the popup channel is not there)
local function codeOrange(player, text)
    local sent = false
    if type(ALifeCmd) == "table" and type(ALifeCmd.reply) == "function" and player ~= nil then
        sent = pcall(ALifeCmd.reply, player, "prisonerCode", { text = text }) == true
    end
    if not sent then notify(player, text, false) end
end

-- ---------------------------------------------------------------- actions ---
function P.canTake(player, record)
    local key = B().keyOf(player)
    if type(record) ~= "table" or key == nil then return false, "not_npc" end
    if P.state().cap[record.uid] ~= nil then return false, "already" end
    if not P.surrenderedTo(record, key) then return false, "not_surrendered" end
    local shell = shellFor(record.uid)
    if shell == nil then return false, "not_here" end
    if P.setting("prisonerRope", true) and ropeCount(player) < ropesNeeded() then return false, "no_rope" end
    if not P.setting("prisonerAnywhere", true) then
        local x, y = posOf(shell)
        if P.yourBaseAt(player, x, y) == nil then return false, "not_in_base" end
    end
    return true
end

function P.take(player, uid)
    local record = readRecord(uid)
    local ok, why = P.canTake(player, record)
    if not ok then return false, why end
    local key = B().keyOf(player)
    local shell = shellFor(uid)
    local x, y = posOf(shell)
    local base = P.yourBaseAt(player, x, y)
    P.state().cap[uid] = { key = key, fid = record.factionId, since = hours(), base = base and base.id or nil, name = nameOf(record),
        gid = type(record.memory) == "table" and record.memory.groupId or nil, seen = hours() }
    P.metrics.taken = P.metrics.taken + 1
    if P.setting("prisonerRope", true) then
        local n = ropesNeeded()
        if not takeRope(player, n) then P.state().cap[uid] = nil; P.metrics.taken = P.metrics.taken - 1; return false, "no_rope" end
        P.state().cap[uid].tied, P.state().cap[uid].rope = true, n
    end
    keepSurrendered(uid, record, shell, player)
    B().change(key, uid, -6, 15, 0, { player = player, record = record })
    witnessCost(key, player, 3)
    notify(player, nameOf(record) .. " is your prisoner" .. (P.state().cap[uid].tied and ", hands tied" or "") .. ". " .. factionTitle(record.factionId) .. " will think twice.", true)
    print(TAG .. " prisoner taken: " .. tostring(uid) .. " (" .. tostring(record.factionId) .. ")")
    if ALifeLLMTalk and ALifeLLMTalk.valPrisoner then ALifeLLMTalk.valPrisoner("prisoner", player, record) end
    return true
end

-- untie (only inside your base, so they can work): the rope comes back. Tying again costs rope again.
function P.untie(player, uid)
    local c = P.state().cap[uid]
    if c == nil or c.key ~= B().keyOf(player) then return false, "not_yours" end
    if not c.tied then return false, "not_tied" end
    local shell = shellFor(uid)
    local x, y = posOf(shell)
    if P.yourBaseAt(player, x, y) == nil then return false, "not_in_base" end
    c.tied = false
    giveRope(player, tonumber(c.rope) or 1)
    c.rope = nil
    notify(player, (c.name or "They") .. " is untied. Rope back in your pack. Watch them.", true)
    return true
end
function P.tie(player, uid)
    local c = P.state().cap[uid]
    if c == nil or c.key ~= B().keyOf(player) then return false, "not_yours" end
    if c.tied then return false, "already" end
    local n = ropesNeeded()
    if ropeCount(player) < n or not takeRope(player, n) then return false, "no_rope" end
    c.tied, c.rope, c.work = true, n, nil
    local record = readRecord(uid)
    if record ~= nil then keepSurrendered(uid, record, shellFor(uid), player) end
    notify(player, (c.name or "They") .. " is tied up again.", true)
    return true
end

function P.release(player, uid)
    local c = P.state().cap[uid]
    local key = B().keyOf(player)
    if c == nil or c.key ~= key then return false, "not_yours" end
    P.state().cap[uid] = nil
    if c.tied then giveRope(player, tonumber(c.rope) or 1) end          -- you cut them loose, the rope is yours
    P.metrics.released = P.metrics.released + 1
    if ALifeLLMTalk and ALifeLLMTalk.valPrisoner then ALifeLLMTalk.valPrisoner("spared", player, readRecord(uid)) end
    local Orders = ProjectALife and ProjectALife.TalkOrders
    if Orders ~= nil and type(Orders.release) == "function" then pcall(Orders.release, uid, "released", true) end
    local op = ProjectALife and ProjectALife.NpcOpinion
    local record = readRecord(uid)
    if op ~= nil and type(op.note) == "function" and record ~= nil then pcall(op.note, "promise", record, player) end
    shakeFaction(key, c.fid, 1, -5, player)
    markLost(key, c.fid)
    notify(player, (c.name or "They") .. " walks free.", true)
    return true
end

local function loseCaptive(uid, c, why)
    P.state().cap[uid] = nil
    local player = ALifeSide.campPlayer()
    if why == "escaped" then
        P.metrics.escaped = P.metrics.escaped + 1
        local Orders = ProjectALife and ProjectALife.TalkOrders
        if Orders ~= nil and type(Orders.release) == "function" then pcall(Orders.release, uid, "escaped", true) end
        local op = ProjectALife and ProjectALife.NpcOpinion
        local record = readRecord(uid)
        if op ~= nil and type(op.adjust) == "function" and record ~= nil then
            pcall(op.adjust, record, player or c.key, -30, "You held them prisoner.")
        end
        local hoursToFind = tonumber(P.setting("prisonerFindH", 24)) or 24
        P.state().fled[uid] = { key = c.key, fid = c.fid, name = c.name, since = hours() }
        if P.setting("prisonerCodeOrange", true) then
            codeOrange(player, "CODE ORANGE. " .. (c.name or "Your prisoner") .. " got loose" .. (c.tied and " and slipped the rope" or "")
                .. " and is running. Find them and hold them up again within about " .. math.floor(hoursToFind)
                .. " hours. If they reach " .. factionTitle(c.fid) .. ", they'll tell them what they saw: where you live and how many you are.")
        else
            notify(player, (c.name or "Your prisoner") .. " escaped!", false)
        end
    else
        P.metrics.died = P.metrics.died + 1
        notify(player, (c.name or "Your prisoner") .. " is dead. " .. factionTitle(c.fid) .. " will hear of it.", false)
    end
    shakeFaction(c.key, c.fid, why == "died" and -10 or -4, -20, player)
    markLost(c.key, c.fid)
    print(TAG .. " prisoner " .. tostring(uid) .. " " .. why)
end

-- tribute -------------------------------------------------------------------
function P.canDemand(player, record)
    local key = B().keyOf(player)
    if type(record) ~= "table" or key == nil or record.factionId == nil then return false, "not_npc" end
    if P.dealOf(key, record.factionId) ~= nil then return false, "already" end
    if P.captivesOf(key, record.factionId) > 0 then return true end
    local r = B().row(key, record.uid, false)
    if B().stageOf(B().effectiveFear(key, record.uid, r)) >= 3 then return true end
    return false, "no_leverage"
end

function P.demand(player, uid)
    local record = readRecord(uid)
    local ok, why = P.canDemand(player, record)
    if not ok then return false, why end
    local key = B().keyOf(player)
    local s = P.state()
    s.deal[key] = s.deal[key] or {}
    s.deal[key][record.factionId] = { since = hours(), last = hours() - P.TRIBUTE_EVERY_H }
    witnessCost(key, player, 2)
    notify(player, factionTitle(record.factionId) .. " will pay you every 3 days.", true)
    print(TAG .. " tribute deal: " .. tostring(record.factionId))
    return true
end

function P.tributeDueIn(key, fid)
    local d = P.dealOf(key, fid)
    if d == nil then return nil end
    return math.max(0, (d.last + P.TRIBUTE_EVERY_H) - hours())
end

local function breakDeal(key, fid, player, why)
    local s = P.state()
    if s.deal[key] == nil or s.deal[key][fid] == nil then return end
    s.deal[key][fid] = nil
    P.metrics.broken = P.metrics.broken + 1
    shakeFaction(key, fid, -8, -20, player)
    markLost(key, fid)
    notify(player, "Your deal with " .. factionTitle(fid) .. " is over (" .. why .. ")", false)
    print(TAG .. " deal broken with " .. tostring(fid) .. ": " .. why)
end

function P.collect(player, uid)
    local record = readRecord(uid)
    local key = B().keyOf(player)
    if record == nil or key == nil then return false, "not_npc" end
    local fid = record.factionId
    local d = P.dealOf(key, fid)
    if d == nil then return false, "no_deal" end
    if hours() - d.last < P.TRIBUTE_EVERY_H then return false, "not_due" end
    -- still scary? a prisoner, or this person fears you at least "Wary" on their own
    local r = B().row(key, uid, false)
    if P.captivesOf(key, fid) == 0 and B().stageOf(r and r.f or 0) < 2 then
        breakDeal(key, fid, player, "they don't fear you anymore")
        return false, "refused"
    end
    local Orders = ProjectALife and ProjectALife.TalkOrders
    local shell = shellFor(uid)
    local taken = {}
    if Orders ~= nil and type(Orders.frisk) == "function" and shell ~= nil then
        local ok, t = pcall(Orders.frisk, record, shell, player, "items", P.TRIBUTE_ITEMS)
        if ok and type(t) == "table" then taken = t end
    end
    d.last = hours()
    P.metrics.tributes = P.metrics.tributes + 1
    B().change(key, uid, -1, 2, 0, { player = player, record = record })
    if #taken > 0 then notify(player, "Tribute: " .. table.concat(taken, ", "), true)
    else notify(player, nameOf(record) .. " has nothing on them. Paid next time.", false) end
    return true, taken
end

-- breaking a deal by hurting their people
local function onDeed(kind, ref, player)
    if kind ~= "hit" and kind ~= "robbery" and kind ~= "killed_mate" then return end
    local key = B().keyOf(player)
    local fid = type(ref) == "table" and ref.factionId or factionOfUid(ref)
    if key ~= nil and fid ~= nil and P.dealOf(key, fid) ~= nil then breakDeal(key, fid, player, "you hurt their people") end
end

-- ------------------------------------------------------------------ ticks ---
local tick = 0
local function holdTick()
    local caps = P.state().cap
    local any = false
    for _ in pairs(caps) do any = true; break end           -- PZ's Lua has no next()
    if not any then return end
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    for uid, c in pairs(caps) do
        local record = readRecord(uid)
        if record == nil or record.lifecycle == "dead" then
            loseCaptive(uid, c, "died")
        else
            local shell = shellFor(uid)
            if shell ~= nil then
                local x, y = posOf(shell)
                if P.yourBaseAt(player, x, y) ~= nil then
                    if c.work == nil then keepSurrendered(uid, record, shell, player) end   -- working: hands down
                    c.seen = hours()
                else
                    -- outside your base: held while you stay close; you leave them alone too long and they slip off
                    local px, py = posOf(player)
                    local leash = tonumber(P.setting("prisonerLeashTiles", 30)) or 30
                    local near = px ~= nil and x ~= nil and math.abs(px - x) <= leash and math.abs(py - y) <= leash
                    if near then
                        if c.work == nil then keepSurrendered(uid, record, shell, player) end
                        c.seen = hours()
                    elseif c.seen ~= nil and hours() - c.seen > (tonumber(P.setting("prisonerAwayMin", 30)) or 30) / 60 then
                        loseCaptive(uid, c, "escaped")
                    end
                end
            end
        end
    end
end

local function onTick()
    tick = tick + 1
    if tick < 60 then return end
    tick = 0
    tryOnce("hold", holdTick)
end

-- Code Orange follow-up (hourly): hold them up again = found. Time runs out = they got away and may talk.
local function fledTick()
    local fled = P.state().fled
    local any = false
    for _ in pairs(fled) do any = true; break end
    if not any then return end
    local player = ALifeSide.campPlayer()
    for uid, f in pairs(fled) do
        local record = readRecord(uid)
        if record == nil or record.lifecycle == "dead" then
            fled[uid] = nil
        elseif P.surrenderedTo(record, f.key) then
            fled[uid] = nil
            P.metrics.refound = (P.metrics.refound or 0) + 1
            notify(player, (f.name or "They") .. " is back in your hands. Take them prisoner again.", true)
        elseif hours() - (tonumber(f.since) or hours()) >= (tonumber(P.setting("prisonerFindH", 24)) or 24) then
            fled[uid] = nil
            P.metrics.gotAway = (P.metrics.gotAway or 0) + 1
            local told = roll100() < (tonumber(P.setting("prisonerTellChance", 60)) or 60)
            if told then
                local warned = false
                pcall(function() warned = ProjectALife.RaidDirector.warn(player, f.fid, hours()) == true end)
                codeOrange(player, (f.name or "Your prisoner") .. " reached " .. factionTitle(f.fid) .. " and told them everything. "
                    .. (warned and "They're coming." or "Expect trouble."))
            else
                notify(player, (f.name or "Your prisoner") .. " got away. No word of where they went.", false)
            end
        end
    end
end

local lastDay = nil
local function daily()
    local d = math.floor(hours() / 24)
    if lastDay == nil then lastDay = d; return end
    if d == lastDay then return end
    lastDay = d
    local player = ALifeSide.campPlayer()
    -- escapes
    for uid, c in pairs(P.state().cap) do
        local chance = math.max(P.ESCAPE_MIN, P.ESCAPE_BASE - P.ESCAPE_PER_GUARD * guardsAt(c.base))
        if c.tied then chance = tonumber(P.setting("prisonerTiedEscape", 2)) or 2 end   -- hands tied: rarely gets loose
        if c.work ~= nil then chance = chance + 10 end      -- hands down, working: easier to slip away
        local r = B().row(c.key, uid, false)
        if r ~= nil and B().stageOf(r.f) >= 3 then chance = math.floor(chance / 2) end
        if roll100() < chance then loseCaptive(uid, c, "escaped") end
    end
    -- desertion: fear-only residents whose leverage is gone
    local j = J()
    local R = j and j.Residents
    local reg = registry()
    if R == nil or type(R.leaveOnTheirOwn) ~= "function" or reg == nil then return end
    local s = P.state()
    local leaving = {}
    pcall(reg.each, function(rec)
        local res = type(rec.memory) == "table" and rec.memory.jimmyResident or nil
        if type(res) == "table" and rec.lifecycle ~= "dead" then
            for key, lost in pairs(s.lost) do
                if lost[rec.factionId] ~= nil then
                    local r = B().row(key, rec.uid, false)
                    if r ~= nil and B().stageOf(r.l) <= 1 and B().stageOf(r.n) <= 1 and r.f >= 10 then
                        leaving[#leaving + 1] = rec
                    end
                end
            end
        end
        return false
    end)
    for _, rec in ipairs(leaving) do
        if roll100() < P.DESERT_CHANCE then
            local ok = pcall(R.leaveOnTheirOwn, rec, "no_longer_afraid")
            if ok then
                P.metrics.deserted = P.metrics.deserted + 1
                notify(player, nameOf(rec) .. " left your base. Fear was all that kept them.", false)
            end
        end
    end
end

-- ---------------------------------------------------------------- install ---
function P.install()
    if B() == nil then return false end
    if P.__installed then return true end
    P.__installed = true
    installBondsHooks()
    -- deals break when you hurt their people: listen on the same deed funnel bonds uses
    local op = ProjectALife and ProjectALife.NpcOpinion
    if op ~= nil and type(op.note) == "function" then
        local orig = op.note
        op.note = function(kind, ref, player, options)
            local result = orig(kind, ref, player, options)
            tryOnce("deed", onDeed, kind, ref, player)
            return result
        end
    end
    print(TAG .. " ready (prisoners, tribute, desertion" .. (J() and J().BaseAreas and ", Jeem bases" or ", NO Jeem bases: prisoners unavailable") .. ")")
    return true
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() tryOnce("install", P.install) end) end
    if Events.OnTick ~= nil then ALifeHealth.add(Events.OnTick, "ALifeBondsPower", onTick) end
    if Events.EveryHours ~= nil then ALifeHealth.add(Events.EveryHours, "ALifeBondsPower", function() tryOnce("fled", fledTick); tryOnce("daily", daily) end) end
end
print(TAG .. " loaded v" .. VERSION)
