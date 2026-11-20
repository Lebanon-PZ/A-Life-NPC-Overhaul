-- ALifeTalk_CampBitten.lua (0.5.4): what your camp does when one of its own is bitten.
-- A-Life already infects NPCs (a bite starts a clock; when it runs out they die and get back up). This file makes
-- the camp live with it: some confess, some hide it until a medic or a fever gives them away, and your camp rule
-- decides what happens next: quarantine, put them down, or let them choose.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampBitten") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPBitten = true
M.cpDefaults.CPBiteRule = 1 -- 1 quarantine, 2 put them down, 3 their choice
M.cpDefaults.CPBiteHide = true
M.cbCfg = { scanMs = 5000, medicFindsH = 1, feverAt = 0.6, witnessTiles = 15 }
M.cbStats = { bitten = 0, told = 0, hid = 0, found = 0, mercy = 0, turned = 0 }
M.cbRules = { "quarantine", "putdown", "choice" }
M.cbRuleLabel = { quarantine = "Quarantine them", putdown = "Put them down", choice = "Let them choose" }

function M.cbOn() return M.cpOpt("CPBitten") ~= false end
function M.cbData()
    local d = M.cpData()
    d.bit = type(d.bit) == "table" and d.bit or {}
    return d
end
function M.cbRule()
    local d = M.cbData()
    if M.cbRuleLabel[d.biteRule or ""] then return d.biteRule end
    return M.cbRules[tonumber(M.cpOpt("CPBiteRule")) or 1] or "quarantine"
end
-- when this person turns (world hours), or nil if they aren't infected
function M.cbTurnAt(uid)
    local r = H.rec(uid)
    local t = r and type(r.memory) == "table" and tonumber(r.memory.infectedTurnAtHours) or nil
    if t then return t end
    local sh = H.shellFor(uid)
    if sh then pcall(function() t = tonumber(sh:getModData().ProjectALifeTurnAtHours) end) end
    return t
end
function M.cbKnown(uid) local b = M.cbData().bit[tostring(uid)]; return type(b) == "table" and b.known == true end
local function lens(uid) local l = {}; pcall(function() l = M.lens(tostring(uid)) end); return l end
local function L(l, k) return tonumber(l[k]) or 0 end

-- would they hide it?
function M.cbHides(uid)
    if M.cpOpt("CPBiteHide") == false then return false end
    local l = lens(uid)
    local s = L(l, "fearful") + 0.6 * L(l, "proud") + 0.4 * L(l, "greedy") + 0.3 * L(l, "paranoid")
        - 0.6 * L(l, "disciplined") - 0.6 * L(l, "loyal") - 0.4 * L(l, "devout") - 0.4 * L(l, "brave")
        + ((H.hash(uid .. "bite") % 31) - 15) / 100
    return s > 0.15
end
-- under "let them choose": the brave ask you to do it; the rest take the quarantine room
function M.cbChoosesMercy(uid)
    local l = lens(uid)
    return L(l, "brave") + L(l, "devout") + L(l, "disciplined") > L(l, "fearful") + 0.2
end

local TOLD = { "I got bit. Out there. I'm sorry.", "It's a bite. I checked twice. It's a bite.", "I need to tell you something. I'm bitten." }
local FOUND_MEDIC = { "Hold still. Let me see that arm... That's a bite. How long were you going to hide it?", "This isn't a scratch. Who else knows?" }
local FEVER = { "%s's burning up. That's not a cold.", "Look at %s. Sweating, shaking. You all know what that is." }
local ASK_HIDDEN = { "...Yeah. I didn't want you to know.", "...How did you know? Yeah. I'm bit." }
local ASK_KNOWN = { "You know I am.", "Don't make me say it again." }
local ASK_CLEAN = { "No. I'm clean. Check if you want.", "No. Not a scratch on me." }
local GO_Q = { "I'll go. Lock the door behind me.", "Alright. Put me somewhere. Just... check on me." }
local NO_Q = "Where do you want me? Somewhere with a door."
local ACCEPT = { "Do it before I turn. And do it yourself. Not them.", "When it's time, you do it. Promise me." }
local PLEAD = { "Please... not yet. Give me till morning.", "Wait. Wait! Maybe it's not... please." }
local HARD = { "We should end it now. Before %s turns on us.", "Quarantine? %s is already dead. We're just waiting." }
local SOFT = { "%s's still in there. Give it time.", "You'd really do it? Just like that, to %s?" }
local MERCY = { "It had to be done.", "...Rest now, %s.", "Somebody had to. I'm glad it wasn't me." }

