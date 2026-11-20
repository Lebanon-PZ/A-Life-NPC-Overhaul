-- A-Life NPC Overhaul 0.8.5: THE WALKIE, client side (the rules live in shared/ALifeNPCOverhaul/ALifeWalkie.lua).
--   * Radio tab (hub window) and radial entry: pick a person -> pick a call (check in, news, come here, need help,
--     need serious help, talk). "Use my channel as ours" sets the channel your own people listen on.
--   * Your radio: a two-way radio in your hands / belt / bags, or a placed one (ham) within 3 tiles: on, powered,
--     its channel and range travel with the call (the server can't see a switch or battery in MP; Jeem's note).
--   * Answers: AI off -> fixed walkie lines. AI on -> their own short radio voice for come / help / refusals (the AI
--     is told what they decided, req.order, so the words match what happens); the fixed line if the AI is late.
--   * They call you: check-ins and alerts reach you only if your radio is on, powered, on their channel and in range;
--     otherwise it's a missed call (the server remembers missed check-ins).
--   * Swap channels: say "what's your channel" / "swap channels" to someone, or the Radio tab button for someone near.
--     Known channels are added to your walkie's presets (vanilla DevicePresets / PresetEntry, the radio window's own).
--   * Overheard: hostile groups with a radio in range may be scanning your channel (walkieScanChance); one that hears
--     where your base is may send people sooner (walkieRaidBump); one that hears "come here" may go for you
--     (walkieAmbush). Both use the 0.6.7 hunters (real members, real road time). Known MP gap: groups live client-side.
--   * The old typed walkie session (Relationships > Call) now follows the same rules (SP).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Walkie") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UI" here (client-only file, loads after shared; used at call time only)
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UIBond" here (client-only file, loads after shared; used at call time only)
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeWalkie"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Walkie"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Walkie") end end

local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeWalkie) ~= "table" then return end
local W = ALifeWalkie

ALifeTalkWalkie = ALifeTalkWalkie or {}
local K = ALifeTalkWalkie
local TAG = "[ALifeTalkWalkie]"
K.VERSION = "0.8.5"
K.metrics = K.metrics or { calls = 0, ai = 0, fixed = 0, incoming = 0, missed = 0, presets = 0, scanned = 0, raids = 0, ambush = 0, swaps = 0 }
K.contacts, K.baseCh = K.contacts or {}, K.baseCh

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function nowMs() return M.nowMs and M.nowMs() or 0 end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end

