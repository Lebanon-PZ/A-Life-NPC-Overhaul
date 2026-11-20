-- A-Life NPC Overhaul 0.8.5: CAPTURED. You can be taken (Joe changed the "never lose control" rule, Nov 11).
-- How you're taken:
--   * surrendering in a stand-off to people who'd want you alive (captureSurrender %), or
--   * the last stand: people (never zombies) drop you and they'd want you alive (captureLastStand %): instead of the
--     killing blow you go down at lastStandHealth. A-Life NPCs hurt players through ProjectALife.Wounds.damagePlayer
--     (read in 1.5.1; in MP it runs where the hit is applied), so that's where it's caught.
-- Who takes you: outlaws and raiders (ransom), slavers (rough crews, only with dark content on), the army (the
--   Louisville National Guard = the Airport faction: forced work, released after captureWorkDays).
-- Then: they take your walkie and guns (real items, into their hands), bandage your bleeding with what THEY carry,
--   and march you to where they live: you black out (vanilla sleep: setForceWakeUpTime / setPlayerFallAsleep) while
--   the real walk time passes, and come to at their place. Real people, real travel; nothing is spawned.
-- Held: you can walk around, open (kick) doors, use a walkie if you somehow still have one (5 s to get the button down),
--   you're fed and watered; nothing else with your hands unless a captor helps you (talk them into it).
-- Ways out:
--   * talk them into letting you go (captureTalkOut % + how much they like you; ransom crews harder; the army won't),
--   * escape: get captureEscape tiles away with no awake guard seeing you. Seen past captureLeash tiles: dragged back,
--     watched closer (they see captureWatchStep tiles further each time), they like you less; rough crews may beat
--     you (real injury, no gore),
--   * your people rescue you: they find out (someone was with you, or you missed a radio check-in), then the camp rule
--     (set in game) and each one's bond decide who comes (real people from your base, real travel - Jeem's radio escort):
--       a "never leave a man behind, even if it costs us" -> love: pay the ransom (real things they carry) or anything,
--       b "never surrender, never leave a man behind"    -> need: by force only, if the odds are fair,
--       c "you're SOL"                                    -> fear: nobody comes ... except love (sometimes), and
--     the one sworn to you (The Oath) comes no matter what: one roll - captureOathDead % everyone in the camp is dead
--     and they're badly wounded, captureOathGun % they wake you and hand you a gun, else a normal rescue,
--   * the army lets you go after captureWorkDays,
--   * MP: the rest of your faction is warned.
-- Server-authoritative (state in global ModData); the client does what only the client can (your body: the black-out,
-- moving you, hunger and thirst, injuries; your hands).
require "ALifeNPCOverhaul/ALifeCmd"

ALifeCapture = ALifeCapture or {}
local C = ALifeCapture
local TAG = "[ALifeCapture]"
C.VERSION = "0.8.5"
C.metrics = C.metrics or { taken = 0, lastStands = 0, surrenders = 0, escaped = 0, caught = 0, talkedOut = 0, ransomed = 0,
    rescued = 0, oath = 0, worked = 0, freed = 0 }

