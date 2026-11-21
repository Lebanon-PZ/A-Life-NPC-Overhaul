-- A-Life Talk 0.4.1: roleplay systems on top of personalities (romance / lie / fear / greed values).
--   * recruiting   "join me / travel with me": gated by trust + personality; success = A-Life's own walkWith plus the
--                  patch's companion mode; failure = an in-character refusal with the real reason
--   * interrogation "where's their camp?": real A-Life data (Rumors dens, OutpostRegistry sites, SquadLedger crews,
--                  their own Haven) told truthfully, lied about (false spot), used as a trap (a manned raider den
--                  described as safe) or refused - by opinion, fear and the persona's lie/fear; what was told is kept
--   * romance      slow build: interested -> crush -> partner (only when the player asks), gated by persona romance,
--                  opinion and several in-game days of kindness; tasteful; shown in Ties / badge; partners grieve hardest
--   * promises     "I'll bring you meds" / "I'll be back tomorrow" -> memory with an in-game due time; kept by a matching
--                  gift / coming back; broken promises cost opinion and are brought up
--   * betrayal     broken promises and attacks are remembered; greedy or lying personalities whose opinion sours may
--                  rob you (patch: A-Life's robbery) or turn on you (patch: A-Life hostility) when they see a chance;
--                  rare, with cooldowns
-- Nothing in A-Life is edited; A-Life's own functions do every action.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Roleplay") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Roleplay"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Roleplay") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function bucket(name)
    local data = M.store()
    data[name] = type(data[name]) == "table" and data[name] or {}
    return data[name]
end
local function opinionOf(r, player)
    local pa = PA()
    if r == nil or player == nil or not fn(pa.NpcOpinion, "valueOf") then return 0 end
    local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
    return ok and tonumber(v) or 0
end
-- 0.5.1.6: nil = unknown (no record / unreadable). Unknown never counts as "drifted apart".
local function opinionKnown(r, player)
    local pa = PA()
    if type(r) ~= "table" or player == nil or r.lifecycle == "dead" or not fn(pa.NpcOpinion, "valueOf") then return nil end
    local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
    return ok and tonumber(v) or nil
end
local function adjust(r, player, delta, why)
    local pa = PA()
    if r == nil or player == nil or delta == 0 or not fn(pa.NpcOpinion, "adjust") then return end
    pcall(pa.NpcOpinion.adjust, r, player, delta, why)
end
local function mods(uid) return (M.personaMods and M.personaMods(uid)) or {} end
local function traits(uid)
    local out = {}
    pcall(function()
        local row = M.personaOf(uid)
        local p = row and M.personaParts(row)
        for _, t in ipairs(p and p.core.traits or {}) do out[t] = true end
    end)
    return out
end
local function pos(o)
    if o == nil then return nil end
    local ok, x, y, z = pcall(function() return o:getX(), o:getY(), o:getZ() end)
    if ok then return x, y, z end
    return nil
end
local function has(low, list) for _, w in ipairs(list) do if string.find(low, w, 1, true) then return w end end return nil end
local function ilog(uid, what, kind, b, a) if M.logInteraction then pcall(M.logInteraction, uid, what, b, a, kind) end end
local function kmem(uid, kind, text) if M.keyMem then pcall(M.keyMem, uid, kind, text) end end

M.rp = {
    recruitNeed = 45, recruitCooldownH = 2,
    intelRange = 2500,
    romanceDays = { 2, 3 }, romancePts = { 12, 30, 45 },
    promiseMaxOpen = 5, promiseKeep = 6, promiseBreak = -8, returnTiles = 20,
    betrayChance = 4, betrayCheckH = 6, betrayCooldownH = 72, betrayGlobalH = 24,
}

----------------------------------------------------------------------------------------------------------------
-- Intent detection (plain word lists; the model is told the outcome, it never decides it)
----------------------------------------------------------------------------------------------------------------
M.rpWords = {
    recruit = { "join me", "join us", "join my", "come with me", "come with us", "travel with me", "travel together",
        "team up", "ride with me", "stick with me", "stick together", "come along with me", "run with me", "be in my group",
        "join our group", "join the group", "want to come with", "wanna come with", "come with me?", "follow me" },
    intelTopic = { "camp", "base", "hideout", "hide out", "den", "raider", "bandit", "crew", "gang", "stash", "outpost",
        "supplies", "where you live", "where you stay", "your people", "survivors", "hiding", "safehouse", "safe house", "leader", "boss" },
    intelAsk = { "where", "tell me", "know any", "know of", "know about", "seen any", "heard of", "any ", "who ", "spill",
        "start talking", "talk!", "what do you know", "show me" },
    threat = { "or i'll", "or else", "or i will", "talk or", "start talking", "i'll kill you", "i will kill you",
        "i'll shoot", "don't make me", "last chance" },
    flirt = { "you're beautiful", "you are beautiful", "you're pretty", "you are pretty", "you're cute", "you are cute",
        "you're handsome", "you are handsome", "gorgeous", "i like you", "i really like you", "i love you", "kiss",
        "date", "you look nice", "you look good", "sweetheart", "darling", "beautiful eyes", "miss you", "thinking about you" },
    askOut = { "be my girlfriend", "be my boyfriend", "be my partner", "be with me", "go out with me", "be together",
        "be mine", "will you be my", "we should be together", "i want to be with you" },
    negate = { "i won't", "i will not", "i can't", "i cannot", "not gonna", "i'm not going to", "no way i" },
}
M.promiseItems = {
    { "medicine", { "med", "medicine", "pill", "antibiotic", "bandage", "painkiller", "first aid", "disinfectant", "drugs" } },
    { "alcohol", { "beer", "whiskey", "booze", "liquor", "vodka", "wine", "bourbon", "a drink" } },
    { "water", { "water", "something to drink" } },
    { "food", { "food", "something to eat", "eat", "can of", "canned", "beans", "meat", "chips", "soup", "bread" } },
    { "ammo", { "ammo", "bullets", "rounds", "shells", "cartridges" } },
    { "gun", { "gun", "rifle", "pistol", "shotgun", "revolver" } },
    { "weapon", { "weapon", "bat", "axe", "knife", "machete", "crowbar" } },
    { "clothing", { "jacket", "clothes", "boots", "shoes", "coat", "shirt" } },
    { "tool", { "tools", "hammer", "saw", "flashlight", "batteries", "radio" } },
}

function M.rpIntent(text)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    local out = {}
    if has(low, M.rpWords.recruit) then out.recruit = true end
    if has(low, M.rpWords.intelTopic) and (has(low, M.rpWords.intelAsk) or string.find(low, "?", 1, true)) then out.intel = true end
    if has(low, M.rpWords.threat) then out.threat = true end
    if has(low, M.rpWords.askOut) then out.askOut = true
    elseif has(low, M.rpWords.flirt) then out.flirt = true end
    return out
end

-- "I'll bring you some meds by tomorrow" -> { kind = "bring", what = "medicine", dueIn = 24, text = ... }
function M.parsePromise(text)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    low = string.gsub(low, "i will", "i'll")
    low = string.gsub(low, "i’ll", "i'll")
    low = string.gsub(low, " ill ", " i'll ")
    low = string.gsub(low, "gonna", "i'll")
    local bring = string.find(low, "i'll bring", 1, true) or string.find(low, "i'll get you", 1, true)
        or string.find(low, "i'll find you", 1, true) or string.find(low, "i'll fetch", 1, true)
        or string.find(low, "promise to bring", 1, true) or string.find(low, "i'll grab you", 1, true)
        or string.find(low, "i'll bring back", 1, true)
    local back = string.find(low, "i'll be back", 1, true) or string.find(low, "i'll come back", 1, true)
        or string.find(low, "i'll return", 1, true) or string.find(low, "see you tomorrow", 1, true)
        or string.find(low, "i'll check on you", 1, true) or string.find(low, "i'll visit", 1, true)
        or string.find(low, "i'll come see you", 1, true)
    local vow = string.find(low, "i promise", 1, true) or string.find(low, "you have my word", 1, true)
        or string.find(low, "i swear", 1, true)
    local at = bring or back or vow
    if at == nil then return nil end
    for _, n in ipairs(M.rpWords.negate) do
        local i = string.find(low, n, 1, true)
        if i ~= nil and i < at + 4 and i >= at - 4 then return nil end
    end
    local p = { text = string.sub(tostring(text), 1, 100) }
    if bring then
        p.kind, p.what, p.dueIn = "bring", "item", 48
        local rest = string.sub(low, bring)
        for _, row in ipairs(M.promiseItems) do
            if has(rest, row[2]) then p.what = row[1]; break end
        end
    elseif back then p.kind, p.dueIn = "return", 24
    else p.kind, p.dueIn = "vow", nil end
    local n = tonumber((string.match(low, "in (%d+) hours?")))
    if n then p.dueIn = n
    elseif string.match(low, "in (%d+) days?") then p.dueIn = 24 * tonumber((string.match(low, "in (%d+) days?")))
    elseif string.find(low, "tonight", 1, true) or string.find(low, "by dark", 1, true) then p.dueIn = 10
    elseif string.find(low, "tomorrow", 1, true) then p.dueIn = 30
    elseif string.find(low, "next week", 1, true) then p.dueIn = 168
    elseif string.find(low, "couple days", 1, true) or string.find(low, "couple of days", 1, true) then p.dueIn = 60
    elseif string.find(low, "in an hour", 1, true) then p.dueIn = 2
    elseif string.find(low, "soon", 1, true) or string.find(low, "later", 1, true) then p.dueIn = p.dueIn and math.min(p.dueIn, 18) or nil end
    if p.kind == "vow" then
        p.dueIn = nil
        p.what = string.match(low, "i promise (.-)[%.%!%?]") or string.match(low, "i promise (.+)") or "to do right by them"
        p.what = string.sub(string.gsub(p.what, "^%s+", ""), 1, 60)
    end
    return p
end

----------------------------------------------------------------------------------------------------------------
-- Promises
----------------------------------------------------------------------------------------------------------------
function M.promisesOf(uid)
    local all = bucket("promises")
    local list = all[tostring(uid)]
    if type(list) ~= "table" then list = {}; all[tostring(uid)] = list end
    return list
end
function M.openPromises(uid)
    local out = {}
    for _, p in ipairs(M.promisesOf(uid)) do if p.state == "open" then out[#out + 1] = p end end
    return out
end
M.promiseWords = { medicine = "medicine", alcohol = "something to drink (alcohol)", water = "water", food = "food",
    ammo = "ammo", gun = "a gun", weapon = "a weapon", clothing = "clothes", tool = "tools", item = "something useful" }
function M.promiseLabel(p)
    if p.kind == "bring" then return "bring " .. tostring(M.promiseWords[p.what] or p.what)
    elseif p.kind == "return" then return "come back" end
    return "promised " .. tostring(p.what)
end

function M.addPromise(uid, p, player)
    if type(p) ~= "table" then return nil end
    local list = M.promisesOf(uid)
    local open = M.openPromises(uid)
    for _, o in ipairs(open) do -- the same promise again just updates the due time
        if o.kind == p.kind and o.what == p.what then
            if p.dueIn then o.dueH = hours() + p.dueIn end
            return o, false
        end
    end
    if #open >= M.rp.promiseMaxOpen then return nil end
    local h = hours()
    local row = { kind = p.kind, what = p.what, text = p.text, madeH = h, dueH = p.dueIn and (h + p.dueIn) or nil, state = "open",
        day = math.floor(h / 24) }
    list[#list + 1] = row
    while #list > 20 do table.remove(list, 1) end
    kmem(uid, "promise", "You promised: " .. M.promiseLabel(row) .. (row.dueH and string.format(" (within %d h)", math.floor(p.dueIn)) or ""))
    ilog(uid, "Promise made: " .. M.promiseLabel(row) .. ' ("' .. string.sub(tostring(p.text), 1, 50) .. '")', "promise")
    log("promise to " .. tostring(uid) .. ": " .. M.promiseLabel(row) .. " due " .. tostring(row.dueH and math.floor(row.dueH) or "-"))
    return row, true
end

function M.settlePromise(uid, row, kept, player, why)
    if row.state ~= "open" then return end
    row.state, row.doneH = kept and "kept" or "broken", hours()
    local r = rec(uid)
    player = player or ALifeSide.you()
    local before = opinionOf(r, player)
    if kept then
        adjust(r, player, M.rp.promiseKeep, "You kept your word (" .. M.promiseLabel(row) .. ").")
        kmem(uid, "kindness", "You kept your promise: " .. M.promiseLabel(row))
        if M.romanceNote then M.romanceNote(uid, 4, "kept a promise") end
    else
        local b = M.betrayalOf(uid)
        b.broken = (b.broken or 0) + 1
        local d = M.rp.promiseBreak * math.min(2, 1 + ((b.broken or 1) - 1) * 0.5)
        adjust(r, player, math.floor(d), "You broke your promise (" .. M.promiseLabel(row) .. ").")
        kmem(uid, "threat", "You broke your promise: " .. M.promiseLabel(row))
        row.mention = true -- they'll bring it up next time they see you
    end
    local after = opinionOf(rec(uid), player)
    ilog(uid, (kept and "Promise kept: " or "Promise broken: ") .. M.promiseLabel(row) .. (why and (" (" .. why .. ")") or ""), "promise", before, after)
    log("promise " .. (kept and "kept" or "broken") .. " for " .. tostring(uid) .. ": " .. M.promiseLabel(row))
end

-- a gift arrived: does it keep a "bring" promise?
function M.promiseGift(uid, items, player)
    local hit = nil
    for _, row in ipairs(M.openPromises(uid)) do
        if row.kind == "bring" then
            for _, info in ipairs(items or {}) do
                local k = info.kind
                local match = (row.what == k) or (row.what == "item" and k ~= "junk")
                    or (row.what == "weapon" and k == "gun") or (row.what == "water" and k == "alcohol" and false)
                if match then hit = row; break end
            end
        end
        if hit then break end
    end
    if hit then M.settlePromise(uid, hit, true, player, "you brought it") end
    return hit
end

function M.promiseTick(player)
    local pa = PA()
    if player == nil then return end
    local h = hours()
    local px, py = pos(player)
    for uid, list in pairs(bucket("promises")) do
        local r = nil
        for _, row in ipairs(type(list) == "table" and list or {}) do
            if row.state == "open" then
                r = r or rec(uid)
                if r == nil or r.lifecycle == "dead" then row.state = "void"
                else
                    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
                    local sx, sy = pos(sh)
                    local near = sx ~= nil and px ~= nil and (sx - px) ^ 2 + (sy - py) ^ 2 <= M.rp.returnTiles ^ 2
                    if row.kind == "return" and near and h - row.madeH >= 1 then
                        M.settlePromise(uid, row, true, player, "you came back")
                    elseif row.dueH and h > row.dueH then
                        M.settlePromise(uid, row, false, player, "overdue")
                    elseif row.kind == "bring" and near and row.dueH and row.dueH - h <= 12 and not row.reminded
                            and h - row.madeH >= 2 then
                        row.reminded = true
                        M.react("promise", { record = r, shell = sh }, player, { what = "The newcomer promised to "
                            .. M.promiseLabel(row) .. " and it's due soon. Remind them, in your own way", maxWords = 14 },
                            { key = "promise:" .. tostring(uid), keyCooldownMs = 600000, face = "player" })
                    end
                end
            elseif row.state == "broken" and row.mention then
                r = r or rec(uid)
                local sh = r and fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
                local sx, sy = pos(sh)
                if sx ~= nil and px ~= nil and (sx - px) ^ 2 + (sy - py) ^ 2 <= 12 ^ 2 then
                    local ok = M.react("promise", { record = r, shell = sh }, player, { what = "The newcomer promised to "
                        .. M.promiseLabel(row) .. " and never did. Bring it up - hurt, angry or cold, as fits you", maxWords = 16 },
                        { key = "promise:" .. tostring(uid), keyCooldownMs = 600000, face = "player" })
                    if ok then row.mention = nil end
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- Betrayal memory (broken promises, attacks) and the rare betrayal
----------------------------------------------------------------------------------------------------------------
function M.betrayalOf(uid)
    local all = bucket("betrayal")
    local b = all[tostring(uid)]
    if type(b) ~= "table" then b = { broken = 0, attacks = 0 }; all[tostring(uid)] = b end
    return b
end

M.attackSeen = {}
function M.noteAttack(uid, player)
    uid = tostring(uid)
    local now = M.nowMs()
    if now - (M.attackSeen[uid] or -1e12) < 30000 then return end
    M.attackSeen[uid] = now
    local b = M.betrayalOf(uid)
    b.attacks, b.lastAttackH = (b.attacks or 0) + 1, hours()
    kmem(uid, "threat", "You attacked them")
    ilog(uid, "You attacked them", "attack")
    for _, row in ipairs(M.openPromises(uid)) do -- "I promise I won't hurt you"
        if row.kind == "vow" then M.settlePromise(uid, row, false, player, "you attacked them") end
    end
    local ro = M.romanceOf(uid)
    if (ro.stage or 0) >= 1 then M.romanceBreak(uid, "you attacked them") end
end

function M.onWeaponHit(wielder, target, weapon, damage)
    if not M.worldHere() then return end
    -- pre-1.0 MP (P2b): any online player's hit (single player: yours, as before)
    local player = nil
    if type(ALifeSide) == "table" then player = ALifeSide.isOnlinePlayer(wielder) and wielder or nil else player = M.you() end
    if wielder == nil or player == nil or wielder ~= player or target == nil then return end
    local pa = PA()
    local uid = nil
    pcall(function() uid = pa.Speech.variable(target, "ALifeUID") end)
    if uid ~= nil and tostring(uid) ~= "" then M.noteAttack(uid, player) end
end

function M.betrayCandidate(uid, r, player)
    local m = mods(uid)
    local greedy, liar = (tonumber(m.greed) or 0) >= 0.6, (tonumber(m.lie) or 0) >= 0.6
    if not (greedy or liar) then return false, "not the type" end
    local v = opinionOf(r, player)
    local b = M.betrayalOf(uid)
    local trend = 0
    local il = M.interactionsOf and M.interactionsOf(uid) or {}
    for i = #il, math.max(1, #il - 6), -1 do if il[i].a and il[i].b then trend = trend + (il[i].b - il[i].a) end end
    local sour = (v <= 15 and trend <= -6) or (b.broken or 0) >= 2 or ((b.attacks or 0) >= 1 and v <= 10)
    if not sour then return false, "not sour" end
    return true, v
end

function M.betrayTick(player)
    if M.settings.betrayal == false or player == nil then return end
    local pa = PA()
    local P = M.patch and M.patch()
    local g = bucket("betrayGlobal")
    local h = hours()
    if h < (tonumber(g.untilH) or -1e9) then return end
    if not fn(pa.Talk, "listeners") then return end
    local px, py = pos(player)
    local okL, list = pcall(pa.Talk.listeners, player, 15)
    if not okL then return end
    local lowHealth = false
    pcall(function() lowHealth = player:getBodyDamage():getHealth() < 50 end)
    for _, l in ipairs(list or {}) do
        local uid = tostring(l.record.uid)
        local b = M.betrayalOf(uid)
        if h >= (tonumber(b.nextCheckH) or -1e9) and h >= (tonumber(b.coolH) or -1e9) then
            local ok, v = M.betrayCandidate(uid, l.record, player)
            if ok then
                b.nextCheckH = h + M.rp.betrayCheckH
                local alone = #list <= 1
                local chance = M.rp.betrayChance + (alone and 3 or 0) + (lowHealth and 3 or 0) + math.min(4, (b.broken or 0))
                if M.roll(100) < chance then
                    local how = nil
                    if P and fn(P, "canRob") and P.canRob(l.record, player) then
                        local okR = P.robPlayer(l.record, player)
                        if okR then how = "rob" end
                    end
                    if how == nil and P and fn(P, "attackNow") and v <= 0
                            and (M.mayTurnHostile == nil or M.mayTurnHostile(uid, (b.attacks or 0) > 0)) then -- 0.5.0
                        local okA = P.attackNow(uid, player, "betrayal")
                        if okA then how = "turn" end
                    end
                    if how ~= nil then
                        b.coolH, b.betrayed = h + M.rp.betrayCooldownH, (b.betrayed or 0) + 1
                        g.untilH = h + M.rp.betrayGlobalH
                        kmem(uid, "threat", how == "rob" and "Turned on you and robbed you" or "Turned on you")
                        ilog(uid, how == "rob" and "Betrayed you: robbery" or "Betrayed you: turned hostile", "betrayal")
                        log("betrayal: " .. nameOf(l.record) .. " " .. how .. " (opinion " .. tostring(v) .. ")")
                        M.react("betray", l, player, { what = how == "rob" and "You've had enough of the newcomer and you're robbing them now"
                            or "You've had enough of the newcomer - you turn on them", maxWords = 12 },
                            { key = "betray:" .. uid, keyCooldownMs = 600000, urgent = true, face = "player" })
                        return how
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- Romance (toward the player)
----------------------------------------------------------------------------------------------------------------
M.romanceWords = { [0] = nil, "fond of you", "sweet on you", "partner" }
function M.romanceOf(uid)
    local all = bucket("romance")
    local r = all[tostring(uid)]
    if type(r) ~= "table" then r = { pts = 0, stage = 0, days = {} }; all[tostring(uid)] = r end
    r.days = type(r.days) == "table" and r.days or {}
    return r
end
local function dayCount(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
function M.romanceGate(uid)
    local rm = tonumber((mods(uid).romance)) or 0.3
    local needOp = 60 + math.floor((1 - math.min(1, rm)) * 20)
    return rm, needOp
end

function M.romanceNote(uid, pts, why)
    if M.settings.romance == false then return end
    local rm = M.romanceGate(uid)
    if rm < 0.2 then return end
    local ro = M.romanceOf(uid)
    if ro.brokenH and hours() - ro.brokenH < 72 then return end -- heartbroken for a while
    ro.pts = math.min(120, (ro.pts or 0) + pts * (0.5 + rm))
    ro.days[tostring(math.floor(hours() / 24))] = true
    ro.lastH = hours()
end

function M.romanceStageFor(uid, player)
    local ro = M.romanceOf(uid)
    local rm, needOp = M.romanceGate(uid)
    if rm < 0.2 then return 0 end
    local v = opinionKnown(rec(uid), player)
    if v == nil then return nil end
    local days = dayCount(ro.days)
    local s = 0
    if v >= 35 and ro.pts >= M.rp.romancePts[1] then s = 1 end
    if s == 1 and v >= needOp - 10 and ro.pts >= M.rp.romancePts[2] and days >= M.rp.romanceDays[1] then s = 2 end
    return s, v, needOp, days
end

function M.romanceBreak(uid, why)
    local ro = M.romanceOf(uid)
    if (ro.stage or 0) == 0 then return end
    local was = ro.stage
    ro.stage, ro.pts, ro.brokenH, ro.since = 0, 0, hours(), nil
    ro.days = {}
    kmem(uid, "insult", "Heartbroken: " .. tostring(why))
    ilog(uid, (was >= 3 and "Broke up with you" or "Feelings for you faded") .. " (" .. tostring(why) .. ")", "romance")
    log("romance: " .. tostring(uid) .. " -> over (" .. tostring(why) .. ")")
end

function M.romanceUpdate(uid, player)
    local ro = M.romanceOf(uid)
    local s, v = M.romanceStageFor(uid, player)
    -- 0.5.1.6: no record / unreadable opinion (far away, unloaded, A-Life re-rendering them) = no change.
    -- Before, that read as 0 -> "you drifted apart" -> break-up, just for being away.
    if s == nil or v == nil then return ro end
    if (ro.stage or 0) >= 1 and v < 20 then M.romanceBreak(uid, "you drifted apart"); return ro end
    if (ro.stage or 0) == 3 then return ro end
    if s > (ro.stage or 0) then
        ro.stage = s
        kmem(uid, "kindness", s == 2 and "Has feelings for you" or "Has grown fond of you")
        ilog(uid, s == 2 and "Developed a crush on you" or "Grew fond of you", "romance")
        log("romance: " .. tostring(uid) .. " stage " .. s)
    end
    -- no kindness for 5 days: it cools
    if ro.lastH and hours() - ro.lastH > 120 and (ro.pts or 0) > 0 then ro.pts = ro.pts * 0.8; ro.lastH = hours() - 96 end
    return ro
end

-- 0.5.1.6: undo break-ups that came only from being far away (before 0.5.1.6 an unreadable opinion counted as 0,
-- so "you drifted apart" fired while they were unloaded). Runs once per person; needs a readable opinion >= 20.
function M.distanceRestore(player)
    if M.settings.romance == false or player == nil then return 0 end
    local n = 0
    local done = bucket("distRestored")
    for uid, ro in pairs(bucket("romance")) do
        if type(ro) == "table" and (ro.stage or 0) == 0 and ro.brokenH ~= nil and not done[uid] then
            local last = nil
            for _, row in ipairs(M.interactionsOf and M.interactionsOf(uid) or {}) do
                if type(row) == "table" and row.k == "romance" then last = row end
            end
            local w = last and tostring(last.w) or ""
            if string.find(w, "(you drifted apart)", 1, true) then
                local v = opinionKnown(rec(uid), player)
                if v ~= nil and v >= 20 then
                    done[uid] = hours()
                    ro.stage = string.find(w, "Broke up", 1, true) and 3 or 1
                    ro.brokenH = nil
                    kmem(uid, "kindness", "The break-up was a mistake - you were only away")
                    ilog(uid, ro.stage == 3 and "Back together (the break-up came from you being far away)" or "Still fond of you (that came from you being far away)", "romance")
                    log("[Relations] restored " .. tostring(uid) .. ": the 'drifted apart' break-up happened only because you were far away (stage " .. ro.stage .. ")")
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- the player asks them to be their partner
function M.romanceAsk(uid, player)
    local ro = M.romanceUpdate(uid, player)
    local rm, needOp = M.romanceGate(uid)
    local v = opinionOf(rec(uid), player)
    local days = dayCount(ro.days)
    if (ro.stage or 0) == 3 then return true, "already together" end
    if rm < 0.2 then return false, "you're not looking for anything like that with anyone" end
    if ro.brokenH and hours() - ro.brokenH < 72 then return false, "they hurt you not long ago" end
    if (ro.stage or 0) < 2 then
        return false, v < 35 and "you barely know them" or "you like them, but it's too soon; you want to take it slow"
    end
    if v < needOp or days < M.rp.romanceDays[2] or (ro.pts or 0) < M.rp.romancePts[3] then
        return false, "you have feelings for them, but you're not ready yet - give it a little more time"
    end
    ro.stage, ro.since = 3, math.floor(hours() / 24)
    kmem(uid, "kindness", "Became your partner")
    ilog(uid, "Became your partner", "romance")
    log("romance: " .. tostring(uid) .. " is now the player's partner")
    return true, "you feel the same way"
end

-- romance from kindness: every positive change in how they feel about you (talk, gifts, help) feeds it
if type(M.logInteraction) == "function" and not M._rpLogWrapped then
    local orig = M.logInteraction
    M.logInteraction = function(uid, what, before, after, kind)
        local r = orig(uid, what, before, after, kind)
        if before and after and after > before and (kind == "opinion" or kind == "talk") then
            pcall(M.romanceNote, uid, after - before, what)
        end
        return r
    end
    M._rpLogWrapped = true
end

-- the player's bond word (badge + Ties) shows the romance
if type(M.playerTie) == "function" and not M._rpTieWrapped then
    local orig = M.playerTie
    M.playerTie = function(r, player)
        local word, v = orig(r, player)
        if r ~= nil and word ~= "nemesis" then
            local ro = bucket("romance")[tostring(r.uid)]
            if type(ro) == "table" and (ro.stage or 0) >= 2 then word = ro.stage >= 3 and "partner" or "sweet on you" end
        end
        return word, v
    end
    M._rpTieWrapped = true
end

-- the player character dies: partners grieve hardest (A-Life Talk grief layer; a new character can meet them)
function M.onPlayerDeath(player)
    local h = hours()
    local pname = "the newcomer"
    pcall(function() pname = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname() end)
    for uid, ro in pairs(bucket("romance")) do
        if type(ro) == "table" and (ro.stage or 0) >= 1 and M.griefOf then
            local w = ({ 0.55, 0.8, 1.0 })[ro.stage] or 0.5
            M.griefOf(uid)["player:" .. pname] = { n = pname, t = ro.stage >= 3 and "partner" or "crush", w = w, at = h,
                saw = false, known = false, kid = "zombie", kn = "the dead" }
            kmem(uid, "death", pname .. (ro.stage >= 3 and " (your partner)" or "") .. " died")
        end
    end
end

----------------------------------------------------------------------------------------------------------------
-- Recruiting
----------------------------------------------------------------------------------------------------------------
function M.recruitVerdict(listener, player)
    local uid = tostring(listener.record.uid)
    local r = listener.record
    local v = opinionOf(r, player)
    local m, t = mods(uid), traits(uid)
    local b = M.betrayalOf(uid)
    local ro = M.romanceOf(uid)
    local need = M.rp.recruitNeed + math.floor(((tonumber(m.fear) or 0.4) - 0.4) * 20)
    if t.loyal then need = need + 10 end
    if t.lonely or t.eager or t.restless then need = need - 10 end
    if (ro.stage or 0) >= 2 then need = need - 15 end
    need = need + 10 * math.min(3, (b.broken or 0) + (b.attacks or 0) * 2)
    -- 0.5.1: friendship and favours owed count (no perfect persuasion needed with a real friend)
    if M.favorsOwed then need = need - M.favorsOwed(uid) * 3 end
    if M.playerTie then
        local tie = select(1, M.playerTie(r, player))
        if tie == "best friend" then need = need - 20 elseif tie == "buddy" or tie == "ally" then need = need - 10 end
    end
    if M.walkingWith(listener, player) then return true, "you're already with them", need, v end
    local memory = type(r.memory) == "table" and r.memory or {}
    if hours() < (tonumber(b.recruitNoH) or -1e9) then return false, "they asked you that already - the answer is still no", need, v end
    if (b.attacks or 0) > 0 and v < 40 then return false, "they attacked you; you don't walk with people who hurt you", need, v end
    if v < need then
        local why
        if v < 0 then why = "you don't trust them at all"
        elseif (b.broken or 0) > 0 then why = "they broke their word to you before"
        elseif t.loyal and memory.groupId ~= nil and not (M.bucket and (M.bucket("settlers")[uid] ~= nil or M.bucket("settlers")[tonumber(uid) or uid] ~= nil)) then why = "your place is with your own people"
        elseif (tonumber(m.fear) or 0) >= 0.6 then why = "it's too dangerous out there with someone you barely know"
        else why = "you don't know them well enough yet" end
        return false, why, need, v
    end
    if M.followVerdict then
        local fv, text = M.followVerdict(listener, player)
        if fv ~= nil then
            local words = { not_friendly = "you're not on good enough terms yet", busy = "you're in the middle of something right now",
                hostile = "you're not on good terms", walk_off = "you can't leave right now", unavailable = "you can't right now",
                not_yet = text or "not yet" }
            return false, words[fv] or "not right now", need, v
        end
    end
    local why = (ro.stage or 0) >= 2 and "you'd follow them anywhere" or ((tonumber(m.greed) or 0) >= 0.6 and "two can scavenge more than one"
        or "you trust them and it's safer together")
    return true, why, need, v
end

function M.recruitApply(listener, player)
    local pa = PA()
    if M.walkingWith(listener, player) then return true end
    if not fn(pa.Talk, "walkWith") then return false end
    local ok, words = pa.Talk.walkWith(player, listener, "WALK_WITH_ME")
    if ok and M.followStart then pcall(M.followStart, listener, player) end
    log("recruit: " .. tostring(listener.record.uid) .. " -> " .. tostring(ok) .. " / " .. tostring(words))
    return ok
end

----------------------------------------------------------------------------------------------------------------
-- Interrogation: what they actually know (A-Life data, read only)
----------------------------------------------------------------------------------------------------------------
local function townAt(x, y)
    local pa = PA()
    local regions = pa and pa.TownRegions
    if regions == nil or not fn(regions, "distanceToTown") or x == nil then return nil end
    local ok, _, town = pcall(regions.distanceToTown, { x = x, y = y })
    return ok and town or nil
end
local function where(x, y, cat)
    local pa = PA()
    local town = townAt(x, y)
    if pa and fn(pa.Rumors, "describe") then
        local ok, txt = pcall(pa.Rumors.describe, x, y, cat or "house", town)
        if ok and txt then return txt end
    end
    return "a place out past the county road"
end
local function factionName(id)
    local pa = PA()
    local name = nil
    if pa and fn(pa.Catalog, "faction") then
        pcall(function()
            local f = pa.Catalog.faction(id)
            name = type(f) == "table" and ((type(f.general) == "table" and f.general.name) or f.name) or nil
        end)
    end
    return name or "a crew"
end

function M.intelKnown(uid)
    local pa = PA()
    local r = rec(uid)
    if r == nil or pa == nil then return {} end
    local memory = type(r.memory) == "table" and r.memory or {}
    local wp = type(r.worldPosition) == "table" and r.worldPosition or {}
    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
    local nx, ny = pos(sh)
    nx, ny = nx or wp.x, ny or wp.y
    local cands = {}
    local function add(e) if e.x and nx then e.d = math.sqrt((e.x - nx) ^ 2 + (e.y - ny) ^ 2) else e.d = 1e9 end; cands[#cands + 1] = e end
    pcall(function()
        local st = fn(pa.Rumors, "store") and pa.Rumors.store() or nil
        for _, den in ipairs(st and st.dens or {}) do
            add({ kind = "den", id = tostring(den.id), x = den.x, y = den.y, robber = true, manned = den.manned == true,
                faction = den.factionId, text = tostring(den.where or where(den.x, den.y)) .. " - " .. factionName(den.factionId)
                    .. (den.manned and " holed up there" or " keep a stash there") })
        end
    end)
    pcall(function()
        for _, site in ipairs(fn(pa.OutpostRegistry, "list") and pa.OutpostRegistry.list() or {}) do
            if site.state ~= "abandoned" and site.state ~= "proposed" and site.factionId ~= r.factionId then
                add({ kind = "camp", id = tostring(site.id), x = site.x, y = site.y, faction = site.factionId,
                    hostile = site.hostileToPlayers == true, text = factionName(site.factionId) .. " run a camp - " .. where(site.x, site.y, "house") })
            end
        end
    end)
    pcall(function()
        for _, q in ipairs(fn(pa.SquadLedger, "briefs") and pa.SquadLedger.briefs() or {}) do
            if q.id ~= memory.squadId and (q.memberCount or 0) > 0 and q.x and q.factionId ~= r.factionId then
                add({ kind = "crew", id = tostring(q.id), x = q.x, y = q.y, faction = q.factionId,
                    text = "a crew of " .. tostring(q.memberCount) .. " (" .. factionName(q.factionId) .. ") seen "
                        .. (q.moving and "moving around " or "around ") .. where(q.x, q.y, "house") })
            end
        end
    end)
    table.sort(cands, function(a, b) return a.d < b.d end)
    local out = {}
    for _, e in ipairs(cands) do
        if e.d <= M.rp.intelRange and #out < 3 then out[#out + 1] = e end
    end
    pcall(function() -- their own home: the secret they guard
        for _, hv in ipairs(fn(pa.Havens, "activeList") and pa.Havens.activeList() or {}) do
            if memory.groupId ~= nil and hv.groupId == memory.groupId then
                out[#out + 1] = { kind = "home", id = tostring(hv.id), x = hv.x, y = hv.y, own = true,
                    text = "their own group's " .. (hv.kind == "camp" and "camp" or "hideout") .. " - " .. where(hv.x, hv.y, "house") }
                break
            end
        end
    end)
    return out
end

function M.toldOf(uid)
    local all = bucket("told")
    local list = all[tostring(uid)]
    if type(list) ~= "table" then list = {}; all[tostring(uid)] = list end
    return list
end

function M.fearOf(uid, listener, player, intent, req)
    local m = mods(uid)
    local f = (tonumber(m.fear) or 0.4) * 0.5
    pcall(function()
        local item = player:getPrimaryHandItem()
        if item ~= nil and instanceof(item, "HandWeapon") then
            f = f + 0.15
            if player:isAiming() then f = f + 0.25 end
        end
    end)
    if req and type(req.npc) == "table" and req.npc.hurt then f = f + 0.2 end
    if req and (req.mateCount or 0) == 0 then f = f + 0.1 end
    if intent and intent.threat then f = f + 0.2 end
    local press = M.pressOf and M.pressOf(uid) or 0
    f = f + math.min(0.2, press * 0.07)
    if M.intimidatedBoost then f = f + M.intimidatedBoost(uid) end -- 0.5.1: a threat that worked still scares them
    return math.min(1, f)
end

M.press = {}
function M.pressOf(uid)
    local p = M.press[tostring(uid)]
    if p == nil or M.nowMs() - p.at > 600000 then return 0 end
    return p.n
end

local function fakeSpot(uid, r, seed)
    local wp = type(r.worldPosition) == "table" and r.worldPosition or {}
    local x0, y0 = wp.x or 10000, wp.y or 10000
    local h = 0
    for i = 1, #seed do h = (h * 31 + string.byte(seed, i)) % 100000 end
    local ang = (h % 360) * math.pi / 180
    local dist = 300 + (h % 600)
    local x, y = math.floor(x0 + math.cos(ang) * dist), math.floor(y0 + math.sin(ang) * dist)
    return x, y
end

-- decide what they tell (and remember it)
function M.interrogate(listener, player, intent, req)
    local uid = tostring(listener.record.uid)
    local r = listener.record
    local m, t = mods(uid), traits(uid)
    local p = M.press[uid] or { n = 0, at = 0 }
    if M.nowMs() - p.at > 600000 then p.n = 0 end
    p.n, p.at = p.n + 1, M.nowMs()
    M.press[uid] = p
    local v = opinionOf(r, player)
    local lie = tonumber(m.lie) or 0.3
    local fear = M.fearOf(uid, listener, player, intent, req)
    local facts = M.intelKnown(uid)
    local told = M.toldOf(uid)
    -- continuity: what they said before stays what they say (liars stick to the lie) unless fear breaks it
    local last = told[#told]
    if last ~= nil and last.t ~= nil and hours() - (last.h or 0) < 72 and not (last.real == false and fear >= 0.8 and lie < 0.8) then
        return { mode = "repeat", text = last.t, why = last.why, real = last.real, fear = fear }
    end
    local outside, home = {}, nil
    for _, f in ipairs(facts) do if f.own then home = f else outside[#outside + 1] = f end end
    local truth = outside[1]
    if truth == nil and home ~= nil and v >= 60 then truth = home end
    local mode
    if v >= 40 then mode = "truth"
    elseif fear >= 0.6 then mode = (lie >= 0.6 and M.roll(100) < 50) and "lie" or "truth"
    elseif v >= 10 then mode = (lie >= 0.5 and M.roll(100) < 50) and "lie" or "truth"
    elseif v > -30 then mode = lie >= 0.4 and "lie" or "refuse"
    else mode = lie >= 0.3 and "ambush" or "refuse" end
    if (mode == "truth") and truth == nil then mode = #facts == 0 and "none" or "refuse" end
    local out = { mode = mode, fear = fear }
    if mode == "truth" then
        out.text, out.real, out.x, out.y, out.kind = truth.text, true, truth.x, truth.y, truth.kind
    elseif mode == "ambush" then
        local den = nil
        for _, f in ipairs(outside) do if f.robber and f.manned then den = f; break end end
        if den then
            out.text = "supplies nobody's guarding at " .. string.gsub(den.text, " %- .*$", "")
            out.real, out.trap, out.x, out.y, out.kind = false, true, den.x, den.y, "den"
        else mode = lie >= 0.4 and "lie" or "refuse"; out.mode = mode end
    end
    if mode == "lie" then
        local fx, fy = fakeSpot(uid, r, uid .. "#lie" .. tostring(#told))
        local kind = (truth and truth.kind) or "camp"
        out.text = (kind == "crew" and "a crew holed up at " or "a camp at ") .. where(fx, fy, "house")
        out.real, out.x, out.y, out.kind = false, fx, fy, kind
        -- 0.5.0: a hostile-leaning liar sends you into a real ambush (A-Life Talk Patch 1.2: an offline A-Life squad of
        -- their faction gets a hunt contract waiting at the false spot). Without the patch the lie is only a lie.
        if v < 0 and lie >= 0.5 and fx then
            local P = M.patch and M.patch() or nil
            if P and type(P.ambushAt) == "function" then
                local okA, set = pcall(P.ambushAt, uid, fx, fy, player)
                if okA and set then out.trap = true; log("interrogation: lie is an ambush at " .. tostring(math.floor(fx)) .. "," .. tostring(math.floor(fy))) end
            end
        end
    elseif mode == "refuse" then
        out.why = (t.loyal and "you don't rat on anyone") or (fear >= 0.5 and "talking gets people killed") or "you don't trust them with that"
    elseif mode == "none" then
        out.why = "you honestly don't know anything about that"
    end
    told[#told + 1] = { t = out.text, real = out.real, mode = out.mode, trap = out.trap, x = out.x, y = out.y, h = hours(), why = out.why }
    while #told > 10 do table.remove(told, 1) end
    if out.text then
        kmem(uid, "event", "Told you about " .. out.text)
        ilog(uid, "Told you about " .. string.sub(out.text, 1, 70), "intel")
    else
        ilog(uid, "Wouldn't tell you anything (" .. tostring(out.why) .. ")", "intel")
    end
    log("interrogation: " .. nameOf(r) .. " " .. out.mode .. " (opinion " .. tostring(v) .. ", fear " .. ALifeFmtDec(fear, 2)
        .. ", lie " .. tostring(lie) .. ")" .. (out.text and (": " .. out.text) or ""))
    return out
end

----------------------------------------------------------------------------------------------------------------
-- Prompt: everything the model needs to play it (decisions are already made here)
----------------------------------------------------------------------------------------------------------------
M.rpPending = {}
M.doubtTraits = { "suspicious", "paranoid", "distrustful", "cynical", "cautious", "wary", "guarded", "bitter", "sly", "shrewd", "calculating" }
-- only the player's own line (reply / radio) counts; chime and banter requests carry NPC lines in the same field
if type(M.requestFor) == "function" and not M._rpReqForWrapped then
    local orig = M.requestFor
    M.requestFor = function(job, now)
        M.rpJob = (type(job) == "table" and (job.mode == "reply" or job.mode == "radio")) and job or nil
        local ok, req = pcall(orig, job, now)
        M.rpJob = nil
        if not ok then error(req) end
        return req
    end
    M._rpReqForWrapped = true
end

table.insert(M.requestExtras, function(req, player, listener, now)
    local uid = tostring(listener.record.uid)
    local rp = {}
    local t = traits(uid)
    for _, w in ipairs(M.doubtTraits) do if t[w] then rp.doubt = true end end
    local job = M.rpJob
    local mine = job ~= nil and tostring(job.uid or uid) == uid
    local radio = mine and job.mode == "radio"
    local said = (mine and type(req.said) == "string") and req.said or ""
    local intent = said ~= "" and M.rpIntent(said) or {}
    local pend = { uid = uid }
    -- promises: a new one in this line, and the ones that are open
    if said ~= "" and M.settings.promises ~= false then
        local pr = M.parsePromise(said)
        if pr then
            local row, fresh = M.addPromise(uid, pr, player)
            if row then rp.promiseNew = { M.promiseLabel(row), row.dueH and math.floor(row.dueH - hours() + 0.5) or -1, fresh and 1 or 0 } end
        end
    end
    local open, kept, broken = {}, 0, 0
    for _, row in ipairs(M.promisesOf(uid)) do
        if row.state == "open" then open[#open + 1] = { M.promiseLabel(row), row.dueH and math.floor(row.dueH - hours() + 0.5) or -1 }
        elseif row.state == "kept" then kept = kept + 1 elseif row.state == "broken" then broken = broken + 1 end
    end
    if #open > 0 then rp.promises = open end
    if kept + broken > 0 then rp.promiseRecord = { kept, broken } end
    local b = M.betrayalOf(uid)
    if (b.attacks or 0) > 0 then rp.attacked = b.attacks end
    -- recruiting
    if intent.recruit and not radio and M.settings.recruiting ~= false then
        local ok, why = M.recruitVerdict(listener, player)
        rp.recruit = { ok and 1 or 0, why }
        pend.recruit = ok
        if ok then req.followNo = nil end
        if not ok then
            b.recruitNoH = hours() + M.rp.recruitCooldownH
            pend.why = why
            req.followNo = why
            local keep = {}
            for _, a in ipairs(req.acts or {}) do if a ~= "WALK_WITH_ME" then keep[#keep + 1] = a end end
            req.acts = keep
            ilog(uid, "Refused to join you (" .. why .. ")", "recruit")
        end
    end
    -- interrogation
    if intent.intel and M.settings.interrogation ~= false then
        local okI, out = pcall(M.interrogate, listener, player, intent, req)
        if okI and out then rp.intel = { out.mode, out.text or "", out.why or "", out.real == false and 1 or 0 } end
    end
    -- romance
    if M.settings.romance ~= false then
        local ro = M.romanceUpdate(uid, player)
        local rm = M.romanceGate(uid)
        if intent.askOut then
            local ok, why = M.romanceAsk(uid, player)
            rp.askOut = { ok and 1 or 0, why }
        elseif intent.flirt then
            local v = opinionOf(listener.record, player)
            if rm >= 0.2 and v >= 30 then M.romanceNote(uid, 3, "flirting") end
            rp.flirt = (rm < 0.2 and "not looking") or (v < 15 and "too forward") or (v < 30 and "unsure") or "welcome"
        end
        if (ro.stage or 0) >= 1 then rp.romance = ro.stage end
    end
    if mine then M.rpPending[uid] = pend end
    for _ in pairs(rp) do req.rp = rp; break end -- (Kahlua has no next())
end)

-- Verdict was NO but a small model said yes anyway ("sure, let's go") while the game then refused: swap in a plain
-- refusal so the words match what happens. Only when the reply agrees and has no refusal word in it.
local agreeWords = { "sure", "yeah", "yes", "okay", "alright", "all right", "let's go", "lets go", "lead the way", "i'm in",
    "im in", "i'll come", "i will come", "count me in", "sounds good", "ok " }
local refuseWords = { " no", "nah", "not ", "n't", "never", "sorry", "maybe later", "afraid", "can't", "cannot", "won't" }
function M.replyGuard(p, text)
    local pend = type(p) == "table" and M.rpPending and M.rpPending[tostring(p.uid)] or nil
    if type(pend) ~= "table" or pend.recruit ~= false or type(text) ~= "string" then return text end
    local low = " " .. string.lower(text) .. " "
    local yes, no = false, false
    for _, w in ipairs(agreeWords) do if string.find(low, w, 1, true) then yes = true end end
    for _, w in ipairs(refuseWords) do if string.find(low, w, 1, true) then no = true end end
    if not yes or no then return text end
    local why = tostring(pend.why or "")
    local line
    if string.find(why, "trust", 1, true) or string.find(why, "know them", 1, true) then line = "Not yet. I don't know you well enough."
    elseif string.find(why, "dangerous", 1, true) then line = "Too risky out there with someone I barely know."
    elseif string.find(why, "own people", 1, true) then line = "My place is with my own people."
    elseif string.find(why, "already", 1, true) then line = "I told you already. Still no."
    else line = "Not right now." end
    log("recruit guard: model agreed but verdict was no (" .. why .. ") -> " .. line)
    return line
end

-- after the answer: carry out a successful recruitment through A-Life (walkWith) + the patch's companion mode
if type(M.finish) == "function" and not M._rpFinishWrapped then
    local orig = M.finish
    M.finish = function(p, r, ...)
        local a, b2 = orig(p, r, ...)
        pcall(function()
            local pend = type(p) == "table" and M.rpPending[tostring(p.uid)] or nil
            if pend == nil then return end
            M.rpPending[tostring(p.uid)] = nil
            if pend.recruit then
                local listener = M.refresh(p) or p.listener
                if listener and M.recruitApply(listener, p.player) then
                    kmem(p.uid, "kindness", "Agreed to travel with you")
                    ilog(p.uid, "Joined you", "recruit")
                end
            end
        end)
        return a, b2
    end
    M._rpFinishWrapped = true
end

-- gifts keep promises (and the gift prompt says so)
if type(M.onGift) == "function" and not M._rpGiftWrapped then
    local orig = M.onGift
    M.onGift = function(player, listener, items, opts)
        local kept = nil
        pcall(function()
            if not (opts and opts.trade) and listener and listener.record then kept = M.promiseGift(tostring(listener.record.uid), items, player) end
        end)
        if kept then
            opts = opts or {}
            opts.promiseKept = M.promiseLabel(kept)
        end
        return orig(player, listener, items, opts)
    end
    M._rpGiftWrapped = true
end
if type(M.giftRequest) == "function" and not M._rpGiftReqWrapped then
    local orig = M.giftRequest
    M.giftRequest = function(job, now)
        local req = orig(job, now)
        pcall(function()
            if req and job and job.uid then
                local list = M.promisesOf(job.uid)
                local last = list[#list]
                if last and last.state == "kept" and last.doneH and hours() - last.doneH < 0.2 then
                    req.rp = req.rp or {}
                    req.rp.promiseKept = M.promiseLabel(last)
                end
            end
        end)
        return req
    end
    M._rpGiftReqWrapped = true
    if type(M.eventModes) == "table" and type(M.eventModes.gift) == "table" then M.eventModes.gift.request = M.giftRequest end
end

----------------------------------------------------------------------------------------------------------------
-- tick + events + settings
----------------------------------------------------------------------------------------------------------------
for k, v in pairs({ recruiting = true, interrogation = true, romance = true, promises = true, betrayal = true }) do
    if M.settings[k] == nil then M.settings[k] = v end
end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "recruiting", "interrogation", "romance", "promises", "betrayal" }) do
        local found = false
        for _, f in ipairs(M.fileKeys) do if f == k then found = true end end
        if not found then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
if type(M.eventModes) == "table" and M.reactRequest then
    for _, mode in ipairs({ "promise", "betray" }) do M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish } end
end
local tickN = 0
function M.rpTick()
    if not M.worldHere() then return end
    tickN = tickN + 1
    -- pre-1.0 MP (P2b): once per online player (single player: you)
    if tickN % 120 == 60 and M.settings.promises ~= false then M.eachPlayer(M.promiseTick) end
    if tickN % 600 == 300 then M.eachPlayer(M.betrayTick) end
    if tickN == 600 or tickN % 36000 == 0 then M.eachPlayer(M.distanceRestore) end
    if tickN % 1800 == 900 and M.settings.romance ~= false then
        M.eachPlayer(function(player)
            for uid, ro in pairs(bucket("romance")) do if type(ro) == "table" then pcall(M.romanceUpdate, uid, player) end end
        end)
    end
end
-- pre-1.0 MP (P2b): OnPlayerDeath fires only on the dying player's own machine (42.21 jar: IsoPlayer.OnDeath returns
-- early on a server, then fires it for the local player only). The server gets OnCharacterDeath for every character
-- (IsoGameCharacter.OnDeath): a player's death reaches the world logic through that.
function M.rpOnCharacterDeath(c)
    if type(ALifeSide) ~= "table" or not ALifeSide.mpServer() then return end -- SP: OnPlayerDeath below (no double)
    if ALifeSide.isOnlinePlayer(c) then ALifeSide.with(c, M.onPlayerDeath, c) end
end
if type(Events) == "table" then
    if Events.OnTick then ALifeHealth.tickAdd("ALifeLLMTalk_Roleplay", function() local ok, e = pcall(M.rpTick); if not ok then log("roleplay tick error: " .. tostring(e)) end end) end
    if Events.OnWeaponHitCharacter then ALifeHealth.add(Events.OnWeaponHitCharacter, "ALifeLLMTalk_Roleplay", function(a, b, c, d) pcall(M.onWeaponHit, a, b, c, d) end) end
    if Events.OnPlayerDeath then Events.OnPlayerDeath.Add(function(p) if M.worldHere() then pcall(M.onPlayerDeath, p) end end) end
    if Events.OnCharacterDeath then Events.OnCharacterDeath.Add(function(c) pcall(M.rpOnCharacterDeath, c) end) end
end

return M