-- ---------------------------------------------------------------------------------------------------- settings
function K.settings()
    if type(M.settings) ~= "table" then return end
    for k, v in pairs(W.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, k in ipairs(M.fileKeys) do have[k] = true end
        for _, k in ipairs(W.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
    end
end
K.settings() -- load time, before the settings file is read
K.ROWS = {
    { "walkie", "Walkie: call one person by name over the radio (they need a radio of their own, in range, on your channel)" },
    { "walkieNpcRadio", "Walkie: they need a two-way radio with charge (or a spare battery) to answer" },
    { "walkieBaseSet", "Walkie: your people at home can answer on the base's own radio" },
    { "walkieCallMin", "Walkie: game minutes a call lasts (their battery)", { 1, 3, 5, 10 } },
    { "walkieDrainScale", "Walkie: battery drain during a call (x the radio's own)", { 1, 2, 5, 10 } },
    { "walkieStandby", "Walkie: drain while they just carry it on (x the radio's own; 0 = off)", { 0, 1 } },
    { "walkieOwn", "Walkie: your own people can be called without swapping channels first" },
    { "walkieSwapTrust", "Walkie: how much someone must like you to swap channels", { 0, 15, 30, 50 } },
    { "walkieHelpFriends", "Walkie: \"need help\" brings this many friends too", { 0, 1, 2, 3 } },
    { "walkieSeriousCount", "Walkie: \"need serious help\" brings up to this many", { 2, 3, 4 } },
    { "walkieFarTiles", "Walkie: further than this (tiles) people who don't like you much won't come", { 1000, 3000, 6000, 20000 } },
    { "walkieFarTrust", "Walkie: ... unless they like you this much", { 40, 60, 80 } },
    { "walkieCheckinH", "Walkie: your people call to check in when you've been away this many game hours (0 = never)", { 0, 4, 8, 12, 24 } },
    { "walkieAlerts", "Walkie: your people call right away when the base is attacked or someone's hurt" },
    { "walkieOverhear", "Walkie: hostiles on your channel can hear your calls" },
    { "walkieScanChance", "Walkie: chance a hostile group in range is scanning your channel (%)", { 0, 5, 15, 30 } },
    { "walkieRaidBump", "Walkie: chance a hostile group that heard where your base is sends people sooner (%)", { 0, 15, 35, 60 } },
    { "walkieAmbush", "Walkie: chance a hostile group that heard \"come here\" goes for you (%)", { 0, 15, 30, 60 } },
}
function K.addRows()
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs(K.ROWS) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
        if type(ALifeTalkSettings) == "table" and tonumber(ALifeTalkSettings.PER_COL) then
            ALifeTalkSettings.PER_COL = math.max(ALifeTalkSettings.PER_COL, math.ceil(#M.settingRows / 3))
        end
    end
    if type(M.settingCatOf) == "table" then for _, r in ipairs(K.ROWS) do M.settingCatOf[r[1]] = "Radio and news" end end
end
K.addRows()

-- ---------------------------------------------------------------------------------------------------- your radio
-- your best usable radio: a walkie on you, else a placed two-way radio within 3 tiles. { on, power, ch, range, id, dd }
function K.myRadio(player)
    player = player or playerOf()
    if player == nil then return nil end
    local best = W.scan(player)
    if best ~= nil and best.on and best.p > 0 then return best end
    local placed = nil
    pcall(function()
        local sq = player:getCurrentSquare()
        local cell = getCell()
        for dx = -3, 3 do for dy = -3, 3 do
            local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            local objs = s and s:getObjects()
            for i = 0, (objs and objs:size() or 0) - 1 do
                local o = objs:get(i)
                if instanceof(o, "IsoWaveSignal") then
                    local f = W.factsOf(o)
                    if f ~= nil and (placed == nil or (f.on and f.p > 0 and not (placed.on and placed.p > 0))) then placed = f end
                end
            end
        end end
    end)
    if placed ~= nil and placed.on and placed.p > 0 then return placed end
    return best or placed
end
function K.facts(player)
    local r = K.myRadio(player)
    local x, y = nil, nil
    pcall(function() x, y = player:getX(), player:getY() end)
    if r == nil then return { x = x, y = y } end
    return { on = r.on, power = r.p, ch = r.c, range = r.r, x = x, y = y }
end

K.WHY = {
    no_radio = "You need a two-way radio: a walkie-talkie on you, or a ham radio right next to you.",
    off = "Your radio's off.",
    no_power = "Your radio's dead. Batteries.",
    not_contact = "You don't have their channel. Ask them to swap channels first.",
    their_none = "Only static. They don't have a radio.",
    their_dead = "Only static. Their radio's dead.",
    wrong_channel = "Only static. You're not on their channel.",
    out_of_range = "Only static. They're out of range.",
    dead = "Nobody answers. Ever.",
    unknown = "Nobody answers.",
    off_setting = "Walkie calls are switched off (Settings, Radio and news).",
}
function K.line(text, name)
    if type(text) ~= "string" or text == "" then return end
    if fn(M, "radioLine") then pcall(M.radioLine, nil, text, name) else print(text) end
end
-- a Jeem keyed line flattened by the server ({ k, a1..a4 }) or plain text
function K.render(l)
    if type(l) == "string" then return l end
    if type(l) ~= "table" or type(l.k) ~= "string" then return nil end
    local args = {}
    for n = 1, 4 do local a = l["a" .. n]; if a ~= nil then args[#args + 1] = (type(a) == "string" and string.sub(a, 1, 5) == "IGUI_" and getText and getText(a)) or tostring(a) end end
    local ok, s = pcall(function() return getText(l.k, args[1], args[2], args[3], args[4]) end)
    if ok and type(s) == "string" and s ~= l.k then return s end
    return nil
end

-- ---------------------------------------------------------------------------------------------------- calls
K.KIND_LABEL = { checkin = "Check in", news = "Any news?", come = "Come to me", help = "I need help", serious = "I need serious help",
    talk = "Talk (type what you say)" }
K.KIND_ORDER = { "checkin", "news", "come", "help", "serious", "talk" }
K.SAID = { checkin = "Check in. How are things? Over.", news = "Anything new out there? Over.", come = "Come to me. I need you here. Over.",
    help = "I need help. Bring whoever you can. Over.", serious = "I'm in serious trouble. Bring everyone who can fight. Over." }
K.ORDER_KIND = { come = "come to them", help = "come help them, with friends", serious = "come with everyone who can fight" }

function K.call(player, uid, kind)
    player = player or playerOf()
    if player == nil or uid == nil then return false end
    local facts = K.facts(player)
    if facts.range == nil then K.line("[Radio] " .. K.WHY.no_radio); return false end
    if facts.on == false then K.line("[Radio] " .. K.WHY.off); return false end
    if num(facts.power, 1) <= 0 then K.line("[Radio] " .. K.WHY.no_power); return false end
    K.metrics.calls = K.metrics.calls + 1
    if kind == "talk" then
        if fn(M, "startRadio") then return M.startRadio(tostring(uid)) end
        return false
    end
    local args = { uid = tostring(uid), kind = kind, on = facts.on, power = facts.power, ch = facts.ch, range = facts.range, x = facts.x, y = facts.y }
    K.line("[Radio] " .. (K.SAID[kind] or "Come in. Over."))
    return ALifeCmd.send(player, "walkieCall", args)
end

-- the AI says it in their voice (they decided already: req.order); fixed line when the AI is off or late
local function aiReady()
    return M.settings.enabled ~= false and fn(M, "isSP") and M.isSP() and fn(M, "bridgeAlive") and M.bridgeAlive(nowMs()) and fn(M, "submit")
end
function K.voice(res, fixed)
    local player = playerOf()
    local spoken = res.kind == "come" or res.kind == "help" or res.kind == "serious"
    if spoken and aiReady() and player ~= nil then
        local rec = W.record(res.uid)
        if rec ~= nil then
            K.metrics.ai = K.metrics.ai + 1
            M.submit({ mode = "walkie", uid = tostring(res.uid), player = player, listener = { record = rec, shell = W.shell(res.uid) },
                text = K.SAID[res.kind], startMs = nowMs(), depth = 0, record = rec, walkie = res, fixed = fixed })
            return true
        end
    end
    K.metrics.fixed = K.metrics.fixed + 1
    K.line(fixed)
    return false
end
if type(M.eventModes) == "table" then
    M.eventModes.walkie = {
        request = function(job, now)
            if not fn(M, "radioRequest") then return nil end
            local req = M.radioRequest(job, now)
            if type(req) == "table" and type(job.walkie) == "table" then
                req.order = { kind = K.ORDER_KIND[job.walkie.kind] or "come to them", obeyed = job.walkie.ok == true and job.walkie.coming == true }
                if job.walkie.why ~= nil and fn(ALifeCommands, "whyWords") then req.order.why = ALifeCommands.whyWords(job.walkie.why) or job.walkie.why end
            end
            return req
        end,
        finish = function(p, r)
            local text = type(r) == "table" and r.text or nil
            if type(text) ~= "string" or text == "" then K.line(p.fixed); return end
            K.line(text, (p.walkie and p.walkie.name) or "Radio")
        end,
        fallback = function(p) K.line(p.fixed) end,
    }
end

function K.onResult(res)
    if type(res) ~= "table" then return end
    local name = tostring(res.name or "Someone")
    if not res.reached then
        K.line("[Radio] " .. (K.WHY[res.why] or K.WHY.unknown))
        return
    end
    if res.setChannel ~= nil then K.baseCh = res.setChannel; K.line("[Radio] (" .. name .. " will listen on " .. W.mhz(res.setChannel) .. " from now on: your people's channel.)") end
    local lines = res.lines or {}
    local first = K.render(lines[1])
    if first ~= nil then K.voice(res, "[Radio] " .. first) end
    for i = 2, #lines do local t = K.render(lines[i]); if t ~= nil then K.line("[Radio] " .. t) end end
    if res.kind == "come" or res.kind == "help" or res.kind == "serious" then
        if M.logInteraction then pcall(M.logInteraction, res.uid, res.coming and ("Answered your radio call: on the way") or "Couldn't come when you called", nil, nil, "event") end
    end
    K.overheard(res)
end

-- ---------------------------------------------------------------------------------------------------- overhearing
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function rollPct(p) local r = 100; pcall(function() r = ZombRand(100) end); return r < num(p, 0) end
function K.groupFor(id)
    if id == nil or not fn(M, "nbStore") then return nil end
    local st = M.nbStore()
    return type(st) == "table" and type(st.byId) == "table" and st.byId[tostring(id)] or nil
end
-- who heard: groups of the hostiles the server found on your channel + hostile groups with a radio scanning the band
function K.overheard(res)
    if W.setting("walkieOverhear") == false then return {} end
    local player = playerOf()
    if player == nil then return {} end
    local groups, seen = {}, {}
    for _, h in ipairs(type(res.heardBy) == "table" and res.heardBy or {}) do
        local b = K.groupFor(h.home)
        if b ~= nil and not seen[b.id] then seen[b.id] = true; groups[#groups + 1] = b end
    end
    local facts = K.facts(player)
    if facts.range ~= nil and fn(M, "rcInRange") then
        for _, b in ipairs(M.rcInRange(player, facts.range)) do
            if not seen[b.id] and num(b.rep, 50) < num(M.rcCfg and M.rcCfg.peaceAt, 30) and rollPct(W.setting("walkieScanChance")) then
                seen[b.id] = true
                groups[#groups + 1] = b
                K.metrics.scanned = K.metrics.scanned + 1
            end
        end
    end
    local h = W.hours()
    local baseWords = res.baseMentioned == true or W.BASE_KINDS[res.kind] == true
    for _, b in ipairs(groups) do
        if fn(M, "nbEvent") then pcall(M.nbEvent, b, "Heard you on the radio", "radio") end
        if baseWords then
            b.heardBase = { h = h }
            if rollPct(W.setting("walkieRaidBump")) then
                if type(b.bounty) == "table" then
                    b.bounty.nextH = math.min(num(b.bounty.nextH, h + 24), h + 2 + (hash(b.id .. h) % 6))
                    K.metrics.raids = K.metrics.raids + 1
                    log(tostring(b.name) .. " heard where your base is: coming sooner")
                end
            end
        end
        if res.kind == "come" and rollPct(W.setting("walkieAmbush")) and fn(M, "rcSend") then
            local n = math.max(1, math.min(3, num(b.crewN, 0) - 1))
            local trip = M.rcSend("hunt", b, n, player, h)
            if trip ~= nil then K.metrics.ambush = K.metrics.ambush + 1; log(tostring(b.name) .. " heard your call: " .. #trip.uids .. " going for you") end
        end
    end
    return groups
end

-- ---------------------------------------------------------------------------------------------------- they call you
K.ALERT_LINE = {
    attack = "%s: Base is under attack! We need you! Over!",
    hurt = "%s: Someone's hurt back here. Over.",
    checkin = "%s: Checking in. Haven't seen you in a while. You okay out there? Over.",
    gate = "%s, at the gate. Over.", -- 0.8.8: the gate guard (ALifeGateGuard)
}
function K.onIncoming(c)
    if type(c) ~= "table" then return end
    local player = playerOf()
    if player == nil then return end
    local facts = K.facts(player)
    local heard = facts.range ~= nil and facts.on ~= false and num(facts.power, 0) > 0
    if heard and c.ch ~= nil and num(facts.ch, -1) ~= num(c.ch, -2) then heard = false end
    if heard and c.d ~= nil then
        local ra = ProjectALifeJimmy and ProjectALifeJimmy.Residents and ProjectALifeJimmy.Residents.radio or nil
        local reach = facts.range
        if fn(ra, "reach") then local ok, r = pcall(ra.reach, facts.range, false); if ok and tonumber(r) then reach = r end end
        if num(c.d, 0) > num(reach, 0) then heard = false end
    end
    K.lastHeard = { kind = c.kind, heard = heard, uid = c.uid } -- 0.8.8: the gate report that follows reads this
    ALifeCmd.send(player, "walkieSeen", { kind = c.kind, heard = heard })
    if not heard then K.metrics.missed = K.metrics.missed + 1; return end
    K.metrics.incoming = K.metrics.incoming + 1
    local name = tostring(c.name or "Base")
    K.line("[Radio] " .. string.format(K.ALERT_LINE[c.kind] or "%s: Come in. Over.", name))
    for _, l in ipairs(type(c.lines) == "table" and c.lines or {}) do local t = K.render(l); if t ~= nil then K.line("[Radio] " .. t) end end
    if c.kind == "attack" then pcall(function() player:setHaloNote(name .. ": base under attack!", 255, 90, 90, 400) end) end
end

-- ---------------------------------------------------------------------------------------------------- channels
-- add a name -> frequency preset to your walkie (vanilla presets; the radio window's own list), once per name
function K.addPreset(name, ch)
    local r = K.myRadio(playerOf())
    if r == nil or r.dd == nil or tonumber(ch) == nil then return false end
    local ok, added = pcall(function()
        local dp = r.dd:getDevicePresets()
        if dp == nil then return false end
        local list = dp:getPresets()
        for i = 0, list:size() - 1 do
            local e = list:get(i)
            if tostring(e:getName()) == tostring(name) then
                if e:getFrequency() ~= ch then e:setFrequency(ch) end
                return false
            end
        end
        if list:size() >= dp:getMaxPresets() then return false end
        list:add(PresetEntry.new(tostring(name), ch))
        r.dd:transmitPresets()
        return true
    end)
    if ok and added then K.metrics.presets = K.metrics.presets + 1 end
    return ok and added
end
function K.syncPresets()
    if K.baseCh ~= nil then K.addPreset("Our people", K.baseCh) end
    for _, c in ipairs(K.contacts or {}) do if c.how == "swapped" and c.ch ~= nil then K.addPreset(c.name, c.ch) end end
end
function K.onContacts(p)
    if type(p) ~= "table" then return end
    K.contacts = type(p.list) == "table" and p.list or {}
    K.baseCh = p.ch
    pcall(K.syncPresets)
end
function K.refresh(player) player = player or playerOf(); if player ~= nil then ALifeCmd.send(player, "walkieContacts", {}) end end
function K.useMyChannel(player)
    player = player or playerOf()
    local f = K.facts(player)
    if f.ch == nil then K.line("[Radio] " .. K.WHY.no_radio); return false end
    return ALifeCmd.send(player, "walkieBaseChannel", { ch = f.ch })
end
function K.onBaseChannel(p)
    if type(p) ~= "table" then return end
    K.baseCh = p.ch
    K.line("[Radio] (Your people will listen on " .. W.mhz(p.ch) .. ".)")
    pcall(K.addPreset, "Our people", p.ch)
end

-- swap channels with someone right here
K.SWAP_WORDS = { "swap channels", "trade channels", "exchange channels", "what's your channel", "whats your channel", "what channel are you on",
    "your frequency", "what frequency", "radio channel", "can i call you", "how do i reach you" }
function K.swap(player, uid)
    if player == nil or uid == nil then return false end
    K.metrics.swaps = K.metrics.swaps + 1
    return ALifeCmd.send(player, "walkieSwap", { uid = tostring(uid) })
end
function K.onSwapped(res)
    if type(res) ~= "table" then return end
    local sh = W.shell(res.uid)
    local player = playerOf()
    if sh ~= nil and fn(M, "say") and res.line ~= nil then pcall(M.say, sh, player, res.line, { record = W.record(res.uid) }) end
    if res.ok and res.ch ~= nil then
        pcall(K.addPreset, res.name or "Contact", res.ch)
        if M.logInteraction then pcall(M.logInteraction, res.uid, "Swapped radio channels with you", nil, nil, "event") end
        K.refresh(player)
    end
end
function K.onWords(player, text, loud, hearers)
    if not W.on() or type(hearers) ~= "table" or hearers[1] == nil then return end
    local low = string.lower(tostring(text or ""))
    for _, w in ipairs(K.SWAP_WORDS) do
        if string.find(low, w, 1, true) then
            local l = hearers[1]
            if type(l.record) == "table" then K.swap(player, l.record.uid) end
            return
        end
    end
end
if type(M.playerWordHooks) == "table" and not K._words then K._words = true; table.insert(M.playerWordHooks, function(...) pcall(K.onWords, ...) end) end

-- ---------------------------------------------------------------------------------------------------- the old typed session follows the rules
function K.wrapSession()
    if K._session or not fn(M, "radioCheck") or not fn(M, "startRadio") then return false end
    K._session = true
    local check = M.radioCheck
    M.radioCheck = function(player, uid, ...)
        local ok, why, rec, shell = check(player, uid, ...)
        if not ok or not W.on() or not (fn(M, "isSP") and M.isSP()) then return ok, why, rec, shell end
        local f = K.facts(player)
        local okW, w = W.reach(player, uid, f)
        if not okW then return false, K.WHY[w] or "Only static." end
        return ok, why, rec, shell
    end
    local start = M.startRadio
    M.startRadio = function(uid, ...)
        local r = start(uid, ...)
        if r and M.radio ~= nil and W.on() and fn(M, "isSP") and M.isSP() then
            M.radio.answers = true -- they have a radio on your channel and in range: they pick up
            pcall(W.drain, tostring(uid), num(W.setting("walkieCallMin"), 3))
        end
        return r
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------- the Radio tab + radial
function K.pageText()
    local kit = M.winKit
    local esc, head, GOLD, TXT, DIM, RED = kit.esc, kit.head, kit.GOLD, kit.TXT, kit.DIM, kit.RED
    local player = playerOf()
    local out = { " <SIZE:medium> " .. GOLD .. "Radio" .. TXT .. " <SIZE:small> <LINE> " }
    local r = K.myRadio(player)
    if r == nil then
        out[#out + 1] = RED .. "No two-way radio on you or next to you." .. TXT .. " <LINE> "
    else
        out[#out + 1] = "Your radio: " .. esc(tostring(r.t)) .. ", " .. (r.on and "on" or (RED .. "off" .. TXT)) .. ", "
            .. (r.p > 0 and (r.p < 0.15 and "battery low" or "battery fine") or (RED .. "battery dead" .. TXT)) .. ", on " .. W.mhz(r.c) .. " <LINE> "
    end
    out[#out + 1] = "Your people's channel: " .. (K.baseCh and W.mhz(K.baseCh) or (DIM .. "not set (your first call to one of yours sets it)" .. TXT)) .. " <LINE> "
    out[#out + 1] = DIM .. "To reach someone they need a radio of their own (or the base's set, at home), switched on with charge, on the channel you're on, and within the weaker radio's range. Strangers' channels you only get if they swap with you (ask them: \"what's your channel?\"). Hostiles on your channel can hear you." .. TXT .. " <LINE> "
    out[#out + 1] = head("People you can call")
    if #(K.contacts or {}) == 0 then
        out[#out + 1] = DIM .. "Nobody yet." .. TXT .. " <LINE> "
    else
        for _, c in ipairs(K.contacts) do
            local how = c.how == "own" and "one of yours" or "swapped channels"
            local state = c.home and "home (base radio)" or (c.has and (c.p and "has a radio" or (RED .. "radio dead" .. TXT)) or (RED .. "no radio" .. TXT))
            out[#out + 1] = GOLD .. esc(c.name) .. TXT .. "  " .. DIM .. how .. TXT .. ", " .. state
                .. (c.ch and (", " .. W.mhz(c.ch)) or "") .. " <LINE> "
        end
    end
    return table.concat(out)
end
function K.callMenu(cm, player)
    if #(K.contacts or {}) == 0 then local o = cm:addOption(ALifeTr("IGUI_ALCP_Menu_Nobody_you_can_call_yet", "Nobody you can call yet."), nil, nil); o.notAvailable = true; return end
    for _, c in ipairs(K.contacts) do
        local o = cm:addOption(c.name, nil, nil)
        local sub = ISContextMenu:getNew(cm)
        cm:addSubMenu(o, sub)
        for _, kind in ipairs(K.KIND_ORDER) do
            if kind ~= "talk" or aiReady() then
                sub:addOption(K.KIND_LABEL[kind], nil, function() K.call(player, c.uid, kind) end)
            end
        end
    end
end
function K.swapMenu(cm, player)
    local T = PA().Talk
    local list = fn(T, "listeners") and T.listeners(player, 6) or {}
    if #list == 0 then local o = cm:addOption(ALifeTr("IGUI_ALCP_Menu_Nobody_close_enough", "Nobody close enough."), nil, nil); o.notAvailable = true; return end
    for _, l in ipairs(list) do
        if type(l.record) == "table" then
            cm:addOption(W.nameOf(l.record), nil, function() K.swap(player, l.record.uid) end)
        end
    end
end
function K.addTab()
    if K.tabAdded then return true end
    local kit = M.winKit
    if type(kit) ~= "table" or not fn(M, "hubAddTab") then return false end
    local RadioPage = kit.page("ALifeTalkRadioPage", "Radio", "radio",
        kit.tr("TipRadio", "<SIZE:medium> Radio <LINE> <SIZE:small> Call your people by name: check in, news, come to me, I need help."))
    function RadioPage:text() local ok, t = pcall(K.pageText); return ok and t or ("Radio: " .. tostring(t)) end
    function RadioPage:actions()
        return {
            { label = "Call someone", accent = true, fn = function(win, b) local p = playerOf(); K.refresh(p); K.callMenu(kit.menuAt(win, b), p) end },
            { label = "Swap channels", fn = function(win, b) K.swapMenu(kit.menuAt(win, b), playerOf()) end },
            { label = "Use my channel as ours", fn = function() K.useMyChannel(playerOf()) end },
            { label = "Refresh", fn = function() K.refresh(playerOf()) end },
        }
    end
    M.hubAddTab({ id = "radio", label = "Radio", class = "ALifeTalkRadioPage",
        open = function() K.refresh(playerOf()); return kit.openPage(RadioPage, "winRadio") end, ref = function() return M.winRadio end }, "people")
    if type(M.winHelp) == "table" then
        table.insert(M.winHelp, { "Radio", "Call one person by name over a walkie: they need a radio of their own (or the base's set), on your channel, in range. Your people check in when you're gone a while and call when the base is hit." })
    end
    K.tabAdded = true
    return true
end
function K.radial()
    if K._radial or type(ALifeRadial) ~= "table" or not fn(ALifeRadial, "addFiller") then return false end
    K._radial = true
    ALifeRadial.addFiller("walkie", "windows", function(playerNum, context, worldobjects, test)
        if test == true or not W.on() or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        local player = getSpecificPlayer(playerNum or 0)
        if player == nil or K.myRadio(player) == nil then return end
        local opt = context:addOption(ALifeTr("IGUI_ALCP_Menu_Walkie_call_someone", "Walkie: call someone"), nil, nil)
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(opt, sub)
        K.refresh(player)
        pcall(K.callMenu, sub, player)
    end)
    return true
end

if fn(ALifeCmd, "onClient") then
    ALifeCmd.onClient("walkieResult", function(p) return K.onResult(p) end)
    ALifeCmd.onClient("walkieIncoming", function(p) return K.onIncoming(p) end)
    ALifeCmd.onClient("walkieSwapped", function(p) return K.onSwapped(p) end)
    ALifeCmd.onClient("walkieContactList", function(p) return K.onContacts(p) end)
    ALifeCmd.onClient("walkieBaseChannelSet", function(p) return K.onBaseChannel(p) end)
end

function K.install()
    K.settings()
    K.addRows()
    local s = pcall(K.wrapSession)
    local t = pcall(K.addTab)
    local r = pcall(K.radial)
    log("ready v" .. K.VERSION .. ": walkie " .. (W.on() and "on" or "off") .. ", Radio tab " .. (K.tabAdded and "on" or "OFF")
        .. ", typed calls follow the rules " .. (K._session and "on" or "OFF") .. ", radial " .. (K._radial and "on" or "OFF"))
    return s and t and r
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
print(TAG .. " loaded v" .. K.VERSION)
