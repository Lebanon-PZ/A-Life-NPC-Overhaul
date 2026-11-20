-- A-Life Talk 0.5.1: PARTY: travel companions with a cap, offers / invites with real reasons, commands, stances, leaving, protection
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Party") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Party"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Party") end end -- 0.5.1.6 perf label
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Party", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
setting("party", true)
-- 0.5.1.3: [ALifeTalk][Party] diagnostics (join asked / verdict / added / follow order / count / removed)
function M.partyLog(msg) print("[ALifeTalk][Party] " .. tostring(msg)) end
local function plog(msg) M.partyLog(msg) end
local function nm(uid) return tostring(nameOf(rec(uid))) .. " (" .. tostring(uid) .. ")" end
setting("partyCap", 6) -- 0.8.2: 6 by default; slots above "partyFree" need prerequisites (ALifePartyCap)
M.partyCfg = { tick = 5000, offerGapH = 24, offerChance = 0.08, leaveOpinion = 5, starving = 0.85, bondEveryMs = 600000, dangerTiles = 8, dropAfterMs = 90000 }
M.partyStances = { "aggressive", "defensive", "passive" }
local function shellFor(uid) local pa = PA(); return fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil end
local function listenerOf(uid) local r = rec(uid); local sh = shellFor(uid); if r == nil then return nil end; return { record = r, shell = sh } end
-- 0.5.1.6: nil when it can't be read (never "0 = treated badly")
local function opinion(r, player) local v = nil; pcall(function() v = tonumber((PA().NpcOpinion.valueOf(r, player))) end); return v end
-- who is in the party: our list + the patch's companions + A-Life walk-with
function M.partyIsMember(uid, player)
    uid = tostring(uid)
    if bucket("party")[uid] then return true end
    local P = patch()
    if P and fn(P, "companionOf") and P.companionOf(uid) ~= nil then return true end
    local l = listenerOf(uid)
    return l ~= nil and player ~= nil and M.walkingWith and M.walkingWith(l, player) == true
end
-- pre-1.0 MP (P3): whose party. Single player: one party (yours). MP server: a row carries owner =
-- ALifeSide.keyOf(player) (set on join); a patch companion carries the A-Life player key it walks with. An old row
-- with no owner belongs to the player they really follow (claimed then). player nil = every party (world queries).
local function mpOn() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
function M.partyOwnerOk(uid, player)
    if not mpOn() or player == nil then return true end
    uid = tostring(uid)
    local b = bucket("party")[uid]
    if type(b) == "table" and b.owner ~= nil then return tostring(b.owner) == tostring(ALifeSide.keyOf(player)) end
    local P = patch()
    local c = P and fn(P, "companionOf") and P.companionOf(uid) or nil
    if type(c) == "table" and c.key ~= nil and fn(P, "playerKey") then
        local ok, k = pcall(P.playerKey, player)
        return ok and k ~= nil and tostring(c.key) == tostring(k)
    end
    return nil -- unknown (old row): who they follow decides