-- someone else at home reacts (one line), picked by personality
local function reactor(player, notUid, want)
    local best, bs = nil, 0
    for _, u in ipairs(M.cpPeople(player)) do
        if u ~= notUid then
            local l = lens(u)
            local s = 0
            for k, w in pairs(want) do s = s + L(l, k) * w end
            if s > bs then best, bs = u, s end
        end
    end
    return best
end
local function sayAs(uid, line) if not H.say(H.shellFor(uid), line) then H.halo(H.firstName(uid) .. ": " .. line) end end

-- the camp now knows. how: "told" | "medic" | "fever" | "asked"
function M.cbReveal(uid, how, player, by)
    uid = tostring(uid)
    local b = M.cbData().bit[uid]
    if type(b) ~= "table" or b.known then return false end
    b.known, b.how = true, how
    local name = H.firstName(uid)
    if how ~= "told" then M.cbStats.found = M.cbStats.found + 1 end
    if how == "medic" and by then sayAs(by, H.pickLine(FOUND_MEDIC, uid))
    elseif how == "fever" then
        local w = by or reactor(player, uid, { paranoid = 1, brave = 0.5, calm = 0.3 })
        if w then sayAs(w, string.format(H.pickLine(FEVER, uid), name)) end
    end
    H.log(name .. " (" .. uid .. ") bitten, camp knows (" .. how .. ")")
    M.cpLog("bite", name .. " was bitten" .. (b.hid and " and hid it" or ""))
    M.cpRelease(uid, H.shellFor(uid))
    if ALifeSide.canOutCard() then
        local HOW = { told = "told you", medic = "was found out by the medic", fever = "was given away by the fever", asked = "admitted it when you asked" }
        local left = math.max(1, math.floor((tonumber(b.turnAt) or H.hours()) - H.hours() + 0.5))
        local choices, def = {}, 1
        for i, id in ipairs(M.cbRules) do
            choices[i] = { label = M.cbRuleLabel[id], fn = function() M.cbApply(uid, id, player) end }
            if id == M.cbRule() then def = i end
        end
        b.pending = true
        ALifeSide.outCard(player or H.thePlayer(), { id = "bite:" .. uid, title = name .. " is bitten", default = def, choices = choices,
            text = name .. " " .. (HOW[how] or "is bitten") .. "." .. (b.hid and " They hid it from you." or "")
                .. " <LINE> <LINE> They'll turn in about " .. left .. " hour" .. (left == 1 and "" or "s") .. ". What does the camp do?" })
        return true
    end
    H.halo(name .. " is bitten." .. (b.hid and " They hid it." or ""), 255, 120, 100)
    return M.cbApply(uid, M.cbRule(), player)
end
-- how the camp judges your call: the hard ones respect putting them down, the soft ones resent it (and the
-- reverse for quarantine). Someone close to the bitten takes a put-down hard. Small numbers, and never for the bitten.
function M.cbJudge(uid, mercy, player)
    local NO = H.PA().NpcOpinion
    if not (NO and type(NO.adjust) == "function") or player == nil then return 0 end
    local n = 0
    for _, u in ipairs(M.cpPeople(player)) do
        if u ~= uid then
            local l = lens(u)
            local hard = L(l, "paranoid") + L(l, "mean") + 0.5 * L(l, "disciplined") - L(l, "kind") - 0.8 * L(l, "romantic") - 0.3 * L(l, "devout")
            local v = mercy and hard * 4 or -hard * 3
            if mercy and H.fn(M, "pairRow") then
                local ok, row = pcall(M.pairRow, u, uid, true)
                if ok and type(row) == "table" and (tonumber(row.s) or 0) >= 40 then v = v - 6 end
            end
            v = math.max(-8, math.min(6, math.floor(v + 0.5)))
            local r = H.rec(u)
            if v ~= 0 and r then
                pcall(NO.adjust, r, player, v, mercy and ("you chose to put " .. H.firstName(uid) .. " down") or ("you kept " .. H.firstName(uid) .. " alive in quarantine"))
                n = n + 1
            end
        end
    end
    return n
