-- A-Life Talk 0.5.1: LAST WORDS.
-- When an A-Life NPC is dying (A-Life's own flags: ProjectALifeInjured "down", a bleed-out timer, or HP <= 12 %),
-- or at the latest at ProjectALife_NpcDied, they say one short last line - once per life:
--   * instantly a stock line shaped by personality (gentle: "find my family", cruel: a curse, bitten: "don't let me
--     turn", depressive: relief), the cause (bite, gunshot, the player, their nemesis), who they love (names a
--     partner / family / best friend nearby) and sometimes their backstory secret;
--   * then the AI upgrades it (mode "last_words") if the answer arrives within a few seconds and the body is still
--     on screen;
--   * the text lingers over the body / corpse ~25 s (a small screen overlay that stays at the corpse);
--   * friends nearby grieve out loud; the words go to their memory, the log, rumors and maybe the radio.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "LastWords"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("LastWords") end end -- 0.5.1.6 perf label
require "ISUI/ISUIElement"

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function dataOf(shell) local d = nil; pcall(function() d = shell:getModData() end); return d end

if M.settings.lastWords == nil then M.settings.lastWords = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "lastWords" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "lastWords" end
end
M.lwCfg = { scanTiles = 30, hpDying = 12, upgradeMs = 6000, lingerMs = 25000, griefTiles = 18, secretChance = 30, overlayMax = 4,
    recoverMs = 15000, pendingMaxMs = 1800000 }
-- 0.5.2.5 [pt252u]: "dying" (A-Life's down / bleed-out / low HP) is NOT death - A-Life NPCs get back up (Injury.recover).
-- Viola Yates was only wounded, yet Jorge's timeline said "Heard Viola Yates's last words". Now the line may still be
-- spoken while they are down, but nothing is remembered (witness logs, key memories, own log, news, deeds) until
-- ProjectALife_NpcDied confirms the death; if they get up again the pending words are dropped. Off: lastWordsConfirm.
M.lastWordsDone = {} -- uid -> { text, at, x, y, z }

local function firstName(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nameOf(r)
    return string.match(n, "^(%S+)") or n
end

-- is this NPC dying right now? (A-Life's own wound flags)
function M.isDying(shell, record)
    local d = shell and dataOf(shell) or nil
    if d then
        if d.ProjectALifeInjured == "down" or d.ProjectALifeBleedOutAtMs ~= nil then return true, "down" end
    end
    local pa = PA()
    if shell and fn(pa and pa.Health, "hpPercent") then
        local ok, hp = pcall(pa.Health.hpPercent, shell)
        if ok and tonumber(hp) and tonumber(hp) > 0 and tonumber(hp) <= M.lwCfg.hpDying then return true, "hp" end
    end
    local dead = false
    pcall(function() dead = shell:isDead() == true end)
    return dead, dead and "dead" or nil
end

-- the cause: bite / gunshot / the player / nemesis / blade / zombies
function M.deathCause(uid, shell, record, killer, player)
    local cause, by = "wounds", nil
    if killer ~= nil and M.killerOf then
        local name, kuid = M.killerOf(killer, player, shell)
        if kuid == "player" then cause, by = "player", "player"
        elseif kuid == "zombie" then cause = "zombies"
        elseif kuid ~= nil then cause, by = "npc", kuid end
    end
    local s = M.woundState and M.woundState(uid, shell, record) or nil
    if s then
        if s.bitten and (cause == "wounds" or cause == "zombies") then cause = "bite" end
        local newest = nil
        for _, w in ipairs(s.list or {}) do if newest == nil or (w.ageH or 99) < (newest.ageH or 99) then newest = w end end
        if newest then
            if cause == "wounds" and newest.byPlayer then cause, by = "player", "player" end
            if cause == "wounds" and newest.kind == "bullet" then cause = "gunshot" end
            if newest.kind == "bullet" and cause == "player" then cause = "player_gun" end
        end
    end
    if by ~= nil and by ~= "player" and M.pairTypeFor and M.pairRow then
        local row = M.pairRow(uid, by)
        if row and M.pairTypeFor(row, uid, by) == "nemesis" then cause = "nemesis" end
    end
    return cause, by
end

-- who they love most (alive), and whether they're close by
function M.lovedOne(uid, x, y)
    local best, bs = nil, 19
    for _, t in ipairs(M.tiesOf and M.tiesOf(uid, nil, 8) or {}) do
        local w = t.score + ((t.type == "partner" or t.type == "family") and 40 or (t.type == "best friend" or t.type == "crush") and 20 or 0)
        if not t.dead and t.score > 0 and w > bs then best, bs = t, w end
    end
    if best == nil then return nil end
    local near = false
    local pa = PA()
    local sh = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(best.uid) or nil
    local ox, oy = pos(sh)
    if ox and x and (ox - x) ^ 2 + (oy - y) ^ 2 <= M.lwCfg.griefTiles ^ 2 then near = true end
    local orec = rec(best.uid)
    return { uid = best.uid, name = orec and firstName(orec) or best.name, type = best.type, near = near }
end

-- the persona's backstory secret in first person ("Their secret: they ran when..." -> "I ran when...")
function M.secretOf(uid)
    local row = M.personaOf and M.personaOf(uid) or nil
    local s = row and type(row.fallback) == "table" and row.fallback[4] or nil
    if type(s) ~= "string" then return nil end
    s = string.gsub(s, "^Their secret: ", "")
    s = string.gsub(s, "%.$", "")
    s = " " .. s .. " "
    s = string.gsub(s, " they were ", " I was "); s = string.gsub(s, " they are ", " I am ") -- 0.5.2.5: not "I were"
    s = string.gsub(s, " they've ", " I've "); s = string.gsub(s, " they're ", " I'm "); s = string.gsub(s, " they ", " I ")
    s = string.gsub(s, " their ", " my "); s = string.gsub(s, " them ", " me "); s = string.gsub(s, " themselves ", " myself ")
    s = string.gsub(s, " I is ", " I am "); s = string.gsub(s, " I was ", " I was ")
    s = string.gsub(s, "^%s+", ""); s = string.gsub(s, "%s+$", "")
    return s
end

M.lwLines = {
    gentle = { "Tell my family... I tried.", "Find them for me... please.", "It's okay... it doesn't hurt anymore.", "Don't... don't be sad." },
    cruel = { "Go to hell... all of you.", "I'll see you... down there.", "Should've... killed you first.", "Damn you..." },
    bite = { "Don't let me turn... please.", "Do it... before I come back.", "Put one in my head... promise me.", "I don't want to be one of them..." },
    depressive = { "Finally... it's over.", "Good. I'm so tired.", "...thank you.", "About time." },
    brave = { "Keep... keep fighting.", "Give 'em hell for me.", "Not a bad run...", "Don't stop... for me." },
    scared = { "I don't wanna die... I don't wanna die...", "Mom...?", "It's so cold...", "Somebody... please..." },
    devout = { "Lord... take me home.", "I'm coming home...", "Forgive me... Father..." },
    jokester = { "Well... this sucks.", "Tell 'em... I went out swinging.", "Guess I'm... off the clock." },
    plain = { "So... this is it.", "I can't... feel my legs.", "Tell them... I'm sorry.", "Not like this..." },
    player = { "Why...?", "You... you did this.", "I trusted you...", "Hope it was... worth it." },
    nemesis = { "You... finally...", "This isn't... over...", "Should've known... it'd be you." },
}
function M.lwStyle(uid, cause)
    local p = M.partsOf and M.partsOf(uid) or nil
    local k = p and p.core and p.core.key or ""
    local kind, _, mods = nil, nil, {}
    if M.personaKind then kind, _, mods = M.personaKind(uid) end
    if cause == "bite" then return "bite", k end
    if k == "depressive" or k == "hopeless" or k == "nihilist" or k == "hollow" or k == "broken" or k == "withdrawn" then return "depressive", k end
    if kind == "dark" or k == "cruel" or k == "sadist" or k == "mean" or k == "bully" or k == "ruthless" or k == "vengeful" then return "cruel", k end
    if k == "gentle" or k == "nurturing" or k == "protective" or k == "generous" or k == "lonely" or k == "dreamer" or k == "idealist" then return "gentle", k end
    if k == "devout" or k == "zealot" or k == "penitent" then return "devout", k end
    if k == "jokester" or k == "prankster" or k == "sarcastic" or k == "cheerful" then return "jokester", k end
    if k == "brave" or k == "stoic" or k == "hardass" or k == "survivalist" then return "brave", k end
    if k == "coward" or k == "shy" or (type(mods) == "table" and mods.bark == "scared") then return "scared", k end
    return "plain", k
end

function M.lastWordsLine(uid, record, cause, loved, opts)
    opts = opts or {}
    local style = M.lwStyle(uid, cause)
    local seed = uid .. "#lw"
    local line
    if cause == "nemesis" then line = pick(M.lwLines.nemesis, seed)
    elseif (cause == "player" or cause == "player_gun") and style ~= "depressive" and style ~= "bite" then
        line = style == "cruel" and "Hope you... rot..." or pick(M.lwLines.player, seed)
    else line = pick(M.lwLines[style] or M.lwLines.plain, seed) end
    if loved and style ~= "cruel" and (hash(seed .. "#love") % 100) < 70 then
        if loved.near then
            line = loved.name .. "... " .. ((loved.type == "partner" or loved.type == "crush") and "I love you..." or loved.type == "family" and "take care of yourself..."
                or "watch out for them...")
        elseif style == "gentle" then
            line = "Tell " .. loved.name .. "... I'm sorry."
        end
    end
    if opts.secret then line = line .. " " .. opts.secret .. "..." end
    return line
end

----------------------------------------------------------------------------------------------------------------
-- overlay: the words linger over the body / corpse
----------------------------------------------------------------------------------------------------------------
M.lwOverlays = {}
if ISUIElement ~= nil then
    ALifeTalkLastWords = ISUIElement:derive("ALifeTalkLastWords")
    local O = ALifeTalkLastWords
    function O:new(shell, text, name, x, y, z)
        local o = ISUIElement.new(self, -400, -400, 260, 40)
        o.shell, o.text, o.name, o.wx, o.wy, o.wz = shell, text, name, x, y, z
        o.born = M.nowMs()
        o.anchorAlwaysOnTop = false
        return o
    end
    function O:initialise()
        ISUIElement.initialise(self)
        pcall(function() self:setAlwaysOnTop(true) end)
    end
    function O:prerender()
        local age = M.nowMs() - self.born
        if age > M.lwCfg.lingerMs then self:kill(); return end
        local x, y, z = nil, nil, nil
        local alive = false
        pcall(function() alive = self.shell ~= nil and self.shell:isDead() ~= true end)
        if alive then x, y, z = pos(self.shell) end
        if x ~= nil then self.wx, self.wy, self.wz = x, y, z end -- follows while they still move, stays at the corpse
        if self.wx == nil then self:kill(); return end
        -- 0.5.1.6: "A and f() or nil" kept only the first return value: sy was nil -> an error every frame (Java stack dumps, FPS)
        local sx, sy = nil, nil
        if M.worldToScreen then sx, sy = M.worldToScreen(self.wx, self.wy, self.wz, 0) end
        if sx == nil or sy == nil then self:setVisible(false); return end
        self:setVisible(true)
        local zoom = 1
        pcall(function() zoom = getCore():getZoom(0) end)
        local tm = getTextManager()
        local font = UIFont.Small
        local w = 120
        pcall(function() w = math.max(tm:MeasureStringX(font, self.text), tm:MeasureStringX(font, self.name)) + 16 end)
        self:setWidth(w)
        self:setX(sx - w / 2)
        self:setY(sy - (alive and 120 or 50) / zoom)
        local a = 1
        if age < 300 then a = age / 300 elseif age > M.lwCfg.lingerMs - 3000 then a = (M.lwCfg.lingerMs - age) / 3000 end
        a = math.max(0, math.min(1, a))
        self:drawRect(0, 0, w, 38, 0.5 * a, 0.02, 0.02, 0.03)
        self:drawRectBorder(0, 0, w, 38, 0.45 * a, 0.5, 0.42, 0.42)
        self:drawTextCentre(self.name, w / 2, 2, 0.62, 0.58, 0.58, a * 0.8, font)
        self:drawTextCentre(self.text, w / 2, 18, 0.88, 0.84, 0.78, a, font)
    end
    function O:render() end
    function O:kill()
        self.dead = true
        self:setVisible(false)
        self:removeFromUIManager()
    end
end

function M.showLastWordsOverlay(uid, shell, text, x, y, z, pending)
    if ALifeTalkLastWords == nil or not M.isSP() then return nil end
    local r = rec(uid)
    local nm = (M.shownName and getPlayer and select(1, M.shownName(uid, ALifeSide.you())) or nameOf(r))
    local title = nm .. (pending and "" or " - last words") -- 0.5.2.5: no "last words" label while they're alive
    for _, o in ipairs(M.lwOverlays) do
        if not o.dead and o.uid == tostring(uid) then o.text = '"' .. text .. '"'; o.name = title; return o end
    end
    local o = ALifeTalkLastWords:new(shell, '"' .. text .. '"', title, x, y, z)
    o.uid = tostring(uid)
    o:initialise()
    o:addToUIManager()
    M.lwOverlays[#M.lwOverlays + 1] = o
    local keep = {}
    for _, q in ipairs(M.lwOverlays) do if not q.dead then keep[#keep + 1] = q end end
    while #keep > M.lwCfg.overlayMax do local old = table.remove(keep, 1); pcall(function() old:kill() end) end
    M.lwOverlays = keep
    return o
end

----------------------------------------------------------------------------------------------------------------
-- the moment
----------------------------------------------------------------------------------------------------------------
local function witnessesAt(uid, x, y, z, tiles, maxN)
    local out = {}
    for i, w in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z or 0, tiles, uid) or {}) do
        if i > maxN then break end
        out[#out + 1] = tostring(w.record.uid)
    end
    return out
end
local function storeWords(uid, record, text, x, y, z, cause, upgraded, wit, witDeed)
    local d = M.lastWordsDone[uid]
    d.text, d.upgraded = text, upgraded == true
    d.stored = true
    local pa = PA()
    local name = nameOf(record)
    local short = string.sub(text, 1, 120)
    -- whoever was close heard it (0.5.2.5: the ones who were there when it was said)
    wit = wit or witnessesAt(uid, x, y, z, M.lwCfg.griefTiles, 6)
    for _, wu in ipairs(wit) do
        if M.keyMem then pcall(M.keyMem, wu, "lastwords", name .. "'s last words were: \"" .. short .. "\"") end
        if M.logInteraction then pcall(M.logInteraction, wu, "Heard " .. name .. "'s last words", nil, nil, "event") end
    end
    if M.logInteraction then pcall(M.logInteraction, uid, "Last words: \"" .. short .. "\"", nil, nil, "event") end
    if not upgraded and M.newsNote and cause ~= "player" and cause ~= "player_gun" then
        pcall(M.newsNote, "lastwords", name .. " died; their last words were \"" .. string.sub(text, 1, 60) .. "\"", x, y)
    end
    if not upgraded and (cause == "player" or cause == "player_gun") and M.addDeed then
        local wd = witDeed or witnessesAt(uid, x, y, z, 20, 50)
        if #wd > 0 then pcall(M.addDeed, "lastwords", "the newcomer killed " .. name .. " - who asked \"" .. string.sub(text, 1, 40) .. "\" with their last breath", -1, wd, x, y) end
    end
end

function M.griefAtDeathbed(uid, record, x, y, z, player, pending)
    local pa = PA()
    local who = nil
    for _, w in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z or 0, M.lwCfg.griefTiles, uid) or {}) do
        local row = M.pairRow and M.pairRow(uid, tostring(w.record.uid)) or nil
        if row and (tonumber(row.s) or 0) >= 20 then who = w; break end
    end
    if who == nil then return end
    local wu = tostring(who.record.uid)
    local name = firstName(record)
    local lines = { "No... no, no, " .. name .. "...", name .. "! Stay with me!", "Hang on, " .. name .. "... please.", "Not you too, " .. name .. "..." }
    local line = pick(lines, wu .. uid)
    local function go()
        if M.say then M.say(who.shell, player, line, { record = who.record }) end
        if M.feel then
            if pending then M.feel(wu, "fear", 0.3, name .. " went down in front of them") -- 0.5.2.5: not dead (yet)
            else M.feel(wu, "grief", 0.5, name .. " died in front of them") end
        end
    end
    if fn(pa.Talk, "later") then pcall(pa.Talk.later, 2500, go) else go() end
end

-- say the last words (once per life); body = the corpse when called from the death event
function M.lastWords(uid, shell, record, killer, player, body)
    uid = tostring(uid)
    if M.settings.lastWords == false or M.lastWordsDone[uid] then return false end
    record = record or rec(uid)
    if record == nil then return false end
    local x, y, z = pos(shell or body)
    if x == nil then x, y, z = pos(body) end
    if x == nil then return false end
    player = player or ALifeSide.you()
    local now = nowMs()
    local cause = M.deathCause(uid, shell, record, killer, player)
    local loved = M.lovedOne(uid, x, y)
    local secret = nil
    local p = M.partsOf and M.partsOf(uid) or nil
    local k = p and p.core and p.core.key or ""
    local sc = M.lwCfg.secretChance + ((k == "honest" or k == "penitent" or k == "haunted") and 30 or 0) - ((k == "liar" or k == "schemer") and 20 or 0)
    if (hash(uid .. "#secret") % 100) < sc then secret = M.secretOf(uid) end
    local line = M.lastWordsLine(uid, record, cause, loved, { secret = secret })
    M.lastWordsDone[uid] = { text = line, at = now, x = x, y = y, z = z, cause = cause }
    local d = M.lastWordsDone[uid]
    local alive = false
    pcall(function() alive = shell ~= nil and shell:isDead() ~= true end)
    if alive and M.settings.lastWordsConfirm ~= false then
        -- 0.5.2.5: said while still alive -> remembered only if the death is confirmed (lastWordsOnDeath)
        d.pending, d.record = true, record
        d.wit = witnessesAt(uid, x, y, z, M.lwCfg.griefTiles, 6)
        d.witDeed = witnessesAt(uid, x, y, z, 20, 50)
    end
    if alive and M.say then M.say(shell, player, line, { record = record, combat = true }) end
    M.showLastWordsOverlay(uid, alive and shell or nil, line, x, y, z, d.pending)
    if not d.pending then storeWords(uid, record, line, x, y, z, cause, false) end
    if alive then M.griefAtDeathbed(uid, record, x, y, z, player, d.pending) end
    log("last words: " .. nameOf(record) .. " (" .. cause .. "): " .. line)
    -- the AI upgrade (only while it still fits the moment)
    if M.react and player ~= nil then
        local what = "You are dying (" .. cause:gsub("_", " ") .. ")."
        if loved then what = what .. " The person you love most is " .. loved.name .. " (your " .. tostring(loved.type) .. ")" .. (loved.near and ", right here" or ", not here") .. "." end
        if secret then what = what .. " You may finally confess your secret: " .. secret .. "." end
        local l = { record = record, shell = alive and shell or body }
        M.react("last_words", l, player, { what = what, style = "your LAST words: very short, broken, in character; no goodbye speeches", maxWords = 14, fallback = line },
            { key = "lw:" .. uid, keyCooldownMs = 600000, modeCooldownMs = 0, urgent = true, onDone = function(job, r)
                if type(r) ~= "table" or type(r.text) ~= "string" or r.text == "" then return end
                if nowMs() - now > M.lwCfg.upgradeMs then return end
                local vx, vy = pos(player)
                if vx and (vx - x) ^ 2 + (vy - y) ^ 2 > 40 * 40 then return end
                local dd = M.lastWordsDone[uid]
                if dd == nil then return end -- 0.5.2.5: they got back up meanwhile
                M.showLastWordsOverlay(uid, nil, r.text, x, y, z, dd.pending)
                if dd.pending then dd.text, dd.upgraded = r.text, true -- remembered once the death is confirmed
                else storeWords(uid, record, r.text, x, y, z, cause, true) end
            end })
    end
    return true
end

-- 0.5.2.5: pending last words of someone who is up again -> dropped (they can have real ones later)
function M.lastWordsPendingTick(now)
    now = now or nowMs()
    local pa = PA()
    for uid, d in pairs(M.lastWordsDone) do
        if type(d) == "table" and d.pending then
            local r = rec(uid)
            local sh = fn(pa and pa.Talk, "shellFor") and pa.Talk.shellFor(uid) or nil
            local deadNow = (r ~= nil and r.lifecycle == "dead") or (M.isFinalDead and M.isFinalDead(uid))
            pcall(function() if sh ~= nil and sh:isDead() == true then deadNow = true end end)
            -- 0.5.2.6 [pt254u]: a death A-Life recorded off-screen (no record left, our confirmed deaths, the book)
            -- counts as confirmed too. A live (down) record is never dead here: down is not dead.
            local offRec = false
            if not deadNow and M.settings.offDeath ~= false and M.isPersonDead and (r == nil or r.lifecycle == "dormant") then
                offRec = M.isPersonDead(uid, r)
                deadNow = offRec
            end
            if deadNow then
                d.okSince = nil -- the death event commits it
                d.deadSince = d.deadSince or now
                -- no event came (they died unloaded / the record was dropped): commit from the record
                if M.settings.offDeath ~= false and (offRec or sh == nil) and now - d.deadSince >= (M.odCfg and M.odCfg.eventWaitMs or 20000) then
                    log("last words: " .. nameOf(r or d.record) .. " - death confirmed from A-Life's records (no death event)")
                    M.lastWordsOnDeath(nil, uid, nil)
                end
            elseif sh ~= nil then
                if M.isDying(sh, r) then d.okSince = nil
                else
                    d.okSince = d.okSince or now
                    if now - d.okSince >= M.lwCfg.recoverMs then M.lastWordsDrop(uid, "recovered") end
                end
            elseif now - (d.at or now) > M.lwCfg.pendingMaxMs then
                M.lastWordsDrop(uid, "never confirmed")
            end
        end
    end
end
function M.lastWordsDrop(uid, why)
    uid = tostring(uid)
    M.lastWordsDone[uid] = nil
    for _, o in ipairs(M.lwOverlays or {}) do if o.uid == uid and not o.dead then pcall(function() o:kill() end) end end
    log("last words: " .. nameOf(rec(uid)) .. " " .. tostring(why) .. " - nothing remembered")
end

function M.lastWordsTick()
    if M.settings.lastWords == false or not M.isSP() then return end
    if M.settings.lastWordsConfirm ~= false then
        pcall(M.lastWordsPendingTick)
        if not M._lwCleaned then pcall(M.lastWordsCleanup) end
    end
    local player = ALifeSide.you()
    if player == nil then return end
    local x, y, z = pos(player)
    for _, l in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z, M.lwCfg.scanTiles) or {}) do
        local uid = tostring(l.record.uid)
        if not M.lastWordsDone[uid] then
            local dying = M.isDying(l.shell, l.record)
            if dying then pcall(M.lastWords, uid, l.shell, l.record, nil, player, nil) end
        end
    end
end

function M.lastWordsOnDeath(body, uid, killer)
    if M.settings.lastWords == false or not M.isSP() then return end
    uid = tostring(uid)
    local d = M.lastWordsDone[uid]
    if d and d.pending then -- 0.5.2.5: said while down - now confirmed, remember it (the people who heard it)
        d.pending, d.okSince = nil, nil
        local r = d.record or rec(uid)
        local cause = d.cause
        if killer ~= nil then
            local okC, c = pcall(M.deathCause, uid, nil, r, killer, ALifeSide.you())
            if okC and c then cause = c end
        end
        storeWords(uid, r, d.text, d.x, d.y, d.z, cause, false, d.wit, d.witDeed)
        for _, o in ipairs(M.lwOverlays) do if o.uid == uid and not o.dead then o.name = nameOf(r) .. " - last words" end end
    end
    if d then -- already spoken: keep the overlay at the corpse
        local bx, by, bz = pos(body)
        for _, o in ipairs(M.lwOverlays) do if o.uid == uid and not o.dead and bx then o.shell, o.wx, o.wy, o.wz = nil, bx, by, bz end end
        return
    end
    local player = ALifeSide.you()
    local px, py = pos(player)
    local bx, by = pos(body)
    if px == nil or bx == nil or (px - bx) ^ 2 + (py - by) ^ 2 > M.lwCfg.scanTiles ^ 2 then return end -- nobody around to hear it
    M.lastWords(uid, nil, nil, killer, player, body)
end

----------------------------------------------------------------------------------------------------------------
-- 0.5.2.5 [pt252u]: save clean-up (once per load). Older versions stored "last words" for people who were only
-- down: "Heard X's last words" (witness logs + Bond timeline), "X's last words were ..." (key memories), the
-- person's own "Last words: ..." row, the radio news line and the rumor. Removed when X is alive (registry says so
-- and no death is on record). Names that are unknown or shared with a dead person are left alone.
----------------------------------------------------------------------------------------------------------------
function M.lastWordsCleanup()
    local pa = PA()
    if not fn(pa and pa.ActorRegistry, "each") then return nil end
    local book = M.bucket("book")
    local status, uidAlive, n = {}, {}, 0
    pa.ActorRegistry.each(function(r)
        if type(r) ~= "table" or r.uid == nil then return end
        n = n + 1
        local uid = tostring(r.uid)
        local e = book[uid]
        local dead = r.lifecycle == "dead" or (M.isFinalDead and M.isFinalDead(uid)) or (type(e) == "table" and e.dead == true)
            or (r.ghost == true)
        uidAlive[uid] = not dead
        local nm = nameOf(r)
        if status[nm] == nil then status[nm] = not dead else status[nm] = status[nm] and not dead end
    end)
    if n == 0 then return nil end -- registry not loaded yet: try again next tick
    M._lwCleaned = true
    for uid, e in pairs(book) do -- people only in our book (A-Life dropped them) and the known dead
        if type(e) == "table" and type(e.name) == "string" and (e.dead == true or uidAlive[tostring(uid)] == nil) then
            if e.dead == true then status[e.name] = false elseif status[e.name] == nil then status[e.name] = false end
        end
    end
    local function aliveName(nm) return nm ~= nil and status[nm] == true end
    local removed = 0
    local function filter(list, bad)
        if type(list) ~= "table" then return list end
        local keep, gone = {}, {}
        for _, row in ipairs(list) do
            if bad(row) then gone[#gone + 1] = row; removed = removed + 1 else keep[#keep + 1] = row end
        end
        if #gone == 0 then return list, gone end
        for i = #list, 1, -1 do list[i] = nil end
        for i, row in ipairs(keep) do list[i] = row end
        return list, gone
    end
    -- interaction logs (+ tell the bridge memory to forget the same rows)
    M.ilogForget = M.ilogForget or {}
    for uid, rows in pairs(M.bucket("ilog")) do
        local _, gone = filter(rows, function(r)
            if type(r) ~= "table" or type(r.w) ~= "string" then return false end
            local nm = string.match(r.w, "^Heard (.+)'s last words$")
            if nm then return aliveName(nm) end
            if string.sub(r.w, 1, 12) == "Last words: " then return uidAlive[tostring(uid)] == true end
            return false
        end)
        for _, g in ipairs(gone or {}) do
            local q = M.ilogForget[tostring(uid)] or {}
            q[#q + 1] = g.w
            M.ilogForget[tostring(uid)] = q
        end
    end
    for _, rows in pairs(M.bucket("keymem")) do
        filter(rows, function(r)
            if type(r) ~= "table" or r.k ~= "lastwords" or type(r.t) ~= "string" then return false end
            return aliveName(string.match(r.t, "^(.-)'s last words were"))
        end)
    end
    for _, e in pairs(book) do
        if type(e) == "table" and type(e.hist) == "table" then
            filter(e.hist, function(r)
                return type(r) == "table" and type(r.t) == "string" and aliveName(string.match(r.t, "^Heard (.+)'s last words$"))
            end)
        end
    end
    local news = M.bucket("news")
    if type(news) == "table" and type(news.events) == "table" then
        filter(news.events, function(r)
            return type(r) == "table" and r.k == "lastwords" and type(r.x) == "string" and aliveName(string.match(r.x, "^(.-) died; their last words"))
        end)
    end
    filter(M.bucket("rumors"), function(r)
        return type(r) == "table" and r.k == "lastwords" and type(r.t) == "string" and aliveName(string.match(r.t, "^the newcomer killed (.-) %- who asked"))
    end)
    M.lastWordsCleaned = removed
    log("last words clean-up: " .. removed .. " row(s) about people who are alive removed")
    return removed
end

if type(Events) == "table" then
    if type(Events.ProjectALife_NpcDied) == "table" and type(Events.ProjectALife_NpcDied.Add) == "function" then
        ALifeHealth.add(Events.ProjectALife_NpcDied, "ALifeLLMTalk_LastWords", function(body, uid, killer)
            local ok, e = pcall(M.lastWordsOnDeath, body, uid, killer)
            if not ok then log("last words error: " .. tostring(e)) end
        end)
    end
    if Events.OnTick then
        local n = 0
        ALifeHealth.tickAdd("ALifeLLMTalk_LastWords", function()
            n = n + 1
            if n % 30 ~= 17 then return end
            local ok, e = pcall(M.lastWordsTick)
            if not ok then log("last words tick error: " .. tostring(e)) end
        end)
    end
end

return M