C.DEFAULTS = {
    capture = true,             -- you can be taken by people who'd want you alive
    captureSurrender = 35,      -- % a crew that wants captives takes you when you surrender in a stand-off
    lastStand = true,           -- people who'd want you alive drop you instead of killing you (never zombies)
    lastStandHealth = 15,       -- ... you go down at this much health
    lastStandChance = 60,       -- ... % they do (else it's a fight to the death)
    captureWalkTiles = 300,     -- tiles per game hour when they march you home (the time that passes)
    captureMarchMax = 16,       -- most game hours the march takes
    captureLeash = 12,          -- tiles from where you're held: a guard who sees you past this drags you back
    captureEscape = 45,         -- tiles from where you're held, unseen: you're out
    captureWatchStep = 6,       -- tiles further they watch each time they catch you
    captureBeat = true,         -- rough crews may beat you when they catch you (real injury, no gore)
    captureFeedH = 8,           -- fed and watered every this many game hours
    captureTalkOut = 10,        -- % base chance talking your way out works (+ half of how much they like you)
    captureHelpTrust = 40,      -- how much a captor must like you to help you with your hands (30 game minutes)
    captureRescue = true,       -- your people come for you (camp rule, bonds, the Oath)
    captureFindOutH = 2,        -- game hours after they learn of it before they set out
    captureRansomItems = 4,     -- rule a: things your rescuers hand over
    captureOathDead = 20,       -- the Oath: % everyone in the camp is dead when they come
    captureOathGun = 50,        -- the Oath: % they wake you and hand you a gun
    captureWorkDays = 7,        -- the army: days of work before they let you go
    captureFightMin = 10,       -- rule b: game minutes after your people arrive before the fight is settled by the odds
    prisonerAnywhere = true,    -- take a surrendered person prisoner where they stand (false = only inside your base)
    prisonerLeashTiles = 30,    -- a prisoner out of your base stays held while you are this close
    prisonerRope = true,        -- taking a prisoner costs rope (they are tied up); off = no rope, no tying
    prisonerRopeCount = 1,      -- ... how many Base.Rope
    prisonerTiedEscape = 2,     -- ... % per day a TIED prisoner gets loose (untied ones use the old escape chance)
    prisonerCodeOrange = true,  -- ... an escape pops a priority 'Code Orange' message
    prisonerFindH = 24,         -- ... game hours you have to find someone who ran
    prisonerTellChance = 60,    -- ... % someone who got away tells their people about you
    prisonerAwayMin = 30,       -- ... game minutes you can be further than that (or out of your base) before they slip away
}
C.FILE_KEYS = {}
for k in pairs(C.DEFAULTS) do C.FILE_KEYS[#C.FILE_KEYS + 1] = k end
table.sort(C.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
local function roll(n) if type(ZombRand) == "function" then return ZombRand(n) end return 0 end
local function pct(p) return roll(100) < num(p, 0) end
local function call(o, m, ...)
    if o == nil then return nil end
    local f = o[m]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o, ...)
    if ok then return v end
    return nil
end
local function xyz(o) return num(call(o, "getX"), nil), num(call(o, "getY"), nil), num(call(o, "getZ"), 0) end

function C.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = C.DEFAULTS[key] end
    return v
end
function C.on() return C.setting("capture") ~= false end
function C.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return num(h, 0) end
function C.dark()
    local m = ALifeLLMTalk
    return type(m) == "table" and type(m.settings) == "table" and m.settings.darkContent == true
end

function C.store()
    local d = nil
    if ModData ~= nil and fn(ModData, "getOrCreate") then
        local ok, t = pcall(ModData.getOrCreate, "ALifeChatPlus_Capture")
        if ok then d = t end
    end
    if d == nil then C._mem = C._mem or {}; d = C._mem end
    if type(d.held) ~= "table" then d.held = {} end
    if type(d.rule) ~= "table" then d.rule = {} end
    return d
end
function C.keyOf(player)
    local pa = PA()
    if player ~= nil and pa ~= nil and fn(pa.Speech, "playerKey") then
        local ok, k = pcall(pa.Speech.playerKey, player)
        if ok and k ~= nil then return tostring(k) end
    end
    return "local"
end
function C.stateOf(player) return C.store().held[C.keyOf(player)] end
function C.isHeld(player) local s = C.stateOf(player); return type(s) == "table" and s.phase ~= "free" end

local function St() local pa = PA(); return pa and pa.Standoff or nil end
function C.record(uid) local pa = PA(); if pa and fn(pa.ActorRegistry, "read") then local ok, r = pcall(pa.ActorRegistry.read, tostring(uid)); if ok then return r end end return nil end
function C.shell(uid)
    local pa = PA()
    if pa and fn(pa.Talk, "shellFor") then local ok, s = pcall(pa.Talk.shellFor, tostring(uid)); if ok and s ~= nil then return s end end
    local wd = pa and pa.Watchdog
    local b = type(wd) == "table" and type(wd.bindings) == "table" and wd.bindings[tostring(uid)] or nil
    return type(b) == "table" and b.shell or nil
end
function C.nameOf(rec) local pa = PA(); if pa and fn(pa.Names, "of") then local ok, n = pcall(pa.Names.of, rec); if ok and n then return tostring(n) end end return "them" end
function C.alive(uid)
    local r = C.record(uid)
    if r == nil or r.lifecycle == "dead" then return false end
    local s = C.shell(uid)
    return s == nil or call(s, "isDead") ~= true
end

-- ---------------------------------------------------------------------------------------------------- who wants you
-- "ransom" (outlaws, raiders), "slaves" (rough, dark content only), "work" (the army = the Airport faction), or nil
function C.wantsAlive(record)
    local S = St()
    if type(record) ~= "table" or S == nil or not fn(S, "voice") then return nil end
    local voice = S.voice(record)
    voice = S.voiceOf and S.voiceOf[tostring(voice)] or voice
    if voice == "outlaw" then return "ransom" end
    if voice == "rough" then return C.dark() and roll(2) == 0 and "slaves" or "ransom" end
    if voice == "military" and type(ALifeSkyPower) == "table" and fn(ALifeSkyPower, "guardActive") then
        local on, s = ALifeSkyPower.guardActive()
        if on and type(s) == "table" and s.factionId ~= nil and tostring(record.factionId) == tostring(s.factionId) then return "work" end
    end
    return nil
end

-- the people fighting you right now, near you (A-Life: activity combat, aimed at a player)
function C.attackersNear(player, reach)
    local out = {}
    local pa = PA()
    if pa == nil or not fn(pa.ActorRegistry, "each") then return out end
    local px, py = xyz(player)
    if px == nil then return out end
    pa.ActorRegistry.each(function(rec)
        if type(rec) == "table" and rec.lifecycle == "active" and rec.activity == "combat" then
            local m = type(rec.memory) == "table" and rec.memory or {}
            local shell = C.shell(rec.uid)
            local x, y = xyz(shell)
            if x ~= nil and (m.combatTargetKind == nil or m.combatTargetKind == "player") and (x - px) ^ 2 + (y - py) ^ 2 <= reach * reach then
                out[#out + 1] = rec
            end
        end
        return #out >= 8
    end)
    return out
end

-- ---------------------------------------------------------------------------------------------------- taken
-- where they live: the leader's leash / home / where they started (A-Life memory), else right here
function C.homeOf(record, player)
    local m = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    for _, k in ipairs({ "leash", "home", "spawnOrigin" }) do
        local p = m[k]
        if type(p) == "table" and tonumber(p.x) ~= nil then return { x = num(p.x, 0), y = num(p.y, 0), z = num(p.z, 0) } end
    end
    local x, y, z = xyz(player)
    return { x = x or 0, y = y or 0, z = z or 0 }
end

-- your walkie and guns go into the leader's hands (real items). Returns what was taken (full types)
function C.strip(player, leaderUid)
    local taken = {}
    local shell = C.shell(leaderUid)
    local theirs = call(shell, "getInventory")
    local inv = call(player, "getInventory")
    local items = call(inv, "getItems")
    local n = num(call(items, "size"), 0)
    local pick = {}
    for i = 0, math.min(n, 300) - 1 do
        local it = items:get(i)
        local walkie = it ~= nil and it.getDeviceData ~= nil and call(call(it, "getDeviceData"), "getIsTwoWay") == true
        local gun = it ~= nil and type(instanceof) == "function" and instanceof(it, "HandWeapon") and call(it, "isRanged") == true
        if walkie or gun then pick[#pick + 1] = it end
    end
    for _, it in ipairs(pick) do
        pcall(function()
            if player:isEquipped(it) then player:removeFromHands(it) end
        end)
        local ok = pcall(function() inv:Remove(it) end)
        if ok then
            if type(isServer) == "function" and isServer() and type(sendRemoveItemFromContainer) == "function" then pcall(sendRemoveItemFromContainer, inv, it) end
            if theirs ~= nil then pcall(function() theirs:AddItem(it) end) end
            taken[#taken + 1] = tostring(call(it, "getFullType"))
        end
    end
    return taken
end

-- they stop your bleeding with what THEY carry (bandages, rags); nothing appears from nowhere
C.BANDAGES = { ["Base.Bandage"] = true, ["Base.AlcoholBandage"] = true, ["Base.RippedSheets"] = true, ["Base.BandageDirty"] = true }
function C.patchUp(player, uids)
    local bd = call(player, "getBodyDamage")
    local parts = call(bd, "getBodyParts")
    local n = num(call(parts, "size"), 0)
    local done = 0
    for i = 0, n - 1 do
        local part = parts:get(i)
        if call(part, "bleeding") == true and call(part, "bandaged") ~= true then
            local used = false
            for _, uid in ipairs(uids or {}) do
                local inv = call(C.shell(uid), "getInventory")
                local items = call(inv, "getItems")
                for j = 0, num(call(items, "size"), 0) - 1 do
                    local it = items:get(j)
                    local t = tostring(call(it, "getFullType"))
                    if C.BANDAGES[t] then
                        pcall(function() inv:Remove(it) end)
                        pcall(function() bd:SetBandaged(i, true, 10.0, false, t) end) -- vanilla SetBandaged(index, on, life, alcohol, type)
                        used, done = true, done + 1
                        break
                    end
                end
                if used then break end
            end
        end
    end
    return done
end

function C.reply(player, payload) if fn(ALifeCmd, "reply") then ALifeCmd.reply(player, "captureState", payload) end end

-- take the player. why = "surrender" | "last_stand". crew = list of records (first = leader)
function C.take(player, crew, kind, why)
    if not C.on() or player == nil or type(crew) ~= "table" or crew[1] == nil or C.isHeld(player) then return nil end
    local leader = crew[1]
    local st, key = C.store(), C.keyOf(player)
    local h = C.hours()
    local px, py, pz = xyz(player)
    local home = C.homeOf(leader, player)
    local d = math.sqrt(((home.x or 0) - (px or 0)) ^ 2 + ((home.y or 0) - (py or 0)) ^ 2)
    local march = math.min(num(C.setting("captureMarchMax"), 16), math.max(0.5, d / math.max(1, num(C.setting("captureWalkTiles"), 300))))
    local uids = {}
    for i, r in ipairs(crew) do if i <= 8 then uids[#uids + 1] = tostring(r.uid) end end
    -- someone of yours saw it (with you, not taken): your people will know
    local witness = nil
    local pa = PA()
    if pa ~= nil and fn(pa.ActorRegistry, "each") and fn(ALifeCommands, "isMine") then
        pa.ActorRegistry.each(function(rec)
            if type(rec) == "table" and rec.lifecycle == "active" then
                local ok, mine = pcall(ALifeCommands.isMine, tostring(rec.uid), player)
                local x, y = xyz(C.shell(rec.uid))
                if ok and mine and x ~= nil and (x - (px or 0)) ^ 2 + (y - (py or 0)) ^ 2 <= 900 then witness = tostring(rec.uid); return true end
            end
            return false
        end)
    end
    local s = { phase = "march", kind = kind, why = why, crew = uids, leader = tostring(leader.uid), leaderName = C.nameOf(leader),
        at = home, from = { x = px, y = py, z = pz }, startH = h, untilH = h + march, watch = 0, caught = 0, fedH = h,
        known = witness ~= nil, knownH = witness ~= nil and h + num(C.setting("captureFindOutH"), 2) or nil, witness = witness,
        rescue = nil }
    st.held[key] = s
    s.taken = C.strip(player, s.leader)
    s.patched = C.patchUp(player, uids)
    -- the crew walks home with you (on paper: A-Life brings them on there)
    C.moveCrew(s)
    -- a stand-off still running is over
    local S = St()
    local so = S and fn(S, "stateFor") and S.stateFor(player) or nil
    if so ~= nil and fn(S, "finish") then pcall(S.finish, so, "captured", fn(S, "now") and S.now() or 0) end
    C.metrics.taken = C.metrics.taken + 1
    if why == "surrender" then C.metrics.surrenders = C.metrics.surrenders + 1 else C.metrics.lastStands = C.metrics.lastStands + 1 end
    log("taken (" .. tostring(why) .. ", " .. tostring(kind) .. ") by " .. tostring(s.leaderName) .. ": march " .. math.floor(march * 60) .. " game min, took "
        .. #s.taken .. " things, bandaged " .. tostring(s.patched))
    C.reply(player, { phase = "march", x = home.x, y = home.y, z = home.z, hours = march, kind = kind, name = s.leaderName, why = why, taken = #s.taken })
    C.warnFaction(player, s)
    return s
end

-- captors home with you: their records move there; a loaded body is put away (A-Life brings it back on where it lives)
function C.moveCrew(s)
    local pa = PA()
    local reg = pa and pa.ActorRegistry
    if not fn(reg, "update") then return 0 end
    local n = 0
    for i, uid in ipairs(s.crew) do
        local r = C.record(uid)
        if r ~= nil and r.lifecycle ~= "dead" then
            local spot = { x = s.at.x + (i % 3) - 1, y = s.at.y + math.floor(i / 3) - 1, z = s.at.z or 0 }
            local ok = pcall(reg.update, r.uid, r.revision, function(e) e.worldPosition = spot; e.memory = type(e.memory) == "table" and e.memory or {}; e.memory.alcpCaptor = true end)
            if ok then n = n + 1 end
            if r.lifecycle == "active" and fn(pa.SpawnService, "dehydrate") then pcall(pa.SpawnService.dehydrate, r.uid, "alcp_capture") end
        end
    end
    return n
end

-- MP: the rest of your faction hears of it
function C.warnFaction(player, s)
    if not (type(isServer) == "function" and isServer()) or type(getOnlinePlayers) ~= "function" then return 0 end
    local J = ProjectALifeJimmy
    local B = J and J.BaseAreas
    if not fn(B, "who") then return 0 end
    local mine = B.who(player)
    local n = 0
    pcall(function()
        local l = getOnlinePlayers()
        for i = 0, l:size() - 1 do
            local p = l:get(i)
            if p ~= player then
                local w = B.who(p)
                if w ~= nil and mine ~= nil and w.faction ~= nil and w.faction == mine.faction then
                    ALifeCmd.reply(p, "captureNotice", { name = tostring(call(player, "getUsername") or "One of yours"), by = s.leaderName })
                    n = n + 1
                end
            end
        end
    end)
    return n
end

function C.free(player, why)
    local s = C.stateOf(player)
    if type(s) ~= "table" or s.phase == "free" then return false end
    s.phase, s.freeWhy, s.freeH = "free", why, C.hours()
    C.metrics.freed = C.metrics.freed + 1
    if why == "escaped" then C.metrics.escaped = C.metrics.escaped + 1 elseif why == "talked" then C.metrics.talkedOut = C.metrics.talkedOut + 1
    elseif why == "ransom" then C.metrics.ransomed = C.metrics.ransomed + 1 elseif why == "rescued" then C.metrics.rescued = C.metrics.rescued + 1
    elseif why == "oath" then C.metrics.oath = C.metrics.oath + 1 elseif why == "worked" then C.metrics.worked = C.metrics.worked + 1 end
    log("free (" .. tostring(why) .. ")")
    C.reply(player, { phase = "free", why = why, name = s.leaderName })
    return true
end

-- ---------------------------------------------------------------------------------------------------- the camp rule
C.RULES = { a = "We never leave a man behind, even if it costs us", b = "Never surrender, never leave a man behind",
    c = "Getting captured is for the weak: you're SOL" }
function C.rule(player) return C.store().rule[C.keyOf(player)] or "a" end
function C.setRule(player, r) if C.RULES[r] then C.store().rule[C.keyOf(player)] = r; return true end return false end

-- who comes for you, from your base: { uid, why = "oath" | "love" | "need" | "fear" }
function C.rescuers(player, s)
    local out = {}
    local J = ProjectALifeJimmy
    local B, R = J and J.BaseAreas, J and J.Residents
    if not (fn(B, "who") and fn(B, "basesFor") and fn(R, "atHome")) then return out end
    local who = B.who(player)
    local rule = C.rule(player)
    local key = fn(ALifeBonds, "keyOf") and ALifeBonds.keyOf(player) or C.keyOf(player)
    for _, base in ipairs(B.basesFor(who.key, who.faction, false) or {}) do
        for _, r in ipairs(R.atHome(base.id) or {}) do
            local uid = tostring(r.uid)
            if r.lifecycle ~= "dead" then
                local sworn = fn(ALifeOathWatch, "isSworn") and ALifeOathWatch.isSworn(uid)
                local row = fn(ALifeBonds, "row") and ALifeBonds.row(key, uid, false) or nil
                local stage = function(k) return row and fn(ALifeBonds, "stageOf") and ALifeBonds.stageOf(row[k]) or 0 end
                local l, n, f = stage("l"), stage("n"), stage("f")
                local why = nil
                if sworn then why = "oath"
                elseif l >= 2 and l >= f and (rule ~= "c" or roll(2) == 0) then why = "love"
                elseif n >= 2 and n >= f and rule ~= "c" then why = "need"
                elseif f >= 2 and roll(10) == 0 then why = "fear" end -- rare: scared of what you'll do if you get out
                if why ~= nil then out[#out + 1] = { uid = uid, why = why, base = base } end
            end
        end
    end
    -- need weighs the odds: not against a crew more than twice their number (rule b fights)
    local crew = 0
    for _, u in ipairs(s.crew or {}) do if C.alive(u) then crew = crew + 1 end end
    local kept = {}
    for _, x in ipairs(out) do
        if x.why ~= "need" or rule == "a" or #out * 2 >= crew then kept[#kept + 1] = x end
        if #kept >= 4 then break end
    end
    return kept
end

-- send them (Jeem's radio escort: real people, real road time, to where you are)
function C.sendRescue(player, s)
    local list = C.rescuers(player, s)
    s.rescue = { state = "none", uids = {}, rule = C.rule(player) }
    if #list == 0 then log("nobody comes (rule " .. s.rescue.rule .. ")"); return 0 end
    local J = ProjectALifeJimmy
    local ra = J and J.Residents and J.Residents.radio
    local n = 0
    for _, x in ipairs(list) do
        if fn(ra, "come") then
            local d = fn(ra, "distance") and ra.distance(x.base.id, s.at.x, s.at.y) or nil
            local ok, lines = pcall(ra.come, player, x.base, { uid = x.uid }, d, C.hours())
            if ok then n = n + 1; s.rescue.uids[#s.rescue.uids + 1] = x.uid; if x.why == "oath" then s.rescue.oath = x.uid end end
        end
    end
    s.rescue.state = n > 0 and "coming" or "none"
    log(n .. " coming for you (rule " .. s.rescue.rule .. (s.rescue.oath and ", the sworn one among them" or "") .. ")")
    return n
end

-- ---------------------------------------------------------------------------------------------------- every minute
local function near(uid, x, y, r) local sx, sy = xyz(C.shell(uid)); return sx ~= nil and (sx - x) ^ 2 + (sy - y) ^ 2 <= r * r end

-- an awake guard who can see you (A-Life ModuleCareful line of sight when it's there)
function C.seenBy(player, s, reach)
    local careful = PA() and PA().ModuleCareful
    local px, py = xyz(player)
    for _, uid in ipairs(s.crew or {}) do
        local r = C.record(uid)
        local shell = C.shell(uid)
        if r ~= nil and r.lifecycle == "active" and shell ~= nil and r.activity ~= "sleep" and call(shell, "isDead") ~= true
                and near(uid, px, py, reach) then
            local seen = true
            if fn(careful, "lineOfSight") then local ok, v = pcall(careful.lineOfSight, shell, player); seen = ok and v == true end
            if seen then return uid end
        end
    end
    return nil
end

-- kill someone for real (a real body; nobody is just deleted)
function C.kill(uid)
    local shell = C.shell(uid)
    if shell == nil then return false end
    local sim = PA() and PA().ShellSimulation
    if fn(sim, "setHealth") then return pcall(sim.setHealth, shell, 0) end
    return pcall(function() shell:setHealth(0) end)
end

-- the sworn one / rule a / rule b when your people get there
function C.resolve(player, s, h)
    local r = s.rescue
    local px, py = xyz(player)
    local here = {}
    for _, uid in ipairs(r.uids) do if C.alive(uid) and near(uid, px, py, 20) then here[#here + 1] = uid end end
    if #here == 0 then return false end
    r.arrivedH = r.arrivedH or h
    local captors = {}
    for _, uid in ipairs(s.crew) do if C.alive(uid) then captors[#captors + 1] = uid end end
    if #captors == 0 then return C.free(player, "rescued") end
    if r.oath ~= nil and not r.rolled then
        r.rolled = true
        local x = roll(100)
        if x < num(C.setting("captureOathDead"), 20) then
            for _, uid in ipairs(captors) do C.kill(uid) end
            local sh = C.shell(r.oath)
            local sim = PA() and PA().ShellSimulation
            if sh ~= nil then pcall(function() if fn(sim, "setHealth") then sim.setHealth(sh, 0.25) else sh:setHealth(0.25) end end) end
            C.reply(player, { phase = "oath", how = "dead", uid = r.oath, name = C.nameOf(C.record(r.oath)) })
            return C.free(player, "oath")
        elseif x < num(C.setting("captureOathDead"), 20) + num(C.setting("captureOathGun"), 50) then
            -- a gun from what they carry, into your hands
            local inv = call(C.shell(r.oath), "getInventory")
            local items = call(inv, "getItems")
            local gun = nil
            for j = 0, num(call(items, "size"), 0) - 1 do
                local it = items:get(j)
                if type(instanceof) == "function" and instanceof(it, "HandWeapon") and call(it, "isRanged") == true then gun = it; break end
            end
            if gun ~= nil then pcall(function() inv:Remove(gun); player:getInventory():AddItem(gun) end) end
            s.phase = "breakout"
            C.reply(player, { phase = "breakout", uid = r.oath, name = C.nameOf(C.record(r.oath)), gun = gun ~= nil })
            return true
        end
    end
    if r.rule == "a" and s.kind ~= "slaves" then
        -- ransom: the most valuable things your rescuers carry, into the leader's hands
        local take, given = num(C.setting("captureRansomItems"), 4), 0
        local theirs = call(C.shell(s.leader), "getInventory")
        local valueOf = PA() and PA().ModuleRobbery and PA().ModuleRobbery.valueOf
        local factsFor = PA() and PA().ModuleRobbery and PA().ModuleRobbery.factsFor
        for _, uid in ipairs(here) do
            local inv = call(C.shell(uid), "getInventory")
            local items = call(inv, "getItems")
            local list = {}
            for j = 0, num(call(items, "size"), 0) - 1 do
                local it = items:get(j)
                local v = 1
                if type(valueOf) == "function" and type(factsFor) == "function" then v = num(valueOf(factsFor(it, nil)), 1) end
                if v > 0 then list[#list + 1] = { it = it, v = v } end
            end
            table.sort(list, function(a, b) return a.v > b.v end)
            for _, e in ipairs(list) do
                if given >= take then break end
                if pcall(function() inv:Remove(e.it) end) then
                    if theirs ~= nil then pcall(function() theirs:AddItem(e.it) end) end
                    given = given + 1
                end
            end
        end
        C.reply(player, { phase = "ransom", given = given })
        return C.free(player, "ransom")
    end
    -- rule b (and slavers, who don't sell back): by force. A-Life's own fighting first; settled by the odds after a while
    if (h - r.arrivedH) * 60 >= num(C.setting("captureFightMin"), 10) then
        local mine, theirs = #here, #captors
        if roll(mine + theirs) < mine then
            for _, uid in ipairs(captors) do if near(uid, px, py, 30) then C.kill(uid) end end
            return C.free(player, "rescued")
        end
        C.kill(here[1])
        r.state, r.uids = "failed", {}
        C.reply(player, { phase = "rescue_failed", name = C.nameOf(C.record(here[1])) })
    end
    return false
end

function C.tickPlayer(player, h)
    local s = C.stateOf(player)
    if type(s) ~= "table" or s.phase == "free" then return end
    if s.phase == "march" then
        if h >= num(s.untilH, h) then
            s.phase, s.heldH = "held", h
            C.reply(player, { phase = "held", x = s.at.x, y = s.at.y, z = s.at.z, kind = s.kind, name = s.leaderName })
        end
        return
    end
    local px, py = xyz(player)
    if px == nil then return end
    local d = math.sqrt((px - s.at.x) ^ 2 + (py - s.at.y) ^ 2)
    local captors = 0
    for _, uid in ipairs(s.crew) do if C.alive(uid) then captors = captors + 1 end end
    if captors == 0 then return C.free(player, s.phase == "breakout" and "escaped" or "captors_dead") end
    -- escape / caught
    local sight = 20 + num(s.watch, 0) * num(C.setting("captureWatchStep"), 6)
    local guard = C.seenBy(player, s, sight)
    if d >= num(C.setting("captureEscape"), 45) and guard == nil then return C.free(player, "escaped") end
    if s.phase == "held" and d > num(C.setting("captureLeash"), 12) and guard ~= nil then
        s.watch, s.caught = num(s.watch, 0) + 1, num(s.caught, 0) + 1
        C.metrics.caught = C.metrics.caught + 1
        local rec = C.record(guard)
        local O = PA() and PA().NpcOpinion
        if rec ~= nil and fn(O, "adjust") then pcall(O.adjust, rec, player, -3, "Tried to run off.") end
        local S = St()
        local voice = (S and fn(S, "voice") and rec) and S.voice(rec) or nil
        local beat = C.setting("captureBeat") ~= false and (voice == "rough" or voice == "raider" or voice == "gang" or voice == "prison") and roll(2) == 0
        C.reply(player, { phase = "dragged", x = s.at.x, y = s.at.y, z = s.at.z, beat = beat and 8 or 0, name = C.nameOf(rec) })
    end
    -- fed and watered
    if h - num(s.fedH, h) >= num(C.setting("captureFeedH"), 8) then
        s.fedH = h
        C.reply(player, { phase = "fed" })
    end
    -- the army lets you go after the work
    if s.kind == "work" and h - num(s.heldH or s.startH, h) >= num(C.setting("captureWorkDays"), 7) * 24 then return C.free(player, "worked") end
    -- your people find out, set out, arrive
    if C.setting("captureRescue") ~= false then
        if not s.known and type(ALifeWalkie) == "table" and fn(ALifeWalkie, "missedCheckins") and ALifeWalkie.missedCheckins(player) >= 1 then
            s.known, s.knownH = true, h + num(C.setting("captureFindOutH"), 2)
        end
        if s.known and s.rescue == nil and h >= num(s.knownH, h) then C.sendRescue(player, s) end
        if type(s.rescue) == "table" and s.rescue.state == "coming" then C.resolve(player, s, h) end
    end
end

-- ---------------------------------------------------------------------------------------------------- talking
C.TALK_LINES = { yes = { "...Fine. Go. Before I change my mind.", "Get out of here. You were never here." },
    no = { "Nice try.", "Sit down and shut up.", "Not a chance." }, never = { "Orders. You work, then you go." },
    help_yes = { "Alright, hold still... there. Don't make me regret it.", "Fine. Just this once." }, help_no = { "Do it yourself." } }
local function pick(l) return l[roll(#l) + 1] end
-- { uid, ask = "free" | "hands" }
function C.serverTalk(player, args)
    local s = C.stateOf(player)
    if type(s) ~= "table" or s.phase ~= "held" or type(args) ~= "table" or type(args.uid) ~= "string" then return nil end
    local isCaptor = false
    for _, u in ipairs(s.crew) do if u == args.uid then isCaptor = true end end
    if not isCaptor then return nil end
    local rec = C.record(args.uid)
    if rec == nil then return nil end
    local O = PA() and PA().NpcOpinion
    local op = 0
    if fn(O, "valueOf") then local ok, v = pcall(O.valueOf, rec, player); op = ok and num(v, 0) or 0 end
    local out = { uid = args.uid, ask = args.ask }
    if args.ask == "hands" then
        out.ok = op >= num(C.setting("captureHelpTrust"), 40)
        out.line = pick(out.ok and C.TALK_LINES.help_yes or C.TALK_LINES.help_no)
        if out.ok then s.handsUntil = C.hours() + 0.5; out.untilH = s.handsUntil end
    else
        if s.kind == "work" then out.ok, out.line = false, pick(C.TALK_LINES.never)
        else
            local chance = num(C.setting("captureTalkOut"), 10) + math.max(0, op) / 2
            if s.kind == "ransom" then chance = chance / 2 elseif s.kind == "slaves" then chance = chance / 4 end
            s.talks = num(s.talks, 0) + 1
            out.ok = pct(chance)
            out.line = pick(out.ok and C.TALK_LINES.yes or C.TALK_LINES.no)
        end
    end
    if fn(ALifeCmd, "reply") then ALifeCmd.reply(player, "captureTalked", out) end
    if out.ok and args.ask ~= "hands" then C.free(player, "talked") end
    return out
end

-- ---------------------------------------------------------------------------------------------------- the hooks
-- surrender in a stand-off to people who'd want you alive
function C.wrapSurrender()
    local S = St()
    if not fn(S, "onPlayerEmote") or C._surrender then return false end
    C._surrender = true
    local orig = S.onPlayerEmote
    S.onPlayerEmote = function(player, emote, ...)
        local s = emote == "surrender" and fn(S, "stateFor") and S.stateFor(player) or nil
        local r = orig(player, emote, ...)
        if s ~= nil and C.on() and not C.isHeld(player) then
            local leader = S.read(s.leaderUid)
            local kind = C.wantsAlive(leader)
            if kind ~= nil and pct(C.setting("captureSurrender")) then
                local crew = {}
                for _, uid in ipairs(s.members or {}) do local rr = S.read(uid); if rr then if uid == s.leaderUid then table.insert(crew, 1, rr) else crew[#crew + 1] = rr end end end
                pcall(C.take, player, crew, kind, "surrender")
            end
        end
        return r
    end
    return true
end

-- the last stand: wrap A-Life's player wound (runs where the hit lands)
function C.wrapWounds()
    local W = PA() and PA().Wounds
    if not fn(W, "damagePlayer") or C._wounds then return false end
    C._wounds = true
    local orig = W.damagePlayer
    W.damagePlayer = function(bodyDamage, weapon, part, ...)
        local a, b = orig(bodyDamage, weapon, part, ...)
        if C.on() and C.setting("lastStand") ~= false then pcall(C.lastStand, bodyDamage) end
        return a, b
    end
    return true
end
function C.lastStand(bodyDamage)
    local floor = num(C.setting("lastStandHealth"), 15)
    local health = num(call(bodyDamage, "getOverallBodyHealth"), 100)
    if health >= floor then return false end
    local player = call(bodyDamage, "getParentChar")
    if player == nil or C.isHeld(player) or (C._downAt and C._downAt[C.keyOf(player)]) then return false end
    local crew = C.attackersNear(player, 30)
    local leader = crew[1]
    local kind = leader and C.wantsAlive(leader) or nil
    if kind == nil or not pct(C.setting("lastStandChance")) then return false end
    -- they pull the killing blow: you go down at the floor, wounds and all (vanilla AddGeneralHealth spreads it)
    pcall(function() bodyDamage:AddGeneralHealth(floor - health + 1) end)
    C._downAt = C._downAt or {}
    C._downAt[C.keyOf(player)] = true
    local uids = {}
    for _, r in ipairs(crew) do uids[#uids + 1] = tostring(r.uid) end
    if fn(ALifeCmd, "send") then ALifeCmd.send(player, "captureLastStand", { uids = uids, kind = kind }) end
    return true
end
function C.serverLastStand(player, args)
    if type(args) ~= "table" or type(args.uids) ~= "table" then return nil end
    if C._downAt then C._downAt[C.keyOf(player)] = nil end
    local crew = {}
    for _, uid in ipairs(args.uids) do local r = C.record(tostring(uid)); if r ~= nil and r.lifecycle ~= "dead" then crew[#crew + 1] = r end end
    local kind = crew[1] and C.wantsAlive(crew[1]) or nil -- the server checks again
    if kind == nil then return nil end
    return C.take(player, crew, kind, "last_stand")
end

function C.players()
    local out = {}
    pcall(function()
        if type(isServer) == "function" and isServer() and type(getOnlinePlayers) == "function" then
            local l = getOnlinePlayers()
            for i = 0, l:size() - 1 do out[#out + 1] = l:get(i) end
        else
            local p = getSpecificPlayer(0)
            if p ~= nil then out[1] = p end
        end
    end)
    return out
end
function C.tick()
    if type(isClient) == "function" and isClient() then return end
    local h = C.hours()
    for _, p in ipairs(C.players()) do pcall(C.tickPlayer, p, h) end
end

if fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("captureLastStand", function(p, a) return C.serverLastStand(p, a) end)
    ALifeCmd.onServer("captureTalk", function(p, a) return C.serverTalk(p, a) end)
    ALifeCmd.onServer("captureRule", function(p, a) if type(a) == "table" and C.setRule(p, a.rule) then ALifeCmd.reply(p, "captureRuleSet", { rule = a.rule, text = C.RULES[a.rule] }) end end)
    ALifeCmd.onServer("captureGetRule", function(p) ALifeCmd.reply(p, "captureRuleSet", { rule = C.rule(p), text = C.RULES[C.rule(p)] }) end)
end
function C.install()
    if C.installed then return true end
    C.installed = true
    local a = C.wrapSurrender()
    local b = C.wrapWounds()
    log("ready v" .. C.VERSION .. ": surrender " .. (a and "hooked" or "NOT hooked") .. ", last stand " .. (b and "hooked" or "NOT hooked")
        .. " (camp rule a/b/c, bonds, the Oath, escape, talk, army work)")
    return a and b
end
if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() local ok, e = pcall(C.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(C.install) end) end
    if Events.EveryOneMinute ~= nil then Events.EveryOneMinute.Add(function() local ok, e = pcall(C.tick); if not ok then log("tick failed: " .. tostring(e)) end end) end
end