end
-- what the camp does with this bitten person: "quarantine" | "putdown" | "choice"
function M.cbApply(uid, rule, player)
    uid = tostring(uid)
    local b = M.cbData().bit[uid]
    if type(b) ~= "table" then return false end
    b.pending, b.rule = nil, rule
    local name = H.firstName(uid)
    local mercy = rule == "putdown" or (rule == "choice" and M.cbChoosesMercy(uid))
    b.mercy = mercy
    if rule ~= "choice" then pcall(M.cbJudge, uid, mercy, player or H.thePlayer()) end -- their own choice isn't on you
    local d = M.cbData()
    if mercy then
        local l = lens(uid)
        local scared = L(l, "fearful") > L(l, "brave") and rule == "putdown"
        sayAs(uid, H.pickLine(scared and PLEAD or ACCEPT, uid))
        H.halo(rule == "choice" and (name .. " asks you to do it, before they turn.") or ("Your rule: put them down. It falls to you."), 255, 150, 110)
        local soft = reactor(player, uid, { kind = 1, romantic = 0.8, devout = 0.3 })
        if soft then sayAs(soft, string.format(H.pickLine(SOFT, uid), name)) end
    else
        sayAs(uid, d.quarantine and H.pickLine(GO_Q, uid) or NO_Q)
        if not d.quarantine then H.halo("Mark a quarantine room: Camp > The bitten > Quarantine room here.") end
        local hard = reactor(player, uid, { paranoid = 1, mean = 1, disciplined = 0.3 })
        if hard then sayAs(hard, string.format(H.pickLine(HARD, uid), name)) end
    end
    return true
end

-- watch for new bites, medics finding hidden ones, fevers giving them away
M.cbScanAt = -1e12
function M.cbTick(player)
    if not M.cbOn() then return end
    local now = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
    if now - M.cbScanAt < M.cbCfg.scanMs then return end
    M.cbScanAt = now
    local d = M.cbData()
    local h = H.hours()
    local people = M.cpPeople(player)
    local medics = {} -- 0.6.16: from the same list (it used to build the camp list twice per scan)
    for _, u in ipairs(people) do if M.cpRoleOf(u) == "medic" then medics[#medics + 1] = u end end
    for _, uid in ipairs(people) do
        local t = M.cbTurnAt(uid)
        local b = d.bit[uid]
        if t and b == nil then
            b = { turnAt = t, at = h, known = false }
            d.bit[uid] = b
            M.cbStats.bitten = M.cbStats.bitten + 1
            if M.cbHides(uid) then
                b.hid = true
                M.cbStats.hid = M.cbStats.hid + 1
                H.log(H.firstName(uid) .. " (" .. uid .. ") was bitten and is hiding it")
            else
                M.cbStats.told = M.cbStats.told + 1
                sayAs(uid, H.pickLine(TOLD, uid))
                M.cbReveal(uid, "told", player)
            end
        elseif b and not b.known then
            local medic = nil
            for _, m in ipairs(medics) do if m ~= uid then medic = m; break end end
            if medic and h - b.at >= M.cbCfg.medicFindsH then M.cbReveal(uid, "medic", player, medic)
            elseif h >= b.at + (b.turnAt - b.at) * M.cbCfg.feverAt then M.cbReveal(uid, "fever", player) end
        end
    end
end

-- death: a mercy kill isn't murder; anyone else bitten who dies is just gone
table.insert(M.cpDeathHooks, function(body, uid, killer)
    uid = tostring(uid)
    local d = M.cbData()
    local b = d.bit[uid]
    if type(b) ~= "table" then return false end
    d.bit[uid] = nil
    local player = H.thePlayer()
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and ALifeSide.isOnlinePlayer(killer) then player = killer end -- MP: the killer
    local byYou = false
    if player and H.fn(M, "killerOf") then local ok, _, ku = pcall(M.killerOf, killer, player, body); byYou = ok and ku == "player" end
    if byYou and b.known then
        M.cbStats.mercy = M.cbStats.mercy + 1
        local bx, by = H.pos(body)
        for _, u in ipairs(M.cpPeople(player)) do
            local sx, sy = H.pos(H.shellFor(u))
            if sx and bx and H.d2(sx, sy, bx, by) <= M.cbCfg.witnessTiles ^ 2 then
                sayAs(u, string.format(H.pickLine(MERCY, u .. uid), H.firstName(uid)))
                break
            end
        end
        H.log("mercy: " .. uid .. " (bitten, the camp knew)")
        return true -- not murder: skip the rules check
    end
    if not byYou then M.cbStats.turned = M.cbStats.turned + 1 end
    return false
end)

-- fear while a known bitten is in the camp
M.cpMoraleHooks = M.cpMoraleHooks or {}
table.insert(M.cpMoraleHooks, function(uid, r, st, player)
    if not M.cbOn() then return 0 end
    for u, b in pairs(M.cbData().bit) do if type(b) == "table" and b.known and u ~= uid then return 1.5 end end
    return 0
end)

-- the known bitten go to the quarantine room (before the watch, before anything)
M.cpAddJob({
    kind = "quarantine", order = -10,
    pick = function(uid, shell, player, b, now)
        if not M.cbOn() or not M.cbKnown(uid) or M.cbData().bit[tostring(uid)].pending then return nil end
        local q = M.cbData().quarantine
        if q == nil then return nil end
        return { key = "quarantine:" .. uid }
    end,
    spot = function(j) return M.cbData().quarantine end,
    ms = function(j) return 6000 end,
    run = function(j, uid, shell, player) return M.cbKnown(uid) and "again" or "done" end,
})

-- "are you bitten?"
table.insert(M.cpIntents, { id = "CAMP_BITTEN_ASK", kind = "bitten_ask", patterns = "are you bitten|did you get bit|were you bitten|did you get bitten|show me your arm|let me see your arm|let me see the wound" })
local baseOrder = M.cpOrder
function M.cpOrder(kind, record, player)
    if kind ~= "bitten_ask" then return baseOrder(kind, record, player) end
    local uid = tostring(record.uid)
    if not M.cbOn() or not M.cpIsHome(uid, player) then return nil end
    local b = M.cbData().bit[uid]
    if type(b) ~= "table" then
        if M.cbTurnAt(uid) then M.cbTick(player); b = M.cbData().bit[uid] end
    end
    if type(b) ~= "table" then return H.pickLine(ASK_CLEAN, uid) end
    if b.known then return H.pickLine(ASK_KNOWN, uid) end
    local line = H.pickLine(ASK_HIDDEN, uid)
    M.cbReveal(uid, "asked", player)
    return line
end

-- menu: Camp > The bitten
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local bm, bo = child("The bitten")
    if not M.cbOn() then off(bo, "Bites are off in this world's sandbox settings.") end
    local d = M.cbData()
    local cur = M.cbRule()
    for _, id in ipairs(M.cbRules) do
        local o = bm:addOption((id == cur and "Rule now: " or "Rule: ") .. M.cbRuleLabel[id], nil, function() M.cpAct("cbRule", id, nil, nil, nil, nil, player) end)
        if id == cur then off(o, "Already the rule.") end
    end
    local q = d.quarantine
    if q and q.x == x and q.y == y and q.z == z then
        bm:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_quarantine_room_anymore", "Not the quarantine room anymore"), nil, function() M.cpAct("cbQuarantineOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = bm:addOption(q and "Move the quarantine room here" or "Quarantine room here", nil, function() M.cpAct("cbQuarantine", x, y, z, nil, nil, player) end)
        if not inRange then off(o, why or "Too far from your base.") end
    end
    for u, b in pairs(d.bit) do
        if type(b) == "table" and b.known then
            local o = bm:addOption(H.firstName(u) .. " is bitten" .. (b.mercy and " (asked you to do it)" or ""))
            off(o, "They will turn. It's a matter of hours.")
        end
    end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender)