end
function M.partyMembers(player)
    local out, seen = {}, {}
    local function add(uid)
        uid = tostring(uid)
        if seen[uid] then return end
        seen[uid] = true
        local mine = M.partyOwnerOk(uid, player)
        if mine == nil then
            local b = bucket("party")[uid]
            local okL, live = pcall(M.partyIsMemberLive, uid, player)
            mine = okL and live == true
            if mine and type(b) == "table" then b.owner = ALifeSide.keyOf(player) end
        end
        if mine and rec(uid) then out[#out + 1] = uid end
    end
    for uid in pairs(bucket("party")) do add(uid) end
    local P = patch()
    if P and fn(P, "store") then local okS, d = pcall(P.store); if okS and type(d) == "table" and type(d.companions) == "table" then for uid in pairs(d.companions) do add(uid) end end end
    table.sort(out)
    return out
end
function M.partyJoin(uid, player, why)
    uid = tostring(uid)
    local b = bucket("party")
    if b[uid] then return false end
    b[uid] = { since = hours(), why = why, stance = "defensive" }
    if mpOn() and player ~= nil then b[uid].owner = ALifeSide.keyOf(player) end -- pre-1.0 MP: whose party
    local P = patch()
    if P and fn(P, "keepMark") then pcall(P.keepMark, uid, true) end -- never despawned / deleted while in the party
    if M.keyMem then pcall(M.keyMem, uid, "party", "Joined the newcomer's party") end
    if M.logInteraction then pcall(M.logInteraction, uid, "Joined your party", nil, nil, "event") end
    log("party: " .. uid .. " joined (" .. tostring(why) .. ")")
    plog("added " .. nm(uid) .. " (" .. tostring(why) .. ") - members now " .. #M.partyMembers(player) .. "/" .. tostring((M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6)))
    return true
end
-- leaving: A-Life's own WALK_STOP; protection off unless they settled at the base
function M.partyLeave(uid, player, why, line)
    uid = tostring(uid)
    local l = listenerOf(uid)
    local pa = PA()
    if l and player and fn(pa.Talk, "walkWith") then pcall(pa.Talk.walkWith, player, l, "WALK_STOP") end
    local P = patch()
    if P and fn(P, "stopCompanion") then pcall(P.stopCompanion, uid) end
    if M.followEnd then pcall(M.followEnd, uid) end
    local had = bucket("party")[uid] ~= nil
    bucket("party")[uid] = nil
    if had then plog("removed " .. nm(uid) .. ": " .. tostring(why) .. " - members now " .. #M.partyMembers(player)) end
    if P and fn(P, "owner") and P.owner(uid) == "party" then pcall(P.release, uid, "left the party") end -- 0.5.1.3 / patch 1.4
    if P and fn(P, "keepMark") and not bucket("settlers")[uid] then pcall(P.keepMark, uid, false) end
    if line and l and l.shell and M.say then M.say(l.shell, player, line, { record = l.record }) end
    if M.logInteraction then pcall(M.logInteraction, uid, "Left your party (" .. tostring(why) .. ")", nil, nil, "event") end
    log("party: " .. uid .. " left (" .. tostring(why) .. ")")
    return true
end
-- the cap and party-specific reasons on top of the recruit verdict (personality / faction / family / morale already in it)
function M.partyInstall()
    if M.partyWrapped or type(M.recruitVerdict) ~= "function" then return end
    M.partyWrapped = true
    local origV = M.recruitVerdict
    M.recruitVerdict = function(listener, player)
        local ok, why, need, v = M.partyVerdictCore(origV, listener, player)
        plog("join asked: " .. nm(listener.record.uid) .. " -> " .. (ok and "accepted" or "refused") .. " (" .. tostring(why) .. "; opinion "
            .. tostring(v) .. " / needs " .. tostring(need) .. ")")
        return ok, why, need, v
    end
    function M.partyVerdictCore(origV, listener, player)
        local ok, why, need, v = origV(listener, player)
        -- 0.5.1.3: refused only because A-Life's walk-with can't take them (own stance / cooldown / personal reputation
        -- off) although they trust you enough: with the patch they follow on a player order instead, so it's a yes
        if not ok and M.settings.party ~= false and tonumber(v) and tonumber(need) and v >= need and M.followVerdict then
            local P = patch()
            local fv = select(1, M.followVerdict(listener, player))
            if (fv == "busy" or fv == "walk_off") and P and fn(P, "playerOrder") then
                ok, why = true, "you trust them enough to drop what you were doing"
                plog(nm(listener.record.uid) .. ": A-Life walk-with would refuse (" .. tostring(fv) .. ") - they'll follow through the patch's order instead")
            end
        end
        if M.settings.party == false or not ok then return ok, why, need, v end
        local uid = tostring(listener.record.uid)
        if not M.partyIsMember(uid, player) and #M.partyMembers(player) >= (M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6) then
            return false, "your group is already " .. #M.partyMembers(player) .. " people - that's a crowd, too loud to move quiet", need, v
        end
        -- family first: they won't leave a partner / sibling behind unless that one comes too
        local fam = nil
        pcall(function() for _, t in ipairs(M.tiesOf and M.tiesOf(uid, player, 6) or {}) do if (t.type == "partner" or t.type == "sibling" or t.type == "family") and not t.dead then fam = t; break end end end) -- 0.5.2.6: not a late partner
        if fam and fam.uid and not M.partyIsMember(fam.uid, player) then
            local lens = M.lens and M.lens(uid) or {}
            if (lens.loyal or 0) + (lens.kind or 0) > 0.5 and #M.partyMembers(player) + 1 >= (M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6) then
                return false, "you won't leave " .. tostring(fam.name or "your family") .. " behind, and there's no room for both", need, v
            end
        end
        return ok, why, need, v
    end
    local origA = M.recruitApply
    if type(origA) == "function" then
        M.recruitApply = function(listener, player)
            local uid = tostring(listener.record.uid)
            local ok = origA(listener, player)
            local via = "A-Life walk-with"
            local P = patch()
            if ok and P and fn(P, "companionOf") and P.companionOf(uid) ~= nil then via = "A-Life walk-with + patch companion mode" end
            if not ok and M.settings.party ~= false then
                -- 0.5.1.3: A-Life's walk-with refuses NPCs with their own stance (squad / guard / patrol), on cooldown, or
                -- when A-Life's personal reputation is off. They agreed, so they follow through the patch's player order
                local why = M.followVerdict and select(1, M.followVerdict(listener, player)) or "?"
                if P and fn(P, "playerOrder") then
                    local okO, r = pcall(P.playerOrder, uid, "follow", player)
                    if okO and r == true then ok, via = true, "patch follow order (A-Life walk-with refused: " .. tostring(why) .. ")" end
                end
                if not ok then plog("follow FAILED for " .. nm(uid) .. ": A-Life walk-with refused (" .. tostring(why) .. ")" .. (P and ", patch order refused" or ", no patch")) end
            end
            if ok and M.settings.party ~= false then
                M.partyJoin(uid, player, "asked")
                local b = bucket("party")[uid]
                if b then b.via = via; b.order = (string.find(via, "order", 1, true) and "follow") or nil end
                plog("follow order issued for " .. nm(uid) .. " via " .. via)
            end
            return ok
        end
    end
    -- "roll with me" and friends count as an invite
    if type(M.rpWords) == "table" and type(M.rpWords.recruit) == "table" then
        for _, w in ipairs({ "roll with me", "want to roll", "wanna roll", "ride with us", "come on the road", "travel with us", "join my party", "join the party" }) do
            local have = false
            for _, x in ipairs(M.rpWords.recruit) do if x == w then have = true end end
            if not have then table.insert(M.rpWords.recruit, w) end
        end
    end
    -- named orders: "Troy, hold here" goes to Troy only; "everyone" / no name -> the whole party (A-Life obey chance kept)
    if type(M.playerOrder) == "function" and not M.partyOrderWrapped then
        M.partyOrderWrapped = true
        local origO = M.playerOrder
        M.playerOrder = function(player, text)
            local named = M.partyNamed(player, text)
            local low = string.lower(tostring(text or ""))
            if named and not (string.find(low, "everyone", 1, true) or string.find(low, "all of you", 1, true) or string.find(low, "everybody", 1, true)) then
                local kind = M.parseOrder and M.parseOrder(text) or nil
                local P = patch()
                if kind and P and fn(P, "playerOrder") then
                    local chance = M.obeyChance and M.obeyChance(named, "player", kind) or 80
                    local done = false
                    if ZombRand(100) < chance then local okO, r = pcall(P.playerOrder, named, kind, player); done = okO and r == true end
                    local l = listenerOf(named)
                    if l and l.shell and M.say and M.ackLine then M.say(l.shell, player, M.ackLine(named, done), { record = l.record }) end
                    M.lastOrder = M.lastOrder or {}
                    M.lastOrder[named] = { kind = kind, obeyed = done, at = nowMs() }
                    return kind, { { uid = named, obeyed = done, chance = chance } }
                end
            end
            return origO(player, text)
        end
    end
end
M.partyInstall()
if type(Events) == "table" and Events.OnGameStart and Events.OnGameStart.Add then Events.OnGameStart.Add(function() pcall(M.partyInstall) end) end
function M.partyNamed(player, text)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    for _, uid in ipairs(M.partyMembers(player)) do
        local r = rec(uid)
        local f = r and string.lower(firstOf(r)) or nil
        if f and #f >= 3 and string.find(low, "[^%a]" .. f .. "[^%a]") then return uid end
    end
    return nil
end
-- party words beyond orders: "go to the base", "you can go / dismissed", stance
M.partyWords = {
    base = { "go to the base", "go back to base", "head to the base", "go home", "head home", "back to base", "wait at the base", "go to base" },
    dismiss = { "you're dismissed", "you are dismissed", "dismissed", "you can go", "go your own way", "leave the party", "part ways", "we're done here" },
    unfollow = { "stop following", "quit following", "stop tagging along", "don't follow me", "dont follow me", "no longer follow", "stop walking with me" },
    aggressive = { "go aggressive", "weapons free", "kill everything", "be aggressive" },
    defensive = { "stay defensive", "defend yourself", "defensive" },
    passive = { "don't fight", "stay out of fights", "hold fire", "be passive", "avoid fights" },
}
local function anyWord(low, list) for _, w in ipairs(list) do if string.find(low, w, 1, true) then return true end end; return false end
function M.partyCommand(uid, cmd, player)
    uid = tostring(uid)
    local P = patch()
    local l = listenerOf(uid)
    if cmd == "follow" or cmd == "hold" or cmd == "guard" then
        local b = bucket("party")[uid]
        if b then b.order = cmd; b.anchor = nil end
        if b then pcall(M.partyOwnStep, uid, player, b, nowMs(), 0) end -- 0.5.1.3: patch 1.4 drives them at once
        if P and fn(P, "playerOrder") then
            local ok, r = pcall(P.playerOrder, uid, cmd, player)
            plog("command " .. cmd .. " -> " .. nm(uid) .. ": " .. tostring(ok and r))
            return ok and r == true
        end
        plog("command " .. cmd .. " -> " .. nm(uid) .. ": needs ALifeTalkPatch")
        return false
    elseif cmd == "base" then
        local base = M.baseState and M.baseState(player) or nil
        if base == nil then if l and l.shell and M.say then M.say(l.shell, player, "What base? We don't have one.", { record = l.record }) end; return false end
        if M.settleApply and l and M.settleApply(l, player, base, {}) then
            M.partyLeave(uid, player, "sent to the base", "Alright. I'll be at the base.")
            return true
        end
        return false
    elseif cmd == "unfollow" then
        -- "stop following me": they stop for good (the party kept renewing the follow order, so they never did)
        return M.partyLeave(uid, player, "told to stop following", pick({ "Okay, okay. I'll keep my distance.", "Fine. I'll stay here.", "Alright. Not following." }, uid .. hours()))
    elseif cmd == "dismiss" then
        return M.partyLeave(uid, player, "dismissed", pick({ "Alright. Take care of yourself.", "Okay. You know where to find me.", "Fine by me. Stay alive." }, uid .. hours()))
    elseif cmd == "aggressive" or cmd == "defensive" or cmd == "passive" then
        local b = bucket("party")[uid]
        if b then b.stance = cmd end
        return b ~= nil
    elseif cmd == "talk" then
        M.lock = { uid = uid, untilMs = nowMs() + (M.settings.targetLockMs or 30000) }
        if M.openChat then pcall(M.openChat) end
        return true
    end
    return false
end
-- 0.5.2.9 [pt266u]: "go home" / "back to base" / "dismissed" only count as an ORDER to the party: said to them
-- ("go home", "you can go home", "Victoria, back to base"), not inside "let's go back to base", "we should head
-- home", "I want to go home" or a question - those sent the whole party home by accident (the left / joined /
-- sent home / left again ping-pong). Setting partyWordsStrict (default on).
M.partyLeadOk = { ["please"] = true, ["now"] = true, ["ok"] = true, ["okay"] = true, ["alright"] = true, ["right"] = true, ["hey"] = true,
    ["just"] = true, ["you"] = true, ["can"] = true, ["should"] = true, ["could"] = true, ["guys"] = true, ["all"] = true, ["everyone"] = true,
    ["everybody"] = true, ["both"] = true, ["of"] = true, ["and"] = true, ["then"] = true, ["so"] = true, ["fine"] = true, ["yeah"] = true, ["yes"] = true,
    ["go"] = true, ["better"] = true, ["you'd"] = true, ["youd"] = true, ["need"] = true, ["to"] = true, ["must"] = true, ["are"] = true, ["is"] = true }
M.partyNotOrder = { "let's", "lets", "let us", " we ", "we'", " us ", " us.", "together", "with me", "with you", "i want", "i need", "i'm", " im ",
    "i'll", "i will", "i wanna", "i miss", "i should", " my ", "when ", "after ", "before ", "if ", "gonna", "going to", "later", "soon", "someday",
    "should we", "can we", "could we", "don't", "dont", "never", "not " }
function M.partyWordsMeant(low, list, player)
    if M.settings.partyWordsStrict == false then return anyWord(low, list) end
    local names = {}
    for _, uid in ipairs(M.partyMembers and M.partyMembers(player) or {}) do
        local r = rec(uid)
        if r then names[string.lower(firstOf(r))] = true end
    end
    -- clause by clause: the phrase must lead its clause (only fillers / names before it) and the clause must not be a
    -- question, first-person or inclusive talk
    local src = " " .. string.lower(tostring(low or "")) .. " "
    for clause, stop in string.gmatch(src, "([^%.!%?;:]+)([%.!%?;:]?)") do
        local c = " " .. clause .. " "
        for _, w in ipairs(list) do
            local at = string.find(c, w, 1, true)
            if at and stop ~= "?" then
                local bad = false
                for _, nb in ipairs(M.partyNotOrder) do if string.find(c, nb, 1, true) then bad = true; break end end
                local lead = string.sub(c, 1, at - 1)
                lead = string.gsub(lead, ",", " ")
                for word in string.gmatch(lead, "%S+") do
                    if not (M.partyLeadOk[word] or names[word]) then bad = true end
                end
                if not bad then return true end
            end
        end
    end
    return false
end
function M.partyOnWords(player, text, loud, hearers)
    if M.settings.party == false then return end
    local low = string.lower(tostring(text or ""))
    local cmd = nil
    for _, k in ipairs({ "base", "dismiss", "unfollow", "aggressive", "defensive", "passive" }) do
        local meant = false
        if k == "base" or k == "dismiss" then meant = M.partyWordsMeant(low, M.partyWords[k], player)
        elseif k == "unfollow" then
            -- aimed at them, not a question, not about someone else ("stop following that car / him")
            meant = anyWord(low, M.partyWords[k]) and not string.find(low, "?", 1, true)
                and not anyWord(low, { " him", " her", " them", " that", " those", " the ", " why", " if " })
        else meant = anyWord(low, M.partyWords[k]) end
        if meant then cmd = k; break end
    end
    if cmd == nil then return end
    local named = M.partyNamed(player, text)
    local list = named and { named } or M.partyMembers(player)
    for _, uid in ipairs(list) do pcall(M.partyCommand, uid, cmd, player) end
    M.partyLastCmd = { cmd = cmd, n = #list, named = named, text = string.sub(tostring(text or ""), 1, 80) }
    if #list > 0 then log("party: your words were an order (" .. cmd .. ") for " .. #list .. ": \"" .. string.sub(tostring(text or ""), 1, 60) .. "\"") end
end
if type(M.playerWordHooks) == "table" then table.insert(M.playerWordHooks, M.partyOnWords) end
-- stances (A-Life has no stance API): passive members fall back to you when the dead get close, defensive ones stay close
function M.partyStanceStep(uid, player, b)
    local P = patch()
    if P == nil or not fn(P, "playerOrder") or not fn(P, "zombiesNear") then return end
    local sh = shellFor(uid)
    local x, y = pos(sh)
    if x == nil then return end
    local n = 0
    pcall(function() n = P.zombiesNear(x, y, M.partyCfg.dangerTiles) or 0 end)
    if n <= 0 then b.stanceAct = nil; return end
    local px, py = pos(player)
    local far = px and ((x - px) ^ 2 + (y - py) ^ 2) > 16
    if b.stance == "passive" and b.stanceAct ~= "fall_back" then b.stanceAct = "fall_back"; pcall(P.playerOrder, uid, "fall_back", player)
    elseif b.stance == "defensive" and far and b.stanceAct ~= "cover_me" then b.stanceAct = "cover_me"; pcall(P.playerOrder, uid, "cover_me", player) end
end
-- leave if treated badly, starving, or terrified with no bond; bonds between members grow on the road
function M.partyLeaveCheck(uid, player, now)
    local r = rec(uid)
    if r == nil then return nil end
    -- 0.5.1.6: only judged in person - unloaded / dormant / out of range never counts (going home is not mistreatment)
    if r.lifecycle ~= "active" then return nil end
    local sh0 = shellFor(uid)
    if sh0 == nil then return nil end
    local x0, y0 = pos(sh0)
    local px0, py0 = pos(player)
    if x0 == nil or px0 == nil or (x0 - px0) ^ 2 + (y0 - py0) ^ 2 > 60 * 60 then return nil end
    local v = opinion(r, player)
    if v == nil then return nil end
    if v < M.partyCfg.leaveOpinion then return "treated badly", pick({ "I'm done. You treat me like dirt.", "I'm out. Find someone else to push around." }, uid .. "bad") end
    local sh = shellFor(uid)
    local needs = (M.needsOf and sh) and M.needsOf(sh) or {}
    if (tonumber(needs.hunger) or 0) >= M.partyCfg.starving then return "starving", "I can't keep walking on an empty stomach. I'm going to find food." end
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    if (b.fear or 0) >= 0.8 and v < 30 then return "too dangerous", "This is suicide. I'm sorry - I'm out." end
    return nil
end
function M.partyTick(now)
    if M.settings.party == false then return end
    M.eachPlayer(M.partyTickFor, now) -- pre-1.0 MP (P3): every player's party (single player: yours)
end
function M.partyTickFor(player, now)
    if player == nil then return end
    local members = M.partyMembers(player)
    local pb = bucket("party")
    for idx, uid in ipairs(members) do
        local b = pb[uid]
        if b == nil then M.partyJoin(uid, player, "companion"); b = pb[uid] end
        if b then
            -- A-Life dropped them (and the patch has no companion entry): forget after a grace period
            local rr = rec(uid)
            local away = type(rr) == "table" and rr.lifecycle ~= "dead" and (rr.lifecycle ~= "active" or shellFor(uid) == nil)
            if away then
                b.goneAt = nil -- 0.5.1.6: unloaded / far away is not "left": they stay in your party until they really leave
            elseif not M.partyIsMemberLive(uid, player) then
                b.goneAt = b.goneAt or now
                if now - b.goneAt > M.partyCfg.dropAfterMs and M.settlerAway and M.settlerAway(uid) then -- 0.5.1.8: a settler on leave goes home
                    M.partyLeave(uid, player, "not following any more - back to the base", nil)
                elseif now - b.goneAt > M.partyCfg.dropAfterMs then pb[uid] = nil; log("party: " .. uid .. " no longer with you")
                    plog("removed " .. nm(uid) .. ": not following any more for 90 s (A-Life walk-with / companion / order all ended)") end
            else
                b.goneAt = nil
                local why, line = M.partyLeaveCheck(uid, player, now)
                if why then M.partyLeave(uid, player, why, line)
                else
                    -- 0.5.1.3: order-followers: renew the follow order when it ran out (unless you told them to hold / guard)
                    local P = patch()
                    local cur = nil
                    pcall(function() local d = PA().DecisionLoop; cur = type(d.orders) == "table" and d.orders[uid] or nil end)
                    local lapsing = cur == nil or cur.kind ~= "follow" or (tonumber(cur.untilMs) ~= nil and tonumber(cur.untilMs) - now < 30000)
                    if b.via and string.find(b.via, "order", 1, true) and b.order == "follow" and lapsing and P
                            and fn(P, "playerOrder") and now - (b.renewAt or -1e12) >= 20000 then
                        b.renewAt = now
                        local okO, r = pcall(P.playerOrder, uid, "follow", player)
                        plog("follow order renewed for " .. nm(uid) .. ": " .. tostring(okO and r))
                    end
                    pcall(M.partyStanceStep, uid, player, b)
                    pcall(M.partyOwnStep, uid, player, b, now, idx)
                    if now - (b.bondAt or now) >= M.partyCfg.bondEveryMs and M.pairBump then
                        for _, o in ipairs(members) do if o ~= uid and o > uid then pcall(M.pairBump, uid, o, 1, "on the road together") end end
                    end
                    b.bondAt = (b.bondAt == nil or now - b.bondAt >= M.partyCfg.bondEveryMs) and now or b.bondAt
                end
            end
        end
    end
    pcall(M.partyOfferTick, player, now, members)
end
-- 0.5.1.3 / patch 1.4: a party member is OWNED by the patch (A-Life's own decision step is skipped for them):
-- follow = stays a couple of tiles behind you (runs to catch up), hold / guard = stays at the spot where you said it.
-- A-Life gets them back instantly on danger (fight, flee, zombies close, hurt, targeted); they are re-claimed after.
function M.partyOwnStep(uid, player, b, now, slot)
    local P = patch()
    if P == nil or not fn(P, "claim") then return false end
    if M.settings.partyOwn == false or M.settings.ownBehaviour == false then
        if P.owner(uid) == "party" then P.release(uid, "setting off") end
        return false
    end
    local mode = b.order or "follow"
    local spec = { mode = mode, player = player, ms = 90000, slot = tonumber(slot) or 0 }
    if mode ~= "follow" then
        if b.anchor == nil then
            local sh = shellFor(uid)
            local x, y, z = pos(sh)
            if x then b.anchor = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) } end
        end
        spec.anchor = b.anchor
    end
    local ok, why = P.claim(uid, "party", spec)
    if not ok and why ~= b.ownWhy then plog("not driving " .. nm(uid) .. " (" .. mode .. "): " .. tostring(why) .. " - A-Life keeps them") end
    b.ownWhy = (not ok) and why or nil
    return ok
end
function M.partyIsMemberLive(uid, player)
    local P = patch()
    if M.partyOwnerOk(uid, player) == false then return false end -- pre-1.0 MP: another player's companion
    if P and fn(P, "companionOf") and P.companionOf(uid) ~= nil then return true end
    local l = listenerOf(uid)
    if l and M.walkingWith and M.walkingWith(l, player) then return true end
    local b = bucket("party")[tostring(uid)]
    if b and b.via and string.find(b.via, "order", 1, true) and l ~= nil and l.shell ~= nil then return true end -- 0.5.1.3
    if b and P and fn(P, "orderedBy") and P.orderedBy(uid) ~= nil and l ~= nil then return true end
    return P == nil and l ~= nil -- no patch: trust our own list while they're around
end
-- a friend may offer to come along (good standing, not at the cap)
function M.partyOfferTick(player, now, members)
    if #members >= (M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6) then return end
    local near = nearPlayer(4)
    local l = near[1]
    if l == nil or not idleOk(l, now) then return end
    local uid = tostring(l.record.uid)
    if M.partyIsMember(uid, player) or bucket("settlers")[uid] then return end
    local o = bucket("partyOffer")
    if hours() - (o[uid] or -1e9) < M.partyCfg.offerGapH then return end
    if ZombRand(1000) >= M.partyCfg.offerChance * 1000 then return end
    local ok, why = M.recruitVerdict and M.recruitVerdict(l, player)
    if not ok then return end
    local v = opinion(l.record, player)
    if v == nil or v < 55 then return end
    o[uid] = hours()
    M.partyOffered = M.partyOffered or {}
    M.partyOffered[uid] = now
    speak(l, player, "party", "You trust the newcomer (" .. tostring(why) .. "). Offer to travel with them for a while, in your own words",
        pick({ "Mind if I tag along for a while?", "You heading out? I could come with you.", "Want some company out there?" }, uid), { keyMs = 3600000, urgent = true })
end
-- "yes" to an offer: join through A-Life's walk-with like an accepted invite
function M.partyOnYes(player, text, loud, hearers)
    if M.settings.party == false or type(M.partyOffered) ~= "table" then return end
    local low = " " .. string.lower(tostring(text or "")) .. " "
    local yes = false
    for _, w in ipairs(M.yesWords or { " yes ", " yeah ", " sure ", " okay ", " ok ", " come on ", " let's go " }) do if string.find(low, w, 1, true) then yes = true end end
    if not yes then return end
    for uid, at in pairs(M.partyOffered) do
        if nowMs() - at < 60000 then
            local l = listenerOf(uid)
            if l and M.recruitApply then pcall(M.recruitApply, l, player) end
            M.partyOffered[uid] = nil
        end
    end
end
if type(M.playerWordHooks) == "table" then table.insert(M.playerWordHooks, M.partyOnYes) end
-- grief / last words: a party member's death is a party loss
if type(Events) == "table" and type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
    ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_Party", function(body, uid, killer)
        pcall(function()
            local b = bucket("party")[tostring(uid)]
            if b == nil then return end
            bucket("party")[tostring(uid)] = nil
            local lost = bucket("partyLost")
            lost[#lost + 1] = { uid = tostring(uid), h = hours() }
            -- pre-1.0 MP: the party they were in (their owner's); single player: yours
            local player = (type(b) == "table" and b.owner ~= nil and type(ALifeSide) == "table") and ALifeSide.byKey(b.owner) or ALifeSide.you()
            if player == nil then return end
            for _, o in ipairs(M.partyMembers(player)) do
                if M.feel then M.feel(o, "grief", 0.35, "lost a travelling companion") end
                if M.keyMem then pcall(M.keyMem, o, "loss", "Lost " .. firstOf(rec(uid) or {}) .. " on the road") end
            end
        end)
    end)
end
-- data for the window and the LLM
function M.partyData(player)
    local out = {}
    for _, uid in ipairs(M.partyMembers(player)) do
        local r = rec(uid)
        local sh = shellFor(uid)
        local w = M.woundState and select(2, pcall(M.woundState, uid, sh, r)) or nil
        if type(w) ~= "table" then w = {} end
        local mood = M.moodOf and select(2, pcall(M.moodOf, uid, 1)) or nil
        local weapon = nil
        if sh and sh.getPrimaryHandItem ~= nil then local it = sh:getPrimaryHandItem(); if it and it.getDisplayName ~= nil then weapon = it:getDisplayName() end end
        local hurt = {}
        if w.bitten then hurt[#hurt + 1] = "bitten" end
        if (w.bleeding or 0) > 0 then hurt[#hurt + 1] = "bleeding" end
        if w.fracture then hurt[#hurt + 1] = "fracture" end
        if w.limp then hurt[#hurt + 1] = "limping" end
        if w.downed then hurt[#hurt + 1] = "downed" end
        local b = bucket("party")[uid] or {}
        out[#out + 1] = { uid = uid, name = r and nameOf(r) or uid, hp = tonumber(w.hp) or 100, hurt = table.concat(hurt, ", "),
            mood = (type(mood) == "table" and mood[1]) and mood[1].adj or "steady", opinion = r and opinion(r, player) or 0,
            activity = M.activityLine and select(2, pcall(M.activityLine, uid)) or nil, weapon = weapon or "unarmed",
            stance = b.stance or "defensive", here = sh ~= nil, order = M.lastOrder and M.lastOrder[uid] and M.lastOrder[uid].kind or "follow" }
        if M.partyExtras then pcall(M.partyExtras, out[#out], sh, player) end -- 0.8.12: hunger, thirst, order, gear (PartyUI)
    end
    return out
end
table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.party == false then return end
    local uid = tostring(listener.record.uid)
    local members = M.partyMembers(player)
    if #members == 0 then return end
    local names = {}
    for _, m in ipairs(members) do if m ~= uid then local r = rec(m); if r then names[#names + 1] = firstOf(r) end end end
    req.party = { member = M.partyIsMember(uid, player) or nil, others = names, size = #members, cap = (M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6) }
end)
regMode("party")
everyMs(M.partyCfg.tick, M.partyTick)

-- 0.5.1.3: an invite INTO the player's party (not "can I join your group")
M.partyInviteExtra = { "join me", "join us", "join my", "come with me", "come with us", "roll with me", "roll with us", "ride with us",
    "travel with me", "travel with us", "be in my party", "be part of my", "join the party", "join our", "tag along", "team up" }
function M.partyInviteWords(text)
    local low = string.lower(tostring(text or ""))
    for _, w in ipairs({ "your group", "your party", "your crew", "your people", "join you", "can i join", "let me join", "may i join" }) do
        if string.find(low, w, 1, true) then return false end
    end
    for _, w in ipairs(M.partyInviteExtra) do if string.find(low, w, 1, true) then return true end end
    if type(M.rpWords) == "table" and type(M.rpWords.recruit) == "table" then
        for _, w in ipairs(M.rpWords.recruit) do if string.find(low, w, 1, true) then return true end end
    end
    return false
end
function M.partyRecruitNow(listener, player, why)
    if type(listener) ~= "table" or type(listener.record) ~= "table" or player == nil then return false end
    local uid = tostring(listener.record.uid)
    if M.partyIsMember(uid, player) and bucket("party")[uid] then plog(nm(uid) .. " is already in your party"); return true end
    if M.settings.recruiting == false or M.settings.party == false then plog("join asked: " .. nm(uid) .. " -> skipped (recruiting / party setting off)"); return false end
    if type(M.recruitVerdict) ~= "function" or type(M.recruitApply) ~= "function" then plog("join asked: recruit code missing"); return false end
    local ok = M.recruitVerdict(listener, player)
    if not ok then return false end
    if M.rpPending then M.rpPending[uid] = nil end -- done here; the after-reply step must not run it twice
    return M.recruitApply(listener, player) == true
end

-- pre-1.0 MP (P3): the party window on an MP client. Buttons go to the server (ALifeRemote "mcall": the sender is the
-- player), the list comes back as a view ("party": the sender's own party rows + cap). Single player: unchanged.
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    local R = ALifeRemote
    R.expose("partyCommand", 2, 3) -- (uid, cmd, player)
    R.expose("baseAsk", 2, 2)      -- (uid, player, how)
    local KEEP = { uid = true, name = true, hp = true, hurt = true, where = true, atBase = true, here = true, stance = true, order = true,
        hunger = true, thirst = true, gear = true, mood = true }
    R.view("party", function(player)
        local rows = (M.partyRows or M.partyData)(player) or {}
        local out = {}
        for i, row in ipairs(rows) do
            if i > 24 then break end
            local r = {}
            for k, v in pairs(row) do
                local t = type(v)
                if KEEP[k] and (t == "string" or t == "number" or t == "boolean") then r[k] = v end
            end
            local b = bucket("party")[tostring(row.uid)]
            if type(b) == "table" then r.stance = r.stance or b.stance; r.order = r.order or b.order end
            out[#out + 1] = r
        end
        out.cap = M.partyCapNow and M.partyCapNow(player) or tonumber(M.settings.partyCap) or 6
        return out
    end, {})
    -- the stance of one member as the window last saw it (MP client: from the view)
    function M.partyRowOf(uid)
        local v = R.cache.party
        if type(v) ~= "table" then return nil end
        for _, r in ipairs(v) do if tostring(r.uid) == tostring(uid) then return r end end
        return nil
    end
    -- MP client: the list functions answer from the view (the server's world), never the empty local save
    function M.partyRemoteInstall()
        if type(ALifeSide) ~= "table" or not ALifeSide.mpClient() or M._partyRemote then return false end
        M._partyRemote = true
        local function rows() local v = R.get("party") or {}; local out = {}; for i, r in ipairs(v) do out[i] = r end; return out end
        M.partyData = function() return rows() end
        if M.partyRows ~= nil then M.partyRows = function() return rows() end end
        M.partyCapNow = function() local v = R.get("party") or {}; return tonumber(v.cap) or tonumber(M.settings.partyCap) or 6 end
        R.onView("party", function()
            if M.partyWindow and M.partyWindow.refresh then pcall(M.partyWindow.refresh, M.partyWindow) end
            if M.homeWindow and M.homeWindow.refresh then pcall(M.homeWindow.refresh, M.homeWindow) end -- Nov17: the At home tab
        end)
        return true
    end
    if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(M.partyRemoteInstall) end) end
end

return M