M.cpActs = M.cpActs or {}
M.cpActs.cbRule = function(player, id)
    id = tostring(id)
    if M.cbRuleLabel[id] == nil then return false end
    M.cbData().biteRule = id
    H.halo("Camp rule for the bitten: " .. string.lower(M.cbRuleLabel[id]) .. ".")
end
M.cpActs.cbQuarantineOff = function() M.cbData().quarantine = nil end
M.cpActs.cbQuarantine = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    M.cbData().quarantine = { x = x, y = y, z = z }
    H.halo("Quarantine room set. The bitten wait here. Somewhere with a door you can shut.")
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function() local q = M.cbData().quarantine; if q then return { { q, 0.9, 0.2, 0.6 } } end end)

-- AI: the bitten know
M.cpExtras = M.cpExtras or {}
table.insert(M.cpExtras, function(req, player, listener)
    if not M.cbOn() or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
    local uid = tostring(listener.record.uid)
    local b = M.cbData().bit[uid]
    if type(b) == "table" then
        if not b.known then return "You were bitten and you are hiding it. Deny it unless someone sees the wound. You're terrified." end
        return b.mercy and "You've been bitten and you'll turn soon. You asked to be put down before it happens."
            or "You've been bitten and you'll turn soon. You're in quarantine, waiting."
    end
    for u, ob in pairs(M.cbData().bit) do
        if type(ob) == "table" and ob.known then return H.firstName(u) .. " from your camp is bitten and will turn soon. It's all anyone thinks about." end
    end
end)

if type(Events) == "table" and Events.OnTick then
    ALifeHealth.add(Events.OnTick, "ALifeTalk_CampBitten", function()
        if M._cbDead then return end
        local ok, err = pcall(function() local p = H.thePlayer(); if p then M.cbTick(p) end end)
        if not ok then M._cbDead = true; H.log("bitten tick error, off for this session: " .. tostring(err)) end
    end)
end
